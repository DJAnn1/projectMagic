--!strict
--[[
	Creatures: every wild creature, as data (docs/EarlyGamePlan.md §7). The first slice of the
	"creatures" world stage: small magical critters around towns.

	A new creature is one entry here (plus its loot items in Shared/Items/Data/Items). The weakness
	table must keep every domain strong against something: Tests/Creatures.spec checks it.

	FIELDS
		name, description
		domain      what its bite counts as (damage number colour, wards)
		level       its "power" for XP relevance: killing far below your ceiling teaches little
		health      MaxHealth. A power 1 Strike deals about 9 (x 1.5 on a weakness)
		walk        WalkSpeed
		hipHeight   how high the Humanoid floats its root: fliers just float higher
		hitbox      size of the invisible root, the thing spells actually hit
		behaviour   wander  minds its own business; fights back when hit (or flees: fightsBack = false)
		            flee    runs from anyone within fleeRadius, or who hits it
		            swarm   comes at anyone within aggroRadius; hit one and the pack comes
		            defend  ignores you until you come within defendRadius of the den, or hit it
		aggroRadius, fleeRadius, defendRadius   studs (per behaviour)
		leash       how far from its den it will ever go; past that it goes home and heals
		bite        { damage, cooldown, reach, property }, nil = can't attack
		pack        { min, max } members of a den
		respawn     { min, max } seconds for a dead member to come back
		resist      Resist_<key> attributes (Cast/Resistances, source "manual"): a domain id, a
		            property id or "all". Positive resists, negative is a weakness (cap -0.5)
		biomes      biome id -> weight when a town picks its dens. Anything else: anyBiome
		xp          base XP per kill, before Progression's factors (channel "challenge")
		coins       { chance, min, max }
		loot        { { item, chance, min, max } }; item ids from Shared/Items/Data/Items
		body        parts welded to the root. { name, shape, size, offset, color, material }. The one
		            called "Head" carries the Humanoid's name and health display.
		emit        { color, rate } a particle emitter on the root
		nestColor   the den's mound (nil: no mound, a herd just grazes there)
		game        an ordinary animal (deer, fowl, hares), not a magical critter. Planned as herds
		            further out (CreatureRules.planHerds, `Creatures.gameIds`), hunted by the town's
		            hunters (Services/HuntService), no name or health bar over it (`silent`)
		silent      nothing floats over it
]]

local rgb = Color3.fromRGB
local M = Enum.Material

export type Part = {
	name: string,
	shape: string, -- "Ball" (an ellipsoid filling `size`) | "Block"
	size: Vector3,
	offset: Vector3,
	rot: Vector3?, -- degrees, X then Y then Z (CreatureRig)
	color: Color3,
	material: Enum.Material,
	transparency: number?,
	anim: { kind: string, amount: number, speed: number, phase: number? }?, -- moved on the client (Fx/FamiliarAnimator)
}

export type Def = {
	id: string,
	name: string,
	description: string,
	domain: string,
	level: number,
	health: number,
	walk: number,
	hipHeight: number,
	hitbox: Vector3,
	behaviour: string,
	fightsBack: boolean?,
	aggroRadius: number?,
	fleeRadius: number?,
	defendRadius: number?,
	leash: number,
	bite: { damage: number, cooldown: number, reach: number, property: string }?,
	pack: { min: number, max: number },
	respawn: { min: number, max: number },
	resist: { [string]: number },
	biomes: { [string]: number },
	xp: number,
	coins: { chance: number, min: number, max: number }?,
	loot: { { item: string, chance: number, min: number, max: number } },
	body: { Part },
	emit: { color: Color3, rate: number }?,
	nestColor: Color3?,
	game: boolean?,
	silent: boolean?,
}

local defs: { [string]: Def } = {}
local ids: { string } = {} -- declaration order: the planner's stable iteration order (critters only)
local gameIds: { string } = {} -- ordinary animals, planned as herds (CreatureRules.planHerds)

local function creature(def: Def)
	defs[def.id] = def
	table.insert(if def.game then gameIds else ids, def.id)
end

