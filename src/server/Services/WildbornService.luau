--!strict
--[[
	WildbornService: people the land remade, haunting the wilds, and their oldest in lairs
	(docs/Wildborn.md). Content: Wildborn/Data/Wildborn. Decisions: Wildborn/WildbornRules. Bodies:
	Wildborn/WildbornRig (always R6 humanoid rigs). Moves: Wildborn/WildbornMoves.

	WHERE
		Haunts: seeded spots in the wilds of each theme's biomes, never near a town, the same on every
		server; one or two ordinary Wildborn each. Lairs: one per theme, its boss, in a ring of standing
		stones. Both wake when a player comes within wakeRadius (and the chunk is built) and sleep past
		sleepRadius: nobody near = no rigs and no cost. maxAlive caps ordinary Wildborn; bosses don't count.
	FIGHTING (every stepSeconds, awake ones only)
		Notices the nearest player within aggro (or whoever hurt it), forgets past deaggro. Past its
		leash it walks home and heals, so it can't be kited to death. Otherwise: the first move that's
		ready and in range (WildbornRules.chooseMove), else walks in and uses its plain blow. Standing
		still while it casts. Knocked down or held: does nothing.
	DEATH
		Paid like a creature kill (CreatureService:rewardFor: XP to the branch you hit it with, seeded
		loot, anti-grind, party shares). A boss: your FIRST kill of it ever pays firstBossXp times its XP
		and writes a Journal line (data.wildborn.slain); it returns to its lair after a real day on this
		server. Ordinary Wildborn return to their haunt after a few minutes.
	TELLING (world over game: no card, no announcement)
		Ask a townsperson for news: they may tell the old story of the nearest boss you haven't heard of,
		with the direction (data.wildborn.heard), and its lair goes on your map (MapService.revealArea).

	Admin: wildborn spawn <enemy> | list | lairs | goto <theme> | clear | revive.
	Log: wildborn_planned, wildborn_killed, wildborn_boss_slain, wildborn_story.
	Flag: wildborn_enabled.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local OmenRules = require(Shared.Magic.OmenRules)

local Server = script.Parent.Parent
local Data = require(Server.Wildborn.Data.Wildborn)
local Rules = require(Server.Wildborn.WildbornRules)
local Rig = require(Server.Wildborn.WildbornRig)
local Moves = require(Server.Wildborn.WildbornMoves)
local WorldConfig = require(Server.World.WorldConfig)
local Util = require(Server.Admin.Util)
local DownedRules = require(Server.Downed.DownedRules)

local T = Data.tuning

local WildbornService = {
	name = "WildbornService",
	dependencies = { "AdminService", "CreatureService", "JournalService", "MapService", "NPCService", "PlayerDataService", "ProgressionService", "WorldService", "WorldStateService" },
}

type View = Moves.View
type Slot = { actor: Actor?, respawnAt: number, generation: number }
type Home = {
	id: string,
	enemy: string,
	theme: string,
	x: number,
	z: number,
	boss: boolean,
	slots: { Slot },
	awake: boolean,
	temporary: boolean,
	center: Vector3?,
	marker: Model?,
	killedAt: number?, -- os.time() its boss was beaten on this server
}
type Actor = Moves.Actor & {
	home: Home,
	slot: Slot,
	tracks: { [string]: AnimationTrack },
	dealt: { [number]: number },
	branch: { [number]: string },
	attacker: number?,
	attackerUntil: number,
	target: View?,
	readyAt: { [number]: number },
	used: { [number]: boolean },
	busyUntil: number,
	nextMelee: number,
	returning: boolean,
	moving: boolean,
	-- Services/DownedService: someone it dragged home. Left alone while they stay inside `radius` of
	-- `center`; fought if they step out; at `untilClock` it lets them be and wanders off.
	hold: { userId: number, center: Vector3, radius: number, untilClock: number, wander: number }?,
	spare: { [number]: number }?, -- userId -> os.clock() until which it ignores them
	wanderTo: Vector3?,
	wanderUntil: number?,
}

local log: any = nil
local bus: any = nil -- ctx.bus (Services/ChronicleService hears DeedDone)
local world: any = nil
local worldService: any = nil
local creatures: any = nil
local journal: any = nil
local map: any = nil
local playerData: any = nil
local progression: any = nil

local homes: { Home } = {}
local lairByTheme: { [string]: Home } = {}
local alive: { Actor } = {}
local byModel: { [Model]: Actor } = {}
local folder: Folder? = nil
local spawnCounter = 0
local tempCount = 0

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function enabled(): boolean
	return FeatureFlags.get("wildborn_enabled") == true
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function livingPlayers(): { View }
	local out: { View } = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") and not DownedRules.ignored(humanoid) then
			table.insert(out, { player = player, humanoid = humanoid, root = root, position = root.Position })
		end
	end
	return out
end

local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Include
terrainParams.FilterDescendantsInstances = { workspace.Terrain }
terrainParams.IgnoreWater = false

local function groundAt(x: number, z: number): Vector3?
	local top = world:surfaceHeight(x, z) + 40
	local hit = workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, -160, 0), terrainParams)
	if not hit or hit.Material == Enum.Material.Water then
		return nil
	end
	return hit.Position
