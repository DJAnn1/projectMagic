--!strict
--[[
	SpellHelp.spec: the Composer's explanations (Shared/UI/SpellHelp) must cover the whole grammar,
	so adding a verb, form or modifier without its help text fails here instead of showing a blank.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local SpellHelp = require(Shared.UI.SpellHelp)

return function(t: any)
	t.describe("SpellHelp", function()
		t.it("explains every verb, form and modifier", function()
			for _, id in Registry.verbIds do
				local help = SpellHelp.verbs[id]
				if not help or help.does == "" or help.example == "" then
					error("no help for verb " .. id)
				end
				t.expect(string.find(help.does, "{p}", 1, true) ~= nil).toBe(true)
			end
			for _, id in Registry.formIds do
				local help = SpellHelp.forms[id]
				if not help or help.shape == "" or help.example == "" then
					error("no help for form " .. id)
				end
			end
			for _, id in Registry.modifierIds do
				local help = SpellHelp.modifiers[id]
				if not help or help.plain == "" or help.when == "" then
					error("no help for modifier " .. id)
				end
			end
		end)

		t.it("has no help for parts that don't exist (renamed ids go through Data/Aliases)", function()
			for id in SpellHelp.verbs do
				t.expect(Registry.verbs[id] ~= nil).toBe(true)
			end
			for id in SpellHelp.forms do
				t.expect(Registry.forms[id] ~= nil).toBe(true)
			end
			for id in SpellHelp.modifiers do
				t.expect(Registry.modifiers[id] ~= nil).toBe(true)
			end
		end)

		t.it("explains every Composer step and has a tour and a glossary", function()
			for _, id in { "branch", "property", "verb", "form", "modifiers", "power" } do
				local step = (SpellHelp.steps :: any)[id]
				t.expect(step ~= nil and step.question ~= "" and step.explain ~= "").toBe(true)
			end
			t.expect(#SpellHelp.tour >= 3).toBe(true)
			t.expect(#SpellHelp.glossary >= 5).toBe(true)
		end)

		t.it("describes a whole spell in one plain sentence", function()
			local text = SpellHelp.describe("generate", "Temperature", "projectile", { "homing" }, true)
			t.expect(text).toBe("Makes temperature out of raw power, thrown as a bolt that flies where you aim. Seeks its target. It can hurt what it hits.")
			local sense = SpellHelp.describe("sense", "Vitality", "touch", {}, false)
			t.expect(string.find(sense, "never harms", 1, true) ~= nil).toBe(true)
			-- Unknown ids still read as a sentence (no "nil", no "{p}").
			local odd = SpellHelp.describe("nope", "Weight", "nope", { "nope" }, false)
			t.expect(string.find(odd, "nil", 1, true)).toBe(nil)
			t.expect(string.find(odd, "{p}", 1, true)).toBe(nil)
		end)
	end)
end
