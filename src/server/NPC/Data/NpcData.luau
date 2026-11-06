--!strict
--[[
	NpcData: everything NPCFactory draws from. Pure data; add entries freely (ids are permanent
	once NPCs exist: renaming an occupation id changes who those NPCs are).

	Personality: Big Five + eight custom traits, every one 0..1 (0.5 = average). Drawn as the mean
	of three uniforms (a soft bell curve), then shifted by culture, age band and occupation.
	Districts: where things happen inside a settlement (ScheduleService places them around the
	settlement centre). Work recipes: what a profession's magic looks like when an NPC near a
	player is working (they must actually know the branch, or they work by hand).
]]

local NpcData = {}

NpcData.bigFive = { "openness", "conscientiousness", "extraversion", "agreeableness", "neuroticism" }
NpcData.custom = { "ambition", "curiosity", "pride", "loyalty", "greed", "compassion", "humor", "patience" }

-- What each trait does, for the design doc and the inspector.
NpcData.traitEffects = {
	openness = "Study and wandering appeal; invents techniques; tolerates strange magic",
	conscientiousness = "Keeps to schedule; works longer; steady study habit",
	extraversion = "Social need decays faster; seeks taverns and markets; talks more",
	agreeableness = "Warmer first impressions; forgives faster; curt and blunt when low",
	neuroticism = "Safety weighs more; flees sooner; negative memories hit harder",
	ambition = "Purpose decays faster; studies toward the Life Ambition; risks backlash",
	curiosity = "Explores; asks questions; drawn to rumours and new magic",
	pride = "Rivalries and duels; slow to accept teaching; resents slights",
	loyalty = "Family and mentor bonds strengthen; trust is sticky once earned",
	greed = "Wealth weighs more; trades and works late; may sell secrets",
	compassion = "Helps the hurt; teaches; heals; will not chase cruel magic",
	humor = "Jokes in dialogue; cheers others up when socialising",
	patience = "Long study sessions; calmer under insult; better teacher",
}

-- Culture shifts (added to drawn traits, then clamped).
NpcData.cultureShift = {
	forgehold = { conscientiousness = 0.12, pride = 0.1, greed = 0.05, openness = -0.05 },
	tidecall = { loyalty = 0.1, patience = 0.1, neuroticism = 0.05 },
	loreseat = { openness = 0.15, curiosity = 0.15, extraversion = -0.08 },
	verdant = { compassion = 0.12, agreeableness = 0.1, greed = -0.1 },
	emberclan = { pride = 0.15, extraversion = 0.08, patience = -0.1 },
	skywarden = { curiosity = 0.1, ambition = 0.08, loyalty = 0.05 },
	frostfolk = { patience = 0.12, loyalty = 0.1, extraversion = -0.1 },
	wayfarer = { extraversion = 0.12, openness = 0.08, greed = 0.08, loyalty = -0.05 },
} :: { [string]: { [string]: number } }

-- Age bands: age shifts (applied by NPCFactory).
NpcData.ageBands = {
	{ min = 6, max = 13, label = "child", shift = { curiosity = 0.15, patience = -0.15, neuroticism = 0.05 } },
	{ min = 14, max = 24, label = "young", shift = { ambition = 0.1, openness = 0.05, patience = -0.05 } },
	{ min = 25, max = 54, label = "adult", shift = {} },
	{ min = 55, max = 90, label = "elder", shift = { patience = 0.12, openness = -0.08, neuroticism = -0.05, ambition = -0.1 } },
}

-- ─── Names ──────────────────────────────────────────────────────────────────

