--!strict
--[[
	FxRecipes: the data that turns a spell cue into particles, beams and trails. No logic here;
	Fx/SpellFx reads it. Three layers combine for every effect:

	1. SIGNATURE (who cast it)   the caster's colours (primary / secondary / accent) tint everything;
	                             their particle style picks the texture and shape; their motion picks
	                             how particles move. Two Fire mages never look the same.
	2. TIER (how well)           mastery tier 0..8 sets refinement. A Novice's fire is messy:
	                             wide spread, flickering transparency, uneven size, short wild lives,
	                             a beam that wobbles (CurveSize). A Grandmaster's is controlled:
	                             tight spread, smooth curves, high LightEmission, a straight beam.
	3. FORM (what shape)         touch / projectile / beam / burst / aura / zone / wall / pillar /
	                             chain / summon / ritual: counts, sizes, speeds, lifetimes.

	Textures are built-in rbxasset particles so everything works before custom art exists
	(docs/UI.md §6 lists the custom textures to commission per particle style).
]]

export type Refinement = {
	spread: number, -- SpreadAngle multiplier
	flicker: number, -- 0..1 transparency noise in the sequence
	sizeJitter: number, -- 0..1 unevenness of the size curve
	rate: number, -- emission multiplier
	lifeSpread: number, -- 0..1 lifetime randomness
	emission: number, -- LightEmission
	drag: number, -- Drag (higher = more controlled, settles faster)
	beamCurve: number, -- beam wobble (CurveSize0/1 magnitude)
	trailLife: number, -- Trail Lifetime (seconds)
}

local Recipes = {}

-- Mastery tier index (MasteryTiers): 0 Untouched .. 8 Transcendent.
Recipes.tiers = {
	[0] = { spread = 2.0, flicker = 0.6, sizeJitter = 0.7, rate = 0.5, lifeSpread = 0.8, emission = 0.1, drag = 0, beamCurve = 4, trailLife = 0.12 },
	[1] = { spread = 1.9, flicker = 0.55, sizeJitter = 0.65, rate = 0.6, lifeSpread = 0.75, emission = 0.15, drag = 0.5, beamCurve = 3.5, trailLife = 0.14 },
	[2] = { spread = 1.6, flicker = 0.45, sizeJitter = 0.5, rate = 0.75, lifeSpread = 0.6, emission = 0.25, drag = 1, beamCurve = 2.5, trailLife = 0.16 }, -- Novice: messy, flickering
	[3] = { spread = 1.3, flicker = 0.3, sizeJitter = 0.35, rate = 0.9, lifeSpread = 0.45, emission = 0.35, drag = 2, beamCurve = 1.5, trailLife = 0.2 },
	[4] = { spread = 1.1, flicker = 0.2, sizeJitter = 0.25, rate = 1.0, lifeSpread = 0.35, emission = 0.45, drag = 3, beamCurve = 0.8, trailLife = 0.24 },
	[5] = { spread = 0.9, flicker = 0.12, sizeJitter = 0.15, rate = 1.1, lifeSpread = 0.25, emission = 0.55, drag = 4, beamCurve = 0.4, trailLife = 0.28 },
	[6] = { spread = 0.75, flicker = 0.06, sizeJitter = 0.1, rate = 1.2, lifeSpread = 0.18, emission = 0.65, drag = 5, beamCurve = 0.15, trailLife = 0.32 },
	[7] = { spread = 0.6, flicker = 0.02, sizeJitter = 0.05, rate = 1.3, lifeSpread = 0.12, emission = 0.75, drag = 6, beamCurve = 0, trailLife = 0.36 }, -- Grandmaster: controlled, elegant
	[8] = { spread = 0.5, flicker = 0, sizeJitter = 0, rate = 1.4, lifeSpread = 0.08, emission = 0.85, drag = 7, beamCurve = 0, trailLife = 0.4 },
} :: { [number]: Refinement }

local SPARKLES = "rbxasset://textures/particles/sparkles_main.dds"
local FIRE = "rbxasset://textures/particles/fire_main.dds"
local SMOKE = "rbxasset://textures/particles/smoke_main.dds"

