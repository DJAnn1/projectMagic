--!strict
--[[
	SpellShape: which shape a recipe plays with (docs/SpellOverhaul.md §2B, stage 3; data in
	Data/SpellShapes). Pure and shared, so the server (Cast/Shapes) and the Composer
	(Magic/SpellOutcome) always agree.

		SpellShape.of(recipe, routeId) -> Shape?
			nil when the route doesn't land damage (only Data/SpellShapes.routes get shapes) or the
			form has no shape for this property
		SpellShape.words(shape) -> string?   the Composer's line for it
]]

local Registry = require(script.Parent.Registry)
local Data = require(script.Parent.Data.SpellShapes)

local SpellShape = {}

function SpellShape.of(recipe: { form: string, property: string, verb: string? }, routeId: string?): Data.Shape?
	if not routeId or not Data.routes[routeId] then
		return nil
	end
	local byForm = Data.forms[recipe.form]
	if not byForm then
		return nil
	end
	local fromVerb = byForm.byVerb and recipe.verb and byForm.byVerb[recipe.property .. "." .. recipe.verb]
	if fromVerb then
		return fromVerb
	end
	local fromProperty = byForm.byProperty and byForm.byProperty[recipe.property]
	if fromProperty then
		return fromProperty
	end
	local property = Registry.properties[recipe.property]
	local category = property and (property :: any).category
	local fromCategory = category and byForm.byCategory and byForm.byCategory[category]
	if fromCategory then
		return fromCategory
	end
	return byForm.default
end

function SpellShape.words(shape: Data.Shape?): string?
	return if shape then Data.words[shape.kind] else nil
end

return SpellShape
