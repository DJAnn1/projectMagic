--!strict
--[[
	Elementals.spec: a harmful Summon spell takes a body (docs/SpellOverhaul.md §8, stage 3b). What
	matters: every domain has an elemental and every branch override names a real branch; a branch
	finds its nearest override walking up the tree (hybrids too); strength grows with power and
	mastery but stays inside the health and damage budgets; one at a time, two from Master; only
	damaging summons get a body and the Composer names it; and its own summoner can never hurt it.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local Data = require(Shared.Magic.Data.Elementals)
local Elemental = require(Shared.Magic.Elemental)
local SpellShape = require(Shared.Magic.SpellShape)
local SpellRoute = require(Shared.Magic.SpellRoute)
local SpellOutcome = require(Shared.Magic.SpellOutcome)
local Targeting = require(ServerScriptService.Server.Magic.Cast.Targeting)
local Damage = require(ServerScriptService.Server.Magic.Cast.Damage)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Elementals data", function()
		it("every domain has one, every override names a real branch, every look is valid", function()
			for id in Registry.domains do
				expect(Data.domains[id] ~= nil).toBe(true)
			end
			local function check(def: any)
				expect(Data.styles[def.style] ~= nil).toBe(true)
				local ok = pcall(function()
					return (Enum.Material :: any)[def.material]
				end)
				expect(ok).toBe(true)
				expect((def.transparency or 0) <= 0.7).toBe(true)
				expect(string.find(def.name, "^an? ") ~= nil).toBe(true)
			end
			for _, def in Data.domains do
				check(def)
			end
			for id, def in Data.byBranch do
				expect(Registry.branches[id] ~= nil).toBe(true)
				check(def)
			end
		end)
	end)

	describe("Which elemental a branch gives", function()
		it("walks up to the nearest override, else the domain's own", function()
			expect((Elemental.forBranch("pyromancy"))).toBe(Data.domains.energy)
			expect((Elemental.forBranch("stillfrost"))).toBe(Data.byBranch.cryothermy)
			expect((Elemental.forBranch("ferromancy"))).toBe(Data.byBranch.metallurgy)
			expect((Elemental.forBranch("volcanism"))).toBe(Data.byBranch.magmacraft)
			expect((Elemental.forBranch("earth"))).toBe(Data.domains.earth)
			expect((Elemental.forBranch("singularity")) ~= nil).toBe(true) -- a hybrid with no override
		end)
	end)

	describe("How strong it is", function()
		it("grows with power and mastery, inside the budgets", function()
			local def = Data.domains.earth
			expect(Elemental.health(def, 6, 4) > Elemental.health(def, 3, 4)).toBe(true)
			expect(Elemental.health(def, 6, 6) > Elemental.health(def, 6, 3)).toBe(true)
			local top = 0
			for _, d in Data.domains do
				top = math.max(top, Elemental.health(d, 10, 8))
			end
			for _, d in Data.byBranch do
				top = math.max(top, Elemental.health(d, 10, 8))
			end
			expect(top <= 1000).toBe(true) -- never sturdier than a top-level player (MagicHealth)
			for _, style in Data.styles do
				expect(Elemental.share(style, 8) <= 0.75).toBe(true)
				expect(Elemental.share(style, 8) > Elemental.share(style, 2)).toBe(true)
			end
		end)

		it("one at a time, two from Master", function()
			expect(Elemental.limit(0)).toBe(1)
			expect(Elemental.limit(5)).toBe(1)
			expect(Elemental.limit(6)).toBe(2)
			expect(Elemental.limit(8)).toBe(2)
		end)
	end)

	describe("Summon spells", function()
		it("only damaging summons take a body", function()
			expect((SpellShape.of({ form = "summon", property = "combustion" }, "ignite") :: any).kind).toBe("elemental")
			expect((SpellShape.of({ form = "summon", property = "momentum" }, "harm") :: any).kind).toBe("elemental")
			expect(SpellShape.of({ form = "summon", property = "temperature" }, "freeze")).toBe(nil)
			expect(SpellShape.of({ form = "summon", property = "growth" }, "restore")).toBe(nil)
		end)

		it("the Composer names the elemental instead of an area blast", function()
			local found = 0
			for _, recipe in {
				{ branch = "pyromancy", property = "combustion", verb = "generate", form = "summon", power = 6 },
				{ branch = "geomancy", property = "cohesion", verb = "amplify", form = "summon", power = 6 },
				{ branch = "kinetic", property = "momentum", verb = "generate", form = "summon", power = 6 },
				{ branch = "thermal", property = "temperature", verb = "amplify", form = "summon", power = 6 },
			} do
				local route = SpellRoute.find(recipe)
				local shape = SpellShape.of(recipe, route.id)
				if shape and shape.kind == "elemental" then
					found += 1
					local outcome = SpellOutcome.of(recipe)
					local def = Elemental.forBranch(recipe.branch)
					local name = string.sub(def.name, (string.find(def.name, " ") :: number) + 1)
					expect(string.find(outcome.text, name, 1, true) ~= nil).toBe(true)
					expect(outcome.shape).toBe(nil)
				end
			end
			expect(found >= 1).toBe(true)
		end)
	end)

	describe("Who can hurt it", function()
		it("never its own summoner", function()
			local model = Instance.new("Model")
			local humanoid = Instance.new("Humanoid")
			humanoid.Parent = model
			model:SetAttribute("ElementalOwner", 4242)
			local caster = { UserId = 4242, Character = nil } :: any
			expect(Targeting.canHarm(caster, model)).toBe(false)
			expect(Damage.apply(humanoid, 10, 4242, "elemental", {})).toBe(0)
			model:Destroy()
		end)
	end)
end
