--!strict
--[[
	Wildborn: people the land remade (docs/Wildborn.md). Each was a mage whose innate magic matched
	a harsh place, and who stayed too long. The place took them in. Ordinary Wildborn haunt their
	biome; the oldest, the bosses, keep one lair each, the same on every server.

	Every enemy is an R6 HUMANOID (Wildborn/WildbornRig): a real character rig dressed in its theme,
	never a welded critter body. One enemy = one entry here; its moves come from the library in
	Wildborn/WildbornMoves, chosen by data.

	ENEMY FIELDS
		name, title        what towns call them; title is the boss's epithet ("the Pyre King")
		theme              key of `themes` (colours, biomes, lore)
		boss               true: a lair boss (scale, lair, a day's return, first-kill reward)
		domain             what its hits count as (damage colour, wards); also what it resists
		level              power for XP relevance (CreatureService pays like any creature kill)
		health, walk       MaxHealth and WalkSpeed
		scale              Model:ScaleTo (bosses stand taller)
		aggro, deaggro     studs: notices you within aggro, forgets you past deaggro
		leash              studs from home it will ever go; past that it goes home and heals
		hitGap             seconds: the most often one player can be hurt by it (bosses, so chained
		                   moves can't kill before you can react; the Grove Sovereign's rule, for all)
		melee              { damage, reach, cooldown, status? } its plain blow
		moves              in priority order: the first one ready and in range is used. Common fields:
		                   move (library kind), cd (seconds), min/max (studs to its target), below
		                   (only under this share of health), once (one use per life)
		resist             Resist_<key>: its own domain strong, the theme's weakness negative
		xp, coins, loot    as Creatures.Def (kills pay through CreatureService:rewardKill)
		look               { skin, cloth, accent, hood? (catalog hood), crown? (boss) }

	MOVE KINDS (Wildborn/WildbornMoves): bolt, lob, dash, blink, echo, burst, eruption, zone,
	tether, rain, pull, stasis, rally. Damage numbers are per hit, before wards and guards.
	`style` is how the client draws it (Controllers/WildbornController).

	Tuning status: first guesses from the owner's reference scripts, not yet played.
]]

local rgb = Color3.fromRGB

export type Move = { [string]: any }
export type Look = { skin: Color3, cloth: Color3, accent: Color3, hood: boolean?, crown: boolean? }
export type Enemy = {
	id: string,
	name: string,
	title: string?,
	theme: string,
	boss: boolean,
	domain: string,
	level: number,
	health: number,
	walk: number,
	scale: number,
	aggro: number,
	deaggro: number,
	leash: number,
	hitGap: number,
	melee: { damage: number, reach: number, cooldown: number, status: { id: string, duration: number, magnitude: number? }? },
	moves: { Move },
	resist: { [string]: number },
	xp: number,
	coins: { chance: number, min: number, max: number }?,
	loot: { { item: string, chance: number, min: number, max: number } },
	look: Look,
}
export type Theme = {
	name: string,
	primary: Color3,
	secondary: Color3,
	biomes: { [string]: number },
	regular: string,
	boss: string,
	story: string, -- a townsperson's telling of the boss; {dir} = direction, {name} = the boss
	haunt: string, -- a townsperson's line about the ordinary Wildborn out there; {dir}
	slain: string, -- your Journal line the first time you kill its boss
}

local Wildborn = {}

Wildborn.themes = {
	fire = {
		name = "Ember Wastes",
		primary = rgb(255, 90, 30),
		secondary = rgb(255, 200, 60),
		biomes = { badlands = 1, volcanic_highlands = 1.4, desert_dunes = 0.7 },
		regular = "ember_wraith",
		boss = "pyre_king",
		story = "They say a fire mage walked into the wastes to the {dir} to be alone with the heat. He never came out. Now there's a king out there, wearing his flames like a crown. {name}, people call him.",
		haunt = "Keep off the hot ground to the {dir}. There are people out there who stopped being people. They burn as they walk.",
		slain = "I put out the Pyre King. Whatever was left of the man inside the fire, I hope he's cooler now.",
	},
	water = {
		name = "Drowned Shore",
		primary = rgb(40, 120, 220),
		secondary = rgb(170, 235, 255),
		biomes = { tidal_flats = 1.4, swamp = 0.6 },
		regular = "tidal_sage",
		boss = "drowned_lord",
		story = "A tide-caller once walked into the sea to the {dir} to listen to it properly. The sea kept him. He comes up on the flats sometimes, and the water comes with him. {name}.",
		haunt = "Don't walk the flats to the {dir} at low tide. Some of the old water-callers still live there, and they don't remember being kind.",
		slain = "The Drowned Lord let go of the sea at last. The flats are only wet now.",
	},
	nature = {
		name = "Overgrown Wilds",
		primary = rgb(60, 180, 80),
		secondary = rgb(170, 230, 100),
		biomes = { deep_forest = 1.4, grasslands = 0.8 },
		regular = "meadow_sentinel",
		boss = "grove_sovereign",
		story = "There was a woman who could make anything grow. She went into the green to the {dir} and grew into it. The trees answer to her now. {name}.",
		haunt = "The woods to the {dir} have keepers that look like people from a distance. Don't let them get close: the roots come up with them.",
		slain = "The Grove Sovereign is still. The vines let go of her one by one, and I swear the forest sighed.",
	},
	stone = {
		name = "Iron Crags",
		primary = rgb(165, 165, 175),
		secondary = rgb(255, 200, 80),
		biomes = { mountains = 1.3, crystal_caverns = 1 },
		regular = "stone_brute",
		boss = "iron_tyrant",
		story = "A smith who could hear iron went up into the peaks to the {dir} to find the mother lode. He found it, and it found him back. He's more metal than man now. {name}.",
		haunt = "Miners won't go to the crags to the {dir} any more. There are men up there made of the mountain, and they don't like company.",
		slain = "The Iron Tyrant fell like a bell rung once. The crags are quiet. I took some of his iron home.",
	},
	shadow = {
		name = "Shadow Mire",
		primary = rgb(70, 10, 110),
		secondary = rgb(160, 70, 230),
		biomes = { swamp = 1.2, ruinlands = 0.8 },
		regular = "mire_stalker",
		boss = "penumbra_lich",
		story = "An old shadow-weaver went into the mire to the {dir} to learn what the dark knows. It taught her to live without light, and without dying. {name}, they call her now.",
		haunt = "Stay out of the mire to the {dir} after dark. Things in there step out of the shadows behind you.",
		slain = "The Penumbra Lich is gone, and the mire has its moonlight back.",
	},
	storm = {
		name = "Frost Peaks",
		primary = rgb(160, 220, 255),
		secondary = rgb(255, 255, 200),
		biomes = { frostpeaks = 1.4, tundra = 0.8, frozen_coast = 0.7, skyreach = 0.8 },
		regular = "storm_caller",
		boss = "tempest_monarch",
		story = "A weather-witch climbed the cold peaks to the {dir} to be nearer the storms. She's still up there, and the storms answer to her. {name}.",
		haunt = "The high snow to the {dir} has callers in it: people who brought the storm down on themselves and stayed in it.",
		slain = "The Tempest Monarch is down, and for the first time I've seen the high peaks under a clear sky.",
	},
	void = {
		name = "Void Rift",
		primary = rgb(110, 255, 200),
		secondary = rgb(215, 200, 255),
		biomes = { ruinlands = 1.2, crystal_caverns = 0.6, skyreach = 0.6 },
		regular = "chrono_phantom",
		boss = "void_warden",
		story = "A scholar of time went into the old ruins to the {dir} to see the moment they fell. He's been seeing it ever since, and so are the people who go looking for him. {name}.",
		haunt = "The ruins to the {dir} aren't empty. Something in there strikes you twice for every blow.",
		slain = "The Void Warden came apart into one moment at a time. I don't think he minded.",
	},
} :: { [string]: Theme }

Wildborn.themeOrder = { "fire", "water", "nature", "stone", "shadow", "storm", "void" }

local function burnOn(seconds: number, dps: number): { id: string, duration: number, magnitude: number }
	return { id = "burning", duration = seconds, magnitude = dps }
end

Wildborn.enemies = {
	-- ─── Fire ────────────────────────────────────────────────────────────────
	ember_wraith = {
		id = "ember_wraith", name = "Ember Wraith", theme = "fire", boss = false, domain = "energy",
		level = 3, health = 110, walk = 16, scale = 1, aggro = 65, deaggro = 110, leash = 140, hitGap = 0,
		melee = { damage = 8, reach = 8, cooldown = 1, status = burnOn(1, 3) },
		moves = {
			{ move = "burst", cd = 12, min = 0, max = 14, radius = 14, damage = 16, status = burnOn(2, 4), style = "flare", windup = 0.5 },
			{ move = "bolt", cd = 3, min = 8, max = 60, damage = 11, speed = 85, size = 2.2, status = burnOn(1.5, 3), style = "fire" },
			{ move = "dash", cd = 8, min = 12, max = 35, distance = 30, trailDamage = 5, endDamage = 12, status = burnOn(1.5, 3), style = "fire" },
		},
		resist = { energy = 0.4, water = -0.4 },
		xp = 40, coins = { chance = 0.6, min = 2, max = 6 },
		loot = { { item = "ember_essence", chance = 0.45, min = 1, max = 2 }, { item = "cinder_salt", chance = 0.25, min = 1, max = 1 } },
		look = { skin = rgb(70, 40, 30), cloth = rgb(60, 30, 20), accent = rgb(255, 120, 40), hood = true },
	},
	pyre_king = {
		id = "pyre_king", name = "Pyre King", title = "the Pyre King", theme = "fire", boss = true, domain = "energy",
		level = 7, health = 1100, walk = 18, scale = 1.6, aggro = 90, deaggro = 160, leash = 90, hitGap = 0.5,
		melee = { damage = 28, reach = 10, cooldown = 1, status = burnOn(2, 5) },
		moves = {
			{ move = "rally", below = 0.3, once = true, heal = 0.4, radius = 22, damage = 50, status = burnOn(3, 8), style = "flare" },
			{ move = "rain", cd = 18, min = 0, max = 90, count = 10, spread = 30, center = "ahead", radius = 12, damage = 44, delay = 1, interval = 0.25, status = burnOn(2, 6), style = "meteor" },
			{ move = "dash", cd = 7, min = 12, max = 40, distance = 40, trailDamage = 14, endDamage = 30, status = burnOn(2, 5), style = "fire" },
			{ move = "bolt", cd = 2.5, min = 9, max = 70, damage = 30, speed = 90, size = 3, splash = 6, status = burnOn(2, 6), style = "fire" },
		},
		resist = { energy = 0.5, water = -0.35 },
		xp = 260, coins = { chance = 1, min = 30, max = 60 },
		loot = { { item = "ember_orb", chance = 0.35, min = 1, max = 1 }, { item = "ember_essence", chance = 1, min = 3, max = 6 }, { item = "notes_on_flame", chance = 0.3, min = 1, max = 1 } },
		look = { skin = rgb(90, 40, 20), cloth = rgb(110, 30, 15), accent = rgb(255, 170, 50), crown = true },
	},

	-- ─── Water ───────────────────────────────────────────────────────────────
	tidal_sage = {
		id = "tidal_sage", name = "Tidal Sage", theme = "water", boss = false, domain = "water",
		level = 3, health = 130, walk = 13, scale = 1, aggro = 60, deaggro = 110, leash = 140, hitGap = 0,
		melee = { damage = 10, reach = 7, cooldown = 1.1 },
		moves = {
			{ move = "eruption", cd = 16, min = 0, max = 25, pattern = "wave", count = 8, spacing = 4, width = 8, damage = 8, delay = 0.35, knockback = 40, style = "wave" },
			{ move = "zone", cd = 11, min = 0, max = 50, at = "target", radius = 7, duration = 3.5, tick = 0.4, damage = 6, pull = 30, style = "whirlpool" },
			{ move = "bolt", cd = 3.5, min = 7, max = 65, damage = 12, speed = 95, size = 1.8, status = { id = "slow", duration = 1.5 }, style = "water" },
		},
		resist = { water = 0.4, energy = -0.4 },
		xp = 40, coins = { chance = 0.6, min = 2, max = 6 },
		loot = { { item = "brine_pearl", chance = 0.3, min = 1, max = 1 }, { item = "raw_fish", chance = 0.5, min = 1, max = 2 } },
		look = { skin = rgb(80, 120, 140), cloth = rgb(30, 60, 90), accent = rgb(140, 220, 255), hood = true },
	},
	drowned_lord = {
		id = "drowned_lord", name = "Drowned Lord", title = "the Drowned Lord", theme = "water", boss = true, domain = "water",
		level = 7, health = 1500, walk = 13, scale = 1.7, aggro = 100, deaggro = 170, leash = 90, hitGap = 0.5,
		melee = { damage = 32, reach = 11, cooldown = 1.2 },
		moves = {
			{ move = "zone", cd = 22, min = 0, max = 100, at = "self", radius = 25, duration = 5, tick = 0.4, damage = 20, pull = 35, style = "maelstrom" },
			{ move = "eruption", cd = 13, min = 0, max = 30, pattern = "wave", count = 11, spacing = 5, width = 10, damage = 23, delay = 0.35, knockback = 55, style = "wave" },
			{ move = "zone", cd = 9, min = 0, max = 50, at = "target", radius = 9, duration = 4, tick = 0.4, damage = 18, pull = 45, style = "whirlpool" },
			{ move = "bolt", cd = 3, min = 10, max = 75, damage = 27, speed = 95, size = 2.2, count = 3, spread = 0.15, style = "water" },
		},
		resist = { water = 0.5, energy = -0.35 },
		xp = 280, coins = { chance = 1, min = 30, max = 60 },
		loot = { { item = "tidecall_tome", chance = 0.35, min = 1, max = 1 }, { item = "brine_pearl", chance = 1, min = 2, max = 4 }, { item = "silver_goblet", chance = 0.3, min = 1, max = 1 } },
		look = { skin = rgb(60, 100, 120), cloth = rgb(20, 40, 70), accent = rgb(160, 230, 255), crown = true },
	},

	-- ─── Nature ──────────────────────────────────────────────────────────────
	meadow_sentinel = {
		id = "meadow_sentinel", name = "Meadow Sentinel", theme = "nature", boss = false, domain = "life",
		level = 3, health = 140, walk = 12, scale = 1, aggro = 60, deaggro = 100, leash = 140, hitGap = 0,
		melee = { damage = 9, reach = 9, cooldown = 1.2 },
		moves = {
			{ move = "burst", cd = 14, below = 0.5, min = 0, max = 16, radius = 16, damage = 16, heal = 18, style = "bloom", windup = 0.4 },
			{ move = "eruption", cd = 7, min = 0, max = 9, pattern = "target", count = 3, radius = 3, damage = 13, delay = 0.4, status = { id = "root", duration = 1.2 }, style = "vine" },
			{ move = "lob", cd = 5, min = 9, max = 50, damage = 20, speed = 70, size = 3, radius = 7, style = "boulder" },
		},
		resist = { life = 0.4, energy = -0.4 },
		xp = 40, coins = { chance = 0.6, min = 2, max = 6 },
		loot = { { item = "silverleaf", chance = 0.5, min = 1, max = 3 }, { item = "wood_plank", chance = 0.3, min = 1, max = 2 } },
		look = { skin = rgb(110, 130, 70), cloth = rgb(50, 80, 35), accent = rgb(150, 220, 90), hood = true },
	},
	grove_sovereign = {
		id = "grove_sovereign", name = "Grove Sovereign", title = "the Grove Sovereign", theme = "nature", boss = true, domain = "life",
		level = 7, health = 1200, walk = 14, scale = 1.6, aggro = 90, deaggro = 160, leash = 90, hitGap = 0.6,
		melee = { damage = 27, reach = 11, cooldown = 1.2 },
		moves = {
			{ move = "rally", below = 0.5, once = true, heal = 0.17, haste = 1.4, hasteFor = 8, radius = 28, damage = 0, style = "bloom" },
			{ move = "zone", cd = 18, min = 0, max = 90, at = "self", radius = 22, duration = 3.5, tick = 0.5, damage = 11, style = "petals" },
			{ move = "eruption", cd = 6, min = 0, max = 50, pattern = "everyone", within = 70, count = 5, radius = 3.5, damage = 32, delay = 0.4, status = { id = "root", duration = 1.5 }, style = "vine" },
			{ move = "lob", cd = 4, min = 11, max = 70, damage = 40, speed = 75, size = 4, radius = 8, count = 3, interval = 0.4, style = "boulder" },
		},
		resist = { life = 0.5, energy = -0.35 },
		xp = 260, coins = { chance = 1, min = 30, max = 60 },
		loot = { { item = "oak_staff", chance = 0.35, min = 1, max = 1 }, { item = "silverleaf", chance = 1, min = 3, max = 6 }, { item = "herb_charm", chance = 0.4, min = 1, max = 1 } },
		look = { skin = rgb(100, 120, 60), cloth = rgb(40, 70, 30), accent = rgb(180, 240, 100), crown = true },
	},

	-- ─── Stone ───────────────────────────────────────────────────────────────
	stone_brute = {
		id = "stone_brute", name = "Stone Brute", theme = "stone", boss = false, domain = "earth",
		level = 4, health = 220, walk = 10, scale = 1.15, aggro = 55, deaggro = 95, leash = 140, hitGap = 0,
		melee = { damage = 14, reach = 8, cooldown = 1.6 },
		moves = {
			{ move = "burst", cd = 12, min = 0, max = 9, radius = 12, damage = 25, knockback = 60, style = "slam", windup = 0.5 },
			{ move = "eruption", cd = 9, min = 9, max = 35, pattern = "line", count = 6, spacing = 3.5, radius = 3.5, damage = 20, delay = 0.35, style = "spike" },
		},
		resist = { earth = 0.4, air = -0.4 },
		xp = 50, coins = { chance = 0.7, min = 3, max = 8 },
		loot = { { item = "iron_ore", chance = 0.5, min = 1, max = 2 }, { item = "copper_ore", chance = 0.4, min = 1, max = 2 }, { item = "quartz", chance = 0.2, min = 1, max = 1 } },
		look = { skin = rgb(120, 115, 110), cloth = rgb(70, 65, 60), accent = rgb(230, 200, 110) },
	},
	iron_tyrant = {
		id = "iron_tyrant", name = "Iron Tyrant", title = "the Iron Tyrant", theme = "stone", boss = true, domain = "earth",
		level = 7, health = 1400, walk = 12, scale = 1.7, aggro = 90, deaggro = 160, leash = 90, hitGap = 0.5,
		melee = { damage = 33, reach = 11, cooldown = 1.4 },
		moves = {
			{ move = "rain", cd = 24, min = 0, max = 90, count = 1, spread = 0, center = "target", radius = 22, damage = 66, delay = 1.4, knockback = 50, style = "anvil" },
			{ move = "pull", cd = 12, min = 14, max = 60, range = 60, speed = 70, delay = 0.5, radius = 18, damage = 44, knockback = 80, style = "magnet" },
			{ move = "burst", cd = 9, min = 0, max = 20, radius = 18, damage = 44, knockback = 80, style = "slam", windup = 0.5 },
			{ move = "eruption", cd = 6, min = 0, max = 35, pattern = "cone", count = 5, rows = 5, spacing = 4, radius = 3.5, damage = 31, delay = 0.35, style = "spike" },
		},
		resist = { earth = 0.5, air = -0.35 },
		xp = 280, coins = { chance = 1, min = 30, max = 60 },
		loot = { { item = "iron_sword", chance = 0.3, min = 1, max = 1 }, { item = "iron_ingot", chance = 1, min = 2, max = 5 }, { item = "chain_mail", chance = 0.2, min = 1, max = 1 } },
		look = { skin = rgb(140, 140, 150), cloth = rgb(60, 60, 70), accent = rgb(255, 200, 80), crown = true },
	},

	-- ─── Shadow ──────────────────────────────────────────────────────────────
	mire_stalker = {
		id = "mire_stalker", name = "Mire Stalker", theme = "shadow", boss = false, domain = "void",
		level = 3, health = 130, walk = 17, scale = 1, aggro = 60, deaggro = 110, leash = 140, hitGap = 0,
		melee = { damage = 10, reach = 7, cooldown = 0.9 },
		moves = {
			{ move = "blink", cd = 7, min = 7, max = 40, where = "behind", distance = 5, delay = 0.3, damage = 20, style = "shadow" },
			{ move = "burst", cd = 14, min = 0, max = 14, radius = 16, damage = 18, status = { id = "slow", duration = 2 }, style = "dread", windup = 0.4 },
			{ move = "tether", cd = 6, min = 0, max = 30, range = 30, ticks = 6, interval = 0.15, damage = 5, heal = 0.8, style = "drain" },
		},
		resist = { void = 0.4, spirit = -0.4 },
		xp = 40, coins = { chance = 0.6, min = 2, max = 6 },
		loot = { { item = "gloom_fur", chance = 0.45, min = 1, max = 2 }, { item = "moth_dust", chance = 0.3, min = 1, max = 2 } },
		look = { skin = rgb(60, 50, 70), cloth = rgb(25, 15, 35), accent = rgb(150, 70, 220), hood = true },
	},
	penumbra_lich = {
		id = "penumbra_lich", name = "Penumbra Lich", title = "the Penumbra Lich", theme = "shadow", boss = true, domain = "void",
		level = 7, health = 1300, walk = 16, scale = 1.6, aggro = 100, deaggro = 170, leash = 90, hitGap = 0.5,
		melee = { damage = 27, reach = 10, cooldown = 1.1 },
		moves = {
			{ move = "burst", cd = 20, min = 0, max = 30, radius = 30, damage = 66, knockback = 35, style = "eclipse", windup = 1.3 },
			{ move = "blink", cd = 6, min = 12, max = 50, where = "behind", distance = 6, delay = 0.3, damage = 34, radius = 12, style = "shadow" },
			{ move = "tether", cd = 7, min = 0, max = 40, range = 40, all = true, ticks = 6, interval = 0.16, damage = 11, heal = 0.7, style = "drain" },
		},
		resist = { void = 0.5, spirit = -0.35 },
		xp = 270, coins = { chance = 1, min = 30, max = 60 },
		loot = { { item = "moonstone_amulet", chance = 0.3, min = 1, max = 1 }, { item = "gloom_fur", chance = 1, min = 2, max = 4 }, { item = "spirit_beads", chance = 0.3, min = 1, max = 1 } },
		look = { skin = rgb(50, 40, 60), cloth = rgb(20, 10, 30), accent = rgb(170, 70, 240), crown = true },
	},

	-- ─── Storm ───────────────────────────────────────────────────────────────
	storm_caller = {
		id = "storm_caller", name = "Storm Caller", theme = "storm", boss = false, domain = "energy",
		level = 3, health = 120, walk = 14, scale = 1, aggro = 65, deaggro = 115, leash = 140, hitGap = 0,
		melee = { damage = 9, reach = 8, cooldown = 1.2 },
		moves = {
			{ move = "burst", cd = 9, min = 0, max = 14, radius = 14, damage = 14, status = { id = "slow", duration = 2.5 }, style = "frost", windup = 0.4 },
			{ move = "zone", cd = 14, min = 0, max = 60, at = "target", radius = 6, duration = 4, tick = 0.4, damage = 5, style = "static" },
			{ move = "rain", cd = 3, min = 10, max = 65, count = 1, spread = 0, center = "target", radius = 6, damage = 16, delay = 0.3, style = "lightning" },
		},
		resist = { energy = 0.4, earth = -0.4 },
		xp = 40, coins = { chance = 0.6, min = 2, max = 6 },
		loot = { { item = "wisp_mote", chance = 0.4, min = 1, max = 2 }, { item = "wool", chance = 0.3, min = 1, max = 2 } },
		look = { skin = rgb(170, 190, 210), cloth = rgb(60, 80, 110), accent = rgb(220, 240, 255), hood = true },
	},
	tempest_monarch = {
		id = "tempest_monarch", name = "Tempest Monarch", title = "the Tempest Monarch", theme = "storm", boss = true, domain = "energy",
		level = 7, health = 1300, walk = 15, scale = 1.6, aggro = 100, deaggro = 170, leash = 90, hitGap = 0.5,
		melee = { damage = 29, reach = 10, cooldown = 1.1 },
		moves = {
			{ move = "rain", cd = 18, min = 0, max = 100, count = 14, spread = 35, center = "self", radius = 7, damage = 52, delay = 0.2, interval = 0.18, style = "lightning" },
			{ move = "zone", cd = 14, min = 0, max = 30, at = "self", radius = 16, duration = 4.5, tick = 0.5, damage = 15, style = "blizzard" },
			{ move = "burst", cd = 9, min = 0, max = 18, radius = 18, damage = 34, status = { id = "slow", duration = 3 }, style = "frost", windup = 0.4 },
			{ move = "bolt", cd = 5, min = 0, max = 60, damage = 29, chain = 4, chainRange = 30, style = "chain" },
		},
		resist = { energy = 0.5, earth = -0.35 },
		xp = 270, coins = { chance = 1, min = 30, max = 60 },
		loot = { { item = "focus_ring", chance = 0.3, min = 1, max = 1 }, { item = "wisp_mote", chance = 1, min = 3, max = 5 }, { item = "wool_cloak", chance = 0.3, min = 1, max = 1 } },
		look = { skin = rgb(180, 200, 220), cloth = rgb(50, 70, 110), accent = rgb(255, 255, 200), crown = true },
	},

	-- ─── Void ────────────────────────────────────────────────────────────────
	chrono_phantom = {
		id = "chrono_phantom", name = "Chrono Phantom", theme = "void", boss = false, domain = "time",
		level = 4, health = 100, walk = 18, scale = 1, aggro = 70, deaggro = 130, leash = 140, hitGap = 0,
		melee = { damage = 11, reach = 9, cooldown = 1 },
		moves = {
			{ move = "stasis", cd = 14, min = 0, max = 60, radius = 8, duration = 1.2, damage = 15, style = "stasis" },
			{ move = "blink", cd = 8, min = 12, max = 50, where = "flank", distance = 5, delay = 0, damage = 0, style = "time" },
			{ move = "echo", cd = 5, min = 0, max = 9, damage = 14, delay = 0.8, style = "time" },
		},
		resist = { time = 0.4, space = -0.4 },
		xp = 50, coins = { chance = 0.7, min = 3, max = 8 },
		loot = { { item = "geode_dust", chance = 0.4, min = 1, max = 2 }, { item = "old_coin", chance = 0.3, min = 1, max = 2 } },
		look = { skin = rgb(150, 200, 190), cloth = rgb(40, 70, 70), accent = rgb(140, 255, 210), hood = true },
	},
	void_warden = {
		id = "void_warden", name = "Void Warden", title = "the Void Warden", theme = "void", boss = true, domain = "time",
		level = 7, health = 1400, walk = 18, scale = 1.6, aggro = 110, deaggro = 180, leash = 90, hitGap = 0.5,
		melee = { damage = 29, reach = 11, cooldown = 1 },
		moves = {
			{ move = "stasis", cd = 22, min = 0, max = 40, radius = 40, around = "self", duration = 1.8, damage = 77, pull = 100, style = "collapse" },
			{ move = "zone", cd = 12, min = 0, max = 60, at = "target", radius = 10, duration = 4, tick = 0.4, damage = 18, style = "tear" },
			{ move = "blink", cd = 6, min = 10, max = 50, where = "behind", distance = 5, delay = 0, damage = 0, clones = 3, cloneDamage = 29, style = "time" },
			{ move = "echo", cd = 4, min = 0, max = 50, damage = 26, second = 35, delay = 0.7, style = "time" },
		},
		resist = { time = 0.5, space = -0.35 },
		xp = 280, coins = { chance = 1, min = 30, max = 60 },
		loot = { { item = "time_relic", chance = 0.25, min = 1, max = 1 }, { item = "still_hour_glass", chance = 0.2, min = 1, max = 1 }, { item = "geode_dust", chance = 1, min = 2, max = 5 } },
		look = { skin = rgb(160, 210, 200), cloth = rgb(30, 50, 60), accent = rgb(220, 200, 255), crown = true },
	},
} :: { [string]: Enemy }

Wildborn.tuning = {
	stepSeconds = 0.2, -- how often each awake Wildborn thinks
	wakeRadius = 240,
	sleepRadius = 320,
	maxAlive = 14, -- regular Wildborn alive on a server (bosses don't count)
	hauntCell = 256, -- studs: the grid haunts are planned on
	hauntChance = 0.22, -- a wild cell of a theme's biome gets a haunt with this chance x biome weight
	hauntMax = 40,
	hauntPack = { min = 1, max = 2 },
	townClearance = 260, -- haunts and lairs keep this far from any town
	lairClearance = 420,
	respawn = { min = 240, max = 420 }, -- seconds for a regular Wildborn to return to its haunt
	bossReturnSeconds = 86400, -- a beaten boss returns on this server after a real day
	firstBossXp = 2.5, -- your first ever kill of each boss pays this many times its XP
	cueRange = 320, -- players within this many studs see its moves
	maxProjectiles = 60, -- in flight at once, server-wide
	maxZones = 12,
	rumorChance = 0.6, -- a townsperson knows the old story of the nearest boss you haven't heard of
	lairRadius = 14, -- the ring of standing stones at a lair
}

return Wildborn
