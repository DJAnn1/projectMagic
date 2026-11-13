--!strict
--[[
	TitanService: huge bosses that cross the island and leave their bones behind (docs/Titans.md).
	Content: Shared/Titans/Data/Titans, Titans/Data/TitanBodies. Decisions: Titans/TitanRules. Bones: Titans/TitanBuilder.

	CLOCK     Every server computes the same slot from os.time() and the same plan from the world seed, so
	          the same Titan walks the same road everywhere without the servers talking. Its position comes
	          from how far it has walked, so a server booting part-way joins it where it should be.
	PHASES    warning -> walking -> ended (recap) -> none.
	BODY      Anchored, and carried along the road by the server, so it can't get stuck and needs no
	          pathfinding. Re-anchored every step, because spells that hold or throw a target can loosen it.
	          It's built once someone has been near, and costs one PivotTo a step until it ends.
	THE FIGHT Damage alone is slow. Three weak points move with it: breaking one bites it and makes it
	          stumble and stop. Statuses and magic reactions beside it bite too. So clever play both hurts
	          it and buys time.
	HARM      Only with someone near (activeRadius), so nothing dies unseen. Footfalls hit characters and
	          structures, capped at maxCollapses per Titan because rubble is physics. The scorched trail is
	          applied directly and never saved: it's this server's, until it restarts.
	FALLS     Whoever kills it first, on any server, writes the fall to the world store (first wins, oldest
	          out at maxFalls). Only that server commits the crater, which the terrain log then shares.
	          Others hear by message, and re-read every refreshSeconds in case they missed it.
	SCORING   Same tiers as shared events (Social/EventRules). Claimed once per Titan in the save.
	PVP       On, as everywhere (owner, 2026-11-06).
	INTENTS   None. Reading the bones is a server-side prompt. RequestTitan only asks what's going on.

	Remotes: RequestTitan, TitanState, TitanPos, TitanScore, TitanCue. Flag: titans_enabled.
	Admin: titan start | end | win | status | schedule | falls | goto | forget <userId> | clearfalls (Studio).
]]

local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local GravityRules = require(Shared.Magic.GravityRules)
local T = require(Shared.Titans.Data.Titans)

local Server = script.Parent.Parent
local PromptRouter = require(Server.Interact.PromptRouter)
local Rules = require(Server.Titans.TitanRules)
local TitanBodies = require(Server.Titans.Data.TitanBodies)
local TitanBuilder = require(Server.Titans.TitanBuilder)
local RiftRules = require(Server.Rifts.RiftRules)
local EventRules = require(Server.Social.EventRules)
local CreatureRig = require(Server.Creatures.CreatureRig)
local Damage = require(Server.Magic.Cast.Damage)
local EffectBudget = require(Server.Magic.Cast.EffectBudget)
local FireSim = require(Server.Magic.Cast.FireSim)
local TimeZones = require(Server.Magic.Cast.TimeZones)
local Schemas = require(Server.Persistence.Schemas)
local TerrainBuilder = require(Server.World.TerrainBuilder)
local TerrainDeform = require(Server.World.TerrainDeform)
local WorldConfig = require(Server.World.WorldConfig)
local Util = require(Server.Admin.Util)

local STEP_SECONDS = 0.1
local TOPIC = "TitanFalls"
local FADE_SECONDS = 2
local BOB = 1.6 -- studs its body rises and sinks with each stride
local BONE_SINK = 6 -- studs its bones lie below the generated ground

local TitanService = {
	name = "TitanService",
	dependencies = { "AdminService", "DataService", "InventoryService", "JournalService", "PlayerDataService", "ProgressionService", "WorldService", "WorldStateService" },
}

type WeakState = { def: TitanBodies.Weak, model: Model, humanoid: Humanoid, root: BasePart }

type Telegraph = {
	at: number,
	position: Vector3,
	radius: number,
	damage: number,
	style: string,
	foot: boolean,
}

type Run = {
	plan: Rules.Plan,
	kind: T.Kind,
	body: TitanBodies.Body,
	phase: string, -- "warning" | "walking" | "ended"
	warnEnds: number, -- os.time()
	walked: number,
	position: Vector3,
	facing: Vector3,
	lastDry: Vector3, -- the last place it stood on land: where it falls, if it dies wading
	model: Model?,
	humanoid: Humanoid?,
	root: BasePart?,
	weak: { WeakState },
	weakBroken: number,
	telegraphs: { Telegraph },
	stumbleUntil: number,
	nextStomp: number,
	nextLightning: number,
	nextFoot: number, -- walked distance of the next footfall
	footSide: number,
	collapses: number,
	exposedAt: { [string]: number },
	scores: { [number]: EventRules.Score },
	peak: number,
	peakPower: number,
	powerDirty: boolean,
	rng: Random,
	lastSent: string,
	result: string?,
}

type PlayerView = { player: Player, humanoid: Humanoid, position: Vector3 }

local log: any = nil
local bus: any = nil
local world: any = nil
local worldService: any = nil
local inventory: any = nil
local journal: any = nil
local playerData: any = nil
local progression: any = nil
local store: any = nil
local mockStore = false -- Studio: nothing to hear from other servers

