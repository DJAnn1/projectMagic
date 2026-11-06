--!strict
--[[
	SceneTemplates: small stories that happen whether or not anyone's watching (docs/LivingWorld.md §5).
	Pure data; Services/SceneDirector runs them. First 10 of the planned 40.

	A TEMPLATE
		id, name
		where         "plaza" (near the town centre) | "edge" (just outside the buildings)
		hours         { from, to } game hours it can start
		weekday       optional: only on this weekday (0 = Sunday)
		weight        how often, against the others that fit
		actors        role -> { occupations = {...} or nil for any adult, child = true, mage = true,
		                        spawn = occupation (a stranger made for the scene, removed after),
		                        name = for a stranger }
		              A resident role takes someone awake and free in this town; no one fits = no scene.
		intro         steps, run in order when someone's there to see it
		wait          seconds the scene holds, open to a player stepping in
		interventions { kind, ..., outcome } what a player can do to change it (below)
		outcomes      id -> {
		                  weight    chance when nobody steps in (and whenever nobody's watching);
		                            0 or nil = only a player can cause it
		                  story     what people say afterwards: a clause after "Did you hear?", lower case.
		                            {a}, {b}... are actors' names; {town} the town
		                  steps     what plays out, if someone's there to see it
		                  rep       town reputation for the player who caused it
		                  bond      { role, delta, memory } what an actor now thinks of that player
		                  remember  { { role, kind, about } } actors' memories of each other. These feed
		                            the normal NPC gossip, with or without a player
		              }

	STEPS
		{ "go", role, mark }             walk there. Marks: center, left, right, front, back, far
		{ "say", role, text }            a speech bubble. Same vars as a story
		{ "clip", role, slot }           Data/Activities.Clips, once
		{ "hold", role, slot }           the same, looped until the scene ends
		{ "cast", role, targetRole }     a harmless cosmetic bolt from their own magic
		{ "creatures", type, count }     wild creatures at the scene (real ones: they fight players)
		{ "wait", seconds }

	INTERVENTIONS
		{ kind = "clear", outcome }                    every creature in the scene was killed by a player
		{ kind = "talk", role, outcome }               a player spoke to that actor
		{ kind = "hit", role, outcome }                a player hit that actor
		{ kind = "magic", domains = {...}, outcome }   a player landed a spell of those domains close by.
		                                               No `domains` = any spell. harmless = true: not an attack
]]

export type Step = { any }

export type Outcome = {
	weight: number?,
	story: string,
	steps: { Step }?,
	rep: number?,
	bond: { role: string, delta: number, memory: string? }?,
	remember: { { role: string, kind: string, about: string } }?,
}

export type Template = {
	id: string,
	name: string,
	where: string,
	hours: { number },
	weekday: number?,
	weight: number,
	actors: { [string]: { occupations: { string }?, child: boolean?, mage: boolean?, spawn: string?, name: string? } },
	intro: { Step },
	wait: number,
	interventions: { { [string]: any } },
	outcomes: { [string]: Outcome },
}

local Templates: { Template } = {
	{
		id = "caravan_ambush", name = "A caravan under attack", where = "edge", hours = { 7, 20 }, weight = 1.2,
		actors = {
			a = { spawn = "merchant", name = "Tobren the Carter" },
			b = { spawn = "guard", name = "a caravan guard" },
		},
		intro = {
			{ "go", "a", "center" }, { "go", "b", "front" },
			{ "creatures", "gloom_rat", 4 },
			{ "wait", 1 },
			{ "say", "a", "Rats! They're in the grain! Get them off the cart!" },
			{ "clip", "b", "hammer" },
			{ "say", "b", "There's too many! Somebody help us!" },
		},
		wait = 45,
		interventions = { { kind = "clear", outcome = "saved" } },
		outcomes = {
			saved = {
				story = "a stranger drove the gloom rats off a caravan outside {town}", rep = 4,
				bond = { role = "a", delta = 0.5, memory = "saved_me" },
				steps = { { "clip", "a", "cheer" }, { "say", "a", "You saved the lot! Whatever you need, in any town I pass." } },
			},
			lost_goods = {
				weight = 0.65, story = "gloom rats ate a whole caravan's grain outside {town}",
				steps = { { "say", "a", "A whole season's grain. Gone. Leave it, it's over." }, { "go", "a", "far" }, { "go", "b", "far" } },
			},
			drove_off = {
				weight = 0.35, story = "a caravan guard held off a swarm of gloom rats near {town}",
				steps = { { "clip", "b", "cheer" }, { "say", "b", "That's the last of them. Move, before more come." }, { "go", "a", "far" }, { "go", "b", "far" } },
			},
		},
	},
	{
		id = "apprentice_duel", name = "Two apprentices duelling", where = "plaza", hours = { 9, 20 }, weight = 1.4,
		actors = { a = { mage = true }, b = { mage = true } },
		intro = {
			{ "go", "a", "left" }, { "go", "b", "right" }, { "wait", 4 },
			{ "say", "a", "Take it back, {b}, or I'll make you." },
			{ "say", "b", "You couldn't light a damp candle." },
			{ "cast", "a", "b" }, { "wait", 2 }, { "cast", "b", "a" },
		},
		wait = 25,
		interventions = {
			{ kind = "talk", role = "a", outcome = "calmed" },
			{ kind = "talk", role = "b", outcome = "calmed" },
			{ kind = "magic", harmless = true, outcome = "upstaged" },
		},
		outcomes = {
			calmed = {
				story = "someone talked {a} and {b} out of a duel in {town}", rep = 2,
				bond = { role = "a", delta = 0.2, memory = "helped_me" },
				steps = { { "say", "a", "...Fine. Fine! Not today." }, { "say", "b", "Lucky for you." } },
			},
			upstaged = {
				story = "a passing mage out-cast {a} and {b} in the middle of their duel", rep = 1,
				steps = { { "clip", "b", "cheer" }, { "say", "b", "How did you do that? Show me!" }, { "say", "a", "...That was better than both of us." } },
			},
			a_wins = {
				weight = 0.5, story = "{a} beat {b} in a duel in {town}, and won't stop talking about it",
				remember = { { role = "b", kind = "duel_lost", about = "a" }, { role = "a", kind = "duel_won", about = "b" } },
				steps = { { "cast", "a", "b" }, { "clip", "a", "cheer" }, { "say", "a", "Ha! Say it again, then." }, { "say", "b", "...I slipped." } },
			},
			b_wins = {
				weight = 0.5, story = "{b} beat {a} in a duel in {town}, and won't stop talking about it",
				remember = { { role = "a", kind = "duel_lost", about = "b" }, { role = "b", kind = "duel_won", about = "a" } },
				steps = { { "cast", "b", "a" }, { "clip", "b", "cheer" }, { "say", "b", "Damp candle, you said?" }, { "say", "a", "...I wasn't ready." } },
			},
		},
	},
	{
		id = "farmer_hermit", name = "A farmer and a hermit argue", where = "edge", hours = { 7, 18 }, weight = 1,
		actors = {
			a = { occupations = { "farmer", "builder", "hunter" } },
			b = { spawn = "retired", name = "Old Sennet" },
		},
		intro = {
			{ "go", "a", "left" }, { "go", "b", "right" }, { "wait", 4 },
			{ "say", "a", "Your goats were in my beans again, Sennet!" },
			{ "say", "b", "Beans on my hill, you mean." },
			{ "clip", "a", "point" },
			{ "say", "a", "Your hill! Since when?" },
			{ "say", "b", "Since before your grandfather could count." },
		},
		wait = 30,
		interventions = {
			{ kind = "talk", role = "a", outcome = "settled" },
			{ kind = "talk", role = "b", outcome = "settled" },
		},
		outcomes = {
			settled = {
				story = "someone settled the old argument between {a} and the hermit on the hill", rep = 2,
				bond = { role = "a", delta = 0.25, memory = "helped_me" },
				steps = { { "say", "b", "Hmph. Half the beans, then." }, { "say", "a", "A third." }, { "say", "b", "...A third." } },
			},
			stalemate = {
				weight = 0.7, story = "{a} and the hermit on the hill still aren't speaking",
				steps = { { "say", "b", "We're done here." }, { "go", "b", "far" }, { "say", "a", "And stay off my beans!" } },
			},
			shoving = {
				weight = 0.3, story = "{a} got into a shoving match with the old hermit, of all people",
				steps = { { "clip", "a", "hammer" }, { "say", "b", "Eighty years old and I'd still flatten you!" }, { "go", "b", "far" } },
			},
		},
	},
	{
		id = "moth_passage", name = "Moths on the move", where = "edge", hours = { 17, 23 }, weight = 0.9,
		actors = { a = { occupations = { "hunter", "farmer", "guard", "weathercaller" } } },
		intro = {
			{ "go", "a", "front" },
			{ "creatures", "gust_moth", 5 },
			{ "wait", 3 },
			{ "clip", "a", "point" },
			{ "say", "a", "Look at that. Hundreds of them, heading inland." },
		},
		wait = 35,
		interventions = { { kind = "clear", outcome = "thinned" } },
		outcomes = {
			thinned = {
				story = "someone cut down a whole flight of gust moths near {town}, and the old folk say it's bad luck", rep = -1,
				steps = { { "say", "a", "...You didn't have to do that, you know." } },
			},
			passed = {
				weight = 1, story = "the gust moths went over {town} at dusk, heading inland",
				steps = { { "say", "a", "They always know before we do. Wonder what's coming." } },
			},
		},
	},
	{
		id = "wounded_stranger", name = "A wounded stranger by the road", where = "edge", hours = { 6, 22 }, weight = 1,
		actors = { a = { spawn = "hunter", name = "a wounded stranger" } },
		intro = {
			{ "go", "a", "center" },
			{ "hold", "a", "sit" },
			{ "wait", 2 },
			{ "say", "a", "Please... is anyone there?" },
			{ "wait", 10 },
			{ "say", "a", "Something on the road. Claws. I don't think I can walk." },
		},
		wait = 60,
		interventions = {
			{ kind = "magic", domains = { "life" }, harmless = true, outcome = "healed" },
			{ kind = "talk", role = "a", outcome = "aided" },
		},
		outcomes = {
			healed = {
				story = "a mage healed a dying stranger on the road outside {town}, and asked nothing for it", rep = 5,
				bond = { role = "a", delta = 0.6, memory = "healed_me" },
				steps = { { "clip", "a", "wave" }, { "say", "a", "It's closing. I can feel it closing. Thank you. Thank you." } },
			},
			aided = {
				story = "someone stopped to help a wounded stranger outside {town}", rep = 3,
				bond = { role = "a", delta = 0.4, memory = "helped_me" },
				steps = { { "say", "a", "You stopped. Nobody stops. The town... I can make it now." } },
			},
			carried = {
				weight = 0.7, story = "a wounded stranger was carried into {town}, muttering about claws on the road",
				steps = { { "say", "a", "There. Someone's coming. Thank the tide." } },
			},
			gone = {
				weight = 0.3, story = "a stranger crawled off the road outside {town} and hasn't been seen since",
				steps = { { "say", "a", "...Never mind. I'll manage." } },
			},
		},
	},
	{
		id = "rival_test", name = "A mage testing something dangerous", where = "edge", hours = { 20, 4 }, weight = 0.8,
		actors = { a = { mage = true } },
		intro = {
			{ "go", "a", "center" }, { "wait", 3 },
			{ "say", "a", "Once more. Only a little more this time." },
			{ "hold", "a", "hold" },
			{ "cast", "a", "a" }, { "wait", 4 }, { "cast", "a", "a" },
			{ "say", "a", "Yes. Yes! It holds! Nearly holds..." },
		},
		wait = 30,
		interventions = { { kind = "talk", role = "a", outcome = "stopped" } },
		outcomes = {
			stopped = {
				story = "someone caught {a} testing a dangerous spell outside {town} at night, and talked them out of it", rep = 2,
				bond = { role = "a", delta = -0.05, memory = "talked_kindly" },
				steps = { { "say", "a", "You saw nothing. ...You're right. It wasn't stable. Don't tell the school." } },
			},
			success = {
				weight = 0.6, story = "there were strange lights outside {town} last night, and {a} is looking very pleased with themselves",
				remember = { { role = "a", kind = "invention", about = "a" } },
				steps = { { "clip", "a", "cheer" }, { "say", "a", "It works. It actually works!" } },
			},
			backlash = {
				weight = 0.4, story = "{a} came home singed and won't say why",
				remember = { { role = "a", kind = "backlash", about = "a" } },
				steps = { { "cast", "a", "a" }, { "say", "a", "Ah! AH! No, no, no..." } },
			},
		},
	},
	{
		id = "festival_procession", name = "A rest-day procession", where = "plaza", hours = { 10, 17 }, weekday = 0, weight = 2.5,
		actors = {
			a = { occupations = { "tidepriest", "scholar", "healer", "retired", "innkeeper" } },
			b = {},
			c = { child = true },
		},
		intro = {
			{ "go", "a", "left" }, { "go", "b", "back" }, { "go", "c", "front" }, { "wait", 4 },
			{ "say", "a", "A good rest-day to {town}, and everyone in it!" },
			{ "hold", "b", "dance" }, { "hold", "c", "dance" },
			{ "go", "a", "right" },
			{ "say", "c", "Faster! Go faster!" },
		},
		wait = 30,
		interventions = { { kind = "magic", harmless = true, outcome = "dazzled" } },
		outcomes = {
			dazzled = {
				story = "a stranger lit up the rest-day procession in {town} with magic, and the children won't talk about anything else", rep = 2,
				bond = { role = "c", delta = 0.3, memory = "impressed_me" },
				steps = { { "clip", "c", "cheer" }, { "say", "c", "Again! AGAIN!" }, { "clip", "a", "cheer" } },
			},
			quiet = {
				weight = 1, story = "{town} held its rest-day procession, and {a} led it",
				steps = { { "clip", "a", "wave" }, { "say", "a", "Until next rest-day, then. Go on, go home." } },
			},
		},
	},
	{
		id = "lost_child", name = "A lost child", where = "plaza", hours = { 9, 19 }, weight = 1,
		actors = { a = { child = true }, b = {} },
		intro = {
			{ "go", "a", "far" }, { "go", "b", "left" }, { "wait", 3 },
			{ "say", "b", "{a}! {a}, where have you got to?" },
			{ "clip", "b", "point" },
			{ "wait", 6 },
			{ "say", "b", "Has anyone seen {a}? About so high. Trouble." },
		},
		wait = 35,
		interventions = {
			{ kind = "talk", role = "a", outcome = "found" },
			{ kind = "talk", role = "b", outcome = "asked" },
		},
		outcomes = {
			found = {
				story = "someone found {a} when the whole of {town} was looking", rep = 3,
				bond = { role = "b", delta = 0.4, memory = "helped_me" },
				steps = { { "go", "a", "left" }, { "say", "b", "There you are! Don't you ever... Thank you. Thank you." } },
			},
			asked = {
				story = "{town} turned out to look for {a}, and a stranger helped", rep = 1,
				bond = { role = "b", delta = 0.15 },
				steps = { { "say", "b", "You'll keep an eye out? Bless you." }, { "go", "a", "left" }, { "say", "a", "I was only looking at the frogs!" } },
			},
			turned_up = {
				weight = 1, story = "{a} went missing in {town} and turned up by the water, perfectly happy",
				steps = { { "go", "a", "left" }, { "say", "a", "I was only looking at the frogs!" }, { "say", "b", "Frogs. FROGS." } },
			},
		},
	},
	{
		id = "market_quarrel", name = "A row at the market", where = "plaza", hours = { 8, 18 }, weight = 1.3,
		actors = { a = { occupations = { "merchant", "innkeeper", "smith" } }, b = {}, c = { occupations = { "guard" } } },
		intro = {
			{ "go", "a", "left" }, { "go", "b", "right" }, { "wait", 3 },
			{ "say", "b", "This is half what you promised me, {a}!" },
			{ "clip", "a", "point" },
			{ "say", "a", "It's what you paid for. Read the scales!" },
			{ "say", "b", "Your scales are a liar and so are you!" },
			{ "go", "c", "front" },
		},
		wait = 25,
		interventions = {
			{ kind = "talk", role = "a", outcome = "smoothed" },
			{ kind = "talk", role = "b", outcome = "smoothed" },
		},
		outcomes = {
			smoothed = {
				story = "a stranger stopped {a} and {b} coming to blows at the market in {town}", rep = 2,
				bond = { role = "b", delta = 0.2, memory = "helped_me" },
				steps = { { "say", "a", "...Fine. A little extra. This once." }, { "say", "b", "That's all I ever asked." } },
			},
			guard_steps_in = {
				weight = 0.7, story = "the watch had to separate {a} and {b} at the market in {town}",
				steps = { { "say", "c", "Enough! Both of you, or it's a night in the cells." }, { "say", "b", "This isn't over." } },
			},
			blows = {
				weight = 0.3, story = "{a} and {b} came to blows at the market in {town}",
				remember = { { role = "a", kind = "talked_rudely", about = "b" }, { role = "b", kind = "cheated_me", about = "a" } },
				steps = { { "clip", "b", "hammer" }, { "say", "a", "You hit me! You all saw that!" }, { "say", "c", "That's it. You, come with me." } },
			},
		},
	},
	{
		id = "pickpocket", name = "A thief in the crowd", where = "plaza", hours = { 9, 21 }, weight = 1,
		actors = {
			a = { occupations = { "merchant", "innkeeper", "scholar", "smith" } },
			b = { spawn = "merchant", name = "a quick-fingered stranger" },
			c = { occupations = { "guard" } },
		},
		intro = {
			{ "go", "b", "center" }, { "go", "a", "left" }, { "wait", 4 },
			{ "go", "b", "far" },
			{ "clip", "a", "point" },
			{ "say", "a", "My purse! Stop them! THAT one, stop them!" },
			{ "go", "c", "far" },
			{ "say", "c", "You there! Hold!" },
		},
		wait = 20,
		interventions = {
			{ kind = "hit", role = "b", outcome = "caught" },
			{ kind = "talk", role = "b", outcome = "shamed" },
		},
		outcomes = {
			caught = {
				story = "someone brought down a thief in the crowd at {town}", rep = 3,
				bond = { role = "a", delta = 0.4, memory = "helped_me" },
				steps = { { "say", "b", "All right! All right! Take it back!" }, { "go", "a", "far" }, { "say", "a", "My purse! Oh, you beauty." } },
			},
			shamed = {
				story = "a thief handed back a purse in {town} after a stranger had a quiet word", rep = 2,
				bond = { role = "a", delta = 0.25, memory = "helped_me" },
				steps = { { "say", "b", "...Yes. Fine. It was a bad week. Here." }, { "go", "a", "far" } },
			},
			escaped = {
				weight = 0.6, story = "a thief got clean away with {a}'s purse in {town}",
				steps = { { "say", "c", "Gone. Into the back lanes." }, { "say", "a", "A month's takings! What do I pay taxes for?" } },
			},
			nabbed = {
				weight = 0.4, story = "the watch caught a pickpocket working the crowd at {town}",
				steps = { { "say", "c", "Got you. Come along." }, { "clip", "a", "cheer" } },
			},
		},
	},
}

return table.freeze(Templates)
