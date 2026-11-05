--!strict
--[[
	Thermal: heat as a quantity that moves between things (Cast/ThermalSim), not just damage.

		params.mode = "byVerb"    reduce -> chill, otherwise heat
		            = "ignite"    combustion: set flammable parts and grass alight (FireSim) + burn
		            = "transfer"  draw heat out of one thing and into the things around it
	Energy = thermal.heatPerPower x power (a P1 Candle ≈ 40, a P5 heat bolt ≈ 500).

	heat      the nearest part at the point takes the full energy, others nearby 30%; characters
	          the form reaches take Impact-scale damage (x0.8) and may start Burning; magic ice melts
	chill     the reverse: parts cool, fires go out, characters slow, water surfaces freeze
	ignite    flammable parts near the point and the ground under it catch; characters burn
	transfer  SOURCE: the explicit target, else the nearest part at the point. DESTINATIONS:
	          up to 4 other parts within the spell's area share transferShare of the energy (the
	          rest is lost). With no destination the heat goes into the caster's hands (nothing
	          happens to it). A character as the source is chilled (slow) and hurt a little.
	Backfires burn (heat/ignite) or chill (chill/transfer) the caster.
]]

local Cast = script.Parent.Parent
local World = Cast.Parent.Parent.World
local T = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local Damage = require(Cast.Damage)
local StatusEffects = require(Cast.StatusEffects)
local ThermalSim = require(Cast.ThermalSim)
local FireSim = require(Cast.FireSim)
local EffectBudget = require(Cast.EffectBudget)
local TerrainDeform = require(World.TerrainDeform)
local Impact = require(script.Parent.Impact)
local DamageModel = require(Cast.DamageModel)
local Explosion = require(Cast.Explosion)

local Thermal = {}

local function radiusFor(stats: any): number
	local form = stats.recipe.form
	if form == "touch" then
		return 3
	elseif form == "projectile" or form == "beam" or form == "chain" then
		return 4
	end
	return math.max(stats.area, 4)
end