-- Legs for an animal standing on four (or two) of them: from the ground up to the body's underside.
local function legs(def: { hipHeight: number, hitbox: Vector3 }, spots: { Vector2 }, width: number, color: Color3): { Part }
	local out: { Part } = {}
	local length = def.hipHeight + 0.2
	local y = -(def.hitbox.Y / 2 + def.hipHeight / 2) + 0.1
	for i, spot in spots do
		table.insert(out, {
			name = "Leg" .. i,
			shape = "Block",
			size = Vector3.new(width, length, width),
			offset = Vector3.new(spot.X, y, spot.Y),
			color = color,
			material = M.Fabric,
		})
	end
	return out
end

local function with(base: { Part }, extra: { Part }): { Part }
	local out = table.clone(base)
	for _, p in extra do
		table.insert(out, p)
	end
	return out
end

creature({
	id = "ember_sprite",
	name = "Ember Sprite",
	description = "A drifting spark that has decided it is alive. Comes in small, annoyed groups.",
	domain = "energy",
	level = 1,
	health = 18,
	walk = 13,
	hipHeight = 3.5,
	hitbox = Vector3.new(2.2, 2.2, 2.2),
	behaviour = "swarm",
	aggroRadius = 16,
	leash = 40,
	bite = { damage = 3, cooldown = 2, reach = 6.5, property = "temperature" },
	pack = { min = 2, max = 4 },
	respawn = { min = 90, max = 150 },
	resist = { energy = 0.6, water = -0.5, void = -0.2 },
	biomes = { volcanic_highlands = 6, badlands = 4, desert_dunes = 4, grasslands = 1 },
	xp = 9,
	coins = { chance = 0.35, min = 1, max = 3 },
	loot = { { item = "ember_essence", chance = 0.06, min = 1, max = 1 } },
	body = {
		{ name = "Head", shape = "Ball", size = Vector3.new(1.5, 1.5, 1.5), offset = Vector3.zero, color = rgb(255, 150, 60), material = M.Neon },
		{ name = "Core", shape = "Ball", size = Vector3.new(0.8, 0.8, 0.8), offset = Vector3.new(0, 0.9, 0), color = rgb(255, 225, 130), material = M.Neon },
	},
	emit = { color = rgb(255, 140, 50), rate = 6 },
	nestColor = rgb(70, 45, 40),
})

creature({
	id = "mud_crawler",
	name = "Mud Crawler",
	description = "Slow, wet and very attached to its hole. Leave it alone and it leaves you alone.",
	domain = "earth",
	level = 2,
	health = 40,
	walk = 7,
	hipHeight = 0.2,
	hitbox = Vector3.new(3.4, 1.6, 4.4),
	behaviour = "defend",
	defendRadius = 18,
	leash = 34,
	bite = { damage = 6, cooldown = 2.4, reach = 5.5, property = "momentum" },
	pack = { min = 2, max = 3 },
	respawn = { min = 120, max = 200 },
	resist = { earth = 0.5, water = 0.3, energy = -0.5, time = -0.4 },
	biomes = { swamp = 6, tidal_flats = 4, deep_forest = 2, grasslands = 2 },
	xp = 13,
	coins = { chance = 0.4, min = 1, max = 4 },
	loot = { { item = "crawler_chitin", chance = 0.5, min = 1, max = 2 } },
	body = {
		{ name = "Head", shape = "Ball", size = Vector3.new(2, 1.6, 2), offset = Vector3.new(0, 0, -1.6), color = rgb(92, 72, 52), material = M.Mud },
		{ name = "Body", shape = "Ball", size = Vector3.new(3.2, 1.8, 3.4), offset = Vector3.new(0, 0, 0.5), color = rgb(80, 62, 45), material = M.Mud },
		{ name = "Tail", shape = "Ball", size = Vector3.new(2, 1.2, 2), offset = Vector3.new(0, -0.1, 2.2), color = rgb(70, 54, 40), material = M.Mud },
	},
	nestColor = rgb(62, 48, 36),
})

