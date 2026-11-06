--!strict
--[[
	SharedEventService: server-wide events on a shared clock (docs/Social.md "Shared events").
	Content: Shared/Social/Data/SharedEvents, Social/Data/EventEnemies. Decisions: Social/EventRules.

	CLOCK    Every server computes the same slot from os.time() and the same plan from the world seed,
	         so all servers run the same event at the same time without talking to each other. Each
	         server's fight is its own: contribution never carries between servers.
	PHASES   warning -> fight -> ended (recap) -> none. A server booting part-way joins only if
	         joinShare of the fight remains.
	ENEMIES  Built only once a player is within spawnRadius and the chunk is built, so an event nobody
	         visits costs nothing and ends as "passed". At most maxEnemies alive. Straight-line movement,
	         with a short hop when a raider gets stuck on a building. Enemies carry the SharedEvent
	         attribute, and CreatureRig's Creature attribute (hitting them is never a crime).
	ATTACKS  Telegraphed: a cue draws the warning on nearby clients, the server applies the damage after
	         the delay to whoever is still inside. The cue never decides who gets hit.
	SCORING  Damage to this event's enemies, healing other players in the zone (capped per second), and
	         presence if you acted recently. Tier relative to the top score at the end.
	PAYING   data.sharedEvents.claimed[event id], in the session-locked save, is checked before paying
	         and written together with the reward, so hopping servers can't pay twice. Someone who leaves
	         before the end gets nothing from this server (and may still earn it on another).

	Remotes: RequestSharedEvent, SharedEventState, SharedEventScore, SharedEventCue.
	Admin: sharedevent start | end | win | status | schedule.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local S = require(Shared.Social.Data.SharedEvents)

local Server = script.Parent.Parent
local EventRules = require(Server.Social.EventRules)
local EventEnemies = require(Server.Social.Data.EventEnemies)
local CreatureRig = require(Server.Creatures.CreatureRig)
local Damage = require(Server.Magic.Cast.Damage)
local TimeZones = require(Server.Magic.Cast.TimeZones)
local WorldConfig = require(Server.World.WorldConfig)
local Util = require(Server.Admin.Util)

local STEP_SECONDS = 0.25
local MOVE_EVERY = 0.5 -- seconds between MoveTo calls per enemy
local CUE_MARGIN = 350 -- studs past the zone that still get cues
local STUCK_SECONDS = 5
local STUCK_HOP = 12
local FADE_SECONDS = 1.2

local SharedEventService = {
	name = "SharedEventService",
	dependencies = { "AdminService", "EffectRunner", "InventoryService", "PlayerDataService", "ProgressionService", "WorldService", "WorldStateService" },
}

type EnemyState = {
	spec: EventEnemies.Enemy,
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	nextAttack: number,
	nextBite: number,
	nextMove: number,
	lastPosition: Vector3,
	lastCheck: number,
	stuckFor: number,
}

type Telegraph = {
	at: number, -- os.clock() when it lands
	position: Vector3,
	radius: number,
	damage: number,
	style: string,
	domain: string,
	level: number,
}

type Active = {
	id: string, -- also the claim key
	typeId: string,
	place: string,
	x: number,
	z: number,
	center: Vector3?, -- ground position, known once the chunk is built
	phase: string, -- "warning" | "fight" | "ended"
	warnEnds: number, -- os.time()
	endsAt: number,
	variant: number,
	rng: Random,
	scores: { [number]: EventRules.Score },
	enemies: { EnemyState },
	telegraphs: { Telegraph },
	peak: number, -- most players ever in the zone: health only scales up
	spawned: boolean,
	progress: number,
	goal: number,
	detail: string?,
	-- Siege
	wave: number,
	nextWave: number,
	waveExtra: number,
	breaches: number,
	-- Comet
	impactAt: number?,
	lastSent: string,
	result: string?,
}

type PlayerView = { player: Player, humanoid: Humanoid, position: Vector3 }

local log: any = nil
local bus: any = nil
local world: any = nil
local worldService: any = nil
local inventory: any = nil
local playerData: any = nil
local progression: any = nil

local current: Active? = nil
local handledSlot = -1
local towns: { EventRules.Town } = {}
local folder: Folder? = nil
local terrainParams: RaycastParams? = nil
local forcedCount = 0

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function enabled(): boolean
	return FeatureFlags.get("shared_events_enabled") == true
end

local function flat(a: Vector3, x: number, z: number): number
	return Vector3.new(a.X - x, 0, a.Z - z).Magnitude
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

-- Dry built terrain at (x, z), or nil.
local function groundAt(x: number, z: number): Vector3?
	local params = terrainParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { workspace.Terrain }
		params.IgnoreWater = false
		terrainParams = params
	end
	local top = world:surfaceHeight(x, z) + 40
	local result = workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, -140, 0), params :: RaycastParams)
	if not result or result.Material == Enum.Material.Water then
		return nil
	end
	return result.Position
