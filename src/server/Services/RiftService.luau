--!strict
--[[
	RiftService: seeded dungeons that open in the world (docs/Rifts.md, stage 1).
	Content: Shared/Rifts/Data/RiftData, Rifts/Data/RiftEnemies. Decisions: Rifts/RiftRules. Parts: Rifts/RiftBuilder.

	CLOCK     Every server computes the same slot from os.time() and the same plan from the world seed, so
	          all servers open the same Rift at the same time without talking to each other. The run
	          itself is per server.
	PHASES    open (a portal, nobody inside yet) -> running (the clock started when someone stepped in)
	          -> ended (recap, then everyone is put back) -> none.
	POCKET    The inside is built off the island when the first person enters, and destroyed afterwards. No
	          chunk is ever built out there, no town can judge you, and WorldStateService.edit doesn't
	          persist terrain changes there, so nothing done inside touches the real world.
	ROOMS     Solved by what spells do. A SpellResolved landing in the current room is sorted by
	          RiftRules.classify into a clever answer or brute force. Nothing is ever a dead end: plain
	          attacks work, slowly. The kinds:
	            barrier  real burnable planks. A fire spell lights them (FireSim), and they're removed when
	                     they've burned out. Anything else removes them directly.
	            chasm    a bridge appears as you earn it. Getting across any other way (a blink, flight)
	                     solves it too.
	            eyes     hanging turrets. A clever cast near one shuts it; or just break it.
	            coils    fill the meter, under discharge.
	BOSS      A status of any kind bites it (exposedShare), so controlling it pays as well as hitting it.
	          It's weak to one seeded domain. Below half health it speeds up and calls for help.
	PVP       Stays on inside: the owner chose no safe zones (2026-11-06).
	SCORING   Same tiers as shared events (Social/EventRules). Clever progress is worth more points.
	PAYING    data.rifts.claimed[plan id], in the session-locked save, is checked before paying and written
	          with the reward, so hopping servers can't pay twice. Leaving the server before the end earns
	          nothing here; leaving the Rift and staying online keeps your score.
	INTENTS   None: entering and leaving are server-side ProximityPrompts. The server moves you.

	Remotes: RequestRift, RiftState, RiftScore, RiftCue. Flag: rifts_enabled.
	Admin: rift open | enter | solve | win | close | status | schedule.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local R = require(Shared.Rifts.Data.RiftData)

local Server = script.Parent.Parent
local RiftRules = require(Server.Rifts.RiftRules)
local RiftBuilder = require(Server.Rifts.RiftBuilder)
local RiftEnemies = require(Server.Rifts.Data.RiftEnemies)
local EventRules = require(Server.Social.EventRules)
local CreatureRig = require(Server.Creatures.CreatureRig)
local Damage = require(Server.Magic.Cast.Damage)
local FireSim = require(Server.Magic.Cast.FireSim)
local ThermalSim = require(Server.Magic.Cast.ThermalSim)
local TimeZones = require(Server.Magic.Cast.TimeZones)
local WorldConfig = require(Server.World.WorldConfig)
local Util = require(Server.Admin.Util)

local STEP_SECONDS = 0.25
local MOVE_EVERY = 0.5
local FADE_SECONDS = 1.2
local CLEANUP_SECONDS = 8 -- teleporting people out can wait on terrain: the pocket outlasts that
local EYE_RANGE = 80

local RiftService = {
	name = "RiftService",
	dependencies = { "AdminService", "EffectRunner", "InventoryService", "PlayerDataService", "ProgressionService", "WorldService", "WorldStateService" },
}

type EnemyState = {
	spec: RiftEnemies.Enemy,
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	nextAttack: number,
	nextBite: number,
	nextMove: number,
	room: RoomState?, -- an eye: which room's progress it counts towards
	shut: boolean, -- an eye closed by a clever cast, not broken
	shutBy: string?, -- the approach's label
}

type Telegraph = {
	at: number,
	position: Vector3,
	radius: number,
	damage: number,
	style: string,
	domain: string,
	level: number,
}

type RoomState = {
	def: R.Room,
	parts: RiftBuilder.RoomParts,
	total: number, -- planks, or eyes; 1 for rooms that fill a meter
	progress: number, -- 0..1
	cleverGain: number,
	bruteGain: number,
	removeCredit: number, -- barrier: pieces owed by gain, not yet taken
	solved: boolean,
	clever: boolean,
	label: string?, -- the last clever approach used here
	nextPulse: number,
}

type Run = {
	plan: RiftRules.Plan,
	twist: R.Twist,
	forced: boolean,
	phase: string, -- "open" | "running" | "ended"
	closesAt: number, -- os.time(): the portal fades if nobody came
	endsAt: number,
	portal: Model?,
	portalGround: Vector3?,
	interior: RiftBuilder.Interior?,
	length: number,
	rooms: { RoomState },
	roomIndex: number, -- which room is unsolved; #rooms + 1 means the arena
	cleverRooms: number,
	enemies: { EnemyState },
	telegraphs: { Telegraph },
	boss: EnemyState?,
	bossHurt: boolean,
	exposedAt: { [string]: number },
	scores: { [number]: EventRules.Score },
	peak: number,
	rng: Random,
	lastSent: string,
	result: string?,
	tornDown: boolean,
}

type PlayerView = { player: Player, humanoid: Humanoid, root: BasePart, position: Vector3 }

local log: any = nil
local bus: any = nil
local world: any = nil
local worldService: any = nil
local inventory: any = nil
local playerData: any = nil
local progression: any = nil

local current: Run? = nil
local handledSlot = -1
local towns: { RiftRules.Town } = {}
local terrainParams: RaycastParams? = nil

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function enabled(): boolean
	return FeatureFlags.get("rifts_enabled") == true
end

local function livingPlayers(): { PlayerView }
	local out: { PlayerView } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
			table.insert(out, { player = player, humanoid = humanoid, root = root, position = root.Position })
		end
	end
	return out
end

local function insidePlayers(run: Run): { PlayerView }
	local out: { PlayerView } = {}
	for _, view in livingPlayers() do
		if RiftRules.inPocket(view.position, run.length) then
			table.insert(out, view)
		end
	end
	return out
end

local function isInside(run: Run, userId: number): boolean
	for _, view in insidePlayers(run) do
		if view.player.UserId == userId then
			return true
		end
	end
	return false
end

local function cue(run: Run, payload: { [string]: any })
	local list: { Player } = {}
	for _, view in insidePlayers(run) do
		table.insert(list, view.player)
	end
	if #list > 0 then
		Net.fireList("RiftCue", list, payload)
	end
end

local function tellInside(run: Run, text: string)
	for _, view in insidePlayers(run) do
		Net.fire("Notify", view.player, text)
	end
end

local function clientTime(t: number): number
	return workspace:GetServerTimeNow() + (t - os.time())
end

local function currentRoom(run: Run): RoomState?
	return run.rooms[run.roomIndex]
end

local function viewOf(run: Run?): { [string]: any }
	if not run then
		return { phase = "none" }
	end
	local view: { [string]: any } = {
		id = run.plan.id,
		phase = run.phase,
		twistName = run.twist.name,
		twistText = run.twist.text,
		place = run.plan.townName,
		x = run.plan.x,
		z = run.plan.z,
		closesAt = clientTime(run.closesAt),
		endsAt = clientTime(run.endsAt),
		pocketLength = run.length,
		roomIndex = run.roomIndex,
		roomCount = #run.rooms,
		cleverRooms = run.cleverRooms,
		result = run.result,
	}
	local room = currentRoom(run)
	if room then
		view.roomName = room.def.name
		view.roomText = room.def.text
		view.roomHint = room.def.hint
		view.progress = math.floor(room.progress * 100)
	elseif run.boss then
		view.bossHealth = math.floor(run.boss.humanoid.Health / run.boss.humanoid.MaxHealth * 100)
		view.bossWeakness = run.plan.bossWeakness
	end
	return view
end

local function signature(run: Run): string
	local room = currentRoom(run)
	local boss = run.boss
	return string.format(
		"%s|%d|%d|%d",
		run.phase,
		run.roomIndex,
		if room then math.floor(room.progress * 100) else -1,
		if boss then math.floor(boss.humanoid.Health / boss.humanoid.MaxHealth * 100) else -1
	)
end

local function pushState(run: Run)
	Net.fireAll("RiftState", viewOf(run))
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

-- ─── Moving people ──────────────────────────────────────────────────────────

-- Held in place until the pocket has streamed in, or they'd fall through a floor they can't see yet.
local function moveInto(player: Player, to: CFrame)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not root or not root:IsA("BasePart") then
		return
	end
	root.Anchored = true
	character:PivotTo(to)
	task.spawn(function()
		pcall(function()
			player:RequestStreamAroundAsync(to.Position, 5)
		end)
		if root.Parent then
			root.Anchored = false
			root.AssemblyLinearVelocity = Vector3.zero
		end
	end)
end

local function putBack(run: Run, player: Player)
	local target = run.portalGround
	local x, y, z
	if target then
		x, y, z = target.X + 14, target.Y, target.Z
	else
		x, y, z = world:findDryLand(run.plan.x, run.plan.z, 96)
	end
	task.spawn(function()
		local ok, err = pcall(Util.teleport, player, world, Vector3.new(x, y + 4, z), false)
		if not ok then
			log:warn("rift_put_back_failed", { userId = player.UserId, err = err })
		end
	end)
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

local function pay(run: Run, player: Player, score: EventRules.Score, top: number, won: boolean): { [string]: any }
	local mine: { [string]: any } = { points = math.floor(score.points) }
	local state = playerData:get(player)
	local tier = EventRules.tierFor(score, top)
	if not state or not tier then
		mine.reason = "too_little"
		return mine
	end
	mine.tier = tier
	local record = state.data.rifts
	if not record then
		record = { claimed = {} }
		state.data.rifts = record
	end
	local now = os.time()
	if EventRules.claimed(record.claimed, run.plan.id) then
		mine.reason = "already"
		return mine
	end
	EventRules.claim(record.claimed, run.plan.id, now)
	EventRules.pruneClaims(record.claimed, now)

	local xp, coins = RiftRules.payout(tier, won, run.cleverRooms)
	progression:awardQuest(player, bestBranch(state), xp)
	if coins > 0 then
		inventory:addCurrency(player, coins, "rift:" .. run.twist.id)
	end
	local rng = Seed.random(worldService:getSeed(), "player:" .. player.UserId, "rift:" .. run.plan.id)
	local given: { { item: string, n: number, rarity: string? } } = {}
	local noRoom = false
	for _, entry in RiftRules.rollItems(tier, won, rng) do
		local added = inventory:give(player, entry.item, entry.n)
		if added > 0 then
			table.insert(given, { item = entry.item, n = added })
		else
			noRoom = true
		end
	end
	local gear, rarity = RiftRules.rollBossLoot(tier, won, run.cleverRooms, rng)
	if gear and rarity then
		if inventory:give(player, gear, 1, { rarity = rarity }) > 0 then
			table.insert(given, { item = gear, n = 1, rarity = rarity })
		else
			noRoom = true
		end
	end
	mine.xp, mine.coins, mine.items, mine.noRoom = xp, coins, given, noRoom
	log:info("rift_paid", { userId = player.UserId, id = run.plan.id, tier = tier, points = mine.points, won = won, clever = run.cleverRooms, gear = gear, rarity = rarity, noRoom = noRoom })
	return mine
end

-- ─── Ending ─────────────────────────────────────────────────────────────────

local function teardown(run: Run)
	if run.tornDown then
		return -- an admin re-open already did it: a second sweep would throw people out of the new run
	end
	run.tornDown = true
	for _, view in insidePlayers(run) do
		putBack(run, view.player)
	end
	if run.portal then
		run.portal:Destroy()
		run.portal = nil
	end
	local interior = run.interior
	run.interior = nil
	if interior then
		task.delay(CLEANUP_SECONDS, function()
			interior.folder:Destroy()
		end)
	end
	if current == run then
		current = nil
		Net.fireAll("RiftState", { phase = "none" })
	end
end

-- result: "won" | "failed" (out of time) | "faded" (nobody came) | "cancelled" (admin or the flag: no rewards)
local function finish(run: Run, result: string)
	if run.phase == "ended" then
		return
	end
	run.phase = "ended"
	run.result = result
	for _, enemy in run.enemies do
		enemy.model:Destroy()
	end
	table.clear(run.enemies)
	table.clear(run.telegraphs)
	run.boss = nil
	if run.portal then
		run.portal:Destroy()
		run.portal = nil
	end

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
		Net.fire("RiftState", player, view)
	end
	run.lastSent = ""
	log:info("rift_ended", { id = run.plan.id, twist = run.twist.id, result = result, players = paid, peak = run.peak, clever = run.cleverRooms, rooms = run.roomIndex - 1 })
	bus:publish(Topics.RiftEnded, { id = run.plan.id, result = result, place = run.plan.townName, players = paid, clever = run.cleverRooms })
	task.delay(if result == "won" then R.recapSeconds else R.failPullSeconds, function()
		teardown(run)
	end)
end

-- ─── Enemies ────────────────────────────────────────────────────────────────

local function spawnEnemy(run: Run, spec: RiftEnemies.Enemy, at: CFrame, room: RoomState?): EnemyState?
	local interior = run.interior
	if not interior then
		return nil
	end
	local def = spec.def
	local model, humanoid, root = CreatureRig.build(def, at)
	model:SetAttribute("RiftEnemy", run.plan.id)
	local health = EventRules.healthFor(def.health * (run.twist.enemyHealth or 1), run.peak)
	humanoid.MaxHealth = health
	humanoid.Health = health
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOn
	humanoid.NameDisplayDistance = 90
	humanoid.HealthDisplayDistance = 90
	root.Anchored = spec.static
	model.Parent = interior.folder
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
		nextAttack = now + 2 + run.rng:NextNumber() * (if spec.attack then spec.attack.cooldown else 0),
		nextBite = 0,
		nextMove = 0,
		room = room,
		shut = false,
		shutBy = nil,
	}
	table.insert(run.enemies, enemy)
	return enemy
end

local function standing(spec: RiftEnemies.Enemy, spot: Vector3): CFrame
	local def = spec.def
	return CFrame.new(spot + Vector3.new(0, def.hipHeight + def.hitbox.Y / 2 + 0.5, 0))
end

local function spawnRiftlings(run: Run, spots: { Vector3 }, count: number)
	for i = 1, count do
		local spot = spots[(i - 1) % #spots + 1]
		spawnEnemy(run, RiftEnemies.riftling, standing(RiftEnemies.riftling, spot + Vector3.new(run.rng:NextNumber() * 4 - 2, 0, run.rng:NextNumber() * 4 - 2)))
	end
end

-- What a room holds wakes when its turn comes, so nothing waits behind a shut door burning budget.
local function wakeRoom(run: Run, room: RoomState)
	local parts = room.parts
	spawnRiftlings(run, parts.spots, RiftEnemies.roomEnemies + (run.twist.extraEnemies or 0))
	for _, at in parts.eyes do
		local look = at + Vector3.new(-10, 0, 0)
		spawnEnemy(run, RiftEnemies.eye, CFrame.lookAt(at, look), room)
	end
	room.nextPulse = os.clock() + 4
end

local function wakeBoss(run: Run)
	local interior = run.interior
	if not interior then
		return
	end
	local spot = interior.arena.spots[1]
	local enemy = spawnEnemy(run, RiftEnemies.warden, standing(RiftEnemies.warden, spot))
	if enemy then
		enemy.humanoid:SetAttribute("Resist_" .. run.plan.bossWeakness, -0.3)
		run.boss = enemy
	end
	spawnRiftlings(run, { spot + Vector3.new(-10, 0, 14), spot + Vector3.new(-10, 0, -14) }, run.twist.extraEnemies or 0)
	tellInside(run, string.format("The Warden stirs. It flinches from %s, and from anything that stops it.", run.plan.bossWeakness))
end

-- ─── Solving rooms ──────────────────────────────────────────────────────────

local function solve(run: Run, room: RoomState, label: string?, clever: boolean)
	if room.solved then
		return
	end
	room.solved = true
	room.progress = 1
	room.clever = clever
	if clever then
		run.cleverRooms += 1
	end
	local door = room.parts.door
	if door then
		door:Destroy()
		room.parts.door = nil
	end
	for _, piece in room.parts.pieces do
		piece:Destroy()
	end
	table.clear(room.parts.pieces)
	log:info("rift_room_solved", { id = run.plan.id, room = room.def.id, clever = clever, label = label })
	if clever and label then
		tellInside(run, string.format("%s: %s. The way opens.", room.def.name, label))
		cue(run, { kind = "solved", clever = true, label = label })
	else
		tellInside(run, string.format("%s: the way opens. There was probably a cleverer way.", room.def.name))
		cue(run, { kind = "solved", clever = false })
	end
	run.roomIndex += 1
	local nextRoom = currentRoom(run)
	if nextRoom then
		wakeRoom(run, nextRoom)
	else
		wakeBoss(run)
	end
	pushState(run)
end

local function nearestPieces(room: RoomState, point: Vector3, count: number): { BasePart }
	local sorted = table.clone(room.parts.pieces)
	table.sort(sorted, function(a, b)
		return (a.Position - point).Magnitude < (b.Position - point).Magnitude
	end)
	local out: { BasePart } = {}
	for i = 1, math.min(count, #sorted) do
		out[i] = sorted[i]
	end
	return out
end

local function removePiece(room: RoomState, piece: BasePart)
	local index = table.find(room.parts.pieces, piece)
	if index then
		table.remove(room.parts.pieces, index)
	end
	piece:Destroy()
end

-- Progress on a meter-filling room shows in the room itself: planks of a bridge, coils waking.
local function showProgress(run: Run, room: RoomState)
	local parts = room.parts
	for i, segment in parts.bridge do
		if room.progress >= i / #parts.bridge and segment.Transparency > 0.5 then
			segment.Transparency = 0.25
			segment.CanCollide = true
			segment.CanQuery = true
		end
	end
	for i, coil in parts.coils do
		if room.progress >= i / #parts.coils and coil.Material ~= Enum.Material.Neon then
			coil.Material = Enum.Material.Neon
			coil.Color = run.twist.color
		end
	end
end

-- One cast's work on the room you're in.
local function workOn(run: Run, room: RoomState, payload: any, point: Vector3, userId: number)
	local kind = room.def.kind
	local cast: RiftRules.Cast = {
		tags = payload.tags or {},
		route = payload.route,
		power = payload.power or 1,
		backfired = payload.backfired,
	}
	local approach, gain = RiftRules.classify(room.def, cast, run.twist)
	if gain <= 0 then
		return
	end
	local now = os.clock()
	local score = scoreFor(run, userId)

	if kind == "eyes" then
		-- Only a clever cast near an eye does anything special. Plain hits just hurt it.
		if not approach then
			return
		end
		local best: EnemyState? = nil
		local bestDistance = R.eyeRadius
		for _, enemy in run.enemies do
			if enemy.room == room and enemy.humanoid.Health > 0 then
				local d = (enemy.root.Position - point).Magnitude
				if d <= bestDistance then
					best, bestDistance = enemy, d
				end
			end
		end
		if best then
			best.shut = true
			best.shutBy = approach.label
			best.humanoid.Health = 0
			EventRules.addDamage(score, R.cleverPoints / room.total, now)
		end
		return
	end

	if approach then
		room.label = approach.label
		room.cleverGain += gain
		EventRules.addDamage(score, gain * R.cleverPoints, now)
	else
		room.bruteGain += gain
		EventRules.addDamage(score, gain * R.brutePoints, now)
	end

	if kind == "barrier" then
		local lit = 0
		if approach and approach.burns then
			-- Real fire: burned-out planks are noticed in stepRoom. If the budget refuses, fall through.
			for _, piece in nearestPieces(room, point, R.burnPieces) do
				if piece:GetAttribute("Burning") or FireSim.ignitePart(piece, 0.9, userId) then
					lit += 1
				end
			end
		end
		if lit == 0 then
			room.removeCredit += gain * room.total
			while room.removeCredit >= 1 and #room.parts.pieces > 0 do
				room.removeCredit -= 1
				local piece = nearestPieces(room, point, 1)[1]
				if piece then
					removePiece(room, piece)
				end
			end
			room.progress = 1 - #room.parts.pieces / room.total
			if #room.parts.pieces == 0 then
				solve(run, room, room.label, RiftRules.solvedCleverly(room.cleverGain, room.bruteGain))
			end
		end
		return
	end

	-- A meter: the chasm's bridge, the engine's coils.
	room.progress = math.min(1, room.progress + gain)
	showProgress(run, room)
	if room.progress >= 1 then
		solve(run, room, room.label, RiftRules.solvedCleverly(room.cleverGain, room.bruteGain))
	end
end

-- ─── Attacks ────────────────────────────────────────────────────────────────

local function telegraph(run: Run, position: Vector3, attack: RiftEnemies.Attack, domain: string, level: number)
	local at = Vector3.new(position.X, R.pocket.y, position.Z)
	table.insert(run.telegraphs, {
		at = os.clock() + attack.delay,
		position = at,
		radius = attack.radius,
		damage = attack.damage * (run.twist.enemyDamage or 1),
		style = attack.style,
		domain = domain,
		level = level,
	})
	cue(run, { kind = "telegraph", style = attack.style, x = at.X, y = at.Y, z = at.Z, radius = attack.radius, duration = attack.delay })
end

local function landTelegraphs(run: Run, players: { PlayerView }, now: number)
	for i = #run.telegraphs, 1, -1 do
		local t = run.telegraphs[i]
		if TimeZones.stopped(t.position) then
			t.at += STEP_SECONDS -- a Timestop: the blow hangs until time resumes
		elseif now >= t.at then
			table.remove(run.telegraphs, i)
			for _, view in players do
				local flat = Vector3.new(view.position.X - t.position.X, 0, view.position.Z - t.position.Z).Magnitude
				if flat <= t.radius and math.abs(view.position.Y - t.position.Y) <= 24 then
					Damage.apply(view.humanoid, t.damage, nil, "rift", { domain = t.domain, from = t.position, form = "burst", power = t.level })
				end
			end
			cue(run, { kind = "impact", style = t.style, x = t.position.X, y = t.position.Y, z = t.position.Z, radius = t.radius })
		end
	end
end

-- ─── Stepping ───────────────────────────────────────────────────────────────

local function nearest(position: Vector3, players: { PlayerView }, within: number): (PlayerView?, number)
	local best: PlayerView? = nil
	local bestDistance = within
	for _, view in players do
		local d = Vector3.new(view.position.X - position.X, 0, view.position.Z - position.Z).Magnitude
		if d <= bestDistance then
			best, bestDistance = view, d
		end
	end
	return best, bestDistance
end

local function fadeOut(enemy: EnemyState)
	enemy.root.Anchored = true
	local model = enemy.model
	for _, child in enemy.root:GetChildren() do
		if child:IsA("ParticleEmitter") then
			child.Enabled = false
		end
	end
	task.delay(FADE_SECONDS, function()
		model:Destroy()
	end)
end

-- Something took an eye out of play: broken by damage, or shut by a clever cast.
local function eyeGone(run: Run, enemy: EnemyState)
	local room = enemy.room
	if not room or room.solved then
		return
	end
	local share = 1 / room.total
	if enemy.shut then
		room.cleverGain += share
		room.label = enemy.shutBy
	else
		room.bruteGain += share
	end
	local left = 0
	for _, other in run.enemies do
		if other.room == room and other ~= enemy and other.humanoid.Health > 0 then
			left += 1
		end
	end
	room.progress = 1 - left / room.total
	if left == 0 then
		solve(run, room, room.label, RiftRules.solvedCleverly(room.cleverGain, room.bruteGain))
	end
end

local function stepEnemy(run: Run, enemy: EnemyState, players: { PlayerView }, now: number)
	local position = enemy.root.Position
	local attack = enemy.spec.attack
	if enemy.spec.static then
		-- An eye strikes at someone in range, in its room.
		if attack and now >= enemy.nextAttack then
			local target = nearest(position, players, EYE_RANGE)
			if target then
				enemy.nextAttack = now + attack.cooldown
				telegraph(run, target.position, attack, enemy.spec.def.domain, enemy.spec.def.level)
			end
		end
		return
	end
	local target, distance = nearest(position, players, math.huge)
	if not target then
		return
	end
	if now >= enemy.nextMove then
		enemy.nextMove = now + MOVE_EVERY
		enemy.humanoid:MoveTo(target.position)
	end
	local b = enemy.spec.def.bite
	if b and distance <= b.reach and now >= enemy.nextBite then
		enemy.nextBite = now + b.cooldown
		Damage.apply(target.humanoid, b.damage * (run.twist.enemyDamage or 1), nil, "rift_bite", {
			domain = enemy.spec.def.domain,
			from = position,
			property = b.property,
			form = "touch",
			power = enemy.spec.def.level,
			attacker = enemy.model,
		})
	end
	if attack and now >= enemy.nextAttack then
		local hurt = enemy == run.boss and run.bossHurt
		enemy.nextAttack = now + attack.cooldown * (if hurt then RiftEnemies.wardenHurtCooldown else 1)
		telegraph(run, target.position, attack, enemy.spec.def.domain, enemy.spec.def.level)
	end
end

local function stepEnemies(run: Run, players: { PlayerView }, now: number)
	for i = #run.enemies, 1, -1 do
		local enemy = run.enemies[i]
		local lost = not enemy.model.Parent or enemy.root.Position.Y < R.pocket.y - R.chasmDepth - 40
		if lost or enemy.humanoid.Health <= 0 then
			table.remove(run.enemies, i)
			if lost then
				enemy.model:Destroy()
			else
				fadeOut(enemy)
			end
			if enemy == run.boss then
				run.boss = nil
				finish(run, "won")
				return
			end
			eyeGone(run, enemy)
			if run.phase ~= "running" then
				return
			end
		elseif not enemy.humanoid:GetAttribute("KnockedDown") and not enemy.model:GetAttribute("GravityHeld") then
			stepEnemy(run, enemy, players, now)
		end
	end
	local boss = run.boss
	if boss and not run.bossHurt and boss.humanoid.Health < boss.humanoid.MaxHealth * RiftEnemies.wardenHurtAt then
		run.bossHurt = true
		local spot = boss.root.Position
		spawnRiftlings(run, { Vector3.new(spot.X, R.pocket.y, spot.Z + 10), Vector3.new(spot.X, R.pocket.y, spot.Z - 10) }, RiftEnemies.wardenHelp)
		tellInside(run, "The Warden howls, and the walls answer.")
	end
end

-- What a room does on its own: planks burned out, someone across the drop, coils spitting.
local function stepRoom(run: Run, room: RoomState, players: { PlayerView }, now: number)
	local kind = room.def.kind
	if kind == "barrier" then
		local changed = false
		for i = #room.parts.pieces, 1, -1 do
			local piece = room.parts.pieces[i]
			if not piece.Parent or (piece:GetAttribute("Flammability") or 0) == 0 then
				table.remove(room.parts.pieces, i)
				piece:Destroy()
				room.cleverGain += 1 / room.total
				room.label = room.label or "Burned it down"
				changed = true
			end
		end
		if changed then
			room.progress = 1 - #room.parts.pieces / room.total
			if #room.parts.pieces == 0 then
				solve(run, room, room.label, RiftRules.solvedCleverly(room.cleverGain, room.bruteGain))
			end
		end
	elseif kind == "chasm" then
		local far = room.parts.farEdge
		if far then
			for _, view in players do
				if view.position.X >= far + 1 and view.position.X <= room.parts.section.startX + room.parts.section.length and view.position.Y >= R.pocket.y - 2 then
					-- Getting across without finishing the bridge is an answer in itself.
					solve(run, room, if room.progress < 1 then "Got across without a bridge" else room.label, true)
					return
				end
			end
		end
	elseif kind == "coils" and now >= room.nextPulse then
		local pulse = RiftEnemies.coilPulse
		room.nextPulse = now + pulse.cooldown
		local inRoom: { PlayerView } = {}
		local s = room.parts.section
		for _, view in players do
			if view.position.X >= s.startX and view.position.X <= s.startX + s.length then
				table.insert(inRoom, view)
			end
		end
		if #inRoom > 0 then
			telegraph(run, inRoom[run.rng:NextInteger(1, #inRoom)].position, pulse, "energy", 3)
		end
	end
end

-- Falling into the drop: the Rift throws you back to where the room starts, and it hurts.
local function stepFalls(run: Run, players: { PlayerView })
	local interior = run.interior
	if not interior then
		return
	end
	for _, view in players do
		if view.position.Y < R.pocket.y - R.fallLine then
			local back = interior.hall.entrance
			for _, room in run.rooms do
				local s = room.parts.section
				if view.position.X >= s.startX and view.position.X <= s.startX + s.length then
					back = room.parts.entrance
				end
			end
			Damage.apply(view.humanoid, view.humanoid.MaxHealth * R.fallDamage, nil, "rift_fall", { domain = "void", form = "burst", power = 1 })
			local character = view.player.Character
			if character and view.humanoid.Health > 0 then
				character:PivotTo(back)
				view.root.AssemblyLinearVelocity = Vector3.zero
			end
		end
	end
end

local function stepRun(run: Run, now: number)
	local players = insidePlayers(run)
	landTelegraphs(run, players, now)
	stepEnemies(run, players, now)
	if run.phase ~= "running" then
		return
	end
	local room = currentRoom(run)
	if room then
		stepRoom(run, room, players, now)
	end
	stepFalls(run, players)
end

-- ─── Entering ───────────────────────────────────────────────────────────────

local function newRoomState(def: R.Room, parts: RiftBuilder.RoomParts): RoomState
	local total = 1
	if def.kind == "barrier" then
		total = #parts.pieces
	elseif def.kind == "eyes" then
		total = #parts.eyes
	end
	return {
		def = def,
		parts = parts,
		total = math.max(1, total),
		progress = 0,
		cleverGain = 0,
		bruteGain = 0,
		removeCredit = 0,
		solved = false,
		clever = false,
		label = nil,
		nextPulse = 0,
	}
end

-- The first step inside: the pocket is built, the clock starts.
local function startRun(run: Run)
	local interior = RiftBuilder.buildInterior(run.plan, run.twist.color)
	run.interior = interior
	run.length = interior.length
	for i, parts in interior.rooms do
		local room = newRoomState(R.rooms[run.plan.rooms[i]], parts)
		run.rooms[i] = room
		for _, piece in parts.pieces do
			ThermalSim.ensure(piece)
		end
	end
	for _, gate in interior.exits do
		local prompt = Instance.new("ProximityPrompt")
		prompt.ActionText = "Leave the Rift"
		prompt.ObjectText = run.twist.name .. " Rift"
		prompt.HoldDuration = 0.6
		prompt.MaxActivationDistance = 12
		prompt.RequiresLineOfSight = false
		prompt.Parent = gate
		prompt.Triggered:Connect(function(player: Player)
			if current == run then
				putBack(run, player)
			end
		end)
	end
	local started = os.time()
	run.phase = "running"
	run.endsAt = if run.forced then started + R.runSeconds else RiftRules.runEnds(run.plan.slot, started)
	if run.twist.fireSpread then
		local middle = Vector3.new(R.pocket.x + run.length / 2, R.pocket.y, R.pocket.z)
		FireSim.boost(middle, run.length, run.twist.fireSpread, run.endsAt - started + 5)
	end
	wakeRoom(run, run.rooms[1])
	log:info("rift_started", { id = run.plan.id, twist = run.twist.id, rooms = table.concat(run.plan.rooms, ","), weak = run.plan.bossWeakness })
end

local function enter(run: Run, player: Player)
	if run.phase == "ended" or current ~= run then
		return
	end
	if run.phase == "open" then
		startRun(run)
		pushState(run)
	end
	local interior = run.interior
	if interior then
		scoreFor(run, player.UserId)
		moveInto(player, interior.hall.entrance)
		Net.fire("Notify", player, string.format("%s Rift: %s", run.twist.name, run.twist.text))
		log:info("rift_entered", { userId = player.UserId, id = run.plan.id })
	end
end

-- The portal appears once someone's near and the ground exists.
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

local function tryPortal(run: Run)
	if run.portal or run.phase == "ended" then
		return
	end
	local near = false
	for _, view in livingPlayers() do
		if Vector3.new(view.position.X - run.plan.x, 0, view.position.Z - run.plan.z).Magnitude <= R.portalRadius then
			near = true
			break
		end
	end
	if not near or not world:isChunkBuilt(run.plan.x, run.plan.z) then
		return
	end
	local ground = groundAt(run.plan.x, run.plan.z)
	if not ground then
		return
	end
	local model, core = RiftBuilder.buildPortal(run.plan, ground, run.twist.color)
	run.portal, run.portalGround = model, ground
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Enter the Rift"
	prompt.ObjectText = run.twist.name .. " Rift"
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.Parent = core
	prompt.Triggered:Connect(function(player: Player)
		enter(run, player)
	end)
end

-- ─── Once a second ──────────────────────────────────────────────────────────

local function secondTick(run: Run)
	if run.phase == "ended" then
		return
	end
	local time = os.time()
	tryPortal(run)
	if run.phase == "open" then
		if time >= run.closesAt then
			finish(run, "faded")
		end
		return
	end
	if time >= run.endsAt then
		finish(run, "failed")
		return
	end
	local players = insidePlayers(run)
	local count = #players
	if count > run.peak then
		run.peak = count
		for _, enemy in run.enemies do
			local base = enemy.spec.def.health * (run.twist.enemyHealth or 1)
			local maxHealth, health = EventRules.raise(enemy.humanoid.MaxHealth, enemy.humanoid.Health, EventRules.healthFor(base, count))
			enemy.humanoid.MaxHealth = maxHealth
			enemy.humanoid.Health = health
		end
	end
	local here: { [number]: boolean } = {}
	for _, view in players do
		here[view.player.UserId] = true
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
		if player then
			Net.fire("RiftScore", player, { points = math.floor(score.points), tier = EventRules.tierFor(score, top), inside = isHere })
		end
	end
	if signature(run) ~= run.lastSent then
		pushState(run)
	end
end

-- ─── Starting ───────────────────────────────────────────────────────────────

local function begin(plan: RiftRules.Plan, forced: boolean, closesAt: number): Run
	local run: Run = {
		plan = plan,
		twist = R.twists[plan.twist],
		forced = forced,
		phase = "open",
		closesAt = closesAt,
		endsAt = closesAt,
		portal = nil,
		portalGround = nil,
		interior = nil,
		length = RiftRules.totalLength(#plan.rooms),
		rooms = {},
		roomIndex = 1,
		cleverRooms = 0,
		enemies = {},
		telegraphs = {},
		boss = nil,
		bossHurt = false,
		exposedAt = {},
		scores = {},
		peak = 1,
		rng = Seed.random(worldService:getSeed(), plan.id, "rift_run"),
		lastSent = "",
		result = nil,
		tornDown = false,
	}
	current = run
	pushState(run)
	log:info("rift_opened", { id = plan.id, twist = plan.twist, place = plan.townName, x = math.floor(plan.x), z = math.floor(plan.z), forced = forced })
	return run
end

local function isDry(x: number, z: number): boolean
	return world:surfaceHeight(x, z) >= WorldConfig.SEA_LEVEL + 2
end

local function planFor(slot: number): RiftRules.Plan
	return RiftRules.plan(worldService:getSeed(), slot, towns, isDry)
end

local function checkSchedule()
	local time = os.time()
	local slot = RiftRules.slotOf(time)
	if slot == handledSlot or current or #towns == 0 or not enabled() then
		return
	end
	handledSlot = slot
	local window = RiftRules.window(slot)
	if time < window.closesAt then
		begin(planFor(slot), false, window.closesAt)
	end
end

-- ─── Listening ──────────────────────────────────────────────────────────────

local function running(): Run?
	local run = current
	return if run and run.phase == "running" then run else nil
end

local function onResolved(payload: any)
	local run = running()
	local userId: number? = payload.casterUserId
	local point: Vector3? = payload.point
	if not run or not userId or typeof(point) ~= "Vector3" or not isInside(run, userId) then
		return
	end
	EventRules.noteAction(scoreFor(run, userId), os.clock())
	local room = currentRoom(run)
	if not room then
		return
	end
	-- It has to land in the room you're stuck at, not just anywhere in the Rift.
	local s = room.parts.section
	if point.X < s.startX or point.X > s.startX + s.length then
		return
	end
	workOn(run, room, payload, point, userId)
end

local function onDamaged(payload: any)
	local run = running()
	local source: number? = payload.sourceUserId
	local model = payload.model
	if run and source and model and model:GetAttribute("RiftEnemy") == run.plan.id then
		EventRules.addDamage(scoreFor(run, source), payload.amount, os.clock())
	end
end

-- Any status on the boss bites: controlling it pays as well as hitting it.
local function onStatus(payload: any)
	local run = running()
	local boss = run and run.boss
	local source: number? = payload.sourceUserId
	if not run or not boss or not source or payload.model ~= boss.model then
		return
	end
	local status = tostring(payload.status)
	local now = os.clock()
	if now < (run.exposedAt[status] or 0) then
		return
	end
	run.exposedAt[status] = now + R.exposedCooldown
	Damage.apply(boss.humanoid, boss.humanoid.MaxHealth * R.exposedShare, source, "rift_exposed", { domain = "void", form = "touch", power = 1 })
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "rift",
		category = "World",
		description = "Rifts: open one in front of you, step straight inside, solve the current room, win (pays out), close (no rewards), status, or the schedule",
		args = {
			{ name = "action", type = "enum", options = { "open", "enter", "solve", "win", "close", "status", "schedule" } },
			{ name = "twist", type = "enum", options = table.clone(R.twistIds), optional = true },
		},
		handler = function(ctx: any, a: any)
			if a.action == "schedule" then
				if #towns == 0 then
					return "the world isn't ready yet"
				end
				local lines = {}
				local slot = RiftRules.slotOf(os.time())
				for i = 0, 5 do
					local plan = planFor(slot + i)
					local inMinutes = math.floor(((slot + i) * R.slotSeconds - os.time()) / 60)
					table.insert(lines, string.format("%+d min  %s near %s (%.0f, %.0f): %s", inMinutes, plan.twist, plan.townName, plan.x, plan.z, table.concat(plan.rooms, ", ")))
				end
				return table.concat(lines, "\n")
			end
			local run = current
			if a.action == "open" then
				if #towns == 0 then
					return "the world isn't ready yet"
				end
				local at = Util.ahead(ctx.player, world, 30)
				if not at then
					return "no character"
				end
				if run then
					finish(run, "cancelled")
					teardown(run)
				end
				local time = os.time()
				local plan = planFor(time) -- an unused slot number: a fresh draw every time
				plan.id = "rift_a" .. time
				plan.x, plan.z = at.X, at.Z
				plan.townName = "here"
				plan.twist = a.twist or plan.twist
				begin(plan, true, time + R.openSeconds)
				return string.format("%s Rift opened here: %s", plan.twist, table.concat(plan.rooms, ", "))
			end
			if not run then
				return "no Rift open"
			end
			if a.action == "status" then
				local lines = { string.format("%s %s near %s: %s, room %d of %d, %d clever, %d enemies, peak %d", run.plan.id, run.twist.id, run.plan.townName, run.phase, run.roomIndex, #run.rooms, run.cleverRooms, #run.enemies, run.peak) }
				for userId, score in run.scores do
					table.insert(lines, string.format("  %d: %d points, %d s", userId, math.floor(score.points), score.seconds))
				end
				return table.concat(lines, "\n")
			elseif a.action == "enter" then
				enter(run, ctx.player)
				return "in you go"
			elseif a.action == "solve" then
				if run.phase ~= "running" then
					return "nobody's inside yet: use rift enter first"
				end
				local room = currentRoom(run)
				if not room then
					return "no room left: it's the boss now"
				end
				solve(run, room, "An admin waved it open", true)
				return "solved " .. room.def.id
			end
			finish(run, if a.action == "win" then "won" else "cancelled")
			return "ended: " .. tostring(run.result)
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function RiftService.init(_self: any, ctx: any)
	log, bus = ctx.log, ctx.bus
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	inventory = ctx.get("InventoryService")
	playerData = ctx.get("PlayerDataService")
	progression = ctx.get("ProgressionService")
	registerAdmin(ctx.get("AdminService"))
	Net.handle("RequestRift", function(_player: Player)
		return viewOf(current)
	end)
	bus:subscribe(Topics.SpellResolved, onResolved)
	bus:subscribe(Topics.TargetDamaged, onDamaged)
	bus:subscribe(Topics.StatusApplied, onStatus)
end

function RiftService.start(_self: any, _ctx: any)
	task.spawn(function()
		world:awaitReady()
		for _, settlement in world:placement().settlements do
			table.insert(towns, { id = settlement.id, name = settlement.name, x = settlement.x, z = settlement.z })
		end
		local acc = 0
		local function step()
			local run = current
			if run and run.phase ~= "ended" and not enabled() then
				finish(run, "cancelled")
			end
			if run and run.phase == "running" then
				stepRun(run, os.clock())
			end
			acc += STEP_SECONDS
			if acc >= 1 then
				acc = 0
				checkSchedule()
				run = current
				if run then
					secondTick(run)
				end
			end
		end
		while true do
			task.wait(STEP_SECONDS)
			-- One failure mustn't stop this loop: no Rift would ever run on this server again.
			local ok, err = pcall(step)
			if not ok then
				log:throttled("rift_step", 30, "Error", "rift_step_failed", { err = err })
			end
		end
	end)
end

return RiftService
