--!strict
--[[
	Familiars: all the content and numbers for familiars, as data (docs/Familiars.md).

	Every number is a first guess. Client and server both read this, and nothing here is secret: the
	seeded choices are made on the server, from the world seed, in Familiars/FamiliarRules.

	FIELDS
		stages       name, xp to reach it, size, share of a full hit per bite, health
		modes        the four orders you can give, with the words the screen shows
		abilities    one per domain. A familiar is born knowing its own domain's at abilityStage, and
		             learns a second at learnStage, from the domain you cast most.
		             kind: bolt   hits the target from range
		                   hinder hits the target and applies `status` for `seconds`
		                   mend   heals you when you're below mendBelow
		                   ward   puts `status` on you during a fight (ward: absorbs `share` of your health)
		                   haste  the same, for speed
		shapes       bodies. Each part names a colour slot: primary, secondary, accent, or eye
		looks        per domain: the material and glow
		personalities  how an innate temperament shows in a familiar. The client gets only the word, so
		             this hints at a temperament you may not know you have without naming it.
		names        safe, hand-picked default names: combining syllables could spell something bad
]]

local rgb = Color3.fromRGB
local M = Enum.Material

export type Stage = { name: string, xp: number, scale: number, bite: number, health: number }
export type Mode = { id: string, label: string, text: string }
export type Ability = {
	id: string,
	name: string,
	text: string,
	kind: string,
	cooldown: number,
	share: number?, -- bolt/hinder: of a bite. mend/ward: of your max health
	status: string?,
	seconds: number?,
}
export type ShapePart = { name: string, shape: string, size: Vector3, offset: Vector3, slot: string, transparency: number? }
export type Shape = { id: string, hover: number, parts: { ShapePart } }
export type Look = { material: Enum.Material, glow: Color3, emit: boolean }
export type Personality = { word: string, line: string, speed: number, damage: number, cooldown: number, health: number }

local Familiars = {}

Familiars.tuning = {
	stepSeconds = 0.2, -- how often each familiar thinks and picks a new goal
	secondSeconds = 1, -- slower checks: regeneration, hunting, whether you're still playing
	tierEvery = 5,

	-- Bonding: your first few spells, or reaching this tier, whichever comes first.
	bondCasts = 5,
	bondTier = 2,

	-- Movement
	speed = 22,
	speedAboveOwner = 8, -- it keeps up with you, however you travel...
	maxSpeed = 110,
	followAt = 7, -- ...staying about this far away
	teleportAt = 110, -- past this it just appears beside you (a Rift, a recall, a long fall)
	stayLimit = 400, -- told to stay, it comes running once you're this far off
	groundRay = 60,

	-- Fighting
	biteReach = 6,
	biteCooldown = 1.8,
	boltRange = 32,
	targetMemory = 8, -- seconds it stays on a target after you or it last touched
	leash = 70, -- never further than this from you
	huntRadius = 36, -- Hunt: wild creatures this close to you
	activeSeconds = 90, -- Hunt and XP only while you've moved or cast this recently: no idle farming
	activeMove = 4, -- studs that count as having moved
	pvpBiteShare = 0.06, -- no bite takes more than this share of another player's health
	pvpStatusShare = 0.5, -- statuses last this much of their time on players
	abilityMinDensity = 0.15, -- abilities fail where magic does (the Hushed Hollow)

	-- Its health: only hurt when something it attacks hits back. Spells can't touch it.
	retaliation = 0.05, -- of its health, for each attack it lands
	retaliationBig = 0.1, -- against anything with at least bigTarget health
	bigTarget = 2000,
	regen = 0.03, -- of its health per second, once out of a fight for regenAfter seconds
	regenAfter = 6,
	koSeconds = 45, -- knocked out, it comes back on its own. It can't die.
	healthPerTier = 0.2, -- +20% per mastery tier above the first
	mythicDamage = 1.25, -- Time, Gravity and Reality familiars hit harder: those domains are meant to be strong

	-- Growing
	castXp = 2,
	castGap = 4, -- seconds between casts that count
	killXp = 10,
	killXpMax = 50,
	killXpHealthPer = 25, -- +1 per this much of the target's health
	dailyXp = 600,
	abilityStage = 2,
	learnStage = 4,
	nameChars = 20,
}

