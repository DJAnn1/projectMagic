--!strict
--[[
	WildZones: permanent regions where the world's rules are broken, as data (docs/WildZones.md). Shared so
	the client can word them. Decisions: Server/World/WildZoneRules. Running: Services/WildZoneService.

	WHERE     Each zone is placed once from the world seed, so it's in the same place on every server.
	RULES     What a zone does to people in it:
	            gravity             multiples of normal gravity, always on
	            tide                the ground lets go on a clock: { every, lasts, mult, ceiling }
	            crawl               everyone moves slowly, creatures too (the zone_crawl status)
	            reservoirPerSecond  share of your max reservoir refilled each second
	            burnsSwimmers       the water is on fire
	            healShare           share of your max health healed each second
	            fireSpread          fires burn and spread this much faster (FireSim.boost)
	MAGIC     What it does to spells, through the same facts every cast already reads (WorldStateService
	          modifiers): density (x), temperature, moisture, stormCharge and fuel (added), bias (x, per domain).
	IDS       Permanent: saves refer to them. A new zone goes at the end of `ids`.

	TUNING STATUS  Every number is a first guess. None has been played.
]]

local rgb = Color3.fromRGB

export type Tide = { every: number, lasts: number, mult: number, ceiling: number }
export type Harvest = { item: string, chance: number, min: number, max: number }

export type Zone = {
	id: string,
	name: string,
	rule: string, -- one line: what's different here
	arrive: string, -- what you notice when you walk in
	color: Color3,
	tint: Color3, -- how the world looks while you're inside
	radius: number,
	biomes: { string }, -- preferred ground, in no order; any land will do if none is free
	coast: boolean?, -- must be on the shore

	gravity: number?,
	tide: Tide?,
	crawl: boolean?,
	reservoirPerSecond: number?,
	burnsSwimmers: boolean?,
	healShare: number?,
	fireSpread: number?,

	density: number?,
	temperature: number?,
	moisture: number?,
	stormCharge: number?,
	fuel: number?,
	bias: { [string]: number }?,

	decor: string, -- how World/WildZoneBuilder dresses it
	heartLift: number?, -- how far above the ground its heart hangs
	creatures: { type: string, count: number }, -- what guards the heart
	harvest: { Harvest },
}

