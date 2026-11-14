--!strict
--[[
	Struggle.spec: spells meeting in the air and spell struggles (docs/SpellStruggle.md). What
	matters most: weight grows with power, tier and form; counters tilt it; the outcome bands (cut
	through, shatter, struggle only head-on and only when both can struggle, glance); surges are
	capped so clicking faster gains nothing; the knot moves toward the weaker side and is clamped; a
	caster is overwhelmed only when the knot reaches them; and the pieces are wired (flags, status,
	remote).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Data = require(Shared.Magic.Data.Struggle)
local Rules = require(Shared.Magic.StruggleRules)
local StatusInfo = require(Shared.Magic.Data.StatusInfo)
local Remotes = require(Shared.Net.Remotes)
local Flags = require(ServerScriptService.Server.Config.Flags)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Spell weight", function()
		it("grows with power, tier and form, and counters tilt it", function()
			expect(Rules.weight(6, "projectile", 0) > Rules.weight(3, "projectile", 0)).toBe(true)
			expect(Rules.weight(4, "projectile", 6) > Rules.weight(4, "projectile", 1)).toBe(true)
			expect(Rules.weight(4, "beam", 2) > Rules.weight(4, "projectile", 2)).toBe(true)
			expect(Rules.matchup({ "water" }, { "fire", "heat" })).toBe(Data.matchupFor)
			expect(Rules.matchup({ "fire", "heat" }, { "water" })).toBe(Data.matchupAgainst)
			expect(Rules.matchup({ "time" }, { "fire" })).toBe(1)
		end)
	end)

	describe("Meeting outcomes", function()
		it("cut through, shatter, struggle head-on only, glance otherwise", function()
			expect((Rules.outcome(2, 1, -1, true))).toBe("cut_a")
			expect((Rules.outcome(1, 2, -1, true))).toBe("cut_b")
			expect((Rules.outcome(1.3, 1, -1, true))).toBe("shatter")
			expect((Rules.outcome(1.05, 1, -0.9, true))).toBe("struggle")
			expect((Rules.outcome(1.05, 1, -0.9, false))).toBe("shatter") -- an arrow or a feral can't struggle
			expect((Rules.outcome(1.05, 1, 0.2, true))).toBe("glance")
			expect((Rules.outcome(1.5, 1, -1, true, 3))).toBe("struggle") -- admin `struggletest`
		end)
	end)

	describe("The struggle", function()
		it("caps surges, and being hit weakens the push", function()
			expect(Rules.push(3, 1, 12, false)).toBe(Rules.push(3, 1, Data.surgeCap, false))
			expect(Rules.push(3, 1, 2, false) > Rules.push(3, 1, 0, false)).toBe(true)
			expect(Rules.push(3, 1, 0, true) < Rules.push(3, 1, 0, false)).toBe(true)
		end)

		it("moves the knot toward the weaker side, clamped, and overwhelms only at the end", function()
			expect(Rules.step(0.5, 2, 1, 1) > 0.5).toBe(true) -- A stronger: the knot moves toward B
			expect(Rules.step(0.5, 1, 1, 1)).toBe(0.5)
			expect(Rules.step(0.99, 10, 0, 5)).toBe(1)
			expect(Rules.overwhelmed(0.5, 50)).toBe(nil)
			expect(Rules.overwhelmed(0.99, 50)).toBe("b")
			expect(Rules.overwhelmed(0.01, 50)).toBe("a")
			local gap = Rules.lineGap(Vector3.new(-10, 0, 0), Vector3.new(10, 0, 0), Vector3.new(0, 0, -10), Vector3.new(0, 0, 10))
			expect(gap < 1e-3).toBe(true)
		end)

		it("is wired: flags, the held status and the intent remote", function()
			expect((Flags :: any).spell_collisions_enabled ~= nil and (Flags :: any).struggles_enabled ~= nil).toBe(true)
			expect((StatusInfo :: any).struggling ~= nil).toBe(true)
			expect((Remotes :: any).StruggleIntent ~= nil and (Remotes :: any).Struggle ~= nil).toBe(true)
		end)
	end)
end
