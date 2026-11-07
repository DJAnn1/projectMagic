--!strict
--[[
	Marks: what the magic you use most does to your body (docs/MagicMarks.md). Pure data; the rules
	are Magic/MarkRules, the server side Services/MarkService, the drawing Client/Fx/MarkFx.

	Nothing here is secret: every client draws marks from it.

	TUNING
		perCast         points one working spell adds to its domain (a hybrid splits them)
		castGap         seconds between counted casts, per player (spam earns nothing extra)
		dayCap          most points one domain can gain in one real day
		decayPerDay     share of a domain's points lost each real day (what you stop using fades)
		stages          points needed for stage 1, 2, 3
		dropAt          a shown stage stays until points fall below threshold x dropAt (no flicker)
		share           a domain must be at least this share of all your points to mark you
		keepShare       ... and keeps a mark while it stays above this share
		maxMarks        most marked domains at once: the strongest win
		resistPerStage  resistance to your own domain per stage (Cast/Resistances "marks")
		npcTiers        an NPC's best mastery tier index (Data/MasteryTiers) for stage 1, 2, 3
		unsettleWeight  how far an unsettling mark moves a nervous NPC's greeting (GreetingRules)

	A DOMAIN
		name       short word for logs and admin
		seen       { stage 1, 2, 3 } what someone sees, as a phrase NPC lines can drop in ({mark})
		unsettle   0..1: how much it bothers nervous people (Void, Spirit, Time, Reality)
		look       how it's drawn (Fx/MarkFx):
		             skin       Color3 of the marked skin
		             material   Enum.Material name for the overlay
		             alpha      overlay transparency (0 solid .. 1 invisible)
		             emit       particles off the hands: texture role in DomainFx.textures, colour,
		                        size, drift (studs/s, + up), gravity (studs/s², + down), life (s)
		             head       true: stage 3 adds a faint haze at the head
		             prints     nil, or a trace left when walking from stage 2: { color, material,
		                        alpha, size, life (s) }
		journal    { appear 1, 2, 3, fade } first-person lines in your Journal
]]

export type Emit = { texture: string, color: Color3, size: number, drift: number, gravity: number, life: number }
export type Prints = { color: Color3, material: string, alpha: number, size: number, life: number }
export type Look = {
	skin: Color3,
	material: string,
	alpha: number,
	emit: Emit,
	head: boolean,
	prints: Prints?,
}
export type Domain = {
	name: string,
	seen: { string },
	unsettle: number,
	look: Look,
	journal: { string },
}

local rgb = Color3.fromRGB

local tuning = table.freeze({
	perCast = 1,
	castGap = 2,
	dayCap = 600,
	decayPerDay = 0.02,
	stages = { 250, 1200, 4000 },
	dropAt = 0.85,
	share = 0.35,
	keepShare = 0.25,
	maxMarks = 2,
	resistPerStage = 0.04,
	npcTiers = { 4, 6, 7 }, -- Skilled, Master, Grandmaster
	unsettleWeight = 0.35,
	-- Drawing (client)
	drawWithin = 120, -- studs: marks further off aren't drawn
	dropBeyond = 140,
	printEvery = 2.4, -- studs walked between prints
	printsMax = 80, -- prints alive at once on one client
	printsWithin = 70, -- studs: only characters this close leave prints
})

