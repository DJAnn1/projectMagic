--!strict
--[[
	Travel.spec: the rules behind Domain Travel, with no live players (docs/Travel.md).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local T = require(Shared.Magic.Data.TravelTuning)
local Rules = require(Shared.Magic.TravelRules)
local Registry = require(Shared.Magic.Registry)
local G = require(Shared.Magic.Data.GravityTuning)
local Remotes = require(Shared.Net.Remotes)
local Controls = require(Shared.UI.Controls)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Travel styles", function()
		it("every domain has its own, with its own name", function()
			local names: { [string]: boolean } = {}
			for _, domain in Registry.domainIds do
				local style = T.styles[domain]
				expect(style ~= nil).toBe(true)
				expect(names[style.name]).toBe(nil)
				names[style.name] = true
			end
		end)
		it("the fallback is a real style", function()
			expect(T.styles[T.fallbackDomain] ~= nil).toBe(true)
		end)
		it("skill means faster and cheaper, and the lists cover all 8 tiers", function()
			expect(#T.speed).toBe(8)
			expect(#T.drainShare).toBe(8)
			for i = 2, 8 do
				expect(T.speed[i] > T.speed[i - 1]).toBe(true)
				expect(T.drainShare[i] < T.drainShare[i - 1]).toBe(true)
			end
		end)
		it("even a beginner beats walking", function()
			for domain in T.styles do
				expect(Rules.speed(domain, 1) > 16).toBe(true)
			end
		end)
		it("doesn't replace Flight at the top", function()
			expect(T.speed[8] < G.flight.speed[8]).toBe(true)
		end)
		it("a style's multiplier applies", function()
			expect(Rules.speed("space", 1)).toBeNear(T.speed[1] * T.styles.space.speedMult, 0.001)
		end)
	end)

	describe("Which domain you ride", function()
		local known: { Rules.Known } = {
			{ domain = "water", tier = 2, xp = 50 },
			{ domain = "energy", tier = 5, xp = 900 },
		}
		it("your best domain, with nothing readied", function()
			local domain, tier = Rules.pick(known, nil)
			expect(domain).toBe("energy")
			expect(tier).toBe(5)
		end)
		it("your readied spell's domain wins, at your tier in it", function()
			local domain, tier = Rules.pick(known, "water")
			expect(domain).toBe("water")
			expect(tier).toBe(2)
		end)
		it("a readied domain you don't know falls back to your best", function()
			expect((Rules.pick(known, "void"))).toBe("energy")
		end)
		it("knowing nothing still gives you a ride", function()
			local domain, tier = Rules.pick({}, nil)
			expect(domain).toBe(T.fallbackDomain)
			expect(tier).toBe(1)
		end)
		it("a tie goes by XP, then the alphabet", function()
			expect((Rules.pick({ { domain = "air", tier = 3, xp = 10 }, { domain = "earth", tier = 3, xp = 20 } }, nil))).toBe("earth")
			expect((Rules.pick({ { domain = "earth", tier = 3, xp = 10 }, { domain = "air", tier = 3, xp = 10 } }, nil))).toBe("air")
		end)
	end)

	describe("Setting off and being knocked off", function()
		it("needs a little reservoir, unless it's infinite", function()
			expect(Rules.canSetOff(100 * T.minReservoir, 100, false)).toBe(true)
			expect(Rules.canSetOff(0, 100, false)).toBe(false)
			expect(Rules.canSetOff(0, 100, true)).toBe(true)
		end)
		it("a big hit knocks you off; a small one doesn't", function()
			expect(Rules.knockedOff(100 * T.knockShare, 100)).toBe(true)
			expect(Rules.knockedOff(100 * T.knockShare - 1, 100)).toBe(false)
			expect(Rules.knockedOff(50, 0)).toBe(false)
		end)
		it("drains a share of your reservoir", function()
			expect(Rules.drainPerSecond(100, 1)).toBeNear(100 * T.drainShare[1], 0.001)
		end)
	end)

	describe("The server's checks", function()
		it("allows full speed and a knock on top", function()
			local top = Rules.speed("energy", 3)
			expect(Rules.violation("energy", 3, top, 0)).toBe(false)
			expect(Rules.violation("energy", 3, top + T.speedMargin, 0)).toBe(false)
		end)
		it("catches a speed nothing explains", function()
			expect(Rules.violation("energy", 3, 1000, 0)).toBe(true)
		end)
		it("allows climbing to the style's lift, and a roof", function()
			local style = T.styles.air
			expect(Rules.violation("air", 1, 0, style.hover + style.lift)).toBe(false)
			expect(Rules.violation("air", 1, 0, style.hover + style.lift + T.heightMargin)).toBe(false)
		end)
		it("catches a height past all of that", function()
			local style = T.styles.earth
			expect(Rules.violation("earth", 1, 0, style.hover + style.lift + T.heightMargin + 1)).toBe(true)
		end)
	end)

	describe("Riding", function()
		it("rises toward its height, no faster than you travel", function()
			expect(Rules.verticalSpeed(0, 1, 40)).toBeNear(6, 0.001)
			expect(Rules.verticalSpeed(0, 100, 40)).toBe(40)
			expect(Rules.verticalSpeed(100, 0, 40)).toBe(-40)
		end)
		it("Space climbs, up to the style's lift", function()
			expect(Rules.nextLift(0, 10, true, false, 0.1) > 0).toBe(true)
			expect(Rules.nextLift(10, 10, true, false, 1)).toBe(10)
		end)
		it("letting go settles you back down, and never below the ground", function()
			expect(Rules.nextLift(5, 10, false, false, 0.1) < 5).toBe(true)
			expect(Rules.nextLift(0, 10, false, false, 1)).toBe(0)
			expect(Rules.nextLift(5, 10, false, true, 1)).toBe(0)
		end)
	end)

	describe("Travel wiring", function()
		it("the remote and controls exist, and Y shares with landing", function()
			expect(Remotes.TravelIntent.from).toBe("Client")
			local validate = (Remotes.TravelIntent.args :: { any })[1]
			expect((validate(true))).toBe(true)
			expect((validate("fast"))).toBe(false)
			local travel = Controls.byId.travel
			expect(table.find(travel.keyboard :: { string }, "Y") ~= nil).toBe(true)
			expect(table.find(Controls.byId.fly_land.shares :: { string }, "travel") ~= nil).toBe(true)
		end)
	end)
end
