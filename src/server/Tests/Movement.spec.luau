--!strict
--[[
	Movement.spec: running and the dash rules (Shared/Magic/Movement + Data/MovementTuning), which
	both the server's checks and the client's prediction use.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Movement = require(Shared.Magic.Movement)
local Registry = require(Shared.Magic.Registry)

local T = Movement.tuning

return function(t: any)
	t.describe("Movement", function()
		t.it("gives every domain a dash with a real style", function()
			for _, domain in Registry.domainIds do
				local flavour = T.dash.domains[domain]
				if not flavour then
					error("no dash for domain " .. domain)
				end
				t.expect(T.dash.styles[flavour.style] ~= nil).toBe(true)
			end
			t.expect(T.dash.styles[T.dash.plain.style] ~= nil).toBe(true)
		end)

		t.it("builds the dash for a domain and a mastery tier", function()
			local plain = Movement.dashFor(nil, 0)
			t.expect(plain.style).toBe("roll")
			t.expect(plain.kind).toBe("impulse")
			t.expect(plain.distance).toBeNear(T.dash.distance)
			t.expect(plain.speed).toBeNear(T.dash.distance / T.dash.duration)

			t.expect(Movement.dashFor("energy", 0).kind).toBe("blink")
			local rewind = Movement.dashFor("time", 0)
			t.expect(rewind.kind).toBe("rewind")
			t.expect(rewind.seconds > 0).toBe(true)
			t.expect(Movement.dashFor("gravity", 0).lift > 0).toBe(true)

			-- Mastery extends it; tiers outside 0..8 are clamped.
			t.expect(Movement.dashFor("air", 8).distance > Movement.dashFor("air", 0).distance).toBe(true)
			t.expect(Movement.dashFor("air", 99).distance).toBeNear(Movement.dashFor("air", 8).distance)
			t.expect(Movement.dashFor("not_a_domain", 0).style).toBe("roll")
		end)

		t.it("dashes where you move, or straight back when standing still", function()
			local forward = Movement.direction(Vector3.new(0, 0, -1), Vector3.new(1, 0, 0))
			t.expect((forward - Vector3.new(0, 0, -1)).Magnitude < 1e-6).toBe(true)
			local back = Movement.direction(Vector3.zero, Vector3.new(1, 0, 0))
			t.expect((back - Vector3.new(-1, 0, 0)).Magnitude < 1e-6).toBe(true)
			-- Never vertical, always unit length.
			local flat = Movement.direction(Vector3.new(1, 5, 1), Vector3.zAxis)
			t.expect(flat.Y).toBe(0)
			t.expect(flat.Magnitude).toBeNear(1)
		end)

		t.it("refills charges over time, never past the max", function()
			local charges, progress = Movement.recharge(0, 0, T.dash.recharge * 0.5)
			t.expect(charges).toBe(0)
			t.expect(progress).toBeNear(0.5)
			charges, progress = Movement.recharge(charges, progress, T.dash.recharge * 0.6)
			t.expect(charges).toBe(1)
			t.expect(progress).toBeNear(0.1)
			charges, progress = Movement.recharge(charges, progress, T.dash.recharge * 100)
			t.expect(charges).toBe(T.dash.charges)
			t.expect(progress).toBe(0)
		end)

		t.it("runs only when free, and the gamepad has hysteresis", function()
			t.expect(Movement.runAllowed("idle", false)).toBe(true)
			t.expect(Movement.runAllowed("idle", true)).toBe(false)
			t.expect(Movement.runAllowed("casting", false)).toBe(false)
			t.expect(Movement.runAllowed("blocking", false)).toBe(false)

			local between = (T.run.gamepadOn + T.run.gamepadOff) / 2
			t.expect(Movement.gamepadRun(false, between)).toBe(false) -- not yet
			t.expect(Movement.gamepadRun(true, between)).toBe(true) -- keeps running
			t.expect(Movement.gamepadRun(false, 1)).toBe(true)
			t.expect(Movement.gamepadRun(true, 0.2)).toBe(false)
		end)
	end)
end
