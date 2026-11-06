--!strict
--[[
	FirstHour.spec: the first-hour targets (docs/EarlyGamePlan.md §10). Runs a shortened simulation:
	every domain must land its first blow inside the target and have a ranged attack inside its own.
	The full report (firsthoursim) may miss the slower targets: that's information, not a test failure.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
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
