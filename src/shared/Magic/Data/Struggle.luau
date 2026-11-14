--!strict
--[[
	Struggle: tuning for spells that meet in the air and spell struggles (docs/SpellStruggle.md;
	rules in Shared/Magic/StruggleRules, runtime in Server/Magic/Cast/Struggle and Cast/Delivery).

	WEIGHT   power^powerExponent x form x (1 + perTier x tier) x matchup. Power already carries the
	         charge stage, gear, weather and Surge (CastService applies them before the strike).
	OUTCOME  by ratio = heavier / lighter: cut through (>= cutAt), shatter (>= struggleBand), else a
	         struggle when head-on (directions' dot <= headOnDot), else a glance (bent glanceDegrees
	         apart). Arrows and knives weigh `arrowWeight` and never struggle.
	STRUGGLE the knot sits at `point` (0 at side A, 1 at side B) and drifts by
	         (pushA - pushB) / (pushA + pushB) x drift per second, toward the weaker side.
	         push = weight x feed x (1 + surges in the last second x surgeBoost) x hurt
	         feed: 1 while you feed it (hold, or a surge in the last feedGrace s) and can pay
	         feedCost x weight reservoir a second; idleFeed otherwise. A surge costs surgeCost of
	         your max reservoir, at most surgeCap a second (more are ignored).
	         Ends: the knot within overwhelmStuds of a caster (overwhelmed: both spells land on them,
	         the winner's at full, the loser's at loserShare, plus a knockdown); a caster lets go (the
	         winner's spell lands letGoDelay s later, unless they moved dodgeStuds); maxSeconds (the
	         knot bursts: each spell lands on the other caster at burstShare).
]]

local Struggle = {
	powerExponent = 0.8,
	form = { projectile = 1.0, beam = 1.3 } :: { [string]: number },
	perTier = 0.04,
	matchupFor = 1.2, -- your tags counter theirs
	matchupAgainst = 0.85, -- theirs counter yours
	-- Tag -> the tags it beats (InteractionMatrix tags). Mythic tags beat nothing and nothing beats them.
	counters = {
		water = { "fire", "heat" },
		stone = { "lightning", "force" },
		lightning = { "water", "metal" },
		fire = { "life", "rot" },
		light = { "dark", "rot", "spirit" },
		dark = { "light" },
		life = { "rot" },
		metal = { "stone" },
		null = { "spirit", "light", "dark" },
		gravity = { "force", "water" },
	} :: { [string]: { string } },
	arrowWeight = 0.6,

	-- Outcome bands.
	cutAt = 1.6,
	struggleBand = 1.15,
	headOnDot = -0.7,
	glanceDegrees = 25,
	shatterShare = 0.5, -- each shattered spell lands at this share, at the meeting point
	contactPad = 0.5, -- studs added to the two radii

	-- Beams.
	beamMemory = 0.6, -- seconds an ordinary beam is remembered, so another can meet it
	beamCross = 2.5, -- studs between the two lines to count as meeting
	beamHeadOnDot = -0.5,

	-- The struggle.
	maxGap = 80, -- studs between the casters to start one
	breakGap = 110, -- further apart than this (a teleport) and the one who moved lets go
	maxStruggles = 6,
	maxSeconds = 8,
	tickRate = 10,
	drift = 0.12,
	idleFeed = 0.3,
	feedCost = 0.9, -- reservoir a second per point of weight
	feedGrace = 0.4,
	surgeCost = 0.04, -- of max reservoir
	surgeBoost = 0.18,
	surgeCap = 4,
	hurtFactor = 0.6, -- push while you're being hit by someone else
	hurtSeconds = 1,
	overwhelmStuds = 3,
	loserShare = 0.5,
	burstShare = 0.6,
	letGoDelay = 0.35,
	dodgeStuds = 5,
	knockdownSeconds = 1.2,
	-- NPC mages: feed = npcFeedBase + npcFeedCourage x courage (0..1), a surge a tick at
	-- npcSurgeChance x courage, and they let go when the knot is within npcLetGoAt of them and their
	-- courage is under npcLetGoCourage.
	npcFeedBase = 0.6,
	npcFeedCourage = 0.5,
	npcSurgeChance = 0.25,
	npcLetGoAt = 0.25,
	npcLetGoCourage = 0.35,
	cueRange = 300, -- players this close get the struggle's updates
}

return Struggle
