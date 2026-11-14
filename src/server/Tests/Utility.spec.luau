--!strict
--[[
	Utility.spec: stage 1b, the properties that did nothing (docs/SpellOverhaul.md §11). What
	matters: each property and verb the stage targets now reaches a real effect (not `manifest`)
	as a touch and as an area, every status the new routes name is real, and the Composer calls
	them useful. It also logs how much of these 14 properties still falls through, for the record
	(`spellaudit` gives the whole picture).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local EffectLibrary = require(Shared.Magic.Data.EffectLibrary)
local StatusInfo = require(Shared.Magic.Data.StatusInfo)
local SpellRoute = require(Shared.Magic.SpellRoute)
local SpellOutcome = require(Shared.Magic.SpellOutcome)

-- property -> verbs this stage gave an effect (any branch carrying the property, touch and zone).
local TARGETED: { [string]: { string } } = {
	presence = { "reduce", "transmute", "generate", "amplify" },
	density = { "generate", "amplify", "reduce" },
	humidity = { "amplify", "reduce" },
	perception = { "generate", "amplify", "reduce", "transmute" },
	warding = { "reduce", "transmute", "bind", "transfer", "redirect", "release" },
	growth = { "reduce", "transmute", "release", "redirect" },
	hardness = { "reduce" },
	viscosity = { "generate", "amplify", "reduce" },
	distance = { "reduce", "generate", "amplify", "release", "redirect", "transfer" },
	emotion = { "amplify", "transmute", "transfer", "redirect", "bind" },
	aether = { "generate", "amplify", "transfer", "release" },
	buoyancy = { "generate", "amplify", "reduce" },
	contour = { "generate", "amplify" },
	purity = { "generate", "amplify", "transmute", "reduce" },
}

-- A branch that carries this property, preferring one outside Gravity (its own powers come first).
local function branchFor(property: string): string?
	local fallback: string? = nil
	for _, id in Registry.branchIds do
		local branch = Registry.branches[id]
		if table.find(branch.properties, property) then
			if not table.find(branch.domains, "gravity") then
				return id
			end
			fallback = fallback or id
		end
	end
	return fallback
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Stage 1b utility", function()
		it("every status a stage 1b route names is real", function()
			for _, route in EffectLibrary.routes do
				local params = route.params :: any
				if params and (params.targetsByForm or params.reservoir or params.extinguish) then
					if params.status then
						expect((StatusInfo :: any)[params.status] ~= nil).toBe(true)
					end
					for _, id in (params.statusByVerb or {}) :: { [string]: string } do
						expect((StatusInfo :: any)[id] ~= nil).toBe(true)
					end
				end
			end
		end)

		it("each targeted property and verb reaches a real effect, as a touch and as an area", function()
			local misses: { string } = {}
			for property, verbs in TARGETED do
				local branch = branchFor(property)
				expect(branch ~= nil).toBe(true)
				for _, verb in verbs do
					-- Contour's stone rises from point forms; everything else is checked as a zone too.
					local forms = if property == "contour" then { "projectile" } else { "touch", "zone" }
					for _, form in forms do
						local recipe = { branch = branch :: string, property = property, verb = verb, form = form, power = 5 }
						local route = SpellRoute.find(recipe)
						if route.id == "manifest" or not SpellOutcome.of(recipe).useful then
							table.insert(misses, string.format("%s %s %s %s -> %s", tostring(branch), property, verb, form, route.id))
						end
					end
				end
			end
			if #misses > 0 then
				t.log("stage 1b misses: " .. table.concat(misses, "; "))
			end
			expect(#misses).toBe(0)
		end)

		it("logs how much of the old pile still does nothing (every grammar-valid recipe, power 5)", function()
			local total, manifest = 0, 0
			for _, branchId in Registry.branchIds do
				local branch = Registry.branches[branchId]
				for _, property in branch.properties do
					if not TARGETED[property] then
						continue
					end
					local category = Registry.properties[property].category
					for _, verb in Registry.verbIds do
						if Registry.verbs[verb].minTier > branch.tier or Registry.verbPropertyEff[verb][property] <= 0 then
							continue
						end
						for _, form in Registry.formIds do
							local f = Registry.forms[form]
							if f.minTier > branch.tier or Registry.formVerbEff[form][verb] <= 0 or Registry.formCategoryBlocked[form][category] then
								continue
							end
							total += 1
							if SpellRoute.find({ branch = branchId, property = property, verb = verb, form = form, power = 5 } :: any).id == "manifest" then
								manifest += 1
							end
						end
					end
				end
			end
			t.log(string.format("stage 1b: %d of %d recipes on the 14 old-pile properties still do nothing (%.1f%%)", manifest, total, if total > 0 then manifest / total * 100 else 0))
			expect(total > 0).toBe(true)
		end)
	end)
end