local zones: { [string]: Zone } = {
	vale = {
		id = "vale",
		name = "The Drifting Vale",
		rule = "Gravity has mostly given up here. Jump, and take your time coming down.",
		arrive = "Your stomach lifts. The stones above you aren't falling.",
		color = rgb(150, 190, 255),
		tint = rgb(226, 236, 255),
		radius = 130,
		biomes = { "skyreach", "mountains", "grasslands" },
		gravity = 0.3,
		bias = { gravity = 1.4, air = 1.2 },
		decor = "vale",
		heartLift = 44,
		creatures = { type = "gust_moth", count = 4 },
		harvest = {
			{ item = "quartz", chance = 1, min = 2, max = 4 },
			{ item = "reservoir_tonic", chance = 0.5, min = 1, max = 1 },
			{ item = "gravity_relic", chance = 0.04, min = 1, max = 1 },
		},
	},
	slowwood = {
		id = "slowwood",
		name = "The Slow Wood",
		rule = "Time crawls. You move slowly, but your magic has all the time in the world to refill.",
		arrive = "The leaves in front of you have stopped falling.",
		color = rgb(190, 225, 170),
		tint = rgb(232, 240, 214),
		radius = 120,
		biomes = { "deep_forest", "swamp", "grasslands" },
		crawl = true,
		reservoirPerSecond = 0.03,
		bias = { time = 1.4 },
		decor = "wood",
		creatures = { type = "mana_wisp", count = 4 },
		harvest = {
			{ item = "healing_draught", chance = 1, min = 1, max = 2 },
			{ item = "reservoir_tonic", chance = 0.7, min = 1, max = 2 },
			{ item = "time_relic", chance = 0.04, min = 1, max = 1 },
		},
	},
	shore = {
		id = "shore",
		name = "The Burning Shore",
		rule = "The water is on fire. Stay out of it, unless you like burning.",
		arrive = "The sea is burning, and nobody seems to be surprised but you.",
		color = rgb(255, 130, 60),
		tint = rgb(255, 226, 200),
		radius = 120,
		biomes = {},
		coast = true,
		burnsSwimmers = true,
		temperature = 0.35,
		fuel = 0.2,
		bias = { energy = 1.4, water = 0.6 },
		decor = "shore",
		creatures = { type = "ember_sprite", count = 4 },
		harvest = {
			{ item = "ember_essence", chance = 1, min = 1, max = 3 },
			{ item = "healing_draught", chance = 0.5, min = 1, max = 1 },
			{ item = "gravity_relic", chance = 0.02, min = 1, max = 1 },
		},
	},
	moor = {
		id = "moor",
		name = "The Tilting Moor",
		rule = "Every few seconds the ground lets go of you. Don't be under anything when it does.",
		arrive = "The stones here have all fallen upward at least once.",
		color = rgb(190, 170, 230),
		tint = rgb(232, 226, 245),
		radius = 125,
		biomes = { "tundra", "ruinlands", "grasslands" },
		tide = { every = 15, lasts = 2.5, mult = -0.1, ceiling = 45 },
		stormCharge = 0.2,
		bias = { space = 1.3, gravity = 1.3 },
		decor = "moor",
		creatures = { type = "glass_beetle", count = 3 },
		harvest = {
			{ item = "quartz", chance = 1, min = 2, max = 3 },
			{ item = "healing_draught", chance = 0.7, min = 1, max = 2 },
			{ item = "time_relic", chance = 0.02, min = 1, max = 1 },
			{ item = "gravity_relic", chance = 0.02, min = 1, max = 1 },
		},
	},
	hollow = {
		id = "hollow",
		name = "The Hushed Hollow",
		rule = "Magic nearly fails here. Spells come out thin, and your reservoir barely fills. Bring a weapon.",
		arrive = "It's very quiet. You reach for your magic, and there's hardly anything there.",
		color = rgb(120, 120, 140),
		tint = rgb(205, 205, 215),
		radius = 110,
		biomes = { "ruinlands", "badlands", "crystal_caverns" },
		density = 0.1,
		bias = { void = 1.5 },
		decor = "hollow",
		creatures = { type = "gloom_rat", count = 5 },
		harvest = {
			{ item = "ember_essence", chance = 0.6, min = 1, max = 2 },
			{ item = "reservoir_tonic", chance = 1, min = 2, max = 3 },
			{ item = "time_relic", chance = 0.03, min = 1, max = 1 },
		},
	},
	riot = {
		id = "riot",
		name = "The Verdant Riot",
		rule = "Everything grows here, including you: you heal as you stand. Fire loves it just as much.",
		arrive = "Something is growing up your leg. It's oddly pleasant.",
		color = rgb(110, 220, 120),
		tint = rgb(222, 245, 216),
		radius = 125,
		biomes = { "grasslands", "swamp", "deep_forest" },
		healShare = 0.015,
		fireSpread = 3,
		fuel = 0.4,
		moisture = 0.2,
		bias = { life = 1.5, energy = 1.1 },
		decor = "riot",
		creatures = { type = "mud_crawler", count = 4 },
		harvest = {
			{ item = "healing_draught", chance = 1, min = 2, max = 3 },
			{ item = "quartz", chance = 0.4, min = 1, max = 2 },
			{ item = "gravity_relic", chance = 0.02, min = 1, max = 1 },
		},
	},
}

local WildZones = {
	zones = zones,
	ids = { "vale", "slowwood", "shore", "moor", "hollow", "riot" },

	townClear = 170, -- studs between a zone's edge and a town's centre
	zoneGap = 220, -- studs between two zones' edges
	poiClear = 30, -- studs between a zone's edge and any other place, while there's room to be fussy
	maxSlope = 0.8,

	wakeMargin = 200, -- its landmarks exist once someone is this far past its edge...
	sleepMargin = 280, -- ...and go past this, so walking along the line doesn't churn parts
	creatureRespawn = 180, -- seconds before the heart's guards come back

	attuneXp = 200, -- the first time you ever touch a zone's heart. Once per zone, ever
	harvestSeconds = 86400, -- one harvest per zone per real day
}

return WildZones