creature({
	id = "gust_moth",
	name = "Gust Moth",
	description = "A pale moth the size of a dinner plate, riding wind that isn't there. Hard to catch.",
	domain = "air",
	level = 1,
	health = 14,
	walk = 15,
	hipHeight = 4.5,
	hitbox = Vector3.new(2.6, 1.6, 2.2),
	behaviour = "flee",
	fleeRadius = 20,
	leash = 44,
	pack = { min = 3, max = 5 },
	respawn = { min = 80, max = 140 },
	resist = { air = 0.6, earth = -0.5, gravity = -0.5 },
	biomes = { grasslands = 5, skyreach = 5, mountains = 3, tundra = 2 },
	xp = 10,
	coins = { chance = 0.2, min = 1, max = 2 },
	loot = { { item = "moth_dust", chance = 0.6, min = 1, max = 2 } },
	body = {
		{ name = "Head", shape = "Ball", size = Vector3.new(0.8, 0.8, 1.5), offset = Vector3.zero, color = rgb(215, 210, 190), material = M.SmoothPlastic },
		{ name = "WingL", shape = "Block", size = Vector3.new(2.2, 0.1, 1.6), offset = Vector3.new(-1.4, 0.2, 0), color = rgb(235, 232, 215), material = M.Fabric },
		{ name = "WingR", shape = "Block", size = Vector3.new(2.2, 0.1, 1.6), offset = Vector3.new(1.4, 0.2, 0), color = rgb(235, 232, 215), material = M.Fabric },
	},
	nestColor = rgb(120, 118, 100),
})

creature({
	id = "gloom_rat",
	name = "Gloom Rat",
	description = "Rats that learned something in the dark and tell each other about it. Never alone.",
	domain = "spirit",
	level = 1,
	health = 16,
	walk = 14,
	hipHeight = 0.2,
	hitbox = Vector3.new(1.8, 1.4, 3),
	behaviour = "swarm",
	aggroRadius = 14,
	leash = 38,
	bite = { damage = 2, cooldown = 2, reach = 5, property = "essence" },
	pack = { min = 3, max = 5 },
	respawn = { min = 80, max = 140 },
	resist = { void = 0.4, spirit = -0.4, mind = -0.5, life = -0.5, energy = -0.2 },
	biomes = { ruinlands = 6, deep_forest = 3, swamp = 3, tundra = 2, grasslands = 2 },
	xp = 8,
	coins = { chance = 0.3, min = 1, max = 2 },
	loot = { { item = "gloom_fur", chance = 0.5, min = 1, max = 1 } },
	body = {
		{ name = "Head", shape = "Ball", size = Vector3.new(1, 1, 1.3), offset = Vector3.new(0, 0.05, -1.1), color = rgb(58, 54, 72), material = M.Fabric },
		{ name = "Body", shape = "Ball", size = Vector3.new(1.5, 1.2, 2.2), offset = Vector3.new(0, 0, 0.3), color = rgb(48, 44, 60), material = M.Fabric },
		{ name = "Tail", shape = "Block", size = Vector3.new(0.2, 0.2, 1.6), offset = Vector3.new(0, -0.2, 2), color = rgb(95, 80, 90), material = M.SmoothPlastic },
	},
	nestColor = rgb(40, 38, 48),
})

creature({
	id = "glass_beetle",
	name = "Glass Beetle",
	description = "Its shell turns aside honest blows. A loud enough noise, though, or a fold in space...",
	domain = "earth",
	level = 2,
	health = 34,
	walk = 8,
	hipHeight = 0.3,
	hitbox = Vector3.new(3, 1.8, 3.6),
	behaviour = "defend",
	defendRadius = 16,
	leash = 32,
	bite = { damage = 5, cooldown = 2.2, reach = 5.5, property = "hardness" },
	pack = { min = 1, max = 3 },
	respawn = { min = 120, max = 200 },
	resist = { earth = 0.5, energy = 0.25, gravity = 0.25, air = -0.5, space = -0.5 },
	biomes = { desert_dunes = 6, mountains = 4, badlands = 4, frostpeaks = 3, frozen_coast = 2 },
	xp = 13,
	coins = { chance = 0.45, min = 2, max = 4 },
	loot = { { item = "beetle_glass", chance = 0.4, min = 1, max = 1 } },
	body = {
		{ name = "Head", shape = "Ball", size = Vector3.new(1.4, 1.1, 1.3), offset = Vector3.new(0, -0.1, -1.6), color = rgb(70, 110, 120), material = M.Glass },
		{ name = "Shell", shape = "Ball", size = Vector3.new(2.8, 1.7, 3.2), offset = Vector3.new(0, 0.1, 0.3), color = rgb(150, 215, 225), material = M.Glass, transparency = 0.25 },
	},
	nestColor = rgb(120, 140, 140),
})

