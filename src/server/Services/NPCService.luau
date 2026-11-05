--!strict
--[[
	NPCService: the orchestrator for settlement NPCs. Everything an NPC IS lives in Server/NPC
	(pure modules); this service owns the live state, the loops, the remotes and persistence.

	BOOT (a Scheduler job, after the world is generated)
	    town records are read first (DataStore calls never happen inside a job), then per settlement:
	    authored NPCs go on the last slots of a matching settlement -> NPCFactory.populate ->
	    enrich (signature, schedule shift, needs, drain, magic baseline) -> RelationshipGraph.seed ->
	    saved facts applied (mythic awakenings, memories of players) -> NPCMagicLife.advance to the
	    current chapter -> compile the brain -> decide -> stand at that action's spot.

	LOOPS
	    Heartbeat   every 0.5 s  LOD.assign + LOD.sync for the NPCs whose tier changed, day/night
	                10 Hz        LOD.stepT0 (walking rigs)          every 2 s  LOD.stepT1 (hopping)
	                every frame  brain ticks for T0 (1 s) and T1 (5 s) NPCs, within BRAIN_BUDGET
	    game hour   T2 brains (ParallelPool when >= PARALLEL_MIN), social pairing + gossip,
	                event relief, knockout recovery, chapter advance
	    120 s       dirty town records saved (Store.update with a merge, so servers never clobber)

	REACTIONS (SignalBus)
	    MagicWitnessed     saw_magic / saw_harmful_magic / saw_mythic_magic memories; harmful magic
	                       close by frightens; same-domain mythic magic wakes a hidden mythic gift
	    MagicDamage        attacked_me + witnesses, reputation loss, a knockout discards the rig
	    WorldEventStarted  danger in overlapping towns (shelter / help); eclipse and starfall wake
	                       hidden Time / Gravity gifts in anyone awake to see them
	    PlayerDataLoaded   the player's saved relationships become graph edges
	    WorldEventRecorded an awakening on another server is applied here too

	SECRETS: inspector snapshots go to admins only; nothing here ever sends the world seed,
	hidden latents (to players) or ProfileTuning to a client.
]]

