--!strict
--[[
	SpellRoute: which EffectLibrary route a recipe reaches. The one place that decides it, shared so
	CastService (what a cast does) and the Composer (what it says a cast will do) can't disagree.

	SpellRoute.find(recipe) -> Route     first route that matches; `manifest` is the catch-all
]]
local Types = require(script.Parent.Types)
local Registry = require(script.Parent.Registry)
local Strike = require(script.Parent.Strike)
local EffectLibrary = require(script.Parent.Data.EffectLibrary)

export type RecipeLike = { branch: string, property: string, verb: string, form: string, power: number }

local SpellRoute = {}

-- A route's `branches` list matches the recipe's branch, any ancestor of it, or one of its domains.
local function branchMatches(branch: Types.BranchDef, ids: { string }): boolean
	local node: Types.BranchDef? = branch
	while node do
		if table.find(ids, node.id) then
			return true
		end
		local parentId = node.parent
		node = if parentId then Registry.branches[parentId] else nil
	end
	for _, d in branch.domains do
		if table.find(ids, d) then
			return true
		end
	end
	return false
end

function SpellRoute.find(recipe: RecipeLike): EffectLibrary.Route
	local branch = Registry.branches[recipe.branch]
	local property = Registry.properties[recipe.property]
	for _, route in EffectLibrary.routes do
		if route.minPower and recipe.power < route.minPower then
			continue
		elseif route.maxPower and recipe.power > route.maxPower then
			continue
		elseif route.harmful ~= nil and property.harmful ~= route.harmful then
			continue
		elseif route.strike and Strike.routed(recipe) == nil then
			continue
		elseif route.properties and not table.find(route.properties, recipe.property) then
			continue
		elseif route.verbs and not table.find(route.verbs, recipe.verb) then
			continue
		elseif route.forms and not table.find(route.forms, recipe.form) then
			continue
		elseif route.categories and not table.find(route.categories, property.category) then
			continue
		elseif route.branches and not branchMatches(branch, route.branches) then
			continue
		end
		return route
	end
	return EffectLibrary.routes[#EffectLibrary.routes] -- manifest
end

return SpellRoute
