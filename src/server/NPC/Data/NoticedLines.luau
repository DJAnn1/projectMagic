--!strict
--[[
	NoticedLines: what people say when they see (or hear about) what you just did with magic
	(docs/Noticing.md, idea #38). Same shape and conditions as Data/Barks; NPC/BarkEngine picks.
	NPC/Noticing chooses the categories, most specific first, and a category with no line for this
	person falls through to the next, so every category but the last may be sparse.

	SEEN (said a moment after the cast, by one person who saw it)
		noticed_backfire   it went wrong on you
		noticed_killed     it killed someone or something
		noticed_hurt       it hurt someone (not a practice dummy)
		noticed_scared     harmful, and it landed near them
		noticed_mythic     Time, Gravity or Reality: nobody's seen this before
		noticed_land       the ground changed
		noticed_dud        nothing much happened
		noticed_big        power 6 and up
		noticed_weak       a real mage watching a small spell (mage = true lines)
		noticed_dummy      practice on a dummy
		noticed_<kind>     heal, protect, boost, control, move, sense, utility
		noticed_<domain>   by its first domain
		noticed_any        always has a line for everyone

	HEARD (asked instead of a greeting, later, by someone in a town it carried to)
		heard_killed, heard_mythic, heard_land, heard_<domain>, heard_any
		VAR {direction}: north, south-east... from where they stand.

	Rules: plain words, short (chat bubbles), no digits, no game words (no "level", "XP", "power").
	People guess at what they saw; they don't name branches or properties.
]]

local Barks = require(script.Parent.Barks)

local Lines: { Barks.Line } = {
	-- ─── It went wrong ──────────────────────────────────────────────────────
	{ cat = "noticed_backfire", text = "Are you all right? That went the wrong way." },
	{ cat = "noticed_backfire", text = "Ha! Bit back at you, did it?", low = { agreeableness = 0.4 } },
	{ cat = "noticed_backfire", text = "Did it hurt? It looked like it hurt!", child = true },
	{ cat = "noticed_backfire", text = "Steady. You're holding it too tight.", mage = true },
	{ cat = "noticed_backfire", text = "That's how it starts. Then it gets loose and someone gets hurt.", fear = { "losing_control" } },
	{ cat = "noticed_backfire", text = "Sit down a moment. You're shaking.", occ = { "healer", "herbalist" } },

	-- ─── It killed ──────────────────────────────────────────────────────────
	{ cat = "noticed_killed", text = "It's dead. You just... it's dead." },
	{ cat = "noticed_killed", text = "Gods. Is that what magic's for?", child = false, high = { agreeableness = 0.55 } },
	{ cat = "noticed_killed", text = "Clean. I'll give you that.", occ = { "hunter", "guard" } },
	{ cat = "noticed_killed", text = "I didn't want to see that.", child = true },

	-- ─── It hurt someone ────────────────────────────────────────────────────
	{ cat = "noticed_hurt", text = "Hey! There are people here!" },
	{ cat = "noticed_hurt", text = "Watch where you throw that!", low = { agreeableness = 0.5 } },
	{ cat = "noticed_hurt", text = "You hit someone. Did you mean to?", high = { agreeableness = 0.5 } },
	{ cat = "noticed_hurt", text = "That's enough of that. I'm watching you.", occ = { "guard" } },
	{ cat = "noticed_hurt", text = "Someone get the healer!", high = { neuroticism = 0.55 } },
	{ cat = "noticed_hurt", text = "Let me see the wound. Stand back, you.", occ = { "healer", "herbalist" } },
	{ cat = "noticed_hurt", text = "Mum! Mum, they hurt someone!", child = true },

	-- ─── It landed near me ──────────────────────────────────────────────────
	{ cat = "noticed_scared", text = "Whoa! Careful!" },
	{ cat = "noticed_scared", text = "That nearly took my head off!" },
	{ cat = "noticed_scared", text = "Not near me. Please, not near me.", high = { neuroticism = 0.6 } },
	{ cat = "noticed_scared", text = "Do that again and you'll answer for it.", low = { agreeableness = 0.4 } },
	{ cat = "noticed_scared", text = "Mages. Every one of you thinks the street's yours.", fear = { "mages" } },
	{ cat = "noticed_scared", text = "Keep that fire away from me!", fear = { "fire" } },
	{ cat = "noticed_scared", text = "Mind the thatch! Mind the thatch!", occ = { "farmer", "builder", "innkeeper" } },
	{ cat = "noticed_scared", text = "Aah!", child = true },
	{ cat = "noticed_scared", text = "Back away. Now.", occ = { "guard" } },

	-- ─── Mythic ─────────────────────────────────────────────────────────────
	{ cat = "noticed_mythic", text = "What was that? That wasn't... that's not a thing people do." },
	{ cat = "noticed_mythic", text = "I felt that in my teeth. What did you just do?" },
	{ cat = "noticed_mythic", text = "My grandmother told stories about magic like that. I thought they were stories.", high = { openness = 0.5 } },
	{ cat = "noticed_mythic", text = "I've studied all my life and I don't know what that was.", mage = true },
	{ cat = "noticed_mythic", text = "Stay away from me. Whatever you are.", fear = { "mages", "void" } },
	{ cat = "noticed_mythic", text = "Teach me that! Teach me, teach me!", child = true },
	{ cat = "noticed_mythic", text = "I'm writing that down. Don't move.", occ = { "scholar" } },

	-- ─── The ground changed ─────────────────────────────────────────────────
	{ cat = "noticed_land", text = "You moved the ground. You actually moved it." },
	{ cat = "noticed_land", text = "Who's going to put that back?", low = { agreeableness = 0.5 } },
	{ cat = "noticed_land", text = "I've spent a week digging less than that.", occ = { "farmer", "miner", "builder" } },
	{ cat = "noticed_land", text = "The whole street shook!", child = true },
	{ cat = "noticed_land", text = "You'll have the old wells cracking, doing that.", occ = { "innkeeper", "retired" } },

	-- ─── Nothing much happened ──────────────────────────────────────────────
	{ cat = "noticed_dud", text = "Was something supposed to happen?" },
	{ cat = "noticed_dud", text = "Pretty glow. Did it do anything?" },
	{ cat = "noticed_dud", text = "Nothing? Do it again, maybe it's broken.", child = true },
	{ cat = "noticed_dud", text = "You're shaping it but not giving it anything to do.", mage = true },
	{ cat = "noticed_dud", text = "All that waving about and not even a spark.", low = { agreeableness = 0.4 } },

	-- ─── Big ────────────────────────────────────────────────────────────────
	{ cat = "noticed_big", text = "Gods above. Who are you?" },
	{ cat = "noticed_big", text = "I've never seen anyone throw that much at once." },
	{ cat = "noticed_big", text = "Do that again! Do it again!", child = true },
	{ cat = "noticed_big", text = "You've been at it a long time to cast like that.", mage = true },
	{ cat = "noticed_big", text = "That's too much for a town street, friend.", occ = { "guard" } },
	{ cat = "noticed_big", text = "Remind me to stay on your good side.", high = { extraversion = 0.55 } },
	{ cat = "noticed_big", text = "Showing off, are we?", low = { agreeableness = 0.4 } },

	-- ─── A real mage, unimpressed ───────────────────────────────────────────
	{ cat = "noticed_weak", text = "Keep at it. Everyone starts small.", mage = true, high = { agreeableness = 0.5 } },
	{ cat = "noticed_weak", text = "That was a spark. You'll know a flame when you cast one.", mage = true },
	{ cat = "noticed_weak", text = "Your stance is off. Feet wider.", mage = true, high = { conscientiousness = 0.55 } },
	{ cat = "noticed_weak", text = "Hm. I did that at your age.", mage = true, low = { agreeableness = 0.45 } },

	-- ─── Practice ───────────────────────────────────────────────────────────
	{ cat = "noticed_dummy", text = "Do that again!", child = true },
	{ cat = "noticed_dummy", text = "Poor dummy. What did it ever do to you?", child = true },
	{ cat = "noticed_dummy", text = "Got it right in the middle!", child = true },
	{ cat = "noticed_dummy", text = "Good shot.", high = { extraversion = 0.5 } },
	{ cat = "noticed_dummy", text = "That dummy's had a hard week.", high = { extraversion = 0.6 } },
	{ cat = "noticed_dummy", text = "Again, and slower. Watch what it does when it lands.", mage = true },
	{ cat = "noticed_dummy", text = "Better a dummy than a person. Keep practising.", occ = { "guard", "hunter" } },

	-- ─── What kind of spell ─────────────────────────────────────────────────
	{ cat = "noticed_heal", text = "Did you just mend that? With your hands?" },
	{ cat = "noticed_heal", text = "Now that's magic worth having." },
	{ cat = "noticed_heal", text = "You could do my work with that. Steady hands, though.", occ = { "healer", "herbalist" } },
	{ cat = "noticed_heal", text = "Can you fix my knee?", occ = { "retired" } },
	{ cat = "noticed_protect", text = "You look like you're expecting trouble." },
	{ cat = "noticed_protect", text = "Is there something coming we should know about?", high = { neuroticism = 0.55 } },
	{ cat = "noticed_protect", text = "A shield! Can I hit it?", child = true },
	{ cat = "noticed_boost", text = "Feeling stronger, are we?" },
	{ cat = "noticed_control", text = "Whatever that was, I don't want it on me." },
	{ cat = "noticed_move", text = "You were there, and now you're here!", child = true },
	{ cat = "noticed_move", text = "Don't pop up like that. My heart." },
	{ cat = "noticed_sense", text = "What are you looking for?" },
	{ cat = "noticed_sense", text = "Your eyes went strange just then." },
	{ cat = "noticed_utility", text = "Handy, that." },

	-- ─── By domain ──────────────────────────────────────────────────────────
	{ cat = "noticed_energy", text = "Fire, in the open? Bold." },
	{ cat = "noticed_energy", text = "Smells like a struck flint round here now." },
	{ cat = "noticed_energy", text = "Mind the sparks! Everything here burns.", fear = { "fire" } },
	{ cat = "noticed_energy", text = "Could you light my forge like that?", occ = { "smith" } },
	{ cat = "noticed_energy", text = "It went crack! Like lightning!", child = true },
	{ cat = "noticed_earth", text = "The stones listen to you, then." },
	{ cat = "noticed_earth", text = "Can you do anything about my field? It's all rock.", occ = { "farmer" } },
	{ cat = "noticed_earth", text = "I could use hands like yours down the mine.", occ = { "miner", "builder" } },
	{ cat = "noticed_water", text = "Water does as it's told for you." },
	{ cat = "noticed_water", text = "We could use that in the dry months.", occ = { "farmer", "herbalist" } },
	{ cat = "noticed_water", text = "Not too much. I don't like deep water.", fear = { "deep_water" } },
	{ cat = "noticed_water", text = "Splash me! Splash me!", child = true },
	{ cat = "noticed_air", text = "Felt that wind from here." },
	{ cat = "noticed_air", text = "You've blown my hat clean off. Well, nearly.", high = { extraversion = 0.5 } },
	{ cat = "noticed_air", text = "Can you push the clouds? Make it rain for the barley?", occ = { "farmer", "weathercaller" } },
	{ cat = "noticed_life", text = "Things grow for you, don't they?" },
	{ cat = "noticed_life", text = "Lovely. Do my garden next.", high = { agreeableness = 0.5 } },
	{ cat = "noticed_life", text = "That's real healer's work.", occ = { "healer", "herbalist" } },
	{ cat = "noticed_mind", text = "Don't go poking about in my head." },
	{ cat = "noticed_mind", text = "Hm. I forgot what I was saying.", high = { openness = 0.55 } },
	{ cat = "noticed_mind", text = "Mind magic. Keep it to yourself.", fear = { "mages" } },
	{ cat = "noticed_spirit", text = "Cold went through me just then." },
	{ cat = "noticed_spirit", text = "My grandmother would say you've talked to the dead.", high = { openness = 0.5 } },
	{ cat = "noticed_spirit", text = "That's a temple thing. You shouldn't do it in the street.", occ = { "tidepriest" } },
	{ cat = "noticed_void", text = "Where did the light go? Where did it go?" },
	{ cat = "noticed_void", text = "I don't like that. I don't like that at all.", fear = { "void", "dark" } },
	{ cat = "noticed_void", text = "It looked like a hole in the air!", child = true },
	{ cat = "noticed_space", text = "The street went... folded? Did it fold?" },
	{ cat = "noticed_space", text = "My eyes hurt looking at that.", high = { neuroticism = 0.5 } },
	{ cat = "noticed_time", text = "Did I just blink twice? I swear I blinked twice." },
	{ cat = "noticed_time", text = "Everything went slow. Didn't it? Didn't it go slow?" },
	{ cat = "noticed_gravity", text = "My feet went light! Did you do that?" },
	{ cat = "noticed_gravity", text = "Things fell the wrong way just then." },
	{ cat = "noticed_reality", text = "That wasn't there. Was it there? It wasn't there." },
	{ cat = "noticed_reality", text = "I don't trust my own eyes now." },

	-- ─── Anyone, anything ───────────────────────────────────────────────────
	{ cat = "noticed_any", text = "Huh. Neat." },
	{ cat = "noticed_any", text = "Not something you see every day." },
	{ cat = "noticed_any", text = "Again! Do it again!", child = true },
	{ cat = "noticed_any", text = "How do you do that?", child = true },
	{ cat = "noticed_any", text = "Clean work.", mage = true },
	{ cat = "noticed_any", text = "Magic in the street. Whatever next.", low = { openness = 0.4 } },
	{ cat = "noticed_any", text = "Careful with that, now.", high = { neuroticism = 0.55 } },
	{ cat = "noticed_any", text = "Oh, that's lovely.", high = { agreeableness = 0.6 } },
	{ cat = "noticed_any", text = "Mages. Can't go a day.", fear = { "mages" } },

	-- ─── Heard from afar, asked later ───────────────────────────────────────
	{ cat = "heard_killed", text = "We heard something die out {direction}. Was that you?" },
	{ cat = "heard_killed", text = "Something screamed out {direction} earlier. Then nothing. You'd know about that?", high = { neuroticism = 0.5 } },
	{ cat = "heard_mythic", text = "Something happened out {direction}. The air went wrong. Was that you?" },
	{ cat = "heard_mythic", text = "The old ones are talking about what happened out {direction}. You've the look of it.", occ = { "retired", "scholar", "tidepriest" } },
	{ cat = "heard_mythic", text = "Was that you, out {direction}? I felt it in my bones.", mage = true },
	{ cat = "heard_land", text = "Was that you, out {direction}? The whole house shook." },
	{ cat = "heard_land", text = "Something shook the ground out {direction}. Cracked my good jug.", occ = { "innkeeper", "merchant" } },
	{ cat = "heard_land", text = "The ground moved! Out {direction}! Was it you?", child = true },
	{ cat = "heard_land", text = "If that was you out {direction}, there'd better not be a hole in my field.", occ = { "farmer" } },
	{ cat = "heard_energy", text = "We saw the flash from here, out {direction}. Was that you?" },
	{ cat = "heard_energy", text = "Lightning with no storm, out {direction}. Was that you?", occ = { "weathercaller" } },
	{ cat = "heard_earth", text = "Did you hear that rumble out {direction}? Was it you?" },
	{ cat = "heard_water", text = "There was a roar of water out {direction}. Was that you?" },
	{ cat = "heard_air", text = "A wind came out of nowhere, from the {direction}. You?" },
	{ cat = "heard_life", text = "Someone said the trees went wild out {direction}. Was that you?" },
	{ cat = "heard_mind", text = "Half the street got a headache at once. Something out {direction}, they said. You?" },
	{ cat = "heard_spirit", text = "The dogs howled at nothing, looking {direction}. Know anything about that?" },
	{ cat = "heard_void", text = "It went dark out {direction}, middle of the day. Was that you?" },
	{ cat = "heard_space", text = "Something looked wrong out {direction}. Bent. Was that you?" },
	{ cat = "heard_any", text = "Was that you, out {direction}? We heard it from here." },
	{ cat = "heard_any", text = "Something big happened out {direction}. You've the look of someone who'd know." },
	{ cat = "heard_any", text = "Everyone's talking about what happened out {direction}. That was you, wasn't it?", high = { extraversion = 0.5 } },
	{ cat = "heard_any", text = "Was that you, out {direction}? Tell me it was you!", child = true },
}

return Lines
