--!strict
--[[
	FeralService: spells that get away from their casters, and go on living in the world for a while
	(docs/FeralSpells.md). Numbers and words: Ferals/Data/FeralData. Decisions: Ferals/FeralRules.

	This is meant to feel like something that happens in the world, not a feature of the game (owner,
	2026-11-07). So there's no interface at all: no card, no map pin, no announcement, no remote, and no
	name or health bar over it. You see one get loose, you run into one, or somebody tells you about it. The
	only client code is cosmetic: Fx/FamiliarAnimator moves its pieces, faster and wilder as its energy runs out.

	ESCAPE     A loss of control (Topics.ControlLost) may tear the spell loose, seeded. NPC mages have
	           accidents too, one chance per time slot, the same on every server, so this happens with
	           nobody around. Nothing here is saved: a loose spell lasts as long as its server, at most.
	ENERGY     It's running out from the moment it escapes, slower where ley energy is thick. It leans
	           towards that energy as it wanders, so loose spells tend to end up along ley lines. When
	           it runs out, it just gutters away.
	BODY       Only with someone near, like a creature den: nobody near means a position and a number.
	           A real Humanoid body (CreatureRig), so every spell, status and weapon works on it.
	MAGIC      It casts the spell it was, weaker, through Delivery and DamageModel like an NPC's bolt, with
	           no source player: nobody's to blame for what it does. It isn't a hunter. It discharges at
	           whatever comes close or hits it, players and NPCs alike. Magic cast nearby draws it, so
	           going quiet is a real way to avoid one.
	AFTER      Bring it down and it leaves a Journal clue to its recipe for anyone who hurt it, unless they
	           knew the spell already: your own backfires teach you nothing, so failing on purpose is
	           pointless. data.feral.studied remembers what you've learned, in the player's save.
	RUMOURS    Ask a townsperson (NPCService.setRumorHook). It goes in your Journal, and marks nothing.

	Flags: feral_spells_enabled, feral_spells_max. Admin: feral list | spawn | goto | clear.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local MagicCore = require(Shared.Magic.MagicCore)
local Registry = require(Shared.Magic.Registry)
local Seed = require(Shared.Magic.Seed)

local Server = script.Parent.Parent
local Cast = Server.Magic.Cast
local DamageModel = require(Cast.DamageModel)
local Delivery = require(Cast.Delivery)
local Targeting = require(Cast.Targeting)
local TimeZones = require(Cast.TimeZones)
local CreatureRig = require(Server.Creatures.CreatureRig)
local Data = require(Server.Ferals.Data.FeralData)
local Rules = require(Server.Ferals.FeralRules)
local NPCCombat = require(Server.NPC.NPCCombat)
local NPCMagicLife = require(Server.NPC.NPCMagicLife)
local WildZoneRules = require(Server.World.WildZoneRules)
local WorldConfig = require(Server.World.WorldConfig)

local T = Data.tuning

local FeralService = {
	name = "FeralService",
	dependencies = { "AdminService", "EffectRunner", "JournalService", "NPCService", "PlayerDataService", "ProgressionService", "WorldService", "WorldStateService" },
}

type Body = { model: Model, humanoid: Humanoid, root: BasePart }

type Feral = {
	id: string,
	name: string,
	recipe: any,
	key: string,
	stats: any,
	domain: string,
	source: string, -- "player" | "npc"
	casterName: string,
	casterUserId: number?,
	x: number,
	z: number,
	energy: number,
	maxEnergy: number,
	healthShare: number,
	body: Body?,
	rng: Random,
	casts: number,
	graceUntil: number,
	nextCast: number,
	nextWander: number,
	goal: Vector3?,
	drawnUntil: number,
	attacker: Model?,
	attackerUntil: number,
	dealt: { [number]: number },
	branch: { [number]: string },
	secondAcc: number,
}

local log: any = nil
local runner: any = nil
local journal: any = nil
local npcs: any = nil
local playerData: any = nil
local progression: any = nil
local worldService: any = nil
local world: any = nil

local ferals: { Feral } = {}
local byModel: { [Model]: Feral } = {}
local counter = 0
local lastEscape: { [number]: number } = {} -- caster's userId -> os.clock()
local escapes: { [number]: number } = {} -- caster's userId -> how many so far, for the seeded roll
local heardBy: { [Player]: { [string]: boolean } } = {}
local handledSlot = -1
local folder: Folder? = nil
local terrainParams: RaycastParams? = nil

local function enabled(): boolean
	return FeatureFlags.get("feral_spells_enabled") == true
end

local function limit(): number
	return tonumber(FeatureFlags.get("feral_spells_max")) or T.maxAlive
end

local function fromCaster(userId: number?): number
	local n = 0
	for _, feral in ferals do
		if feral.casterUserId == userId then
			n += 1
		end
	end
	return n
end

local function isLand(x: number, z: number): boolean
	return Rules.onIsland(x, z, WorldConfig.WORLD_SIZE) and world:surfaceHeight(x, z) >= WorldConfig.SEA_LEVEL + T.seaMargin
end

-- ─── Getting loose ──────────────────────────────────────────────────────────

local function create(recipe: any, stats: any, source: string, casterName: string, casterUserId: number?, x: number, z: number, seedKey: string): Feral?
	local domain: string? = stats.domains and stats.domains[1]
	if not domain or not Registry.domains[domain] then
		return nil
	end
	counter += 1
	local feral: Feral = {
		id = "feral_" .. counter,
		name = Data.words[domain] or "Loose Working",
		recipe = recipe,
		key = MagicCore.recipeKey(recipe),
		stats = stats,
		domain = domain,
		source = source,
		casterName = casterName,
		casterUserId = casterUserId,
		x = x,
		z = z,
		energy = Rules.energyFor(recipe.power),
		maxEnergy = Rules.energyFor(recipe.power),
		healthShare = 1,
		body = nil,
		rng = Seed.random(worldService:getSeed(), seedKey, "feral_life", counter),
		casts = 0,
		graceUntil = os.clock() + T.graceSeconds,
		nextCast = 0,
		nextWander = 0,
		goal = nil,
		drawnUntil = 0,
		attacker = nil,
		attackerUntil = 0,
		dealt = {},
		branch = {},
		secondAcc = 0,
	}
	table.insert(ferals, feral)
	log:info("feral_escaped", { id = feral.id, source = source, domain = domain, form = recipe.form, power = recipe.power, x = math.floor(x), z = math.floor(z) })
	return feral
end

local function onControlLost(payload: any)
	if not enabled() then
		return
	end
	local player: Player = payload.player
	local position: Vector3 = payload.position
	local stats = payload.stats
	local userId = player.UserId
	escapes[userId] = (escapes[userId] or 0) + 1
	local roll = Seed.random(worldService:getSeed(), "player:" .. userId, "feral_escape", escapes[userId]):NextNumber()
	local allowed = Rules.mayEscape({
		severity = payload.severity,
		roll = roll,
		alive = #ferals,
		limit = limit(),
		fromCaster = fromCaster(userId),
		sinceLastEscape = os.clock() - (lastEscape[userId] or -math.huge),
		onIsland = Rules.onIsland(position.X, position.Z, WorldConfig.WORLD_SIZE),
	})
	if not allowed then
		return
	end
	lastEscape[userId] = os.clock()
	local feral = create(stats.recipe, stats, "player", player.DisplayName, userId, position.X, position.Z, "player:" .. userId)
	if feral then
		-- It leaves a mark of what happened where you'd look for it, and a word over it. No announcement.
		journal:log(player, "discovery", string.format("A spell tore loose from you and didn't go out. It moved off on its own: a %s, you'd call it.", string.lower(feral.name)))
		runner:cue("statusTag", { status = "feral_escaped", name = "It got away", harmful = false, caster = userId }, position + Vector3.new(0, 5, 0), false)
	end
end

-- Somewhere on the island, a mage has an accident. The same for every server in this slot.
local function checkAccident()
	local slot = os.time() // T.accidentSeconds
	if slot == handledSlot then
		return
	end
	local first = handledSlot == -1
	handledSlot = slot
	if first or #ferals >= limit() then
		return -- not at boot: only as time actually passes on this server
	end
	local rng = Seed.random(worldService:getSeed(), "world", "feral_accident", slot)
	if rng:NextNumber() >= T.accidentChance then
		return
	end
	local mages: { any } = {}
	for _, npc in npcs:all() do
		if not npc.knockedOut and npc.magic and npc.magic.caster and npc.ageBand ~= "child" then
			local _, _, tier = NPCMagicLife.best(npc)
			if tier >= T.accidentMinTier and isLand(npc.position.X, npc.position.Z) then
				table.insert(mages, npc)
			end
		end
	end
	if #mages == 0 then
		return
	end
	table.sort(mages, function(a, b)
		return a.id < b.id
	end)
	local mage = mages[rng:NextInteger(1, #mages)]
	local recipe = NPCCombat.attackRecipe(mage)
	local stats = recipe and MagicCore.computeStats(recipe, mage.magic.caster, nil)
	if recipe and stats then
		create(recipe, stats, "npc", mage.name, nil, mage.position.X, mage.position.Z, "npc:" .. tostring(mage.id))
	end
end

-- ─── Its body ───────────────────────────────────────────────────────────────

local function groundAt(x: number, z: number): Vector3?
	local params = terrainParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { workspace.Terrain }
		params.IgnoreWater = false
		terrainParams = params
	end
	local result = workspace:Raycast(Vector3.new(x, world:surfaceHeight(x, z) + 40, z), Vector3.new(0, -140, 0), params :: RaycastParams)
	return if result then result.Position else nil
end

local function wakeBody(feral: Feral)
	local ground = groundAt(feral.x, feral.z)
	if not ground or not folder then
		return
	end
	local domain = Registry.domains[feral.domain]
	-- Seeded by its id, so it has the same body each time it wakes.
	local bodyRng = Seed.random(worldService:getSeed(), feral.id, "feral_body")
	local def = Rules.def(feral.recipe, feral.domain, domain.feel.palette, domain.oppositions, feral.name, bodyRng)
	local at = CFrame.new(ground + Vector3.new(0, T.hover + def.hitbox.Y / 2 + 0.5, 0))
	local model, humanoid, root = CreatureRig.build(def, at)
	model:SetAttribute("FeralSpell", feral.id)
	model:SetAttribute("Unstable", Rules.unstable(feral.energy, feral.maxEnergy))
	humanoid.MaxHealth = def.health
	humanoid.Health = math.max(1, def.health * feral.healthShare)
	model.Parent = folder
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	feral.body = { model = model, humanoid = humanoid, root = root }
	byModel[model] = feral
	log:info("feral_woke", { id = feral.id, health = math.floor(humanoid.Health) })
end

local function dropBody(feral: Feral)
	local body = feral.body
	if body then
		feral.healthShare = math.clamp(body.humanoid.Health / math.max(1, body.humanoid.MaxHealth), 0.05, 1)
		byModel[body.model] = nil
		feral.body = nil
		body.model:Destroy()
	end
end

local function fade(model: Model)
	task.spawn(function()
		local parts: { BasePart } = {}
		for _, child in model:GetChildren() do
			if child:IsA("BasePart") and child.Transparency < 1 then
				table.insert(parts, child)
				child.Anchored = true
			elseif child:IsA("ParticleEmitter") then
				child.Enabled = false
			end
		end
		for step = 1, 5 do
			task.wait(T.fadeSeconds / 5)
			for _, part in parts do
				part.Transparency = math.max(part.Transparency, step / 5)
			end
		end
		model:Destroy()
	end)
end

local function forget(feral: Feral)
	local index = table.find(ferals, feral)
	if index then
		table.remove(ferals, index)
	end
end

-- Ran out. Nobody's told: it's simply gone.
local function gutter(feral: Feral)
	local body = feral.body
	if body then
		byModel[body.model] = nil
		feral.body = nil
		local root = body.root
		root.Anchored = true
		fade(body.model)
	end
	forget(feral)
	log:info("feral_guttered", { id = feral.id })
end

-- ─── What it leaves behind ──────────────────────────────────────────────────

local function studyRecord(state: any): { [string]: number }
	state.data.feral = state.data.feral or { studied = {} }
	return state.data.feral.studied
end

local function nameOf(group: { [string]: any }, id: string): string
	local def = group[id]
	return string.lower(if def and def.name then def.name else id)
end

local function reward(feral: Feral, maxHealth: number)
	for userId, dealt in feral.dealt do
		local player = Players:GetPlayerByUserId(userId)
		local state = player and playerData:get(player)
		if player and state then
			local studied = studyRecord(state)
			local key = feral.key
			if Rules.learnsFrom({ dealt = dealt, maxHealth = maxHealth, known = state.data.spellbook[key] ~= nil, studied = studied[key] ~= nil }) then
				studied[key] = os.time()
				Rules.pruneStudied(studied, T.studiedMax)
				local recipe = feral.recipe
				journal:log(player, "discovery", Rules.clue({
					branch = nameOf(Registry.branches, recipe.branch),
					property = nameOf(Registry.properties, recipe.property),
					verb = nameOf(Registry.verbs, recipe.verb),
					form = nameOf(Registry.forms, recipe.form),
				}))
				local branch = feral.branch[userId]
				if branch then
					progression:awardCreatureKill(player, branch, T.xpPerPower * recipe.power, "feral", recipe.power)
				end
				log:info("feral_studied", { id = feral.id, userId = userId, key = key })
			end
		end
	end
end

local function die(feral: Feral)
	local body = feral.body :: Body
	local maxHealth = body.humanoid.MaxHealth
	byModel[body.model] = nil
	feral.body = nil
	body.root.Anchored = true
	reward(feral, maxHealth)
	fade(body.model)
	forget(feral)
	local helpers = 0
	for _ in feral.dealt do
		helpers += 1
	end
	log:info("feral_fell", { id = feral.id, helpers = helpers })
end

-- ─── Its magic ──────────────────────────────────────────────────────────────

local function spellCue(feral: Feral): { [string]: any }
	local stats, recipe = feral.stats, feral.recipe
	return {
		domain = feral.domain,
		property = recipe.property,
		verb = recipe.verb,
		form = recipe.form,
		power = recipe.power,
		masteryTier = stats.masteryTier,
		harmful = true,
		radius = stats.area,
		castTime = stats.castTime,
		backfire = false,
	}
end

local function contextFor(feral: Feral, body: Body, targetModel: Model?, point: Vector3): any
	feral.casts += 1
	return {
		player = nil, -- nobody's to blame: no source UserId
		character = body.model,
		root = body.root,
		stats = feral.stats,
		context = {},
		power = feral.stats.power,
		origin = body.root.Position,
		point = point,
		measuredAt = point,
		target = targetModel,
		onSurface = false,
		backfire = false,
		pulse = 0,
		rng = Seed.random(worldService:getSeed(), feral.id, "feral_cast", feral.casts),
		world = nil,
		stored = {},
		runtime = runner,
		services = {},
	}
end

local function canReach(model: Model): boolean
	return model:GetAttribute("FeralSpell") == nil and model:GetAttribute("PracticeTarget") == nil and model:GetAttribute("Creature") == nil
end

local function discharge(feral: Feral, body: Body, targetModel: Model, targetRoot: BasePart)
	local form: string = feral.recipe.form
	local kind: string = feral.recipe.property
	if form == "projectile" and Delivery.capacity() then
		local ctx = contextFor(feral, body, targetModel, targetRoot.Position)
		local flight = Delivery.plan(ctx)
		local launch = spellCue(feral)
		launch.stage = "launch"
		launch.origin = flight.origin
		launch.point = ctx.point
		launch.projectileId = flight.id
		launch.velocity = flight.velocity
		launch.gravity = flight.gravity
		launch.hitRadius = flight.radius
		launch.turnRate = flight.turnRate
		launch.lifetime = flight.lifetime
		runner:cue("spell", launch, flight.origin, false)
		task.spawn(function()
			local impact = Delivery.fly(flight, { body.model })
			local resolve = spellCue(feral)
			resolve.stage = "resolve"
			resolve.origin = flight.origin
			resolve.point = impact.point
			resolve.projectileId = flight.id
			resolve.normal = impact.normal
			resolve.expired = impact.expired
			runner:cue("spell", resolve, impact.point, false)
			ctx.point = impact.point
			for _, hit in impact.hits do
				if hit.model ~= body.model or impact.reflectedBy then
					DamageModel.hit(ctx, hit, T.hitShare, kind)
				end
			end
		end)
		return
	end
	-- Everything else lands where it's aimed: one target, or everyone around it.
	local point = targetRoot.Position
	local ctx = contextFor(feral, body, targetModel, point)
	local resolve = spellCue(feral)
	resolve.stage = "resolve"
	resolve.origin = body.root.Position
	resolve.point = point
	runner:cue("spell", resolve, point, false)
	if Data.areaForms[form] then
		local radius = math.max(6, tonumber(feral.stats.area) or 6)
		for _, hit in Targeting.inRadius(point, radius, Data.maxAreaTargets, { [body.model] = true }) do
			if canReach(hit.model) then
				DamageModel.hit(ctx, hit, T.hitShare * 0.8, kind)
			end
		end
	else
		local hit = Targeting.characterOf(targetModel)
		if hit then
			DamageModel.hit(ctx, hit, T.hitShare, kind)
		end
	end
end

-- ─── Moving and acting ──────────────────────────────────────────────────────

local function newDirection(feral: Feral, from: Vector3): Vector3?
	local samples: { Rules.Sample } = {}
	local directions: { Vector3 } = {}
	for i = 1, 8 do
		local angle = (i - 1) * math.pi / 4
		local direction = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local spot = from + direction * T.sampleDistance
		directions[i] = direction
		samples[i] = { density = world:densityAt(spot.X, spot.Z), land = isLand(spot.X, spot.Z) }
	end
	local pick = Rules.pickDirection(samples, feral.rng:NextNumber())
	return if pick then directions[pick] else nil
end

local function stepBody(feral: Feral, body: Body, now: number)
	local root, humanoid = body.root, body.humanoid
	local position = root.Position
	feral.x, feral.z = position.X, position.Z
	if TimeZones.stopped(position) or body.model:GetAttribute("GravityHeld") or humanoid:GetAttribute("KnockedDown") then
		return
	end

	if now < feral.graceUntil then
		-- It's just got loose: away from wherever that was, before anything else.
		if not feral.goal then
			local away = newDirection(feral, position)
			feral.goal = if away then position + away * T.sampleDistance else nil
		end
		if feral.goal then
			humanoid:MoveTo(feral.goal)
		end
		return
	end

	-- Whoever hit it, if they're still about. Otherwise whatever has come close.
	local targetModel: Model? = nil
	local targetRoot: BasePart? = nil
	local attacker = feral.attacker
	if attacker and now < feral.attackerUntil and attacker.Parent then
		local hit = Targeting.characterOf(attacker)
		if hit and (hit.root.Position - position).Magnitude <= T.reach then
			targetModel, targetRoot = hit.model, hit.root
		end
	end
	if not targetModel then
		for _, hit in Targeting.inRadius(position, T.notice, 6, { [body.model] = true }) do
			if canReach(hit.model) then
				targetModel, targetRoot = hit.model, hit.root
				break
			end
		end
	end

	if targetModel and targetRoot then
		humanoid:MoveTo(position + (targetRoot.Position - position) * 0.3)
		if now >= feral.nextCast then
			feral.nextCast = now + T.castEvery
			discharge(feral, body, targetModel, targetRoot)
		end
		return
	end

	if now >= feral.nextWander and now >= feral.drawnUntil then
		feral.nextWander = now + T.wanderSeconds
		local direction = newDirection(feral, position)
		feral.goal = if direction then position + direction * (T.walk * T.wanderSeconds) else nil
	end
	if feral.goal then
		humanoid:MoveTo(feral.goal)
	end
end

-- With nobody near, it still goes somewhere: a position and a direction, and no parts at all.
local function stepDormant(feral: Feral, now: number)
	if now < feral.nextWander then
		return
	end
	feral.nextWander = now + T.wanderSeconds
	local direction = newDirection(feral, Vector3.new(feral.x, 0, feral.z))
	if direction then
		local x = feral.x + direction.X * T.walk * T.wanderSeconds
		local z = feral.z + direction.Z * T.walk * T.wanderSeconds
		if isLand(x, z) then
			feral.x, feral.z = x, z
		end
	end
end

local function nearestPlayer(x: number, z: number): number
	local nearest = math.huge
	for _, player in Players:GetPlayers() do
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			nearest = math.min(nearest, Vector3.new(root.Position.X - x, 0, root.Position.Z - z).Magnitude)
		end
	end
	return nearest
end

local function stepOne(feral: Feral, now: number)
	local body = feral.body
	if body and (not body.model.Parent or body.root.Position.Y < WorldConfig.SEA_LEVEL - 60) then
		-- Destroyed from outside, or fell through the world: it carries on with no body for now.
		byModel[body.model] = nil
		feral.body = nil
		if body.model.Parent then
			body.model:Destroy()
		end
		body = nil
	end
	if body and body.humanoid.Health <= 0 then
		die(feral)
		return
	end

	feral.secondAcc += T.stepSeconds
	if feral.secondAcc >= 1 then
		feral.secondAcc = 0
		-- Stopped time doesn't use it up.
		if not TimeZones.stopped(Vector3.new(feral.x, if body then body.root.Position.Y else 0, feral.z)) then
			feral.energy -= Rules.drainRate(world:densityAt(feral.x, feral.z))
		end
		if feral.energy <= 0 then
			gutter(feral)
			return
		end
		if body then
			local unstable = Rules.unstable(feral.energy, feral.maxEnergy)
			if body.model:GetAttribute("Unstable") ~= unstable then
				body.model:SetAttribute("Unstable", unstable)
			end
		end
		local distance = nearestPlayer(feral.x, feral.z)
		if body and distance > T.sleepRadius then
			dropBody(feral)
			body = nil
		elseif not body and distance <= T.wakeRadius and world:isChunkBuilt(feral.x, feral.z) then
			wakeBody(feral)
			body = feral.body
		end
	end

	if body then
		stepBody(feral, body, now)
	else
		stepDormant(feral, now)
	end
end

-- ─── Things that happen near it ─────────────────────────────────────────────

local function onDamaged(payload: any)
	local feral = payload.model and byModel[payload.model]
	if not feral then
		return
	end
	local source: number? = payload.sourceUserId
	if source then
		feral.dealt[source] = (feral.dealt[source] or 0) + payload.amount
		if payload.branch then
			feral.branch[source] = payload.branch
		end
		local attacker = Players:GetPlayerByUserId(source)
		if attacker and attacker.Character then
			feral.attacker = attacker.Character
			feral.attackerUntil = os.clock() + T.attackerMemory
		end
	end
end

-- Magic cast close by draws it, which is why going quiet is a way to avoid one.
local function onSpell(payload: any)
	local point: Vector3? = payload.point
	if typeof(point) ~= "Vector3" then
		return
	end
	local now = os.clock()
	for _, feral in ferals do
		if feral.body and now >= feral.graceUntil and (feral.body.root.Position - point).Magnitude <= T.drawnRadius then
			feral.goal = point
			feral.drawnUntil = now + T.drawnSeconds
		end
	end
end

local function rumorHook(player: Player, npc: any): string?
	if not enabled() or #ferals == 0 then
		return nil
	end
	local at: Vector3 = npc.position
	local heard = heardBy[player]
	if not heard then
		heard = {}
		heardBy[player] = heard
	end
	-- Seeded per person and per loose spell, so asking the same person again gets the same answer.
	local rng = Seed.random(worldService:getSeed(), "player:" .. player.UserId, "feral_rumor:" .. tostring(npc.id), #ferals)
	local list: { Rules.RumorFeral } = ferals :: any
	local found = Rules.rumorFor(list, heard, at.X, at.Z, rng:NextNumber())
	if not found then
		return nil
	end
	heard[found.id] = true
	local feral = found :: any
	local text = Rules.rumorLine(feral.source, feral.casterName, WildZoneRules.bearing(at.X, at.Z, feral.x, feral.z), rng:NextNumber())
	journal:log(player, "rumor", string.format("%s said: \"%s\"", tostring(npc.name), text))
	log:info("feral_rumor", { userId = player.UserId, id = feral.id, npc = npc.id })
	return text
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "feral",
		category = "Spells",
		description = "Loose spells: list them, spawn one from your first known spell, goto the nearest, or clear them",
		args = { { name = "action", type = "enum", options = { "list", "spawn", "goto", "clear" } } },
		handler = function(ctx: any, a: any)
			if not enabled() then
				return "flag feral_spells_enabled is off"
			end
			local root = ctx.player.Character and ctx.player.Character:FindFirstChild("HumanoidRootPart")
			if a.action == "list" then
				local lines = { string.format("%d of %d loose", #ferals, limit()) }
				for _, feral in ferals do
					table.insert(lines, string.format("%s %s (%s, %s, power %d) from %s at (%d, %d), energy %d, %s", feral.id, feral.name, feral.domain, feral.recipe.form, feral.recipe.power, feral.casterName, feral.x, feral.z, feral.energy, if feral.body then "awake" else "no body"))
				end
				return table.concat(lines, "\n")
			elseif a.action == "clear" then
				local n = #ferals
				for i = #ferals, 1, -1 do
					gutter(ferals[i])
				end
				return string.format("cleared %d", n)
			elseif a.action == "goto" then
				if not root then
					return "no character"
				end
				local best, bestD = nil, math.huge
				for _, feral in ferals do
					local d = Vector3.new(root.Position.X - feral.x, 0, root.Position.Z - feral.z).Magnitude
					if d < bestD then
						best, bestD = feral, d
					end
				end
				if not best then
					return "none loose: feral spawn"
				end
				ctx.player.Character:PivotTo(CFrame.new(best.x + 25, world:surfaceHeight(best.x + 25, best.z) + 5, best.z))
				return "beside " .. best.id
			end
			-- spawn
			local state = playerData:get(ctx.player)
			if not state or not root then
				return "no character or data yet"
			end
			local keys: { string } = {}
			for key in state.data.spellbook do
				table.insert(keys, key)
			end
			table.sort(keys)
			for _, key in keys do
				local stats = MagicCore.computeStats(state.data.spellbook[key].recipe, state.caster, nil)
				if stats and stats.harmful then
					local at = root.Position + root.CFrame.LookVector * 18
					local feral = create(stats.recipe, stats, "player", ctx.player.DisplayName, nil, at.X, at.Z, "admin")
					if feral then
						return "loose: " .. feral.id .. ", " .. feral.name
					end
				end
			end
			return "you know no harmful spell to let loose"
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function FeralService.init(_self: any, ctx: any)
	log = ctx.log
	runner = ctx.get("EffectRunner")
	journal = ctx.get("JournalService")
	npcs = ctx.get("NPCService")
	playerData = ctx.get("PlayerDataService")
	progression = ctx.get("ProgressionService")
	worldService = ctx.get("WorldService")
	world = ctx.get("WorldStateService")
	ctx.bus:subscribe(Topics.ControlLost, onControlLost)
	ctx.bus:subscribe(Topics.TargetDamaged, onDamaged)
	ctx.bus:subscribe(Topics.SpellResolved, onSpell)
	npcs:setRumorHook(rumorHook, true) -- ahead of old news: something loose nearby is what people talk about
	registerAdmin(ctx.get("AdminService"))
end

function FeralService.start(_self: any, _ctx: any)
	local parent = Instance.new("Folder")
	parent.Name = "FeralSpells"
	parent.Parent = workspace
	folder = parent
	Players.PlayerRemoving:Connect(function(player)
		heardBy[player] = nil
	end)
	task.spawn(function()
		world:awaitReady()
		local accidentAcc = 0
		while true do
			task.wait(T.stepSeconds)
			local now = os.clock()
			if enabled() then
				accidentAcc += T.stepSeconds
				if accidentAcc >= 10 then
					accidentAcc = 0
					local ok, err = pcall(checkAccident)
					if not ok then
						log:throttled("feral_accident", 60, "Error", "feral_accident_failed", { err = err })
					end
				end
				for i = #ferals, 1, -1 do
					-- One failure mustn't stop the rest, or leave one going forever.
					local ok, err = pcall(stepOne, ferals[i], now)
					if not ok then
						log:throttled("feral_step", 30, "Error", "feral_step_failed", { err = err })
					end
				end
			elseif #ferals > 0 then
				for i = #ferals, 1, -1 do
					gutter(ferals[i])
				end
			end
		end
	end)
end

return FeralService
