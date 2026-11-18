--!strict
--[[
	PlaceKinds: what a place in the wilds can have been (docs/WorldPlaces.md §2–§3). Pure data, read by
	Places/PlaceHistory. Server only: a place's history decides what's inside it, so it never goes
	to clients whole; people tell pieces of it.

	SITES      which POI types are places, their size ("site" or "deep"), and whether a stage has
	           built a body for them yet (`built`). A place nobody has built yet and that grants
	           nothing is held back from rumours (RumorService asks PlaceService:rumorable).
	DEEP       the eight kinds a deep place (a "dungeon" POI) can be, weighted by biome.
	BUILDERS   who made it, and what they leave behind.
	FATES      what happened to it, what it leaves behind, what you can see from outside.
	OCCUPANTS  who's there now.

	Every pick list is an ARRAY of { id, w } so a seeded pick is the same on every server (string-
	keyed tables have no promised order). Weights are relative.

	Words, not numbers: lines here are spoken by people later (rumours, letters), and townspeople
	don't say "84 years". `ages` turns years into a phrase.
]]

export type Pick = { id: string, w: number }

export type SiteDef = {
	size: string, -- "site" | "deep"
	kind: string?, -- a site's fixed kind (deep places roll one from DEEP)
	built: boolean, -- has a stage given it a body yet?
	builders: { Pick }?, -- sites: who made it
	fates: { Pick }?, -- sites: what happened
}

export type DeepDef = {
	id: string,
	label: string, -- what people call the kind: "an old mine works"
	biomes: { [string]: number }, -- biome -> weight (missing = 0)
	anywhere: number?, -- weight in biomes not listed
	nearTown: number?, -- extra weight when a town is within 700 studs
	dense: number?, -- extra weight scaled by magic density (0..2)
	builders: { Pick },
	fates: { Pick },
	names: { string }, -- patterns: {family} {first} {town} {word}
	words: { string }?, -- fills {word}
	depths: { number }, -- min, max
	rooms: { number }, -- min, max
	danger: number, -- 0..1 base
}

export type BuilderDef = {
	who: string, -- "miners from {town}"
	old: boolean?, -- ancient: nobody remembers them (ages 300+)
	leaves: { string }, -- belongings tags (PlaceLoot keys them, stage 1+)
	writes: boolean, -- leaves letters, ledgers or notes
}

export type FateDef = {
	says: { string }, -- "{name} burned"; one is picked
	leaves: { string },
	signs: { string }, -- what you see from outside
	danger: number,
	occupants: { Pick },
}

export type OccupantDef = {
	says: { string }, -- "", or "Wildborn sleep there now."
	signs: { string },
	danger: number,
}

local PlaceKinds = {}

-- ─── Sites (the existing POIs) ──────────────────────────────────────────────

PlaceKinds.sites = {
	dungeon = { size = "deep", built = false },
	ruined_library = {
		size = "site", kind = "library", built = false,
		builders = { { id = "scholars", w = 3 }, { id = "old_ones", w = 2 }, { id = "priests", w = 1 } },
		fates = { { id = "abandoned", w = 3 }, { id = "burned", w = 2 }, { id = "collapsed", w = 2 }, { id = "sealed", w = 1 } },
	},
	hermit_tower = {
		size = "site", kind = "tower", built = false,
		builders = { { id = "hermit", w = 5 }, { id = "mages", w = 1 } },
		fates = { { id = "standing", w = 3 }, { id = "abandoned", w = 2 }, { id = "burned", w = 1 }, { id = "accident", w = 2 } },
	},
	academy = {
		size = "site", kind = "academy", built = false,
		builders = { { id = "mages", w = 1 } },
		fates = { { id = "standing", w = 1 } },
	},
	mine = {
		size = "site", kind = "mine", built = false,
		builders = { { id = "miners", w = 1 } },
		fates = { { id = "working", w = 3 }, { id = "abandoned", w = 2 }, { id = "flooded", w = 1 }, { id = "collapsed", w = 1 } },
	},
	-- shrine_<domain> uses this entry (PlaceKinds.siteFor).
	shrine = {
		size = "site", kind = "shrine", built = false,
		builders = { { id = "priests", w = 3 }, { id = "old_ones", w = 2 } },
		fates = { { id = "tended", w = 3 }, { id = "forgotten", w = 2 } },
	},
} :: { [string]: SiteDef }

