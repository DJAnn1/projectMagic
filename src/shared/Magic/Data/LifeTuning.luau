--!strict
--[[
	LifeTuning: the numbers behind Life's spells (docs/DomainIdeas.md, "Life"). Ordinary spells that fit
	their branches, not ultimates: each is a narrow route in Data/EffectLibrary ("life_" .. move), resolved
	by Server/Magic/Cast/Effects/LifeArt; anything that lasts runs in Server/Magic/Cast/ArtRuntime and is
	drawn by Client/Fx/ArtFx with LifeFx's builders.

	A `{ base, perPower, max }` grows with the recipe's power: LifeTuning.at(c, power) =
	min(max, base + perPower x power). `share` is a fraction of a normal hit (Cast/DamageModel.base); heals
	use the same base.
]]

local LifeTuning = {}

export type Curve = { base: number, perPower: number, max: number }

function LifeTuning.at(curve: Curve, power: number): number
	return math.min(curve.max, curve.base + curve.perPower * math.max(0, power))
end

-- ─── Restoration, Mending, Resurgence ───────────────────────────────────────

LifeTuning.healing_grove = {
	radius = { base = 7, perPower = 0.6, max = 14 } :: Curve,
	seconds = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	every = 1,
	heal = 0.2, -- of a normal hit, each second, on allies standing in it
}

LifeTuning.lifeline = {
	give = 0.6, -- of a normal hit, from your own health
	mult = 1.7, -- what reaches them
	floor = 0.25, -- you never give below this share of your max health
}

LifeTuning.petal_ward = {
	radius = 10,
	seconds = { base = 10, perPower = 1, max = 22 } :: Curve,
	shield = 1.5, -- of a normal hit, on each of you
}

LifeTuning.second_wind = {
	radius = 12,
	heal = 0.35,
	hasteSeconds = 4,
}

LifeTuning.raise_them = {
	health = 0.35, -- of max health they come round with (DownedService)
}

-- ─── Flora, Arborism, Mycology ──────────────────────────────────────────────

LifeTuning.vine_lash = {
	share = 0.6,
	stopShort = 4, -- studs in front of you they land
	dragSeconds = 0.4,
}

LifeTuning.root_snare = {
	share = 0.25,
	seconds = { base = 1.6, perPower = 0.15, max = 3.2 } :: Curve,
	pvpSeconds = 2,
	thornShare = 0.08, -- per second while held
}

LifeTuning.thorn_burst = {
	radius = { base = 7, perPower = 0.7, max = 15 } :: Curve,
	share = 0.6,
	bleedSeconds = 4,
	bleedShare = 0.08,
}

LifeTuning.bramble_wall = {
	length = { base = 12, perPower = 1, max = 24 } :: Curve,
	seconds = { base = 10, perPower = 1, max = 22 } :: Curve,
	reach = 2,
	share = 0.15,
	gap = 0.8,
	slowSeconds = 1.5,
}

LifeTuning.sapling = {
	seconds = { base = 30, perPower = 4, max = 70 } :: Curve,
	height = { base = 9, perPower = 0.8, max = 16 } :: Curve,
}

LifeTuning.spore_cloud = {
	radius = { base = 7, perPower = 0.7, max = 15 } :: Curve,
	seconds = { base = 6, perPower = 0.5, max = 12 } :: Curve,
	every = 0.6,
	dazeSeconds = 1.2,
}

LifeTuning.fairy_ring = {
	radius = 5,
	seconds = { base = 15, perPower = 2, max = 35 } :: Curve,
	every = 0.15,
	bounce = { base = 70, perPower = 4, max = 100 } :: Curve,
	gap = 1, -- each person bounces at most once a second
}

-- ─── Fauna, Wildshape ───────────────────────────────────────────────────────

LifeTuning.swarm = {
	share = 0.4,
	seconds = { base = 5, perPower = 0.4, max = 9 } :: Curve,
	every = 0.5,
	stingShare = 0.1,
}

LifeTuning.flock = {
	radius = { base = 10, perPower = 1, max = 20 } :: Curve,
	blindSeconds = 2,
}

LifeTuning.beast_claws = {
	seconds = { base = 10, perPower = 1, max = 24 } :: Curve,
	share = 0.25, -- added to each blow you land
	gap = 0.3,
}

-- ─── Blight, Pestilence, Withering ──────────────────────────────────────────

LifeTuning.rot = {
	share = 0.4,
	seconds = 8,
	structure = 3, -- damage to wood and buildings at the spot, per power
	radius = 6,
}

LifeTuning.withering_field = {
	radius = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	seconds = { base = 6, perPower = 0.6, max = 12 } :: Curve,
	every = 1,
	witherSeconds = 2,
}

LifeTuning.plague_flies = {
	share = 0.3,
	poisonSeconds = 5,
	poisonShare = 0.1,
	jumps = 3, -- the flies move on to someone near, at most this many times
	jumpEvery = 2,
	jumpReach = 12,
}

LifeTuning.corpse_bloom = {
	seconds = { base = 20, perPower = 2, max = 40 } :: Curve,
	trigger = 5,
	radius = 7,
	share = 0.6,
	poisonSeconds = 5,
	poisonShare = 0.12,
	every = 0.3,
}

-- ─── Looks (client) ─────────────────────────────────────────────────────────

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

LifeTuning.looks = {
	leaf = rgb(90, 170, 70),
	leafLight = rgb(160, 220, 110),
	bloom = rgb(255, 170, 200),
	petal = rgb(255, 210, 225),
	heal = rgb(150, 255, 160),
	wood = rgb(110, 76, 48),
	thorn = rgb(70, 90, 40),
	spore = rgb(220, 200, 120),
	mushroom = rgb(200, 60, 60),
	insect = rgb(40, 34, 20),
	bird = rgb(70, 60, 55),
	rot = rgb(70, 60, 40),
	plague = rgb(140, 170, 60),
	wither = rgb(130, 110, 80),
}

return LifeTuning
