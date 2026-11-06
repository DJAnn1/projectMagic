--!strict
--[[
	CastService: turns a client's CastIntent into magic in the world. Server-authoritative: the
	client sends only (recipe, aim point, target?); every number is recomputed here from the
	player's real caster profile and the world as the server measures it.

	PIPELINE (each step can refuse with a reason code; nothing is paid before step 9)
	 1. GATES      casting enabled, data loaded, alive, not silenced, not mid-cast or inside the
	               global cooldown (the Net layer already rate-limited the remote)
	 2. VALIDATE   MagicCore.validateRecipe with the real caster: knowledge (unlocked branch),
	               mastery tier (verbs, forms, power cap), grammar; in equip mode a client cast
	               must be the attuned spell (AttunementService, NOT_ATTUNED)
	 3. COOLDOWN   per recipe key
	 4. AIM        plausibility (not deep underground), range (stats.range with tolerance),
	               explicit target near the aim point, line of sight from the caster's head
	 5. ROUTE      Data/EffectLibrary picks the effect resolver (Cast/Effects/*) and its params
	 6. MEASURE    WorldStateService:castContext where the resolver says (usually the aim point)
	 7. STATS      MagicCore.computeStats with that context (affinity, mastery, temperament
	               traits, ambient density, resonance, modifiers, environment rules), then the
	               player's items (Items/StatCache.applyToCast: spell/domain power, cast speed,
	               cost, stability, and the focus tradeoff at power 6+; docs/Items.md §5)
	 8. REQUIRE    verb requirement (Target/Source: something there; Stored: a held charge), the
	               resolver's own precheck (field/light budgets), the per-server heavy budget
	               (EffectBudget), enough health for a Vital price
	 9. PAY        Reservoir.trySpend with a seeded Random (worldSeed, "player:<id>", "cast",
	               castCounter); HP for the Vital price; overdraw consequences (weakened by item
	               backlash resistance) through BacklashService (backlash damage, burnout,
	               lockouts, the domain's risk effect)
	10. COMMIT     cooldown, busy-until-cast-time, settlement law (judgeCast), CastResult
	               "accepted", a "spell begin" cue (EffectRunner LOD fan-out)
	11. RESOLVE    after castTime (+ delay modifier): interrupted if the caster died; backfire roll
	               (x StatusEffects.backfireMult: Fortune); the resolver applies the effect; echoes
	               and channel pulses; loss of control (BacklashService) on high-power backfires
	12. AFTERMATH  presence for InteractionMatrix (emergent reactions), magic pressure,
	               EventDirector relief, Topics.MagicWitnessed (NPC reactions), practice XP
	               (challenge when overdrawn, badly hurt or inside a world event), discovery log,
	               spellbook cast count, observation XP, survival facts, CastResult "resolved"

	CastResult (server -> caster), see also Net/Remotes and docs/UI.md §10:
		refused   { ok = false, stage = "refused", key?, reason, detail?, cooldownUntil? }
		accepted  { ok = true, stage = "accepted", key, cost, hpCost, castTime, cooldownUntil, consequences, riskNote? }
		resolved  { ok = true, stage = "resolved", key, cooldownUntil, effective, hits, backfired,
		            interrupted?, note?, xp? = { branch, gained } }
	Cues: WorldEffect { kind = "spell", stage = "begin" | "launch" | "resolve" | "chain", lod, caster,
	domain, form, verb, property, power, masteryTier, harmful, origin, point, radius, castTime,
	backfire, + launch: projectileId, velocity, gravity, hitRadius, homing, turnRate, lifetime;
	resolve after a flight: projectileId, normal, expired; chain: points }. Clients style them with
	the caster's Signature (Player attribute "MagicSignature", set when data loads).

	COMBAT (docs/Combat.md): at resolve the spell re-aims at a moving validated target; projectile
	forms FLY (Cast/Delivery) and land where they really hit; every hit goes through
	Cast/DamageModel; each strike's damage is recorded (Damage.record) for the per-cast log
	(combat_debug_log flag) and Topics.SpellHit; Topics.SpellCast fires on accept.

	State is per session: cooldowns and stored charges reset on rejoin (the reservoir does too).
]]

local HttpService = game:GetService("HttpService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Types = require(Shared.Magic.Types)
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local Aim = require(Shared.Magic.Aim)
local Charge = require(Shared.Magic.Charge)
local Reservoir = require(Shared.Magic.Reservoir)
local Seed = require(Shared.Magic.Seed)
local Strike = require(Shared.Magic.Strike)

local MagicFolder = script.Parent.Parent.Magic
local T = require(MagicFolder.Data.CastTuning)
local C = require(MagicFolder.Data.CombatTuning)
local EffectLibrary = require(MagicFolder.Data.EffectLibrary)
local CastTypes = require(MagicFolder.Cast.CastTypes)
local Targeting = require(MagicFolder.Cast.Targeting)
local Delivery = require(MagicFolder.Cast.Delivery)
local Damage = require(MagicFolder.Cast.Damage)
local DamageModel = require(MagicFolder.Cast.DamageModel)
local EffectBudget = require(MagicFolder.Cast.EffectBudget)
local StatusEffects = require(MagicFolder.Cast.StatusEffects)
local ActionState = require(MagicFolder.Cast.ActionState)
local Finisher = require(MagicFolder.Cast.Finisher)
local InteractionMatrix = require(MagicFolder.Cast.InteractionMatrix)
local StatCache = require(script.Parent.Parent.Items.StatCache)

type Route = EffectLibrary.Route

type CasterState = {
	busyUntil: number,
	gcdUntil: number,
	cooldowns: { [string]: number }, -- recipe key -> server time when castable again
	stored: { [string]: { power: number, expires: number } },
	castCharacter: Model?, -- the character that started the current cast
}

type Pending = {
	player: Player,
	state: any, -- PlayerDataService state
	caster: CasterState,
	stats: Types.SpellStats,
	context: Types.CastContext,
	route: Route,
	resolver: CastTypes.Resolver,
	rng: Random,
	point: Vector3,
	measuredAt: Vector3,
	target: Model?,
	onSurface: boolean,
	challenge: boolean,
	heavy: boolean,
	cooldownUntil: number,
	noBacklash: boolean?,
	charge: Charge.Applied?, -- the hold-to-charge stage this cast was released at
	channel: Channel?, -- a client-held channelled spell (release or ChannelAim steer it)
}

-- Hold-to-charge (Casting.md §8): when the server saw "begin", on its own clock.
type Hold = { key: string, startedAt: number, maxHold: number, character: Model }
-- A channelled spell held by a client: released early, and where it's being swept to.
type Channel = { released: boolean, aim: Vector3?, point: Vector3? }

-- Admin spell tools (the panel's Spells tab). Per player, this session only; never saved.
export type Cheats = {
	infinite: boolean?, -- reservoir refilled before and after every cast
	noCooldown: boolean?, -- no recipe cooldowns or global cooldown
	noBacklash: boolean?, -- no overdraw consequences and no backfire
	overpowerOnce: boolean?, -- the next cast ignores knowledge, tier and power caps
	unboundOnce: boolean?, -- the next cast ignores aim, range and line of sight (castAs)
}

local CastService = {
	name = "CastService",
	dependencies = {
		"NetService",
		"PlayerDataService",
		"ReservoirService",
		"WorldStateService",
		"WorldService",
		"ProgressionService",
		"DiscoveryLog",
		"EventDirector",
		"AdminService",
		"EffectRunner",
		"BacklashService",
		"AttunementService",
	},
}

local log: any = nil
local flags: any = nil
local bus: any = nil
local playerData: any = nil
local reservoirs: any = nil
local world: any = nil
local worldService: any = nil
local progression: any = nil
local discovery: any = nil
local events: any = nil
local runner: any = nil
local backlash: any = nil
local attunement: any = nil

local holds: { [Player]: Hold } = {}
local channels: { [Player]: Channel } = {}

local resolvers: { [string]: CastTypes.Resolver } = {}
local casters: { [Player]: CasterState } = {}
local cheats: { [Player]: Cheats } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function casterStateOf(player: Player): CasterState
	local s = casters[player]
	if not s then
		s = { busyUntil = 0, gcdUntil = 0, cooldowns = {}, stored = {}, castCharacter = nil }
		casters[player] = s
	end
	return s
end

local function refuse(player: Player, key: string?, reason: string, extra: { [string]: any }?)
	local payload: { [string]: any } = { ok = false, stage = "refused", key = key, reason = reason }
	for k, v in (extra or {}) :: { [string]: any } do
		payload[k] = v
	end
	Net.fire("CastResult", player, payload)
	log:debug("cast_refused", { userId = player.UserId, reason = reason, key = key })
	return reason
end

-- A caster who knows everything at Transcendent with every domain at full affinity: the
-- admin "overpower" cast validates against this (grammar rules still apply).
local function unboundCaster(real: Types.CasterProfile): Types.CasterProfile
	local affinities, awakened, mastery, unlocked = {}, {}, {}, {}
	for _, d in Registry.domainIds do
		affinities[d], awakened[d] = 1, true
	end
	for _, b in Registry.branchIds do
		mastery[b], unlocked[b] = 100, true
	end
	return {
		id = real.id,
		affinities = affinities,
		awakened = awakened,
		mastery = mastery,
		unlocked = unlocked,
		branchAffinities = real.branchAffinities,
		traits = real.traits,
		branchMods = real.branchMods,
		signatures = real.signatures,
	}
end

-- ─── Routing (Data/EffectLibrary) ───────────────────────────────────────────

local function branchMatches(branch: Types.BranchDef, ids: { string }): boolean
	local node: Types.BranchDef? = branch
	while node do
		if table.find(ids, node.id) then
			return true
		end
		local parentId = node.parent
		node = if parentId then Registry.branches[parentId] else nil
	end
	for _, d in branch.domains do
		if table.find(ids, d) then
			return true
		end
	end
	return false
end

local function routeFor(recipe: Types.Recipe): Route
	local branch = Registry.branches[recipe.branch]
	local property = Registry.properties[recipe.property]
	for _, route in EffectLibrary.routes do
		if route.minPower and recipe.power < route.minPower then
			continue
		elseif route.maxPower and recipe.power > route.maxPower then
			continue
		elseif route.harmful ~= nil and property.harmful ~= route.harmful then
			continue
		elseif route.strike and Strike.routed(recipe) == nil then
			continue
		elseif route.properties and not table.find(route.properties, recipe.property) then
			continue
		elseif route.verbs and not table.find(route.verbs, recipe.verb) then
			continue
		elseif route.forms and not table.find(route.forms, recipe.form) then
			continue
		elseif route.categories and not table.find(route.categories, property.category) then
			continue
		elseif route.branches and not branchMatches(branch, route.branches) then
			continue
		end
		return route
	end
	return EffectLibrary.routes[#EffectLibrary.routes] -- manifest
end
CastService.routeFor = routeFor -- for specs and tools

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function aliveParts(character: Model?): (BasePart?, Humanoid?)
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
		return root, humanoid
	end
	return nil, nil
end

-- The "spell" cue, fanned out by distance (EffectRunner LOD). Clients add the Signature.
-- `extra` carries stage-specific fields (the launch's velocity, the impact's projectile id...).
local function cue(
	player: Player,
	stats: Types.SpellStats,
	origin: Vector3,
	point: Vector3,
	stage: string,
	heavy: boolean,
	backfire: boolean?,
	extra: { [string]: any }?
)
	local payload: { [string]: any } = {
		stage = stage,
		caster = player.UserId,
		domain = stats.domains[1],
		property = stats.recipe.property,
		verb = stats.recipe.verb,
		form = stats.recipe.form,
		power = stats.recipe.power,
		masteryTier = stats.masteryTier,
		harmful = stats.harmful,
		origin = origin,
		point = point,
		radius = stats.area,
		castTime = stats.castTime,
		backfire = backfire == true,
	}
	for k, v in (extra or {}) :: { [string]: any } do
		payload[k] = v
	end
	runner:cue("spell", payload, point, heavy)
end

-- Did the line from the eye to the aim end on something solid near the aim point?
local function landsOnSurface(eye: Vector3, aim: Vector3, character: Model): boolean
	local direction = aim - eye
	if direction.Magnitude < 0.1 then
		return true
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character }
	local result = workspace:Raycast(eye, direction + direction.Unit * 2, params)
	return result ~= nil and (result.Position - aim).Magnitude <= T.losTolerance
end

-- An aim point deep under the ground is a fabricated one (nothing legitimate aims there).
local function plausibleAim(aim: Vector3): boolean
	local ok, surface = pcall(world.surfaceHeight, world, aim.X, aim.Z)
	return not ok or surface - aim.Y <= T.maxAimBelowGround
end

-- ─── Resolution (after cast time) ───────────────────────────────────────────

local function merge(total: CastTypes.Outcome, extra: CastTypes.Outcome)
	total.effective = total.effective or extra.effective
	total.hits += extra.hits
	total.harmedSelf = total.harmedSelf or extra.harmedSelf
	total.note = total.note or extra.note
	total.effectId = total.effectId or extra.effectId
end

-- The per-cast combat log (Debug always; Info with the combat_debug_log flag) and Topics.SpellHit.
local function reportHits(p: Pending, record: { Damage.RecordEntry }, backfire: boolean): number
	local stats = p.stats
	local total = 0
	local lines: { string } = {}
	for _, entry in record do
		total += entry.dealt
		table.insert(
			lines,
			string.format(
				"%s %.1f%s%s (%s)",
				entry.name,
				entry.dealt,
				if entry.crit then " CRIT" else "",
				if entry.killed then " KILL" else "",
				entry.kind
			)
		)
	end
	local fields = {
		userId = p.player.UserId,
		key = stats.key,
		route = p.route.id,
		recipePower = stats.recipe.power,
		power = stats.power,
		base = math.floor(DamageModel.base(stats.power) * 10) / 10,
		backfire = backfire,
		total = math.floor(total * 10) / 10,
		hits = table.concat(lines, "; "),
	}
	if flags.get("combat_debug_log") == true then
		log:info("cast_hits", fields)
	else
		log:debug("cast_hits", fields)
	end
	if #record > 0 then
		bus:publish(Topics.SpellHit, {
			casterUserId = p.player.UserId,
			key = stats.key,
			route = p.route.id,
			domain = stats.domains[1],
			total = total,
			targets = record,
		})
	end
	return total
end

local function aftermath(
	p: Pending,
	outcome: CastTypes.Outcome,
	backfire: boolean,
	landedAt: Vector3,
	extraNote: string?,
	record: { Damage.RecordEntry }
)
	local player, stats = p.player, p.stats
	local totalDamage = reportHits(p, record, backfire)

	--[[
		Settlement law. A harmful spell only counts as harmful casting when it hurt someone (a
		player or NPC; practice dummies don't count) or changed the land (terrain routes and the
		world-recording ones: quakes, tsunamis). Otherwise a new player practising on the plaza
		posted a bounty in ~7 casts (docs/Improvements.md, Feel #1). Banned domains, forbidden
		magic and towns that ban all casting still judge every cast (Settlements.judgeCast).
	]]
	local hurtSomeone = false
	for _, entry in record do
		if not entry.practice then
			hurtSomeone = true
			break
		end
	end
	local changedLand = p.route.recordsWorld == true or p.route.effect == "Terrain"
	world:judgeCast(player, stats, landedAt, stats.harmful and (hurtSomeone or changedLand))

	-- Magic leaves a trace: other magic that meets it here can react (InteractionMatrix).
	runner:addPresence(
		InteractionMatrix.tagsFor(stats),
		landedAt,
		stats.area,
		stats.power,
		player.UserId,
		outcome.effectId,
		stats.recipe.branch
	)
	if not p.route.recordsWorld then
		world:noteMagic(landedAt, stats.domains, stats.power)
	end
	events:noteCast(landedAt, stats.domains, stats.power)
	bus:publish(Topics.MagicWitnessed, {
		position = landedAt,
		radius = stats.area,
		domains = stats.domains,
		power = stats.recipe.power,
		harmful = stats.harmful,
		casterUserId = player.UserId,
	})
	-- What the spell did, for quests (Quests/Objectives) and factions (FactionService).
	local branchPath: { string } = {}
	local node = Registry.branches[stats.recipe.branch]
	while node do
		table.insert(branchPath, node.id)
		node = if node.parent then Registry.branches[node.parent] else nil
	end
	local branchDef = Registry.branches[stats.recipe.branch]
	bus:publish(Topics.SpellResolved, {
		casterUserId = player.UserId,
		key = stats.key,
		route = p.route.id,
		point = landedAt,
		domains = stats.domains,
		branch = stats.recipe.branch,
		branchPath = branchPath,
		property = stats.recipe.property,
		verb = stats.recipe.verb,
		form = stats.recipe.form,
		power = stats.recipe.power,
		tags = InteractionMatrix.tagsFor(stats),
		effective = outcome.effective and not backfire,
		backfired = backfire,
		hits = outcome.hits,
		harmful = stats.harmful,
		forbidden = branchDef ~= nil and table.find(branchDef.tags or {}, "forbidden") ~= nil,
	})

	local gain = progression:awardPractice(
		player,
		stats,
		{ effective = outcome.effective, challenge = p.challenge and outcome.effective }
	)
	discovery:recordCast(player, stats, outcome.effective)
	local entry = p.state.data.spellbook[stats.key]
	if entry then
		entry.casts += 1
	end

	-- Watching someone stronger teaches (ProgressionService applies the tier gap and cooldowns).
	if outcome.effective then
		for _, other in Players:GetPlayers() do
			local root = if other ~= player then aliveParts(other.Character) else nil
			if root and (root.Position - landedAt).Magnitude <= T.observeRadius then
				progression:awardObservation(
					other,
					"player:" .. player.UserId,
					stats.recipe.branch,
					stats.masteryTier,
					stats.recipe.power
				)
			end
		end
	end

	-- "Survive being caught in your own fire": a breakthrough fact, once you've lived through it.
	local fact = T.selfHarmFacts[stats.domains[1]]
	if outcome.harmedSelf and fact then
		local character = player.Character
		task.delay(T.survivalDelay, function()
			local _, humanoid = aliveParts(character)
			if humanoid and player.Parent and player.Character == character then
				progression:recordFact(player, "survived", fact)
			end
		end)
	end

	local note = outcome.note
	if extraNote then
		note = if note then note .. " " .. extraNote else extraNote
	end
	Net.fire("CastResult", player, {
		ok = true,
		stage = "resolved",
		key = stats.key,
		cooldownUntil = p.cooldownUntil,
		effective = outcome.effective,
		hits = outcome.hits,
		damage = math.floor(totalDamage + 0.5),
		backfired = backfire,
		note = note,
		xp = if gain and gain.gained > 0
			then { branch = gain.branch, gained = math.floor(gain.gained * 10) / 10 }
			else nil,
	})
end

-- Where the spell goes now: a validated target that moved during the cast time is followed, and
-- self-centred forms land where the caster stands now (not where they started casting).
local function currentPoint(p: Pending, root: BasePart): Vector3
	if T.selfCentred[p.stats.recipe.form] then
		return root.Position
	end
	if p.target then
		local hit = Targeting.characterOf(p.target)
		local reach = p.stats.range * T.rangeTolerance + T.rangeSlack + C.retargetSlack
		if hit and (hit.root.Position - root.Position).Magnitude <= reach then
			return hit.root.Position
		end
	end
	return p.point
end

-- A held channel without a target follows the client's ChannelAim, turning at most
-- channelTurnDegreesPerSecond and never reaching past the spell's range.
local function channelPoint(p: Pending, root: BasePart): Vector3
	local channel = p.channel
	if not channel or not channel.aim or p.target or T.selfCentred[p.stats.recipe.form] then
		return currentPoint(p, root)
	end
	local muzzle = Aim.muzzle(root.Position)
	local want = (channel.aim :: Vector3) - muzzle
	local current = (channel.point or p.point) - muzzle
	if want.Magnitude < 0.5 or current.Magnitude < 0.5 then
		return channel.point or p.point
	end
	local angle = math.acos(math.clamp(current.Unit:Dot(want.Unit), -1, 1))
	local maxTurn = math.rad(Charge.data.channelTurnDegreesPerSecond) * T.channelInterval
	local direction = if angle <= maxTurn
		then want.Unit
		else CFrame.lookAt(Vector3.zero, current.Unit):Lerp(CFrame.lookAt(Vector3.zero, want.Unit), maxTurn / angle).LookVector
	local point = muzzle + direction * math.min(want.Magnitude, Aim.maxDistance(p.stats.range))
	channel.point = point
	return point
end

--[[
	One delivery + resolution: the cast itself, an echo or a channel pulse. Projectile forms fly
	first (Cast/Delivery; the "launch" cue lets clients draw the same flight), then the resolver
	runs where the flight ended, on whoever it struck. Every hit dealt on this thread is recorded.
]]
local function strike(
	p: Pending,
	ctx: CastTypes.EffectContext,
	params: { [string]: any },
	record: { Damage.RecordEntry }
): CastTypes.Outcome
	local player, stats = p.player, p.stats
	ctx.delivered = nil
	local wasBackfire = ctx.backfire -- a reflected bolt sets it for this strike only
	local extra: { [string]: any }? = nil
	if stats.recipe.form == "projectile" and not ctx.backfire and Delivery.capacity() then
		local flight = Delivery.plan(ctx)
		cue(player, stats, flight.origin, ctx.point, "launch", p.heavy, false, {
			projectileId = flight.id,
			velocity = flight.velocity,
			gravity = flight.gravity,
			hitRadius = flight.radius,
			homing = if flight.homing then flight.homing.Parent else nil,
			turnRate = flight.turnRate,
			lifetime = flight.lifetime,
		})
		-- A parry turns it back (Cast/Guard): the old bolt bursts on the ward, a new one returns.
		flight.onReflect = function(oldId: number, at: Vector3, velocity: Vector3)
			cue(player, stats, at, at, "resolve", false, false, { projectileId = oldId, expired = false })
			cue(player, stats, at, ctx.origin, "launch", p.heavy, false, {
				projectileId = flight.id,
				velocity = velocity,
				gravity = flight.gravity,
				hitRadius = flight.radius,
				homing = ctx.character,
				turnRate = flight.turnRate,
				lifetime = flight.lifetime,
			})
		end
		local impact = Delivery.fly(flight, { ctx.character })
		ctx.point = impact.point
		ctx.delivered = impact.hits
		ctx.onSurface = impact.surface
		ctx.target = if impact.hits[1] then impact.hits[1].model else nil
		-- Turned back and it found its caster: the spell lands on them, as a backfire does.
		if impact.reflectedBy then
			for _, h in impact.hits do
				if h.model == ctx.character then
					ctx.backfire = true
					ctx.point = h.root.Position
				end
			end
		end
		extra = { projectileId = flight.id, normal = impact.normal, expired = impact.expired }
	end
	cue(player, stats, ctx.origin, ctx.point, "resolve", p.heavy, ctx.backfire, extra)
	local recording = Damage.record()
	local outcome = p.resolver.resolve(ctx, params)
	Damage.stopRecord(recording)
	if ctx.backfire and not wasBackfire then
		outcome.harmedSelf = true -- your own parried bolt came home
	end
	ctx.backfire = wasBackfire
	table.move(recording, 1, #recording, #record + 1, record)
	if stats.recipe.form == "chain" and #recording > 1 and not ctx.backfire then
		-- Clients draw the arcs between everyone the chain struck, in hop order.
		local points: { Vector3 } = {}
		for _, entry in recording do
			if entry.position then
				table.insert(points, entry.position)
			end
		end
		cue(player, stats, ctx.origin, ctx.point, "chain", false, false, { points = points })
	end
	return outcome
end

local function resolve(p: Pending)
	local player, stats = p.player, p.stats
	task.wait(stats.castTime + stats.delay)

	local character = p.caster.castCharacter
	local root, humanoid = aliveParts(character)
	if not root or not humanoid or not character or player.Character ~= character or not player.Parent then
		if player.Parent then
			Net.fire("CastResult", player, {
				ok = true,
				stage = "resolved",
				key = stats.key,
				cooldownUntil = p.cooldownUntil,
				effective = false,
				hits = 0,
				backfired = false,
				interrupted = true,
			})
		end
		return
	end

	local backfireChance = if p.noBacklash then 0 else stats.backfireChance * StatusEffects.backfireMult(humanoid)
	local backfire = p.rng:NextNumber() < backfireChance
	local ctx: CastTypes.EffectContext = {
		player = player,
		character = character,
		root = root,
		stats = stats,
		context = p.context,
		power = stats.power,
		origin = root.Position,
		point = if backfire then root.Position else currentPoint(p, root),
		measuredAt = p.measuredAt,
		target = if backfire then character else p.target,
		onSurface = p.onSurface,
		backfire = backfire,
		pulse = 0,
		rng = p.rng,
		world = world,
		stored = p.caster.stored,
		runtime = runner,
		services = { reservoirs = reservoirs },
		speedMult = if p.charge then p.charge.speedMult else nil,
	}
	local params = p.route.params or {}
	local record: { Damage.RecordEntry } = {}
	local outcome = strike(p, ctx, params, record)

	-- Losing control of a strong spell is more than the spell landing on you.
	local riskNote: string? = nil
	if backfire and stats.recipe.power >= T.controlLossPower then
		local _, text = backlash:controlLoss(player, humanoid, stats)
		riskNote = text
		outcome.harmedSelf = true
	end

	if p.route.repeatable and not backfire then
		-- Echoes: weaker repeats of the same effect.
		for i = 1, stats.echoes do
			task.wait(T.echoInterval)
			local echoRoot = aliveParts(character)
			if not echoRoot then
				break
			end
			ctx.pulse, ctx.power, ctx.origin = i, stats.echoPower, echoRoot.Position
			ctx.point, ctx.target = currentPoint(p, echoRoot), p.target
			merge(outcome, strike(p, ctx, params, record))
		end
		-- Channeled: pulses while the caster lives and can pay the upkeep (no overdraw for upkeep).
		-- A client holding the button keeps it going (released early = ends); ChannelAim sweeps it.
		if stats.flags.channeled then
			local reservoir = reservoirs:get(player)
			local pulses = math.floor(stats.maxChannelTime / T.channelInterval)
			local channel = p.channel
			if channel and not channel.released then
				ActionState.set(character, "channeling", { domain = stats.domains[1] })
			end
			for i = 1, pulses do
				task.wait(T.channelInterval)
				local pulseRoot = aliveParts(character)
				if
					not pulseRoot
					or not reservoir
					or reservoir.current < stats.channelCostPerSecond * T.channelInterval
					or (channel and channel.released)
				then
					break
				end
				reservoir.current -= stats.channelCostPerSecond * T.channelInterval
				reservoirs:push(player)
				ctx.pulse, ctx.power, ctx.origin = stats.echoes + i, stats.power, pulseRoot.Position
				-- A channelled beam follows its target: each pulse is a damage tick on where it is now.
				ctx.point, ctx.target = channelPoint(p, pulseRoot), p.target
				merge(outcome, strike(p, ctx, params, record))
			end
			if channel then
				if channels[player] == channel then
					channels[player] = nil
				end
				ActionState.clear(character, "channeling")
			end
		end
	end

	aftermath(p, outcome, backfire, ctx.point, riskNote, record)
end

-- ─── The intent ─────────────────────────────────────────────────────────────

-- ─── Hold to charge (Casting.md §8) ─────────────────────────────────────────

-- Ends a charge's visible side (attributes, slowed walk). The action state is the caller's.
local function clearHoldBody(hold: Hold)
	local character = hold.character
	character:SetAttribute("ChargeStart", nil)
	character:SetAttribute("ChargeStep", nil)
	local humanoid = character:FindFirstChildOfClass("Humanoid")
	if humanoid then
		StatusEffects.setWalkMultiplier(humanoid, "charging", nil)
	end
end

local function cancelHold(player: Player, why: string)
	local hold = holds[player]
	if not hold then
		return
	end
	holds[player] = nil
	clearHoldBody(hold)
	if hold.character.Parent then
		ActionState.clear(hold.character, "charging") -- idle; an attuned body goes back to holding
	end
	log:debug("charge_cancelled", { userId = player.UserId, why = why })
end

-- The charge a release is cashing in (removed either way, so a refused cast also ends it).
local function takeHold(player: Player): Hold?
	local hold = holds[player]
	if hold then
		holds[player] = nil
		clearHoldBody(hold)
	end
	return hold
end

local function onHold(player: Player, kind: string)
	if kind == "cancel" then
		cancelHold(player, "client")
		return
	elseif kind == "release" then
		local channel = channels[player]
		if channel then
			channel.released = true
		end
		return
	end
	-- "begin": only an attuned spell in equip mode, only when it could be cast right now.
	if holds[player] or not attunement:equipMode(player) then
		return
	end
	local key = attunement:attunedKey(player)
	local recipe = attunement:attunedRecipe(player)
	local state = playerData:get(player)
	local character = player.Character
	local root, humanoid = aliveParts(character)
	if not key or not recipe or not state or not root or not humanoid or not character then
		return
	end
	if StatusEffects.blocksCasting(humanoid) then
		refuse(player, key, "SILENCED")
		return
	end
	local free, action = ActionState.can(character, "cast")
	if not free then
		refuse(player, key, if action == "staggered" then "STAGGERED" else "BUSY")
		return
	end
	local t = now()
	local caster = casterStateOf(player)
	local cheat: Cheats = cheats[player] or {}
	if t < caster.busyUntil or (t < caster.gcdUntil and not cheat.noCooldown) then
		refuse(player, key, "BUSY")
		return
	end
	-- No charging through a cooldown: the charge would be ready the instant the cooldown ends.
	local readyAt = caster.cooldowns[key]
	if readyAt and readyAt > t and not cheat.noCooldown then
		refuse(player, key, "ON_COOLDOWN", { cooldownUntil = readyAt })
		return
	end
	local shape = MagicCore.computeStats(recipe, state.caster, nil)
	if not shape or shape.flags.channeled or not Charge.chargeable(shape.castTime) then
		return -- channelled and slow spells cast on release without a charge
	end
	local maxHold = Charge.maxHold(shape.castTime)
	local hold: Hold = { key = key, startedAt = t, maxHold = maxHold, character = character }
	holds[player] = hold
	character:SetAttribute("ChargeStart", t)
	character:SetAttribute("ChargeStep", Charge.step(shape.castTime))
	StatusEffects.setWalkMultiplier(humanoid, "charging", Charge.data.walkMult)
	ActionState.set(character, "charging", { duration = maxHold + Charge.data.releaseGrace, domain = shape.domains[1] })
	-- Nobody released it: the charge fizzles (no cost, no cooldown).
	task.delay(maxHold + Charge.data.releaseGrace, function()
		if holds[player] == hold then
			cancelHold(player, "timeout")
		end
	end)
end

-- `fromClient`: the CastIntent remote (equip mode applies). Scrolls and admin casts pass nil.
local function onCastIntent(player: Player, raw: any, aim: Vector3, target: Model?, fromClient: boolean?)
	local hold = if fromClient then takeHold(player) else nil
	-- 1. Gates
	if flags.get("magic_casting_enabled") == false then
		return refuse(player, nil, "CASTING_DISABLED")
	end
	local state = playerData:get(player)
	local reservoir = reservoirs:get(player)
	if not state or not reservoir then
		return refuse(player, nil, "NOT_LOADED")
	end
	local character = player.Character
	local root, humanoid = aliveParts(character)
	if not root or not humanoid or not character then
		return refuse(player, nil, "DEAD")
	end
	if StatusEffects.blocksCasting(humanoid) then
		return refuse(player, nil, "SILENCED")
	end
	-- The body has to be free to cast (not knocked down, dashing, mid-slash: Cast/ActionState).
	local free, action = ActionState.can(character, "cast")
	if not free then
		return refuse(player, nil, if action == "casting" then "BUSY" elseif action == "staggered" then "STAGGERED" else "ACTION_LOCKED")
	end
	local t = now()
	local caster = casterStateOf(player)
	local cheat: Cheats = cheats[player] or {}
	if t < caster.busyUntil or (t < caster.gcdUntil and not cheat.noCooldown) then
		return refuse(player, nil, "BUSY")
	end
	-- Admin one-shots are consumed by this attempt, whether or not it succeeds.
	local overpower, unbound = cheat.overpowerOnce == true, cheat.unboundOnce == true
	cheat.overpowerOnce, cheat.unboundOnce = nil, nil
	-- Items: extra modifier slots and form reach from foci (Items/StatCache; docs/Items.md §5).
	state.caster.bonusModifierSlots = StatCache.modifierSlots(player)
	state.caster.bonusFormTier = StatCache.formTier(player)
	local casterProfile = if overpower then unboundCaster(state.caster) else state.caster

	-- 2. Validate with the real caster profile; from here on only the normalized recipe is used.
	local valid, errors, recipe = MagicCore.validateRecipe(raw, casterProfile)
	if not valid or not recipe then
		return refuse(player, nil, errors[1] and errors[1].code or "INVALID_RECIPE")
	end
	local key = MagicCore.recipeKey(recipe)
	-- Equip mode: a client may only cast the spell it has attuned (Services/AttunementService).
	if fromClient and not attunement:allowsCast(player, key) then
		return refuse(player, key, "NOT_ATTUNED")
	end
	-- Hold-to-charge applies to client casts in equip mode; a release without a "begin" is a tap.
	local charging = fromClient == true and attunement:equipMode(player)
	local held = if hold and hold.key == key then math.clamp(now() - hold.startedAt, 0, hold.maxHold) else 0

	-- 3. Cooldown
	local readyAt = caster.cooldowns[key]
	if readyAt and readyAt > t and not cheat.noCooldown then
		return refuse(player, key, "ON_COOLDOWN", { cooldownUntil = readyAt })
	end

	-- 4. Aim. Range and area don't depend on the place, so a context-free pass gives the shape.
	local shape = MagicCore.computeStats(recipe, casterProfile, nil)
	if not shape then
		return refuse(player, key, "INVALID_RECIPE")
	end
	local form = recipe.form
	local selfCentred = T.selfCentred[form] == true
	if not selfCentred and not unbound and not plausibleAim(aim) then
		return refuse(player, key, "BAD_AIM")
	end
	local point = if selfCentred then root.Position else aim
	-- Range from the muzzle (Shared/Magic/Aim), exactly what the client's reticle measures.
	if not selfCentred and not unbound and not Aim.withinRange(Aim.muzzle(root.Position), aim, shape.range) then
		return refuse(player, key, "OUT_OF_RANGE")
	end
	local targetModel: Model? = nil
	if target then
		local hit = Targeting.characterOf(target)
		if hit and hit.model ~= character and (hit.root.Position - aim).Magnitude <= shape.area + T.targetSlack then
			targetModel = hit.model
		end
	end
	local eye = Aim.eye(character) or root.Position
	local onSurface = selfCentred
	if not selfCentred then
		if not T.noLineOfSight[form] and not unbound then
			local ignore: { Instance } = { character }
			if targetModel then
				table.insert(ignore, targetModel)
			end
			if not Targeting.lineOfSight(eye, aim, ignore, T.losTolerance) then
				return refuse(player, key, "NO_LINE_OF_SIGHT")
			end
		end
		onSurface = landsOnSurface(eye, aim, character)
	end

	-- 5. Route
	local route = routeFor(recipe)
	local resolver = resolvers[route.effect]
	if not resolver then
		log:error("missing_resolver", { route = route.id, effect = route.effect })
		return refuse(player, key, "INVALID_RECIPE")
	end
	local params = route.params or {}

	-- 6. Measure the world where this spell needs it.
	local measuredAt, radius = point, math.max(shape.area, 16)
	if resolver.measure then
		local at, r = resolver.measure(world, point, shape.area)
		if not at then
			return refuse(player, key, "ENVIRONMENT_BLOCKED", { detail = route.id })
		end
		measuredAt, radius = at, r or radius
	end
	local context = world:castContext(measuredAt, radius)

	-- 7. Real stats
	local stats, statErrors = MagicCore.computeStats(recipe, casterProfile, context)
	if not stats then
		return refuse(player, key, statErrors[1] and statErrors[1].code or "INVALID_RECIPE")
	end
	if stats.blockedBy then
		return refuse(player, key, "ENVIRONMENT_BLOCKED", { detail = stats.blockedBy })
	end
	StatCache.applyToCast(player, stats)
	-- The charge stage (power, area, targets, overcharge risk, the time left to wait).
	local charged: Charge.Applied? = nil
	if charging and not stats.flags.channeled and Charge.chargeable(stats.castTime) then
		charged = Charge.apply(stats, Charge.stageIndex(held, stats.castTime), held)
	end
	-- Spellblade finisher: a Slash2 that just landed makes this cast stronger (Cast/Finisher).
	if fromClient then
		stats.power *= Finisher.consume(player)
	end

	-- 8. Requirements and budgets
	if (stats.requirement == "Target" or stats.requirement == "Source") and not (targetModel or onSurface) then
		return refuse(player, key, "NO_TARGET")
	end
	local charge = caster.stored[recipe.property]
	if stats.requirement == "Stored" and (not charge or charge.expires < t) then
		return refuse(player, key, "NOTHING_STORED")
	end
	if resolver.precheck then
		local reason = resolver.precheck(params, stats, player)
		if reason then
			return refuse(player, key, reason, { detail = route.id })
		end
	end
	local heavy = route.heavy == true and recipe.power >= T.budget.heavyPower
	if heavy and EffectBudget.available("heavy") <= 0 then
		return refuse(player, key, "WORLD_STRAINED", { detail = "heavy" })
	end
	local hpCost = stats.costBreakdown.vitalHp
	if hpCost > 0 and humanoid.Health <= hpCost + 1 then
		return refuse(player, key, "TOO_WEAK")
	end

	-- 9. Pay. The cast counter (saved) salts the seed, so every cast's rolls are reproducible.
	local counter = (state.data.stats.casts or 0) + 1
	local rng = Seed.random(worldService:getSeed(), "player:" .. player.UserId, "cast", counter)
	if cheat.infinite then
		reservoir.current = reservoir.max
	end
	if cheat.noBacklash then
		reservoir.burnoutUntil = 0
		table.clear(reservoir.lockouts)
	end
	local spend = Reservoir.trySpend(reservoir, stats, t, rng)
	if not spend.ok then
		return refuse(player, key, spend.reason or "INSUFFICIENT_RESERVOIR")
	end
	if cheat.noBacklash then
		-- trySpend already applied burnout/lockouts to the state: undo them with the consequences.
		spend.consequences = {}
		reservoir.burnoutUntil = 0
		table.clear(reservoir.lockouts)
	end
	if cheat.infinite then
		reservoir.current, reservoir.strain = reservoir.max, 0
	end
	StatCache.applyToConsequences(player, spend.consequences, reservoir, t)
	state.data.stats.casts = counter
	if stats.requirement == "Stored" then
		caster.stored[recipe.property] = nil
	end
	if hpCost > 0 then
		humanoid:TakeDamage(hpCost)
	end
	local riskNote = if #spend.consequences > 0
		then backlash:overdraw(player, humanoid, stats, spend.consequences)
		else nil
	reservoirs:push(player)

	-- 10. Commit
	local cooldownUntil = if cheat.noCooldown
		then t + stats.castTime
		else t + stats.castTime + stats.delay + stats.cooldown
	caster.cooldowns[key] = cooldownUntil
	caster.busyUntil = t + stats.castTime
	caster.gcdUntil = if cheat.noCooldown then t else t + T.globalCooldown
	caster.castCharacter = character
	-- The cast animation follows this state; instant casts still get a short gesture.
	ActionState.set(character, "casting", {
		duration = math.max(stats.castTime + stats.delay, T.minCastAnimation),
		domain = stats.domains[1],
	})
	local danger = reservoir.current < 0
		or humanoid.Health <= humanoid.MaxHealth * T.challengeHealth
		or #events:activeAt(point.X, point.Z) > 0
	-- Settlement law is judged in aftermath(), once we know whether the spell hurt anyone.

	Net.fire("CastResult", player, {
		ok = true,
		stage = "accepted",
		key = key,
		cost = stats.costBreakdown.reservoir,
		hpCost = hpCost,
		castTime = stats.castTime,
		cooldownUntil = cooldownUntil,
		consequences = spend.consequences,
		riskNote = riskNote,
		charge = if charged then charged.stage.id else nil,
	})
	cue(player, stats, root.Position, point, "begin", heavy)
	log:debug("cast_accepted", { userId = player.UserId, key = key, route = route.id, power = recipe.power })
	bus:publish(Topics.SpellCast, {
		casterUserId = player.UserId,
		key = key,
		route = route.id,
		domain = stats.domains[1],
		power = recipe.power,
		point = point,
	})

	-- 11-12. Resolve after the cast time, off this thread.
	if heavy then
		EffectBudget.acquire("heavy")
	end
	local pending: Pending = {
		player = player,
		state = state,
		caster = caster,
		stats = stats,
		context = context,
		route = route,
		resolver = resolver,
		rng = rng,
		point = point,
		measuredAt = measuredAt,
		target = targetModel,
		onSurface = onSurface,
		challenge = danger,
		heavy = heavy,
		cooldownUntil = cooldownUntil,
		noBacklash = cheat.noBacklash,
		charge = charged,
		channel = nil,
	}
	if fromClient and stats.flags.channeled then
		local channel: Channel = { released = false, aim = point }
		channels[player] = channel
		pending.channel = channel
	end
	if charged then
		log:debug("cast_charged", { userId = player.UserId, key = key, stage = charged.stage.id, held = held })
	end
	task.spawn(function()
		local ok, err = xpcall(resolve, debug.traceback, pending)
		if heavy then
			EffectBudget.release("heavy")
		end
		if not ok then
			log:error("cast_resolve_failed", { userId = player.UserId, key = key, route = route.id, err = err })
		end
	end)
end

-- ─── Signatures (VFX identity) ──────────────────────────────────────────────

-- Every client styles a caster's spells from this attribute (colours, particle, motion, timbre).
-- The signature is how magic LOOKS, not a secret: the visible profile already includes it.
local function publishSignature(player: Player)
	local state = playerData:get(player)
	local signature = state and state.innate and state.innate.signature
	if signature then
		player:SetAttribute("MagicSignature", HttpService:JSONEncode(signature))
	end
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "castinfo",
		category = "Spells",
		description = "Reservoir, cooldowns, stored charges, statuses and active cheats",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(ctx, a)
			local player: Player = a.player
			local reservoir = reservoirs:get(player)
			local caster = casterStateOf(player)
			local t = now()
			local c = cheats[player] or {}
			local on = {}
			for k, v in c do
				if v then
					table.insert(on, k)
				end
			end
			table.sort(on)
			local lines = {
				if reservoir
					then string.format(
						"reservoir %.0f / %.0f, strain %.0f, burnout %.0fs, risk x%.2f",
						reservoir.current,
						reservoir.max,
						reservoir.strain,
						math.max(0, reservoir.burnoutUntil - t),
						reservoir.riskMult
					)
					else "reservoir: not loaded",
				string.format(
					"busy %.1fs, heavy effects active %d",
					math.max(0, caster.busyUntil - t),
					EffectBudget.counts().heavy
				),
				"cheats: " .. (if #on > 0 then table.concat(on, ", ") else "none"),
			}
			for k, untilTime in caster.cooldowns do
				if untilTime > t then
					table.insert(lines, string.format("cooldown %.1fs  %s", untilTime - t, k))
				end
			end
			for property, charge in caster.stored do
				if charge.expires > t then
					table.insert(
						lines,
						string.format(
							"stored %s (power %.1f, %ds left)",
							property,
							charge.power,
							math.floor(charge.expires - t)
						)
					)
				end
			end
			local _, humanoid = aliveParts(player.Character)
			if humanoid then
				local statuses = StatusEffects.list(humanoid)
				table.insert(lines, "statuses: " .. (if #statuses > 0 then table.concat(statuses, ", ") else "none"))
			end
			return table.concat(lines, "\n")
		end,
	})

	admin:Register({
		name = "refill",
		category = "Spells",
		description = "Full reservoir; clears strain, burnout, lockouts, cooldowns and statuses",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local player: Player = a.player
			local reservoir = reservoirs:get(player)
			if not reservoir then
				return "not loaded"
			end
			reservoir.current, reservoir.strain, reservoir.burnoutUntil = reservoir.max, 0, 0
			table.clear(reservoir.lockouts)
			local caster = casterStateOf(player)
			table.clear(caster.cooldowns)
			caster.busyUntil, caster.gcdUntil = 0, 0
			local _, humanoid = aliveParts(player.Character)
			if humanoid then
				StatusEffects.dispel(humanoid)
			end
			reservoirs:push(player)
			return "refilled " .. player.Name
		end,
	})

	admin:Register({
		name = "route",
		category = "Spells",
		description = "Which effect a recipe produces",
		args = {
			{ name = "branch", type = "branch" },
			{ name = "property", type = "property" },
			{ name = "verb", type = "verb" },
			{ name = "form", type = "form" },
			{ name = "power", type = "integer", min = 1, max = 10, default = 3, slider = true },
		},
		handler = function(_, a)
			local _, errors, recipe = MagicCore.validateRecipe({
				branch = a.branch,
				property = a.property,
				verb = a.verb,
				form = a.form,
				power = a.power,
			})
			if not recipe then
				return "invalid: " .. (errors[1] and errors[1].message or "?")
			end
			local r = routeFor(recipe)
			return string.format(
				"%s -> route %s (effect %s)%s",
				MagicCore.describe(recipe),
				r.id,
				r.effect,
				if r.heavy then ", heavy at P" .. T.budget.heavyPower .. "+" else ""
			)
		end,
	})
end

-- ─── Admin API (Server/Admin/Commands/Magic) ────────────────────────────────

-- The player's cheat switches (created on first use).
function CastService.cheats(_self: any, player: Player): Cheats
	local c = cheats[player]
	if not c then
		c = {}
		cheats[player] = c
	end
	return c
end

--[[
	Casts any recipe for a player, through the real pipeline, ignoring knowledge, tier, power caps,
	aim, range and line of sight for this one cast (payment, budgets and effects are real; turn
	on infinite/noBacklash for those). Returns nil when accepted, else the refusal reason.
]]
function CastService.castAs(self: any, player: Player, recipe: any, aim: Vector3, target: Model?): string?
	local c = self:cheats(player)
	c.overpowerOnce, c.unboundOnce = true, true
	return onCastIntent(player, recipe, aim, target)
end

--[[
	Casts a recipe stored in an item (spell scrolls; imbued foci later). Knowledge, tier and power
	caps are waived (that's what the scroll is for) but everything else is real: aim, range, line
	of sight, cooldowns, payment, budgets. Returns nil when accepted, else the refusal reason.
]]
function CastService.castFromItem(self: any, player: Player, recipe: any, aim: Vector3, target: Model?): string?
	local c = self:cheats(player)
	c.overpowerOnce = true
	return onCastIntent(player, recipe, aim, target)
end

-- Stats for a recipe as this player would cast it here, without casting. Returns (stats?, error?).
function CastService.preview(
	_self: any,
	player: Player,
	recipe: any,
	at: Vector3?,
	unboundRules: boolean?
): (Types.SpellStats?, string?)
	local state = playerData:get(player)
	if not state then
		return nil, "not loaded"
	end
	local profile = if unboundRules then unboundCaster(state.caster) else state.caster
	local context = if at then world:castContext(at, 16) else nil
	local stats, errors = MagicCore.computeStats(recipe, profile, context)
	if stats then
		StatCache.applyToCast(player, stats)
	end
	if not stats then
		return nil, if errors[1] then errors[1].code .. ": " .. errors[1].message else "invalid"
	end
	return stats, nil
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function CastService.init(_self: any, ctx: any)
	log, flags, bus = ctx.log, ctx.flags, ctx.bus
	playerData = ctx.get("PlayerDataService")
	reservoirs = ctx.get("ReservoirService")
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	progression = ctx.get("ProgressionService")
	discovery = ctx.get("DiscoveryLog")
	events = ctx.get("EventDirector")
	runner = ctx.get("EffectRunner")
	backlash = ctx.get("BacklashService")
	attunement = ctx.get("AttunementService")

	-- Every route's effect must exist: a typo in EffectLibrary fails the boot, not a player's cast.
	local effects = MagicFolder.Cast.Effects
	for _, route in EffectLibrary.routes do
		if not resolvers[route.effect] then
			local module = effects:FindFirstChild(route.effect)
			assert(
				module and module:IsA("ModuleScript"),
				"EffectLibrary route " .. route.id .. ": no resolver Cast/Effects/" .. route.effect
			)
			resolvers[route.effect] = (require :: any)(module)
		end
	end

	Net.on("CastIntent", function(player: Player, raw: any, aim: Vector3, target: Model?)
		local refused = onCastIntent(player, raw, aim, target, true)
		-- A refused release leaves no charging pose behind.
		local character = player.Character
		if refused and character and ActionState.get(character) == "charging" then
			ActionState.clear(character, "charging")
		end
	end)
	Net.on("CastHold", onHold :: any)
	Net.on("ChannelAim", function(player: Player, aim: Vector3)
		local channel = channels[player]
		if channel then
			channel.aim = aim -- channelPoint caps the turn rate and the range
		end
	end)
	-- A knockdown, a dash or raising a guard breaks a charge.
	ActionState.changed:Connect(function(model: Model, state: string)
		if state ~= "staggered" and state ~= "dashing" and state ~= "blocking" then
			return
		end
		local player = Players:GetPlayerFromCharacter(model)
		if player and holds[player] then
			cancelHold(player, state)
		end
	end)
	registerAdmin(ctx.get("AdminService"))
	bus:subscribe(Topics.PlayerDataLoaded, function(payload: any)
		publishSignature(payload.player)
	end)
end

function CastService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		casters[player] = nil
		cheats[player] = nil
		holds[player] = nil
		channels[player] = nil
	end)
	for _, player in Players:GetPlayers() do
		publishSignature(player)
	end
end

return CastService
