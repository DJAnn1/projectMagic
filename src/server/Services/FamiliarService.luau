--!strict
--[[
	FamiliarService: a small creature born from your own magic, which grows and fights beside you
	(docs/Familiars.md). Content and numbers: Shared/Familiars/Data/Familiars. Decisions:
	Shared/Familiars/FamiliarRules. Body: Familiars/FamiliarRig.

	BOND      Your first few spells, or reaching Novice. Its look, default name and personality are seeded
	          (Seed.random(worldSeed, "player:<id>", "familiar")) with your profile, so it's the same on
	          every server. There are no rerolls.
	STEP      Each familiar thinks 5 times a second: it follows you, or goes after its target. It has no
	          Humanoid (see FamiliarRig), so spells can't touch it and walls don't stop it.
	TARGETS   Guard: what you hit, and what hits you. Hunt: also wild creatures near you, only while
	          you're playing. Follow never fights. Stay fights only what comes within reach.
	          It sits out your duels.
	DAMAGE    Through Cast/Damage with you as the source, so PvP rules, wards, quest wards and creature
	          credit all work. Kinds start "familiar", and SurgeService ignores those: it can't fill
	          your meter for you.
	HEALTH    Only what it attacks hurts it (retaliation). At zero it's knocked out for a while and comes
	          back by itself. It can't die.
	GROWTH    XP from your casts and from kills it helped with, while you're playing, up to a daily limit.
	          Saved in PlayerData.familiar, so progress resets and erasure already cover it.
	NAME      The raw name stays on the server. Everyone sees the TextService-filtered one
	          (SpellbookService:filterName); if filtering fails live, the default name shows.

	Remotes: FamiliarAction (client -> server), FamiliarState. Flags: familiars_enabled,
	familiars_max_alive. Admin: familiar.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local MagicCore = require(Shared.Magic.MagicCore)
local Registry = require(Shared.Magic.Registry)
local F = require(Shared.Familiars.Data.Familiars)
local Rules = require(Shared.Familiars.FamiliarRules)

local Server = script.Parent.Parent
local Cast = Server.Magic.Cast
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local PvpRules = require(Cast.PvpRules)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local TimeZones = require(Cast.TimeZones)
local InnateProfile = require(Server.Magic.InnateProfile)
local Progression = require(Server.Progression.Progression)
local FamiliarRig = require(Server.Familiars.FamiliarRig)

local T = F.tuning

local FamiliarService = {
	name = "FamiliarService",
	dependencies = { "NetService", "AdminService", "EffectRunner", "JournalService", "PlayerDataService", "SpellbookService", "WorldService", "WorldStateService" },
}

type Target = { model: Model, humanoid: Humanoid, root: BasePart, untilClock: number }

type Live = {
	player: Player,
	record: any,
	identity: Rules.Identity,
	stage: number,
	tier: number,
	nextTier: number,
	stats: Rules.Stats,
	rig: FamiliarRig.Rig?,
	health: number,
	shownHealth: number,
	koUntil: number,
	displayName: string,
	target: Target?,
	nextBite: number,
	nextAbility: { [string]: number },
	lastFight: number,
	lastAction: number,
	lastCastXp: number,
	lastOwnerPosition: Vector3?,
	hover: number,
	hoverPhase: number,
	stayAt: Vector3?,
	secondAcc: number,
	groundAcc: number,
	groundY: number?,
}

local log: any = nil
local runner: any = nil
local journal: any = nil
local playerData: any = nil
local spellbook: any = nil
local worldService: any = nil
local world: any = nil

local lives: { [Player]: Live } = {}
local folder: Folder? = nil
local aliveCount = 0

-- Who last hit what, for kill XP. Weak keys: a destroyed model doesn't linger here.
local lastHitBy: { [Model]: { live: Live, at: number } } = setmetatable({}, { __mode = "k" }) :: any

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function enabled(): boolean
	return FeatureFlags.get("familiars_enabled") == true
end

local function ownerBody(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil, nil, nil
	end
	return character, humanoid, root
end

local function bestTier(state: any): number
	local p = state.data.progression
	local best = 1
	for branchId in p.unlocked do
		local tier = (Progression.getMasteryTier(p, branchId))
		best = math.max(best, tier)
	end
	return best
end

local function fullHitAt(tier: number): number
	return DamageModel.base(math.max(1, MagicCore.tierDef(tier).powerCeiling))
end

local function refreshStats(live: Live)
	local before = live.stats.maxHealth
	live.stats = Rules.statsFor(live.identity, live.stage, live.tier, fullHitAt(live.tier))
	if before > 0 then
		live.health = math.min(live.stats.maxHealth, live.health * live.stats.maxHealth / before)
	else
		live.health = live.stats.maxHealth
	end
end

local function viewOf(live: Live?, player: Player, note: string?): { [string]: any }
	if not enabled() then
		return { bonded = false, off = true }
	end
	if not live then
		local state = playerData:get(player)
		local casts = if state and state.data.familiar then state.data.familiar.casts or 0 else 0
		return { bonded = false, castsLeft = math.max(0, T.bondCasts - casts), note = note }
	end
	local record = live.record
	local stageDef = F.stages[live.stage]
	local nextDef = F.stages[live.stage + 1]
	local domain = Registry.domains[record.domain]
	local abilities = {}
	for _, ability in Rules.abilitiesOf(record, live.stage) do
		table.insert(abilities, { name = ability.name, text = ability.text })
	end
	return {
		bonded = true,
		name = live.displayName,
		custom = record.name ~= "",
		stage = live.stage,
		stageName = stageDef.name,
		stages = #F.stages,
		domain = record.domain,
		domainName = if domain then domain.name else record.domain,
		word = live.identity.personality.word,
		line = live.identity.personality.line,
		mode = record.mode,
		summoned = record.summoned,
		health = math.floor(live.health / math.max(1, live.stats.maxHealth) * 100),
		koSeconds = if live.koUntil > os.clock() then math.ceil(live.koUntil - os.clock()) else nil,
		xp = math.floor(record.xp),
		xpFrom = stageDef.xp,
		xpTo = if nextDef then nextDef.xp else nil,
		abilities = abilities,
		note = note,
	}
end

local function push(live: Live?, player: Player, note: string?)
	Net.fire("FamiliarState", player, viewOf(live, player, note))
end

-- ─── The body ───────────────────────────────────────────────────────────────

local function destroyBody(live: Live)
	local rig = live.rig
	if rig then
		live.rig = nil
		aliveCount -= 1
		rig.model:Destroy()
	end
	live.target = nil
end

local function showHealth(live: Live)
	local share = math.clamp(live.health / math.max(1, live.stats.maxHealth), 0, 1)
	local rig = live.rig
	if rig then
		rig.healthBar.Size = UDim2.fromScale(share, 1)
	end
	-- The screen only needs it in steps of a tenth: no remote for every bite.
	if math.abs(share - live.shownHealth) >= 0.1 then
		live.shownHealth = share
		push(live, live.player)
	end
end

local function nameTag(live: Live): string
	return string.format("%s · %s", live.displayName, F.stages[live.stage].name)
end

-- Ground at (x, z), looking down from about the height you're at, so inside a house it finds the floor.
local function groundUnder(x: number, referenceY: number, z: number, player: Player): number?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local ignore: { Instance } = {}
	if player.Character then
		table.insert(ignore, player.Character)
	end
	if folder then
		table.insert(ignore, folder)
	end
	params.FilterDescendantsInstances = ignore
	local result = workspace:Raycast(Vector3.new(x, referenceY + 8, z), Vector3.new(0, -T.groundRay, 0), params)
	return if result then result.Position.Y else nil
end

-- The spot it likes to keep beside you. No raycast: this runs every step, and moveTo looks for the
-- ground less often. Y is roughly your feet.
local function followSpot(live: Live, ownerPosition: Vector3): Vector3
	local angle = live.identity.followAngle
	return Vector3.new(ownerPosition.X + math.cos(angle) * T.followAt * 0.7, ownerPosition.Y - 3, ownerPosition.Z + math.sin(angle) * T.followAt * 0.7)
end

-- The same spot on the real ground, for the moments it appears there.
local function besideOwner(live: Live, ownerPosition: Vector3): Vector3
	local spot = followSpot(live, ownerPosition)
	local ground = groundUnder(spot.X, ownerPosition.Y, spot.Z, live.player)
	return Vector3.new(spot.X, ground or spot.Y, spot.Z)
end

local function buildBody(live: Live): boolean
	if live.rig or not folder or not enabled() or live.koUntil > os.clock() or not live.record.summoned then
		return false
	end
	local limit = tonumber(FeatureFlags.get("familiars_max_alive")) or 60
	if aliveCount >= limit then
		log:throttled("familiar_budget", 60, "Info", "familiar_budget_full", { alive = aliveCount, limit = limit })
		return false
	end
	local _, _, ownerRoot = ownerBody(live.player)
	if not ownerRoot then
		return false
	end
	local body = Rules.body(live.identity, live.stage)
	local at = besideOwner(live, ownerRoot.Position) + Vector3.new(0, body.hover, 0)
	local rig = FamiliarRig.build(body, CFrame.new(at), live.player.UserId)
	rig.nameLabel.Text = nameTag(live)
	rig.model.Parent = folder
	pcall(function()
		rig.root:SetNetworkOwner(nil) -- server-driven: no client can move it
	end)
	live.rig = rig
	live.hover = body.hover
	live.groundY = at.Y - body.hover
	aliveCount += 1
	showHealth(live)
	return true
end

-- ─── Growing ────────────────────────────────────────────────────────────────

-- Old enough, and no second ability yet: it learns one. Returns the words to tell you, if it did.
local function learnIfDue(live: Live): string?
	local record = live.record
	if live.stage < T.learnStage or record.learned ~= "" then
		return nil
	end
	local domain = Registry.domains[record.domain]
	local learned = Rules.learnedDomain(record.tally, record.domain, domain and domain.synergies)
	if not learned then
		return nil
	end
	record.learned = learned
	return " It has watched you, and learned " .. F.abilities[learned].name .. "."
end

local function grow(live: Live, amount: number)
	if not Rules.active(os.clock(), live.lastAction) then
		return
	end
	local record = live.record
	if Rules.addXp(record, amount, os.time() // 86400) <= 0 then
		return
	end
	local stage = Rules.stageOf(record.xp)
	if stage <= live.stage then
		return
	end
	live.stage = stage
	refreshStats(live)
	live.health = live.stats.maxHealth
	local note = string.format("%s has grown: %s.", live.displayName, F.stages[stage].name)
	if stage >= T.abilityStage and F.abilities[record.domain] and stage < T.learnStage then
		note ..= " It knows " .. F.abilities[record.domain].name .. "."
	end
	note ..= learnIfDue(live) or ""
	local rig = live.rig
	local at = if rig then rig.root.Position else nil
	destroyBody(live)
	buildBody(live)
	if at then
		runner:cue("familiar", { fx = "grow", domain = record.domain }, at, false)
	end
	journal:log(live.player, "discovery", note)
	log:info("familiar_grew", { userId = live.player.UserId, stage = stage, learned = record.learned })
	push(live, live.player, note)
end

-- ─── Knocked out ────────────────────────────────────────────────────────────

local function knockOut(live: Live)
	local rig = live.rig
	if rig then
		runner:cue("familiar", { fx = "ko", domain = live.record.domain }, rig.root.Position, false)
	end
	destroyBody(live)
	live.health = 0
	live.koUntil = os.clock() + T.koSeconds
	log:info("familiar_ko", { userId = live.player.UserId })
	push(live, live.player, string.format("%s is knocked out, and will be back soon.", live.displayName))
end

local function hurtBack(live: Live, targetMaxHealth: number)
	live.health -= Rules.retaliation(live.stats.maxHealth, targetMaxHealth)
	live.lastFight = os.clock()
	if live.health <= 0 then
		knockOut(live)
	else
		showHealth(live)
	end
end

-- ─── Fighting ───────────────────────────────────────────────────────────────

local function damageFor(live: Live, target: Target, amount: number): number
	local domain = live.identity.domain
	local result = amount * (1 - DamageModel.resistance(target.humanoid, { domain }, "momentum"))
	if Players:GetPlayerFromCharacter(target.model) then
		result = math.min(result, target.humanoid.MaxHealth * T.pvpBiteShare)
	end
	return math.max(1, result)
end

local function strike(live: Live, target: Target, amount: number, kind: string, domain: string, from: Vector3): number
	local dealt = Damage.apply(target.humanoid, damageFor(live, target, amount), live.player.UserId, kind, {
		domain = domain,
		from = from,
		form = "touch",
		property = "momentum",
		power = 1,
	})
	if dealt > 0 then
		lastHitBy[target.model] = { live = live, at = os.clock() }
		target.untilClock = os.clock() + T.targetMemory
		live.lastFight = os.clock()
	end
	return dealt
end

local function useAbility(live: Live, ability: F.Ability, from: Vector3, now: number): boolean
	local _, ownerHumanoid, ownerRoot = ownerBody(live.player)
	if not ownerHumanoid or not ownerRoot then
		return false
	end
	local userId = live.player.UserId
	local target = live.target
	local inFight = target ~= nil
	local kind = ability.kind
	if kind == "mend" then
		if ownerHumanoid.Health >= ownerHumanoid.MaxHealth * 0.7 then
			return false
		end
		Damage.heal(ownerHumanoid, ownerHumanoid.MaxHealth * (ability.share or 0), userId, { domain = ability.id })
		runner:cue("familiar", { fx = "bolt", domain = ability.id, to = ownerRoot.Position }, from, false)
	elseif kind == "ward" then
		if not inFight then
			return false
		end
		StatusEffects.apply(ownerHumanoid, ability.status or "ward", {
			duration = ability.seconds or 4,
			magnitude = ownerHumanoid.MaxHealth * (ability.share or 0),
			source = userId,
		})
		runner:cue("familiar", { fx = "bolt", domain = ability.id, to = ownerRoot.Position }, from, false)
	elseif kind == "haste" then
		if not inFight then
			return false
		end
		StatusEffects.apply(ownerHumanoid, ability.status or "haste", { duration = ability.seconds or 3, source = userId })
		runner:cue("familiar", { fx = "bolt", domain = ability.id, to = ownerRoot.Position }, from, false)
	else
		if not target or (target.root.Position - from).Magnitude > T.boltRange then
			return false
		end
		local amount = live.stats.bite * (ability.share or 1)
		local dealt = strike(live, target, amount, "familiar_ability", ability.id, from)
		if dealt <= 0 then
			return false
		end
		runner:cue("familiar", { fx = "bolt", domain = ability.id, to = target.root.Position }, from, false)
		local status = ability.status
		if status and target.humanoid.Health > 0 then
			local isPlayer = Players:GetPlayerFromCharacter(target.model) ~= nil
			StatusEffects.apply(target.humanoid, status, {
				duration = (ability.seconds or 2) * (if isPlayer then T.pvpStatusShare else 1),
				magnitude = if StatusEffects.defs[status] and StatusEffects.defs[status].dot then math.max(1, amount * 0.25) else nil,
				source = userId,
			})
		end
		hurtBack(live, target.humanoid.MaxHealth)
	end
	live.nextAbility[ability.id] = now + ability.cooldown
	return true
end

-- Abilities are magic, so they fail where magic does (the Hushed Hollow). Bites don't.
local function tryAbilities(live: Live, from: Vector3, now: number)
	if PvpRules.inDuel(live.player.UserId) then
		return
	end
	local checked = false
	for _, ability in Rules.abilitiesOf(live.record, live.stage) do
		if now >= (live.nextAbility[ability.id] or 0) then
			if not checked then
				checked = true
				if world:densityAt(from.X, from.Z) < T.abilityMinDensity then
					return
				end
			end
			if useAbility(live, ability, from, now) or not live.rig then
				return
			end
		end
	end
end

local function targetAlive(target: Target?): boolean
	return target ~= nil and target.model.Parent ~= nil and target.humanoid.Parent ~= nil and target.humanoid.Health > 0 and target.root.Parent ~= nil
end

local function setTarget(live: Live, model: Model)
	if live.player.Character == model or model:GetAttribute("PracticeTarget") then
		return
	end
	local hit = Targeting.characterOf(model)
	if hit then
		live.target = { model = hit.model, humanoid = hit.humanoid, root = hit.root, untilClock = os.clock() + T.targetMemory }
	end
end

-- Hunt: the nearest wild creature close to you. Only ever creatures: it never starts on a person.
local function hunt(live: Live, ownerPosition: Vector3)
	if live.record.mode ~= "hunt" or live.target or not Rules.active(os.clock(), live.lastAction) then
		return
	end
	for _, hit in Targeting.inRadius(ownerPosition, T.huntRadius, 8) do
		if hit.model:GetAttribute("Creature") ~= nil and not hit.model:GetAttribute("PracticeTarget") then
			setTarget(live, hit.model)
			return
		end
	end
end

-- ─── The step ───────────────────────────────────────────────────────────────

local function moveTo(live: Live, rig: FamiliarRig.Rig, goal: Vector3, ownerSpeed: number, now: number)
	local position = rig.root.Position
	local flat = Vector3.new(goal.X - position.X, 0, goal.Z - position.Z)
	live.groundAcc += T.stepSeconds
	if live.groundAcc >= 0.6 or live.groundY == nil then
		live.groundAcc = 0
		local reference = if live.groundY then live.groundY else goal.Y
		live.groundY = groundUnder(goal.X, math.max(reference, goal.Y), goal.Z, live.player) or goal.Y
	end
	local bob = math.sin(now * 1.6 + live.hoverPhase) * 0.25
	local y = math.max((live.groundY :: number), goal.Y) + live.hover + bob
	rig.align.Position = Vector3.new(goal.X, y, goal.Z)
	rig.align.MaxVelocity = math.min(T.maxSpeed, math.max(live.stats.speed, ownerSpeed + T.speedAboveOwner))
	if flat.Magnitude > 0.5 then
		rig.orient.CFrame = CFrame.lookAt(Vector3.zero, flat.Unit)
	end
end

local function stepOne(live: Live, now: number)
	local player = live.player
	if live.koUntil > 0 and live.koUntil <= now then
		live.koUntil = 0
		live.health = live.stats.maxHealth
		if buildBody(live) then
			push(live, player, string.format("%s is back.", live.displayName))
		end
	end
	if not live.rig then
		-- Waiting for a character, or for room in the budget.
		if live.record.summoned and live.koUntil == 0 then
			buildBody(live)
		end
		return
	end
	local rig = live.rig :: FamiliarRig.Rig
	if not rig.root.Parent then
		live.rig = nil
		aliveCount -= 1
		return
	end
	local _, _, ownerRoot = ownerBody(player)
	local position = rig.root.Position
	local ownerPosition = if ownerRoot then ownerRoot.Position else position
	local ownerSpeed = if ownerRoot then ownerRoot.AssemblyLinearVelocity.Magnitude else 0

	if not targetAlive(live.target) or (live.target :: Target).untilClock < now then
		live.target = nil
	end

	-- Slower checks.
	live.secondAcc += T.stepSeconds
	if live.secondAcc >= T.secondSeconds then
		live.secondAcc = 0
		if ownerRoot then
			local last = live.lastOwnerPosition
			if not last or (ownerPosition - last).Magnitude >= T.activeMove then
				live.lastOwnerPosition = ownerPosition
				live.lastAction = now
			end
			hunt(live, ownerPosition)
		end
		if now - live.lastFight >= T.regenAfter and live.health < live.stats.maxHealth then
			live.health = math.min(live.stats.maxHealth, live.health + live.stats.maxHealth * T.regen)
			showHealth(live)
		end
		if now >= live.nextTier then
			live.nextTier = now + T.tierEvery
			local state = playerData:get(player)
			if state then
				local tier = bestTier(state)
				if tier ~= live.tier then
					live.tier = tier
					refreshStats(live)
					showHealth(live)
				end
			end
		end
	end

	local target = live.target
	local reach = T.biteReach
	local targetDistance, targetToOwner = math.huge, math.huge
	if target then
		local size = target.root.Size
		targetDistance = (target.root.Position - position).Magnitude - math.max(size.X, size.Z) / 2
		targetToOwner = (target.root.Position - ownerPosition).Magnitude
	end
	local stay = live.record.mode == "stay"
	local action = Rules.decide({
		hasOwner = ownerRoot ~= nil,
		frozen = TimeZones.stopped(position),
		mode = live.record.mode,
		ownerDistance = (ownerPosition - position).Magnitude,
		hasTarget = target ~= nil,
		targetInReach = targetDistance <= reach,
		targetToOwner = targetToOwner,
		inDuel = PvpRules.inDuel(player.UserId),
	})

	if action == "teleport" then
		local at = besideOwner(live, ownerPosition)
		local spot = at + Vector3.new(0, live.hover, 0)
		rig.root.AssemblyLinearVelocity = Vector3.zero
		rig.root.CFrame = CFrame.new(spot)
		rig.align.Position = spot
		live.groundY = at.Y
		live.stayAt = nil
		return
	end
	if action == "attack" and target then
		if targetDistance > reach and not stay then
			moveTo(live, rig, target.root.Position, ownerSpeed, now)
		end
		if targetDistance <= reach and now >= live.nextBite then
			live.nextBite = now + live.stats.biteCooldown
			if strike(live, target, live.stats.bite, "familiar_bite", live.identity.domain, position) > 0 then
				runner:cue("familiar", { fx = "bite", domain = live.identity.domain, to = target.root.Position }, position, false)
				hurtBack(live, target.humanoid.MaxHealth)
				if not live.rig then
					return
				end
			end
		end
		tryAbilities(live, position, now)
		return
	end
	if action == "follow" then
		moveTo(live, rig, followSpot(live, ownerPosition), ownerSpeed, now)
	elseif stay then
		local anchor = live.stayAt or position
		live.stayAt = anchor
		moveTo(live, rig, Vector3.new(anchor.X, anchor.Y - live.hover, anchor.Z), 0, now)
	end
	-- Not fighting, but mending still works, and stepping aside is no reason to stop helping.
	if ownerRoot then
		tryAbilities(live, position, now)
	end
end

-- ─── Starting up, and bonding ───────────────────────────────────────────────

local function makeLive(player: Player, state: any): Live
	local record = state.data.familiar
	local profile = state.data.profile
	local identity = Rules.generate(worldService:getSeed(), player.UserId, record.domain, profile and profile.temperaments or {}, InnateProfile.signatureColors(profile))
	local tier = bestTier(state)
	local stage = Rules.stageOf(record.xp)
	local now = os.clock()
	local live: Live = {
		player = player,
		record = record,
		identity = identity,
		stage = stage,
		tier = tier,
		nextTier = 0,
		stats = { maxHealth = 0, bite = 0, biteCooldown = T.biteCooldown, speed = T.speed },
		rig = nil,
		health = 0,
		shownHealth = 1,
		koUntil = 0,
		displayName = identity.defaultName,
		target = nil,
		nextBite = 0,
		nextAbility = {},
		lastFight = 0,
		lastAction = now,
		lastCastXp = 0,
		lastOwnerPosition = nil,
		hover = 0,
		hoverPhase = identity.followAngle,
		stayAt = nil,
		secondAcc = 0,
		groundAcc = 0,
		groundY = nil,
	}
	refreshStats(live)
	return live
end

local function filterInto(live: Live)
	local raw: string = live.record.name
	if raw == "" then
		live.displayName = live.identity.defaultName
	else
		local filtered = spellbook:filterName(live.player, raw)
		live.displayName = if filtered and filtered ~= "" then filtered else live.identity.defaultName
	end
	local rig = live.rig
	if rig then
		rig.nameLabel.Text = nameTag(live)
	end
end

local function wake(player: Player, state: any): Live
	local existing = lives[player]
	if existing then
		return existing
	end
	local live = makeLive(player, state)
	lives[player] = live
	buildBody(live)
	local learned = learnIfDue(live) -- one that passed the stage before it had anything to learn from
	task.spawn(function()
		filterInto(live)
		push(live, player, if learned then live.displayName .. learned else nil)
	end)
	return live
end

local function bond(player: Player, state: any): Live?
	local record = state.data.familiar
	local profile = state.data.profile
	if record.bonded ~= 0 or not profile then
		return nil
	end
	record.bonded = os.time()
	record.domain = Rules.bondDomain(profile.manifest or {}, profile.domains or {})
	local live = wake(player, state)
	local rig = live.rig
	if rig then
		runner:cue("familiar", { fx = "born", domain = record.domain }, rig.root.Position, true)
	end
	local note = string.format("Something answers your magic: %s, a small %s creature. Press O to see it.", live.displayName, record.domain)
	journal:log(player, "discovery", string.format("Your magic has drawn something to you. You've called it %s, for now.", live.displayName))
	log:info("familiar_bonded", { userId = player.UserId, domain = record.domain, shape = live.identity.shape, personality = live.identity.personality.word })
	push(live, player, note)
	return live
end

local function checkBond(player: Player)
	if not enabled() then
		return
	end
	local state = playerData:get(player)
	if not state then
		return
	end
	local record = state.data.familiar
	if record.bonded ~= 0 then
		wake(player, state)
	elseif Rules.shouldBond(record.casts, bestTier(state)) then
		bond(player, state)
	end
end

-- ─── Things that happen in the world ────────────────────────────────────────

local function onSpell(payload: any)
	local player = Players:GetPlayerByUserId(payload.casterUserId)
	local state = player and playerData:get(player)
	if not player or not state then
		return
	end
	local record = state.data.familiar
	record.casts += 1
	if record.bonded == 0 then
		checkBond(player)
		return
	end
	local domain = payload.domains and payload.domains[1]
	if typeof(domain) == "string" and F.abilities[domain] then
		record.tally[domain] = (record.tally[domain] or 0) + 1
	end
	local live = lives[player]
	if not live then
		return
	end
	local now = os.clock()
	live.lastAction = now
	if payload.effective and now - live.lastCastXp >= T.castGap then
		live.lastCastXp = now
		grow(live, T.castXp)
	end
end

-- You hit something, or something with a name hit you: that's who it goes for.
local function onDamaged(payload: any)
	local source: number? = payload.sourceUserId
	local model: Model? = payload.model
	if not model then
		return
	end
	local kind: string = payload.kind or ""
	if source and string.sub(kind, 1, 8) ~= "familiar" and not StatusEffects.defs[kind] then
		local attacker = Players:GetPlayerByUserId(source)
		local live = attacker and lives[attacker]
		if live and attacker and attacker.Character ~= model then
			live.lastAction = os.clock()
			if live.record.mode ~= "follow" and not model:GetAttribute("FamiliarOwner") then
				setTarget(live, model)
			end
		end
	end
	local victim = Players:GetPlayerFromCharacter(model)
	if victim and source and source ~= victim.UserId then
		local live = lives[victim]
		local attacker = Players:GetPlayerByUserId(source)
		if live and attacker and attacker.Character and live.record.mode ~= "follow" then
			setTarget(live, attacker.Character)
		end
	end
end

-- A creature's bite (it has no source player). Cast/Damage tells us who bit you.
local function onAttacked(humanoid: Humanoid, attacker: Model)
	local model = humanoid.Parent
	local victim = if model and model:IsA("Model") then Players:GetPlayerFromCharacter(model) else nil
	local live = victim and lives[victim]
	if live and live.record.mode ~= "follow" then
		setTarget(live, attacker)
	end
end

local function onKilled(payload: any)
	local model: Model? = payload.model
	local entry = model and lastHitBy[model]
	if not entry or os.clock() - entry.at > T.targetMemory then
		return
	end
	local live = entry.live
	if lives[live.player] == live then
		grow(live, Rules.killXp(payload.humanoid and payload.humanoid.MaxHealth or 0))
	end
end

-- ─── Intents ────────────────────────────────────────────────────────────────

local function action(player: Player, op: string, value: string?): { [string]: any }
	if op == "state" then
		return { ok = true, view = viewOf(lives[player], player) }
	end
	if not enabled() then
		return { ok = false, reason = "OFF" }
	end
	local live = lives[player]
	if not live then
		return { ok = false, reason = "NOT_BONDED" }
	end
	local record = live.record
	if op == "mode" then
		if not Rules.modeExists(value) then
			return { ok = false, reason = "BAD_MODE" }
		end
		record.mode = value
		live.stayAt = nil
		live.target = nil
		push(live, player)
		return { ok = true }
	elseif op == "summon" then
		record.summoned = true
		if not live.rig and live.koUntil == 0 and not buildBody(live) then
			push(live, player)
			return { ok = false, reason = "NO_ROOM" }
		end
		push(live, player)
		return { ok = true }
	elseif op == "dismiss" then
		record.summoned = false
		destroyBody(live)
		push(live, player)
		return { ok = true }
	elseif op == "rename" then
		record.name = Rules.cleanName(value or "")
		filterInto(live) -- yields on TextService: fine in a remote's own thread
		push(live, player)
		log:info("familiar_renamed", { userId = player.UserId })
		return { ok = true, name = live.displayName }
	end
	return { ok = false, reason = "BAD_OP" }
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "familiar",
		category = "Spells",
		description = "bond it now, status, xp <amount>, stage <1-5>, mode <1-4 follow guard hunt stay>, ko, or forget it (erases that player's familiar)",
		args = {
			{ name = "action", type = "enum", options = { "bond", "status", "xp", "stage", "mode", "ko", "forget" } },
			{ name = "amount", type = "number", optional = true },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_ctx: any, a: any)
			local player: Player = a.player
			local state = playerData:get(player)
			if not state then
				return "no data for them yet"
			end
			if not enabled() then
				return "flag familiars_enabled is off"
			end
			if a.action == "bond" then
				local live = bond(player, state)
				return if live then string.format("%s: %s %s", live.displayName, live.record.domain, live.identity.shape) else "already bonded, or no profile yet"
			end
			if a.action == "forget" then
				local live = lives[player]
				if live then
					destroyBody(live)
					lives[player] = nil
				end
				state.data.familiar = { bonded = 0, domain = "", xp = 0, day = 0, dayXp = 0, casts = 0, name = "", mode = F.defaultMode, summoned = true, learned = "", tally = {} }
				push(nil, player)
				return "forgotten: it bonds again from their next spells"
			end
			local live = lives[player]
			if not live then
				return "they have no familiar yet: familiar bond"
			end
			local record = live.record
			if a.action == "status" then
				local learned = if record.learned ~= "" then record.learned else "nothing yet"
				return string.format(
					"%s (%s, %s, %s): stage %d %s, xp %d (%d today), health %d/%d, bite %.1f, mode %s, learned %s, target %s, alive here %d",
					live.displayName, record.domain, live.identity.shape, live.identity.personality.word, live.stage, F.stages[live.stage].name,
					record.xp, record.dayXp, live.health, live.stats.maxHealth, live.stats.bite, record.mode, learned,
					if live.target then live.target.model.Name else "none", aliveCount
				)
			elseif a.action == "xp" or a.action == "stage" then
				local amount = tonumber(a.amount) or 0
				record.day = os.time() // 86400
				record.dayXp = 0 -- an admin's XP doesn't use up the player's day
				if a.action == "stage" then
					local stage = F.stages[math.clamp(math.floor(amount), 1, #F.stages)]
					record.xp = stage.xp
					live.stage = 0 -- so grow() notices, even when going down
				else
					record.xp += math.max(0, amount)
				end
				live.lastAction = os.clock()
				grow(live, 0.001)
				return string.format("xp %d, stage %d", record.xp, live.stage)
			elseif a.action == "mode" then
				local mode = F.modes[math.clamp(math.floor(tonumber(a.amount) or 2), 1, #F.modes)]
				record.mode = mode.id
				live.target = nil
				push(live, player)
				return "mode " .. mode.id
			elseif a.action == "ko" then
				knockOut(live)
				return "knocked out"
			end
			return "?"
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function FamiliarService.init(_self: any, ctx: any)
	log = ctx.log
	runner = ctx.get("EffectRunner")
	journal = ctx.get("JournalService")
	playerData = ctx.get("PlayerDataService")
	spellbook = ctx.get("SpellbookService")
	worldService = ctx.get("WorldService")
	world = ctx.get("WorldStateService")
	Net.handle("FamiliarAction", action)
	ctx.bus:subscribe(Topics.SpellResolved, onSpell)
	ctx.bus:subscribe(Topics.TargetDamaged, onDamaged)
	ctx.bus:subscribe(Topics.TargetKilled, onKilled)
	Damage.onAttacked = onAttacked
	ctx.bus:subscribe(Topics.PlayerDataLoaded, function(payload: any)
		task.defer(checkBond, payload.player) -- after ProgressionService has unlocked the roots
	end)
	registerAdmin(ctx.get("AdminService"))
end

function FamiliarService.start(_self: any, _ctx: any)
	local parent = Instance.new("Folder")
	parent.Name = "Familiars"
	parent.Parent = workspace
	folder = parent
	Players.PlayerRemoving:Connect(function(player)
		local live = lives[player]
		if live then
			destroyBody(live)
			lives[player] = nil
		end
	end)
	task.spawn(function()
		while true do
			task.wait(T.stepSeconds)
			local now = os.clock()
			if enabled() then
				for _, live in lives do
					-- One failure mustn't stop everyone else's familiar.
					local ok, err = pcall(stepOne, live, now)
					if not ok then
						log:throttled("familiar_step", 30, "Error", "familiar_step_failed", { err = err })
					end
				end
			elseif aliveCount > 0 then
				for _, live in lives do
					destroyBody(live)
				end
			end
		end
	end)
	-- Anyone who bonded before the world finished loading, or joined just as this started.
	for _, player in Players:GetPlayers() do
		task.defer(checkBond, player)
	end
	log:info("familiars_ready", { max = tonumber(FeatureFlags.get("familiars_max_alive")) or 60 })
end

return FamiliarService
