--!strict
--[[
	FeralData: the numbers, bodies and words for feral spells (docs/FeralSpells.md). Every number is a first
	guess. Server only: clients never need any of this, because a feral spell has no interface.

	FIELDS
		bodies   what a loose spell looks like, by the shape of the spell that escaped. Part slots:
		         core (the domain's darkest bright colour, Neon), body, haze (see-through)
		forms    which body each spell form becomes
		words    what it's called, by domain. Plain, like something a person would say
		rumors   what people say about one. %s are who lost it, and where it was seen
]]

export type Part = { name: string, shape: string, size: Vector3, offset: Vector3, slot: string, transparency: number? }

local FeralData = {}

FeralData.tuning = {
	-- Getting loose. A backfire must already have been a loss of control (CastTuning.controlLossPower).
	escapeBase = 0.25,
	escapePerSeverity = 0.2, -- per point of severity above 1
	escapeMin = 0.1,
	escapeMax = 0.7,
	perCasterCooldown = 240, -- seconds: a mage who keeps failing doesn't fill the island
	maxAlive = 6, -- flag feral_spells_max
	maxPerCaster = 1,

	-- NPC mages have accidents too, so this happens on an empty server as well.
	accidentSeconds = 1500, -- one chance per slot of this long, on every server alike
	accidentChance = 0.6,
	accidentMinTier = 2,

	-- Energy: a loose spell is running out from the moment it escapes.
	energyBase = 600, -- seconds
	energyPerPower = 150,
	drainThick = 0.4, -- how fast it drains where ley energy is densest...
	drainThin = 1.6, -- ...and where there's almost none
	densityLow = 0.2,
	densityHigh = 0.8,

	-- Its body
	healthBase = 30,
	healthPerPower = 28,
	walk = 9,
	sizeBase = 0.8,
	sizePerPower = 0.1,
	hover = 3,
	ownResist = 0.5, -- its own domain barely touches it
	opposedWeakness = -0.3, -- the domain's opposites hurt it more: water on fire

	-- Moving
	stepSeconds = 0.25,
	wanderSeconds = 6, -- a new direction this often
	sampleDistance = 50, -- how far ahead it feels for ley energy
	densityWeight = 4, -- how strongly energy pulls it
	wakeRadius = 180, -- gets a body when someone is this close and the ground is built
	sleepRadius = 240, -- loses it past this
	drawnRadius = 90, -- it turns towards magic cast this close
	drawnSeconds = 10,
	seaMargin = 1,

	-- Fighting. It isn't a hunter: it discharges at whatever's near, or whoever hit it.
	reach = 34,
	notice = 22, -- what comes this close gets discharged at, unprovoked
	castEvery = 3.2,
	hitShare = 0.5, -- of a full hit from the spell it was
	graceSeconds = 4, -- the moment it escapes, it's busy getting away
	attackerMemory = 12,
	fadeSeconds = 1.4,

	-- What it leaves
	creditShare = 0.2, -- of its health dealt, to have understood anything from it
	xpPerPower = 14,
	studiedMax = 60, -- saved recipe keys, oldest dropped

	-- Rumours
	rumorChance = 0.6,
	rumorRadius = 1100, -- people only talk about what's near enough to worry them
}

FeralData.bodies = {
	-- Touch, projectile and chain: a small hard spark of the thing.
	spark = {
		{ name = "Head", shape = "Ball", size = Vector3.new(1.1, 1.1, 1.1), offset = Vector3.zero, slot = "core" },
		{ name = "Shell", shape = "Ball", size = Vector3.new(1.9, 1.9, 1.9), offset = Vector3.zero, slot = "body", transparency = 0.45 },
		{ name = "Haze", shape = "Ball", size = Vector3.new(3.2, 3.2, 3.2), offset = Vector3.zero, slot = "haze", transparency = 0.82 },
		{ name = "ShardA", shape = "Ball", size = Vector3.new(0.45, 0.45, 1.1), offset = Vector3.new(1.3, 0.3, 0.2), slot = "body" },
		{ name = "ShardB", shape = "Ball", size = Vector3.new(0.4, 1, 0.4), offset = Vector3.new(-1.1, -0.45, -0.5), slot = "body" },
		{ name = "ShardC", shape = "Ball", size = Vector3.new(0.9, 0.35, 0.35), offset = Vector3.new(0.1, 1.15, 0.8), slot = "core" },
	},
	-- Burst, aura and zone: a loose churning mass.
	mass = {
		{ name = "Head", shape = "Ball", size = Vector3.new(1.5, 1.3, 1.5), offset = Vector3.new(0, 0.25, 0), slot = "core" },
		{ name = "LobeA", shape = "Ball", size = Vector3.new(2, 1.5, 1.7), offset = Vector3.new(0.75, -0.2, 0.3), slot = "body", transparency = 0.3 },
		{ name = "LobeB", shape = "Ball", size = Vector3.new(1.7, 1.6, 2), offset = Vector3.new(-0.7, 0, -0.4), slot = "body", transparency = 0.35 },
		{ name = "LobeC", shape = "Ball", size = Vector3.new(1.4, 1.2, 1.4), offset = Vector3.new(0.1, 0.8, -0.7), slot = "body", transparency = 0.4 },
		{ name = "Haze", shape = "Ball", size = Vector3.new(4.4, 3.6, 4.4), offset = Vector3.zero, slot = "haze", transparency = 0.85 },
	},
	-- Beam, wall and pillar: tall and thin, hard to look at straight on.
	column = {
		{ name = "Head", shape = "Ball", size = Vector3.new(0.8, 1, 0.8), offset = Vector3.new(0, 1.6, 0), slot = "core" },
		{ name = "Spine", shape = "Ball", size = Vector3.new(0.8, 3.4, 0.8), offset = Vector3.zero, slot = "core" },
		{ name = "Shell", shape = "Ball", size = Vector3.new(1.5, 4, 1.5), offset = Vector3.zero, slot = "body", transparency = 0.5 },
		{ name = "Haze", shape = "Ball", size = Vector3.new(2.7, 5, 2.7), offset = Vector3.zero, slot = "haze", transparency = 0.84 },
	},
	-- Summon and ritual: rings of something that nearly forms a shape.
	knot = {
		{ name = "Head", shape = "Ball", size = Vector3.new(1, 1, 1), offset = Vector3.zero, slot = "core" },
		{ name = "RingA", shape = "Ball", size = Vector3.new(3, 0.25, 3), offset = Vector3.zero, slot = "body", transparency = 0.25 },
		{ name = "RingB", shape = "Ball", size = Vector3.new(0.25, 3, 3), offset = Vector3.zero, slot = "body", transparency = 0.3 },
		{ name = "RingC", shape = "Ball", size = Vector3.new(3, 3, 0.25), offset = Vector3.zero, slot = "body", transparency = 0.35 },
		{ name = "Haze", shape = "Ball", size = Vector3.new(3.8, 3.8, 3.8), offset = Vector3.zero, slot = "haze", transparency = 0.86 },
	},
} :: { [string]: { Part } }

FeralData.forms = {
	touch = "spark", projectile = "spark", chain = "spark",
	burst = "mass", aura = "mass", zone = "mass",
	beam = "column", wall = "column", pillar = "column",
	summon = "knot", ritual = "knot",
} :: { [string]: string }

FeralData.defaultBody = "spark"

-- Forms that land everywhere at once; the rest go at one target.
FeralData.areaForms = { burst = true, aura = true, zone = true, pillar = true, summon = true, ritual = true, wall = true } :: { [string]: boolean }
FeralData.maxAreaTargets = 6

FeralData.words = {
	energy = "Stray Ember",
	earth = "Loose Stone",
	water = "Wandering Tide",
	air = "Lost Gust",
	life = "Runaway Growth",
	mind = "Stray Thought",
	spirit = "Unquiet Working",
	void = "Hollow Wisp",
	space = "Misplaced Fold",
	time = "Lost Moment",
	gravity = "Stray Weight",
	reality = "Small Wrongness",
} :: { [string]: string }

FeralData.rumors = {
	player = {
		"%s lost hold of a spell, %s of here. It didn't go out. They say it's still moving about.",
		"Word is someone called %s let a working get away from them, somewhere %s. Keep your own magic quiet if you go that way.",
	},
	npc = {
		"%s lost hold of a working, and it got clean away. Last seen %s of here. Nobody's keen to go and look.",
		"You heard about %s? A spell slipped loose, and it went off %s. They say it comes to you if you use your magic near it.",
	},
}

return table.freeze(FeralData)
