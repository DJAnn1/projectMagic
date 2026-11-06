--!strict
--[[
	Types
	Shared type definitions for the magic grammar:
		Domain -> Branch tree -> (Property, Verb, Form, Modifiers) -> Recipe -> SpellStats

	Data modules are keyed by stable string ids. The key IS the id and is what gets saved,
	so ids must never be renamed or reused (see Data/Aliases for renames).
]]

-- ─── Definitions (authored data) ────────────────────────────────────────────

export type RiskDef = {
	id: string,
	name: string,
	description: string,
	backlashMult: number, -- HP damage on overdraw
	burnoutMult: number, -- regen-halt duration
	lockoutMult: number, -- domain lockout duration
	mutationMult: number, -- chance of a permanent mutation roll
}

export type FeelDef = {
	palette: { Color3 },
	sound: string,
	particles: string,
}

export type DomainDef = {
	name: string,
	concept: string,
	rarity: string, -- "Common" | "Uncommon" | "Rare" | "Mythic" (validated by Registry)
	properties: { string }, -- every Property this Domain can ever touch
	synergies: { string },
	oppositions: { string },
	costMult: number,
	volatility: number,
	feel: FeelDef,
	risk: RiskDef,
}

-- A domain's first attack (Data/Strikes).
export type StrikeRider = {
	status: string?,
	duration: number?,
	chance: number?,
	dotShare: number?,
	strip: number?,
	shove: number?,
	word: string,
}

export type StrikeDef = {
	name: string,
	rangedName: string, -- the projectile version's name (the third innate spell: Cantrips.bolt)
	property: string,
	verbs: { string },
	forms: { string }?,
	native: string?,
	share: number?,
	innateCost: number?, -- rarity tax x costWeight for the power 1 Strike and its thrown form (Data/Strikes)
	rider: StrikeRider?,
	flavour: string,
}

export type PropertyDef = {
	name: string,
	category: string, -- column in the Verb x Category matrix (validated by Registry)
	costWeight: number, -- how expensive it is to manipulate at all
	volatility: number, -- flat instability contribution
	harmful: boolean, -- can directly injure (used by safe zones, AI threat scoring)
	description: string,
}

export type VerbDef = {
	name: string,
	description: string,
	minTier: number, -- branch tier required to use this verb
	requirement: string, -- "None" | "Target" | "Source" | "Stored": what the world must provide at cast time
	costMult: number,
	powerMult: number,
	instability: number,
	castTimeMult: number,
	durationMult: number,
}

export type FormDef = {
	name: string,
	description: string,
	minTier: number,
	minMastery: number,
	baseRange: number, -- studs
	baseArea: number, -- studs (radius, or half-length for Wall)
	baseDuration: number, -- seconds
	castTime: number, -- seconds
	cooldown: number, -- seconds
	costMult: number,
	powerMult: number, -- concentration: focused forms hit harder per target
	instability: number,
	maxTargets: number, -- 0 = area-limited (capped by Tuning.maxAreaTargets)
	extraTargetsPerPower: number,
	modifierSlotsBonus: number,
}

export type ModifierDef = {
	name: string,
	description: string,
	minTier: number,
	costMult: number,
	powerMult: number,
	rangeMult: number,
	areaMult: number,
	durationMult: number,
	castTimeMult: number,
	cooldownMult: number,
	instability: number, -- additive
	forms: { string }?, -- nil = any form
	verbs: { string }?, -- nil = any verb
	excludes: { string }?, -- made symmetric by Registry
	params: { [string]: number }?,
}

export type Prerequisite = {
	branch: string,
	mastery: number,
}

-- Authoring shape of the branch tree (nested).
export type BranchNode = {
	id: string,
	name: string,
	description: string,
	properties: { string }?, -- granted IN ADDITION to everything the parent grants
	maxPower: number?, -- defaults to Tuning.tierMaxPower[tier]
	prerequisites: { Prerequisite }?, -- extra requirements beyond "parent mastery >= threshold"
	tags: { string }?,
	children: { BranchNode }?,
}