local current: Run? = nil
local handledSlot = -1
local towns: { Rules.Town } = {}
local falls: { Rules.Fall } = {}
local landmarks: { [string]: Model } = {}
local folder: Folder? = nil
local forcedCount = 0

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function enabled(): boolean
	return FeatureFlags.get("titans_enabled") == true
end

local function storeKey(): string
	return worldService:scopedKey("titan_falls")
end

local function groundAt(x: number, z: number): number
	return math.max(world:surfaceHeight(x, z), WorldConfig.SEA_LEVEL)
end

local function livingPlayers(): { PlayerView }
	local out: { PlayerView } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
			table.insert(out, { player = player, humanoid = humanoid, position = root.Position })
		end
	end
	return out
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function watchers(run: Run): { Player }
	local out: { Player } = {}
	for _, view in livingPlayers() do
		if flatDistance(view.position, run.position) <= T.activeRadius + T.cueMargin then
			table.insert(out, view.player)
		end
	end
	return out
end

local function cue(run: Run, payload: { [string]: any })
	local list = watchers(run)
	if #list > 0 then
		Net.fireList("TitanCue", list, payload)
	end
end

local function tellNear(run: Run, text: string)
	for _, player in watchers(run) do
		Net.fire("Notify", player, text)
	end
end

local function clientTime(t: number): number
	return workspace:GetServerTimeNow() + (t - os.time())
end

local function healthShare(run: Run): number
	local humanoid = run.humanoid
	return if humanoid then math.floor(humanoid.Health / math.max(humanoid.MaxHealth, 1) * 100) else 100
end

local function viewOf(run: Run?): { [string]: any }
	if not run then
		return { phase = "none" }
	end
	return {
		id = run.plan.id,
		phase = run.phase,
		kind = run.kind.id,
		name = run.kind.name,
		text = run.kind.text,
		towns = run.plan.towns,
		x = run.position.X,
		z = run.position.Z,
		warnEnds = clientTime(run.warnEnds),
		walkedShare = math.floor(run.walked / math.max(run.plan.length, 1) * 100),
		health = healthShare(run),
		weakLeft = #run.weak,
		weakTotal = 3,
		stumbling = os.clock() < run.stumbleUntil,
		result = run.result,
	}
end