end

-- Everyone close enough to see this event's warnings.
local function watchers(active: Active): { Player }
	local reach = S.types[active.typeId].radius + CUE_MARGIN
	local out: { Player } = {}
	for _, view in livingPlayers() do
		if flat(view.position, active.x, active.z) <= reach then
			table.insert(out, view.player)
		end
	end
	return out
end

local function cue(active: Active, payload: { [string]: any })
	Net.fireList("SharedEventCue", watchers(active), payload)
end

-- os.time() is what the schedule runs on; clients count down on the synced server clock.
local function clientTime(t: number): number
	return workspace:GetServerTimeNow() + (t - os.time())
end

local function viewOf(active: Active?): { [string]: any }
	if not active then
		return { phase = "none" }
	end
	local def = S.types[active.typeId]
	return {
		id = active.id,
		type = active.typeId,
		phase = active.phase,
		name = def.name,
		text = def.text,
		goalText = def.goalText,
		place = active.place,
		x = active.x,
		z = active.z,
		radius = def.radius,
		warnEnds = clientTime(active.warnEnds),
		endsAt = clientTime(active.endsAt),
		progress = active.progress,
		goal = active.goal,
		detail = active.detail,
		result = active.result,
		started = active.spawned,
	}
end

local function pushState(active: Active)
	Net.fireAll("SharedEventState", viewOf(active))
	active.lastSent = string.format("%s|%d|%d|%s", active.phase, active.progress, active.goal, active.detail or "")
end

-- ─── Paying out ─────────────────────────────────────────────────────────────

local function bestBranch(state: any): string?
	local best, bestXp = nil, -1
	for branchId in state.data.progression.unlocked do
		local xp = state.data.progression.xp[branchId] or 0
		if xp > bestXp then
			best, bestXp = branchId, xp
		end
	end
	return best
end

-- Pays one player, once. Returns what their recap should say.
local function pay(active: Active, player: Player, score: EventRules.Score, top: number, won: boolean): { [string]: any }
	local mine: { [string]: any } = { points = math.floor(score.points) }
	local state = playerData:get(player)
	local tier = EventRules.tierFor(score, top)
	if not state or not tier then
		mine.reason = "too_little"
		return mine
	end
	mine.tier = tier
	local record = state.data.sharedEvents
	if not record then
		record = { claimed = {} }
		state.data.sharedEvents = record
	end
	local now = os.time()
	if EventRules.claimed(record.claimed, active.id) then
		mine.reason = "already"
		return mine
	end
	EventRules.claim(record.claimed, active.id, now)
	EventRules.pruneClaims(record.claimed, now)

	local xp, coins = EventRules.payout(tier, won)
	progression:awardQuest(player, bestBranch(state), xp)
	if coins > 0 then
		inventory:addCurrency(player, coins, "shared_event:" .. active.typeId)
	end
	local rng = Seed.random(worldService:getSeed(), "player:" .. player.UserId, "shared_event:" .. active.id)
	local given: { { item: string, n: number } } = {}
	for _, entry in EventRules.rollItems(tier, won, rng) do
		local added = inventory:give(player, entry.item, entry.n)
		if added > 0 then
			table.insert(given, { item = entry.item, n = added })
		else
			log:info("shared_event_no_room", { userId = player.UserId, item = entry.item })
		end
	end
	mine.xp, mine.coins, mine.items = xp, coins, given
	log:info("shared_event_paid", { userId = player.UserId, id = active.id, tier = tier, points = mine.points, won = won })
	return mine
