--!strict
--[[
	VoidTuning: the numbers behind Void's spells (docs/DomainIdeas.md, "Void"). Void takes away: magic,
	light, sound, presence. Ordinary spells that fit their branches, not ultimates: each is a narrow route
	in Data/EffectLibrary ("void_" .. move), resolved by Server/Magic/Cast/Effects/VoidArt; anything that
	lasts runs in Server/Magic/Cast/ArtRuntime and is drawn by Client/Fx/ArtFx with VoidFx's builders.

	A `{ base, perPower, max }` grows with the recipe's power: VoidTuning.at(c, power) =
	min(max, base + perPower x power). `share` is a fraction of a normal hit (Cast/DamageModel.base).
]]

local VoidTuning = {}

export type Curve = { base: number, perPower: number, max: number }

function VoidTuning.at(curve: Curve, power: number): number
	return math.min(curve.max, curve.base + curve.perPower * math.max(0, power))
end

-- ─── Negation, Dispelling, Antimagic ────────────────────────────────────────

VoidTuning.null_bolt = {
	share = 0.6,
	strips = { base = 1, perPower = 0.2, max = 3 } :: Curve, -- good statuses torn off
}

VoidTuning.unravel = {
	length = { base = 24, perPower = 2, max = 45 } :: Curve,
	width = 3,
	maxBodies = 8, -- other people's lasting spells it can end at once
	maxSolids = 10,
}

VoidTuning.antimagic_shell = {
	seconds = { base = 6, perPower = 0.8, max = 14 } :: Curve,
	resist = { base = 0.3, perPower = 0.03, max = 0.55 } :: Curve, -- of all magic
	every = 0.5,
}

VoidTuning.null_ground = {
	radius = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	seconds = { base = 5, perPower = 0.5, max = 10 } :: Curve,
	every = 0.5,
	silenceSeconds = 0.8, -- refreshed on foes inside: nobody casts there but you
}

-- ─── Dampening, Silence, Eclipse ────────────────────────────────────────────

VoidTuning.black_sun = {
	radius = { base = 9, perPower = 0.8, max = 18 } :: Curve,
	seconds = { base = 6, perPower = 0.6, max = 12 } :: Curve,
	height = 18,
	every = 0.8,
	blindSeconds = 1.2,
}

VoidTuning.hush = {
	share = 0.3,
	seconds = { base = 2, perPower = 0.2, max = 4 } :: Curve,
	pvpSeconds = 1.5,
}

VoidTuning.ground_out = {
	radius = { base = 9, perPower = 0.8, max = 18 } :: Curve,
	seconds = { base = 8, perPower = 0.8, max = 16 } :: Curve,
}

-- ─── Absorption, Siphoning ──────────────────────────────────────────────────

VoidTuning.sponge = {
	seconds = { base = 8, perPower = 1, max = 18 } :: Curve,
	charges = { base = 1, perPower = 0.25, max = 3 } :: Curve, -- bolts it swallows before it's full
	reach = 4.5, -- studs from you a bolt is caught
	refill = 0.08, -- of your reservoir's max, each bolt swallowed
}

VoidTuning.hungry_mouth = {
	radius = { base = 7, perPower = 0.6, max = 13 } :: Curve,
	reachUp = 2.5, -- times its radius: how high above it things flying over are still drawn in
	seconds = { base = 6, perPower = 0.6, max = 12 } :: Curve,
	every = 0.4,
	pull = 10,
}

-- ─── Obscurance, Nullsign ───────────────────────────────────────────────────

VoidTuning.shadow_step = {
	reach = { base = 24, perPower = 3, max = 48 } :: Curve,
}

VoidTuning.rift_mote = {
	seconds = 2,
	radius = { base = 7, perPower = 0.5, max = 12 } :: Curve,
	every = 0.25,
	pull = 12,
	share = 0.7, -- when it collapses
}

VoidTuning.black_flame = {
	share = 0.25,
	burn = { base = 8, perPower = 2.5, max = 30 } :: Curve, -- reservoir burned from a player
	nonPlayerShare = 0.5, -- with no reservoir to burn, it bites flesh a little more
}

VoidTuning.unseen = {
	seconds = { base = 10, perPower = 1, max = 24 } :: Curve,
}

-- ─── Looks (client) ─────────────────────────────────────────────────────────

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

VoidTuning.looks = {
	void = rgb(12, 8, 20),
	rim = rgb(170, 140, 255),
	pale = rgb(220, 210, 255),
	thread = rgb(200, 180, 255),
}

return VoidTuning
