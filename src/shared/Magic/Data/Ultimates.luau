--!strict
--[[
	Ultimates: a Ritual at power 8+ in a domain's own magic becomes that domain's ultimate
	(docs/SpellOverhaul.md §2E and §10, stage 5; owner, 2026-11-13: "inspired by the bosses,
	borrowing from them, not exact copies"). Time, Gravity and Reality keep the powers they have.
	Read by Data/EffectLibrary (one route each), Server/Magic/Cast/Effects/Ultimate (the run) and
	the Composer (Data/RouteSummaries).

	An ultimate is a list of BEATS, each starting `at` seconds after the cast:
		where     "center"  the spell's landing point
		          "scatter" `count` spots spread over `spread` studs around it
		          "ring"    `count` spots on a circle `distance` studs out
		          "targets" under each of up to `count` people the caster may harm within `spread`
		          "caster"  around the caster
		warn      seconds of ground warning first (shown to everyone near; 0 = none)
		radius    studs hit around each spot
		share     each hit as a share of the spell's base hit (DamageModel.base): an ultimate's
		          beats add up to roughly 4 to 6 hits, spread over several seconds
		look      the client's look: "drop" (falls from the sky), "nova" (a ring), "erupt" (out of
		          the ground), "hit" (an impact)
		status    { id, duration }   ignite   true: sets the ground there burning (FireSim, unsaved)
		lift      studs/s upward     push / pull   studs/s away from / toward the spot
		heal      a share of the beat's damage that heals the caster
		zone      { seconds, every }: instead of one hit, the area stays and hits every `every` s
	A person is hit at most once per beat however many spots overlap.

	`cooldown` (by mastery tier, 1..8, per caster per ultimate) and `maxActive` (on the server) keep
	them rare; the warnings make them readable.
	Tuning status: first pass, 2026-11-13, not yet played.
]]

export type Beat = {
	at: number,
	where: string,
	count: number?,
	spread: number?,
	distance: number?,
	warn: number?,
	radius: number,
	share: number,
	look: string,
	status: { id: string, duration: number }?,
	ignite: boolean?,
	lift: number?,
	push: number?,
	pull: number?,
	heal: number?,
	zone: { seconds: number, every: number }?,
}

export type Ultimate = {
	name: string,
	domain: string,
	properties: { string }?, -- nil: any property of the domain
	words: string,
	beats: { Beat },
}

local OFFENSIVE = { "generate", "amplify", "reduce", "transfer", "redirect", "transmute", "release" }

