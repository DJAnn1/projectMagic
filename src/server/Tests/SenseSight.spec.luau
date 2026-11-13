--!strict
--[[
	SenseSight.spec: Sense spells show the world (docs/SenseSight.md). What matters most: every
	sight kind names real properties and has its words; a property maps to one kind at most; reach
	and duration grow with power and stop at their caps; a ley line is clipped to exactly the part
	inside the circle; footprints are left only by real movement on the ground, are never your own,
	come newest first and fade out of the store; and the Composer says what each Sense spell shows.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local SpellOutcome = require(Shared.Magic.SpellOutcome)
local SenseRules = require(Shared.Magic.SenseRules)
local Data = require(Shared.Magic.Data.SenseSight)
local Flags = require(ServerScriptService.Server.Config.Flags)

local function near(a: number, b: number): boolean
	return math.abs(a - b) < 1e-6
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Sense sight data", function()
		it("every kind names real properties, each property in one kind at most, with all its words", function()
			local owner: { [string]: string } = {}
			for _, kindId in Data.order do
				local kind = Data.kinds[kindId]
				expect(kind ~= nil).toBe(true)
				expect(#kind.properties > 0).toBe(true)
				for _, property in kind.properties do
					expect(Registry.properties[property] ~= nil).toBe(true)
					expect(owner[property]).toBe(nil)
					owner[property] = kindId
					expect(SenseRules.kindFor(property)).toBe(kindId)
				end
				expect(#kind.summary > 20 and #kind.journal > 40 and #kind.found > 5 and #kind.empty > 5).toBe(true)
			end
			expect(SenseRules.kindFor("pressure")).toBe(nil)
			expect((Flags :: any).sense_sight_enabled ~= nil).toBe(true)
		end)
	end)

	describe("Sense sight reach", function()
		it("radius and duration grow with power, stop at their caps, and a wider spell area wins", function()
			expect(SenseRules.radiusFor(4, nil) > SenseRules.radiusFor(1, nil)).toBe(true)
			expect(SenseRules.radiusFor(100, nil)).toBe(Data.radius.max)
			expect(SenseRules.radiusFor(1, 70)).toBe(70)
			expect(SenseRules.durationFor(4) > SenseRules.durationFor(1)).toBe(true)
			expect(SenseRules.durationFor(100)).toBe(Data.duration.max)
		end)
	end)

	describe("Ley line clipping", function()
		it("keeps a segment inside the circle whole, cuts a crossing one at the edge, drops a miss", function()
			local x1, z1, x2, z2 = SenseRules.clipSegment(-5, 0, 5, 0, 0, 0, 10)
			expect(near(x1 :: number, -5) and near(z1 :: number, 0) and near(x2 :: number, 5) and near(z2 :: number, 0)).toBe(true)

			x1, z1, x2, z2 = SenseRules.clipSegment(-50, 0, 50, 0, 0, 0, 10)
			expect(near(x1 :: number, -10) and near(x2 :: number, 10)).toBe(true)

			x1, z1, x2, z2 = SenseRules.clipSegment(0, 0, 50, 0, 0, 0, 10) -- starts inside, leaves
			expect(near(x1 :: number, 0) and near(x2 :: number, 10)).toBe(true)

			x1 = SenseRules.clipSegment(-50, 20, 50, 20, 0, 0, 10) -- passes by
			expect(x1).toBe(nil)
			x1 = SenseRules.clipSegment(20, 0, 50, 0, 0, 0, 10) -- the line would cross, the segment doesn't
			expect(x1).toBe(nil)
		end)
	end)

	describe("Tracks", function()
		it("leaves a print only after real movement on the ground, never your own, newest first", function()
			local store = SenseRules.newTracks()
			local step = Data.tracks.minStep
			store:step("a", Vector3.new(0, 0, 0), 0, "person", true) -- first sighting: no print yet
			expect(store:count()).toBe(0)
			store:step("a", Vector3.new(step * 0.5, 0, 0), 1, "person", true) -- shuffled in place
			expect(store:count()).toBe(0)
			store:step("a", Vector3.new(step * 1.2, 0, 0), 2, "person", true)
			expect(store:count()).toBe(1)
			store:step("a", Vector3.new(step * 2.4, 0, 0), 3, "person", false) -- flying: moved, no print
			expect(store:count()).toBe(1)
			store:step("a", Vector3.new(step * 3.6, 0, 0), 4, "person", true)
			expect(store:count()).toBe(2)

			store:step("b", Vector3.new(0, 0, 2), 0, "beast", true)
			store:step("b", Vector3.new(0, 0, 2 + step * 1.5), 5, "beast", true)
			local seen = store:query(Vector3.zero, 30, 6, "a", 100)
			expect(#seen).toBe(1)
			expect(seen[1].key).toBe("b")
			expect(seen[1].kind).toBe("beast")
			expect(near(seen[1].heading, 0)).toBe(true) -- walked along +Z

			local all = store:query(Vector3.zero, 30, 6, nil, 100)
			expect(#all).toBe(3)
			expect(all[1].t >= all[2].t and all[2].t >= all[3].t).toBe(true)
			expect(#store:query(Vector3.zero, 30, 6, nil, 2)).toBe(2)
			expect(#store:query(Vector3.new(500, 0, 500), 30, 6, nil, 100)).toBe(0)
		end)

		it("prints fade out of the store after keepSeconds", function()
			local store = SenseRules.newTracks()
			store:step("a", Vector3.new(0, 0, 0), 0, "person", true)
			store:step("a", Vector3.new(10, 0, 0), 1, "person", true)
			expect(#store:query(Vector3.zero, 30, 1 + Data.tracks.keepSeconds - 1, nil, 100)).toBe(1)
			expect(#store:query(Vector3.zero, 30, 1 + Data.tracks.keepSeconds + 1, nil, 100)).toBe(0)
			store:prune(1 + Data.tracks.keepSeconds + 1)
			expect(store:count()).toBe(0)
		end)
	end)

	describe("The Composer on Sense spells", function()
		it("says what a seeing Sense spell shows, and keeps the old words for the rest", function()
			local heat = SpellOutcome.of({ branch = "air", property = "temperature", verb = "sense", form = "aura", power = 2 })
			expect(heat.route).toBe("sense")
			expect(heat.text).toBe(Data.kinds.heat.summary)
			local tracks = SpellOutcome.of({ branch = "air", property = "perception", verb = "sense", form = "aura", power = 2 })
			expect(tracks.text).toBe(Data.kinds.tracks.summary)
			local plain = SpellOutcome.of({ branch = "air", property = "pressure", verb = "sense", form = "aura", power = 2 })
			expect(plain.route).toBe("sense")
			expect(plain.text ~= Data.kinds.heat.summary and plain.useful).toBe(true)
		end)
	end)
end
