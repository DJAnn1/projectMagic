--!strict
--[[
	PropertyLooks: what a spell looks like by PROPERTY, layered over its domain's look (docs/
	SpellOverhaul.md §2C, stage 2). Before this the property changed one thing on screen (charge drew
	lightning); a sound bolt, a radiation bolt and a soul bolt from the same domain looked the same.
	Read by Client/Fx/DomainFx (DomainFx.look(domain, property) merges this over the domain look)
	and Client/Fx/PropertyFx (colour pull, flourishes, lingering effects). Shared so the spec can
	check it; it holds no secrets.

	Fields (every one optional; anything left out keeps the domain's value)
		tint      { color, share }: pulls the caster's palette (domain colours tinted by their
		          signature) toward this colour by `share` (0..1). Frost reads icy in any domain.
		body      partial override of the domain's body cloud: texture (a ROLE name, see `roles`),
		          size, lifetime, speed, additive
		sparks    partial override: texture, size, speed, gravity (negative rises), lifetime
		smoke     false removes the after-smoke; a table { tint, size, lifetime } replaces it
		dark      true gives a near-black core (void-like)
		light     partial override: brightness, range, flicker
		mark      the ground mark (FxLayers.groundMark kind), or false for none
		shake     camera shake multiplier
		beam      how a beam or chain is drawn: "lightning" (forked bolts) or "ripple" (a beam with
		          rings riding along it); nil keeps the plain beam
		flourish  list of extra impact layers drawn by Fx/PropertyFx (kinds in `flourishes`)
		linger    { kind, seconds }: something left hanging at the impact for a while (kinds in
		          `lingers`): frost mist, embers, sick motes, spores, dust, wisps

	Sounds per property are NOT here yet: the owner asked for them last (2026-11-13), so every
	property keeps its domain's cast, launch and impact sounds for now.
	Tuning status: first pass, not yet seen in play.
]]

export type Look = {
	tint: { color: Color3, share: number }?,
	body: { [string]: any }?,
	sparks: { [string]: any }?,
	smoke: any?,
	dark: boolean?,
	light: { [string]: number }?,
	mark: any?,
	shake: number?,
	beam: string?,
	flourish: { string }?,
	linger: { kind: string, seconds: number }?,
}

local C = Color3.fromRGB