export type HybridNode = {
	id: string,
	name: string,
	description: string,
	domains: { string },
	properties: { string },
	prerequisites: { Prerequisite },
	maxPower: number?,
	tags: { string }?,
	children: { BranchNode }?,
}

-- Flattened, resolved branch produced by the Registry.
export type BranchDef = {
	id: string,
	name: string,
	description: string,
	tier: number,
	domains: { string },
	parent: string?,
	children: { string },
	ownProperties: { string },
	properties: { string }, -- own + inherited
	propertySet: { [string]: boolean },
	prerequisites: { Prerequisite },
	maxPower: number,
	isRoot: boolean,
	isHybrid: boolean,
	tags: { string },
}

export type CostProfileDef = {
	name: string,
	description: string,
	ambientSharePerDensity: number,
	ambientShareMax: number,
	minDensity: number,
	vitalShare: number,
	hpPerMana: number,
	powerMult: number,
	instabilityMult: number,
	castTimeMult: number,
}

-- ─── Runtime ────────────────────────────────────────────────────────────────

-- What gets saved and sent over the network. Domain is derived from the branch.
export type Recipe = {
	v: number,
	branch: string,
	property: string,
	verb: string,
	form: string,
	modifiers: { string }, -- sorted, unique
	power: number, -- integer PowerLevel 1..10
	costProfile: string,
}

-- Aggregated innate modifiers (temperaments x innate reservoir). Every field is neutral at 1
-- (multipliers) or 0 (bonuses); see Tuning.neutralTraits.
export type CasterTraits = {
	power: number,
	cost: number,
	instability: number,
	castTime: number,
	capacity: number,
	regen: number,
	overdrawRisk: number,
	ambientShareBonus: number,
	vitalCost: number,
	detectability: number,
	allyPower: number,
}

