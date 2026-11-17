--!strict
--[[
	Sigils: the drawn circles of magic (docs/Smoothness.md, stage 2). Data only; Client/Fx/Sigils
	draws them as crisp lines on a flat part, Fx/Conjure and Fx/SpellFx place them.

	Each domain has its own FAMILY (our own designs; never another game's drawings):
		pattern   the inner drawing (one of `patterns`, drawn by Fx/Sigils)
		band      the outer band once the caster's tier earns it (one of `bands`)
		core      the centre (one of `cores`)
		spin      turns a second of the inner drawing (the band counter-turns at half)
		weight    line thickness multiplier
	A property's CATEGORY adds one small MOTIF round the edge; the VERB sets how it MOVES; the
	caster's tier sets the DETAIL. The caster's spell hand seeds the variations, so two mages of
	one domain never draw quite the same circle.

	Sizes are diameters in studs. Everything here is cosmetic: no gameplay reads it.
]]

export type Family = {
	pattern: string,
	band: string,
	core: string,
	spin: number,
	weight: number,
}

export type Motion = {
	spin: number, -- multiplies the family's spin (negative turns the other way)
	pulse: number, -- 0..1 breathing in size while it holds
	draw: string, -- "out": grows from the centre; "in": shrinks onto the caster; "steady"
}

local Sigils = {}

Sigils.patterns = table.freeze({
	"lattice", "plates", "ripples", "spiral", "rosette", "iris",
	"glyphs", "web", "constellation", "dial", "well", "tessellation",
})
Sigils.bands = table.freeze({ "ring", "ticks", "runes", "beads" })
Sigils.cores = table.freeze({ "star", "disc", "eye", "void", "none" })
Sigils.motifs = table.freeze({ "spikes", "notches", "waves", "chevrons", "dots", "crosses", "petals", "hooks" })

Sigils.families = table.freeze({
	energy = { pattern = "lattice", band = "ticks", core = "star", spin = 0.12, weight = 1 },
	earth = { pattern = "plates", band = "ring", core = "disc", spin = 0.04, weight = 1.5 },
	water = { pattern = "ripples", band = "beads", core = "disc", spin = 0.08, weight = 1 },
	air = { pattern = "spiral", band = "ticks", core = "none", spin = 0.3, weight = 0.8 },
	life = { pattern = "rosette", band = "beads", core = "disc", spin = 0.06, weight = 1 },
	mind = { pattern = "iris", band = "runes", core = "eye", spin = 0.1, weight = 0.9 },
	spirit = { pattern = "glyphs", band = "runes", core = "star", spin = 0.09, weight = 1 },
	void = { pattern = "web", band = "ring", core = "void", spin = 0.05, weight = 0.8 },
	space = { pattern = "constellation", band = "beads", core = "star", spin = 0.07, weight = 0.8 },
	time = { pattern = "dial", band = "ticks", core = "disc", spin = 0.05, weight = 1 },
	gravity = { pattern = "well", band = "ring", core = "void", spin = 0.15, weight = 1.2 },
	reality = { pattern = "tessellation", band = "runes", core = "eye", spin = 0.06, weight = 0.9 },
} :: { [string]: Family })

-- Property category -> the motif round the edge.
Sigils.motifByCategory = table.freeze({
	Energetic = "spikes",
	Thermal = "chevrons",
	Material = "notches",
	Fluid = "waves",
	Kinetic = "chevrons",
	Vital = "petals",
	Mental = "dots",
	Spiritual = "crosses",
	Metaphysical = "hooks",
	Spatial = "dots",
	Temporal = "notches",
	Arcane = "hooks",
} :: { [string]: string })

Sigils.motions = table.freeze({
	generate = { spin = 1, pulse = 0.03, draw = "out" },
	amplify = { spin = 1.2, pulse = 0.06, draw = "out" },
	reduce = { spin = -0.8, pulse = 0.03, draw = "in" },
	transfer = { spin = 1.5, pulse = 0.02, draw = "steady" },
	redirect = { spin = 2.4, pulse = 0, draw = "steady" },
	transmute = { spin = 0.6, pulse = 0.05, draw = "out" },
	bind = { spin = 0.3, pulse = 0, draw = "in" },
	sense = { spin = 0.5, pulse = 0.08, draw = "out" },
	store = { spin = 0.2, pulse = 0.02, draw = "in" },
	release = { spin = 1.8, pulse = 0.04, draw = "out" },
} :: { [string]: Motion })
Sigils.defaultMotion = table.freeze({ spin = 1, pulse = 0.03, draw = "out" }) :: Motion

-- Detail by mastery tier (0..8): what's drawn.
Sigils.detail = table.freeze({
	ringAt = 1, -- a plain outer ring
	bandAt = 3, -- the family's band
	motifAt = 2, -- the property's motif
	innerRingAt = 5, -- a second, counter-turning inner ring
	crownAt = 7, -- a crown of dots outside the band
	reducedMaxTier = 3, -- Reduce spell effects draws no more than this tier's detail
})

-- Where and how big (diameters, studs).
Sigils.size = table.freeze({
	-- A timed cast's circle at the feet: from `start`, growing to base + per power while it casts.
	feetStart = 2.5,
	feetBase = 4,
	feetPerPower = 0.8,
	feetPerTier = 0.25,
	-- The disc standing in front of the hand (bolts, beams, touch, chains).
	handBase = 1.6,
	handPerPower = 0.16,
	handReach = 1.4, -- studs in front of the palm
	-- Charging (Fx/Conjure): the disc snaps one size per charge stage (index 1..4).
	chargeStages = { 0.55, 0.8, 1, 1.12 },
	-- The snap out on release: the circle grows to this many times its size (or to the spell's
	-- area, whichever is bigger) while it fades.
	burstMult = 2.2,
	burstAreaMult = 2.2,
	burstTime = 0.22,
	burstFade = 0.4,
	-- A mark where a spell lands: impact radius x this.
	stampMult = 2.4,
	stampAreaMult = 2.1,
	stampMin = 2,
	stampMax = 90,
})

-- How far a sigil lying on the ground sits above it (studs). Terrain grass blades would cover a
-- flush drawing, so on grass materials it rides above the place's grass length (Terrain.GrassLength).
Sigils.lift = table.freeze({
	base = 0.08,
	aboveGrass = 0.15, -- added to Terrain.GrassLength on Grass / LeafyGrass
	grassMaterials = { "Grass", "LeafyGrass" },
})

Sigils.timing = table.freeze({
	snap = 18, -- how fast a disc catches up with its new size (higher = snappier)
	stampGrow = 0.12,
	stampHold = 0.35,
	stampHoldPerPower = 0.05,
	stampFade = 0.45,
	cancelFade = 0.3,
})

-- Limits (per client).
Sigils.caps = table.freeze({
	live = 14, -- at most this many on screen; past it, the old particle circle is used
	pool = 16, -- finished drawings kept for reuse (same caster, domain and tier draw the same)
	range = 160, -- studs from the camera: further away, nothing is drawn
	canvas = 512, -- pixels across the drawing surface
	brightness = 2.2, -- above 1 so Bloom makes the lines glow
})

return Sigils