end

local function destroyEnemies(active: Active)
	for _, enemy in active.enemies do
		enemy.model:Destroy()
	end
	table.clear(active.enemies)
	table.clear(active.telegraphs)
end

-- result: "won" | "failed" | "passed" (nobody came) | "cancelled" (admin or the flag: no rewards)
local function finish(active: Active, result: string)
	if active.phase == "ended" then
		return
	end
	active.phase = "ended"
	active.result = result
	destroyEnemies(active)

	local top = 0
	for _, score in active.scores do
		top = math.max(top, score.points)
	end
	local paid = 0
	for _, player in Players:GetPlayers() do
		local view = viewOf(active)
		local score = active.scores[player.UserId]
		if score and (result == "won" or result == "failed") then
			view.mine = pay(active, player, score, top, result == "won")
			if view.mine.xp then
				paid += 1
			end
		end
		Net.fire("SharedEventState", player, view)
	end
	active.lastSent = ""
	log:info("shared_event_ended", { id = active.id, type = active.typeId, result = result, players = paid, peak = active.peak })
	bus:publish(Topics.SharedEventEnded, { id = active.id, type = active.typeId, result = result, place = active.place, players = paid })
	task.delay(S.recapSeconds, function()
		if current == active then
			current = nil
			Net.fireAll("SharedEventState", { phase = "none" })
		end
	end)
end

-- ─── Enemies ────────────────────────────────────────────────────────────────

local function spawnEnemy(active: Active, spec: EventEnemies.Enemy, ground: Vector3): EnemyState?
	if #active.enemies >= S.maxEnemies then
		return nil
	end
	local def = spec.def
	local height = def.hipHeight + def.hitbox.Y / 2 + 0.5
	local model, humanoid, root = CreatureRig.build(def, CFrame.new(ground + Vector3.new(0, height, 0)))
	model:SetAttribute("SharedEvent", active.id)
	local health = EventRules.healthFor(def.health, active.peak)
	humanoid.MaxHealth = health
	humanoid.Health = health
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOn
	humanoid.NameDisplayDistance = 120
	humanoid.HealthDisplayDistance = 120
	root.Anchored = spec.static
	model.Parent = folder
	if not spec.static then
		pcall(function()
			root:SetNetworkOwner(nil) -- server-driven: a nearby client can't own (and teleport) it
		end)
	end
	local now = os.clock()
	local enemy: EnemyState = {
		spec = spec,
		model = model,
		humanoid = humanoid,
		root = root,
		-- Staggered, so three nodes don't all strike on the same beat.
		nextAttack = now + 2 + active.rng:NextNumber() * (if spec.attack then spec.attack.cooldown else 0),
		nextBite = 0,
		nextMove = 0,
		lastPosition = root.Position,
		lastCheck = now,
		stuckFor = 0,
	}
	table.insert(active.enemies, enemy)
	return enemy
end

-- A dry spot on a ring round the centre: tries a few angles, then settles for the centre.
local function ringSpot(active: Active, center: Vector3, radius: number, angle: number): Vector3
	for i = 0, 5 do
		local a = angle + i * 0.9
		local ground = groundAt(center.X + math.cos(a) * radius, center.Z + math.sin(a) * radius)
		if ground then
			return ground
		end
	end
	return center + Vector3.new(active.rng:NextNumber() * 6 - 3, 0, active.rng:NextNumber() * 6 - 3)
end

local function spawnWave(active: Active, center: Vector3)
	local waves = EventEnemies.siege.waves
	active.wave += 1
	local size = waves[active.wave] + active.waveExtra
	for _ = 1, size do
		local angle = active.rng:NextNumber() * 2 * math.pi
		spawnEnemy(active, EventEnemies.raider, ringSpot(active, center, EventEnemies.siege.spawnDistance, angle))
	end
	active.nextWave = os.clock() + EventEnemies.siege.waveGap
end

local function spawnRing(active: Active, center: Vector3, spec: EventEnemies.Enemy, count: number)
	local start = active.rng:NextNumber() * 2 * math.pi
	for i = 1, count do
		local angle = start + (i / count) * 2 * math.pi
		spawnEnemy(active, spec, ringSpot(active, center, EventEnemies.ringRadius, angle))
	end