local looks: { [string]: Look } = {
	-- ─── Fire and frost ──────────────────────────────────────────────────────
	combustion = {
		tint = { color = C(255, 110, 30), share = 0.45 },
		body = { texture = "fire", additive = true, size = 1.6 },
		sparks = { texture = "fireSparks", gravity = -12, speed = 18, lifetime = 1.2 }, -- embers rise
		light = { brightness = 7, flicker = 0.55 },
		mark = "scorch",
		flourish = { "embers" },
		linger = { kind = "embers", seconds = 3 },
	},
	heat = {
		tint = { color = C(255, 150, 60), share = 0.35 },
		body = { texture = "fire", additive = true },
		sparks = { texture = "fireSparks", gravity = -6 },
		light = { brightness = 5, flicker = 0.35 },
		mark = "scorch",
		flourish = { "embers" },
	},
	temperature = {
		tint = { color = C(255, 150, 60), share = 0.3 },
		body = { texture = "fire", additive = true },
		sparks = { texture = "fireSparks", gravity = -6 },
		light = { brightness = 4, flicker = 0.3 },
		mark = "scorch",
		flourish = { "embers" },
	},
	cold = {
		tint = { color = C(175, 225, 255), share = 0.55 },
		body = { texture = "smoke", additive = false, size = 2, lifetime = 0.9, speed = 5 }, -- frost mist
		sparks = { texture = "shard", size = 0.5, speed = 28, gravity = 60, lifetime = 0.9 }, -- ice shards
		smoke = { tint = C(225, 240, 255), size = 3.5, lifetime = 2 },
		light = { brightness = 2, flicker = 0 },
		mark = "frost",
		shake = 0.8,
		flourish = { "shards" },
		linger = { kind = "mist", seconds = 3 },
	},
	phase = {
		tint = { color = C(175, 225, 255), share = 0.5 },
		body = { texture = "smoke", additive = false, size = 1.8 },
		sparks = { texture = "shard", size = 0.45, speed = 26, gravity = 60 },
		smoke = { tint = C(225, 240, 255), size = 3, lifetime = 1.6 },
		mark = "frost",
		flourish = { "shards" },
		linger = { kind = "mist", seconds = 2.5 },
	},

	-- ─── Energy ──────────────────────────────────────────────────────────────
	charge = {
		tint = { color = C(185, 205, 255), share = 0.4 },
		body = { texture = "glow", additive = true, size = 1.3, lifetime = 0.3 },
		sparks = { texture = "crackle", size = 0.6, speed = 45, gravity = 0, lifetime = 0.25 },
		light = { brightness = 6, flicker = 0.8 },
		mark = "scorch",
		beam = "lightning",
		flourish = { "fork" },
	},
	luminosity = {
		tint = { color = C(255, 248, 215), share = 0.5 },
		body = { texture = "glow", additive = true, size = 2.2, lifetime = 0.35 },
		sparks = { texture = "sparkles", size = 0.35, speed = 30, gravity = 0 },
		smoke = false,
		light = { brightness = 9, range = 1.8, flicker = 0 },
		mark = false,
		flourish = { "flare" },
	},
	radiation = {
		tint = { color = C(140, 255, 90), share = 0.55 },
		body = { texture = "glow", additive = true, size = 1.6, lifetime = 0.8, speed = 3 },
		sparks = { texture = "mote", size = 0.35, speed = 6, gravity = -3, lifetime = 1.6 },
		smoke = false,
		light = { brightness = 3, flicker = 0.3 },
		mark = "stain",
		flourish = { "motes" },
		linger = { kind = "motes", seconds = 4 },
	},

	-- ─── Force and sound ─────────────────────────────────────────────────────
	sound = {
		body = { texture = "ring", additive = true, size = 2.4, lifetime = 0.4, speed = 18 },
		sparks = { texture = "sparkles", size = 0.25, speed = 30, gravity = 0, lifetime = 0.3 },
		smoke = false,
		light = { brightness = 0.6 },
		mark = false,
		shake = 1.4,
		beam = "ripple",
		flourish = { "rings" },
	},
	resonance = {
		tint = { color = C(205, 185, 255), share = 0.3 },
		body = { texture = "ring", additive = true, size = 1.8, lifetime = 0.6 },
		sparks = { texture = "shard", size = 0.4, speed = 18, gravity = 20 },
		smoke = false,
		beam = "ripple",
		flourish = { "rings", "shards" },
	},
	momentum = {
		body = { texture = "smoke", additive = false, size = 2.2, speed = 32, lifetime = 0.45 },
		sparks = { texture = "debris", gravity = 90, speed = 40 },
		mark = "crack",
		shake = 1.6,
		flourish = { "gust" },
	},
	weight = {
		body = { texture = "burstSmoke", additive = false, size = 2.6, speed = 6 },
		sparks = { texture = "debris", size = 0.5, gravity = 170, speed = 26 },
		mark = "crack",
		shake = 2,
		flourish = { "crush", "dust" },
	},
	orientation = {
		tint = { color = C(170, 140, 255), share = 0.3 },
		body = { texture = "vortex", additive = true, size = 2.2, speed = 2 },
		sparks = { texture = "square", size = 0.3, gravity = -25, speed = 14 }, -- bits falling upward
		mark = "rune",
		flourish = { "warp" },
	},
	pressure = {
		body = { texture = "smoke", additive = false, size = 2.4, speed = 26, lifetime = 0.4 },
		sparks = { texture = "sparkles", size = 0.25, speed = 40, gravity = 0 },
		smoke = false,
		shake = 1.4,
		flourish = { "gust", "rings" },
	},
	flow = {
		tint = { color = C(80, 160, 240), share = 0.4 },
		body = { texture = "sparkles", additive = false, size = 1.2, speed = 16 },
		sparks = { texture = "sparkles", size = 0.45, speed = 26, gravity = 75 },
		mark = "puddle",
		flourish = { "splash" },
	},
	breath = {
		tint = { color = C(215, 232, 242), share = 0.3 },
		body = { texture = "smoke", additive = false, size = 2, speed = 14 },
		sparks = { texture = "mote", size = 0.3, speed = 6, gravity = -8, lifetime = 1.2 }, -- air leaving them
		smoke = false,
		mark = false,
		flourish = { "gust" },
	},

	-- ─── Body and soul ───────────────────────────────────────────────────────
	cohesion = {
		tint = { color = C(200, 170, 125), share = 0.3 },
		body = { texture = "dust", additive = false, size = 1.8 },
		sparks = { texture = "debris", size = 0.4, gravity = 80 },
		mark = "crack",
		flourish = { "dust" },
	},
	vitality = {
		tint = { color = C(210, 50, 70), share = 0.35 },
		body = { texture = "glow", additive = true, size = 1.4 },
		sparks = { texture = "mote", size = 0.4, speed = 8, gravity = -2 },
		smoke = false,
		mark = "stain",
		flourish = { "drain" },
	},
	metabolism = {
		tint = { color = C(170, 200, 60), share = 0.4 },
		body = { texture = "smoke", additive = false, size = 1.6, speed = 4 },
		sparks = { texture = "spore", size = 0.35, speed = 5, gravity = -1, lifetime = 1.8 },
		smoke = false,
		mark = "stain",
		flourish = { "spores" },
		linger = { kind = "spores", seconds = 3 },
	},
	soul = {
		tint = { color = C(180, 230, 255), share = 0.45 },
		body = { texture = "glow", additive = true, size = 1.8, lifetime = 0.9, speed = 3 },
		sparks = { texture = "wisp", size = 0.7, speed = 6, gravity = -12, lifetime = 1.4 },
		smoke = false,
		mark = "rune",
		flourish = { "wisps" },
	},
	essence = {
		tint = { color = C(120, 140, 255), share = 0.35 },
		body = { texture = "glow", additive = true, size = 1.5 },
		sparks = { texture = "mote", size = 0.4, speed = 10, gravity = 0 },
		smoke = false,
		mark = "rune",
		flourish = { "drain" },
	},
	unlife = {
		tint = { color = C(105, 115, 95), share = 0.55 },
		body = { texture = "smoke", additive = false, size = 2, speed = 3, lifetime = 1 },
		sparks = { texture = "spore", size = 0.4, speed = 4, gravity = -4, lifetime = 1.8 },
		smoke = { tint = C(50, 55, 45), size = 3, lifetime = 2 },
		light = { brightness = 0.8, flicker = 0.2 },
		mark = "stain",
		flourish = { "wisps", "spores" },
		linger = { kind = "spores", seconds = 4 },
	},
	age = {
		tint = { color = C(205, 188, 150), share = 0.45 },
		body = { texture = "dust", additive = false, size = 2, speed = 4, lifetime = 1.1 },
		sparks = { texture = "dust", size = 0.4, speed = 8, gravity = 25, lifetime = 1.4 },
		smoke = false,
		light = { brightness = 1 },
		mark = "crack",
		flourish = { "dust" },
		linger = { kind = "dust", seconds = 3 },
	},
}

return table.freeze({
	looks = looks,
	-- Texture roles a look may name (Client/Fx/DomainFx.textures provides each one).
	roles = table.freeze({
		"sparkles", "fire", "fireSparks", "smoke", "core", "shock", "implode", "burstSmoke", "glow", "vortex",
		"square", "rune", "debris", "shard", "ring", "mote", "wisp", "spore", "dust", "crackle",
	}),
	-- Impact flourishes Fx/PropertyFx draws, and lingering effects.
	flourishes = table.freeze({ "embers", "shards", "fork", "flare", "motes", "rings", "gust", "crush", "dust", "warp", "splash", "drain", "spores", "wisps" }),
	lingers = table.freeze({ "mist", "embers", "motes", "spores", "dust" }),
	-- Ground marks FxLayers.groundMark knows.
	marks = table.freeze({ "scorch", "crack", "puddle", "frost", "bloom", "rune", "void", "stain" }),
	beams = table.freeze({ "lightning", "ripple" }),
})
