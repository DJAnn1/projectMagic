--!strict
--[[
	Wishes: the rules behind Reality's wishes (docs/Reality.md "Conjured beings"). Pure and shared,
	so the server (Cast/Conjuring), the Composer and Tests/Wishes.spec always agree.

		Wishes.kindOf(recipe) -> "being"|"land"|"thing"?   does this recipe take a wish, and which
		Wishes.being(id) -> (Elemental?, domain?)     a being by wish id (nil for "aim"/"self")
		Wishes.isValid(kind, id) -> boolean
		Wishes.fromMaterial(name) -> id               what "aim" raises from a material
		Wishes.plan(verb, power, tier) -> Plan        how many, how big, how strong, how long
		Wishes.name(id, kind?) -> string              "a frost wight", "what you aim at", "lava"...
		Wishes.words(recipe, tier) -> string          the Composer's line
		Wishes.choices(kind?) -> { {name, ids} }      the Composer's groups (beings by default)
		Wishes.land(id) / Wishes.thing(id)            a land or thing wish's data (nil if unknown)
		Wishes.remakeRadius(power, tier) / Wishes.default(kind)

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
	remake_land = "land",
	conjure_things = "thing",
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

function Wishes.land(id: string?): { name: string, material: string }?
	return if id then (Data.lands :: any)[id] else nil
end

function Wishes.thing(id: string?): { name: string }?
	return if id then (Data.things :: any)[id] else nil
end

function Wishes.default(kind: string): string
	return if kind == "land" then Data.landDefault elseif kind == "thing" then Data.thingDefault else "aim"
end

function Wishes.isValid(kind: string, id: string): boolean
	if kind == "being" then
		return id == "aim" or id == "self" or (Wishes.being(id)) ~= nil
	elseif kind == "land" then
		return Wishes.land(id) ~= nil
	elseif kind == "thing" then
		return Wishes.thing(id) ~= nil
	end
	return false
end

function Wishes.remakeRadius(power: number, tier: number): number
	local base = R.remake.radius[math.clamp(math.floor(math.max(1, tier)), 1, #R.remake.radius)]
	return base * (0.6 + math.clamp(power, 1, 10) * 0.08)
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

function Wishes.name(id: string?, kind: string?): string
	if kind == "land" then
		local land = Wishes.land(id or Data.landDefault)
		return if land then land.name else "green grass"
	elseif kind == "thing" then
		local thing = Wishes.thing(id or Data.thingDefault)
		return if thing then thing.name else "a forest"
	end
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
	local kind = Wishes.kindOf(recipe)
	if kind == "land" then
		local r = Wishes.remakeRadius(recipe.power or 1, tier)
		return string.format(
			"The ground for %d studs around where you aim becomes %s, for good, on every server. Never inside a town; once every %d s.",
			math.floor(r), Wishes.name(recipe.wish, "land"), R.remake.cooldown[math.clamp(math.max(1, tier), 1, 8)]
		)
	elseif kind == "thing" then
		local t = math.clamp(math.max(1, tier), 1, 8)
		return string.format("%s appears for %d studs around where you aim, for %d s.",
			(string.gsub(Wishes.name(recipe.wish, "thing"), "^%l", string.upper)), R.things.radius[t], R.things.seconds[t])
	end
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

local function sortedIds(map: { [string]: any }): { string }
	local ids: { string } = {}
	for id in map do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end

function Wishes.choices(kind: string?): { { name: string, ids: { string } } }
	if kind == "land" then
		return { { name = "The ground becomes", ids = sortedIds(Data.lands) } }
	elseif kind == "thing" then
		return { { name = "What appears", ids = sortedIds(Data.things) } }
	end
	return Data.groups :: any
end

return Wishes
