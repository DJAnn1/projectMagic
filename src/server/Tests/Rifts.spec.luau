--!strict
--[[
	Rifts.spec: the rules behind Rifts, with no live players (docs/Rifts.md). Enemies are built detached,
	never parented to the workspace; the pocket's parts aren't built here at all.

	The ones that matter most: no room may shut a domain out, a new player's plain attacks must still
	work, and plain attacks must never count as clever.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local RiftRules = require(Server.Rifts.RiftRules)
local RiftEnemies = require(Server.Rifts.Data.RiftEnemies)
local CreatureRig = require(Server.Creatures.CreatureRig)
local WorldConfig = require(Server.World.WorldConfig)

local Shared = ReplicatedStorage.Shared
local R = require(Shared.Rifts.Data.RiftData)
local Registry = require(Shared.Magic.Registry)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local Remotes = require(Shared.Net.Remotes)
local Topics = require(Shared.Core.Topics)

local TOWNS: { RiftRules.Town } = {
	{ id = "a", name = "Alder", x = 0, z = 0 },
	{ id = "b", name = "Birch", x = 900, z = 0 },
	{ id = "c", name = "Cedar", x = 0, z = 900 },
}

local function always(_x: number, _z: number): boolean
	return true
end

local function never(_x: number, _z: number): boolean
	return false
end

local function cast(tags: { string }, power: number?, route: string?, backfired: boolean?): RiftRules.Cast
	return { tags = tags, power = power or 2, route = route or "thermal", backfired = backfired }
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Rift schedule", function()
		it("a slot fits the portal's window and a full run from its last moment, or caps the run", function()
			local w = RiftRules.window(10)
			expect(w.closesAt < w.lastEnd).toBe(true)
			expect(RiftRules.runEnds(10, w.startsAt)).toBe(w.startsAt + R.runSeconds)
			expect(RiftRules.runEnds(10, w.closesAt) <= w.lastEnd).toBe(true)
		end)
		it("a run always ends before the next Rift's slot", function()
			local w = RiftRules.window(10)
			expect(RiftRules.runEnds(10, w.closesAt) < RiftRules.window(11).startsAt).toBe(true)
		end)
		it("a run lasts 5 to 10 minutes when started as soon as it opens", function()
			expect(R.runSeconds >= 300 and R.runSeconds <= 600).toBe(true)
		end)
		it("every server plans the same Rift", function()
			local a = RiftRules.plan(1337, 50, TOWNS, always)
			local b = RiftRules.plan(1337, 50, TOWNS, always)
			expect(a).toEqual(b)
		end)
		it("a different slot or world seed can plan a different Rift", function()
			local base = RiftRules.plan(1337, 50, TOWNS, always)
			local differs = false
			for slot = 51, 80 do
				local other = RiftRules.plan(1337, slot, TOWNS, always)
				differs = differs or other.twist ~= base.twist or table.concat(other.rooms) ~= table.concat(base.rooms)
			end
			expect(differs).toBe(true)
		end)
		it("a plan draws distinct rooms that exist", function()
			for slot = 1, 40 do
				local plan = RiftRules.plan(1337, slot, TOWNS, always)
				expect(#plan.rooms).toBe(R.roomCount)
				local seen: { [string]: boolean } = {}
				for _, id in plan.rooms do
					expect(R.rooms[id] ~= nil).toBe(true)
					expect(seen[id]).toBe(nil)
					seen[id] = true
				end
				expect(R.twists[plan.twist] ~= nil).toBe(true)
				expect(Registry.domains[plan.bossWeakness] ~= nil).toBe(true)
			end
		end)
		it("falls back to the town itself when nowhere nearby is dry", function()
			local plan = RiftRules.plan(1337, 50, TOWNS, never)
			local onTown = false
			for _, town in TOWNS do
				onTown = onTown or (plan.x == town.x and plan.z == town.z)
			end
			expect(onTown).toBe(true)
		end)
		it("a portal sits outside the town when it can", function()
			local plan = RiftRules.plan(1337, 50, TOWNS, always)
			local nearest = math.huge
			for _, town in TOWNS do
				nearest = math.min(nearest, math.sqrt((plan.x - town.x) ^ 2 + (plan.z - town.z) ^ 2))
			end
			expect(nearest >= R.placeOffset.min - 1).toBe(true)
		end)
	end)

	describe("Rift pocket", function()
		it("sits entirely off the island", function()
			expect(R.pocket.x - 10 > WorldConfig.WORLD_SIZE / 2).toBe(true)
		end)
		it("lays out a hall, the rooms in order, then the arena, wall to wall", function()
			local sections = RiftRules.layout({ "thornwall", "chasm", "engine" })
			expect(#sections).toBe(5)
			expect(sections[1].kind).toBe("hall")
			expect(sections[2].roomId).toBe("thornwall")
			expect(sections[4].roomId).toBe("engine")
			expect(sections[5].kind).toBe("arena")
			for i = 2, #sections do
				expect(sections[i].startX).toBe(sections[i - 1].startX + sections[i - 1].length)
			end
			local last = sections[#sections]
			expect(last.startX + last.length - R.pocket.x).toBe(RiftRules.totalLength(3))
		end)
		it("knows who's inside", function()
			local length = RiftRules.totalLength(3)
			local p = R.pocket
			expect(RiftRules.inPocket(Vector3.new(p.x + 20, p.y + 3, p.z), length)).toBe(true)
			expect(RiftRules.inPocket(Vector3.new(0, 80, 0), length)).toBe(false)
			expect(RiftRules.inPocket(Vector3.new(p.x + 20, p.y - R.chasmDepth, p.z), length)).toBe(true)
		end)
		it("the fall line is above the pit's floor, so you're caught before you land", function()
			expect(R.fallLine < R.chasmDepth).toBe(true)
		end)
		it("a door fits inside a wall", function()
			expect(R.doorWidth < R.width and R.doorHeight < R.height).toBe(true)
		end)
		it("the drop can't be jumped", function()
			expect(R.chasmEnd - R.chasmStart > 30).toBe(true)
		end)
	end)

	describe("Rift rooms", function()
		it("every room has an approach for every domain", function()
			for roomId, room in R.rooms do
				for domainId in Registry.domains do
					local found = false
					for _, approach in room.approaches do
						found = found or table.find(approach.tags, domainId) ~= nil
					end
					if not found then
						error(string.format("%s has no approach for %s", roomId, domainId))
					end
				end
			end
		end)
		it("every approach has a label and an id, and ids are unique in a room", function()
			for _, room in R.rooms do
				local seen: { [string]: boolean } = {}
				for _, approach in room.approaches do
					expect(#approach.label > 0).toBe(true)
					expect(seen[approach.id]).toBe(nil)
					seen[approach.id] = true
				end
			end
		end)
		it("every room in the draw order exists, and every room has a known kind", function()
			for _, id in R.roomIds do
				expect(R.rooms[id] ~= nil).toBe(true)
			end
			for _, room in R.rooms do
				expect(table.find({ "barrier", "chasm", "eyes", "coils" }, room.kind) ~= nil).toBe(true)
			end
		end)
		it("every twist in the draw order exists and has words", function()
			for _, id in R.twistIds do
				expect(#R.twists[id].name > 0 and #R.twists[id].text > 0).toBe(true)
			end
		end)
		it("a clever answer is recognised by its tag", function()
			local approach, gain = RiftRules.classify(R.rooms.thornwall, cast({ "fire", "heat" }))
			expect(approach and approach.id).toBe("burn")
			expect(gain > 0).toBe(true)
		end)
		it("a plain strike is never clever, whatever its tags, and still makes progress", function()
			local approach, gain = RiftRules.classify(R.rooms.thornwall, cast({ "fire" }, 1, "strike"))
			expect(approach).toBe(nil)
			expect(gain > 0).toBe(true)
		end)
		it("anything else still chips away: nothing is a dead end", function()
			local approach, gain = RiftRules.classify(R.rooms.chasm, cast({ "made_up_tag" }))
			expect(approach).toBe(nil)
			expect(gain > 0).toBe(true)
		end)
		it("a clever answer is much faster than brute force", function()
			local _, clever = RiftRules.classify(R.rooms.engine, cast({ "lightning" }))
			local _, brute = RiftRules.classify(R.rooms.engine, cast({ "lightning" }, 2, "strike"))
			expect(clever >= brute * 4).toBe(true)
		end)
		it("a backfire does nothing", function()
			local approach, gain = RiftRules.classify(R.rooms.engine, cast({ "lightning" }, 5, "thermal", true))
			expect(approach).toBe(nil)
			expect(gain).toBe(0)
		end)
		it("a stronger spell does more, within limits", function()
			local _, weak = RiftRules.classify(R.rooms.engine, cast({ "lightning" }, 1))
			local _, strong = RiftRules.classify(R.rooms.engine, cast({ "lightning" }, 8))
			local _, absurd = RiftRules.classify(R.rooms.engine, cast({ "lightning" }, 60))
			expect(strong > weak).toBe(true)
			expect(absurd).toBe(strong)
		end)
		it("one huge spell can't clear a meter from nothing below power 2", function()
			local _, gain = RiftRules.classify(R.rooms.engine, cast({ "lightning" }, 1))
			expect(gain < 1).toBe(true)
		end)
		it("Stubborn slows brute force and rewards thinking", function()
			local _, brute = RiftRules.classify(R.rooms.engine, cast({ "x" }), R.twists.stubborn)
			local _, plain = RiftRules.classify(R.rooms.engine, cast({ "x" }))
			local _, clever = RiftRules.classify(R.rooms.engine, cast({ "lightning" }), R.twists.stubborn)
			local _, normal = RiftRules.classify(R.rooms.engine, cast({ "lightning" }))
			expect(brute < plain).toBe(true)
			expect(clever > normal).toBe(true)
		end)
		it("Wildfire doubles the worth of burning, and nothing else", function()
			local _, burn = RiftRules.classify(R.rooms.thornwall, cast({ "fire" }), R.twists.wildfire)
			local _, plainBurn = RiftRules.classify(R.rooms.thornwall, cast({ "fire" }))
			expect(burn).toBeNear(plainBurn * 2, 0.001)
			local _, rot = RiftRules.classify(R.rooms.thornwall, cast({ "rot" }), R.twists.wildfire)
			local _, plainRot = RiftRules.classify(R.rooms.thornwall, cast({ "rot" }))
			expect(rot).toBeNear(plainRot, 0.001)
		end)
		it("a room counts as clever only if at least half the work was", function()
			expect(RiftRules.solvedCleverly(1, 0)).toBe(true)
			expect(RiftRules.solvedCleverly(0.5, 0.5)).toBe(true)
			expect(RiftRules.solvedCleverly(0.2, 0.8)).toBe(false)
			expect(RiftRules.solvedCleverly(0, 1)).toBe(false)
		end)
	end)

	describe("Rift rewards", function()
		it("a win pays in full and thinking pays more", function()
			local base, coins = RiftRules.payout("gold", true, 0)
			expect(base).toBe(R.rewards.gold.xp)
			expect(coins).toBe(R.rewards.gold.coins)
			local clever = RiftRules.payout("gold", true, 3)
			expect(clever > base).toBe(true)
		end)
		it("running out of time pays a share and no items or gear", function()
			local xp = RiftRules.payout("gold", false, 0)
			expect(xp).toBe(math.floor(R.rewards.gold.xp * R.failedShare))
			expect(#RiftRules.rollItems("gold", false, Random.new(1))).toBe(0)
			expect(RiftRules.rollBossLoot("gold", false, 3, Random.new(1))).toBe(nil)
		end)
		it("the boss gives gear to gold and silver, not bronze", function()
			expect(RiftRules.rollBossLoot("gold", true, 0, Random.new(1)) ~= nil).toBe(true)
			expect(RiftRules.rollBossLoot("silver", true, 0, Random.new(1)) ~= nil).toBe(true)
			expect(RiftRules.rollBossLoot("bronze", true, 3, Random.new(1))).toBe(nil)
		end)
		it("cleverness raises the boss's rarity", function()
			expect(RiftRules.bossRarity("gold", 0, Random.new(1))).toBe("rare")
			expect(RiftRules.bossRarity("gold", 2, Random.new(1))).toBe("epic")
		end)
		it("a legendary needs gold and every room solved cleverly", function()
			local sawLegendary = false
			for seed = 1, 300 do
				sawLegendary = sawLegendary or RiftRules.bossRarity("gold", 3, Random.new(seed)) == "legendary"
				expect(RiftRules.bossRarity("silver", 3, Random.new(seed)) ~= "legendary").toBe(true)
				expect(RiftRules.bossRarity("gold", 2, Random.new(seed)) ~= "legendary").toBe(true)
			end
			expect(sawLegendary).toBe(true)
		end)
		it("every reward names a real item", function()
			for _, reward in R.rewards do
				for _, entry in reward.items do
					expect(ItemDatabase.get(entry.item) ~= nil).toBe(true)
				end
			end
			for _, id in R.bossLoot do
				expect(ItemDatabase.get(id) ~= nil).toBe(true)
			end
		end)
		it("a Rift pays better than a shared event's gold", function()
			local SharedEvents = require(Shared.Social.Data.SharedEvents)
			expect(R.rewards.gold.xp > SharedEvents.rewards.gold.xp).toBe(true)
		end)
	end)

	describe("Rift wiring", function()
		it("declares its remotes and topic", function()
			local remotes = (Remotes :: any).remotes or Remotes
			for _, name in { "RequestRift", "RiftState", "RiftScore", "RiftCue" } do
				expect(remotes[name] ~= nil).toBe(true)
			end
			expect(Topics.RiftEnded).toBe("RiftEnded")
		end)
		it("clients can't send anything into a Rift: the only client remote just asks", function()
			local remotes = (Remotes :: any).remotes or Remotes
			expect(remotes.RiftState.from).toBe("Server")
			expect(remotes.RiftScore.from).toBe("Server")
			expect(remotes.RiftCue.from).toBe("Server")
			expect(remotes.RequestRift.kind).toBe("Function")
			expect(#remotes.RequestRift.args).toBe(0)
		end)
		it("enemies build detached and are never in dens", function()
			local Creatures = require(Server.Creatures.Data.Creatures)
			for _, spec in { RiftEnemies.riftling, RiftEnemies.eye, RiftEnemies.warden } do
				local model = CreatureRig.build(spec.def, CFrame.new())
				expect(model.Parent).toBe(nil)
				expect(model:GetAttribute("Creature")).toBe(spec.def.id)
				model:Destroy()
				expect(Creatures.defs[spec.def.id]).toBe(nil)
			end
		end)
	end)
end