end

local function recordOf(player: Player): { heard: { [string]: number }, slain: { [string]: number } }?
	local state = playerData:get(player)
	if not state then
		return nil
	end
	local data = state.data
	data.wildborn = data.wildborn or { heard = {}, slain = {} }
	data.wildborn.heard = data.wildborn.heard or {}
	data.wildborn.slain = data.wildborn.slain or {}
	return data.wildborn
end

local function play(actor: Actor, name: string)
	local track = actor.tracks[name]
	if track then
		pcall(function()
			track:Play(0.1)
		end)
	end
end

-- ─── Lair markers ───────────────────────────────────────────────────────────

local function makeMarker(home: Home)
	local center = home.center
	if home.marker or not center or not home.boss then
		return
	end
	local theme = Data.themes[home.theme]
	local model = Instance.new("Model")
	model.Name = "WildbornLair"
	local rng = Seed.random(worldService:getSeed(), home.id, "lair_stones")
	for i = 0, 6 do
		local angle = (i / 7) * math.pi * 2 + rng:NextNumber() * 0.2
		local height = 5 + rng:NextNumber() * 4
		local base = groundAt(center.X + math.cos(angle) * T.lairRadius, center.Z + math.sin(angle) * T.lairRadius) or center
		local stone = Instance.new("Part")
		stone.Name = "LairStone"
		stone.Size = Vector3.new(2.4, height, 1.6)
		stone.CFrame = CFrame.new(base + Vector3.new(0, height / 2 - 0.5, 0)) * CFrame.Angles(math.rad(rng:NextNumber() * 10 - 5), -angle, 0)
		stone.Color = Color3.fromRGB(80, 76, 72):Lerp(theme.primary, 0.15)
		stone.Material = Enum.Material.Slate
		stone.Anchored = true
		stone:SetAttribute("Flammability", 0)
		stone:SetAttribute("NoMagicEdit", true)
		stone.Parent = model
		local glyph = Instance.new("Part")
		glyph.Name = "LairGlyph"
		glyph.Size = Vector3.new(0.6, 0.6, 0.1)
		glyph.Color = Color3.new(theme.secondary.R * 0.45, theme.secondary.G * 0.45, theme.secondary.B * 0.45)
		glyph.Material = Enum.Material.Neon
		glyph.Anchored = true
		glyph.CanCollide = false
		glyph.CanQuery = false
		glyph.CFrame = stone.CFrame * CFrame.new(0, height * 0.25, -0.85)
		glyph.Parent = model
	end
	model.Parent = folder
	home.marker = model
end

-- ─── Spawning ───────────────────────────────────────────────────────────────