creature({
	id = "mana_wisp",
	name = "Mana Wisp",
	description = "Loose magic that has wandered off from whatever cast it. Harmless, until it isn't.",
	domain = "reality",
	level = 2,
	health = 24,
	walk = 10,
	hipHeight = 4,
	hitbox = Vector3.new(2.2, 2.2, 2.2),
	behaviour = "wander",
	fightsBack = true,
	leash = 40,
	bite = { damage = 4, cooldown = 2.2, reach = 7, property = "aether" },
	pack = { min = 1, max = 3 },
	respawn = { min = 110, max = 180 },
	resist = { energy = 0.2, void = -0.5, reality = -0.5, spirit = -0.25 },
	biomes = { skyreach = 6, ruinlands = 4, deep_forest = 3, frostpeaks = 2, tundra = 2 },
	xp = 14,
	coins = { chance = 0.3, min = 1, max = 3 },
	loot = { { item = "wisp_mote", chance = 0.35, min = 1, max = 1 } },
	body = {
		{ name = "Head", shape = "Ball", size = Vector3.new(1.4, 1.4, 1.4), offset = Vector3.zero, color = rgb(150, 190, 255), material = M.Neon },
	},
	emit = { color = rgb(170, 200, 255), rate = 5 },
	nestColor = rgb(90, 95, 120),
})

-- ─── Game: ordinary animals the hunters go out for (docs/Hunting.md) ─────────────────────────────

-- Deer, second look (owner's screenshot 2026-11-16: an upright neck and flat floating ears read as an
-- alpaca with antlers). Now: a slim body with a deeper chest, the neck leaning forward, a long narrow
-- head with a darker muzzle, upright ears tilted out, thin legs, a white rump with a small tail on it.
local DEER_BROWN, DEER_DARK, DEER_PALE, DEER_LEG = rgb(146, 100, 62), rgb(70, 50, 36), rgb(226, 214, 196), rgb(112, 80, 54)
local deerShape = { hipHeight = 2.2, hitbox = Vector3.new(1.5, 1.6, 3.6) }
creature({
	id = "deer",
	name = "Deer",
	description = "Red deer, grazing in twos and threes at the edge of the trees. Gone at the first wrong sound.",
	domain = "life",
	level = 1,
	health = 30,
	walk = 20,
	hipHeight = deerShape.hipHeight,
	hitbox = deerShape.hitbox,
	behaviour = "flee",
	fleeRadius = 30,
	leash = 90,
	pack = { min = 2, max = 4 },
	respawn = { min = 300, max = 480 },
	resist = {},
	biomes = { grasslands = 6, deep_forest = 6, mountains = 2, tundra = 2, swamp = 1 },
	xp = 5,
	loot = { { item = "raw_meat", chance = 1, min = 2, max = 3 }, { item = "deer_hide", chance = 0.8, min = 1, max = 1 } },
	body = with({
		{ name = "Body", shape = "Ball", size = Vector3.new(1.5, 1.6, 3.6), offset = Vector3.zero, color = DEER_BROWN, material = M.Fabric },
		{ name = "Chest", shape = "Ball", size = Vector3.new(1.4, 1.7, 1.5), offset = Vector3.new(0, 0.15, -1.25), color = DEER_BROWN, material = M.Fabric },
		{ name = "Neck", shape = "Block", size = Vector3.new(0.55, 1.9, 0.75), offset = Vector3.new(0, 1.45, -1.9), rot = Vector3.new(-32, 0, 0), color = DEER_BROWN, material = M.Fabric },
		{ name = "Head", shape = "Ball", size = Vector3.new(0.7, 0.75, 1.1), offset = Vector3.new(0, 2.45, -2.6), color = DEER_BROWN, material = M.Fabric,
			anim = { kind = "bob", amount = 0.06, speed = 1.3 } },
		{ name = "Muzzle", shape = "Ball", size = Vector3.new(0.45, 0.45, 0.75), offset = Vector3.new(0, 2.28, -3.15), color = rgb(120, 84, 56), material = M.Fabric },
		{ name = "Nose", shape = "Ball", size = Vector3.new(0.26, 0.2, 0.18), offset = Vector3.new(0, 2.32, -3.5), color = DEER_DARK, material = M.SmoothPlastic },
		{ name = "EarL", shape = "Block", size = Vector3.new(0.14, 0.6, 0.32), offset = Vector3.new(-0.38, 2.95, -2.45), rot = Vector3.new(0, 0, 38), color = DEER_BROWN, material = M.Fabric },
		{ name = "EarR", shape = "Block", size = Vector3.new(0.14, 0.6, 0.32), offset = Vector3.new(0.38, 2.95, -2.45), rot = Vector3.new(0, 0, -38), color = DEER_BROWN, material = M.Fabric },
		{ name = "Rump", shape = "Ball", size = Vector3.new(1.1, 1, 0.5), offset = Vector3.new(0, 0.25, 1.6), color = DEER_PALE, material = M.Fabric },
		{ name = "Tail", shape = "Ball", size = Vector3.new(0.28, 0.45, 0.22), offset = Vector3.new(0, 0.6, 1.8), color = DEER_PALE, material = M.Fabric,
			anim = { kind = "wag", amount = 0.35, speed = 2.2 } },
	}, legs(deerShape, { Vector2.new(-0.45, -1.2), Vector2.new(0.45, -1.2), Vector2.new(-0.45, 1.15), Vector2.new(0.45, 1.15) }, 0.22, DEER_LEG)),
	game = true,
	silent = true,
})

