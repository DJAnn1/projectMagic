--!strict
--[[
	Strike: is this recipe its domain's first attack (Data/Strikes)? Shared so the server's
	routing (CastService.routeFor -> the `strike` route), MagicCore's `harmful` flag and the
	Composer's "Strike" line all agree.

		Strike.find(recipe)   -> (domainId?, StrikeDef?)  the recipe is a strike, native or not
		Strike.routed(recipe) -> (domainId?, StrikeDef?)  ...and it goes through the strike route
		Strike.formsOf(def)   -> { string }              the forms it can take

	A recipe is a strike when one of its branch's domains has a strike on the recipe's property,
	with one of its verbs, in one of its forms. Hybrid branches match through either domain.
]]
local Types = require(script.Parent.Types)
local Registry = require(script.Parent.Registry)

type StrikeDef = Types.StrikeDef

local DEFAULT_FORMS = { "touch", "projectile", "beam", "chain" }

local Strike = {}

-- Forms a strike can take: its own list or the default, minus forms that block its category.
local formsCache: { [StrikeDef]: { string } } = {}
function Strike.formsOf(def: StrikeDef): { string }
	local cached = formsCache[def]
	if cached then
		return cached
	end
	local category = Registry.properties[def.property].category
	local out: { string } = {}
	for _, f in def.forms or DEFAULT_FORMS do
		if not Registry.formCategoryBlocked[f][category] then
			table.insert(out, f)
		end
	end
	formsCache[def] = out
	return out
end

type RecipeLike = { branch: string, property: string, verb: string, form: string }

function Strike.find(recipe: RecipeLike): (string?, StrikeDef?)
	local branch = Registry.branches[recipe.branch]
	if not branch then
		return nil, nil
	end
	for _, domainId in branch.domains do
		local def = Registry.strikes[domainId]
		if def and def.property == recipe.property and table.find(def.verbs, recipe.verb) and table.find(Strike.formsOf(def), recipe.form) then
			return domainId, def
		end
	end
	return nil, nil
end

function Strike.routed(recipe: RecipeLike): (string?, StrikeDef?)
	local domainId, def = Strike.find(recipe)
	if def and not def.native then
		return domainId, def
	end
	return nil, nil
end

return Strike
