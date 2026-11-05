--!strict
-- Unit specs for the quest system's data and pure rules (docs/Quests.md): every template is
-- internally consistent, factions reference real factions, and creative casts are recognised.

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local QuestTemplates = require(Server.Quests.Data.QuestTemplates)
local Factions = require(Server.Quests.Data.Factions)
local SituationDetector = require(Server.Quests.SituationDetector)
local Objectives = require(Server.Quests.Objectives)
local QuestFactory = require(Server.Quests.QuestFactory)

local KINDS = { talk = true, reach = true, cast = true, subdue = true, escort = true, collect = true, deliver = true, demonstrate = true, wait = true, witness = true, pay = true, state = true }

local function cast(fields: { [string]: any }): any
	local c: any = {
		casterUserId = 1, point = Vector3.zero, domains = { "water" }, branch = "water", branchPath = { "water" },
		property = "humidity", verb = "generate", form = "burst", route = "pour", power = 4, tags = { "water" },
		effective = true, hits = 0, harmful = false,
	}
	for k, v in fields do
		c[k] = v
	end
	return c
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Quest templates", function()
		it("has at least fifteen", function()
			expect(#QuestTemplates.list >= 15).toBe(true)
		end)
		it("are internally consistent", function()
			for _, template in QuestTemplates.list do
				local function fail(what: string)
					error(template.id .. ": " .. what, 0)
				end
				local stages: { [string]: boolean } = {}
				for _, stage in template.stages do
					stages[stage.id] = true
				end
				if #template.stages == 0 then
					fail("no stages")
				end
				for _, kind in template.situations do
					if not table.find(SituationDetector.KINDS, kind) then
						fail("unknown situation " .. kind)
					end
				end
				if not template.outcomes[template.failOutcome] then
					fail("failOutcome " .. template.failOutcome)
				end
				if template.giver and not template.slots[template.giver] then
					fail("giver slot " .. template.giver)
				end
				local function slotExists(name: string?): boolean
					return name == nil or template.slots[name] ~= nil or (template.spawns ~= nil and template.spawns[name] ~= nil)
				end
				for _, stage in template.stages do
					if #stage.options == 0 then
						fail("stage " .. stage.id .. " has no options")
					end
					if stage.failOnDeath and not template.outcomes[stage.failOnDeath] then
						fail("failOnDeath " .. stage.failOnDeath)
					end
					for _, option in stage.options do
						if (option.outcome == nil) == (option.next == nil) then
							fail(option.id .. " needs exactly one of outcome / next")
						end
						if option.outcome and not template.outcomes[option.outcome] then
							fail(option.id .. " -> missing outcome " .. option.outcome)
						end
						if option.next and not stages[option.next] then
							fail(option.id .. " -> missing stage " .. option.next)
						end
						for _, spec in option.objectives do
							if not KINDS[spec.kind] then
								fail("objective kind " .. spec.kind)
							end
							if not slotExists(spec.target) or not slotExists(spec.at) then
								fail(option.id .. "/" .. spec.id .. " names a missing slot")
							end
							if spec.onNoticed and not template.outcomes[spec.onNoticed] then
								fail("onNoticed " .. spec.onNoticed)
							end
						end
					end
				end
				for _, extra in { template.npcSolve and template.npcSolve.outcome, template.escalation and template.escalation.outcome, template.protectOutcome } do
					if extra and not template.outcomes[extra] then
						fail("missing outcome " .. extra)
					end
				end
				for _, outcome in template.outcomes do
					for key in (outcome.rewards and outcome.rewards.reputation or {}) :: { [string]: number } do
						if key ~= "settlement" and not Factions.factions[key] then
							fail("reputation for unknown faction " .. key)
						end
					end
				end
			end
			expect(true).toBe(true)
		end)
		it("offers more than one way through every decisive stage", function()
			for _, template in QuestTemplates.list do
				local last = template.stages[#template.stages]
				expect(#last.options >= 2).toBe(true)
			end
		end)
	end)

	describe("Factions", function()
		it("only relate to factions that exist", function()
			for id, f in Factions.factions do
				for other in f.relations do
					if not Factions.factions[other] then
						error(id .. " relates to unknown " .. other, 0)
					end
				end
			end
			expect(true).toBe(true)
		end)
		it("has ranks from highest to lowest", function()
			for i = 2, #Factions.ranks do
				expect(Factions.ranks[i].min < Factions.ranks[i - 1].min).toBe(true)
			end
		end)
	end)

	describe("Objectives", function()
		it("counts a listed solution in full", function()
			local spec: any = { kind = "cast", id = "x", text = "", amount = 10, match = { domains = { "water" } }, needs = { "water" } }
			local gain, creative = Objectives.castGain(spec, cast({}))
			expect(gain).toBe(4)
			expect(creative).toBe(false)
		end)
		it("recognises a creative solution by its interaction tags", function()
			-- Freezing a flood: not the listed earth wall, but "ice" meets the needs.
			local spec: any = { kind = "cast", id = "x", text = "", count = 3, match = { forms = { "wall" } }, needs = { "stone", "ice" } }
			local gain, creative = Objectives.castGain(spec, cast({ form = "zone", tags = { "ice" } }))
			expect(gain > 0).toBe(true)
			expect(creative).toBe(true)
		end)
		it("ignores casts that did nothing", function()
			local spec: any = { kind = "cast", id = "x", text = "", amount = 10, match = { domains = { "water" } } }
			expect((Objectives.castGain(spec, cast({ effective = false })))).toBe(0)
		end)
		it("respects ordered options", function()
			local option: any = { id = "o", ordered = true, objectives = { { kind = "talk", id = "a", text = "" }, { kind = "talk", id = "b", text = "" } } }
			expect(#Objectives.open(option, {})).toBe(1)
			expect(Objectives.open(option, { ["o/a"] = 1 })[1].id).toBe("b")
		end)
	end)

	describe("Quest text", function()
		it("fills names and ids", function()
			local quest: any = { slots = { branch = "alloycraft", town = "s1" }, names = { giver = "Hedda", town_name = "Emberfall" } }
			expect(QuestFactory.text(quest, "{giver} of {town_name}")).toBe("Hedda of Emberfall")
			expect(QuestFactory.fill(quest, "treatise:{branch}")).toBe("treatise:alloycraft")
		end)
	end)
end
