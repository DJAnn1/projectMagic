--!strict
--[[
	Wave: a spell-sized wave (Breaker) that rolls from the caster toward the aim. Same simulator as
	the tsunami (World/WaveSimulator) at a fraction of the scale, riding on the ground level where
	it starts (baseLevel) and never writing terrain: clients draw the water from the "wave" cue.
	It knocks down, shoves and damages what stands in it, and breaks weak structures.
	A backfire rolls it back over the caster.
]]

local Cast = script.Parent.Parent
local World = Cast.Parent.Parent.World
local CastTypes = require(Cast.CastTypes)
local WaveSimulator = require(World.WaveSimulator)
local TerrainDeform = require(World.TerrainDeform)

local Wave = {}

function Wave.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	local stats = ctx.stats
	-- On a backfire ctx.point is the caster; the original aim survives in measuredAt.
	local from = if ctx.backfire then ctx.measuredAt else ctx.origin
	local to = if ctx.backfire then ctx.origin else ctx.point
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	local direction = if flat.Magnitude > 0.5 then flat.Unit else ctx.root.CFrame.LookVector
	local width = math.clamp(stats.area * 2, 16, 64)
	local crest = math.clamp(2 + math.sqrt(math.max(0, ctx.power)) * 0.8, 2, 14)
	local reach = math.clamp(stats.range, 20, 120)
	local level = TerrainDeform.surfaceAt(ctx.world, from.X, from.Z) + 1

	ctx.runtime:cue("wave", {
		origin = from,
		direction = direction,
		width = width,
		crest = crest,
		reach = reach,
		caster = ctx.player.UserId,
	}, from, stats.recipe.power >= 6)

	local report = WaveSimulator.run(ctx.world, {
		origin = from - direction * 4,
		direction = direction,
		width = width,
		crest = crest,
		maxRunup = reach,
		maxDistance = reach + 8,
		startAt = 0,
		baseLevel = level,
		writeTerrain = false,
		damagePerStud = 2,
		structurePerStud = 1.5,
		caster = ctx.player,
	})
	return { effective = report.hits > 0 or report.collapsed > 0, hits = report.hits, harmedSelf = ctx.backfire and report.hits > 0 }
end

return Wave