-- The site entry for a POI type, or nil if the POI isn't a place (towns, natural wonders, mythic sites).
function PlaceKinds.siteFor(poiType: string): SiteDef?
	if string.sub(poiType, 1, 7) == "shrine_" then
		return PlaceKinds.sites.shrine
	end
	return PlaceKinds.sites[poiType]
end

-- ─── Deep places ────────────────────────────────────────────────────────────

PlaceKinds.deep = {
	{
		id = "sunken_keep", label = "a sunken keep",
		biomes = { swamp = 5, deep_forest = 3 }, anywhere = 0.3,
		builders = { { id = "lord", w = 4 }, { id = "old_ones", w = 1 } },
		fates = { { id = "flooded", w = 4 }, { id = "abandoned", w = 1 }, { id = "overrun", w = 2 } },
		names = { "{family} Keep", "the drowned hall of {first}", "the old keep below {town}" },
		depths = { 2, 3 }, rooms = { 16, 26 }, danger = 0.45,
	},
	{
		id = "old_works", label = "an old mine works",
		biomes = { mountains = 5, badlands = 4, frostpeaks = 1 },
		builders = { { id = "miners", w = 5 }, { id = "smugglers", w = 1 } },
		fates = { { id = "flooded", w = 2 }, { id = "collapsed", w = 3 }, { id = "abandoned", w = 2 }, { id = "overrun", w = 2 } },
		names = { "the {family} works", "the old {town} mine", "{first}'s dig" },
		depths = { 2, 3 }, rooms = { 18, 30 }, danger = 0.4,
	},
	{
		id = "buried_temple", label = "a buried temple",
		biomes = { badlands = 2, ruinlands = 5, desert_dunes = 4, deep_forest = 1 }, anywhere = 0.2,
		builders = { { id = "old_ones", w = 4 }, { id = "priests", w = 2 } },
		fates = { { id = "sealed", w = 4 }, { id = "abandoned", w = 2 }, { id = "collapsed", w = 1 } },
		names = { "the {word} temple", "the temple under the {word} hill", "the house of the {word} god" },
		words = { "nameless", "sunken", "ash", "hollow", "silent", "broken", "old" },
		depths = { 2, 3 }, rooms = { 15, 24 }, danger = 0.55,
	},
	{
		id = "warren", label = "a Wildborn warren",
		biomes = { mountains = 1, badlands = 1, swamp = 2, deep_forest = 2, frostpeaks = 1, volcanic_highlands = 2 }, anywhere = 0.5,
		builders = { { id = "wildborn", w = 1 } },
		fates = { { id = "grown", w = 1 } },
		names = { "the {word} warren", "the hole the {word} ones dug" },
		words = { "deep", "crooked", "black", "breathing", "bone", "root" },
		depths = { 2, 3 }, rooms = { 15, 22 }, danger = 0.65,
	},
	{
		id = "failed_academy", label = "a sealed academy",
		biomes = {}, anywhere = 0.6, dense = 2.5,
		builders = { { id = "mages", w = 1 } },
		fates = { { id = "accident", w = 4 }, { id = "sealed", w = 2 } },
		names = { "the {family} college", "the sealed school of {first}", "the {town} academy" },
		depths = { 2, 3 }, rooms = { 18, 28 }, danger = 0.6,
	},
	{
		id = "cistern", label = "an old cistern",
		biomes = { swamp = 1, deep_forest = 0.5, badlands = 0.5 }, anywhere = 0.2, nearTown = 3,
		builders = { { id = "engineers", w = 4 }, { id = "old_ones", w = 1 } },
		fates = { { id = "abandoned", w = 2 }, { id = "flooded", w = 2 }, { id = "overrun", w = 3 } },
		names = { "the {town} cistern", "the old waterworks under {town}", "{family}'s cistern" },
		depths = { 2, 2 }, rooms = { 15, 22 }, danger = 0.35,
	},
	{
		id = "ice_hall", label = "an ice hall",
		biomes = { frostpeaks = 6, mountains = 0.5 },
		builders = { { id = "lord", w = 2 }, { id = "old_ones", w = 2 }, { id = "mages", w = 1 } },
		fates = { { id = "frozen", w = 5 }, { id = "sealed", w = 1 } },
		names = { "{family}'s ice hall", "the frozen hall of {first}", "the {word} hall" },
		words = { "white", "still", "glass", "silent", "long" },
		depths = { 2, 3 }, rooms = { 15, 24 }, danger = 0.5,
	},
	{
		id = "vent_forge", label = "a forge in the vents",
		biomes = { volcanic_highlands = 6, badlands = 0.5 },
		builders = { { id = "smiths", w = 4 }, { id = "old_ones", w = 1 } },
		fates = { { id = "abandoned", w = 2 }, { id = "burned", w = 2 }, { id = "overrun", w = 2 } },
		names = { "the {family} forge", "the deep forge of {first}", "the {word} forge" },
		words = { "red", "ash", "black", "old", "burning" },
		depths = { 2, 3 }, rooms = { 16, 26 }, danger = 0.55,
	},
} :: { DeepDef }

