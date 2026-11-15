--!strict
--[[
	ChronicleLines: how people tell the world's big moments (docs/LivingHistory.md §4). Same shape
	and conditions as NPC/Data/Barks; AmbientLifeService:lineFor picks and fills them.

	CATEGORIES (<kind> from Chronicle/Data/ChronicleKinds)
		say_<kind>       evening talk, one person to another, overheard
		reply_<group>    the other answers: feat | disaster | wonder | loss; reply_any always fits
		told_<kind>      you asked them for news: the fuller story
		greet_<kind>     someone who remembers you did it brings it up when you walk by
		journal_<kind>   your own Journal, first person, when your deed becomes a legend

	VARS: {who} the top doer's name (a line holding it is skipped when nobody is named), {what}
	(our own data: "The Ashwalker", "drought"), {where} ("here", "out north", "up by Larkwell"),
	{dir}, plus Barks' own {town} {name} {player}.
	Rules: people's words, secondhand and a little wrong; short (a chat bubble); no digits.
]]

local Barks = require(script.Parent.Parent.Parent.NPC.Data.Barks)

local Lines: { Barks.Line } = {
	-- ─── A Titan fell ───────────────────────────────────────────────────────
	{ cat = "say_titan_fell", text = "You heard? {who} brought {what} down {where}. The ground's still warm, they say." },
	{ cat = "say_titan_fell", text = "{what} came down {where}. I felt it through the floor." },
	{ cat = "say_titan_fell", text = "My uncle saw {what} fall {where}. Says it took the sky with it.", high = { extraversion = 0.55 } },
	{ cat = "say_titan_fell", text = "They're saying {who} was the one who finished {what}. Can you imagine.", high = { openness = 0.5 } },
	{ cat = "told_titan_fell", text = "{what} walked across the island like it owned it, and {who} put it down {where}. The bones are still there if you want to see." },
	{ cat = "told_titan_fell", text = "{what} fell {where}. Folk go out to look at the crater and come back quiet." },
	{ cat = "greet_titan_fell", text = "You were at the fall of {what}, weren't you? Everyone's saying so." },
	{ cat = "greet_titan_fell", text = "There's the one who brought down {what}. Welcome, welcome." },
	{ cat = "journal_titan_fell", text = "People are already telling the story of {what}. I don't think they'll stop soon." },

	-- ─── A Wildborn boss ────────────────────────────────────────────────────
	{ cat = "say_boss_slain", text = "{who} went into the wilds {where} and killed {what}. Walked out on their own feet." },
	{ cat = "say_boss_slain", text = "{what}'s dead. The thing in the stones {where}. Someone finally did it." },
	{ cat = "say_boss_slain", text = "I won't believe {what}'s gone till I see it. That thing took my cousin's cart.", high = { neuroticism = 0.55 } },
	{ cat = "told_boss_slain", text = "There was a thing out {dir} among the standing stones, {what} they called it. {who} went and killed it. The stones are quiet now, for a while anyway." },
	{ cat = "told_boss_slain", text = "{what} used to hold the stones {where}. Not any more. Whoever did it didn't stay to be thanked." },
	{ cat = "greet_boss_slain", text = "They say you killed {what}. Is it true?" },
	{ cat = "greet_boss_slain", text = "You're the one who went into the stones after {what}. I'd buy you a drink." },
	{ cat = "journal_boss_slain", text = "They talk about {what} in the taverns now, and about me with it." },

	-- ─── A shared event ─────────────────────────────────────────────────────
	{ cat = "say_shared_event_won", text = "The trouble {where}, the {what}. A crowd of mages stood up to it and won." },
	{ cat = "say_shared_event_won", text = "{who} was right in the middle of that {what} {where}, I heard." },
	{ cat = "told_shared_event_won", text = "There was a {what} {where}, a bad one. Mages came from all over and held it off. {who} most of all, the way people tell it." },
	{ cat = "told_shared_event_won", text = "A {what} hit {where}. It could have gone worse. Plenty of folk stood their ground." },
	{ cat = "greet_shared_event_won", text = "You stood in that {what}, didn't you? Good on you." },

	-- ─── Loose spells ───────────────────────────────────────────────────────
	{ cat = "say_feral_ended", text = "That loose spell {where}? {who} put it out. Good riddance." },
	{ cat = "say_feral_ended", text = "Someone finally stopped that wild magic {where}. I can sleep again.", high = { neuroticism = 0.5 } },
	{ cat = "told_feral_ended", text = "A spell got loose {where} and went wandering, burning what it touched. {who} brought it down in the end." },
	{ cat = "greet_feral_ended", text = "You ended that loose spell, didn't you? Thank you." },

	{ cat = "say_feral_escaped", text = "{who} let a spell get away from them {where}. It's still out there somewhere." },
	{ cat = "say_feral_escaped", text = "Some mage lost hold of a spell {where}. Just walked off on its own, the spell.", fear = { "mages", "losing_control" } },
	{ cat = "say_feral_escaped", text = "A spell tore loose {where}. Keep the children in.", high = { conscientiousness = 0.5 } },
	{ cat = "told_feral_escaped", text = "Someone's spell tore loose {where} and didn't go out. {who}, people say. Mind yourself if you're walking that way." },
	{ cat = "greet_feral_escaped", text = "You're the one whose spell got loose. Keep a tighter grip, eh?" },
	{ cat = "greet_feral_escaped", text = "Mind your magic round here. We remember the last time.", low = { agreeableness = 0.45 } },

	-- ─── The town's troubles ────────────────────────────────────────────────
	{ cat = "say_crisis_resolved", text = "That mess in {town}'s sorted. {who} saw to it." },
	{ cat = "say_crisis_resolved", text = "Things are better in {town} than they were. Someone helped, and it wasn't the council." },
	{ cat = "told_crisis_resolved", text = "We had real trouble here a while back. {who} stepped in when nobody else would. People don't forget that." },
	{ cat = "greet_crisis_resolved", text = "You helped us when it counted. Don't think we've forgotten." },

	{ cat = "say_event_relieved", text = "The {what} broke {where}. {who} did it with magic, they say." },
	{ cat = "say_event_relieved", text = "The {what}'s over {where}. Somebody's magic ended it." },
	{ cat = "told_event_relieved", text = "There was a {what} {where}, and it should have gone on for days. {who} ended it. Just like that." },
	{ cat = "greet_event_relieved", text = "You ended the {what}. My garden thanks you." , occ = { "farmer", "herbalist" } },
	{ cat = "greet_event_relieved", text = "You're the one who broke the {what}, aren't you?" },

	-- ─── Magic people talk about ────────────────────────────────────────────
	{ cat = "say_great_spell", text = "Did you see the sky {where}? That was {who}. One spell." },
	{ cat = "say_great_spell", text = "Someone cast a {what} {where}. A whole sky's worth of magic." },
	{ cat = "say_great_spell", text = "Magic like that {where} isn't natural. I don't care who did it.", fear = { "mages", "losing_control" } },
	{ cat = "told_great_spell", text = "{who} cast something {where} people are still arguing about. {what}, the mages call it. I just call it loud." },
	{ cat = "greet_great_spell", text = "That was you, the {what}? I've never seen the like." },
	{ cat = "greet_great_spell", text = "Please don't do that {what} anywhere near my roof.", low = { agreeableness = 0.5 } },
	{ cat = "journal_great_spell", text = "People are still talking about my {what}. I suppose I'd talk about it too." },

	{ cat = "say_quake", text = "The ground shook {where}. That was no natural quake, it was {who}." },
	{ cat = "say_quake", text = "That quake {where} cracked half the walls. Some mage did it." },
	{ cat = "told_quake", text = "Someone shook the earth {where}. {who}, they say. Builders have been busy ever since." },
	{ cat = "greet_quake", text = "You're the one who shook the ground. My shelves still aren't straight." },
	{ cat = "journal_quake", text = "They talk about the day I shook the ground. Not always kindly." },

	{ cat = "say_tsunami", text = "The sea came in {where}. Called up by {who}, they say." },
	{ cat = "say_tsunami", text = "A wave like a wall {where}. Someone called the sea and it came.", fear = { "deep_water" } },
	{ cat = "told_tsunami", text = "{who} raised the sea {where}. A wave like a cliff. People still look at the water different." },
	{ cat = "greet_tsunami", text = "You brought the sea in. I'll keep my boots on round you." },
	{ cat = "journal_tsunami", text = "They tell of the day I called the sea. They tell it with their eyes on the water." },

	{ cat = "say_npc_awakened", text = "{what}'s magic woke {where}. Out of nowhere, like that." },
	{ cat = "say_npc_awakened", text = "Did you hear about {what}? Magic in them all along, and nobody knew." },
	{ cat = "told_npc_awakened", text = "{what} woke up to their magic {where}, sudden as anything. Old magic, too, the kind you don't see." },

	{ cat = "say_world_first", text = "{who} made a spell nobody's ever made before. Not anywhere." },
	{ cat = "say_world_first", text = "The scholars are fussing over some new spell {who} came up with.", occ = { "scholar" } },
	{ cat = "told_world_first", text = "{who} worked out a spell nobody had ever cast. The scholars wrote it down. They don't do that for just anyone." },
	{ cat = "greet_world_first", text = "You're the one with the new spell. The scholars are jealous." },
	{ cat = "journal_world_first", text = "Someone told me the scholars wrote down my spell. The first of its kind, they said." },

	-- ─── Replies ────────────────────────────────────────────────────────────
	{ cat = "reply_feat", text = "Good. About time someone did." },
	{ cat = "reply_feat", text = "I'll believe it when I see it." , low = { agreeableness = 0.4 } },
	{ cat = "reply_feat", text = "I'd have liked to see that.", high = { openness = 0.5 } },
	{ cat = "reply_feat", text = "We owe them, then." },
	{ cat = "reply_disaster", text = "Mages. Every time." , fear = { "mages", "losing_control" } },
	{ cat = "reply_disaster", text = "I hope someone's making it right." },
	{ cat = "reply_disaster", text = "Don't. I don't want to think about it.", high = { neuroticism = 0.5 } },
	{ cat = "reply_wonder", text = "The things people can do now." },
	{ cat = "reply_wonder", text = "Makes you wonder what's in the rest of us." , high = { openness = 0.5 } },
	{ cat = "reply_wonder", text = "Hm. Magic like that doesn't come free." },
	{ cat = "reply_any", text = "So they say." },
	{ cat = "reply_any", text = "Hm." },
	{ cat = "reply_any", text = "Is that so." },
}

return Lines
