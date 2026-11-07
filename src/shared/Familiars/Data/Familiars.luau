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
		shapes       bodies. Each part names a colour slot: primary, secondary, accent, glow (Neon),
		             dark or eye. fromStage is when it appears, anim how it moves on the client
		             (wag, flap, bob, orbit; Fx/FamiliarAnimator)
		growth       what shows a familiar's stage from a distance
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
export type Anim = { kind: string, amount: number, speed: number, phase: number? }
export type ShapePart = { name: string, shape: string, size: Vector3, offset: Vector3, slot: string, transparency: number?, fromStage: number?, anim: Anim? }
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

local function v(x: number, y: number, z: number): Vector3
	return Vector3.new(x, y, z)
end

-- A part, with its options: alpha (transparency), from (the stage it appears at), anim (how it moves).
local function ball(name: string, size: Vector3, offset: Vector3, slot: string, opts: { [string]: any }?): ShapePart
	local o = opts or {}
	return { name = name, shape = "Ball", size = size, offset = offset, slot = slot, transparency = o.alpha, fromStage = o.from, anim = o.anim }
end

local function block(name: string, size: Vector3, offset: Vector3, slot: string, opts: { [string]: any }?): ShapePart
	local o = opts or {}
	return { name = name, shape = "Block", size = size, offset = offset, slot = slot, transparency = o.alpha, fromStage = o.from, anim = o.anim }
end

local function wag(amount: number, speed: number, phase: number?): Anim
	return { kind = "wag", amount = amount, speed = speed, phase = phase }
end

local function flap(amount: number, speed: number, phase: number?): Anim
	return { kind = "flap", amount = amount, speed = speed, phase = phase }
end

local function bob(amount: number, speed: number, phase: number?): Anim
	return { kind = "bob", amount = amount, speed = speed, phase = phase }
end

local function orbit(speed: number, phase: number?): Anim
	return { kind = "orbit", amount = 0, speed = speed, phase = phase }
end

