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
	            so nobody is ever stuck, but a clever answer is about five times faster and pays better.
	IDS         `roomIds` and `twistIds` are draw orders. Reordering them reshuffles future Rifts (harmless:
	            claims are by slot).

	TUNING STATUS  Room and boss numbers were tuned once, from high-level runs only. The low-level end, the
	               twists and reactions are still first guesses.
]]

local rgb = Color3.fromRGB

export type Approach = {
	id: string,
	label: string, -- shown when this solves the room
	tags: { string },
	burns: boolean?, -- lights the barricade for real, instead of removing pieces directly
	key: string?, -- what finding this counts as, if not "<room>:<id>" (a reaction: "reaction:<result>")
}

export type Room = {
	id: string,
	kind: string, -- "barrier" | "chasm" | "eyes" | "coils" | "lamps" | "vigil"
	burnable: boolean?, -- barrier: real planks that burn. Otherwise pieces are only ever removed
	pieceColor: Color3?, -- barrier: how it looks, if not wood
	pieceMaterial: Enum.Material?,
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
	lightShare: number?, -- the Rift's lamps burn at this share of their brightness
	echoSeconds: number?, -- every telegraphed attack lands a second time, this much later
	clockShare: number?, -- the run's clock is this share of runSeconds
	rewardShare: number?, -- multiplies the XP and coins
	reservoirPerSecond: number?, -- share of your max reservoir refilled each second inside
}

export type Boss = {
	id: string,
	name: string,
	text: string, -- shown on the panel; %s is its weakness (the Twins have two)
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
	gloom = {
		id = "gloom",
		name = "Gloom",
		text = "The light here is failing. You'll have to bring your own.",
		color = rgb(90, 100, 150),
		lightShare = 0.2,
	},
	echo = {
		id = "echo",
		name = "Echo",
		text = "Every blow lands twice. Don't step back into the same spot.",
		color = rgb(240, 200, 110),
		echoSeconds = 1.4,
	},
	shortfuse = {
		id = "shortfuse",
		name = "Short Fuse",
		text = "This Rift is closing fast, and it pays for the hurry.",
		color = rgb(255, 90, 90),
		clockShare = 0.6,
		rewardShare = 1.3,
	},
	overflow = {
		id = "overflow",
		name = "Overflow",
		text = "Magic pours out of the walls. It's feeding them too.",
		color = rgb(90, 210, 230),
		reservoirPerSecond = 0.03,
		enemyHealth = 1.3,
	},
}

local bosses: { [string]: Boss } = {
	warden = {
		id = "warden",
		name = "The Rift Warden",
		text = "It flinches from %s, and any status you land on it hurts it.",
	},
	stormheart = {
		id = "stormheart",
		name = "The Stormheart",
		text = "Nothing touches it while its pylons stand, and they come back. It flinches from %s. A reaction beside it breaks the shield at once.",
	},
	twins = {
		id = "twins",
		name = "The Twins",
		text = "One flinches from %s, the other from %s. Kill one and the other brings it back, unless you finish both in time.",
	},
}