local function spawnActor(home: Home, index: number, slot: Slot): boolean
	local enemy = Data.enemies[home.enemy]
	local rng = Seed.random(worldService:getSeed(), home.id, "wildborn_member", index * 1000 + slot.generation)
	local angle = rng:NextNumber() * 2 * math.pi
	local distance = if home.boss then 0 else rng:NextNumber() * 10
	local ground = groundAt(home.x + math.cos(angle) * distance, home.z + math.sin(angle) * distance)
	if not ground then
		slot.respawnAt = os.clock() + 5
		return false
	end
	local at = CFrame.new(ground + Vector3.new(0, 3.2 * enemy.scale, 0)) * CFrame.Angles(0, rng:NextNumber() * 2 * math.pi, 0)
	spawnCounter += 1
	local rig = Rig.build(enemy, at, spawnCounter)
	if not rig then
		slot.respawnAt = os.clock() + 10
		return false
	end
	rig.model:PivotTo(at)
	rig.model:SetAttribute("WildbornHome", home.id)
	rig.model.Parent = folder
	pcall(function()
		rig.root:SetNetworkOwner(nil) -- server-driven: no client can teleport it
	end)
	local actor: Actor = {
		enemy = enemy,
		model = rig.model,
		humanoid = rig.humanoid,
		root = rig.root,
		rng = rng,
		lastHit = setmetatable({}, { __mode = "k" }) :: any,
		home = home,
		slot = slot,
		tracks = rig.tracks,
		dealt = {},
		branch = {},
		attacker = nil,
		attackerUntil = 0,
		target = nil,
		readyAt = {},
		used = {},
		busyUntil = 0,
		nextMelee = 0,
		returning = false,
		moving = false,
	}
	-- Moves start staggered, so a group doesn't open with everything at once.
	for i, move in enemy.moves do
		actor.readyAt[i] = os.clock() + rng:NextNumber() * math.min(move.cd or 4, 4)
	end
	play(actor, "idle")
	slot.actor = actor
	table.insert(alive, actor)
	byModel[rig.model] = actor
	return true
end

local function forget(actor: Actor)
	byModel[actor.model] = nil
	actor.slot.actor = nil
	Moves.forget(actor)
	local index = table.find(alive, actor)
	if index then
		table.remove(alive, index)
	end
end

local function sleepHome(home: Home)
	home.awake = false
	for _, slot in home.slots do
		local actor = slot.actor
		if actor then
			forget(actor)
			actor.model:Destroy()
		end
	end
	if home.marker then
		home.marker:Destroy()
		home.marker = nil
	end
	if home.temporary then
		local index = table.find(homes, home)
		if index then
			table.remove(homes, index)
		end
	end
end

local function regularAlive(): number
	local n = 0
	for _, actor in alive do
		if not actor.enemy.boss then
			n += 1
		end
	end
	return n
end

local function wakeTick()
	local players = livingPlayers()
	local now = os.clock()
	local room = T.maxAlive - regularAlive()
	for i = #homes, 1, -1 do
		local home = homes[i]
		local position = Vector3.new(home.x, 0, home.z)
		local nearest = math.huge
		for _, view in players do
			nearest = math.min(nearest, flat(view.position, position))
		end
		if home.awake and nearest > T.sleepRadius then
			sleepHome(home)
		elseif not home.awake and nearest <= T.wakeRadius and world:isChunkBuilt(home.x, home.z) then
			home.center = groundAt(home.x, home.z)
			if home.center then
				home.awake = true
				makeMarker(home)
			end
		end
		if home.awake then
			for index, slot in home.slots do
				local back = not home.boss or Rules.bossBack(home.killedAt, os.time())
				if not slot.actor and now >= slot.respawnAt and back and (home.boss or home.temporary or room > 0) then
					if spawnActor(home, index, slot) and not home.boss and not home.temporary then
						room -= 1
					end
				end
			end
		end
	end
end

-- ─── Death ──────────────────────────────────────────────────────────────────

