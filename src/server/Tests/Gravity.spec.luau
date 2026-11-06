--!strict
--[[
	Gravity.spec: the gravity powers' routing, scaling and holds, with no live players (docs/Gravity.md).
	Holds are tested on detached bodies, never in the workspace.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Cast = Server.Magic.Cast
local GravityRuntime = require(Cast.GravityRuntime)
local StatusEffects = require(Cast.StatusEffects)
local CastService = require(Server.Services.CastService)
local EffectLibrary = require(Server.Magic.Data.EffectLibrary)

local Shared = ReplicatedStorage.Shared
local Rules = require(Shared.Magic.GravityRules)
local G = require(Shared.Magic.Data.GravityTuning)
local MagicCore = require(Shared.Magic.MagicCore)
local Remotes = require(Shared.Net.Remotes)
local Controls = require(Shared.UI.Controls)

local SOURCE = 91000101

-- Kept out of the workspace, but a hold treats a body with no parent as gone.
local holder = Instance.new("Folder")

local function body(anchored: boolean?): any
	local model = Instance.new("Model")
	model.Parent = holder
	local humanoid = Instance.new("Humanoid")
	humanoid.MaxHealth = 100
	humanoid.Health = 100
	humanoid.Parent = model
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = anchored == true
	root.Parent = model
	return GravityRuntime.hitFor(model, humanoid, root)
end

local function route(recipe: any): string
	local _, _, normalized = MagicCore.validateRecipe(recipe)
	return CastService.routeFor(normalized or recipe).id
end

local function rising(list: { number }): boolean
	for i = 2, #list do
		if list[i] < list[i - 1] then
			return false
		end
	end
	return true
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Gravity routes", function()
		it("each power has a route, on the one resolver", function()
			local want = { "singularity", "orbit_shield", "gravity_well", "flight", "mass_shift", "crushing_grip", "bend_path", "lift_slam" }
			for _, id in want do
				local found = false
				for _, r in EffectLibrary.routes do
					found = found or (r.id == id and r.effect == "GravityPower")
				end
				expect(found).toBe(true)
			end
		end)
		it("they come before the broad routes that would swallow them", function()
			local order: { [string]: number } = {}
			for i, r in EffectLibrary.routes do
				order[r.id] = i
			end
			for _, id in { "crushing_grip", "lift_slam", "bend_path", "gravity_well" } do
				expect(order[id] < order.gravity_field).toBe(true)
				expect(order[id] < order.force).toBe(true)
				expect(order[id] < order.harm).toBe(true)
			end
		end)
		it("low-power collapse is a well; high power is a singularity", function()
			expect(route({ branch = "collapse", property = "weight", verb = "amplify", form = "zone", power = 6 })).toBe("gravity_well")
			expect(route({ branch = "collapse", property = "weight", verb = "amplify", form = "zone", power = 8 })).toBe("singularity")
		end)
		it("leaves the older gravity spells where they were", function()
			expect(route({ branch = "weightcraft", property = "weight", verb = "amplify", form = "zone", power = 5 })).toBe("gravity_field")
			expect(route({ branch = "levitation", property = "weight", verb = "reduce", form = "aura", power = 4 })).toBe("gravity_field")
			expect(route({ branch = "inversion", property = "orientation", verb = "transmute", form = "zone", power = 6 })).toBe("gravity_field")
		end)
		it("a thrown crush is still a plain hit", function()
			expect(route({ branch = "crushing", property = "weight", verb = "amplify", form = "projectile", power = 5 })).toBe("harm")
		end)
	end)

	describe("Gravity scaling", function()
		it("byTier clamps at both ends", function()
			local list = { 1, 2, 3 }
			expect(Rules.byTier(list, 0)).toBe(1)
			expect(Rules.byTier(list, 2)).toBe(2)
			expect(Rules.byTier(list, 9)).toBe(3)
		end)
		it("every per-tier list covers all 8 tiers", function()
			for _, list in { G.flight.speed, G.flight.ceiling, G.flight.drainShare, G.grip.duration, G.grip.execute, G.lift.height, G.lift.throw, G.well.seconds, G.well.pull, G.well.crushShare, G.orbit.pieces, G.bend.reflectChance, G.mass.resist, G.mass.damage, G.field.heavy, G.field.invert, G.field.crushShare } :: { { number } } do
				expect(#list).toBe(8)
			end
		end)
		it("power only ever rises with skill", function()
			for _, list in { G.flight.speed, G.flight.ceiling, G.grip.duration, G.grip.execute, G.lift.height, G.lift.throw, G.well.pull, G.orbit.pieces, G.bend.reflectChance, G.mass.resist, G.field.heavy, G.field.crushShare } :: { { number } } do
				expect(rising(list)).toBe(true)
			end
		end)
		it("flight gets cheaper with skill", function()
			for i = 2, 8 do
				expect(G.flight.drainShare[i] < G.flight.drainShare[i - 1]).toBe(true)
			end
		end)
		it("a grip tightens the longer it holds", function()
			expect(Rules.gripShare(0)).toBe(G.grip.share)
			expect(Rules.gripShare(3) > Rules.gripShare(1)).toBe(true)
			expect(Rules.gripShare(-1)).toBe(G.grip.share)
		end)
		it("a master's grip can kill a full-health player unaided, a novice's can't", function()
			local function total(power: number, tier: number): number
				local base = 9 * power ^ 0.6
				local seconds, sum = Rules.byTier(G.grip.duration, tier), 0
				local at = 0
				while at <= seconds do
					sum += base * Rules.gripShare(at)
					at += G.grip.tick
				end
				return sum
			end
			expect(total(8, 6) >= 100).toBe(true)
			expect(total(3, 2) < 100).toBe(true)
		end)
		it("only Expert and above can finish someone off", function()
			expect(Rules.gripExecutes(4, 0.01)).toBe(false)
			expect(Rules.gripExecutes(5, 0.05)).toBe(true)
			expect(Rules.gripExecutes(5, 0.06)).toBe(false)
			expect(Rules.gripExecutes(8, 0.3)).toBe(true)
		end)
		it("a higher slam hits harder", function()
			expect(Rules.slamShare(80) > Rules.slamShare(6)).toBe(true)
		end)
		it("a throw goes toward the aim, no further than the tier allows", function()
			local start = Vector3.new(0, 50, 0)
			expect(Rules.throwTarget(start, Vector3.new(500, 0, 0), 2)).toBe(start)
			local thrown = Rules.throwTarget(start, Vector3.new(500, 0, 0), 8)
			expect(thrown.X).toBeNear(G.lift.throw[8], 0.01)
			expect(thrown.Y).toBe(50)
			expect(Rules.throwTarget(start, Vector3.new(5, 0, 0), 8).X).toBeNear(5, 0.01)
		end)
		it("a well pulls hardest at the middle and not at all past the rim", function()
			expect(Rules.wellPull(5, 0, 40)).toBe(G.well.pull[5])
			expect(Rules.wellPull(5, 40, 40)).toBeNear(G.well.pull[5] * G.well.edgePull, 0.001)
			expect(Rules.wellPull(5, 41, 40)).toBe(0)
		end)
		it("a master's well outruns a walker", function()
			expect(Rules.wellPull(6, 0, 40) > 16).toBe(true)
		end)
		it("heavy fields scale; light ones don't", function()
			expect((Rules.fieldMult("heavy", 8) :: number) > (Rules.fieldMult("heavy", 1) :: number)).toBe(true)
			expect(Rules.fieldMult("heavy", 1)).toBe(2.2)
			expect(Rules.fieldMult("light", 8)).toBe(nil)
			expect((Rules.fieldMult("invert", 8) :: number) < 0).toBe(true)
		end)
	end)

	describe("Flight checks", function()
		local flight = Rules.flight(4)
		it("allows flying at full speed, and a knock on top", function()
			expect(Rules.flightViolation(flight, flight.speed, 10)).toBe(false)
			expect(Rules.flightViolation(flight, flight.speed + 25, 10)).toBe(false)
		end)
		it("catches a speed nothing explains", function()
			expect(Rules.flightViolation(flight, 500, 10)).toBe(true)
		end)
		it("catches a height past the ceiling", function()
			expect(Rules.flightViolation(flight, 0, flight.ceiling)).toBe(false)
			expect(Rules.flightViolation(flight, 0, flight.ceiling * 3 + 100)).toBe(true)
		end)
		it("a meteor needs Master and height", function()
			expect(Rules.canMeteor(5, 500)).toBe(false)
			expect(Rules.canMeteor(6, 5)).toBe(false)
			expect(Rules.canMeteor(6, G.meteor.minHeight)).toBe(true)
		end)
		it("a higher fall hits harder and wider, up to the caps", function()
			expect(Rules.meteorShare(100) > Rules.meteorShare(20)).toBe(true)
			expect(Rules.meteorShare(100000)).toBe(G.meteor.maxShare)
			expect(Rules.meteorRadius(100000)).toBe(G.meteor.maxRadius)
		end)
	end)

	describe("Holds", function()
		it("anchors the body, marks it, and stops casting", function()
			local hit = body()
			local hold = GravityRuntime.hold(hit, SOURCE, 2)
			expect(hold ~= nil).toBe(true)
			expect(hit.root.Anchored).toBe(true)
			expect(hit.model:GetAttribute(GravityRuntime.heldAttribute)).toBe(true)
			expect(StatusEffects.blocksCasting(hit.humanoid)).toBe(true)
			GravityRuntime.release(hold :: any)
			expect(hit.root.Anchored).toBe(false)
			expect(hit.model:GetAttribute(GravityRuntime.heldAttribute)).toBe(nil)
			expect(StatusEffects.blocksCasting(hit.humanoid)).toBe(false)
		end)
		it("can't hold someone twice", function()
			local hit = body()
			local hold = GravityRuntime.hold(hit, SOURCE, 2)
			expect(GravityRuntime.hold(hit, SOURCE, 2)).toBe(nil)
			GravityRuntime.release(hold :: any)
		end)
		it("gives a moment of immunity after one ends", function()
			local hit = body()
			GravityRuntime.release(GravityRuntime.hold(hit, SOURCE, 2) :: any)
			expect(GravityRuntime.hold(hit, SOURCE, 2)).toBe(nil)
		end)
		it("releasing twice does no harm", function()
			local hit = body()
			local hold = GravityRuntime.hold(hit, SOURCE, 2) :: any
			GravityRuntime.release(hold)
			GravityRuntime.release(hold)
			expect(hit.root.Anchored).toBe(false)
		end)
		it("leaves something already anchored anchored", function()
			local hit = body(true)
			GravityRuntime.release(GravityRuntime.hold(hit, SOURCE, 2) :: any)
			expect(hit.root.Anchored).toBe(true)
		end)
		it("won't freeze a quest NPC warded for someone else", function()
			local hit = body()
			hit.humanoid:SetAttribute("QuestWard", SOURCE + 1)
			expect(GravityRuntime.hold(hit, SOURCE, 2)).toBe(nil)
			expect(hit.root.Anchored).toBe(false)
		end)
		it("the dead can't be held", function()
			local hit = body()
			hit.humanoid.Health = 0
			expect(GravityRuntime.hold(hit, SOURCE, 2)).toBe(nil)
		end)
	end)

	describe("Statuses and anchoring", function()
		-- The bug this guards: any status on a static enemy, or someone held, used to drop them.
		it("a status doesn't unanchor something anchored by anything else", function()
			local hit = body(true)
			StatusEffects.apply(hit.humanoid, "slow", { duration = 5 })
			expect(hit.root.Anchored).toBe(true)
			StatusEffects.remove(hit.humanoid, "slow")
			expect(hit.root.Anchored).toBe(true)
		end)
		it("stasis anchors an NPC and lets go afterwards", function()
			local hit = body()
			StatusEffects.apply(hit.humanoid, "stasis", { duration = 5 })
			expect(hit.root.Anchored).toBe(true)
			StatusEffects.remove(hit.humanoid, "stasis")
			expect(hit.root.Anchored).toBe(false)
		end)
		it("stasis ending doesn't drop someone in a gravity hold", function()
			local hit = body()
			StatusEffects.apply(hit.humanoid, "stasis", { duration = 5 })
			local hold = GravityRuntime.hold(hit, SOURCE, 2) :: any
			StatusEffects.remove(hit.humanoid, "stasis")
			expect(hit.root.Anchored).toBe(true)
			GravityRuntime.release(hold)
			expect(hit.root.Anchored).toBe(false) -- and nothing leaves them anchored for good
		end)
		it("a hold ending doesn't free someone still in stasis", function()
			local hit = body()
			StatusEffects.apply(hit.humanoid, "stasis", { duration = 5 })
			GravityRuntime.release(GravityRuntime.hold(hit, SOURCE, 2) :: any)
			expect(hit.root.Anchored).toBe(true)
			StatusEffects.remove(hit.humanoid, "stasis")
			expect(hit.root.Anchored).toBe(false)
		end)
		it("Anchor Weight makes your spells hit harder, and only it does", function()
			local hit = body()
			expect(StatusEffects.damageDealtMult(hit.humanoid)).toBe(1)
			StatusEffects.apply(hit.humanoid, "gravity_light", { duration = 5 })
			expect(StatusEffects.damageDealtMult(hit.humanoid)).toBe(1)
			StatusEffects.apply(hit.humanoid, "gravity_heavy", { duration = 5, magnitude = 0.5 })
			expect(StatusEffects.damageDealtMult(hit.humanoid)).toBeNear(1.5, 0.001)
			StatusEffects.dispel(hit.humanoid)
		end)
	end)

	describe("Gravity wiring", function()
		it("the remote and controls exist", function()
			expect(Remotes.FlightIntent.from).toBe("Client")
			local validate = (Remotes.FlightIntent.args :: { any })[1]
			expect((validate("land"))).toBe(true)
			expect((validate("teleport"))).toBe(false)
			expect(Controls.byId.fly_land ~= nil and Controls.byId.fly_dive ~= nil).toBe(true)
			expect(Controls.contexts.flying ~= nil).toBe(true)
		end)
	end)
end