local rooms: { [string]: Room } = {
	thornwall = {
		id = "thornwall",
		kind = "barrier",
		burnable = true,
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
			-- No tags: no spell matches this one. It's recognised by where you end up (RiftService.stepRoom).
			{ id = "across", label = "Got across without a bridge", tags = {} },
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
	frostgate = {
		id = "frostgate",
		kind = "barrier",
		pieceColor = rgb(170, 215, 240),
		pieceMaterial = Enum.Material.Ice,
		name = "The Frostgate",
		text = "A wall of old blue ice seals the hall. It's been frozen a very long time.",
		hint = "Ice is only water that's holding still.",
		approaches = {
			{ id = "melt", label = "Melted through it", tags = { "fire", "heat", "light", "lightning", "energy" } },
			{ id = "shatter", label = "Shattered it", tags = { "force", "wind", "air", "gravity", "stone", "metal", "earth" } },
			{ id = "call", label = "Called the water out of it", tags = { "water", "ice", "cold" } },
			{ id = "root", label = "Split it with roots", tags = { "life", "rot" } },
			{ id = "winters", label = "Let a thousand winters pass", tags = { "time" } },
			{ id = "around", label = "Went around it, in a way", tags = { "space" } },
			{ id = "unmake", label = "Unmade it", tags = { "null", "void", "dark", "reality" } },
			{ id = "persuade", label = "Woke what was frozen inside", tags = { "mind", "spirit" } },
		},
	},
	longdark = {
		id = "longdark",
		kind = "lamps",
		name = "The Long Dark",
		text = "Four dead lamps stand in a hall with almost no light. Shades strike from wherever it's darkest.",
		hint = "Each lamp you wake leaves them less dark to hide in. A lamp doesn't care what wakes it.",
		approaches = {
			{ id = "light", label = "Lit them by hand", tags = { "light", "fire", "heat", "lightning", "energy" } },
			{ id = "drink", label = "Drank the dark out of them", tags = { "dark", "null", "void" } },
			{ id = "fill", label = "Fed them with water and breath", tags = { "water", "ice", "cold", "wind", "air" } },
			{ id = "ore", label = "Woke the ore in their bones", tags = { "stone", "metal", "earth", "gravity", "force" } },
			{ id = "bloom", label = "Grew something that glows", tags = { "life", "rot" } },
			{ id = "remember", label = "Reminded them they used to burn", tags = { "mind", "spirit", "time" } },
			{ id = "borrow", label = "Borrowed light from somewhere else", tags = { "space", "reality" } },
		},
	},
	vigil = {
		id = "vigil",
		kind = "vigil",
		name = "The Vigil",
		text = "A ring of light on the floor. The door listens to whoever stands in it, and everything else in here wants them gone.",
		hint = "Someone has to hold the ring. Magic cast into it makes the wait shorter.",
		approaches = {
			{ id = "kindle", label = "Fed the ring with flame", tags = { "fire", "heat", "light", "lightning", "energy" } },
			{ id = "ward", label = "Warded the ring", tags = { "spirit", "mind", "reality" } },
			{ id = "wall", label = "Walled it in", tags = { "stone", "metal", "earth", "ice", "cold", "water" } },
			{ id = "grove", label = "Grew a grove around it", tags = { "life", "rot" } },
			{ id = "gale", label = "Kept them back with a gale", tags = { "wind", "air", "force", "gravity" } },
			{ id = "hasten", label = "Hurried the wait along", tags = { "time", "space" } },
			{ id = "hush", label = "Hid the ring from them", tags = { "dark", "null", "void" } },
		},
	},
}

local RiftData = {
	twists = twists,
	rooms = rooms,
	bosses = bosses,
	roomIds = { "thornwall", "chasm", "gallery", "engine", "frostgate", "longdark", "vigil" },
	twistIds = { "wildfire", "glass", "stubborn", "swarm", "gloom", "echo", "shortfuse", "overflow" },
	bossIds = { "warden", "stormheart", "twins" },
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
	-- Low on purpose: off the island, Travel and Flight measure your height from sea level, so a higher
	-- pocket reads as flying too high and ends your ride (Tests/Rifts.spec holds this down).
	pocket = { x = 6000, y = 60, z = 0 },
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

	-- TUNED 2026-11-06 from two high-level runs, one with cheats. A power 7+ cast used to be worth 0.68 of a
	-- room, so the Engine took 2 casts. No low-level run has been seen yet, so those barely moved.
	cleverGain = 0.3, -- of a room per clever cast, x the power factor (0.8 at power 1, 1.2 from power 5): 3 to 5 casts
	bruteGain = 0.06, -- per plain cast: about 14 to 21
	repeatShare = 0.7, -- each time the same answer is used again in a room, it's worth this share of the last...
	repeatFloor = 0.35, -- ...but never less than this: one spell takes about 5 casts, a mix of answers 3
	targetScale = 2.2, -- an eye or lamp fills by this x a clever cast's gain: two casts each, at any power
	eyeRadius = 14, -- a clever cast this close to an eye works on it
	burnPieces = 5, -- how many pieces of a barricade one fire spell lights
	cleverPoints = 500, -- contribution per whole room's worth of clever progress
	brutePoints = 200,
	-- Enemies scale to the strongest spell cast inside, so a tier 8 mage gets a real fight. At power 3 or
	-- below nothing changes. Health is raised live, so holding back until the boss gains nothing.
	powerHealthPerLevel = 0.3, -- +this share of health per power above 3...
	powerHealthCap = 2.5, -- ...up to this multiple
	powerDamagePerLevel = 0.12,
	powerDamageCap = 1.6,

	exposedShare = 0.03, -- a status on the boss bites this share of its max health...
	exposedCooldown = 12, -- ...once per this many seconds, per kind of status

	lampRadius = 14, -- a cast this close to a dead lamp works on it
	lampBruteScale = 4, -- a plain cast fills a lamp by this x its gain: about four casts each at power 2
	lampLightRange = 34,
	vigilRadius = 12,
	vigilSeconds = 45, -- one person holding the ring, with nothing else helping
	vigilPlayerCap = 2, -- more than this in the ring doesn't go faster
	vigilCastShare = 0.5, -- a clever cast is worth this share of its usual progress here
	vigilWaveSeconds = 12,
	maxEnemies = 18, -- waves stop while this many are alive

	reactionGain = 0.6, -- a magic reaction landing in the room: nearly two clever casts in one
	reactionBite = 0.06, -- share of a boss's max health, when a reaction lands next to it
	reactionReach = 14, -- studs past the reaction's own radius that count as next to it
	noveltyXp = 60, -- the first time you ever solve something this way. Only once per answer, ever
	noveltyPoints = 100,
	pylons = 3,
	pylonRing = 26, -- studs from the Stormheart
	stormExposedSeconds = 25, -- how long its shield stays down once the pylons fall
	twinReviveSeconds = 20,
	twinReviveShare = 0.5, -- of max health

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