-- True when someone killed this boss for the first time.
local function payBoss(actor: Actor): boolean
	local first = false
	local enemy = actor.enemy
	local theme = Data.themes[enemy.theme]
	for userId, dealt in actor.dealt do
		local player = Players:GetPlayerByUserId(userId)
		local record = player and recordOf(player)
		if player and record and dealt >= enemy.health * 0.05 and not record.slain[enemy.id] then
			record.slain[enemy.id] = os.time()
			journal:log(player, "wildborn", theme.slain, { wildborn = enemy.id, quiet = true })
			local branch = actor.branch[userId]
			if branch then
				progression:awardCreatureKill(player, branch, enemy.xp * (T.firstBossXp - 1), enemy.id, enemy.level)
			end
			log:info("wildborn_boss_slain", { userId = userId, boss = enemy.id, first = true })
			first = true
		end
	end
	return first
end

local function die(actor: Actor)
	forget(actor)
	local enemy = actor.enemy
	local home = actor.home
	actor.slot.generation += 1
	if enemy.boss then
		home.killedAt = os.time()
		actor.slot.respawnAt = 0 -- gated by bossBack instead
	else
		actor.slot.respawnAt = if home.temporary then math.huge else os.clock() + T.respawn.min + actor.rng:NextNumber() * (T.respawn.max - T.respawn.min)
	end
	creatures:rewardFor(enemy, actor.dealt, actor.branch, actor.root.Position)
	if enemy.boss then
		local first = payBoss(actor)
		-- The world remembers it (Services/ChronicleService): whoever did most first.
		local by: { number } = {}
		for userId in actor.dealt do
			table.insert(by, userId)
		end
		table.sort(by, function(x, y)
			return actor.dealt[x] > actor.dealt[y]
		end)
		if #by > 0 and bus then
			local at = actor.root.Position
			bus:publish(Topics.DeedDone, { kind = "boss_slain", x = at.X, z = at.Z, by = by, what = enemy.name, first = first })
		end
	end
	local killers = 0
	for _ in actor.dealt do
		killers += 1
	end
	log:info("wildborn_killed", { enemy = enemy.id, home = home.id, killers = killers })
	-- It crumbles where it fell into its theme's colour, then goes.
	local model = actor.model
	actor.root.Anchored = true
	for _, track in actor.tracks do
		track:Stop(0.2)
	end
	task.spawn(function()
		local parts: { BasePart } = {}
		for _, d in model:GetDescendants() do
			if d:IsA("BasePart") and d.Transparency < 1 then
				table.insert(parts, d)
			elseif d:IsA("ParticleEmitter") then
				d.Enabled = false
			end
		end
		for step = 1, 6 do
			task.wait(0.2)
			for _, part in parts do
				part.Transparency = math.max(part.Transparency, step / 6)
			end
		end
		model:Destroy()
	end)
end

-- ─── Thinking ───────────────────────────────────────────────────────────────

local function viewOf(players: { View }, userId: number?): View?
	if not userId then
		return nil
	end
	for _, view in players do
		if view.player.UserId == userId then
			return view
		end
	end
	return nil
end

