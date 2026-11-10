--!strict
--[[
	BreakTheCharge.spec: hurt enough while holding a charge and your focus breaks
	(docs/BreakTheCharge.md). What matters most: a novice breaks at a tenth of their health, mastery
	steadies you up to a cap, overcharged is half as steady, and nothing breaks without real harm.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Charge = require(ReplicatedStorage.Shared.Magic.Charge)
local Flags = require(ServerScriptService.Server.Config.Flags)

local F = Charge.data.focus

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Breaking the charge", function()
		it("a novice's focus breaks at a tenth of their health, not before", function()
			expect(Charge.focusBreaks(9.9, 100, 0, false)).toBe(false)
			expect(Charge.focusBreaks(10, 100, 0, false)).toBe(true)
		end)

		it("mastery steadies you, up to a cap", function()
			expect(Charge.focusLimit(4, false) > Charge.focusLimit(0, false)).toBe(true)
			expect(Charge.focusLimit(8, false) > Charge.focusLimit(4, false)).toBe(true)
			expect(Charge.focusLimit(100, false)).toBe(F.shareMax)
		end)

		it("overcharged is half as steady", function()
			for _, tier in { 0, 3, 8 } do
				expect(math.abs(Charge.focusLimit(tier, true) - Charge.focusLimit(tier, false) * F.overchargeMult) < 1e-9).toBe(true)
			end
			-- A grandmaster overcharging is about as fragile as a novice holding a plain charge.
			expect(Charge.focusLimit(8, true) < Charge.focusLimit(0, false) * 1.2).toBe(true)
		end)

		it("nothing breaks without harm, or with no health to measure", function()
			expect(Charge.focusBreaks(0, 100, 0, true)).toBe(false)
			expect(Charge.focusBreaks(-20, 100, 0, true)).toBe(false)
			expect(Charge.focusBreaks(50, 0, 0, false)).toBe(false)
		end)

		it("has a flag and a short lockout", function()
			expect((Flags :: any).charge_break_enabled ~= nil).toBe(true)
			expect(F.lockout > 0 and F.lockout <= 2).toBe(true)
		end)
	end)
end
