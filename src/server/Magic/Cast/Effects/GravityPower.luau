--!strict
--[[
	GravityPower: every gravity power that isn't a plain field (docs/Gravity.md). `params.power` in
	Data/EffectLibrary picks one; Cast/GravityRuntime keeps it running after the cast.

		flight        take to the air; lasts until you land, run dry or get dragged down
		grip          pin one target and crush them (the first target you can hurt, of those selected)
		lift          seize one target, raise it, drive it into the ground
		well          drag everyone in reach toward the point; the middle crushes
		singularity   hold a crowd, pull them together, detonate
		orbit         debris that stops hostile projectiles
		bend          a bubble that curves hostile projectiles away, or turns them back
		mass          heavy (amplify: resist damage and hit harder, ignore knockback) or
		              light (reduce: fast, and huge jumps)

	A backfire lands on the caster: their own gravity turns on them, once, with the usual self-share.
	Refusals (nobody to grip, no field slot) cost nothing further and say why in a note.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Types = require(Shared.Magic.Types)
local G = require(Shared.Magic.Data.GravityTuning)
local Rules = require(Shared.Magic.GravityRules)

local Cast = script.Parent.Parent
local T = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)
local DamageModel = require(Cast.DamageModel)
local GravityRuntime = require(Cast.GravityRuntime)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)

local AREA: { [string]: boolean } = { well = true, singularity = true }

local GravityPower = {}

-- The kill switch, and wells and singularities take a mythic field slot: both refuse before payment.
function GravityPower.precheck(params: { [string]: any }, _stats: Types.SpellStats, player: Player): string?
	if FeatureFlags.get("gravity_powers_enabled") ~= true then
		return "WORLD_STRAINED"
	end
	if AREA[params.power] and not GravityRuntime.canStartArea(player.UserId) then
		return "WORLD_STRAINED"
	end
	return nil
end

-- The first selected target this caster may hurt.
local function pickTarget(ctx: CastTypes.EffectContext): CastTypes.Hit?
	for _, hit in Targeting.select(ctx) do
		if Targeting.canHarm(ctx.player, hit.model) then
			return hit
		end
	end
	return nil
end

local function applyMass(ctx: CastTypes.EffectContext): CastTypes.Outcome
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return { effective = false, hits = 0 }
	end
	local tier = ctx.stats.masteryTier
	local seconds = Rules.seconds(G.mass.seconds, G.mass.secondsPerTier, tier)
	if ctx.stats.recipe.verb == "reduce" then
		StatusEffects.remove(humanoid, "gravity_heavy")
		StatusEffects.apply(humanoid, "gravity_light", { duration = seconds, source = ctx.player.UserId })
	else
		StatusEffects.remove(humanoid, "gravity_light")
		StatusEffects.apply(humanoid, "gravity_heavy", {
			duration = seconds,
			source = ctx.player.UserId,
			magnitude = Rules.byTier(G.mass.damage, tier),
			resist = { all = Rules.byTier(G.mass.resist, tier) },
		})
	end
	return { effective = true, hits = 1 }
end

function GravityPower.resolve(ctx: CastTypes.EffectContext, params: { [string]: any }): CastTypes.Outcome
	local power = params.power
	if ctx.backfire then
		local own = Targeting.select(ctx)[1]
		if own then
			DamageModel.hit(ctx, own, T.backfireSelfShare, "backfire", { noCrit = true, noFalloff = true })
		end
		return { effective = false, hits = 1, harmedSelf = true }
	end

	if power == "flight" then
		GravityRuntime.startFlight(ctx)
		return { effective = true, hits = 0, note = "You rise. Space climbs, Shift sinks, Y lands." }
	elseif power == "mass" then
		return applyMass(ctx)
	elseif power == "orbit" then
		GravityRuntime.startOrbit(ctx)
		return { effective = true, hits = 0 }
	elseif power == "bend" then
		GravityRuntime.startBend(ctx)
		return { effective = true, hits = 0 }
	elseif power == "well" then
		if GravityRuntime.startWell(ctx) then
			return { effective = true, hits = 0 }
		end
		return { effective = false, hits = 0, note = "The world won't bend that way again yet." }
	elseif power == "singularity" then
		if GravityRuntime.startSingularity(ctx) then
			return { effective = true, hits = 0 }
		end
		return { effective = false, hits = 0, note = "The world won't bend that way again yet." }
	end

	local hit = pickTarget(ctx)
	if not hit then
		return { effective = false, hits = 0, note = "Nothing there for your gravity to take hold of." }
	end
	local started = if power == "grip" then GravityRuntime.startGrip(ctx, hit) else GravityRuntime.startLift(ctx, hit)
	if not started then
		return { effective = false, hits = 0, note = "They slip your hold: something else has them, or they've only just got free." }
	end
	return { effective = true, hits = 1 }
end

return GravityPower
