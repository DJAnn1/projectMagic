--!strict
--[[
	NPCCombat: what an NPC does when someone hurts it (or someone near it). Driven by NPCService
	from TargetDamaged / MagicDamage; numbers in Magic/Data/CombatTuning.aggro.

	AGGRO    npc.combat.threat[subject] (subject = "u:<userId>"): + threatPerDamage per point of
	         damage taken, + witnessThreat for guards and hunters who see a neighbour attacked;
	         decays decayPerSecond. The target is the highest threat whose character is alive.
	STANCE   decided when the fight starts (and re-decided if health drops below a third):
	             courage = Σ courage weights x (trait - 0.5) x 2 + magic tier x courageMagicPerTier
	                       + (health share - 0.5) x courageHealthWeight (+ guardBonus for guards/hunters)
	             fight  if courage >= fightAt and the NPC has an attack spell, else flee.
	         Children and the retired always flee.
	FIGHT    (T0 rigs) close to keepDistance, face the target, and every castInterval cast a real
	         bolt: the NPC's own magic (best branch's domain -> attackProperties, validated with
	         MagicCore against its caster profile, power capped by its mastery and maxPower), flown
	         by Cast/Delivery and dealt by Cast/DamageModel, with launch/resolve cues in its
	         Signature. NPCs don't pay reservoir: the interval is their limit.
	FLEE     run fleeDistance away from the attacker at a jog (unless a status owns WalkSpeed).
	GUARD    a fighting NPC watches its target: when the target starts a cast, it may raise its
	         guard (Cast/Guard) after a reaction delay and hold it briefly. Chance and speed from
	         magic tier and conscientiousness (guardBase/PerTier/Trait, guardReact*), so skilled,
	         careful NPCs block often and sometimes parry (a raise lands inside the parry window).
	         A parried bolt can come back at the NPC that threw it.
	ENDS     no hit for maxEngageSeconds, threat decayed away, target gone, or the NPC knocked out.
	         Then the brain re-decides (safety is low, so shelter usually wins).
	While engaged, NPCService skips the NPC's brain routing and walks it from here; knockdowns and
	flinches still pause it (HitReactions attributes).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local MagicCore = require(Shared.Magic.MagicCore)
local Registry = require(Shared.Magic.Registry)
local Seed = require(Shared.Magic.Seed)

local Server = script.Parent.Parent
local C = require(Server.Magic.Data.CombatTuning)
local Delivery = require(Server.Magic.Cast.Delivery)
local DamageModel = require(Server.Magic.Cast.DamageModel)
local Targeting = require(Server.Magic.Cast.Targeting)
local ActionState = require(Server.Magic.Cast.ActionState)
local Guard = require(Server.Magic.Cast.Guard)
local ActionRules = require(Shared.Magic.ActionRules)
local Charge = require(Shared.Magic.Charge)
local NPCMagicLife = require(script.Parent.NPCMagicLife)

local A = C.aggro
local JOG = 16

export type Combat = {
	threat: { [string]: number },
	stance: string, -- "fight" | "flee"
	target: string?,
	lastHit: number, -- os.clock()
	nextCast: number,
	casts: number,
	jogging: boolean,
	watchedSeq: number, -- the target's last action-state seq we reacted to
}

local NPCCombat = {}

local worldSeed = 0
local runner: any = nil

function NPCCombat.init(seed: number, effectRunner: any)
	worldSeed = seed
	runner = effectRunner
end

-- ─── Decisions ──────────────────────────────────────────────────────────────

function NPCCombat.courage(npc: any, healthShare: number): number
	local c = 0
	for trait, weight in A.courage do
		c += weight * ((npc.traits[trait] or 0.5) - 0.5) * 2
	end
	local _, _, tier = NPCMagicLife.best(npc)
	c += tier * A.courageMagicPerTier
	c += (healthShare - 0.5) * A.courageHealthWeight
	if npc.occupation == "guard" or npc.occupation == "hunter" then
		c += A.guardBonus
	end
	return c
end

--[[
	The NPC's attack spell: a projectile in its best branch, first valid property for that branch's
	domain (then the fallbacks), at the highest power its mastery allows (<= maxPower). Cached per
	magical chapter; nil when it has no usable offensive magic.
]]
function NPCCombat.attackRecipe(npc: any): any?
	local magic = npc.magic
	local cache = npc.combatRecipe
	if cache ~= nil and npc.combatRecipeChapter == magic.chapter then
		return if cache == false then nil else cache
	end
	npc.combatRecipeChapter = magic.chapter
	npc.combatRecipe = false
	local branchId = NPCMagicLife.best(npc)
	if not branchId or not magic.caster or npc.age < 12 then
		return nil
	end
	local cap = math.min(A.maxPower, MagicCore.powerCap(magic.caster, branchId))
	if cap < 1 then
		return nil
	end
	local domain = Registry.branches[branchId].domains[1]
	local tries = table.clone(A.attackProperties[domain] or {})
	for _, p in A.fallbackProperties do
		table.insert(tries, p)
	end
	for _, property in tries do
		local raw = { branch = branchId, property = property, verb = "generate", form = "projectile", power = cap }
		local ok, _, recipe = MagicCore.validateRecipe(raw, magic.caster)
		if ok and recipe and Registry.properties[property].harmful then
			npc.combatRecipe = recipe
			return recipe
		end
	end
	return nil
end

local function healthShare(npc: any): number
	local rig = npc.rig
	if not rig then
		return 1
	end
	return rig.humanoid.Health / math.max(1, rig.humanoid.MaxHealth)
end

local function chooseStance(npc: any): string
	if A.alwaysFlee[npc.occupation] or npc.ageBand == "child" then
		return "flee"
	end
	if NPCCombat.courage(npc, healthShare(npc)) >= A.fightAt and NPCCombat.attackRecipe(npc) then
		return "fight"
	end
	return "flee"
end

local function combatOf(npc: any): Combat
	local c: Combat? = npc.combat
	if c then
		return c
	end
	local fresh: Combat =
		{ threat = {}, stance = "flee", target = nil, lastHit = os.clock(), nextCast = 0, casts = 0, jogging = false, watchedSeq = 0 }
	npc.combat = fresh
	return fresh
end

-- Someone hurt this NPC. Returns the stance (for NPCService's speech).
function NPCCombat.onAttacked(npc: any, subject: string?, amount: number): string
	local fresh = npc.combat == nil
	local c = combatOf(npc)
	c.lastHit = os.clock()
	if subject then
		c.threat[subject] = (c.threat[subject] or 0) + amount * A.threatPerDamage
	end
	if fresh then
		c.stance = chooseStance(npc)
		c.nextCast = os.clock() + 0.6 + (npc.seed % 7) * 0.1 -- a beat to react before the first bolt
	elseif c.stance == "fight" and healthShare(npc) < 0.33 then
		c.stance = chooseStance(npc) -- badly hurt: courage may break
	end
	return c.stance
end

-- A guard or hunter saw someone attacked nearby: they come to help (if they can fight).
function NPCCombat.onWitness(npc: any, subject: string)
	if npc.occupation ~= "guard" and npc.occupation ~= "hunter" then
		return
	end
	local fresh = npc.combat == nil
	local c = combatOf(npc)
	c.lastHit = os.clock()
	c.threat[subject] = (c.threat[subject] or 0) + A.witnessThreat
	if fresh then
		c.stance = if NPCCombat.attackRecipe(npc) then "fight" else "flee"
		c.nextCast = os.clock() + 1 + (npc.seed % 9) * 0.1
	end
end

--[[
	A fight that isn't about courage: a duel the NPC agreed to, or a quest hostile sent for the
	player. Fights if it has an attack spell (else flees), and won't break off for decay alone
	while the subject is near.
]]
function NPCCombat.challenge(npc: any, subject: string)
	local c = combatOf(npc)
	c.lastHit = os.clock()
	c.threat[subject] = math.max(c.threat[subject] or 0, A.witnessThreat * 4)
	c.stance = if NPCCombat.attackRecipe(npc) then "fight" else "flee"
	c.nextCast = os.clock() + 1.2
end

function NPCCombat.engaged(npc: any): boolean
	return npc.combat ~= nil
end

local function characterOf(subject: string): (Model?, BasePart?)
	if string.sub(subject, 1, 2) ~= "u:" then
		return nil, nil
	end
	local player = Players:GetPlayerByUserId(tonumber(string.sub(subject, 3)) or 0)
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then
		return character, root
	end
	return nil, nil
end

-- Ends the fight: walking speed back, brain re-decides on its next tick.
function NPCCombat.disengage(npc: any)
	local c: Combat? = npc.combat
	npc.combat = nil
	npc.actionUntil = 0
	local rig = npc.rig
	if c and c.jogging and rig and rig.humanoid:GetAttribute("MagicBaseWalk") == nil then
		rig.humanoid.WalkSpeed = 10
	end
end

-- ─── Casting ────────────────────────────────────────────────────────────────

-- Fires the bolt after the charge: the same Delivery and DamageModel as a player's cast, at the
-- stage's power (and projectile speed).
local function launchBolt(npc: any, rig: any, recipe: any, stats: any, applied: Charge.Applied, targetModel: Model, targetRoot: BasePart)
	local c = npc.combat :: Combat
	local root: BasePart = rig.root
	local ctx: any = {
		player = nil, -- NPC caster: no Player, no source UserId
		character = rig.model,
		root = root,
		stats = stats,
		context = {},
		power = stats.power,
		origin = root.Position,
		point = targetRoot.Position,
		measuredAt = targetRoot.Position,
		target = targetModel,
		onSurface = false,
		backfire = false,
		pulse = 0,
		rng = Seed.random(worldSeed, "npc:" .. tostring(npc.id), "combat", c.casts),
		world = nil,
		stored = {},
		runtime = runner,
		services = {},
		speedMult = applied.speedMult,
	}
	local flight = Delivery.plan(ctx)
	local base = {
		domain = stats.domains[1],
		property = recipe.property,
		verb = recipe.verb,
		form = recipe.form,
		power = recipe.power,
		masteryTier = stats.masteryTier,
		harmful = true,
		radius = stats.area,
		castTime = stats.castTime,
		backfire = false,
		signature = npc.signatureJson,
		npcId = npc.id,
		caster = nil,
	}
	local launch = table.clone(base)
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
	-- The release resumes the charging pose (NPCLOD.followState) as the bolt launches.
	ActionState.set(rig.model, "casting", { duration = math.max(stats.castTime, 0.35), domain = stats.domains[1] })

	-- Parried (Cast/Guard): the old bolt bursts on the ward, a new one comes back.
	flight.onReflect = function(oldId: number, at: Vector3, velocity: Vector3)
		local burst = table.clone(base)
		burst.stage, burst.origin, burst.point, burst.projectileId = "resolve", at, at, oldId
		runner:cue("spell", burst, at, false)
		local back = table.clone(base)
		back.stage, back.origin, back.point, back.projectileId = "launch", at, root.Position, flight.id
		back.velocity, back.gravity, back.hitRadius = velocity, flight.gravity, flight.radius
		back.turnRate, back.lifetime = flight.turnRate, flight.lifetime
		runner:cue("spell", back, at, false)
	end
	task.spawn(function()
		local impact = Delivery.fly(flight, { rig.model })
		local resolve = table.clone(base)
		resolve.stage = "resolve"
		resolve.origin = flight.origin
		resolve.point = impact.point
		resolve.projectileId = flight.id
		resolve.normal = impact.normal
		resolve.expired = impact.expired
		runner:cue("spell", resolve, impact.point, false)
		ctx.point = impact.point
		for _, hit in impact.hits do
			-- Its own bolt only hurts it when someone parried it back.
			if hit.model ~= rig.model or impact.reflectedBy then
				DamageModel.hit(ctx, hit, 1, recipe.property)
			end
		end
	end)
end

-- Telegraphed charge (Casting.md §8): the NPC winds up (the frozen CastSpell pose, "charging")
-- for its stage's hold time, then fires. Stage by a seeded roll; skilled casters charge fuller.
-- NPCs never overcharge (no backlash for them to suffer). The charge is dropped if the NPC or its
-- target is gone, or something interrupted it (a knockdown sets "staggered").
local function castBolt(npc: any, targetModel: Model, targetRoot: BasePart)
	local rig = npc.rig
	local recipe = NPCCombat.attackRecipe(npc)
	if not rig or not recipe or not Delivery.capacity() then
		return
	end
	local stats = MagicCore.computeStats(recipe, npc.magic.caster, nil)
	if not stats then
		return
	end
	local c = npc.combat :: Combat
	c.casts += 1
	local roll = Seed.random(worldSeed, "npc:" .. tostring(npc.id), "charge", c.casts):NextNumber()
	local fullShare = A.chargeFullBase + A.chargeFullPerTier * (stats.masteryTier or 0)
	local index = if roll < A.chargeTapShare then 1 elseif roll < A.chargeTapShare + fullShare then 3 else 2
	local stage = Charge.stage(index)
	local hold = if stage.castTime then 0.2 else Charge.step(stats.castTime) * stage.at
	ActionState.set(rig.model, "charging", { duration = hold + 0.5, domain = stats.domains[1] })
	task.delay(hold, function()
		local alive = rig.model.Parent ~= nil and rig.humanoid.Health > 0 and npc.rig == rig
		if not alive or ActionState.get(rig.model) ~= "charging" or not targetRoot.Parent then
			return -- knocked down, despawned, or the target is gone
		end
		local applied = Charge.apply(stats, index, hold)
		launchBolt(npc, rig, recipe, stats, applied, targetModel, targetRoot)
	end)
end

-- A fighting NPC sees its target begin a cast and may raise its guard in time.
local function watchTarget(npc: any, c: Combat, rig: any, targetModel: Model)
	local snapshot = ActionRules.read(targetModel)
	if snapshot.seq == c.watchedSeq then
		return
	end
	c.watchedSeq = snapshot.seq
	if snapshot.state ~= "casting" and snapshot.state ~= "charging" then
		return
	end
	local _, _, tier = NPCMagicLife.best(npc)
	local careful = (npc.traits.conscientiousness or 0.5) - 0.5
	local chance = math.clamp(A.guardBase + A.guardPerTier * tier + A.guardTrait * careful, 0, A.guardMax)
	local roll = Seed.random(worldSeed, "npc:" .. tostring(npc.id), "guard", snapshot.seq):NextNumber()
	if roll >= chance then
		return
	end
	local react = math.max(A.guardReactMin, A.guardReactBase - A.guardReactPerTier * tier)
	local domain = rig.model:GetAttribute("ActionStateDomain")
	task.delay(react, function()
		if npc.rig ~= rig or not rig.model.Parent or rig.humanoid.Health <= 0 then
			return
		end
		local ok = Guard.raise(rig.model, if typeof(domain) == "string" then domain else "energy")
		if ok then
			task.delay(A.guardHold, function()
				if npc.rig == rig and Guard.isGuarding(rig.model) then
					Guard.lower(rig.model)
				end
			end)
		end
	end)
end

-- ─── Stepping (T0, ~10 Hz) ──────────────────────────────────────────────────

local function decay(c: Combat, dt: number): string?
	local best, bestThreat = nil, A.forgetBelow
	for subject, threat in c.threat do
		local left = threat - A.decayPerSecond * dt
		if left < A.forgetBelow then
			c.threat[subject] = nil
		else
			c.threat[subject] = left
			if left >= bestThreat and characterOf(subject) then
				best, bestThreat = subject, left
			end
		end
	end
	return best
end

-- Advances an engaged NPC. Returns false when the fight is over (and has disengaged it).
function NPCCombat.step(npc: any, dt: number): boolean
	local c: Combat? = npc.combat
	local rig = npc.rig
	if not c or not rig or npc.knockedOut then
		NPCCombat.disengage(npc)
		return false
	end
	local clock = os.clock()
	c.target = decay(c, dt)
	if not c.target or clock - c.lastHit > A.maxEngageSeconds then
		NPCCombat.disengage(npc)
		return false
	end
	local targetModel, targetRoot = characterOf(c.target :: string)
	if not targetModel or not targetRoot then
		NPCCombat.disengage(npc)
		return false
	end
	local humanoid: Humanoid = rig.humanoid
	local root: BasePart = rig.root
	npc.position = root.Position
	-- Knocked down or flinching: no moving this tick.
	local flinchUntil = humanoid:GetAttribute("FlinchUntil")
	if
		humanoid:GetAttribute("KnockedDown")
		or (typeof(flinchUntil) == "number" and flinchUntil > workspace:GetServerTimeNow())
	then
		humanoid:Move(Vector3.zero)
		return true
	end
	if humanoid:GetAttribute("MagicBaseWalk") == nil then
		humanoid.WalkSpeed = JOG
		c.jogging = true
	end

	local offset = targetRoot.Position - root.Position
	local flat = Vector3.new(offset.X, 0, offset.Z)
	local distance = flat.Magnitude
	local toward = if distance > 0.1 then flat.Unit else root.CFrame.LookVector

	if c.stance == "flee" then
		humanoid:MoveTo(root.Position - toward * A.fleeDistance)
		if rig.tracks.walk and not rig.tracks.walk.IsPlaying then
			rig.tracks.walk:Play()
		end
		return true
	end

	watchTarget(npc, c, rig, targetModel)
	if Guard.isGuarding(rig.model) then
		humanoid:Move(Vector3.zero)
		root.CFrame = CFrame.lookAt(root.Position, root.Position + toward) -- the ward faces the threat
		return true
	end

	-- Fight: hold keepDistance, face the target, cast when ready and in sight.
	if distance > A.keepDistance + 4 then
		humanoid:MoveTo(targetRoot.Position - toward * A.keepDistance)
	elseif distance < A.keepDistance - 6 then
		humanoid:MoveTo(root.Position - toward * 6)
	else
		humanoid:Move(Vector3.zero)
		root.CFrame = CFrame.lookAt(root.Position, root.Position + toward)
	end
	if clock >= c.nextCast and distance <= A.castRange then
		local eye = root.Position + Vector3.new(0, 1.5, 0)
		if Targeting.lineOfSight(eye, targetRoot.Position, { rig.model, targetModel }, 2) then
			local jitter = 0.8 + ((npc.seed + c.casts * 7919) % 41) / 100 -- 0.8 .. 1.2, deterministic
			c.nextCast = clock + A.castInterval * jitter
			castBolt(npc, targetModel, targetRoot)
		end
	end
	return true
end

return NPCCombat
