--!strict
--[[
	POIPlacer: deterministic placement of points of interest from POIRules.

	1. Every WorldIndex cell is a candidate (128-stud grid, jittered inside the cell).
	2. Each rule (in order) filters and scores the candidates, then greedily accepts the best
	   that respect its spacing and global clearance, up to `count`.
	3. Settlements get culture, name, size (best 2 = cities, next 4 = towns, rest villages).
	4. Roads: minimum spanning tree over settlements + a few short extra links.
	5. Lore hints: each mythic site gets hints scattered across libraries, shrines and towers.
	   A hint gives a vague bearing and distance to the site; collecting hints is the ONLY way
	   to make a mythic site discoverable (see POIService).
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)
local Rules = require(script.Parent.POIRules)
local Settlements = require(script.Parent.Settlements)
local WorldIndex = require(script.Parent.WorldIndex)
local MagicMap = require(script.Parent.MagicMap)
local SettlementSites = require(script.Parent.SettlementSites)
local SettlementStyles = require(script.Parent.SettlementStyles)
local TerrainBuilder = require(script.Parent.TerrainBuilder)

export type POI = {
	id: string,
	type: string,
	x: number,
	z: number,
	biome: string,
	radius: number,
	hidden: boolean,
	grants: { catalyst: string?, insight: string?, awakening: string?, mythic: string?, lore: string? },
	settlement: Settlements.Settlement?,
	hints: { string }, -- lore-hint ids available at this POI
}

export type Placement = {
	pois: { POI },
	byId: { [string]: POI },
	settlements: { Settlements.Settlement },
	roads: { TerrainBuilder.Road },
	hintText: { [string]: string }, -- hint id -> text
}

local POIPlacer = {}

local HINTS_PER_MYTHIC = 4
local BEARINGS = { "east", "north-east", "north", "north-west", "west", "south-west", "south", "south-east" }

local function bearing(fromX: number, fromZ: number, toX: number, toZ: number): string
	-- North is -Z.
	local angle = math.atan2(-(toZ - fromZ), toX - fromX)
	local index = math.floor(((angle + math.pi * 2) % (math.pi * 2)) / (math.pi / 4) + 0.5) % 8
	return BEARINGS[index + 1]
end

local function distanceBand(d: number): string
	if d < 600 then
		return "a short walk"
	elseif d < 1400 then
		return "half a day's travel"
	end
	return "far, past many roads"
end

function POIPlacer.place(index: WorldIndex.WorldIndex, magic: MagicMap.MagicMap, worldSeed: number, yieldFn: (() -> ())?): Placement
	local placed: { POI } = {}
	local byId: { [string]: POI } = {}

	-- Candidates (resonance attached so shrine rules can score it).
	local candidates = {}
	for _, cell in index.cells do
		local c = table.clone(cell) :: any
		c.resonance = magic:resonanceAt(cell.x, cell.z, cell.sample)
		table.insert(candidates, c)
	end
	if yieldFn then
		yieldFn()
	end

	local function tooClose(x: number, z: number, typeName: string, spacing: number, clearance: number): boolean
		for _, poi in placed do
			local d2 = (poi.x - x) ^ 2 + (poi.z - z) ^ 2
			if d2 < clearance * clearance then
				return true
			end
			if poi.type == typeName and d2 < spacing * spacing then
				return true
			end
		end
		return false
	end

	local culturesUsed: { [string]: number } = {}
	for _, rule in Rules do
		local rng = Seed.random(worldSeed, rule.type, "poi")
		local scored = {}
		for _, c in candidates do
			if rule.biomes and not table.find(rule.biomes, c.sample.biome) then
				continue
			end
			if rule.filter and not rule.filter(c) then
				continue
			end
			table.insert(scored, { cell = c, score = rule.score(c) })
		end
		table.sort(scored, function(a, b)
			if a.score ~= b.score then
				return a.score > b.score
			end
			return (a.cell.rz * 1000 + a.cell.rx) < (b.cell.rz * 1000 + b.cell.rx)
		end)
		local count = 0
		for _, entry in scored do
			if count >= rule.count then
				break
			end
			local c = entry.cell
			local x = c.x + (rng:NextNumber() - 0.5) * 80
			local z = c.z + (rng:NextNumber() - 0.5) * 80
			local siteOk = true
			if rule.type == "settlement" then
				-- Step 1, fine pass: the flattest dry open ground near the coarse pick (SettlementSites).
				-- No dry ground near this cell at all: skip it, the next candidate takes its place.
				local site = SettlementSites.refine((magic :: any).gen, index, x, z, SettlementSites.OPEN_RADIUS, yieldFn)
				if site then
					x, z = site.x, site.z
				else
					siteOk = false
				end
			end
			if siteOk and not tooClose(x, z, rule.type, rule.spacing, rule.clearance) then
				count += 1
				local poi: POI = {
					id = string.format("%s_%d", rule.type, count),
					type = rule.type,
					x = x,
					z = z,
					biome = c.sample.biome,
					radius = rule.radius,
					hidden = rule.hidden == true,
					grants = rule.grants or {},
					settlement = nil,
					hints = {},
				}
				if rule.type == "settlement" then
					local srng = Seed.random(worldSeed, poi.id, "settlement")
					poi.settlement = {
						id = poi.id,
						name = Settlements.makeName(srng),
						culture = Settlements.chooseCulture(srng, c.sample.biome, c.coastDistance <= 1, culturesUsed),
						size = "village",
						x = x,
						z = z,
						population = 0,
						relations = {},
					}
					local chosen = (poi.settlement :: any).culture
					culturesUsed[chosen] = (culturesUsed[chosen] or 0) + 1
				end
				table.insert(placed, poi)
				byId[poi.id] = poi
			end
		end
		if yieldFn then
			yieldFn()
		end
	end

	-- Settlement sizes and relations (placement order = suitability order).
	local settlements = {}
	for _, poi in placed do
		local s = poi.settlement
		if s then
			local rank = #settlements + 1
			s.size = if rank <= 2 then "city" elseif rank <= 6 then "town" else "village"
			s.population = if s.size == "city" then 40 elseif s.size == "town" then 18 else 8 -- simulated NPCs
			poi.radius = SettlementStyles.tiers[s.size].radius -- the layout's open radius (laws, NPC districts)
			table.insert(settlements, s)
		end
	end
	Settlements.computeRelations(settlements, worldSeed)

	-- Roads: MST over settlements (Prim), plus links shorter than 900 studs.
	local roads: { TerrainBuilder.Road } = {}
	if #settlements >= 2 then
		local inTree = { [1] = true }
		local function road(a: Settlements.Settlement, b: Settlements.Settlement)
			table.insert(roads, { ax = a.x, az = a.z, bx = b.x, bz = b.z, width = if a.size == "city" or b.size == "city" then 10 else 6 })
		end
		for _ = 2, #settlements do
			local bi, bj, best = 0, 0, math.huge
			for i in inTree do
				for j = 1, #settlements do
					if not inTree[j] then
						local d = (settlements[i].x - settlements[j].x) ^ 2 + (settlements[i].z - settlements[j].z) ^ 2
						if d < best then
							bi, bj, best = i, j, d
						end
					end
				end
			end
			inTree[bj] = true
			road(settlements[bi], settlements[bj])
		end
		for i = 1, #settlements do
			for j = i + 1, #settlements do
				local d = math.sqrt((settlements[i].x - settlements[j].x) ^ 2 + (settlements[i].z - settlements[j].z) ^ 2)
				if d < 900 and Seed.derive(worldSeed, settlements[i].id .. settlements[j].id, "road") % 3 == 0 then
					road(settlements[i], settlements[j])
				end
			end
		end
	end

	-- Lore hints toward mythic sites.
	local hintText: { [string]: string } = {}
	local hosts = {}
	for _, poi in placed do
		if poi.type == "ruined_library" or poi.type == "hermit_tower" or string.sub(poi.type, 1, 7) == "shrine_" then
			table.insert(hosts, poi)
		end
	end
	for _, poi in placed do
		local mythic = poi.grants.mythic
		if mythic and #hosts > 0 then
			local rng = Seed.random(worldSeed, poi.id, "hints")
			for h = 1, HINTS_PER_MYTHIC do
				local host = hosts[rng:NextInteger(1, #hosts)]
				local hintId = string.format("hint:%s:%d", mythic, h)
				local d = math.sqrt((poi.x - host.x) ^ 2 + (poi.z - host.z) ^ 2)
				hintText[hintId] = string.format(
					"An inscription speaks of a place where %s gathers: %s from here, %s, in lands of %s.",
					mythic, bearing(host.x, host.z, poi.x, poi.z), distanceBand(d), poi.biome
				)
				table.insert(host.hints, hintId)
			end
		end
	end

	return { pois = placed, byId = byId, settlements = settlements, roads = roads, hintText = hintText }
end

-- Roads touching a chunk's bounds (for TerrainBuilder road paint).
function POIPlacer.roadsInChunk(roads: { TerrainBuilder.Road }, originX: number, originZ: number, size: number): { TerrainBuilder.Road }
	local out = {}
	for _, r in roads do
		local minX, maxX = math.min(r.ax, r.bx) - r.width, math.max(r.ax, r.bx) + r.width
		local minZ, maxZ = math.min(r.az, r.bz) - r.width, math.max(r.az, r.bz) + r.width
		if maxX >= originX and minX <= originX + size and maxZ >= originZ and minZ <= originZ + size then
			table.insert(out, r)
		end
	end
	return out
end

return POIPlacer
