--!strict
--[[
	MagicHealth.spec: your health grows with your magic (docs/SpellOverhaul.md §2F), and the spell
	audit counts every recipe (§2G). What matters most: no magic = no bonus; the best tier pays
	perTier each; breadth counts only OTHER branches at Novice+, capped; Life affinity adds a share;
	more mastery never means less health; and the audit's counts add up.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local MagicHealth = require(Shared.Magic.MagicHealth)
local SpellAudit = require(Shared.Magic.SpellAudit)
local Data = require(Shared.Magic.Data.MagicHealth)

local function caster(mastery: { [string]: number }, life: number?): any
	local unlocked: { [string]: boolean } = {}
	for id in mastery do
		unlocked[id] = true
	end
	return { id = "spec", affinities = { life = life or 0 }, awakened = {}, mastery = mastery, unlocked = unlocked }
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local ids = Registry.branchIds

	describe("Health from magic", function()
		it("no magic gives nothing; the best tier pays perTier each", function()
			local none = MagicHealth.of(caster({}))
			expect(none.flat).toBe(0)
			expect(none.pct).toBe(0)
			local master = MagicHealth.of(caster({ [ids[1]] = 70 }))
			expect(master.best).toBe(MagicCore.tierForMastery(70))
			expect(master.tierFlat).toBe(master.best * Data.perTier)
			expect(master.breadth).toBe(0) -- the best branch never counts as breadth
		end)

		it("breadth counts other branches at Novice or above, up to the cap", function()
			local m: { [string]: number } = { [ids[1]] = 70, [ids[2]] = 10, [ids[3]] = 5 }
			local parts = MagicHealth.of(caster(m))
			local expected = if MagicCore.tierForMastery(5) >= Data.breadthMinTier then 2 else 1
			expect(parts.breadth).toBe(expected)
			local many: { [string]: number } = { [ids[1]] = 70 }
			for i = 2, 40 do
				many[ids[i]] = 30
			end
			expect(MagicHealth.of(caster(many)).breadthFlat).toBe(Data.breadthCap)
		end)

		it("Life affinity adds a share, and more mastery never means less health", function()
			expect(MagicHealth.of(caster({}, 1)).pct).toBe(Data.lifePct)
			expect(MagicHealth.maxFor(caster({}, 0), 100)).toBe(100)
			local last = -1
			for mastery = 0, 100, 5 do
				local hp = MagicHealth.maxFor(caster({ [ids[1]] = mastery }), 100)
				expect(hp >= last).toBe(true)
				last = hp
			end
			expect(last).toBe(100 + 8 * Data.perTier) -- Transcendent, no breadth
		end)
	end)

	describe("Spell audit", function()
		it("counts every recipe of a domain once, by route", function()
			local report = SpellAudit.run({ power = 5, domain = "energy" })
			expect(report.total > 0).toBe(true)
			local sum = 0
			for _, n in report.byRoute do
				sum += n
			end
			expect(sum).toBe(report.total)
			local harm = 0
			for _, n in report.harmByProperty do
				harm += n
			end
			expect(harm).toBe(report.byRoute.harm or 0)
			expect(#SpellAudit.lines(report, 5) >= 4).toBe(true)
		end)
	end)
end
