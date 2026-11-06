--!strict
--[[
	Experiment: the pure rules for "experimentation pays" (docs/EarlyGamePlan.md §8).

		comboKey(recipe) -> "verb|property|form"      what counts as "something new". Not the branch or
		                                              power: raising the power isn't a new idea.
		noveltyXp(found) -> number                    the (found + 1)th new combination's base XP
		suggest(caster, explored, rng) -> raw recipe? a valid spell you haven't tried, or nil

	Saved set: PlayerData.discoveries.novelty (combo -> 1), capped at noveltyCap, in the compressed
	`discoveries` field, so a veteran's save stays bounded. Past the cap new combos simply stop paying.

	Suggestions only ever come from branches the caster has unlocked and are checked with the real
	validator, so they can't reveal a locked branch, a mythic fragment or a hidden latent.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local T = require(script.Parent.ProgressionTuning)

local E = T.experimentation
local MAX_CHECKS = 1500 -- validator calls per suggestion: the worst case for a veteran stays small

local Experiment = {}

function Experiment.comboKey(recipe: { verb: string, property: string, form: string }): string
	return recipe.verb .. "|" .. recipe.property .. "|" .. recipe.form
end

function Experiment.noveltyXp(found: number): number
	return math.max(E.noveltyFloor, E.noveltyBase * E.noveltyDecay ^ math.max(0, found))
end

--[[
	The verbs and forms a save has already used, as firsts keys ("verb:<id>", "form:<id>"), read from
	its recipes ("v|branch|property|verb|form|power|cost|mods") and novelty set ("verb|property|form").
	So a player from before flourishes existed isn't told they've just discovered Generate.
]]
function Experiment.firstsFromSave(discoveries: { [string]: any }): { [string]: number }
	local firsts: { [string]: number } = {}
	for key, at in (discoveries.recipes or {}) :: { [string]: any } do
		local parts = string.split(key, "|")
		if parts[4] and parts[5] then
			firsts["verb:" .. parts[4]] = if typeof(at) == "number" then at else 0
			firsts["form:" .. parts[5]] = if typeof(at) == "number" then at else 0
		end
	end
	for combo in (discoveries.novelty or {}) :: { [string]: any } do
		local parts = string.split(combo, "|")
		if parts[1] and parts[3] then
			firsts["verb:" .. parts[1]] = firsts["verb:" .. parts[1]] or 0
			firsts["form:" .. parts[3]] = firsts["form:" .. parts[3]] or 0
		end
	end
	return firsts
end

local function shuffled(list: { string }, rng: Random): { string }
	local out = table.clone(list)
	for i = #out, 2, -1 do
		local j = rng:NextInteger(1, i)
		out[i], out[j] = out[j], out[i]
	end
	return out
end

function Experiment.suggest(caster: any, explored: { [string]: any }, rng: Random): { [string]: any }?
	local branchIds: { string } = {}
	for _, id in Registry.branchIds do
		local branch = Registry.branches[id]
		-- Never suggest a crime: forbidden branches are there for those who go looking.
		if caster.unlocked[id] and not table.find(branch.tags or {}, "forbidden") then
			table.insert(branchIds, id)
		end
	end
	local verbs, forms = shuffled(Registry.verbIds, rng), shuffled(Registry.formIds, rng)
	local checks = 0
	for _, branchId in shuffled(branchIds, rng) do
		local branch: any = Registry.branches[branchId]
		-- One step under the ceiling: something to try, not an overreach that backfires.
		local power = math.max(1, MagicCore.powerCap(caster, branchId) - 1)
		for _, property in shuffled(branch.properties or branch.ownProperties, rng) do
			for _, verb in verbs do
				for _, form in forms do
					local recipe = { branch = branchId, property = property, verb = verb, form = form, power = power, modifiers = {} }
					if not explored[Experiment.comboKey(recipe)] then
						checks += 1
						if checks > MAX_CHECKS then
							return nil
						end
						local valid = MagicCore.validateRecipe(recipe, caster)
						if valid then
							return recipe
						end
					end
				end
			end
		end
	end
	return nil
end

return Experiment
