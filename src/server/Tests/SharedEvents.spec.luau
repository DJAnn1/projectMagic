--!strict
--[[
	SharedEvents.spec: the rules behind server-wide events, with no live players (docs/Social.md).
	Enemies are built detached, never parented to the workspace.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local EventRules = require(Server.Social.EventRules)
local EventEnemies = require(Server.Social.Data.EventEnemies)
local CreatureRig = require(Server.Creatures.CreatureRig)

local Shared = ReplicatedStorage.Shared
local S = require(Shared.Social.Data.SharedEvents)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local Remotes = require(Shared.Net.Remotes)
local Settings = require(Shared.UI.Settings)
local Topics = require(Shared.Core.Topics)

local TOWNS: { EventRules.Town } = {
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

-- A score that has been in the zone long enough to earn a tier.
local function scored(points: number, seconds: number?): EventRules.Score
	local score = EventRules.newScore()
	score.points = points
	score.seconds = seconds or 60
	return score
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Shared event schedule", function()
		it("a slot is long enough for the warning, the longest fight and the recap", function()
			for _, id in S.ids do
				expect(S.warnSeconds + S.types[id].duration + S.recapSeconds < S.slotSeconds).toBe(true)
			end
		end)
		it("every id in the draw order is a type, and every type is drawn", function()
			local seen = 0
			for _, id in S.ids do
				expect(S.types[id] ~= nil).toBe(true)
				seen += 1
			end
			local total = 0
			for _ in S.types do
				total += 1
			end
			expect(seen).toBe(total)
		end)
		it("the same seed and slot give the same plan", function()
			local a = EventRules.plan(1337, 500, TOWNS, always)
			local b = EventRules.plan(1337, 500, TOWNS, always)
			expect(a).toEqual(b)
		end)
		it("different slots eventually differ, and every type comes up", function()
			local seen: { [string]: boolean } = {}
			for slot = 1, 200 do
				seen[EventRules.plan(1337, slot, TOWNS, always).typeId] = true
			end
			for _, id in S.ids do
				expect(seen[id]).toBe(true)
			end
		end)
		it("outside-town events are placed in the offset ring, on dry ground", function()
			for slot = 1, 100 do
				local plan = EventRules.plan(1337, slot, TOWNS, always)
				local town = TOWNS[1]
				for _, candidate in TOWNS do
					if candidate.id == plan.townId then
						town = candidate
					end
				end
				local distance = Vector2.new(plan.x - town.x, plan.z - town.z).Magnitude
				if S.types[plan.typeId].outsideTown then
					expect(distance >= S.placeOffset.min - 0.01 and distance <= S.placeOffset.max + 0.01).toBe(true)
				else
					expect(distance).toBeNear(0, 0.01)
				end
			end
		end)
		it("with no dry ground an event falls back to the town itself", function()
			for slot = 1, 30 do
				local plan = EventRules.plan(1337, slot, TOWNS, never)
				local found = false
				for _, town in TOWNS do
					found = found or (town.id == plan.townId and town.x == plan.x and town.z == plan.z)
				end
				expect(found).toBe(true)
			end
		end)
		it("the phases follow the clock", function()
			local tl = EventRules.timeline(10, "elemental")
			expect(tl.startsAt).toBe(10 * S.slotSeconds)
			expect(EventRules.phaseAt(tl, tl.startsAt)).toBe("warning")
			expect(EventRules.phaseAt(tl, tl.warnEnds)).toBe("fight")
			expect(EventRules.phaseAt(tl, tl.endsAt)).toBe("over")
		end)
		it("a late server joins only with enough of the fight left", function()
			local tl = EventRules.timeline(10, "elemental")
			expect(EventRules.canJoin(tl, tl.startsAt)).toBe(true)
			expect(EventRules.canJoin(tl, tl.endsAt - tl.duration * 0.5)).toBe(true)
			expect(EventRules.canJoin(tl, tl.endsAt - tl.duration * S.joinShare)).toBe(true)
			expect(EventRules.canJoin(tl, tl.endsAt - tl.duration * (S.joinShare - 0.01))).toBe(false)
		end)
	end)

	describe("Shared event scaling", function()
		it("one player gets the base, more get more", function()
			expect(EventRules.healthFor(100, 1)).toBe(100)
			expect(EventRules.healthFor(100, 0)).toBe(100)
			expect(EventRules.healthFor(100, 3)).toBeNear(100 + 200 * S.perExtraPlayer)
		end)
		it("raising adds the difference, so damage already dealt stands", function()
			local maxHealth, health = EventRules.raise(100, 40, 250)
			expect(maxHealth).toBe(250)
			expect(health).toBe(190)
		end)
		it("never lowers health when players leave", function()
			local maxHealth, health = EventRules.raise(250, 190, 100)
			expect(maxHealth).toBe(250)
			expect(health).toBe(190)
		end)
	end)

	describe("Shared event contribution", function()
		it("damage scores and counts as acting", function()
			local score = EventRules.newScore()
			EventRules.addDamage(score, 20, 5)
			expect(score.points).toBe(20)
			expect(score.lastAct).toBe(5)
		end)
		it("standing around with no action earns nothing but time", function()
			local score = EventRules.newScore()
			for i = 1, 10 do
				EventRules.tickScore(score, true, i)
			end
			expect(score.points).toBe(0)
			expect(score.seconds).toBe(10)
		end)
		it("presence earns only within the active window, and only in the zone", function()
			local c = S.contribution
			local score = EventRules.newScore()
			EventRules.noteAction(score, 100)
			EventRules.tickScore(score, true, 100 + c.activeSeconds)
			expect(score.points).toBe(c.presencePerSecond)
			EventRules.tickScore(score, true, 100 + c.activeSeconds + 1)
			expect(score.points).toBe(c.presencePerSecond)
			EventRules.noteAction(score, 200)
			EventRules.tickScore(score, false, 201)
			expect(score.points).toBe(c.presencePerSecond)
		end)
		it("healing is capped per second, and the cap resets", function()
			local cap = S.contribution.healCapPerSecond
			local score = EventRules.newScore()
			expect(EventRules.addHeal(score, cap + 50, 10)).toBe(cap)
			expect(EventRules.addHeal(score, 10, 10.5)).toBe(0)
			expect(EventRules.addHeal(score, 10, 11)).toBe(10)
			expect(score.points).toBe(cap + 10)
		end)
		it("tiers are relative to the top score", function()
			local c = S.contribution
			local top = 1000
			expect(EventRules.tierFor(scored(top * c.gold), top)).toBe("gold")
			expect(EventRules.tierFor(scored(top * c.gold - 1), top)).toBe("silver")
			expect(EventRules.tierFor(scored(top * c.silver), top)).toBe("silver")
			expect(EventRules.tierFor(scored(top * c.silver - 1), top)).toBe("bronze")
		end)
		it("no tier below the minimum points or time", function()
			local c = S.contribution
			expect(EventRules.tierFor(scored(c.minPoints - 1), 1000)).toBe(nil)
			expect(EventRules.tierFor(scored(1000, c.minSeconds - 1), 1000)).toBe(nil)
			expect(EventRules.tierFor(scored(c.minPoints, c.minSeconds), c.minPoints)).toBe("gold")
		end)
		it("playing alone is enough for gold", function()
			local score = scored(200)
			expect(EventRules.tierFor(score, score.points)).toBe("gold")
		end)
	end)

	describe("Shared event rewards", function()
		it("a better tier always pays more", function()
			local order = S.tierOrder
			for i = 1, #order - 1 do
				local xpA, coinsA = EventRules.payout(order[i], true)
				local xpB, coinsB = EventRules.payout(order[i + 1], true)
				expect(xpA > xpB and coinsA > coinsB).toBe(true)
			end
		end)
		it("a failed event pays its share and no items", function()
			local xp, coins = EventRules.payout("gold", false)
			expect(xp).toBe(math.floor(S.rewards.gold.xp * S.failedShare))
			expect(coins).toBe(math.floor(S.rewards.gold.coins * S.failedShare))
			expect(#EventRules.rollItems("gold", false, Random.new(1))).toBe(0)
		end)
		it("the same seed rolls the same items", function()
			expect(EventRules.rollItems("gold", true, Random.new(7))).toEqual(EventRules.rollItems("gold", true, Random.new(7)))
		end)
		it("every reward item exists", function()
			for _, reward in S.rewards do
				for _, entry in reward.items do
					expect(ItemDatabase.get(entry.item) ~= nil).toBe(true)
				end
			end
		end)
		it("every tier has a name and a reward", function()
			for _, tier in S.tierOrder do
				expect(S.tierNames[tier] ~= nil and S.rewards[tier] ~= nil).toBe(true)
			end
		end)
	end)

	describe("Shared event claims", function()
		it("a claim stops a second payment", function()
			local claims: { [string]: number } = {}
			expect(EventRules.claimed(claims, "s9")).toBe(false)
			EventRules.claim(claims, "s9", 1000)
			expect(EventRules.claimed(claims, "s9")).toBe(true)
			expect(EventRules.claimed(claims, "s10")).toBe(false)
		end)
		it("pruning keeps claims while their event could still run", function()
			local claims: { [string]: number } = { old = 0, recent = 1000 }
			local now = S.slotSeconds * 3 + 500
			EventRules.pruneClaims(claims, now)
			expect(claims.old).toBe(nil)
			expect(claims.recent).toBe(1000)
			expect(S.slotSeconds * 3 > S.warnSeconds + 360).toBe(true)
		end)
	end)

	describe("Shared event enemies", function()
		local function all(): { EventEnemies.Enemy }
			local out = table.clone(EventEnemies.elementals)
			table.insert(out, EventEnemies.node)
			table.insert(out, EventEnemies.raider)
			table.insert(out, EventEnemies.shard)
			return out
		end
		it("every enemy builds into a rig with the Creature attribute", function()
			for _, enemy in all() do
				local model, humanoid = CreatureRig.build(enemy.def, CFrame.new())
				expect(model:GetAttribute("Creature")).toBe(enemy.def.id)
				expect(humanoid.MaxHealth).toBe(enemy.def.health)
				model:Destroy()
			end
		end)
		it("telegraphs always give time to move, and static enemies have an attack", function()
			for _, enemy in all() do
				if enemy.attack then
					expect(enemy.attack.delay >= 1).toBe(true)
					expect(enemy.attack.cooldown > enemy.attack.delay).toBe(true)
				end
				if enemy.static then
					expect(enemy.attack ~= nil).toBe(true)
				end
			end
		end)
		it("the biggest siege, all at once, fits the enemy cap", function()
			local siege = EventEnemies.siege
			local biggest = 0
			for _, size in siege.waves do
				biggest = math.max(biggest, size)
			end
			expect(biggest + siege.maxExtra <= S.maxEnemies).toBe(true)
		end)
		it("nodes and shards fit the enemy cap", function()
			expect(EventEnemies.nodes <= S.maxEnemies and EventEnemies.comet.shards <= S.maxEnemies).toBe(true)
		end)
	end)

	describe("Shared event wiring", function()
		it("the remotes, topics and setting exist", function()
			expect(Remotes.RequestSharedEvent.from).toBe("Client")
			expect(Remotes.SharedEventState.from).toBe("Server")
			expect(Remotes.SharedEventScore.kind).toBe("Unreliable")
			expect(Remotes.SharedEventCue.from).toBe("Server")
			expect(Topics.TargetHealed).toBe("TargetHealed")
			expect(Topics.SharedEventEnded).toBe("SharedEventEnded")
			expect(Settings.eventAlerts.default).toBe(true)
		end)
	end)
end
