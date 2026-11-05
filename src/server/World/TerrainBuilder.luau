--!strict
--[[
	TerrainBuilder: turns a chunk of WorldGen into Roblox terrain without hitching.

	Pipeline for one chunk (runs as a Scheduler job, yielding between steps):
	1. WorldGen.chunkField: per-voxel heights + coarse biome grid (yields every 8 rows).
	2. Deep fill: one FillBlock of rock from bedrock up to (lowest surface - SHELL_DEPTH).
	   Cheap, engine-side, and means digging deep never finds a void.
	3. Detail band: for each 32x32 quadrant, WriteVoxels slabs of 32x16x32 voxels covering
	   [lowest surface - SHELL_DEPTH, max(highest surface, sea level) + 4]. Per voxel:
	   material by depth and slope, smooth occupancy at the surface, water below sea level,
	   caves in cavern hosts, road paint.
	4. Features: floating islands in Skyreach (a few FillBall blobs).
	5. Ops, in this order (applyChunkOps):
	   a. generated settlement ops (paving, levelling, foundations), clipped to this chunk;
	   b. ground painters (SettlementGround: surface materials inside each town's mask);
	   c. persistent deltas: the chunk's recorded terrain edits (idempotent ops), so players'
	      and disasters' edits always win.

	Cost: about 12-40 WriteVoxels slabs per chunk, about 2-5 ms each; at a 4 ms frame budget a chunk takes
	roughly 10-40 frames. Air above the surface is never written (terrain starts empty).
]]

local C = require(script.Parent.WorldConfig)
local WorldGen = require(script.Parent.WorldGen)
local Biomes = require(script.Parent.Biomes)
local Seed = require(game:GetService("ReplicatedStorage").Shared.Magic.Seed)
local Scheduler = require(script.Parent.Parent.Core.Scheduler)

export type Road = { ax: number, az: number, bx: number, bz: number, width: number }

export type TerrainOp = {
	i: string, -- op id (deduplication)
	k: string, -- "ball" | "block" | "replace"
	m: string, -- material name ("Air" erases)
	x: number,
	y: number,
	z: number,
	r: number?, -- ball radius
	sx: number?, -- block / replace size
	sy: number?,
	sz: number?,
	f: string?, -- replace: source material
	t: number, -- unix time recorded
	c: boolean?, -- clip to the chunk being built (generated settlement ops)
}

-- An XZ rectangle ops may write into: the chunk being built.
export type Clip = { x0: number, z0: number, x1: number, z1: number }

-- Rewrites surface materials inside a clip (SettlementGround.paint). Runs inside the chunk job.
export type Painter = (Clip) -> ()

local TerrainBuilder = {}

local terrain = workspace.Terrain
local M = Enum.Material
local QUADRANT = 32 -- voxel columns per quadrant side

local function slopeAt(field: WorldGen.ChunkField, i: number, k: number): number
	local idx = WorldGen.fieldIndex
	local size = field.size
	local h = field.heights
	local dx = math.abs(h[idx(size, i + 1, k)] - h[idx(size, i - 1, k)])
	local dz = math.abs(h[idx(size, i, k + 1)] - h[idx(size, i, k - 1)])
	return math.max(dx, dz) / (2 * C.VOXEL)
end

-- Columns within a road's width get road material on top.
local function roadMask(field: WorldGen.ChunkField, roads: { Road }): { [number]: boolean }
	local mask: { [number]: boolean } = {}
	local size = field.size
	for _, road in roads do
		local dx, dz = road.bx - road.ax, road.bz - road.az
		local lengthSq = dx * dx + dz * dz
		for k = 1, size do
			for i = 1, size do
				local x = field.originX + (i - 0.5) * C.VOXEL
				local z = field.originZ + (k - 0.5) * C.VOXEL
				local t = if lengthSq > 0 then math.clamp(((x - road.ax) * dx + (z - road.az) * dz) / lengthSq, 0, 1) else 0
				local px, pz = road.ax + t * dx, road.az + t * dz
				if (x - px) ^ 2 + (z - pz) ^ 2 <= road.width * road.width then
					mask[(k - 1) * size + i] = true
				end
			end
		end
	end
	return mask
end

local function writeSlab(gen: WorldGen.WorldGen, field: WorldGen.ChunkField, q0i: number, q0k: number, y0: number, slabVoxels: number, roads: { [number]: boolean })
	local size = field.size
	local materials = table.create(QUADRANT)
	local occupancy = table.create(QUADRANT)
	local seaLevel = C.SEA_LEVEL
	local voxel = C.VOXEL
	for qi = 1, QUADRANT do
		local i = q0i + qi - 1
		local matX = table.create(slabVoxels)
		local occX = table.create(slabVoxels)
		materials[qi], occupancy[qi] = matX, occX
		for yj = 1, slabVoxels do
			matX[yj], occX[yj] = table.create(QUADRANT, M.Air), table.create(QUADRANT, 0)
		end
		for qk = 1, QUADRANT do
			local k = q0k + qk - 1
			local column = (k - 1) * size + i
			local h = field.heights[WorldGen.fieldIndex(size, i, k)]
			local biome = Biomes.defs[field.biomes[column]]
			local mats = biome.materials
			local cliff = slopeAt(field, i, k) > C.terrain.cliffSlope
			local cavernHost = field.hasCaverns and (field.biomes[column] == "mountains" or field.biomes[column] == "badlands" or field.biomes[column] == "frostpeaks")
			local x = field.originX + (i - 0.5) * voxel
			local z = field.originZ + (k - 0.5) * voxel
			for yj = 1, slabVoxels do
				local yBottom = y0 + (yj - 1) * voxel
				local yCenter = yBottom + voxel / 2
				local material, occ = M.Air, 0
				if yCenter < h - voxel / 2 then
					local depth = h - yCenter
					if cavernHost and gen:isCave(x, yCenter, z, h) then
						material, occ = M.Air, 0
					elseif cliff and depth < 12 then
						material, occ = mats.cliff, 1
					elseif depth < voxel then
						material, occ = (if roads[column] then M.Cobblestone else mats.top), 1
					elseif depth < 14 then
						material, occ = mats.sub, 1
					else
						material, occ = mats.deep, 1
					end
				elseif yBottom < h then
					-- Surface voxel: partial occupancy gives smooth terrain instead of steps.
					material = if cliff then mats.cliff elseif roads[column] then M.Cobblestone else mats.top
					occ = math.clamp((h - yBottom) / voxel, 0.05, 1)
				elseif yCenter < seaLevel then
					material, occ = M.Water, 1
				end
				matX[yj][qk] = material
				occX[yj][qk] = occ
			end
		end
	end
	local min = Vector3.new(field.originX + (q0i - 1) * voxel, y0, field.originZ + (q0k - 1) * voxel)
	local max = min + Vector3.new(QUADRANT * voxel, slabVoxels * voxel, QUADRANT * voxel)
	terrain:WriteVoxels(Region3.new(min, max):ExpandToGrid(voxel), voxel, materials, occupancy)
end

-- Floating islands: deterministic blobs of FillBall per Skyreach chunk.
local function floatingIslands(gen: WorldGen.WorldGen, field: WorldGen.ChunkField)
	local skyColumns = 0
	for _, biome in field.biomes do
		if biome == "skyreach" then
			skyColumns += 1
		end
	end
	if skyColumns < #field.biomes * 0.3 then
		return
	end
	local rng = Random.new(Seed.derive(gen.seed, string.format("%d,%d", field.cx, field.cz), "islands"))
	for _ = 1, rng:NextInteger(1, 3) do
		local x = field.originX + rng:NextNumber(40, C.CHUNK_SIZE - 40)
		local z = field.originZ + rng:NextNumber(40, C.CHUNK_SIZE - 40)
		local y = field.maxHeight + rng:NextNumber(60, 140)
		local radius = rng:NextNumber(18, 40)
		terrain:FillBall(Vector3.new(x, y, z), radius, M.Limestone)
		for _ = 1, 3 do -- a tapering underside
			local drop = rng:NextNumber(0.6, 1.2) * radius
			terrain:FillBall(Vector3.new(x + rng:NextNumber(-8, 8), y - drop, z + rng:NextNumber(-8, 8)), radius * 0.55, M.Rock)
		end
		terrain:FillBlock(CFrame.new(x, y + radius * 0.55, z), Vector3.new(radius * 1.3, 4, radius * 1.3), M.Grass)
		Scheduler.checkpoint()
	end
end

function TerrainBuilder.chunkClip(cx: number, cz: number): Clip
	local originX, originZ = WorldGen.chunkOrigin(cx, cz)
	return { x0 = originX, z0 = originZ, x1 = originX + C.CHUNK_SIZE, z1 = originZ + C.CHUNK_SIZE }
end

--[[
	Applies one recorded edit. Ops are idempotent: replaying them always gives the same result.
	With `clip`, a block op marked `c` only writes the part inside the clip rectangle (the chunk
	being built). Every chunk then writes only its own columns, in op order, so an op that spans
	a chunk border gives the same terrain whichever chunk builds first, and a chunk built later
	never re-fills terrain over a neighbour's building. Chunk borders lie on the voxel grid, so a
	clipped box covers each voxel exactly as much as the whole box would: no seams.
]]
function TerrainBuilder.applyOp(op: TerrainOp, clip: Clip?)
	local material = (Enum.Material :: any)[op.m] or M.Air
	local position = Vector3.new(op.x, op.y, op.z)
	if op.k == "ball" then
		terrain:FillBall(position, op.r or 4, material)
	elseif op.k == "block" then
		local sx, sy, sz = op.sx or 4, op.sy or 4, op.sz or 4
		if clip and op.c then
			local x0, x1 = math.max(op.x - sx / 2, clip.x0), math.min(op.x + sx / 2, clip.x1)
			local z0, z1 = math.max(op.z - sz / 2, clip.z0), math.min(op.z + sz / 2, clip.z1)
			if x1 - x0 <= 0 or z1 - z0 <= 0 then
				return
			end
			position = Vector3.new((x0 + x1) / 2, op.y, (z0 + z1) / 2)
			sx, sz = x1 - x0, z1 - z0
		end
		terrain:FillBlock(CFrame.new(position), Vector3.new(sx, sy, sz), material)
	elseif op.k == "replace" then
		local half = Vector3.new(op.sx or 4, op.sy or 4, op.sz or 4) / 2
		local source = (Enum.Material :: any)[op.f or "Air"] or M.Air
		terrain:ReplaceMaterial(Region3.new(position - half, position + half):ExpandToGrid(C.VOXEL), C.VOXEL, source, material)
	end
end

--[[
	Applies a chunk's ops: generated ones (c = true, always first in the list) clipped to the
	chunk, then the ground painters, then the saved edits. MUST run inside a Scheduler job.
]]
function TerrainBuilder.applyChunkOps(cx: number, cz: number, ops: { TerrainOp }, painters: { Painter }?)
	local clip = TerrainBuilder.chunkClip(cx, cz)
	local painted = false
	local function paint()
		painted = true
		for _, painter in (painters or {}) :: { Painter } do
			painter(clip)
			Scheduler.checkpoint()
		end
	end
	for index, op in ops do
		if not op.c and not painted then
			paint()
		end
		TerrainBuilder.applyOp(op, clip)
		if index % 20 == 0 then
			Scheduler.checkpoint()
		end
	end
	if not painted then
		paint()
	end
end

--[[
	Builds one chunk. MUST run inside a Scheduler job (it calls Scheduler.checkpoint).
	`roads` are the road segments touching this chunk; `ops` the generated ops then the persisted
	edits to replay; `painters` the settlement ground passes for this chunk.
]]
function TerrainBuilder.buildChunk(gen: WorldGen.WorldGen, cx: number, cz: number, roads: { Road }, ops: { TerrainOp }, painters: { Painter }?)
	local field = gen:chunkField(cx, cz, Scheduler.checkpoint)
	local voxel = C.VOXEL
	local roadColumns = roadMask(field, roads)
	Scheduler.checkpoint()

	-- 2. Deep fill (one engine call).
	local shellBottom = math.floor((field.minHeight - C.SHELL_DEPTH) / voxel) * voxel
	if shellBottom > C.BEDROCK_Y then
		local centre = Vector3.new(field.originX + C.CHUNK_SIZE / 2, (C.BEDROCK_Y + shellBottom) / 2, field.originZ + C.CHUNK_SIZE / 2)
		terrain:FillBlock(CFrame.new(centre), Vector3.new(C.CHUNK_SIZE, shellBottom - C.BEDROCK_Y, C.CHUNK_SIZE), M.Rock)
	end

	-- 3. Detail band, per quadrant, in slabs.
	local slab = C.SLAB_VOXELS
	for q0k = 1, field.size, QUADRANT do
		for q0i = 1, field.size, QUADRANT do
			local qMin, qMax = math.huge, -math.huge
			for k = q0k, q0k + QUADRANT - 1 do
				for i = q0i, q0i + QUADRANT - 1 do
					local h = field.heights[WorldGen.fieldIndex(field.size, i, k)]
					qMin, qMax = math.min(qMin, h), math.max(qMax, h)
				end
			end
			local bottom = math.max(C.BEDROCK_Y, math.floor((math.min(qMin, field.minHeight) - C.SHELL_DEPTH) / voxel) * voxel)
			local top = math.max(qMax, C.SEA_LEVEL) + voxel
			local y = math.max(bottom, shellBottom)
			while y < top do
				writeSlab(gen, field, q0i, q0k, y, slab, roadColumns)
				y += slab * voxel
				Scheduler.checkpoint()
			end
		end
	end

	-- 4. Features.
	floatingIslands(gen, field)

	-- 5. Generated settlement ops, the ground pass, then persistent edits.
	TerrainBuilder.applyChunkOps(cx, cz, ops, painters)
end

-- Clears a chunk's terrain (used before a rebuild, e.g. after a delta compaction).
function TerrainBuilder.clearChunk(cx: number, cz: number)
	local originX, originZ = WorldGen.chunkOrigin(cx, cz)
	local min = Vector3.new(originX, C.BEDROCK_Y, originZ)
	local max = Vector3.new(originX + C.CHUNK_SIZE, C.MAX_HEIGHT + 300, originZ + C.CHUNK_SIZE)
	terrain:FillRegion(Region3.new(min, max):ExpandToGrid(C.VOXEL), C.VOXEL, M.Air)
end

return TerrainBuilder
