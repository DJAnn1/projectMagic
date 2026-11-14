--!strict
--[[
	Evolutions.spec: spells grow with mastery and verbs have flavours (docs/SpellOverhaul.md §9,
	stage 4). What matters: every behaviour has a finisher, and every status a finisher or a verb
	names is real; shape growth only touches numbers the shapes have, comes at Expert and again at
	Transcendent, and never changes the shared data; flavours only on the plain-damage route; and the
	Composer's lines open up as mastery rises.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Data = require(Shared.Magic.Data.Evolutions)
local Behaviours = require(Shared.Magic.Data.PropertyBehaviours)
local ShapeData = require(Shared.Magic.Data.SpellShapes)
local StatusInfo = require(Shared.Magic.Data.StatusInfo)
local Evolution = require(Shared.Magic.Evolution)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Evolutions data", function()
		it("every behaviour has a finisher, and every status named is real", function()
			for id in Behaviours do
				expect(Data.finishers[id] ~= nil).toBe(true)
			end
			for id, finisher in Data.finishers do
				expect(Behaviours[id] ~= nil).toBe(true)
				expect((StatusInfo :: any)[finisher.needs] ~= nil).toBe(true)
				if finisher.status then
					expect((StatusInfo :: any)[finisher.status.id] ~= nil).toBe(true)
				end
				expect(finisher.share ~= nil or finisher.status ~= nil).toBe(true)
				expect((finisher.share or 0) <= 1).toBe(true)
			end
			for _, flavour in Data.verbs do
				if flavour.status then
					expect((StatusInfo :: any)[flavour.status.id] ~= nil).toBe(true)
				end
				expect((flavour.share or 1) >= 0.8 and (flavour.share or 1) <= 1.25).toBe(true)
			end
		end)

		it("shape growth only names real shape kinds", function()
			for kind in Data.shapeGrowth do
				expect(table.find(ShapeData.kinds, kind) ~= nil).toBe(true)
				expect(Data.shapeWords[kind] ~= nil).toBe(true)
			end
		end)
	end)

	describe("Evolution rules", function()
		it("a shape grows at Expert and again at Transcendent, without touching the data", function()
			local split = ShapeData.forms.projectile.byProperty.phase
			local before = split.count
			expect(Evolution.shape(split, 4).count).toBe(before)
			expect(Evolution.shape(split, 5).count).toBe(before + 2)
			expect(Evolution.shape(split, 8).count).toBe(before + 4)
			expect(split.count).toBe(before)
			expect(Evolution.shape(nil, 8)).toBe(nil)
		end)

		it("Master and Grandmaster open at their tiers; flavours only on plain damage", function()
			expect(Evolution.masterReady(5)).toBe(false)
			expect(Evolution.masterReady(6)).toBe(true)
			expect(Evolution.finisherReady(6)).toBe(false)
			expect(Evolution.finisherReady(7)).toBe(true)
			expect(Evolution.finisherMult(8) > Evolution.finisherMult(7)).toBe(true)
			expect(Evolution.flavour("amplify", "harm") ~= nil).toBe(true)
			expect(Evolution.flavour("amplify", "thermal")).toBe(nil)
			expect(Evolution.behaviourFor({ property = "temperature", verb = "reduce" }, "thermal")).toBe("cold")
			expect(Evolution.behaviourFor({ property = "phase", verb = "amplify" }, "harm")).toBe("heat")
			expect(Evolution.behaviourFor({ property = "sound", verb = "generate" }, "manifest")).toBe(nil)
		end)

		it("the Composer's lines open up as mastery rises", function()
			local recipe = { verb = "amplify" }
			local shape = ShapeData.forms.projectile.byProperty.phase
			local function reached(tier: number): number
				local n = 0
				for _, line in Evolution.lines(recipe, "harm", shape, "phase", tier) do
					if line.reached then
						n += 1
					end
				end
				return n
			end
			expect(#Evolution.lines(recipe, "harm", shape, "phase", 1)).toBe(5)
			expect(reached(1)).toBe(1) -- the verb's flavour is always yours
			expect(reached(5)).toBe(2)
			expect(reached(7)).toBe(4)
			expect(reached(8)).toBe(5)
		end)
	end)
end
