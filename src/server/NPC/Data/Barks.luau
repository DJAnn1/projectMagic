--!strict
--[[
	Barks: the things NPCs mutter, and how they react to a player walking up (docs/LivingWorld.md §3).
	Pure data; NPC/BarkEngine picks and fills them.

	A LINE: { cat, text, ...conditions }. Every condition present must hold.
		hours    { from, to } game hours (wraps past midnight)
		occ      { occupation ids }
		action   { action ids }
		mood     { content, cheerful, anxious, angry, grieving, tired, hungry }
		rel      { stranger, acquaintance, friend, close, wary, hostile } toward the nearest hearer
		high     { trait = at least }
		low      { trait = at most }
		quirk    { quirk ids, any one }
		event    { world event types near the NPC }
		biome    { biome ids of the town }
		culture  { culture ids }
		child    true = children only, false = adults only
		deed     { memory kinds this NPC holds about the nearest hearer }
		mage     true = has real magic, false = doesn't

	VARS in {braces}; a line whose var isn't available right now is skipped.
		{town} {name} {player} {story} {friend}

	The more conditions a line has, the likelier it's chosen when they all hold, so a specific line
	beats a general one. `cat` starting "greet_" are greetings, never ambient: GreetingRules picks the
	category. Text is plain and short: it shows in a chat bubble.
]]

export type Line = {
	cat: string,
	text: string,
	hours: { number }?,
	occ: { string }?,
	action: { string }?,
	mood: { string }?,
	rel: { string }?,
	high: { [string]: number }?,
	low: { [string]: number }?,
	quirk: { string }?,
	event: { string }?,
	biome: { string }?,
	culture: { string }?,
	child: boolean?,
	deed: { string }?,
	mage: boolean?,
}

