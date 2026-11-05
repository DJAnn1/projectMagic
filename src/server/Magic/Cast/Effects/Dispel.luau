--!strict
--[[
	Dispel: Void magic that unmakes magic. Ends every effect in the area that isn't the caster's
	own: fields, fires, statuses on characters, magic walls and lights, magic ice
	(EffectRunner:dispelArea). The counter to everything else in the library.
	A backfire strips the caster's own statuses instead (wards included).
]]

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local StatusEffects = require(Cast.StatusEffects)

local Dispel = {}

function Dispel.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	if ctx.backfire then
		local own = ctx.character:FindFirstChildOfClass("Humanoid")
		local removed = if own then StatusEffects.dispel(own) else 0
		return { effective = false, hits = removed, note = "The void turns inward and strips your own workings." }
	end
	local count = ctx.runtime:dispelArea(ctx.point, math.max(ctx.stats.area, 6), ctx.player.UserId)
	return { effective = count > 0, hits = count, note = if count == 0 then "Nothing here to unmake." else nil }
end

return Dispel
