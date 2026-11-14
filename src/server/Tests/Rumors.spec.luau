--!strict
--[[
	Rumors.spec: overheard rumours (docs/Rumors.md, idea #39). What matters most: hidden mythic sites
	and towns are never talked about; a rumour never repeats one you've heard, nor points at something
	in the square; every kind has an opener (and a story when it's ours to tell) that says which way;
	replies always fit someone; no line holds a digit.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local RumorRules = require(Server.Rumors.RumorRules)
local Lines = require(Server.Rumors.Data.RumorLines)
local POIRules = require(Server.World.POIRules)
local Creatures = require(Server.Creatures.Data.Creatures)
local Flags = require(Server.Config.Flags)

local CONDITIONS = { "hours", "occ", "action", "mood", "rel", "high", "low", "quirk", "event", "biome", "culture", "child", "deed", "mage", "fear" }

local function fact(id: string, x: number, z: number): RumorRules.Fact
	return { id = id, kind = "mine", group = "place", x = x, z = z, tellable = true }
end

local function plain(line: any): boolean
	for _, key in CONDITIONS do
		if line[key] ~= nil then
			return false
		end
	end
	return true
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Rumour rules", function()
		it("never talk about towns or mythic sites, and name every shrine", function()
			for _, rule in POIRules :: { any } do
				local kind = RumorRules.poiKind(rule.type)
				if rule.hidden or rule.type == "settlement" or string.sub(rule.type, 1, 7) == "mythic_" then
					expect(kind == nil).toBe(true)
				else
					expect(kind ~= nil).toBe(true)
				end
			end
			expect(RumorRules.shrinePlace("energy")).toBe("the fire shrine")
			expect((Flags :: any).rumors_enabled ~= nil).toBe(true)
		end)

		it("choose only unheard things within reach, the same way every time", function()
			local facts = { fact("a", 300, 0), fact("b", 0, 20), fact("c", 5000, 0), fact("d", -400, 0) }
			for i = 0, 10 do
				local pick = RumorRules.choose(facts, 0, 0, { d = true }, i / 10)
				expect(pick ~= nil and pick.id == "a").toBe(true) -- b too close, c too far, d heard
			end
			expect(RumorRules.choose(facts, 0, 0, { a = true, d = true }, 0.5) == nil).toBe(true)
			local reversed = { facts[4], facts[3], facts[2], facts[1] }
			local x = RumorRules.choose(facts, 0, 0, {}, 0.7)
			local y = RumorRules.choose(reversed, 0, 0, {}, 0.7)
			expect(x ~= nil and y ~= nil and x.id == y.id).toBe(true)
			local _, reply, told = RumorRules.categories({ id = "z", kind = "zone", group = "danger", x = 0, z = 0, tellable = false })
			expect(#told).toBe(0)
			expect(reply[#reply]).toBe("reply_any")
		end)
	end)

	describe("Rumour lines", function()
		it("give every kind an opener with a direction, and a story when it's ours to tell", function()
			local byCat: { [string]: { any } } = {}
			for _, line in Lines do
				byCat[line.cat] = byCat[line.cat] or {}
				table.insert(byCat[line.cat], line)
			end
			local kinds: { [string]: boolean } = { zone = false, lair = false, feral = false }
			for _, rule in POIRules :: { any } do
				local kind = RumorRules.poiKind(rule.type)
				if kind then
					kinds[kind] = true
				end
			end
			for _, id in Creatures.ids do
				kinds["den_" .. id] = true
			end
			for kind, tellable in kinds do
				local say = byCat["say_" .. kind]
				expect(say ~= nil).toBe(true)
				local hasPlain = false
				for _, line in say or {} do
					hasPlain = hasPlain or plain(line)
				end
				expect(hasPlain).toBe(true) -- anyone can bring it up
				if tellable then
					local told = byCat["told_" .. kind]
					expect(told ~= nil and plain(told[1])).toBe(true)
				end
			end
			local replyPlain = false
			for _, line in byCat.reply_any do
				replyPlain = replyPlain or plain(line)
			end
			expect(replyPlain).toBe(true)
		end)

		it("hold no digit, and say which way in every opener and story", function()
			for _, line in Lines do
				expect(string.find(line.text, "%d") == nil).toBe(true)
				local prefix = string.sub(line.cat, 1, 4)
				if prefix == "say_" or string.sub(line.cat, 1, 5) == "told_" then
					expect(string.find(line.text, "{dir}", 1, true) ~= nil).toBe(true)
				end
			end
		end)
	end)
end