local FOWL_COPPER, FOWL_DARK, FOWL_GREEN = rgb(170, 92, 48), rgb(80, 52, 36), rgb(40, 92, 70)
local fowlShape = { hipHeight = 0.7, hitbox = Vector3.new(1.1, 1, 1.6) }
creature({
	id = "wild_fowl",
	name = "Wild Fowl",
	description = "Copper-backed pheasants that scratch in the long grass and run rather than fly.",
	domain = "life",
	level = 1,
	health = 10,
	walk = 16,
	hipHeight = fowlShape.hipHeight,
	hitbox = fowlShape.hitbox,
	behaviour = "flee",
	fleeRadius = 16,
	leash = 60,
	pack = { min = 3, max = 5 },
	respawn = { min = 200, max = 360 },
	resist = {},
	biomes = { grasslands = 5, swamp = 3, tidal_flats = 3, deep_forest = 2, badlands = 1 },
	xp = 3,
	loot = { { item = "raw_meat", chance = 0.9, min = 1, max = 1 }, { item = "feather", chance = 0.9, min = 1, max = 3 } },
	body = with({
		{ name = "Body", shape = "Ball", size = Vector3.new(1.1, 1, 1.6), offset = Vector3.zero, color = FOWL_COPPER, material = M.Fabric },
		{ name = "Head", shape = "Ball", size = Vector3.new(0.5, 0.55, 0.55), offset = Vector3.new(0, 0.65, -0.75), color = FOWL_GREEN, material = M.SmoothPlastic,
			anim = { kind = "bob", amount = 0.12, speed = 3.5 } },
		{ name = "Beak", shape = "Block", size = Vector3.new(0.14, 0.12, 0.25), offset = Vector3.new(0, 0.6, -1.08), color = rgb(220, 200, 140), material = M.SmoothPlastic },
		{ name = "Wattle", shape = "Ball", size = Vector3.new(0.3, 0.2, 0.2), offset = Vector3.new(0, 0.78, -0.88), color = rgb(190, 40, 40), material = M.SmoothPlastic },
		{ name = "Tail", shape = "Block", size = Vector3.new(0.22, 0.12, 1.8), offset = Vector3.new(0, 0.35, 1.5), color = FOWL_DARK, material = M.Fabric,
			anim = { kind = "wag", amount = 0.2, speed = 1.6 } },
	}, legs(fowlShape, { Vector2.new(-0.22, 0.1), Vector2.new(0.22, 0.1) }, 0.1, rgb(150, 130, 90))),
	game = true,
	silent = true,
})

