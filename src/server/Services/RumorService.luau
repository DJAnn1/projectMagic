--!strict
--[[
	RumorService: townspeople talk to each other about real things nearby, and you overhear them
	(docs/Rumors.md, idea #39 "Overheard rumours"). No interface: two people in a chat bubble.

	OVERHEARD  Every Tuning.tick seconds, for each player in a town: if two free townspeople stand
	           within pairRadius of each other and hearRadius of the player, the more outgoing one
	           may tell the other about something real (RumorRules.choose: nearer is likelier), with
	           the direction from where they stand, and the other answers. They face each other while
	           they talk. Everyone within hearRadius has overheard it.
	ASKED      Asking anyone in that town for rumours (the NPC "rumor" topic) within askKeep gets
	           the fuller story for places and dens, a Journal line (…) and that patch of the map.
	           Wild zones, Wildborn lairs and ferals are only talked about here: their own services
	           already tell their stories when asked (WildZoneService, WildbornService, FeralService).

	FACTS      visible POIs (never towns or hidden mythic sites), creature dens, wild zones, lairs
	           whose boss is alive on this server, loose ferals. Gathered fresh for each talk (a few
	           hundred entries at most; POIs are cached).

	LIMITS     one talk per town per townGap, one per player per playerGap, each thing overheard once
	           per player per session. Lines are our own data (no player text).

	Flag rumors_enabled. Admin: rumors [clear], rumornow. Log: rumor_overheard, rumor_told.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Seed = require(Shared.Magic.Seed)
local OmenRules = require(Shared.Magic.OmenRules)

local Server = ServerScriptService.Server
local RumorRules = require(Server.Rumors.RumorRules)
local Lines = require(Server.Rumors.Data.RumorLines)

local T = RumorRules.Tuning

local RumorService = {
	name = "RumorService",
	dependencies = {
		"AdminService",
		"AmbientLifeService",
		"CreatureService",
		"FeralService",
		"JournalService",
		"MapService",
		"NPCService",
		"WildbornService",
		"WildZoneService",
		"WorldService",
		"WorldStateService",
	},
}

type Heard = { at: number, town: string, fact: RumorRules.Fact, asked: boolean }

local log: any = nil
local npcs: any = nil
local ambient: any = nil
local world: any = nil
local worldService: any = nil
local map: any = nil
local journal: any = nil
local creatures: any = nil
local ferals: any = nil
local wildborn: any = nil
local wildZones: any = nil

local poiFacts: { RumorRules.Fact }? = nil
local heardBy: { [Player]: { [string]: Heard } } = {}
local playerLast: { [Player]: number } = {}
local townLast: { [string]: number } = {}
local counter = 0
local counts = { overheard = 0, told = 0 }

local function enabled(): boolean
	return FeatureFlags.get("rumors_enabled") == true and FeatureFlags.get("ambient_life_enabled") == true
end

local function rngFor(salt: string): Random
	counter += 1
	return Seed.random(worldService:getSeed(), "rumors", salt, counter)
end

local function rootOf(player: Player): Vector3?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

local function free(npc: any): boolean
	return npc.rig ~= nil
		and not npc.knockedOut
		and not npc.combat
		and not npc.talk
		and not npc.leash
		and npc.action ~= "sleep"
		and npc.action ~= "shelter"
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- ─── Facts ──────────────────────────────────────────────────────────────────

local function placesOnce(): { RumorRules.Fact }
	if poiFacts then
		return poiFacts
	end
	local placement = world:placement()
	if not placement then
		return {}
	end
	local out: { RumorRules.Fact } = {}
	for _, poi in placement.pois do
		local kind = if poi.hidden then nil else RumorRules.poiKind(poi.type)
		if kind then
			local place = if kind == "shrine" then RumorRules.shrinePlace(string.sub(poi.type, 8)) else nil
			table.insert(out, { id = "poi:" .. poi.id, kind = kind, group = "place", x = poi.x, z = poi.z, place = place, tellable = true })
		end
	end
	poiFacts = out
	return out
end

local function gather(): { RumorRules.Fact }
	local out = table.clone(placesOnce())
	local function each(source: any, method: string, make: (any) -> RumorRules.Fact?)
		local ok, list = pcall(source[method], source)
		if ok and typeof(list) == "table" then
			for _, entry in list do
				local fact = make(entry)
				if fact then
					table.insert(out, fact)
				end
			end
		end
	end
	each(creatures, "dens", function(den)
		return { id = "den:" .. den.id, kind = "den_" .. den.type, group = "den", x = den.x, z = den.z, tellable = true }
	end)
	each(wildZones, "places", function(zone)
		return { id = "zone:" .. zone.id, kind = "zone", group = "danger", x = zone.x, z = zone.z, place = zone.name, tellable = false }
	end)
	each(wildborn, "lairs", function(lair)
		if lair.beaten then
			return nil
		end
		return { id = "lair:" .. lair.id, kind = "lair", group = "danger", x = lair.x, z = lair.z, tellable = false }
	end)
	each(ferals, "loose", function(feral)
		return { id = "feral:" .. feral.id, kind = "feral", group = "danger", x = feral.x, z = feral.z, tellable = false }
	end)
	return out
end

local function heardOf(player: Player): { [string]: Heard }
	local heard = heardBy[player]
	if not heard then
		heard = {}
		heardBy[player] = heard
	end
	return heard
end

-- ─── Overheard ──────────────────────────────────────────────────────────────

local function townOf(at: Vector3): any?
	for _, town in npcs:towns() do
		local reach = town.radius * 1.3
		if (town.x - at.X) ^ 2 + (town.z - at.Z) ^ 2 <= reach * reach then
			return town
		end
	end
	return nil
end

-- Two free people close together, near `at`: the nearest such pair, or nil.
local function pairNear(town: any, at: Vector3): (any?, any?)
	local near: { any } = {}
	for _, npc in town.npcs do
		if free(npc) and flat(npc.position, at) <= T.hearRadius then
			table.insert(near, npc)
		end
	end
	table.sort(near, function(a, b)
		return flat(a.position, at) < flat(b.position, at)
	end)
	for i = 1, #near do
		for j = i + 1, #near do
			if flat(near[i].position, near[j].position) <= T.pairRadius then
				return near[i], near[j]
			end
		end
	end
	return nil, nil
end

-- Plays one conversation between `a` and `b` in `town` about something `listener` hasn't heard.
-- Returns why not, or nil when it started.
local function converse(listener: Player, town: any, a: any, b: any, clock: number): string?
	local heard = heardOf(listener)
	local fact = RumorRules.choose(gather(), town.x, town.z, heard, rngFor(tostring(listener.UserId) .. town.id):NextNumber())
	if not fact then
		return "nothing near this town they haven't told you already"
	end
	-- The more outgoing of the two brings it up.
	if (b.traits.extraversion or 0.5) > (a.traits.extraversion or 0.5) then
		a, b = b, a
	end
	local say, reply = RumorRules.categories(fact)
	local vars = { dir = OmenRules.bearing(a.position.X, a.position.Z, fact.x, fact.z), place = fact.place or "" }
	local opener = ambient:lineFor(a, nil, say, Lines, vars)
	local answer = ambient:lineFor(b, nil, reply, Lines, vars)
	if not opener or not answer then
		return "no line fits " .. fact.kind
	end
	townLast[town.id] = clock
	-- Everyone close enough has overheard it.
	local mid = (a.position + b.position) / 2
	for _, player in Players:GetPlayers() do
		local at = rootOf(player)
		if at and flat(at, mid) <= T.hearRadius + T.pairRadius then
			heardOf(player)[fact.id] = { at = clock, town = town.id, fact = fact, asked = false }
			playerLast[player] = clock
		end
	end
	ambient:face(a, b.position, T.facing)
	ambient:face(b, a.position, T.facing)
	npcs:speak(a, opener, T.speakRadius)
	local rng = rngFor("reply")
	task.delay(T.replyDelay[1] + rng:NextNumber() * (T.replyDelay[2] - T.replyDelay[1]), function()
		if free(b) then
			npcs:speak(b, answer, T.speakRadius)
		end
	end)
	counts.overheard += 1
	log:info("rumor_overheard", { town = town.id, fact = fact.id, kind = fact.kind, a = a.id, b = b.id, text = opener })
	return nil
end

local function tick()
	if not enabled() then
		return
	end
	local clock = os.clock()
	for _, player in Players:GetPlayers() do
		local at = rootOf(player)
		if at and clock - (playerLast[player] or -math.huge) >= T.playerGap then
			local town = townOf(at)
			if town and clock - (townLast[town.id] or -math.huge) >= T.townGap then
				local a, b = pairNear(town, at)
				if a and b then
					converse(player, town, a, b, clock)
				end
			end
		end
	end
end

-- ─── Asked ──────────────────────────────────────────────────────────────────

-- The NPC "rumor" topic: the story behind something you overheard in this town.
local function rumorHook(player: Player, npc: any): string?
	if not enabled() or typeof(npc) ~= "table" or typeof(npc.position) ~= "Vector3" then
		return nil
	end
	local heard = heardBy[player]
	if not heard then
		return nil
	end
	local clock = os.clock()
	local best: Heard? = nil
	for _, entry in heard do
		if not entry.asked and entry.fact.tellable and entry.town == npc.settlementId and clock - entry.at <= T.askKeep then
			if not best or entry.at > best.at then
				best = entry
			end
		end
	end
	if not best then
		return nil
	end
	local fact = best.fact
	local _, _, told = RumorRules.categories(fact)
	local text = ambient:lineFor(npc, player, told, Lines, {
		dir = OmenRules.bearing(npc.position.X, npc.position.Z, fact.x, fact.z),
		place = fact.place or "",
	})
	if not text then
		return nil
	end
	best.asked = true
	counts.told += 1
	journal:log(player, "rumor", "I asked about something I'd overheard. " .. text, { quiet = true })
	map:revealArea(player, fact.x, fact.z, T.reveal)
	log:info("rumor_told", { userId = player.UserId, npc = npc.id, fact = fact.id })
	return text
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "rumors",
		category = "NPCs",
		description = "What townspeople near you could talk about (nearest first: kind, direction, distance, whether you've overheard or asked about it), or clear what you've overheard and every wait",
		args = { { name = "clear", type = "string", default = "" } },
		handler = function(ctx: any, a: any)
			if a.clear == "clear" then
				heardBy[ctx.player] = nil
				playerLast[ctx.player] = nil
				table.clear(townLast)
				return "cleared: you can overhear everything again, and the next talk can start now"
			end
			local at = rootOf(ctx.player)
			local town = at and townOf(at)
			if not at or not town then
				return "stand in a town first"
			end
			local heard = heardBy[ctx.player] or {}
			local facts = gather()
			table.sort(facts, function(x, y)
				return (x.x - town.x) ^ 2 + (x.z - town.z) ^ 2 < (y.x - town.x) ^ 2 + (y.z - town.z) ^ 2
			end)
			local lines = { string.format("%s · on=%s · overheard %d · told %d", tostring(town.settlement.name), tostring(enabled()), counts.overheard, counts.told) }
			for _, fact in facts do
				local d = math.sqrt((fact.x - town.x) ^ 2 + (fact.z - town.z) ^ 2)
				if d <= T.reach and #lines <= 20 then
					local h = heard[fact.id]
					table.insert(
						lines,
						string.format(
							"%s %s, %s %d studs%s%s",
							fact.kind,
							fact.place or "",
							OmenRules.bearing(town.x, town.z, fact.x, fact.z),
							math.floor(d),
							if d < T.minReach then " (too close to be a rumour)" else "",
							if h then (if h.asked then " · asked" else " · overheard") else ""
						)
					)
				end
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "rumornow",
		category = "NPCs",
		description = "Have the nearest two people standing together (within 30 studs, ignoring how far apart) talk about a rumour right now, ignoring every wait",
		args = {},
		handler = function(ctx: any, _a: any)
			local at = rootOf(ctx.player)
			local town = at and townOf(at)
			if not at or not town then
				return "stand in a town first"
			end
			local near: { any } = {}
			for _, npc in town.npcs do
				if free(npc) and flat(npc.position, at) <= 30 then
					table.insert(near, npc)
				end
			end
			table.sort(near, function(x, y)
				return flat(x.position, at) < flat(y.position, at)
			end)
			if #near < 2 then
				return "need two free people within 30 studs"
			end
			local why = converse(ctx.player, town, near[1], near[2], os.clock())
			return why or string.format("%s and %s are talking", tostring(near[1].name), tostring(near[2].name))
		end,
	})
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

function RumorService.init(_self: any, ctx: any)
	log = ctx.log
	npcs = ctx.get("NPCService")
	ambient = ctx.get("AmbientLifeService")
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	map = ctx.get("MapService")
	journal = ctx.get("JournalService")
	creatures = ctx.get("CreatureService")
	ferals = ctx.get("FeralService")
	wildborn = ctx.get("WildbornService")
	wildZones = ctx.get("WildZoneService")
	registerAdmin(ctx.get("AdminService"))
	-- First: something you just overheard is what you'd ask about.
	npcs:setRumorHook(rumorHook, true)
	Players.PlayerRemoving:Connect(function(player)
		heardBy[player] = nil
		playerLast[player] = nil
	end)
end

function RumorService.start(_self: any, _ctx: any)
	task.spawn(function()
		world:awaitReady()
		while true do
			task.wait(T.tick)
			local ok, err = pcall(tick)
			if not ok then
				log:warn("rumor_tick_failed", { error = tostring(err) })
			end
		end
	end)
end

return RumorService