local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ServerStorage = game:GetService("ServerStorage")
local TextService = game:GetService("TextService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local Registry = require(Shared.Magic.Registry)

local Server = script.Parent.Parent
local Scheduler = require(Server.Core.Scheduler)
local ParallelPool = require(Server.Core.ParallelPool)
local Schemas = require(Server.Persistence.Schemas)
local Progression = require(Server.Progression.Progression)
local ProgressionTuning = require(Server.Progression.ProgressionTuning)
local InnateProfile = require(Server.Magic.InnateProfile)
local Settlements = require(Server.World.Settlements)
local WorldConfig = require(Server.World.WorldConfig)

local NPC = Server.NPC
local NpcData = require(NPC.Data.NpcData)
local NeedsActions = require(NPC.Data.NeedsActions)
local Quirks = require(NPC.Data.Quirks)
local WorldClock = require(NPC.WorldClock)
local NPCFactory = require(NPC.NPCFactory)
local NPCBrain = require(NPC.NPCBrain)
local UtilityScore = require(NPC.UtilityScore)
local ScheduleService = require(NPC.ScheduleService)
local MemoryService = require(NPC.MemoryService)
local RelationshipGraph = require(NPC.RelationshipGraph)
local NPCMagicLife = require(NPC.NPCMagicLife)
local DialogueEngine = require(NPC.DialogueEngine)
local LOD = require(NPC.NPCLOD)
local NPCCombat = require(NPC.NPCCombat)
local Combat = require(Server.Magic.Data.CombatTuning)
local Resistances = require(Server.Magic.Cast.Resistances)

local LOD_INTERVAL = 0.5
local T0_STEP = 0.1
local T1_STEP = 2
local T0_BRAIN = 1
local T1_BRAIN = 5
local BRAIN_BUDGET = 0.001 -- seconds of brain work per frame (T0 + T1)
local PARALLEL_MIN = 64
local PARALLEL_BATCH = 50
local SAVE_INTERVAL = 120
local SAVED_MEMORIES = 8 -- per NPC, memories of players only
local SAVED_RELATIONS = 80 -- per player save
local TALK_DISTANCE = 14
local BARK_RADIUS = 28
local WITNESS_CAP = 24
local MYTHIC_WITNESS_RANGE = 50
local MYTHIC_WITNESS_POWER = 4
local RENDER_BUDGET = 2
local RENDER_CACHE_CAP = 256
local SEA = WorldConfig.SEA_LEVEL
local TOPICS = { "greet", "self", "magic", "rumor", "work", "learn", "farewell" }
-- When the QuestDirector says this NPC has something for you (an offer, or a step of your quest).
local withQuestTopic = { "quest", "greet", "self", "magic", "rumor", "work", "learn", "farewell" }

-- A world event's sky sight wakes the matching hidden gift.
local SKY_AWAKENINGS: { [string]: string } = { eclipse = "time", starfall = "gravity" }

type Town = {
	id: string,
	settlement: Settlements.Settlement,
	x: number,
	z: number,
	radius: number,
	place: ScheduleService.Place,
	npcs: { any },
	dangers: { [string]: string }, -- world event id -> type
	dirty: boolean,
	saved: any?, -- the record read at boot
	spawnPoints: { Vector3 }?, -- the plaza's NPCSpawn points (SettlementService)
}

local NPCService = {
	name = "NPCService",
	dependencies = {
		"NetService",
		"DataService",
		"WorldService",
		"WorldStateService",
		"SettlementService",
		"PlayerDataService",
		"ProgressionService",
		"EventDirector",
		"EffectRunner",
	},
}

local log: any = nil
local bus: any = nil
local flags: any = nil
local worldService: any = nil
local world: any = nil
local playerData: any = nil
local progression: any = nil
local events: any = nil
local runner: any = nil
local talkHook: ((Player, any, string) -> (string?, boolean))? = nil -- QuestDirector (setTalkHook)
local store: any = nil
local dataService: any = nil
local settlementSvc: any = nil

local worldSeed = 0
local epoch = 0
local ready = false
local towns: { Town } = {}
local townById: { [string]: Town } = {}
local byId: { [string]: any } = {}
local all: { any } = {}
local near: { any } = {} -- T0 + T1, rebuilt every LOD pass
local tier0: { any } = {}
local tier1: { any } = {}
local brainCursor = 1
local lastChapter = -1
local pool: ParallelPool.ParallelPool? = nil
local playerRoots: { { player: Player, position: Vector3 } } = {}
local talkTurns: { [Player]: { [string]: number } } = {}
local renderCache: { [string]: string } = {}
local renderCacheSize = 0
local stats = { brainMs = 0, brainTicks = 0, t2Ms = 0, t2Count = 0, parallel = false, bootMs = 0 }

local function enabled(): boolean
	return ready and flags.get("npc_enabled") == true
end

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function groundAt(v: Vector3): Vector3
	return Vector3.new(v.X, world:surfaceHeight(v.X, v.Z), v.Z)
end

local function round(n: number, places: number): number
	local m = 10 ^ places
	return math.floor(n * m + 0.5) / m
end

local function subjectOf(userId: number): string
	return "u:" .. userId
end

local function nameOf(id: string): string
	if string.sub(id, 1, 2) == "u:" then
		local player = Players:GetPlayerByUserId(tonumber(string.sub(id, 3)) or 0)
		return if player then player.DisplayName else "a traveller"
	end
	local npc = byId[id]
	return if npc then npc.name else "someone"
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function playersNear(position: Vector3, radius: number): { Player }
	local out = {}
	for _, entry in playerRoots do
		if (entry.position - position).Magnitude <= radius then
			table.insert(out, entry.player)
		end
	end
	return out
end

local function townAt(position: Vector3, margin: number): { Town }
	local out = {}
	for _, town in towns do
		local reach = town.radius * 1.7 + margin -- wilds and farms sit outside the POI radius
		if (town.x - position.X) ^ 2 + (town.z - position.Z) ^ 2 <= reach * reach then
			table.insert(out, town)
		end
	end
	return out
end

-- Finds an NPC by id, by (part of) a name, or the one nearest a player.
local function findNpc(query: string?, viewer: Player?): any?
	if query and byId[query] then
		return byId[query]
	end
	if query and query ~= "" then
		local q = string.lower(query)
		for _, npc in all do
			if string.find(string.lower(npc.name), q, 1, true) then
				return npc
			end
		end
		return nil
	end
	local root = viewer and rootOf(viewer)
	if not root then
		return nil
	end
	local best, bestD = nil, math.huge
	for _, npc in all do
		local d = (npc.position - root.Position).Magnitude
		if d < bestD then
			best, bestD = npc, d
		end
	end
	return best
end

-- ─── Places ─────────────────────────────────────────────────────────────────

-- A person's own spot in a district, on dry ground (cached: spots never move).
local function spotFor(npc: any, district: string): Vector3
	local cached = npc.spots[district]
	if cached then
		return cached
	end
	local town = townById[npc.settlementId]
	local x, z = ScheduleService.spot(town.place, district, npc.seed, npc.household)
	if world:surfaceHeight(x, z) < SEA + 2 then
		local dx, _, dz = world:findDryLand(x, z, 96)
		x, z = dx, dz
	end
	local spot = Vector3.new(x, world:surfaceHeight(x, z), z)
	npc.spots[district] = spot
	return spot
end

-- Sends an NPC toward where its current action happens. T2 NPCs are simply there.
-- ─── Homes and workplaces (SettlementService lots) ──────────────────────────

-- Which building kind each profession works in. Others keep their outdoor district spots.
local WORKS_AT: { [string]: string } = {
	smith = "smithy", innkeeper = "tavern", merchant = "market_stall", herbalist = "market_stall",
	guard = "watchtower", farmer = "barn", scholar = "magic_school",
	tidepriest = "shrine", healer = "shrine", weathercaller = "shrine",
}

--[[
	Deterministic, from layout data (works before any building exists):
	  homes      households, largest first, each take the smallest free house with enough beds
	             (else the roomiest left; a town with too few houses leaves the last households in
	             their old district homes). The eldest member owns it (OwnerNPCId); members sleep
	             in its beds in age order, sharing when there are more people than beds.
	  workplaces each profession with a building kind (WORKS_AT) is spread round-robin over that
	             town's lots of the kind; `index` fans co-workers out around the anchor.
]]
local function assignBuildings(town: Town)
	local homes = settlementSvc:homes(town.id)
	local households: { [string]: { any } } = {}
	local orderKeys: { string } = {}
	for _, npc in town.npcs do
		if not households[npc.household] then
			households[npc.household] = {}
			table.insert(orderKeys, npc.household)
		end
		table.insert(households[npc.household], npc)
	end
	table.sort(orderKeys, function(a, b)
		local na, nb = #households[a], #households[b]
		if na ~= nb then
			return na > nb
		end
		return a < b
	end)
	local free = table.clone(homes)
	for _, key in orderKeys do
		local members = households[key]
		if #free == 0 then
			break
		end
		local pick, pickIndex = nil, 0
		for i, home in free do
			if home.beds >= #members and (not pick or home.beds < pick.beds) then
				pick, pickIndex = home, i
			end
		end
		if not pick then
			for i, home in free do
				if not pick or home.beds > pick.beds then
					pick, pickIndex = home, i
				end
			end
		end
		local home = pick :: any
		table.remove(free, pickIndex)
		table.sort(members, function(a, b)
			if a.age ~= b.age then
				return a.age > b.age
			end
			return a.slot < b.slot
		end)
		for i, member in members do
			member.home = { lot = home.lotId, slot = (i - 1) % home.beds + 1 }
		end
		settlementSvc:setOwner(home.lotId, members[1].id)
	end

	local byKind: { [string]: { string } } = {}
	for _, place in settlementSvc:workplaces(town.id) do
		byKind[place.kind] = byKind[place.kind] or {}
		table.insert(byKind[place.kind], place.lotId)
	end
	local counts: { [string]: number } = {}
	for _, npc in town.npcs do
		local kind = WORKS_AT[npc.occupation]
		local lots = kind and byKind[kind]
		if kind and lots and #lots > 0 then
			local n = counts[kind] or 0
			counts[kind] = n + 1
			npc.work = { lot = lots[n % #lots + 1], index = n // #lots }
		end
	end
end

-- Where an NPC sleeps: its bed's NPCHome anchor, else its old district home spot.
local function homePosition(npc: any): Vector3
	local home = npc.home
	local at = home and settlementSvc:anchor(home.lot, "NPCHome", home.slot)
	return at or spotFor(npc, "home")
end

-- Where an NPC works: its workplace's NPCWork anchor (co-workers spread around it), or nil.
local function workPosition(npc: any): Vector3?
	local work = npc.work
	local at = work and settlementSvc:anchor(work.lot, "NPCWork")
	if not at then
		return nil
	end
	if work.index > 0 then
		local a = work.index * 2.1
		at += Vector3.new(math.cos(a), 0, math.sin(a)) * 1.8
	end
	return at
end

-- Data-only (T2) NPCs reach their destination on the next hourly pass (thinkFar), so a town
-- seen from afar fills up over the first game hour instead of all at once.
local function route(npc: any)
	local def = NeedsActions.actions[npc.action]
	if not def or def.district == "here" then
		return
	end
	local rogue = npc.magic.rogue
	local district = if rogue then "wilds" else ScheduleService.districtFor(npc, npc.action, def.district)
	local target: Vector3? = nil
	if not rogue and district == "home" and npc.home then
		target = homePosition(npc)
	elseif not rogue and def.district == "work" then
		target = workPosition(npc)
	end
	LOD.setDestination(npc, target or spotFor(npc, district))
end

local function inDanger(npc: any): boolean
	local town = townById[npc.settlementId]
	return town ~= nil and next(town.dangers) ~= nil
end

local function threatened(npc: any, now: number): boolean
	return inDanger(npc) or (npc.threatUntil or -1) > now
end

-- ─── Dialogue ───────────────────────────────────────────────────────────────

local function eventHookAt(position: Vector3): string?
	local active = events:activeAt(position.X, position.Z)
	return if active[1] then active[1].hook else nil
end

local function reputationOf(player: Player?, npc: any): number?
	local state = player and playerData:get(player)
	if not state then
		return nil
	end
	local standing = state.data.reputation[npc.settlementId] or 0
	return math.clamp(standing / 50, -0.6, 0.4)
end

local function contextFor(npc: any, listener: string, player: Player?, teach: any?): DialogueEngine.Context
	local now = WorldClock.now()
	return DialogueEngine.context(npc, listener, {
		now = now,
		hour = WorldClock.hourOf(now),
		nameOf = nameOf,
		eventHook = eventHookAt(npc.position),
		reputation = reputationOf(player, npc),
		teach = teach,
	})
end

-- One spoken line over an NPC's head, to the players close enough to hear it.
local function say(npc: any, topic: string, listener: string?, player: Player?)
	local hearers = playersNear(npc.position, BARK_RADIUS)
	if #hearers == 0 then
		return
	end
	local who = listener or subjectOf(hearers[1].UserId)
	local ctx = contextFor(npc, who, player or hearers[1], nil)
	npc.barks = (npc.barks or 0) + 1
	local text = DialogueEngine.line(npc, topic, ctx, npc.barks)
	Net.fireList("NpcSpeech", hearers, { npcId = npc.id, text = text })
end

-- The optional model hook: 2 s budget, cached, always filtered for the listener. Nil = use baseline.
local function rendered(npc: any, topic: string, ctx: DialogueEngine.Context, baseline: string, player: Player): string?
	local renderer = DialogueEngine.renderer
	if not renderer or not flags.get("npc_llm_dialogue") then
		return nil
	end
	local keys = {}
	for k, v in ctx.vars do
		table.insert(keys, k .. "=" .. v)
	end
	table.sort(keys)
	local cacheKey = npc.id .. "|" .. topic .. "|" .. ctx.mood .. "|" .. ctx.rel .. "|" .. table.concat(keys, ";")
	local text = renderCache[cacheKey]
	if not text then
		local done, result = false, nil :: string?
		task.spawn(function()
			local ok, out = pcall(renderer, ctx, baseline)
			if ok and typeof(out) == "string" and #out > 0 and #out <= 400 then
				result = out
			end
			done = true
		end)
		local started = os.clock()
		while not done and os.clock() - started < RENDER_BUDGET do
			task.wait(0.05)
		end
		if not result then
			return nil
		end
		text = result
		if renderCacheSize >= RENDER_CACHE_CAP then
			table.clear(renderCache)
			renderCacheSize = 0
		end
		renderCache[cacheKey] = result :: string
		renderCacheSize += 1
	end
	local ok, filtered = pcall(function()
		local result = TextService:FilterStringAsync(text :: string, player.UserId, Enum.TextFilterContext.PublicChat)
		return result:GetNonChatStringForUserAsync(player.UserId)
	end)
	return if ok and typeof(filtered) == "string" then filtered else nil
end

-- ─── Brains ─────────────────────────────────────────────────────────────────

-- Drains needs up to now and re-decides when the action ran out (or something forced it).
local function think(npc: any, now: number)
	if npc.knockedOut or npc.frozen then
		npc.lastTick = now
		return
	end
	local hours = math.max(0, (now - npc.lastTick) * 24)
	NPCBrain.integrate(npc, hours, npc.action)
	npc.lastTick = now
	if NPCCombat.engaged(npc) and (npc.tier ~= 0 or not npc.rig) then
		NPCCombat.disengage(npc) -- fights only run on full rigs; out of sight, it's over
	end
	if now < npc.actionUntil or NPCCombat.engaged(npc) or npc.leash then
		return -- a fight (NPCCombat) or a quest leash owns the NPC until it ends
	end
	local previous = npc.action
	local block = ScheduleService.blockAt(npc, WorldClock.hourOf(now), inDanger(npc))
	NPCBrain.decide(npc, now, block, threatened(npc, now))
	if npc.action ~= previous or not npc.destination then
		route(npc)
	end
end

-- Precise (T0) extras: barks near players and cosmetic work casts.
local function liveExtras(npc: any, now: number, clock: number)
	if npc.knockedOut or not npc.rig then
		return
	end
	if clock >= (npc.nextBark or 0) and #playersNear(npc.position, BARK_RADIUS) > 0 then
		npc.nextBark = clock + 45 + (npc.seed % 45)
		say(npc, "ambient", nil, nil)
	end
	if npc.action == "work" and LOD.arrived(npc) and clock >= (npc.nextWorkCast or 0) then
		npc.nextWorkCast = clock + 12 + (npc.seed % 14)
		local day = math.floor(now)
		local spell = NPCMagicLife.workCast(npc, day, WorldClock.weekdayOf(day))
		if spell then
			LOD.playCast(npc)
			local root: BasePart = npc.rig.root
			local point = root.Position + root.CFrame.LookVector * 3
			runner:cue("spell", {
				stage = "resolve",
				domain = spell.domains[1],
				property = spell.recipe.property,
				verb = spell.recipe.verb,
				form = spell.recipe.form,
				power = spell.recipe.power,
				masteryTier = spell.masteryTier,
				origin = root.Position,
				point = point,
				radius = spell.area,
				castTime = spell.castTime,
				backfire = false,
				signature = npc.signatureJson,
				npcId = npc.id,
			}, point, false)
		end
	end
end

-- T0/T1 brains: round-robin over `near`, within BRAIN_BUDGET per frame.
local function brainStep()
	local count = #near
	if count == 0 then
		return
	end
	local started = os.clock()
	local now = WorldClock.now()
	for _ = 1, count do
		if brainCursor > count then
			brainCursor = 1
		end
		local npc = near[brainCursor]
		brainCursor += 1
		local clock = os.clock()
		if clock >= (npc.nextBrain or 0) then
			npc.nextBrain = clock + (if npc.tier == 0 then T0_BRAIN else T1_BRAIN)
			think(npc, now)
			if npc.tier == 0 then
				liveExtras(npc, now, clock)
			end
			stats.brainTicks += 1
		end
		if os.clock() - started > BRAIN_BUDGET then
			break
		end
	end
	stats.brainMs += (os.clock() - started) * 1000
end

-- T2 brains, once per game hour. Large batches are scored on Actors (same UtilityScore module).
local function thinkFar(now: number)
	local started = os.clock()
	local due: { any } = {}
	for _, npc in all do
		if (npc.tier or 2) == 2 and not npc.knockedOut then
			if npc.destination and not LOD.arrived(npc) then
				LOD.teleport(npc, groundAt)
			end
			NPCBrain.integrate(npc, math.max(0, (now - npc.lastTick) * 24), npc.action)
			npc.lastTick = now
			if now >= npc.actionUntil then
				table.insert(due, npc)
			end
		end
	end
	stats.t2Count = #due
	stats.parallel = false
	local p = pool
	if p and flags.get("npc_parallel") and #due >= PARALLEL_MIN then
		local batches, blocks = {}, {}
		for i, npc in due do
			local b = (i - 1) // PARALLEL_BATCH + 1
			batches[b] = batches[b] or { jobs = {} }
			local block = ScheduleService.blockAt(npc, WorldClock.hourOf(now), inDanger(npc))
			blocks[npc.id] = block
			table.insert(batches[b].jobs, {
				id = npc.id,
				compiled = npc.compiled,
				needs = npc.needs,
				block = block,
				current = npc.action,
				hour = math.floor(now * 24),
				threat = threatened(npc, now),
			})
		end
		local ok, results = pcall(p.map, p, batches)
		if ok then
			stats.parallel = true
			for _, result in results do
				if typeof(result) == "table" and not result.error then
					for id, action in result do
						local npc = byId[id]
						-- The NPC may have come near a player while the batch ran; its own brain wins.
						if npc and (npc.tier or 2) == 2 and NeedsActions.actions[action] then
							local previous = npc.action
							NPCBrain.apply(npc, now, blocks[id], action)
							if action ~= previous then
								route(npc)
							end
						end
					end
				elseif typeof(result) == "table" then
					log:warn("npc_parallel_failed", { err = result.error })
				end
			end
			stats.t2Ms = (os.clock() - started) * 1000
			return
		end
		log:warn("npc_parallel_unavailable", { err = tostring(results) })
	end
	for _, npc in due do
		local previous = npc.action
		NPCBrain.decide(npc, now, ScheduleService.blockAt(npc, WorldClock.hourOf(now), inDanger(npc)), threatened(npc, now))
		if npc.action ~= previous then
			route(npc)
		end
	end
	stats.t2Ms = (os.clock() - started) * 1000
end

-- ─── Social life (hourly) ───────────────────────────────────────────────────

local SOCIAL: { [string]: boolean } = { socialize = true, play = true, eat = true, worship = true, trade = true, help = true }

local function socialHour(town: Town, now: number)
	-- People doing something social in the same district pair up, seeded per hour.
	local groups: { [string]: { any } } = {}
	for _, npc in town.npcs do
		if SOCIAL[npc.action] and not npc.knockedOut and not npc.magic.rogue then
			local def = NeedsActions.actions[npc.action]
			local district = ScheduleService.districtFor(npc, npc.action, def.district)
			if district == "home" then
				district ..= ":" .. npc.household
			end
			groups[district] = groups[district] or {}
			table.insert(groups[district], npc)
		end
	end
	local rng = Seed.random(worldSeed, town.id, "npc.social", math.floor(now * 24))
	local names = {}
	for district in groups do
		table.insert(names, district)
	end
	table.sort(names)
	for _, district in names do
		local group = groups[district]
		for i = #group, 2, -1 do
			local j = rng:NextInteger(1, i)
			group[i], group[j] = group[j], group[i]
		end
		for i = 1, #group - 1, 2 do
			local a, b = group[i], group[i + 1]
			RelationshipGraph.onChat(a, b)
			for _, pair in { { a, b }, { b, a } } do
				local speaker, listener = pair[1], pair[2]
				local memory = MemoryService.gossip(speaker, listener, now, RelationshipGraph.get(listener.id, speaker.id).trust)
				if memory and string.sub(memory.subject, 1, 2) == "u:" then
					town.dirty = true
				end
			end
		end
	end
end

-- Professions that answer a danger turn out for it: their work magic relieves the event.
local function reliefHour(town: Town, now: number)
	if next(town.dangers) == nil then
		return
	end
	local day = math.floor(now)
	for _, npc in town.npcs do
		local relief = NpcData.occupations[npc.occupation].relief
		if relief and not npc.knockedOut and (npc.action == "help" or npc.action == "work") then
			for _, eventType in town.dangers do
				if table.find(relief, eventType) then
					local spell = NPCMagicLife.workCast(npc, day, WorldClock.weekdayOf(day))
					if spell then
						events:noteCast(npc.position, spell.domains, spell.recipe.power)
					end
					break
				end
			end
		end
	end
end

local function recoverHour(now: number)
	for _, npc in all do
		if npc.knockedOut and now >= npc.knockedOutUntil then
			npc.knockedOut = false
			npc.position = homePosition(npc)
			npc.action = "idle"
			npc.actionUntil = 0
		end
	end
end

local function recompile(npcs: { any })
	for _, npc in npcs do
		npc.compiled = NPCBrain.compile(npc)
	end
end

-- A new chapter of everyone's magical career (one per NPCMagicLife.CHAPTER_DAYS game days).
local function advanceChapters(now: number)
	local chapter = math.floor(now / NPCMagicLife.CHAPTER_DAYS)
	if chapter <= lastChapter then
		return
	end
	lastChapter = chapter
	local job = Scheduler.spawn("npc chapter " .. chapter, function()
		for _, town in towns do
			NPCMagicLife.advance(town.npcs, chapter, now, Scheduler.checkpoint)
			recompile(town.npcs)
			Scheduler.checkpoint()
		end
	end, Scheduler.Priority.Low)
	Scheduler.await(job)
	log:info("npc_chapter", { chapter = chapter })
end

-- ─── Mythic awakenings ──────────────────────────────────────────────────────

local function awaken(npc: any, cause: string, broadcast: boolean, day: number?): boolean
	local domain = npc.magic.hiddenMythic
	local when = day or math.floor(WorldClock.now())
	if not NPCMagicLife.awaken(npc, when, cause) then
		return false
	end
	npc.compiled = NPCBrain.compile(npc)
	local town = townById[npc.settlementId]
	if town then
		town.dirty = true
	end
	log:info("npc_awakened", { npc = npc.id, cause = cause })
	-- Neighbours who saw it remember (and will gossip about it).
	local now = WorldClock.now()
	for _, other in (if town then town.npcs else {}) :: { any } do
		if other ~= npc and (other.position - npc.position).Magnitude < 60 then
			MemoryService.add(other, "awakened", npc.id, now, { intensity = 0.8, note = domain })
		end
	end
	if broadcast then
		task.spawn(worldService.recordEvent, worldService, "npc_awakened", { npc = npc.id, domain = domain, day = when })
	end
	return true
end

-- ─── Reactions ──────────────────────────────────────────────────────────────

local function onWitnessed(payload: any)
	if not enabled() then
		return
	end
	local position: Vector3 = payload.position
	local subject = subjectOf(payload.casterUserId)
	local reach = math.max(40, (payload.radius or 0) * 2)
	local now = WorldClock.now()
	local mythic = false
	for _, d in payload.domains do
		if Registry.domains[d] and Registry.domains[d].rarity == "Mythic" then
			mythic = true
		end
	end
	local kind = if mythic then "saw_mythic_magic" elseif payload.harmful then "saw_harmful_magic" else "saw_magic"
	local intensity = math.clamp((payload.power or 1) / 10, 0.1, 0.8)
	local seen = 0
	for _, town in townAt(position, reach) do
		for _, npc in town.npcs do
			if npc.knockedOut or npc.action == "sleep" then
				continue
			end
			local d = (npc.position - position).Magnitude
			if d > reach then
				continue
			end
			MemoryService.add(npc, kind, subject, now, { intensity = intensity })
			if not RelationshipGraph.peek(npc.id, subject) then
				RelationshipGraph.adjust(npc.id, subject, RelationshipGraph.domainBias(npc, payload.domains), 0)
			end
			if payload.harmful and d < (payload.radius or 0) + 12 then
				npc.needs.safety = math.max(0, npc.needs.safety - 0.25)
				npc.threatUntil = now + 1 / 24
				npc.actionUntil = 0
			end
			local hidden = npc.magic.hiddenMythic
			if hidden and table.find(payload.domains, hidden) and d <= MYTHIC_WITNESS_RANGE and (payload.power or 0) >= MYTHIC_WITNESS_POWER then
				awaken(npc, "witnessed " .. Registry.domains[hidden].name .. " magic", true)
			end
			town.dirty = true
			seen += 1
			if seen >= WITNESS_CAP then
				return
			end
		end
	end
end

-- Out cold for six game hours; a dead Humanoid can't be revived, so its rig is discarded.
local function knockout(npc: any, source: number?)
	npc.knockedOut = true
	npc.knockedOutUntil = WorldClock.now() + 0.25
	LOD.discard(npc)
	local _, built = LOD.poolStats()
	LOD.prewarm(built + 1)
	log:info("npc_knocked_out", { npc = npc.id, by = source })
end

local function onDamage(payload: any)
	if not enabled() then
		return
	end
	local humanoid: Humanoid = payload.humanoid
	local model = humanoid.Parent
	local npc = model and byId[model:GetAttribute("NpcId") :: any]
	if not npc or npc.knockedOut then
		return
	end
	local now = WorldClock.now()
	local town = townById[npc.settlementId]
	local source: number? = payload.sourceUserId
	npc.needs.safety = math.max(0, npc.needs.safety - 0.4)
	npc.threatUntil = now + 1 / 24
	npc.actionUntil = 0
	local knockedOut = humanoid.Health <= 0
	if source then
		local subject = subjectOf(source)
		MemoryService.add(npc, "attacked_me", subject, now, { intensity = math.clamp(payload.amount / 40, 0.3, 1) })
		RelationshipGraph.adjust(npc.id, subject, -0.15, -0.1)
		for _, other in town.npcs do
			if other ~= npc and not other.knockedOut and (other.position - npc.position).Magnitude < 40 then
				MemoryService.add(other, "attacked_someone", subject, now, { intensity = 0.5 })
				RelationshipGraph.adjust(other.id, subject, -0.05, -0.03)
				-- Guards and hunters who see it come to help (NPC/NPCCombat).
				if other.rig and (other.position - npc.position).Magnitude < Combat.aggro.witnessRadius then
					NPCCombat.onWitness(other, subject)
				end
			end
		end
		local player = Players:GetPlayerByUserId(source)
		local state = player and playerData:get(player)
		if state then
			local reputation = state.data.reputation
			local delta = Settlements.scaleReputation(town.settlement, if knockedOut then -15 else -3)
			reputation[town.id] = (reputation[town.id] or 0) + delta
		end
		town.dirty = true
	end
	if knockedOut then
		NPCCombat.disengage(npc)
		knockout(npc, source)
		return
	end
	-- Aggro: fight back or flee (NPC/NPCCombat). Speak only when the fight starts.
	local fresh = not NPCCombat.engaged(npc)
	NPCCombat.onAttacked(npc, if source then subjectOf(source) else nil, payload.amount)
	if fresh and npc.tier == 0 then
		say(npc, "react_attacked", if source then subjectOf(source) else nil, nil)
	end
end

local function onEventStarted(payload: any)
	if not ready then
		return
	end
	local severity = NeedsActions.dangerEvents[payload.type]
	if severity then
		for _, town in towns do
			local reach = payload.radius + town.radius
			if (town.x - payload.x) ^ 2 + (town.z - payload.z) ^ 2 <= reach * reach then
				town.dangers[payload.id] = payload.type
				for _, npc in town.npcs do
					npc.needs.safety = math.max(0, npc.needs.safety - severity)
					npc.actionUntil = 0
				end
			end
		end
	end
	local domain = SKY_AWAKENINGS[payload.type]
	if domain then
		for _, npc in all do
			if npc.magic.hiddenMythic == domain and npc.action ~= "sleep" and not npc.knockedOut then
				awaken(npc, "saw the " .. payload.type, true)
			end
		end
	end
end

local function onEventEnded(payload: any)
	for _, town in towns do
		if town.dangers[payload.id] then
			town.dangers[payload.id] = nil
			for _, npc in town.npcs do
				npc.actionUntil = 0
			end
		end
	end
end

-- ─── Persistence ────────────────────────────────────────────────────────────

-- Scoped by the world's generation, so a reseeded world starts with fresh town records.
local function townKey(id: string): string
	return worldService:scopedKey("town_" .. id)
end

-- What a town must remember: awakenings and memories of players (the rest regenerates).
local function snapshot(town: Town, now: number): { [string]: any }
	local out = {}
	for _, npc in town.npcs do
		local entry: any = {}
		local a = npc.magic.awakened
		if a then
			entry.mythic = { domain = a.domain, day = a.day }
		end
		local memories = {}
		for _, m in MemoryService.top(npc, 64, now) do
			if string.sub(m.subject, 1, 2) == "u:" and #memories < SAVED_MEMORIES then
				table.insert(memories, { t = round(m.t, 3), k = m.kind, s = m.subject, v = round(m.valence, 2), i = round(m.intensity, 2) })
			end
		end
		if #memories > 0 then
			entry.memories = memories
		end
		if entry.mythic or entry.memories then
			out[npc.id] = entry
		end
	end
	return out
end

local function saveTown(town: Town)
	local now = WorldClock.now()
	local mine = snapshot(town, now)
	town.dirty = false
	local _, err = store:update(townKey(town.id), function(data: any)
		for npcId, entry in mine do
			local saved: any = data.npcs[npcId] or {}
			if entry.mythic and (not saved.mythic or entry.mythic.day < saved.mythic.day) then
				saved.mythic = entry.mythic
			end
			-- Union by (t, kind, subject); keep the strongest SAVED_MEMORIES (intensity, decayed by age).
			local merged: { [string]: any } = {}
			for _, list in { saved.memories or {}, entry.memories or {} } :: { { any } } do
				for _, m in list do
					local key = m.t .. "|" .. m.k .. "|" .. m.s
					if not merged[key] or merged[key].i < m.i then
						merged[key] = m
					end
				end
			end
			local list = {}
			for _, m in merged do
				table.insert(list, m)
			end
			table.sort(list, function(a, b)
				return a.i * 0.5 ^ ((now - a.t) / 5) > b.i * 0.5 ^ ((now - b.t) / 5)
			end)
			while #list > SAVED_MEMORIES do
				table.remove(list)
			end
			saved.memories = list
			data.npcs[npcId] = saved
		end
		data.rev += 1
		return data
	end)
	if err then
		town.dirty = true
		log:warn("npc_town_save_failed", { town = town.id, reason = err })
	end
end

local function flushTowns()
	for _, town in towns do
		if town.dirty then
			saveTown(town)
		end
	end
end

local function applySaved(town: Town)
	local saved = town.saved
	if not saved then
		return
	end
	for npcId, entry in (saved.npcs or {}) :: { [string]: any } do
		local npc = byId[npcId]
		if not npc or typeof(entry) ~= "table" then
			continue
		end
		local mythic = entry.mythic
		if mythic and npc.magic.hiddenMythic == mythic.domain then
			NPCMagicLife.awaken(npc, tonumber(mythic.day) or 0, "remembered")
		end
		for _, m in (entry.memories or {}) :: { any } do
			if typeof(m) == "table" and MemoryService.KINDS[m.k] and typeof(m.s) == "string" then
				table.insert(npc.memories, {
					t = tonumber(m.t) or 0,
					kind = m.k,
					subject = m.s,
					valence = tonumber(m.v) or 0,
					intensity = math.clamp(tonumber(m.i) or 0.3, 0.01, 1),
					secondhand = false,
				})
			end
		end
		MemoryService.prune(npc, WorldClock.now())
	end
	town.saved = nil
end

-- The NPC's view of a player rides in the PLAYER's save (bounded).
local function savePlayerRelation(player: Player, npc: any)
	local state = playerData:get(player)
	local edge = RelationshipGraph.peek(npc.id, subjectOf(player.UserId))
	if not state or not edge then
		return
	end
	local relationships = state.data.relationships
	local memories = {}
	for _, m in MemoryService.top(npc, 3, WorldClock.now(), subjectOf(player.UserId)) do
		table.insert(memories, { t = round(m.t, 3), kind = m.kind })
	end
	relationships[npc.id] = { affinity = round(edge.affinity, 3), trust = round(edge.trust, 3), memories = memories }
	local count, weakest, weakestScore = 0, nil, math.huge
	for id, rel in relationships do
		count += 1
		local score = math.abs(tonumber(rel.affinity) or 0)
		if id ~= npc.id and score < weakestScore then
			weakest, weakestScore = id, score
		end
	end
	if count > SAVED_RELATIONS and weakest then
		relationships[weakest] = nil
	end
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

local function populationOf(settlement: Settlements.Settlement): number
	local mult = math.clamp(tonumber(flags.get("npc_population_mult")) or 1, 0.25, 3)
	return math.max(1, math.floor(settlement.population * mult + 0.5))
end

-- Authored NPCs take the LAST slots of the first settlement that fits (culture, then any culture,
-- then any size), so their ids are stable "<settlementId>#<slot>".
local function authoredOverrides(settlements: { Settlements.Settlement }): { [string]: { [number]: any } }
	local out: { [string]: { [number]: any } } = {}
	local used: { [string]: number } = {}
	for _, def in NpcData.authored :: { any } do
		local target: Settlements.Settlement? = nil
		for pass = 1, 3 do
			for _, s in settlements do
				local cultureOk = pass >= 2 or #def.cultures == 0 or table.find(def.cultures, s.culture) ~= nil
				local sizeOk = pass == 3 or table.find(def.size, s.size) ~= nil
				if cultureOk and sizeOk then
					target = s
					break
				end
			end
			if target then
				break
			end
		end
		if target then
			local n = used[target.id] or 0
			local slot = populationOf(target) - n
			if slot >= 1 then
				used[target.id] = n + 1
				out[target.id] = out[target.id] or {}
				out[target.id][slot] = def
			end
		end
	end
	return out
end

local function enrich(npc: any, town: Town, now: number)
	npc.signatureJson = HttpService:JSONEncode(npc.profile.signature)
	npc.occupationName = NpcData.occupations[npc.occupation].name
	npc.scheduleShift = ScheduleService.shift(npc)
	npc.needs = NPCBrain.freshNeeds(npc.seed)
	npc.drain = NPCBrain.drainOf(npc)
	npc.memories = {}
	npc.spots = {}
	npc.tier = 2
	npc.action = "idle"
	npc.actionUntil = 0
	npc.lastTick = now
	NPCMagicLife.init(npc)
	-- Everyone starts at one of the plaza's NPCSpawn points and walks (or, far away, travels) out.
	local points = town.spawnPoints
	if points and #points > 0 then
		local p = points[(npc.slot - 1) % #points + 1]
		local jitter = (npc.seed % 628) / 100
		npc.position = groundAt(p + Vector3.new(math.cos(jitter), 0, math.sin(jitter)) * 2)
	else
		npc.position = spotFor(npc, "home")
	end
	table.insert(town.npcs, npc)
	byId[npc.id] = npc
	table.insert(all, npc)
end

local function newTown(s: Settlements.Settlement, radius: number, load: boolean): Town
	local town: Town = {
		id = s.id,
		settlement = s,
		x = s.x,
		z = s.z,
		radius = radius,
		place = { x = s.x, z = s.z, radius = radius, seed = Seed.derive(worldSeed, s.id, "npc.layout") },
		npcs = {},
		dangers = {},
		dirty = false,
		saved = nil,
	}
	if load then
		local data, err = store:read(townKey(s.id))
		if err then
			log:warn("npc_town_load_failed", { town = s.id, reason = err })
		end
		town.saved = data
	end
	table.insert(towns, town)
	townById[s.id] = town
	return town
end

-- Generates a town's residents and brings them to the present. Runs inside a Scheduler job.
local function populateTown(town: Town, overrides: { [number]: any }?, now: number, chapter: number)
	local s = table.clone(town.settlement)
	s.population = populationOf(town.settlement)
	for _, npc in NPCFactory.populate(worldSeed, s, overrides) do
		enrich(npc, town, now)
		Scheduler.checkpoint()
	end
	RelationshipGraph.seed(town.npcs)
	assignBuildings(town)
	applySaved(town)
	NPCMagicLife.advance(town.npcs, chapter, now, Scheduler.checkpoint)
	for _, npc in town.npcs do
		npc.compiled = NPCBrain.compile(npc)
		NPCBrain.decide(npc, now, ScheduleService.blockAt(npc, WorldClock.hourOf(now), false), false)
		route(npc)
		Scheduler.checkpoint()
	end
end

local function boot()
	local started = os.clock()
	local settlements = world:placement().settlements
	local placement = world:placement()
	local overrides = authoredOverrides(settlements)
	local now = WorldClock.now()
	local chapter = math.floor(now / NPCMagicLife.CHAPTER_DAYS)

	-- Town records first: DataStore reads yield, which Scheduler jobs must never do.
	for _, s in settlements do
		local poi = placement.byId[s.id]
		local town = newTown(s, if poi then poi.radius else 60, true)
		settlementSvc:layoutFor(s.id) -- computed now, outside the job (it may wait for another thread)
		town.spawnPoints = settlementSvc:spawnPoints(s.id)
	end

	local job = Scheduler.spawn("npc populate", function()
		for _, town in towns do
			populateTown(town, overrides[town.id], now, chapter)
		end
	end, Scheduler.Priority.Low)
	Scheduler.await(job)
	lastChapter = chapter

	-- Players who loaded before the NPCs existed.
	for _, state in playerData:list() do
		RelationshipGraph.loadPlayer(state.player.UserId, state.data.relationships)
	end
	stats.bootMs = math.floor((os.clock() - started) * 1000)
	ready = true
	log:info("npcs_ready", { npcs = #all, towns = #towns, chapter = chapter, ms = stats.bootMs, clock = WorldClock.stamp() })
end

-- ─── LOD pass ───────────────────────────────────────────────────────────────

local function lodPass()
	table.clear(playerRoots)
	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		if root then
			table.insert(playerRoots, { player = player, position = root.Position })
		end
	end
	if flags.get("npc_day_night") then
		Lighting.ClockTime = WorldClock.hour()
	end

	for _, npc in LOD.assign(towns :: { any }) do
		local hadRig = npc.rig ~= nil
		if not LOD.sync(npc, groundAt) then
			local available, built = LOD.poolStats()
			if available == 0 then
				LOD.prewarm(math.min(built + 12, LOD.limits.maxT0 + LOD.limits.maxT1))
			end
		elseif npc.rig and not hadRig then
			npc.nextBrain = 0
			if npc.destination then
				LOD.setDestination(npc, npc.destination)
			else
				route(npc)
			end
		end
	end

	table.clear(near)
	table.clear(tier0)
	table.clear(tier1)
	for _, npc in all do
		if npc.tier == 0 and npc.rig then
			table.insert(tier0, npc)
			table.insert(near, npc)
		elseif npc.tier == 1 and npc.rig then
			table.insert(tier1, npc)
			table.insert(near, npc)
		end
	end
end

-- Everything goes back to data (the flag was switched off).
local function demoteAll()
	for _, npc in all do
		if (npc.tier or 2) ~= 2 then
			npc.tier = 2
			LOD.sync(npc, groundAt)
		end
	end
	table.clear(near)
	table.clear(tier0)
	table.clear(tier1)
end

local function heartbeat()
	local lodAt, t0At, t1At = 0, 0, 0
	local wasEnabled = true
	RunService.Heartbeat:Connect(function()
		if not enabled() then
			if wasEnabled and ready then
				demoteAll()
			end
			wasEnabled = false
			return
		end
		wasEnabled = true
		local clock = os.clock()
		if clock >= lodAt then
			lodAt = clock + LOD_INTERVAL
			lodPass()
		end
		if clock >= t0At then
			t0At = clock + T0_STEP
			local serverNow = workspace:GetServerTimeNow()
			for _, npc in tier0 do
				if not npc.rig then
					continue -- knocked out this frame: the rig is gone, the next LOD pass drops it
				end
				local humanoid: Humanoid = npc.rig.humanoid
				local flinchUntil = humanoid:GetAttribute("FlinchUntil")
				-- Down or recoiling (HitReactions): no walking, unless a fight is stepping it.
				local reeling = humanoid:GetAttribute("KnockedDown") or (typeof(flinchUntil) == "number" and flinchUntil > serverNow)
				if npc.frozen or (npc.talkingUntil or 0) > clock or (reeling and not NPCCombat.engaged(npc)) then
					humanoid:Move(Vector3.zero)
				elseif NPCCombat.engaged(npc) then
					NPCCombat.step(npc, T0_STEP)
				else
					local leash = npc.leash
					if leash and leash.kind == "follow" then
						-- Escort: walk to a spot just behind the player.
						local player = Players:GetPlayerByUserId(leash.userId or 0)
						local proot = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
						if proot and proot:IsA("BasePart") and (proot.Position - npc.position).Magnitude > 7 then
							LOD.setDestination(npc, proot.Position - proot.CFrame.LookVector * 4)
						end
					end
					LOD.stepT0(npc)
				end
			end
		end
		if clock >= t1At then
			t1At = clock + T1_STEP
			for _, npc in tier1 do
				if not npc.frozen then
					LOD.stepT1(npc, groundAt)
				end
			end
		end
		brainStep()
	end)
end

-- Polls for a new game hour, so pausing or speeding up the clock (admin time scale) just works.
-- After a jump of many hours (simulate days) the hour's work runs once, not once per hour.
local function hourly()
	local lastHour = math.floor(WorldClock.now() * 24)
	while true do
		task.wait(0.25)
		local hourIndex = math.floor(WorldClock.now() * 24)
		if hourIndex == lastHour or not enabled() then
			continue
		end
		lastHour = hourIndex
		local now = WorldClock.now()
		recoverHour(now)
		thinkFar(now)
		for _, town in towns do
			socialHour(town, now)
			reliefHour(town, now)
		end
		advanceChapters(now)
	end
end

-- ─── Remotes ────────────────────────────────────────────────────────────────

-- Teaching: their best branch, if they're a tier above the player in it.
local function teachOffer(player: Player, npc: any): any?
	local state = playerData:get(player)
	local branch = NPCMagicLife.best(npc)
	if not branch or not state then
		return nil
	end
	local mentorTier = NPCMagicLife.tierOf(npc, branch)
	local p = state.data.progression
	local playerTier = Progression.getMasteryTier(p, branch)
	local gap = mentorTier - playerTier
	return {
		branch = branch,
		canTeach = p.unlocked[branch] == true and gap >= ProgressionTuning.study.minTierGap,
		noGap = p.unlocked[branch] == true and gap < ProgressionTuning.study.minTierGap,
		mentorTier = mentorTier,
	}
end

local function onTalk(player: Player, npcId: string, topic: string): any
	if not enabled() then
		return { ok = false, reason = "unavailable" }
	end
	local npc = byId[npcId]
	local root = rootOf(player)
	if not npc or not npc.rig or npc.knockedOut or not root then
		return { ok = false, reason = "unavailable" }
	end
	local npcRoot: BasePart = npc.rig.root
	if (npcRoot.Position - root.Position).Magnitude > TALK_DISTANCE then
		return { ok = false, reason = "too_far" }
	end
	local listener = subjectOf(player.UserId)
	local now = WorldClock.now()
	local state = playerData:get(player)

	-- First impressions colour by the domains the player visibly uses.
	if not RelationshipGraph.peek(npc.id, listener) and state then
		RelationshipGraph.adjust(npc.id, listener, RelationshipGraph.domainBias(npc, state.innate.manifest), 0)
	end

	local teach: any = if topic == "learn" then teachOffer(player, npc) else nil
	local branch = if teach then teach.branch else nil

	talkTurns[player] = talkTurns[player] or {}
	local turn = (talkTurns[player][npc.id] or 0) + 1
	talkTurns[player][npc.id] = turn

	local ctx = contextFor(npc, listener, player, teach)
	-- Quests: the Director may answer (topic "quest"), and decides whether to offer the topic.
	local questText, offersQuest = nil, false
	if talkHook then
		local ok, text, offers = pcall(talkHook :: any, player, npc, topic)
		if ok then
			questText, offersQuest = text, offers == true
		end
	end
	bus:publish(Topics.NpcTalked, { player = player, npcId = npc.id, topic = topic })
	local text = if topic == "quest" and questText then questText else DialogueEngine.line(npc, if topic == "quest" then "greet" else topic, ctx, turn)
	local studied: any = nil
	if teach and teach.canTeach and (ctx.rel == "acquaintance" or ctx.rel == "friend" or ctx.rel == "close") then
		local gain, err = progression:awardStudy(player, branch :: string, "mentor", npc.id, { mentorTier = teach.mentorTier })
		studied = if gain then { branch = branch, ok = true } else { branch = branch, ok = false, reason = err }
		if gain then
			RelationshipGraph.adjust(npc.id, listener, 0.03, 0.04)
		end
	end
	text = rendered(npc, topic, ctx, text, player) or text

	-- A friendly talk is a small good memory; a talk while they hold a grudge isn't.
	MemoryService.add(npc, "talked_kindly", listener, now, { intensity = 0.15 })
	RelationshipGraph.adjust(npc.id, listener, if ctx.vars.grievance then 0.005 else 0.02, 0.01)
	townById[npc.settlementId].dirty = true
	savePlayerRelation(player, npc)

	-- Face the speaker and stand still for a moment.
	npc.talkingUntil = os.clock() + 8
	local flat = Vector3.new(root.Position.X, npcRoot.Position.Y, root.Position.Z)
	if (flat - npcRoot.Position).Magnitude > 0.1 and not npcRoot.Anchored then
		npc.rig.model:PivotTo(CFrame.lookAt(npcRoot.Position, flat))
	end

	local mood = DialogueEngine.mood(npc, now)
	return {
		ok = true,
		npcId = npc.id,
		name = npc.name,
		occupation = npc.occupationName,
		topic = topic,
		text = text,
		mood = mood,
		rel = ctx.rel,
		studied = studied,
		topics = if offersQuest then withQuestTopic else TOPICS,
	}
end

-- The inspector's view of one NPC. ADMINS ONLY: it includes hidden potential.
local function inspect(npc: any): { [string]: any }
	local now = WorldClock.now()
	local quirks = {}
	for _, q in npc.quirks do
		table.insert(quirks, Quirks.defs[q].name or q)
	end
	local memories = {}
	for _, m in MemoryService.top(npc, 6, now) do
		table.insert(memories, string.format("%s %s (%.2f%s)", m.kind, nameOf(m.subject), MemoryService.strength(npc, m, now), if m.secondhand then ", heard" else ""))
	end
	local relations = {}
	for _, rel in RelationshipGraph.top(npc.id, 6) do
		table.insert(relations, string.format("%s: %s aff %.2f trust %.2f%s", nameOf(rel.id), RelationshipGraph.bondLabel(rel.edge.bond), rel.edge.affinity, rel.edge.trust, if rel.edge.rivalry > 0.2 then " rival" else ""))
	end
	local scores = {}
	for _, row in (npc.lastScores or {}) :: { UtilityScore.Breakdown } do
		table.insert(scores, string.format("%s %.3f (needs %.2f fit %.2f pers %.2f quirk %.2f)", row.action, row.total, row.needs, row.fit, row.personality, row.quirk))
	end
	local best, mastery, tier = NPCMagicLife.best(npc)
	local magic = npc.magic
	local techniques = {}
	for _, t in magic.techniques do
		table.insert(techniques, t.name)
	end
	local history = {}
	for i = math.max(1, #magic.history - 5), #magic.history do
		local h = magic.history[i]
		table.insert(history, string.format("day %d: %s", h.day, h.text))
	end
	local needs = {}
	for _, need in NeedsActions.needs do
		needs[need] = round(npc.needs[need] or 0, 2)
	end
	local traits = {}
	for t, v in npc.traits do
		traits[t] = round(v, 2)
	end
	return {
		id = npc.id,
		name = npc.name,
		age = npc.age,
		occupation = npc.occupationName,
		settlement = npc.settlementName,
		culture = npc.culture,
		home = if npc.home then string.format("%s (bed %d)", settlementSvc:lotName(npc.home.lot), npc.home.slot) else "no house (district spot)",
		work = if npc.work then settlementSvc:lotName(npc.work.lot) else "outdoors (district spot)",
		tier = npc.tier or 2,
		clock = WorldClock.stamp(now),
		action = npc.action,
		block = npc.lastBlock,
		mood = (DialogueEngine.mood(npc, now)),
		knockedOut = npc.knockedOut == true,
		traits = traits,
		quirks = quirks,
		values = npc.values,
		fears = npc.fears,
		goal = npc.goal.text,
		ambition = npc.ambition.text,
		secret = if npc.secret then npc.secret.text else nil,
		needs = needs,
		scores = scores,
		memories = memories,
		relations = relations,
		magic = {
			manifest = npc.profile.manifest,
			rarity = InnateProfile.getRarityTier(npc.profile, false),
			best = if best then Registry.branches[best].name else nil,
			mastery = round(mastery, 1),
			tier = tier,
			focus = if magic.focus then Registry.branches[magic.focus].name else nil,
			school = magic.school,
			mentor = if magic.mentor then nameOf(magic.mentor) else nil,
			students = #magic.students,
			rival = if magic.rival then nameOf(magic.rival) else nil,
			techniques = techniques,
			forbidden = magic.forbidden,
			rogue = magic.rogue,
			hiddenMythic = magic.hiddenMythic,
			awakened = if magic.awakened then magic.awakened.domain else nil,
			history = history,
		},
	}
end

-- ─── Console ────────────────────────────────────────────────────────────────

-- A deterministic 24-hour trace: fresh needs at midnight, no threats, 15-minute steps.
local function dayTrace(npc: any): string
	local shadow = setmetatable({ needs = NPCBrain.freshNeeds(npc.seed), action = "sleep", actionUntil = 0 }, { __index = npc }) :: any
	local start = math.floor(WorldClock.now())
	local lines = { string.format("%s (%s, %d, %s) on %s", npc.name, npc.occupationName, npc.age, npc.id, WorldClock.stamp(start)) }
	local last: string? = nil
	for step = 0, 95 do
		local t = start + step / 96
		if step > 0 then
			NPCBrain.integrate(shadow, 0.25, shadow.action)
		end
		if t >= shadow.actionUntil then
			local block = ScheduleService.blockAt(npc, WorldClock.hourOf(t), false)
			NPCBrain.decide(shadow, t, block, false)
		end
		if shadow.action ~= last then
			last = shadow.action
			local def = NeedsActions.actions[shadow.action]
			local district = if npc.magic.rogue then "wilds" else ScheduleService.districtFor(npc, shadow.action, def.district)
			local n = shadow.needs
			table.insert(lines, string.format("%02d:%02d [%s] %s at %s  (rest %.2f food %.2f social %.2f purpose %.2f)", step // 4, (step % 4) * 15, shadow.lastBlock or "?", def.verb, district, n.rest, n.food, n.social, n.purpose))
		end
	end
	return table.concat(lines, "\n")
end

local function describe(npc: any): string
	local v = inspect(npc)
	local lines = {
		string.format("%s, %d, %s of %s (%s) [%s] T%d", v.name, v.age, v.occupation, v.settlement, v.culture, v.id, v.tier),
		string.format("%s: %s (%s block), mood %s%s", v.clock, v.action, tostring(v.block), v.mood, if v.knockedOut then ", KNOCKED OUT" else ""),
		"lives: " .. v.home .. " | works: " .. v.work,
		"quirks: " .. table.concat(v.quirks, ", "),
		"goal: " .. v.goal .. " | ambition: " .. v.ambition,
		string.format("needs: rest %.2f food %.2f safety %.2f social %.2f purpose %.2f wealth %.2f", v.needs.rest, v.needs.food, v.needs.safety, v.needs.social, v.needs.purpose, v.needs.wealth),
		string.format("magic: %s, best %s (%.1f, tier %d), focus %s%s%s%s", table.concat(v.magic.manifest, "/"), tostring(v.magic.best), v.magic.mastery, v.magic.tier, tostring(v.magic.focus),
			if v.magic.school then ", school " .. v.magic.school else "", if v.magic.hiddenMythic then ", HIDDEN " .. v.magic.hiddenMythic else "", if v.magic.rogue then ", ROGUE" else ""),
		"scores: " .. table.concat(v.scores, " | "),
		"memories: " .. (if #v.memories > 0 then table.concat(v.memories, "; ") else "(none)"),
		"relations: " .. table.concat(v.relations, "; "),
		"history: " .. table.concat(v.magic.history, "; "),
	}
	return table.concat(lines, "\n")
end

-- ─── Public API (the admin panel's NPC tools: Server/Admin/Commands/Npc) ────
-- These deliberately skip gameplay rules (distance, cooldown-free edits): admins only.

local adminSpawns = 0
local SPECIAL_ACTIONS = { "home", "flee", "duel", "teachme" }
NPCService.specialActions = SPECIAL_ACTIONS

function NPCService.isReady(_self: any): boolean
	return ready
end

function NPCService.find(_self: any, query: string?, viewer: Player?): any?
	return findNpc(query, viewer)
end

function NPCService.all(_self: any): { any }
	return all
end

-- Exactly the NPC with this id (no name matching), or nil.
function NPCService.get(_self: any, id: any): any?
	return if typeof(id) == "string" then byId[id] else nil
end

--[[
	Quest leashes (QuestDirector): while set, the brain doesn't route the NPC.
		{ kind = "follow", userId }      walks after that player (escorts)
		{ kind = "hold", position }      stays at that place (a missing apprentice at the ruin)
	nil releases it, and the brain re-decides at once.
]]
function NPCService.setLeash(_self: any, npc: any, leash: { kind: string, userId: number?, position: Vector3? }?)
	npc.leash = leash
	npc.actionUntil = 0
	if leash and leash.kind == "hold" and leash.position then
		LOD.setDestination(npc, leash.position)
		if (npc.tier or 2) ~= 0 then
			npc.position = groundAt(leash.position) -- out of sight: just be there
		end
	elseif not leash then
		route(npc)
	end
end

-- QuestDirector's hook into conversations: (text?, offersQuest) for a player talking to an NPC.
function NPCService.setTalkHook(_self: any, fn: (Player, any, string) -> (string?, boolean))
	talkHook = fn
end

-- A quest's ending, remembered: relationship change plus a memory the NPC may gossip about.
function NPCService.questBond(_self: any, npc: any, player: Player, delta: number, memoryKind: string?)
	local subject = subjectOf(player.UserId)
	RelationshipGraph.adjust(npc.id, subject, delta, delta * 0.6)
	if memoryKind then
		MemoryService.add(npc, memoryKind, subject, WorldClock.now(), { intensity = math.clamp(math.abs(delta) * 3, 0.3, 1) })
	end
	local town = townById[npc.settlementId]
	if town then
		town.dirty = true
	end
	savePlayerRelation(player, npc)
end

function NPCService.towns(_self: any): { Town }
	return towns
end

function NPCService.nameOf(_self: any, id: string): string
	return nameOf(id)
end

function NPCService.inspect(_self: any, npc: any): { [string]: any }
	return inspect(npc)
end

function NPCService.describe(_self: any, npc: any): string
	return describe(npc)
end

function NPCService.dayTrace(_self: any, npc: any): string
	return dayTrace(npc)
end

function NPCService.stats(_self: any): { [string]: any }
	return stats
end

function NPCService.awaken(_self: any, npc: any, cause: string): boolean
	return awaken(npc, cause, true)
end

-- What an NPC would say to a player right now (no distance check, no side effects).
function NPCService.sample(_self: any, npc: any, player: Player, topic: string): string
	local ctx = contextFor(npc, subjectOf(player.UserId), player, if topic == "learn" then teachOffer(player, npc) else nil)
	return string.format("%s [%s, %s]: %s", npc.name, ctx.mood, ctx.rel, DialogueEngine.line(npc, topic, ctx, os.time()))
end

local function nearestTown(position: Vector3): Town?
	local best, bestD = nil, math.huge
	for _, town in towns do
		local d = (town.x - position.X) ^ 2 + (town.z - position.Z) ^ 2
		if d < bestD then
			best, bestD = town, d
		end
	end
	return best
end

--[[
	Spawns a new NPC at a position, belonging to the nearest town. opts (all optional):
	  seed        generate from this world seed instead of the real one (a different person)
	  occupation, name, age, traits = { trait = 0..1 }, quirks = { id }, mastery = { branch = 0..100 }
	Ids are "<town>#<1000+n>", so they never collide with generated residents. Not saved.
]]
function NPCService.spawn(_self: any, position: Vector3, opts: { [string]: any }): (any?, string?)
	local town = nearestTown(position)
	if not ready or not town then
		return nil, "NPCs aren't ready"
	end
	adminSpawns += 1
	local slot = 1000 + adminSpawns
	local override: any = {
		key = "admin",
		occupation = opts.occupation,
		name = opts.name,
		age = opts.age,
		traits = opts.traits,
		quirks = opts.quirks,
	}
	if override.occupation == "child" then
		override.age = override.age or 10
	elseif override.occupation == "retired" then
		override.age = override.age or 70
	end
	local now = WorldClock.now()
	local npc = NPCFactory.generate(opts.seed or worldSeed, town.settlement, slot, override)
	npc.household = town.id .. "/admin" .. slot
	enrich(npc, town, now)
	for branch, value in (opts.mastery or {}) :: { [string]: number } do
		npc.magic.unlocked[branch] = true
		npc.magic.mastery[branch] = math.clamp(value, 0, 100)
	end
	NPCMagicLife.refresh(npc)
	npc.compiled = NPCBrain.compile(npc)
	npc.position = groundAt(position)
	npc.spots.home = npc.position
	npc.factionOverride = opts.faction -- quest-spawned agents (the Quiet Hand's hunters)
	NPCBrain.decide(npc, now, ScheduleService.blockAt(npc, WorldClock.hourOf(now), false), false)
	route(npc)
	return npc, nil
end

function NPCService.remove(_self: any, npc: any)
	npc.tier = 2
	LOD.sync(npc, groundAt)
	local town = townById[npc.settlementId]
	if town then
		local i = table.find(town.npcs, npc)
		if i then
			table.remove(town.npcs, i)
		end
	end
	local i = table.find(all, npc)
	if i then
		table.remove(all, i)
	end
	byId[npc.id] = nil
	RelationshipGraph.forget(npc.id)
end

function NPCService.knockout(_self: any, npc: any)
	if not npc.knockedOut then
		knockout(npc, nil)
	end
end

function NPCService.heal(_self: any, npc: any)
	npc.knockedOut = false
	npc.knockedOutUntil = nil
	npc.threatUntil = nil
	npc.magic.injuredUntil = -1
	for _, need in NeedsActions.needs do
		npc.needs[need] = 1
	end
	if npc.rig then
		npc.rig.humanoid.Health = npc.rig.humanoid.MaxHealth
	end
	npc.actionUntil = 0
end

function NPCService.setFrozen(_self: any, npc: any, frozen: boolean)
	npc.frozen = frozen or nil
	if npc.rig then
		npc.rig.humanoid:Move(Vector3.zero)
		npc.rig.root.Anchored = frozen or npc.tier == 1
	end
	if not frozen then
		npc.actionUntil = 0
	end
end

-- nil = back to distance-based LOD.
function NPCService.forceTier(_self: any, npc: any, tier: number?)
	npc.forcedTier = tier
end

-- A duel with their rival (or the nearest adult who knows magic): the same rules as a chapter duel.
local function duel(npc: any): string
	local town = townById[npc.settlementId]
	local opponent = if npc.magic.rival then byId[npc.magic.rival] else nil
	if not opponent and town then
		local bestD = math.huge
		for _, other in town.npcs do
			local d = (other.position - npc.position).Magnitude
			if other ~= npc and other.ageBand ~= "child" and not other.knockedOut and NPCMagicLife.best(other) and d < bestD then
				opponent, bestD = other, d
			end
		end
	end
	local branch = NPCMagicLife.best(npc)
	if not opponent or not branch then
		return npc.name .. " has nobody (or no magic) to duel"
	end
	local rng = Random.new()
	local mine = (npc.magic.mastery[branch] or 0) + rng:NextNumber() * 15
	local theirs = (opponent.magic.mastery[branch] or 0) + rng:NextNumber() * 15
	local winner, loser = if mine >= theirs then npc else opponent, if mine >= theirs then opponent else npc
	local now = WorldClock.now()
	loser.magic.injuredUntil = math.floor(now) + 1
	MemoryService.add(winner, "duel_won", loser.id, now, { intensity = 0.6 })
	MemoryService.add(loser, "duel_lost", winner.id, now, { intensity = 0.7 })
	RelationshipGraph.adjust(loser.id, winner.id, -0.1, 0, 0.1)
	for _, fighter in { npc, opponent } do
		if fighter.rig then
			LOD.playCast(fighter)
		end
	end
	return string.format("%s duelled %s in %s: %s won (%.0f vs %.0f)", npc.name, opponent.name, Registry.branches[branch].name, winner.name, math.max(mine, theirs), math.min(mine, theirs))
end

--[[
	Forces an action for `minutes` of game time. Any NeedsActions id, or:
	  home     walk home and idle there      flee   terrified: re-decides (shelter) now
	  duel     fight their rival now          teachme  give `player` a lesson (no distance check)
]]
function NPCService.forceAction(_self: any, npc: any, action: string, minutes: number, player: Player?): string
	local now = WorldClock.now()
	if action == "duel" then
		return duel(npc)
	elseif action == "teachme" then
		if not player then
			return "teachme needs a player"
		end
		local offer = teachOffer(player, npc)
		if not offer then
			return npc.name .. " has no magic to teach"
		elseif not offer.canTeach then
			return string.format("%s can't teach you %s: %s", npc.name, Registry.branches[offer.branch].name,
				if offer.noGap then "you're not a tier below them" else "you haven't unlocked it")
		end
		local gain, err = progression:awardStudy(player, offer.branch, "mentor", npc.id, { mentorTier = offer.mentorTier })
		return if gain then string.format("%s taught you %s (+%d XP)", npc.name, Registry.branches[offer.branch].name, math.floor(gain.gained)) else "no lesson: " .. tostring(err)
	elseif action == "flee" then
		npc.needs.safety = 0.05
		npc.threatUntil = now + minutes / 1440
		npc.actionUntil = 0
		think(npc, now)
		return npc.name .. " is " .. NeedsActions.actions[npc.action].verb
	elseif action == "home" then
		npc.action = "idle"
		npc.actionStarted = now
		npc.actionUntil = now + minutes / 1440
		LOD.setDestination(npc, homePosition(npc))
		if (npc.tier or 2) == 2 then
			LOD.teleport(npc, groundAt)
		end
		return npc.name .. " is going home"
	end
	if not NeedsActions.actions[action] then
		return "unknown action " .. action
	end
	npc.action = action
	npc.actionStarted = now
	npc.actionUntil = now + minutes / 1440
	route(npc)
	return string.format("%s is %s for %d game minutes", npc.name, NeedsActions.actions[action].verb, minutes)
end

function NPCService.setNeed(_self: any, npc: any, need: string, value: number)
	npc.needs[need] = math.clamp(value, 0, 1)
	npc.actionUntil = 0
end

function NPCService.setTrait(_self: any, npc: any, trait: string, value: number)
	npc.traits[trait] = math.clamp(value, 0, 1)
	npc.scheduleShift = ScheduleService.shift(npc)
	npc.drain = NPCBrain.drainOf(npc)
	npc.compiled = NPCBrain.compile(npc)
	npc.actionUntil = 0
end

function NPCService.setMastery(_self: any, npc: any, branch: string, value: number)
	if value <= 0 then
		npc.magic.mastery[branch] = nil
		npc.magic.unlocked[branch] = nil
	else
		npc.magic.unlocked[branch] = true
		npc.magic.mastery[branch] = math.clamp(value, 0, 100)
	end
	NPCMagicLife.refresh(npc)
	npc.compiled = NPCBrain.compile(npc)
end

-- An NPC's view of someone (an NPC id or "u:<userId>").
function NPCService.setRelation(_self: any, npc: any, subject: string, affinity: number, trust: number, player: Player?)
	local edge = RelationshipGraph.get(npc.id, subject)
	edge.affinity = math.clamp(affinity, -1, 1)
	edge.trust = math.clamp(trust, 0, 1)
	if player then
		savePlayerRelation(player, npc)
	end
end

--[[
	teacher    the NPC treats the player as their student (so lessons aren't refused as a stranger)
	apprentice the NPC treats the player as their mentor: their chapters study x1.5 in every domain
	           and they name the player as their mentor in dialogue
	none       clears either
]]
function NPCService.setBond(_self: any, npc: any, player: Player, kind: string)
	local subject = subjectOf(player.UserId)
	local edge = RelationshipGraph.get(npc.id, subject)
	if kind == "teacher" then
		edge.bond = "student"
		edge.affinity = math.max(edge.affinity, 0.45)
		edge.trust = math.max(edge.trust, 0.6)
	elseif kind == "apprentice" then
		edge.bond = "mentor"
		edge.affinity = math.max(edge.affinity, 0.5)
		edge.trust = math.max(edge.trust, 0.7)
		npc.magic.mentor = subject
	else
		edge.bond = nil
		if npc.magic.mentor == subject then
			npc.magic.mentor = nil
		end
	end
	savePlayerRelation(player, npc)
end

-- The NPC gossips with up to five nearby townsfolk now. Returns how many heard something new.
function NPCService.gossip(_self: any, npc: any): number
	local town = townById[npc.settlementId]
	if not town then
		return 0
	end
	local listeners = {}
	for _, other in town.npcs do
		if other ~= npc and not other.knockedOut then
			table.insert(listeners, { npc = other, d = (other.position - npc.position).Magnitude })
		end
	end
	table.sort(listeners, function(a, b)
		return a.d < b.d
	end)
	local now, told = WorldClock.now(), 0
	for i = 1, math.min(5, #listeners) do
		local listener = listeners[i].npc
		RelationshipGraph.onChat(npc, listener)
		if MemoryService.gossip(npc, listener, now, RelationshipGraph.get(listener.id, npc.id).trust) then
			told += 1
		end
	end
	town.dirty = true
	return told
end

function NPCService.setAmbition(_self: any, npc: any, ambitionId: string, branch: string?): boolean
	local def: any = nil
	for _, a in NpcData.ambitions do
		if a.id == ambitionId then
			def = a
		end
	end
	if not def then
		return false
	end
	local branchName = if branch and Registry.branches[branch] then Registry.branches[branch].name else "their art"
	npc.ambition = { id = def.id, text = (string.gsub(def.text, "{branch}", branchName)), kind = def.kind, branch = branch }
	npc.compiled = NPCBrain.compile(npc)
	return true
end

-- Saves, throws every NPC away and generates them again (e.g. after npc_population_mult changes).
function NPCService.rebuild(_self: any): string
	if not ready then
		return "NPCs aren't ready"
	end
	flushTowns()
	ready = false
	demoteAll()
	table.clear(towns)
	table.clear(townById)
	table.clear(byId)
	table.clear(all)
	RelationshipGraph.clear()
	boot()
	return string.format("rebuilt %d NPCs in %d towns in %d ms", #all, #towns, stats.bootMs)
end

-- Jumps this server's clock forward and lets everything catch up (needs, chapters, recovery).
function NPCService.simulateDays(_self: any, days: number): string
	WorldClock.advance(days)
	local now = WorldClock.now()
	for _, npc in all do
		npc.actionUntil = 0
	end
	recoverHour(now)
	thinkFar(now)
	advanceChapters(now)
	return string.format("advanced %.2f days to %s (chapter %d)", days, WorldClock.stamp(now), lastChapter)
end

-- A new settlement (admin spawn): its town and residents, generated like any other.
function NPCService.addTown(_self: any, settlement: Settlements.Settlement, radius: number): number
	local now = WorldClock.now()
	local town = newTown(settlement, radius, false)
	local job = Scheduler.spawn("npc town " .. settlement.id, function()
		populateTown(town, nil, now, math.floor(now / NPCMagicLife.CHAPTER_DAYS))
	end, Scheduler.Priority.Normal)
	Scheduler.await(job)
	return #town.npcs
end

-- Overlay data: every town's outline and district anchors.
function NPCService.townOutlines(_self: any): { any }
	local out = {}
	for _, town in towns do
		local districts = {}
		for _, d in ScheduleService.districts do
			local x, z = ScheduleService.districtPoint(town.place, d)
			table.insert(districts, { name = d, x = x, z = z, y = world:surfaceHeight(x, z) })
		end
		table.insert(out, { id = town.id, name = town.settlement.name, x = town.x, z = town.z, y = world:surfaceHeight(town.x, town.z), radius = town.radius, districts = districts })
	end
	return out
end

-- Overlay data: NPC positions and LOD tiers within `radius` of a point.
function NPCService.lodPoints(_self: any, center: Vector3, radius: number): { any }
	local out = {}
	for _, npc in all do
		local p = if npc.rig then npc.rig.root.Position else npc.position
		if (p - center).Magnitude <= radius then
			table.insert(out, { x = p.X, y = p.Y, z = p.Z, tier = npc.tier or 2, name = npc.name, frozen = npc.frozen == true, forced = npc.forcedTier ~= nil })
		end
	end
	return out
end

-- Where an NPC is right now (its rig if it has one).
function NPCService.positionOf(_self: any, npc: any): Vector3
	return if npc.rig then npc.rig.root.Position else npc.position
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function NPCService.init(_self: any, ctx: any)
	log, bus, flags = ctx.log, ctx.bus, ctx.flags
	worldService = ctx.get("WorldService")
	world = ctx.get("WorldStateService")
	playerData = ctx.get("PlayerDataService")
	progression = ctx.get("ProgressionService")
	events = ctx.get("EventDirector")
	runner = ctx.get("EffectRunner")
	dataService = ctx.get("DataService")
	settlementSvc = ctx.get("SettlementService")
	store = dataService:openStore(Schemas.NpcTown)
	Net.handle("NpcTalk", onTalk)

	bus:subscribe(Topics.MagicWitnessed, onWitnessed)
	bus:subscribe(Topics.MagicDamage, onDamage)
	bus:subscribe(Topics.WorldEventStarted, onEventStarted)
	bus:subscribe(Topics.WorldEventEnded, onEventEnded)
	bus:subscribe(Topics.BuildingBuilt, function(payload)
		-- Planned anchor points become real ones: re-route whoever lives or works there.
		if not ready then
			return
		end
		local town = townById[payload.settlementId]
		for _, npc in (if town then town.npcs else {}) :: { any } do
			if (npc.home and npc.home.lot == payload.lotId) or (npc.work and npc.work.lot == payload.lotId) then
				route(npc)
			end
		end
	end)
	bus:subscribe(Topics.PlayerDataLoaded, function(payload)
		local state = playerData:get(payload.player)
		if state and ready then
			RelationshipGraph.loadPlayer(payload.player.UserId, state.data.relationships)
		end
	end)
	bus:subscribe(Topics.PlayerDataReleased, function(payload)
		RelationshipGraph.forgetPlayer(payload.userId)
		if payload.player then
			talkTurns[payload.player] = nil
		end
	end)
	bus:subscribe(Topics.WorldEventRecorded, function(event)
		if event.kind ~= "npc_awakened" or event.origin == game.JobId or typeof(event.data) ~= "table" then
			return
		end
		local npc = ready and byId[event.data.npc]
		if npc and npc.magic.hiddenMythic == event.data.domain then
			awaken(npc, "news from afar", false, tonumber(event.data.day))
		end
	end)
	bus:subscribe(Topics.FlagChanged, function(payload)
		if payload.name == "npc_day_seconds" and ready then
			WorldClock.setDaySeconds(tonumber(payload.value) or 1440)
			log:warn("npc_clock_changed", { daySeconds = payload.value, clock = WorldClock.stamp() })
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		talkTurns[player] = nil
	end)
	game:BindToClose(function()
		if ready then
			flushTowns()
		end
	end)
end

function NPCService.start(_self: any, _ctx: any)
	-- Nothing is generated while the flag is off; flipping it on later boots the NPCs then.
	if not flags.get("npc_enabled") then
		log:info("npcs_disabled", {})
		repeat
			task.wait(5)
		until flags.get("npc_enabled")
	end
	worldSeed = worldService:getSeed()
	epoch = worldService:getEpoch()
	NPCCombat.init(worldSeed, runner)
	-- NPCs' innate resistances: their affinities and traits (Cast/Resistances "innate" source).
	Resistances.setInnateProvider(function(humanoid: Humanoid)
		local model = humanoid.Parent
		local npc = model and byId[model:GetAttribute("NpcId") :: any]
		if not npc or not npc.magic or not npc.magic.caster then
			return nil
		end
		if npc.resistChapter ~= npc.magic.chapter or not npc.resist then
			npc.resist = Resistances.innateFor(npc.magic.caster.affinities, npc.traits)
			npc.resistChapter = npc.magic.chapter
		end
		return npc.resist
	end)
	if dataService:isMock() then
		-- The mock store makes a new world every Play, whose clock would start at midnight.
		local hour = math.clamp(tonumber(flags.get("npc_studio_start_hour")) or 0, 0, 23)
		epoch -= hour / 24 * (tonumber(flags.get("npc_day_seconds")) or 1440)
	end
	WorldClock.setup(epoch, tonumber(flags.get("npc_day_seconds")) or 1440)
	world:awaitReady()

	local worker = ServerStorage:FindFirstChild("Workers") and (ServerStorage :: any).Workers:FindFirstChild("NpcScoringWorker")
	if worker and worker:IsA("Script") then
		pool = ParallelPool.new("NpcScoring", worker, 4)
	end

	boot()
	LOD.prewarm(math.min(#all, 48))
	LOD.startPathWorker()
	heartbeat()
	task.spawn(hourly)
	while true do
		task.wait(SAVE_INTERVAL)
		flushTowns()
	end
end

return NPCService
