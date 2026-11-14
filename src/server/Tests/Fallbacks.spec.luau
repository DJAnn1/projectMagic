--!strict
--[[
	Fallbacks.spec: stage 1c (docs/SpellOverhaul.md §12). What matters: every property in
	Data/PropertyFallbacks is real and non-harmful and has an entry for every verb; every status it
	names is real; and every one of those property-verb pairs now reaches a useful effect, as a
	touch and as a zone, on a branch that carries the property (more specific routes may win, which
	is fine: they're useful too).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local Data = require(Shared.Magic.Data.PropertyFallbacks)
local StatusInfo = require(Shared.Magic.Data.StatusInfo)
local SpellRoute = require(Shared.Magic.SpellRoute)
local SpellOutcome = require(Shared.Magic.SpellOutcome)

local function branchesFor(property: string): { string }
	local out: { string } = {}
	for _, id in Registry.branchIds do
		if table.find(Registry.branches[id].properties, property) then
			table.insert(out, id)
		end
	end
	return out
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Stage 1c fallbacks", function()
		it("every property is real and non-harmful, with every verb, and every status is real", function()
			for property, verbs in Data.list do
				local def = Registry.properties[property]
				expect(def ~= nil).toBe(true)
				expect(def and def.harmful).toBe(false)
				for _, verb in Data.verbs do
					local entry = verbs[verb]
					expect(entry ~= nil).toBe(true)
					if entry then
						expect((StatusInfo :: any)[entry.status] ~= nil).toBe(true)
						expect(#entry.words > 0).toBe(true)
						expect(entry.on == nil or entry.on == "foe" or entry.on == "friend").toBe(true)
					end
				end
			end
		end)

		it("every property and verb reaches a useful effect, as a touch and as a zone, on every branch carrying it", function()
			local misses: { string } = {}
			local checked = 0
			for property in Data.list do
				local branches = branchesFor(property)
				expect(#branches > 0).toBe(true)
				for _, branch in branches do
					for _, verb in Data.verbs do
						for _, form in { "touch", "zone" } do
							local recipe = { branch = branch, property = property, verb = verb, form = form, power = 5 }
							checked += 1
							if not SpellOutcome.of(recipe).useful then
								table.insert(misses, string.format("%s %s %s %s -> %s", branch, property, verb, form, SpellRoute.find(recipe).id))
							end
						end
					end
				end
			end
			t.log(string.format("stage 1c: %d pairs checked, %d dead", checked, #misses))
			if #misses > 0 then
				t.log("stage 1c misses: " .. table.concat(misses, "; "))
			end
			expect(#misses).toBe(0)
		end)
	end)
end
