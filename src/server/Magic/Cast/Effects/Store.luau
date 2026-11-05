--!strict
--[[
	Store: the caster captures a charge of the property and holds it (CastTuning.storedChargeSeconds).
	Verbs with requirement "Stored" (Release) need a held charge of the same property;
	CastService checks and consumes it before paying. Storing again replaces the charge.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local Cast = script.Parent.Parent
local T = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)

local Store = {}

function Store.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	if ctx.backfire then
		return { effective = false, hits = 0, note = "The charge slips out of your grasp." }
	end
	local propertyId = ctx.stats.recipe.property
	ctx.stored[propertyId] = { power = ctx.power, expires = workspace:GetServerTimeNow() + T.storedChargeSeconds }
	return { effective = true, hits = 0, note = string.format("You hold a charge of %s.", string.lower(Registry.properties[propertyId].name)) }
end

return Store
