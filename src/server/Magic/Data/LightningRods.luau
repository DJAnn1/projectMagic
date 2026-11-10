--!strict
--[[
	LightningRods: metal draws lightning (docs/LightningRods.md). Numbers for Cast/LightningRods.

	When a conducting spell (charge) lands, every attractor near the landing point competes with the
	spot it was aimed at. The bolt goes to the strongest:

		stay score       = stay + (pull of the aimed-at character's own metal, if any)
		attractor score  = pull x (1 - distance / radius) ^ falloffPower
		radius           = (radiusBase + radiusPerPower x (power - 1)) x (1 + stormRadius x stormCharge),
		                   capped at radiusMax

	Pull:
		a metal part     clamp(height / partHeightPerPull, partPullMin, partPullMax); parts smaller
		                 than minPartVolume (nails, coins, hinges) don't count. Taller pulls harder.
		a person         clamp(metalWeight / weightPerPull, 0, personPullMax), from worn items tagged
		                 "metal" (summed item weight: chain mail 9, a miner's helm 2) plus a manual
		                 "MetalCarried" attribute. Below minWeight they don't count at all.

	A projectile that struck someone directly is never bent (you hit them). Touch, beam, aura, wall,
	summon and ritual aren't bent either: the spell is in your hand, or isn't a bolt. The caster's
	own metal never draws their own spell.
]]

return table.freeze({
	-- Forms whose landing point can be pulled to metal.
	forms = table.freeze({ projectile = true, burst = true, zone = true, pillar = true, chain = true }) :: { [string]: boolean },

	stay = 0.6,
	radiusBase = 9,
	radiusPerPower = 1.5,
	radiusMax = 30,
	stormRadius = 0.6, -- a full storm stretches the reach by 60% (Data/WeatherFuel's facts)
	falloffPower = 1,

	minPartVolume = 1.5,
	partHeightPerPull = 4, -- a 6-stud lamp post pulls 1.5
	partPullMin = 0.4,
	partPullMax = 3,

	weightPerPull = 6, -- chain mail (9) pulls 1.5
	minWeight = 2,
	personPullMax = 2,

	maxQueryParts = 80, -- spatial query cap per strike
	minBend = 3, -- studs: a bend shorter than this isn't a bend (no cue, no Journal)
})
