--!strict
--[[
	Sigils.spec: the drawn circles of magic (docs/Smoothness.md stage 2, Shared/Magic/Data/Sigils).
	What matters most: every domain has a family that the drawer knows, every verb moves its sigil,
	every property category has a motif, charge stages grow, and the limits stay sane. The drawing
	itself is client-only (Client/Fx/Sigils) and is checked in play with the admin `sigil` command.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Data = require(ReplicatedStorage.Shared.Magic.Data.Sigils)
local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local Flags = require(ServerScriptService.Server.Config.Flags)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Sigils", function()
		it("gives every domain a family the drawer knows", function()
			for id in Registry.domains do
				local family = Data.families[id]
				expect(family ~= nil).toBe(true)
				local f = family :: Data.Family
				expect(table.find(Data.patterns, f.pattern) ~= nil).toBe(true)
				expect(table.find(Data.bands, f.band) ~= nil).toBe(true)
				expect(table.find(Data.cores, f.core) ~= nil).toBe(true)
				expect(f.weight > 0).toBe(true)
			end
			expect((Flags :: any).sigils_enabled ~= nil).toBe(true)
		end)

		it("gives each domain its own pattern", function()
			local seen: { [string]: string } = {}
			for id, family in Data.families do
				expect(seen[family.pattern] == nil).toBe(true)
				seen[family.pattern] = id
			end
		end)

		it("moves for every verb and marks every property category", function()
			for id in Registry.verbs do
				expect(Data.motions[id] ~= nil).toBe(true)
			end
			for _, property in Registry.properties do
				local motif = Data.motifByCategory[(property :: any).category]
				expect(motif ~= nil and table.find(Data.motifs, motif) ~= nil).toBe(true)
			end
		end)

		it("grows with each charge stage and keeps sane limits", function()
			local stages = Data.size.chargeStages
			for i = 2, #stages do
				expect(stages[i] > stages[i - 1]).toBe(true)
			end
			expect(Data.caps.live > 0 and Data.caps.live <= 30).toBe(true)
			expect(Data.caps.brightness > 1).toBe(true)
			expect(Data.detail.ringAt <= Data.detail.bandAt and Data.detail.bandAt <= Data.detail.crownAt).toBe(true)
		end)
	end)
end