local domains: { [string]: Domain } = {
	energy = {
		name = "energy",
		seen = { "soot on the fingertips", "hands gone black as a smith's", "arms scorched to the shoulder" },
		unsettle = 0,
		look = {
			skin = rgb(46, 38, 34),
			material = "Slate",
			alpha = 0.25,
			emit = { texture = "fireSparks", color = rgb(255, 150, 60), size = 0.18, drift = 1.2, gravity = -1.5, life = 1.1 },
			head = true,
			prints = { color = rgb(40, 32, 28), material = "Slate", alpha = 0.35, size = 0.9, life = 9 },
		},
		journal = {
			"My fingertips have gone dark, like I've been raking a fire bare-handed. They don't wash clean.",
			"The black has spread past my wrists. My hands are always warm now, even in the cold.",
			"I'm scorched to the shoulder. Embers come off my skin when I'm angry, and grass browns where I've stood.",
			"The soot on my hands is lighter than it was. The fire's letting go of me.",
		},
	},
	earth = {
		name = "earth",
		seen = { "grit in the knuckles", "hands gone grey as stone", "arms like weathered granite" },
		unsettle = 0,
		look = {
			skin = rgb(128, 124, 116),
			material = "Slate",
			alpha = 0.1,
			emit = { texture = "debris", color = rgb(120, 105, 85), size = 0.12, drift = 0.3, gravity = 8, life = 1.2 },
			head = false,
			prints = { color = rgb(95, 85, 70), material = "Ground", alpha = 0.3, size = 1, life = 10 },
		},
		journal = {
			"There's grit in the creases of my knuckles that won't scrub out. My hands feel heavier.",
			"My hands have gone grey and rough as stone. Knocks I'd have felt last month, I barely notice.",
			"My arms are stone to the shoulder now. Dust trickles off me when I move, and the ground cracks under my feet.",
			"The stone in my hands is softening back into skin.",
		},
	},
	water = {
		name = "water",
		seen = { "wet fingertips", "hands like river glass", "arms that drip and never dry" },
		unsettle = 0,
		look = {
			skin = rgb(110, 165, 205),
			material = "Glass",
			alpha = 0.45,
			emit = { texture = "sparkles", color = rgb(150, 205, 245), size = 0.14, drift = 0.2, gravity = 12, life = 0.8 },
			head = false,
			prints = { color = rgb(60, 80, 95), material = "SmoothPlastic", alpha = 0.55, size = 0.9, life = 12 },
		},
		journal = {
			"My fingertips are always damp, however long I dry them.",
			"My hands have turned faintly blue and glassy, and they drip when I'm still. I leave wet prints behind me.",
			"Water runs off my arms all day. Anything I hold for long ends up soaked.",
			"My hands stay dry for whole hours now. The water's leaving me.",
		},
	},
	air = {
		name = "air",
		seen = { "pale, chilly fingers", "hands pale as cloud", "arms that move in their own breeze" },
		unsettle = 0,
		look = {
			skin = rgb(228, 236, 242),
			material = "SmoothPlastic",
			alpha = 0.4,
			emit = { texture = "smoke", color = rgb(235, 245, 255), size = 0.4, drift = 1.6, gravity = -0.5, life = 1.3 },
			head = true,
			prints = nil,
		},
		journal = {
			"My fingers have gone pale and cold, and there's always a little draught around them.",
			"My hands are pale as cloud now. Loose things lift a little when I pass.",
			"I can't stand still without a breeze following me, and it plucks at my hair and clothes.",
			"The breeze around me has died down. My hands are warming up again.",
		},
	},
	life = {
		name = "life",
		seen = { "green under the nails", "green veins up the wrists", "arms threaded with green" },
		unsettle = 0,
		look = {
			skin = rgb(110, 160, 90),
			material = "Grass",
			alpha = 0.45,
			emit = { texture = "sparkles", color = rgb(200, 240, 140), size = 0.12, drift = 0.6, gravity = -0.3, life = 1.8 },
			head = false,
			prints = { color = rgb(90, 160, 70), material = "Grass", alpha = 0.1, size = 0.5, life = 14 },
		},
		journal = {
			"There's green under my nails, and it isn't dirt.",
			"Green veins are climbing my wrists. Little shoots come up where I stand too long.",
			"My arms are threaded with green to the shoulder. I smell of cut grass, and things grow where I've walked.",
			"The green in my veins is fading.",
		},
	},
	mind = {
		name = "mind",
		seen = { "violet bruising at the fingertips", "hands faintly violet", "arms marbled violet" },
		unsettle = 0.15,
		look = {
			skin = rgb(150, 120, 190),
			material = "SmoothPlastic",
			alpha = 0.5,
			emit = { texture = "glow", color = rgb(200, 170, 255), size = 0.22, drift = 0.5, gravity = 0, life = 1.6 },
			head = true,
			prints = nil,
		},
		journal = {
			"My fingertips look bruised, faintly violet. They ache when people lie near me.",
			"The violet has spread over my hands. Other people's moods press on me like weather.",
			"My arms are marbled violet, and something shimmers around my head when I think hard.",
			"The violet in my hands is fading, and the world's gone a little quieter.",
		},
	},
	spirit = {
		name = "spirit",
		seen = { "fingers that look half there", "hands you can almost see through", "arms like candle smoke" },
		unsettle = 0.5,
		look = {
			skin = rgb(205, 225, 235),
			material = "ForceField",
			alpha = 0.2,
			emit = { texture = "glow", color = rgb(190, 235, 255), size = 0.3, drift = 0.8, gravity = -0.8, life = 2 },
			head = true,
			prints = nil,
		},
		journal = {
			"In the right light my fingertips look half there, like the edge of a candle flame.",
			"I can almost see through my hands. Dogs won't come near me, and some people stare.",
			"My arms look like candle smoke. Cold spots follow me around.",
			"My hands look solid again.",
		},
	},
	void = {
		name = "void",
		seen = { "fingertips that drink the light", "hands too dark to look at", "arms like holes in the world" },
		unsettle = 0.7,
		look = {
			skin = rgb(14, 12, 20),
			material = "SmoothPlastic",
			alpha = 0.05,
			emit = { texture = "implode", color = rgb(40, 30, 60), size = 0.25, drift = -0.6, gravity = 0, life = 1 },
			head = true,
			prints = { color = rgb(10, 8, 14), material = "SmoothPlastic", alpha = 0.4, size = 0.85, life = 7 },
		},
		journal = {
			"My fingertips have gone dark. Not dirty: dark, as if the light doesn't land on them.",
			"My hands are too dark to look at properly. People's eyes slide off them.",
			"My arms look like holes cut in the world, and I leave dark prints wherever I walk.",
			"Light lands on my hands again.",
		},
	},
	space = {
		name = "space",
		seen = { "fingertips that shimmer at the edges", "hands that blur when they move", "arms that never sit quite where they are" },
		unsettle = 0.3,
		look = {
			skin = rgb(120, 140, 210),
			material = "ForceField",
			alpha = 0.15,
			emit = { texture = "vortex", color = rgb(150, 170, 255), size = 0.28, drift = 0.4, gravity = 0, life = 1.2 },
			head = false,
			prints = nil,
		},
		journal = {
			"The edges of my fingers shimmer, like heat over a road.",
			"My hands blur when I move them, as if they arrive a little before I do.",
			"My arms never sit quite where they are. People flinch when I reach for things.",
			"My hands have stopped shimmering.",
		},
	},
	time = {
		name = "time",
		seen = { "fingertips gone grey with age", "hands much older than the rest", "arms that age and heal as you watch" },
		unsettle = 0.55,
		look = {
			skin = rgb(190, 175, 150),
			material = "Fabric",
			alpha = 0.2,
			emit = { texture = "vortex", color = rgb(230, 210, 160), size = 0.2, drift = 0.15, gravity = 0, life = 3 },
			head = true,
			prints = nil,
		},
		journal = {
			"My fingertips look older than the rest of me: dry, lined, grey.",
			"My hands are an old person's hands. Clocks near me run a little wrong.",
			"My arms age and heal while I watch, and dust settles slowly around me, as if the air's in no hurry.",
			"My hands look my own age again.",
		},
	},
	gravity = {
		name = "gravity",
		seen = { "heavy-looking hands", "dust that clings to the hands", "arms that pull grit into orbit" },
		unsettle = 0.2,
		look = {
			skin = rgb(85, 80, 100),
			material = "Basalt",
			alpha = 0.15,
			emit = { texture = "debris", color = rgb(110, 100, 120), size = 0.1, drift = 0.25, gravity = -2, life = 2.4 },
			head = false,
			prints = { color = rgb(70, 65, 80), material = "Ground", alpha = 0.25, size = 1.1, life = 10 },
		},
		journal = {
			"My hands feel heavy, and loose dust clings to them.",
			"Grit drifts up to my hands and won't settle. My footprints go deeper than they should.",
			"Pebbles and dust circle my arms. Light things roll towards me.",
			"My hands are lighter. The dust has stopped following me.",
		},
	},
	reality = {
		name = "reality",
		seen = { "fingertips that flicker", "hands that skip like a bad memory", "arms that don't agree with themselves" },
		unsettle = 0.65,
		look = {
			skin = rgb(220, 200, 235),
			material = "ForceField",
			alpha = 0.1,
			emit = { texture = "square", color = rgb(240, 220, 255), size = 0.16, drift = 0.6, gravity = 0, life = 0.5 },
			head = true,
			prints = nil,
		},
		journal = {
			"Now and then my fingertips flicker, as though they're not sure they're there.",
			"My hands skip like a bad memory. People blink and look again.",
			"My arms don't agree with themselves from one moment to the next. Small things nearby are sometimes slightly wrong.",
			"My hands stay put again.",
		},
	},
}

return table.freeze({
	tuning = tuning,
	domains = domains,
})
