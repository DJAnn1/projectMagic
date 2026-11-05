--!strict
--[[
	Earthquake route: adapts a player's seismic cast to World/Effects/Earthquake (the worked
	example in docs/World.md §9), which deforms terrain, damages structures and characters,
	releases stress and records magic pressure and the "survived earth:self_collapse" fact itself.

	A backfire moves the epicentre under the caster.
]]

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Quake = require(Cast.Parent.Parent.World.Effects.Earthquake)

local MEASURE_RADIUS = 150

local Earthquake = {}

function Earthquake.measure(_world: any, point: Vector3, area: number): (Vector3?, number?)
	return point, math.max(area, MEASURE_RADIUS)
end

function Earthquake.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	local epicenter = if ctx.backfire then ctx.origin else ctx.point
	local report = Quake.resolve(ctx.world, ctx.player, ctx.stats, epicenter, ctx.rng)
	local caught = (ctx.root.Position - epicenter).Magnitude <= report.radius * 0.6
	return { effective = report.ops > 0, hits = report.hits, harmedSelf = caught }
end

return Earthquake
