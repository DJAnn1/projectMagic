--!strict
--[[
	SpellHand data: how a caster's own style shows in their magic, and how each domain looks while a
	charge is being conjured (docs/SpellHand.md). Pure data; rules in Magic/SpellHand, drawing in
	Client/Fx/Conjure. Not secret: every client draws from it.

	A HAND (seeded per player on the server, Services/SpellHandService)
		rune    which rune pattern (an index into `runes`, Kenney Particle Pack names): your cast
		        circle and the glyphs in anything you conjure
		shape   what your conjured spell gathers into (`shapes`)
		spin    +1 or -1, and speed: which way and how fast your magic turns
		pitch   your cast sound's pitch, as a multiplier
		tier    your best mastery tier index: the hand grows more elaborate (see `detail`)

	TEMPERAMENTS lean the shape: a temperament listed here makes its shape `temperamentWeight`
	times as likely as each of the others. Everyone can still have any shape.

	FORMS decide where a charge is conjured: in the palm, overhead, or on the ground at your feet.

	DOMAINS: the core's material and transparency, whether the shape's pieces are solid (rock,
	ice) or light, and an optional per-property override (lightning is not fire, ice is not water).
]]

export type Look = {
	material: string, -- Enum.Material name of the core and solid pieces (never Neon: Bloom whitens it)
	alpha: number, -- core transparency
	solid: boolean, -- the shape's pieces are physical-looking (stone, ice) rather than light
	body: string?, -- DomainFx.textures role for the swirl around the core (default: the domain's spell body)
}

local shapes = { "orb", "shards", "halo", "helix" }

local temperamentShape: { [string]: string } = {
	volatile = "shards",
	brittle = "shards",
	precise = "shards",
	resonant = "halo",
	patient = "halo",
	steadfast = "orb",
	deepwell = "orb",
	radiant = "orb",
	swift = "helix",
	conduit = "helix",
	subtle = "helix",
}

local formMode: { [string]: string } = {
	touch = "hand",
	projectile = "hand",
	beam = "hand",
	chain = "hand",
	burst = "overhead",
	summon = "overhead",
	aura = "ground",
	wall = "ground",
	zone = "ground",
	pillar = "ground",
	ritual = "ground",
}

local domains: { [string]: Look } = {
	energy = { material = "ForceField", alpha = 0.1, solid = false },
	earth = { material = "Slate", alpha = 0, solid = true },
	water = { material = "Glass", alpha = 0.35, solid = false },
	air = { material = "ForceField", alpha = 0.5, solid = false, body = "smoke" },
	life = { material = "Grass", alpha = 0.2, solid = true, body = "sparkles" },
	mind = { material = "ForceField", alpha = 0.15, solid = false, body = "glow" },
	spirit = { material = "ForceField", alpha = 0.35, solid = false, body = "glow" },
	void = { material = "SmoothPlastic", alpha = 0, solid = false, body = "implode" },
	space = { material = "ForceField", alpha = 0.2, solid = false, body = "vortex" },
	time = { material = "Glass", alpha = 0.3, solid = false, body = "vortex" },
	gravity = { material = "Basalt", alpha = 0, solid = true, body = "implode" },
	reality = { material = "ForceField", alpha = 0.1, solid = false, body = "square" },
}

-- "domain.property" overrides: what a spell visibly is matters more than its domain.
local properties: { [string]: Look } = {
	["energy.charge"] = { material = "ForceField", alpha = 0.05, solid = false, body = "lightningAlt" },
	["energy.shadow"] = { material = "SmoothPlastic", alpha = 0.1, solid = false, body = "implode" },
	["energy.luminosity"] = { material = "Glass", alpha = 0.2, solid = false, body = "glow" },
	["water.temperature"] = { material = "Ice", alpha = 0.15, solid = true, body = "sparkles" },
	["air.charge"] = { material = "ForceField", alpha = 0.05, solid = false, body = "lightningAlt" },
	["earth.magnetism"] = { material = "Metal", alpha = 0, solid = true },
}

return table.freeze({
	shapes = shapes,
	runes = { "magic_01", "magic_02", "magic_03", "magic_04", "magic_05" },
	temperamentShape = temperamentShape,
	temperamentWeight = 3,
	formMode = formMode,
	domains = domains,
	properties = properties,
	spinSpeed = { 0.6, 1.6 }, -- turns a second, min..max
	pitch = { 0.88, 1.14 },
	detail = {
		motesEvery = 2, -- one orbiting mote per this many tiers (Novice none, Transcendent 4)
		motesMax = 4,
		secondRingAt = 5, -- Expert
		crownAt = 7, -- Grandmaster
	},
	-- Conjuring (client): size of the core at the start and at a full charge, in studs, by mode.
	size = {
		hand = { 0.35, 1.3 },
		overhead = { 0.6, 2.6 },
		ground = { 2, 7 }, -- the rune circle's diameter
	},
	overheadHeight = 3.2, -- studs above the head
	handReach = 1.1, -- studs in front of the palm
})