-- Heats (or with negative energy, cools) the parts at a point: the nearest takes it all.
local function heatParts(point: Vector3, radius: number, energy: number): number
	local parts = ThermalSim.partsNear(point, radius, 8)
	local granted = EffectBudget.takeParts(#parts)
	for i = 1, granted do
		ThermalSim.addHeat(parts[i], if i == 1 then energy else energy * 0.3)
	end
	return granted
end

local function backfire(ctx: CastTypes.EffectContext, hot: boolean): CastTypes.Outcome
	local own = ctx.character:FindFirstChildOfClass("Humanoid")
	if own then
		if hot then
			StatusEffects.apply(own, "burning", { duration = 3, magnitude = Impact.damageFor(ctx.power) * 0.2, source = ctx.player.UserId })
		else
			StatusEffects.apply(own, "slow", { duration = 4 })
		end
		Damage.apply(own, Impact.damageFor(ctx.power) * T.backfireSelfShare * 0.5, ctx.player.UserId, "backfire")
	end
	return { effective = false, hits = 1, harmedSelf = true }
end

local function heat(ctx: CastTypes.EffectContext, energy: number): CastTypes.Outcome
	local stats = ctx.stats
	local radius = radiusFor(stats)
	local touched = heatParts(ctx.point, radius, energy)
	TerrainDeform.meltAt(ctx.point, radius)
	local hits = 0
	if stats.harmful then
		for _, hit in Targeting.select(ctx) do
			if Targeting.canHarm(ctx.player, hit.model) then
				DamageModel.hit(ctx, hit, 0.8, "heat")
				if stats.recipe.power >= 3 then
					StatusEffects.apply(hit.humanoid, "burning", { duration = 2, magnitude = Impact.damageFor(ctx.power) * 0.1, source = ctx.player.UserId })
				end
				hits += 1
			end
		end
	end
	local blasted = if Explosion.applies(stats) then Explosion.blast(ctx.point, Explosion.radiusFor(stats), stats.recipe.power, ctx.character) else 0
	return { effective = touched > 0 or hits > 0 or blasted > 0, hits = hits }
end

local function chill(ctx: CastTypes.EffectContext, energy: number): CastTypes.Outcome
	local stats = ctx.stats
	local radius = radiusFor(stats)
	local affected = heatParts(ctx.point, radius, -energy)
	affected += FireSim.extinguish(ctx.point, radius)
	if TerrainDeform.freeze(ctx.world, ctx.point, math.min(radius, 12), 15) then
		affected += 1
	end
	local hits = 0
	for _, hit in Targeting.select(ctx) do
		if Targeting.canHarm(ctx.player, hit.model) then
			StatusEffects.apply(hit.humanoid, "slow", { duration = 3 + stats.recipe.power * 0.5, source = ctx.player.UserId })
			if stats.harmful then
				DamageModel.hit(ctx, hit, 0.6, "cold")
			end
			hits += 1
		end
	end
	return { effective = affected > 0 or hits > 0, hits = hits }
end

local function ignite(ctx: CastTypes.EffectContext): CastTypes.Outcome
	local stats = ctx.stats
	local radius = radiusFor(stats)
	local intensity = math.clamp(0.5 + stats.recipe.power * 0.15, 0.5, 2)
	local lit = 0
	for _, part in ThermalSim.partsNear(ctx.point, radius, 6) do
		ThermalSim.addHeat(part, T.thermal.heatPerPower * ctx.power)
		if FireSim.ignitePart(part, intensity, ctx.player.UserId) then
			lit += 1
		end
	end
	if FireSim.igniteGround(ctx.point, intensity, ctx.player.UserId) then
		lit += 1
	end
	local hits = 0
	for _, hit in Targeting.select(ctx) do
		if Targeting.canHarm(ctx.player, hit.model) then
			DamageModel.hit(ctx, hit, 0.6, "fire")
			StatusEffects.apply(hit.humanoid, "burning", { duration = T.fire.burnStatusSeconds, magnitude = Impact.damageFor(ctx.power) * 0.15, source = ctx.player.UserId })
			hits += 1
		end
	end
	local blasted = if Explosion.applies(stats) then Explosion.blast(ctx.point, Explosion.radiusFor(stats), stats.recipe.power, ctx.character) else 0
	return { effective = lit > 0 or hits > 0 or blasted > 0, hits = hits }
end

local function transfer(ctx: CastTypes.EffectContext): CastTypes.Outcome
	local stats = ctx.stats
	local energy = T.thermal.heatPerPower * ctx.power

	-- Source: a character target, else the nearest part at the point.
	local sourceHit = if ctx.target then Targeting.characterOf(ctx.target) else nil
	local sourcePart: BasePart? = nil
	if not sourceHit then
		sourcePart = ThermalSim.partsNear(ctx.point, 4, 1)[1]
	end
	if not sourceHit and not sourcePart then
		return { effective = false, hits = 0, note = "There's nothing there to draw warmth from." }
	end

	local hits = 0
	if sourceHit then
		if not Targeting.canHarm(ctx.player, sourceHit.model) then
			return { effective = false, hits = 0, note = "You can't draw warmth from them." }
		end
		StatusEffects.apply(sourceHit.humanoid, "slow", { duration = 3, source = ctx.player.UserId })
		DamageModel.hit(ctx, sourceHit, 0.3, "cold", { noFalloff = true })
		hits = 1
	else
		ThermalSim.addHeat(sourcePart :: BasePart, -energy)
	end

	-- Destinations: other heat-capable parts in the area.
	local origin = if sourceHit then sourceHit.root.Position else (sourcePart :: BasePart).Position
	local destinations: { BasePart } = {}
	for _, part in ThermalSim.partsNear(origin, math.max(stats.area, 6), 5) do
		if part ~= sourcePart and #destinations < 4 then
			table.insert(destinations, part)
		end
	end
	local granted = EffectBudget.takeParts(#destinations)
	for i = 1, granted do
		ThermalSim.addHeat(destinations[i], energy * T.thermal.transferShare / granted)
	end
	return {
		effective = true,
		hits = hits,
		note = if granted == 0 then "You draw the warmth into your hands." else nil,
	}
end

function Thermal.resolve(ctx: CastTypes.EffectContext, params: { [string]: any }): CastTypes.Outcome
	local mode = params.mode
	if mode == "byVerb" then
		mode = if ctx.stats.recipe.verb == "reduce" then "chill" else "heat"
	end
	if ctx.backfire then
		return backfire(ctx, mode == "heat" or mode == "ignite")
	end
	local energy = T.thermal.heatPerPower * ctx.power
	if mode == "chill" then
		return chill(ctx, energy)
	elseif mode == "ignite" then
		return ignite(ctx)
	elseif mode == "transfer" then
		return transfer(ctx)
	end
	return heat(ctx, energy)
end

return Thermal
