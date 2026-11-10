--!strict
--[[
	SpellOutcome: what a recipe will actually do, for the Spell Composer. Pure: routing comes from
	Magic/SpellRoute (the same code CastService uses), the words from Data/RouteSummaries.

		of(recipe)                    -> Outcome          the effect at the recipe's power
		tag(outcome)                  -> "⚔ Attack"
		summarize(templates, match)   -> Summary          what a choice can lead to, at best power
		usefulFrom(recipe)            -> number?          lowest power with a real effect
		steps(recipe, maxPower)       -> { Step }         powers where the effect changes
		modifierProblem(id, outcome)  -> string?          why a modifier would be wasted here
		alternatives(recipe, templates, limit) -> { Alternative }   nearest spells that do something

	Nothing here is secret: it describes the public grammar and its routes.
]]
local Types = require(script.Parent.Types)
local Registry = require(script.Parent.Registry)
local SpellRoute = require(script.Parent.SpellRoute)
local Summaries = require(script.Parent.Data.RouteSummaries)

type RecipeLike = SpellRoute.RecipeLike

export type Outcome = {
	route: string,
	kind: string,
	text: string,
	useful: boolean,
	repeatable: boolean,
	lasts: boolean,
	shape: string?, -- replaces the form's usual wording when the form behaves differently here
}

export type Summary = {
	useful: boolean,
	tag: string, -- at most two kinds, for a tile
	full: string, -- every kind
	first: Outcome?, -- the first matching template's outcome
}

export type Step = { power: number, outcome: Outcome }
export type Alternative = { recipe: RecipeLike, outcome: Outcome }

local SpellOutcome = {}

-- A recipe's route depends only on these five fields, so the answer never goes stale.
local cache: { [string]: Outcome } = {}

function SpellOutcome.of(recipe: RecipeLike): Outcome
	local key = table.concat({ recipe.branch, recipe.property, recipe.verb, recipe.form, tostring(recipe.power) }, "|")
	local cached = cache[key]
	if cached then
		return cached
	end
	local route = SpellRoute.find(recipe)
	local summary = Summaries.routes[route.id] or Summaries.routes.manifest
	local kind, text = summary.kind, summary.text
	local byVerb = summary.byVerb and summary.byVerb[recipe.verb]
	if byVerb then
		kind, text = byVerb.kind or kind, byVerb.text or text
	end
	local byForm = summary.byForm and summary.byForm[recipe.form] -- wins over the verb
	if byForm then
		kind, text = byForm.kind or kind, byForm.text or text
	end
	local shape: string? = nil
	if recipe.form == "summon" or (recipe.form == "wall" and not Summaries.builds[route.id]) then
		shape = Summaries.areaShape
	end
	local outcome: Outcome = {
		route = route.id,
		kind = kind,
		text = text,
		useful = kind ~= "none",
		repeatable = route.repeatable == true,
		lasts = summary.lasts == true,
		shape = shape,
	}
	cache[key] = outcome
	return outcome
end

function SpellOutcome.tag(outcome: Outcome): string
	local kind = Summaries.kinds[outcome.kind]
	return kind.glyph .. " " .. kind.word
end

-- What the templates selected by `match` can do, each at the highest power the caster can reach.
function SpellOutcome.summarize(templates: { Types.RecipeTemplate }, match: (Types.RecipeTemplate) -> boolean): Summary
	local seen: { [string]: boolean } = {}
	local first: Outcome? = nil
	for _, t in templates do
		if match(t) then
			local outcome = SpellOutcome.of({ branch = t.branch, property = t.property, verb = t.verb, form = t.form, power = math.max(1, t.maxPower) })
			first = first or outcome
			seen[outcome.kind] = true
		end
	end
	local words: { string } = {}
	for _, kindId in Summaries.kindOrder do
		if seen[kindId] then
			local kind = Summaries.kinds[kindId]
			table.insert(words, kind.glyph .. " " .. kind.word)
		end
	end
	if #words == 0 then
		local none = Summaries.kinds.none
		local text = none.glyph .. " " .. none.word
		return { useful = false, tag = text, full = text, first = first }
	end
	local tag = table.concat(words, " · ", 1, math.min(2, #words))
	if #words > 2 then
		tag ..= string.format(" +%d", #words - 2)
	end
	return { useful = true, tag = tag, full = table.concat(words, " · "), first = first }
end

local function atPower(recipe: RecipeLike, power: number): RecipeLike
	return { branch = recipe.branch, property = recipe.property, verb = recipe.verb, form = recipe.form, power = power }
end

function SpellOutcome.usefulFrom(recipe: RecipeLike): number?
	for power = Registry.Tuning.MIN_POWER, Registry.Tuning.MAX_POWER do
		if SpellOutcome.of(atPower(recipe, power)).useful then
			return power
		end
	end
	return nil
end

-- Each power above the first where the spell turns into a different effect.
function SpellOutcome.steps(recipe: RecipeLike, maxPower: number): { Step }
	local out: { Step } = {}
	local last: string? = nil
	for power = Registry.Tuning.MIN_POWER, maxPower do
		local outcome = SpellOutcome.of(atPower(recipe, power))
		if last and outcome.route ~= last then
			table.insert(out, { power = power, outcome = outcome })
		end
		last = outcome.route
	end
	return out
end

function SpellOutcome.modifierProblem(modifierId: string, outcome: Outcome): string?
	local dead = Summaries.deadModifiers[modifierId]
	if dead then
		return dead
	elseif (modifierId == "echoing" or modifierId == "channeled") and not outcome.repeatable then
		return Summaries.wasted[modifierId]
	elseif modifierId == "lingering" and not outcome.lasts then
		return Summaries.wasted.lingering
	end
	return nil
end

-- Nearest spells with a real effect: change the form first, then the verb, then the property.
-- One per kind, so the choices are different from each other.
function SpellOutcome.alternatives(recipe: RecipeLike, templates: { Types.RecipeTemplate }, limit: number): { Alternative }
	local function rank(t: Types.RecipeTemplate): number
		if t.property == recipe.property and t.verb == recipe.verb then
			return 1
		end
		return if t.property == recipe.property then 2 else 3
	end
	local out: { Alternative } = {}
	local seen: { [string]: boolean } = {}
	for wanted = 1, 3 do
		for _, t in templates do
			if rank(t) == wanted then
				local candidate = { branch = t.branch, property = t.property, verb = t.verb, form = t.form, power = math.min(recipe.power, math.max(1, t.maxPower)) }
				local outcome = SpellOutcome.of(candidate)
				if outcome.useful and not seen[outcome.kind] then
					seen[outcome.kind] = true
					table.insert(out, { recipe = candidate, outcome = outcome })
					if #out >= limit then
						return out
					end
				end
			end
		end
	end
	return out
end

return SpellOutcome
