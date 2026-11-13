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

	-- Conjured beings (docs/Reality.md "Conjured beings"; owner, 2026-11-13: "a genie that can do
	-- whatever they want to the world"). A Conjuration Summon spell: the verb picks the summoning.
	--   generate   a host that walks beside you
	--   bind       guardians that hold the spot you aimed at (they last longer, and don't follow)
	--   transmute  one colossal being, bigger with power
	-- Each is an elemental (Cast/Elementals) with these multipliers on top of its own numbers.
	summon = {
		seconds = { 30, 35, 40, 50, 60, 75, 90, 120 },
		host = { 1, 1, 1, 2, 2, 3, 3, 4 }, -- generate: bodies per cast
		guardians = { 1, 1, 2, 2, 3, 3, 4, 5 }, -- bind: bodies per cast
		extraFromPower = { [8] = 1, [9] = 1, [10] = 2 }, -- more bodies at these powers (generate and bind)
		limit = { 2, 2, 3, 3, 4, 5, 6, 8 }, -- yours alive at once; the oldest goes
		health = { 1.2, 1.3, 1.5, 1.7, 2, 2.3, 2.7, 3.2 }, -- x its health
		blow = { 1.1, 1.15, 1.25, 1.35, 1.5, 1.65, 1.8, 2 }, -- x each blow
		guardSeconds = 1.5, -- x seconds for guardians
		growFromPower = 9, -- generate and bind bodies grow from this power: x(1 + (power - 8) x growPerPower)
		growPerPower = 0.2,
		colossus = { scaleBase = 1.6, scalePerPower = 0.16, health = 4, blow = 2.2, maxScale = 3.4 }, -- transmute
		copyMaxParts = 160, -- a double is refused for anything with more parts than this
		spread = 5, -- studs between bodies raised together
	},

	-- Remake the land (docs/Reality.md "World wishes"): the ground in the area becomes the wished
	-- material, for good (saved, every server), never inside a town.
	remake = {
		radius = { 10, 12, 15, 18, 22, 28, 34, 42 }, -- at power 5; x(0.6 + power x 0.08)
		depth = 10, -- studs of ground rewritten under the surface (water: 6, a lake not a pit)
		waterDepth = 6,
		cooldown = { 30, 26, 22, 18, 14, 10, 8, 6 }, -- per caster (saved terrain is forever)
	},

	-- Conjure things: what appears in the area, for a while.
	things = {
		seconds = { 30, 40, 50, 60, 80, 100, 130, 180 },
		count = { 3, 4, 5, 6, 8, 10, 12, 16 }, -- trees, lights, spires, boulders (x2 for lights)
		fires = { 2, 3, 3, 4, 5, 6, 7, 9 },
		radius = { 8, 10, 12, 14, 17, 20, 24, 30 },
		maxParts = 160, -- one cast
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
