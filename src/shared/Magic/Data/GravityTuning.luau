--!strict
--[[
	GravityTuning: how the gravity powers scale with skill (docs/Gravity.md). The owner's brief
	(2026-11-06): Gravity is supposed to be overpowered, so the top of every table is meant to feel
	that way. Limits exist only where they keep the server honest or stop one person freezing
	someone forever.

	Lists are indexed by mastery tier in the spell's branch:
	      1 Sensing  2 Novice  3 Adept  4 Skilled  5 Expert  6 Master  7 Grandmaster  8 Transcendent
	Damage comes from the normal formula (DamageModel), so it also grows with spell power, and the
	shares here multiply it. For scale: a full hit is about 17 at power 3, 26 at power 6, 36 at power 10.

	TUNING STATUS  First guesses. None has been played.
]]

return table.freeze({
	flight = {
		speed = { 16, 22, 30, 40, 52, 66, 85, 110 }, -- studs/s
		ceiling = { 8, 15, 30, 60, 100, 160, 260, 500 }, -- studs above the ground
		drainShare = { 0.08, 0.06, 0.045, 0.03, 0.02, 0.012, 0.006, 0.002 }, -- of max reservoir per second (the top is below regen: flight without end)
		speedSlack = 1.5, -- the server allows speed x this + speedMargin before it counts a strike
		speedMargin = 30, -- room for knockback and hastes
		heightSlack = 1.2, -- ceiling x this + heightMargin
		heightMargin = 30,
		strikesToEnd = 3, -- checks in a row over the limit before flight ends
		checkSeconds = 0.25,
	},

	meteor = {
		minTier = 6, -- Master
		minHeight = 15, -- studs above the ground to dive
		speed = 200, -- studs/s of the fall
		share = 0.8, -- of a full hit, plus sharePerStud per stud fallen, at most maxShare
		sharePerStud = 0.012,
		maxShare = 2.8,
		radius = 12, -- studs, plus radiusPerStud per stud fallen, at most maxRadius
		radiusPerStud = 0.12,
		maxRadius = 42,
		maxTargets = 24,
	},

	-- Pinned in place by the server: the victim can't move, cast, dash or attack.
	hold = {
		immunitySeconds = 1.5, -- after one ends, before the next can start (no holding someone forever)
		maxHolds = 40, -- on the server at once
	},

	grip = {
		duration = { 2, 2.5, 3, 3.5, 4.5, 5.5, 7, 9 }, -- seconds
		tick = 0.5,
		share = 0.25, -- of a full hit per tick when it starts ...
		ramp = 0.35, -- ... plus this share of that per second held
		execute = { 0, 0, 0, 0, 0.05, 0.12, 0.2, 0.3 }, -- at or below this share of max health, it finishes them
		rangeMult = 1.6, -- slips free past range x this + rangeMargin
		rangeMargin = 10,
		sightEvery = 0.5, -- seconds between line-of-sight checks
	},

	lift = {
		height = { 6, 10, 16, 24, 34, 46, 60, 80 }, -- studs
		throw = { 0, 0, 10, 20, 35, 50, 70, 100 }, -- studs toward where you aimed
		rise = 0.6, -- seconds
		hang = 0.25,
		fall = 0.22,
		firstShare = 0.1, -- of a full hit when they're seized
		slamShare = 0.5, -- when they land, plus slamPerStud per stud of height
		slamPerStud = 0.02,
		splashShare = 0.4, -- of the slam, to others near the landing
		splashRadius = 8, -- plus splashPerTier per tier
		splashPerTier = 1.5,
		maxSplash = 12,
	},

	well = {
		radiusMin = 14,
		radiusMax = 70,
		seconds = { 5, 6, 7, 8, 10, 12, 16, 20 },
		pull = { 8, 10, 13, 16, 20, 25, 30, 38 }, -- studs/s at the middle of the well (walking is 16)
		edgePull = 0.6, -- the pull at the rim, as a share of the middle's
		crushShare = { 0.05, 0.08, 0.1, 0.14, 0.18, 0.22, 0.26, 0.3 }, -- of a full hit per second, at the centre
		tick = 0.25,
		maxTargets = 24,
		maxLooseParts = 20,
	},

	singularity = {
		radiusMin = 22,
		radiusMax = 85,
		seconds = 3, -- the pull in, then it detonates
		maxTargets = 12,
		tick = 0.5,
		tickShare = 0.2, -- of a full hit per tick
		blastShare = 1.2, -- the detonation, plus blastPerTier per tier
		blastPerTier = 0.15,
		pullRate = 2.2, -- share of the remaining distance closed per second
		blastLaunch = 90, -- studs/s outward afterwards
	},

	orbit = {
		pieces = { 1, 2, 2, 3, 4, 5, 6, 8 }, -- projectiles it stops
		seconds = 12, -- plus secondsPerTier per tier
		secondsPerTier = 4,
		radius = 8, -- studs from you
	},

	bend = {
		radius = 16, -- studs, plus radiusPerTier per tier
		radiusPerTier = 2.5,
		seconds = 8, -- plus secondsPerTier per tier
		secondsPerTier = 2,
		reflectChance = { 0, 0, 0.1, 0.2, 0.3, 0.45, 0.6, 0.8 }, -- it comes back at them instead of curving past
		turn = 1.4, -- how hard a bent projectile veers away from you
	},

	mass = {
		seconds = 15, -- plus secondsPerTier per tier
		secondsPerTier = 5,
		resist = { 0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5 }, -- heavy: resist all damage
		damage = { 0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4, 0.5 }, -- heavy: your spells hit this much harder
	},

	crater = {
		meteorRadius = 6, -- studs, plus meteorPerStud per stud fallen, at most maxRadius
		meteorPerStud = 0.05,
		singularityShare = 0.35, -- of the singularity's radius
		minRadius = 6,
		maxRadius = 26,
		depthShare = 0.45, -- how deep the bowl is, as a share of its radius
		rimBalls = 8, -- mounds of thrown-up ground around the edge
		rimSize = 0.22, -- each, as a share of the radius
		minAboveSea = 3, -- studs: lower than this and no crater (it would flood)
		cell = 24, -- studs: repeats in one cell are skipped ...
		cellSeconds = 600, -- ... for this long, so one spot can't fill the world's saved edits
		minGap = 3, -- seconds between any two craters on a server
	},

	field = {
		heavy = { 2.2, 2.4, 2.7, 3, 3.5, 4, 5, 6 }, -- multiples of normal gravity
		invert = { -0.8, -0.8, -0.9, -1, -1.1, -1.2, -1.4, -1.6 }, -- the pull upward, still capped by the field's ceiling
		crushShare = { 0.15, 0.15, 0.18, 0.22, 0.28, 0.34, 0.42, 0.55 }, -- of a full hit per second, at the centre
	},
})
