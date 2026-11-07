--!strict
--[[
	FeralData: the numbers, bodies and words for feral spells (docs/FeralSpells.md). Every number is a first
	guess. Server only: clients never need any of this, because a feral spell has no interface.

	FIELDS
		styles   how each domain comes apart: no shell or outline, just loose pieces, in that domain's
		         character. Each loose spell's pieces are seeded, so no two look quite the same
		effects  what it does beyond damage, by domain. status and seconds land on whoever it hits. push
		         throws them back. ground is what it does to the land as it passes: burn sets fire to
		         what can burn (never saved), quench puts fires out
		shouts   what townsfolk call out when one comes near
		memories what people say when asked for rumours, about a loose spell they remember. you is said
		         to the person it's about, known by someone who saw it, heard by someone who was told
		words    what people call it, by domain. In their words and the Journal: nothing floats over it
		rumors   what people say about one. %s are who lost it, and where it was seen
]]

export type Style = {
	count: number, -- pieces
	spread: Vector3, -- how far out they scatter
	size: { number }, -- min, max
	stretch: Vector3, -- leaves are flat, slivers are long
	shape: string, -- "Ball" | "Block"
	motion: string, -- tumble | swirl | flicker (Fx/FamiliarAnimator)
	amount: number, -- how far each piece wanders
	speed: { number }, -- min, max
	glowShare: number, -- share of the pieces that are Neon
	alpha: { number }, -- min, max transparency
	material: string?,
	dark: boolean?,
}

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

	-- The world's response. Only NPCs with a full body near a player, the same as any NPC fight.
	guardRadius = 70, -- guards and hunters come for it from this far
	fleeRadius = 30, -- everyone else gets away from it
	shoutChance = 0.35,
	shoutRadius = 60,
	trailSeconds = 2, -- how often it marks the ground it's passing
	trailHeat = 0.7, -- how fierce the fires it starts are
	quenchRadius = 16,
	dotShare = 0.2, -- burning and the like, per tick, as a share of the hit
	provokedSeconds = 10, -- once hurt, it lashes out at anything within `reach`, not just `notice`

	-- What people remember, and what it costs. Nothing here is a crime: it was an accident.
	witnessRadius = 70, -- saw it get loose, or saw it brought down
	blamePerHit = -2, -- standing in that person's town, when your loose spell hurts them...
	blameMax = 3, -- ...for this many hits per loose spell
	thanks = 3, -- standing, for bringing one down with people watching
	thanksOwn = 1, -- when it was yours to begin with
	rememberedStrength = 0.05, -- below this, they've all but forgotten

	-- What it leaves
	creditShare = 0.2, -- of its health dealt, to have understood anything from it
	xpPerPower = 14,
	studiedMax = 60, -- saved recipe keys, oldest dropped

	-- Rumours
	rumorChance = 0.6,
	rumorRadius = 1100, -- people only talk about what's near enough to worry them
}

