--!strict
--[[
	QuestTuning: every number the quest system uses (docs/Quests.md). Server-only.
]]

return table.freeze({
	-- ─── Situation detection (Quests/SituationDetector) ─────────────────────
	scanSeconds = 30, -- world scan interval (spread over frames by the Scheduler)
	situationHours = 72, -- real hours an undetected-again situation stays alive
	maxSituations = 400, -- server-wide cap (least recently seen dropped first; never one true right now)
	npcScanPerPass = 60, -- NPCs inspected per pass (round-robin over the whole population)
	stressThreshold = 0.65, -- tectonic stress share that counts as "tremors"
	mineStressRadius = 300,
	lowDensity = 0.55, -- ambient density at a settlement that counts as a ley shift
	hostileRelation = -0.35, -- settlement relation that counts as a dispute
	beginner = { -- first-hour situations (SituationDetector.scanPlayer)
		belowTier = 3, -- best branch below Adept
		radius = 300, -- studs from a town's centre
		duskFrom = 17, -- game hours: "light the lamps"
		duskTo = 22,
	},

	-- ─── The Director (Services/QuestDirector) ──────────────────────────────
	directorSeconds = 45, -- per-player decision interval (staggered)
	offerRadius = 1400, -- situations this far from a player can become offers
	maxOffers = 3, -- open offers per player
	maxActive = 5, -- active personal quests per player
	offerHours = 6, -- real hours an unaccepted offer stays open
	-- Party members advancing each other's quests (docs/Social.md §3).
	party = {
		helperShare = 0.6, -- a helper's rewards, as a share of what the quest's owner gets
		assistRadius = 150, -- studs from the owner when it ends: being there counts as helping
	},
	--[[
		Item drops for a quest that succeeds, by template type: { item, chance, min, max }. Seeded by
		the quest id, so abandoning and retrying can't reroll them. A type that isn't listed uses
		`default`; `false` drops nothing (first-hour chores keep their own rewards simple).
	]]
	loot = {
		default = {
			{ item = "healing_draught", chance = 0.4, min = 1, max = 2 },
			{ item = "reservoir_tonic", chance = 0.25, min = 1, max = 1 },
		},
		chore = false,
		training = false,
		hunted = false,
		atonement = false,
		crisis = {
			{ item = "healing_draught", chance = 0.5, min = 1, max = 2 },
			{ item = "reservoir_tonic", chance = 0.4, min = 1, max = 2 },
			{ item = "quartz", chance = 0.3, min = 1, max = 2 },
		},
		research = {
			{ item = "blank_vellum", chance = 0.6, min = 1, max = 2 },
			{ item = "reservoir_tonic", chance = 0.3, min = 1, max = 1 },
		},
		hunt = {
			{ item = "wolf_hide", chance = 0.5, min = 1, max = 3 },
			{ item = "healing_draught", chance = 0.3, min = 1, max = 1 },
			{ item = "bone_dagger", chance = 0.08, min = 1, max = 1 },
		},
		heist = {
			{ item = "lockpick", chance = 0.6, min = 2, max = 4 },
			{ item = "copper_band", chance = 0.12, min = 1, max = 1 },
		},
	},
	-- Pacing: tension 0..1 per player. Calm wants intensity <= 0.35, rising <= 0.65, peak any.
	tension = {
		decayPerMinute = 0.02,
		damageTaken = 0.004, -- per point of damage taken
		damageDealt = 0.001,
		questFailed = 0.15,
		questCompleted = -0.2, -- release after a climax
		crisisNearby = 0.1, -- per director check with an active world event near the player
	},
	phases = { -- by tension
		{ max = 0.25, id = "calm", wantIntensity = 0.3 },
		{ max = 0.6, id = "rising", wantIntensity = 0.6 },
		{ max = 1, id = "peak", wantIntensity = 0.9 },
	},
	-- Scoring: weight x focus x novelty x pacing x power x faction x distance.
	focusBoost = 1.6, -- added x (share of the player's recent XP in the template's domains)
	focusFloor = 0.6, -- templates outside your focus still score at least this (never exclusive)
	noveltyBase = 0.45, -- x this per completion of the same template in the last 10
	noveltyTypeBase = 0.75, -- x this per recent quest of the same TYPE
	pacingWidth = 0.35, -- intensity distance at which pacing fit halves
	offerChance = 0.55, -- chance a check produces an offer when one scores
	complicationScale = { calm = 0.3, rising = 1, peak = 1.6 },

	-- ─── Objectives ─────────────────────────────────────────────────────────
	pollSeconds = 1, -- position objectives (reach, escort, witness, unseen)
	noticeRadius = 14, -- unseen: an awake NPC this close notices you
	noticeSeconds = 1.5, -- ...after being that close for this long
	duelYieldShare = 0.3, -- a duelling NPC yields at this health share
	contributionMin = 0.15, -- shared quests: share of the top contributor needed for a reward

	-- ─── Reputation (Services/ReputationService) ────────────────────────────
	infamy = {
		max = 100,
		decayPerHour = 1.5, -- real hours
		crimeScale = 0.6, -- infamy per point of settlement reputation lost to a crime
		bountyAt = 25, -- infamy at which the Concord posts a bounty in that territory
		bountyPerInfamy = 12, -- currency
		guardsEngageAt = 40, -- guards attack on sight (in the bounty's territory)
	},
	mythicNotoriety = {
		perCast = 2, -- per mythic-domain cast seen by anyone
		perAwakening = 40,
		decayPerHour = 0.5,
		huntAt = 35, -- the Quiet Hand sends hunters (the "hunted" situation)
	},
	witnessRadius = 60, -- a faction member this close sees a deed
})
