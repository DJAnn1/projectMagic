--!strict
--[[
	Omens.spec: strange signs before big events (docs/Omens.md). What matters most: every event
	that can happen has an omen (every world event type, every Titan, every shared event, Rifts),
	every omen's signs are drawable and have their words; strength rises over the lead, holds
	briefly after the start, then ends; directions use the island's north (-Z); and an omen is
	noticed only close and strong enough, unless it's seen from anywhere.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Data = require(Shared.Magic.Data.Omens)
local OmenRules = require(Shared.Magic.OmenRules)
local Titans = require(Shared.Titans.Data.Titans)
local SharedEvents = require(Shared.Social.Data.SharedEvents)
local EventDefs = require(ServerScriptService.Server.World.EventDefs)
local Flags = require(ServerScriptService.Server.Config.Flags)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Omen data", function()
		it("every event that can happen has an omen", function()
			for typeName in EventDefs do
				expect(Data.sources["world_" .. typeName] ~= nil).toBe(true)
			end
			for _, kind in Titans.ids do
				expect(Data.sources["titan_" .. kind] ~= nil).toBe(true)
			end
			for typeId in SharedEvents.types do
				expect(Data.sources["shared_" .. typeId] ~= nil).toBe(true)
			end
			expect(Data.sources.rift ~= nil).toBe(true)
			expect((Flags :: any).omens_enabled ~= nil).toBe(true)
		end)

		it("every omen's signs exist, draw with a known style and have their words", function()
			for _, source in Data.sources do
				expect(#source.signs >= 1 and #source.signs <= 2).toBe(true)
				expect(source.lead > 0 and source.seen > 0 and #source.after > 20).toBe(true)
				for _, signId in source.signs do
					expect(Data.signs[signId] ~= nil).toBe(true)
				end
			end
			for _, sign in Data.signs do
				expect(table.find(Data.styles, sign.style) ~= nil).toBe(true)
				expect(#sign.journal > 40 and #sign.rumor > 20).toBe(true)
			end
		end)
	end)

	describe("Omen strength", function()
		it("rises over the lead, holds just after the start, then ends", function()
			expect(OmenRules.strength(1000, 1000 - 700, 600)).toBe(nil) -- too early
			expect(OmenRules.strength(1000, 1000 - 600, 600)).toBe(0)
			expect(OmenRules.strength(1000, 1000 - 300, 600)).toBe(0.5)
			expect(OmenRules.strength(1000, 1000, 600)).toBe(1)
			expect(OmenRules.strength(1000, 1000 + Data.linger, 600)).toBe(1)
			expect(OmenRules.strength(1000, 1000 + Data.linger + 1, 600)).toBe(nil)
		end)
	end)

	describe("Omen telling", function()
		it("directions use the island's north (-Z)", function()
			expect(OmenRules.bearing(0, 0, 0, -10)).toBe("north")
			expect(OmenRules.bearing(0, 0, 10, 0)).toBe("east")
			expect(OmenRules.bearing(0, 0, -10, 10)).toBe("south-west")
			local line = OmenRules.rumor("birds", 0, 0, 0, -100) :: string
			expect(string.find(line, "north", 1, true) ~= nil and string.find(line, "{dir}", 1, true) == nil).toBe(true)
			expect(OmenRules.rumor("no_such_sign", 0, 0, 1, 1)).toBe(nil)
		end)

		it("is noticed only close and strong enough, unless seen from anywhere", function()
			local near = { signs = { "birds" }, lead = 100, seen = 800, after = "x" }
			local anywhere = { signs = { "new_star" }, lead = 100, seen = math.huge, after = "x" }
			expect(OmenRules.visible(near, 700, 0)).toBe(true)
			expect(OmenRules.visible(near, 900, 0)).toBe(false)
			expect(OmenRules.visible(anywhere, 1e6, 0)).toBe(true)
			expect(OmenRules.noticeable(near, 100, 0, 0.9)).toBe(true)
			expect(OmenRules.noticeable(near, Data.noticeRange + 50, 0, 0.9)).toBe(false)
			expect(OmenRules.noticeable(near, 100, 0, Data.noticeAt / 2)).toBe(false)
			expect(OmenRules.noticeable(anywhere, 1e6, 0, 0.9)).toBe(true)
		end)

		it("resends only when what you see changes by a tenth", function()
			local a = OmenRules.signature({ { id = "x", source = "rift", s = 0.51 } })
			local b = OmenRules.signature({ { id = "x", source = "rift", s = 0.53 } })
			local c = OmenRules.signature({ { id = "x", source = "rift", s = 0.66 } })
			expect(a).toBe(b)
			expect(a ~= c).toBe(true)
			expect(OmenRules.signature({})).toBe("")
		end)
	end)
end