PlaceKinds.deepById = {} :: { [string]: DeepDef }
for _, def in PlaceKinds.deep do
	PlaceKinds.deepById[def.id] = def
end

-- Site names, by site kind (deep places name themselves in DEEP).
PlaceKinds.siteNames = {
	library = { "the {family} library", "the old library of {first}", "the {word} library" },
	tower = { "{first}'s tower", "the {word} tower", "the tower on the {town} road" },
	academy = { "the {family} academy", "the {town} academy" },
	mine = { "the {family} mine", "the {town} mine", "{first}'s mine" },
	shrine = { "the {word} shrine" },
} :: { [string]: { string } }

PlaceKinds.siteWords = {
	library = { "burned", "quiet", "high", "forgotten", "old" },
	tower = { "leaning", "grey", "lonely", "split", "tall" },
	shrine = { "old", "worn", "mossy", "quiet", "hill" },
} :: { [string]: { string } }

-- ─── Builders ───────────────────────────────────────────────────────────────

PlaceKinds.builders = {
	miners = { who = "miners out of {town}", leaves = { "tools", "ore", "lamps", "provisions" }, writes = true },
	lord = { who = "the {family} family", leaves = { "coin", "arms", "plate", "seal" }, writes = true },
	priests = { who = "an order of priests", leaves = { "candles", "relics", "scripture" }, writes = true },
	mages = { who = "mages of the {family} line", leaves = { "treatises", "foci", "reagents", "spell_pages" }, writes = true },
	scholars = { who = "scholars from {town}", leaves = { "books", "treatises", "ink" }, writes = true },
	hermit = { who = "a hermit called {first}", leaves = { "notes", "focus", "herbs" }, writes = true },
	smugglers = { who = "smugglers working the {town} road", leaves = { "coin", "contraband", "maps" }, writes = true },
	engineers = { who = "the waterworks of {town}", leaves = { "tools", "pipes", "ledgers" }, writes = true },
	smiths = { who = "smiths of the {family} line", leaves = { "tools", "ingots", "arms" }, writes = true },
	old_ones = { who = "people nobody remembers", old = true, leaves = { "carvings", "old_coin", "sealed_things" }, writes = false },
	wildborn = { who = "nobody: the land made it", old = false, leaves = { "bones", "trophies" }, writes = false },
} :: { [string]: BuilderDef }

-- ─── Fates ──────────────────────────────────────────────────────────────────

local NOBODY = { { id = "nobody", w = 1 } }

