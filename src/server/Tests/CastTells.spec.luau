--!strict
--[[
	CastTells.spec: Read the cast (docs/ReadTheCast.md). What matters most: every kind of spell has
	a way of moving, the tells say what they mean (attacks restless and throwing off, heals slow and
	rising, wards still, land magic sinking), power makes a spell bigger and deeper but capped, and
	every example spell resolves to a kind without erroring.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local CastTells = require(Shared.Magic.CastTells)
local Data = require(Shared.Magic.Data.CastTells)
local RouteSummaries = require(Shared.Magic.Data.RouteSummaries)
local SpellExamples = require(Shared.Magic.Data.SpellExamples)
local Flags = require(ServerScriptService.Server.Config.Flags)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Read the cast", function()
		it("every kind of spell has a way of moving", function()
			for kind in RouteSummaries.kinds do
				expect(Data.kinds[kind] ~= nil).toBe(true)
			end
			for _, tell in Data.kinds do
				expect(tell.pull == "in" or tell.pull == "out").toBe(true)
				expect(tell.spin > 0 and tell.light > 0).toBe(true)
			end
			expect((Flags :: any).cast_tells_enabled ~= nil).toBe(true)
		end)

		it("the tells mean what they should", function()
			local attack, heal = CastTells.tellFor("attack"), CastTells.tellFor("heal")
			expect(attack.spin > heal.spin).toBe(true)
			expect(attack.pull).toBe("out")
			expect(attack.jitter > 0).toBe(true)
			expect(heal.rise > 0).toBe(true)
			expect(heal.jitter).toBe(0)
			expect(CastTells.tellFor("protect").pulseRate).toBe(0)
			expect(CastTells.tellFor("land").rise < 0).toBe(true)
			expect(CastTells.tellFor("none").light < CastTells.tellFor("utility").light).toBe(true)
		end)

		it("an unknown kind looks neutral", function()
			expect(CastTells.tellFor("no_such_kind")).toBe(Data.kinds[Data.fallback])
			expect(CastTells.tellFor(nil)).toBe(Data.kinds[Data.fallback])
		end)

		it("power makes it bigger and deeper, within limits", function()
			expect(CastTells.scaleFor(1)).toBe(1)
			expect(CastTells.scaleFor(5) > CastTells.scaleFor(2)).toBe(true)
			expect(CastTells.scaleFor(100)).toBe(Data.scaleMax)
			expect(CastTells.pitchFor(1)).toBe(1)
			expect(CastTells.pitchFor(6) < 1).toBe(true)
			expect(CastTells.pitchFor(100)).toBe(Data.pitchMin)
			expect(CastTells.scaleFor(nil)).toBe(1)
		end)

		it("every example spell reads as a kind, and a fire bolt reads as an attack", function()
			for _, example in SpellExamples do
				local recipe = (example :: any).recipe
				if recipe then
					expect(Data.kinds[CastTells.kindOf(recipe)] ~= nil).toBe(true)
				end
			end
			expect(CastTells.kindOf({ branch = "thermal", property = "temperature", verb = "generate", form = "projectile", power = 2 })).toBe("attack")
			-- A spell that does nothing reads as hollow (the Composer's dead example).
			expect(CastTells.kindOf({ branch = "void", property = "presence", verb = "redirect", form = "touch", power = 2 })).toBe("none")
		end)
	end)
end