Familiars.stages = {
	{ name = "Hatchling", xp = 0, scale = 0.75, bite = 0.18, health = 60 },
	{ name = "Young", xp = 120, scale = 0.9, bite = 0.24, health = 110 },
	{ name = "Grown", xp = 500, scale = 1.05, bite = 0.3, health = 170 },
	{ name = "Elder", xp = 1500, scale = 1.25, bite = 0.36, health = 240 },
	{ name = "Ascendant", xp = 4000, scale = 1.5, bite = 0.45, health = 330 },
} :: { Stage }

Familiars.modes = {
	{ id = "follow", label = "Follow", text = "Stays with you and never fights." },
	{ id = "guard", label = "Guard", text = "Fights what you fight, and whatever fights you." },
	{ id = "hunt", label = "Hunt", text = "Also goes after wild creatures close to you, while you're playing." },
	{ id = "stay", label = "Stay", text = "Holds this spot, and bites whatever comes within reach." },
} :: { Mode }

Familiars.defaultMode = "guard"

Familiars.abilities = {
	energy = { id = "energy", name = "Spark Spit", text = "Spits a burning spark at your enemy.", kind = "hinder", cooldown = 10, share = 1.2, status = "burning", seconds = 3 },
	earth = { id = "earth", name = "Stone Hide", text = "Lends you a stone skin in a fight.", kind = "ward", cooldown = 18, share = 0.08, status = "ward", seconds = 6 },
	water = { id = "water", name = "Tide Snare", text = "Drags at your enemy's feet.", kind = "hinder", cooldown = 11, share = 0.8, status = "slow", seconds = 3 },
	air = { id = "air", name = "Tailwind", text = "Puts the wind behind you in a fight.", kind = "haste", cooldown = 16, status = "haste", seconds = 3 },
	life = { id = "life", name = "Mending Bloom", text = "Heals you when you're hurt.", kind = "mend", cooldown = 14, share = 0.07 },
	mind = { id = "mind", name = "Dizzy Thought", text = "Leaves your enemy dazed.", kind = "hinder", cooldown = 12, share = 0.8, status = "dazed", seconds = 3 },
	spirit = { id = "spirit", name = "Watchful Presence", text = "Stands between you and the next blow.", kind = "ward", cooldown = 18, share = 0.08, status = "ward", seconds = 6 },
	void = { id = "void", name = "Hollow Bite", text = "Its bite makes your enemy easier to hurt.", kind = "hinder", cooldown = 12, share = 1, status = "hexed", seconds = 4 },
	space = { id = "space", name = "Skip Bite", text = "Bites from somewhere it isn't.", kind = "bolt", cooldown = 7, share = 1.7 },
	time = { id = "time", name = "Slow Moment", text = "Your enemy's next few seconds pass slowly.", kind = "hinder", cooldown = 13, share = 0.8, status = "time_slow", seconds = 3 },
	gravity = { id = "gravity", name = "Weigh Down", text = "Pins your enemy to the ground for a moment.", kind = "hinder", cooldown = 13, share = 1, status = "root", seconds = 1.5 },
	reality = { id = "reality", name = "Small Mistake", text = "Your enemy becomes unlucky: hits on them crit more.", kind = "hinder", cooldown = 12, share = 1, status = "jinxed", seconds = 5 },
} :: { [string]: Ability }

local function ball(name: string, size: Vector3, offset: Vector3, slot: string, transparency: number?): ShapePart
	return { name = name, shape = "Ball", size = size, offset = offset, slot = slot, transparency = transparency }
end

local function block(name: string, size: Vector3, offset: Vector3, slot: string): ShapePart
	return { name = name, shape = "Block", size = size, offset = offset, slot = slot }
end

