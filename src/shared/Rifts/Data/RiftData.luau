--!strict
--[[
	RiftData: Rifts as data (docs/Rifts.md). Shared so the client can word them the way the server runs
	them. Enemy bodies and attack numbers are server-only (Server/Rifts/Data/RiftEnemies). The rules that
	use this table are in Server/Rifts/RiftRules.

	SCHEDULE    One Rift per slot of `slotSeconds`, chosen from the world seed, so every server opens the
	            same Rift at the same time. The portal stays open for `openSeconds`. The clock starts when
	            the first person steps in. Each server's run is its own.
	ROOMS       `roomCount` are drawn from `rooms`, then the boss. A room's `kind` says how it's built and
	            how it's solved (RiftBuilder, RiftService).
	APPROACHES  What counts as a clever way through a room. A cast matches if ANY of its interaction tags
	            (Magic/Cast/InteractionMatrix.tagsFor) is listed. A spell whose property has no tag is
	            tagged with its domain, so every domain's id is listed in every room, and Tests/Rifts.spec
	            enforces that: no room may shut a domain out. Anything else still chips away (`bruteGain`),
	            so nobody is ever stuck, but a clever answer is about six times faster and pays better.
	IDS         `roomIds` and `twistIds` are draw orders. Reordering them reshuffles future Rifts (harmless:
	            claims are by slot).

	TUNING STATUS  Every number is a first guess. None has been played.
]]

local rgb = Color3.fromRGB

export type Approach = {
	id: string,
	label: string, -- shown when this solves the room
	tags: { string },
	burns: boolean?, -- lights the barricade for real, instead of removing pieces directly
}

export type Room = {
	id: string,
	kind: string, -- "barrier" | "chasm" | "eyes" | "coils"
	name: string,
	text: string, -- what you see
	hint: string, -- a nudge that names no spell
	approaches: { Approach },
}

export type Twist = {
	id: string,
	name: string,
	text: string,
	color: Color3, -- the Rift's accent
	fireSpread: number?, -- fires in the Rift burn and spread this much faster (FireSim.boost)
	burnGain: number?, -- multiplies a `burns` approach
	enemyHealth: number?,
	enemyDamage: number?,
	bruteGain: number?, -- multiplies progress from plain attacks
	cleverGain: number?, -- multiplies progress from clever answers
	extraEnemies: number?, -- more enemies in every room
}

export type Reward = { xp: number, coins: number, items: { { item: string, chance: number, min: number, max: number } } }

local twists: { [string]: Twist } = {
	wildfire = {
		id = "wildfire",
		name = "Wildfire",
		text = "Fire spreads twice as fast here, and it doesn't care whose side you're on.",
		color = rgb(255, 120, 50),
		fireSpread = 2,
		burnGain = 2,
	},
	glass = {
		id = "glass",
		name = "Glass",
		text = "Everything here breaks easily, including you.",
		color = rgb(190, 225, 255),
		enemyHealth = 0.6,
		enemyDamage = 1.6,
	},
	stubborn = {
		id = "stubborn",
		name = "Stubborn",
		text = "The Rift shrugs off brute force. Think, or be here a long time.",
		color = rgb(170, 130, 255),
		bruteGain = 0.4,
		cleverGain = 1.25,
	},
	swarm = {
		id = "swarm",
		name = "Swarm",
		text = "Something keeps crawling out of the walls.",
		color = rgb(120, 220, 130),
		extraEnemies = 3,
	},
}

local rooms: { [string]: Room } = {
	thornwall = {
		id = "thornwall",
		kind = "barrier",
		name = "The Thornwall",
		text = "A wall of dry, woody bramble fills the hall from side to side.",
		hint = "It's dead wood, and it's brittle. What happens to dead wood?",
		approaches = {
			{ id = "burn", label = "Burned it down", tags = { "fire", "heat", "lightning", "energy" }, burns = true },
			{ id = "rot", label = "Rotted it from inside", tags = { "rot", "life" } },
			{ id = "brittle", label = "Froze it until it snapped", tags = { "cold", "ice", "water" } },
			{ id = "tear", label = "Tore it apart", tags = { "force", "wind", "air", "gravity" } },
			{ id = "crush", label = "Crushed it under stone", tags = { "stone", "metal", "earth" } },
			{ id = "age", label = "Aged it to dust", tags = { "time" } },
			{ id = "fold", label = "Folded it out of the way", tags = { "space" } },
			{ id = "unmake", label = "Unmade it", tags = { "null", "void", "dark", "reality" } },
			{ id = "persuade", label = "Talked the thorns into parting", tags = { "mind", "spirit" } },
		},
	},
	chasm = {
		id = "chasm",
		kind = "chasm",
		name = "The Drop",
		text = "The floor stops. The far side is too far to jump, and the bottom doesn't look kind.",
		hint = "You don't need a bridge if you can get over it some other way. And you can always make one.",
		approaches = {
			{ id = "ice", label = "Froze a bridge across", tags = { "water", "ice", "cold" } },
			{ id = "stone", label = "Raised a stone causeway", tags = { "stone", "metal", "earth" } },
			{ id = "vine", label = "Grew a bridge of roots", tags = { "life", "rot" } },
			{ id = "lift", label = "Loosened the drop's pull", tags = { "gravity", "wind", "air", "force" } },
			{ id = "fold", label = "Folded the far side closer", tags = { "space", "time" } },
			{ id = "light", label = "Woke a path of light", tags = { "light", "heat", "fire", "lightning", "energy" } },
			{ id = "belief", label = "Convinced the air it was a floor", tags = { "mind", "spirit", "reality", "void", "null", "dark" } },
		},
	},
	gallery = {
		id = "gallery",
		kind = "eyes",
		name = "The Watching Gallery",
		text = "Three great eyes hang in the hall. Wherever they look, lightning follows.",
		hint = "You could break them. Or you could stop them seeing you.",
		approaches = {
			{ id = "dazzle", label = "Dazzled them shut", tags = { "light", "heat", "fire", "lightning", "energy" } },
			{ id = "shroud", label = "Shrouded them in darkness", tags = { "dark", "null", "void" } },
			{ id = "mist", label = "Hid in a wall of mist", tags = { "water", "ice", "cold", "wind", "air" } },
			{ id = "cover", label = "Sealed them over", tags = { "stone", "metal", "earth", "life", "rot" } },
			{ id = "lull", label = "Lulled them to sleep", tags = { "mind", "spirit", "time" } },
			{ id = "misdirect", label = "Bent what they were looking at", tags = { "space", "gravity", "force", "reality" } },
		},
	},
	engine = {
		id = "engine",
		kind = "coils",
		name = "The Cold Engine",
		text = "Three dead coils stand beside a sealed door. Something here wants waking, and it spits when it stirs.",
		hint = "An engine runs on power. It doesn't much mind what kind.",
		approaches = {
			{ id = "charge", label = "Charged the coils", tags = { "lightning", "metal", "energy" } },
			{ id = "stoke", label = "Stoked it like a furnace", tags = { "fire", "heat", "light" } },
			{ id = "spin", label = "Spun it up by hand", tags = { "force", "wind", "air", "gravity", "water" } },
			{ id = "wind", label = "Rewound it to when it ran", tags = { "time", "space", "reality" } },
			{ id = "haunt", label = "Gave it a spirit to run on", tags = { "spirit", "mind", "void", "null", "life", "rot" } },
			{ id = "rebuild", label = "Rebuilt what had seized", tags = { "stone", "earth", "cold", "ice" } },
		},
	},
}

