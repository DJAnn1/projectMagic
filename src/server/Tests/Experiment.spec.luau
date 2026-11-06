--!strict
--[[
	Experiment.spec: experimentation pays (docs/EarlyGamePlan.md §8). Novelty XP falls and can't be
	farmed; suggestions are valid, unexplored, seeded and run out; every domain gets one at Sensing.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local MagicCore = require(ReplicatedStorage.Shared.Magic.MagicCore)
local AudioLibrary = require(ReplicatedStorage.Shared.Audio.AudioLibrary)
local Experiment = require(ServerScriptService.Server.Progression.Experiment)
local T = require(ServerScriptService.Server.Progression.ProgressionTuning)
local InteractionMatrix = require(ServerScriptService.Server.Magic.Cast.InteractionMatrix)

local E = T.experimentation

local function sensingCaster(domainId: string): any
	local sensing = Registry.masteryTiers.tiers[2].minMastery
	return {
		id = "spec_experiment_" .. domainId,
		affinities = { [domainId] = 0.5 },
		awakened = { [domainId] = true },
		mastery = { [domainId] = sensing },
		unlocked = { [domainId] = true },
	}
end

return function(t: any)
	t.describe("Experiment", function()
		t.it("pays less for each new combination, never below the floor", function()
			t.expect(Experiment.noveltyXp(0)).toBe(E.noveltyBase)
			local last = Experiment.noveltyXp(0)
			for found = 1, 200 do
				local xp = Experiment.noveltyXp(found)
				t.expect(xp <= last and xp >= E.noveltyFloor).toBe(true)
				last = xp
			end
			t.expect(Experiment.noveltyXp(100000)).toBe(E.noveltyFloor)
		end)

		t.it("caps what novelty can ever pay", function()
			local total = 0
			for found = 0, E.noveltyCap - 1 do
				total += Experiment.noveltyXp(found)
			end
			-- Base XP before multipliers: a nudge, not a way to skip the curve.
			t.log(string.format("  novelty over the whole cap: %.0f base XP", total))
			t.expect(total < 3000).toBe(true)
		end)

		t.it("suggests a valid spell for every domain at Sensing", function()
			for _, domainId in Registry.domainIds do
				local caster = sensingCaster(domainId)
				local recipe = Experiment.suggest(caster, {}, Random.new(11))
				if not recipe then
					error(domainId .. ": nothing to suggest at Sensing")
				end
				t.expect((MagicCore.validateRecipe(recipe, caster))).toBe(true)
			end
		end)

		t.it("gives the same suggestion from the same seed", function()
			local caster = sensingCaster("energy")
			local a = Experiment.suggest(caster, {}, Random.new(42)) :: any
			local b = Experiment.suggest(caster, {}, Random.new(42)) :: any
			t.expect(Experiment.comboKey(a)).toBe(Experiment.comboKey(b))
		end)

		t.it("never repeats what you've tried, and runs out", function()
			local caster = sensingCaster("energy")
			local explored: { [string]: any } = {}
			local rng = Random.new(3)
			local steps = 0
			while steps < 500 do
				local recipe = Experiment.suggest(caster, explored, rng)
				if not recipe then
					break
				end
				local key = Experiment.comboKey(recipe :: any)
				t.expect(explored[key]).toBe(nil)
				explored[key] = 1
				steps += 1
			end
			t.expect(steps > 0 and steps < 500).toBe(true)
		end)

		t.it("only suggests branches you've unlocked", function()
			local caster = sensingCaster("earth")
			for seed = 1, 20 do
				local recipe = Experiment.suggest(caster, {}, Random.new(seed)) :: any
				t.expect(recipe.branch).toBe("earth")
			end
		end)

		t.it("reads the verbs and forms an old save already used", function()
			local recipe = { branch = "energy", property = "temperature", verb = "generate", form = "touch", power = 2, modifiers = {} }
			local _, _, normalized = MagicCore.validateRecipe(recipe)
			local key = MagicCore.recipeKey(normalized :: any)
			local firsts = Experiment.firstsFromSave({ recipes = { [key] = 500 }, novelty = { ["sense|temperature|aura"] = 1 } })
			t.expect(firsts["verb:generate"]).toBe(500)
			t.expect(firsts["form:touch"]).toBe(500)
			t.expect(firsts["verb:sense"] ~= nil).toBe(true)
			t.expect(firsts["form:aura"] ~= nil).toBe(true)
			t.expect(firsts["verb:reduce"]).toBe(nil)
			t.expect(firsts.damage).toBe(nil) -- never inferred: a save can't show it
		end)

		t.it("starts a brand new save with no firsts", function()
			t.expect(next(Experiment.firstsFromSave({ recipes = {}, novelty = {} }))).toBe(nil)
		end)

		t.it("has a stinger for first-time flourishes", function()
			t.expect(AudioLibrary.get("sting.first") ~= nil).toBe(true)
		end)

		t.it("has a description for every reaction, for the discovery toast", function()
			for _, reaction in InteractionMatrix.reactions do
				t.expect(reaction.description ~= "" and reaction.result ~= "").toBe(true)
			end
		end)
	end)
end
