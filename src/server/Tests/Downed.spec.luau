--!strict
--[[
	Downed.spec: losing leads somewhere (docs/LivingHistory.md §7, Living History stage 3). What
	matters most: another player's blow and Rifts stay deaths; capture only deep, only by a Wildborn,
	never twice inside the gap; no outcome twice in a row; a purse is a share of your coins and never
	two in a row; honest or friendly finders give it back; every category the service asks for has
	lines, and no line holds a digit.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Rules = require(Server.Downed.DownedRules)
local LineData = require(Server.Downed.Data.DownedLines)
local Flags = require(Server.Config.Flags)
local StatusInfo = require(ReplicatedStorage.Shared.Magic.Data.StatusInfo)

local T = Rules.Tuning

local function ctx(over: { [string]: any }): Rules.Context
	local c: { [string]: any } = { pvp = false, rift = false, carrier = false, deep = false, wildborn = false, captureReady = true, last = nil }
	for k, v in over do
		c[k] = v
	end
	return c :: any
end

local function hasCat(cat: string): boolean
	for _, line in LineData.lines do
		if line.cat == cat then
			return true
		end
	end
	return false
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Downed", function()
		it("keeps another player's blow and Rifts as deaths", function()
			expect(Rules.choose(ctx({ pvp = true, carrier = true }), 0)).toBe("death")
			expect(Rules.choose(ctx({ rift = true, deep = true, wildborn = true }), 0)).toBe("death")
		end)

		it("carries you when someone is near, else you come round where you fell", function()
			expect(Rules.choose(ctx({ carrier = true }), 0.5)).toBe("carry")
			expect(Rules.choose(ctx({}), 0.5)).toBe("wake")
		end)

		it("captures only deep in the wilds, by a Wildborn, outside the gap", function()
			expect(Rules.choose(ctx({ deep = true, wildborn = true }), 0)).toBe("capture")
			expect(Rules.choose(ctx({ deep = false, wildborn = true }), 0)).toBe("wake")
			expect(Rules.choose(ctx({ deep = true, wildborn = false }), 0)).toBe("wake")
			expect(Rules.choose(ctx({ deep = true, wildborn = true, captureReady = false }), 0)).toBe("wake")
			expect(Rules.choose(ctx({ deep = true, wildborn = true }), 0.99)).toBe("wake")
			expect(Rules.deep(T.deepFrom)).toBe(true)
			expect(Rules.deep(T.deepFrom - 1)).toBe(false)
		end)

		it("never gives the same outcome twice in a row", function()
			expect(Rules.choose(ctx({ carrier = true, last = "carry" }), 0.5)).toBe("wake")
			expect(Rules.choose(ctx({ last = "wake" }), 0.5)).toBe("spawn")
			expect(Rules.choose(ctx({ deep = true, wildborn = true, carrier = true, last = "capture" }), 0)).toBe("carry")
		end)

		it("drops a share of your coins, never two purses in a row", function()
			expect(Rules.purse(T.purseMin - 1, false, 0.5)).toBe(0)
			expect(Rules.purse(1000, true, 0.5)).toBe(0)
			local low, high = Rules.purse(1000, false, 0), Rules.purse(1000, false, 1)
			expect(low).toBe(math.floor(1000 * T.purseShare[1]))
			expect(high).toBe(math.floor(1000 * T.purseShare[2]))
			expect(Rules.purse(T.purseMin, false, 0) >= 1).toBe(true)
		end)

		it("has honest or friendly finders give it back, and others keep it", function()
			expect(Rules.returns({ agreeableness = 0.9, conscientiousness = 0.8 }, 0.3, 0.2)).toBe(true)
			expect(Rules.returns({ agreeableness = 0.1, conscientiousness = 0.2 }, -0.4, 0.5)).toBe(false)
			expect(Rules.returns({ agreeableness = 0.5, conscientiousness = 0.5 }, 0.6, 0)).toBe(true)
		end)

		it("has lines for every moment, no digits, a flag and a status", function()
			expect((Flags :: any).downed_enabled ~= nil).toBe(true)
			expect((StatusInfo :: any).downed ~= nil).toBe(true)
			for _, cat in { "healer_wake", "carrier_greet", "carrier_thanks", "purse_found", "purse_return", "purse_kept" } do
				expect(hasCat(cat)).toBe(true)
			end
			for _, key in { "carry", "carry_nohealer", "wake", "capture", "escaped_fought", "escaped_walked", "escaped_waited", "purse_lost", "purse_own", "purse_returned", "purse_kept", "thanked" } do
				expect(LineData.journal[key] ~= nil and #LineData.journal[key] > 0).toBe(true)
			end
			for _, line in LineData.lines do
				expect(string.find(line.text, "%d") == nil).toBe(true)
			end
			for _, list in LineData.journal do
				for _, text in list do
					expect(string.find(text, "%d") == nil).toBe(true)
				end
			end
		end)
	end)
end