export type CasterProfile = {
	id: string,
	attunement: number?, -- 0..100; derived from mastery when nil
	affinities: { [string]: number }, -- domainId -> 0..1 (innate, seeded)
	awakened: { [string]: boolean }, -- domainId -> discovered
	mastery: { [string]: number }, -- branchId -> 0..100
	branchAffinities: { [string]: number }?, -- tier-1 branchId -> 0..1 innate leaning
	traits: CasterTraits?,
	-- Progression-driven fields. When `unlocked` is present it is authoritative; without it
	-- (tests, previews) unlocking falls back to the legacy parent-mastery rule.
	unlocked: { [string]: boolean }?,
	branchMods: { [string]: BranchMod }?, -- from specialization commitments
	signatures: { [string]: number }?, -- recipeKey -> declared at; the creator's signature spells
	-- Item bonuses (Server/Items/StatCache), set by CastService before each validation.
	bonusModifierSlots: number?, -- extra modifier slots (never beyond a form's structural max)
	bonusFormTier: number?, -- forms gated one tier higher become usable
}

export type BranchMod = {
	power: number,
	cost: number,
	xp: number,
}

export type MasteryTierDef = {
	index: number, -- 0 = Untouched .. 8 = Transcendent
	id: string,
	name: string,
	minMastery: number,
	powerCeiling: number,
	breakthrough: boolean, -- crossing INTO this tier needs a breakthrough
	verbs: { string }, -- verbs that first become usable at this tier
	forms: { string }, -- forms that first become usable at this tier
	vfxScale: number, -- how strongly the caster's magic visibly expresses itself
	unlocks: string,
	look: string,
}

export type SpecializationDef = {
	name: string,
	description: string,
	branch: string, -- boosted, with all descendants
	minMastery: number,
	boost: BranchMod,
	weakens: { string }, -- branches (with descendants) that get `penalty`
	penalty: BranchMod,
}

export type TechniqueDef = {
	name: string,
	domain: string,
	tier: number, -- mastery tier at which this becomes possible
	recipe: { branch: string, property: string, verb: string, form: string, power: number, modifiers: { string }?, costProfile: string? },
	description: string,
	environment: string?,
}

export type EnvironmentRuleDef = {
	id: string,
	description: string,
	branches: { string }, -- matches these branches and all their descendants
	properties: { string }?, -- nil = any property
	verbs: { string }?, -- nil = any verb
	minPower: number,
	fact: string, -- key in CastContext.environment
	base: number, -- required amount at minPower
	growth: number, -- required *= growth per power level above minPower
	hardFraction: number, -- below this share of the requirement, the cast is blocked
}

export type CastContext = {
	ambientDensity: number?, -- 0 (dead zone) .. 3 (nexus); default 1
	ambientBias: { [string]: number }?, -- domainId -> multiplier (volcano: energy 1.5)
	-- Server-measured world facts near the cast (waterVolume, groundMass, seismicStress, fuel, ...).
	-- Missing facts don't block (previews), they only warn; the cast pipeline must supply them.
	environment: { [string]: number }?,
}

export type ValidationError = {
	code: string,
	message: string,
}

export type CostBreakdown = {
	reservoir: number,
	ambient: number,
	vitalHp: number,
}

export type SpellStats = {
	key: string,
	recipe: Recipe,
	domains: { string },
	tier: number,
	category: string,
	requirement: string,
	harmful: boolean,
	magnitude: number,
	power: number,
	cost: number,
	costBreakdown: CostBreakdown,
	range: number,
	area: number,
	duration: number,
	castTime: number,
	cooldown: number,
	maxTargets: number,
	instability: number,
	backfireChance: number,
	comfortPower: number,
	overreach: number,
	flags: { [string]: boolean }, -- one entry per modifier id
	channelCostPerSecond: number,
	maxChannelTime: number,
	echoes: number,
	echoPower: number,
	delay: number,
	masteryTier: number,
	resonance: number, -- power multiplier from the place's domain resonance (ambientBias)
	environmentFactor: number, -- multiplier on power from environmental conditions
	blockedBy: string?, -- environment rule id that makes this cast impossible here
	warnings: { string },
}

export type RecipeTemplate = {
	branch: string,
	property: string,
	verb: string,
	form: string,
	maxPower: number,
	comfortPower: number,
	modifierSlots: number,
	modifiers: { string },
}

export type TemplateFilter = {
	branch: string?,
	property: string?,
	verb: string?,
	form: string?,
	limit: number?,
}

export type ReservoirState = {
	current: number,
	max: number,
	strain: number, -- 0..100, decays over time
	burnoutUntil: number, -- timestamp; regen halted and overdraw forbidden until then
	lockouts: { [string]: number }, -- domainId -> timestamp
	regenMult: number, -- innate (traits.regen)
	riskMult: number, -- innate (traits.overdrawRisk)
}

export type Consequence = {
	kind: string, -- "Backlash" | "Burnout" | "Lockout" | "Mutation"
	riskId: string, -- domain-flavoured risk (e.g. "withering") for VFX/status hooks
	amount: number,
	duration: number,
	domain: string?,
}

export type SpendResult = {
	ok: boolean,
	reason: string?,
	overdraw: number,
	hpCost: number,
	consequences: { Consequence },
}

-- ─── Innate profile ─────────────────────────────────────────────────────────

export type TraitEffects = {
	power: number?,
	cost: number?,
	instability: number?,
	castTime: number?,
	capacity: number?,
	regen: number?,
	overdrawRisk: number?,
	ambientShareBonus: number?, -- additive
	vitalCost: number?,
	detectability: number?,
	allyPower: number?, -- additive: power bonus granted to allies nearby
}

export type TemperamentDef = {
	name: string,
	description: string,
	effects: TraitEffects,
	excludes: { string }?,
}

export type GrowthCurveDef = {
	name: string,
	description: string,
	points: { { number } }, -- { mastery, gainMultiplier }, ascending mastery
	afterBreakthrough: { { number } }?,
}

export type Latent = {
	id: string, -- stable within the profile ("L1", "L2", "LM" for mythic)
	kind: string, -- "Domain" | "Amplify" | "Capacity" | "Temperament" | "Mythic"
	target: string, -- domain id, temperament id, or "" for Capacity
	strength: number,
	triggers: { string }, -- awakening categories that can reveal it
	revealed: boolean,
}

-- Colors are stored as hex strings: Color3 can't be written to a DataStore.
export type Signature = {
	primary: string,
	secondary: string,
	accent: string,
	particle: string,
	motion: string,
	timbre: string,
	pitch: number, -- semitone offset
}

export type AwakeningRecord = {
	count: number,
	lastAt: number,
}

export type HistoryEntry = {
	e: string, -- event id
	t: number, -- timestamp
}

-- The innate profile IS the save shape: plain data, JSON-safe, versioned.
export type InnateProfile = {
	v: number, -- save schema version
	gen: number, -- generator algorithm version that produced it
	worldSeed: number,
	entityId: string,
	kind: string, -- "Player" | "NPC"
	giftTier: string,
	potential: number, -- 0..1
	capacity: number, -- innate reservoir multiplier
	regen: number, -- innate regen multiplier
	domains: { [string]: number }, -- every domain, 0..1
	leanings: { [string]: number }, -- tier-1 branchId -> multiplier on its domain affinity
	manifest: { string }, -- awakened domains, strongest first
	temperaments: { string },
	growth: string,
	breakthrough: boolean,
	learning: { [string]: number }, -- styleId -> mastery gain multiplier
	latents: { Latent },
	signature: Signature,
	awakenings: { [string]: AwakeningRecord },
	history: { HistoryEntry },
}

export type GenerateContext = {
	kind: string?, -- "Player" | "NPC" (default "NPC")
	minGiftTier: string?, -- floor; players default to ProfileTuning.playerMinGiftTier
	forceGiftTier: string?, -- authored NPCs
	forceMythic: string?, -- authored NPCs only; never from player input
	domainBias: { [string]: number }?, -- lineage / birthplace weighting for domain picks
}

export type AwakeningEventDef = {
	name: string,
	category: string,
	description: string,
	trigger: string, -- designer-facing condition; detected by the system that calls applyAwakening
	-- Facts the caller must supply in context.facts, each within [min, max]. Checked by applyAwakening.
	requires: { [string]: { min: number?, max: number? } }?,
	domains: { string }?, -- nil = any domain
	domainFromContext: boolean?, -- e.g. a mentor teaches their own domain
	reveals: { string }, -- latent kinds it can reveal
	maxReveals: number,
	minorGain: number, -- affinity bump when nothing is revealed
	mythic: string?, -- mythic events reveal only this mythic domain's latent
	once: boolean?,
	cooldownHours: number,
	risk: {
		chance: number,
		temperament: string?,
		capacityLoss: number?,
		description: string,
	}?,
}

export type AwakeningContext = {
	now: number,
	domain: string?, -- for domainFromContext events
	facts: { [string]: number }?, -- server-measured, for events with `requires`
}

export type AwakeningResult = {
	ok: boolean,
	reason: string?,
	revealed: { Latent },
	changes: { string },
	risk: string?,
}

export type VisibleDomain = {
	domain: string,
	band: string?,
	value: number?,
}

export type VisibleProfile = {
	entityId: string,
	knowledgeLevel: number,
	domains: { VisibleDomain },
	leanings: { [string]: number }?,
	temperaments: { string }?,
	growth: string?,
	favoredLearning: string?,
	learning: { [string]: number }?,
	capacityBand: string?,
	capacity: number?,
	regen: number?,
	latentHints: { string }?,
	rarityTier: string?,
	signature: Signature,
}

return {}
