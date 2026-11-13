--!strict
--[[
	Wishes: the rules behind Reality's wishes (docs/Reality.md "Conjured beings"). Pure and shared,
	so the server (Cast/Conjuring), the Composer and Tests/Wishes.spec always agree.

		Wishes.kindOf(recipe) -> "being"?             does this recipe take a wish?
		Wishes.being(id) -> (Elemental?, domain?)     a being by wish id (nil for "aim"/"self")
		Wishes.isValid(kind, id) -> boolean
		Wishes.fromMaterial(name) -> id               what "aim" raises from a material
		Wishes.plan(verb, power, tier) -> Plan        how many, how big, how strong, how long
		Wishes.name(id) -> string                     "a frost wight", "what you aim at"...
		Wishes.words(recipe, tier) -> string          the Composer's line
		Wishes.choices() -> { {name, ids} }           the Composer's groups

	Tiers are mastery in the spell's branch, 1 (Sensing) to 8 (Transcendent); 0 counts as 1.
]]

local SpellRoute = require(script.Parent.SpellRoute)
local Elementals = require(script.Parent.Data.Elementals)
local Data = require(script.Parent.Data.Wishes)
local R = require(script.Parent.Data.RealityTuning)

local S = R.summon

export type Plan = {
	mode: string, -- "host" | "guard" | "colossus"
	count: number,
	limit: number,
	scale: number, -- x the being's own scale
	health: number, -- x its health
	blow: number, -- x each blow
	seconds: number,
}

local Wishes = {}

local ROUTE_KINDS: { [string]: string } = {
	conjure_being = "being",
}

function Wishes.kindOf(recipe: any): string?
	if not (recipe and recipe.branch and recipe.property and recipe.verb and recipe.form) then
		return nil
	end
	local ok, route = pcall(SpellRoute.find, recipe)
	return if ok and route then ROUTE_KINDS[route.id] else nil
end

function Wishes.being(id: string): (Elementals.Elemental?, string?)
	local conjured = (Elementals.conjured :: any)[id]
	if conjured then
		return conjured, conjured.domain
	end
	local byDomain = Elementals.domains[id]
	if byDomain then
		return byDomain, id
	end
	local byBranch = Elementals.byBranch[id]
	if byBranch then
		return byBranch, nil -- the caller finds the branch's domain (Registry)
	end
	return nil, nil
end

function Wishes.isValid(kind: string, id: string): boolean
	if kind == "being" then
		return id == "aim" or id == "self" or (Wishes.being(id)) ~= nil
	end
	return false
end

function Wishes.fromMaterial(name: string): string
	return (Data.materials :: any)[name] or Data.fallback
end

local function byTier(list: { number }, tier: number): number
	return list[math.clamp(math.floor(tier), 1, #list)]
end

function Wishes.plan(verb: string, power: number, tier: number): Plan
	local t = math.max(1, tier)
	local p = math.clamp(math.floor(power), 1, 10)
	local seconds = byTier(S.seconds, t)
	local limit = byTier(S.limit, t)
	if verb == "transmute" then
		local c = S.colossus
		return {
			mode = "colossus",
			count = 1,
			limit = limit,
			scale = math.min(c.maxScale, c.scaleBase + p * c.scalePerPower),
			health = byTier(S.health, t) * c.health,
			blow = byTier(S.blow, t) * c.blow,
			seconds = seconds,
		}
	end
	local guard = verb == "bind"
	local count = byTier(if guard then S.guardians else S.host, t)
	for at, extra in S.extraFromPower do
		if p >= at then
			count += extra
		end
	end
	count = math.min(count, limit)
	local grow = if p >= S.growFromPower then 1 + (p - 8) * S.growPerPower else 1
	return {
		mode = if guard then "guard" else "host",
		count = count,
		limit = limit,
		scale = grow,
		health = byTier(S.health, t),
		blow = byTier(S.blow, t),
		seconds = if guard then seconds * S.guardSeconds else seconds,
	}
end

function Wishes.name(id: string?): string
	if id == nil or id == "aim" then
		return "what you aim at"
	elseif id == "self" then
		return "a double of you"
	end
	local def = Wishes.being(id)
	return if def then def.name else "what you aim at"
end

local MODE_WORDS: { [string]: string } = {
	host = "%s rise where you aim and fight beside you",
	guard = "%s rise where you aim and hold that ground",
	colossus = "%s rises where you aim, immense, and fights beside you",
}

function Wishes.words(recipe: any, tier: number): string
	local plan = Wishes.plan(recipe.verb, recipe.power or 1, tier)
	local wish = recipe.wish or "aim"
	local who: string
	if wish == "aim" then
		who = if plan.count > 1 then string.format("%d of whatever you aim at", plan.count) else "Whatever you aim at"
	elseif plan.count > 1 then
		who = string.format("%d of %s", plan.count, Wishes.name(wish))
	else
		who = Wishes.name(wish)
	end
	who = string.upper(string.sub(who, 1, 1)) .. string.sub(who, 2)
	local line = string.format(MODE_WORDS[plan.mode] or MODE_WORDS.host, who)
	line ..= string.format(" for %d s (%d of yours at once).", math.floor(plan.seconds), plan.limit)
	if wish == "aim" then
		line ..= " Lava gives fire, water a tide spirit, metal an iron golem, the sky a gale; a creature or a person gives a double of them."
	end
	return line
end

function Wishes.choices(): { { name: string, ids: { string } } }
	return Data.groups :: any
end

return Wishes
