--!strict
--[[
	ProgressionTuning (server): every balance number for how experience is earned.
	See docs/Progression.md §2-§4 for the reasoning. Changing these never breaks saves:
	saves store XP, and mastery is always recomputed from it.
]]

local ProgressionTuning = {
	-- ─── Channels ───────────────────────────────────────────────────────────
	-- weight: multiplier on the channel's base amount.
	-- style:  which innate learning style (InnateProfile.learning) scales it.
	-- dailyCap: max XP per real day from this channel, summed over branches (nil = none).
	channels = {
		practice = { weight = 1.0, style = nil :: string?, dailyCap = nil :: number? },
		challenge = { weight = 1.75, style = "combat" :: string?, dailyCap = nil :: number? },
		study = { weight = 1.0, style = "study" :: string?, dailyCap = nil :: number? },
		experimentation = { weight = 1.0, style = "experimentation" :: string?, dailyCap = 2500 :: number? },
		observation = { weight = 1.0, style = "meditation" :: string?, dailyCap = 1500 :: number? },
		teaching = { weight = 1.0, style = "teaching" :: string?, dailyCap = 2500 :: number? },
	},

	-- ─── Practice ───────────────────────────────────────────────────────────
	practice = {
		base = 1.2, -- XP per cast = base * reservoirCost ^ costExponent * modifiers below
		costExponent = 0.6, -- effort-weighted: big spells teach more, but reservoir regen limits the rate
		relevanceFloor = 0.2, -- casting far below your comfort power teaches little
		ineffective = 0.25, -- a cast that hit nothing and changed nothing
		repeatHalfLife = 600, -- seconds for a recipe's repeat count to halve
		repeatScale = 12, -- spam factor = exp(-repeats / repeatScale)
		spamFloor = 0.05,
		hourlySoftCap = 2500, -- per branch per real hour; beyond it practice XP x hourlyOverflow
		hourlyOverflow = 0.25,
		idleSeconds = 120, -- no movement/aim change for this long = AFK: practice & observation give 0
		metronomeCasts = 20, -- casts examined for macro-like timing
		metronomeVariation = 0.03, -- coefficient of variation below this = machine-regular timing
		metronomePenalty = 0.5,
	},

	-- ─── Study sources ──────────────────────────────────────────────────────
	-- Each source id can be studied once per branch (books/scrolls) or per cooldown (mentors, lectures).
	study = {
		scroll = { xp = 120, cooldownHours = nil :: number? },
		book = { xp = 300, cooldownHours = nil :: number? },
		lecture = { xp = 450, cooldownHours = 20 :: number? },
		mentor = { xp = 650, cooldownHours = 20 :: number? }, -- scaled by (mentorTier - yourTier), min 1
		minTierGap = 1, -- a mentor must be at least this many tiers above you
	},

	-- ─── Experimentation ────────────────────────────────────────────────────
	experimentation = {
		personalFirstBase = 40, -- first time YOU cast a recipe: base + perPower * power
		personalFirstPerPower = 25,
		worldFirst = 1500, -- first time ANYONE in the world casts it
		minPowerForCredit = 2, -- P1 recipes are too trivial to count as discoveries
		-- Novelty: the first effective cast of a new verb + property + form, at any power (Experiment).
		noveltyBase = 30, -- base XP of the first one
		noveltyDecay = 0.95, -- each one found multiplies the next by this
		noveltyFloor = 3,
		noveltyCap = 400, -- combos remembered per player; past this they stop paying (save size)
		reactionXp = 60, -- the first time you trigger each InteractionMatrix reaction
	},

	-- ─── Observation ────────────────────────────────────────────────────────
	observation = {
		perTierGap = 4, -- XP = perTierGap * (theirTier - yourTier) * theirPower
		sameCasterCooldown = 60, -- seconds before the same caster can teach you by example again
		range = 40, -- studs
		insightSite = 600, -- one-time XP for studying an environmental insight site
	},

	-- ─── Teaching ───────────────────────────────────────────────────────────
	teaching = {
		share = 0.3, -- teacher gets this share of the student's study XP from them
		minTierGap = 2,
		minTeacherTier = 3, -- Adept
	},

	-- ─── Focus vs breadth ───────────────────────────────────────────────────
	focus = {
		halfLifeSeconds = 172800, -- 48 h: how quickly "recent focus" forgets
		maxBonus = 0.5, -- XP x (1 + maxBonus * share^2) for your share of recent XP in this domain
	},
	breadth = {
		lineThresholdMastery = 25, -- a tier-1 line counts as "active" at Adept or above
		freeLines = 3,
		penaltyPerLine = 0.10,
		floor = 0.5,
	},
	lineage = {
		trickle = 0.4, -- parent gets 40% of a branch's gain, grandparent 16%, ...
		hybridTrickle = 0.3, -- each hybrid prerequisite branch gets 30%
	},

	-- ─── Specialization ─────────────────────────────────────────────────────
	specialization = {
		commitmentsByTier = { [4] = 1, [5] = 1, [6] = 2, [7] = 3, [8] = 3 } :: { [number]: number },
		renounceXpLoss = 0.35,
		renounceCooldownSeconds = 30 * 86400,
		renounceLore = "rite:unbinding",
	},

	-- ─── Signature spells (paradigm shifts) ─────────────────────────────────
	signature = {
		minCasts = 50,
		minTier = 5, -- Expert in the spell's branch
		maxSignatures = 3,
	},
}

return ProgressionTuning
