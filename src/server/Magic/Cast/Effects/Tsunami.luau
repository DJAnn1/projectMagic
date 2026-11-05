--!strict
--[[
	Tsunami route: adapts a player's Tsunamancy working to World/Effects/Tsunami (docs/World.md §10).

	The caster aims at the coast they want the sea to strike. `measure` finds the nearest open sea
	to that point and backs off 200 studs so the wave has water to build over; CastService
	measures the world there (waterVolume) and refuses the cast when there's no open sea in reach.
	The wave then travels from that origin toward the aim point.

	A backfire turns the wave toward the caster.
]]

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Wave = require(Cast.Parent.Parent.World.Effects.Tsunami)

local MEASURE_RADIUS = 400
local BACK_OFF = 200

local Tsunami = {}

function Tsunami.measure(world: any, point: Vector3, _area: number): (Vector3?, number?)
	local origin = Wave.findOpenSea(world, point)
	if not origin then
		return nil, nil
	end
	local back = Vector3.new(origin.X - point.X, 0, origin.Z - point.Z)
	if back.Magnitude > 0 then
		origin += back.Unit * BACK_OFF
	end
	return origin, MEASURE_RADIUS
end

function Tsunami.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	local target = if ctx.backfire then ctx.origin else ctx.point
	ctx.world:requestArea(target.X, target.Z, 1)
	local report = Wave.resolve(ctx.world, ctx.player, ctx.stats, ctx.measuredAt, target)
	if not report.ok then
		return { effective = false, hits = 0, note = "The sea won't answer here: " .. tostring(report.reason) }
	end
	return { effective = true, hits = report.hits, harmedSelf = ctx.backfire }
end

return Tsunami
