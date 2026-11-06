--!strict
--[[
	MapData: what the map knows, and the rules for what you've uncovered (docs/Map.md). Shared and pure, so
	the server and client agree on the grid, and Tests/Map.spec can check every rule.

	GRID     The island is cut into `cols` x `cols` cells of `cell` studs. Each cell is one character: its
	         biome and how high it stands. "." means you haven't uncovered it.
	REVEALED A bitset in the player's save (data.discoveries.map): word index as a string key -> 30 bits,
	         so it's a few KB at most, and it compresses with the rest of discoveries.
	SECRETS  This holds looks and arithmetic only. Hidden sites are filtered out on the server
	         (MapData.knownPois), and a client is only ever sent the cells it has uncovered.
]]

local rgb = Color3.fromRGB

local WORLD_SIZE = 4096 -- WorldConfig.WORLD_SIZE: the spec checks they agree
local HALF = WORLD_SIZE / 2
local CELL = 64
local COLS = WORLD_SIZE // CELL
local WORD_BITS = 30
local SHADES = 3
local FIRST_CODE = 48 -- "0": a printable start, so a grid can be read in a log
local UNKNOWN = "."

export type BiomeStyle = { id: string, name: string, color: Color3 }
export type PoiStyle = { glyph: string, label: string }
export type KnownPoi = { id: string, type: string, x: number, z: number, name: string? }

-- Order matters: a biome's place in this list is its code. Add new biomes at the end.
local biomes: { BiomeStyle } = {
	{ id = "ocean", name = "Open Ocean", color = rgb(38, 78, 120) },
	{ id = "tidal_flats", name = "Tidal Flats", color = rgb(176, 168, 130) },
	{ id = "frozen_coast", name = "Frozen Coast", color = rgb(200, 220, 228) },
	{ id = "tundra", name = "Tundra", color = rgb(172, 186, 170) },
	{ id = "grasslands", name = "Grasslands", color = rgb(112, 158, 84) },
	{ id = "deep_forest", name = "Deep Forest", color = rgb(52, 104, 62) },
	{ id = "swamp", name = "Swamp", color = rgb(84, 98, 62) },
	{ id = "desert_dunes", name = "Desert Dunes", color = rgb(216, 190, 124) },
	{ id = "badlands", name = "Red Badlands", color = rgb(176, 96, 62) },
	{ id = "mountains", name = "Mountain Range", color = rgb(124, 118, 112) },
	{ id = "frostpeaks", name = "Frostpeaks", color = rgb(226, 234, 240) },
	{ id = "volcanic_highlands", name = "Volcanic Highlands", color = rgb(74, 54, 54) },
	{ id = "skyreach", name = "Skyreach", color = rgb(150, 190, 150) },
	{ id = "ruinlands", name = "Ruinlands", color = rgb(146, 132, 108) },
	{ id = "crystal_caverns", name = "Crystal Caverns", color = rgb(150, 130, 190) },
}

local biomeIndex: { [string]: number } = {}
for i, biome in biomes do
	biomeIndex[biome.id] = i
end

local poiStyles: { [string]: PoiStyle } = {
	settlement = { glyph = "⌂", label = "Town" },
	academy = { glyph = "✎", label = "Academy" },
	hermit_tower = { glyph = "♜", label = "Hermit's tower" },
	ruined_library = { glyph = "▤", label = "Ruined library" },
	mine = { glyph = "⚒", label = "Mine" },
	volcanic_vent = { glyph = "▲", label = "Volcanic vent" },
	fault_zone = { glyph = "≈", label = "Fault zone" },
	ocean_trench = { glyph = "▽", label = "Ocean trench" },
	singing_caverns = { glyph = "♪", label = "Singing Caverns" },
	hollow_grove = { glyph = "♣", label = "Hollow Grove" },
	sunken_shrine = { glyph = "✧", label = "Sunken shrine" },
	quiet_place = { glyph = "○", label = "A quiet place" },
	dungeon = { glyph = "☗", label = "Dungeon" },
}

local MapData = {
	worldSize = WORLD_SIZE,
	cell = CELL,
	cols = COLS,
	unknown = UNKNOWN,
	biomes = biomes,
	revealRadius = 192, -- studs you uncover around you
	revealPerHeight = 0.5, -- plus this per stud above the ground: you can see further from up high
	maxRevealRadius = 448,
}

-- ─── The grid ───────────────────────────────────────────────────────────────

-- Cells count from 0, row by row. Anywhere off the island clamps to its edge.
function MapData.cellIndex(x: number, z: number): number
	local cx = math.clamp(math.floor((x + HALF) / CELL), 0, COLS - 1)
	local cz = math.clamp(math.floor((z + HALF) / CELL), 0, COLS - 1)
	return cz * COLS + cx
end

