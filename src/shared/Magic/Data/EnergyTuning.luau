--!strict
--[[
	EnergyTuning: the numbers behind Energy's spells (docs/DomainIdeas.md, "Energy"). Ordinary spells
	that fit their branches, not ultimates: each is a narrow route in Data/EffectLibrary (route id =
	"energy_" .. move), resolved by Server/Magic/Cast/Effects/EnergyArt; anything that lasts is kept by
	Server/Magic/Cast/ArtRuntime and drawn by Client/Fx/ArtFx with EnergyFx's builders.

	A `{ base, perPower, max }` grows with the recipe's power: EnergyTuning.at(c, power) =
	min(max, base + perPower x power). `share` is a fraction of a normal hit (Cast/DamageModel.base):
	1 = what a plain bolt of that power deals.

	Looks (colours) are here so client and server agree; every move's body is tagged ArtBody with
	attribute ArtLook = the move id.
]]

local EnergyTuning = {}

export type Curve = { base: number, perPower: number, max: number }

function EnergyTuning.at(curve: Curve, power: number): number
	return math.min(curve.max, curve.base + curve.perPower * math.max(0, power))
end

-- How far an Arc Tether stretches before it snaps. (Caps on lasting things: Server/Magic/Cast/ArtRuntime.caps.)
EnergyTuning.caps = {
	tetherReach = 26,
}

-- ─── Fire (Pyromancy, Conflagration) ────────────────────────────────────────

EnergyTuning.ember_swarm = {
	share = 0.55, -- the burst itself, on everyone in it
	embers = { base = 8, perPower = 2, max = 26 } :: Curve,
	spread = 1.6, -- embers land up to this many times the burst's radius out
	emberShare = 0.25, -- someone an ember lands next to
	emberRadius = 3,
	burnSeconds = 3,
	burnShare = 0.12, -- per second, of a normal hit
}

EnergyTuning.fire_whip = {
	reach = { base = 10, perPower = 1.2, max = 22 } :: Curve,
	arc = 110, -- degrees swept in front of you
	share = 0.9,
	maxTargets = 5,
	burnSeconds = 3,
	burnShare = 0.12,
}

EnergyTuning.flame_serpent = {
	speed = 0.8, -- of a normal bolt's speed: it winds
	share = 1.2,
	coils = 3, -- squeezes after it lands
	coilEvery = 0.4,
	coilShare = 0.25,
	burnSeconds = 4,
	burnShare = 0.15,
	sourceRadius = 30, -- fires this close to the caster feed it, and go out
}

EnergyTuning.ring_of_fire = {
	radius = { base = 7, perPower = 0.5, max = 14 } :: Curve,
	seconds = { base = 6, perPower = 0.6, max = 14 } :: Curve,
	band = 1.8, -- studs either side of the ring that burn
	every = 0.4,
	share = 0.22,
	burnSeconds = 2,
	burnShare = 0.1,
}

EnergyTuning.smother = {
	radius = { base = 6, perPower = 0.8, max = 16 } :: Curve,
	seconds = { base = 5, perPower = 0.4, max = 9 } :: Curve,
	every = 0.5,
	blindSeconds = 1.5, -- refreshed while a foe stays in the smoke
}

EnergyTuning.kindle = {
	seconds = { base = 10, perPower = 2, max = 30 } :: Curve,
	burnSeconds = 3,
	burnShare = 0.12,
	gap = 0.4, -- the same person can't be lit again for this long
}

-- ─── Frost (Cryothermy, Stillfrost) ─────────────────────────────────────────

EnergyTuning.ice_spike_line = {
	length = { base = 18, perPower = 3, max = 45 } :: Curve,
	step = 3, -- studs between spikes
	stepDelay = 0.07, -- seconds between spikes
	radius = 3,
	share = 0.45,
	lift = 30,
}

EnergyTuning.frost_lance = {
	share = 1.15,
	pinSeconds = 1,
	shardRadius = 6,
	shardShare = 0.35,
}

EnergyTuning.hoarfrost = {
	radius = { base = 8, perPower = 0.8, max = 18 } :: Curve,
	seconds = { base = 8, perPower = 0.5, max = 15 } :: Curve,
	every = 1,
	slipSpeed = 13, -- studs a second: anyone running across this fast may fall
	slipChance = 0.35,
	slipGap = 4,
	slipSeconds = 1.2,
}

EnergyTuning.ice_mirror = {
	width = { base = 8, perPower = 0.6, max = 14 } :: Curve,
	height = 9,
	seconds = { base = 8, perPower = 1, max = 18 } :: Curve,
	thickness = 1.5, -- a bolt this close to the pane's face is turned
}

EnergyTuning.flurry = {
	radius = { base = 8, perPower = 0.4, max = 14 } :: Curve,
	seconds = { base = 6, perPower = 0.5, max = 12 } :: Curve,
	every = 0.8,
	share = 0.12,
}

-- ─── Heat (Calefaction) ─────────────────────────────────────────────────────

EnergyTuning.heat_haze = {
	seconds = { base = 8, perPower = 1, max = 20 } :: Curve,
	radius = 10,
	degrees = { base = 12, perPower = 1, max = 22 } :: Curve, -- how far a bolt is pushed off line
}

EnergyTuning.boil = {
	waterRadius = 8, -- water this close to where you touch boils
	radius = { base = 8, perPower = 0.5, max = 14 } :: Curve,
	share = 0.8,
	blindSeconds = 1.5,
}

EnergyTuning.searing_ground = {
	radius = { base = 6, perPower = 0.8, max = 18 } :: Curve,
	seconds = { base = 6, perPower = 0.6, max = 14 } :: Curve,
	every = 0.6,
	share = 0.18,
	heat = 25, -- per tick, into burnable parts inside (ThermalSim)
}

