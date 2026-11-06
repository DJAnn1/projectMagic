--!strict
--[[
	FirstHour.spec: the first-hour targets (docs/EarlyGamePlan.md §10). Runs a shortened simulation:
	every domain must land its first blow inside the target and have a ranged attack inside its own.
	The full report (firsthoursim) may miss the slower targets: that's information, not a test failure.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local MagicCore = require(ReplicatedStorage.Shared.Magic.MagicCore)
local Server = ServerScriptService.Server
local FirstHour = require(Server.Progression.FirstHour)
local Progression = require(Server.Progression.Progression)
local FirstHourSim = require(Server.Tests.FirstHourSim)

return function(t: any)
	t.describe("First hour", function()
		t.it("lets every domain land its first blow and first ranged hit in time, at the weakest gift", function()
			for _, domainId in Registry.domainIds do
				local row: any = FirstHourSim.run(domainId, "Modest", { minutes = 12 })
				if not row.damage or row.damage > FirstHour.TARGETS.damage then
					error(domainId .. ": first damage at " .. FirstHour.format(row.damage))
				end
				if not row.ranged or row.ranged > FirstHour.TARGETS.ranged then
					error(domainId .. ": first ranged damage at " .. FirstHour.format(row.ranged))
				end
				t.log(string.format("  %s: damage %s, ranged %s, %.1f casts/min", domainId, FirstHour.format(row.damage), FirstHour.format(row.ranged), row.castsPerMinute))
			end
		end)

		t.it("discounts only Time's and Reality's power 1 attacks", function()
			local function cost(domainId: string, verb: string, form: string, power: number, modifiers: { string }?): number
				local caster: any = {
					id = "spec_innate_" .. domainId,
					affinities = { [domainId] = 0.5 },
					awakened = { [domainId] = true },
					mastery = { [domainId] = 60 }, -- comfortable at power 2: no overreach in the numbers
					unlocked = { [domainId] = true },
				}
				local property = Registry.strikes[domainId].property
				local stats = MagicCore.computeStats({ branch = domainId, property = property, verb = verb, form = form, power = power, modifiers = modifiers or {} }, caster)
				if not stats then
					error(string.format("%s %s %s P%d doesn't validate", domainId, verb, form, power))
				end
				return (stats :: any).cost
			end
			local growth = Registry.Tuning.costGrowth
			-- Power 2 pays full price, so P2 / P1 shows the discount, whatever else goes into the cost.
			for domainId, full in { time = 1.6 * 2.0, reality = 1.8 * 2.2 } do
				local factor = 2.24 / full
				for _, form in { "touch", "projectile" } do
					t.expect(cost(domainId, "generate", form, 2) / cost(domainId, "generate", form, 1)).toBeNear(growth / factor, 0.05)
				end
				-- Another verb on the same property isn't the Strike.
				t.expect(cost(domainId, "sense", "touch", 2) / cost(domainId, "sense", "touch", 1)).toBeNear(growth, 0.05)
				-- A modifier takes it off the discount: compare with what the modifier alone would do.
				local efficient = Registry.modifiers.efficient.costMult
				t.expect(cost(domainId, "generate", "projectile", 1, { "efficient" }) / cost(domainId, "generate", "projectile", 1)).toBeNear(efficient / factor, 0.05)
			end
			-- A domain without the field is untouched.
			t.expect(cost("energy", "generate", "projectile", 2) / cost("energy", "generate", "projectile", 1)).toBeNear(growth, 0.05)
		end)

		t.it("doesn't let the beginner lesson reach Novice by itself", function()
			local novice = Registry.masteryTiers.tiers[3].minMastery
			t.expect(Progression.masteryForXp(FirstHourSim.lessonXp()) < novice).toBe(true)
		end)

		t.it("judges a row against the targets, fairly to players still on the way", function()
			local on = { damage = 60, ranged = 200 }
			t.expect(#FirstHour.misses(on, 300)).toBe(0) -- the slower targets haven't come due
			local misses = FirstHour.misses({ damage = 500 }, 700)
			t.expect(table.find(misses, "damage") ~= nil).toBe(true)
			t.expect(table.find(misses, "ranged") ~= nil).toBe(true)
			t.expect(table.find(misses, "novice")).toBe(nil)
		end)

		t.it("compares a domain with Energy", function()
			t.expect(FirstHour.tooSlow(100, 100)).toBe(false)
			t.expect(FirstHour.tooSlow(125, 100)).toBe(false)
			t.expect(FirstHour.tooSlow(126, 100)).toBe(true)
			t.expect(FirstHour.tooSlow(nil, 100)).toBe(true)
			t.expect(FirstHour.tooSlow(nil, nil)).toBe(false)
		end)

		t.it("takes a median", function()
			t.expect(FirstHour.median({})).toBe(nil)
			t.expect(FirstHour.median({ 5 })).toBe(5)
			t.expect(FirstHour.median({ 9, 1, 5 })).toBe(5)
			t.expect(FirstHour.median({ 1, 2, 3, 4 })).toBe(2.5)
		end)
	end)
end
