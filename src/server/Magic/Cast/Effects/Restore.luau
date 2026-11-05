--!strict
--[[
	Restore: vitality, growth and metabolism magic that mends. Heals the characters the form
	reaches, or the caster when it reaches nobody (touch and aura always include the caster).
	Never heals above MaxHealth. A backfire turns it on the caster: a third of the heal as damage.

	Heal = heal.perPower * power ^ heal.exponent.
]]

local Cast = script.Parent.Parent
local T = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local Damage = require(Cast.Damage)

local Restore = {}

function Restore.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	local amount = T.heal.perPower * math.max(0, ctx.power) ^ T.heal.exponent
	local own = ctx.character:FindFirstChildOfClass("Humanoid")

	if ctx.backfire then
		if own then
			Damage.apply(own, amount / 3, ctx.player.UserId, "backfire")
		end
		return { effective = false, hits = 1, harmedSelf = true }
	end

	local targets: { Humanoid } = {}
	for _, hit in Targeting.select(ctx) do
		table.insert(targets, hit.humanoid)
	end
	local form = ctx.stats.recipe.form
	if own and (#targets == 0 or form == "aura" or (form == "touch" and not ctx.target)) then
		table.insert(targets, own)
	end

	local healed = 0
	for _, humanoid in targets do
		if Damage.heal(humanoid, amount, ctx.player.UserId, { domain = ctx.stats.domains[1] }) > 0 then
			healed += 1
		end
	end
	return { effective = healed > 0, hits = healed }
end

return Restore
