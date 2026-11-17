--!strict
--[[
	Stagings.spec: staged effects (docs/Smoothness.md stage 3, Shared/Magic/Data/Stagings). What
	matters most: every spell form has a beat list, every beat is a kind the player knows and can
	actually play (in range of recipe powers, with sane times), and an ultimate's sequence leaves a
	build before its stillness. The pieces themselves are client-only (Client/Fx/Staging) and are
	checked in play.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Data = require(ReplicatedStorage.Shared.Magic.Data.Stagings)
local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local Flags = require(ServerScriptService.Server.Config.Flags)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Stagings", function()
		it("has a beat list for every spell form", function()
			for id in Registry.forms do
				expect(Data.forms[id] ~= nil).toBe(true)
			end
			expect((Flags :: any).staging_enabled ~= nil).toBe(true)
		end)

		it("only uses known kinds, reachable powers and sane times", function()
			for _, beats in Data.forms do
				for _, b in beats do
					expect(table.find(Data.kinds, b.kind) ~= nil).toBe(true)
					expect((b.minPower or 0) <= 10).toBe(true)
					expect((b.at or 0) >= 0 and (b.at or 0) < 2).toBe(true)
					expect((b.scale or 1) > 0 and (b.scale or 1) <= 3).toBe(true)
					local total = (b.grow or 0) + (b.hold or 0) + (b.fade or 0)
					expect(total < 4).toBe(true)
				end
			end
		end)

		it("leaves an ultimate a build before its stillness", function()
			local U = Data.ultimate
			expect(U.minBuild > U.pause * 0.5).toBe(true)
			expect(U.pause > 0 and U.pause < 1.5).toBe(true)
			expect(U.ringEvery > 0.2).toBe(true)
			expect(Data.caps.insideTint <= 0.4 and Data.caps.insideTintReduced < Data.caps.insideTint).toBe(true)
		end)
	end)
end
