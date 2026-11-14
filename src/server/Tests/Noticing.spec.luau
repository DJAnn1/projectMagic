--!strict
--[[
	Noticing.spec: people noticing your magic (docs/Noticing.md, idea #38). What matters most: the
	alarming things come first (a backfire, someone hurt) and noticed_any is always last; everyone
	can always say something (noticed_any and heard_any have lines with no conditions); "heard"
	lines always say which way; no line holds a digit; every fear a line names is a real fear and
	BarkEngine honours it; repeats aren't news unless big.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Domains = require(Shared.Magic.Data.Domains)
local Server = ServerScriptService.Server
local Noticing = require(Server.NPC.Noticing)
local Lines = require(Server.NPC.Data.NoticedLines)
local BarkEngine = require(Server.NPC.BarkEngine)
local NpcData = require(Server.NPC.Data.NpcData)
local Flags = require(Server.Config.Flags)

local CONDITIONS = { "hours", "occ", "action", "mood", "rel", "high", "low", "quirk", "event", "biome", "culture", "child", "deed", "mage", "fear" }

local function seen(over: { [string]: any }): Noticing.Seen
	local payload: { [string]: any } = { domains = { "energy" }, power = 3, harmful = false }
	for k, v in over do
		payload[k] = v
	end
	return Noticing.read(payload, over.mythic == true, over.kind)
end

local function plain(line: any): boolean
	for _, key in CONDITIONS do
		if line[key] ~= nil then
			return false
		end
	end
	return true
end

local function ctx(fears: { [string]: boolean }?): BarkEngine.Context
	return {
		hour = 12,
		occupation = "farmer",
		mood = "content",
		rel = "stranger",
		traits = {},
		quirks = {},
		events = {},
		child = false,
		mage = false,
		deeds = {},
		fears = fears,
		vars = { direction = "north" },
	}
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Noticing categories", function()
		it("put the alarming things first and noticed_any last", function()
			local list = Noticing.categories(seen({ backfire = true, hurt = true, power = 7 }), { scared = true })
			expect(list[1]).toBe("noticed_backfire")
			expect(list[2]).toBe("noticed_hurt")
			expect(list[3]).toBe("noticed_scared")
			expect(list[#list]).toBe("noticed_any")
			expect(table.find(list, "noticed_big") ~= nil).toBe(true)
			expect(table.find(list, "noticed_energy") ~= nil).toBe(true)

			local dud = Noticing.categories(seen({ kind = "none" }), {})
			expect(dud[1]).toBe("noticed_dud")
			local dummy = Noticing.categories(seen({ practice = true, kind = "attack" }), {})
			expect(dummy[1]).toBe("noticed_dummy")
			expect(table.find(dummy, "noticed_attack") == nil).toBe(true)
			local heal = Noticing.categories(seen({ kind = "heal", domains = { "life" } }), {})
			expect(heal[1]).toBe("noticed_heal")
			local heardList = Noticing.heardCategories(seen({ changedLand = true, domains = { "earth" } }))
			expect(heardList[1]).toBe("heard_land")
			expect(heardList[#heardList]).toBe("heard_any")
			expect((Flags :: any).noticing_enabled ~= nil).toBe(true)
		end)

		it("call big what towns would hear, and nothing else", function()
			expect(Noticing.big(seen({ power = 6 }))).toBe(true)
			expect(Noticing.big(seen({ changedLand = true }))).toBe(true)
			expect(Noticing.big(seen({ killed = true }))).toBe(true)
			expect(Noticing.big(seen({ mythic = true }))).toBe(true)
			expect(Noticing.big(seen({ power = 5, hurt = true }))).toBe(false)
			expect(Noticing.outclassed(1, 5)).toBe(true)
			expect(Noticing.outclassed(4, 8)).toBe(false)
			expect(Noticing.outclassed(1, 2)).toBe(false)
		end)

		it("don't treat a repeat as news unless it's big, and always react to alarming things", function()
			local keys = { k = 100 }
			expect(Noticing.fresh(keys, "k", 100 + Noticing.Tuning.repeatGap - 1, false)).toBe(false)
			expect(Noticing.fresh(keys, "k", 100 + Noticing.Tuning.repeatGap, false)).toBe(true)
			expect(Noticing.fresh(keys, "k", 101, true)).toBe(true)
			expect(Noticing.fresh(keys, "other", 101, false)).toBe(true)
			expect(Noticing.chance(seen({ hurt = true }), 0, false)).toBe(1)
			expect(Noticing.chance(seen({ backfire = true }), 0, false)).toBe(1)
			expect(Noticing.chance(seen({}), 0, false) < Noticing.chance(seen({}), 0.9, true)).toBe(true)
			expect(Noticing.score(0.5, false, 2, 0) > Noticing.score(0.5, false, 30, 0)).toBe(true)
		end)
	end)

	describe("Noticed lines", function()
		it("give everyone something to say, and cover every domain", function()
			local plainAny, plainHeard = false, false
			local cats: { [string]: boolean } = {}
			for _, line in Lines do
				cats[line.cat] = true
				if line.cat == "noticed_any" and plain(line) then
					plainAny = true
				end
				if line.cat == "heard_any" and plain(line) then
					plainHeard = true
				end
			end
			expect(plainAny).toBe(true)
			expect(plainHeard).toBe(true)
			for id in Domains :: { [string]: any } do
				expect(cats["noticed_" .. id] == true).toBe(true)
			end
			for _, cat in { "noticed_backfire", "noticed_killed", "noticed_hurt", "noticed_scared", "noticed_mythic", "noticed_land", "noticed_dud", "noticed_big", "noticed_weak", "noticed_dummy", "heard_land", "heard_mythic", "heard_killed" } do
				expect(cats[cat] == true).toBe(true)
			end
		end)

		it("hold no digit, say which way when heard, and name only real fears", function()
			local fearIds: { [string]: boolean } = {}
			for _, fear in NpcData.fears do
				fearIds[fear.id] = true
			end
			for _, line in Lines do
				expect(string.find(line.text, "%d") == nil).toBe(true)
				if string.sub(line.cat, 1, 6) == "heard_" then
					expect(string.find(line.text, "{direction}", 1, true) ~= nil).toBe(true)
				end
				for _, fear in (line.fear or {}) :: { string } do
					expect(fearIds[fear] == true).toBe(true)
				end
			end
			-- BarkEngine: a fear line only for someone with that fear.
			local fireLine = { cat = "x", text = "Keep that fire away!", fear = { "fire" } }
			expect(BarkEngine.eligible(fireLine :: any, ctx(nil))).toBe(false)
			expect(BarkEngine.eligible(fireLine :: any, ctx({ heights = true }))).toBe(false)
			expect(BarkEngine.eligible(fireLine :: any, ctx({ fire = true }))).toBe(true)
			local _, text = BarkEngine.pick("heard_any", ctx(nil), Random.new(1), {}, nil, Lines)
			expect(text ~= nil and string.find(text :: string, "north", 1, true) ~= nil).toBe(true)
		end)
	end)
end
