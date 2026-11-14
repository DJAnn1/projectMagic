--!strict
--[[
	SaveFiles.spec: save files (docs/SaveFiles.md). What matters: file 1 keeps the original
	profile seed (so existing characters are untouched) and files 2 and 3 get their own; the
	account record starts empty; the menu's remotes are declared; and a fresh Player template has
	no profile, so a reset file regenerates its innate magic from its seed.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local Schemas = require(ServerScriptService.Server.Persistence.Schemas)
local PlayerDataService = require(ServerScriptService.Server.Services.PlayerDataService)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Save files", function()
		it("file 1 keeps the original seed; files 2 and 3 are characters of their own", function()
			expect(PlayerDataService:entityFor(123, 1)).toBe("player:123")
			local two, three = PlayerDataService:entityFor(123, 2), PlayerDataService:entityFor(123, 3)
			expect(two ~= "player:123" and three ~= "player:123" and two ~= three).toBe(true)
		end)

		it("the account record starts empty and the menu's remotes exist", function()
			local account = Schemas.Account.template()
			expect(account.last).toBe(0)
			expect(next(account.files)).toBe(nil)
			for _, name in { "FileList", "FileChoose", "FileReset", "FileReturn", "FileJoinFriend" } do
				expect((Remotes :: any)[name] ~= nil).toBe(true)
			end
		end)

		it("a fresh save has no profile, so a reset file is reborn with the same magic", function()
			local fresh = Schemas.Player.template()
			expect(fresh.profile).toBe(nil)
			expect(fresh.progression ~= nil and fresh.spellbook ~= nil).toBe(true)
		end)
	end)
end
