--!strict
--[[
	AmbientLifeService: makes settlements look lived in and lets people react to you
	(docs/LivingWorld.md). Runs through two hooks NPCService calls:

		ambient hook   once a second for every T0 NPC: activity, bark, greeting
		place hook     where a leisure or work district really is: the real tavern, not a point in space

	DAILY LIFE    NPC/DailyLife + Data/Activities: only in the spawn town for now (flag
	              ambient_all_towns turns on the rest). Also stalls open and close, and lamps are lit by
	              the lamplighter on their round.
	BARKS         everywhere. NPC/BarkEngine + Data/Barks: a line every 45-90 s per NPC when someone is
	              close enough to hear, no repeats, never two people at once in one town.
	GREETINGS     everywhere. NPC/GreetingRules: from your reputation here, the NPC's factions, what the
	              NPC thinks of you, infamy, bounties, and whether magic is visibly in your hand.

	Server only and cosmetic: nothing here changes reputation, XP or anything saved.

	BUDGET (T0 is capped at 40 rigs by NPCLOD)
		activity     up to 40 cheap checks a second; a prop is 1-2 welded parts on T0 rigs only
		clips        lazily loaded per rig, 1 at a time, sharing NPCLOD's clip budget for one-shots
		barks        at most one per BARK_TOWN_GAP seconds per town
		greetings    a distance check per T0 NPC per second, at most one per player per GREET_GAP seconds
		stalls/lamps a scan of one town's tagged models every PROPS_EVERY seconds

	Admin: dailylife, bark [npc], greetstate [npc]
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Registry = require(Shared.Magic.Registry)
local Seed = require(Shared.Magic.Seed)

local Server = script.Parent.Parent
local NPC = Server.NPC
local Activities = require(NPC.Data.Activities)
local Barks = require(NPC.Data.Barks)
local BarkEngine = require(NPC.BarkEngine)
local DailyLife = require(NPC.DailyLife)
local DialogueEngine = require(NPC.DialogueEngine)
local GreetingRules = require(NPC.GreetingRules)
local LOD = require(NPC.NPCLOD)
local MemoryService = require(NPC.MemoryService)
local NPCMagicLife = require(NPC.NPCMagicLife)
local WorldClock = require(NPC.WorldClock)

local BARK_RADIUS = 28
local BARK_TOWN_GAP = 6 -- seconds between any two barks in one town
local BARK_NPC_MIN, BARK_NPC_SPREAD = 45, 45 -- a person's own gap
local LINE_COOLDOWN = 180 -- a line heard in a town won't come up there again for this long
local RECENT_PER_NPC = 8
local GREET_RADIUS = 14
local WHISPER_RADIUS = 26
local GREET_AGAIN = 300 -- this NPC won't greet this player again for this long
local GREET_GAP = 5 -- at most one greeting per player this often, or a crowd all talks at once
local AVOID_SECONDS = 7
local STALLS_OPEN, STALLS_CLOSE = 8, 18
local LAMPS_ON, LAMPS_OFF = 19, 6.5
local LAMPS_FORCED = 21 -- by now every lamp is lit, lamplighter or not
local PROPS_EVERY = 5
local TOWN_REACH = 1.3 -- of a town's radius, for tagged lamps and stalls

local AmbientLifeService = {
	name = "AmbientLifeService",
	dependencies = { "AdminService", "EffectRunner", "EventDirector", "FactionService", "NPCService", "ReputationService", "SettlementService", "WorldService", "WorldStateService" },
}

local log: any = nil
local npcs: any = nil
local reputation: any = nil
local factions: any = nil
local settlements: any = nil
local world: any = nil
local worldService: any = nil
local events: any = nil

local spawnTownId: string? = nil
local townBark: { [string]: number } = {} -- town -> when anyone last barked
local townLines: { [string]: { [number]: number } } = {} -- town -> line -> when it was last said
local playerGreeted: { [Player]: number } = {}
local visitedLamps: { [Instance]: boolean } = {}
local stories: { [string]: { { text: string, day: number } } } = {} -- town -> recent news (SceneDirector)
local counters = { barks = 0, greetings = 0, whispers = 0 }

local function ground(v: Vector3): Vector3
	return Vector3.new(v.X, world:surfaceHeight(v.X, v.Z), v.Z)
end

local function townEnabled(settlementId: string): boolean
	if FeatureFlags.get("ambient_life_enabled") ~= true then
		return false
	end
	return FeatureFlags.get("ambient_all_towns") == true or settlementId == spawnTownId
end

local function townRecord(settlementId: string): any?
	for _, town in npcs:towns() do
		if town.id == settlementId then
			return town
		end
	end
	return nil
end

-- ─── Stories (SceneDirector feeds these; barks read them) ───────────────────

function AmbientLifeService.addStory(_self: any, settlementId: string, text: string)
	local list = stories[settlementId]
	if not list then
		list = {}
		stories[settlementId] = list
	end
	table.insert(list, 1, { text = text, day = WorldClock.now() })
	while #list > 6 do
		table.remove(list)
	end
end

local function latestStory(settlementId: string, rng: Random): string?
	local list = stories[settlementId]
	if not list or #list == 0 then
		return nil
	end
	local now = WorldClock.now()
	local fresh: { string } = {}
	for _, story in list do
		if now - story.day <= 3 then
			table.insert(fresh, story.text)
		end
	end
	return if #fresh > 0 then fresh[rng:NextInteger(1, #fresh)] else nil
end

-- ─── Places ─────────────────────────────────────────────────────────────────

-- The real building for a district: a seeded spot at its work anchor or, in a tavern, a seat.
local function placeFor(npc: any, district: string): Vector3?
	if not townEnabled(npc.settlementId) then
		return nil
	end
	local kind = Activities.districtBuildings[district]
	if not kind then
		return nil
	end
	local lots: { string } = {}
	for _, lot in settlements:workplaces(npc.settlementId) do
		if lot.kind == kind then
			table.insert(lots, lot.lotId)
		end
	end
	if #lots == 0 then
		return nil
	end
	local lotId = lots[npc.seed % #lots + 1]
	if kind == "tavern" then
		-- A named seat if this tavern has that many. An unknown name gives the room's middle.
		local at = settlements:anchor(lotId, "NPCSeat" .. (npc.seed % 8 + 1))
		if at then
			return at
		end
	end
	local at = settlements:anchor(lotId, "NPCWork")
	if not at then
		return nil
	end
	local angle = (npc.seed % 628) / 100
	local reach = 1.5 + (npc.seed % 40) / 10
	return at + Vector3.new(math.cos(angle), 0, math.sin(angle)) * reach
end

local function lampsNear(town: any): { Model }
	local out: { Model } = {}
	local reach = town.radius * TOWN_REACH
	for _, lamp in CollectionService:GetTagged("LampPost") do
		if lamp:IsA("Model") then
			local p = lamp:GetPivot().Position
			if (p.X - town.x) ^ 2 + (p.Z - town.z) ^ 2 <= reach * reach then
				table.insert(out, lamp)
			end
		end
	end
	return out
end

local function patrolPoints(npc: any, kind: string): { Vector3 }
	local town = townRecord(npc.settlementId)
	if not town then
		return {}
	end
	if kind == "lamps" then
		local points: { Vector3 } = {}
		local lamps = lampsNear(town)
		-- A stable order, offset per lamplighter so two of them spread out.
		table.sort(lamps, function(a, b)
			return a:GetPivot().Position.X < b:GetPivot().Position.X
		end)
		for i = 1, #lamps do
			local lamp = lamps[(i + npc.seed) % #lamps + 1]
			table.insert(points, ground(lamp:GetPivot().Position + Vector3.new(2, 0, 2)))
		end
		return points
	end
	-- Guards: their post, then the plaza's corners, then back.
	local points: { Vector3 } = {}
	if npc.life and npc.life.center then
		table.insert(points, npc.life.center)
	end
	for i, p in town.spawnPoints or {} do
		if (i + npc.seed) % 2 == 0 then
			table.insert(points, ground(p))
		end
	end
	return points
end

local function onStop(npc: any, kind: string, _index: number)
	if kind ~= "lamps" then
		return
	end
	local town = townRecord(npc.settlementId)
	if not town then
		return
	end
	-- Whichever lamp is closest to where they stand.
	local nearest, best = nil :: Model?, 12
	for _, lamp in lampsNear(town) do
		local p = lamp:GetPivot().Position
		local d = Vector3.new(p.X - npc.position.X, 0, p.Z - npc.position.Z).Magnitude
		if d < best then
			nearest, best = lamp, d
		end
	end
	if nearest then
		visitedLamps[nearest] = true
	end
end

local function spark(npc: any)
	local branchId = NPCMagicLife.best(npc)
	local branch = branchId and Registry.branches[branchId]
	if not branch then
		return -- no magic of their own: no sparks
	end
	local root = npc.rig and npc.rig.root
	if root then
		npcs:cueCast(npc, { domain = branch.domains[1], property = "luminosity", verb = "generate", form = "touch", power = 1 }, root.Position + root.CFrame.LookVector * 2)
	end
end

local ENV = { ground = ground, patrolPoints = patrolPoints, onStop = onStop, spark = spark }

-- ─── Stalls and lamps ───────────────────────────────────────────────────────

local function setStall(stall: Model, open: boolean)
	if stall:GetAttribute("StallOpen") == open then
		return
	end
	stall:SetAttribute("StallOpen", open)
	for _, part in stall:GetDescendants() do
		if part:IsA("BasePart") and part.Name == "Goods" then
			part.Transparency = if open then 0 else 1
		end
	end
end

local function setLamp(lamp: Model, lit: boolean)
	if lamp:GetAttribute("LampLit") == lit then
		return
	end
	lamp:SetAttribute("LampLit", lit)
	local lantern = lamp:FindFirstChild("Lantern", true)
	if lantern and lantern:IsA("BasePart") then
		lantern.Material = if lit then Enum.Material.Neon else Enum.Material.SmoothPlastic
		lantern.Color = if lit then Color3.fromRGB(255, 214, 150) else Color3.fromRGB(95, 88, 72)
		local light = lantern:FindFirstChildOfClass("PointLight")
		if light then
			light.Enabled = lit
		end
	end
end

local function hasLamplighter(town: any): boolean
	for _, npc in town.npcs do
		if npc.occupation == "lamplighter" and not npc.knockedOut then
			return true
		end
	end
	return false
end

local function propsTick()
	local hour = WorldClock.hour()
	local night = hour >= LAMPS_ON or hour < LAMPS_OFF
	if not night then
		table.clear(visitedLamps)
	end
	for _, town in npcs:towns() do
		if townEnabled(town.id) then
			local open = hour >= STALLS_OPEN and hour < STALLS_CLOSE
			local reach = town.radius * TOWN_REACH
			for _, stall in CollectionService:GetTagged("MarketStall") do
				if stall:IsA("Model") then
					local p = stall:GetPivot().Position
					if (p.X - town.x) ^ 2 + (p.Z - town.z) ^ 2 <= reach * reach then
						setStall(stall, open)
					end
				end
			end
			local everyLamp = hour >= LAMPS_FORCED or hour < LAMPS_OFF or not hasLamplighter(town)
			for _, lamp in lampsNear(town) do
				setLamp(lamp, night and (everyLamp or visitedLamps[lamp] == true))
			end
		end
	end
end

-- ─── Context ────────────────────────────────────────────────────────────────

local function contextFor(npc: any, player: Player?, rng: Random, now: number): BarkEngine.Context
	local listener = if player then "u:" .. player.UserId else "none"
	local mood = DialogueEngine.mood(npc, now)
	local rel = DialogueEngine.band(npc, listener, now)
	local quirks: { [string]: boolean } = {}
	for _, q in npc.quirks do
		quirks[q] = true
	end
	local active: { [string]: boolean } = {}
	for _, event in events:activeAt(npc.position.X, npc.position.Z) do
		active[event.type] = true
	end
	local deeds: { [string]: boolean } = {}
	if player then
		for _, memory in MemoryService.top(npc, 3, now, listener) do
			deeds[memory.kind] = true
		end
	end
	local town = townRecord(npc.settlementId)
	local vars: { [string]: string } = { name = npc.name }
	if town then
		vars.town = town.settlement.name
	end
	if player then
		vars.player = player.DisplayName
	end
	vars.story = latestStory(npc.settlementId, rng)
	local placement = world:placement()
	local poi = placement and placement.byId[npc.settlementId]
	return {
		hour = WorldClock.hourOf(now),
		occupation = npc.occupation,
		action = npc.action,
		mood = mood,
		rel = rel,
		traits = npc.traits,
		quirks = quirks,
		events = active,
		biome = if poi then poi.biome else nil,
		culture = if town then town.settlement.culture else nil,
		child = npc.ageBand == "child",
		mage = NPCMagicLife.best(npc) ~= nil,
		deeds = deeds,
		vars = vars,
	}
end

local function rngFor(npc: any, purpose: string): Random
	npc.barks = (npc.barks or 0) + 1
	return Seed.random(worldService:getSeed(), "npc:" .. tostring(npc.id), purpose, npc.barks)
end

-- ─── Barks ──────────────────────────────────────────────────────────────────

local function townCooling(settlementId: string, clock: number): { [number]: boolean }
	local said = townLines[settlementId]
	local out: { [number]: boolean } = {}
	if said then
		for index, at in said do
			if clock - at < LINE_COOLDOWN then
				out[index] = true
			else
				said[index] = nil
			end
		end
	end
	return out
end

local function noteLine(npc: any, settlementId: string, index: number, clock: number)
	local said = townLines[settlementId]
	if not said then
		said = {}
		townLines[settlementId] = said
	end
	said[index] = clock
	local recent = npc.recentBarks
	if not recent then
		recent = { list = {}, set = {} }
		npc.recentBarks = recent
	end
	table.insert(recent.list, index)
	recent.set[index] = true
	while #recent.list > RECENT_PER_NPC do
		recent.set[table.remove(recent.list, 1) :: number] = nil
	end
end

local function bark(npc: any, now: number, clock: number)
	if clock < (npc.nextBark or 0) or clock - (townBark[npc.settlementId] or -math.huge) < BARK_TOWN_GAP then
		return
	end
	local hearers = npcs:hearers(npc.position, BARK_RADIUS)
	if #hearers == 0 then
		return
	end
	npc.nextBark = clock + BARK_NPC_MIN + npc.seed % BARK_NPC_SPREAD
	local rng = rngFor(npc, "bark")
	local ctx = contextFor(npc, hearers[1], rng, now)
	local recent = if npc.recentBarks then npc.recentBarks.set else {}
	local index, text = BarkEngine.pick("ambient", ctx, rng, recent, townCooling(npc.settlementId, clock))
	if index and text then
		townBark[npc.settlementId] = clock
		noteLine(npc, npc.settlementId, index, clock)
		counters.barks += 1
		npcs:speak(npc, text, BARK_RADIUS)
	end
end

-- ─── Greetings ──────────────────────────────────────────────────────────────

local function greetingInput(npc: any, player: Player, now: number): GreetingRules.Input
	local factionStanding = 0
	for _, factionId in factions:factionsOf(npc) do
		local standing = reputation:standing(player, factionId)
		if math.abs(standing) > math.abs(factionStanding) then
			factionStanding = standing
		end
	end
	local _, opinion = DialogueEngine.band(npc, "u:" .. player.UserId, now)
	local topNotoriety = 0
	for _, value in reputation:notorietyOf(player) do
		topNotoriety = math.max(topNotoriety, value)
	end
	local character = player.Character
	return {
		settlement = reputation:settlement(player, npc.settlementId),
		faction = factionStanding,
		opinion = opinion,
		infamy = reputation:infamyOf(player),
		bounty = reputation:bountiesOf(player)[npc.settlementId] ~= nil,
		notoriety = topNotoriety,
		attuned = character ~= nil and character:GetAttribute("AttunedDomain") ~= nil,
		agreeable = npc.traits.agreeableness or 0.5,
		nervous = npc.traits.neuroticism or 0.5,
		child = npc.ageBand == "child",
	}
end

local function faceTowards(npc: any, position: Vector3)
	local root = npc.rig and npc.rig.root
	if root and not root.Anchored then
		local flat = Vector3.new(position.X, root.Position.Y, position.Z)
		if (flat - root.Position).Magnitude > 0.5 then
			root.CFrame = CFrame.lookAt(root.Position, flat)
		end
	end
end

local function behave(npc: any, band: string, player: Player, clock: number)
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	if band == "avoid" then
		local away = Vector3.new(npc.position.X - root.Position.X, 0, npc.position.Z - root.Position.Z)
		local dir = if away.Magnitude > 0.1 then away.Unit else Vector3.xAxis
		LOD.setDestination(npc, ground(npc.position + dir * 16))
		npc.avoidUntil = clock + AVOID_SECONDS
		return
	end
	faceTowards(npc, root.Position)
	npc.talkingUntil = clock + 2.5
	if band == "fawn" then
		LOD.playActivity(npc, "cheer", Activities.Clips.cheer, false)
	elseif band == "warm" or band == "awe" then
		LOD.playActivity(npc, "wave", Activities.Clips.wave, false)
	end
end

local function greet(npc: any, now: number, clock: number)
	if npc.combat or npc.leash or npc.action == "sleep" or npc.action == "shelter" then
		return
	end
	for _, player in npcs:hearers(npc.position, WHISPER_RADIUS) do
		npc.greeted = npc.greeted or {}
		local key = player.UserId
		if clock - (npc.greeted[key] or -math.huge) >= GREET_AGAIN and clock - (playerGreeted[player] or -math.huge) >= GREET_GAP then
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				local close = (root.Position - npc.position).Magnitude <= GREET_RADIUS
				local band = GreetingRules.band(greetingInput(npc, player, now))
				local category = if close then "greet_" .. band else GreetingRules.whisper(band)
				if category then
					local rng = rngFor(npc, "greet")
					local index, text = BarkEngine.pick(category, contextFor(npc, player, rng, now), rng, {}, nil)
					if index and text then
						npc.greeted[key] = clock
						playerGreeted[player] = clock
						if close then
							counters.greetings += 1
							behave(npc, band, player, clock)
						else
							counters.whispers += 1
						end
						npcs:speak(npc, text, BARK_RADIUS)
						return
					end
				end
			end
		end
	end
end

-- ─── The hook ───────────────────────────────────────────────────────────────

local function ambient(npc: any, now: number, clock: number)
	if FeatureFlags.get("ambient_life_enabled") ~= true then
		return
	end
	if (npc.avoidUntil or 0) > 0 and clock >= npc.avoidUntil then
		npc.avoidUntil = 0
		npcs:reroute(npc)
	end
	if townEnabled(npc.settlementId) then
		DailyLife.step(npc, clock, ENV)
	end
	greet(npc, now, clock)
	if not npc.leash then -- a scene or quest has its own lines for them
		bark(npc, now, clock)
	end
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "dailylife",
		category = "World",
		description = "What daily life is doing: which towns, how many NPCs are doing what near you, barks and greetings so far",
		args = {},
		handler = function(_ctx: any, _a: any)
			local doing: { [string]: number } = {}
			for _, town in npcs:towns() do
				for _, npc in town.npcs do
					if npc.tier == 0 then
						local key = npc.occupation .. "." .. tostring(npc.action)
						doing[key] = (doing[key] or 0) + 1
					end
				end
			end
			local lines = {
				string.format("spawn town %s, all towns: %s, %s", tostring(spawnTownId), tostring(FeatureFlags.get("ambient_all_towns")), WorldClock.stamp()),
				string.format("barks %d, greetings %d, whispers %d, %d lines", counters.barks, counters.greetings, counters.whispers, #Barks),
			}
			local keys: { string } = {}
			for key in doing do
				table.insert(keys, key)
			end
			table.sort(keys)
			for _, key in keys do
				table.insert(lines, string.format("  %s: %d", key, doing[key]))
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "bark",
		category = "NPCs",
		description = "Make an NPC bark now (the nearest by default), ignoring cooldowns",
		args = { { name = "npc", type = "string", optional = true } },
		handler = function(ctx: any, a: any)
			local npc = npcs:find(a.npc, ctx.player)
			if not npc then
				return "no such NPC"
			end
			local rng = rngFor(npc, "bark")
			local index, text = BarkEngine.pick("ambient", contextFor(npc, ctx.player, rng, WorldClock.now()), rng, {}, nil)
			if not index or not text then
				return npc.name .. " has nothing to say right now"
			end
			npcs:speak(npc, text, BARK_RADIUS)
			return string.format("%s [%s]: %s", npc.name, Barks[index].cat, text)
		end,
	})
	admin:Register({
		name = "greetstate",
		category = "NPCs",
		description = "How an NPC feels about you (the nearest by default): every input, the score, the reaction. Resets its greeting cooldown",
		args = { { name = "npc", type = "string", optional = true } },
		handler = function(ctx: any, a: any)
			local npc = npcs:find(a.npc, ctx.player)
			if not npc then
				return "no such NPC"
			end
			local input = greetingInput(npc, ctx.player, WorldClock.now())
			if npc.greeted then
				npc.greeted[ctx.player.UserId] = nil
			end
			playerGreeted[ctx.player] = nil
			return string.format(
				"%s: %s (score %.2f)\n  town %.0f, faction %.0f, opinion %.2f, infamy %.0f, bounty %s, notoriety %.0f, attuned %s",
				npc.name, GreetingRules.band(input), GreetingRules.score(input),
				input.settlement, input.faction, input.opinion, input.infamy, tostring(input.bounty), input.notoriety, tostring(input.attuned)
			)
		end,
	})
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

function AmbientLifeService.init(_self: any, ctx: any)
	log = ctx.log
	npcs = ctx.get("NPCService")
	reputation = ctx.get("ReputationService")
	factions = ctx.get("FactionService")
	settlements = ctx.get("SettlementService")
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	events = ctx.get("EventDirector")
	registerAdmin(ctx.get("AdminService"))
	npcs:setAmbientHooks(ambient, placeFor)
	Players.PlayerRemoving:Connect(function(player)
		playerGreeted[player] = nil
	end)
end

function AmbientLifeService.start(_self: any, _ctx: any)
	task.spawn(function()
		world:awaitReady()
		-- The town the world spawn sits in: the first one to get daily life.
		while not spawnTownId do
			local at = world:spawnPoint()
			local settlement = at and world:settlementAt(at.X, at.Z)
			if settlement then
				spawnTownId = settlement.id
				log:info("daily_life_town", { settlement = settlement.id, name = settlement.name })
			else
				task.wait(1)
			end
		end
		while true do
			task.wait(PROPS_EVERY)
			propsTick()
		end
	end)
end

return AmbientLifeService
