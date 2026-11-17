--!strict
--[[
	ShotPlan.spec: the caster's local bolt (docs/Smoothness.md stage 1) flies the server's flight.
	What matters most: the numbers ShotPlan copies from server-only tuning still match it, every
	example bolt gets a plan and nothing else does, a charge never slows a bolt, homing needs a
	target, and the launch velocity heads for the aim point.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local ShotPlan = require(Shared.Magic.ShotPlan)
local SpellExamples = require(Shared.Magic.Data.SpellExamples)
local CombatTuning = require(ServerScriptService.Server.Magic.Data.CombatTuning)
local Flags = require(ServerScriptService.Server.Config.Flags)

local function stubStats(recipe: any): any
	return {
		recipe = recipe,
		domains = { "energy" },
		masteryTier = 0,
		castTime = 1,
		delay = 0,
		flags = {},
		power = recipe.power,
		area = 1,
		maxTargets = 1,
		cost = 1,
		costBreakdown = { reservoir = 1 },
		backfireChance = 0,
		harmful = true,
	}
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Local shots", function()
		it("copies the server's flight tuning exactly", function()
			local probe = ShotPlan.of(
				{ branch = "pyromancy", property = "combustion", verb = "generate", form = "projectile", power = 4 },
				stubStats({ form = "projectile", power = 4 }),
				nil
			)
			expect(probe ~= nil).toBe(true)
			local plan = probe :: ShotPlan.Plan
			expect(math.abs(plan.turnRate - CombatTuning.projectile.homingTurn) < 1e-6).toBe(true)
			expect(plan.lifetime).toBe(CombatTuning.projectile.maxLifetime)
			expect((Flags :: any).local_shots_enabled ~= nil).toBe(true)
		end)

		it("plans every example bolt and nothing that isn't one", function()
			for _, example in SpellExamples do
				local recipe = example.recipe
				local plan = ShotPlan.of(recipe, stubStats(recipe), nil)
				if recipe.form == "projectile" then
					expect(plan ~= nil).toBe(true)
					local p = plan :: ShotPlan.Plan
					expect(p.speed > 0 and p.gravity >= 0).toBe(true)
					expect(p.homing).toBe(false) -- no target picked
				else
					expect(plan == nil).toBe(true)
				end
			end
		end)

		it("a charged release never flies slower than a tap", function()
			local recipe = { branch = "pyromancy", property = "combustion", verb = "generate", form = "projectile", power = 4 }
			local tap = ShotPlan.of(recipe, stubStats(recipe), nil) :: ShotPlan.Plan
			local full = ShotPlan.of(recipe, stubStats(recipe), { held = 3 }) :: ShotPlan.Plan
			expect(full.speed >= tap.speed).toBe(true)
		end)

		it("aims the launch at the point", function()
			local plan: ShotPlan.Plan = { speed = 80, gravity = 0, homing = false, turnRate = 0, lifetime = 4, radius = 1, look = nil, domain = "energy" }
			local v = ShotPlan.velocity(plan, Vector3.zero, Vector3.new(0, 0, -40), Vector3.new(1, 0, 0))
			expect(math.abs(v.Magnitude - 80) < 1e-3).toBe(true)
			expect(v.Unit:Dot(Vector3.new(0, 0, -1)) > 0.999).toBe(true)
		end)
	end)
end
