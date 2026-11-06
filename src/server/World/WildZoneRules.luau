--!strict
--[[
	WildZoneRules: the decisions behind Wild Zones, with no Instances, so Tests/WildZones.spec can check
	them (docs/WildZones.md). Services/WildZoneService does the running.

		plan(worldSeed, cells, towns, pois) -> { Placed }   the same on every server
		zoneAt(placed, x, z) -> Placed?
		gravityAt(def, t, height) -> number?                nil: normal gravity
		nextTide(def, t) -> seconds?                        until the ground next lets go
		modifierOf(placed) -> a WorldStateService modifier  what it does to spells
		dayOf(now) / canHarvest(harvests, id, day) / rollHarvest(def, rng)
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)
local W = require(Shared.World.WildZones)

export type Cell = { x: number, z: number, biome: string, ocean: boolean, slope: number, coastDistance: number }
export type Spot = { x: number, z: number }
export type Placed = { id: string, def: W.Zone, x: number, z: number, biome: string }

local WildZoneRules = {}

-- ─── Placement ──────────────────────────────────────────────────────────────

local function clearOf(x: number, z: number, others: { Spot }, gap: number): boolean
	for _, other in others do
		if (other.x - x) ^ 2 + (other.z - z) ^ 2 < gap * gap then
			return false
		end
	end
	return true
end

--[[
	Each zone in turn takes the first free cell of a seeded shuffle: its preferred ground first, then any
	land, and last of all it stops caring about being near other places. Towns and other zones it never
	gives way on. A zone with nowhere to go is left out rather than put in a town.

	`cells`, `towns` and `pois` must be in a stable order and come from the generator, not built terrain.
]]
function WildZoneRules.plan(worldSeed: number, cells: { Cell }, towns: { Spot }, pois: { Spot }): { Placed }
	local placed: { Placed } = {}
	for _, id in W.ids do
		local def = W.zones[id]
		local rng = Seed.random(worldSeed, "wild_zone:" .. id, "place")
		local order = table.clone(cells)
		for i = #order, 2, -1 do
			local j = rng:NextInteger(1, i)
			order[i], order[j] = order[j], order[i]
		end

		local function usable(cell: Cell, wantBiome: boolean, wantClear: boolean): boolean
			if cell.ocean or cell.slope > W.maxSlope then
				return false
			end
			if def.coast and cell.coastDistance > 1 then
				return false
			end
			if wantBiome and #def.biomes > 0 and not table.find(def.biomes, cell.biome) then
				return false
			end
			if not clearOf(cell.x, cell.z, towns, def.radius + W.townClear) then
				return false
			end
			for _, other in placed do
				if not clearOf(cell.x, cell.z, { { x = other.x, z = other.z } }, def.radius + other.def.radius + W.zoneGap) then
					return false
				end
			end
			return not wantClear or clearOf(cell.x, cell.z, pois, def.radius + W.poiClear)
		end

		local chosen: Cell? = nil
		for _, wants in { { true, true }, { false, true }, { true, false }, { false, false } } do
			for _, cell in order do
				if usable(cell, wants[1], wants[2]) then
					chosen = cell
					break
				end
			end
			if chosen then
				break
			end
		end
		if chosen then
			table.insert(placed, { id = id, def = def, x = chosen.x, z = chosen.z, biome = chosen.biome })
		end
	end
	return placed
end

function WildZoneRules.zoneAt(placed: { Placed }, x: number, z: number): Placed?
	for _, zone in placed do
		if (zone.x - x) ^ 2 + (zone.z - z) ^ 2 <= zone.def.radius * zone.def.radius then
			return zone
		end
	end
	return nil
end

-- ─── Rules ──────────────────────────────────────────────────────────────────

--[[
	Multiples of normal gravity right now, or nil for normal. `height` is how far above the ground you
	are: a tide stops lifting you at its ceiling and leaves you weightless, so nobody is flung into the sky.
	`t` is the synced server clock, so the client can count down to the same moment.
]]
function WildZoneRules.gravityAt(def: W.Zone, t: number, height: number): number?
	local tide = def.tide
	if tide and t % tide.every < tide.lasts then
		return if height >= tide.ceiling then 0 else tide.mult
	end
	return def.gravity
end

-- Seconds until the ground next lets go, or 0 while it has. Nil if this zone has no tide.
function WildZoneRules.nextTide(def: W.Zone, t: number): number?
	local tide = def.tide
	if not tide then
		return nil
	end
	local phase = t % tide.every
	return if phase < tide.lasts then 0 else tide.every - phase
end

-- What the zone does to magic, as a modifier that never runs out. Every cast already reads these.
function WildZoneRules.modifierOf(zone: Placed): { [string]: any }
	local def = zone.def
	return {
		id = "wild_zone:" .. zone.id,
		x = zone.x,
		z = zone.z,
		radius = def.radius,
		density = def.density,
		temperature = def.temperature,
		moisture = def.moisture,
		stormCharge = def.stormCharge,
		fuel = def.fuel,
		bias = def.bias,
		expiresAt = math.huge,
	}
end

-- ─── The ground ─────────────────────────────────────────────────────────────

--[[
	The terrain ops that shape a zone: never saved, the same on every server, applied as each chunk builds.
	They only add to the ground or recolour it, so the generator's height is always safe to stand things
	on. Marked `c` so they run with the generated layer, before the saved edits, which must stay on top.
]]
function WildZoneRules.terrainOps(zone: Placed, worldSeed: number, heightAt: (number, number) -> number, seaLevel: number): { any }
	local def = zone.def
	local shape = def.terrain
	local ops: { any } = {}
	local count = 0
	local function add(op: { [string]: any })
		count += 1
		op.i = string.format("wz:%s:%d", zone.id, count)
		op.c = true
		op.t = 0
		table.insert(ops, op)
	end
	local rng = Seed.random(worldSeed, "wild_zone:" .. zone.id, "terrain")

	-- A seeded spot in the zone, far enough from the heart for this radius.
	local function spot(radius: number): (number?, number?, number?)
		for _ = 1, 8 do
			local angle = rng:NextNumber() * 2 * math.pi
			local distance = def.radius * (0.15 + rng:NextNumber() * 0.8)
			if distance >= radius + W.heartClear then
				local x, z = zone.x + math.cos(angle) * distance, zone.z + math.sin(angle) * distance
				return x, heightAt(x, z), z
			end
		end
		return nil, nil, nil
	end

	local paint = shape.paint
	if paint then
		local cell = W.paintCell
		local reach = math.ceil(def.radius / cell)
		local x0, z0 = math.floor(zone.x / cell) * cell, math.floor(zone.z / cell) * cell
		for dz = -reach, reach do
			for dx = -reach, reach do
				local cx, cz = x0 + (dx + 0.5) * cell, z0 + (dz + 0.5) * cell
				if (cx - zone.x) ^ 2 + (cz - zone.z) ^ 2 <= def.radius * def.radius then
					local h = heightAt(cx, cz)
					if h >= seaLevel then
						for _, from in W.paintFrom do
							if from ~= paint then
								add({ k = "replace", m = paint, f = from, x = cx, y = math.floor(h / 4) * 4, z = cz, sx = cell, sy = W.paintDepth, sz = cell })
							end
						end
					end
				end
			end
		end
	end

	local mounds = shape.mounds
	if mounds then
		for _ = 1, mounds.count do
			local radius = mounds.min + rng:NextNumber() * (mounds.max - mounds.min)
			local x, h, z = spot(radius)
			if x and h and z and h >= seaLevel then
				local r = radius
				local y = h - radius * 0.3
				for _ = 1, mounds.stack do
					add({ k = "ball", m = mounds.material, x = x, y = y, z = z, r = r })
					y += r * 0.9
					r *= 0.75
				end
			end
		end
	end

	local function island(x: number, y: number, z: number, radius: number)
		add({ k = "ball", m = "Grass", x = x, y = y, z = z, r = radius })
		add({ k = "ball", m = "Rock", x = x, y = y - radius * 0.45, z = z, r = radius * 0.92 })
	end
	local islands = shape.islands
	if islands then
		for _ = 1, islands.count do
			local radius = islands.min + rng:NextNumber() * (islands.max - islands.min)
			local x, h, z = spot(radius)
			if x and h and z then
				local ground = math.max(h, seaLevel)
				island(x, ground + islands.lowest + radius + rng:NextNumber() * (islands.highest - islands.lowest), z, radius)
			end
		end
	end
	if shape.heartIsland then
		-- Its top just under the heart, so there's something to stand on when you get there.
		local ground = math.max(heightAt(zone.x, zone.z), seaLevel)
		island(zone.x, ground + (def.heartLift or 0) - 8, zone.z, 10)
	end
	return ops
end

-- Which chunks an op must run in: a ball can reach several, and each rewrites what its neighbour's build
-- cleared, so the result is the same whichever chunk builds first.
function WildZoneRules.chunksOf(op: { [string]: any }, chunkOf: (number, number) -> (number, number)): { string }
	local out: { string } = {}
	local reach = if op.k == "ball" then op.r else 0
	local x0, z0 = chunkOf(op.x - reach, op.z - reach)
	local x1, z1 = chunkOf(op.x + reach, op.z + reach)
	for cz = z0, z1 do
		for cx = x0, x1 do
			table.insert(out, cx .. "," .. cz)
		end
	end
	return out
end

-- ─── Rumours ────────────────────────────────────────────────────────────────

local BEARINGS = { "east", "north-east", "north", "north-west", "west", "south-west", "south", "south-east" }

function WildZoneRules.bearing(fromX: number, fromZ: number, toX: number, toZ: number): string
	-- North is -Z, as in POIPlacer.
	local angle = math.atan2(-(toZ - fromZ), toX - fromX)
	local index = math.floor(((angle + math.pi * 2) % (math.pi * 2)) / (math.pi / 4) + 0.5) % 8
	return BEARINGS[index + 1]
end

--[[
	The zone this person could tell you about: the nearest you've neither found nor heard of. `roll` is
	a seeded number for this person and this player, so asking again doesn't change the answer: someone
	either knows, or doesn't, and you find out by asking someone else.
]]
function WildZoneRules.rumorFor(placed: { Placed }, known: { [string]: any }, heard: { [string]: any }, x: number, z: number, roll: number): Placed?
	if roll >= W.rumorChance then
		return nil
	end
	local best: Placed? = nil
	local bestDistance = math.huge
	for _, zone in placed do
		if not known[zone.id] and not heard[zone.id] then
			local d = (zone.x - x) ^ 2 + (zone.z - z) ^ 2
			if d < bestDistance then
				best, bestDistance = zone, d
			end
		end
	end
	return best
end

-- ─── The heart ──────────────────────────────────────────────────────────────

function WildZoneRules.dayOf(now: number): number
	return math.floor(now / W.harvestSeconds)
end

function WildZoneRules.canHarvest(harvests: { [string]: number }, id: string, day: number): boolean
	return harvests[id] ~= day
end

function WildZoneRules.rollHarvest(def: W.Zone, rng: Random): { { item: string, n: number } }
	local out: { { item: string, n: number } } = {}
	for _, entry in def.harvest do
		if rng:NextNumber() < entry.chance then
			table.insert(out, { item = entry.item, n = rng:NextInteger(entry.min, entry.max) })
		end
	end
	return out
end

return WildZoneRules
