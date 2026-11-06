--!strict
--[[
	Titans.spec: the rules behind Titans, with no live players (docs/Titans.md). The ones that matter most:
	every server agrees on the road, a fall never lands in a town, and the world can only keep so many.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Rules = require(Server.Titans.TitanRules)
local TitanBodies = require(Server.Titans.Data.TitanBodies)
local CreatureRig = require(Server.Creatures.CreatureRig)
local Creatures = require(Server.Creatures.Data.Creatures)
local Flags = require(Server.Config.Flags)
local Schemas = require(Server.Persistence.Schemas)
local WorldConfig = require(Server.World.WorldConfig)

local Shared = ReplicatedStorage.Shared
local T = require(Shared.Titans.Data.Titans)
local Registry = require(Shared.Magic.Registry)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local MapData = require(Shared.World.MapData)
local Remotes = require(Shared.Net.Remotes)
local Topics = require(Shared.Core.Topics)
local SharedEvents = require(Shared.Social.Data.SharedEvents)

local TOWNS: { Rules.Town } = {
	{ id = "a", name = "Alder", x = 0, z = 0, radius = 100 },
	{ id = "b", name = "Birch", x = 700, z = 100, radius = 80 },
	{ id = "c", name = "Cedar", x = -600, z = -200, radius = 90 },
	{ id = "d", name = "Dunmore", x = 100, z = 900, radius = 70 },
	{ id = "e", name = "Elm", x = -300, z = 700, radius = 70 },
	{ id = "f", name = "Fen", x = 1000, z = -800, radius = 70 },
}
local SIZE = WorldConfig.WORLD_SIZE

local function fall(id: string, t: number): Rules.Fall
	return { id = id, kind = "ashwalker", x = 10, z = 20, t = t, by = "Someone", u = 42, n = 2 }
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Titan data", function()
		it("every kind in the draw order exists, with words, a body and a real weakness", function()
			for _, id in T.ids do
				local kind = T.kinds[id]
				expect(kind ~= nil).toBe(true)
				expect(#kind.name > 0 and #kind.text > 0).toBe(true)
				expect(select(2, string.gsub(kind.fallText, "%%s", ""))).toBe(1)
				expect(Registry.domains[kind.weakness] ~= nil).toBe(true)
				expect(TitanBodies.bodies[id] ~= nil).toBe(true)
			end
		end)
		it("every reward and piece of gear is a real item", function()
			for _, reward in T.rewards do
				for _, entry in reward.items do
					expect(ItemDatabase.get(entry.item) ~= nil).toBe(true)
				end
			end
			for _, id in T.gear do
				expect(ItemDatabase.get(id) ~= nil).toBe(true)
			end
		end)
		it("pays better than a shared event, as the rarer fight", function()
			expect(T.rewards.gold.xp > SharedEvents.rewards.gold.xp).toBe(true)
			expect(T.slotSeconds > SharedEvents.slotSeconds).toBe(true)
		end)
		it("the body builds detached, and never in a den", function()
			for _, id in T.ids do
				local spec = TitanBodies.bodies[id]
				local model = CreatureRig.build(spec.def, CFrame.new())
				expect(model.Parent).toBe(nil)
				expect(model:GetAttribute("Creature")).toBe(spec.def.id)
				expect(Creatures.defs[spec.def.id]).toBe(nil)
				model:Destroy()
			end
		end)
		it("has three weak points that build, and one needs reach", function()
			local points = TitanBodies.weakPoints(T.kinds.ashwalker)
			expect(#points).toBe(3)
			local high = false
			for _, point in points do
				local model = CreatureRig.build(point.def, CFrame.new())
				model:Destroy()
				high = high or point.offset.Y > 25
			end
			expect(high).toBe(true)
		end)
		it("each kind takes more from its weakness", function()
			for _, id in T.ids do
				local kind = T.kinds[id]
				expect((TitanBodies.bodies[id].def.resist[kind.weakness] :: number) < 0).toBe(true)
			end
		end)
		it("a weak point's break costs it real health, but breaking all three isn't the whole fight", function()
			expect(T.breakBite > 0).toBe(true)
			expect(T.breakBite * 3 < 0.5).toBe(true)
		end)
		it("declares its flag, store, remotes and topic, and clients can only ask", function()
			expect((Flags :: any).titans_enabled ~= nil).toBe(true)
			expect(Schemas.TitanFalls ~= nil).toBe(true)
			expect(Remotes.TitanState.from).toBe("Server")
			expect(Remotes.TitanPos.from).toBe("Server")
			expect(Remotes.TitanScore.from).toBe("Server")
			expect(Remotes.TitanCue.from).toBe("Server")
			expect(#(Remotes.RequestTitan.args :: { any })).toBe(0)
			expect(Topics.TitanEnded).toBe("TitanEnded")
		end)
		it("its bones show on the map under their own name", function()
			expect(MapData.poiStyle("titan_fall").label).toBe("Titan's bones")
		end)
	end)

	describe("Titan roads", function()
		it("every server plans the same road", function()
			expect(Rules.plan(1337, 50, TOWNS, SIZE)).toEqual(Rules.plan(1337, 50, TOWNS, SIZE))
		end)
		it("different slots can differ", function()
			local base = Rules.plan(1337, 50, TOWNS, SIZE)
			local differs = false
			for slot = 51, 80 do
				local other = Rules.plan(1337, slot, TOWNS, SIZE)
				differs = differs or other.kind ~= base.kind or other.points[1].x ~= base.points[1].x
			end
			expect(differs).toBe(true)
		end)
		it("every kind comes up", function()
			local seen: { [string]: boolean } = {}
			for slot = 1, 200 do
				seen[Rules.plan(1337, slot, TOWNS, SIZE).kind] = true
			end
			for _, id in T.ids do
				expect(seen[id]).toBe(true)
			end
		end)
		it("walks through two different towns, in the order it meets them", function()
			for slot = 1, 40 do
				local plan = Rules.plan(1337, slot, TOWNS, SIZE)
				expect(#plan.towns).toBe(T.routeTowns)
				expect(plan.towns[1] ~= plan.towns[2]).toBe(true)
				expect(#plan.points).toBe(T.routeTowns + 2)
				-- Towards the far coast the whole way: it never doubles back along its line.
				local first, last = plan.points[1], plan.points[#plan.points]
				local dx, dz = last.x - first.x, last.z - first.z
				for i = 2, #plan.points do
					local a, b = plan.points[i - 1], plan.points[i]
					expect((b.x - a.x) * dx + (b.z - a.z) * dz >= -1e-6).toBe(true)
				end
			end
		end)
		it("copes with a world of one town", function()
			local plan = Rules.plan(1337, 50, { TOWNS[1] }, SIZE)
			expect(#plan.towns).toBe(1)
		end)
		it("starts and ends inside the world", function()
			for slot = 1, 20 do
				local plan = Rules.plan(1337, slot, TOWNS, SIZE)
				for _, point in { plan.points[1], plan.points[#plan.points] } do
					expect(math.abs(point.x) <= SIZE / 2 and math.abs(point.z) <= SIZE / 2).toBe(true)
				end
			end
		end)
		it("a crossing fits comfortably inside a slot, at any kind's speed", function()
			for slot = 1, 40 do
				local plan = Rules.plan(1337, slot, TOWNS, SIZE)
				local seconds = T.warnSeconds + plan.length / T.kinds[plan.kind].speed + T.recapSeconds
				expect(seconds < T.slotSeconds).toBe(true)
			end
		end)
		it("takes long enough to fight: at least a few minutes", function()
			for slot = 1, 40 do
				local plan = Rules.plan(1337, slot, TOWNS, SIZE)
				expect(plan.length / T.kinds[plan.kind].speed >= 240).toBe(true)
			end
		end)
		it("walks the road in order, and says when it's done", function()
			local points = { { x = 0, z = 0 }, { x = 100, z = 0 }, { x = 100, z = 100 } }
			local x, z, dirX, dirZ, arrived = Rules.pointAt(points, 50)
			expect(x).toBe(50)
			expect(z).toBe(0)
			expect(dirX).toBe(1)
			expect(dirZ).toBe(0)
			expect(arrived).toBe(false)
			x, z, dirX, dirZ, arrived = Rules.pointAt(points, 150)
			expect(x).toBe(100)
			expect(z).toBe(50)
			expect(dirZ).toBe(1)
			expect(arrived).toBe(false)
			local _, _, _, _, done = Rules.pointAt(points, 201)
			expect(done).toBe(true)
		end)
		it("measures the road", function()
			expect(Rules.lengthOf({ { x = 0, z = 0 }, { x = 30, z = 40 } })).toBe(50)
		end)
		it("an admin's Titan starts where they said, and stays in the world", function()
			local points = Rules.forcedRoute(1900, 1900, 0.5, SIZE)
			expect(points[1].x).toBe(1900)
			expect(math.abs(points[2].x) <= SIZE / 2 and math.abs(points[2].z) <= SIZE / 2).toBe(true)
		end)
	end)

	describe("Titan falls", function()
		it("a fall in open ground stays where it is", function()
			local x, z = Rules.fallSpot(3000, 3000, TOWNS)
			expect(x).toBe(3000)
			expect(z).toBe(3000)
		end)
		it("a fall in a town is moved past its edge", function()
			local x, z = Rules.fallSpot(10, 0, TOWNS)
			local distance = math.sqrt(x * x + z * z)
			expect(distance).toBeNear(TOWNS[1].radius + T.landmarkOffset, 0.01)
		end)
		it("a fall in the dead centre of a town still gets out", function()
			local x, z = Rules.fallSpot(0, 0, TOWNS)
			expect(math.sqrt(x * x + z * z) >= TOWNS[1].radius).toBe(true)
		end)
		it("the first server to report a Titan's death wins", function()
			local falls: { Rules.Fall } = {}
			expect(Rules.addFall(falls, fall("titan_1", 100), 20)).toBe(true)
			local other = fall("titan_1", 101)
			other.x = 999
			expect(Rules.addFall(falls, other, 20)).toBe(false)
			expect(#falls).toBe(1)
			expect(falls[1].x).toBe(10)
		end)
		it("keeps only so many, oldest out", function()
			local falls: { Rules.Fall } = {}
			for i = 1, T.maxFalls + 5 do
				Rules.addFall(falls, fall("titan_" .. i, i), T.maxFalls)
			end
			expect(#falls).toBe(T.maxFalls)
			expect(falls[1].id).toBe("titan_6")
			expect(falls[#falls].id).toBe("titan_" .. (T.maxFalls + 5))
		end)
		it("the store fits the falls it's allowed", function()
			-- A DataStore value is limited to 4 MB, and each record is under 200 bytes.
			expect(T.maxFalls * 200 < 4000000).toBe(true)
		end)
		it("credits who brought it down", function()
			local one = fall("x", 1)
			one.n = 0
			expect(Rules.credit(one)).toBe("Someone")
			one.n = 1
			expect(Rules.credit(one)).toBe("Someone and 1 other")
			one.n = 3
			expect(Rules.credit(one)).toBe("Someone and 3 others")
		end)
		it("a name can be taken off the bones, and the bones stay", function()
			local falls = { fall("a", 1), fall("b", 2) }
			falls[2].u = 7
			expect(Rules.scrub(falls, 42)).toBe(true)
			expect(falls[1].by).toBe("someone")
			expect(falls[1].u).toBe(0)
			expect(falls[2].by).toBe("Someone")
			expect(#falls).toBe(2)
			expect(Rules.scrub(falls, 12345)).toBe(false)
		end)
	end)

	describe("Titan rewards", function()
		it("a win pays in full, and walking into the sea pays a share and no items", function()
			local xp, coins = Rules.payout("gold", true)
			expect(xp).toBe(T.rewards.gold.xp)
			expect(coins).toBe(T.rewards.gold.coins)
			expect((Rules.payout("gold", false))).toBe(math.floor(T.rewards.gold.xp * T.failedShare))
			expect(#Rules.rollItems("gold", false, Random.new(1))).toBe(0)
			expect((Rules.rollGear("gold", false, Random.new(1)))).toBe(nil)
		end)
		it("gear goes to gold and silver on a win, not bronze", function()
			expect((Rules.rollGear("gold", true, Random.new(1))) ~= nil).toBe(true)
			expect((Rules.rollGear("silver", true, Random.new(1))) ~= nil).toBe(true)
			expect((Rules.rollGear("bronze", true, Random.new(1)))).toBe(nil)
		end)
		it("a legendary needs gold", function()
			local saw = false
			for seed = 1, 300 do
				local _, gold = Rules.rollGear("gold", true, Random.new(seed))
				saw = saw or gold == "legendary"
				local _, silver = Rules.rollGear("silver", true, Random.new(seed))
				expect(silver).toBe("rare")
			end
			expect(saw).toBe(true)
		end)
		it("the claim record outlives the Titan it guards", function()
			-- EventRules keeps a claim for 3 shared-event slots: it must not expire while this Titan can still pay.
			local longest = T.warnSeconds + 4000 / 5 + T.recapSeconds
			expect(SharedEvents.slotSeconds * 3 > longest).toBe(true)
		end)
	end)
end
