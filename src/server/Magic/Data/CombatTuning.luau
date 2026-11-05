--!strict
--[[
	CombatTuning: every number the damage formula (Cast/DamageModel), form delivery (Cast/Delivery,
	Cast/Targeting) and hit feedback (EffectRunner) use. Server-only. docs/Combat.md explains the
	formula and why each number is what it is.

	stats.power is already the caster's whole strength: magnitude (1.85^(P-1)) x verb/form fit x
	affinity (0.75..1.25) x mastery (+30% at 100) x temperament traits x domain resonance of the
	place x specialization / signature / environment. Nothing here re-applies those.
]]

local AimTuning = require(game:GetService("ReplicatedStorage").Shared.Magic.Aim).tuning

local CombatTuning = {
	-- ─── Damage formula (Cast/DamageModel) ──────────────────────────────────
	damage = {
		-- base(power) = perPower * power ^ exponent
		-- P1 ≈ 9, P3 ≈ 19, P5 ≈ 39, P8 ≈ 105, P10 ≈ 250 against 100 HP (typical caster)
		perPower = 9,
		exponent = 0.6,
		minDamage = 1, -- a hit that lands always does at least this (after resistance)
		maxHit = 400, -- hard cap per hit, whatever the power
		pvpMaxShare = 0.6, -- one hit takes at most this share of a PLAYER's MaxHealth
		-- Variance: x(1 ± spread). Overreach (casting above your comfort power) widens it.
		variance = 0.08,
		variancePerOverreach = 0.06,
		-- Crits: chance = critBase + critPerTier * masteryTier (+ reckless), capped.
		critBase = 0.04,
		critPerTier = 0.015,
		critReckless = 0.08,
		critMax = 0.25,
		critMult = 1.6,
		-- Area falloff: centre takes 100%, the rim areaFalloffMin, along distance ^ curve.
		areaFalloffMin = 0.45,
		areaFalloffCurve = 1.5,
		-- Resistance: Humanoid attributes "Resist_<domain>" / "Resist_<property>" (0.3 = 30% less,
		-- -0.25 = 25% more). The sum is clamped to these bounds.
		maxResist = 0.8,
		maxVulnerability = 0.5,
		chainFalloff = 0.8, -- each chain hop deals this share of the previous one
	},

	-- ─── Delivery by form ───────────────────────────────────────────────────
	projectile = {
		-- Flight numbers are shared with the client's reticle arc (Shared/Magic/Aim).
		speedBase = AimTuning.projectile.speedBase,
		speedPerPower = AimTuning.projectile.speedPerPower,
		maxSpeed = AimTuning.projectile.maxSpeed,
		radiusBase = AimTuning.projectile.radiusBase,
		radiusPerPower = AimTuning.projectile.radiusPerPower,
		splash = 2.5, -- an impact on the ground this close to a character still hits it
		rangeMult = AimTuning.projectile.rangeMult,
		maxLifetime = 4, -- seconds
		homingTurn = math.rad(160), -- max steering per second with the Homing modifier
		maxActive = 160, -- server-wide flights; past this, a cast resolves along a line instantly
		-- Downward pull (studs/s²) by domain: earth is lobbed, water arcs a little.
		gravityByDomain = AimTuning.projectile.gravityByDomain,
		bounces = 0, -- ricochets off solid surfaces before impact (0 = explode on first contact)
	},
	beam = {
		radius = AimTuning.beam.radius, -- thickness of the beam's hit sweep (shared: Aim)
		radiusPerPower = AimTuning.beam.radiusPerPower,
		rangeMult = 1.0, -- beams reach the aim point plus a little; walls stop them
	},
	touch = {
		coneDegrees = AimTuning.touch.coneDegrees, -- half-angle in front of the caster (shared: Aim)
		reachSlack = AimTuning.touch.reachSlack,
	},
	chain = {
		jumpBase = AimTuning.chain.jumpBase, -- studs a chain can leap (shared: Aim)
		jumpPerPower = AimTuning.chain.jumpPerPower,
		needsSight = true, -- a hop must see its next target
	},
	area = {
		occlusion = true, -- walls between the centre and a target shield it
		lift = 1.5, -- studs the occlusion ray starts above the impact point (ground aims)
	},
	retargetSlack = 10, -- a moving explicit target is followed if still within range + this

	-- ─── Hit feedback (EffectRunner) ────────────────────────────────────────
	feedback = {
		dotFlush = 0.75, -- seconds damage-over-time is summed before one number is shown
		heavyShare = 0.25, -- a hit worth this share of the target's MaxHealth is "heavy" (hit-stop)
	},

	-- ─── Hit reactions (Cast/HitReactions), players and NPCs alike ──────────
	reactions = {
		flinchShare = 0.04, -- a hit this big makes an NPC recoil (players get the camera cues)
		flinchSeconds = 0.3,
		flinchDegrees = 18, -- max torso recoil at a heavy hit
		knockdownShare = 0.3, -- one hit of this share of MaxHealth knocks anyone down
		-- Kinetic magic knocks down at a lower share once it's strong enough.
		knockdownKinds = { momentum = true, seismicity = true, weight = true, pressure = true, crush = true, landslide = true, wave = true } :: { [string]: boolean },
		kineticShare = 0.12,
		kineticMinPower = 4, -- recipe power (DamageModel passes it in Damage info)
		knockdownSeconds = 1.6,
		knockdownImmunity = 4, -- seconds after getting up before the next knockdown (no stun-lock)
		knockdownLaunch = 18, -- studs/s of push away from the hit (NPCs; players via their client)
	},

	-- ─── NPC aggro and retaliation (NPC/NPCCombat) ──────────────────────────
	aggro = {
		threatPerDamage = 1, -- threat added per point of damage taken
		witnessThreat = 8, -- threat a nearby guard / loyal friend adds when someone is attacked
		witnessRadius = 40,
		decayPerSecond = 2, -- threat lost per second
		forgetBelow = 1,
		maxEngageSeconds = 45, -- gives up a fight (or stops fleeing) after this long without a new hit
		-- Fight or flee: courage = Σ trait weights (centred at 0.5) + magic + health; >= fightAt fights.
		courage = { neuroticism = -0.9, pride = 0.5, loyalty = 0.3, ambition = 0.2, agreeableness = -0.2 } :: { [string]: number },
		courageMagicPerTier = 0.08, -- per mastery tier of their best branch
		courageHealthWeight = 0.5, -- x (health share - 0.5)
		fightAt = 0.15,
		guardBonus = 0.6, -- guards and hunters lean toward fighting
		alwaysFlee = { child = true, retired = true } :: { [string]: boolean },
		fleeDistance = 45, -- studs away from the attacker
		-- Retaliation casts: a real bolt through Cast/Delivery + DamageModel.
		castRange = 45,
		keepDistance = 18, -- fighters close to this range, then cast
		castInterval = 2.2, -- seconds between bolts (x 0.8..1.2 per NPC)
		-- Telegraphed charge before each bolt (Shared/Magic/Charge stages; NPCs never overcharge).
		chargeTapShare = 0.1, -- quick taps (0.75x power, barely any wind-up)
		chargeFullBase = 0.2, -- full charges (1.25x, two steps of wind-up) ...
		chargeFullPerTier = 0.06, -- ... more often per mastery tier; the rest are plain charges
		-- Guarding (Cast/Guard): when the target starts a cast, maybe raise a guard after a delay.
		guardBase = 0.15, -- chance per enemy cast
		guardPerTier = 0.07, -- + per magic tier
		guardTrait = 0.3, -- + this x (conscientiousness - 0.5) x 1
		guardMax = 0.8,
		guardReactBase = 0.35, -- seconds from seeing the cast to the guard going up ...
		guardReactPerTier = 0.04, -- ... minus this per tier (masters can land parries) ...
		guardReactMin = 0.06, -- ... but never faster than this
		guardHold = 0.9, -- seconds the guard stays up
		maxPower = 5, -- NPC bolts never exceed this recipe power
		-- Properties an NPC tries for its bolt, by domain of its best branch (first valid wins).
		attackProperties = {
			energy = { "combustion", "charge", "luminosity" },
			earth = { "momentum", "cohesion" },
			water = { "pressure", "temperature", "flow" },
			air = { "pressure", "momentum" },
			life = { "toxin", "decay" },
			spirit = { "essence", "malediction", "soul" },
			mind = { "sound" },
			void = { "essence" },
			space = { "orientation" },
			time = { "age" },
			gravity = { "weight" },
			reality = { "substance" },
		} :: { [string]: { string } },
		fallbackProperties = { "momentum", "temperature" },
	},

	-- ─── Lightning conduction (Cast/Conduction) ─────────────────────────────
	conduction = {
		properties = { charge = true } :: { [string]: boolean }, -- what conducts
		metalMaterials = { "Metal", "DiamondPlate", "CorrodedMetal", "Foil" },
		metalLinkGap = 1.5, -- studs between metal parts that still carry current
		maxMetalParts = 40, -- flood-fill budget per strike
		metalReach = 3.5, -- characters within this of a charged metal part are shocked
		waterRadiusBase = 10, -- studs of water charged around the strike (x power growth)
		waterRadiusPerPower = 2.5,
		waterProbe = 3, -- studs below the strike checked for water
		share = 0.6, -- of the bolt's base damage, to everyone it reaches
		falloffPerHop = 0.85, -- metal: per part between the strike and the victim
		waterFalloffMin = 0.4, -- water: at the edge of the charged area
	},

	-- ─── Crushing fields (Effects/Field + FieldEffects) ──────────────────────
	-- A heavy gravity field cast with a harmful verb crushes everyone inside but its caster.
	crush = {
		share = 0.15, -- of a full hit (DamageModel), per interval, at the centre
		interval = 1, -- seconds between crushes
		verbs = { generate = true, amplify = true } :: { [string]: boolean },
	},

	-- ─── Explosions (Cast/Explosion) ────────────────────────────────────────
	explosion = {
		minPower = 3, -- recipe power for an area harm to blast loose parts
		categories = { Thermal = true, Kinetic = true, Energetic = true } :: { [string]: boolean },
		forms = { burst = true, zone = true, pillar = true, ritual = true, projectile = true } :: { [string]: boolean },
		radiusMult = 1.3, -- of the spell's area (projectiles: of their impact radius)
		projectileRadius = 4, -- base blast radius of an exploding projectile (+0.6 per power)
		impulse = 70, -- studs/s at the centre (falls off to 0 at the edge), capped below
		maxSpeed = 160,
		maxParts = 60, -- per blast (also charged to EffectBudget.takeParts)
		breakTags = { "Decor", "Breakable", "Rubble" }, -- anchored parts of these models can be blasted loose
		breakPower = 5, -- recipe power needed to rip ANCHORED tagged parts loose
		maxPartSize = 12, -- parts larger than this (any axis) never move
		debrisSeconds = 20, -- blasted-loose parts are cleaned up after this
	},

	-- ─── Resistances (Cast/Resistances) ─────────────────────────────────────
	resistances = {
		-- NPC innate: affinity above `from` in a domain resists it, up to `max`.
		affinityFrom = 0.35,
		affinityScale = 0.45,
		affinityMax = 0.3,
		-- NPC traits (centred: (trait - 0.5) x weight) -> resistance keys.
		traits = {
			neuroticism = { mind = -0.5 }, -- anxious minds are easier to frighten and charm
			patience = { mind = 0.3, time = 0.2 },
			conscientiousness = { malediction = 0.2 },
			pride = { emotion = 0.3 },
			compassion = { essence = -0.2 },
		} :: { [string]: { [string]: number } },
		-- Wards: every ward also resists all magic by this (scaled by the ward's recipe power).
		wardBase = 0.06,
		wardPerPower = 0.025,
		wardMax = 0.35,
	},
}

return CombatTuning
