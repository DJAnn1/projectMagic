--!strict
--[[
	EventDirector: emergent world events.

	Every TICK seconds: with probability START_CHANCE (if under the caps), pick an active player's
	location, weigh every regional EventDef there by biome and magic pressure (what people have
	been casting nearby, from WorldStateService), and start one. Global events (eclipse, starfall)
	roll separately and rarely.

	A running event:
	- applies its modifiers through WorldStateService (density, moisture, fuel, storm charge...)
	- announces a quest hook naming the nearest settlement
	- can be ended early by relief: matching magic cast inside it (noteCast, called by CastService)
	- ends on its timer, removing its modifiers

	Events are per-server (live world state); the chronicle records the global ones.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local World = game:GetService("ServerScriptService").Server.World
local EventDefs = require(World.EventDefs)

export type ActiveEvent = {
	id: string,
	type: string,
	x: number,
	z: number,
	radius: number,
	endsAt: number,
	relief: number,
	hook: string,
}

local TICK = 60
local START_CHANCE = 0.2
local MAX_REGIONAL = 4
local MAX_GLOBAL = 1

local EventDirector = {
	name = "EventDirector",
	dependencies = { "NetService", "WorldStateService", "WorldService", "AdminService" },
}

local log: any = nil
local bus: any = nil
local flags: any = nil
local world: any = nil
local chronicle: any = nil
local active: { [string]: ActiveEvent } = {}
local counter = 0
local rng = Random.new()

local function nearestSettlementName(x: number, z: number): string
	local best, bestD = "the wilds", math.huge
	for _, s in world:placement().settlements do
		local d = (s.x - x) ^ 2 + (s.z - z) ^ 2
		if d < bestD then
			best, bestD = s.name, d
		end
	end
	return best
end

local function countActive(): ({ [string]: number }, number, number)
	local byType: { [string]: number } = {}
	local regional, global = 0, 0
	for _, e in active do
		byType[e.type] = (byType[e.type] or 0) + 1
		if EventDefs[e.type].scope == "global" then
			global += 1
		else
			regional += 1
		end
	end
	return byType, regional, global
end

-- Where an event of this def happens, near (x, z). Nil if there's no valid place.
local function locate(def: EventDefs.EventDef, x: number, z: number): (number?, number?)
	if def.at == "player" then
		return x + rng:NextNumber(-200, 200), z + rng:NextNumber(-200, 200)
	elseif def.at == "nexus" then
		local best, bestD = nil :: any, math.huge
		for _, nexus in world:nexuses() do
			local d = (nexus.x - x) ^ 2 + (nexus.z - z) ^ 2
			if d < bestD then
				best, bestD = nexus, d
			end
		end
		if best and bestD < 1500 ^ 2 then
			return best.x, best.z
		end
	elseif def.at == "settlement" then
		local best, bestD = nil :: any, math.huge
		for _, s in world:placement().settlements do
			local d = (s.x - x) ^ 2 + (s.z - z) ^ 2
			if d < bestD then
				best, bestD = s, d
			end
		end
		if best and bestD < 1200 ^ 2 then
			return best.x, best.z
		end
	elseif string.sub(def.at, 1, 4) == "poi:" then
		local poiType = string.sub(def.at, 5)
		for _, poi in world:placement().pois do
			if poi.type == poiType then
				return poi.x, poi.z
			end
		end
	end
	return nil, nil
end

-- `radiusOverride` (admin "global" events) replaces the def's radius.
function EventDirector.startEvent(_self: any, typeName: string, x: number, z: number, radiusOverride: number?): ActiveEvent?
	local def = EventDefs[typeName]
	if not def then
		return nil
	end
	counter += 1
	local now = os.time()
	local id = string.format("%s_%d", typeName, counter)
	local event: ActiveEvent = {
		id = id,
		type = typeName,
		x = x,
		z = z,
		radius = radiusOverride or def.radius,
		endsAt = now + rng:NextInteger(def.duration[1], def.duration[2]),
		relief = 0,
		hook = (string.gsub(def.hook, "{place}", nearestSettlementName(x, z))),
	}
	active[id] = event
	local m = def.modifiers
	world:addModifier({
		id = id,
		x = x,
		z = z,
		radius = event.radius,
		expiresAt = event.endsAt,
		density = m.density,
		temperature = m.temperature,
		moisture = m.moisture,
		stormCharge = m.stormCharge,
		fuel = m.fuel,
	})
	if def.stress then
		world:addStress(x, z, def.stress)
	end
	log:info("event_started", { id = id, x = math.floor(x), z = math.floor(z) })
	bus:publish(Topics.WorldEventStarted, { id = id, type = typeName, x = x, z = z, radius = event.radius })
	Net.fireAll("WorldEffect", { kind = "event", event = typeName, name = def.name, x = x, z = z, radius = event.radius, hook = event.hook })
	if def.scope == "global" then
		task.spawn(chronicle.recordEvent, chronicle, "world_event", { type = typeName })
	end
	return event
end

function EventDirector.stopEvent(_self: any, id: string, reason: string)
	local event = active[id]
	if not event then
		return
	end
	active[id] = nil
	world:removeModifier(id)
	log:info("event_ended", { id = id, reason = reason })
	bus:publish(Topics.WorldEventEnded, { id = id, type = event.type })
	Net.fireAll("WorldEffect", { kind = "event_end", event = event.type, id = id, reason = reason })
end

-- Events active at a point (POIService and CastService use this).
function EventDirector.activeAt(_self: any, x: number, z: number): { ActiveEvent }
	local out = {}
	for _, e in active do
		if (e.x - x) ^ 2 + (e.z - z) ^ 2 <= e.radius * e.radius then
			table.insert(out, e)
		end
	end
	return out
end

function EventDirector.isActive(_self: any, typeName: string): boolean
	for _, e in active do
		if e.type == typeName then
			return true
		end
	end
	return false
end

-- Magic cast inside an event can relieve it (water ends droughts, life ends plagues...).
function EventDirector.noteCast(self: any, position: Vector3, domains: { string }, power: number)
	for _, e in self:activeAt(position.X, position.Z) do
		local relief = EventDefs[e.type].relief
		if relief and table.find(domains, relief.domain) then
			e.relief += power
			if e.relief >= relief.amount then
				self:stopEvent(e.id, "relieved")
			end
		end
	end
end

local function tick()
	local now = os.time()
	for id, e in active do
		if now >= e.endsAt then
			EventDirector:stopEvent(id, "expired")
		end
	end
	local byType, regional, global = countActive()

	-- Global events roll independently, and rarely.
	if global < MAX_GLOBAL then
		for typeName, def in EventDefs do
			if def.scope == "global" and rng:NextNumber() < def.weight({}) then
				local x, z = locate(def, 0, 0)
				if x and z then
					EventDirector:startEvent(typeName, x, z)
					break
				end
			end
		end
	end

	local players = Players:GetPlayers()
	if regional >= MAX_REGIONAL or #players == 0 or rng:NextNumber() > START_CHANCE then
		return
	end
	local player = players[rng:NextInteger(1, #players)]
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not root then
		return
	end
	local p = root.Position
	local s = world:gen():sample(p.X, p.Z)
	local ctx = { biome = s.biome, pressure = world:pressureAt(p.X, p.Z), active = byType, density = world:densityAt(p.X, p.Z) }

	local candidates, total = {}, 0
	for typeName, def in EventDefs do
		if def.scope == "region" and (byType[typeName] or 0) == 0 then
			local w = math.max(0, def.weight(ctx))
			if w > 0 then
				table.insert(candidates, { typeName = typeName, weight = w })
				total += w
			end
		end
	end
	if total <= 0 then
		return
	end
	table.sort(candidates, function(a, b)
		return a.typeName < b.typeName
	end)
	local roll = rng:NextNumber() * total
	for _, c in candidates do
		roll -= c.weight
		if roll <= 0 then
			local x, z = locate(EventDefs[c.typeName], p.X, p.Z)
			if x and z then
				EventDirector:startEvent(c.typeName, x, z)
			end
			return
		end
	end
end

function EventDirector.init(_self: any, ctx: any)
	log, bus, flags = ctx.log, ctx.bus, ctx.flags
	world = ctx.get("WorldStateService")
	chronicle = ctx.get("WorldService")
	-- RegionInfo carries the event a player stands in (the client's music: "event").
	world:setEventLookup(function(x: number, z: number): string?
		local here = EventDirector:activeAt(x, z)
		return if here[1] then here[1].type else nil
	end)
	local admin = ctx.get("AdminService")

	local eventTypes = {}
	for typeName in EventDefs do
		table.insert(eventTypes, typeName)
	end
	table.sort(eventTypes)

	admin:Register({
		name = "events", category = "World", description = "Active world events",
		handler = function()
			local lines = {}
			local now = os.time()
			for _, e in active do
				table.insert(lines, string.format("%s at (%.0f, %.0f) r%.0f, %ds left, relief %.0f | %s", e.id, e.x, e.z, e.radius, e.endsAt - now, e.relief, e.hook))
			end
			return if #lines > 0 then table.concat(lines, "\n") else "(no active events)"
		end,
	})

	admin:Register({
		name = "startevent", aliases = { "event" }, category = "World",
		description = "Start a world event near you, at a point, or across the whole island (global)",
		args = {
			{ name = "type", type = "enum", options = eventTypes },
			{ name = "where", type = "enum", options = { "here", "global", "point" }, default = "here" },
			{ name = "at", type = "vector3", optional = true, hint = "for where=point: @cursor or x,y,z" },
		},
		handler = function(ctx, a)
			local def = EventDefs[a.type]
			local root = ctx.player.Character and ctx.player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local event: ActiveEvent? = nil
			if a.where == "global" then
				event = EventDirector:startEvent(a.type, 0, 0, 4000)
			elseif a.where == "point" then
				if not a.at then
					return "where=point needs an 'at' position"
				end
				event = EventDirector:startEvent(a.type, a.at.X, a.at.Z)
			else
				if not root then
					return "no character"
				end
				local x, z = locate(def, root.Position.X, root.Position.Z)
				event = EventDirector:startEvent(a.type, x or root.Position.X, z or root.Position.Z)
			end
			return if event then "started " .. event.id .. ": " .. event.hook else "failed"
		end,
	})

	admin:RegisterType("activeevent", {
		parse = function(raw)
			if raw == "all" or active[raw] then
				return raw, nil
			end
			local ids = { "all" }
			for id in active do
				table.insert(ids, id)
			end
			return admin.matchOption(raw, ids)
		end,
		options = function()
			local ids = { "all" }
			for id in active do
				table.insert(ids, id)
			end
			table.sort(ids)
			return ids
		end,
	})

	admin:Register({
		name = "stopevent", category = "World", description = "End an active event (or all of them)",
		args = { { name = "id", type = "activeevent" } },
		handler = function(_, a)
			if a.id == "all" then
				local n = 0
				for id in active do
					EventDirector:stopEvent(id, "admin")
					n += 1
				end
				return "stopped " .. n
			end
			EventDirector:stopEvent(a.id, "admin")
			return "stopped " .. a.id
		end,
	})
end

function EventDirector.start(_self: any, _ctx: any)
	world:awaitReady()
	while true do
		task.wait(TICK)
		if flags.get("world_events_enabled") then
			tick()
		end
	end
end

return EventDirector
