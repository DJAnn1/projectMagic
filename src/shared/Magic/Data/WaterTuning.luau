--!strict
--[[
	WaterTuning: the numbers behind Water's spells (docs/DomainIdeas.md, "Water"). Ordinary spells that
	fit their branches, not ultimates: each is a narrow route in Data/EffectLibrary ("water_" .. move),
	resolved by Server/Magic/Cast/Effects/WaterArt; anything that lasts runs in Server/Magic/Cast/ArtRuntime
	and is drawn by Client/Fx/ArtFx with WaterFx's builders.

	A `{ base, perPower, max }` grows with the recipe's power: WaterTuning.at(c, power) =
	min(max, base + perPower x power). `share` is a fraction of a normal hit (Cast/DamageModel.base).
]]

local WaterTuning = {}

export type Curve = { base: number, perPower: number, max: number }

function WaterTuning.at(curve: Curve, power: number): number
	return math.min(curve.max, curve.base + curve.perPower * math.max(0, power))
end

-- ─── Hydromancy, Hydrostatics ───────────────────────────────────────────────

WaterTuning.water_whip = {
	reach = { base = 11, perPower = 1.2, max = 22 } :: Curve,
	arc = 100,
	share = 0.85,
	pull = 24, -- studs a second, a step toward you
	maxTargets = 5,
}

WaterTuning.pressure_jet = {
	length = { base = 18, perPower = 2, max = 36 } :: Curve,
	width = 2,
	share = 0.9,
	push = 46,
	maxTargets = 4,
}

WaterTuning.bubble = {
	share = 0.15,
	seconds = { base = 1.5, perPower = 0.15, max = 3 } :: Curve,
	pvpSeconds = 1.5,
	lift = 6, -- studs it floats them up (NPCs and creatures; players get a hop)
}

WaterTuning.geyser = {
	radius = { base = 4, perPower = 0.3, max = 7 } :: Curve,
	warn = 0.6,
	share = 0.6,
	lift = { base = 55, perPower = 4, max = 85 } :: Curve,
}

WaterTuning.mire = {
	radius = { base = 7, perPower = 0.7, max = 15 } :: Curve,
	seconds = { base = 6, perPower = 0.6, max = 12 } :: Curve,
	every = 0.5,
}

-- ─── Tidal ──────────────────────────────────────────────────────────────────

WaterTuning.wave_surge = {
	width = { base = 10, perPower = 0.8, max = 18 } :: Curve,
	distance = { base = 24, perPower = 2.5, max = 45 } :: Curve,
	speed = 22, -- studs a second the wave rolls
	share = 0.5,
	carry = 30, -- studs a second, along with it
}

WaterTuning.whirlpool = {
	radius = { base = 8, perPower = 0.7, max = 16 } :: Curve,
	seconds = { base = 5, perPower = 0.5, max = 10 } :: Curve,
	every = 0.4,
	pull = 14,
	swirl = 12,
	share = 0.1,
}

WaterTuning.riptide = {
	share = 0.5,
	stopShort = 4, -- studs in front of you they land
	dragSeconds = 0.45,
}

-- ─── Glaciation, Permafrost ─────────────────────────────────────────────────

WaterTuning.ice_slide = {
	length = { base = 24, perPower = 2.5, max = 48 } :: Curve,
	width = 4,
	seconds = { base = 8, perPower = 1, max = 18 } :: Curve,
	every = 0.3,
	hasteSeconds = 0.6, -- refreshed while an ally stands on it
	slipChance = 0.3,
	slipGap = 3,
}

WaterTuning.permafrost = {
	radius = { base = 7, perPower = 0.7, max = 15 } :: Curve,
	seconds = { base = 6, perPower = 0.5, max = 12 } :: Curve,
	every = 1.5,
	rootSeconds = 0.9,
}

WaterTuning.icicle_rain = {
	icicles = { base = 6, perPower = 1.2, max = 16 } :: Curve,
	radius = { base = 8, perPower = 0.8, max = 18 } :: Curve,
	warn = 0.9,
	hitRadius = 2.6,
	share = 0.45,
}

WaterTuning.ice_dome = {
	radius = { base = 7, perPower = 0.4, max = 11 } :: Curve,
	seconds = { base = 6, perPower = 0.8, max = 14 } :: Curve,
	panels = 10,
	height = 8,
}

-- ─── Vapor, Fogweaving ──────────────────────────────────────────────────────

WaterTuning.scald = {
	radius = { base = 7, perPower = 0.6, max = 14 } :: Curve,
	share = 0.7,
	blindSeconds = 1.4,
}

WaterTuning.fog_bank = {
	radius = { base = 10, perPower = 1, max = 22 } :: Curve,
	seconds = { base = 10, perPower = 1, max = 22 } :: Curve,
	every = 0.5,
	veilSeconds = 1, -- refreshed on allies inside: hidden from anyone outside
}

WaterTuning.cloud_step = {
	seconds = { base = 4, perPower = 0.5, max = 9 } :: Curve,
	size = 6,
}

-- ─── Purification, Wellspring ───────────────────────────────────────────────

WaterTuning.cleansing_rain = {
	radius = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	seconds = { base = 6, perPower = 0.6, max = 12 } :: Curve,
	every = 1,
	heal = 0.12, -- of a normal hit, each second, on allies inside
}

WaterTuning.water_shield = {
	seconds = { base = 10, perPower = 1, max = 22 } :: Curve,
	every = 0.5,
}

WaterTuning.fountain = {
	radius = 10,
	seconds = { base = 20, perPower = 3, max = 60 } :: Curve,
	every = 1,
}

-- ─── Looks (client) ─────────────────────────────────────────────────────────

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

WaterTuning.looks = {
	water = rgb(60, 150, 230),
	waterLight = rgb(150, 210, 255),
	foam = rgb(235, 248, 255),
	deep = rgb(20, 70, 140),
	mud = rgb(80, 66, 46),
	ice = rgb(175, 225, 255),
	steam = rgb(235, 240, 245),
	fog = rgb(200, 208, 215),
	cloud = rgb(245, 248, 252),
	pure = rgb(170, 240, 255),
}

return WaterTuning
