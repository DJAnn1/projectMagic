--!strict
--[[
	Moments.spec: Borrowed Power and Surge, with no live players (docs/Moments.md).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local CastService = require(Server.Services.CastService)
local AdminService = require(Server.Services.AdminService)
local ItemUse = require(Server.Items.ItemUse)
local EventRules = require(Server.Social.EventRules)

local Shared = ReplicatedStorage.Shared
local Borrowed = require(Shared.Magic.Data.BorrowedPowers)
local S = require(Shared.Magic.Data.SurgeTuning)
local Rules = require(Shared.Magic.SurgeRules)
local Reservoir = require(Shared.Magic.Reservoir)
local MagicCore = require(Shared.Magic.MagicCore)
local Registry = require(Shared.Magic.Registry)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local StatusInfo = require(Shared.Magic.Data.StatusInfo)
local SharedEvents = require(Shared.Social.Data.SharedEvents)
local Remotes = require(Shared.Net.Remotes)
local Controls = require(Shared.UI.Controls)

local function spendState(): any
	return { current = 100, max = 100, strain = 0, burnoutUntil = 0, lockouts = {}, regenMult = 1, riskMult = 1 }
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Borrowed Power", function()
		it("every relic has a real item that starts it", function()
			for _, id in Borrowed.ids do
				local relic = Borrowed.relics[id]
				local def = ItemDatabase.get(relic.item)
				expect(def ~= nil).toBe(true)
				local effect = ((def :: any).use.effects :: { any })[1]
				expect(effect.kind).toBe("borrow")
				expect(effect.relic).toBe(id)
			end
		end)
		it("the item's effect has a handler", function()
			expect(ItemUse.kinds.borrow ~= nil).toBe(true)
		end)
		it("every ability is valid grammar and reaches the power it claims", function()
			local problems: { string } = {}
			for _, id in Borrowed.ids do
				for _, ability in Borrowed.relics[id].abilities do
					local ok, errors, normalized = MagicCore.validateRecipe(ability.recipe)
					if not ok or not normalized then
						table.insert(problems, string.format("%s: %s", ability.name, errors[1] and errors[1].message or "?"))
					elseif CastService.routeFor(normalized).id ~= ability.route then
						table.insert(problems, string.format("%s routes to %s", ability.name, CastService.routeFor(normalized).id))
					end
				end
			end
			if #problems > 0 then
				error(table.concat(problems, "\n"))
			end
		end)
		it("no relic has more abilities than keys", function()
			for _, id in Borrowed.ids do
				expect(#Borrowed.relics[id].abilities <= 3).toBe(true)
			end
		end)
		it("a borrowed cast is free, even past a full reservoir, with no consequences", function()
			local state = spendState()
			local stats: any = { domains = { "time" }, costBreakdown = { reservoir = 1e6, vitalHp = 0 } }
			local result = Reservoir.trySpend(state, stats, 0, Random.new(1), true)
			expect(result.ok).toBe(true)
			expect(#result.consequences).toBe(0)
			expect(state.current).toBe(100)
		end)
		it("the same cast without the flag is refused", function()
			local stats: any = { domains = { "time" }, costBreakdown = { reservoir = 1e6, vitalHp = 0 } }
			expect(Reservoir.trySpend(spendState(), stats, 0, Random.new(1)).ok).toBe(false)
		end)
	end)

	describe("Your first relic", function()
		it("comes with your first gold in a won event", function()
			local relic = EventRules.firstRelic("gold", true, false, Random.new(1))
			expect(relic ~= nil and table.find(SharedEvents.relics, relic) ~= nil).toBe(true)
		end)
		it("comes only once", function()
			expect(EventRules.firstRelic("gold", true, true, Random.new(1))).toBe(nil)
		end)
		it("needs gold, and a win", function()
			expect(EventRules.firstRelic("silver", true, false, Random.new(1))).toBe(nil)
			expect(EventRules.firstRelic("gold", false, false, Random.new(1))).toBe(nil)
		end)
		it("every relic in the list exists", function()
			for _, id in SharedEvents.relics do
				expect(ItemDatabase.get(id) ~= nil).toBe(true)
			end
		end)
	end)

	describe("The Surge meter", function()
		it("fills from damage dealt, and stronger mages need more", function()
			expect(Rules.gainFromDealing(36, 1) > Rules.gainFromDealing(36, 8)).toBe(true)
			expect(Rules.gainFromDealing(0, 1)).toBe(0)
		end)
		it("no single hit fills it", function()
			expect(Rules.gainFromDealing(100000, 1)).toBe(S.maxPerHit)
			expect(Rules.gainFromTaking(100000, 100)).toBe(S.maxPerHit)
		end)
		it("fills from damage taken too", function()
			expect(Rules.gainFromTaking(10, 100)).toBeNear(0.1 * S.takenShare, 0.0001)
			expect(Rules.gainFromTaking(10, 0)).toBe(0)
		end)
		it("stays between empty and full", function()
			expect(Rules.addMeter(0.95, 0.5)).toBe(1)
			expect(Rules.addMeter(0, -1)).toBe(0)
		end)
		it("is only ready when full", function()
			expect(Rules.ready(0.99)).toBe(false)
			expect(Rules.ready(1)).toBe(true)
		end)
		it("fades only after a while with no fighting", function()
			expect(Rules.fade(0.5, S.idleSeconds - 1, 1)).toBe(0.5)
			expect(Rules.fade(0.5, S.idleSeconds, 1)).toBeNear(0.5 - S.fadePerSecond, 0.0001)
			expect(Rules.fade(0, S.idleSeconds, 1)).toBe(0)
		end)
	end)

	describe("The transformation", function()
		it("takes the domain you fought with most", function()
			expect(Rules.favourite({ water = 10, energy = 40 }, "air")).toBe("energy")
			expect(Rules.favourite({}, "air")).toBe("air")
		end)
		it("settles a tie the same way every time", function()
			expect(Rules.favourite({ water = 10, energy = 10 }, "air")).toBe("energy")
		end)
		it("every domain has its own finisher", function()
			local names: { [string]: boolean } = {}
			for _, domain in Registry.domainIds do
				local finisher = S.finishers[domain]
				expect(finisher ~= nil).toBe(true)
				expect(names[finisher.name]).toBe(nil)
				names[finisher.name] = true
			end
		end)
		it("every finisher's status exists", function()
			for _, finisher in S.finishers do
				if finisher.status then
					expect(StatusEffects.defs[finisher.status] ~= nil).toBe(true)
				end
			end
		end)
		it("every per-tier list covers all 8 tiers, and skill only helps", function()
			for _, list in { S.seconds, S.damage, S.resist, S.finisherShare, S.finisherRadius, S.fillDamage } :: { { number } } do
				expect(#list).toBe(8)
				for i = 2, 8 do
					expect(list[i] > list[i - 1]).toBe(true)
				end
			end
			for i = 2, 8 do
				expect(S.costMult[i] < S.costMult[i - 1]).toBe(true)
			end
		end)
		it("the blast is strongest at the centre, and weaker at the rim", function()
			expect(Rules.finisherAmount(10, 1, 0, 20)).toBeNear(10 * S.finisherShare[1], 0.001)
			expect(Rules.finisherAmount(10, 1, 20, 20)).toBeNear(10 * S.finisherShare[1] * S.finisherRim, 0.001)
			expect(Rules.finisherAmount(10, 1, 100, 20)).toBeNear(10 * S.finisherShare[1] * S.finisherRim, 0.001)
		end)
		it("spells cost less while it lasts", function()
			local state = spendState()
			state.costMult = 0.5
			local stats: any = { domains = { "energy" }, costBreakdown = { reservoir = 40, vitalHp = 0 } }
			Reservoir.trySpend(state, stats, 0, Random.new(1))
			expect(state.current).toBe(80)
		end)
		it("a recall can't hand you a Surge back", function()
			local model = Instance.new("Model")
			local humanoid = Instance.new("Humanoid")
			humanoid.Parent = model
			StatusEffects.apply(humanoid, "surging", { duration = 5, magnitude = 0.2 })
			expect(#StatusEffects.snapshot(humanoid)).toBe(0)
			expect(StatusEffects.damageDealtMult(humanoid)).toBeNear(1.2, 0.001)
			StatusEffects.dispel(humanoid)
		end)
	end)

	describe("Admin argument defaults", function()
		-- The bug this guards: a left-out player reached handlers as the word "me".
		local def: any = {
			name = "spec",
			args = {
				{ name = "where", type = "string", default = "nearest" },
				{ name = "player", type = "player", default = "me" },
			},
		}
		local ctx: any = { player = "the caller" }
		it("a left-out player default becomes the real caller", function()
			local args: any = AdminService.parseArgs(def, {}, ctx)
			expect(args.player).toBe("the caller")
		end)
		it("a player typed as me means the same", function()
			local args: any = AdminService.parseArgs(def, { "here", "me" }, ctx)
			expect(args.player).toBe("the caller")
		end)
		it("other string defaults stay as words for their handlers", function()
			local args: any = AdminService.parseArgs(def, {}, ctx)
			expect(args.where).toBe("nearest")
		end)
	end)

	describe("Moments wiring", function()
		it("the remotes, status and controls exist", function()
			expect(Remotes.SurgeIntent.from).toBe("Client")
			expect(Remotes.BorrowedCast.from).toBe("Client")
			expect(StatusInfo.surging ~= nil).toBe(true)
			expect(Controls.byId.surge ~= nil and Controls.byId.borrowed_1 ~= nil).toBe(true)
		end)
	end)
end