end

-- The first enemies, once someone is near and the ground exists. Returns false to try again later.
local function trySpawn(active: Active, inZonePlayers: number): boolean
	local nearby = false
	for _, view in livingPlayers() do
		if flat(view.position, active.x, active.z) <= S.spawnRadius then
			nearby = true
			break
		end
	end
	if not nearby or not world:isChunkBuilt(active.x, active.z) then
		return false
	end
	local center = groundAt(active.x, active.z)
	if not center then
		return false
	end
	active.center = center
	active.spawned = true
	active.peak = math.max(active.peak, inZonePlayers, 1)
	if active.typeId == "elemental" then
		local list = EventEnemies.elementals
		spawnEnemy(active, list[active.variant % #list + 1], center)
		active.goal = 100
	elseif active.typeId == "storm" then
		spawnRing(active, center, EventEnemies.node, EventEnemies.nodes)
		active.goal = EventEnemies.nodes
	elseif active.typeId == "siege" then
		local siege = EventEnemies.siege
		active.waveExtra = math.min(siege.maxExtra, active.peak // siege.extraPerPlayers)
		local total = 0
		for _, size in siege.waves do
			total += size + active.waveExtra
		end
		active.goal = total
		spawnWave(active, center)
	else -- comet: the fall first, the shards when it lands
		active.goal = EventEnemies.comet.shards
		active.impactAt = os.clock() + EventEnemies.comet.fallSeconds
		cue(active, { kind = "comet", x = center.X, y = center.Y, z = center.Z, radius = EventEnemies.comet.impactRadius, duration = EventEnemies.comet.fallSeconds })
	end
	log:info("shared_event_spawned", { id = active.id, type = active.typeId, enemies = #active.enemies, peak = active.peak })
	return true
end

-- ─── Attacks ────────────────────────────────────────────────────────────────

local function telegraph(active: Active, position: Vector3, attack: EventEnemies.Attack, domain: string, level: number)
	table.insert(active.telegraphs, {
		at = os.clock() + attack.delay,
		position = position,
		radius = attack.radius,
		damage = attack.damage,
		style = attack.style,
		domain = domain,
		level = level,
	})
	cue(active, { kind = "telegraph", style = attack.style, x = position.X, y = position.Y, z = position.Z, radius = attack.radius, duration = attack.delay })
end

local function hitArea(position: Vector3, radius: number, amount: number, domain: string, level: number, players: { PlayerView })
	for _, view in players do
		if flat(view.position, position.X, position.Z) <= radius and math.abs(view.position.Y - position.Y) <= 30 then
			Damage.apply(view.humanoid, amount, nil, "shared_event", { domain = domain, from = position, form = "burst", power = level })
		end
	end
end

local function landTelegraphs(active: Active, players: { PlayerView }, now: number)
	for i = #active.telegraphs, 1, -1 do
		local t = active.telegraphs[i]
		if TimeZones.stopped(t.position) then
			t.at += STEP_SECONDS -- a Timestop: the blow hangs until time resumes
		elseif now >= t.at then
			table.remove(active.telegraphs, i)
			hitArea(t.position, t.radius, t.damage, t.domain, t.level, players)
			cue(active, { kind = "impact", style = t.style, x = t.position.X, y = t.position.Y, z = t.position.Z, radius = t.radius })
		end
	end
end

-- ─── Stepping enemies ───────────────────────────────────────────────────────

local function nearestPlayer(position: Vector3, players: { PlayerView }, within: number): (PlayerView?, number)
	local best: PlayerView? = nil
	local bestDistance = within
	for _, view in players do
		local d = flat(view.position, position.X, position.Z)
		if d <= bestDistance then
			best, bestDistance = view, d
		end
	end
	return best, bestDistance
end

local function bite(enemy: EnemyState, target: PlayerView, distance: number, now: number)
	local b = enemy.spec.def.bite
	if not b or distance > b.reach or now < enemy.nextBite then
		return
	end
	enemy.nextBite = now + b.cooldown
	Damage.apply(target.humanoid, b.damage, nil, "shared_event_bite", {
		domain = enemy.spec.def.domain,
		from = enemy.root.Position,
		property = b.property,
		form = "touch",
		power = enemy.spec.def.level,
		attacker = enemy.model,
	})
end

local function moveTo(enemy: EnemyState, goal: Vector3, now: number)
	if now >= enemy.nextMove then
		enemy.nextMove = now + MOVE_EVERY
		enemy.humanoid:MoveTo(goal)
	end
end

local function stepBoss(active: Active, enemy: EnemyState, center: Vector3, players: { PlayerView }, now: number)
	local position = enemy.root.Position
	local reach = S.types[active.typeId].radius
	local target, distance = nearestPlayer(position, players, reach * 1.3)
	if not target or flat(position, center.X, center.Z) > reach then
		moveTo(enemy, center, now)
		return
	end
	moveTo(enemy, target.position, now)
	bite(enemy, target, distance, now)
	local attack = enemy.spec.attack
	if attack and now >= enemy.nextAttack then
		-- Faster once it's badly hurt, so the end of the fight feels different from the start.
		local hurt = enemy.humanoid.Health < enemy.humanoid.MaxHealth * 0.5
		enemy.nextAttack = now + attack.cooldown * (if hurt then 0.7 else 1)
		telegraph(active, target.position, attack, enemy.spec.def.domain, enemy.spec.def.level)
	end
end

-- Nodes strike anyone in the zone. Shards only pulse at someone standing close.
local function stepStatic(active: Active, enemy: EnemyState, players: { PlayerView }, now: number)
	local attack = enemy.spec.attack
	if not attack or now < enemy.nextAttack then
		return
	end
	if active.typeId == "storm" then
		local reach = S.types[active.typeId].radius
		local inZone: { PlayerView } = {}
		for _, view in players do
			if flat(view.position, active.x, active.z) <= reach then
				table.insert(inZone, view)
			end
		end
		if #inZone > 0 then
			enemy.nextAttack = now + attack.cooldown
			telegraph(active, inZone[active.rng:NextInteger(1, #inZone)].position, attack, enemy.spec.def.domain, enemy.spec.def.level)
		end
	else
		local target = nearestPlayer(enemy.root.Position, players, EventEnemies.pulseRange)
		if target then
			enemy.nextAttack = now + attack.cooldown
			telegraph(active, enemy.root.Position, attack, enemy.spec.def.domain, enemy.spec.def.level)
		end
	end
end

-- Returns true if this raider got through to the plaza.
local function stepRaider(enemy: EnemyState, center: Vector3, players: { PlayerView }, now: number): boolean
	local position = enemy.root.Position
	if flat(position, center.X, center.Z) <= EventEnemies.siege.plazaRadius then
		return true
	end
	local target, distance = nearestPlayer(position, players, EventEnemies.raiderAggro)
	if target then
		moveTo(enemy, target.position, now)
		bite(enemy, target, distance, now)
		enemy.stuckFor = 0
		return false
	end
	moveTo(enemy, center, now)
	-- Straight lines meet buildings. Stuck for a while: hop forward (a raider isn't worth pathfinding).
	if now - enemy.lastCheck >= 1 then
		local moved = (position - enemy.lastPosition).Magnitude
		enemy.lastPosition, enemy.lastCheck = position, now
		enemy.stuckFor = if moved < 1.5 then enemy.stuckFor + 1 else 0
		if enemy.stuckFor >= STUCK_SECONDS then
			enemy.stuckFor = 0
			local away = Vector3.new(center.X - position.X, 0, center.Z - position.Z)
			if away.Magnitude > 0.1 then
				local to = position + away.Unit * STUCK_HOP
				local ground = groundAt(to.X, to.Z)
				if ground then
					local def = enemy.spec.def
					enemy.model:PivotTo(CFrame.new(ground + Vector3.new(0, def.hipHeight + def.hitbox.Y / 2 + 0.5, 0)))
				end
			end
		end
	end
	return false
end

local function fadeOut(enemy: EnemyState)
	enemy.root.Anchored = true
	local model = enemy.model
	for _, child in model:GetChildren() do
		if child:IsA("ParticleEmitter") then
			child.Enabled = false
		end
	end
	task.delay(FADE_SECONDS, function()
		model:Destroy()
	end)
end

-- Advances every enemy and removes the dead. Returns how many were defeated and how many got through.
local function stepEnemies(active: Active, center: Vector3, players: { PlayerView }, now: number): (number, number)
	local defeated, through = 0, 0
	for i = #active.enemies, 1, -1 do
		local enemy = active.enemies[i]
		local lost = not enemy.model.Parent or enemy.root.Position.Y < WorldConfig.SEA_LEVEL - 60
		if lost or enemy.humanoid.Health <= 0 then
			-- Removed from outside or fell out of the world: it counts as gone, so the event can't hang.
			table.remove(active.enemies, i)
			defeated += 1
			if not lost then
				fadeOut(enemy)
			else
				enemy.model:Destroy()
			end
		elseif not enemy.humanoid:GetAttribute("KnockedDown") and not enemy.model:GetAttribute("GravityHeld") then
			if enemy.spec.static then
				stepStatic(active, enemy, players, now)
			elseif enemy.spec == EventEnemies.raider then
				if stepRaider(enemy, center, players, now) then
					table.remove(active.enemies, i)
					through += 1
					enemy.model:Destroy()
				end
			else
				stepBoss(active, enemy, center, players, now)
			end
		end
	end
	return defeated, through
end

-- ─── One event's step ───────────────────────────────────────────────────────

local function stepEvent(active: Active, now: number)
	local center = active.center
	if not center or not active.spawned then
		return
	end
	local players = livingPlayers()
	landTelegraphs(active, players, now)

	-- The comet lands: damage, then the shards.
	local impactAt = active.impactAt
	if impactAt and TimeZones.stopped(center) then
		active.impactAt = impactAt + STEP_SECONDS
		return -- the comet hangs in the sky
	end
	if impactAt and now >= impactAt then
		active.impactAt = nil
		local c = EventEnemies.comet
		hitArea(center, c.impactRadius, c.impactDamage, "energy", 4, players)
		cue(active, { kind = "impact", style = "comet", x = center.X, y = center.Y, z = center.Z, radius = c.impactRadius })
		spawnRing(active, center, EventEnemies.shard, c.shards)
		return
	end
	if active.impactAt then
		return -- still falling
	end

	local defeated, through = stepEnemies(active, center, players, now)
	if active.typeId == "elemental" then
		local boss = active.enemies[1]
		if boss then
			active.progress = math.floor((1 - boss.humanoid.Health / boss.humanoid.MaxHealth) * 100)
		else
			active.progress = 100
			finish(active, "won")
		end
	elseif active.typeId == "siege" then
		active.progress += defeated + through
		active.breaches += through
		local siege = EventEnemies.siege
		active.detail = string.format("Wave %d of %d · %d of %d through", active.wave, #siege.waves, active.breaches, siege.breachLimit)
		if active.breaches >= siege.breachLimit then
			finish(active, "failed")
		elseif active.wave < #siege.waves and (#active.enemies == 0 or now >= active.nextWave) then
			spawnWave(active, center)
		elseif active.wave >= #siege.waves and #active.enemies == 0 then
			finish(active, "won")
		end
	else
		active.progress += defeated
		if #active.enemies == 0 then
			finish(active, "won")
		end
	end
end

-- Once a second: time, the zone, scaling, scores, and telling clients about changes.
local function secondTick(active: Active)
	local now = os.clock()
	local time = os.time()
	if active.phase == "warning" then
		if time >= active.warnEnds then
			active.phase = "fight"
			pushState(active)
		end
		return
	end
	if active.phase ~= "fight" then
		return
	end
	if time >= active.endsAt then
		finish(active, if active.spawned then "failed" else "passed")
		return
	end

	local radius = S.types[active.typeId].radius
	local inZone: { [number]: boolean } = {}
	local count = 0
	for _, view in livingPlayers() do
		if flat(view.position, active.x, active.z) <= radius then
			inZone[view.player.UserId] = true
			count += 1
		end
	end
	if not active.spawned then
		trySpawn(active, count)
	end

	-- Scaling: only up, and only by the difference, so damage already dealt still counts.
	if count > active.peak then
		active.peak = count
		for _, enemy in active.enemies do
			local maxHealth, health = EventRules.raise(enemy.humanoid.MaxHealth, enemy.humanoid.Health, EventRules.healthFor(enemy.spec.def.health, count))
			enemy.humanoid.MaxHealth = maxHealth
			enemy.humanoid.Health = health
		end
	end

	if active.spawned then
		for userId in inZone do
			if not active.scores[userId] then
				active.scores[userId] = EventRules.newScore()
			end
		end
		local top = 0
		for _, score in active.scores do
			top = math.max(top, score.points)
		end
		for userId, score in active.scores do
			local here = inZone[userId] == true
			EventRules.tickScore(score, here, now)
			local player = Players:GetPlayerByUserId(userId)
			if player and (here or score.points > 0) then
				Net.fire("SharedEventScore", player, { points = math.floor(score.points), tier = EventRules.tierFor(score, top), seconds = score.seconds, inZone = here })
			end
		end
	end

	local sent = string.format("%s|%d|%d|%s", active.phase, active.progress, active.goal, active.detail or "")
	if sent ~= active.lastSent then
		pushState(active)
	end
end

-- ─── Starting ───────────────────────────────────────────────────────────────

local function begin(id: string, typeId: string, place: string, x: number, z: number, warnEnds: number, endsAt: number, variant: number): Active
	local active: Active = {
		id = id,
		typeId = typeId,
		place = place,
		x = x,
		z = z,
		center = nil,
		phase = if os.time() < warnEnds then "warning" else "fight",
		warnEnds = warnEnds,
		endsAt = endsAt,
		variant = variant,
		rng = Seed.random(worldService:getSeed(), id, "shared_event_run"),
		scores = {},
		enemies = {},
		telegraphs = {},
		peak = 1,
		spawned = false,
		progress = 0,
		goal = 1,
		detail = nil,
		wave = 0,
		nextWave = 0,
		waveExtra = 0,
		breaches = 0,
		impactAt = nil,
		lastSent = "",
		result = nil,
	}
	current = active
	pushState(active)
	log:info("shared_event_started", { id = id, type = typeId, place = place, x = math.floor(x), z = math.floor(z) })
	return active
end

local function isDry(x: number, z: number): boolean
	return world:surfaceHeight(x, z) >= WorldConfig.SEA_LEVEL + 2
end

local function planFor(slot: number): EventRules.Plan
	return EventRules.plan(worldService:getSeed(), slot, towns, isDry)
end

-- The clock: starts this slot's event if there's one to start.
local function checkSchedule()
	local time = os.time()
	local slot = EventRules.slotOf(time)
	if slot == handledSlot or current or #towns == 0 or not enabled() then
		return
	end
	handledSlot = slot
	local plan = planFor(slot)
	local timeline = EventRules.timeline(slot, plan.typeId)
	if EventRules.phaseAt(timeline, time) == "over" or not EventRules.canJoin(timeline, time) then
		return
	end
	begin("s" .. slot, plan.typeId, plan.townName, plan.x, plan.z, timeline.warnEnds, timeline.endsAt, plan.variant)
end

-- ─── Being hit, healing, acting ─────────────────────────────────────────────

local function fighting(): Active?
	local active = current
	return if active and active.phase == "fight" and active.spawned then active else nil
end

local function scoreFor(active: Active, userId: number): EventRules.Score
	local score = active.scores[userId]
	if not score then
		score = EventRules.newScore()
		active.scores[userId] = score
	end
	return score
end

local function onDamaged(payload: any)
	local active = fighting()
	local source: number? = payload.sourceUserId
	local model = payload.model
	if not active or not source or not model or model:GetAttribute("SharedEvent") ~= active.id then
		return
	end
	EventRules.addDamage(scoreFor(active, source), payload.amount, os.clock())
end

-- Healing another player who is in the zone. Healing yourself or an NPC scores nothing.
local function onHealed(payload: any)
	local active = fighting()
	local source: number? = payload.sourceUserId
	local model = payload.model
	if not active or not source or not model then
		return
	end
	local target = Players:GetPlayerFromCharacter(model)
	if not target or target.UserId == source then
		return
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and flat(root.Position, active.x, active.z) <= S.types[active.typeId].radius then
		EventRules.addHeal(scoreFor(active, source), payload.amount, os.clock())
	end
end

local function onCast(payload: any)
	local active = fighting()
	if active and payload.casterUserId then
		EventRules.noteAction(scoreFor(active, payload.casterUserId), os.clock())
	end
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "sharedevent",
		category = "Social",
		description = "Shared events: start one in front of you (10 s warning), end it with no rewards, win it (pays out), show its scores, or list the schedule",
		args = {
			{ name = "action", type = "enum", options = { "start", "end", "win", "status", "schedule" } },
			{ name = "type", type = "enum", options = table.clone(S.ids), optional = true },
		},
		handler = function(ctx: any, a: any)
			if a.action == "schedule" then
				if #towns == 0 then
					return "the world isn't ready yet"
				end
				local lines = {}
				local slot = EventRules.slotOf(os.time())
				for i = 0, 5 do
					local plan = planFor(slot + i)
					local inMinutes = math.floor(((slot + i) * S.slotSeconds - os.time()) / 60)
					table.insert(lines, string.format("%+d min  %s near %s (%.0f, %.0f)", inMinutes, plan.typeId, plan.townName, plan.x, plan.z))
				end
				return table.concat(lines, "\n")
			end
			local active = current
			if a.action == "start" then
				if not a.type then
					return "which type? " .. table.concat(S.ids, ", ")
				end
				local at = Util.ahead(ctx.player, world, 45)
				if not at then
					return "no character"
				end
				if active and active.phase ~= "ended" then
					finish(active, "cancelled")
				end
				forcedCount += 1
				local time = os.time()
				local warnEnds = time + 10
				begin(string.format("a%d_%d", time, forcedCount), a.type, "here", at.X, at.Z, warnEnds, warnEnds + S.types[a.type].duration, forcedCount)
				return string.format("%s starts in 10 s", a.type)
			end
			if not active then
				return "no event running"
			end
			if a.action == "status" then
				local lines = { string.format("%s %s at %s: %s, %d / %d, peak %d, %d enemies", active.id, active.typeId, active.place, active.phase, active.progress, active.goal, active.peak, #active.enemies) }
				for userId, score in active.scores do
					table.insert(lines, string.format("  %d: %d points (%d damage, %d healing), %d s", userId, math.floor(score.points), math.floor(score.damage), math.floor(score.healing), score.seconds))
				end
				return table.concat(lines, "\n")
			end
			finish(active, if a.action == "win" then "won" else "cancelled")
			return "ended: " .. tostring(active.result)
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function SharedEventService.init(_self: any, ctx: any)
	log, bus = ctx.log, ctx.bus
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	inventory = ctx.get("InventoryService")
	playerData = ctx.get("PlayerDataService")
	progression = ctx.get("ProgressionService")
	registerAdmin(ctx.get("AdminService"))
	Net.handle("RequestSharedEvent", function(_player: Player)
		return viewOf(current)
	end)
	bus:subscribe(Topics.TargetDamaged, onDamaged)
	bus:subscribe(Topics.TargetHealed, onHealed)
	bus:subscribe(Topics.SpellCast, onCast)
end

function SharedEventService.start(_self: any, _ctx: any)
	local parent = Instance.new("Folder")
	parent.Name = "SharedEventEnemies"
	parent.Parent = workspace
	folder = parent
	task.spawn(function()
		world:awaitReady()
		for _, settlement in world:placement().settlements do
			table.insert(towns, { id = settlement.id, name = settlement.name, x = settlement.x, z = settlement.z })
		end
		local acc = 0
		while true do
			task.wait(STEP_SECONDS)
			local active = current
			if active and active.phase ~= "ended" and not enabled() then
				finish(active, "cancelled")
			end
			if active and active.phase == "fight" then
				stepEvent(active, os.clock())
			end
			acc += STEP_SECONDS
			if acc >= 1 then
				acc = 0
				checkSchedule()
				active = current
				if active then
					secondTick(active)
				end
			end
		end
	end)
end

return SharedEventService
