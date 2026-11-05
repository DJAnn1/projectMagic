--!strict
-- Unit specs for the NPC simulation: data integrity, deterministic generation, households, the
-- utility brain, schedules, memory and gossip, relationships, magical careers and dialogue.

local ServerScriptService = game:GetService("ServerScriptService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)

local NPC = ServerScriptService.Server.NPC
local NpcData = require(NPC.Data.NpcData)
local NeedsActions = require(NPC.Data.NeedsActions)
local Quirks = require(NPC.Data.Quirks)
local Grammar = require(NPC.Data.DialogueGrammar)
local NPCFactory = require(NPC.NPCFactory)
local NPCBrain = require(NPC.NPCBrain)
local UtilityScore = require(NPC.UtilityScore)
local ScheduleService = require(NPC.ScheduleService)
local MemoryService = require(NPC.MemoryService)
local RelationshipGraph = require(NPC.RelationshipGraph)
local NPCMagicLife = require(NPC.NPCMagicLife)
local DialogueEngine = require(NPC.DialogueEngine)

local SEED = 1337

local function settlement(population: number): any
	return { id = "settlement_t", name = "Testford", culture = "forgehold", size = "town", x = 0, z = 0, population = population, relations = {} }
end

-- What NPCService.enrich adds, minus anything that needs the world.
local function ready(npc: any): any
	npc.scheduleShift = ScheduleService.shift(npc)
	npc.needs = NPCBrain.freshNeeds(npc.seed)
	npc.drain = NPCBrain.drainOf(npc)
	npc.memories = {}
	npc.action = "idle"
	npc.actionUntil = 0
	NPCMagicLife.init(npc)
	npc.compiled = NPCBrain.compile(npc)
	return npc
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("NPC data", function()
		it("references only real quirks, actions, schedules, branches and grammar topics", function()
			for id, q in Quirks.defs do
				for action in (q.effects.actionMult or {}) :: { [string]: number } do
					expect(NeedsActions.actions[action] ~= nil or action).toBe(true)
				end
				for _, other in (q.excludes or {}) :: { string } do
					expect(Quirks.defs[other] ~= nil or id .. " excludes " .. other).toBe(true)
				end
			end
			for id, occ in NpcData.occupations do
				expect(NeedsActions.schedules[occ.schedule] ~= nil or id).toBe(true)
				if occ.work then
					expect(Registry.branches[occ.work.branch] ~= nil or id).toBe(true)
				end
			end
			for _, def in NpcData.authored :: { any } do
				for _, q in def.quirks or {} do
					expect(Quirks.defs[q] ~= nil or def.key .. ": " .. q).toBe(true)
				end
			end
			for _, topic in { "greet", "self", "magic", "rumor", "work", "learn", "farewell", "ambient", "react_attacked" } do
				expect(Grammar[topic] ~= nil or topic).toBe(true)
			end
		end)
		it("has 50+ quirks and a full 24-hour plan in every schedule", function()
			expect(#Quirks.ids >= 50).toBe(true)
			for name, plan in NeedsActions.schedules do
				expect(#plan == 24 or name).toBe(true)
			end
		end)
	end)

	describe("NPCFactory", function()
		it("generates the same person from the same seed and id", function()
			local a = NPCFactory.generate(SEED, settlement(18), 5)
			local b = NPCFactory.generate(SEED, settlement(18), 5)
			expect(a.id).toBe("settlement_t#5")
			expect(a.name).toBe(b.name)
			expect(a.occupation).toBe(b.occupation)
			expect(a.traits).toEqual(b.traits)
			expect(a.quirks).toEqual(b.quirks)
			expect(a.profile.manifest).toEqual(b.profile.manifest)
			expect(NPCFactory.generate(SEED + 1, settlement(18), 5).seed ~= a.seed).toBe(true)
		end)
		it("never gives anyone two quirks that exclude each other", function()
			for _, npc in NPCFactory.populate(SEED, settlement(40)) do
				expect(#npc.quirks >= 2 and #npc.quirks <= 4).toBe(true)
				for _, q in npc.quirks do
					for _, other in (Quirks.defs[q].excludes or {}) :: { string } do
						expect(table.find(npc.quirks, other) == nil or npc.id).toBe(true)
					end
				end
			end
		end)
		it("puts everyone in a household of at most four", function()
			local homes: { [string]: number } = {}
			for _, npc in NPCFactory.populate(SEED, settlement(40)) do
				expect(npc.household ~= "").toBe(true)
				homes[npc.household] = (homes[npc.household] or 0) + 1
			end
			for home, n in homes do
				expect(n <= 4 or home).toBe(true)
			end
		end)
		it("honours authored overrides, including a forced hidden mythic", function()
			local child = (NpcData.authored :: { any })[3]
			local npc = ready(NPCFactory.generate(SEED, settlement(18), 18, child))
			expect(npc.authored).toBe("gravitychild")
			expect(npc.age).toBe(9)
			expect(npc.magic.hiddenMythic).toBe("gravity")
		end)
	end)

	describe("NPCBrain", function()
		local npcs = NPCFactory.populate(SEED, settlement(18))
		local adult: any = nil
		for _, npc in npcs do
			if npc.ageBand == "adult" and npc.occupation ~= "retired" and not adult then
				adult = ready(npc)
			end
		end

		it("sleeps at night when tired", function()
			adult.needs.rest = 0.15
			local action = NPCBrain.decide(adult, 0.1, "sleep", false)
			expect(action).toBe("sleep")
		end)
		it("never shelters without a threat, and shelters when terrified", function()
			adult.needs.safety = 0.05
			expect(NPCBrain.decide(adult, 0.5, "work", false) ~= "shelter").toBe(true)
			expect(NPCBrain.decide(adult, 0.5, "danger", true)).toBe("shelter")
			adult.needs.safety = 1
		end)
		it("scores the same in a batch (the parallel path) as serially", function()
			local hour = 300
			local best = UtilityScore.score(adult.compiled, adult.needs, "free", "idle", hour, false)
			local out = UtilityScore.batch({ { id = adult.id, compiled = adult.compiled, needs = adult.needs, block = "free", current = "idle", hour = hour, threat = false } })
			expect(out[adult.id]).toBe(best)
		end)
		it("integrates needs within 0..1", function()
			NPCBrain.integrate(adult, 30, "idle")
			for _, need in NeedsActions.needs do
				expect(adult.needs[need] >= 0 and adult.needs[need] <= 1).toBe(true)
			end
		end)
	end)

	describe("ScheduleService", function()
		it("shifts the day plan by the person's schedule shift", function()
			local npc: any = { occupation = "smith", scheduleShift = 0 }
			expect(ScheduleService.blockAt(npc, 9, false)).toBe("work")
			npc.scheduleShift = 3
			expect(ScheduleService.blockAt(npc, 9, false)).toBe("meal") -- 9 - 3 = 06:00
			expect(ScheduleService.blockAt(npc, 9, true)).toBe("danger")
		end)
		it("gives each person a stable spot", function()
			local place = { x = 100, z = -50, radius = 80, seed = 42 }
			local x1, z1 = ScheduleService.spot(place, "forge", 7, nil)
			local x2, z2 = ScheduleService.spot(place, "forge", 7, nil)
			expect(x1).toBe(x2)
			expect(z1).toBe(z2)
		end)
	end)

	describe("MemoryService", function()
		local function person(id: string): any
			return { id = id, traits = { neuroticism = 0.5, extraversion = 0.5 }, quirks = {}, memories = {} }
		end
		it("merges repeats within the hour and stays under the cap", function()
			local p = person("a")
			MemoryService.add(p, "saw_magic", "u:1", 1, { intensity = 0.3 })
			MemoryService.add(p, "saw_magic", "u:1", 1.01, { intensity = 0.3 })
			expect(#p.memories).toBe(1)
			for i = 1, 40 do
				MemoryService.add(p, "attacked_someone", "npc" .. i, 2 + i, { intensity = 0.5 })
			end
			expect(#p.memories <= 24).toBe(true)
		end)
		it("fades with time and colours opinion", function()
			local p = person("a")
			local m = MemoryService.add(p, "attacked_me", "u:2", 0, { intensity = 0.8 })
			expect(MemoryService.strength(p, m, 30) < MemoryService.strength(p, m, 0)).toBe(true)
			expect(MemoryService.opinion(p, "u:2", 0) < 0).toBe(true)
		end)
		it("passes gossip on weaker, once per listener", function()
			local a, b = person("a"), person("b")
			MemoryService.add(a, "attacked_me", "u:3", 0, { intensity = 0.9 })
			local heard = MemoryService.gossip(a, b, 0, 1)
			expect(heard ~= nil).toBe(true)
			expect((heard :: any).secondhand).toBe(true)
			expect((heard :: any).intensity < a.memories[1].intensity).toBe(true)
			expect(MemoryService.gossip(a, b, 0, 1)).toBe(nil)
		end)
	end)

	describe("RelationshipGraph", function()
		it("seeds family bonds that mirror each other", function()
			RelationshipGraph.clear()
			local npcs = NPCFactory.populate(SEED, settlement(40))
			RelationshipGraph.seed(npcs)
			local mirror = { parent = "child", child = "parent", spouse = "spouse", sibling = "sibling" }
			local checked = 0
			for _, a in npcs do
				for _, b in npcs do
					local e = a ~= b and a.household == b.household and RelationshipGraph.peek(a.id, b.id)
					if e and e.bond and mirror[e.bond] then
						local back = RelationshipGraph.peek(b.id, a.id)
						expect(back and back.bond).toBe(mirror[e.bond])
						checked += 1
					end
				end
			end
			expect(checked > 0).toBe(true)
			RelationshipGraph.clear()
		end)
	end)

	describe("NPCMagicLife", function()
		it("advances careers deterministically", function()
			RelationshipGraph.clear()
			local function run(): { any }
				local npcs = NPCFactory.populate(SEED, settlement(18))
				for _, npc in npcs do
					npc.memories = {}
					NPCMagicLife.init(npc)
				end
				NPCMagicLife.advance(npcs, 12, 84, nil)
				return npcs
			end
			local a, b = run(), run()
			for i, npc in a do
				expect(npc.magic.mastery).toEqual(b[i].magic.mastery)
				expect(npc.magic.focus).toBe(b[i].magic.focus)
			end
			RelationshipGraph.clear()
		end)
		it("wakes a hidden mythic gift exactly once", function()
			local child = (NpcData.authored :: { any })[3]
			local npc = ready(NPCFactory.generate(SEED, settlement(18), 18, child))
			expect(NPCMagicLife.awaken(npc, 3, "test")).toBe(true)
			expect(npc.magic.awakened.domain).toBe("gravity")
			expect(table.find(npc.profile.manifest, "gravity") ~= nil).toBe(true)
			expect(NPCMagicLife.awaken(npc, 4, "again")).toBe(false)
		end)
	end)

	describe("DialogueEngine", function()
		it("says something deterministic on every topic", function()
			RelationshipGraph.clear()
			local npc = ready(NPCFactory.generate(SEED, settlement(18), 3))
			local env = { now = 10.5, hour = 12, nameOf = function(id: string): string
				return id
			end }
			local ctx = DialogueEngine.context(npc, "u:1", env)
			for _, topic in { "greet", "self", "magic", "rumor", "work", "learn", "farewell", "ambient" } do
				local line = DialogueEngine.line(npc, topic, ctx, 1)
				expect(#line > 0).toBe(true)
				expect(string.find(line, "{", 1, true) == nil and string.find(line, "<", 1, true) == nil or line).toBe(true)
				expect(DialogueEngine.line(npc, topic, ctx, 1)).toBe(line)
			end
		end)
	end)
end