-- -Z is its front. Eyes get a pupil and a blink from FamiliarRules.body. Each part's anim is applied on
-- the client by Fx/FamiliarAnimator. fromStage parts are how it visibly grows.
Familiars.shapes = {
	{
		id = "wisp", hover = 4.4,
		parts = {
			ball("Core", v(1.1, 1.1, 1.1), v(0, 0, 0), "glow"),
			ball("Body", v(1.9, 1.9, 1.9), v(0, 0, 0), "primary", { alpha = 0.35 }),
			ball("Aura", v(3, 3, 3), v(0, 0, 0), "secondary", { alpha = 0.8 }),
			ball("Tail1", v(0.9, 0.9, 1), v(0, -0.15, 1.3), "primary", { alpha = 0.2, anim = wag(0.25, 2.4) }),
			ball("Tail2", v(0.6, 0.6, 0.8), v(0, -0.3, 2), "accent", { alpha = 0.3, anim = wag(0.3, 2.4, 0.7) }),
			ball("Tail3", v(0.32, 0.32, 0.6), v(0, -0.42, 2.55), "glow", { alpha = 0.3, anim = wag(0.35, 2.4, 1.4) }),
			ball("Spark1", v(0.3, 0.3, 0.3), v(1.6, 0.2, 0), "glow", { anim = orbit(1.4) }),
			ball("Spark2", v(0.26, 0.26, 0.26), v(-1.6, -0.25, 0), "glow", { from = 3, anim = orbit(1.4) }),
			ball("EyeL", v(0.42, 0.46, 0.2), v(-0.36, 0.2, -0.86), "eye"),
			ball("EyeR", v(0.42, 0.46, 0.2), v(0.36, 0.2, -0.86), "eye"),
		},
	},
	{
		id = "moth", hover = 3.9,
		parts = {
			ball("Thorax", v(0.95, 0.95, 1.2), v(0, 0, -0.1), "primary"),
			ball("Abdomen", v(0.8, 0.75, 1.4), v(0, -0.08, 0.95), "secondary"),
			ball("Stripe", v(0.84, 0.3, 0.5), v(0, -0.02, 1), "accent"),
			ball("Head", v(0.72, 0.68, 0.62), v(0, 0.08, -0.9), "primary"),
			ball("WingL", v(2.3, 0.1, 1.5), v(-1.45, 0.25, -0.2), "secondary", { alpha = 0.12, anim = flap(0.5, 9) }),
			ball("WingR", v(2.3, 0.1, 1.5), v(1.45, 0.25, -0.2), "secondary", { alpha = 0.12, anim = flap(0.5, 9) }),
			ball("SpotL", v(0.7, 0.12, 0.6), v(-1.75, 0.34, -0.2), "accent", { anim = flap(0.5, 9) }),
			ball("SpotR", v(0.7, 0.12, 0.6), v(1.75, 0.34, -0.2), "accent", { anim = flap(0.5, 9) }),
			ball("RearL", v(1.5, 0.1, 1.1), v(-1, 0.1, 0.85), "primary", { alpha = 0.2, anim = flap(0.42, 9, 0.5) }),
			ball("RearR", v(1.5, 0.1, 1.1), v(1, 0.1, 0.85), "primary", { alpha = 0.2, anim = flap(0.42, 9, 0.5) }),
			ball("FeelerL", v(0.08, 0.1, 0.8), v(-0.22, 0.45, -1.3), "accent", { anim = bob(0.05, 5) }),
			ball("FeelerR", v(0.08, 0.1, 0.8), v(0.22, 0.45, -1.3), "accent", { anim = bob(0.05, 5, 1) }),
			ball("Crest", v(0.34, 0.5, 0.34), v(0, 0.55, -0.15), "glow", { from = 3 }),
			ball("EyeL", v(0.32, 0.36, 0.18), v(-0.24, 0.16, -1.14), "eye"),
			ball("EyeR", v(0.32, 0.36, 0.18), v(0.24, 0.16, -1.14), "eye"),
		},
	},
	{
		id = "beetle", hover = 1.5,
		parts = {
			ball("Body", v(1.9, 1.05, 2.5), v(0, -0.05, 0.1), "secondary"),
			ball("ShellL", v(1.05, 0.95, 2.4), v(-0.5, 0.22, 0.1), "primary"),
			ball("ShellR", v(1.05, 0.95, 2.4), v(0.5, 0.22, 0.1), "primary"),
			ball("Stripe", v(0.2, 1.06, 2.2), v(0, 0.24, 0.1), "glow"),
			ball("Head", v(1.05, 0.8, 0.85), v(0, 0, -1.3), "secondary"),
			ball("HornL", v(0.16, 0.16, 0.8), v(-0.32, 0.12, -1.95), "accent", { anim = bob(0.04, 4) }),
			ball("HornR", v(0.16, 0.16, 0.8), v(0.32, 0.12, -1.95), "accent", { anim = bob(0.04, 4, 1) }),
			ball("LegFL", v(0.8, 0.14, 0.16), v(-1.15, -0.45, -0.6), "secondary", { anim = bob(0.07, 7) }),
			ball("LegFR", v(0.8, 0.14, 0.16), v(1.15, -0.45, -0.6), "secondary", { anim = bob(0.07, 7, 3.1) }),
			ball("LegML", v(0.8, 0.14, 0.16), v(-1.2, -0.45, 0.1), "secondary", { anim = bob(0.07, 7, 3.1) }),
			ball("LegMR", v(0.8, 0.14, 0.16), v(1.2, -0.45, 0.1), "secondary", { anim = bob(0.07, 7) }),
			ball("LegRL", v(0.8, 0.14, 0.16), v(-1.15, -0.45, 0.85), "secondary", { anim = bob(0.07, 7) }),
			ball("LegRR", v(0.8, 0.14, 0.16), v(1.15, -0.45, 0.85), "secondary", { anim = bob(0.07, 7, 3.1) }),
			ball("GreatHorn", v(0.3, 0.8, 0.3), v(0, 0.75, -1.35), "glow", { from = 3 }),
			ball("EyeL", v(0.28, 0.32, 0.16), v(-0.3, 0.16, -1.68), "eye"),
			ball("EyeR", v(0.28, 0.32, 0.16), v(0.3, 0.16, -1.68), "eye"),
		},
	},
	{
		id = "serpent", hover = 2.7,
		parts = {
			ball("Head", v(1.2, 0.9, 1.45), v(0, 0.35, -1.7), "primary"),
			ball("Snout", v(0.8, 0.5, 0.75), v(0, 0.2, -2.45), "secondary"),
			ball("Neck", v(0.98, 0.92, 1.1), v(0, 0.1, -0.85), "primary"),
			ball("Seg1", v(0.95, 0.9, 1.1), v(0, -0.02, -0.05), "secondary", { anim = wag(0.05, 2.4) }),
			ball("Seg2", v(0.88, 0.84, 1.05), v(0, -0.1, 0.7), "primary", { anim = wag(0.13, 2.4, 0.6) }),
			ball("Seg3", v(0.76, 0.72, 1), v(0, -0.16, 1.42), "secondary", { anim = wag(0.2, 2.4, 1.2) }),
			ball("Seg4", v(0.62, 0.58, 0.95), v(0, -0.2, 2.1), "primary", { anim = wag(0.27, 2.4, 1.8) }),
			ball("Seg5", v(0.45, 0.42, 0.9), v(0, -0.23, 2.72), "secondary", { anim = wag(0.33, 2.4, 2.4) }),
			ball("TailTip", v(0.24, 0.5, 0.75), v(0, -0.2, 3.28), "glow", { anim = wag(0.38, 2.4, 3) }),
			ball("Belly", v(0.7, 0.3, 2.6), v(0, -0.4, 0), "accent", { alpha = 0.1 }),
			ball("Fin1", v(0.12, 0.55, 0.6), v(0, 0.62, -0.75), "accent"),
			ball("Fin2", v(0.12, 0.5, 0.55), v(0, 0.48, -0.05), "accent", { anim = wag(0.05, 2.4) }),
			ball("Fin3", v(0.12, 0.42, 0.5), v(0, 0.3, 0.7), "accent", { anim = wag(0.13, 2.4, 0.6) }),
			ball("WhiskerL", v(0.6, 0.06, 0.06), v(-0.62, 0.12, -2.45), "glow", { anim = bob(0.05, 3) }),
			ball("WhiskerR", v(0.6, 0.06, 0.06), v(0.62, 0.12, -2.45), "glow", { anim = bob(0.05, 3, 1) }),
			ball("HornL", v(0.16, 0.65, 0.2), v(-0.34, 0.95, -1.5), "glow", { from = 3 }),
			ball("HornR", v(0.16, 0.65, 0.2), v(0.34, 0.95, -1.5), "glow", { from = 3 }),
			ball("FrillL", v(0.75, 0.55, 0.14), v(-0.72, 0.38, -1.25), "accent", { from = 4, alpha = 0.1, anim = flap(0.12, 3) }),
			ball("FrillR", v(0.75, 0.55, 0.14), v(0.72, 0.38, -1.25), "accent", { from = 4, alpha = 0.1, anim = flap(0.12, 3) }),
			ball("EyeL", v(0.34, 0.38, 0.2), v(-0.44, 0.52, -2.1), "eye"),
			ball("EyeR", v(0.34, 0.38, 0.2), v(0.44, 0.52, -2.1), "eye"),
		},
	},
	{
		id = "golem", hover = 2.4,
		parts = {
			block("Body", v(1.8, 1.7, 1.4), v(0, 0, 0), "primary"),
			block("Chest", v(1.2, 0.9, 0.2), v(0, 0.15, -0.72), "secondary"),
			ball("Heart", v(0.55, 0.55, 0.3), v(0, 0.15, -0.84), "glow"),
			block("Head", v(1.15, 0.85, 1), v(0, 1.35, -0.1), "secondary", { anim = bob(0.07, 1.8) }),
			block("Brow", v(1.2, 0.18, 0.2), v(0, 1.62, -0.6), "primary", { anim = bob(0.07, 1.8) }),
			block("ArmL", v(0.55, 1.15, 0.65), v(-1.55, 0, 0), "accent", { anim = bob(0.16, 1.8, 1.2) }),
			block("ArmR", v(0.55, 1.15, 0.65), v(1.55, 0, 0), "accent", { anim = bob(0.16, 1.8, 2.4) }),
			block("Foot", v(1.2, 0.5, 1), v(0, -1.25, 0), "secondary", { anim = bob(0.08, 1.8, 3.1) }),
			block("Rock1", v(0.42, 0.42, 0.42), v(1.7, 1, 0.5), "primary", { anim = orbit(0.9) }),
			block("Rock2", v(0.34, 0.34, 0.34), v(-1.7, 0.8, -0.5), "accent", { from = 3, anim = orbit(0.9) }),
			block("Shoulder", v(2.3, 0.3, 0.8), v(0, 0.92, 0), "accent", { from = 4 }),
			ball("EyeL", v(0.26, 0.3, 0.14), v(-0.26, 1.38, -0.62), "eye", { anim = bob(0.07, 1.8) }),
			ball("EyeR", v(0.26, 0.3, 0.14), v(0.26, 1.38, -0.62), "eye", { anim = bob(0.07, 1.8) }),
		},
	},
	{
		id = "fox", hover = 2,
		parts = {
			ball("Body", v(1.15, 1.05, 2.2), v(0, 0, 0.15), "primary"),
			ball("Chest", v(0.85, 0.85, 0.75), v(0, 0.02, -0.75), "accent"),
			ball("Head", v(1.2, 1, 1.05), v(0, 0.6, -1.2), "primary"),
			ball("Muzzle", v(0.55, 0.42, 0.65), v(0, 0.4, -1.8), "accent"),
			ball("Nose", v(0.18, 0.15, 0.14), v(0, 0.48, -2.12), "dark"),
			ball("EarL", v(0.36, 0.72, 0.22), v(-0.4, 1.3, -1.15), "primary", { anim = bob(0.04, 2.1) }),
			ball("EarR", v(0.36, 0.72, 0.22), v(0.4, 1.3, -1.15), "primary", { anim = bob(0.04, 2.1, 1.5) }),
			ball("InnerL", v(0.18, 0.45, 0.1), v(-0.4, 1.28, -1.27), "glow", { anim = bob(0.04, 2.1) }),
			ball("InnerR", v(0.18, 0.45, 0.1), v(0.4, 1.28, -1.27), "glow", { anim = bob(0.04, 2.1, 1.5) }),
			ball("LegFL", v(0.26, 0.7, 0.26), v(-0.36, -0.6, -0.55), "secondary", { anim = bob(0.09, 6) }),
			ball("LegFR", v(0.26, 0.7, 0.26), v(0.36, -0.6, -0.55), "secondary", { anim = bob(0.09, 6, 3.1) }),
			ball("LegRL", v(0.26, 0.7, 0.26), v(-0.36, -0.6, 0.8), "secondary", { anim = bob(0.09, 6, 3.1) }),
			ball("LegRR", v(0.26, 0.7, 0.26), v(0.36, -0.6, 0.8), "secondary", { anim = bob(0.09, 6) }),
			ball("Tail", v(0.72, 0.72, 1.7), v(0, 0.4, 1.95), "primary", { anim = wag(0.28, 3.2) }),
			ball("TailTip", v(0.48, 0.48, 0.75), v(0, 0.48, 2.85), "accent", { anim = wag(0.34, 3.2, 0.4) }),
			ball("TailTwo", v(0.55, 0.55, 1.4), v(0.75, 0.55, 1.8), "primary", { from = 3, anim = wag(0.3, 3.2, 1.2) }),
			ball("TailThree", v(0.55, 0.55, 1.4), v(-0.75, 0.55, 1.8), "primary", { from = 4, anim = wag(0.3, 3.2, 2.1) }),
			ball("EyeL", v(0.26, 0.3, 0.14), v(-0.3, 0.72, -1.68), "eye"),
			ball("EyeR", v(0.26, 0.3, 0.14), v(0.3, 0.72, -1.68), "eye"),
		},
	},
} :: { Shape }

