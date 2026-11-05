--!strict
-- Unit specs for hold-to-charge (Shared/Magic/Charge, Data/ChargeTuning) and the charging pose.
-- docs/Casting.md §8.

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Charge = require(ReplicatedStorage.Shared.Magic.Charge)
local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local ActionRules = require(ReplicatedStorage.Shared.Magic.ActionRules)
local CombatAnimations = require(ReplicatedStorage.Shared.Magic.Data.CombatAnimations)

local D = Charge.data

-- The fields Charge.apply touches, on a fresh table per test.
local function stats(form: string, castTime: number): any
	return {
		recipe = { form = form },
		power = 10,
		castTime = castTime,
		area = 8,
		maxTargets = 3,
		cost = 20,
		costBreakdown = { reservoir = 20 },
		backfireChance = 0.05,
	}
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Charge stages", function()
		it("orders stages by hold time and ends at the overcharge", function()
			for i = 2, #D.stages do
				expect(D.stages[i].at > D.stages[i - 1].at).toBe(true)
				expect(D.stages[i].power >= D.stages[i - 1].power).toBe(true)
			end
			expect(D.stages[#D.stages].overcharge).toBe(true)
			expect(D.maxSteps > D.stages[#D.stages].at).toBe(true)
		end)
		it("reaches each stage at its step, and never past the max hold", function()
			local castTime = 0.8
			local step = Charge.step(castTime)
			expect(Charge.stageIndex(0, castTime)).toBe(1)
			expect(Charge.stageIndex(step * 0.99, castTime)).toBe(1)
			expect(Charge.stageIndex(step, castTime)).toBe(2)
			expect(Charge.stageIndex(step * 2, castTime)).toBe(3)
			expect(Charge.stageIndex(999, castTime)).toBe(#D.stages)
			expect(Charge.step(0.05)).toBe(D.minStep)
		end)
		it("keeps a held-to-'Charged' cast exactly as strong as today's cast", function()
			local s = stats("projectile", 0.8)
			local applied = Charge.apply(s, 2, 0.8)
			expect(s.power).toBe(10)
			expect(s.castTime).toBe(D.releaseTime)
			expect(applied.speedMult).toBe(1)
		end)
		it("makes a tap weaker but quicker", function()
			local s = stats("projectile", 0.8)
			Charge.apply(s, 1, 0.1)
			expect(s.power < 10).toBe(true)
			expect(s.castTime).toBeNear(0.8 * D.stages[1].castTime - 0.1, 1e-6)
		end)
		it("scales area, targets and speed only for forms that take them", function()
			local burst = stats("burst", 0.8)
			Charge.apply(burst, 3, 1.6)
			expect(burst.area > 8).toBe(true)
			expect(burst.maxTargets).toBe(3)
			local chain = stats("chain", 0.8)
			Charge.apply(chain, 3, 1.6)
			expect(chain.maxTargets).toBe(4)
			expect(chain.area).toBe(8)
			local bolt = stats("projectile", 0.8)
			expect(Charge.apply(bolt, 3, 1.6).speedMult > 1).toBe(true)
		end)
		it("charges overcharge in cost and backfire risk", function()
			local s = stats("beam", 0.8)
			Charge.apply(s, #D.stages, 3)
			expect(s.cost).toBe(20 * D.overcharge.costMult)
			expect(s.costBreakdown.reservoir).toBe(20 * D.overcharge.costMult)
			expect(s.backfireChance).toBeNear(0.05 + D.overcharge.backfireAdd, 1e-6)
		end)
		it("doesn't charge slow spells", function()
			expect(Charge.chargeable(0.8)).toBe(true)
			expect(Charge.chargeable(20)).toBe(false)
		end)
		it("only names real forms", function()
			for form in D.formScales do
				expect(Registry.forms[form] ~= nil).toBe(true)
			end
		end)
	end)

	describe("Charging pose", function()
		it("freezes CastSpell at a marker the clip has", function()
			local charging = CombatAnimations.states.charging
			expect(charging.animation).toBe("CastSpell")
			expect(ActionRules.markerFraction("CastSpell", charging.holdAt :: string) ~= nil).toBe(true)
		end)
		it("resumes the rest of the clip within the speed clamp", function()
			local speed = ActionRules.resumeSpeed("CastSpell", 0.63, 0.65, 0.35)
			expect(speed >= CombatAnimations.minSpeed and speed <= CombatAnimations.maxSpeed).toBe(true)
		end)
		it("lets a channel end into holding", function()
			expect(ActionRules.canEnter("channeling", "holding")).toBe(true)
			expect(ActionRules.allows("channeling", "cast")).toBe(false)
		end)
	end)
end