function MapData.cellCentre(index: number): (number, number)
	local cz = index // COLS
	local cx = index - cz * COLS
	return (cx + 0.5) * CELL - HALF, (cz + 0.5) * CELL - HALF
end

-- Where a world position sits on the map, 0..1 on each axis, and back.
function MapData.toMap(x: number, z: number): (number, number)
	return math.clamp((x + HALF) / WORLD_SIZE, 0, 1), math.clamp((z + HALF) / WORLD_SIZE, 0, 1)
end

function MapData.fromMap(u: number, v: number): (number, number)
	return math.clamp(u, 0, 1) * WORLD_SIZE - HALF, math.clamp(v, 0, 1) * WORLD_SIZE - HALF
end

-- One cell as one character: biome and shade (0 low, 1 mid, 2 high).
function MapData.encodeCell(biome: string, height: number, seaLevel: number): string
	local index = biomeIndex[biome] or 1
	local above = height - seaLevel
	local shade = if above < 25 then 0 elseif above < 90 then 1 else 2
	return string.char(FIRST_CODE + (index - 1) * SHADES + shade)
end

-- The colour of a cell's character, or nil if it isn't uncovered. High ground is lighter, low darker.
function MapData.colorOf(code: string): Color3?
	if code == UNKNOWN or code == "" then
		return nil
	end
	local value = string.byte(code) - FIRST_CODE
	local biome = biomes[value // SHADES + 1]
	if not biome then
		return nil
	end
	local shade = value % SHADES
	if shade == 0 then
		return biome.color:Lerp(Color3.new(0, 0, 0), 0.12)
	elseif shade == 2 then
		return biome.color:Lerp(Color3.new(1, 1, 1), 0.14)
	end
	return biome.color
end

-- ─── What you've uncovered ──────────────────────────────────────────────────

function MapData.isRevealed(bits: { [string]: number }, index: number): boolean
	local word = bits[tostring(index // WORD_BITS)]
	return word ~= nil and bit32.btest(word, bit32.lshift(1, index % WORD_BITS))
end

-- Returns true if this is news.
function MapData.reveal(bits: { [string]: number }, index: number): boolean
	if MapData.isRevealed(bits, index) then
		return false
	end
	local key = tostring(index // WORD_BITS)
	bits[key] = bit32.bor(bits[key] or 0, bit32.lshift(1, index % WORD_BITS))
	return true
end

function MapData.radiusAt(heightAboveGround: number): number
	return math.min(MapData.maxRevealRadius, MapData.revealRadius + math.max(0, heightAboveGround) * MapData.revealPerHeight)
end

-- Uncovers everything within `radius`, and returns the cells that are new.
function MapData.revealAround(bits: { [string]: number }, x: number, z: number, radius: number): { number }
	local fresh: { number } = {}
	local reach = math.ceil(radius / CELL)
	local cx = math.floor((x + HALF) / CELL)
	local cz = math.floor((z + HALF) / CELL)
	for dz = -reach, reach do
		local rz = cz + dz
		if rz >= 0 and rz < COLS then
			for dx = -reach, reach do
				local rx = cx + dx
				if rx >= 0 and rx < COLS then
					local index = rz * COLS + rx
					local cellX, cellZ = MapData.cellCentre(index)
					if (cellX - x) ^ 2 + (cellZ - z) ^ 2 <= radius * radius and MapData.reveal(bits, index) then
						table.insert(fresh, index)
					end
				end
			end
		end
	end
	return fresh
end

-- The whole grid as this player may see it: everything they haven't uncovered is hidden.
function MapData.visibleGrid(grid: string, bits: { [string]: number }): string
	local parts = table.create(#grid)
	for i = 1, #grid do
		parts[i] = if MapData.isRevealed(bits, i - 1) then string.sub(grid, i, i) else UNKNOWN
	end
	return table.concat(parts)
end

-- The places this player knows of: in ground they've uncovered, and never a hidden site.
function MapData.knownPois(pois: { any }, bits: { [string]: number }): { KnownPoi }
	local out: { KnownPoi } = {}
	for _, poi in pois do
		if not poi.hidden and MapData.isRevealed(bits, MapData.cellIndex(poi.x, poi.z)) then
			table.insert(out, {
				id = poi.id,
				type = poi.type,
				x = math.floor(poi.x),
				z = math.floor(poi.z),
				name = if poi.settlement then poi.settlement.name else nil,
			})
		end
	end
	return out
end

-- ─── Looks ──────────────────────────────────────────────────────────────────

function MapData.poiStyle(poiType: string): PoiStyle
	if string.sub(poiType, 1, 7) == "shrine_" then
		local domain = string.sub(poiType, 8)
		return { glyph = "✦", label = "Shrine of " .. string.upper(string.sub(domain, 1, 1)) .. string.sub(domain, 2) }
	end
	return poiStyles[poiType] or { glyph = "◇", label = "Somewhere" }
end

return MapData
