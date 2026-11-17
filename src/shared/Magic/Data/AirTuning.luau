--!strict
--[[
	AirTuning: the numbers behind Air's spells (docs/DomainIdeas.md, "Air"). Ordinary spells that fit
	their branches, not ultimates: each is a narrow route in Data/EffectLibrary ("air_" .. move), resolved
	by Server/Magic/Cast/Effects/AirArt; anything that lasts runs in Server/Magic/Cast/ArtRuntime and is
	drawn by Client/Fx/ArtFx with AirFx's builders.

	A `{ base, perPower, max }` grows with the recipe's power: AirTuning.at(c, power) =
	min(max, base + perPower x power). `share` is a fraction of a normal hit (Cast/DamageModel.base).
]]

local AirTuning = {}

export type Curve = { base: number, perPower: number, max: number }

function AirTuning.at(curve: Curve, power: number): number
	return math.min(curve.max, curve.base + curve.perPower * math.max(0, power))
end

-- ─── Windshaping, Tempest, Vacuity ──────────────────────────────────────────

AirTuning.wind_blade = {
	speed = 1.4, -- of a normal bolt's speed: wind is quick
	share = 1,
	knock = 22,
	pierce = 2, -- it cuts on through this many more people along its line
	reach = 30,
}

AirTuning.gale = {
	reach = { base = 16, perPower = 1.5, max = 30 } :: Curve,
	arc = 80,
	share = 0.25,
	push = { base = 55, perPower = 4, max = 90 } :: Curve,
}

AirTuning.twister = {
	seconds = { base = 6, perPower = 0.6, max = 12 } :: Curve,
	speed = 8,
	seek = 30,
	radius = 5,
	every = 0.4,
	share = 0.12,
	lift = 28,
}

AirTuning.updraft = {
	radius = 4,
	seconds = { base = 6, perPower = 0.6, max = 12 } :: Curve,
	every = 0.3,
	lift = 32,
}

AirTuning.airless = {
	share = 0.3,
	seconds = { base = 1.5, perPower = 0.12, max = 3 } :: Curve,
	pvpSeconds = 1.5,
	chokeSeconds = 4,
	chokeShare = 0.12, -- per second
}

AirTuning.pressure_bomb = {
	radius = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	pullTime = 0.5,
	pull = 30,
	share = 0.8,
	push = 60,
}

AirTuning.tailwind = {
	radius = 14,
	seconds = { base = 8, perPower = 1, max = 20 } :: Curve,
}

AirTuning.windwall = {
	width = { base = 12, perPower = 0.8, max = 22 } :: Curve,
	height = 10,
	seconds = { base = 6, perPower = 0.8, max = 14 } :: Curve,
	thickness = 2,
	turn = 65, -- degrees a bolt is turned aside
	push = 40, -- anyone walking into it is shoved back
	every = 0.3,
}

-- ─── Sonics, Echolocation, Thunderclap ──────────────────────────────────────

AirTuning.sonic_ring = {
	length = { base = 22, perPower = 2.5, max = 45 } :: Curve,
	width = 3,
	share = 0.6,
	dazeSeconds = 1.5,
	maxTargets = 8,
}

AirTuning.shatter = {
	radius = { base = 6, perPower = 0.5, max = 12 } :: Curve,
	share = 0.5,
	breakMax = 12, -- conjured stone, ice and crystal it can break at once
}

AirTuning.echo_pulse = {
	radius = { base = 40, perPower = 6, max = 100 } :: Curve,
	seconds = { base = 4, perPower = 0.4, max = 8 } :: Curve,
	maxShown = 30,
}

AirTuning.thunder_boom = {
	radius = { base = 10, perPower = 1, max = 20 } :: Curve,
	share = 0.35,
	dazeSeconds = 2,
	push = 34,
}

-- ─── Weathercraft, Rainmaking, Stormbrewing ─────────────────────────────────

AirTuning.raincloud = {
	seconds = { base = 10, perPower = 1, max = 24 } :: Curve,
	every = 1,
}

AirTuning.call_lightning = {
	warn = 0.5,
	radius = 3.5,
	share = 1.2,
	soakedMult = 1.5, -- under a raincloud: harder, and it finds them wherever they step
	dazeSeconds = 1.5,
}

AirTuning.hail = {
	stones = { base = 8, perPower = 1.4, max = 20 } :: Curve,
	radius = { base = 9, perPower = 0.8, max = 18 } :: Curve,
	warn = 0.8,
	hitRadius = 2.4,
	share = 0.35,
}

-- ─── Looks (client) ─────────────────────────────────────────────────────────

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

AirTuning.looks = {
	wind = rgb(220, 240, 245),
	windEdge = rgb(160, 210, 225),
	leaf = rgb(120, 170, 90),
	dust = rgb(180, 170, 150),
	sound = rgb(200, 190, 255),
	echo = rgb(150, 220, 255),
	cloud = rgb(110, 118, 130),
	rain = rgb(160, 190, 230),
	bolt = rgb(220, 235, 255),
	hail = rgb(230, 240, 250),
}

return AirTuning
