--!strict
--[[
	History.spec: things with a past (docs/LivingHistory.md §6, Living History stage 2a). What
	matters most: names come from our own data and never hold digits; one named place per spacing,
	the biggest legend first, the same whatever order the legends arrive in; the line on an item
	never carries a person's name; a saved record with a past still validates.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Rules = require(Server.Chronicle.HistoryRules)
local Names = require(Server.Chronicle.Data.DeedNames)
local Kinds = require(Server.Chronicle.Data.ChronicleKinds)
local Flags = require(Server.Config.Flags)
local ItemInstance = require(ReplicatedStorage.Shared.Items.ItemInstance)

local function legend(id: string, score: number, x: number, z: number, what: string?): Rules.Entry
	return { id = id, kind = "boss_slain", x = x, z = z, score = score, what = what, names = { "Ann" } }
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("History", function()
		it("has a root, a history line and words for every kind and group", function()
			expect((Flags :: any).history_enabled ~= nil).toBe(true)
			for kind, def in Kinds do
				expect(Names.rootByKind[kind] ~= nil).toBe(true)
				expect(Names.history[kind] ~= nil).toBe(true)
				expect(Names.epithets[def.group] ~= nil).toBe(true)
				expect(Names.places[def.group] ~= nil).toBe(true)
				expect(Names.monument[def.group] ~= nil and Names.monument[def.group .. "_nameless"] ~= nil).toBe(true)
			end
			local function noDigits(text: string)
				expect(string.find(text, "%d") == nil).toBe(true)
			end
			for _, list in Names.epithets do
				for _, text in list do
					noDigits(text)
				end
			end
			for _, list in Names.places do
				for _, text in list do
					noDigits(text)
				end
			end
			for _, line in Names.lines do
				noDigits(line.text)
			end
		end)

		it("names things from the legend's own words", function()
			local e = legend("a", 0.9, 0, 0, "The Ashwalker")
			expect(Rules.root(e)).toBe("Ashwalker")
			expect(Rules.root(legend("b", 0.9, 0, 0, "drought"))).toBe("Drought")
			expect(Rules.root({ id = "c", kind = "quake", x = 0, z = 0, score = 1 })).toBe("Quake")
			expect(string.find(Rules.epithet(e, 0), "Ashwalker", 1, true) ~= nil).toBe(true)
			expect(string.find(Rules.placeName(e, 0.99), "Ashwalker", 1, true) ~= nil).toBe(true)
			-- A many-word root never gets a suffix glued on.
			local long = legend("d", 0.9, 0, 0, "the thing in the test")
			for i = 0, 9 do
				expect(string.find(Rules.epithet(long, i / 10), "test-", 1, true) == nil).toBe(true)
				expect(string.find(Rules.placeName(long, i / 10), "testlight", 1, true) == nil).toBe(true)
			end
		end)

		it("never puts a person's name on an item, and puts it on the stone", function()
			local e = legend("a", 0.9, 0, 0, "The Ashwalker")
			local line = Rules.historyLine(e, "out north of Glenhold")
			expect(string.find(line, "Ann", 1, true) == nil).toBe(true)
			expect(line).toBe("Struck down The Ashwalker out north of Glenhold.")
			expect(string.find(Rules.monumentLine(e, "here"), "Ann", 1, true) ~= nil).toBe(true)
			local nameless = Rules.monumentLine({ id = "q", kind = "quake", x = 0, z = 0, score = 1 }, "here")
			expect(string.find(nameless, "{", 1, true) == nil).toBe(true)
		end)

		it("names one place per spacing, the biggest first, in any order", function()
			local list = {
				legend("small", 0.7, 0, 0),
				legend("big", 0.95, 100, 0),
				legend("far", 0.8, 1000, 0),
			}
			local a = Rules.places(list, 400)
			local reversed = { list[3], list[2], list[1] }
			local b = Rules.places(reversed, 400)
			expect(#a).toBe(2)
			expect(a[1].id).toBe("big")
			expect(a[2].id).toBe("far")
			expect(b[1].id).toBe("big")
			expect((Rules.top(list) :: any).id).toBe("big")
		end)

		it("keeps a record with a past valid", function()
			local ok, why = ItemInstance.validate({ i = "oak_staff", u = "x1", h = "studio_1_1", hn = "Ashwalker's Bane", hl = "Struck down The Ashwalker." })
			expect(ok).toBe(true)
			expect(why).toBe(nil)
			local name = ItemInstance.displayName({ i = "oak_staff", u = "x1", hn = "Ashwalker's Bane" } :: any)
			expect(string.find(name, "Ashwalker's Bane", 1, true) == 1).toBe(true)
		end)
	end)
end