NpcData.names = {
	forgehold = { first = { "Bran", "Hed", "Torv", "Ama", "Kel", "Dur", "Mag", "Sig" }, firstEnd = { "noc", "rik", "da", "a", "wen", "ra", "ol", "rid" }, family = { "Ironwell", "Ashhand", "Coalbrook", "Hammerson", "Brightforge", "Stonebell" } },
	tidecall = { first = { "Mar", "Sel", "Cor", "Isa", "Neri", "Lio", "Tam", "Oda" }, firstEnd = { "en", "ine", "al", "bel", "o", "ra", "is", "le" }, family = { "Saltmere", "Tidewright", "Gullcrest", "Deepwater", "Shellward", "Brine" } },
	loreseat = { first = { "Al", "Ver", "Ith", "Cael", "Orm", "Lys", "Eld", "Mir" }, firstEnd = { "aric", "enne", "ias", "us", "a", "andra", "rin", "o" }, family = { "Quillfast", "Inkwell", "Vellum", "Starcount", "Ledger", "Archive" } },
	verdant = { first = { "Fen", "Wil", "Ros", "Ash", "Bri", "Hol", "Lin", "Ivy" }, firstEnd = { "na", "low", "alind", "ling", "ar", "ly", "den", "ette" }, family = { "Greenbough", "Thornfield", "Mossbank", "Willowmere", "Rootwell", "Fernhollow" } },
	emberclan = { first = { "Kor", "Ras", "Vul", "Ena", "Tor", "Bra", "Ign", "Sha" }, firstEnd = { "rak", "ka", "an", "is", "ga", "zir", "en", "ra" }, family = { "Emberkin", "of the Red Ash", "Cinderborn", "Flameheart", "Scorchfoot", "Kilnclaw" } },
	skywarden = { first = { "Aer", "Cyr", "Ze", "Pel", "Sor", "Ila", "Fal", "Kes" }, firstEnd = { "in", "ra", "phyr", "ion", "en", "ane", "co", "tra" }, family = { "Highwind", "Cloudmere", "Stormwatch", "Featherfall", "Skyreach", "Updraft" } },
	frostfolk = { first = { "Hal", "Ing", "Sif", "Bjor", "Vey", "Ulf", "Ast", "Fri" }, firstEnd = { "var", "rid", "a", "n", "a", "ric", "a", "da" }, family = { "Frostmantle", "Snowdrift", "Icewater", "Coldhearth", "Whitepine", "Rimewall" } },
	wayfarer = { first = { "Jo", "Mae", "Dex", "Rin", "Tob", "Wren", "Cas", "Lu" }, firstEnd = { "nas", "ve", "ter", "a", "y", "", "sia", "ca" }, family = { "Roadwell", "Farwalk", "Crossway", "Milestone", "Lanternbearer", "Dusttrail" } },
} :: { [string]: { first: { string }, firstEnd: { string }, family: { string } } }

-- ─── Appearance ─────────────────────────────────────────────────────────────

NpcData.skinTones = {
	Color3.fromRGB(255, 220, 190), Color3.fromRGB(234, 192, 160), Color3.fromRGB(205, 160, 120),
	Color3.fromRGB(170, 120, 85), Color3.fromRGB(130, 90, 60), Color3.fromRGB(95, 65, 45),
}
NpcData.hair = { "black", "dark brown", "brown", "auburn", "red", "blond", "ash", "grey", "white" }
NpcData.builds = { "slight", "wiry", "average", "sturdy", "broad", "heavy" }
NpcData.features = {
	"a burn scar on one hand", "ink-stained fingers", "a crooked nose", "bright, restless eyes", "a missing tooth",
	"a braided beard", "freckles", "calloused palms", "a soft voice", "a booming laugh", "a limp",
	"salt-bleached hair", "a tattoo of a wave", "spectacles", "a silver earring", "soot in every crease",
}

-- ─── Occupations ────────────────────────────────────────────────────────────

export type Occupation = {
	name: string,
	district: string, -- where they work (ScheduleService)
	schedule: string, -- ScheduleService template id
	domains: { [string]: number }, -- domain -> weight when the factory biases their magic
	branches: { string }, -- preferred study branches (and their descendants)
	work: { branch: string, property: string, verb: string, form: string, power: number }?,
	wealth: number, -- wealth need restored per working hour
	cultures: { [string]: number }?, -- culture -> weight multiplier
	minAge: number,
	maxAge: number,
	relief: { string }?, -- world events this profession turns out for (EventDirector relief)
}