local function stepActor(actor: Actor, players: { View }, now: number)
	local enemy = actor.enemy
	local humanoid, root = actor.humanoid, actor.root
	local home = actor.home.center or root.Position
	local position = root.Position

	-- Walking or standing: the right loop.
	local moving = root.AssemblyLinearVelocity.Magnitude > 1.5
	if moving ~= actor.moving then
		actor.moving = moving
		local walk, idle = actor.tracks.walk, actor.tracks.idle
		if walk and idle then
			if moving then
				idle:Stop(0.2)
				walk:Play(0.2)
			else
				walk:Stop(0.2)
				idle:Play(0.2)
			end
		end
	end

	-- Frozen, rooted or in stasis (a walk-0 status, Cast/StatusEffects): no moves either.
	if humanoid:GetAttribute("KnockedDown") or actor.model:GetAttribute("GravityHeld") or humanoid.WalkSpeed <= 0.01 then
		return
	end

	-- A captive (Services/DownedService): when the hold runs out it lets them be and wanders off.
	local hold = actor.hold
	if hold and now >= hold.untilClock then
		actor.hold = nil
		actor.spare = actor.spare or {}
		;(actor.spare :: { [number]: number })[hold.userId] = now + hold.wander + 30
		local angle = actor.rng:NextNumber() * 2 * math.pi
		actor.wanderTo = home + Vector3.new(math.cos(angle) * 90, 0, math.sin(angle) * 90)
		actor.wanderUntil = now + hold.wander
	end
	if actor.wanderUntil and now < actor.wanderUntil and actor.wanderTo and not (actor.attacker and now < actor.attackerUntil) then
		humanoid:MoveTo(actor.wanderTo :: Vector3)
		return
	end

	-- Too far from home: it goes back and heals (and forgets the fight).
	if Rules.shouldReturn(flat(position, home), enemy.leash) then
		actor.returning = true
	end
	if actor.returning then
		if flat(position, home) < 6 then
			actor.returning = false
			humanoid.Health = humanoid.MaxHealth
			table.clear(actor.dealt)
			table.clear(actor.branch)
			table.clear(actor.used)
		else
			humanoid:MoveTo(home)
			return
		end
	end

	-- Who: whoever hurt it lately, else the nearest within aggro; nobody past deaggro.
	if now >= actor.attackerUntil then
		actor.attacker = nil
	end
	local target = viewOf(players, actor.attacker)
	if not target then
		local best = enemy.aggro
		for _, view in players do
			local d = flat(view.position, position)
			local uid = view.player.UserId
			local spared = (actor.spare and (actor.spare[uid] or 0) > now)
				or (hold ~= nil and actor.hold ~= nil and hold.userId == uid and flat(view.position, hold.center) <= hold.radius)
			if d <= best and not spared then
				target, best = view, d
			end
		end
	end
	if target and flat(target.position, position) > enemy.deaggro then
		target = nil
	end
	actor.target = target
	if not target then
		-- Nobody to fight: drift back toward home.
		if flat(position, home) > 12 then
			humanoid:MoveTo(home)
		end
		return
	end

	if now < actor.busyUntil then
		humanoid:MoveTo(position) -- standing still while it casts
		return
	end
	local distance = flat(target.position, position)
	local index, move = Rules.chooseMove(enemy, {
		distance = distance,
		healthShare = humanoid.Health / humanoid.MaxHealth,
		now = now,
		readyAt = actor.readyAt,
		used = actor.used,
	})
	if index and move then
		actor.readyAt[index] = now + (move.cd or 5)
		if move.once then
			actor.used[index] = true
		end
		humanoid:MoveTo(position)
		play(actor, "CastSpell")
		local ok, busy = pcall(Moves.run, actor, move, target)
		actor.busyUntil = now + (if ok and typeof(busy) == "number" then busy else 0.5)
		if not ok then
			log:warn("wildborn_move_failed", { enemy = enemy.id, move = move.move, err = tostring(busy) })
		end
		return
	end
	local reach = enemy.melee.reach * enemy.scale
	if distance <= reach then
		humanoid:MoveTo(position)
		if now >= actor.nextMelee then
			actor.nextMelee = now + enemy.melee.cooldown
			play(actor, "Slash1")
			Moves.melee(actor, target)
		end
	else
		humanoid:MoveTo(target.position)
	end
end

local function step()
	local players = livingPlayers()
	local now = os.clock()
	for i = #alive, 1, -1 do
		local actor = alive[i]
		if not actor.model.Parent or actor.root.Position.Y < WorldConfig.SEA_LEVEL - 60 then
			forget(actor)
			actor.slot.respawnAt = if actor.home.temporary then math.huge else now + 10
			actor.model:Destroy()
		elseif actor.humanoid.Health <= 0 then
			die(actor)
		else
			local ok, err = pcall(stepActor, actor, players, now)
			if not ok then
				log:warn("wildborn_step_failed", { enemy = actor.enemy.id, err = tostring(err) })
			end
		end
	end
end

