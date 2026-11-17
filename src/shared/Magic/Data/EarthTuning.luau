--!strict
--[[
	EarthTuning: the numbers behind Earth's spells (docs/DomainIdeas.md, "Earth"). Ordinary spells that
	fit their branches, not ultimates: each is a narrow route in Data/EffectLibrary ("earth_" .. move),
	resolved by Server/Magic/Cast/Effects/EarthArt; anything that lasts runs in Server/Magic/Cast/ArtRuntime
	and is drawn by Client/Fx/ArtFx with EarthFx's builders.

	A `{ base, perPower, max }` grows with the recipe's power: EarthTuning.at(c, power) =
	min(max, base + perPower x power). `share` is a fraction of a normal hit (Cast/DamageModel.base).
	Stone that stands (spike walls, ramps, steps, spires, prisons) is a real anchored part people can
	stand on and that blocks; it crumbles when its time is up. None of it is saved.
]]

local EarthTuning = {}

export type Curve = { base: number, perPower: number, max: number }

function EarthTuning.at(curve: Curve, power: number): number
	return math.min(curve.max, curve.base + curve.perPower * math.max(0, power))
end

-- ─── Stone (Lithomancy, Architectonics) ─────────────────────────────────────

EarthTuning.stone_fist = {
	speed = 0.75, -- of a normal bolt's speed: it's heavy
	gravity = 1.6, -- it drops
	share = 1.25,
	knock = 42, -- studs a second, back from where it came
	splash = 4,
	splashShare = 0.35,
}

EarthTuning.gravel_burst = {
	radius = { base = 6, perPower = 0.8, max = 16 } :: Curve,
	share = 0.75,
	lift = 22,
}

EarthTuning.spike_trail = {
	length = { base = 18, perPower = 3, max = 45 } :: Curve,
	step = 3,
	stepDelay = 0.06,
	radius = 3,
	share = 0.5,
	lift = 34,
	stays = 5, -- seconds the spikes stand (they block) before they crumble
}

EarthTuning.stone_step = {
	height = { base = 8, perPower = 1.5, max = 22 } :: Curve,
	seconds = { base = 10, perPower = 1, max = 20 } :: Curve,
	width = 4,
}

EarthTuning.stone_grip = {
	share = 0.3,
	seconds = { base = 1.6, perPower = 0.15, max = 3.2 } :: Curve,
	pvpSeconds = 2,
}

EarthTuning.ramp = {
	length = { base = 14, perPower = 1.5, max = 30 } :: Curve,
	rise = { base = 6, perPower = 0.8, max = 16 } :: Curve,
	width = 6,
	seconds = { base = 20, perPower = 3, max = 50 } :: Curve,
}

EarthTuning.boulder = {
	speed = 0.85,
	roll = { base = 26, perPower = 3, max = 50 } :: Curve, -- studs it rolls on after landing
	rollSpeed = 30, -- studs a second
	radius = 3.2,
	share = 0.8,
	downSeconds = 1.2,
}

-- ─── Metal (Metallurgy, Ferromancy, Alloycraft) ─────────────────────────────

EarthTuning.iron_storm = {
	radius = { base = 7, perPower = 0.8, max = 16 } :: Curve,
	seconds = { base = 5, perPower = 0.5, max = 10 } :: Curve,
	every = 0.6,
	share = 0.14,
	metalMult = 2, -- anyone wearing metal is cut worse (and dragged toward the middle)
	drag = 10,
}

EarthTuning.blade_rain = {
	blades = { base = 6, perPower = 1.2, max = 16 } :: Curve,
	radius = { base = 8, perPower = 0.8, max = 18 } :: Curve,
	warn = 0.9,
	hitRadius = 2.6,
	share = 0.45,
}

EarthTuning.quicksilver_lash = {
	reach = { base = 12, perPower = 1.2, max = 24 } :: Curve,
	arc = 90,
	share = 0.85,
	pull = 30, -- studs a second toward you
	maxTargets = 4,
}

-- ─── Crystal (Crystallurgy, Focuscraft) ─────────────────────────────────────

EarthTuning.crystal_spires = {
	count = { base = 5, perPower = 0.6, max = 10 } :: Curve,
	radius = { base = 5, perPower = 0.5, max = 11 } :: Curve,
	share = 0.4, -- as they burst up
	shatterAfter = 4, -- seconds standing; hit one (or wait) and it shatters
	shatterRadius = 6,
	shatterShare = 0.45,
}

EarthTuning.singing_shard = {
	share = 0.7,
	pulses = 3,
	every = 0.7,
	pulseShare = 0.3,
}

EarthTuning.crystal_prison = {
	share = 0.2,
	seconds = { base = 1.4, perPower = 0.12, max = 2.6 } :: Curve,
	pvpSeconds = 1.5,
}

EarthTuning.geode_shell = {
	seconds = { base = 10, perPower = 1.2, max = 24 } :: Curve,
	plates = 6, -- drawn plates; they chip off as the ward is used
}

-- ─── Seismic (Faultwork) ────────────────────────────────────────────────────

EarthTuning.fissure = {
	length = { base = 20, perPower = 3, max = 48 } :: Curve,
	width = 3,
	speed = 60, -- studs a second the crack runs
	share = 0.6,
	downSeconds = 1.4,
}

EarthTuning.ground_ripple = {
	radius = { base = 12, perPower = 1.5, max = 30 } :: Curve,
	speed = 28, -- studs a second the ring spreads
	band = 3,
	share = 0.35,
	lift = 30,
}

-- ─── Sand (Sandshaping, Dunecalling) ────────────────────────────────────────

EarthTuning.sand_blast = {
	reach = { base = 14, perPower = 1.5, max = 28 } :: Curve,
	arc = 70,
	share = 0.35,
	blindSeconds = 1.6,
	push = 34,
}

EarthTuning.dust_cloud = {
	radius = { base = 7, perPower = 0.8, max = 16 } :: Curve,
	seconds = { base = 6, perPower = 0.5, max = 12 } :: Curve,
	every = 0.5,
	blindSeconds = 1,
}

EarthTuning.quicksand = {
	radius = { base = 6, perPower = 0.7, max = 15 } :: Curve,
	seconds = { base = 7, perPower = 0.6, max = 14 } :: Curve,
	every = 0.5,
	share = 0.06,
	rootAfter = 3, -- seconds stood in it before you're stuck fast for a moment
	rootSeconds = 1.2,
}

EarthTuning.dust_devil = {
	seconds = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	speed = 9,
	seek = 30,
	radius = 4,
	every = 0.5,
	share = 0.1,
	blindSeconds = 1,
}

EarthTuning.sand_shroud = {
	seconds = { base = 8, perPower = 0.8, max = 18 } :: Curve,
	radius = 6,
	every = 0.8,
	share = 0.08,
}

-- ─── Looks (client) ─────────────────────────────────────────────────────────

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

EarthTuning.looks = {
	stone = rgb(120, 112, 104),
	stoneDark = rgb(78, 72, 66),
	dirt = rgb(110, 86, 62),
	dust = rgb(170, 150, 120),
	sand = rgb(214, 190, 140),
	iron = rgb(120, 124, 132),
	silver = rgb(220, 226, 236),
	crystal = rgb(150, 220, 255),
	crystalCore = rgb(235, 250, 255),
	crack = rgb(255, 150, 70),
}

return EarthTuning
