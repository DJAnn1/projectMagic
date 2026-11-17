--!strict
--[[
	MindTuning: the numbers behind Mind's spells (docs/DomainIdeas.md, "Mind"). Mind works on people:
	what they see, feel, remember and do. Ordinary spells that fit their branches, not ultimates: each is
	a narrow route in Data/EffectLibrary ("mind_" .. move), resolved by Server/Magic/Cast/Effects/MindArt;
	anything that lasts runs in Server/Magic/Cast/ArtRuntime and is drawn by Client/Fx/ArtFx with MindFx's
	builders. Mind's properties aren't harmful ones, so only Mind Spike and Phantom Blade hurt outright.

	A `{ base, perPower, max }` grows with the recipe's power: MindTuning.at(c, power) =
	min(max, base + perPower x power). `share` is a fraction of a normal hit (Cast/DamageModel.base).
]]

local MindTuning = {}

export type Curve = { base: number, perPower: number, max: number }

function MindTuning.at(curve: Curve, power: number): number
	return math.min(curve.max, curve.base + curve.perPower * math.max(0, power))
end

-- ─── Perceptics, Farsight, Insight ──────────────────────────────────────────

MindTuning.far_eye = {
	speed = 1.2,
	seconds = { base = 4, perPower = 0.5, max = 8 } :: Curve, -- you look through it this long
}

MindTuning.weak_spot = {
	seconds = { base = 6, perPower = 0.6, max = 12 } :: Curve, -- jinxed and crumbling: hits crit more, land harder
}

-- ─── Empathy, Charm, Dread ──────────────────────────────────────────────────

MindTuning.rally = {
	radius = 14,
	hasteSeconds = { base = 5, perPower = 0.5, max = 10 } :: Curve,
	heal = 0.2,
}

MindTuning.despair = {
	radius = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	seconds = { base = 6, perPower = 0.6, max = 12 } :: Curve,
	every = 0.6,
}

MindTuning.pacify = {
	radius = { base = 8, perPower = 0.7, max = 15 } :: Curve,
	seconds = { base = 5, perPower = 0.5, max = 10 } :: Curve,
	every = 0.5,
	calmSeconds = 1, -- refreshed while they stand in it
}

-- ─── Illusion, Phantasms, Grand Illusion, Veiling ───────────────────────────

MindTuning.mirror_images = {
	seconds = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	images = 3,
	shield = 0.6, -- of a normal hit, per image
}

MindTuning.phantom_blade = {
	share = 0.9,
	dazeSeconds = 1.5,
}

MindTuning.false_wall = {
	width = { base = 10, perPower = 0.8, max = 18 } :: Curve,
	height = 9,
	seconds = { base = 12, perPower = 1.5, max = 30 } :: Curve,
}

MindTuning.phantom_beast = {
	seconds = { base = 5, perPower = 0.4, max = 9 } :: Curve,
	every = 0.8,
	fearSeconds = 1.2,
}

MindTuning.vanish = {
	seconds = { base = 8, perPower = 1, max = 20 } :: Curve,
}

MindTuning.mirage_pit = {
	radius = { base = 6, perPower = 0.6, max = 12 } :: Curve,
	seconds = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	every = 0.4,
	push = 30,
}

-- ─── Mnemonics, Oblivion ────────────────────────────────────────────────────

MindTuning.forget_me = {
	seconds = { base = 10, perPower = 1.5, max = 25 } :: Curve, -- how long they don't notice you again
}

-- ─── Telepathy, Dominion ────────────────────────────────────────────────────

MindTuning.mind_spike = {
	share = 1,
	dazeSeconds = 1.5,
}

MindTuning.psychic_push = {
	reach = { base = 14, perPower = 1.5, max = 26 } :: Curve,
	arc = 70,
	push = { base = 50, perPower = 4, max = 85 } :: Curve,
	share = 0.15,
}

MindTuning.whispers = {
	radius = { base = 8, perPower = 0.8, max = 16 } :: Curve,
	seconds = { base = 6, perPower = 0.6, max = 12 } :: Curve,
	every = 0.8,
}

MindTuning.puppet = {
	seconds = { base = 1.5, perPower = 0.1, max = 3 } :: Curve,
	reach = { base = 14, perPower = 1.5, max = 30 } :: Curve, -- how far you can walk them
	pvpReach = 8,
	pvpSeconds = 1.5,
}

-- ─── Looks (client) ─────────────────────────────────────────────────────────

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

MindTuning.looks = {
	psychic = rgb(190, 110, 255),
	pale = rgb(230, 210, 255),
	warm = rgb(255, 200, 150),
	dread = rgb(60, 30, 80),
	illusion = rgb(150, 220, 255),
	shimmer = rgb(240, 250, 255),
	memory = rgb(220, 200, 150),
}

return MindTuning
