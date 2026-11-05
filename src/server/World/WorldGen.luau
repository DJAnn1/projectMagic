--!strict
--[[
	WorldGen: the deterministic shape of the world. A pure function of (seed, x, z): height,
	climate, tectonic stress, magic noise and biome. Nothing here touches Instances, so any
	server (or a Studio bake) produces the identical world.

		local gen = WorldGen.new(seed)
		local s = gen:sample(x, z)            -- one point: height, temperature, moisture, biome, ...
		local h = gen:height(x, z)            -- height only (cheaper)
		local field = gen:chunkField(cx, cz)  -- per-voxel heights + coarse biome grid for building

	SERVER ONLY: the terrain seed is derived from the world seed, and a 32-bit world seed can be
	brute-forced from enough terrain samples. Clients get biome/density via RegionInfo instead.
]]

local Seed = require(game:GetService("ReplicatedStorage").Shared.Magic.Seed)
local C = require(script.Parent.WorldConfig)
local Noise = require(script.Parent.Noise)
local Biomes = require(script.Parent.Biomes)

export type Sample = {
	x: number,
	z: number,
	height: number,
	continental: number,
	temperature: number, -- 0 cold .. 1 hot
	moisture: number, -- 0 dry .. 1 wet
	magic: number, -- 0..1 raw magic noise (MagicMap adds biome and ley lines)
	fault: number, -- 0..1 closeness to a fault line
	ancient: number, -- 0..1
	biome: string,
}

export type ChunkField = {
	cx: number,
	cz: number,
	originX: number, -- world X of voxel column 1's min edge
	originZ: number,
	size: number, -- columns per side (64)
	heights: { number }, -- (size + 2)^2, includes a 1-column border for slopes; index via fieldIndex
	biomes: { string }, -- per column (size^2), from the coarse biome grid
	minHeight: number,
	maxHeight: number,
	hasCaverns: boolean,
}

local WorldGen = {}
WorldGen.__index = WorldGen

type GenData = {
	seed: number,
	layers: { [string]: Noise.Layer },
}
export type WorldGen = typeof(setmetatable({} :: GenData, WorldGen))

function WorldGen.new(worldSeed: number): WorldGen
	-- The terrain uses a derived seed so generation layers never see the world seed directly.
	local terrainSeed = Seed.derive(worldSeed, "world", "terrain")
	local layers = {}
	for name, config in C.noise do
		layers[name] = Noise.layer(terrainSeed, name, config :: any)
	end
	return setmetatable({ seed = terrainSeed, layers = layers }, WorldGen)
end

local HALF = C.WORLD_SIZE / 2
local T = C.terrain

function WorldGen.continental(self: WorldGen, x: number, z: number): number
	local wx, wz = Noise.warp(self.layers.warp, x, z, C.noise.warp.amplitude)
	local c = Noise.fbm(self.layers.continent, wx, wz) + 0.35 -- land bias: ~1/3 of the world is ocean
	-- Sink the edges so the world is an island continent surrounded by ocean.
	local d = math.max(math.abs(x), math.abs(z)) / HALF
	if d > T.edgeFalloffStart then
		c -= (d - T.edgeFalloffStart) * T.edgeFalloffStrength
	end
	return c
end

function WorldGen.heightFrom(self: WorldGen, x: number, z: number, c: number): number
	if c < T.shore then
		return math.max(T.seaFloorMin, C.SEA_LEVEL - 6 - (T.shore - c) * 170)
	end
	local land = c - T.shore
	local hills = Noise.fbm(self.layers.hills, x, z) * T.hillAmplitude * (0.4 + land)
	local ridge = Noise.ridged(self.layers.ridges, x, z)
	local mountainMask = Noise.smoothstep(0.25, 0.65, land)
	local h = C.SEA_LEVEL + 2 + land * T.landBase + hills + ridge * ridge * ridge * T.mountainHeight * mountainMask
	return math.clamp(h, T.seaFloorMin, C.MAX_HEIGHT)
end

function WorldGen.height(self: WorldGen, x: number, z: number): number
	return self:heightFrom(x, z, self:continental(x, z))
end

-- Climate and special fields; `h` and `c` may be passed in when already known.
function WorldGen.sample(self: WorldGen, x: number, z: number, cIn: number?, hIn: number?): Sample
	local c = cIn or self:continental(x, z)
	local h = hIn or self:heightFrom(x, z, c)
	local L = self.layers
	local latitude = math.clamp(z / HALF, -1, 1) -- north (-Z) is cold, south (+Z) is hot
	local temperature = 0.5 + 0.32 * latitude + 0.22 * Noise.fbm(L.temperature, x, z) - math.max(0, h - C.SEA_LEVEL) / 520
	local coastal = math.clamp(0.25 - (c - T.shore), 0, 0.25)
	local moisture = 0.5 + 0.4 * Noise.fbm(L.moisture, x, z) + coastal
	local magic = math.clamp(0.5 + 0.55 * Noise.fbm(L.magic, x, z), 0, 1)
	local fault = Noise.ridged(L.faults, x, z)
	local ancient = math.clamp(0.5 + 0.6 * Noise.fbm(L.ancient, x, z), 0, 1)
	local s: Sample = {
		x = x,
		z = z,
		height = h,
		continental = c,
		temperature = math.clamp(temperature, 0, 1),
		moisture = math.clamp(moisture, 0, 1),
		magic = magic,
		fault = fault,
		ancient = ancient,
		biome = "grasslands",
	}
	s.biome = WorldGen.biomeFor(s)
	return s
end

