--!strict
--[[
	StatusLooks: what a status looks like ON A BODY, seen by everyone nearby (docs/SpellOverhaul.md
	§2C, stage 2). Until now a status showed as a floating word ("▼ Chilled") and, for your own,
	a screen tint. Now the chilled are rimed with frost, the frozen sit in an ice shell, the burning
	burn, the irradiated give off green motes. Drawn by Client/Controllers/StatusLookController
	(Fx/StatusFx) from the replicated "Status_<id>" Humanoid attributes (Cast/StatusEffects).

	Fields
		emit    list of particle layers, each:
		          at        "torso" | "head" | "feet" (the body part it hangs on)
		          texture   a ROLE name (Data/PropertyLooks.roles; Client/Fx/DomainFx.textures)
		          color     Color3
		          size      particle size (studs)
		          rate      particles per second at full quality
		          lifetime  seconds
		          speed     studs/s outward
		          rise      studs/s² upward (negative falls)
		          additive  true glows (LightEmission 1), false is lit like matter
		          orbit     true: emitted from a sphere surface around the part (stars round a head)
		shell   { color, transparency, material }: a translucent shell around the torso and limbs
		        (frozen in ice). Drawn on the client only, never collides, weighs nothing.
	Tuning status: first pass, not yet seen in play.
]]

export type Emit = {
	at: string,
	texture: string,
	color: Color3,
	size: number,
	rate: number,
	lifetime: number,
	speed: number?,
	rise: number?,
	additive: boolean?,
	orbit: boolean?,
}
export type Look = { emit: { Emit }?, shell: { color: Color3, transparency: number, material: string }? }

local C = Color3.fromRGB

local looks: { [string]: Look } = {
	burning = { emit = {
		{ at = "torso", texture = "fire", color = C(255, 130, 40), size = 1.6, rate = 18, lifetime = 0.6, speed = 1, rise = 6, additive = true },
		{ at = "torso", texture = "fireSparks", color = C(255, 190, 90), size = 0.25, rate = 8, lifetime = 0.9, speed = 3, rise = 8, additive = true },
	} },
	chilled = { emit = {
		{ at = "torso", texture = "sparkles", color = C(210, 238, 255), size = 0.35, rate = 10, lifetime = 0.9, speed = 0.5, rise = -2, additive = true },
		{ at = "feet", texture = "smoke", color = C(220, 238, 255), size = 1.6, rate = 4, lifetime = 1.4, speed = 0.4, rise = 0.5 },
	} },
	frozen = {
		shell = { color = C(170, 215, 255), transparency = 0.35, material = "Ice" },
		emit = { { at = "feet", texture = "smoke", color = C(225, 242, 255), size = 2.2, rate = 6, lifetime = 1.6, speed = 0.6, rise = 0.4 } },
	},
	dazed = { emit = {
		{ at = "head", texture = "sparkles", color = C(255, 240, 150), size = 0.4, rate = 6, lifetime = 0.8, speed = 0.3, additive = true, orbit = true },
	} },
	blind = { emit = {
		{ at = "head", texture = "smoke", color = C(30, 28, 34), size = 1.2, rate = 8, lifetime = 0.7, speed = 0.3 },
	} },
	irradiated = { emit = {
		{ at = "torso", texture = "mote", color = C(140, 255, 90), size = 0.3, rate = 9, lifetime = 1.4, speed = 1, rise = 1.5, additive = true },
	} },
	silence = { emit = {
		{ at = "head", texture = "ring", color = C(200, 200, 220), size = 1.4, rate = 2, lifetime = 0.6, speed = 0, additive = true },
	} },
	crumbling = { emit = {
		{ at = "torso", texture = "debris", color = C(140, 120, 95), size = 0.3, rate = 7, lifetime = 0.9, speed = 1, rise = -30 },
	} },
	withering = { emit = {
		{ at = "torso", texture = "smoke", color = C(90, 95, 80), size = 1.2, rate = 7, lifetime = 1.3, speed = 0.5, rise = 2.5 },
	} },
	aged = { emit = {
		{ at = "torso", texture = "dust", color = C(200, 185, 150), size = 0.6, rate = 5, lifetime = 1.2, speed = 0.6, rise = -4 },
	} },
	soulmarked = { emit = {
		{ at = "torso", texture = "wisp", color = C(175, 225, 255), size = 0.9, rate = 3, lifetime = 1.6, speed = 0.4, rise = 3, additive = true },
	} },
	sapped = { emit = {
		{ at = "torso", texture = "mote", color = C(150, 120, 200), size = 0.3, rate = 6, lifetime = 1.2, speed = 0.8, rise = -3, additive = true },
	} },
	suffocating = { emit = {
		{ at = "head", texture = "mote", color = C(220, 235, 245), size = 0.3, rate = 6, lifetime = 0.9, speed = 1.5, rise = 4 },
	} },
	jinxed = { emit = {
		{ at = "head", texture = "square", color = C(180, 110, 255), size = 0.3, rate = 5, lifetime = 0.7, speed = 1, additive = true, orbit = true },
	} },
}

return table.freeze({
	looks = looks,
	parts = table.freeze({ "torso", "head", "feet" }),
})
