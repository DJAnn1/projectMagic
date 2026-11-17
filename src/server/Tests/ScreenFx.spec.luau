--!strict
--[[
	ScreenFx.spec: what spells do to the screen (docs/Smoothness.md stage 4, Data/ScreenFx). What
	matters most: flashes stay gentle enough for photosensitive players (capped brightness, a gap
	between flashes, a faint version under Reduce spell effects), every domain has a sky for its
	ultimate, and the kick stays small. The effects themselves are client-only, checked in play.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Data = require(ReplicatedStorage.Shared.Magic.Data.ScreenFx)
local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local Flags = require(ServerScriptService.Server.Config.Flags)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("ScreenFx", function()
		it("keeps flashes gentle", function()
			local F = Data.flash
			expect(F.maxBrightness <= 0.4).toBe(true)
			expect(F.minGap >= 0.5).toBe(true)
			expect(F.reducedMult <= 0.3).toBe(true)
			expect(F.othersMult < 1 and F.othersFrom >= F.ownFrom).toBe(true)
			-- Even a power 10 spell stays under the cap before clamping, give or take.
			expect((10 - F.ownFrom + 1) * F.brightnessPerPower <= F.maxBrightness * 1.1).toBe(true)
			expect((Flags :: any).screen_fx_enabled ~= nil).toBe(true)
		end)

		it("has a sky for every domain's ultimate", function()
			for id in Registry.domains do
				local sky = Data.sky.byDomain[id]
				expect(sky ~= nil).toBe(true)
				local s = sky :: Data.Sky
				expect(s.brightness <= 0 and s.brightness >= -0.4).toBe(true)
			end
			expect(Data.sky.full < Data.sky.range).toBe(true)
		end)

		it("keeps the kick small", function()
			expect(Data.kick.maxDegrees <= 4).toBe(true)
			expect(Data.kick.settle > 0.1 and Data.kick.settle < 0.5).toBe(true)
		end)
	end)
end
