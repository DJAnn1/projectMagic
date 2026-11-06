--!strict
--[[
	Titans: huge bosses that cross the island, as data (docs/Titans.md). Shared so the client can word them.
	Bodies and attack numbers: Server/Titans/Data/TitanBodies. Decisions: Server/Titans/TitanRules.
	Running: Services/TitanService.

	SCHEDULE  One per slot of `slotSeconds`, chosen from the world seed, so every server sends the same Titan
	          down the same road at the same time. Each server fights its own.
	FALLS     The first server to kill a given Titan writes where it fell to a world store. Every server shows
	          it: a crater, its bones, a place on the map. Only `maxFalls` are kept, oldest out, so the world
	          and the store can't grow forever.
	IDS       `ids` is the schedule's draw order. A fall keeps its kind's id, so don't rename one that's live.

	TUNING STATUS  Every number is a first guess. None has been played. Health assumes a group.
]]

local rgb = Color3.fromRGB

export type Kind = {
	id: string,
	name: string,
	text: string, -- one line for the panel
	fallText: string, -- what its bones say; %s is who felled it
	color: Color3,
	bone: Color3,
	speed: number, -- studs a second
	weakness: string, -- a domain: it takes more from this
	structureDamage: number, -- per footfall, to buildings it passes
	structureRadius: number,
	burnsGround: boolean?, -- each footfall starts a real fire
	callsLightning: boolean?, -- strikes people near it, as well as stomping
}

export type Reward = { xp: number, coins: number, items: { { item: string, chance: number, min: number, max: number } } }

local kinds: { [string]: Kind } = {
	ashwalker = {
		id = "ashwalker",
		name = "The Ashwalker",
		text = "It has been burning since before the towns were built, and the ground catches where it steps.",
		fallText = "The Ashwalker burned out here, brought down by %s.",
		color = rgb(255, 120, 50),
		bone = rgb(60, 48, 44),
		speed = 6.5,
		weakness = "water",
		structureDamage = 6,
		structureRadius = 30,
		burnsGround = true,
	},
	stonefather = {
		id = "stonefather",
		name = "The Stonefather",
		text = "A hill that got up. Whatever it walks through stops being a building.",
		fallText = "The Stonefather lay down here for the last time, brought down by %s.",
		color = rgb(170, 150, 120),
		bone = rgb(120, 112, 100),
		speed = 5,
		weakness = "air",
		structureDamage = 12,
		structureRadius = 40,
	},
	stormcrown = {
		id = "stormcrown",
		name = "The Stormcrown",
		text = "The sky follows it. Keep moving, because the lightning is looking for you.",
		fallText = "The Stormcrown came to earth here, brought down by %s.",
		color = rgb(170, 200, 255),
		bone = rgb(88, 96, 120),
		speed = 7,
		weakness = "earth",
		structureDamage = 6,
		structureRadius = 30,
		callsLightning = true,
	},
}

local Titans = {
	kinds = kinds,
	ids = { "ashwalker", "stonefather", "stormcrown" },

	slotSeconds = 7200, -- one every 2 hours
	warnSeconds = 180, -- the countdown before it wades ashore
	recapSeconds = 40,

	routeReach = 0.82, -- starts and ends this share of the way from the centre to the world's edge
	routeTowns = 2, -- towns it walks through
	routeChoices = 5, -- chosen from this many nearest its line

	buildRadius = 900, -- its body exists once a player has been this close
	activeRadius = 450, -- it only harms the world with someone this close, so nothing dies unseen
	zoneRadius = 240, -- this close counts as taking part
	cueMargin = 200, -- studs past activeRadius that still see its warnings

	stride = 26, -- studs between footfalls
	footOffset = 12, -- how far to the side each foot lands
	footLead = 7, -- how far ahead the warning lands, so it's where the foot will be
	stumbleSeconds = 14, -- it stops when a weak point breaks
	reactionStumble = 4,
	breakBite = 0.08, -- share of its max health when a weak point breaks
	exposedShare = 0.012, -- a status bites this share...
	exposedCooldown = 10, -- ...once per this many seconds, per kind of status
	reactionShare = 0.03, -- a magic reaction beside it
	reactionReach = 40, -- studs past the reaction's own radius that count as beside it
	maxCollapses = 6, -- buildings one Titan can bring down on a server: rubble is physics
	trailBudget = 2, -- terrain ops per footfall for the scorched trail (never saved)

	maxFalls = 20,
	craterRadius = 26,
	landmarkBuild = 500, -- its bones exist within this of a player...
	landmarkSleep = 620, -- ...and go past this
	landmarkOffset = 25, -- a fall in a town is moved this far past its edge
	visitXp = 60, -- reading the marks on a fall, once per fall
	refreshSeconds = 300, -- how often to re-read the falls, in case a message was missed

	failedShare = 0.3, -- it walked into the sea: this share of the XP and coins, and no items

	tierNames = { gold = "Gold", silver = "Silver", bronze = "Bronze" } :: { [string]: string },

	rewards = {
		gold = {
			xp = 800,
			coins = 200,
			items = {
				{ item = "healing_draught", chance = 1, min = 2, max = 3 },
				{ item = "reservoir_tonic", chance = 1, min = 2, max = 3 },
				{ item = "ember_essence", chance = 0.8, min = 2, max = 4 },
				{ item = "time_relic", chance = 0.12, min = 1, max = 1 },
				{ item = "gravity_relic", chance = 0.12, min = 1, max = 1 },
			},
		},
		silver = {
			xp = 450,
			coins = 100,
			items = {
				{ item = "healing_draught", chance = 1, min = 1, max = 2 },
				{ item = "quartz", chance = 0.8, min = 1, max = 3 },
				{ item = "time_relic", chance = 0.03, min = 1, max = 1 },
				{ item = "gravity_relic", chance = 0.03, min = 1, max = 1 },
			},
		},
		bronze = {
			xp = 200,
			coins = 40,
			items = {
				{ item = "healing_draught", chance = 0.6, min = 1, max = 1 },
			},
		},
	} :: { [string]: Reward },

	gear = { "oak_staff", "ember_orb", "tidecall_tome", "moonstone_amulet", "focus_ring", "iron_sword", "chain_mail" },
	gearRarity = { gold = "epic", silver = "rare" } :: { [string]: string },
	legendaryChance = 0.1, -- gold on a win, instead of epic
}

return Titans