local function signature(run: Run): string
	return string.format("%s|%d|%d|%s", run.phase, healthShare(run), #run.weak, tostring(os.clock() < run.stumbleUntil))
end

local function pushState(run: Run)
	Net.fireAll("TitanState", viewOf(run))
	run.lastSent = signature(run)
end

local function scoreFor(run: Run, userId: number): EventRules.Score
	local score = run.scores[userId]
	if not score then
		score = EventRules.newScore()
		run.scores[userId] = score
	end
	return score
end

-- ─── The falls ──────────────────────────────────────────────────────────────

local function ensurePoi(fall: Rules.Fall)
	local id = "titan_fall_" .. fall.id
	if not world:placement().byId[id] then
		world:addPOI({
			id = id,
			type = "titan_fall",
			name = "Bones of " .. T.kinds[fall.kind].name,
			x = fall.x,
			z = fall.z,
			biome = "",
			radius = 60,
			hidden = false,
			grants = {},
			settlement = nil,
			hints = {},
		})
	end
end

-- Takes in the current list: map places for the new, removal for any that have faded.
local function applyFalls(list: { Rules.Fall }, announce: boolean)
	local known: { [string]: boolean } = {}
	for _, fall in falls do
		known[fall.id] = true
	end
	local keep: { [string]: boolean } = {}
	for _, fall in list do
		keep[fall.id] = true
		if T.kinds[fall.kind] then
			ensurePoi(fall)
			if announce and not known[fall.id] then
				Net.fireAll("Notify", string.format("%s Its bones are on your map, if you've walked that far.", string.format(T.kinds[fall.kind].fallText, Rules.credit(fall))))
			end
		end
	end
	for _, fall in falls do
		if not keep[fall.id] then
			world:removePOI("titan_fall_" .. fall.id)
			local model = landmarks[fall.id]
			if model then
				model:Destroy()
				landmarks[fall.id] = nil
			end
		end
	end
	falls = list
end

local function refreshFalls(announce: boolean)
	local data = store:read(storeKey())
	if typeof(data) == "table" and typeof(data.falls) == "table" then
		applyFalls(data.falls, announce)
	end
end

-- Reads the marks: a journal line, and a little XP, once per fall.
local function readBones(fall: Rules.Fall, player: Player)
	local line = string.format(T.kinds[fall.kind].fallText, Rules.credit(fall))
	Net.fire("Notify", player, line)
	local state = playerData:get(player)
	if not state then
		return
	end
	local record = state.data.titans
	if not record then
		record = { claimed = {}, visited = {} }
		state.data.titans = record
	end
	record.visited = record.visited or {}
	if record.visited[fall.id] then
		return
	end
	-- Only falls that still exist are worth remembering, so this can't grow past maxFalls.
	local still: { [string]: boolean } = {}
	for _, other in falls do
		still[other.id] = true
	end
	for id in record.visited do
		if not still[id] then
			record.visited[id] = nil
		end
	end
	record.visited[fall.id] = os.time()
	local best, bestXp = nil, -1
	for branchId in state.data.progression.unlocked do
		local xp = state.data.progression.xp[branchId] or 0
		if xp > bestXp then
			best, bestXp = branchId, xp
		end
	end
	progression:awardQuest(player, best, T.visitXp)
	journal:log(player, "discovery", line)
end

-- Bones exist only while someone is near. Every two seconds is plenty: they don't move.
local function landmarkTick()
	local views = livingPlayers()
	for _, fall in falls do
		if T.kinds[fall.kind] then
			local at = Vector3.new(fall.x, 0, fall.z)
			local nearest = math.huge
			for _, view in views do
				nearest = math.min(nearest, flatDistance(view.position, at))
			end
			local model = landmarks[fall.id]
			if model and nearest > T.landmarkSleep then
				model:Destroy()
				landmarks[fall.id] = nil
			elseif not model and nearest <= T.landmarkBuild then
				-- Sunk into the crater dug around it, which the generator's height doesn't know about.
				local built, ember = TitanBuilder.landmark(fall, worldService:getSeed(), groundAt(fall.x, fall.z) - BONE_SINK)
				landmarks[fall.id] = built
				local prompt = Instance.new("ProximityPrompt")
				prompt.ActionText = "Read the marks"
				prompt.ObjectText = "Bones of " .. T.kinds[fall.kind].name
				prompt.HoldDuration = 0.5
				prompt.MaxActivationDistance = 18
				prompt.RequiresLineOfSight = false
				prompt.Parent = ember
				PromptRouter.connect(prompt, function(player: Player)
					readBones(fall, player)
				end)
			end
		end
	end
end

-- This server killed it. If nobody got there first, this is where the world remembers it fell.
local function recordFall(run: Run)
	local at = run.lastDry
	local x, z = Rules.fallSpot(at.X, at.Z, towns)
	local top, topId = -1, 0
	local helpers = 0
	for userId, score in run.scores do
		if score.points > 0 then
			helpers += 1
			if score.points > top then
				top, topId = score.points, userId
			end
		end
	end
	local leader = Players:GetPlayerByUserId(topId)
	local record: Rules.Fall = {
		id = run.plan.id,
		kind = run.kind.id,
		x = math.floor(x),
		z = math.floor(z),
		t = os.time(),
		by = if leader then leader.Name else "someone",
		u = topId,
		n = math.max(0, helpers - 1),
	}
	task.spawn(function()
		local inserted = false
		local result = store:update(storeKey(), function(data: any): any
			if typeof(data.falls) ~= "table" then
				data.falls = {}
			end
			inserted = Rules.addFall(data.falls, table.clone(record), T.maxFalls)
			return data
		end)
		if typeof(result) ~= "table" then
			log:warn("titan_fall_not_saved", { id = record.id })
			applyFalls(falls, false)
			return
		end
		log:info("titan_fell", { id = record.id, kind = record.kind, x = record.x, z = record.z, by = record.by, first = inserted })
		applyFalls(result.falls, true)
		if not inserted then
			return -- another server's Titan fell first: its bones stand, and it dug the crater
		end
		local y = TerrainDeform.surfaceAt(world, record.x, record.z)
		if y >= WorldConfig.SEA_LEVEL + 2 then
			local ok, err = pcall(TerrainDeform.commit, world, "titan_fall", GravityRules.craterOps(record.x, y, record.z, T.craterRadius))
			if not ok then
				log:warn("titan_crater_failed", { err = err })
			end
		end
		if FeatureFlags.get("world_messaging") and not mockStore then
			pcall(function()
				MessagingService:PublishAsync(TOPIC, { origin = game.JobId })
			end)
		end
	end)
end

-- ─── Paying out ─────────────────────────────────────────────────────────────

local function pay(run: Run, player: Player, score: EventRules.Score, top: number, won: boolean): { [string]: any }
	local mine: { [string]: any } = { points = math.floor(score.points) }
	local state = playerData:get(player)
	local tier = EventRules.tierFor(score, top)
	if not state or not tier then
		mine.reason = "too_little"
		return mine
	end
	mine.tier = tier
	local record = state.data.titans
	if not record then
		record = { claimed = {}, visited = {} }
		state.data.titans = record
	end
	local now = os.time()
	if EventRules.claimed(record.claimed, run.plan.id) then
		mine.reason = "already"
		return mine
	end
	EventRules.claim(record.claimed, run.plan.id, now)
	EventRules.pruneClaims(record.claimed, now)

	local xp, coins = Rules.payout(tier, won)
	local best, bestXp = nil, -1
	for branchId in state.data.progression.unlocked do
		local amount = state.data.progression.xp[branchId] or 0
		if amount > bestXp then
			best, bestXp = branchId, amount
		end
	end
	progression:awardQuest(player, best, xp)
	if coins > 0 then
		inventory:addCurrency(player, coins, "titan:" .. run.kind.id)
	end
	local rng = Seed.random(worldService:getSeed(), "player:" .. player.UserId, "titan:" .. run.plan.id)
	local given: { { item: string, n: number, rarity: string? } } = {}
	local noRoom = false
	for _, entry in Rules.rollItems(tier, won, rng) do
		local added = inventory:give(player, entry.item, entry.n)
		if added > 0 then
			table.insert(given, { item = entry.item, n = added })
		else
			noRoom = true
		end
	end
	local gear, rarity = Rules.rollGear(tier, won, rng)
	if gear and rarity then
		if inventory:give(player, gear, 1, { rarity = rarity }) > 0 then
			table.insert(given, { item = gear, n = 1, rarity = rarity })
		else
			noRoom = true
		end
	end
	mine.xp, mine.coins, mine.items, mine.noRoom = xp, coins, given, noRoom
	if won then
		journal:log(player, "discovery", string.format("You helped bring down %s.", run.kind.name))
	end
	log:info("titan_paid", { userId = player.UserId, id = run.plan.id, tier = tier, points = mine.points, won = won, gear = gear, rarity = rarity, noRoom = noRoom })
	return mine
end

-- ─── Ending ─────────────────────────────────────────────────────────────────

local function destroyBody(run: Run, fade: boolean)
	for _, point in run.weak do
		point.model:Destroy()
	end
	table.clear(run.weak)
	local model = run.model
	run.model, run.humanoid, run.root = nil, nil, nil
	if model then
		if fade then
			task.delay(FADE_SECONDS, function()
				model:Destroy()
			end)
		else
			model:Destroy()
		end
	end
end

-- result: "won" | "failed" (reached the far coast) | "passed" (nobody came) | "cancelled" (no rewards)
local function finish(run: Run, result: string)
	if run.phase == "ended" then
		return
	end
	run.phase = "ended"
	run.result = result
	table.clear(run.telegraphs)
	if result == "won" then
		recordFall(run)
	end
	destroyBody(run, result == "won")

	local top = 0
	for _, score in run.scores do
		top = math.max(top, score.points)
	end
	local paid = 0
	for _, player in Players:GetPlayers() do
		local view = viewOf(run)
		local score = run.scores[player.UserId]
		if score and (result == "won" or result == "failed") then
			view.mine = pay(run, player, score, top, result == "won")
			if view.mine.xp then
				paid += 1
			end
		end
		Net.fire("TitanState", player, view)
	end
	log:info("titan_ended", { id = run.plan.id, kind = run.kind.id, result = result, players = paid, peak = run.peak, power = run.peakPower, walked = math.floor(run.walked), weakBroken = run.weakBroken, collapses = run.collapses })
	bus:publish(Topics.TitanEnded, { id = run.plan.id, kind = run.kind.id, result = result, players = paid })
	task.delay(T.recapSeconds, function()
		if current == run then
			current = nil
			Net.fireAll("TitanState", { phase = "none" })
		end
	end)
end

-- ─── The body ───────────────────────────────────────────────────────────────

local function healthOf(run: Run, base: number): number
	return EventRules.healthFor(base * RiftRules.powerHealth(run.peakPower), run.peak)
end

local function damageOf(run: Run, base: number): number
	return base * RiftRules.powerDamage(run.peakPower)
end

local function buildPart(run: Run, def: any, at: CFrame): (Model, Humanoid, BasePart)
	local model, humanoid, root = CreatureRig.build(def, at)
	model:SetAttribute("TitanId", run.plan.id)
	model.ModelStreamingMode = Enum.ModelStreamingMode.Persistent -- it's visible from far away, and that's the point
	local health = healthOf(run, def.health)
	humanoid.MaxHealth = health
	humanoid.Health = health
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOn
	humanoid.NameDisplayDistance = 400
	humanoid.HealthDisplayDistance = 400
	root.Anchored = true
	root.CanCollide = false -- it walks over you: its stomps are what hurt, not being shoved through a wall
	model.Parent = folder
	return model, humanoid, root
end

local function bodyFrame(run: Run): CFrame
	local p = run.position
	local stride = math.sin(run.walked / T.stride * math.pi)
	local up = Vector3.new(p.X, p.Y + TitanBodies.height / 2 + math.abs(stride) * BOB, p.Z)
	return CFrame.lookAt(up, up + run.facing)
end

local function buildBody(run: Run)
	local frame = bodyFrame(run)
	local model, humanoid, root = buildPart(run, run.body.def, frame)
	run.model, run.humanoid, run.root = model, humanoid, root
	for _, def in TitanBodies.weakPoints(run.kind) do
		local weakModel, weakHumanoid, weakRoot = buildPart(run, def.def, frame * CFrame.new(def.offset))
		table.insert(run.weak, { def = def, model = weakModel, humanoid = weakHumanoid, root = weakRoot })
	end
	log:info("titan_built", { id = run.plan.id, kind = run.kind.id, health = math.floor(humanoid.MaxHealth), peak = run.peak, power = run.peakPower })
end

local function place(run: Run)
	local frame = bodyFrame(run)
	local model, root = run.model, run.root
	if model and root then
		root.Anchored = true -- a grip or a throw may have let go of it
		model:PivotTo(frame)
	end
	for _, point in run.weak do
		point.root.Anchored = true
		point.model:PivotTo(frame * CFrame.new(point.def.offset))
	end
end

local function stumble(run: Run, seconds: number)
	run.stumbleUntil = math.max(run.stumbleUntil, os.clock() + seconds)
end

-- ─── Attacks ────────────────────────────────────────────────────────────────

local function telegraph(run: Run, position: Vector3, attack: TitanBodies.Attack, foot: boolean)
	local at = Vector3.new(position.X, groundAt(position.X, position.Z), position.Z)
	table.insert(run.telegraphs, {
		at = os.clock() + attack.delay,
		position = at,
		radius = attack.radius,
		damage = damageOf(run, attack.damage),
		style = attack.style,
		foot = foot,
	})
	cue(run, { kind = "telegraph", style = attack.style, x = at.X, y = at.Y, z = at.Z, radius = attack.radius, duration = attack.delay })
end

-- What a footfall does to the world: buildings, a fire, a scorched print. Capped, and never saved.
local function footLands(run: Run, position: Vector3)
	if run.collapses < T.maxCollapses then
		run.collapses += world:damageStructures(position, run.kind.structureRadius, run.kind.structureDamage, "titan")
	end
	if run.kind.burnsGround then
		FireSim.igniteGround(position, 1, nil, true) -- unsaved: burning out must not write to the island
	end
	if EffectBudget.takeTerrainOps(T.trailBudget) >= T.trailBudget then
		for _, from in { "Grass", "LeafyGrass" } do
			TerrainBuilder.applyOp({ i = "", k = "replace", f = from, m = "Ground", x = position.X, y = position.Y, z = position.Z, sx = 16, sy = 8, sz = 16, t = 0 } :: any)
		end
	end
end

local function landTelegraphs(run: Run, now: number)
	for i = #run.telegraphs, 1, -1 do
		local t = run.telegraphs[i]
		if TimeZones.stopped(t.position) then
			t.at += STEP_SECONDS -- a Timestop: the blow hangs until time resumes
		elseif now >= t.at then
			table.remove(run.telegraphs, i)
			-- Players and NPCs both, through Cast/Damage: nobody caused this, so PvP rules don't enter into it.
			world:damageCharacters(t.position + Vector3.new(0, 3, 0), t.radius + 4, t.damage, nil)
			cue(run, { kind = "impact", style = t.style, x = t.position.X, y = t.position.Y, z = t.position.Z, radius = t.radius })
			if t.foot then
				footLands(run, t.position)
			end
		end
	end
end

local function nearest(position: Vector3, players: { PlayerView }, within: number): PlayerView?
	local best: PlayerView? = nil
	local bestDistance = within
	for _, view in players do
		local d = flatDistance(view.position, position)
		if d <= bestDistance then
			best, bestDistance = view, d
		end
	end
	return best
end

-- ─── Stepping ───────────────────────────────────────────────────────────────

local function stepWeakPoints(run: Run)
	for i = #run.weak, 1, -1 do
		local point = run.weak[i]
		if not point.model.Parent or point.humanoid.Health <= 0 then
			table.remove(run.weak, i)
			point.model:Destroy()
			run.weakBroken += 1
			stumble(run, T.stumbleSeconds)
			local humanoid = run.humanoid
			if humanoid then
				Damage.apply(humanoid, humanoid.MaxHealth * T.breakBite, nil, "titan_break", { domain = "earth", form = "burst", power = 1 })
			end
			tellNear(run, string.format("%s breaks! %s stumbles and stops.", point.def.name, run.kind.name))
			log:info("titan_weak_broken", { id = run.plan.id, point = point.def.name })
		end
	end
end

local function stepWalking(run: Run, dt: number, now: number)
	local stopped = now < run.stumbleUntil or TimeZones.stopped(run.position)
	if not stopped then
		run.walked += run.kind.speed * dt
	end
	local x, z, dirX, dirZ, arrived = Rules.pointAt(run.plan.points, run.walked)
	if arrived then
		finish(run, if run.model then "failed" else "passed")
		return
	end
	local y = groundAt(x, z)
	run.position = Vector3.new(x, y, z)
	run.facing = Vector3.new(dirX, 0, dirZ)
	if world:surfaceHeight(x, z) >= WorldConfig.SEA_LEVEL + 2 then
		run.lastDry = run.position
	end

	local players = livingPlayers()
	if not run.model and nearest(run.position, players, T.buildRadius) then
		buildBody(run)
	end
	local humanoid = run.humanoid
	if not humanoid then
		return
	end
	if humanoid.Health <= 0 or not (run.model :: Model).Parent then
		finish(run, "won")
		return
	end
	place(run)
	stepWeakPoints(run)
	landTelegraphs(run, now)

	local target = nearest(run.position, players, T.activeRadius)
	if not target then
		return -- nobody near: it walks, and harms nothing
	end
	-- Footfalls while it walks, each warned about where the foot will land.
	if not stopped and run.walked >= run.nextFoot then
		run.nextFoot = run.walked + T.stride
		run.footSide = -run.footSide
		local side = Vector3.new(-run.facing.Z, 0, run.facing.X) * run.footSide * T.footOffset
		telegraph(run, run.position + run.facing * T.footLead + side, run.body.foot, true)
	end
	if stopped then
		return -- a stumbling Titan isn't aiming at anyone
	end
	if now >= run.nextStomp then
		local victim = nearest(run.position, players, T.zoneRadius)
		if victim then
			run.nextStomp = now + run.body.stomp.cooldown
			telegraph(run, victim.position, run.body.stomp, false)
		end
	end
	if run.kind.callsLightning and now >= run.nextLightning then
		run.nextLightning = now + run.body.lightning.cooldown
		local inRange: { PlayerView } = {}
		for _, view in players do
			if flatDistance(view.position, run.position) <= T.activeRadius then
				table.insert(inRange, view)
			end
		end
		if #inRange > 0 then
			telegraph(run, inRange[run.rng:NextInteger(1, #inRange)].position, run.body.lightning, false)
		end
	end
end

-- Once a second: scaling, scores, telling clients.
local function secondTick(run: Run)
	if run.phase == "warning" then
		if os.time() >= run.warnEnds then
			run.phase = "walking"
			pushState(run)
		end
		return
	end
	if run.phase ~= "walking" then
		return
	end
	Net.fireAll("TitanPos", { x = run.position.X, z = run.position.Z })

	local here: { [number]: boolean } = {}
	local count = 0
	for _, view in livingPlayers() do
		if flatDistance(view.position, run.position) <= T.zoneRadius then
			here[view.player.UserId] = true
			count += 1
		end
	end
	if count > run.peak or run.powerDirty then
		run.peak = math.max(run.peak, count)
		run.powerDirty = false
		local humanoid = run.humanoid
		if humanoid then
			local maxHealth, health = EventRules.raise(humanoid.MaxHealth, humanoid.Health, healthOf(run, run.body.def.health))
			humanoid.MaxHealth = maxHealth
			humanoid.Health = health
		end
		for _, point in run.weak do
			local maxHealth, health = EventRules.raise(point.humanoid.MaxHealth, point.humanoid.Health, healthOf(run, point.def.def.health))
			point.humanoid.MaxHealth = maxHealth
			point.humanoid.Health = health
		end
	end
	if run.model then
		for userId in here do
			scoreFor(run, userId)
		end
		local top = 0
		for _, score in run.scores do
			top = math.max(top, score.points)
		end
		local now = os.clock()
		for userId, score in run.scores do
			local isHere = here[userId] == true
			EventRules.tickScore(score, isHere, now)
			local player = Players:GetPlayerByUserId(userId)
			if player and (isHere or score.points > 0) then
				Net.fire("TitanScore", player, { points = math.floor(score.points), tier = EventRules.tierFor(score, top), inZone = isHere })
			end
		end
	end
	if signature(run) ~= run.lastSent then
		pushState(run)
	end
end

-- ─── Starting ───────────────────────────────────────────────────────────────

local function begin(plan: Rules.Plan, warnEnds: number, walked: number): Run
	local kind = T.kinds[plan.kind]
	local x, z, dirX, dirZ = Rules.pointAt(plan.points, walked)
	local position = Vector3.new(x, groundAt(x, z), z)
	local run: Run = {
		plan = plan,
		kind = kind,
		body = TitanBodies.bodies[plan.kind],
		phase = if os.time() < warnEnds then "warning" else "walking",
		warnEnds = warnEnds,
		walked = walked,
		position = position,
		facing = Vector3.new(dirX, 0, dirZ),
		lastDry = position,
		model = nil,
		humanoid = nil,
		root = nil,
		weak = {},
		weakBroken = 0,
		telegraphs = {},
		stumbleUntil = 0,
		nextStomp = 0,
		nextLightning = 0,
		nextFoot = walked,
		footSide = 1,
		collapses = 0,
		exposedAt = {},
		scores = {},
		peak = 1,
		peakPower = 1,
		powerDirty = false,
		rng = Seed.random(worldService:getSeed(), plan.id, "titan_run"),
		lastSent = "",
		result = nil,
	}
	current = run
	pushState(run)
	log:info("titan_started", { id = plan.id, kind = plan.kind, towns = table.concat(plan.towns, ","), length = math.floor(plan.length), walked = math.floor(walked) })
	return run
end

local function checkSchedule()
	local time = os.time()
	local slot = Rules.slotOf(time)
	if slot == handledSlot or current or #towns == 0 or not enabled() then
		return
	end
	handledSlot = slot
	local plan = Rules.plan(worldService:getSeed(), slot, towns, WorldConfig.WORLD_SIZE)
	local warnEnds = slot * T.slotSeconds + T.warnSeconds
	local walked = math.max(0, time - warnEnds) * T.kinds[plan.kind].speed
	if walked < plan.length then
		begin(plan, warnEnds, walked)
	end
end

-- ─── Being hit ──────────────────────────────────────────────────────────────

local function walking(): Run?
	local run = current
	return if run and run.phase == "walking" and run.model then run else nil
end

local function onDamaged(payload: any)
	local run = walking()
	local source: number? = payload.sourceUserId
	local model = payload.model
	if run and source and model and model:GetAttribute("TitanId") == run.plan.id then
		EventRules.addDamage(scoreFor(run, source), payload.amount, os.clock())
	end
end

local function onHealed(payload: any)
	local run = walking()
	local source: number? = payload.sourceUserId
	local model = payload.model
	if not run or not source or not model then
		return
	end
	local target = Players:GetPlayerFromCharacter(model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if target and target.UserId ~= source and root and root:IsA("BasePart") and flatDistance(root.Position, run.position) <= T.zoneRadius then
		EventRules.addHeal(scoreFor(run, source), payload.amount, os.clock())
	end
end

local function onResolved(payload: any)
	local run = walking()
	local userId: number? = payload.casterUserId
	if not run or not userId then
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or flatDistance(root.Position, run.position) > T.zoneRadius then
		return
	end
	EventRules.noteAction(scoreFor(run, userId), os.clock())
	local power: number = payload.power or 1
	if not payload.borrowed and power > run.peakPower then
		run.peakPower = power
		run.powerDirty = true
	end
end

-- Any status on it bites, so controlling it pays as well as hitting it.
local function onStatus(payload: any)
	local run = walking()
	local humanoid = run and run.humanoid
	local source: number? = payload.sourceUserId
	if not run or not humanoid or not source or payload.model ~= run.model then
		return
	end
	local status = tostring(payload.status)
	local now = os.clock()
	if now < (run.exposedAt[status] or 0) then
		return
	end
	run.exposedAt[status] = now + T.exposedCooldown
	Damage.apply(humanoid, humanoid.MaxHealth * T.exposedShare, source, "titan_exposed", { domain = "earth", form = "touch", power = 1 })
end

-- Two spells meeting beside it: it bites, and it staggers. The reaction's own cooldown limits this.
local function onReaction(payload: any)
	local run = walking()
	local humanoid = run and run.humanoid
	local position: Vector3? = payload.position
	if not run or not humanoid or typeof(position) ~= "Vector3" then
		return
	end
	if flatDistance(position, run.position) <= (payload.radius or 0) + T.reactionReach then
		stumble(run, T.reactionStumble)
		Damage.apply(humanoid, humanoid.MaxHealth * T.reactionShare, payload.owner, "titan_reaction", { domain = "earth", form = "burst", power = 1 })
		log:info("titan_reaction", { id = run.plan.id, result = payload.result, owner = payload.owner })
	end
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	local kindOptions = { "any" }
	for _, id in T.ids do
		table.insert(kindOptions, id)
	end
	admin:Register({
		name = "titan",
		category = "World",
		description = "Titans: start one near you (30 s warning, then it walks away across the world), end it (no rewards), win it (pays out, leaves bones), status, the schedule, the falls, go to it, take a name off the bones, or clear the falls (Studio only)",
		args = {
			{ name = "action", type = "enum", options = { "start", "end", "win", "status", "schedule", "falls", "goto", "forget", "clearfalls" } },
			{ name = "kind", type = "enum", options = kindOptions, optional = true }, -- "any" to skip it: titan forget any 123
			{ name = "userId", type = "number", optional = true },
		},
		handler = function(ctx: any, a: any)
			if #towns == 0 then
				return "the world isn't ready yet"
			end
			if a.action == "schedule" then
				local lines = {}
				local slot = Rules.slotOf(os.time())
				for i = 0, 5 do
					local plan = Rules.plan(worldService:getSeed(), slot + i, towns, WorldConfig.WORLD_SIZE)
					local inMinutes = math.floor(((slot + i) * T.slotSeconds - os.time()) / 60)
					table.insert(lines, string.format("%+d min  %s through %s", inMinutes, plan.kind, table.concat(plan.towns, ", ")))
				end
				return table.concat(lines, "\n")
			elseif a.action == "falls" then
				local lines = { string.format("%d falls, %d kept at most", #falls, T.maxFalls) }
				for _, fall in falls do
					table.insert(lines, string.format("%s  %s at (%d, %d), %s", fall.id, fall.kind, fall.x, fall.z, Rules.credit(fall)))
				end
				return table.concat(lines, "\n")
			elseif a.action == "forget" then
				if not a.userId then
					return "whose UserId?"
				end
				local result = store:update(storeKey(), function(data: any): any
					if typeof(data.falls) == "table" then
						Rules.scrub(data.falls, a.userId)
					end
					return data
				end)
				if typeof(result) == "table" then
					applyFalls(result.falls or {}, false)
				end
				return "their name is off the bones"
			elseif a.action == "clearfalls" then
				if not RunService:IsStudio() then
					return "Studio only: craters are saved, and clearing the list leaves them nameless"
				end
				local result = store:update(storeKey(), function(data: any): any
					data.falls = {}
					return data
				end)
				if typeof(result) == "table" then
					applyFalls({}, false)
				end
				return "cleared (craters stay)"
			end
			local run = current
			if a.action == "start" then
				local at = Util.ahead(ctx.player, world, 150)
				if not at then
					return "no character"
				end
				if run and run.phase ~= "ended" then
					finish(run, "cancelled")
				end
				forcedCount += 1
				local time = os.time()
				local plan = Rules.plan(worldService:getSeed(), time, towns, WorldConfig.WORLD_SIZE)
				plan.id = string.format("titan_a%d_%d", time, forcedCount)
				if a.kind and a.kind ~= "any" then
					plan.kind = a.kind
				end
				local angle = Random.new(time):NextNumber() * 2 * math.pi
				plan.points = Rules.forcedRoute(at.X, at.Z, angle, WorldConfig.WORLD_SIZE)
				plan.length = Rules.lengthOf(plan.points)
				plan.towns = {}
				begin(plan, time + 30, 0)
				return string.format("%s comes ashore in 30 s", plan.kind)
			end
			if not run then
				return "no Titan walking"
			end
			if a.action == "status" then
				local lines = { string.format("%s %s: %s, walked %d of %d, health %d%%, weak points %d, peak %d, power %d, collapses %d", run.plan.id, run.kind.id, run.phase, run.walked, run.plan.length, healthShare(run), #run.weak, run.peak, run.peakPower, run.collapses) }
				for userId, score in run.scores do
					table.insert(lines, string.format("  %d: %d points", userId, math.floor(score.points)))
				end
				return table.concat(lines, "\n")
			elseif a.action == "goto" then
				local ok, message = Util.teleport(ctx.player, world, run.position + run.facing * 120, true)
				return if ok then "there" else message
			end
			finish(run, if a.action == "win" then "won" else "cancelled")
			return "ended: " .. tostring(run.result)
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function TitanService.init(_self: any, ctx: any)
	log, bus = ctx.log, ctx.bus
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	inventory = ctx.get("InventoryService")
	journal = ctx.get("JournalService")
	playerData = ctx.get("PlayerDataService")
	progression = ctx.get("ProgressionService")
	store = ctx.get("DataService"):openStore(Schemas.TitanFalls)
	mockStore = ctx.get("DataService"):isMock()
	registerAdmin(ctx.get("AdminService"))
	Net.handle("RequestTitan", function(_player: Player)
		return viewOf(current)
	end)
	bus:subscribe(Topics.TargetDamaged, onDamaged)
	bus:subscribe(Topics.TargetHealed, onHealed)
	bus:subscribe(Topics.SpellResolved, onResolved)
	bus:subscribe(Topics.StatusApplied, onStatus)
	bus:subscribe(Topics.MagicReaction, onReaction)
end

-- The next Titan, if it begins within `within` seconds: where it wades ashore and when (OmenService).
-- Every server computes the same answer. The plan is cached for its slot.
local upcomingCache: { slot: number, plan: Rules.Plan }? = nil
function TitanService.upcoming(_self: any, within: number): { id: string, kind: string, x: number, z: number, startsAt: number }?
	if not enabled() or #towns == 0 then
		return nil
	end
	local now = os.time()
	local slot = Rules.slotOf(now) + 1
	local startsAt = slot * T.slotSeconds
	if startsAt - now > within then
		return nil
	end
	local cached = upcomingCache
	if not cached or cached.slot ~= slot then
		cached = { slot = slot, plan = Rules.plan(worldService:getSeed(), slot, towns, WorldConfig.WORLD_SIZE) }
		upcomingCache = cached
	end
	local plan = (cached :: { slot: number, plan: Rules.Plan }).plan
	local first = plan.points[1]
	if not first then
		return nil
	end
	return { id = plan.id, kind = plan.kind, x = first.x, z = first.z, startsAt = startsAt }
end

function TitanService.start(_self: any, _ctx: any)
	local parent = Instance.new("Folder")
	parent.Name = "Titans"
	parent.Parent = workspace
	folder = parent
	task.spawn(function()
		world:awaitReady()
		for _, poi in world:placement().pois do
			local settlement = poi.settlement
			if settlement then
				table.insert(towns, { id = settlement.id, name = settlement.name, x = poi.x, z = poi.z, radius = poi.radius })
			end
		end
		local ok, err = pcall(refreshFalls, false)
		if not ok then
			log:warn("titan_falls_read_failed", { err = err })
		end
		if FeatureFlags.get("world_messaging") and not mockStore then
			pcall(function()
				MessagingService:SubscribeAsync(TOPIC, function(message: any)
					if typeof(message.Data) == "table" and message.Data.origin ~= game.JobId then
						task.spawn(pcall, refreshFalls, true)
					end
				end)
			end)
		end
		log:info("titans_ready", { towns = #towns, falls = #falls })

		local secondAcc, landmarkAcc, refreshAcc = 0, 0, 0
		local function step()
			local run = current
			if run and run.phase ~= "ended" and not enabled() then
				finish(run, "cancelled")
			end
			if run and run.phase == "walking" then
				stepWalking(run, STEP_SECONDS, os.clock())
			end
			secondAcc += STEP_SECONDS
			if secondAcc >= 1 then
				secondAcc = 0
				checkSchedule()
				run = current
				if run then
					secondTick(run)
				end
			end
			landmarkAcc += STEP_SECONDS
			if landmarkAcc >= 2 then
				landmarkAcc = 0
				landmarkTick()
			end
		end
		while true do
			task.wait(STEP_SECONDS)
			-- One failure mustn't stop this loop: no Titan would ever walk on this server again.
			local stepOk, stepErr = pcall(step)
			if not stepOk then
				log:throttled("titan_step", 30, "Error", "titan_step_failed", { err = stepErr })
			end
			refreshAcc += STEP_SECONDS
			if refreshAcc >= T.refreshSeconds then
				refreshAcc = 0
				task.spawn(pcall, refreshFalls, true)
			end
		end
	end)
end

return TitanService
