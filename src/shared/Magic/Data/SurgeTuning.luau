--!strict
--[[
	SurgeTuning: the transformation everyone earns by fighting (docs/Moments.md). Lists are indexed by your
	best mastery tier, 1 (Sensing) to 8 (Transcendent).

	TUNING STATUS  First guesses, not yet played. A power 3 hit is about 17, power 10 about 36.
]]

export type Finisher = { name: string, status: string?, seconds: number?, dotShare: number?, launch: number? }

local finishers: { [string]: Finisher } = {
	energy = { name = "Solar Flare", status = "burning", seconds = 4, dotShare = 0.15 },
	earth = { name = "Worldbreaker", launch = 60 },
	water = { name = "Deluge", status = "slow", seconds = 5 },
	air = { name = "Cyclone", launch = 110 },
	life = { name = "Overgrowth", status = "root", seconds = 2.5 },
	spirit = { name = "Soulfire", status = "hexed", seconds = 5, dotShare = 0.1 },
	mind = { name = "Mindbreak", status = "dazed", seconds = 5 },
	void = { name = "Annihilation", status = "silence", seconds = 3 },
	space = { name = "Fold", status = "jinxed", seconds = 6, launch = 50 },
	time = { name = "Last Second", status = "time_slow", seconds = 4 },
	gravity = { name = "Collapse", status = "root", seconds = 2, launch = 40 },
	reality = { name = "Unwrite", status = "jinxed", seconds = 8 },
}

return table.freeze({
	finishers = finishers,
	fallback = { name = "Release" } :: Finisher,

	-- Filling the meter.
	fillDamage = { 180, 300, 380, 440, 480, 520, 620, 720 }, -- damage dealt for a full meter
	maxPerHit = 0.12, -- no single hit gives more than this share
	takenShare = 0.8, -- losing all your health would fill this much
	idleSeconds = 20, -- no fighting for this long and it starts to fade
	fadePerSecond = 0.02,

	-- The transformation.
	seconds = { 12, 13, 14, 15, 16, 18, 20, 25 },
	damage = { 0.15, 0.18, 0.22, 0.27, 0.33, 0.4, 0.5, 0.6 }, -- your spells hit this much harder
	resist = { 0.1, 0.12, 0.15, 0.18, 0.22, 0.27, 0.33, 0.4 }, -- resist all damage
	costMult = { 0.8, 0.75, 0.7, 0.65, 0.6, 0.55, 0.45, 0.4 }, -- spells cost this share
	healShare = 0.15, -- of max health when you transform
	reservoirShare = 0.4, -- of max reservoir when you transform

	-- The finisher: press again to end it with a blast.
	finisherShare = { 1, 1.2, 1.4, 1.6, 1.9, 2.2, 2.6, 3 }, -- of a full hit, at the centre
	finisherRadius = { 14, 16, 18, 21, 24, 28, 34, 40 }, -- studs
	finisherRim = 0.5, -- damage at the edge, as a share of the centre's
	maxTargets = 24,
})
