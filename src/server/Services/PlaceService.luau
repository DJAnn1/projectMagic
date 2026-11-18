--!strict
--[[
	PlaceService: the places in the wilds and what's happened to them (docs/WorldPlaces.md). Stage 0:
	every place gets its seeded history, and this server keeps what state each is in. Later stages
	build bodies (wayside spots, sites, deep places), stream interiors and fill them from here.

		PlaceService:all() -> { Place }                 every place, in placement order
		PlaceService:get(poiId) -> Place?
		PlaceService:history(poiId) -> History?
		PlaceService:nearest(position, within?) -> (Place?, distance)
		PlaceService:rumorable(poi) -> boolean          may townspeople send someone there?
		PlaceService:setState(poiId, state, why?)       untouched | entered | cleared | resettled

	HISTORIES  PlaceHistory.of, from the world seed + POI + its nearest town and magic density. The
	           same on every server. Built once, when the world is ready (~45 places, a few ms).
	STATE      per server (the owner's rule for fallen towns), in memory: a new server starts every
	           place untouched. Nothing is saved yet; the first player-facing stage adds the
	           personal record (data.places, through WorldService:progressKey) and eraseUser.
	RUMOURS    a place that has no body yet AND grants nothing (today: the ten deep places) is held
	           back from rumours, so nobody is sent to an empty hillside. A place that grants
	           something (a library's treatise, a mine's ore) is real enough to talk about.

	SECRETS    histories never go to clients. Players learn them in pieces, through people, letters
	           and what they see.

	Flag places_enabled (off: rumours behave as before; histories are still built for the admin).
	Admin (World): places [near|deep|site|all], placegoto <poi>, placehistory [poi].
	Log: places_ready, place_state.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local OmenRules = require(Shared.Magic.OmenRules)

local Server = ServerScriptService.Server
local PlaceHistory = require(Server.Places.PlaceHistory)
local PlaceKinds = require(Server.Places.Data.PlaceKinds)
local Util = require(Server.Admin.Util)

export type Place = {
	poi: any, -- POIPlacer.POI
	history: PlaceHistory.History,
	state: string, -- untouched | entered | cleared | resettled
	since: number, -- os.time() of the last state change
}

local STATES = { untouched = true, entered = true, cleared = true, resettled = true }

local PlaceService = {
	name = "PlaceService",
	dependencies = { "AdminService", "WorldService", "WorldStateService" },
}

local log: any = nil
local world: any = nil
local worldService: any = nil

local places: { Place } = {}
local byId: { [string]: Place } = {}
local ready = false

local function flat(x1: number, z1: number, x2: number, z2: number): number
	return math.sqrt((x1 - x2) ^ 2 + (z1 - z2) ^ 2)
end

-- The nearest town to a point (every place is told about from somewhere).
local function nearestTown(placement: any, x: number, z: number): { id: string, name: string, culture: string, distance: number }
	local best, bestD = nil, math.huge
	for _, s in placement.settlements do
		local d = flat(s.x, s.z, x, z)
		if d < bestD then
			best, bestD = s, d
		end
	end
	if not best then
		return { id = "none", name = "the coast", culture = "wayfarer", distance = math.huge }
	end
	return { id = best.id, name = best.name, culture = best.culture, distance = bestD }
end

local function build()
	local placement = world:placement()
	local seed = worldService:getSeed()
	local started = os.clock()
	local deep, site = 0, 0
	for _, poi in placement.pois do
		local context: PlaceHistory.Context = {
			town = nearestTown(placement, poi.x, poi.z),
			density = world:densityAt(poi.x, poi.z),
		}
		local history = PlaceHistory.of(seed, poi, context)
		if history then
			local place: Place = { poi = poi, history = history, state = "untouched", since = os.time() }
			table.insert(places, place)
			byId[poi.id] = place
			if history.size == "deep" then
				deep += 1
			else
				site += 1
			end
		end
	end
	ready = true
	log:info("places_ready", { deep = deep, sites = site, ms = math.floor((os.clock() - started) * 1000) })
end

-- ─── API ────────────────────────────────────────────────────────────────────

function PlaceService.all(_self: any): { Place }
	return places
end

function PlaceService.get(_self: any, poiId: string): Place?
	return byId[poiId]
end

function PlaceService.history(_self: any, poiId: string): PlaceHistory.History?
	local place = byId[poiId]
	return if place then place.history else nil
end

function PlaceService.isReady(_self: any): boolean
	return ready
end

function PlaceService.nearest(_self: any, position: Vector3, within: number?): (Place?, number)
	local best, bestD = nil, within or math.huge
	for _, place in places do
		local d = flat(place.poi.x, place.poi.z, position.X, position.Z)
		if d <= bestD then
			best, bestD = place, d
		end
	end
	return best, bestD
end

-- May townspeople point someone at this POI? Only things that exist: a place with a body, or one
-- that grants something when you stand there. Non-places (wonders, vents) are left to their callers.
function PlaceService.rumorable(_self: any, poi: any): boolean
	if FeatureFlags.get("places_enabled") ~= true then
		return true
	end
	local site = PlaceKinds.siteFor(poi.type)
	if not site or site.built then
		return true
	end
	local grants = poi.grants or {}
	return next(grants) ~= nil
end

function PlaceService.setState(_self: any, poiId: string, state: string, why: string?)
	local place = byId[poiId]
	assert(place, "PlaceService.setState: unknown place " .. tostring(poiId))
	assert(STATES[state], "PlaceService.setState: unknown state " .. tostring(state))
	if place.state == state then
		return
	end
	log:info("place_state", { place = poiId, from = place.state, to = state, why = why or "" })
	place.state = state
	place.since = os.time()
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function summary(place: Place, from: Vector3?): string
	local h = place.history
	local where = ""
	if from then
		where = string.format(" · %s %d studs", OmenRules.bearing(from.X, from.Z, place.poi.x, place.poi.z), math.floor(flat(from.X, from.Z, place.poi.x, place.poi.z)))
	end
	local size = if h.size == "deep" then string.format(" · %d depths, %d rooms", h.depths or 0, h.rooms or 0) else ""
	return string.format("%s [%s] %s (%s) · %s · %s · danger %.2f%s · %s%s",
		place.poi.id, h.size, h.name, h.kind, h.fate, h.occupant, h.danger, size, place.state, where)
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "places",
		category = "World",
		description = "Places in the wilds and their seeded histories: the 20 nearest (near), or every deep place, site or place (name, kind, fate, who's there, danger, state, which way)",
		args = { { name = "which", type = "enum", options = { "near", "deep", "site", "all" }, default = "near" } },
		handler = function(ctx: any, a: any)
			if not ready then
				return "places aren't built yet (the world is still generating)"
			end
			local root = Util.rootOf(ctx.player)
			local from = if root then root.Position else nil
			local list: { Place } = {}
			for _, place in places do
				if a.which == "near" or a.which == "all" or place.history.size == a.which then
					table.insert(list, place)
				end
			end
			if from then
				table.sort(list, function(x, y)
					return flat(x.poi.x, x.poi.z, from.X, from.Z) < flat(y.poi.x, y.poi.z, from.X, from.Z)
				end)
			end
			local limit = if a.which == "near" then 20 else #list
			local deep = 0
			for _, place in places do
				if place.history.size == "deep" then
					deep += 1
				end
			end
			local lines = { string.format("%d places (%d deep, %d sites) · on=%s", #places, deep, #places - deep, tostring(FeatureFlags.get("places_enabled"))) }
			for i = 1, math.min(limit, #list) do
				table.insert(lines, summary(list[i], from))
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "placegoto",
		category = "World",
		description = "Teleport to a place in the wilds (just outside it, on dry ground)",
		args = { { name = "poi", type = "poi" } },
		handler = function(ctx: any, a: any)
			local place = byId[a.poi.id]
			if not place then
				return a.poi.id .. " isn't a place (towns, wonders and mythic sites have no history); try tppoi"
			end
			local ok, msg = Util.teleport(ctx.player, world, Vector3.new(place.poi.x + place.poi.radius + 12, 0, place.poi.z), true)
			return if ok then string.format("%s: %s", place.history.name, msg) else msg
		end,
	})
	admin:Register({
		name = "placehistory",
		category = "World",
		description = "The whole seeded history of a place (the nearest if none given): who made it, what happened, who's there, what they left, what shows outside, and the lines people tell",
		args = { { name = "poi", type = "poi", optional = true } },
		handler = function(ctx: any, a: any)
			if not ready then
				return "places aren't built yet"
			end
			local place: Place? = nil
			if a.poi then
				place = byId[a.poi.id]
				if not place then
					return a.poi.id .. " isn't a place"
				end
			else
				local root = Util.rootOf(ctx.player)
				if not root then
					return "no character"
				end
				place = PlaceService.nearest(PlaceService, root.Position)
			end
			if not place then
				return "no places"
			end
			local h = place.history
			local lines = {
				summary(place, nil),
				string.format("label: %s · builder %s · %d years ago (%s) · told from %s (%s)", h.label, h.builder, h.yearsAgo, h.age, h.town, h.culture),
				"left behind: " .. table.concat(h.leaves, ", ") .. (if h.writes then " · writes letters" else ""),
				"seen outside: " .. (if #h.signs > 0 then table.concat(h.signs, ", ") else "nothing"),
				string.format("rumours: %s · at (%.0f, %.0f) in %s", if PlaceService.rumorable(PlaceService, place.poi) then "yes" else "held back (no body yet)", place.poi.x, place.poi.z, place.poi.biome),
			}
			for _, line in h.lines do
				table.insert(lines, "  “" .. line .. "”")
			end
			return table.concat(lines, "\n")
		end,
	})
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

function PlaceService.init(_self: any, ctx: any)
	log = ctx.log
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	registerAdmin(ctx.get("AdminService"))
end

function PlaceService.start(_self: any, _ctx: any)
	task.spawn(function()
		world:awaitReady()
		local ok, err = pcall(build)
		if not ok then
			log:warn("places_failed", { error = tostring(err) })
		end
	end)
end

return PlaceService