-- `glow` colours a domain's Neon details. Materials avoid Glass, which draws badly on these meshes.
Familiars.looks = {
	energy = { material = M.SmoothPlastic, glow = rgb(255, 150, 60), emit = true },
	earth = { material = M.Slate, glow = rgb(205, 165, 105), emit = false },
	water = { material = M.SmoothPlastic, glow = rgb(90, 180, 255), emit = true },
	air = { material = M.SmoothPlastic, glow = rgb(190, 240, 245), emit = true },
	life = { material = M.Grass, glow = rgb(120, 230, 110), emit = true },
	mind = { material = M.SmoothPlastic, glow = rgb(205, 130, 255), emit = true },
	spirit = { material = M.SmoothPlastic, glow = rgb(190, 225, 255), emit = true },
	void = { material = M.Slate, glow = rgb(130, 85, 225), emit = true },
	space = { material = M.SmoothPlastic, glow = rgb(110, 110, 245), emit = true },
	time = { material = M.Metal, glow = rgb(240, 210, 115), emit = true },
	gravity = { material = M.Basalt, glow = rgb(150, 105, 230), emit = true },
	reality = { material = M.SmoothPlastic, glow = rgb(255, 110, 195), emit = true },
} :: { [string]: Look }

-- Growing shows from a distance: motes circling it from `moteFrom`, one more per stage, then a light.
Familiars.growth = { moteFrom = 3, moteSize = 0.24, moteRadius = 1.3, moteSpeed = 1.1, lightFrom = 4, trailFrom = 2 }

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

Familiars.eyeColor = rgb(245, 245, 240)
Familiars.pupilColor = rgb(16, 16, 22)

return table.freeze(Familiars)
