--!strict
--[[
	ProgressReset.spec: how a reset of all players' progress keys its records (docs/Backend.md, "Resetting
	progress"). The one that matters most: generation 0 must keep today's keys, or the first update with
	this code would lose every existing save.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local ProgressKeys = require(Server.Persistence.ProgressKeys)
local Schemas = require(Server.Persistence.Schemas)
local WorldService = require(Server.Services.WorldService)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Progress keys", function()
		it("generation 0 keeps today's exact keys, so existing saves are found", function()
			expect(ProgressKeys.key("player_123", 0)).toBe("player_123")
			expect(ProgressKeys.key("housing", 0)).toBe("housing")
		end)
		it("a new generation is a different key, so everyone starts fresh", function()
			expect(ProgressKeys.key("player_123", 1) ~= ProgressKeys.key("player_123", 0)).toBe(true)
			expect(ProgressKeys.key("player_123", 1) ~= ProgressKeys.key("player_123", 2)).toBe(true)
		end)
		it("two players never share a key", function()
			expect(ProgressKeys.key("player_1", 12) ~= ProgressKeys.key("player_12", 1)).toBe(true)
		end)
		it("fits a DataStore key's 50 characters at any sensible size", function()
			expect(#ProgressKeys.key("player_" .. 2 ^ 53, 9999) <= 50).toBe(true)
			expect(#ProgressKeys.key("g999_housing", 9999) <= 50).toBe(true)
			expect(#ProgressKeys.key("r_0123456789abcdef", 9999) <= 50).toBe(true)
		end)
		it("an erasure request reaches every generation of a save", function()
			local keys = ProgressKeys.allKeys("player_5", 2)
			expect(#keys).toBe(3)
			expect(keys[1]).toBe("player_5")
			expect(table.find(keys, ProgressKeys.key("player_5", 2)) ~= nil).toBe(true)
		end)
	end)

	describe("Generations", function()
		it("a reset goes past the highest, so numbers are never reused", function()
			expect(ProgressKeys.nextGeneration(0)).toBe(1)
			expect(ProgressKeys.nextGeneration(4)).toBe(5)
		end)
		it("can put back any earlier generation", function()
			expect(ProgressKeys.canRestore(0, 2, 2)).toBe(nil)
			expect(ProgressKeys.canRestore(1, 2, 2)).toBe(nil)
		end)
		it("can go forward again after an undo", function()
			expect(ProgressKeys.canRestore(2, 0, 2)).toBe(nil)
		end)
		it("won't restore what's already in use, or never existed", function()
			expect(ProgressKeys.canRestore(2, 2, 2) ~= nil).toBe(true)
			expect(ProgressKeys.canRestore(3, 2, 2) ~= nil).toBe(true)
			expect(ProgressKeys.canRestore(-1, 2, 2) ~= nil).toBe(true)
			expect(ProgressKeys.canRestore(1.5, 2, 2) ~= nil).toBe(true)
		end)
	end)

	describe("Who can reset", function()
		it("only the owner", function()
			local ok, message = WorldService:resetProgress(1, 2)
			expect(ok).toBe(false)
			expect(message).toBe("owner only")
		end)
		it("only the owner can restore", function()
			local ok = WorldService:restoreProgress(0, 1, 2)
			expect(ok).toBe(false)
		end)
	end)

	describe("A fresh world record", function()
		it("starts on the original generation", function()
			local record = Schemas.World.template()
			expect(record.playerGeneration).toBe(0)
			expect(record.playerGenerationMax).toBe(0)
		end)
	end)
end