NpcData.occupations = {
	smith = { name = "Smith", district = "forge", schedule = "day", domains = { earth = 3, energy = 1.5 }, branches = { "metallurgy", "calefaction" },
		work = { branch = "metallurgy", property = "hardness", verb = "amplify", form = "touch", power = 2 }, wealth = 0.07, cultures = { forgehold = 4, emberclan = 2 }, minAge = 14, maxAge = 70 },
	miner = { name = "Miner", district = "mine", schedule = "day", domains = { earth = 3 }, branches = { "geomancy", "seismic" },
		work = { branch = "geomancy", property = "contour", verb = "reduce", form = "touch", power = 2 }, wealth = 0.06, cultures = { forgehold = 3, frostfolk = 1.5 }, minAge = 16, maxAge = 60 },
	builder = { name = "Builder", district = "market", schedule = "day", domains = { earth = 2.5 }, branches = { "geomancy", "lithomancy" },
		work = { branch = "geomancy", property = "cohesion", verb = "amplify", form = "touch", power = 2 }, wealth = 0.06, minAge = 16, maxAge = 65 },
	farmer = { name = "Farmer", district = "farm", schedule = "early", domains = { water = 2, life = 2, earth = 1 }, branches = { "water", "flora" },
		work = { branch = "water", property = "humidity", verb = "generate", form = "burst", power = 1 }, wealth = 0.04, cultures = { verdant = 3 }, minAge = 12, maxAge = 80, relief = { "drought" } },
	herbalist = { name = "Herbalist", district = "clinic", schedule = "day", domains = { life = 3 }, branches = { "flora", "restoration" },
		work = { branch = "flora", property = "growth", verb = "amplify", form = "touch", power = 2 }, wealth = 0.05, cultures = { verdant = 3 }, minAge = 16, maxAge = 85 },
	healer = { name = "Healer", district = "clinic", schedule = "day", domains = { life = 3, spirit = 1 }, branches = { "restoration", "mending" },
		work = { branch = "restoration", property = "vitality", verb = "amplify", form = "touch", power = 2 }, wealth = 0.06, minAge = 18, maxAge = 85, relief = { "plague" } },
	lamplighter = { name = "Lamplighter", district = "street", schedule = "night", domains = { energy = 3 }, branches = { "luminous" },
		work = { branch = "energy", property = "luminosity", verb = "generate", form = "touch", power = 1 }, wealth = 0.04, minAge = 12, maxAge = 75 },
	tidepriest = { name = "Tide-priest", district = "temple", schedule = "priest", domains = { water = 3, spirit = 2 }, branches = { "tidal", "warding" },
		work = { branch = "water", property = "flow", verb = "sense", form = "touch", power = 1 }, wealth = 0.03, cultures = { tidecall = 6, frostfolk = 1 }, minAge = 20, maxAge = 90, relief = { "drought", "tempest" } },
	fisher = { name = "Fisher", district = "harbor", schedule = "early", domains = { water = 2.5, air = 1 }, branches = { "hydromancy" },
		work = { branch = "water", property = "flow", verb = "sense", form = "touch", power = 1 }, wealth = 0.05, cultures = { tidecall = 4, frostfolk = 2 }, minAge = 12, maxAge = 75 },
	weathercaller = { name = "Weathercaller", district = "temple", schedule = "day", domains = { air = 3 }, branches = { "weathercraft", "aeromancy" },
		work = { branch = "air", property = "flow", verb = "generate", form = "burst", power = 1 }, wealth = 0.05, cultures = { skywarden = 4 }, minAge = 18, maxAge = 80, relief = { "tempest", "wildfire" } },
	guard = { name = "Guard", district = "guardpost", schedule = "shift", rota = { "shift", "shift_late", "shift_night" }, domains = { energy = 1.5, earth = 1 }, branches = { "kinetic", "warding" },
		work = { branch = "energy", property = "momentum", verb = "generate", form = "touch", power = 1 }, wealth = 0.05, minAge = 18, maxAge = 55, relief = { "monster_migration" } },
	scholar = { name = "Scholar", district = "library", schedule = "scholar", domains = { mind = 2, spirit = 1.5, space = 1 }, branches = { "perceptics", "mnemonics" },
		work = { branch = "mind", property = "perception", verb = "sense", form = "touch", power = 1 }, wealth = 0.04, cultures = { loreseat = 5 }, minAge = 16, maxAge = 95 },
	merchant = { name = "Merchant", district = "market", schedule = "day", domains = {}, branches = {}, wealth = 0.09, cultures = { wayfarer = 4 }, minAge = 16, maxAge = 75 },
	innkeeper = { name = "Innkeeper", district = "tavern", schedule = "evening", domains = { energy = 1 }, branches = {},
		work = { branch = "energy", property = "temperature", verb = "generate", form = "touch", power = 1 }, wealth = 0.06, minAge = 20, maxAge = 80 },
	hunter = { name = "Hunter", district = "wilds", schedule = "early", domains = { air = 1.5, life = 1.5 }, branches = { "fauna" }, wealth = 0.05, cultures = { frostfolk = 2, skywarden = 1.5 }, minAge = 14, maxAge = 65, relief = { "monster_migration" } },
	child = { name = "Child", district = "school", schedule = "child", domains = {}, branches = {}, wealth = 0, minAge = 6, maxAge = 13 },
	retired = { name = "Retired", district = "home", schedule = "retired", domains = {}, branches = {}, wealth = 0.01, minAge = 60, maxAge = 95 },
} :: { [string]: Occupation }

-- Sorted ids, for deterministic weighted picks.
NpcData.occupationIds = (function()
	local ids = {}
	for id in NpcData.occupations do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end)()

-- ─── Values, fears, secrets, goals, ambitions ───────────────────────────────

NpcData.values = { "family", "knowledge", "power", "wealth", "faith", "freedom", "tradition", "honor", "craft", "beauty", "community", "justice" }

