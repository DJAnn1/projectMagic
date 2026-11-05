--!strict
-- Unit specs for the cast runtime's pure parts: effect routing, the example library, statuses,
-- interactions, budgets and the invariants that keep terrain edits safe.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = ServerScriptService.Server
local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local MagicCore = require(ReplicatedStorage.Shared.Magic.MagicCore)
local SpellExamples = require(ReplicatedStorage.Shared.Magic.Data.SpellExamples)
local EffectLibrary = require(Server.Magic.Data.EffectLibrary)
local CastService = require(Server.Services.CastService)
local Impact = require(Server.Magic.Cast.Effects.Impact)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local InteractionMatrix = require(Server.Magic.Cast.InteractionMatrix)
local EffectBudget = require(Server.Magic.Cast.EffectBudget)
local Biomes = require(Server.World.Biomes)

local function route(recipe: any): string
	local _, errors, normalized = MagicCore.validateRecipe(recipe)
	-- Build the message only on failure: assert evaluates its message eagerly.
	if not normalized then
		error("recipe is invalid: " .. MagicCore.describe(recipe) .. " (" .. (errors[1] and errors[1].code or "?") .. ")", 2)
	end
	return CastService.routeFor(normalized).id
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Effect library", function()
		it("has a resolver module for every route", function()
			for _, r in EffectLibrary.routes do
				expect(Server.Magic.Cast.Effects:FindFirstChild(r.effect) ~= nil).toBe(true)
			end
		end)
		it("ends with the manifest fallback", function()
			expect(EffectLibrary.routes[#EffectLibrary.routes].id).toBe("manifest")
		end)
		it("only names statuses that exist", function()
			for _, r in EffectLibrary.routes do
				local p: { [string]: any } = r.params or {}
				local names: { string } = {}
				if p.status then
					table.insert(names, p.status)
				end
				for _, map in { p.statusByVerb or {}, p.statusByProperty or {} } :: { { [string]: string } } do
					for _, id in map do
						table.insert(names, id)
					end
				end
				for _, id in (p.cleanse or {}) :: { string } do
					table.insert(names, id)
				end
				for _, id in names do
					expect(StatusEffects.defs[id] ~= nil).toBe(true)
				end
			end
		end)
		it("sends disasters to their world resolvers and keeps small ones out", function()
			expect(route(Registry.techniques.cataclysm.recipe)).toBe("earthquake")
			expect(route(Registry.techniques.tsunami.recipe)).toBe("tsunami")
			expect(route({ branch = "seismic", property = "seismicity", verb = "generate", form = "burst", power = 3 })).toBe("tremor")
		end)
		it("routes every technique somewhere", function()
			for _, technique in Registry.techniques do
				local _, _, normalized = MagicCore.validateRecipe(technique.recipe)
				expect(normalized ~= nil).toBe(true)
				if normalized then
					expect(typeof(CastService.routeFor(normalized).effect)).toBe("string")
				end
			end
		end)
	end)

	describe("Spell examples", function()
		it("has at least 4 examples for every domain", function()
			local counts: { [string]: number } = {}
			for _, e in SpellExamples do
				counts[e.domain] = (counts[e.domain] or 0) + 1
			end
			for _, domainId in Registry.domainIds do
				if (counts[domainId] or 0) < 4 then
					error("fewer than 4 spell examples for " .. domainId)
				end
			end
		end)
		it("are valid grammar and reach the effect they claim", function()
			for _, e in SpellExamples do
				local ok, errors, normalized = MagicCore.validateRecipe(e.recipe)
				if not ok or not normalized then
					error(string.format("example %s is invalid: %s", e.name, errors[1] and errors[1].message or "?"))
				end
				local got = CastService.routeFor(normalized).id
				if got ~= e.effect then
					error(string.format("example %s routes to %s, expected %s", e.name, got, e.effect))
				end
			end
		end)
		it("covers the five worked walkthroughs", function()
			local seen: { [string]: boolean } = {}
			for _, e in SpellExamples do
				if e.walkthrough then
					seen[e.walkthrough] = true
				end
			end
			for _, w in { "a", "b", "c", "d", "e" } do
				expect(seen[w] == true).toBe(true)
			end
		end)
	end)

	describe("Interactions", function()
		it("has a handler for every reaction and only uses producible tags", function()
			local producible = InteractionMatrix.producibleTags()
			for _, r in InteractionMatrix.reactions do
				expect(InteractionMatrix.hasHandler(r.result)).toBe(true)
				expect(producible[r.a] == true).toBe(true)
				expect(r.b == "*" or producible[r.b] == true).toBe(true)
			end
		end)
		it("tags water magic as water and air magic as wind", function()
			local function tags(recipe: any): { string }
				local stats, errors = MagicCore.computeStats(recipe, {
					id = "spec",
					affinities = { water = 0.5, air = 0.5, energy = 0.5 },
					awakened = { water = true, air = true, energy = true },
					-- Root-branch mastery: with none, the tier gates refuse even a P1 burst.
					mastery = { water = 30, air = 30, energy = 30 },
				})
				if not stats then
					error("computeStats refused " .. MagicCore.describe(recipe) .. ": " .. (errors[1] and errors[1].code or "?"), 2)
				end
				return InteractionMatrix.tagsFor(stats)
			end
			expect(table.find(tags({ branch = "water", property = "flow", verb = "generate", form = "burst", power = 1 }), "water") ~= nil).toBe(true)
			expect(table.find(tags({ branch = "air", property = "flow", verb = "generate", form = "burst", power = 1 }), "wind") ~= nil).toBe(true)
			expect(table.find(tags({ branch = "energy", property = "temperature", verb = "reduce", form = "burst", power = 1 }), "cold") ~= nil).toBe(true)
		end)
		it("matches water against fire in either order", function()
			local a = { id = 1, tags = { "water" }, position = Vector3.zero, radius = 5, power = 1, expires = math.huge }
			local b = { id = 2, tags = { "fire", "heat" }, position = Vector3.zero, radius = 5, power = 1, expires = math.huge }
			local results: { string } = {}
			for _, r in InteractionMatrix.match(b, a) do
				table.insert(results, r.result)
			end
			expect(table.find(results, "extinguish") ~= nil).toBe(true)
			expect(table.find(results, "steam") ~= nil).toBe(true)
		end)
	end)

	describe("Budgets and safety", function()
		it("refuses slots beyond the limit and gives them back", function()
			local free = EffectBudget.available("heavy")
			for _ = 1, free do
				expect(EffectBudget.acquire("heavy")).toBe(true)
			end
			expect(EffectBudget.acquire("heavy")).toBe(false)
			for _ = 1, free do
				EffectBudget.release("heavy")
			end
			expect(EffectBudget.available("heavy")).toBe(free)
		end)
		it("never grants more parts than asked", function()
			expect(EffectBudget.takeParts(3) <= 3).toBe(true)
		end)
		it("keeps magic stone (Granite) out of every biome, so reverting it is safe", function()
			for _, def in Biomes.defs do
				for _, material in def.materials do
					expect(material ~= Enum.Material.Granite).toBe(true)
				end
			end
		end)
		it("scales damage up with power and keeps P1 gentle", function()
			expect(Impact.damageFor(1) < Impact.damageFor(12)).toBe(true)
			expect(Impact.damageFor(12) < Impact.damageFor(300)).toBe(true)
			expect(Impact.damageFor(0)).toBe(0)
			expect(Impact.damageFor(1) < 10).toBe(true)
		end)
	end)
end
