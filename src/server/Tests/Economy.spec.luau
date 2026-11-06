--!strict
--[[
	Economy.spec: how a party divides what it earns (docs/Social.md §3). Trade and market rules join
	this file when they're built.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local LootRules = require(ServerScriptService.Server.Social.LootRules)
local PartyRewards = require(ReplicatedStorage.Shared.Social.Data.PartyRewards)

local function total(list: { number }): number
	local sum = 0
	for _, n in list do
		sum += n
	end
	return sum
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Party coin split", function()
		it("loses and makes no coins", function()
			for coins = 0, 40 do
				for n = 1, 5 do
					expect(total(LootRules.splitCoins(coins, n))).toBe(coins)
				end
			end
		end)
		it("is as even as whole coins allow", function()
			local split = LootRules.splitCoins(11, 3)
			expect(split).toEqual({ 4, 4, 3 })
		end)
		it("gives everything to one person with nobody to share with", function()
			expect(LootRules.splitCoins(7, 1)).toEqual({ 7 })
			expect(LootRules.splitCoins(7, 0)).toEqual({ 7 })
		end)
	end)

	describe("Need or greed", function()
		local function entries(a: string?, b: string?, c: string?): { LootRules.RollEntry }
			return { { userId = 1, choice = a }, { userId = 2, choice = b }, { userId = 3, choice = c } }
		end
		it("need beats greed", function()
			expect(LootRules.decideRoll(entries("greed", "need", "greed"), Random.new(1))).toBe(2)
		end)
		it("greed wins when nobody needs it", function()
			expect(LootRules.decideRoll(entries("pass", nil, "greed"), Random.new(1))).toBe(3)
		end)
		it("nobody wins when all pass or nobody answers", function()
			expect(LootRules.decideRoll(entries("pass", "pass", nil), Random.new(1))).toBe(nil)
			expect(LootRules.decideRoll(entries(nil, nil, nil), Random.new(1))).toBe(nil)
		end)
		it("a tie is decided the same way by the same seed, whatever the order", function()
			local a = LootRules.decideRoll({ { userId = 1, choice = "need" }, { userId = 2, choice = "need" } }, Random.new(5))
			local b = LootRules.decideRoll({ { userId = 2, choice = "need" }, { userId = 1, choice = "need" } }, Random.new(5))
			expect(a).toBe(b)
		end)
	end)

	describe("Party share", function()
		it("alone you earn everything", function()
			expect(PartyRewards.shareFor(1)).toBe(1)
		end)
		it("each member earns less as the party grows, but the party earns more", function()
			for n = 2, 5 do
				expect(PartyRewards.shareFor(n) < PartyRewards.shareFor(n - 1)).toBe(true)
				expect(PartyRewards.shareFor(n) * n > PartyRewards.shareFor(n - 1) * (n - 1)).toBe(true)
			end
		end)
		it("matches the documented shares", function()
			expect(PartyRewards.shareFor(2)).toBeNear(0.675, 0.001)
			expect(PartyRewards.shareFor(5)).toBeNear(0.48, 0.001)
		end)
		it("every mode has a name, and the default exists", function()
			expect(PartyRewards.modes[PartyRewards.default] ~= nil).toBe(true)
			expect(#PartyRewards.ordered).toBe(3)
		end)
	end)
end