-- Signature particle style -> texture and base shape of each particle.
Recipes.particles = {
	embers = { texture = FIRE, size = 0.6, lightInfluence = 0 },
	motes = { texture = SPARKLES, size = 0.4, lightInfluence = 0 },
	shards = { texture = SPARKLES, size = 0.5, lightInfluence = 0.3 },
	ribbons = { texture = SPARKLES, size = 0.8, lightInfluence = 0 },
	sparks = { texture = SPARKLES, size = 0.3, lightInfluence = 0 },
	petals = { texture = SPARKLES, size = 0.6, lightInfluence = 0.6 },
	ripples = { texture = SPARKLES, size = 0.9, lightInfluence = 0.3 },
	glyphs = { texture = SPARKLES, size = 0.7, lightInfluence = 0 },
	smoke = { texture = SMOKE, size = 1.4, lightInfluence = 1 },
	dust = { texture = SMOKE, size = 1.0, lightInfluence = 1 },
	bubbles = { texture = SPARKLES, size = 0.5, lightInfluence = 0.4 },
	feathers = { texture = SPARKLES, size = 0.6, lightInfluence = 0.5 },
} :: { [string]: { texture: string, size: number, lightInfluence: number } }

-- Signature motion -> how particles move (base values; tier refinement scales spread and drag).
Recipes.motions = {
	swirling = { speed = 4, spread = 45, rotSpeed = 180, accelerationUp = 1, pulse = false },
	darting = { speed = 14, spread = 20, rotSpeed = 30, accelerationUp = 0, pulse = false },
	drifting = { speed = 1.5, spread = 60, rotSpeed = 20, accelerationUp = 2, pulse = false },
	pulsing = { speed = 3, spread = 30, rotSpeed = 40, accelerationUp = 0, pulse = true },
	spiraling = { speed = 5, spread = 15, rotSpeed = 360, accelerationUp = 3, pulse = false },
	flickering = { speed = 2, spread = 35, rotSpeed = 90, accelerationUp = 1, pulse = true },
} :: { [string]: { speed: number, spread: number, rotSpeed: number, accelerationUp: number, pulse: boolean } }

-- Form -> particle counts (at full LOD, power 5), lifetime and footprint.
Recipes.forms = {
	touch = { burst = 18, lifetime = 0.5, footprint = 1.5 },
	projectile = { burst = 10, lifetime = 0.4, footprint = 1, speed = 140, size = 0.7 },
	beam = { burst = 14, lifetime = 0.35, footprint = 1, duration = 0.4, width = 0.6 },
	chain = { burst = 10, lifetime = 0.3, footprint = 1, duration = 0.3, width = 0.4 },
	burst = { burst = 60, lifetime = 0.8, footprint = 1 },
	aura = { burst = 40, lifetime = 1.2, footprint = 1 },
	zone = { burst = 80, lifetime = 1.6, footprint = 1 },
	wall = { burst = 50, lifetime = 1.2, footprint = 1 },
	pillar = { burst = 45, lifetime = 1.2, footprint = 1 },
	summon = { burst = 50, lifetime = 1.5, footprint = 1 },
	ritual = { burst = 140, lifetime = 2.5, footprint = 1 },
} :: { [string]: { burst: number, lifetime: number, footprint: number, speed: number?, size: number?, duration: number?, width: number? } }

-- Reaction / world cue colours (InteractionMatrix results and backlash).
Recipes.reactions = {
	steam = { color = Color3.fromRGB(235, 240, 245), texture = SMOKE, count = 60, lifetime = 2.5 },
	smoke = { color = Color3.fromRGB(90, 110, 60), texture = SMOKE, count = 50, lifetime = 3 },
	conduction = { color = Color3.fromRGB(150, 200, 255), texture = SPARKLES, count = 70, lifetime = 0.4 },
	firestorm = { color = Color3.fromRGB(255, 120, 30), texture = FIRE, count = 90, lifetime = 1.2 },
	blizzard = { color = Color3.fromRGB(220, 240, 255), texture = SPARKLES, count = 90, lifetime = 2 },
	crush = { color = Color3.fromRGB(120, 100, 80), texture = SMOKE, count = 50, lifetime = 1.5 },
	shear = { color = Color3.fromRGB(255, 80, 200), texture = SPARKLES, count = 60, lifetime = 0.8 },
	backlash = { color = Color3.fromRGB(255, 60, 30), texture = SPARKLES, count = 50, lifetime = 0.7 },
	tremor = { color = Color3.fromRGB(140, 120, 95), texture = SMOKE, count = 40, lifetime = 1.4 },
} :: { [string]: { color: Color3, texture: string, count: number, lifetime: number } }

-- Field zones: ring colour and transparency.
Recipes.fields = {
	time = { color = Color3.fromRGB(230, 200, 120), transparency = 0.85 },
	gravity = { color = Color3.fromRGB(140, 110, 190), transparency = 0.82 },
	current = { color = Color3.fromRGB(70, 150, 235), transparency = 0.88 },
	reality = { color = Color3.fromRGB(255, 80, 200), transparency = 0.85 },
} :: { [string]: { color: Color3, transparency: number } }

return Recipes
