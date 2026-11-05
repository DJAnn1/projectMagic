--!strict
--[[
	CastTypes: the contract between CastService and the effect resolvers in Cast/Effects.

	A resolver is a module with:
		resolve(ctx: EffectContext, params) -> Outcome   required; may yield (disasters do).
		    `params` is the route's params table from Data/EffectLibrary ({} when none).
		measure(world, point, area) -> (Vector3, number)?   optional: where and how wide to
		    measure the world for this spell (Tsunami measures the open sea, not the aim point)
		precheck(params, stats, player) -> reason?   optional: refuse before payment (budgets)

	Resolvers only apply the effect. Payment, cooldowns, XP, discoveries, settlement laws and
	messages to the client all stay in CastService, so a resolver can't forget one.
]]

local Types = require(game:GetService("ReplicatedStorage").Shared.Magic.Types)

-- A character a spell reaches (Targeting re-exports this).
export type Hit = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	distance: number,
}

export type EffectContext = {
	player: Player,
	character: Model,
	root: BasePart,
	stats: Types.SpellStats,
	context: Types.CastContext, -- what the server measured at `point`
	power: number, -- stats.power, or the echo's reduced power
	origin: Vector3, -- the caster's position when the effect resolves
	point: Vector3, -- where the spell lands (the caster, for aura forms and backfires)
	measuredAt: Vector3, -- where the world was measured (resolver.measure; usually `point`)
	target: Model?, -- validated explicit target
	onSurface: boolean, -- the aim point touches something solid (terrain or a part)
	backfire: boolean, -- the spell twisted: it lands on the caster
	delivered: { Hit }?, -- who a projectile flight actually struck (Cast/Delivery); select() uses it
	pulse: number, -- 0 = the cast itself; 1+ = echo or channel pulse
	rng: Random, -- seeded: Seed.random(worldSeed, "player:<id>", "cast", castCounter)
	world: any, -- WorldStateService
	stored: { [string]: { power: number, expires: number } }, -- the caster's stored charges, by property
	runtime: any, -- EffectRunner (fields, presences, dispel, cues)
	services: { reservoirs: any }, -- other services a resolver may need
	speedMult: number?, -- projectile speed from the charge stage (Magic/Charge); nil = 1
}

export type Outcome = {
	effective: boolean, -- it did something real (XP, discoveries and feats only count effective casts)
	hits: number,
	harmedSelf: boolean?, -- the caster was hurt by their own spell (survival facts)
	note: string?, -- a line for the caster (Sense results, "Something stands in the way")
	effectId: number?, -- a durational effect it started (EffectRunner); its presence lives as long
}

export type Resolver = {
	resolve: (ctx: EffectContext, params: { [string]: any }) -> Outcome,
	-- Optional, runs BEFORE payment: a refusal code ("WORLD_STRAINED") when the effect can't run,
	-- so a full budget never eats the caster's reservoir.
	precheck: ((params: { [string]: any }, stats: Types.SpellStats, player: Player) -> string?)?,
	measure: ((world: any, point: Vector3, area: number) -> (Vector3?, number?))?,
}

return {}
