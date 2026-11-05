--!strict
--[[
	DialogueGrammar: the lines NPCs can say, as a small generative grammar.

	A rule maps a SYMBOL to variants. A variant's `text` may contain:
		<symbol>   expanded recursively (another rule)
		{var}      filled from the conversation context (name, player, place, branch, rumor...)
	`when` gates a variant on context (all listed conditions must hold):
		mood = { ... }        the NPC's current mood label
		rel = { ... }         relationship band toward the listener
		above = { trait = x } / below = { trait = x }   personality
		has = { var... }      only if these context vars exist (e.g. a rival, a technique)
	`w` is a weight (default 1). Choice is seeded per (npc, listener, topic, turn), so the same
	moment always yields the same line on every server, and repeated talks vary.

	Mood labels: cheerful, content, tired, hungry, anxious, angry, grieving.
	Relationship bands: hostile, wary, stranger, acquaintance, friend, close.
]]

export type Variant = {
	text: string,
	w: number?,
	when: {
		mood: { string }?,
		rel: { string }?,
		above: { [string]: number }?,
		below: { [string]: number }?,
		has: { string }?,
	}?,
}

local G: { [string]: { Variant } } = {
	-- ─── Greetings ──────────────────────────────────────────────────────────
	greet = {
		{ text = "<hello>, {player}. <state>" },
		{ text = "<hello>. <state>", when = { rel = { "stranger", "acquaintance" } } },
		{ text = "{player}! <glad> <state>", when = { rel = { "friend", "close" } }, w = 2 },
		{ text = "<cold_hello>", when = { rel = { "hostile", "wary" } }, w = 3 },
		{ text = "You again. <cold_hello>", when = { rel = { "hostile" } }, w = 2 },
	},
	hello = {
		{ text = "Morning", when = { has = { "morning" } } },
		{ text = "Evening", when = { has = { "evening" } } },
		{ text = "Well met" },
		{ text = "Hello" },
		{ text = "Ho there", when = { above = { extraversion = 0.6 } } },
		{ text = "Mm. Hello", when = { below = { extraversion = 0.35 } } },
	},
	glad = {
		{ text = "Good to see you." },
		{ text = "There you are!", when = { above = { extraversion = 0.6 } } },
		{ text = "I was hoping you'd come by.", when = { rel = { "close" } } },
	},
	cold_hello = {
		{ text = "What do you want." },
		{ text = "I remember what you did. Keep your distance." , when = { has = { "grievance" } }, w = 3 },
		{ text = "Say your piece and go.", when = { below = { agreeableness = 0.4 } } },
		{ text = "...Yes?", when = { above = { neuroticism = 0.6 } } },
	},
	state = {
		{ text = "", w = 2 },
		{ text = "Busy day.", when = { mood = { "content", "tired" } } },
		{ text = "I haven't eaten since dawn, so forgive me.", when = { mood = { "hungry" } } },
		{ text = "I'm dead on my feet.", when = { mood = { "tired" } } },
		{ text = "Something's wrong today. Can you feel it?", when = { mood = { "anxious" } } },
		{ text = "Don't test me today.", when = { mood = { "angry" } } },
		{ text = "It's... been a hard week.", when = { mood = { "grieving" } } },
		{ text = "Beautiful day for it!", when = { mood = { "cheerful" } } },
	},

	-- ─── About themselves ───────────────────────────────────────────────────
	self = {
		{ text = "I'm {name}, {occupation_a} here in {place}. <self_more>" },
		{ text = "{name}. {occupation_cap}. <self_more>", when = { below = { extraversion = 0.35 } }, w = 2 },
		{ text = "Name's {first}. I keep this town {occupation_verb}. <self_more>", when = { above = { extraversion = 0.6 } } },
	},
	self_more = {
		{ text = "" },
		{ text = "Someday I'll {ambition}.", when = { above = { ambition = 0.6 } }, w = 2 },
		{ text = "Right now I'm trying to {goal}." },
		{ text = "Born and raised here. {age} years now." },
		{ text = "My {bond_word}, {bond_name}, says I work too hard.", when = { has = { "bond_name" } } },
	},

	-- ─── Magic ──────────────────────────────────────────────────────────────
	magic = {
		{ text = "I work in {best_branch}. {tier_phrase}" , when = { has = { "best_branch" } }, w = 2 },
		{ text = "Magic? A little {domain}, nothing grand.", when = { has = { "domain" }, below = { pride = 0.5 } } },
		{ text = "I'm {tier_name} in {best_branch}, and don't you forget it.", when = { has = { "best_branch" }, above = { pride = 0.7 } }, w = 2 },
		{ text = "These days I'm studying {focus}. <magic_more>", when = { has = { "focus" } } },
		{ text = "I made something of my own once. {technique}. Ask nicely and I'll show you.", when = { has = { "technique" } }, w = 3 },
		{ text = "I teach at {school}.", when = { has = { "school" } }, w = 2 },
		{ text = "I study under {mentor}. They're hard on me. Fair, though.", when = { has = { "mentor" } }, w = 2 },
		{ text = "There's a {rival_word} of mine, {rival}. Don't mention them.", when = { has = { "rival" } }, w = 2 },
		{ text = "Strange. Lately the ground feels... lighter around me. Probably nothing.", when = { has = { "hidden_stirring" } }, w = 4 },
	},
	magic_more = {
		{ text = "" },
		{ text = "It's slow going." , when = { below = { patience = 0.4 } } },
		{ text = "Every day a little further." , when = { above = { conscientiousness = 0.6 } } },
	},
	tier_phrase = {
		{ text = "Still learning.", when = { has = { "low_tier" } } },
		{ text = "I'm good at it. Better than most.", when = { has = { "mid_tier" } } },
		{ text = "People come from other towns to ask me things.", when = { has = { "high_tier" } } },
	},

	-- ─── Rumours (gossip from memory) ───────────────────────────────────────
	rumor = {
		{ text = "Have you heard? {rumor}", when = { has = { "rumor" } }, w = 3 },
		{ text = "They say {rumor} I don't know if it's true.", when = { has = { "rumor" }, above = { neuroticism = 0.55 } }, w = 2 },
		{ text = "{rumor} Don't tell anyone I told you.", when = { has = { "rumor" }, above = { extraversion = 0.6 } }, w = 2 },
		{ text = "Nothing worth repeating.", when = { below = { extraversion = 0.4 } } },
		{ text = "Quiet week. Too quiet, if you ask me." },
		{ text = "There's talk of {event_hook}", when = { has = { "event_hook" } }, w = 3 },
	},

	-- ─── Teaching ───────────────────────────────────────────────────────────
	learn = {
		{ text = "I can show you a little {teach_branch}. Watch closely.", when = { has = { "can_teach" }, rel = { "acquaintance", "friend", "close" } }, w = 3 },
		{ text = "Teach you? I hardly know you. Come back when I do.", when = { has = { "can_teach" }, rel = { "stranger", "wary" } }, w = 3 },
		{ text = "Not to you. Never to you.", when = { rel = { "hostile" } }, w = 5 },
		{ text = "You know more than I could teach you, I think.", when = { has = { "no_gap" } }, w = 2 },
		{ text = "I'm no teacher. Try the school, or someone with patience.", when = { below = { patience = 0.4 } } },
		{ text = "I've nothing to teach, I'm afraid." },
	},

	-- ─── Work, ambition, farewell, reactions ────────────────────────────────
	work = {
		{ text = "Can't stop to chat long. {occupation_cap} work doesn't do itself." },
		{ text = "I love it, honestly.", when = { above = { conscientiousness = 0.6 } } },
		{ text = "It pays. Mostly.", when = { above = { greed = 0.6 } } },
	},
	farewell = {
		{ text = "Safe roads." },
		{ text = "Come back soon.", when = { rel = { "friend", "close" } } },
		{ text = "Go on, then.", when = { rel = { "hostile", "wary" } } },
		{ text = "Don't get yourself killed out there.", when = { above = { compassion = 0.6 } } },
	},
	react_attacked = {
		{ text = "Get away from me!" },
		{ text = "You'll pay for that!", when = { above = { pride = 0.6 } }, w = 2 },
		{ text = "Help! Somebody help!", when = { above = { neuroticism = 0.6 } }, w = 2 },
	},
	react_healed = {
		{ text = "...Thank you. I won't forget it." },
		{ text = "You didn't have to do that.", when = { above = { pride = 0.6 } } },
	},

	-- ─── Overheard (NPC to NPC bubbles, for ambience) ───────────────────────
	ambient = {
		{ text = "Did you hear about {rumor_short}?", when = { has = { "rumor_short" } }, w = 2 },
		{ text = "Long day at the {district}." },
		{ text = "My back is killing me.", when = { has = { "elder" } } },
		{ text = "Ha! You always say that.", when = { above = { humor = 0.6 } } },
		{ text = "Not on a Tuesday, I said!", when = { has = { "tuesday_quirk" } }, w = 3 },
	},

	-- ─── Garnish (spliced in by DialogueEngine's style pass) ────────────────
	joke = {
		{ text = "Ha! Don't mind me." },
		{ text = "That's a joke. Mostly." },
		{ text = "My {bond_word} says I'm not funny. My {bond_word} is wrong.", when = { has = { "bond_name" } } },
	},
	hedge = {
		{ text = "I mean, " },
		{ text = "Well, maybe, " },
		{ text = "I could be wrong, but " },
	},
}

return G
