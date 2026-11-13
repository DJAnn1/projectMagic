--!strict
--[[
	Wishes.spec: Reality's conjured beings and world wishes (docs/Reality.md). What matters: every
	being the Composer offers is real and looks valid; the world's materials all raise a real being;
	a Conjuration Summon spell routes to the wish, and only it takes one; a recipe's wish survives
	normalizing, is checked, and changes the key only when present (older keys never move); and the
	plan grows with mastery and power without passing its own limits.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MagicCore = require(Shared.Magic.MagicCore)
local Elementals = require(Shared.Magic.Data.Elementals)
local WishData = require(Shared.Magic.Data.Wishes)
local Wishes = require(Shared.Magic.Wishes)
local SpellRoute = require(Shared.Magic.SpellRoute)
local SpellOutcome = require(Shared.Magic.SpellOutcome)

local function recipe(verb: string, wish: string?): any
	return { v = 1, branch = "conjuration", property = "substance", verb = verb, form = "summon", modifiers = {}, power = 6, costProfile = "reservoir", wish = wish }
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Wishes data", function()
		it("every offered being exists and looks valid", function()
			local count = 0
			for _, group in Wishes.choices() do
				for _, id in group.ids do
					local def = Wishes.being(id)
					expect(def ~= nil).toBe(true)
					expect(Wishes.isValid("being", id)).toBe(true)
					expect(Elementals.styles[(def :: any).style] ~= nil).toBe(true)
					expect(string.find(Wishes.name(id), "^an? ") ~= nil).toBe(true)
					count += 1
				end
			end
			expect(count >= 45).toBe(true)
			for _, def in Elementals.conjured do
				local ok = pcall(function()
					return (Enum.Material :: any)[def.material]
				end)
				expect(ok).toBe(true)
			end
		end)

		it("every material, fire, sky, night and the fallback raise a real being", function()
			for name, id in WishData.materials do
				expect(Wishes.being(id) ~= nil).toBe(true)
				expect(Wishes.fromMaterial(name)).toBe(id)
			end
			for _, id in { WishData.fire, WishData.sky, WishData.night, WishData.fallback } do
				expect(Wishes.being(id) ~= nil).toBe(true)
			end
			expect(Wishes.fromMaterial("NotAMaterial")).toBe(WishData.fallback)
			expect(Wishes.isValid("being", "aim")).toBe(true)
			expect(Wishes.isValid("being", "self")).toBe(true)
			expect(Wishes.isValid("being", "nonsense")).toBe(false)
		end)
	end)

	describe("Wishes routing", function()
		it("Conjuration Summon routes to conjured beings for every allowed verb, and says so", function()
			for _, verb in { "generate", "bind", "transmute" } do
				local r = recipe(verb)
				expect(SpellRoute.find(r).id).toBe("conjure_being")
				expect(Wishes.kindOf(r)).toBe("being")
				local outcome = SpellOutcome.of(r)
				expect(outcome.useful).toBe(true)
				expect(outcome.shape).toBe(nil)
			end
			expect(Wishes.kindOf({ branch = "conjuration", property = "substance", verb = "generate", form = "wall", power = 6 })).toBe(nil)
			expect(Wishes.kindOf({ branch = "pyromancy", property = "combustion", verb = "generate", form = "summon", power = 6 })).toBe(nil)
		end)

		it("a wish survives normalizing, is checked, and only changes the key when present", function()
			local plain = MagicCore.normalizeRecipe(recipe("generate"))
			local wished = MagicCore.normalizeRecipe(recipe("generate", "seraph"))
			expect(plain ~= nil and wished ~= nil).toBe(true)
			expect((wished :: any).wish).toBe("seraph")
			expect((plain :: any).wish).toBe(nil)
			expect(string.find(MagicCore.recipeKey(plain :: any), "|w=", 1, true)).toBe(nil)
			expect(MagicCore.recipeKey(wished :: any) ~= MagicCore.recipeKey(plain :: any)).toBe(true)
			local bad = MagicCore.normalizeRecipe(recipe("generate", string.rep("x", 40)))
			expect(bad).toBe(nil)
			local ok = MagicCore.validateRecipe(recipe("generate", "seraph"))
			expect(ok).toBe(true)
		end)
	end)

	describe("World wishes", function()
		it("every land is a real terrain material and every thing has a name; transmute and amplify areas route to them", function()
			for id, land in WishData.lands do
				local ok, value = pcall(function()
					return (Enum.Material :: any)[land.material]
				end)
				expect(ok and value ~= nil).toBe(true)
				expect(Wishes.isValid("land", id)).toBe(true)
				expect(table.find(WishData.landSources, "Granite")).toBe(nil)
			end
			for id in WishData.things do
				expect(Wishes.isValid("thing", id)).toBe(true)
			end
			expect(Wishes.land(WishData.landDefault) ~= nil and Wishes.thing(WishData.thingDefault) ~= nil).toBe(true)
			for _, form in { "zone", "burst", "ritual" } do
				local land = { branch = "conjuration", property = "substance", verb = "transmute", form = form, power = 6 }
				local thing = { branch = "conjuration", property = "substance", verb = "amplify", form = form, power = 6 }
				expect(SpellRoute.find(land).id).toBe("remake_land")
				expect(SpellRoute.find(thing).id).toBe("conjure_things")
				expect(Wishes.kindOf(land)).toBe("land")
				expect(Wishes.kindOf(thing)).toBe("thing")
				expect(SpellOutcome.of(land).useful and SpellOutcome.of(thing).useful).toBe(true)
				expect(#Wishes.words(land, 5) > 0 and #Wishes.words(thing, 5) > 0).toBe(true)
			end
			expect(Wishes.remakeRadius(10, 8) > Wishes.remakeRadius(1, 1)).toBe(true)
		end)
	end)

	describe("Wishes plan", function()
		it("grows with mastery and power, and never passes its own limit", function()
			local low = Wishes.plan("generate", 4, 1)
			local high = Wishes.plan("generate", 10, 8)
			expect(high.count > low.count).toBe(true)
			expect(high.health > low.health).toBe(true)
			expect(high.seconds > low.seconds).toBe(true)
			expect(high.scale > low.scale).toBe(true)
			for tier = 0, 8 do
				for power = 1, 10 do
					for _, verb in { "generate", "bind", "transmute" } do
						local plan = Wishes.plan(verb, power, tier)
						expect(plan.count >= 1 and plan.count <= plan.limit).toBe(true)
						expect(plan.scale >= 1 and plan.scale <= 3.4).toBe(true)
					end
				end
			end
		end)

		it("bind guards and lasts longer; transmute is one colossus that grows with power", function()
			local guard = Wishes.plan("bind", 6, 6)
			local host = Wishes.plan("generate", 6, 6)
			expect(guard.mode).toBe("guard")
			expect(guard.seconds > host.seconds).toBe(true)
			local small = Wishes.plan("transmute", 3, 6)
			local big = Wishes.plan("transmute", 10, 6)
			expect(big.mode).toBe("colossus")
			expect(big.count).toBe(1)
			expect(big.scale > small.scale).toBe(true)
			expect(big.health > host.health).toBe(true)
			expect(#Wishes.words(recipe("transmute", "colossus"), 8) > 0).toBe(true)
			expect(#Wishes.words(recipe("generate"), 8) > 0).toBe(true)
		end)
	end)
end
