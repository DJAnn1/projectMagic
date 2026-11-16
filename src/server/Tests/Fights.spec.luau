--!strict
--[[
	Fights.spec: NPCs fighting each other (docs/NpcFights.md). What matters most: family never
	brawls; a grudge grows with rivalry, dislike and clashing tempers; a brawl ends the moment one
	is at the floor or a guard arrives; raiders are fighters first; no line holds a digit and every
	category the service speaks has lines; the flag and memory kinds exist.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local FightRules = require(Server.Fights.FightRules)
local Data = require(Server.Fights.Data.Fights)
local MemoryService = require(Server.NPC.MemoryService)
local Flags = require(Server.Config.Flags)

local function person(agreeableness: number, other: number?): any
	local o = other or 0.5
	return {
		traits = { agreeableness = agreeableness, extraversion = o, openness = o, humor = o, conscientiousness = o },
		ageBand = "adult",
		occupation = "farmer",
		action = "socialize",
	}
end

local function state(over: { [string]: any }): FightRules.BrawlState
	local s: any = {
		elapsed = 5, lasts = 40, shareA = 0.8, shareB = 0.8, floor = 0.35,
		apart = 10, apartLimit = 45, guardDistance = nil, breakAt = 9, goneA = false, goneB = false,
	}
	for k, v in over do
		s[k] = v
	end
	return s
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("NPC fights (docs/NpcFights.md)", function()
		it("family never brawl; grudges grow with rivalry, dislike and temper", function()
			local a, b = person(0.1, 0.1), person(0.9, 0.9)
			expect(FightRules.grudge(a, b, { affinity = -0.8, trust = 0, rivalry = 1, bond = "sibling" }, nil)).toBe(0)
			local calm = FightRules.grudge(person(0.8), person(0.8), nil, nil)
			local clash = FightRules.grudge(a, b, nil, nil)
			expect(clash > calm).toBe(true)
			local hated = FightRules.grudge(a, b, { affinity = -0.6, trust = 0, rivalry = 0.5, bond = "rival" }, nil)
			expect(hated > clash).toBe(true)
			expect(FightRules.friction(a, b) >= 0 and FightRules.friction(a, b) <= 1).toBe(true)
		end)

		it("only free adults brawl", function()
			expect(FightRules.canBrawl(person(0.2))).toBe(true)
			local kid = person(0.2)
			kid.ageBand = "child"
			expect(FightRules.canBrawl(kid)).toBe(false)
			local asleep = person(0.2)
			asleep.action = "sleep"
			expect(FightRules.canBrawl(asleep)).toBe(false)
			local fighting = person(0.2)
			fighting.combat = {}
			expect(FightRules.canBrawl(fighting)).toBe(false)
			expect(FightRules.inHours(23, { 16, 25 })).toBe(true)
			expect(FightRules.inHours(0.5, { 16, 25 })).toBe(true)
			expect(FightRules.inHours(12, { 16, 25 })).toBe(false)
		end)

		it("a brawl ends at the floor, when a guard arrives, when one runs, or in time", function()
			expect(FightRules.brawlOver(state({}))).toBe(nil)
			expect(FightRules.brawlOver(state({ shareB = 0.36 }))).toBe("a_won")
			expect(FightRules.brawlOver(state({ shareA = 0.35 }))).toBe("b_won")
			expect(FightRules.brawlOver(state({ guardDistance = 8 }))).toBe("broken")
			expect(FightRules.brawlOver(state({ guardDistance = 30 }))).toBe(nil)
			expect(FightRules.brawlOver(state({ apart = 60 }))).toBe("ran")
			expect(FightRules.brawlOver(state({ elapsed = 41 }))).toBe("spent")
			expect(FightRules.brawlOver(state({ goneA = true, shareB = 0.1 }))).toBe("gone")
		end)

		it("raiders: fighters first, then the bravest; counts stay in range", function()
			local ranked = FightRules.rankRaiders({
				{ id = "c", fighter = false, courage = 0.9 },
				{ id = "a", fighter = true, courage = 0.1 },
				{ id = "b", fighter = false, courage = 0.95 },
				{ id = "d", fighter = true, courage = 0.4 },
			})
			expect(ranked[1].id).toBe("d")
			expect(ranked[2].id).toBe("a")
			expect(ranked[3].id).toBe("b")
			for _, roll in { 0, 0.3, 0.6, 0.999, 1 } do
				local n = FightRules.raidCount(roll, Data.tuning.raid.count)
				expect(n >= Data.tuning.raid.count[1] and n <= Data.tuning.raid.count[2]).toBe(true)
			end
		end)

		it("every category spoken has lines, none with digits; flag and memories exist", function()
			local seen: { [string]: boolean } = {}
			for _, line in Data.lines do
				seen[line.cat] = true
				expect(string.find(line.text, "%d") == nil).toBe(true)
			end
			for _, cat in { "brawl_words_a", "brawl_words_b", "brawl_won", "brawl_lost", "brawl_broken", "brawl_watch", "raid_arrive", "raid_fire", "raid_flee", "raid_beaten" } do
				expect(seen[cat] == true).toBe(true)
			end
			expect((Flags :: any).npc_fights_enabled ~= nil).toBe(true)
			for _, kind in { "brawled_with", "saw_brawl", "broke_up_fight", "raided_us", "duel_won", "duel_lost" } do
				expect(MemoryService.KINDS[kind] ~= nil).toBe(true)
			end
		end)
	end)
end
