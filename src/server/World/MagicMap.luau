--!strict
--[[
	MagicMap: the world's magical layer.

	Ambient density at a point (0 dead zone .. 3 nexus):
		density = biome.density * (0.4 + 1.2 * magicNoise)        -- regional texture
		        + lineBoost * falloff(distance to nearest ley line)
		        + nexusBoost * falloff(distance to nearest nexus)
		        then * event multipliers (WorldStateService), clamped to 0..3
	Barren zones appear where magic noise is low and no ley line is near.

	Domain resonance (CastContext.ambientBias): the biome's table, plus the domain carried by a
	nearby ley line (lines carry the dominant domain of their nexuses). Opposed domains
	(Domains data `oppositions`) of a strongly aligned domain are suppressed.

	Ley network: nexuses on a jittered grid (deterministic), connected by a minimum spanning
	tree plus a few short extra edges, so the network has loops.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local Seed = require(Shared.Magic.Seed)
local C = require(script.Parent.WorldConfig)
local Biomes = require(script.Parent.Biomes)
local WorldGen = require(script.Parent.WorldGen)

export type Nexus = {
	id: string,
	x: number,
	z: number,
	biome: string,
	domain: string,
	strength: number,
}

export type LeyLine = {
	a: Nexus,
	b: Nexus,
	domain: string,
}

local MagicMap = {}
MagicMap.__index = MagicMap

type MapData = {
	gen: WorldGen.WorldGen,
	nexuses: { Nexus },
	lines: { LeyLine },
}
export type MagicMap = typeof(setmetatable({} :: MapData, MagicMap))

local HALF = C.WORLD_SIZE / 2
local L = C.ley

-- The domain a biome most favours (ties broken by id for determinism).
local function dominantDomain(biomeId: string): string
	local best, bestValue = "energy", -1
	local resonance = Biomes.defs[biomeId].resonance
	local ids = {}
	for domainId in resonance do
		table.insert(ids, domainId)
	end
	table.sort(ids)
	for _, domainId in ids do
		if resonance[domainId] > bestValue then
			best, bestValue = domainId, resonance[domainId]
		end
	end
	return best
end

function MagicMap.new(gen: WorldGen.WorldGen, worldSeed: number): MagicMap
	local self = setmetatable({ gen = gen, nexuses = {}, lines = {} }, MagicMap)
	local rng = Seed.random(worldSeed, "world", "ley")

	-- 1. Nexuses: one candidate per cell, kept where the land is magical enough.
	local cells = math.floor(C.WORLD_SIZE / L.cell)
	for gz = 0, cells - 1 do
		for gx = 0, cells - 1 do
			local x = -HALF + (gx + 0.15 + rng:NextNumber() * 0.7) * L.cell
			local z = -HALF + (gz + 0.15 + rng:NextNumber() * 0.7) * L.cell
			local s = gen:sample(x, z)
			if s.biome ~= "ocean" and s.magic >= L.acceptMagic then
				table.insert(self.nexuses, {
					id = string.format("nexus_%d_%d", gx, gz),
					x = x,
					z = z,
					biome = s.biome,
					domain = dominantDomain(s.biome),
					strength = 0.6 + 0.4 * s.magic,
				})
			end
		end
	end

	-- 2. Minimum spanning tree (Prim, O(n^2); n is ~20-25) + short extra edges for loops.
	local n = #self.nexuses
	if n >= 2 then
		local inTree = { [1] = true }
		local edges: { [string]: boolean } = {}
		local function dist(a: Nexus, b: Nexus): number
			return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
		end
		local function addLine(i: number, j: number)
			local key = if i < j then i .. ":" .. j else j .. ":" .. i
			if edges[key] then
				return
			end
			edges[key] = true
			local a, b = self.nexuses[i], self.nexuses[j]
			table.insert(self.lines, { a = a, b = b, domain = if a.strength >= b.strength then a.domain else b.domain })
		end
		for _ = 2, n do
			local bestI, bestJ, best = 0, 0, math.huge
			for i in inTree do
				for j = 1, n do
					if not inTree[j] then
						local d = dist(self.nexuses[i], self.nexuses[j])
						if d < best then
							bestI, bestJ, best = i, j, d
						end
					end
				end
			end
			inTree[bestJ] = true
			addLine(bestI, bestJ)
		end
		for i = 1, n do
			for j = i + 1, n do
				local d = dist(self.nexuses[i], self.nexuses[j])
				if d < L.extraEdgeMaxLength and rng:NextNumber() < 0.25 then
					addLine(i, j)
				end
			end
		end
	end
	return self
end

-- Distance from point P to segment AB (2D).
local function segmentDistance(px: number, pz: number, ax: number, az: number, bx: number, bz: number): number
	local dx, dz = bx - ax, bz - az
	local lengthSq = dx * dx + dz * dz
	local t = if lengthSq > 0 then math.clamp(((px - ax) * dx + (pz - az) * dz) / lengthSq, 0, 1) else 0
	local cx, cz = ax + t * dx, az + t * dz
	return math.sqrt((px - cx) ^ 2 + (pz - cz) ^ 2)
end

-- Nearest ley line and nexus influence at a point: (lineFalloff 0..1, lineDomain?, nexusFalloff 0..1, nexus?)
function MagicMap.leyInfluence(self: MagicMap, x: number, z: number): (number, string?, number, Nexus?)
	local bestLine, lineDomain = 0, nil
	for _, line in self.lines do
		local d = segmentDistance(x, z, line.a.x, line.a.z, line.b.x, line.b.z)
		local falloff = math.clamp(1 - d / (L.lineWidth * 3), 0, 1) ^ 2
		if falloff > bestLine then
			bestLine, lineDomain = falloff, line.domain
		end
	end
	local bestNexus, nexus = 0, nil
	for _, candidate in self.nexuses do
		local d = math.sqrt((x - candidate.x) ^ 2 + (z - candidate.z) ^ 2)
		local falloff = math.clamp(1 - d / (L.nexusRadius * 2.5), 0, 1) ^ 2 * candidate.strength
		if falloff > bestNexus then
			bestNexus, nexus = falloff, candidate
		end
	end
	return bestLine, lineDomain, bestNexus, nexus
end

-- Ambient density at a point, before temporary event modifiers.
function MagicMap.densityAt(self: MagicMap, x: number, z: number, sample: WorldGen.Sample?): number
	local s = sample or self.gen:sample(x, z)
	local biome = Biomes.defs[s.biome]
	local line, _, nexus = self:leyInfluence(x, z)
	local density = biome.density * (0.4 + 1.2 * s.magic) + L.lineBoost * line + L.nexusBoost * nexus
	-- Barren pockets: low magic noise far from the network collapses toward 0.
	if s.magic < 0.18 and line < 0.05 and nexus < 0.05 then
		density *= s.magic / 0.18
	end
	return math.clamp(density, 0, 3)
end

-- Domain multipliers at a point (CastContext.ambientBias).
function MagicMap.resonanceAt(self: MagicMap, x: number, z: number, sample: WorldGen.Sample?): { [string]: number }
	local s = sample or self.gen:sample(x, z)
	local bias: { [string]: number } = table.clone(Biomes.defs[s.biome].resonance)
	local line, lineDomain = self:leyInfluence(x, z)
	if lineDomain and line > 0 then
		bias[lineDomain] = (bias[lineDomain] or 1) * (1 + 0.2 * line)
	end
	-- Strong alignment suppresses that domain's oppositions (if the biome doesn't already set them).
	for domainId, value in table.clone(bias) do
		if value >= 1.25 then
			for _, opposed in Registry.domains[domainId].oppositions do
				if bias[opposed] == nil then
					bias[opposed] = 0.85
				end
			end
		end
	end
	return bias
end

return MagicMap
