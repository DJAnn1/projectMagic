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
