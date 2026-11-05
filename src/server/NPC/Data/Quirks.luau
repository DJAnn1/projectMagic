--!strict
--[[
	Quirks: small, specific habits that make an NPC a person. Each NPC draws 2-4 (NPCFactory),
	weighted by `affinity` (traits that make a quirk likelier) and blocked by `excludes`.

	Every quirk has a MECHANICAL effect read by the systems below, never just flavour text:
		actionMult       NPCBrain   multiplies an action's utility (hobby, socialize, study...)
		needDecay        NPCBrain   multiplies how fast a need drains
		trait            NPCFactory shifts a trait once, at generation
		scheduleShift    ScheduleService  hours added to the day plan (night owls, early risers)
		noMagicWeekday   NPCMagicLife     no casting on that weekday (0 = Sunday)
		hobby            NPCBrain   the free-time "hobby" action becomes available (text = what they do)
		distrustDomain / likeDomain   RelationshipGraph  first impressions of people known to use it
		negativeHalfLife / positiveHalfLife   MemoryService  multiplier on memory decay half-lives
		gossipMult       MemoryService  how strongly they pass gossip on (and believe it)
		fear             NPCFactory adds a fear; NPCBrain flees it (safety need)
		castFlourish     NPCMagicLife   a flourish in their casting cue and dialogue
		studyMult        NPCMagicLife   multiplier on abstract study progress
		lines            DialogueEngine extra lines that surface in conversation
]]

export type QuirkEffects = {
	actionMult: { [string]: number }?,
	needDecay: { [string]: number }?,
	trait: { [string]: number }?,
	scheduleShift: number?,
	noMagicWeekday: number?,
	hobby: string?,
	distrustDomain: string?,
	likeDomain: string?,
	negativeHalfLife: number?,
	positiveHalfLife: number?,
	gossipMult: number?,
	fear: string?,
	castFlourish: string?,
	studyMult: number?,
	lines: { string }?,
}

export type Quirk = {
	name: string,
	text: string, -- third person, for the inspector and gossip
	affinity: { [string]: number }?, -- trait -> weight bonus when drawing
	excludes: { string }?,
	effects: QuirkEffects,
}

