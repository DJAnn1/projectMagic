--!strict
--[[
	SenseSight data: what a Sense spell lets you SEE (docs/SenseSight.md). Shared, because the
	Composer's summary of a Sense spell (Data/RouteSummaries) names what it shows.

	A Sense spell whose property is listed under a kind shows that kind of hidden thing in the world,
	to the caster only, for a while. Every other property keeps the old one-line answer
	(Cast/Effects/Sense).

		heat     warm bodies (through walls), fires, lit lamps and hearths, hot and cold things
		metal    metal parts (through walls) and people wearing metal
		ley      the ley line seam along the ground, in its domain's colour, and a nearby nexus
		tracks   footprints of people and beasts in the last `tracks.keepSeconds`, fading with age

	journal  the first-person Journal line written the first time you see that kind (once, ever)
	found    the short line to the caster when something showed
	empty    the short line when nothing did (the spell still worked: there was nothing to see)
	summary  the Composer's "what it does"
]]

export type Kind = {
	properties: { string },
	summary: string,
	journal: string,
	found: string,
	empty: string,
}

local SenseSight = {}

SenseSight.kinds = {
	heat = {
		properties = { "temperature", "combustion" },
		summary = "For a while you see heat: warm bodies glow, even through walls, and so do fires, lit lamps and hot or frozen things. It touches nobody.",
		journal = "I reached for warmth and the world went dim around it. People burned like coals through the walls, and every fire stood out like a lantern in the dark.",
		found = "Warmth stands out around you.",
		empty = "You feel for warmth, but nothing near you is warmer than the air.",
	},
	metal = {
		properties = { "magnetism", "purity", "density" },
		summary = "For a while you see metal: iron in walls and doors and on people's backs, even where you can't see it. It touches nobody.",
		journal = "Metal answered me today. Iron in the walls, in the doors, on people's backs: I could feel every piece of it, even the ones out of sight.",
		found = "Metal stands out around you.",
		empty = "You feel for metal and find none close by.",
	},
	ley = {
		properties = { "aether", "presence" },
		summary = "For a while you see where magic runs: a ley line's seam along the ground, and a nexus if one is near. It touches nobody.",
		journal = "I felt for the magic itself and saw where it runs: a bright seam in the ground, flowing on further than I could follow.",
		found = "You see where the magic runs here.",
		empty = "No ley line runs near here.",
	},
	tracks = {
		properties = { "perception", "instinct", "memory", "age" },
		summary = "For a while you see fresh tracks: where people and beasts walked in the last minute or so, fading the older they are. It touches nobody.",
		journal = "The ground remembered who had walked on it. Their footsteps glowed behind them, fainter the older they were, and I could tell which way they'd gone.",
		found = "Fresh tracks stand out on the ground.",
		empty = "The ground here holds no fresh tracks.",
	},
} :: { [string]: Kind }

-- Order the admin tools and specs list them in.
SenseSight.order = { "heat", "metal", "ley", "tracks" }

-- How far (studs) and how long (seconds) you see, from the spell's power.
SenseSight.radius = { base = 24, perPower = 6, max = 90 }
SenseSight.duration = { base = 6, perPower = 1.5, max = 20 }

-- The most of each thing one reveal sends (and the client draws).
SenseSight.caps = {
	bodies = 24, -- warm or metal-wearing people and beasts
	spots = 40, -- fires, lamps, hot or cold parts
	metalParts = 40,
	leyLines = 8,
	nexuses = 3,
	prints = 160,
	queryParts = 400, -- parts scanned around the point (one GetPartBoundsInRadius)
}

SenseSight.heat = {
	hotAt = 45, -- °C: a part at least this hot shows as heat (ambient is 20)
	coldAt = 0, -- °C: a part at most this cold shows as cold
}

SenseSight.metal = {
	minWeight = 2, -- a person shows as wearing metal from this much worn metal weight
}

SenseSight.tracks = {
	sampleEvery = 1, -- seconds between samples of everyone's position (SenseService)
	minStep = 2.5, -- studs moved since the last print before a new one is left
	keepSeconds = 90, -- prints older than this are gone
	cell = 16, -- studs: the store's grid
	perCell = 40, -- the most prints one cell keeps (oldest dropped)
}

return SenseSight
