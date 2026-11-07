--!strict
--[[
	TownRepair.spec: how places recover, with no live world (docs/TownRepair.md). The ones that matter most:
	the right person comes, nobody who shouldn't be asked is, and every scar's quarters cover it.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Flags = require(Server.Config.Flags)
local Activities = require(Server.NPC.Data.Activities)
local FireSim = require(Server.Magic.Cast.FireSim)
local Data = require(Server.Towns.Data.Repair)
local Rules = require(Server.Towns.RepairRules)

local T = Data.tuning

local function person(id: string, occupation: string, distance: number, available: boolean?): Rules.Candidate
	return { id = id, occupation = occupation, distance = distance, available = available ~= false }
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Burned ground", function()
		it("only grass burns bare", function()
			expect(Rules.scorches("Grass")).toBe(true)
			expect(Rules.scorches("LeafyGrass")).toBe(true)
			expect(Rules.scorches("Rock")).toBe(false)
			expect(Rules.scorches("Ground")).toBe(false)
		end)

		it("regrows in four quarters that cover the scar", function()
			local spots = Rules.quarters(100, 200, 8)
			expect(#spots).toBe(4)
			local seen: { [string]: boolean } = {}
			for _, spot in spots do
				expect(math.abs(spot.x - 100)).toBe(2)
				expect(math.abs(spot.z - 200)).toBe(2)
				seen[spot.x .. "," .. spot.z] = true
			end
			local count = 0
			for _ in seen do
				count += 1
			end
			expect(count).toBe(4)
		end)

		it("comes back over time, each quarter at its own moment, and the same way every run", function()
			local a, b = Rules.healTimes(50, Random.new(9)), Rules.healTimes(50, Random.new(9))
			for i = 1, 4 do
				expect(a[i]).toBe(b[i])
				expect(a[i] >= 50 + T.healMin).toBe(true)
				expect(a[i] <= 50 + T.healMin + T.healSpread).toBe(true)
			end
			expect(a[1] == a[2] and a[2] == a[3]).toBe(false)
		end)
	end)

	describe("What recovers by itself", function()
		it("nobody hammers a tree, but they do mend a fence or a house", function()
			expect(Rules.isLiving("tree")).toBe(true)
			expect(Rules.isLiving("Hedge_02")).toBe(true)
			expect(Rules.isLiving("fence")).toBe(false)
			expect(Rules.isLiving("HouseMedium_07")).toBe(false)
			expect(Rules.isLiving("Smithy_01")).toBe(false)
		end)
	end)

	describe("Collapsed buildings", function()
		local function piece(name: string, y: number): any
			return { at = CFrame.new(0, y, 0), part = { Name = name } }
		end

		it("goes back up from the ground: the list is worked from its end", function()
			local pieces = { piece("roof", 30), piece("floor", 2), piece("wall", 10) }
			Rules.rebuildOrder(pieces)
			expect(pieces[#pieces].part.Name).toBe("floor")
			expect(pieces[#pieces - 1].part.Name).toBe("wall")
			expect(pieces[1].part.Name).toBe("roof")
		end)

		it("puts pieces at the same height in a steady order", function()
			local a, b = { piece("a", 5), piece("b", 5) }, { piece("b", 5), piece("a", 5) }
			Rules.rebuildOrder(a)
			Rules.rebuildOrder(b)
			expect(a[1].part.Name).toBe(b[1].part.Name)
		end)

		it("takes its time, and longer with nobody on it", function()
			expect(T.rebuildDelay > 0).toBe(true)
			expect(T.rebuildSeconds > T.workSeconds).toBe(true)
			expect(T.rebuildOffscreenSeconds > T.rebuildSeconds).toBe(true)
		end)

		it("has its own words", function()
			expect(#Data.lines.rebuildStart > 0 and #Data.lines.rebuildFinish > 0).toBe(true)
		end)
	end)

	describe("A building's footprint", function()
		it("comes from where the pieces belong", function()
			local f = Rules.footprint({ Vector3.new(0, 0, 0), Vector3.new(10, 5, 20) })
			expect(f.x).toBe(5)
			expect(f.z).toBe(10)
			expect(f.hx).toBe(5)
			expect(f.hz).toBe(10)
			expect(Rules.inside(f, Vector3.new(5, 0, 10))).toBe(true)
			expect(Rules.inside(f, Vector3.new(50, 0, 10))).toBe(false)
		end)

		it("survives having no pieces", function()
			expect(Rules.footprint({}).hx).toBe(0)
		end)

		it("allows for a turned building", function()
			local f = Rules.footprintOf(CFrame.Angles(0, math.pi / 2, 0), Vector3.new(10, 4, 20))
			expect(math.abs(f.hx - 10) < 0.01).toBe(true)
			expect(math.abs(f.hz - 5) < 0.01).toBe(true)
		end)
	end)

	describe("Stray parts", function()
		local house: Rules.Footprint = { x = 0, z = 0, hx = 10, hz = 8 }

		it("one far-off part doesn't change how tall a building is", function()
			local base, top, strays = Rules.heightsWithin(house, { Vector3.new(0, 60, 0), Vector3.new(5, 75, 5), Vector3.new(900, 400, -900) }, 6)
			expect(base).toBe(60)
			expect(top).toBe(75)
			expect(strays).toBe(1)
		end)

		it("counts a part just outside the lot as part of it", function()
			local _, top, strays = Rules.heightsWithin(house, { Vector3.new(0, 60, 0), Vector3.new(14, 70, 0) }, 6)
			expect(top).toBe(70)
			expect(strays).toBe(0)
		end)

		it("survives nothing being near it", function()
			local base, top, strays = Rules.heightsWithin(house, { Vector3.new(900, 1, 0) }, 6)
			expect(base).toBe(0)
			expect(top).toBe(0)
			expect(strays).toBe(1)
		end)

		it("a scaffold planned from a lot stays the size of the lot", function()
			local lot = Rules.footprintOf(CFrame.new(100, 60, 100), Vector3.new(30, 0, 24))
			for _, piece in Rules.scaffoldPlan(lot, 60, 80) do
				expect(math.abs(piece.position.X - 100) <= 15 + Data.scaffold.margin).toBe(true)
				expect(math.abs(piece.position.Z - 100) <= 12 + Data.scaffold.margin).toBe(true)
				expect(piece.size.Magnitude < 60).toBe(true)
			end
		end)
	end)

	describe("Scaffolding", function()
		local house: Rules.Footprint = { x = 0, z = 0, hx = 10, hz = 8 }

		it("stands outside the building, with poles and planks", function()
			local poles, planks = 0, 0
			for _, piece in Rules.scaffoldPlan(house, 60, 80) do
				if piece.kind == "Pole" then
					poles += 1
					expect(Rules.inside(house, piece.position)).toBe(false)
				else
					planks += 1
				end
			end
			expect(poles >= 4).toBe(true)
			expect(planks >= 4).toBe(true)
		end)

		it("doesn't grow without limit on something very tall", function()
			local plan = Rules.scaffoldPlan(house, 0, 1000)
			expect(#plan <= 8 + Data.scaffold.maxLevels * 4).toBe(true)
		end)

		it("a low building gets poles and no platforms", function()
			for _, piece in Rules.scaffoldPlan(house, 60, 62) do
				expect(piece.kind).toBe("Pole")
			end
		end)
	end)

	describe("People whose building came down", function()
		it("have words for it, and the friend's name fits", function()
			for _, line in Data.lines.homeLostFriend do
				expect(string.find(line, "%s", 1, true) ~= nil).toBe(true)
			end
			for _, kind in { "homeLost", "workLost", "homeBack" } do
				expect(#(Data.lines :: any)[kind] > 0).toBe(true)
				for _, line in (Data.lines :: any)[kind] do
					expect(string.find(line, "%", 1, true)).toBe(nil)
				end
			end
		end)
	end)

	describe("Damaged but standing", function()
		it("recovers a little at a time, and never past whole", function()
			local after, gained = Rules.mended(50)
			expect(after).toBe(50 + T.mendAmount)
			expect(gained).toBe(T.mendAmount)
			local full, none = Rules.mended(T.wholeIntegrity)
			expect(full).toBe(T.wholeIntegrity)
			expect(none).toBe(0)
		end)

		it("only gains what it's missing", function()
			local after, gained = Rules.mended(T.wholeIntegrity - 0.25)
			expect(after).toBe(T.wholeIntegrity)
			expect(gained).toBe(0.25)
		end)
	end)

	describe("Who comes to fix it", function()
		it("the builder before anyone else, even from further off", function()
			expect(Rules.pickWorker({ person("a", "farmer", 5), person("b", "builder", 90) })).toBe("b")
		end)

		it("the closest of the same trade", function()
			expect(Rules.pickWorker({ person("a", "builder", 50), person("b", "builder", 10) })).toBe("b")
		end)

		it("anyone at all, if no one with a trade is free", function()
			expect(Rules.pickWorker({ person("a", "builder", 5, false), person("b", "scholar", 40) })).toBe("b")
		end)

		it("never a child, a retired person or a guard", function()
			expect(Rules.pickWorker({ person("a", "child", 1), person("b", "retired", 1), person("c", "guard", 1) })).toBe(nil)
		end)

		it("nobody, if nobody's free", function()
			expect(Rules.pickWorker({})).toBe(nil)
			expect(Rules.pickWorker({ person("a", "builder", 5, false) })).toBe(nil)
		end)

		it("doesn't depend on the order people are listed in", function()
			local a = person("a", "builder", 10)
			local b = person("b", "builder", 10)
			expect(Rules.pickWorker({ a, b })).toBe(Rules.pickWorker({ b, a }))
		end)

		it("stands outside the building, on the side they came from", function()
			local house: Rules.Footprint = { x = 0, z = 0, hx = 10, hz = 6 }
			local spot = Rules.spotAround(house, Vector3.new(50, 60, 0), 0)
			expect(spot.X).toBe(10 + T.stepOff)
			expect(spot.Z).toBe(0)
			expect(spot.Y).toBe(60)
			expect(Rules.inside(house, spot)).toBe(false)
		end)

		it("is never inside it, from anywhere and on any side: that's how the builder got walled in", function()
			local house: Rules.Footprint = { x = 5, z = -3, hx = 8, hz = 12 }
			for _, from in { Vector3.new(5, 0, -3), Vector3.new(6, 0, 0), Vector3.new(100, 0, 3), Vector3.new(-40, 0, -90) } do
				for turn = 0, 3 do
					expect(Rules.inside(house, Rules.spotAround(house, from, turn))).toBe(false)
				end
			end
		end)

		it("works its way round: four turns visit four different sides", function()
			local house: Rules.Footprint = { x = 0, z = 0, hx = 10, hz = 10 }
			local seen: { [string]: boolean } = {}
			for turn = 0, 3 do
				local spot = Rules.spotAround(house, Vector3.new(50, 0, 0), turn)
				seen[spot.X .. "," .. spot.Z] = true
			end
			local count = 0
			for _ in seen do
				count += 1
			end
			expect(count).toBe(4)
		end)
	end)

	describe("What a repair looks like", function()
		it("a repaired part stays a little different from what it was", function()
			local original = Color3.fromRGB(90, 60, 40)
			local fresh = Rules.freshColor(original)
			expect(fresh == original).toBe(false)
			local gap = math.abs(fresh.R - original.R) + math.abs(fresh.G - original.G) + math.abs(fresh.B - original.B)
			expect(gap < 0.4).toBe(true)
		end)
	end)

	describe("Wiring", function()
		it("has its flag, the hammer clip and its words", function()
			expect((Flags :: any).town_repair_enabled ~= nil).toBe(true)
			expect(Activities.Clips.hammer ~= nil).toBe(true)
			expect(Activities.Props.hammer ~= nil).toBe(true)
			expect(#Data.lines.start > 0 and #Data.lines.finish > 0).toBe(true)
		end)

		it("FireSim has somewhere to report burning to", function()
			expect((FireSim :: any).igniteGround ~= nil).toBe(true)
			local before = FireSim.onCharred
			FireSim.onCharred = function() end
			expect(FireSim.onCharred ~= nil).toBe(true)
			FireSim.onCharred = before
		end)
	end)
end