local function onDamaged(payload: any)
	local actor = byModel[payload.model]
	local source: number? = payload.sourceUserId
	if not actor or not source then
		return
	end
	actor.dealt[source] = (actor.dealt[source] or 0) + payload.amount
	if payload.branch then
		actor.branch[source] = payload.branch
	end
	actor.attacker = source
	actor.attackerUntil = os.clock() + 12
end

-- ─── Rumours ────────────────────────────────────────────────────────────────

local function rumor(player: Player, npc: any): string?
	if not enabled() then
		return nil
	end
	local at: Vector3? = npc and npc.position
	local record = recordOf(player)
	if typeof(at) ~= "Vector3" or not record then
		return nil
	end
	local roll = Seed.random(worldService:getSeed(), "player:" .. player.UserId, "wildborn_story:" .. tostring(npc.id)):NextNumber()
	if roll >= T.rumorChance then
		return nil
	end
	local best: Home?, bestD = nil, math.huge
	for _, home in lairByTheme do
		local d = flat(at, Vector3.new(home.x, 0, home.z))
		if not record.heard[home.theme] and d < bestD then
			best, bestD = home, d
		end
	end
	if not best then
		return nil
	end
	local theme = Data.themes[best.theme]
	local boss = Data.enemies[best.enemy]
	record.heard[best.theme] = os.time()
	map:revealArea(player, best.x, best.z, 60)
	local text = string.gsub(string.gsub(theme.story, "{dir}", OmenRules.bearing(at.X, at.Z, best.x, best.z)), "{name}", boss.title and (string.gsub(boss.title, "^the ", "The ")) or boss.name)
	journal:log(player, "wildborn", "I heard a story: " .. text, { wildborn = best.enemy, quiet = true })
	log:info("wildborn_story", { userId = player.UserId, theme = best.theme })
	return text
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	local ids: { string } = {}
	for id in Data.enemies do
		table.insert(ids, id)
	end
	table.sort(ids)

	admin:Register({
		name = "wildborn",
		category = "World",
		description = "Wildborn: spawn one in front of you, list the nearest haunts, list lairs, go to a theme's lair, clear every living one, or bring the beaten bosses back",
		args = {
			{ name = "action", type = "enum", options = { "spawn", "list", "lairs", "goto", "clear", "revive" } },
			{ name = "what", type = "string", optional = true },
		},
		handler = function(ctx: any, a: any)
			if a.action == "spawn" then
				if not a.what or not Data.enemies[a.what] then
					return "which? " .. table.concat(ids, ", ")
				end
				local at = Util.ahead(ctx.player, world, 22)
				if not at then
					return "no character"
				end
				tempCount += 1
				local enemy = Data.enemies[a.what]
				local home: Home = {
					id = "temp:" .. tempCount, enemy = a.what, theme = enemy.theme, x = at.X, z = at.Z,
					boss = enemy.boss, slots = { { actor = nil, respawnAt = math.huge, generation = 0 } },
					awake = true, temporary = true, center = groundAt(at.X, at.Z) or at, marker = nil, killedAt = nil,
				}
				table.insert(homes, home)
				local ok = spawnActor(home, 1, home.slots[1])
				home.slots[1].respawnAt = math.huge
				return if ok then string.format("spawned %s (no respawn; gone when you walk away)", enemy.name) else "couldn't place it (water or unbuilt ground?)"
			elseif a.action == "clear" then
				local n = #alive
				for i = #alive, 1, -1 do
					local actor = alive[i]
					forget(actor)
					actor.slot.respawnAt = if actor.home.temporary then math.huge else os.clock() + 30
					actor.model:Destroy()
				end
				return string.format("cleared %d Wildborn (haunts refill in 30 s)", n)
			elseif a.action == "revive" then
				for _, home in lairByTheme do
					home.killedAt = nil
				end
				return "every beaten boss is back in its lair"
			elseif a.action == "lairs" then
				local lines = {}
				for _, themeId in Data.themeOrder do
					local home = lairByTheme[themeId]
					if home then
						table.insert(lines, string.format("%s: %s at (%.0f, %.0f) %s%s", themeId, home.enemy, home.x, home.z,
							if home.awake then "awake" else "asleep", if home.killedAt then string.format(", beaten %d s ago", os.time() - home.killedAt) else ""))
					else
						table.insert(lines, themeId .. ": no lair (this world has none of its biomes)")
					end
				end
				return table.concat(lines, "\n")
			elseif a.action == "goto" then
				local home = a.what and lairByTheme[a.what]
				local root = Util.rootOf(ctx.player)
				if not home or not root then
					return "which theme? " .. table.concat(Data.themeOrder, ", ")
				end
				local ground = groundAt(home.x + T.lairRadius + 30, home.z) or Vector3.new(home.x + T.lairRadius + 30, world:surfaceHeight(home.x, home.z) + 5, home.z)
				ctx.player.Character:PivotTo(CFrame.new(ground + Vector3.new(0, 4, 0)))
				return string.format("near %s's lair (%.0f, %.0f)", home.enemy, home.x, home.z)
			end
			-- list: the nearest haunts
			local root = Util.rootOf(ctx.player)
			if not root then
				return "no character"
			end
			local sorted = table.clone(homes)
			table.sort(sorted, function(x, y)
				return flat(root.Position, Vector3.new(x.x, 0, x.z)) < flat(root.Position, Vector3.new(y.x, 0, y.z))
			end)
			local lines = { string.format("%d haunts and lairs, %d alive (%d ordinary of %d)", #homes, #alive, regularAlive(), T.maxAlive) }
			for i = 1, math.min(10, #sorted) do
				local home = sorted[i]
				local living = 0
				for _, slot in home.slots do
					if slot.actor then
						living += 1
					end
				end
				table.insert(lines, string.format("%s  %s  %.0f studs  (%.0f, %.0f)  %d/%d  %s", home.id, home.enemy,
					flat(root.Position, Vector3.new(home.x, 0, home.z)), home.x, home.z, living, #home.slots, if home.awake then "awake" else "asleep"))
			end
			local p, z = Moves.counts()
			table.insert(lines, string.format("in flight: %d projectiles, %d zones", p, z))
			return table.concat(lines, "\n")
		end,
	})
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

local function planWorld()
	world:awaitReady()
	local placement = world:placement()
	local gen = world:gen()
	local towns: { Rules.Town } = {}
	for _, settlement in placement.settlements do
		local poi = placement.byId[settlement.id]
		if poi then
			table.insert(towns, { x = poi.x, z = poi.z })
		end
	end
	local function sample(x: number, z: number): Rules.Sample
		local h = gen:height(x, z)
		local slope = math.max(math.abs(gen:height(x + 8, z) - h), math.abs(gen:height(x, z + 8) - h)) / 8
		return { biome = gen:sample(x, z).biome, height = h, slope = slope }
	end
	local seed = worldService:getSeed()
	for _, haunt in Rules.planHaunts(seed, sample, towns, WorldConfig.WORLD_SIZE, WorldConfig.SEA_LEVEL) do
		local slots: { Slot } = {}
		for i = 1, haunt.count do
			slots[i] = { actor = nil, respawnAt = 0, generation = 0 }
		end
		table.insert(homes, {
			id = haunt.id, enemy = haunt.enemy, theme = haunt.theme, x = haunt.x, z = haunt.z, boss = false,
			slots = slots, awake = false, temporary = false, center = nil, marker = nil, killedAt = nil,
		})
	end
	local lairs = Rules.planLairs(seed, sample, towns, WorldConfig.WORLD_SIZE, WorldConfig.SEA_LEVEL)
	local lairCount = 0
	for themeId, lair in lairs do
		local home: Home = {
			id = lair.id, enemy = lair.enemy, theme = themeId, x = lair.x, z = lair.z, boss = true,
			slots = { { actor = nil, respawnAt = 0, generation = 0 } }, awake = false, temporary = false,
			center = nil, marker = nil, killedAt = nil,
		}
		table.insert(homes, home)
		lairByTheme[themeId] = home
		lairCount += 1
	end
	log:info("wildborn_planned", { haunts = #homes - lairCount, lairs = lairCount })
end

-- ─── Captives (Services/DownedService) ─────────────────────────────────────

-- The Wildborn behind this model and where it lives, or nil.
function WildbornService.captorOf(_self: any, model: Model?): { center: Vector3, name: string, boss: boolean, home: string }?
	local actor = model and byModel[model]
	if not actor or actor.humanoid.Health <= 0 then
		return nil
	end
	local home = actor.home
	local center = home.center or groundAt(home.x, home.z)
	if not center then
		return nil
	end
	return { center = center, name = actor.enemy.name, boss = home.boss, home = home.id }
end

-- The nearest living Wildborn within `reach` of `at` (admin `downme capture`), or nil.
function WildbornService.nearestCaptor(_self: any, at: Vector3, reach: number): Model?
	local best: Model?, bestD = nil, reach
	for _, actor in alive do
		local d = flat(actor.root.Position, at)
		if actor.humanoid.Health > 0 and d <= bestD then
			best, bestD = actor.model, d
		end
	end
	return best
end

-- Hold a captive: it leaves them be inside `radius` of `center` for `seconds`, then wanders off for
-- `wander` seconds. Returns false if the captor is gone.
function WildbornService.hold(_self: any, model: Model, userId: number, center: Vector3, radius: number, seconds: number, wander: number): boolean
	local actor = byModel[model]
	if not actor or actor.humanoid.Health <= 0 then
		return false
	end
	actor.hold = { userId = userId, center = center, radius = radius, untilClock = os.clock() + seconds, wander = wander }
	actor.attacker = nil
	actor.target = nil
	actor.returning = false
	actor.wanderUntil = nil
	return true
end

-- Whether this captor still lives and still holds this person.
function WildbornService.holding(_self: any, model: Model, userId: number): (boolean, boolean)
	local actor = byModel[model]
	local living = actor ~= nil and actor.humanoid.Health > 0 and model.Parent ~= nil
	return living, living and actor.hold ~= nil and (actor.hold :: any).userId == userId
end

-- Boss lairs, and whether their boss is beaten on this server (Services/RumorService).
function WildbornService.lairs(_self: any): { { id: string, theme: string, x: number, z: number, beaten: boolean } }
	local out = {}
	for theme, home in lairByTheme do
		local beaten = home.killedAt ~= nil and not Rules.bossBack(home.killedAt, os.time())
		table.insert(out, { id = home.id, theme = theme, x = home.x, z = home.z, beaten = beaten })
	end
	return out
end

function WildbornService.init(_self: any, ctx: any)
	log = ctx.log
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	creatures = ctx.get("CreatureService")
	journal = ctx.get("JournalService")
	map = ctx.get("MapService")
	playerData = ctx.get("PlayerDataService")
	progression = ctx.get("ProgressionService")
	Moves.setPlayers(livingPlayers)
	bus = ctx.bus
	ctx.bus:subscribe(Topics.TargetDamaged, onDamaged)
	ctx.get("NPCService"):setRumorHook(rumor)
	registerAdmin(ctx.get("AdminService"))
end

function WildbornService.start(_self: any, _ctx: any)
	local parent = Instance.new("Folder")
	parent.Name = "Wildborn"
	parent.Parent = workspace
	folder = parent
	Moves.start()
	task.spawn(function()
		local ok, err = pcall(planWorld)
		if not ok then
			log:warn("wildborn_plan_failed", { err = tostring(err) })
			return
		end
		local sinceWake = 0
		while true do
			task.wait(T.stepSeconds)
			if enabled() then
				sinceWake += T.stepSeconds
				if sinceWake >= 1 then
					sinceWake = 0
					local okWake, errWake = pcall(wakeTick)
					if not okWake then
						log:warn("wildborn_wake_failed", { err = tostring(errWake) })
					end
				end
				step()
			elseif #alive > 0 then
				for _, home in table.clone(homes) do
					if home.awake then
						sleepHome(home)
					end
				end
			end
		end
	end)
end

return WildbornService