local list: { [string]: Ultimate } = {
	meteor_cascade = {
		name = "Meteor Cascade",
		domain = "energy",
		properties = { "combustion", "temperature" },
		words = "Three waves of meteors fall on marked ground and set it burning, then the heart of it explodes.",
		beats = {
			{ at = 0, where = "scatter", count = 5, spread = 26, warn = 1.2, radius = 8, share = 0.8, look = "drop", ignite = true },
			{ at = 1.3, where = "scatter", count = 5, spread = 26, warn = 1.2, radius = 8, share = 0.8, look = "drop", ignite = true },
			{ at = 2.6, where = "scatter", count = 5, spread = 26, warn = 1.2, radius = 8, share = 0.8, look = "drop", ignite = true },
			{ at = 4.2, where = "center", warn = 1.2, radius = 16, share = 1.3, look = "nova", lift = 45, status = { id = "burning", duration = 4 } },
		},
	},
	skyfall_tempest = {
		name = "Skyfall Tempest",
		domain = "energy",
		properties = { "charge", "luminosity", "radiation", "momentum" },
		words = "Lightning hunts everyone you can hurt: four strikes on marked ground beneath them, dazing, then the storm breaks over all of it.",
		beats = {
			{ at = 0, where = "targets", count = 8, spread = 30, warn = 0.7, radius = 6, share = 0.6, look = "drop", status = { id = "dazed", duration = 1.5 } },
			{ at = 0.9, where = "targets", count = 8, spread = 30, warn = 0.7, radius = 6, share = 0.6, look = "drop" },
			{ at = 1.8, where = "targets", count = 8, spread = 30, warn = 0.7, radius = 6, share = 0.6, look = "drop", status = { id = "dazed", duration = 1.5 } },
			{ at = 2.7, where = "targets", count = 8, spread = 30, warn = 0.7, radius = 6, share = 0.6, look = "drop" },
			{ at = 3.8, where = "center", warn = 0.9, radius = 26, share = 0.7, look = "nova", status = { id = "knockdown", duration = 1.2 } },
		},
	},
	forge_of_tyrants = {
		name = "Forge of Tyrants",
		domain = "earth",
		words = "Rings of iron spikes burst out of the ground, wider and wider, then an anvil of stone crushes the middle.",
		beats = {
			{ at = 0, where = "ring", count = 6, distance = 7, warn = 0.9, radius = 5, share = 0.7, look = "erupt", lift = 35 },
			{ at = 0.7, where = "ring", count = 10, distance = 15, warn = 0.9, radius = 5, share = 0.7, look = "erupt", lift = 35 },
			{ at = 1.4, where = "ring", count = 14, distance = 23, warn = 0.9, radius = 5, share = 0.7, look = "erupt", lift = 35 },
			{ at = 2.8, where = "center", warn = 1.3, radius = 11, share = 1.5, look = "drop", status = { id = "knockdown", duration = 1.6 } },
		},
	},
	maelstrom_crucible = {
		name = "Maelstrom Crucible",
		domain = "water",
		words = "A whirlpool drags everyone in for seven seconds, grinding and slowing them, then bursts outward.",
		beats = {
			{ at = 0, where = "center", warn = 0.8, radius = 26, share = 0.18, look = "nova", pull = 14, status = { id = "slow", duration = 1.2 }, zone = { seconds = 7, every = 0.7 } },
			{ at = 7.4, where = "center", radius = 26, share = 1.0, look = "nova", push = 55 },
		},
	},
	cyclone_throne = {
		name = "Cyclone Throne",
		domain = "air",
		words = "A cyclone tears up everyone around it, lifting and spinning them for six seconds, then hurls them away.",
		beats = {
			{ at = 0, where = "center", warn = 0.8, radius = 22, share = 0.15, look = "nova", pull = 10, lift = 16, zone = { seconds = 6, every = 0.6 } },
			{ at = 6.3, where = "center", radius = 24, share = 0.9, look = "nova", push = 70, lift = 20 },
		},
	},
	verdant_storm = {
		name = "Verdant Storm",
		domain = "life",
		words = "Thorns burst up under everyone you can hurt, rooting them, three times over, and their life feeds yours.",
		beats = {
			{ at = 0, where = "targets", count = 8, spread = 28, warn = 0.8, radius = 6, share = 0.6, look = "erupt", status = { id = "root", duration = 1.5 }, heal = 0.3 },
			{ at = 1.2, where = "targets", count = 8, spread = 28, warn = 0.8, radius = 6, share = 0.6, look = "erupt", status = { id = "poison", duration = 4 }, heal = 0.3 },
			{ at = 2.4, where = "targets", count = 8, spread = 28, warn = 0.8, radius = 6, share = 0.6, look = "erupt", status = { id = "root", duration = 1.5 }, heal = 0.3 },
			{ at = 3.6, where = "center", radius = 22, share = 0.6, look = "nova", heal = 0.5 },
		},
	},
	shattered_mind = {
		name = "Shattered Mind",
		domain = "mind",
		words = "Waves of dread roll out four times: everyone you can hurt is dazed, afraid and finally silenced.",
		beats = {
			{ at = 0, where = "center", warn = 0.6, radius = 24, share = 0.45, look = "nova", status = { id = "dazed", duration = 2 } },
			{ at = 1.0, where = "center", radius = 24, share = 0.45, look = "nova", status = { id = "fear", duration = 3 } },
			{ at = 2.0, where = "center", radius = 24, share = 0.45, look = "nova", status = { id = "dazed", duration = 2 } },
			{ at = 3.0, where = "center", radius = 24, share = 0.8, look = "nova", status = { id = "silence", duration = 2.5 } },
		},
	},
	soulfire_requiem = {
		name = "Soulfire Requiem",
		domain = "spirit",
		words = "Soulfire falls on everyone you can hurt, five times, marking their souls and feeding yours, then a last toll.",
		beats = {
			{ at = 0, where = "targets", count = 8, spread = 28, warn = 0.5, radius = 5, share = 0.5, look = "drop", status = { id = "soulmarked", duration = 6 }, heal = 0.25 },
			{ at = 0.7, where = "targets", count = 8, spread = 28, warn = 0.5, radius = 5, share = 0.5, look = "drop", heal = 0.25 },
			{ at = 1.4, where = "targets", count = 8, spread = 28, warn = 0.5, radius = 5, share = 0.5, look = "drop", heal = 0.25 },
			{ at = 2.1, where = "targets", count = 8, spread = 28, warn = 0.5, radius = 5, share = 0.5, look = "drop", heal = 0.25 },
			{ at = 2.8, where = "targets", count = 8, spread = 28, warn = 0.5, radius = 5, share = 0.5, look = "drop", heal = 0.25 },
			{ at = 3.8, where = "center", warn = 0.8, radius = 20, share = 0.9, look = "nova" },
		},
	},
	eclipse_erasure = {
		name = "Eclipse Erasure",
		domain = "void",
		words = "A darkness swallows the area for five seconds, blinding and drawing everyone in, then collapses on itself.",
		beats = {
			{ at = 0, where = "center", warn = 0.8, radius = 24, share = 0.2, look = "nova", pull = 7, status = { id = "blind", duration = 1.2 }, zone = { seconds = 5, every = 1 } },
			{ at = 5.2, where = "center", warn = 1.0, radius = 24, share = 1.5, look = "erupt" },
		},
	},
	fold_of_worlds = {
		name = "Fold of Worlds",
		domain = "space",
		words = "Space folds: everyone around is dragged to the middle, crushed as it closes, then thrown out as it opens again.",
		beats = {
			{ at = 0, where = "center", warn = 0.9, radius = 28, share = 0.3, look = "nova", pull = 60 },
			{ at = 1.0, where = "center", radius = 12, share = 1.2, look = "erupt", status = { id = "dazed", duration = 2 } },
			{ at = 2.0, where = "center", radius = 22, share = 0.6, look = "nova", push = 55 },
		},
	},
}

return table.freeze({
	list = list,
	verbs = OFFENSIVE,
	minPower = 8,
	-- Seconds before the same caster can call this ultimate again, by mastery tier (1..8).
	cooldown = { 240, 240, 240, 220, 200, 160, 120, 90 },
	maxActive = 4, -- running on the server at once
})