--[[
	Biome rules, checked in order (first match wins). Keeping this a readable ordered list makes
	it easy to reason about and tune; see docs/World.md §3 for the table.
]]
function WorldGen.biomeFor(s: Sample): string
	local h, t, m = s.height, s.temperature, s.moisture
	local sea = C.SEA_LEVEL
	if h < sea - 6 then
		return "ocean"
	elseif h < sea + 4 then
		return if t < 0.3 then "frozen_coast" else "tidal_flats"
	elseif h > 240 then
		if t < 0.42 then
			return "frostpeaks"
		elseif s.fault > 0.55 and t > 0.55 then
			return "volcanic_highlands"
		end
		return "mountains"
	elseif s.fault > 0.58 and t > 0.6 and h > 90 then
		return "volcanic_highlands"
	elseif s.magic > 0.78 and h > 130 then
		return "skyreach"
	elseif t < 0.24 then
		return "tundra"
	elseif t > 0.66 and m < 0.32 then
		return "desert_dunes"
	elseif t > 0.58 and m < 0.45 then
		return "badlands"
	elseif m > 0.74 and h < sea + 34 and t > 0.42 then
		return "swamp"
	elseif m > 0.56 then
		return "deep_forest"
	elseif s.ancient > 0.8 then
		return "ruinlands"
	elseif h > 180 then
		return "mountains"
	end
	return "grasslands"
end

-- Crystal caverns exist beneath these surface biomes, where the cave noise allows.
local CAVERN_HOSTS: { [string]: boolean } = { mountains = true, badlands = true, frostpeaks = true }

function WorldGen.isCave(self: WorldGen, x: number, y: number, z: number, surface: number): boolean
	if y > surface - 12 or y < surface - 90 or y < C.BEDROCK_Y + 8 then
		return false
	end
	return Noise.fbm3(self.layers.caves, x, y * 1.6, z) > 0.42
end

local function chunkOrigin(cx: number, cz: number): (number, number)
	return -HALF + cx * C.CHUNK_SIZE, -HALF + cz * C.CHUNK_SIZE
end
WorldGen.chunkOrigin = chunkOrigin

function WorldGen.chunkOf(x: number, z: number): (number, number)
	return math.floor((x + HALF) / C.CHUNK_SIZE), math.floor((z + HALF) / C.CHUNK_SIZE)
end

function WorldGen.chunkCount(): number
	return C.WORLD_SIZE // C.CHUNK_SIZE
end

-- Index into ChunkField.heights for column (i, k), with i, k in 0..size+1 (0 and size+1 are the border).
function WorldGen.fieldIndex(size: number, i: number, k: number): number
	return k * (size + 2) + i + 1
end

--[[
	Everything TerrainBuilder needs for one chunk. Heights are per voxel column (with a border
	for slope tests); biomes come from a coarse grid every BIOME_STEP columns, reused for the
	columns in between (the slow climate layers don't need per-voxel resolution).
	`yieldFn` is called periodically so the caller can spread the work across frames.
]]
function WorldGen.chunkField(self: WorldGen, cx: number, cz: number, yieldFn: (() -> ())?): ChunkField
	local size = C.CHUNK_SIZE // C.VOXEL
	local originX, originZ = chunkOrigin(cx, cz)
	local heights: { number } = table.create((size + 2) * (size + 2))
	local minH, maxH = math.huge, -math.huge
	local half = C.VOXEL / 2

	for k = 0, size + 1 do
		for i = 0, size + 1 do
			local x = originX + (i - 1) * C.VOXEL + half
			local z = originZ + (k - 1) * C.VOXEL + half
			local h = self:height(x, z)
			heights[WorldGen.fieldIndex(size, i, k)] = h
			if i >= 1 and i <= size and k >= 1 and k <= size then
				minH = math.min(minH, h)
				maxH = math.max(maxH, h)
			end
		end
		if yieldFn and k % 8 == 0 then
			yieldFn()
		end
	end

	local biomes: { string } = table.create(size * size)
	local step = C.BIOME_STEP
	local hasCaverns = false
	for k0 = 1, size, step do
		for i0 = 1, size, step do
			local ci, ck = i0 + step // 2, k0 + step // 2
			local x = originX + (ci - 1) * C.VOXEL + half
			local z = originZ + (ck - 1) * C.VOXEL + half
			local s = self:sample(x, z, nil, heights[WorldGen.fieldIndex(size, ci, ck)])
			hasCaverns = hasCaverns or CAVERN_HOSTS[s.biome] == true
			for k = k0, math.min(size, k0 + step - 1) do
				for i = i0, math.min(size, i0 + step - 1) do
					biomes[(k - 1) * size + i] = s.biome
				end
			end
		end
		if yieldFn then
			yieldFn()
		end
	end

	return {
		cx = cx,
		cz = cz,
		originX = originX,
		originZ = originZ,
		size = size,
		heights = heights,
		biomes = biomes,
		minHeight = minH,
		maxHeight = maxH,
		hasCaverns = hasCaverns,
	}
end

-- Dominant biome and stats for a chunk (cheap: a 5x5 sample grid). Cached by callers.
function WorldGen.chunkSummary(self: WorldGen, cx: number, cz: number): { biome: string, counts: { [string]: number }, meanHeight: number }
	local originX, originZ = chunkOrigin(cx, cz)
	local counts: { [string]: number } = {}
	local total = 0
	for k = 0, 4 do
		for i = 0, 4 do
			local s = self:sample(originX + (i + 0.5) * C.CHUNK_SIZE / 5, originZ + (k + 0.5) * C.CHUNK_SIZE / 5)
			counts[s.biome] = (counts[s.biome] or 0) + 1
			total += s.height
		end
	end
	local best, bestCount = "grasslands", -1
	for _, id in Biomes.order do
		if (counts[id] or 0) > bestCount then
			best, bestCount = id, counts[id] or 0
		end
	end
	return { biome = best, counts = counts, meanHeight = total / 25 }
end

return WorldGen
