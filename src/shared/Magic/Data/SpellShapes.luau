--!strict
--[[
	SpellShapes: how a harmful spell PLAYS, by form and property (docs/SpellOverhaul.md §2B, stage
	3). A shape sits on top of what the spell already does (its route's resolver still lands the
	main hit); it adds a follow-up, a delay with a ground warning, a lingering area, a rain. Read by
	Server/Magic/Cast/Shapes (what happens), Client/Fx/ShapeFx (what it looks like) and the
	Composer (Magic/SpellOutcome says the shape).

	A recipe's shape: byVerb["property.verb"], byProperty[property] or byCategory[category] of its
	form, else the form's `default`. A form with no entry has no shape.

	Shape kinds and their fields
		echo     { delay, share }: the hit lands again `delay` s later on whoever was struck
		split    { count, share, radius }: the bolt breaks on impact; shards fly to up to `count`
		         others within `radius`
		lob      { gravityMult, splash, share }: the bolt flies a high arc and splashes `splash`
		         studs around where it lands
		homing   {}: the bolt turns toward the target (needs a target picked)
		skip     { bounces }: the bolt skips off surfaces
		drain    { back }: you heal `back` of what the beam dealt
		nova     { delay, scale, share }: a second ring `scale` x wider rolls out after `delay`
		linger   { seconds, every, share, warn? }: the area stays and ticks every `every` s
		barrier  { seconds, every }: the area acts on whoever is in it (the property's behaviour,
		         no extra damage)
		erupt    { warn, lift }: a ground warning for `warn` s, then the spell lands where it was
		         marked and throws them up (`lift` studs/s)
		rain     { warn, drops, perPower, radius, share, spread }: warned spots across the area,
		         one drop each: `drops` + power x `perPower` of them
		pulse    { count, every, share }: rings out around you `count` more times

	`share`: each extra hit as a share of the spell's base hit (DamageModel.base), like the
	behaviours' budget. `warn`: seconds of ground warning, shown to everyone near (owner,
	2026-11-13: ground warnings for players' big spells too).
	Only routes in `routes` get a shape (the ones that land damage): control spells such as the water
	freeze stay control (owner, 2026-11-13).
	Tuning status: first pass, not yet played.
]]

export type Shape = { kind: string, [string]: any }
export type FormShapes = { default: Shape?, byCategory: { [string]: Shape }?, byProperty: { [string]: Shape }?, byVerb: { [string]: Shape }? }

local forms: { [string]: FormShapes } = {
	touch = {
		default = { kind = "echo", delay = 0.6, share = 0.45 },
	},
	projectile = {
		-- "property.verb" beats the property, which beats its category; anything unlisted flies as a
		-- plain orb. A cold bolt (temperature reduced) shatters like ice.
		byVerb = {
			["temperature.reduce"] = { kind = "split", count = 3, share = 0.3, radius = 14 },
		},
		byProperty = {
			phase = { kind = "split", count = 3, share = 0.3, radius = 14 },
			sound = { kind = "skip", bounces = 2 },
			resonance = { kind = "split", count = 3, share = 0.3, radius = 14 },
		},
		byCategory = {
			Material = { kind = "lob", gravityMult = 2.6, splash = 7, share = 0.35 },
			Spiritual = { kind = "homing" },
			Vital = { kind = "homing" },
		},
	},
	beam = {
		byCategory = {
			Vital = { kind = "drain", back = 0.35 },
			Spiritual = { kind = "drain", back = 0.25 },
		},
	},
	burst = {
		default = { kind = "nova", delay = 0.35, scale = 1.7, share = 0.4 },
	},
	zone = {
		default = { kind = "linger", seconds = 5, every = 1, share = 0.14, warn = 0.4 },
	},
	wall = {
		default = { kind = "barrier", seconds = 6, every = 1 },
	},
	pillar = {
		default = { kind = "erupt", warn = 0.8, lift = 38 },
	},
	ritual = {
		default = { kind = "rain", warn = 0.9, drops = 3, perPower = 0.6, radius = 5, share = 0.45, spread = 0.9 },
	},
	aura = {
		default = { kind = "pulse", count = 2, every = 1, share = 0.3 },
	},
}

return table.freeze({
	forms = forms,
	-- Routes whose spells get a shape (they land damage); every other route keeps its own behaviour.
	routes = table.freeze({ harm = true, thermal = true, ignite = true, strike = true }),
	kinds = table.freeze({ "echo", "split", "lob", "homing", "skip", "drain", "nova", "linger", "barrier", "erupt", "rain", "pulse" }),
	-- What the Composer says about each shape (Magic/SpellOutcome).
	words = table.freeze({
		echo = "The hit lands again a moment later.",
		split = "It shatters on impact; shards fly to others nearby.",
		lob = "It flies a high arc and splashes where it lands.",
		homing = "It turns toward whoever you aimed at.",
		skip = "It skips off the ground and walls.",
		drain = "You heal part of what it takes.",
		nova = "A second, wider ring rolls out after the first.",
		linger = "The area stays and keeps hurting for a few seconds.",
		barrier = "It stays, and whoever stands in it feels it.",
		erupt = "The ground is marked first, then it erupts and throws them up.",
		rain = "It rains down on marked spots across the area.",
		pulse = "It rings out around you again, and again.",
	}),
	-- Live caps (server): lingering areas and barriers at once, drops per rain.
	caps = table.freeze({ zones = 16, zonesPerPlayer = 3, maxDrops = 9 }),
})
