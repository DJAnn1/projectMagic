--!strict
--[[
	RealityTuning: how the Reality powers scale with skill (docs/Reality.md). The owner's brief
	(2026-11-09): make Reality more powerful, with many more utilities, like Gravity and Time. Reality
	is the rarest domain, so the top of every table is meant to feel like rewriting the world.

	Lists are indexed by mastery tier in the spell's branch:
	      1 Sensing  2 Novice  3 Adept  4 Skilled  5 Expert  6 Master  7 Grandmaster  8 Transcendent

	TUNING STATUS  First guesses. None has been played.
]]

return table.freeze({
	-- Fortune: luck bends your way.
	favor = {
		seconds = { 15, 18, 22, 26, 30, 35, 40, 50 },
		crit = { 0.05, 0.08, 0.1, 0.14, 0.18, 0.22, 0.28, 0.35 }, -- added to your crit chance (and to its cap)
		graze = { 0, 0.03, 0.05, 0.08, 0.1, 0.14, 0.18, 0.25 }, -- chance a direct hit on you simply misses
	},

	-- Doom: their luck turns.
	doom = {
		seconds = { 5, 6, 7, 8, 9, 10, 12, 15 },
		crit = { 0.08, 0.1, 0.12, 0.15, 0.2, 0.25, 0.3, 0.4 }, -- added to the crit chance of hits on them
		miss = { 0.05, 0.08, 0.1, 0.15, 0.2, 0.25, 0.3, 0.4 }, -- chance their direct hits miss
	},

	-- Certainty: the next hits on them are guaranteed crits.
	certainty = {
		hits = { 1, 1, 2, 2, 3, 4, 5, 6 },
		seconds = 15,
	},

	-- Twist of Fate: charges that cancel a hit and send it back.
	twist = {
		charges = { 1, 1, 1, 2, 2, 3, 4, 5 },
		seconds = { 15, 18, 20, 25, 30, 35, 40, 60 },
		reflect = { 0.25, 0.35, 0.5, 0.6, 0.75, 0.9, 1.1, 1.5 }, -- of the cancelled hit, dealt to whoever sent it
	},

	-- Conjure: matter from nothing. Every shape is a temporary construct.
	conjure = {
		seconds = { 8, 10, 14, 18, 24, 30, 45, 60 },
		stepSize = 7,
		wallWidth = { 10, 12, 14, 18, 22, 28, 34, 40 },
		wallHeight = { 8, 9, 10, 12, 14, 16, 20, 24 },
		bridgeLength = { 20, 30, 40, 55, 70, 90, 120, 150 },
		bridgeWidth = 6,
		pillarHeight = { 6, 8, 10, 14, 18, 24, 30, 40 },
		bastionRadius = { 6, 7, 8, 10, 12, 14, 16, 20 },
		bastionPanels = 10,
		maxPerCaster = 4, -- conjured shapes alive at once; making one more removes the oldest
	},

	cage = {
		seconds = { 2, 2.5, 3, 4, 5, 6, 8, 10 },
		size = 7, -- inside width
		height = 9,
	},

	-- Unmake: matter to nothing, for a while. Floors stay.
	unmake = {
		seconds = { 4, 5, 6, 8, 10, 14, 18, 25 },
		parts = { 4, 6, 8, 12, 16, 24, 32, 40 }, -- per cast
		share = { 0.6, 0.7, 0.8, 0.9, 1.0, 1.2, 1.4, 1.7 }, -- of a full hit, to people it reaches
		strip = { 1, 1, 1, 2, 2, 3, 3, 4 }, -- helpful statuses (wards first) torn away before the hit
		pointRadius = 4, -- touch, beam, projectile and chain: around the spot
		areaRadiusMax = 40,
		serverParts = 300, -- unmade at once on the server
		transparency = 0.85,
	},

	undying = {
		seconds = { 2, 2, 3, 3, 4, 5, 6, 8 },
		cooldown = { 90, 80, 70, 60, 50, 40, 30, 20 },
	},

	fray = {
		seconds = { 5, 6, 7, 8, 9, 10, 12, 15 },
		mult = { 1.1, 1.15, 1.2, 1.25, 1.3, 1.4, 1.5, 1.75 }, -- damage they take
	},

	polymorph = {
		seconds = { 2, 2.5, 3, 3.5, 4, 5, 6, 8 },
		immunity = 4, -- seconds after one ends before another can land
	},

	exchange = {
		cooldown = { 90, 80, 70, 60, 50, 40, 30, 20 },
	},

	-- Edicts: a local law, one per caster.
	edict = {
		seconds = { 6, 7, 8, 10, 12, 15, 18, 24 },
		radiusMin = 10,
		radiusMax = { 12, 14, 16, 18, 22, 26, 32, 40 },
		reversal = { 0.5, 0.55, 0.6, 0.7, 0.8, 0.9, 1.0, 1.2 }, -- of the harm, healed instead
		scanEvery = 0.5, -- seconds between Hush silencing whoever walked in
		maxTargets = 40,
		maxActive = 8, -- edicts on the server
	},

	-- Worldlaw: an edict over a region.
	worldlaw = {
		seconds = { 90, 90, 90, 120, 150, 180, 300, 600 },
		radius = { 150, 150, 150, 180, 220, 260, 320, 400 },
		cooldown = 900, -- per caster
		maxActive = 1, -- on the server
		maxTargets = 60,
	},
})