PlaceKinds.fates = {
	standing = {
		says = { "It's still in use." }, leaves = {}, signs = { "smoke from a chimney", "a lit window" }, danger = -0.3,
		occupants = { { id = "keepers", w = 1 } },
	},
	working = {
		says = { "They still work it." }, leaves = {}, signs = { "carts by the mouth", "fresh spoil heaps" }, danger = -0.3,
		occupants = { { id = "keepers", w = 1 } },
	},
	tended = {
		says = { "Someone still tends it." }, leaves = {}, signs = { "fresh offerings", "a swept path" }, danger = -0.3,
		occupants = NOBODY,
	},
	forgotten = {
		says = { "Nobody tends it any more." }, leaves = { "moss" }, signs = { "moss on the steps", "a path gone to grass" }, danger = -0.1,
		occupants = { { id = "nobody", w = 4 }, { id = "creatures", w = 1 } },
	},
	abandoned = {
		says = { "They left it and never came back.", "It was left when the work ran out." },
		leaves = { "dust" }, signs = { "a door hanging open", "grass in the doorway" }, danger = 0,
		occupants = { { id = "nobody", w = 2 }, { id = "creatures", w = 3 }, { id = "robbers", w = 2 }, { id = "wildborn", w = 1 } },
	},
	burned = {
		says = { "It burned one night and the fire took everyone who was in it.", "It burned, and nobody rebuilt it." },
		leaves = { "scorched", "ash" }, signs = { "old scorch marks", "a blackened roof" }, danger = 0.05,
		occupants = { { id = "nobody", w = 1 }, { id = "wildborn", w = 2 }, { id = "creatures", w = 1 } },
	},
	flooded = {
		says = { "The water came up and the lower halls drowned.", "A spring broke through and flooded it." },
		leaves = { "silt", "drowned_lamps" }, signs = { "water running out of the entrance", "the smell of standing water" }, danger = 0.1,
		occupants = { { id = "creatures", w = 3 }, { id = "nobody", w = 1 }, { id = "wildborn", w = 1 } },
	},
	collapsed = {
		says = { "A quake brought the roof down on it.", "Part of it fell in, and nobody dug them out." },
		leaves = { "rubble", "remains" }, signs = { "fallen stone around the mouth", "a split in the hillside" }, danger = 0.1,
		occupants = { { id = "nobody", w = 2 }, { id = "creatures", w = 2 }, { id = "wildborn", w = 1 } },
	},
	overrun = {
		says = { "Something moved in and the people who lived there didn't get out.", "It was overrun." },
		leaves = { "remains", "claw_marks" }, signs = { "bones by the entrance", "claw marks on the stone" }, danger = 0.2,
		occupants = { { id = "wildborn", w = 3 }, { id = "creatures", w = 2 } },
	},
	sealed = {
		says = { "They sealed it themselves, from outside.", "Someone walled it up and left a warning." },
		leaves = { "seals", "warnings" }, signs = { "a walled-up door", "a warning cut into the stone" }, danger = 0.2,
		occupants = { { id = "ward", w = 3 }, { id = "wildborn", w = 1 }, { id = "ferals", w = 1 } },
	},
	accident = {
		says = { "A working went wrong inside, and nobody came out.", "Something they were casting got loose." },
		leaves = { "scorched", "broken_foci", "spell_pages" }, signs = { "air that hums", "lights in the windows at night" }, danger = 0.25,
		occupants = { { id = "ferals", w = 3 }, { id = "ward", w = 2 }, { id = "nobody", w = 1 } },
	},
	frozen = {
		says = { "The cold took it all at once, one winter.", "It froze, with everyone still in it." },
		leaves = { "frozen", "remains" }, signs = { "cold air breathing out of it", "ice on the stones in summer" }, danger = 0.15,
		occupants = { { id = "wildborn", w = 2 }, { id = "ward", w = 1 }, { id = "nobody", w = 1 } },
	},
	grown = {
		says = { "Nobody built it. It grew, the way the Wildborn grow." },
		leaves = { "bones", "trophies" }, signs = { "bones outside", "trampled ground", "a smell like a den" }, danger = 0.15,
		occupants = { { id = "wildborn", w = 1 } },
	},
} :: { [string]: FateDef }

-- ─── Occupants ──────────────────────────────────────────────────────────────

PlaceKinds.occupants = {
	nobody = { says = { "Nothing lives there now." }, signs = {}, danger = -0.15 },
	keepers = { says = { "People still live and work there." }, signs = {}, danger = -0.3 },
	creatures = { says = { "Animals have made a den of it." }, signs = { "tracks going in and out" }, danger = 0 },
	wildborn = { says = { "Wildborn sleep there now.", "Wildborn hold it now." }, signs = { "a Wildborn shape at the entrance at dusk" }, danger = 0.2 },
	robbers = { says = { "Robbers use it now." }, signs = { "a fresh fire pit", "boot prints" }, danger = 0.05 },
	ward = { says = { "Something they left behind still guards it." }, signs = { "a glow behind the stones" }, danger = 0.15 },
	ferals = { says = { "What got loose is still in there." }, signs = { "a light moving where nobody walks" }, danger = 0.2 },
} :: { [string]: OccupantDef }

-- ─── Ages ───────────────────────────────────────────────────────────────────

-- Years ago -> a phrase people would say. In order: the first band whose `upTo` covers it.
PlaceKinds.ages = {
	{ upTo = 12, says = "not long ago" },
	{ upTo = 40, says = "in my parents' day" },
	{ upTo = 90, says = "in my grandparents' time" },
	{ upTo = 250, says = "long before anyone living was born" },
	{ upTo = math.huge, says = "before anyone kept records" },
}

PlaceKinds.ageRange = { recent = { 3, 160 }, old = { 300, 1200 } }

return PlaceKinds
