--!strict
--[[
	Marks.spec: the rules behind Magic Marks, with no live players (docs/MagicMarks.md). The ones that
	matter most: every domain can be drawn, written about and remarked on; marks need both points and
	a real share of your magic; spam and single days can't rush them; they fade without flickering;
	and the wire format can't be abused to claim more than the rules allow.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Flags = require(Server.Config.Flags)
local Schemas = require(Server.Persistence.Schemas)
local GreetingRules = require(Server.NPC.GreetingRules)
local BarkEngine = require(Server.NPC.BarkEngine)
local MarkLines = require(Server.NPC.Data.MarkLines)
local NpcData = require(Server.NPC.Data.NpcData)

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local MarkRules = require(Shared.Magic.MarkRules)
local MarkData = require(Shared.Magic.Data.Marks)

local T = MarkData.tuning

-- Casts `count` times into one domain over as many days as the daily cap needs.
local function castInto(record: MarkRules.Record, domains: { string }, count: number, startDay: number): number
	local day = startDay
	local done = 0
	while done < count do
		local added = MarkRules.addCast(record, domains, day)
		if added <= 0 then
			day += 1
		else
			done += 1
		end
	end
	return day
end

local function greeting(over: { [string]: any }): GreetingRules.Input
	local base: { [string]: any } = {
		settlement = 0,
		faction = 0,
		opinion = 0,
		infamy = 0,
		bounty = false,
		notoriety = 0,
		attuned = false,
		agreeable = 0.5,
		nervous = 0.5,
		child = false,
	}
	for key, value in over do
		base[key] = value
	end
	return base :: any
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Mark data", function()
		it("every domain has a look, phrases for each stage, and Journal lines for each stage and for fading", function()
			for _, id in Registry.domainIds do
				local def = MarkData.domains[id]
				expect(def ~= nil).toBe(true)
				expect(#def.seen).toBe(#T.stages)
				expect(#def.journal).toBe(#T.stages + 1)
				expect(def.unsettle >= 0 and def.unsettle <= 1).toBe(true)
				expect(def.look.alpha >= 0 and def.look.alpha < 1).toBe(true)
				expect(typeof(def.look.skin)).toBe("Color3")
				local ok = pcall(function()
					return (Enum.Material :: any)[def.look.material]
				end)
				expect(ok).toBe(true)
				if def.look.prints then
					expect(def.look.prints.life > 0).toBe(true)
				end
			end
		end)

		it("only domains that exist are listed", function()
			for id in MarkData.domains do
				expect(Registry.domains[id] ~= nil).toBe(true)
			end
		end)

		it("stages rise, and the thresholds and shares make sense", function()
			for i = 2, #T.stages do
				expect(T.stages[i] > T.stages[i - 1]).toBe(true)
				expect(T.npcTiers[i] >= T.npcTiers[i - 1]).toBe(true)
			end
			expect(T.dropAt > 0 and T.dropAt < 1).toBe(true)
			expect(T.keepShare < T.share).toBe(true)
			expect(T.share * T.maxMarks <= 1).toBe(true)
			expect(#T.npcTiers).toBe(#T.stages)
		end)

		it("is saved, and has a kill switch", function()
			local save = Schemas.Player.template().marks
			expect(typeof(save)).toBe("table")
			expect(typeof(save.points)).toBe("table")
			expect(typeof(save.shown)).toBe("table")
			expect(Flags.magic_marks_enabled ~= nil).toBe(true)
			expect(Flags.magic_marks_enabled.default).toBe(true)
		end)
	end)

	describe("Counting", function()
		it("a working spell adds a point; a hybrid splits it", function()
			local r = MarkRules.newRecord()
			expect(MarkRules.addCast(r, { "energy" }, 100)).toBeNear(T.perCast, 1e-9)
			expect(r.points.energy).toBeNear(T.perCast, 1e-9)
			MarkRules.addCast(r, { "energy", "water" }, 100)
			expect(r.points.energy).toBeNear(T.perCast * 1.5, 1e-9)
			expect(r.points.water).toBeNear(T.perCast * 0.5, 1e-9)
		end)

		it("ignores domains that don't exist", function()
			local r = MarkRules.newRecord()
			expect(MarkRules.addCast(r, { "nonsense" }, 100)).toBe(0)
			expect(next(r.points)).toBe(nil)
		end)

		it("one domain can't gain more than the daily cap in a day, and the cap resets the next day", function()
			local r = MarkRules.newRecord()
			for _ = 1, T.dayCap + 50 do
				MarkRules.addCast(r, { "earth" }, 200)
			end
			expect(r.points.earth).toBeNear(T.dayCap, 1e-6)
			expect(MarkRules.addCast(r, { "earth" }, 201) > 0).toBe(true)
		end)

		it("the first mark takes at least a day's cap's worth of play, the last at least a week", function()
			expect(T.stages[1] <= T.dayCap).toBe(true)
			expect(T.stages[#T.stages] / T.dayCap >= 6).toBe(true)
			t.log(string.format("  days of capped play per stage: %.1f / %.1f / %.1f",
				T.stages[1] / T.dayCap, T.stages[2] / T.dayCap, T.stages[3] / T.dayCap))
		end)
	end)

	describe("Stages", function()
		it("points earn stages at the thresholds", function()
			expect(MarkRules.stageFor(0, nil)).toBe(0)
			expect(MarkRules.stageFor(T.stages[1] - 1, nil)).toBe(0)
			expect(MarkRules.stageFor(T.stages[1], nil)).toBe(1)
			expect(MarkRules.stageFor(T.stages[3], nil)).toBe(3)
		end)

		it("a shown stage holds until points fall below threshold x dropAt", function()
			local justUnder = T.stages[2] - 1
			expect(MarkRules.stageFor(justUnder, 2)).toBe(2)
			expect(MarkRules.stageFor(T.stages[2] * T.dropAt - 1, 2)).toBe(1)
			expect(MarkRules.stageFor(T.stages[1] * T.dropAt - 1, 1)).toBe(0)
		end)

		it("needs a real share: a little of everything marks nobody", function()
			local r = MarkRules.newRecord()
			for _, id in Registry.domainIds do
				r.points[id] = T.stages[3]
			end
			local shown = MarkRules.evaluate(r)
			expect(next(shown)).toBe(nil)
		end)

		it("what you use most marks you, at most maxMarks", function()
			local r = MarkRules.newRecord()
			r.points.energy = T.stages[2]
			r.points.air = T.stages[2] * 0.7 -- stage 1, and about 40% of the total
			r.points.water = 10
			local shown = MarkRules.evaluate(r)
			expect(shown.energy).toBe(2)
			expect(shown.air).toBe(1)
			expect(shown.water).toBe(nil)
			local count = 0
			for _ in shown do
				count += 1
			end
			expect(count <= T.maxMarks).toBe(true)
		end)

		it("a shown mark keeps its place at a lower share than it took to gain", function()
			local r = MarkRules.newRecord()
			r.points.energy = 300
			r.points.water = 700 -- energy is 30%: too little to gain, enough to keep
			expect(MarkRules.evaluate(r).energy).toBe(nil)
			r.shown = { energy = 1 }
			expect(MarkRules.evaluate(r).energy).toBe(1)
		end)

		it("a week of capped casting reaches the last stage", function()
			local r = MarkRules.newRecord()
			castInto(r, { "life" }, T.stages[3], 1000)
			expect(MarkRules.evaluate(r).life).toBe(3)
		end)

		it("changes name what appeared, grew and faded", function()
			local changes = MarkRules.changes({ energy = 1, air = 2 }, { energy = 2, mind = 1 })
			expect(#changes).toBe(3)
			local byDomain: { [string]: MarkRules.Change } = {}
			for _, change in changes do
				byDomain[change.domain] = change
			end
			expect(byDomain.energy.to).toBe(2)
			expect(byDomain.air.to).toBe(0)
			expect(byDomain.mind.from).toBe(0)
			expect(MarkRules.journalLine("energy", 1, 2)).toBe(MarkData.domains.energy.journal[2])
			expect(MarkRules.journalLine("energy", 2, 1)).toBe(MarkData.domains.energy.journal[#T.stages + 1])
			expect(MarkRules.journalLine("energy", 2, 2)).toBe(nil)
		end)
	end)

	describe("Fading", function()
		it("unused points fade a little each day, and fully after long enough", function()
			local r = MarkRules.newRecord()
			MarkRules.decay(r, 500) -- the first call only starts the clock
			r.points.void = 1000
			MarkRules.decay(r, 501)
			expect(r.points.void).toBeNear(1000 * (1 - T.decayPerDay), 1e-6)
			MarkRules.decay(r, 501) -- same day: nothing more
			expect(r.points.void).toBeNear(1000 * (1 - T.decayPerDay), 1e-6)
			MarkRules.decay(r, 501 + 2000)
			expect(r.points.void).toBe(nil)
		end)

		it("a month away drops a fresh stage 3 mark no further than stage 2", function()
			local r = MarkRules.newRecord()
			r.points.time = T.stages[3] * 1.05
			r.shown = { time = 3 }
			r.decayDay = 1
			MarkRules.decay(r, 31)
			local stage = MarkRules.evaluate(r).time
			t.log(string.format("  stage 3 after 30 days away: points %.0f, stage %s", r.points.time or 0, tostring(stage)))
			expect(stage ~= nil and stage >= 2).toBe(true)
		end)
	end)

	describe("Wire format", function()
		it("round-trips, strongest first", function()
			local raw = MarkRules.encode({ water = 1, energy = 3 })
			expect(raw).toBe("energy:3,water:1")
			local marks = MarkRules.decode(raw)
			expect(marks[1].domain).toBe("energy")
			expect(marks[1].stage).toBe(3)
			expect(marks[2].domain).toBe("water")
		end)

		it("nothing encodes to nil", function()
			expect(MarkRules.encode({})).toBe(nil)
			expect(#MarkRules.decode(nil)).toBe(0)
			expect(#MarkRules.decode("")).toBe(0)
		end)

		it("junk, unknown domains, too many marks and stages past the last are refused", function()
			expect(#MarkRules.decode("hello")).toBe(0)
			expect(#MarkRules.decode("nonsense:3")).toBe(0)
			expect(#MarkRules.decode("energy:0")).toBe(0)
			expect(MarkRules.decode("energy:9")[1].stage).toBe(#T.stages)
			expect(#MarkRules.decode("energy:1,water:1,air:1,earth:1") <= T.maxMarks).toBe(true)
		end)
	end)

	describe("Perk and quirk", function()
		it("each stage resists your own domain a little more, and nothing else", function()
			local r = MarkRules.resist("energy:2")
			expect(r.energy).toBeNear(2 * T.resistPerStage, 1e-9)
			expect(r.water).toBe(nil)
			expect(next(MarkRules.resist(nil))).toBe(nil)
		end)

		it("strange marks unsettle; ordinary ones don't", function()
			expect(MarkRules.unsettle("energy:3")).toBe(0)
			expect(MarkRules.unsettle("void:3") > MarkRules.unsettle("void:1")).toBe(true)
			expect(MarkRules.unsettle("void:3") <= 1).toBe(true)
		end)

		it("a strange mark makes a nervous person warier, a calm one hardly at all", function()
			local unsettle = MarkRules.unsettle("void:3")
			local nervousDrop = GreetingRules.score(greeting({ nervous = 0.9 })) - GreetingRules.score(greeting({ nervous = 0.9, unsettle = unsettle }))
			local calmDrop = GreetingRules.score(greeting({ nervous = 0.1 })) - GreetingRules.score(greeting({ nervous = 0.1, unsettle = unsettle }))
			expect(nervousDrop > calmDrop).toBe(true)
			expect(calmDrop >= 0).toBe(true)
			-- Old callers without the field still work.
			expect(GreetingRules.score(greeting({}))).toBeNear(GreetingRules.score(greeting({ unsettle = 0 })), 1e-9)
		end)

		it("NPCs earn stages from their mastery tier", function()
			expect(MarkRules.npcStage(0)).toBe(0)
			expect(MarkRules.npcStage(T.npcTiers[1] - 1)).toBe(0)
			expect(MarkRules.npcStage(T.npcTiers[1])).toBe(1)
			expect(MarkRules.npcStage(8)).toBe(#T.stages)
		end)
	end)

	describe("What NPCs say", function()
		it("every domain has its own remark, and the shared categories have lines", function()
			local cats: { [string]: number } = {}
			for _, line in MarkLines do
				cats[line.cat] = (cats[line.cat] or 0) + 1
			end
			for _, id in Registry.domainIds do
				expect((cats["mark_" .. id] or 0) >= 3).toBe(true)
			end
			for _, cat in { "mark_any", "mark_kin", "mark_whisper" } do
				expect((cats[cat] or 0) >= 4).toBe(true)
			end
		end)

		it("uses only known vars and real occupations", function()
			local known = { town = true, name = true, player = true, mark = true }
			for _, line in MarkLines do
				for var in string.gmatch(line.text, "{(%a+)}") do
					if not known[var] then
						error(line.text .. ": unknown var " .. var)
					end
				end
				for _, occupation in (line.occ or {}) :: { string } do
					if not NpcData.occupations[occupation] then
						error(line.text .. ": no occupation " .. occupation)
					end
				end
			end
		end)

		it("an adult with no special traits always has something to say about any mark", function()
			local ctx: BarkEngine.Context = {
				hour = 12,
				occupation = "none",
				mood = "content",
				rel = "stranger",
				traits = {},
				quirks = {},
				events = {},
				child = false,
				mage = false,
				deeds = {},
				vars = { mark = "soot on the fingertips", name = "Ann", player = "You" },
			}
			for _, cat in { "mark_any", "mark_whisper" } do
				local _, text = BarkEngine.pick(cat, ctx, Random.new(1), {}, nil, MarkLines)
				expect(text ~= nil).toBe(true)
			end
		end)
	end)
end
