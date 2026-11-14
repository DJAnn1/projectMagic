--!strict
--[[
	Dreams: what you dream when you sleep in a bed (docs/Dreams.md; rules in Server/Magic/Dreams,
	the service is Services/DreamService).

	SERVER ONLY. A dream can be about a hidden latent, so this table, the rules and the choice never
	leave the server: the client receives only the finished line, through the Journal.

	A dream about a latent is built from up to three sentences, by clarity:
		1  an IMAGE of what the latent touches   (domains[target], capacity, temperaments[target])
		2  + a sentence saying it felt like YOURS (kinds[kind])
		3  + a hint at what might wake it         (triggers[category], the latent's trigger category)
	Mythic latents and mythic domains have NO lines here on purpose: they are never dreamt.
	No line may hold a digit, a domain's name or a number (Tests/Dreams.spec checks the digits).

	sleep      real seconds lying in a bed before you drift off (night or day), and how long the
	           drift lasts before the dream is written
	gapSeconds real seconds between two dreams, on top of one dream per in-game day
	ordinaryChance   the share of nights you dream of nothing in particular even with hidden latents,
	           so that dreaming never proves you have one
	clarityStep      dreams about the same latent per clarity step (1-2 vague, 3-4 clearer, 5+ clear)
]]

export type Kind = { mine: { string }, recalled: { string } }

local Dreams = {
	sleep = { night = 25, day = 60, drift = 4, nightFrom = 20, nightTo = 6 },
	gapSeconds = 600,
	ordinaryChance = 0.3,
	clarityStep = 2,
	knowledgeBonusAt = 3, -- self-knowledge level that makes every dream one step clearer

	domains = {
		energy = {
			"I dreamt of a fire that wouldn't stay in the hearth. It kept climbing the walls toward me, and it wasn't hot.",
			"I dreamt of a storm with no rain in it, only light, and the hair on my arms stood up long after I woke.",
			"I dreamt the sun came down to the edge of the field and waited there, humming, like it was waiting to be asked.",
		},
		earth = {
			"I dreamt the ground under the bed was breathing, slow, the way stone would breathe if it could.",
			"I dreamt of a mountain turning over in its sleep, and every stone in it turning with it.",
			"I dreamt my hands were pressed flat on cold rock, and the rock was pressing back.",
		},
		water = {
			"I dreamt of water, and something under it that wasn't water.",
			"I dreamt of a tide coming in over dry land, unhurried, and it parted around me like it knew my name.",
			"I dreamt of rain falling upward, every drop of it, back into a sky that was waiting.",
		},
		air = {
			"I dreamt of wind in a closed room, going round and round, looking for a way out through me.",
			"I dreamt I was standing on nothing, high up, and nothing was holding me.",
			"I dreamt of a whistle so high I felt it instead of hearing it, coming from everywhere at once.",
		},
		life = {
			"I dreamt of roots coming up through the floorboards, gently, and none of them were hungry.",
			"I dreamt of a heartbeat that wasn't mine, then a hundred of them, all around me in the dark.",
			"I dreamt of green things growing over a grave until there was no grave, only a meadow.",
		},
		mind = {
			"I dreamt I could hear everyone in the town thinking at once, like a market heard from a hill.",
			"I dreamt of a door inside someone else's head, and it was open, and I knew how to walk through it.",
			"I dreamt of my own thoughts laid out on a table, and someone else was reading them back to me in my voice.",
		},
		spirit = {
			"I dreamt the dead were standing at the edge of the light, not angry, just waiting to be noticed.",
			"I dreamt of a pale thread running out of my chest and off into the dark, and something on the other end tugged it.",
			"I dreamt of a choir with no singers, and the song had a place in it shaped like me.",
		},
		void = {
			"I dreamt of a hole in the night sky where no stars were, and it was the quietest thing I've ever seen.",
			"I dreamt that everything around me went out, one thing at a time, and I wasn't afraid of it.",
			"I dreamt of a cold that wasn't cold, only an absence, and it fit around my hands like a glove.",
		},
		space = {
			"I dreamt the room was bigger on the inside than the house, and the far wall kept moving away.",
			"I dreamt I took one step and was on the other side of the island, and nobody thought it strange.",
			"I dreamt of a fold in the air, like a curtain, and something on the far side of it was the same place.",
		},
	} :: { [string]: { string } },

	capacity = {
		"I dreamt of a well in the dark. I kept lowering the bucket and the rope never ran out.",
		"I dreamt I was a jar, and someone kept pouring, and I never filled.",
		"I dreamt of a cellar under my house I'd never seen, going down and down, every room of it empty and waiting.",
	},

	temperaments = {
		volatile = { "I dreamt I was holding a lit lamp in a room full of straw, and part of me wanted to drop it." },
		precise = { "I dreamt of a needle passing through the eye of another needle, again and again, never touching." },
		resonant = { "I dreamt of a bell. When anyone near me spoke, it rang, and it rang louder the more of us there were." },
		hollow = { "I dreamt of a reed, empty all the way through, and the wind made it sing." },
		deepwell = { "I dreamt of a lake so deep the bottom was night, slow to fill and slower to empty." },
		swift = { "I dreamt of a hare that was always already where it was going." },
		patient = { "I dreamt of a tree that grew one ring a night, and every ring made it stronger." },
		steadfast = { "I dreamt of a wall in a flood. The water broke over it all night and in the morning it was still there." },
		brittle = { "I dreamt of thin ice over deep water, beautiful, and I could hear it creak under my feet." },
		conduit = { "I dreamt of a river running through me instead of past me, and I was only the bed it ran in." },
		bloodbound = { "I dreamt of my own pulse, loud and red, and how much it could carry if I let it." },
		subtle = { "I dreamt I walked through a crowded hall and nobody turned their head, though I wasn't hiding." },
		radiant = { "I dreamt I was a lamp in a dark street, and everyone who passed looked straight at me." },
	} :: { [string]: { string } },

	kinds = {
		Domain = {
			mine = {
				"I've never touched anything like it awake. In the dream it already knew me.",
				"It wasn't a place I was visiting. It felt like a room in me I haven't opened.",
			},
			recalled = {
				"I've dreamt of this before. Now it's in my hands, and it feels exactly the way the dream did.",
				"The dream was right. Whatever was waiting in me has woken.",
			},
		},
		Amplify = {
			mine = {
				"It was something I already know, only louder than I've ever let it be.",
				"It felt like my own magic with a door taken off its hinges.",
			},
			recalled = {
				"I've dreamt of this. It's the same magic I had, only the door the dream showed me is open now.",
				"Something I already knew just got louder, the way it did in the dream.",
			},
		},
		Capacity = {
			mine = {
				"I woke sure the well was me.",
				"There's more room in me than I've been using. The dream was certain of it.",
			},
			recalled = {
				"I've dreamt of that well. Today the rope went further down than it ever has.",
				"I feel deeper than I was, the way the dream promised.",
			},
		},
		Temperament = {
			mine = {
				"It wasn't something I did in the dream. It was how I was.",
				"I woke feeling it was a truer picture of me than any mirror.",
			},
			recalled = {
				"I've dreamt of this. Something in the way I am has turned, the way it did in the dream.",
				"I'm not quite who I was yesterday. I saw this coming, asleep.",
			},
		},
	} :: { [string]: Kind },

	-- One clue per awakening category (Server/Magic/Data/AwakeningEvents categories, minus Mythic).
	triggers = {
		Danger = {
			"In the dream it only opened when I was a breath from dying.",
			"It came when something meant to kill me, and didn't manage it.",
		},
		Location = {
			"It wasn't waiting in me. It was waiting in a place, and the place knew I'd come.",
			"Somewhere out there is ground that would wake it if I stood on it long enough.",
		},
		Mentor = {
			"Someone stronger than me was teaching, and it woke while I listened.",
			"In the dream someone older showed me, patiently, until it answered.",
		},
		Ritual = {
			"It answered to a vow, or a vigil. Something done slowly and on purpose.",
			"I was kneeling, and keeping some long promise, when it opened.",
		},
		Emotion = {
			"It came up out of grief, or fury, or love. Something that tore at me.",
			"It only woke when I felt something too big to hold.",
		},
		Experiment = {
			"I was making something that had never been made, and it woke from the mess.",
			"It came out of a mistake. A bad mix, a spell nobody had tried.",
		},
	} :: { [string]: { string } },

	-- Nights you dream of nothing in particular (always, if you have no hidden latents).
	ordinary = {
		"I dreamt I was late for something in a town I'd never been to, and couldn't find the door.",
		"I dreamt of my first spell, only in the dream it went right.",
		"I dreamt of a long market day, every stall selling bread, and nobody would take my coin.",
		"I dreamt of rain on a roof, and nothing else. I woke rested.",
		"I dreamt I was walking a road that kept getting longer behind me.",
		"I dreamt of people I used to know, sitting around a table, talking about the weather.",
		"I dreamt I'd forgotten how to read, and every book I opened was full of birds.",
		"I dreamt of a dog that followed me all night and never barked once.",
		"I dreamt I was falling and woke with a start before I hit anything.",
		"I dreamt of a feast in a hall with no walls, and the wind kept blowing out the candles.",
		"I slept without dreaming at all, and woke clear-headed.",
		"I dreamt of a fight I'd already won, only this time I lost it, slowly.",
		"I dreamt I was a child again, hiding from someone who wasn't looking very hard.",
		"I dreamt of the sea, plain and grey and endless, and woke a little sad.",
	},
}

return Dreams
