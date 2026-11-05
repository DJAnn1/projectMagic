--!strict
--[[
	Impact: harmful magic (fire, frost, lightning, blight, crushing weight...). Damages the
	characters the form reaches; area forms strong enough also damage structures.

	Damage per target = Cast/DamageModel (base curve x falloff x resistance x variance x crit, with
	caps; Data/CombatTuning.damage). Chains lose chainFalloff per hop. A backfire deals
	backfireSelfShare of it to the caster. Other players are only hurt with pvp_enabled
	(Targeting.canHarm). Beams of heat or light are lasers: they also heat the first part they
	strike (ThermalSim), which can set it alight.
	Conducting magic (charge) runs on through metal and water (Cast/Conduction); strong area harm
	of a blasting category throws loose and breakable parts (Cast/Explosion).

	Impact.damageFor(power) is the base curve, kept for resolvers that size statuses from it.
]]

local Cast = script.Parent.Parent
local T = require(Cast.Parent.Data.CastTuning)
local C = require(Cast.Parent.Data.CombatTuning)
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local DamageModel = require(Cast.DamageModel)
local ThermalSim = require(Cast.ThermalSim)
local Conduction = require(Cast.Conduction)
local Explosion = require(Cast.Explosion)

local POINT_FORMS: { [string]: boolean } = { touch = true, projectile = true, beam = true, chain = true }

local Impact = {}

function Impact.damageFor(power: number): number
	return DamageModel.base(power)
end

local HEAT_CATEGORIES: { [string]: boolean } = { Thermal = true, Energetic = true }

-- A beam heats the first solid part on its line.
local function laserHeat(ctx: CastTypes.EffectContext, amount: number)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ctx.character }
	local direction = ctx.point - ctx.origin
	if direction.Magnitude < 0.1 then
		return
	end
	local result = workspace:Raycast(ctx.origin, direction + direction.Unit * 2, params)
	local part = result and result.Instance
	if part and part:IsA("BasePart") and not part:IsA("Terrain") and not Targeting.characterOf(part) then
		ThermalSim.addHeat(part, amount)
	end
end

function Impact.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	local stats = ctx.stats

	if ctx.backfire then
		local own = Targeting.select(ctx)[1]
		if own then
			DamageModel.hit(ctx, own, T.backfireSelfShare, "backfire", { noCrit = true, noFalloff = true })
		end
		return { effective = false, hits = 1, harmedSelf = true }
	end

	local dealt = 0
	local struck: { CastTypes.Hit } = {}
	for index, hit in Targeting.select(ctx) do
		if Targeting.canHarm(ctx.player, hit.model) then
			local falloff = if stats.recipe.form == "chain" then C.damage.chainFalloff ^ (index - 1) else nil
			DamageModel.hit(ctx, hit, 1, stats.recipe.property, { falloff = falloff })
			dealt += 1
			table.insert(struck, hit)
		end
	end

	-- Lightning runs on through metal and water (Cast/Conduction).
	local harmedSelf = false
	if Conduction.conducts(stats.recipe.property) then
		local shocked, own = Conduction.spread(ctx, struck)
		dealt += shocked
		harmedSelf = own
	end

	-- Strong area harm throws loose parts (Cast/Explosion).
	local blasted = 0
	if Explosion.applies(stats) then
		blasted = Explosion.blast(ctx.point, Explosion.radiusFor(stats), stats.recipe.power, ctx.character)
	end

	local heated = false
	if stats.recipe.form == "beam" and HEAT_CATEGORIES[stats.category] then
		laserHeat(ctx, T.thermal.heatPerPower * ctx.power)
		heated = true
	end

	local collapsed = 0
	if not POINT_FORMS[stats.recipe.form] and stats.recipe.power >= T.structureDamage.minPower then
		collapsed = ctx.world:damageStructures(ctx.point, stats.area, ctx.power * T.structureDamage.perPower, "spell")
	end
	return { effective = dealt > 0 or collapsed > 0 or heated or blasted > 0, hits = dealt, harmedSelf = harmedSelf }
end

return Impact
