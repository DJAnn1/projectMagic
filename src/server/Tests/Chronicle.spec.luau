--!strict
--[[
	Chronicle.spec: the world remembers (docs/LivingHistory.md §4, Living History stage 1). What
	matters most: repeats can't farm a legend; the cap drops the smallest deeds, not the biggest;
	taking a name off a legend keeps the deed; telling picks the same thing whatever order the
	chronicle is in and never repeats what you've heard; every kind can be told, and every named
	kind can greet you; no line holds a digit.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Rules = require(Server.Chronicle.ChronicleRules)
local Kinds = require(Server.Chronicle.Data.ChronicleKinds)
local Lines = require(Server.Chronicle.Data.ChronicleLines)
local MemoryService = require(Server.NPC.MemoryService)
local Flags = require(Server.Config.Flags)

local T = Rules.Tuning

local function entry(id: string, score: number, x: number, z: number, t: number?): Rules.Entry
	return { id = id, kind = "boss_slain", t = t or 0, x = x, z = z, score = score }
end

local function hasCat(cat: string): boolean
	for _, line in Lines do
		if line.cat == cat then
			return true
		end
	end
	return false
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Chronicle", function()
		it("can tell every kind, greet for every named kind, and answer every group", function()
			expect((Flags :: any).chronicle_enabled ~= nil).toBe(true)
			expect(MemoryService.KINDS.legend_of ~= nil).toBe(true)
			local groups: { [string]: boolean } = {}
			for kind, def in Kinds do
				expect(hasCat("say_" .. kind)).toBe(true)
				expect(hasCat("told_" .. kind)).toBe(true)
				if def.named then
					expect(hasCat("greet_" .. kind)).toBe(true)
				end
				groups[def.group] = true
			end
			for group in groups do
				expect(hasCat("reply_" .. group)).toBe(true)
			end
			expect(hasCat("reply_any")).toBe(true)
			for _, line in Lines do
				expect(string.find(line.text, "%d") == nil).toBe(true)
				local _, _, _, _, journal = Rules.categories({ id = "x", kind = string.match(line.cat, "^%a+_(.+)$") or "", t = 0, x = 0, z = 0, score = 0 })
				expect(typeof(journal)).toBe("string")
			end
		end)

		it("scores firsts, power and towns up, and halves each repeat", function()
			local base = Rules.score("boss_slain", {}, 0)
			expect(math.abs(base - Kinds.boss_slain.base) < 1e-6).toBe(true)
			expect(Rules.score("boss_slain", { first = true }, 0) > base).toBe(true)
			expect(Rules.score("boss_slain", { power = 10 }, 0) > Rules.score("boss_slain", { power = 7 }, 0)).toBe(true)
			expect(Rules.score("boss_slain", { inTown = true }, 0) > base).toBe(true)
			expect(math.abs(Rules.score("boss_slain", {}, 1) - base * T.repeatFactor) < 1e-6).toBe(true)
			expect(Rules.score("titan_fell", { first = true, power = 10, inTown = true }, 0) <= 1).toBe(true)
			expect(Rules.score("nonsense", {}, 0)).toBe(0)
			-- A Titan is a legend; a first boss kill is; killing the same boss again soon isn't.
			expect(Rules.isLegend(Rules.score("titan_fell", {}, 0))).toBe(true)
			expect(Rules.isLegend(Rules.score("boss_slain", { first = true }, 0))).toBe(true)
			expect(Rules.isLegend(Rules.score("boss_slain", { first = true }, 1))).toBe(false)
			expect(Rules.repeatKey("quake", "u:1", "t1") ~= Rules.repeatKey("quake", "u:2", "t1")).toBe(true)
		end)

		it("drop the smallest deed past the cap, and keep legends oldest-out without doubles", function()
			local list: { Rules.Entry } = {}
			Rules.add(list, entry("big", 0.9, 0, 0, 1), 2)
			Rules.add(list, entry("small", 0.3, 0, 0, 2), 2)
			local gone = Rules.add(list, entry("mid", 0.5, 0, 0, 3), 2)
			expect(gone ~= nil and gone.id == "small").toBe(true)
			expect(#list).toBe(2)

			local legends: { Rules.Legend } = {}
			for i = 1, 4 do
				local e = entry("L" .. i, 0.8, i, i, i)
				e.by, e.names = { 100 + i }, { "P" .. i }
				expect(Rules.addLegend(legends, Rules.legendOf(e), 3)).toBe(true)
			end
			expect(#legends).toBe(3)
			expect(legends[1].id).toBe("L2")
			expect(Rules.addLegend(legends, Rules.legendOf(entry("L4", 0.8, 0, 0)), 3)).toBe(false)
			-- Taking a name off keeps the deed.
			expect(Rules.forget(legends, 103)).toBe(1)
			expect(legends[2].u == nil and legends[2].by == nil and legends[2].k == "boss_slain").toBe(true)
			local back = Rules.entryOf(legends[3])
			expect(back.old == true and back.legend == true and back.names ~= nil and back.names[1] == "P4").toBe(true)
		end)

		it("belong to the nearest town in reach, and know when it's in the town itself", function()
			local towns = { { id = "a", x = 0, z = 0, radius = 100 }, { id = "b", x = 500, z = 0, radius = 100 } }
			local id, inside = Rules.townFor(towns, 50, 0)
			expect(id == "a" and inside).toBe(true)
			id, inside = Rules.townFor(towns, 380, 0)
			expect(id == "b" and not inside).toBe(true)
			id = Rules.townFor(towns, 5000, 0)
			expect(id == nil).toBe(true)
		end)

		it("tell the same thing whatever order, never what you've heard, and only what's in reach", function()
			local far = entry("far", 1, 5000, 0)
			local farHere = entry("farHere", 0.5, 5000, 0)
			farHere.town = "home"
			local list = { entry("a", 0.6, 100, 0), entry("b", 0.4, -200, 0), far, farHere }
			for i = 0, 9 do
				local roll = i / 10
				local x = Rules.choose(list, 0, 0, {}, roll, "home")
				local y = Rules.choose({ list[4], list[3], list[2], list[1] }, 0, 0, {}, roll, "home")
				expect(x ~= nil and y ~= nil and x.id == y.id and x.id ~= "far").toBe(true)
			end
			expect(Rules.choose(list, 0, 0, { a = true, b = true, farHere = true }, 0.5, "home") == nil).toBe(true)
			expect(Rules.choose(list, 0, 0, { a = true, b = true }, 0.5, "elsewhere") == nil).toBe(true)
		end)

		it("talk in the evening, past midnight too", function()
			expect(Rules.evening(19)).toBe(true)
			expect(Rules.evening(1)).toBe(true)
			expect(Rules.evening(12)).toBe(false)
		end)
	end)
end