-- rgbs come from the domain's palette, except `dark`, which uses near-black instead.
FeralData.styles = {
	energy = { count = 11, spread = Vector3.new(1.5, 1.8, 1.5), size = { 0.2, 0.6 }, stretch = Vector3.new(0.5, 1.4, 0.5), shape = "Ball", motion = "flicker", amount = 0.45, speed = { 2.5, 5 }, glowShare = 0.8, alpha = { 0, 0.25 } },
	earth = { count = 9, spread = Vector3.new(1.5, 1.2, 1.5), size = { 0.35, 0.95 }, stretch = Vector3.new(1, 0.8, 1.1), shape = "Block", motion = "tumble", amount = 0.3, speed = { 0.4, 1.1 }, glowShare = 0, alpha = { 0, 0 }, material = "Slate" },
	water = { count = 10, spread = Vector3.new(1.4, 1.4, 1.4), size = { 0.35, 0.85 }, stretch = Vector3.new(1, 1.15, 1), shape = "Ball", motion = "swirl", amount = 0, speed = { 0.7, 1.5 }, glowShare = 0, alpha = { 0.25, 0.5 } },
	air = { count = 12, spread = Vector3.new(1.9, 1, 1.9), size = { 0.3, 0.7 }, stretch = Vector3.new(2.6, 0.14, 0.4), shape = "Ball", motion = "swirl", amount = 0, speed = { 1.5, 3.2 }, glowShare = 0, alpha = { 0.45, 0.75 } },
	life = { count = 12, spread = Vector3.new(1.5, 1.5, 1.5), size = { 0.25, 0.6 }, stretch = Vector3.new(1.3, 0.2, 0.8), shape = "Ball", motion = "tumble", amount = 0.35, speed = { 0.5, 1.4 }, glowShare = 0.1, alpha = { 0, 0.15 } },
	mind = { count = 7, spread = Vector3.new(1.1, 1.5, 1.1), size = { 0.8, 1.7 }, stretch = Vector3.new(1, 1, 0.06), shape = "Ball", motion = "tumble", amount = 0.2, speed = { 0.5, 1.2 }, glowShare = 0.3, alpha = { 0.35, 0.65 } },
	spirit = { count = 10, spread = Vector3.new(1.2, 2, 1.2), size = { 0.3, 0.7 }, stretch = Vector3.new(0.6, 1.7, 0.6), shape = "Ball", motion = "flicker", amount = 0.6, speed = { 0.7, 1.4 }, glowShare = 0.2, alpha = { 0.45, 0.7 } },
	void = { count = 10, spread = Vector3.new(1.4, 1.4, 1.4), size = { 0.25, 0.8 }, stretch = Vector3.new(0.35, 1.5, 0.35), shape = "Block", motion = "tumble", amount = 0.4, speed = { 0.3, 0.9 }, glowShare = 0.12, alpha = { 0, 0.2 }, dark = true },
	space = { count = 7, spread = Vector3.new(1.3, 1.3, 1.3), size = { 0.8, 1.6 }, stretch = Vector3.new(1, 1, 0.05), shape = "Block", motion = "flicker", amount = 0.7, speed = { 1, 2.5 }, glowShare = 0.25, alpha = { 0.3, 0.6 } },
	time = { count = 8, spread = Vector3.new(1.7, 0.5, 1.7), size = { 0.3, 0.9 }, stretch = Vector3.new(0.16, 0.1, 1.5), shape = "Block", motion = "swirl", amount = 0, speed = { 0.25, 1.4 }, glowShare = 0.4, alpha = { 0, 0.2 } },
	gravity = { count = 9, spread = Vector3.new(1.3, 0.8, 1.3), size = { 0.3, 0.85 }, stretch = Vector3.new(1, 1, 1), shape = "Block", motion = "swirl", amount = 0, speed = { 0.8, 1.8 }, glowShare = 0.1, alpha = { 0, 0 }, dark = true, material = "Basalt" },
	reality = { count = 10, spread = Vector3.new(1.5, 1.5, 1.5), size = { 0.25, 0.9 }, stretch = Vector3.new(1, 1, 1), shape = "Block", motion = "flicker", amount = 0.5, speed = { 0.5, 3 }, glowShare = 0.5, alpha = { 0, 0.4 } },
} :: { [string]: Style }

FeralData.coreSize = 0.55 -- a small bright centre, called Head because the rest of the game looks for one
FeralData.unstableSteps = 10 -- how finely the look follows its energy: fewer means less replication

-- Forms that land everywhere at once; the rest go at one target.
FeralData.areaForms = { burst = true, aura = true, zone = true, pillar = true, summon = true, ritual = true, wall = true } :: { [string]: boolean }
FeralData.maxAreaTargets = 6

FeralData.effects = {
	energy = { status = "burning", seconds = 3, ground = "burn" },
	earth = { status = "slow", seconds = 3 },
	water = { status = "slow", seconds = 2.5, ground = "quench" },
	air = { push = 55 },
	life = { status = "rot", seconds = 4 },
	mind = { status = "dazed", seconds = 3 },
	spirit = { status = "fear", seconds = 3 },
	void = { status = "hexed", seconds = 4 },
	space = { status = "slow", seconds = 2 },
	time = { status = "time_slow", seconds = 2.5 },
	gravity = { status = "root", seconds = 1.2 },
	reality = { status = "jinxed", seconds = 5 },
} :: { [string]: { status: string?, seconds: number?, push: number?, ground: string? } }

FeralData.shouts = {
	fight = {
		"Back! Everyone get back from it!",
		"Don't use magic near it! It comes to magic!",
		"It's loose in the street. Spread out!",
	},
	flee = {
		"Run! There's one of those things!",
		"Get inside!",
		"Whose is that?! Somebody stop it!",
	},
} :: { [string]: { string } }

FeralData.memories = {
	lost_control = {
		you = "You know what they say about you here. That spell of yours, the one that got away.",
		known = "I saw it myself. %s lost hold of a spell, right here, and it just went.",
		heard = "They say %s lost hold of a spell round here. Got clean away from them.",
	},
	spell_hurt_me = {
		you = "I still feel where your spell caught me. I don't suppose you meant it.",
		known = "That loose spell of %s's caught me. I've still got the marks.",
		heard = "Someone got hurt by a loose spell, one of %s's, they say.",
	},
	ended_it = {
		you = "People remember you brought down that loose spell.",
		known = "I watched %s bring down one of those loose spells. Good thing someone did.",
		heard = "They say %s brought down a loose spell near here, and nobody asked them to.",
	},
	cleaned_up = {
		you = "It was yours, that spell, but you did go after it. That counts for something.",
		known = "%s went after their own loose spell and finished it. Fair's fair.",
		heard = "They say %s put down their own loose spell. Better than leaving it.",
	},
} :: { [string]: { you: string, known: string, heard: string } }

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