local Q: { [string]: Quirk } = {
	talks_to_plants = { name = "Talks to plants", text = "talks to their plants every morning", affinity = { compassion = 1, openness = 0.5 },
		effects = { hobby = "tending and talking to their plants", actionMult = { hobby = 1.4 }, lines = { "The basil's sulking again. I told it about you." } } },
	no_magic_tuesday = { name = "No magic on Tuesdays", text = "refuses to cast on Tuesdays", affinity = { conscientiousness = 0.8, neuroticism = 0.5 },
		effects = { noMagicWeekday = 2, lines = { "Not on a Tuesday. Never on a Tuesday." } } },
	collects_broken_tools = { name = "Collects broken tools", text = "collects broken tools nobody else wants", affinity = { curiosity = 0.6, greed = 0.4 },
		effects = { hobby = "sorting their broken-tool collection", actionMult = { hobby = 1.2, trade = 1.2 }, lines = { "Got a cracked chisel? I'll take it off your hands." } } },
	hums_when_casting = { name = "Hums when casting", text = "hums tunelessly whenever they cast", affinity = { extraversion = 0.5, humor = 0.5 },
		effects = { castFlourish = "hums a few bars", lines = { "Sorry, was I humming? I always hum." } } },
	distrusts_void = { name = "Distrusts the Void-touched", text = "won't trust anyone with Void affinity", affinity = { neuroticism = 0.8, loyalty = 0.4 },
		effects = { distrustDomain = "void", lines = { "There's a coldness about some people. You know the kind." } } },
	lucky_coin = { name = "Lucky coin", text = "always carries one lucky coin", affinity = { neuroticism = 0.5 },
		effects = { needDecay = { safety = 0.85 }, lines = { "Flipped my coin this morning. Heads. Good day for it." } } },
	secret_poet = { name = "Secret poet", text = "secretly writes poetry", affinity = { openness = 1, extraversion = -0.5 },
		effects = { hobby = "scribbling verses where no one can see", actionMult = { hobby = 1.3 }, trait = { openness = 0.05 } } },
	tests_on_pigeons = { name = "Tests spells on pigeons", text = "tests new spells on pigeons first", affinity = { curiosity = 0.8, compassion = -0.6 },
		effects = { actionMult = { practice = 1.3 }, studyMult = 1.05, lines = { "The pigeons have been very brave about it." } } },
	night_owl = { name = "Night owl", text = "keeps strange hours", affinity = { openness = 0.4, conscientiousness = -0.6 }, excludes = { "early_riser" },
		effects = { scheduleShift = 3 } },
	early_riser = { name = "Early riser", text = "is up before the birds", affinity = { conscientiousness = 0.8 }, excludes = { "night_owl" },
		effects = { scheduleShift = -2, lines = { "You've missed the best part of the day already." } } },
	grudge_keeper = { name = "Keeps grudges", text = "never forgets a slight", affinity = { pride = 1, agreeableness = -0.8 }, excludes = { "forgiving" },
		effects = { negativeHalfLife = 3, lines = { "I remember. I always remember." } } },
	forgiving = { name = "Forgiving", text = "forgives almost anything", affinity = { agreeableness = 1, compassion = 0.6 }, excludes = { "grudge_keeper" },
		effects = { negativeHalfLife = 0.4 } },
	gossip = { name = "Incorrigible gossip", text = "knows everyone's business and shares it", affinity = { extraversion = 1, agreeableness = -0.2 },
		effects = { gossipMult = 1.8, actionMult = { socialize = 1.3 }, needDecay = { social = 1.3 } } },
	tight_lipped = { name = "Tight-lipped", text = "never repeats what they hear", affinity = { loyalty = 1, extraversion = -0.5 }, excludes = { "gossip" },
		effects = { gossipMult = 0.2 } },
	counts_steps = { name = "Counts steps", text = "counts every step out loud under their breath", affinity = { neuroticism = 0.7, conscientiousness = 0.6 },
		effects = { needDecay = { safety = 0.9 }, lines = { "...four hundred and twelve. Sorry, what?" } } },
	afraid_of_fire = { name = "Afraid of fire", text = "is terrified of open flame", affinity = { neuroticism = 1 },
		effects = { fear = "fire", lines = { "Keep that away from me. Please." } } },
	sea_shanties = { name = "Sings shanties", text = "sings shanties whenever they work", affinity = { extraversion = 0.8, humor = 0.6 },
		effects = { actionMult = { work = 1.1 }, needDecay = { social = 0.8 } } },
	feeds_strays = { name = "Feeds strays", text = "feeds every stray animal in town", affinity = { compassion = 1 },
		effects = { hobby = "feeding the strays", actionMult = { hobby = 1.2, help = 1.2 }, needDecay = { wealth = 1.1 } } },
	hoards_candles = { name = "Hoards candles", text = "keeps hundreds of candles, just in case", affinity = { neuroticism = 0.6, greed = 0.3 },
		effects = { fear = "dark", hobby = "counting their candles", lines = { "You can never have too many candles. Ask anyone who's run out." } } },
	reads_at_meals = { name = "Reads at meals", text = "eats with a book open", affinity = { openness = 0.8, extraversion = -0.6 },
		effects = { studyMult = 1.05, actionMult = { eat = 1.0, socialize = 0.85 } } },
	insists_on_titles = { name = "Insists on titles", text = "corrects anyone who forgets their title", affinity = { pride = 1 },
		effects = { lines = { "That's 'Adept' to you, if you don't mind." } } },
	terrible_jokes = { name = "Terrible jokes", text = "tells the worst jokes on the island", affinity = { humor = 1.2 },
		effects = { actionMult = { socialize = 1.15 }, lines = { "Why did the geomancer break up with the sand? It kept shifting." } } },
	nervous_laugh = { name = "Nervous laugh", text = "laughs when nervous", affinity = { neuroticism = 0.8 },
		effects = { lines = { "Ha. Ha ha. Is that... is that a threat? Ha." } } },
	collects_rumors = { name = "Collects rumours", text = "writes down every rumour in a little book", affinity = { curiosity = 1 },
		effects = { gossipMult = 1.3, positiveHalfLife = 1.5 } },
	prays_before_casting = { name = "Prays before casting", text = "says a short prayer before every spell", affinity = { conscientiousness = 0.5, loyalty = 0.5 },
		effects = { castFlourish = "murmurs a prayer first", actionMult = { worship = 1.3 } } },
	stacks_stones = { name = "Stacks stones", text = "balances little towers of stones everywhere", affinity = { patience = 0.6, curiosity = 0.6 },
		effects = { hobby = "balancing stones into impossible towers", actionMult = { hobby = 1.3 }, lines = { "They stay up if you ask nicely." } } },
	afraid_of_heights_but_climbs = { name = "Climbs despite heights", text = "is afraid of heights and climbs everything anyway", affinity = { curiosity = 0.8, neuroticism = 0.4 },
		effects = { fear = "heights", actionMult = { wander = 1.3 } } },
	talks_to_the_sea = { name = "Talks to the sea", text = "argues with the sea out loud", affinity = { loyalty = 0.5, neuroticism = 0.4 },
		effects = { hobby = "standing at the shore, arguing with the tide", actionMult = { hobby = 1.4, worship = 1.2 }, likeDomain = "water", lines = { "She's in a mood today. The sea, I mean." } } },
	bakes_for_neighbors = { name = "Bakes for neighbours", text = "bakes for the whole street", affinity = { compassion = 0.8, extraversion = 0.4 },
		effects = { actionMult = { help = 1.3, socialize = 1.1 }, needDecay = { food = 0.9 } } },
	hates_mornings = { name = "Hates mornings", text = "is unbearable before noon", affinity = { agreeableness = -0.6 },
		effects = { scheduleShift = 1, lines = { "It is too early for words." } } },
	map_maker = { name = "Draws maps", text = "draws maps of places they've never been", affinity = { curiosity = 1, openness = 0.6 },
		effects = { hobby = "drawing maps of places they've only heard of", actionMult = { wander = 1.2 }, likeDomain = "space" } },
	competitive = { name = "Hyper-competitive", text = "turns everything into a contest", affinity = { pride = 1, ambition = 0.6 },
		effects = { actionMult = { practice = 1.25 }, studyMult = 1.05 } },
	collects_feathers = { name = "Collects feathers", text = "collects feathers and names each one", affinity = { curiosity = 0.6, patience = 0.5 },
		effects = { hobby = "naming their feather collection", likeDomain = "air" } },
	never_sits = { name = "Never sits down", text = "refuses to sit down, ever", affinity = { conscientiousness = 0.6, neuroticism = 0.4 },
		effects = { needDecay = { rest = 1.2 }, actionMult = { idle = 0.6 } } },
	sleeps_anywhere = { name = "Sleeps anywhere", text = "can nap anywhere, instantly", affinity = { neuroticism = -0.8 },
		effects = { needDecay = { rest = 0.8 }, actionMult = { sleep = 1.2 } } },
	keeps_ledgers = { name = "Keeps ledgers", text = "writes down every coin they spend", affinity = { greed = 0.8, conscientiousness = 0.6 },
		effects = { needDecay = { wealth = 1.2 }, actionMult = { trade = 1.2 } } },
	generous_to_a_fault = { name = "Generous to a fault", text = "gives away more than they can afford", affinity = { compassion = 1, greed = -0.8 },
		effects = { needDecay = { wealth = 1.3 }, actionMult = { help = 1.3 } } },
	superstitious = { name = "Superstitious", text = "sees omens in everything", affinity = { neuroticism = 0.8, openness = 0.3 },
		effects = { needDecay = { safety = 1.2 }, actionMult = { worship = 1.2 }, lines = { "A crow on the left. Something's coming." } } },
	fascinated_by_mythic = { name = "Mythic-obsessed", text = "is obsessed with Time, Gravity and Reality", affinity = { curiosity = 1, openness = 0.8 },
		effects = { likeDomain = "time", studyMult = 1.05, lines = { "They say a whole ruin stopped in time once. Imagine." } } },
	whittles = { name = "Whittles", text = "whittles little animals out of scrap wood", affinity = { patience = 1 },
		effects = { hobby = "whittling small wooden animals" } },
	smells_magic = { name = "Smells magic", text = "claims they can smell magic", affinity = { openness = 0.6 },
		effects = { lines = { "You smell like {domain}. Don't ask me how I know." } } },
	hates_crowds = { name = "Hates crowds", text = "avoids anywhere with more than three people", affinity = { extraversion = -1 },
		effects = { fear = "crowds", actionMult = { socialize = 0.6, hobby = 1.2 } } },
	life_of_the_party = { name = "Life of the party", text = "is the loudest person at every gathering", affinity = { extraversion = 1.2, humor = 0.6 }, excludes = { "hates_crowds" },
		effects = { actionMult = { socialize = 1.4 }, needDecay = { social = 1.4 } } },
	keeps_old_letters = { name = "Keeps old letters", text = "rereads the same old letters every night", affinity = { loyalty = 0.8, neuroticism = 0.4 },
		effects = { positiveHalfLife = 2, hobby = "rereading old letters" } },
	overprepared = { name = "Always overprepared", text = "carries a pack for every emergency", affinity = { conscientiousness = 1, neuroticism = 0.5 },
		effects = { needDecay = { safety = 0.8 } } },
	tastes_everything = { name = "Tastes everything", text = "tastes anything once, including reagents", affinity = { curiosity = 1, neuroticism = -0.4 },
		effects = { needDecay = { food = 1.1 }, studyMult = 1.03 } },
	clean_freak = { name = "Clean freak", text = "cleans when anxious, which is always", affinity = { conscientiousness = 0.8, neuroticism = 0.6 },
		effects = { hobby = "scrubbing things that are already clean" } },
	debates_everyone = { name = "Debates everyone", text = "will argue any side of anything", affinity = { pride = 0.6, openness = 0.6 },
		effects = { actionMult = { socialize = 1.1 }, lines = { "Interesting. Wrong, but interesting." } } },
	afraid_of_mages = { name = "Afraid of strong mages", text = "goes quiet around powerful mages", affinity = { neuroticism = 1, pride = -0.5 },
		effects = { fear = "mages" } },
	worships_a_hero = { name = "Hero worship", text = "idolises a famous mage", affinity = { loyalty = 1, ambition = 0.4 },
		effects = { studyMult = 1.05, positiveHalfLife = 1.5 } },
	sleepwalker = { name = "Sleepwalker", text = "sleepwalks most nights", affinity = { neuroticism = 0.6 },
		effects = { needDecay = { rest = 1.15 }, lines = { "Woke up on the roof again." } } },
	pockets_full_of_seeds = { name = "Seeds in every pocket", text = "plants seeds wherever they walk", affinity = { compassion = 0.4, openness = 0.5 },
		effects = { likeDomain = "life", actionMult = { wander = 1.1 } } },
	fixes_things = { name = "Fixes everything", text = "can't walk past something broken", affinity = { conscientiousness = 0.6, compassion = 0.5 },
		effects = { actionMult = { help = 1.3, work = 1.05 } } },
	names_their_spells = { name = "Names their spells", text = "gives every spell a grand name", affinity = { pride = 0.6, humor = 0.4 },
		effects = { castFlourish = "announces the spell's name grandly", lines = { "Behold: Dorran's Moderately Warm Breeze!" } } },
	distrusts_reality_mages = { name = "Fears reality-benders", text = "is convinced reality mages are rewriting their memories", affinity = { neuroticism = 0.8 },
		effects = { distrustDomain = "reality" } },
	hums_lullabies = { name = "Hums lullabies", text = "hums lullabies when nervous", affinity = { compassion = 0.6, neuroticism = 0.5 },
		effects = { needDecay = { safety = 0.9 } } },
	collector_of_tales = { name = "Collects tales", text = "trades stories with every traveller", affinity = { curiosity = 0.8, extraversion = 0.5 },
		effects = { gossipMult = 1.2, actionMult = { socialize = 1.15, trade = 1.1 } } },
	practices_at_dawn = { name = "Practises at dawn", text = "practises magic at first light, every day", affinity = { conscientiousness = 0.8, ambition = 0.6 },
		effects = { scheduleShift = -1, actionMult = { practice = 1.3 }, studyMult = 1.08 } },
}

local Quirks = {}
Quirks.defs = Q

local ids = {}
for id in Q do
	table.insert(ids, id)
end
table.sort(ids)
Quirks.ids = ids

return Quirks
