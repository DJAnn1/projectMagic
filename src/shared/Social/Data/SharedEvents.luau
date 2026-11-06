--!strict
--[[
	SharedEvents: the server-wide events, as data (docs/Social.md "Shared events"). Shared so the client
	can word them the way the server runs them. Enemy bodies and attack numbers are server-only, in
	Server/Social/Data/EventEnemies. The rules that use this table are in Server/Social/EventRules.

	SCHEDULE  One event per slot of `slotSeconds`, chosen from the world seed, so every server runs the
	          same event at the same time: warning, then fight, then a recap until the marker clears.
	IDS       `ids` is the schedule's draw order. Reordering it reshuffles future events (harmless,
	          nothing saved depends on it), but renaming an id breaks nothing either: claims are by slot.

	TUNING STATUS  Every number here is a first guess from the damage formula (a power 3 caster deals
	about 11 damage a second). None has been played. Boss health is meant to last about 2 minutes solo.
]]

export type EventType = {
	id: string,
	name: string,
	text: string, -- one line for the panel
	goalText: string, -- what the progress bar counts
	duration: number, -- seconds of fighting
	radius: number, -- studs: the zone that counts as taking part
	outsideTown: boolean, -- true: placed on dry ground near a town; false: on the town itself
}

export type Reward = {
	xp: number,
	coins: number,
	items: { { item: string, chance: number, min: number, max: number } },
}

local types: { [string]: EventType } = {
	elemental = {
		id = "elemental",
		name = "Wild Elemental",
		text = "A raging elemental has woken. Keep clear of the ground it slams.",
		goalText = "Elemental worn down",
		duration = 300,
		radius = 130,
		outsideTown = true,
	},
	storm = {
		id = "storm",
		name = "Magical Storm",
		text = "Three static nodes are calling lightning down. Break them, and move when the ground glows.",
		goalText = "Nodes broken",
		duration = 300,
		radius = 110,
		outsideTown = true,
	},
	siege = {
		id = "siege",
		name = "Siege",
		text = "Hollow raiders are marching on the plaza. Stop them before too many get through.",
		goalText = "Raiders stopped",
		duration = 360,
		radius = 130,
		outsideTown = false,
	},
	comet = {
		id = "comet",
		name = "Fallen Comet",
		text = "A comet has come down. Break its shards before they burn out.",
		goalText = "Shards broken",
		duration = 270,
		radius = 110,
		outsideTown = true,
	},
}

local SharedEvents = {
	types = types,
	ids = { "elemental", "storm", "siege", "comet" },

	slotSeconds = 2400, -- one event every 40 minutes
	warnSeconds = 120, -- the countdown before the fight
	joinShare = 0.25, -- a server booting mid-fight joins only if this share of the fight remains
	recapSeconds = 40, -- how long the result stays up

	spawnRadius = 320, -- enemies appear once a player is this close and the chunk is built
	maxEnemies = 24,
	placeOffset = { min = 150, max = 230 }, -- studs from the town, for events outside it
	placeTries = 8,

	-- Enemy health = base x (1 + perExtraPlayer x (players in the zone - 1)). It only ever rises.
	perExtraPlayer = 0.85,

	contribution = {
		activeSeconds = 30, -- standing in the zone scores only if you acted this recently
		presencePerSecond = 2,
		healCapPerSecond = 40, -- healing above this doesn't score: a swap-heal loop can't farm gold
		minSeconds = 30, -- seconds in the zone before you can earn any tier
		minPoints = 25,
		gold = 0.4, -- share of the top score
		silver = 0.1,
	},

	failedShare = 0.35, -- a failed event pays this share of the XP and coins, and no items

	relics = { "time_relic", "gravity_relic" }, -- your first gold finish guarantees one, chosen by seed

	tierOrder = { "gold", "silver", "bronze" },
	tierNames = { gold = "Gold", silver = "Silver", bronze = "Bronze" } :: { [string]: string },

	rewards = {
		gold = {
			xp = 300,
			coins = 60,
			items = {
				{ item = "healing_draught", chance = 1, min = 1, max = 2 },
				{ item = "reservoir_tonic", chance = 0.6, min = 1, max = 2 },
				{ item = "ember_essence", chance = 0.4, min = 1, max = 2 },
				{ item = "copper_band", chance = 0.06, min = 1, max = 1 },
				{ item = "time_relic", chance = 0.06, min = 1, max = 1 },
				{ item = "gravity_relic", chance = 0.06, min = 1, max = 1 },
			},
		},
		silver = {
			xp = 180,
			coins = 30,
			items = {
				{ item = "healing_draught", chance = 0.7, min = 1, max = 1 },
				{ item = "quartz", chance = 0.4, min = 1, max = 2 },
				{ item = "time_relic", chance = 0.02, min = 1, max = 1 },
				{ item = "gravity_relic", chance = 0.02, min = 1, max = 1 },
			},
		},
		bronze = {
			xp = 90,
			coins = 12,
			items = {
				{ item = "healing_draught", chance = 0.35, min = 1, max = 1 },
			},
		},
	} :: { [string]: Reward },
}

return SharedEvents