local HARE_FUR, HARE_DARK = rgb(160, 138, 108), rgb(90, 76, 60)
local hareShape = { hipHeight = 0.35, hitbox = Vector3.new(0.9, 0.9, 1.4) }
creature({
	id = "hare",
	name = "Hare",
	description = "Long-eared and quick, sitting up in the open as if nothing could ever catch it.",
	domain = "life",
	level = 1,
	health = 8,
	walk = 22,
	hipHeight = hareShape.hipHeight,
	hitbox = hareShape.hitbox,
	behaviour = "flee",
	fleeRadius = 20,
	leash = 60,
	pack = { min = 2, max = 4 },
	respawn = { min = 180, max = 320 },
	resist = {},
	biomes = { grasslands = 5, tundra = 4, frostpeaks = 2, desert_dunes = 2, badlands = 2, mountains = 2 },
	xp = 3,
	loot = { { item = "raw_meat", chance = 0.8, min = 1, max = 1 }, { item = "hare_pelt", chance = 0.8, min = 1, max = 1 } },
	body = with({
		{ name = "Body", shape = "Ball", size = Vector3.new(0.9, 0.9, 1.4), offset = Vector3.zero, color = HARE_FUR, material = M.Fabric },
		{ name = "Head", shape = "Ball", size = Vector3.new(0.6, 0.6, 0.7), offset = Vector3.new(0, 0.45, -0.7), color = HARE_FUR, material = M.Fabric },
		{ name = "EarL", shape = "Block", size = Vector3.new(0.14, 0.8, 0.28), offset = Vector3.new(-0.14, 1.1, -0.6), color = HARE_DARK, material = M.Fabric,
			anim = { kind = "wag", amount = 0.15, speed = 1.1 } },
		{ name = "EarR", shape = "Block", size = Vector3.new(0.14, 0.8, 0.28), offset = Vector3.new(0.14, 1.1, -0.6), color = HARE_DARK, material = M.Fabric,
			anim = { kind = "wag", amount = 0.15, speed = 1.3, phase = 1.2 } },
		{ name = "Tail", shape = "Ball", size = Vector3.new(0.3, 0.3, 0.3), offset = Vector3.new(0, 0.15, 0.75), color = rgb(235, 230, 220), material = M.Fabric },
	}, legs(hareShape, { Vector2.new(-0.25, -0.4), Vector2.new(0.25, -0.4), Vector2.new(-0.28, 0.4), Vector2.new(0.28, 0.4) }, 0.18, HARE_DARK)),
	game = true,
	silent = true,
})

return table.freeze({
	defs = table.freeze(defs),
	ids = table.freeze(ids),
	gameIds = table.freeze(gameIds),
	anyBiome = 1, -- the weight of a creature in a biome it doesn't list: every creature can turn up
	tuning = table.freeze({
		-- Population. Dens exist as data only; nothing is in the workspace until a player is near.
		wakeRadius = 220,
		sleepRadius = 300, -- hysteresis: walking back and forth at the edge doesn't churn rigs
		maxAlive = 70, -- default of the creatures_max_alive flag
		spawnsPerSecond = 6, -- rigs built per wake tick, nearest den first (no boot hitch)
		stepSeconds = 0.25,
		-- Dens. Rings are measured from the town's EDGE, so nothing is born inside the law's reach.
		densPerTown = 4,
		ringMin = 45,
		ringMax = 150,
		denSpacing = 45,
		denRadius = 12, -- members spawn and idle this close
		townMargin = 30, -- also stay this far out of every OTHER town
		minAboveSea = 4,
		maxSlope = 0.7,
		tries = 16,
		-- Herds of game (deer, fowl, hares): further out than the critters' dens, where hunters walk to.
		-- Planned with their own seed system ("herds"), so adding them moved no existing den.
		herdsPerTown = 3,
		herdRingMin = 70,
		herdRingMax = 230,
		scaredSeconds = 6, -- a shot (or a miss) sends the whole herd running from the shooter this long
		-- A dead member doesn't come back while someone stands on the den (no camping a spawn).
		campRadius = 35,
		-- Behaviour
		attackerMemory = 8, -- seconds it stays angry at whoever last hit it
		wanderPause = { min = 3, max = 7 },
		wanderStep = 14,
		fleeStep = 22,
		-- Rewards
		creditShare = 0.2, -- deal this share of its health to share in the kill
		decayScale = 8, -- factor = 1 / (1 + killsThisHour / decayScale), per type, per player
		-- Feedback
		weakAt = -0.3, -- at or below: "Weak!" over the target
		resistAt = 0.3, -- at or above: "Resists"
		wordCooldown = 1.5,
		fadeSeconds = 0.6,
	}),
})