NpcData.fears = {
	{ id = "fire", text = "fire" }, { id = "deep_water", text = "deep water" }, { id = "void", text = "the Void" },
	{ id = "forgotten", text = "being forgotten" }, { id = "failure", text = "failing" }, { id = "poverty", text = "poverty" },
	{ id = "sickness", text = "sickness" }, { id = "crowds", text = "crowds" }, { id = "heights", text = "heights" },
	{ id = "mages", text = "powerful mages" }, { id = "dark", text = "the dark" }, { id = "losing_control", text = "losing control of their magic" },
}

NpcData.secrets = {
	{ id = "debt", text = "owes a dangerous amount to someone in another town" },
	{ id = "forbidden_dabble", text = "once studied a forbidden art, and liked it" },
	{ id = "not_from_here", text = "isn't really from here, and lied about it" },
	{ id = "loves_rival", text = "is in love with their rival" },
	{ id = "failed_test", text = "failed their guild test and forged the seal" },
	{ id = "poetry", text = "writes poetry in secret" },
	{ id = "thief", text = "has been skimming from their employer" },
	{ id = "deserter", text = "deserted a militia years ago" },
	{ id = "second_family", text = "has a second family in another settlement" },
	{ id = "cant_read", text = "can't read, and hides it" },
}

NpcData.goals = {
	{ id = "commission", text = "finish a difficult commission" },
	{ id = "savings", text = "save up for better tools" },
	{ id = "technique", text = "master one particular technique" },
	{ id = "court", text = "work up the courage to court someone" },
	{ id = "reconcile", text = "make peace with an estranged sibling" },
	{ id = "repair", text = "repair the family home" },
	{ id = "contest", text = "win the next festival contest" },
	{ id = "read", text = "learn to read properly" },
	{ id = "apprentice", text = "take on an apprentice" },
	{ id = "journey", text = "visit another settlement" },
}

-- Life Ambitions. `kind` steers NPCMagicLife (which branch they push toward) and the brain.
NpcData.ambitions = {
	{ id = "master_branch", text = "become a Master of {branch}", kind = "mastery" },
	{ id = "found_school", text = "found a school of {branch}", kind = "school" },
	{ id = "lost_sibling", text = "find a lost sibling", kind = "travel" },
	{ id = "avenge", text = "avenge a ruined village", kind = "power" },
	{ id = "guildmaster", text = "become guildmaster", kind = "status" },
	{ id = "wealthy", text = "die rich", kind = "wealth" },
	{ id = "see_world", text = "see every settlement on the island", kind = "travel" },
	{ id = "great_book", text = "write a book people still read in a hundred years", kind = "knowledge" },
	{ id = "protect_town", text = "keep their town safe, whatever it costs", kind = "duty" },
	{ id = "new_technique", text = "invent a technique that bears their name", kind = "invention" },
	{ id = "forbidden", text = "learn what the forbidden arts are hiding", kind = "forbidden" },
	{ id = "quiet_life", text = "live quietly and be left alone", kind = "peace" },
}

-- ─── Authored NPCs (the doc's day-in-the-life subjects) ─────────────────────
-- Placed in the first settlement of a matching culture (else the first city / village).
-- Every field overrides the factory's draw; anything left out is still procedurally generated.

NpcData.authored = {
	{
		key = "metallurgist",
		cultures = { "forgehold", "emberclan" },
		size = { "city", "town" },
		name = "Hedda Ashhand",
		age = 19,
		occupation = "smith",
		traits = { ambition = 0.92, conscientiousness = 0.8, pride = 0.7, curiosity = 0.7, patience = 0.35, extraversion = 0.55 },
		quirks = { "hums_when_casting", "collects_broken_tools", "tests_on_pigeons" },
		ambition = "master_branch",
		ambitionBranch = "alloycraft",
		domainBias = { earth = 6, energy = 1.5 },
		minGift = "Gifted",
	},
	{
		key = "tidepriest",
		cultures = { "tidecall", "frostfolk" },
		size = { "city", "town", "village" },
		name = "Corvel Saltmere",
		age = 71,
		occupation = "retired",
		formerOccupation = "tidepriest",
		traits = { agreeableness = 0.15, neuroticism = 0.6, patience = 0.3, humor = 0.55, loyalty = 0.8, compassion = 0.55, extraversion = 0.25 },
		quirks = { "talks_to_the_sea", "grudge_keeper", "no_magic_tuesday" },
		ambition = "quiet_life",
		domainBias = { water = 6, spirit = 2 },
		minGift = "Gifted",
	},
	{
		key = "gravitychild",
		cultures = {},
		size = { "village", "town" },
		name = nil, -- procedurally named
		age = 9,
		occupation = "child",
		traits = { curiosity = 0.85, neuroticism = 0.55, extraversion = 0.35 },
		quirks = { "stacks_stones", "afraid_of_heights_but_climbs" },
		ambition = "see_world",
		forceMythic = "gravity", -- a hidden latent: nobody, including them, knows
	},
}

return NpcData