local RiftData = {
	twists = twists,
	rooms = rooms,
	roomIds = { "thornwall", "chasm", "gallery", "engine" },
	twistIds = { "wildfire", "glass", "stubborn", "swarm" },
	roomCount = 3,

	slotSeconds = 1500, -- a new Rift every 25 minutes
	openSeconds = 900, -- the portal is open this long, unless the run is still going
	runSeconds = 600, -- the clock, from the first step inside
	closeMargin = 45, -- a run always ends this long before the next slot begins
	recapSeconds = 25, -- how long you can stay after a win
	failPullSeconds = 4, -- how quickly you're thrown out when time runs out

	portalRadius = 320, -- the portal appears once a player is this close and the chunk is built
	placeOffset = { min = 190, max = 320 }, -- studs from a town
	placeTries = 10,

	-- The pocket: off the island's 4,096 studs, so no chunk is ever built here, no town judges you and
	-- nothing cast inside can touch the real world.
	pocket = { x = 6000, y = 120, z = 0 },
	hallLength = 30,
	roomLength = 72,
	arenaLength = 96,
	width = 64,
	height = 30,
	doorWidth = 14,
	doorHeight = 16,
	chasmStart = 18, -- studs into the room where the floor ends
	chasmEnd = 54,
	chasmDepth = 32,
	fallLine = 24, -- this far below the floor: the Rift throws you back
	fallDamage = 0.1, -- share of max health
	bridgeSegments = 9,
	barrierColumns = 6,
	barrierRows = 3,

	cleverGain = 0.34, -- a room's progress per clever cast at power 2: about three casts
	bruteGain = 0.06, -- per plain cast: about fifteen
	eyeRadius = 14, -- a clever cast this close to an eye shuts it
	burnPieces = 5, -- how many pieces of a barricade one fire spell lights
	cleverPoints = 500, -- contribution per whole room's worth of clever progress
	brutePoints = 200,
	exposedShare = 0.03, -- a status on the boss bites this share of its max health...
	exposedCooldown = 12, -- ...once per this many seconds, per kind of status

	failedShare = 0.3, -- a run that runs out of time pays this share of the XP and coins, and no items
	cleverXp = 0.2, -- +this share of the XP per room solved cleverly

	tierNames = { gold = "Gold", silver = "Silver", bronze = "Bronze" } :: { [string]: string },

	rewards = {
		gold = {
			xp = 500,
			coins = 120,
			items = {
				{ item = "healing_draught", chance = 1, min = 2, max = 3 },
				{ item = "reservoir_tonic", chance = 1, min = 1, max = 2 },
				{ item = "ember_essence", chance = 0.6, min = 1, max = 3 },
				{ item = "time_relic", chance = 0.08, min = 1, max = 1 },
				{ item = "gravity_relic", chance = 0.08, min = 1, max = 1 },
			},
		},
		silver = {
			xp = 300,
			coins = 60,
			items = {
				{ item = "healing_draught", chance = 1, min = 1, max = 2 },
				{ item = "quartz", chance = 0.6, min = 1, max = 2 },
				{ item = "time_relic", chance = 0.02, min = 1, max = 1 },
				{ item = "gravity_relic", chance = 0.02, min = 1, max = 1 },
			},
		},
		bronze = {
			xp = 140,
			coins = 20,
			items = {
				{ item = "healing_draught", chance = 0.5, min = 1, max = 1 },
			},
		},
	} :: { [string]: Reward },

	-- What the boss leaves: one piece of gear, for gold and silver. Solving rooms cleverly raises its rarity.
	bossLoot = { "oak_staff", "ember_orb", "tidecall_tome", "moonstone_amulet", "focus_ring", "iron_sword", "chain_mail" },
	bossRarity = {
		base = "rare",
		silverCap = "epic", -- silver never goes past this
		epicAt = 2, -- rooms solved cleverly
		legendaryAt = 3,
		legendaryChance = 0.35, -- with legendaryAt met, and gold
	},
}

return RiftData
