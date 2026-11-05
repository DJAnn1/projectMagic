--!strict
--[[
	Tuning
	Every constant in the power/cost/instability model lives here so balance passes never
	touch logic. See docs/MagicSystem.md §5 for the formulas these feed.
]]
local Types = require(script.Parent.Parent.Types)

local CostProfiles: { [string]: Types.CostProfileDef } = {
	reservoir = {
		name = "Reservoir",
		description = "Paid entirely from the caster's internal reservoir.",
		ambientSharePerDensity = 0,
		ambientShareMax = 0,
		minDensity = 0,
		vitalShare = 0,
		hpPerMana = 0,
		powerMult = 1,
		instabilityMult = 1,
		castTimeMult = 1,
	},
	ambient = {
		name = "Ambient Draw",
		description = "Pulls part of the cost from the surrounding ambient density. Slow and a little wild; useless in dead zones.",
		ambientSharePerDensity = 0.2, -- density 3 (nexus) covers 60%
		ambientShareMax = 0.6,
		minDensity = 0.25,
		vitalShare = 0,
		hpPerMana = 0,
		powerMult = 1,
		instabilityMult = 1.15,
		castTimeMult = 1.5,
	},
	vital = {
		name = "Vital Price",
		description = "Burns the caster's own life to pay part of the cost. Faster, stronger, far less stable.",
		ambientSharePerDensity = 0,
		ambientShareMax = 0,
		minDensity = 0,
		vitalShare = 0.3,
		hpPerMana = 0.5,
		powerMult = 1.15,
		instabilityMult = 1.25,
		castTimeMult = 0.9,
	},
}

local Tuning = {
	-- Schema / anti-exploit limits
	RECIPE_VERSION = 1,
	MIN_POWER = 1,
	MAX_POWER = 10,
	MAX_MODIFIERS = 4, -- absolute cap regardless of mastery
	MAX_ID_LENGTH = 48,
	DEFAULT_COST_PROFILE = "reservoir",

	-- Magnitude & cost curves. Cost grows slightly faster than magnitude, so big spells are
	-- disproportionately expensive and can't be spammed.
	magnitudeGrowth = 1.85, -- P10 ≈ 254x a P1 effect
	costBase = 4,
	costGrowth = 1.95, -- P10 base cost ≈ 1633
	awkwardCostExponent = 0.5, -- cost *= (1 / (verbEff * formEff)) ^ this

	-- Shape scaling per power level above 1
	areaExponent = 0.4, -- area radius *= magnitude ^ 0.4  (P10 ≈ 9.2x)
	rangePerLevel = 0.12,
	durationPerLevel = 0.08,
	castTimePerLevel = 0.06,
	cooldownPerLevel = 0.15,
	minCooldown = 0.25,
	minCastTime = 0.1,
	maxAreaTargets = 24, -- server perf cap on area spells

	-- Branch tiers
	tierMaxPower = { [0] = 3, [1] = 5, [2] = 7, [3] = 9, [4] = 10 } :: { [number]: number },
	unlockMastery = { [1] = 15, [2] = 30, [3] = 50, [4] = 70 } :: { [number]: number }, -- parent mastery needed
	hybridTier = 2,

	-- Mastery (0..100 on the branch being cast from)
	mastery = {
		powerBonus = 0.3, -- +30% power at 100
		costDiscount = 0.45, -- -45% cost at 100
		costCurve = 0.8,
		castTimeReduction = 0.35,
		rangeBonus = 0.4,
		instabilityReduction = 0.5,
		comfortCurve = 0.75, -- comfortPower = 1 + 9 * (m/100)^0.75
	},

	-- Affinity (0..1 per domain; hybrids use the geometric mean)
	affinity = {
		powerMin = 0.75,
		powerSpan = 0.5, -- 0.75x .. 1.25x
		costMax = 1.3,
		costSpan = 0.5, -- 1.3x .. 0.8x
		branchBlend = 0.3, -- how far an innate branch leaning pulls effective affinity
	},

	-- Casters without an innate profile (tests, summons) use these.
	neutralTraits = {
		power = 1,
		cost = 1,
		instability = 1,
		castTime = 1,
		capacity = 1,
		regen = 1,
		overdrawRisk = 1,
		ambientShareBonus = 0,
		vitalCost = 1,
		detectability = 1,
		allyPower = 0,
	} :: Types.CasterTraits,
	maxAmbientShare = 0.9,

	-- A creator's own signature spell (see docs/Progression.md §5).
	signature = { power = 1.1, cost = 0.9 },

	-- Environmental surplus: rich conditions help a little (EnvironmentRules handles shortfalls).
	environment = { maxBonus = 1.15, surplusBonus = 0.05 },

	-- Place resonance: power *= clamp(bias ^ powerExponent, min, max). Bias comes from the
	-- world's MagicMap (e.g. Energy 1.35 in volcanic highlands -> about x1.16 power).
	resonance = { powerExponent = 0.5, min = 0.75, max = 1.25 },

	-- Casting above your comfort power
	overreach = {
		maxLevels = 2,
		instabilityPerLevel = 0.12,
	},

	modifierSlots = {
		base = 1,
		perMastery = 30, -- +1 slot per 30 mastery
		max = 3,
	},

	instability = {
		powerBase = 0.5,
		powerScale = 0.1, -- multiplier = 0.5 + 0.1 * P
	},

	Ambient = {
		default = 1,
		min = 0,
		max = 3,
		scarcityCostMult = 0.6, -- cost *= 1 + 0.6 * max(0, 1 - density)
	},

	CostProfiles = CostProfiles,

	Reservoir = {
		base = 100,
		span = 900, -- max = 100 + 900 * (attunement/100)^curve
		curve = 1.25,
		attunementScale = 600, -- attunement = 100 * (1 - e^(-totalMastery/600))
		regenFraction = 0.012, -- of max per second at density 1
		activity = { Normal = 1, Resting = 2.5, Meditating = 4, Combat = 0.4 } :: { [string]: number }, -- Meditating: a meditation mat
		overdrawLimit = 0.5, -- may go down to -50% of max
		strainPerDepth = 100,
		strainDecayPerSecond = 2,
		strainRegenPenalty = 0.5,
		backlashHpPerMana = 0.5,
		burnoutThreshold = 0.15,
		burnoutBase = 10,
		burnoutPerDepth = 60,
		lockoutThreshold = 0.3,
		lockoutBase = 30,
		lockoutPerDepth = 120,
		mutationThreshold = 0.25,
		mutationPerDepth = 0.4,
		mutationMaxChance = 0.35,
	},

	-- Generation odds per rarity live server-side in ProfileTuning (never replicated).
	rarities = { "Common", "Uncommon", "Rare", "Mythic" },
}

return Tuning
