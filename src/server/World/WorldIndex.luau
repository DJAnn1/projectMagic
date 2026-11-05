--!strict
--[[
	WorldIndex: a coarse 32 x 32 grid (one cell per REGION_SIZE = 128 studs) sampled once at
	server start (~1k samples, a few hundred ms spread over frames). Used for:
	- POI placement (candidate cells with height, slope, biome, density, ore)
	- ocean mask, and which ocean cells connect to the open sea (flood fill from the world edge)
	- distance to coast in cells (BFS), for settlements, tsunami targeting and coastline checks
	Region ids ("rx,rz") match WorldStateService's environment regions.
]]

local C = require(script.Parent.WorldConfig)
local WorldGen = require(script.Parent.WorldGen)
local MagicMap = require(script.Parent.MagicMap)
local Biomes = require(script.Parent.Biomes)

export type Cell = {
	rx: number,
	rz: number,
	x: number, -- centre, world studs
	z: number,
	sample: WorldGen.Sample,
	density: number,
	slope: number,
	ore: number,
	ocean: boolean,
	openSea: boolean, -- ocean connected to the world edge
	coastDistance: number, -- in cells; 0 = coastal land or ocean
}

local WorldIndex = {}
WorldIndex.__index = WorldIndex

type IndexData = { size: number, cells: { Cell } }
export type WorldIndex = typeof(setmetatable({} :: IndexData, WorldIndex))

local HALF = C.WORLD_SIZE / 2

function WorldIndex.regionOf(x: number, z: number): (number, number)
	local n = C.WORLD_SIZE // C.REGION_SIZE
	return math.clamp(math.floor((x + HALF) / C.REGION_SIZE), 0, n - 1), math.clamp(math.floor((z + HALF) / C.REGION_SIZE), 0, n - 1)
end

function WorldIndex.regionId(rx: number, rz: number): string
	return rx .. "," .. rz
end

function WorldIndex.build(gen: WorldGen.WorldGen, magic: MagicMap.MagicMap, yieldFn: (() -> ())?): WorldIndex
	local n = C.WORLD_SIZE // C.REGION_SIZE
	local cells: { Cell } = table.create(n * n)
	for rz = 0, n - 1 do
		for rx = 0, n - 1 do
			local x = -HALF + (rx + 0.5) * C.REGION_SIZE
			local z = -HALF + (rz + 0.5) * C.REGION_SIZE
			local s = gen:sample(x, z)
			local hx = gen:height(x + 16, z)
			local hz = gen:height(x, z + 16)
			cells[rz * n + rx + 1] = {
				rx = rx,
				rz = rz,
				x = x,
				z = z,
				sample = s,
				density = magic:densityAt(x, z, s),
				slope = math.max(math.abs(hx - s.height), math.abs(hz - s.height)) / 16,
				ore = Biomes.defs[s.biome].ore * (0.5 + 0.5 * s.fault),
				ocean = s.height < C.SEA_LEVEL,
				openSea = false,
				coastDistance = math.huge,
			}
		end
		if yieldFn then
			yieldFn()
		end
	end
	local self = setmetatable({ size = n, cells = cells }, WorldIndex)

	-- Open sea: flood fill through ocean cells from the border.
	local queue = {}
	for _, cell in cells do
		if cell.ocean and (cell.rx == 0 or cell.rz == 0 or cell.rx == n - 1 or cell.rz == n - 1) then
			cell.openSea = true
			table.insert(queue, cell)
		end
	end
	local head = 1
	while head <= #queue do
		local cell = queue[head]
		head += 1
		for _, neighbor in self:neighbors(cell) do
			if neighbor.ocean and not neighbor.openSea then
				neighbor.openSea = true
				table.insert(queue, neighbor)
			end
		end
	end

	-- Coast distance: BFS from every land cell touching ocean (and every ocean cell).
	queue, head = {}, 1
	for _, cell in cells do
		local coastal = cell.ocean
		if not coastal then
			for _, neighbor in self:neighbors(cell) do
				coastal = coastal or neighbor.ocean
			end
		end
		if coastal then
			cell.coastDistance = 0
			table.insert(queue, cell)
		end
	end
	while head <= #queue do
		local cell = queue[head]
		head += 1
		for _, neighbor in self:neighbors(cell) do
			if neighbor.coastDistance > cell.coastDistance + 1 then
				neighbor.coastDistance = cell.coastDistance + 1
				table.insert(queue, neighbor)
			end
		end
	end
	return self
end

function WorldIndex.cell(self: WorldIndex, rx: number, rz: number): Cell?
	if rx < 0 or rz < 0 or rx >= self.size or rz >= self.size then
		return nil
	end
	return self.cells[rz * self.size + rx + 1]
end

function WorldIndex.cellAt(self: WorldIndex, x: number, z: number): Cell
	local rx, rz = WorldIndex.regionOf(x, z)
	return self.cells[rz * self.size + rx + 1]
end

function WorldIndex.neighbors(self: WorldIndex, cell: Cell): { Cell }
	local out = {}
	for _, d in { { 1, 0 }, { -1, 0 }, { 0, 1 }, { 0, -1 } } do
		local neighbor = self:cell(cell.rx + d[1], cell.rz + d[2])
		if neighbor then
			table.insert(out, neighbor)
		end
	end
	return out
end

return WorldIndex
