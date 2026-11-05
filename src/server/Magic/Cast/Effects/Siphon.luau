--!strict
--[[
	Siphon: drink another's life (and, from a player, their reservoir). Half the health taken
	heals the caster; half the reservoir taken refills theirs (never above max). A harmful act:
	other players only with pvp_enabled. A backfire drains the caster's own reservoir.
]]

local Players = game:GetService("Players")

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)

local Siphon = {}

function Siphon.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	local reservoirs = ctx.services.reservoirs
	local own = ctx.character:FindFirstChildOfClass("Humanoid")
	local mine = reservoirs:get(ctx.player)
	if ctx.backfire then
		if mine then
			mine.current -= mine.max * 0.1
			reservoirs:push(ctx.player)
		end
		return { effective = false, hits = 0, note = "The siphon runs the wrong way." }
	end

	local target: Targeting.Hit? = nil
	for _, hit in Targeting.select(ctx, 1) do
		if Targeting.canHarm(ctx.player, hit.model) then
			target = hit
			break
		end
	end
	if not target then
		return { effective = false, hits = 0, note = "Nothing there to drink from." }
	end

	local taken = DamageModel.hit(ctx, target, 0.6, "siphon", { noFalloff = true })
	if own then
		Damage.heal(own, taken * 0.5, ctx.player.UserId, { domain = ctx.stats.domains[1] })
	end
	local drained = 0
	local victim = Players:GetPlayerFromCharacter(target.model)
	local theirs = victim and reservoirs:get(victim)
	if victim and theirs and mine then
		drained = math.clamp(ctx.stats.recipe.power * 3, 0, math.max(0, theirs.current))
		theirs.current -= drained
		mine.current = math.min(mine.max, mine.current + drained * 0.5)
		reservoirs:push(victim)
		reservoirs:push(ctx.player)
	end
	return { effective = taken > 0 or drained > 0, hits = 1 }
end

return Siphon
