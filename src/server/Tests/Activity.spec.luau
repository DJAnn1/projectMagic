--!strict
--[[
	Activity.spec: readable NPC activities with no live world (docs/Activities.md). The ones that matter
	most: every activity has everything it needs to be seen, the replicated record survives the trip, and
	the right person is doing the right thing.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local ActivityLibrary = require(Shared.Life.Data.ActivityLibrary)
local ActivityPoses = require(Shared.Life.Data.ActivityPoses)
local ActivityState = require(Shared.Life.ActivityState)
local HeldProps = require(Shared.Life.Data.HeldProps)
local StationTypes = require(Shared.Life.Data.StationTypes)
local Registry = require(Shared.Magic.Registry)

local Server = ServerScriptService.Server
local NeedsActions = require(Server.NPC.Data.NeedsActions)
local Activities = require(Server.NPC.Data.Activities)
local ActivityRules = require(Server.Life.ActivityRules)
local ReadabilityReport = require(Server.Life.ReadabilityReport)

local SET_PIECES = { furrows = true, swept = true, logpile = true, fishing = true, blanket = true, practice_energy = true, practice_earth = true, practice_water = true }
local VFX = { flour = true, dust = true, dirt = true, chips = true, prayer = true }
local SPOTS = { route = true, door = true, yard = true, patrol = true }
local INTERRUPTS = { hold = true, setDown = true, stay = true }
local JOINTS = { ["Right Shoulder"] = true, ["Left Shoulder"] = true, ["Right Hip"] = true, ["Left Hip"] = true, ["Neck"] = true, ["RootJoint"] = true }

local function rootBranch(domain: string): string
	for id, branch in Registry.branches do
		if branch.isRoot and branch.domains[1] == domain then
			return id
		end
	end
	error("no root branch for " .. domain)
end

local function person(overrides: { [string]: any }): any
	local base: any = {
		id = "test#1", seed = 4242, name = "Marta", occupation = "smith", occupationName = "Smith", ageBand = "adult",
		traits = { extraversion = 0.5, conscientiousness = 0.5 }, needs = { food = 0.8, rest = 0.8, safety = 1 },
		magic = { mastery = {}, unlocked = {} },
	}
	for k, v in overrides do
		base[k] = v
	end
	return base
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Activity library", function()
		it("has at least the fifteen first-stage activities, each id once, indexed in order", function()
			expect(#ActivityLibrary.list >= 15).toBe(true)
			local seen: { [string]: boolean } = {}
			for i, def in ActivityLibrary.list do
				expect(seen[def.id]).toBe(nil)
				seen[def.id] = true
				expect(def.index).toBe(i)
				expect(ActivityLibrary.byIndex[i]).toBe(def)
			end
		end)

		it("serves only real brain actions", function()
			for _, def in ActivityLibrary.list do
				for _, action in def.actions do
					expect(NeedsActions.actions[action] ~= nil).toBe(true)
				end
			end
		end)

		it("names props, poses, stations, set pieces and effects that exist", function()
			for _, def in ActivityLibrary.list do
				for _, id in { def.props.right, def.props.left } :: { string? } do
					if id then
						expect(HeldProps.get(id) ~= nil).toBe(true)
					end
				end
				expect(ActivityPoses.poses[def.pose] ~= nil).toBe(true)
				if def.clip then
					expect(ActivityPoses.slots[def.clip] ~= nil).toBe(true)
				end
				if def.station then
					expect(StationTypes.types[def.station] ~= nil).toBe(true)
				else
					expect(SPOTS[def.spot or ""] == true).toBe(true)
				end
				if def.setPiece then
					expect(SET_PIECES[def.setPiece]).toBe(true)
				end
				for _, v in def.vfx do
					expect(VFX[v]).toBe(true)
				end
				expect(INTERRUPTS[def.interrupt]).toBe(true)
			end
		end)

		it("has sensible durations and the words a tooltip needs", function()
			for _, def in ActivityLibrary.list do
				expect(def.minutes[1] > 0 and def.minutes[2] >= def.minutes[1]).toBe(true)
				expect(def.seen ~= "" and def.doing ~= "" and def.tell ~= "" and def.learn ~= "").toBe(true)
				if string.find(def.doing, "{item}", 1, true) then
					expect(def.items ~= nil and #(def.items :: { string }) > 0).toBe(true)
					expect(string.find(ActivityLibrary.doingText(def, 1), "{item}", 1, true)).toBe(nil)
				end
			end
		end)

		it("passes the Readability Report's data checks (sound is a later stage)", function()
			for _, def in ActivityLibrary.list do
				local checks = ReadabilityReport.checks(def)
				for _, k in { "station", "props", "animation", "tooltip" } do
					if not checks[k].ok then
						t.log(def.id .. " " .. k .. ": " .. checks[k].text)
					end
					expect(checks[k].ok).toBe(true)
				end
			end
		end)

		it("keeps the server's clip table and the shared slots as one table", function()
			expect(Activities.Clips).toBe(ActivityPoses.slots)
			expect(ActivityPoses.hasClip("hammer")).toBe(true)
			expect(ActivityPoses.hasClip("talk")).toBe(false)
		end)
	end)

	describe("Poses", function()
		it("move only R6 joints and have variants", function()
			for _, pose in ActivityPoses.poses do
				for joint in pose.joints do
					expect(JOINTS[joint]).toBe(true)
				end
				for _, m in pose.motion do
					expect(JOINTS[m.joint]).toBe(true)
				end
				expect(#pose.variants >= 2).toBe(true)
				expect(pose.period > 0).toBe(true)
			end
		end)

		it("land a strike once per period, at the period's end", function()
			expect(ActivityPoses.wave("strike", 0, 1)).toBeNear(0, 1e-6)
			expect(ActivityPoses.wave("strike", 0.7, 1)).toBeNear(1, 1e-6)
			expect(ActivityPoses.wave("strike", 0.85, 1)).toBeNear(0.5, 1e-6)
			expect(ActivityPoses.strikesBetween(0.5, 1.5, 1)).toBe(1)
			expect(ActivityPoses.strikesBetween(0.1, 0.9, 1)).toBe(0)
			expect(ActivityPoses.strikesBetween(0.1, 3.2, 1.1)).toBe(2)
		end)
	end)

	describe("The replicated record", function()
		it("survives encode and decode", function()
			local s = ActivityState.new(3, 1000.25)
			s.phase = "W"
			s.start = 990.5
			s.duration = 120
			s.station = "settlement_1:lot4:anvil1"
			s.reason = "shift"
			s.variant = 2
			s.item = 5
			s.tier = 7
			s.domain = "energy"
			local back = ActivityState.decode(ActivityState.encode(s)) :: ActivityState.State
			expect(back ~= nil).toBe(true)
			for _, k in { "index", "phase", "station", "reason", "variant", "item", "tier", "domain" } do
				expect((back :: any)[k]).toBe((s :: any)[k])
			end
			expect(back.start).toBeNear(990.5, 0.01)
			expect(back.duration).toBeNear(120, 0.05)
		end)

		it("refuses what isn't a record", function()
			expect(ActivityState.decode(nil)).toBe(nil)
			expect(ActivityState.decode("")).toBe(nil)
			expect(ActivityState.decode("1|Q|0|0|0||||||")).toBe(nil)
			expect(ActivityState.decode(42)).toBe(nil)
		end)

		it("loops progress per piece of work and freezes it while interrupted", function()
			local s = ActivityState.new(1, 0)
			s.phase = "W"
			s.start = 100
			s.duration = 50
			local p, pieces = ActivityState.progress(s, 175)
			expect(pieces).toBe(1)
			expect(p).toBeNear(0.5, 1e-6)
			s.phase = "I"
			s.phaseAt = 120
			local frozen = ActivityState.progress(s, 500)
			expect(frozen).toBeNear(0.4, 1e-6)
			s.phase = "T"
			expect((ActivityState.progress(s, 500))).toBe(0)
		end)

		it("eases the pose in and out, and puts props away part-way through finishing", function()
			local s = ActivityState.new(1, 0)
			s.phase = "P"
			s.phaseAt = 10
			expect(ActivityState.weight(s, 10)).toBe(0)
			expect(ActivityState.weight(s, 10 + ActivityState.PREPARE_SECONDS)).toBe(1)
			s.phase = "F"
			expect(ActivityState.propsOut(s, 10.1, false, "hold")).toBe(true)
			expect(ActivityState.propsOut(s, 10 + ActivityState.FINISH_SECONDS, false, "hold")).toBe(false)
			s.phase = "I"
			expect(ActivityState.propsOut(s, 11, false, "hold")).toBe(true)
			expect(ActivityState.propsOut(s, 11, false, "setDown")).toBe(false)
			s.phase = "T"
			expect(ActivityState.propsOut(s, 11, true, "hold")).toBe(true)
			expect(ActivityState.propsOut(s, 11, false, "hold")).toBe(false)
		end)

		it("carries what a station is making", function()
			local index, start, duration, item = StationTypes.decodeWork(StationTypes.encodeWork(2, 55.5, 90, 3))
			expect(index).toBe(2)
			expect(start).toBeNear(55.5, 0.05)
			expect(duration).toBeNear(90, 0.05)
			expect(item).toBe(3)
			expect((StationTypes.decodeWork(""))).toBe(nil)
		end)
	end)

	describe("Who does what", function()
		it("gives each trade its own work", function()
			local cases = { smith = "forging", farmer = "farming", guard = "patrolling", fisher = "fishing", innkeeper = "baking" }
			for occupation, expected in cases do
				local def = ActivityRules.pick(person({ occupation = occupation }), "work", 10)
				expect(def ~= nil and def.id).toBe(expected)
			end
			expect(ActivityRules.pick(person({ occupation = "merchant" }), "work", 10)).toBe(nil)
		end)

		it("sends sociable people to the tavern to eat and quiet ones home", function()
			local out = ActivityRules.pick(person({ traits = { extraversion = 0.9 } }), "eat", 3)
			local home = ActivityRules.pick(person({ traits = { extraversion = 0.2 } }), "eat", 3)
			expect(out and out.id).toBe("eating_tavern")
			expect(home and home.id).toBe("eating_home")
		end)

		it("practises in the domain they're strongest in", function()
			for _, domain in { "energy", "earth", "water" } do
				local npc = person({ magic = { mastery = { [rootBranch(domain)] = 40 }, unlocked = { [rootBranch(domain)] = true } } })
				local def = ActivityRules.pick(npc, "practice", 1)
				expect(def and def.id).toBe("practice_" .. domain)
				local d, tier = ActivityRules.bestDomain(npc)
				expect(d).toBe(domain)
				expect(tier >= 1).toBe(true)
			end
		end)

		it("helps the same way all day, and differently across people and days", function()
			local a = ActivityRules.pick(person({ seed = 11 }), "help", 5)
			expect(ActivityRules.pick(person({ seed = 11 }), "help", 5)).toBe(a)
			local kinds: { [string]: boolean } = {}
			for seed = 1, 40 do
				local def = ActivityRules.pick(person({ seed = seed }), "help", seed)
				if def then
					kinds[def.id] = true
				end
			end
			expect(kinds.sweeping).toBe(true)
			expect(kinds.chopping).toBe(true)
		end)

		it("knows why", function()
			expect(ActivityRules.reason(person({ needs = { food = 0.1 } }), "eat", "meal")).toBe("hungry")
			expect(ActivityRules.reason(person({}), "eat", "meal")).toBe("mealtime")
			expect(ActivityRules.reason(person({}), "work", "free")).toBe("overtime")
			expect(ActivityRules.reason(person({ occupation = "guard" }), "work", "work")).toBe("watch")
			expect(ActivityRules.reason(person({ needs = { safety = 0.3 } }), "worship", "worship")).toBe("frightened")
		end)
	end)

	describe("Observe", function()
		it("shows strangers less, and more the longer you watch or the better you know them", function()
			expect(ActivityRules.knowledge("stranger", 0, 0)).toBe(0)
			expect(ActivityRules.knowledge("stranger", 0, ActivityRules.WATCH_SECONDS)).toBe(1)
			expect(ActivityRules.knowledge("acquaintance", 0, 0)).toBe(1)
			expect(ActivityRules.knowledge("friend", 0, 0)).toBe(2)
			expect(ActivityRules.knowledge("stranger", 5, ActivityRules.WATCH_SECONDS)).toBe(2)
			expect(ActivityRules.knowledge("hostile", 9, 60)).toBe(1)
		end)

		it("hides a stranger's name and gives a known person's reason", function()
			local npc = person({ traits = { conscientiousness = 0.9 } })
			local def = ActivityLibrary.byId.forging
			local opts = { detail = "Standard", progress = 0.5, phase = "W", item = 1, reason = "shift" }
			local t0, l0 = ActivityRules.describe(npc, def, 0, opts)
			expect(string.find(t0, "Marta", 1, true)).toBe(nil)
			expect(l0).toBe(def.seen)
			local t2, l2 = ActivityRules.describe(npc, def, 2, opts)
			expect(string.find(t2, "Marta", 1, true) ~= nil).toBe(true)
			expect(string.find(l2, "plowshare", 1, true) ~= nil).toBe(true)
			expect(string.find(l2, "on shift", 1, true) ~= nil).toBe(true)
			expect(string.find(l2, "with great care", 1, true) ~= nil).toBe(true)
			local _, minimal = ActivityRules.describe(npc, def, 2, { detail = "Minimal", progress = 0.5, phase = "W", item = 1, reason = "shift" })
			expect(string.find(minimal, "on shift", 1, true)).toBe(nil)
			local _, detailed = ActivityRules.describe(npc, def, 2, { detail = "Detailed", progress = 0.9, phase = "W", item = 1, reason = "shift" })
			expect(string.find(detailed, "nearly done", 1, true) ~= nil).toBe(true)
		end)
	end)
end