-- ─── Light (Photomancy, Irradiance) ─────────────────────────────────────────

EnergyTuning.prism_bolt = {
	share = 1,
	rays = { base = 3, perPower = 0.34, max = 5 } :: Curve,
	fan = 50, -- degrees, the rays spread past the target
	length = { base = 24, perPower = 2, max = 40 } :: Curve,
	rayShare = 0.45,
}

EnergyTuning.sunspot = {
	radius = { base = 6, perPower = 0.7, max = 16 } :: Curve,
	seconds = { base = 6, perPower = 0.5, max = 12 } :: Curve,
	every = 0.5,
	share = 0.1,
	blindSeconds = 1,
}

EnergyTuning.wisps = {
	count = 3,
	seconds = { base = 60, perPower = 10, max = 180 } :: Curve,
	reveal = 12, -- veiled people this close to a wisp are shown
	every = 1,
}

EnergyTuning.flash = {
	radius = { base = 10, perPower = 1.2, max = 24 } :: Curve,
	blindSeconds = { base = 2, perPower = 0.2, max = 4 } :: Curve,
	facing = 0.2, -- dot product: roughly looking your way
}

EnergyTuning.glowing_poison = {
	share = 0.5,
	seconds = { base = 8, perPower = 0.8, max = 14 } :: Curve,
	dotShare = 0.1, -- per second
}

-- ─── Shadow (Umbramancy) ────────────────────────────────────────────────────

EnergyTuning.shadow_grasp = {
	share = 0.35,
	seconds = { base = 1.5, perPower = 0.15, max = 3 } :: Curve,
	pvpSeconds = 2,
}

EnergyTuning.shade_cloak = {
	seconds = { base = 8, perPower = 1, max = 20 } :: Curve,
	nightMult = 1.5,
}

EnergyTuning.shadow_puppet = {
	seconds = { base = 12, perPower = 1, max = 25 } :: Curve,
	delay = 0.35, -- it copies your blow this long after
	share = 0.3,
	gap = 0.5,
}

-- ─── Kinetic (Impetus, Deflection, Inertia) ─────────────────────────────────

EnergyTuning.stomp = {
	radius = { base = 8, perPower = 0.9, max = 20 } :: Curve,
	share = 0.5,
	downSeconds = 1.2,
	lift = 18,
}

EnergyTuning.ricochet = {
	bounces = { base = 2, perPower = 0.25, max = 4 } :: Curve,
	reach = 22,
	falloff = 0.7, -- each bounce
}

EnergyTuning.repulse = {
	seconds = { base = 6, perPower = 0.6, max = 14 } :: Curve,
	radius = 9,
}

EnergyTuning.inertia_lock = {
	seconds = { base = 1.2, perPower = 0.1, max = 2.4 } :: Curve,
	speed = 40,
}

EnergyTuning.launch = {
	forward = { base = 60, perPower = 4, max = 100 } :: Curve,
	up = { base = 35, perPower = 2, max = 55 } :: Curve,
}

-- ─── Lightning (Electromancy, Galvanism, Arcweaving) ────────────────────────

EnergyTuning.ball_lightning = {
	speed = 0.3, -- of a normal bolt's speed
	seconds = { base = 4, perPower = 0.3, max = 7 } :: Curve,
	drift = 6, -- studs a second toward whoever's nearest
	seek = 20,
	zapRadius = 9,
	zapEvery = 0.5,
	zapShare = 0.3,
	popRadius = 6,
	popShare = 0.5,
}

EnergyTuning.static_field = {
	radius = { base = 8, perPower = 0.8, max = 18 } :: Curve,
	seconds = { base = 6, perPower = 0.5, max = 12 } :: Curve,
	every = 0.6,
	arcReach = 14,
	maxArcs = 6,
	share = 0.12,
	aloneShare = 0.06,
}

EnergyTuning.arc_tether = {
	seconds = { base = 5, perPower = 0.3, max = 8 } :: Curve,
	every = 0.5,
	share = 0.2,
	snapShare = 0.6,
	findReach = 20, -- one target only: the tether reaches for whoever else is nearest
}

EnergyTuning.galvanise = {
	seconds = { base = 6, perPower = 1, max = 16 } :: Curve,
}

EnergyTuning.arc_fence = {
	length = { base = 12, perPower = 1, max = 24 } :: Curve,
	seconds = { base = 8, perPower = 1, max = 18 } :: Curve,
	reach = 1.6, -- studs from the line that count as crossing it
	share = 0.3,
	dazeSeconds = 1.5,
	gap = 0.8,
}

-- ─── Looks (client) ─────────────────────────────────────────────────────────

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

EnergyTuning.looks = {
	fire = rgb(255, 120, 30),
	fireHot = rgb(255, 225, 140),
	ember = rgb(255, 150, 60),
	smoke = rgb(40, 36, 34),
	ice = rgb(170, 225, 255),
	iceDeep = rgb(80, 160, 230),
	frost = rgb(225, 245, 255),
	heat = rgb(255, 170, 90),
	steam = rgb(235, 240, 245),
	light = rgb(255, 245, 200),
	sun = rgb(255, 225, 120),
	radiation = rgb(140, 255, 90),
	shadow = rgb(18, 12, 26),
	shadowEdge = rgb(90, 60, 140),
	force = rgb(200, 220, 255),
	charge = rgb(140, 200, 255),
	chargeHot = rgb(235, 245, 255),
	prism = { rgb(255, 80, 80), rgb(255, 200, 60), rgb(90, 255, 120), rgb(80, 160, 255), rgb(200, 100, 255) },
}

return EnergyTuning
