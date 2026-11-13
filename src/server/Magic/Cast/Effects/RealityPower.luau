--!strict
--[[
	RealityPower: the Reality powers (docs/Reality.md). `params.power` in Data/EffectLibrary picks one;
	Cast/RealityRuntime keeps it running after the cast.

		favor        luck bends your way: crits, grazes, fewer backfires
		doom         a target's luck turns
		certainty    your next hits on a target are guaranteed crits
		twist        charges that cancel a hit and send it back
		conjure      matter from nothing (shape by form: step, bridge, wall, pillar, bastion)
		summon       conjured beings: any elemental, Reality's own giants, doubles (Cast/Conjuring)
		remake       the ground in an area becomes the wished material, saved (Cast/WorldWishes)
		things       wished things appear for a while: forest, fire, lights... (Cast/WorldWishes)
		cage         a solid box around a target
		unmake       matter in reach stops existing for a while; people lose wards and are hit
		undying      nothing takes you below 1 health for a few seconds
		fray         a target takes more damage
		polymorph    a target becomes a small harmless creature. With nobody there, it falls back to
		             the older object transmutation (the reality field)
		exchange     you and a target swap health percentages
		edict        a local law by verb (params.worldlaw: over a region)

	A backfire lands on the caster, once, with the usual self-share.
	Refusals before payment: the kill switch, a cooldown, and the edict caps.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Types = require(Shared.Magic.Types)
local Rules = require(Shared.Magic.RealityRules)

local Cast = script.Parent.Parent
local C = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)
local DamageModel = require(Cast.DamageModel)
local Targeting = require(Cast.Targeting)
local RealityRuntime = require(Cast.RealityRuntime)
local Field = require(script.Parent.Field)
local Conjuring = require(Cast.Conjuring)
local WorldWishes = require(Cast.WorldWishes)

local RealityPower = {}

function RealityPower.precheck(params: { [string]: any }, _stats: Types.SpellStats, player: Player): string?
	if FeatureFlags.get("reality_powers_enabled") ~= true then
		return "WORLD_STRAINED"
	end
	local power = params.power
	if power == "undying" or power == "exchange" then
		return RealityRuntime.cooldownRefusal(power, player.UserId)
	elseif power == "edict" then
		return RealityRuntime.edictRefusal(player.UserId, params.worldlaw == true)
	elseif power == "summon" and FeatureFlags.get("elementals_enabled") == false then
		return "WORLD_STRAINED"
	elseif power == "remake" then
		return WorldWishes.remakeRefusal(player.UserId)
	end
	return nil
end

-- The first selected target this caster may affect.
local function pickTarget(ctx: CastTypes.EffectContext): CastTypes.Hit?
	for _, hit in Targeting.select(ctx) do
		if Targeting.canHarm(ctx.player, hit.model) then
			return hit
		end
	end
	return nil
end

local NO_TARGET = "Nobody there for reality to take hold of."

function RealityPower.resolve(ctx: CastTypes.EffectContext, params: { [string]: any }): CastTypes.Outcome
	local power = params.power
	if ctx.backfire then
		local own = Targeting.select(ctx)[1]
		if own then
			DamageModel.hit(ctx, own, C.backfireSelfShare, "backfire", { noCrit = true, noFalloff = true })
		end
		return { effective = false, hits = 1, harmedSelf = true }
	end

	-- Powers on yourself, or on the world.
	if power == "favor" then
		return { effective = RealityRuntime.startFavor(ctx), hits = 0, note = "Luck leans your way." }
	elseif power == "twist" then
		return { effective = RealityRuntime.startTwist(ctx), hits = 0, note = "Fate will turn the next blows back." }
	elseif power == "undying" then
		return { effective = RealityRuntime.startUndying(ctx), hits = 0, note = "For a moment, you can't stop existing." }
	elseif power == "edict" then
		local kind = Rules.edictKind(ctx.stats.recipe.verb)
		if not kind then
			return { effective = false, hits = 0 }
		end
		RealityRuntime.startEdict(ctx, kind, params.worldlaw == true)
		return { effective = true, hits = 0 }
	elseif power == "conjure" then
		local parts, why = RealityRuntime.conjure(ctx)
		return { effective = parts > 0, hits = 0, note = why }
	elseif power == "unmake" then
		local parts, hits = RealityRuntime.unmake(ctx)
		return { effective = parts > 0 or hits > 0, hits = hits }
	elseif power == "summon" then
		-- Conjured beings (Cast/Conjuring): whatever the wish asks for, or what the aim finds.
		local raised, note = Conjuring.summon(ctx)
		return { effective = raised > 0, hits = 0, note = note }
	elseif power == "remake" then
		local ops, note = WorldWishes.remake(ctx)
		return { effective = ops > 0, hits = 0, note = note }
	elseif power == "things" then
		local made, note = WorldWishes.things(ctx)
		return { effective = made > 0, hits = 0, note = note }
	end

	local hit = pickTarget(ctx)
	if not hit then
		if power == "polymorph" then
			-- Nobody to change: change the things there instead, as Transmute always did.
			return Field.resolve(ctx, { field = "reality", ruleByProperty = { identity = "transmute" } })
		end
		return { effective = false, hits = 0, note = NO_TARGET }
	end
	if power == "doom" then
		RealityRuntime.startDoom(ctx, hit)
	elseif power == "certainty" then
		RealityRuntime.startCertainty(ctx, hit)
	elseif power == "fray" then
		RealityRuntime.startFray(ctx, hit)
	elseif power == "cage" then
		if not RealityRuntime.cage(ctx, hit) then
			return { effective = false, hits = 0, note = "The world won't hold any more of that right now." }
		end
	elseif power == "polymorph" then
		if not RealityRuntime.startPolymorph(ctx, hit) then
			return { effective = false, hits = 0, note = "Their shape won't take another change yet." }
		end
	elseif power == "exchange" then
		if not RealityRuntime.exchange(ctx, hit) then
			return { effective = false, hits = 0, note = "You'd gain nothing from that trade." }
		end
	else
		return { effective = false, hits = 0 }
	end
	return { effective = true, hits = 1 }
end

return RealityPower
