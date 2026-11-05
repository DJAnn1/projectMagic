--!strict
--[[
	ProfileTuning (SERVER ONLY)
	Every number that shapes innate profile generation. It lives in ServerScriptService
	because together with the world seed it would let a client compute every NPC's hidden
	latents. See docs/InnateProfiles.md §2 for the math these feed.

	Weighted lists are ARRAYS so the draw order is deterministic. Reordering or inserting
	entries changes every generated profile: bump GENERATOR_VERSION when you do.
]]

local ProfileTuning = {
	GENERATOR_VERSION = 1, -- bump when anything below changes the outcome for an existing seed
	PROFILE_VERSION = 1, -- save schema version

	-- Overall giftedness. potential ~ Uniform(min, max) within the rolled tier.
	-- domainCount = weights for having 1, 2, 3, 4 primary domains.
	-- mythicMult scales mythic.baseChance.
	giftTiers = {
		{ id = "Faint", weight = 30, min = 0.05, max = 0.20, mythicMult = 0, domainCount = { 70, 25, 5, 0 } },
		{ id = "Modest", weight = 45, min = 0.20, max = 0.45, mythicMult = 0.25, domainCount = { 45, 40, 13, 2 } },
		{ id = "Gifted", weight = 18, min = 0.45, max = 0.65, mythicMult = 1, domainCount = { 30, 45, 20, 5 } },
		{ id = "Prodigy", weight = 6, min = 0.65, max = 0.85, mythicMult = 4, domainCount = { 20, 45, 28, 7 } },
		{ id = "Paragon", weight = 1, min = 0.85, max = 1.00, mythicMult = 20, domainCount = { 10, 35, 40, 15 } },
	},
	playerMinGiftTier = "Modest",

	-- Weight of each domain when picking primaries (without replacement), by domain rarity.
	domainRarityWeight = { Common = 1.0, Uncommon = 0.45, Rare = 0.15, Mythic = 0 } :: { [string]: number },
	-- Extra multiplier when a hidden Domain latent picks its target: hidden gifts skew rarer.
	latentRarityBoost = { Common = 1, Uncommon = 1.5, Rare = 2.5, Mythic = 0 } :: { [string]: number },

	affinity = {
		rankFactor = { 1.0, 0.8, 0.65, 0.55 }, -- primary #k gets potential * rankFactor[k] * jitter
		jitterMin = 0.85,
		jitterMax = 1.15,
		primaryFloor = 0.25, -- every primary is at least meaningful
		backgroundMax = 0.18, -- non-primary: backgroundMax * u^backgroundExponent
		backgroundExponent = 3,
	},
	manifestThreshold = 0.25,
	exceptionalThreshold = 0.8,

	-- Tier-1 branch leaning = multiplier on its domain's affinity.
	leaning = { min = 0.7, max = 1.3, favoredMult = 1.35 },

	reservoir = {
		capacityBase = 0.7, -- capacity = (0.7 + 0.8 * potential) * (1 ± 0.1)
		capacityPerPotential = 0.8,
		capacityJitter = 0.1,
		regenMin = 0.85,
		regenMax = 1.15,
	},

	temperamentCount = { 15, 50, 28, 7 }, -- weights for 0, 1, 2, 3 temperaments
	temperamentWeights = {
		{ id = "volatile", weight = 10 },
		{ id = "precise", weight = 10 },
		{ id = "swift", weight = 9 },
		{ id = "patient", weight = 9 },
		{ id = "steadfast", weight = 8 },
		{ id = "subtle", weight = 7 },
		{ id = "radiant", weight = 7 },
		{ id = "resonant", weight = 6 },
		{ id = "hollow", weight = 6 },
		{ id = "deepwell", weight = 6 },
		{ id = "conduit", weight = 6 },
		{ id = "brittle", weight = 5 },
		{ id = "bloodbound", weight = 3 },
	},

	growthWeights = {
		{ id = "early", weight = 25 },
		{ id = "steady", weight = 45 },
		{ id = "late", weight = 20 },
		{ id = "breakthrough", weight = 10 },
	},

	learning = {
		styles = { "study", "combat", "teaching", "meditation", "experimentation" },
		favoredMin = 1.4,
		favoredMax = 1.7,
		weakMin = 0.6,
		weakMax = 0.8,
		otherMin = 0.9,
		otherMax = 1.1,
	},

	latentCount = { 35, 40, 18, 7 }, -- weights for 0, 1, 2, 3 latents (mythic is separate)
	latentKinds = {
		{ id = "Domain", weight = 40 },
		{ id = "Amplify", weight = 25 },
		{ id = "Capacity", weight = 15 },
		{ id = "Temperament", weight = 20 },
	},
	latentStrength = {
		Domain = { 0.25, 0.6 }, -- affinity the domain is raised to
		Amplify = { 0.08, 0.25 }, -- added to an existing domain
		Capacity = { 0.1, 0.35 }, -- added to the capacity multiplier
		Temperament = { 1, 1 },
		Mythic = { 0.3, 0.7 },
	} :: { [string]: { number } },
	latentTriggerCount = 2,
	awakeningCategories = { "Danger", "Location", "Mentor", "Ritual", "Emotion", "Experiment" },

	-- P(mythic latent) = baseChance * giftTier.mythicMult. Overall ≈ 1 in 40,956 people.
	mythic = {
		baseChance = 1 / 30000,
		domains = {
			{ id = "time", weight = 45 },
			{ id = "gravity", weight = 45 },
			{ id = "reality", weight = 10 },
		},
	},

	signature = {
		hueShift = 0.05,
		particles = { "embers", "motes", "shards", "ribbons", "sparks", "petals", "ripples", "glyphs", "smoke", "dust", "bubbles", "feathers" },
		motions = { "swirling", "darting", "drifting", "pulsing", "spiraling", "flickering" },
		timbres = { "bright", "hollow", "warm", "glassy", "gritty", "breathy" },
		pitchRange = 7, -- semitones; triangular distribution centred on 0
	},

	-- Person rarity tier rules (applied by InnateProfile.getRarityTier).
	-- Target shares (true tier): ~45 / 30 / 17 / 6 / 1.5 / mythic.
	rarity = {
		legendaryExceptionalCount = 2,
		epicRareDomainAffinity = 0.6,
		rareRareDomainAffinity = 0.35, -- a Rare domain only makes you Rare once it's notable
		rareGiftedTopAffinity = 0.55, -- a Gifted gift only counts once it shows in your strongest domain
		rareMeaningfulCount = 4,
		uncommonDomainAffinity = 0.35, -- an Uncommon/Rare domain must be notable to make you Uncommon
		uncommonMeaningfulCount = 3, -- 1-3 domains is normal; 2 alone isn't special
	},

	-- What a person can perceive about themselves, by knowledge level.
	bands = {
		{ min = 0.8, name = "Exceptional" },
		{ min = 0.65, name = "Formidable" },
		{ min = 0.45, name = "Strong" },
		{ min = 0.25, name = "Moderate" },
		{ min = 0.1, name = "Faint" },
	},
	capacityBands = {
		{ min = 1.4, name = "Vast" },
		{ min = 1.1, name = "Deep" },
		{ min = 0.85, name = "Average" },
		{ min = 0, name = "Shallow" },
	},

	historyCap = 50,
}

return ProfileTuning
