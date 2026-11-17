--!strict
--[[
	Stagings: what a spell does on screen once it lands, beat by beat (docs/Smoothness.md, stage 3).
	Data only; Client/Fx/Staging plays it, Fx/SpellFx starts it on the server's resolve, and
	Fx/ShapeFx starts an ultimate's long sequence on its "ultimate" cue. Cosmetic: nothing here
	changes when or whom a spell hits (the flash always lands on the server's resolve).

	A BEAT
		at        seconds after the resolve
		kind      "dome"    a glass sphere (ForceField) growing out of the spot: grow, hold, fade
		          "rings"   thick rings running out along the ground, `count` of them `every` s apart
		          "rays"    light shafts beaming up out of the spot
		          "slashes" crescents whirled round the caster (SlashFx arcs)
		          "shards"  pieces thrown out of the spot
		          "flash"   one bright ball of light, gone in a blink
		scale     x the spell's radius (area forms) or impact radius (others)
		minPower  the beat only plays from this recipe power up
		grow / hold / fade   seconds (domes)
		count / every        (rings, rays, slashes, shards)

	FORMS   one beat list per spell form.
	ULTIMATE   the long sequence of a domain ultimate (Data/Ultimates), timed from the server's
	           cue: BUILD (its sigil spreads and rays rise until the pause), PAUSE (the rays die,
	           nothing moves), REVEAL (on the first hit: a flash, the field-sized dome, a ring
	           stream), LINGER (until the ultimate ends), FADE.
]]

export type Beat = {
	at: number?,
	kind: string,
	scale: number?,
	minPower: number?,
	grow: number?,
	hold: number?,
	fade: number?,
	count: number?,
	every: number?,
}

local Stagings = {}

Stagings.kinds = table.freeze({ "dome", "rings", "rays", "slashes", "shards", "flash" })

Stagings.forms = table.freeze({
	burst = {
		{ kind = "flash", scale = 0.5 },
		{ kind = "dome", scale = 1, grow = 0.2, hold = 0.1, fade = 0.5, minPower = 3 },
		{ kind = "rings", scale = 1.3, count = 1 },
		{ at = 0.04, kind = "shards", count = 16, minPower = 4 },
	},
	zone = {
		{ kind = "dome", scale = 0.95, grow = 0.35, hold = 0.6, fade = 0.8, minPower = 3 },
		{ kind = "rings", scale = 1, count = 4, every = 0.45 },
		{ at = 0.1, kind = "rays", count = 3, minPower = 5 },
	},
	aura = {
		{ kind = "rings", scale = 1.2, count = 2, every = 0.15 },
		{ kind = "slashes", count = 2, minPower = 3 },
		{ kind = "dome", scale = 0.8, grow = 0.15, hold = 0, fade = 0.35, minPower = 5 },
	},
	pillar = {
		{ kind = "rays", count = 4, minPower = 3 },
		{ kind = "rings", scale = 1.1, count = 1 },
	},
	ritual = {
		{ kind = "flash", scale = 0.6 },
		{ kind = "rays", count = 7 },
		{ kind = "dome", scale = 1.15, grow = 0.5, hold = 0.6, fade = 0.9 },
		{ kind = "rings", scale = 1.2, count = 3, every = 0.3 },
		{ at = 0.1, kind = "shards", count = 24 },
	},
	wall = {
		{ kind = "rings", scale = 0.8, count = 1 },
	},
	summon = {
		{ kind = "rays", count = 3 },
		{ kind = "rings", scale = 1, count = 2, every = 0.2 },
	},
	touch = {
		{ kind = "slashes", count = 1, minPower = 4 },
	},
	projectile = {
		{ kind = "rings", scale = 1.6, count = 1, minPower = 4 },
		{ kind = "dome", scale = 1.1, grow = 0.12, hold = 0, fade = 0.3, minPower = 6 },
	},
	beam = {
		{ kind = "rings", scale = 1.4, count = 1, minPower = 5 },
	},
	chain = {},
} :: { [string]: { Beat } })

Stagings.ultimate = table.freeze({
	pause = 0.55, -- seconds of stillness right before the reveal (the build stops short of it)
	sigilMult = 2.4, -- the ultimate's sigil: x its reach (diameter)
	buildRays = 6,
	domeScale = 1.25, -- x its reach
	domeGrow = 0.45,
	domeFade = 1.0,
	ringEvery = 0.55,
	revealShards = 30,
	minBuild = 0.6, -- an ultimate whose first hit comes sooner still gets this much build
	maxReach = 80,
})

-- Sizes and limits for the pieces (studs, seconds, per client).
Stagings.pieces = table.freeze({
	ringThickness = 0.045, -- of the ring's diameter
	ringLife = 0.65,
	rayHeightBase = 14,
	rayHeightPerRadius = 1.6,
	rayRise = 0.25,
	rayLife = 0.9,
	shardSpeed = 18,
	slashReachBase = 2.5,
	slashReachPerRadius = 0.5,
})

Stagings.caps = table.freeze({
	domes = 10,
	rings = 28,
	range = 260, -- studs from the camera: further away, nothing is staged
	-- Standing inside someone's dome tints your view toward its colour, at most this much.
	insideTint = 0.3,
	insideTintReduced = 0.1,
})

return Stagings
