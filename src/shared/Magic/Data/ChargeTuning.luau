--!strict
--[[
	ChargeTuning: hold-to-charge numbers (docs/Casting.md §8). Shared: the server applies them
	(Services/CastService via Magic/Charge) and the client shows them (cast bar, animation, glow).

	STEP     a spell's charge step = max(castTime, minStep) seconds. Stages are reached at `at`
	         steps of holding. Stage 2 ("Charged") at one step is exactly today's cast: the same
	         power after the same wait, so nothing gets weaker for players who hold to the end.
	STAGES   power      multiplies the spell's power (and so its damage, heal, size of effect)
	         castTime   tap only: the share of the normal cast time still to wait after release
	         area       multiplies the area of forms that scale area (formScales)
	         speed      multiplies projectile speed (forms that scale speed)
	         targets    extra targets for forms that scale targets (chain)
	         overcharge past the safe stage: + backfireAdd backfire chance, cost x costMult
	HOLD     at maxSteps the client releases on its own; the server never counts more than
	         maxSteps, and drops a charge nobody releases within releaseGrace after that.
]]

export type Stage = {
	id: string,
	name: string,
	glyph: string, -- the cast bar shows glyph + name (never colour alone)
	at: number, -- steps of holding to reach it
	power: number,
	castTime: number?, -- tap only
	area: number?,
	speed: number?,
	targets: number?,
	overcharge: boolean?,
}

local ChargeTuning = {
	stages = {
		{ id = "tap", name = "Quick", glyph = "·", at = 0, power = 0.75, castTime = 0.5 },
		{ id = "charged", name = "Charged", glyph = "◆", at = 1, power = 1.0 },
		{ id = "full", name = "Full", glyph = "◆◆", at = 2, power = 1.25, area = 1.15, speed = 1.1, targets = 1 },
		{ id = "over", name = "Overcharged", glyph = "⚠", at = 3, power = 1.5, area = 1.3, speed = 1.2, targets = 1, overcharge = true },
	} :: { Stage },
	minStep = 0.35, -- seconds: instant spells still have stages you can feel
	maxChargeableCastTime = 3, -- spells slower than this cast normally (no charge, no tap penalty)
	maxSteps = 4.5, -- the client auto-releases here; the server counts no further
	releaseGrace = 1.0, -- seconds after maxSteps before the server drops an unreleased charge
	releaseTime = 0.15, -- seconds from release to effect for a charged cast (the release motion)
	overcharge = { backfireAdd = 0.12, costMult = 1.5 },
	walkMult = 0.6, -- walk speed while charging
	-- Which extra scalars each form takes from its stage (power always applies).
	formScales = {
		projectile = { speed = true },
		chain = { targets = true },
		burst = { area = true },
		zone = { area = true },
		pillar = { area = true },
		wall = { area = true },
		aura = { area = true },
		ritual = { area = true },
		summon = { area = true },
	} :: { [string]: { [string]: boolean } },
	-- Channelled spells (the channeled modifier): the aim sweeps toward the cursor at this rate.
	channelTurnDegreesPerSecond = 90,
}

return ChargeTuning