local function v(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

-- -Z is its front (its eyes look that way).
Familiars.shapes = {
	{
		id = "wisp", hover = 4.2,
		parts = {
			ball("Body", v(1.8, 1.8, 1.8), v(0, 0, 0), "primary"),
			ball("Aura", v(2.8, 2.8, 2.8), v(0, 0, 0), "secondary", 0.75),
			ball("Tail", v(0.8, 0.8, 1.2), v(0, -0.2, 1.3), "accent", 0.25),
			ball("EyeL", v(0.32, 0.32, 0.32), v(-0.38, 0.2, -0.82), "eye"),
			ball("EyeR", v(0.32, 0.32, 0.32), v(0.38, 0.2, -0.82), "eye"),
		},
	},
	{
		id = "moth", hover = 3.8,
		parts = {
			ball("Body", v(0.9, 0.9, 1.9), v(0, 0, 0), "primary"),
			ball("WingL", v(1.9, 0.18, 1.3), v(-1.2, 0.25, 0), "secondary", 0.15),
			ball("WingR", v(1.9, 0.18, 1.3), v(1.2, 0.25, 0), "secondary", 0.15),
			ball("Crest", v(0.3, 0.7, 0.3), v(0, 0.6, -0.65), "accent"),
			ball("EyeL", v(0.26, 0.26, 0.26), v(-0.22, 0.14, -0.86), "eye"),
			ball("EyeR", v(0.26, 0.26, 0.26), v(0.22, 0.14, -0.86), "eye"),
		},
	},
	{
		id = "beetle", hover = 1.6,
		parts = {
			ball("Body", v(2, 1.2, 2.5), v(0, 0, 0.1), "primary"),
			ball("Stripe", v(0.55, 1.26, 2.2), v(0, 0.02, 0.1), "accent"),
			ball("Head", v(1.1, 0.9, 0.9), v(0, 0, -1.3), "secondary"),
			ball("EyeL", v(0.26, 0.26, 0.26), v(-0.32, 0.18, -1.7), "eye"),
			ball("EyeR", v(0.26, 0.26, 0.26), v(0.32, 0.18, -1.7), "eye"),
		},
	},
	{
		id = "serpent", hover = 2.6,
		parts = {
			ball("Head", v(1.2, 1, 1.4), v(0, 0.25, -1.35), "primary"),
			ball("Neck", v(1.05, 1, 1.25), v(0, 0.05, -0.3), "secondary"),
			ball("Middle", v(0.9, 0.85, 1.15), v(0, -0.1, 0.65), "primary"),
			ball("Tail", v(0.6, 0.55, 1), v(0, -0.2, 1.55), "accent"),
			ball("EyeL", v(0.24, 0.24, 0.24), v(-0.36, 0.45, -1.9), "eye"),
			ball("EyeR", v(0.24, 0.24, 0.24), v(0.36, 0.45, -1.9), "eye"),
		},
	},
	{
		id = "golem", hover = 2.1,
		parts = {
			block("Body", v(1.8, 1.8, 1.5), v(0, 0, 0), "primary"),
			block("Head", v(1.1, 0.8, 1), v(0, 1.25, -0.1), "secondary"),
			block("ArmL", v(0.5, 1.2, 0.6), v(-1.25, -0.1, 0), "accent"),
			block("ArmR", v(0.5, 1.2, 0.6), v(1.25, -0.1, 0), "accent"),
			ball("EyeL", v(0.24, 0.24, 0.24), v(-0.26, 1.3, -0.6), "eye"),
			ball("EyeR", v(0.24, 0.24, 0.24), v(0.26, 1.3, -0.6), "eye"),
		},
	},
	{
		id = "fox", hover = 1.9,
		parts = {
			ball("Body", v(1.2, 1.1, 2.2), v(0, 0, 0.1), "primary"),
			ball("Head", v(1.2, 1.05, 1.1), v(0, 0.55, -1.2), "secondary"),
			ball("EarL", v(0.32, 0.65, 0.25), v(-0.38, 1.2, -1.2), "accent"),
			ball("EarR", v(0.32, 0.65, 0.25), v(0.38, 1.2, -1.2), "accent"),
			ball("Tail", v(0.65, 0.65, 1.7), v(0, 0.45, 1.75), "accent"),
			ball("EyeL", v(0.22, 0.22, 0.22), v(-0.28, 0.7, -1.72), "eye"),
			ball("EyeR", v(0.22, 0.22, 0.22), v(0.28, 0.7, -1.72), "eye"),
		},
	},
} :: { Shape }

Familiars.looks = {
	energy = { material = M.Neon, glow = rgb(255, 150, 60), emit = true },
	earth = { material = M.Slate, glow = rgb(170, 135, 95), emit = false },
	water = { material = M.Glass, glow = rgb(80, 170, 255), emit = true },
	air = { material = M.SmoothPlastic, glow = rgb(205, 240, 245), emit = true },
	life = { material = M.Grass, glow = rgb(110, 225, 110), emit = true },
	mind = { material = M.SmoothPlastic, glow = rgb(205, 130, 255), emit = true },
	spirit = { material = M.Neon, glow = rgb(190, 225, 255), emit = true },
	void = { material = M.Glass, glow = rgb(95, 60, 165), emit = true },
	space = { material = M.Glass, glow = rgb(90, 90, 225), emit = true },
	time = { material = M.Metal, glow = rgb(235, 205, 110), emit = true },
	gravity = { material = M.Basalt, glow = rgb(135, 95, 215), emit = true },
	reality = { material = M.Neon, glow = rgb(255, 110, 195), emit = true },
} :: { [string]: Look }

Familiars.personalities = {
	volatile = { word = "Fierce", line = "It snaps first and thinks later.", speed = 1.05, damage = 1.15, cooldown = 1, health = 0.9 },
	precise = { word = "Careful", line = "It watches, then bites exactly once.", speed = 1, damage = 1.05, cooldown = 1.05, health = 1 },
	resonant = { word = "Devoted", line = "It hums when you're near.", speed = 1, damage = 1, cooldown = 1, health = 1.1 },
	hollow = { word = "Restless", line = "It tires fast and is back up faster.", speed = 1.1, damage = 1, cooldown = 0.95, health = 0.85 },
	deepwell = { word = "Sturdy", line = "It takes a lot of wearing down.", speed = 0.95, damage = 1, cooldown = 1.05, health = 1.25 },
	swift = { word = "Quick", line = "It's already there.", speed = 1.2, damage = 0.95, cooldown = 0.9, health = 0.95 },
	patient = { word = "Patient", line = "It waits for the moment, and it hits hard.", speed = 0.95, damage = 1.15, cooldown = 1.1, health = 1.05 },
	steadfast = { word = "Loyal", line = "It doesn't leave your side willingly.", speed = 1, damage = 0.95, cooldown = 1, health = 1.2 },
	brittle = { word = "Reckless", line = "It's braver than it is tough.", speed = 1.05, damage = 1.2, cooldown = 1, health = 0.8 },
	conduit = { word = "Curious", line = "It noses at every trace of magic nearby.", speed = 1.1, damage = 1, cooldown = 1, health = 1 },
	bloodbound = { word = "Bonded", line = "When you hurt, it knows.", speed = 1, damage = 1.1, cooldown = 1, health = 1 },
} :: { [string]: Personality }

Familiars.defaultPersonality = { word = "Gentle", line = "It seems pleased just to be here.", speed = 1, damage = 1, cooldown = 1, health = 1 } :: Personality

Familiars.names = {
	"Pip", "Moss", "Ember", "Nib", "Tansy", "Quill", "Bracken", "Wick", "Sorrel", "Fennel",
	"Tam", "Juniper", "Flint", "Mote", "Dapple", "Thimble", "Rook", "Sable", "Clove", "Pebble",
	"Bramble", "Nettle", "Cricket", "Sprig", "Tumble", "Oriel", "Whit", "Hazel", "Marrow", "Drift",
	"Lumen", "Cinder", "Vesper", "Sundry", "Kestrel", "Nimbus", "Tallow", "Burr", "Yarrow", "Minnow",
}

Familiars.eyeColor = rgb(20, 20, 26)

return table.freeze(Familiars)
