--!strict
--[[
	SpiritTuning: the numbers behind Spirit's spells (docs/DomainIdeas.md, "Spirit"). Spirit deals with
	wards, curses, bonds and the dead. Ordinary spells that fit their branches, not ultimates: each is a
	narrow route in Data/EffectLibrary ("spirit_" .. move), resolved by Server/Magic/Cast/Effects/SpiritArt;
	anything that lasts runs in Server/Magic/Cast/ArtRuntime and is drawn by Client/Fx/ArtFx with SpiritFx's
	builders.

	A `{ base, perPower, max }` grows with the recipe's power: SpiritTuning.at(c, power) =
	min(max, base + perPower x power). `share` is a fraction of a normal hit (Cast/DamageModel.base).
]]

local SpiritTuning = {}

export type Curve = { base: number, perPower: number, max: number }

function SpiritTuning.at(curve: Curve, power: number): number
	return math.min(curve.max, curve.base + curve.perPower * math.max(0, power))
end

-- ─── Warding, Sanctums, Hallowing, Counterwarding ───────────────────────────

SpiritTuning.glyph_shield = {
	width = { base = 8, perPower = 0.6, max = 14 } :: Curve,
	height = 8,
	seconds = { base = 6, perPower = 0.8, max = 14 } :: Curve,
	thickness = 1.5,
}

SpiritTuning.sigil_trap = {
	radius = 4,
	seconds = { base = 45, perPower = 5, max = 90 } :: Curve, -- it waits this long for someone
	every = 0.2,
	share = 0.5,
	push = 60,
	dazeSeconds = 2,
}

SpiritTuning.hallowed_ground = {
	radius = { base = 8, perPower = 0.7, max = 15 } :: Curve,
	seconds = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	every = 1,
	heal = 0.12, -- allies, each second
	burn = 0.2, -- cursed foes (hexed, soul-marked, withering), each second
}

SpiritTuning.mirror_ward = {
	seconds = { base = 5, perPower = 0.6, max = 12 } :: Curve,
	radius = 5,
	charges = { base = 2, perPower = 0.3, max = 5 } :: Curve,
}

-- ─── Hexcraft, Greater Curses ───────────────────────────────────────────────

SpiritTuning.doom_mark = {
	seconds = { base = 6, perPower = 0.3, max = 9 } :: Curve,
	share = 0.5, -- when it lands, before what was added
	perHit = 0.2, -- added for every blow anyone landed on them while marked
	maxHits = 10,
}

SpiritTuning.ill_luck = {
	radius = 12,
	seconds = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	every = 1,
}

SpiritTuning.thorn_curse = {
	seconds = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	share = 0.3, -- they take this each time they land a blow
	gap = 0.5,
}

-- ─── Binding, Pactcraft, Soulbinding ────────────────────────────────────────

SpiritTuning.spirit_chains = {
	share = 0.25,
	seconds = { base = 1.6, perPower = 0.15, max = 3 } :: Curve,
	pvpSeconds = 2,
	drag = 8, -- studs toward you first
}

SpiritTuning.soul_tether = {
	seconds = { base = 6, perPower = 0.5, max = 12 } :: Curve,
	reach = 10, -- studs apart before the bond pulls them back
	every = 0.25,
	findReach = 20,
}

SpiritTuning.shared_fate = {
	seconds = { base = 10, perPower = 1, max = 24 } :: Curve,
	split = 0.5, -- of every hit on either of you goes to the other instead
}

-- ─── Necrourgy, Deathspeech, Revenancy ──────────────────────────────────────

SpiritTuning.grave_hand = {
	share = 0.5,
	seconds = { base = 1.4, perPower = 0.12, max = 2.6 } :: Curve,
	pvpSeconds = 1.5,
}

SpiritTuning.spirit_wolves = {
	count = 3,
	seconds = { base = 10, perPower = 0.8, max = 18 } :: Curve,
	speed = 22,
	seek = 40,
	bite = 4,
	every = 0.6,
	share = 0.25,
}

SpiritTuning.ghost_form = {
	seconds = { base = 2.5, perPower = 0.2, max = 4.5 } :: Curve,
	resist = 0.85, -- of all damage passes through you
}

SpiritTuning.wail = {
	radius = { base = 10, perPower = 1, max = 20 } :: Curve,
	fearSeconds = { base = 2.5, perPower = 0.2, max = 4 } :: Curve,
	share = 0.25,
}

SpiritTuning.grave_mist = {
	radius = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	seconds = { base = 7, perPower = 0.6, max = 14 } :: Curve,
	every = 0.8,
	share = 0.08,
}

-- ─── Looks (client) ─────────────────────────────────────────────────────────

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

SpiritTuning.looks = {
	rune = rgb(255, 225, 140),
	holy = rgb(255, 245, 200),
	hex = rgb(150, 60, 190),
	hexDark = rgb(50, 15, 70),
	chain = rgb(200, 230, 255),
	soul = rgb(150, 230, 255),
	ghost = rgb(200, 240, 255),
	bone = rgb(225, 215, 195),
	mist = rgb(130, 150, 160),
}

return SpiritTuning
