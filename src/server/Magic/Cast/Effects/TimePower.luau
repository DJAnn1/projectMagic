--!strict
--[[
	TimePower: the Time powers (docs/Time.md). `params.power` in Data/EffectLibrary picks one;
	Cast/TimeRuntime keeps it running after the cast.

		self_timeline    mark yourself; N recalls you (and at Grandmaster, death does)
		target_timeline  mark someone; L snaps them back, stunned
		stored           your projectiles hang in the air; L sends them
		timestop         everyone you can harm in the zone freezes, and every projectile in it hangs
		wound            aura: hits on you wait, and cost less. Otherwise: hits on them wait, and cost more
		sight            see where nearby spells are aimed, and sometimes not be there
		loop             a target keeps being snapped back to where it stood

	A backfire lands on the caster, once, with the usual self-share.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Types = require(Shared.Magic.Types)

local Cast = script.Parent.Parent
local C = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)
local DamageModel = require(Cast.DamageModel)
local Targeting = require(Cast.Targeting)
local TimeRuntime = require(Cast.TimeRuntime)

local TimePower = {}

function TimePower.precheck(params: { [string]: any }, _stats: Types.SpellStats, player: Player): string?
	if FeatureFlags.get("time_powers_enabled") ~= true then
		return "WORLD_STRAINED"
	end
	if params.power == "timestop" then
		return TimeRuntime.stopRefusal(player.UserId)
	end
	return nil
end

local function pickTarget(ctx: CastTypes.EffectContext): CastTypes.Hit?
	for _, hit in Targeting.select(ctx) do
		if Targeting.canHarm(ctx.player, hit.model) then
			return hit
		end
	end
	return nil
end

local NO_TARGET = "Nobody there for your time to take hold of."

function TimePower.resolve(ctx: CastTypes.EffectContext, params: { [string]: any }): CastTypes.Outcome
	local power = params.power
	if ctx.backfire then
		local own = Targeting.select(ctx)[1]
		if own then
			DamageModel.hit(ctx, own, C.backfireSelfShare, "backfire", { noCrit = true, noFalloff = true })
		end
		return { effective = false, hits = 1, harmedSelf = true }
	end

	if power == "self_timeline" then
		TimeRuntime.markSelf(ctx)
		return { effective = true, hits = 0, note = "You've marked this moment. N returns you to it." }
	elseif power == "stored" then
		TimeRuntime.startStored(ctx)
		return { effective = true, hits = 0, note = "Your spells will wait. L sends them." }
	elseif power == "timestop" then
		TimeRuntime.startStop(ctx)
		return { effective = true, hits = 0 }
	elseif power == "sight" then
		TimeRuntime.startSight(ctx)
		return { effective = true, hits = 0 }
	elseif power == "wound" and ctx.stats.recipe.form == "aura" then
		local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
		if humanoid then
			TimeRuntime.startWoundOn(ctx, { model = ctx.character, humanoid = humanoid, root = ctx.root, distance = 0 }, true)
		end
		return { effective = true, hits = 0, note = "What happens to you now, you'll pay for later." }
	end

	local hit = pickTarget(ctx)
	if not hit then
		return { effective = false, hits = 0, note = NO_TARGET }
	end
	if power == "target_timeline" then
		TimeRuntime.markTarget(ctx, hit)
		return { effective = true, hits = 1, note = "They're marked. L brings them back here." }
	elseif power == "wound" then
		TimeRuntime.startWoundOn(ctx, hit, false)
		return { effective = true, hits = 1 }
	elseif power == "loop" then
		TimeRuntime.startLoop(ctx, hit)
		return { effective = true, hits = 1 }
	end
	return { effective = false, hits = 0 }
end

return TimePower
