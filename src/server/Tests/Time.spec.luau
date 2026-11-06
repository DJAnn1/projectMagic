--!strict
--[[
	Time.spec: the Time powers' routing, rules and status snapshots, with no live players
	(docs/Time.md). Also the craters' terrain ops, since they're pure.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Cast = Server.Magic.Cast
local StatusEffects = require(Cast.StatusEffects)
local Damage = require(Cast.Damage)
local CastService = require(Server.Services.CastService)
local EffectLibrary = require(Server.Magic.Data.EffectLibrary)

local Shared = ReplicatedStorage.Shared
local Rules = require(Shared.Magic.TimeRules)
local T = require(Shared.Magic.Data.TimeTuning)
local GravityRules = require(Shared.Magic.GravityRules)
local G = require(Shared.Magic.Data.GravityTuning)
local MagicCore = require(Shared.Magic.MagicCore)
local Remotes = require(Shared.Net.Remotes)
local Controls = require(Shared.UI.Controls)

local holder = Instance.new("Folder")

local function body(): Humanoid
	local model = Instance.new("Model")
	model.Parent = holder
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.Parent = model
	return humanoid
end

local function route(recipe: any): string
	local _, _, normalized = MagicCore.validateRecipe(recipe)
	return CastService.routeFor(normalized or recipe).id
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Time routes", function()
		it("each power has a route, on the one resolver", function()
			for _, id in { "self_timeline", "target_timeline", "time_loop", "stored_moment", "borrowed_wound", "future_sight", "timestop" } do
				local found = false
				for _, r in EffectLibrary.routes do
					found = found or (r.id == id and r.effect == "TimePower")
				end
				expect(found).toBe(true)
			end
		end)
		it("Self Timeline isn't swallowed by the general store route", function()
			expect(route({ branch = "rewind", property = "sequence", verb = "store", form = "aura", power = 5 })).toBe("self_timeline")
		end)
		it("low-power stasis zones stay slow fields; high power stops time", function()
			expect(route({ branch = "stasis", property = "tempo", verb = "reduce", form = "zone", power = 6 })).toBe("time_field")
			expect(route({ branch = "stasis", property = "tempo", verb = "reduce", form = "zone", power = 7 })).toBe("timestop")
		end)
		it("the older Time spells stay where they were", function()
			expect(route({ branch = "chronokinesis", property = "tempo", verb = "reduce", form = "zone", power = 5 })).toBe("time_field")
			expect(route({ branch = "hastening", property = "tempo", verb = "amplify", form = "touch", power = 4 })).toBe("tempo")
			expect(route({ branch = "stasis", property = "persistence", verb = "bind", form = "touch", power = 6 })).toBe("stasis")
		end)
		it("Stored Moment is a recipe the grammar accepts (Bind needs a tier 2 branch)", function()
			local recipe = { branch = "rewind", property = "sequence", verb = "bind", form = "aura", power = 5 }
			expect((MagicCore.validateRecipe(recipe))).toBe(true)
			expect(route(recipe)).toBe("stored_moment")
		end)
		it("Borrowed Wound covers both enemies and yourself", function()
			expect(route({ branch = "causality", property = "sequence", verb = "amplify", form = "beam", power = 5 })).toBe("borrowed_wound")
			expect(route({ branch = "causality", property = "sequence", verb = "reduce", form = "aura", power = 5 })).toBe("borrowed_wound")
		end)
	end)

	describe("Time scaling", function()
		it("every per-tier list covers all 8 tiers", function()
			for _, list in { T.selfTimeline.window, T.selfTimeline.cooldown, T.lastMoment.cooldown, T.targetTimeline.window, T.targetTimeline.marks, T.targetTimeline.stun, T.stored.seconds, T.stored.capacity, T.timestop.seconds, T.timestop.cooldown, T.wound.seconds, T.wound.targetMult, T.wound.selfMult, T.foresight.seconds, T.foresight.dodge, T.loop.loops } :: { { number } } do
				expect(#list).toBe(8)
			end
		end)
		it("skill means longer windows, shorter cooldowns, longer stops", function()
			for i = 2, 8 do
				expect(T.selfTimeline.window[i] > T.selfTimeline.window[i - 1]).toBe(true)
				expect(T.selfTimeline.cooldown[i] < T.selfTimeline.cooldown[i - 1]).toBe(true)
				expect(T.timestop.seconds[i] >= T.timestop.seconds[i - 1]).toBe(true)
				expect(T.wound.selfMult[i] < T.wound.selfMult[i - 1]).toBe(true)
				expect(T.wound.targetMult[i] > T.wound.targetMult[i - 1]).toBe(true)
			end
		end)
		it("a borrowed wound multiplies what was held", function()
			expect(Rules.woundTotal(100, 2)).toBe(200)
			expect(Rules.woundTotal(0, 2)).toBe(0)
			expect(Rules.woundTotal(-5, 2)).toBe(0)
		end)
		it("a stop's radius is clamped", function()
			expect(Rules.stopRadius(1)).toBe(T.timestop.radiusMin)
			expect(Rules.stopRadius(1000)).toBe(T.timestop.radiusMax)
		end)
	end)

	describe("Recalling", function()
		it("works with a live mark and a ready timeline", function()
			expect(Rules.recallRefusal(true, 100, 0, 50, false, false)).toBe(nil)
		end)
		it("needs a mark that hasn't run out", function()
			expect(Rules.recallRefusal(false, 100, 0, 50, false, false)).toBe("NO_MARK")
			expect(Rules.recallRefusal(true, 100, 0, 100, false, false)).toBe("NO_MARK")
		end)
		it("can't undo a duel", function()
			expect(Rules.recallRefusal(true, 100, 0, 50, true, false)).toBe("IN_DUEL")
		end)
		it("can't happen while time is stopped around you", function()
			expect(Rules.recallRefusal(true, 100, 0, 50, false, true)).toBe("TIME_STOPPED")
		end)
		it("waits for its cooldown", function()
			expect(Rules.recallRefusal(true, 100, 60, 50, false, false)).toBe("TOO_SOON")
		end)
	end)

	describe("Saved from death", function()
		local GM = T.lastMoment.minTier
		it("a killing blow triggers a Grandmaster's mark", function()
			expect(Rules.savesFromDeath(50, 50, true, 100, GM, 0, 10)).toBe(true)
			expect(Rules.savesFromDeath(500, 50, true, 100, GM, 0, 10)).toBe(true)
		end)
		it("below Grandmaster it doesn't", function()
			expect(Rules.savesFromDeath(500, 50, true, 100, GM - 1, 0, 10)).toBe(false)
		end)
		it("a blow you'd survive doesn't spend it", function()
			expect(Rules.savesFromDeath(49, 50, true, 100, GM, 0, 10)).toBe(false)
		end)
		it("needs a live mark and a ready save", function()
			expect(Rules.savesFromDeath(500, 50, false, 100, GM, 0, 10)).toBe(false)
			expect(Rules.savesFromDeath(500, 50, true, 5, GM, 0, 10)).toBe(false)
			expect(Rules.savesFromDeath(500, 50, true, 100, GM, 20, 10)).toBe(false)
		end)
		it("the interceptor can stop a blow outright", function()
			local humanoid = body()
			local previous = Damage.interceptor
			Damage.interceptor = function(_h: Humanoid, _amount: number, _source: number?, _kind: string, _info: any): number
				return 0
			end
			local dealt = Damage.apply(humanoid, 500, nil, "spec")
			Damage.internal(humanoid, 500)
			Damage.interceptor = previous
			expect(dealt).toBe(0)
			expect(humanoid.Health).toBe(100)
		end)
		it("the interceptor sees backlash too, marked internal", function()
			local humanoid = body()
			local previous = Damage.interceptor
			local seen = ""
			Damage.interceptor = function(_h: Humanoid, amount: number, _source: number?, kind: string, _info: any): number
				seen = kind
				return amount
			end
			Damage.internal(humanoid, 30)
			Damage.interceptor = previous
			expect(seen).toBe("internal")
			expect(humanoid.Health).toBe(70)
		end)
	end)

	describe("What a recall restores", function()
		it("cooldowns come back with the time they had left, and later ones are gone", function()
			local left = Rules.cooldownsLeft({ a = 110, b = 90 }, 100)
			expect(left.a).toBe(10)
			expect(left.b).toBe(nil)
			local restored = Rules.cooldownsRestored(left, 500)
			expect(restored.a).toBe(510)
			expect(restored.c).toBe(nil)
		end)
		it("statuses go back to how they were", function()
			local humanoid = body()
			StatusEffects.apply(humanoid, "haste", { duration = 30 })
			local snapshot = StatusEffects.snapshot(humanoid)
			StatusEffects.apply(humanoid, "poison", { duration = 30, magnitude = 5 })
			StatusEffects.remove(humanoid, "haste")
			StatusEffects.restore(humanoid, snapshot)
			expect(StatusEffects.has(humanoid, "haste")).toBe(true)
			expect(StatusEffects.has(humanoid, "poison")).toBe(false)
			StatusEffects.dispel(humanoid)
		end)
		it("keeps a status's strength and what it resists", function()
			local humanoid = body()
			StatusEffects.apply(humanoid, "gravity_heavy", { duration = 30, magnitude = 0.5, resist = { all = 0.4 } })
			local snapshot = StatusEffects.snapshot(humanoid)
			StatusEffects.dispel(humanoid)
			StatusEffects.restore(humanoid, snapshot)
			expect(StatusEffects.damageDealtMult(humanoid)).toBeNear(1.5, 0.001)
			expect((StatusEffects.resistOf(humanoid) :: any).all).toBeNear(0.4, 0.001)
			StatusEffects.dispel(humanoid)
		end)
		it("being held isn't part of your past", function()
			local humanoid = body()
			StatusEffects.apply(humanoid, "gravity_held", { duration = 30 })
			StatusEffects.apply(humanoid, "stasis", { duration = 30 })
			expect(#StatusEffects.snapshot(humanoid)).toBe(0)
			StatusEffects.dispel(humanoid)
		end)
	end)

	describe("Marking people", function()
		local function same(a: any, b: any): boolean
			return a.who == b.who
		end
		it("holds up to the cap, and the oldest goes", function()
			local marks: { any } = {}
			expect(Rules.addMark(marks, { who = 1 }, 2, same)).toBe(nil)
			expect(Rules.addMark(marks, { who = 2 }, 2, same)).toBe(nil)
			local pushed: any = Rules.addMark(marks, { who = 3 }, 2, same)
			expect(pushed.who).toBe(1)
			expect(#marks).toBe(2)
		end)
		it("marking someone again replaces their mark", function()
			local marks: { any } = {}
			Rules.addMark(marks, { who = 1, at = "old" }, 2, same)
			Rules.addMark(marks, { who = 1, at = "new" }, 2, same)
			expect(#marks).toBe(1)
			expect(marks[1].at).toBe("new")
		end)
	end)

	describe("Craters", function()
		it("the bowl comes first, so a short budget only loses the rim", function()
			local ops = GravityRules.craterOps(10, 20, 30, 12)
			expect(ops[1].k).toBe("ball")
			expect(ops[1].m).toBe("Air")
		end)
		it("digs down from the surface by the right share", function()
			local radius = 12
			local ops = GravityRules.craterOps(0, 50, 0, radius)
			local bottom = ops[1].y - ops[1].r
			expect(bottom).toBeNear(50 - radius * G.crater.depthShare, 0.001)
		end)
		it("uses only carving and natural ground (nothing saved is magic stone)", function()
			for _, op in GravityRules.craterOps(0, 0, 0, 10) do
				expect(op.m == "Air" or op.m == "Ground").toBe(true)
			end
		end)
		it("a higher fall digs a bigger crater, within limits", function()
			expect(GravityRules.meteorCrater(200) > GravityRules.meteorCrater(20)).toBe(true)
			expect(GravityRules.meteorCrater(0)).toBe(G.crater.minRadius)
			expect(GravityRules.meteorCrater(100000)).toBe(G.crater.maxRadius)
			expect(GravityRules.singularityCrater(100000)).toBe(G.crater.maxRadius)
		end)
	end)

	describe("Time wiring", function()
		it("the remote, status and controls exist", function()
			expect(Remotes.TimeIntent.from).toBe("Client")
			local validate = (Remotes.TimeIntent.args :: { any })[1]
			expect((validate("recall"))).toBe(true)
			expect((validate("teleport"))).toBe(false)
			expect(StatusEffects.defs.foreseeing ~= nil).toBe(true)
			expect(Controls.byId.time_recall ~= nil and Controls.byId.time_release ~= nil).toBe(true)
		end)
	end)
end
