--!strict
--[[
	CastTuning: every number the cast pipeline and the effect runtime use that isn't part of the
	spell grammar itself. Server-only. Which spell does what lives in Data/EffectLibrary.

	Effect strengths scale from stats.power, which is ~1 at P1 and ~250-500 at P10.
]]

local AimTuning = require(game:GetService("ReplicatedStorage").Shared.Magic.Aim).tuning

local CastTuning = {
	-- ─── Validation tolerances ──────────────────────────────────────────────
	-- Range, sight and self-centred forms are shared with the client's reticle (Shared/Magic/Aim).
	rangeTolerance = AimTuning.rangeTolerance,
	rangeSlack = AimTuning.rangeSlack,
	losTolerance = AimTuning.losTolerance,
	targetSlack = 12, -- an explicit target must be within area + this of the aim point
	maxAimBelowGround = 40, -- aim points deeper than this under the surface are implausible
	noLineOfSight = AimTuning.noLineOfSight,
	selfCentred = AimTuning.selfCentred,

	-- ─── Timing ─────────────────────────────────────────────────────────────
	globalCooldown = 0.35, -- seconds between any two casts
	minCastAnimation = 0.35, -- shortest "casting" action state (instant casts still gesture)
	-- Attunement (equip mode, Services/AttunementService)
	attuneSwapCooldown = 0.25, -- seconds between two attune/stow requests
	attunedWalkMult = 0.85, -- walk speed while a spell is attuned
	echoInterval = 0.6,
	channelInterval = 1, -- seconds between channel pulses

	-- ─── Per-server budgets (30-60 players, 100-300 NPCs); see Cast/EffectBudget ──
	budget = {
		heavyPower = 8, -- recipes at or above this power are "heavy" when their route says so
		maxHeavyActive = 2, -- concurrent heavy effects per server
		maxActiveEffects = 60, -- durational effects (fields, fires, currents) per server
		maxActivePerPlayer = 4,
		maxFields = 4, -- time/gravity/current/reality zones per server
		maxMythicFields = 2, -- of which Time/Gravity/Reality
		partsPerSecond = 600, -- parts any effect may touch per second, server-wide (token bucket)
		partsBurst = 900,
		terrainOpsPerSecond = 80, -- terrain writes per second, server-wide
		terrainOpsBurst = 160,
		maxLights = 40,
		maxBurningParts = 60,
		maxGroundFires = 120,
		maxConstructsPerPlayer = 3, -- live walls/pillars/lights per player (oldest is removed)
	},

	-- ─── Cue LOD: who hears about an effect, and in how much detail ─────────
	lod = {
		near = 150, -- full detail
		mid = 400, -- reduced (fewer particles, no secondary emitters)
		far = 1200, -- heavy effects only (a distant quake still shakes the horizon)
	},

	-- ─── Effect strength ────────────────────────────────────────────────────
	-- Damage lives in CombatTuning (one curve for spells, reactions and backlash).
	damage = require(script.Parent.CombatTuning).damage,
	heal = { perPower = 8, exponent = 0.6 }, -- P1 ≈ 8, P5 ≈ 35, P10 ≈ 220 (mirrors the damage curve)
	force = { perPower = 30, exponent = 0.45, maxSpeed = 220, harmShare = 0.3 },
	structureDamage = { minPower = 4, perPower = 0.5 },
	light = { rangePerPower = 6, maxRange = 60, minLifetime = 6, maxLifetime = 120 },
	construct = { minLifetime = 3, maxLifetime = 60, thickness = 2, heightBase = 6, heightPerPower = 1.5 },
	status = { durationPerLevel = 1.2, minDuration = 3, maxDuration = 30, dotShare = 0.25, wardPerPower = 6 },
	storedChargeSeconds = 300,

	thermal = {
		ambient = 20, -- °C
		heatPerPower = 40, -- energy units per stats.power (a P3 heat spell ≈ 400)
		transferShare = 0.6, -- share of the drawn heat that arrives (the rest is lost)
		conductRadius = 6, -- studs between parts that exchange heat
		conduction = 0.08, -- share of the temperature difference exchanged per second
		cooling = 0.02, -- share of (T - ambient) lost per second
		maxActive = 150, -- thermally active parts simulated per tick
		scaldAt = 70, -- characters touching parts hotter than this take burn damage
	},
	fire = {
		tick = 0.5,
		spreadChance = 0.35, -- per burning cell per tick, scaled by flammability and wind
		groundCell = 8, -- studs between ground fire cells
		groundLifetime = 12,
		partBurnPerSecond = 0.08, -- share of a part's fuel burned per second
		burnStatusSeconds = 4,
		windInfluence = 0.6, -- how strongly spread prefers downwind
	},
	field = {
		tick = 0.1,
		maxAssemblies = 40, -- per field per tick
		timeSlow = 0.35, -- time factor in a slow field
		timeHaste = 1.5,
		gravityHeavy = 2.2, -- multiples of normal gravity
		gravityLight = 0.25,
		gravityInvert = -0.8, -- capped: inverted pull is weaker than normal gravity
		maxFieldSeconds = 30,
		maxFieldRadius = 60,
		currentSpeed = 28,
		realityMaxParts = 40,
	},
	wave = {
		columnWidth = 16, -- studs per simulated column across the front
		step = 16, -- studs advanced per simulation step
		speed = 70, -- studs per second
		shoalingExponent = 0.25, -- Green's law: H ∝ depth^-1/4
		minDepth = 2,
		runupFriction = 0.035, -- crest lost per stud travelled inland
		slopeLoss = 0.9, -- crest lost per stud of ground above sea level
		smoothing = 0.25, -- lateral diffusion between neighbouring columns per step
	},

	-- ─── Backfire, backlash and danger ──────────────────────────────────────
	backfireSelfShare = 0.6, -- share of the spell's own damage a backfire deals to the caster
	controlLossPower = 6, -- backfires at or above this power also trigger a backlash event
	challengeHealth = 0.35, -- casting at or below this health share counts as "under real danger"
	survivalDelay = 5, -- seconds a caster must live after harming themselves to record the survival
	-- Self-harm facts for breakthroughs (Progression/Breakthroughs "survive" ids), by domain.
	selfHarmFacts = {
		energy = "energy:self_burn",
		water = "water:drowning",
	} :: { [string]: string },

	-- ─── Presences and interactions (Cast/InteractionMatrix) ────────────────
	presenceSeconds = 4, -- how long an instant spell's elemental trace lingers for reactions
	reactionCooldown = 2, -- seconds before the same pair can react again in the same place

	-- ─── Observation XP ─────────────────────────────────────────────────────
	observeRadius = 60,
}

return CastTuning