local Lines: { Line } = {
	-- ─── Time of day (12) ───────────────────────────────────────────────────
	{ cat = "time", text = "Up before the birds again.", hours = { 4, 7 } },
	{ cat = "time", text = "Morning. Or what passes for it.", hours = { 5, 8 }, mood = { "tired" } },
	{ cat = "time", text = "Good light today. Best get on with it.", hours = { 7, 11 }, mood = { "content", "cheerful" } },
	{ cat = "time", text = "Half the day gone already.", hours = { 11, 13 } },
	{ cat = "time", text = "Is it midday yet? My stomach says so.", hours = { 11, 14 }, mood = { "hungry" } },
	{ cat = "time", text = "Long shadows. Nearly done.", hours = { 16, 19 } },
	{ cat = "time", text = "Sun's going. Lamps soon.", hours = { 17, 20 } },
	{ cat = "time", text = "Evening's the only honest part of the day.", hours = { 18, 22 }, high = { openness = 0.6 } },
	{ cat = "time", text = "Cold comes down fast once it's dark.", hours = { 19, 23 } },
	{ cat = "time", text = "Should be asleep. Should be a lot of things.", hours = { 22, 3 } },
	{ cat = "time", text = "Quiet, this hour. I like it.", hours = { 22, 4 }, low = { extraversion = 0.4 } },
	{ cat = "time", text = "Another night, another watch.", hours = { 22, 5 }, occ = { "guard", "lamplighter" } },

	-- ─── Weather and land (12) ──────────────────────────────────────────────
	{ cat = "land", text = "Sea air gets into everything. Even the bread.", biome = { "tidal_flats", "frozen_coast" } },
	{ cat = "land", text = "You can smell the tide from here.", biome = { "tidal_flats" } },
	{ cat = "land", text = "Cold enough to crack a good pot.", biome = { "tundra", "frostpeaks", "frozen_coast" } },
	{ cat = "land", text = "Three coats and I still feel it.", biome = { "tundra", "frostpeaks" }, mood = { "tired", "hungry" } },
	{ cat = "land", text = "Sand in the bed again.", biome = { "desert_dunes" } },
	{ cat = "land", text = "Dry out. Dry as an old sermon.", biome = { "desert_dunes", "badlands" } },
	{ cat = "land", text = "These woods have opinions, I swear.", biome = { "deep_forest" } },
	{ cat = "land", text = "Mud to the knee. Lovely.", biome = { "swamp" } },
	{ cat = "land", text = "Good grazing this year, they say.", biome = { "grasslands" }, occ = { "farmer", "merchant" } },
	{ cat = "land", text = "Air's thin up here. You get used to it.", biome = { "mountains", "skyreach" } },
	{ cat = "land", text = "Dig anywhere round here and you hit somebody's old wall.", biome = { "ruinlands" } },
	{ cat = "land", text = "The ground's warm. It shouldn't be.", biome = { "volcanic_highlands" } },

	-- ─── Work (24) ──────────────────────────────────────────────────────────
	{ cat = "work", text = "This edge won't hold. Again.", occ = { "smith" }, action = { "work" } },
	{ cat = "work", text = "Iron doesn't care how you feel about it.", occ = { "smith" }, action = { "work" } },
	{ cat = "work", text = "Who keeps moving my tongs?", occ = { "smith" }, action = { "work" }, mood = { "angry", "tired" } },
	{ cat = "work", text = "Mind the seam. Mind the seam...", occ = { "miner" }, action = { "work" } },
	{ cat = "work", text = "Sounded hollow, that last one. Didn't like it.", occ = { "miner" }, action = { "work" }, high = { neuroticism = 0.55 } },
	{ cat = "work", text = "Plumb, more or less. Mostly less.", occ = { "builder" }, action = { "work" } },
	{ cat = "work", text = "Whoever built this wall was drunk. It was me.", occ = { "builder" }, action = { "work" }, high = { humor = 0.55 } },
	{ cat = "work", text = "Rows won't hoe themselves.", occ = { "farmer" }, action = { "work" } },
	{ cat = "work", text = "Could do with rain. Or a water mage who owes me.", occ = { "farmer" }, action = { "work" } },
	{ cat = "work", text = "Fresh today! Well. Fresh enough.", occ = { "merchant" }, action = { "work" }, high = { humor = 0.5 } },
	{ cat = "work", text = "Best prices in {town}! Ask anyone. Don't ask anyone.", occ = { "merchant" }, action = { "work" } },
	{ cat = "work", text = "Every coin counts. Every single one.", occ = { "merchant" }, action = { "work" }, high = { greed = 0.6 } },
	{ cat = "work", text = "Round of the usual? Course it is.", occ = { "innkeeper" }, action = { "work" } },
	{ cat = "work", text = "Somebody's going to pay that tab one day.", occ = { "innkeeper" }, action = { "work" } },
	{ cat = "work", text = "All quiet. I'd like it to stay that way.", occ = { "guard" }, action = { "work" } },
	{ cat = "work", text = "Eyes up. Boots dry. That's the job.", occ = { "guard" }, action = { "work" } },
	{ cat = "work", text = "Nearly end of shift. Nearly.", occ = { "guard" }, action = { "work" }, mood = { "tired", "hungry" } },
	{ cat = "work", text = "One more lamp. Then another one more.", occ = { "lamplighter" }, action = { "work" } },
	{ cat = "work", text = "Nobody thanks the lamplighter until it's dark.", occ = { "lamplighter" }, action = { "work" } },
	{ cat = "work", text = "Fish aren't biting. Or they're laughing.", occ = { "fisher" }, action = { "work" } },
	{ cat = "work", text = "Yarrow, for the fever. Or was that the other one?", occ = { "herbalist", "healer" }, action = { "work" } },
	{ cat = "work", text = "That's three footnotes disagreeing with each other.", occ = { "scholar" } },
	{ cat = "work", text = "The tide keeps its own counsel.", occ = { "tidepriest" } },
	{ cat = "work", text = "Wind's backing east. Something's on its way.", occ = { "weathercaller" } },

	-- ─── Personality and quirks (14) ────────────────────────────────────────
	{ cat = "self", text = "Did I lock the door? I locked the door.", high = { neuroticism = 0.7 } },
	{ cat = "self", text = "Something's about to go wrong. I can feel it.", high = { neuroticism = 0.75 } },
	{ cat = "self", text = "Lovely day to mind everyone else's business.", high = { extraversion = 0.7 } },
	{ cat = "self", text = "Everyone's so loud.", low = { extraversion = 0.3 } },
	{ cat = "self", text = "I wonder what's under that.", high = { curiosity = 0.75 } },
	{ cat = "self", text = "I'll be somebody yet. You watch.", high = { ambition = 0.75 } },
	{ cat = "self", text = "Nobody here does it right but me.", high = { pride = 0.75 } },
	{ cat = "self", text = "That's worth something, if you know who to ask.", high = { greed = 0.75 } },
	{ cat = "self", text = "Poor thing. Someone ought to help.", high = { compassion = 0.75 } },
	{ cat = "self", text = "Roses are... no. That's terrible.", quirk = { "secret_poet" } },
	{ cat = "self", text = "The pigeons were very brave about it.", quirk = { "tests_on_pigeons" } },
	{ cat = "self", text = "That one's Margaret. This feather. Don't touch it.", quirk = { "collects_feathers" } },
	{ cat = "self", text = "Sit down? Never. Not once. Not me.", quirk = { "never_sits" } },
	{ cat = "self", text = "You didn't hear this from me, but...", quirk = { "gossip", "collects_rumors" } },

	-- ─── Moods (10) ─────────────────────────────────────────────────────────
	{ cat = "mood", text = "Can't complain. I could, though.", mood = { "content" } },
	{ cat = "mood", text = "What a morning. What a whole day, really.", mood = { "cheerful" } },
	{ cat = "mood", text = "Sing something, why don't you? No? Fine. I will.", mood = { "cheerful" }, high = { extraversion = 0.55 } },
	{ cat = "mood", text = "If I close my eyes for just a moment...", mood = { "tired" } },
	{ cat = "mood", text = "Could eat a whole goat. Horns and all.", mood = { "hungry" } },
	{ cat = "mood", text = "Stay close to the walls. Just in case.", mood = { "anxious" } },
	{ cat = "mood", text = "Don't like this. Don't like this at all.", mood = { "anxious" } },
	{ cat = "mood", text = "Next one who looks at me sideways...", mood = { "angry" } },
	{ cat = "mood", text = "Leave me be. Just for today.", mood = { "grieving" } },
	{ cat = "mood", text = "Funny how quiet a house gets.", mood = { "grieving" } },

	-- ─── World events near them (10) ────────────────────────────────────────
	{ cat = "event", text = "Well's nearly mud now. Pray for rain.", event = { "drought" } },
	{ cat = "event", text = "If the water goes, {town} goes.", event = { "drought" } },
	{ cat = "event", text = "Smell that? That's the woods burning.", event = { "wildfire" } },
	{ cat = "event", text = "My hair's standing up. All of it. Magic in the air.", event = { "magic_storm" } },
	{ cat = "event", text = "Don't cast anything today. I mean it. It comes out wrong.", event = { "magic_storm" }, mage = true },
	{ cat = "event", text = "Tie it down or lose it. Storm's coming in.", event = { "tempest" } },
	{ cat = "event", text = "The vents are waking. Ground's been humming all week.", event = { "volcanic_unrest" } },
	{ cat = "event", text = "Things moving out there. Big things. Keep off the road.", event = { "monster_migration" } },
	{ cat = "event", text = "Half the street's coughing. Wash your hands.", event = { "plague" } },
	{ cat = "event", text = "Feel that? The air's rich. Good day to study.", event = { "ley_surge" }, mage = true },

	-- ─── Magic in daily life (6) ────────────────────────────────────────────
	{ cat = "magic", text = "Steady... steady... there.", mage = true, action = { "practice", "work" } },
	{ cat = "magic", text = "That was supposed to be smaller.", mage = true, action = { "practice" } },
	{ cat = "magic", text = "My teacher made this look easy.", mage = true, action = { "practice", "study" } },
	{ cat = "magic", text = "Never had the knack, me. Honest work suits me fine.", mage = false, child = false },
	{ cat = "magic", text = "My cousin can light a pipe with her thumb. Show-off.", mage = false, child = false },
	{ cat = "magic", text = "The school's taking students, I hear.", child = false, high = { curiosity = 0.5 } },

	-- ─── Children (9) ───────────────────────────────────────────────────────
	{ cat = "child", text = "You're it! No, YOU'RE it!", child = true, action = { "play" } },
	{ cat = "child", text = "Bet I can jump higher than the well.", child = true, action = { "play" } },
	{ cat = "child", text = "Watch this! No, watch! You weren't watching.", child = true, action = { "play" } },
	{ cat = "child", text = "I made a spark yesterday. A real one! Nearly.", child = true },
	{ cat = "child", text = "When I grow up I'm going to move a mountain.", child = true, high = { ambition = 0.5 } },
	{ cat = "child", text = "Do we have to go in? It's not even dark.", child = true, hours = { 17, 21 } },
	{ cat = "child", text = "Why is the sky? Nobody ever tells me.", child = true, high = { curiosity = 0.5 } },
	{ cat = "child", text = "Teacher says I talk too much. I don't. Do I?", child = true, action = { "attend" } },
	{ cat = "child", text = "There's a monster in the old barn. A big one. I saw it.", child = true },

	-- ─── Leisure and town (7) ───────────────────────────────────────────────
	{ cat = "leisure", text = "Another round? Twist my arm.", action = { "socialize" }, hours = { 17, 24 } },
	{ cat = "leisure", text = "And THEN, he says to the goat...", action = { "socialize" }, high = { humor = 0.5 } },
	{ cat = "leisure", text = "Good stew tonight. Don't ask what's in it.", action = { "eat" } },
	{ cat = "leisure", text = "Give me a warm fire and no surprises.", action = { "socialize", "eat", "hobby" }, low = { openness = 0.45 } },
	{ cat = "leisure", text = "{town} isn't much. It's ours, though.", high = { loyalty = 0.6 } },
	{ cat = "leisure", text = "Nothing ever happens in {town}.", low = { loyalty = 0.45 }, high = { curiosity = 0.5 } },
	{ cat = "leisure", text = "They'll have the market cleared by dark.", occ = { "merchant", "builder" }, hours = { 16, 19 } },

	-- ─── News from the world (6): things that happened whether anyone watched or not ─────
	{ cat = "story", text = "Did you hear? {story}." },
	{ cat = "story", text = "They're all saying {story}." },
	{ cat = "story", text = "Word is, {story}. Make of that what you will.", high = { extraversion = 0.45 } },
	{ cat = "story", text = "Mark my words, {story}, and that's only the start.", high = { neuroticism = 0.55 } },
	{ cat = "story", text = "Heard at the well: {story}.", quirk = { "gossip", "collects_rumors" } },
	{ cat = "story", text = "Nobody told you? {story}.", high = { extraversion = 0.6 } },

	-- ─── Things this NPC remembers about the player beside them (12) ────────
	{ cat = "deed", text = "That's who I saw casting the other day.", deed = { "saw_magic" } },
	{ cat = "deed", text = "I saw what you can do. Bit showy, if you ask me.", deed = { "saw_magic" }, low = { agreeableness = 0.45 } },
	{ cat = "deed", text = "Careful with that magic round here. People got scared.", deed = { "saw_harmful_magic" } },
	{ cat = "deed", text = "I've never seen anything like what you did. Never.", deed = { "saw_mythic_magic" } },
	{ cat = "deed", text = "I haven't forgotten what you did to me.", deed = { "attacked_me" } },
	{ cat = "deed", text = "Keep your distance. I saw what you did to them.", deed = { "attacked_someone" } },
	{ cat = "deed", text = "You're the one who patched me up. I owe you.", deed = { "healed_me" } },
	{ cat = "deed", text = "You helped me when you didn't have to.", deed = { "helped_me", "protected_me" } },
	{ cat = "deed", text = "I'd be dead if not for you. I don't forget that.", deed = { "saved_me" } },
	{ cat = "deed", text = "How's the practice coming? Remember what I told you.", deed = { "taught_me" } },
	{ cat = "deed", text = "You beat me fair. Next time, though.", deed = { "beat_me_fairly", "beat_me", "duel_lost" } },
	{ cat = "deed", text = "You let me down. I told people I trusted you.", deed = { "failed_me", "cheated_me", "betrayed_me" } },

	-- ─── Greetings: GreetingRules picks the category (40) ───────────────────
	{ cat = "greet_fawn", text = "{player}! An honour. A real honour." },
	{ cat = "greet_fawn", text = "It's you! Everyone's been talking. Come, stand here, where they can see you." },
	{ cat = "greet_fawn", text = "Anything you need in {town}, you only have to ask." },
	{ cat = "greet_fawn", text = "They'll put up a statue of you one day, {player}. I'd pay for it." },
	{ cat = "greet_fawn", text = "On the house! Whatever it is. Anything.", occ = { "innkeeper", "merchant" } },
	{ cat = "greet_fawn", text = "Stand up straight, you lot. That's {player}.", occ = { "guard" } },
	{ cat = "greet_fawn", text = "Is it really you? Can I tell my sister I met you?", child = false, high = { extraversion = 0.5 } },
	{ cat = "greet_warm", text = "Good to see you, {player}." },
	{ cat = "greet_warm", text = "Back again? {town} suits you." },
	{ cat = "greet_warm", text = "There you are. Keeping well?" },
	{ cat = "greet_warm", text = "Morning, {player}. Good day for it.", hours = { 5, 12 } },
	{ cat = "greet_warm", text = "Evening, {player}. Mind how you go.", hours = { 17, 24 } },
	{ cat = "greet_warm", text = "Hello! Hello! Show me a spell! Please?", child = true },
	{ cat = "greet_warm", text = "Roads treating you kindly?", occ = { "merchant", "guard", "hunter" } },
	{ cat = "greet_neutral", text = "Traveller." },
	{ cat = "greet_neutral", text = "Mm. Afternoon.", hours = { 12, 18 } },
	{ cat = "greet_neutral", text = "New in {town}? Don't touch the good well." },
	{ cat = "greet_neutral", text = "Mind yourself." },
	{ cat = "greet_neutral", text = "Who's that, then?", child = true },
	{ cat = "greet_neutral", text = "Move along. Nothing to see here but work.", occ = { "guard" } },
	{ cat = "greet_neutral", text = "Buying or just looking?", occ = { "merchant" } },
	{ cat = "greet_awe", text = "Is that... magic? In your hand? Look at that.", mage = false },
	{ cat = "greet_awe", text = "Careful with that, friend. It's a very nice glow, but careful." },
	{ cat = "greet_awe", text = "Whoa! Do it! Do the thing! Please do the thing!", child = true },
	{ cat = "greet_awe", text = "Good control. Who taught you?", mage = true },
	{ cat = "greet_wary", text = "I know about you." },
	{ cat = "greet_wary", text = "Hands where I can see them." },
	{ cat = "greet_wary", text = "We don't want trouble here." },
	{ cat = "greet_wary", text = "I'm watching you. So is everyone.", occ = { "guard" } },
	{ cat = "greet_wary", text = "My mother says I'm not to talk to you.", child = true },
	{ cat = "greet_avoid", text = "No. No, not you. Stay back." },
	{ cat = "greet_avoid", text = "I've got nothing! Leave me alone!" },
	{ cat = "greet_avoid", text = "Get away from me!", high = { neuroticism = 0.5 } },
	{ cat = "greet_avoid", text = "Mama! MAMA!", child = true },
	{ cat = "greet_whisper_good", text = "That's {player}. I told you. That's them." },
	{ cat = "greet_whisper_good", text = "Look who it is. Don't stare. Well, stare a little." },
	{ cat = "greet_whisper_good", text = "They say {player} is the real thing." },
	{ cat = "greet_whisper_bad", text = "Don't look now. That's the one they've been talking about." },
	{ cat = "greet_whisper_bad", text = "Keep walking. Don't catch their eye." },
	{ cat = "greet_whisper_bad", text = "Should someone fetch the guard?" },
}

return table.freeze(Lines)
