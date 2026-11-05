--!strict
--[[
	CreatureService: wild creatures around towns (docs/EarlyGamePlan.md §7). The first slice of the
	"creatures" world stage. Content: Creatures/Data/Creatures. Decisions: Creatures/CreatureRules.

	LIFECYCLE
		Dens are data, planned once and the same on every server (Seed.random(worldSeed,
		"settlement:<id>", "creatures")). A den wakes when a player comes within wakeRadius and its
		chunk is built, and its members are built then; it sleeps past sleepRadius and they're
		destroyed. Nobody near = no instances and no cost. creatures_max_alive caps the total; when
		dens compete, the nearest fill first.
	STEP (every stepSeconds, awake creatures only)
		Straight-line Humanoid:MoveTo, no pathfinding. A creature that gets stuck picks a new goal;
		it's a critter, not a hunter. Statuses and knockdowns work through the Humanoid.
	DAMAGE
		In: the normal pipeline. Resist_<key> attributes hold its weaknesses, and hitting one is never
		a crime (Cast/Damage marks it `practice`). Out: bites go through Damage.apply, so guards,
		wards and parries work; bites have no source UserId.
	DEATH + REWARDS
		Noticed in the step, by Health, so every way of dying counts and the killing blow's
		TargetDamaged has already been tallied. Everyone who dealt creditShare of its health gets XP
		(challenge channel, to the branch they last hit it with; weapon-only kills give no magic XP)
		and their own seeded loot roll, both scaled by rewardFactor(kills of this type this hour),
		saved in PlayerData.creatureHunt so hopping servers doesn't reset it.

	Admin: creature, creatures, creaturedens.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)

local Server = script.Parent.Parent
local Creatures = require(Server.Creatures.Data.Creatures)
local CreatureRules = require(Server.Creatures.CreatureRules)
local CreatureRig = require(Server.Creatures.CreatureRig)
local Damage = require(Server.Magic.Cast.Damage)
local WorldConfig = require(Server.World.WorldConfig)
local Util = require(Server.Admin.Util)

local T = Creatures.tuning

local CreatureService = {
	name = "CreatureService",
	dependencies = { "AdminService", "EffectRunner", "InventoryService", "PlayerDataService", "ProgressionService", "WorldService", "WorldStateService" },
}

type Slot = { creature: Creature?, respawnAt: number, generation: number }

type DenState = {
	id: string,
	type: string,
	settlementId: string,
	x: number,
	z: number,
	slots: { Slot },
	awake: boolean,
	temporary: boolean, -- made by the admin `creature spawn`: no respawns, removed when it sleeps
	center: Vector3?, -- ground position, known once awake
	nest: BasePart?,
}

type Creature = {
	def: Creatures.Def,
	den: DenState,
	slot: Slot,
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	rng: Random,
	dealt: { [number]: number }, -- userId -> damage dealt
	branch: { [number]: string }, -- userId -> the branch that last hit it
	attacker: number?,
	attackerUntil: number,
	returning: boolean,
	nextGoal: number,
	nextBite: number,
	nextWord: number,
}

type PlayerView = { player: Player, humanoid: Humanoid, root: BasePart, position: Vector3 }

local log: any = nil
local world: any = nil
local worldService: any = nil
local runner: any = nil
local inventory: any = nil
local playerData: any = nil
local progression: any = nil

local dens: { DenState } = {}
local alive: { Creature } = {}
local byModel: { [Model]: Creature } = {}
local folder: Folder? = nil
local adminDens = 0
local terrainParams: RaycastParams? = nil

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function enabled(): boolean
	return FeatureFlags.get("creatures_enabled") == true
end

local function budget(): number
	return tonumber(FeatureFlags.get("creatures_max_alive")) or T.maxAlive
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- Dry terrain at (x, z), or nil. Asks the built terrain, not the generator, so edits and water count.
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

-- ─── Spawning ───────────────────────────────────────────────────────────────

local function spawnMember(den: DenState, index: number, slot: Slot): boolean
	local def = Creatures.defs[den.type]
	local rng = Seed.random(worldService:getSeed(), den.id, "creature_member", index * 1000 + slot.generation)
	local angle = rng:NextNumber() * 2 * math.pi
	local distance = rng:NextNumber() * T.denRadius
	local ground = groundAt(den.x + math.cos(angle) * distance, den.z + math.sin(angle) * distance)
	if not ground then
		slot.respawnAt = os.clock() + 5 -- water or unbuilt ground here right now: try again shortly
		return false
	end
	local height = def.hipHeight + def.hitbox.Y / 2 + 0.5
	local at = CFrame.new(ground + Vector3.new(0, height, 0)) * CFrame.Angles(0, rng:NextNumber() * 2 * math.pi, 0)
	local model, humanoid, root = CreatureRig.build(def, at)
	model:SetAttribute("CreatureDen", den.id)
	model.Parent = folder
	pcall(function()
		root:SetNetworkOwner(nil) -- server-driven: a nearby client can't own (and teleport) it
	end)
	local creature: Creature = {
		def = def,
		den = den,
		slot = slot,
		model = model,
		humanoid = humanoid,
		root = root,
		rng = rng,
		dealt = {},
		branch = {},
		attacker = nil,
		attackerUntil = 0,
		returning = false,
		nextGoal = os.clock() + rng:NextNumber() * 3,
		nextBite = 0,
		nextWord = 0,
	}
	slot.creature = creature
	table.insert(alive, creature)
	byModel[model] = creature
	return true
end

local function forget(creature: Creature)
	byModel[creature.model] = nil
	creature.slot.creature = nil
	local index = table.find(alive, creature)
	if index then
		table.remove(alive, index)
	end
end

local function makeNest(den: DenState)
	local center = den.center
	if den.nest or not center then
		return
	end
	local nest = Instance.new("Part")
	nest.Name = "CreatureDen"
	nest.Size = Vector3.new(7, 1.6, 7)
	CreatureRig.ellipsoid(nest)
	nest.CFrame = CFrame.new(center)
	nest.Color = Creatures.defs[den.type].nestColor
	nest.Material = Enum.Material.Ground
	nest.Anchored = true
	nest.CanCollide = false
	nest.CanTouch = false
	nest.CanQuery = false
	nest.CastShadow = false
	nest:SetAttribute("Flammability", 0)
	nest.Parent = folder
	den.nest = nest
end

local function sleepDen(den: DenState)
	den.awake = false
	for _, slot in den.slots do
		local creature = slot.creature
		if creature then
			forget(creature)
			creature.model:Destroy()
		end
	end
	if den.nest then
		den.nest:Destroy()
		den.nest = nil
	end
	if den.temporary then
		local index = table.find(dens, den)
		if index then
			table.remove(dens, index)
		end
	end
end

-- Once a second: wake and sleep dens, and fill the awake ones nearest-first within the budget.
local function wakeTick()
	local players = livingPlayers()
	local now = os.clock()
	local want: { { den: DenState, index: number, slot: Slot, distance: number } } = {}
	for i = #dens, 1, -1 do
		local den = dens[i]
		local position = Vector3.new(den.x, 0, den.z)
		local nearest = math.huge
		for _, view in players do
			nearest = math.min(nearest, flat(view.position, position))
		end
		if den.awake and nearest > T.sleepRadius then
			sleepDen(den)
		elseif not den.awake and nearest <= T.wakeRadius and world:isChunkBuilt(den.x, den.z) then
			den.center = groundAt(den.x, den.z)
			if den.center then
				den.awake = true
				makeNest(den)
			end
		end
		if den.awake then
			for index, slot in den.slots do
				local camped = slot.generation > 0 and nearest < T.campRadius
				if not slot.creature and now >= slot.respawnAt and not camped then
					table.insert(want, { den = den, index = index, slot = slot, distance = nearest })
				end
			end
		end
	end
	table.sort(want, function(a, b)
		return a.distance < b.distance
	end)
	local room = math.min(T.spawnsPerSecond, budget() - #alive)
	for _, entry in want do
		if room <= 0 then
			break
		end
		if spawnMember(entry.den, entry.index, entry.slot) then
			room -= 1
		end
	end
end

-- ─── Death and rewards ──────────────────────────────────────────────────────

local function rewardOne(creature: Creature, userId: number)
	local player = Players:GetPlayerByUserId(userId)
	local state = player and playerData:get(player)
	if not player or not state then
		return
	end
	local def = creature.def
	local hunt = state.data.creatureHunt
	if not hunt then
		hunt = { hour = 0, total = 0, byType = {} }
		state.data.creatureHunt = hunt
	end
	local hour = math.floor(os.time() / 3600)
	if hunt.hour ~= hour then
		hunt.hour, hunt.byType = hour, {}
	end
	local kills = hunt.byType[def.id] or 0
	local factor = CreatureRules.rewardFactor(kills)
	hunt.byType[def.id] = kills + 1
	hunt.total += 1

	local branch = creature.branch[userId]
	if branch then
		progression:awardCreatureKill(player, branch, def.xp * factor, def.id, def.level)
	end
	local rng = Seed.random(worldService:getSeed(), "player:" .. userId, "creature_loot:" .. def.id, hunt.total)
	local items, coins = CreatureRules.rollLoot(def, rng, factor)
	for _, entry in items do
		inventory:give(player, entry.item, entry.n)
	end
	if coins > 0 then
		inventory:addCurrency(player, coins, "creature:" .. def.id)
	end
	log:info("creature_killed", { userId = userId, type = def.id, branch = branch, factor = math.floor(factor * 100) / 100, items = #items, coins = coins })
end

local function die(creature: Creature)
	forget(creature)
	local def = creature.def
	local slot = creature.slot
	slot.generation += 1
	slot.respawnAt = if creature.den.temporary
		then math.huge
		else os.clock() + def.respawn.min + creature.rng:NextNumber() * (def.respawn.max - def.respawn.min)
	local need = def.health * T.creditShare
	for userId, dealt in creature.dealt do
		if dealt >= need then
			rewardOne(creature, userId)
		end
	end
	-- Fades where it fell. Anchored so it doesn't roll off during the fade.
	local model = creature.model
	creature.root.Anchored = true
	task.spawn(function()
		local parts: { BasePart } = {}
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") and child.Transparency < 1 then
				table.insert(parts, child)
			elseif child:IsA("ParticleEmitter") then
				child.Enabled = false
			end
		end
		for step = 1, 4 do
			task.wait(T.fadeSeconds / 4)
			for _, part in parts do
				part.Transparency = math.max(part.Transparency, step / 4)
			end
		end
		model:Destroy()
	end)
end

-- ─── Step ───────────────────────────────────────────────────────────────────

local function bite(creature: Creature, target: PlayerView, distance: number, now: number)
	local b = creature.def.bite
	if not b or distance > b.reach or now < creature.nextBite then
		return
	end
	creature.nextBite = now + b.cooldown
	Damage.apply(target.humanoid, b.damage, nil, "creature_bite", {
		domain = creature.def.domain,
		from = creature.root.Position,
		property = b.property,
		form = "touch",
		power = creature.def.level,
		attacker = creature.model,
	})
end

local function wander(creature: Creature, den: Vector3, now: number)
	if now < creature.nextGoal then
		return
	end
	local pause = T.wanderPause
	creature.nextGoal = now + pause.min + creature.rng:NextNumber() * (pause.max - pause.min)
	local position = creature.root.Position
	local angle = creature.rng:NextNumber() * 2 * math.pi
	local goal = position + Vector3.new(math.cos(angle), 0, math.sin(angle)) * (T.wanderStep * (0.4 + creature.rng:NextNumber() * 0.6))
	goal = CreatureRules.clampToLeash(den, goal, creature.def.leash * 0.6)
	-- Don't amble into the sea: stay put for this beat instead.
	if world:surfaceHeight(goal.X, goal.Z) >= WorldConfig.SEA_LEVEL + 1 then
		creature.humanoid:MoveTo(goal)
	end
end

local function stepCreature(creature: Creature, players: { PlayerView }, now: number)
	local humanoid, root = creature.humanoid, creature.root
	local den = creature.den.center or root.Position
	local position = root.Position

	-- Nearest player to it and to its den, and whoever last hit it, if they're still around.
	local nearest: PlayerView? = nil
	local nearestDistance, playerToDen = math.huge, math.huge
	local attacker: PlayerView? = nil
	for _, view in players do
		local d = flat(view.position, position)
		if d < nearestDistance then
			nearest, nearestDistance = view, d
		end
		playerToDen = math.min(playerToDen, flat(view.position, den))
		if view.player.UserId == creature.attacker then
			attacker = view
		end
	end
	if now >= creature.attackerUntil then
		attacker = nil
		creature.attacker = nil
	end

	local toDen = flat(position, den)
	local action = CreatureRules.decide(creature.def, {
		distanceToDen = toDen,
		returning = creature.returning,
		hasAttacker = attacker ~= nil,
		nearestPlayer = if nearest then nearestDistance else nil,
		playerToDen = if nearest then playerToDen else nil,
	})

	-- Home again: it gets its health back and forgets the fight, so kiting a creature to the edge of
	-- its leash and back doesn't whittle it down for free.
	if creature.returning and action ~= "return" then
		creature.returning = false
		humanoid.Health = humanoid.MaxHealth
		table.clear(creature.dealt)
		table.clear(creature.branch)
	end

	-- Knocked down or flinching: no moving (bites wait too). Slows just lower WalkSpeed.
	if humanoid:GetAttribute("KnockedDown") then
		return
	end

	if action == "return" then
		creature.returning = true
		creature.attacker = nil
		humanoid:MoveTo(den)
	elseif action == "chase" then
		local target = attacker or nearest
		if target then
			humanoid:MoveTo(target.position)
			bite(creature, target, flat(target.position, position), now)
		end
	elseif action == "flee" then
		local from = attacker or nearest
		if from then
			local away = Vector3.new(position.X - from.position.X, 0, position.Z - from.position.Z)
			local dir = if away.Magnitude > 0.1 then away.Unit else root.CFrame.LookVector
			humanoid:MoveTo(CreatureRules.clampToLeash(den, position + dir * T.fleeStep, creature.def.leash))
		end
	else
		wander(creature, den, now)
	end
end

local function step()
	local players = livingPlayers()
	local now = os.clock()
	for i = #alive, 1, -1 do
		local creature = alive[i]
		if not creature.model.Parent or creature.root.Position.Y < WorldConfig.SEA_LEVEL - 60 then
			-- Destroyed from outside, or fell through the world: it comes back, nobody gets paid.
			forget(creature)
			creature.slot.respawnAt = if creature.den.temporary then math.huge else now + 10
			creature.model:Destroy()
		elseif creature.humanoid.Health <= 0 then
			die(creature)
		else
			stepCreature(creature, players, now)
		end
	end
end

-- ─── Being hit ──────────────────────────────────────────────────────────────

local function angerPack(creature: Creature, source: number, now: number)
	local until_ = now + T.attackerMemory
	for _, slot in creature.den.slots do
		local mate = slot.creature
		if mate then
			mate.attacker = source
			mate.attackerUntil = until_
		end
	end
end

local function onDamaged(payload: any)
	local creature = byModel[payload.model]
	local source: number? = payload.sourceUserId
	if not creature or not source then
		return
	end
	creature.dealt[source] = (creature.dealt[source] or 0) + payload.amount
	if payload.branch then
		creature.branch[source] = payload.branch
	end
	local now = os.clock()
	if creature.def.behaviour == "wander" then
		creature.attacker = source
		creature.attackerUntil = now + T.attackerMemory
	else
		angerPack(creature, source, now)
	end
	-- "Weak!" / "Resists" over the target: how a player learns what works, with no bestiary yet.
	local domain = payload.domain
	local resist = if domain then creature.def.resist[domain] else nil
	if resist and now >= creature.nextWord and (resist <= T.weakAt or resist >= T.resistAt) then
		creature.nextWord = now + T.wordCooldown
		local weak = resist <= T.weakAt
		runner:cue("statusTag", {
			status = if weak then "creature_weak" else "creature_resist",
			name = if weak then "Weak!" else "Resists",
			harmful = weak,
			caster = source,
		}, creature.root.Position + Vector3.new(0, creature.def.hitbox.Y / 2 + 1, 0), false)
	end
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "creature",
		category = "World",
		description = "Spawn creatures in front of you (a temporary den, no respawns), or clear every living creature",
		args = {
			{ name = "action", type = "enum", options = { "spawn", "clear" } },
			{ name = "type", type = "enum", options = table.clone(Creatures.ids), optional = true },
			{ name = "count", type = "number", min = 1, max = 10, default = 3 },
		},
		handler = function(ctx: any, a: any)
			if a.action == "clear" then
				local n = #alive
				for i = #alive, 1, -1 do
					local creature = alive[i]
					forget(creature)
					creature.slot.respawnAt = if creature.den.temporary then math.huge else os.clock() + 30
					creature.model:Destroy()
				end
				return string.format("cleared %d creatures (dens refill in 30 s)", n)
			end
			if not a.type then
				return "which type? " .. table.concat(Creatures.ids, ", ")
			end
			local at = Util.ahead(ctx.player, world, 18)
			if not at then
				return "no character"
			end
			adminDens += 1
			local count = math.floor(a.count)
			local den: DenState = {
				id = "admin:" .. adminDens,
				type = a.type,
				settlementId = "admin",
				x = at.X,
				z = at.Z,
				slots = {},
				awake = true,
				temporary = true,
				center = groundAt(at.X, at.Z) or at,
				nest = nil,
			}
			local spawned = 0
			for i = 1, count do
				local slot: Slot = { creature = nil, respawnAt = math.huge, generation = 0 }
				den.slots[i] = slot
				if spawnMember(den, i, slot) then
					spawned += 1
				else
					slot.respawnAt = math.huge
				end
			end
			table.insert(dens, den)
			return string.format("spawned %d %s (budget doesn't apply to this command)", spawned, a.type)
		end,
	})

	admin:Register({
		name = "creatures",
		category = "World",
		description = "How many creatures are alive by type, the budget, and your kills this hour",
		args = {},
		handler = function(ctx: any, _a: any)
			local counts: { [string]: number } = {}
			for _, creature in alive do
				counts[creature.def.id] = (counts[creature.def.id] or 0) + 1
			end
			local awake = 0
			for _, den in dens do
				if den.awake then
					awake += 1
				end
			end
			local lines = { string.format("alive %d / %d, dens awake %d / %d", #alive, budget(), awake, #dens) }
			local state = playerData:get(ctx.player)
			local hunt = state and state.data.creatureHunt
			for _, id in Creatures.ids do
				local kills = if hunt and hunt.hour == math.floor(os.time() / 3600) then hunt.byType[id] or 0 else 0
				table.insert(lines, string.format("%s: %d alive, you killed %d this hour (reward x%.2f)", id, counts[id] or 0, kills, CreatureRules.rewardFactor(kills)))
			end
			return table.concat(lines, "\n")
		end,
	})

	admin:Register({
		name = "creaturedens",
		category = "World",
		description = "The dens nearest you: type, town, distance, members",
		args = {},
		handler = function(ctx: any, _a: any)
			local root = Util.rootOf(ctx.player)
			if not root then
				return "no character"
			end
			local sorted = table.clone(dens)
			local position = root.Position
			table.sort(sorted, function(a, b)
				return flat(position, Vector3.new(a.x, 0, a.z)) < flat(position, Vector3.new(b.x, 0, b.z))
			end)
			local lines = { string.format("%d dens", #dens) }
			for i = 1, math.min(10, #sorted) do
				local den = sorted[i]
				local living = 0
				for _, slot in den.slots do
					if slot.creature then
						living += 1
					end
				end
				table.insert(lines, string.format(
					"%s  %s  %.0f studs  (%.0f, %.0f)  %d/%d  %s",
					den.id, den.type, flat(position, Vector3.new(den.x, 0, den.z)), den.x, den.z, living, #den.slots, if den.awake then "awake" else "asleep"
				))
			end
			return table.concat(lines, "\n")
		end,
	})
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

local function planWorld()
	world:awaitReady()
	local placement = world:placement()
	local gen = world:gen()
	local towns: { CreatureRules.Town } = {}
	for _, settlement in placement.settlements do
		local poi = placement.byId[settlement.id]
		if poi then
			table.insert(towns, { id = settlement.id, x = poi.x, z = poi.z, radius = poi.radius, biome = poi.biome })
		end
	end
	local plan = CreatureRules.planDens(worldService:getSeed(), towns, function(x: number, z: number): (number, number)
		local h = gen:height(x, z)
		return h, math.max(math.abs(gen:height(x + 8, z) - h), math.abs(gen:height(x, z + 8) - h)) / 8
	end, WorldConfig.SEA_LEVEL)
	for _, den in plan do
		local slots: { Slot } = {}
		for i = 1, den.count do
			slots[i] = { creature = nil, respawnAt = 0, generation = 0 }
		end
		table.insert(dens, {
			id = den.id,
			type = den.type,
			settlementId = den.settlementId,
			x = den.x,
			z = den.z,
			slots = slots,
			awake = false,
			temporary = false,
			center = nil,
			nest = nil,
		})
	end
	log:info("creature_dens", { dens = #dens, towns = #towns })
end

function CreatureService.init(_self: any, ctx: any)
	log = ctx.log
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	runner = ctx.get("EffectRunner")
	inventory = ctx.get("InventoryService")
	playerData = ctx.get("PlayerDataService")
	progression = ctx.get("ProgressionService")
	registerAdmin(ctx.get("AdminService"))
	ctx.bus:subscribe(Topics.TargetDamaged, onDamaged)
end

function CreatureService.start(_self: any, _ctx: any)
	local parent = Instance.new("Folder")
	parent.Name = "Creatures"
	parent.Parent = workspace
	folder = parent
	task.spawn(function()
		planWorld()
		local wakeAcc = 0
		while true do
			task.wait(T.stepSeconds)
			if enabled() then
				wakeAcc += T.stepSeconds
				if wakeAcc >= 1 then
					wakeAcc = 0
					wakeTick()
				end
				step()
			elseif #dens > 0 and #alive > 0 then
				-- Switched off at runtime: everything goes to sleep.
				for _, den in table.clone(dens) do
					if den.awake then
						sleepDen(den)
					end
				end
			end
		end
	end)
end

return CreatureService
