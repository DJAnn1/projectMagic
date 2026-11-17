--!strict
--[[
	Weight.spec: how casts and hits feel (docs/Smoothness.md stage 6). What matters most: the cancel
	window lets a cast's last moments be cut into a dash, block or slash and nothing earlier, the
	hit-stop and flinch stay brief and small, the step stays within a short distance, and nothing
	here turns the camera (there is no camera setting in the data at all).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ActionRules = require(Shared.Magic.ActionRules)
local Weight = require(Shared.Magic.Data.Weight)

local function castingSnapshot(untilTime: number): ActionRules.Snapshot
	return { state = "casting", untilTime = untilTime, duration = 0.8, domain = nil, variant = nil, seq = 1 }
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Weight", function()
		it("lets only a cast's last moments be cut short", function()
			local now = 100
			local early = castingSnapshot(now + 0.5)
			expect((ActionRules.allowsAt(early, now, "dash"))).toBe(false)
			local late = castingSnapshot(now + 0.1)
			expect((ActionRules.allowsAt(late, now, "dash"))).toBe(true)
			expect((ActionRules.allowsAt(late, now, "block"))).toBe(true)
			expect((ActionRules.allowsAt(late, now, "equip"))).toBe(false)
			-- A dash can take over a cast, so the server's set() accepts it.
			expect(ActionRules.canEnter("casting", "dashing")).toBe(true)
			expect(ActionRules.canEnter("casting", "blocking")).toBe(true)
		end)

		it("keeps the hit-stop, flinch and step small", function()
			expect(Weight.hitStop.max <= 0.12).toBe(true)
			expect(Weight.flinch.degrees <= 25 and Weight.flinch.seconds <= 0.5).toBe(true)
			expect(Weight.step.speed * Weight.step.seconds <= 3).toBe(true)
			expect(Weight.buffer.seconds > 0 and Weight.buffer.seconds <= 0.5).toBe(true)
		end)
	end)
end
