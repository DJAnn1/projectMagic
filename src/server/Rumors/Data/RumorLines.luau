--!strict
--[[
	RumorLines: what townspeople say to each other about real things nearby, and what they tell you
	when you ask (docs/Rumors.md, idea #39 "Overheard rumours"). Same shape and conditions as
	NPC/Data/Barks; AmbientLifeService:lineFor picks and fills them for the person speaking.

	CATEGORIES (the <kind> is Rumors/RumorRules' fact kind)
		say_<kind>     the first person, to the second: an overheard opener
		reply_<group>  the second person answers: group place | den | danger; reply_any always fits
		told_<kind>    you asked them for rumours afterwards: the fuller story (places and dens only;
		               wild zones, lairs and ferals have their own stories in their own services)

	KINDS
		library academy hermit mine vent fault trench caverns grove sunken quiet dungeon shrine
		den_<creature id>   ember_sprite mud_crawler gust_moth gloom_rat glass_beetle mana_wisp
		zone lair feral

	VARS: {dir} (north, south-east...), {place} (a wild zone's name; "the <word> shrine" for a
	shrine), {name} {town}. Every say_ and told_ line holds {dir}: a rumour you can follow.
	Rules: people's words, vague and secondhand ("they say", "my cousin saw"); no digits.
]]

local Barks = require(script.Parent.Parent.Parent.NPC.Data.Barks)

local Lines: { Barks.Line } = {
	-- ─── Places ─────────────────────────────────────────────────────────────
	{ cat = "say_library", text = "Someone saw lights in that old library out {dir}. Nobody's lived there in ages." },
	{ cat = "say_library", text = "My cousin went poking round the ruined library out {dir}. Came back with ink on his hands and wouldn't say why.", high = { extraversion = 0.5 } },
	{ cat = "say_library", text = "There's books still in that ruin out {dir}. Books! Just sitting there.", occ = { "scholar", "merchant" } },
	{ cat = "told_library", text = "There's a ruined library out {dir}. Half the roof's gone, but there's still writing on the walls nobody can read. People who study go out there and come back quieter." },

	{ cat = "say_academy", text = "Another lot of students went up to the academy out {dir}. Didn't see them come back down." },
	{ cat = "say_academy", text = "They say the academy out {dir} takes anyone who can make a spark. Anyone.", mage = false },
	{ cat = "told_academy", text = "The academy's out {dir}. Proper mages, robes and all. If you want to learn from people who've written it down, that's where." },

	{ cat = "say_hermit", text = "That tower out {dir}, the old hermit's. Smoke from the chimney again last night." },
	{ cat = "say_hermit", text = "Nobody's seen the hermit out {dir} in years. But someone's keeping that tower lit.", high = { neuroticism = 0.5 } },
	{ cat = "told_hermit", text = "There's a tower out {dir}. Someone lives in it who doesn't want company. Mages go out there to ask things, and mostly come back with more questions." },

	{ cat = "say_mine", text = "The mine out {dir} is going deeper. They hit something that hums, they say." },
	{ cat = "say_mine", text = "My brother works the mine out {dir}. Says the ore's been warm lately.", occ = { "miner", "smith" } },
	{ cat = "told_mine", text = "Out {dir} there's a mine. Good ore, and they say some of it carries magic. Smiths pay well for what comes out of there." },

	{ cat = "say_vent", text = "The ground's smoking again out {dir}. That vent's never really gone quiet." },
	{ cat = "say_vent", text = "Fire mages go and sit by the vent out {dir}. Just sit there. In the heat.", mage = false },
	{ cat = "told_vent", text = "There's a vent out {dir} where the ground breathes fire. Anyone who works fire goes there sooner or later. They say the heat teaches you." },

	{ cat = "say_fault", text = "The ground cracked again out {dir}. Along the old fault." },
	{ cat = "say_fault", text = "You can feel it out {dir}, by the fault. Like the earth's holding its breath.", high = { openness = 0.55 } },
	{ cat = "told_fault", text = "Out {dir} the land's split along an old fault. It moves sometimes. Stone mages go and listen to it." },

	{ cat = "say_trench", text = "The fishers won't go over the trench out {dir}. Say the water's too dark." },
	{ cat = "say_trench", text = "Something big moved under the boat over the deep water out {dir}. Swear it.", occ = { "fisher" } },
	{ cat = "told_trench", text = "Out {dir} the sea drops away into a trench. Deep as anything. Water mages say it pulls at you." },

	{ cat = "say_caverns", text = "Did you hear the caves out {dir} singing again last night?" },
	{ cat = "say_caverns", text = "The caves out {dir} sing when the wind's right. My gran said it's the stone remembering.", high = { openness = 0.5 } },
	{ cat = "told_caverns", text = "Out {dir} there are caves that sing. Not wind. Something in the stone. People who've gone deep say it changed them." },

	{ cat = "say_grove", text = "The hollow grove out {dir}. Nothing grows right in there. Too quiet." },
	{ cat = "say_grove", text = "Don't go in the grove out {dir} after dark. My aunt did. She was never quite the same.", high = { neuroticism = 0.5 } },
	{ cat = "told_grove", text = "There's a grove out {dir} where the trees are hollow and nothing sings. People go in looking for something. Some of them find it." },

	{ cat = "say_sunken", text = "When the tide's out you can see the top of the old shrine out {dir}. Under the water." },
	{ cat = "told_sunken", text = "Out {dir} there's a shrine the sea took. You can reach it at low water. Nobody knows who built it." },

	{ cat = "say_quiet", text = "Out {dir} there's a place where nothing makes a sound. Not even you." },
	{ cat = "say_quiet", text = "Took the cart out {dir} once. Everything went quiet. The horse wouldn't go on.", occ = { "merchant", "farmer" } },
	{ cat = "told_quiet", text = "Out {dir} there's a place where the magic just... stops. Dead quiet. Some go there to rest. Some to find out what's left of them without it." },

	{ cat = "say_dungeon", text = "There's caves out {dir} with things living in them. Glowing things." },
	{ cat = "say_dungeon", text = "Hunters lost a dog in the caves out {dir}. Heard it barking under the ground for a day.", occ = { "hunter", "guard" } },
	{ cat = "say_dungeon", text = "Somebody found a cave out {dir} full of lights! Real lights!", child = true },
	{ cat = "told_dungeon", text = "Out {dir} there are caves full of strange life. The magic's thick down there. Go armed." },

	{ cat = "say_shrine", text = "Pilgrims on the road again, heading for {place} out {dir}." },
	{ cat = "say_shrine", text = "I took an offering to {place} out {dir}. Felt lighter all week.", high = { agreeableness = 0.5 } },
	{ cat = "told_shrine", text = "{place} is out {dir}. People who work that kind of magic go and stay a while. They say you learn things there you can't learn from a book." },

	-- ─── Dens ───────────────────────────────────────────────────────────────
	{ cat = "say_den_ember_sprite", text = "Something's been scorching the hedges out {dir}. Little sparks, flying about." },
	{ cat = "say_den_ember_sprite", text = "Those fire sprites out {dir} set my haystack going.", occ = { "farmer" } },
	{ cat = "told_den_ember_sprite", text = "There's a nest of fire sprites out {dir}. Small, but they come at you in a swarm. Water helps." },
	{ cat = "say_den_mud_crawler", text = "Something's dug a great wet hole out {dir}. Don't put your foot in it." },
	{ cat = "say_den_mud_crawler", text = "One of those mud things bit a goat out {dir}. Right through the fence.", occ = { "farmer", "hunter" } },
	{ cat = "told_den_mud_crawler", text = "Mud crawlers out {dir}. Slow, but they don't like you near their holes. Leave them be and they'll leave you." },
	{ cat = "say_den_gust_moth", text = "Big moths out {dir}. Big as a dog. Blew my washing clean off the line." },
	{ cat = "told_den_gust_moth", text = "Out {dir} there's moths the size of dogs. They'll knock you flat with their wings. Pretty, though." },
	{ cat = "say_den_gloom_rat", text = "Rats out {dir}. The dark kind. You can't see them till they're on you." },
	{ cat = "say_den_gloom_rat", text = "Something's been at the grain store again. Rats, from out {dir}.", occ = { "innkeeper", "merchant", "farmer" } },
	{ cat = "told_den_gloom_rat", text = "Gloom rats out {dir}. They come at anyone who wanders close. Bring a light." },
	{ cat = "say_den_glass_beetle", text = "Found a beetle shell out {dir}. Clear as glass. Hard as it, too." },
	{ cat = "told_den_glass_beetle", text = "There's beetles out {dir} with shells like glass. Hard to hurt. Smiths like the shells." },
	{ cat = "say_den_mana_wisp", text = "Little lights drifting about out {dir} at night. Wisps, my mother said." },
	{ cat = "say_den_mana_wisp", text = "I saw the wisps out {dir}! They followed me!", child = true },
	{ cat = "told_den_mana_wisp", text = "Wisps out {dir}. Pure magic, drifting. Mages hunt them for what they leave behind." },

	-- ─── Dangers (their own services tell the full story when asked) ────────
	{ cat = "say_zone", text = "Did you hear about {place} out {dir}? The ground doesn't play by the rules out there." },
	{ cat = "say_zone", text = "Don't go near {place}, out {dir}. Things are wrong there.", high = { neuroticism = 0.5 } },
	{ cat = "say_zone", text = "My uncle walked into {place} out {dir} for a bet. Says he'll never do it again.", high = { extraversion = 0.5 } },
	{ cat = "say_lair", text = "There's something living out {dir}. Was a person once, they say." },
	{ cat = "say_lair", text = "Hunters won't go out {dir} any more. Not since they saw what's living there.", occ = { "hunter", "guard" } },
	{ cat = "say_lair", text = "An old trapper swears he saw a man walking out {dir} who wasn't a man any more.", high = { openness = 0.5 } },
	{ cat = "say_feral", text = "There's a spell loose out {dir}. Nobody holding it. Just drifting about." },
	{ cat = "say_feral", text = "Something bright went past out {dir}, all on its own. Like a spell with no one casting it.", high = { neuroticism = 0.5 } },
	{ cat = "say_feral", text = "Some mage let one get away. It's out {dir} somewhere.", fear = { "mages", "losing_control" } },

	-- ─── Replies ────────────────────────────────────────────────────────────
	{ cat = "reply_any", text = "Is that right?" },
	{ cat = "reply_any", text = "Hm. People say a lot of things." },
	{ cat = "reply_any", text = "I heard that too." },
	{ cat = "reply_any", text = "You and your stories.", low = { openness = 0.45 } },
	{ cat = "reply_any", text = "Really? Tell me everything.", high = { extraversion = 0.55 } },
	{ cat = "reply_any", text = "Can we go and see? Can we?", child = true },
	{ cat = "reply_place", text = "I always meant to go out there." },
	{ cat = "reply_place", text = "My father went once. Wouldn't talk about it.", high = { neuroticism = 0.5 } },
	{ cat = "reply_place", text = "Old places should be left alone.", low = { openness = 0.4 } },
	{ cat = "reply_place", text = "Somebody ought to write that down.", occ = { "scholar" } },
	{ cat = "reply_den", text = "Someone should clear them out." },
	{ cat = "reply_den", text = "Not my problem as long as they stay out there.", low = { agreeableness = 0.45 } },
	{ cat = "reply_den", text = "I'll keep the lamp lit tonight, then.", high = { neuroticism = 0.5 } },
	{ cat = "reply_den", text = "I'll take the bow out and have a look.", occ = { "hunter" } },
	{ cat = "reply_danger", text = "And nobody's doing anything about it?" },
	{ cat = "reply_danger", text = "Don't. I won't sleep.", high = { neuroticism = 0.55 } },
	{ cat = "reply_danger", text = "Let the mages deal with it.", mage = false },
	{ cat = "reply_danger", text = "Someone should go and see.", high = { conscientiousness = 0.55 } },
	{ cat = "reply_danger", text = "We'll keep an eye on the road.", occ = { "guard" } },
}

return Lines
