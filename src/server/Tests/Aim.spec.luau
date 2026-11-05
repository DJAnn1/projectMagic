--!strict
-- Unit specs for Shared/Magic/Aim: the geometry the server's checks and the client's reticle share.
-- docs/Casting.md §7.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Aim = require(ReplicatedStorage.Shared.Magic.Aim)
local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local C = require(ServerScriptService.Server.Magic.Data.CombatTuning)
local T = require(ServerScriptService.Server.Magic.Data.CastTuning)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Aim geometry", function()
		it("lands an arc on the aim point, with or without gravity", function()
			local muzzle = Vector3.new(0, 5, 0)
			for _, case in { { point = Vector3.new(40, 0, 30), gravity = 70 }, { point = Vector3.new(-20, 12, 5), gravity = 0 } } do
				local speed = Aim.projectileSpeed(3)
				local velocity = Aim.launchVelocity(muzzle, case.point, speed, case.gravity, Vector3.new(0, 0, -1))
				local flightTime = (case.point - muzzle).Magnitude / speed
				local landed = Aim.positionAt(muzzle, velocity, case.gravity, flightTime)
				expect((landed - case.point).Magnitude).toBeNear(0, 1e-3)
			end
		end)
		it("caps projectile speed and grows the hit radius with power", function()
			expect(Aim.projectileSpeed(10) <= Aim.tuning.projectile.maxSpeed).toBe(true)
			expect(Aim.projectileRadius(5) > Aim.projectileRadius(1)).toBe(true)
			expect(Aim.projectileGravity("earth") > 0).toBe(true)
			expect(Aim.projectileGravity("energy")).toBe(0)
		end)
		it("measures range from the muzzle with the shared tolerance", function()
			local muzzle = Aim.muzzle(Vector3.zero)
			expect(muzzle.Y).toBe(Aim.tuning.muzzleHeight)
			local edge = Aim.maxDistance(40)
			expect(Aim.withinRange(muzzle, muzzle + Vector3.new(edge - 0.01, 0, 0), 40)).toBe(true)
			expect(Aim.withinRange(muzzle, muzzle + Vector3.new(edge + 0.01, 0, 0), 40)).toBe(false)
		end)
		it("gives every form a reticle", function()
			local kinds = { arc = true, line = true, chain = true, cone = true, ground = true, wall = true, self = true }
			for id in Registry.forms do
				expect(kinds[Aim.reticleKind(id)]).toBe(true)
			end
			expect(Aim.reticleKind("projectile")).toBe("arc")
			expect(Aim.reticleKind("aura")).toBe("self")
		end)
		it("is the single source for the server's tuning", function()
			expect(C.projectile.speedBase).toBe(Aim.tuning.projectile.speedBase)
			expect(C.projectile.gravityByDomain).toBe(Aim.tuning.projectile.gravityByDomain)
			expect(C.beam.radius).toBe(Aim.tuning.beam.radius)
			expect(C.touch.coneDegrees).toBe(Aim.tuning.touch.coneDegrees)
			expect(C.chain.jumpBase).toBe(Aim.tuning.chain.jumpBase)
			expect(T.rangeTolerance).toBe(Aim.tuning.rangeTolerance)
			expect(T.selfCentred).toBe(Aim.tuning.selfCentred)
		end)
		it("sees through open air", function()
			local clear = Aim.lineOfSight(Vector3.new(0, 5000, 0), Vector3.new(10, 5000, 0), {})
			expect(clear).toBe(true)
		end)
	end)
end
