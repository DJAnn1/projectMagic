--!strict
--[[
	SpellShapes.spec: spells play by form and property (docs/SpellOverhaul.md §2B, stage 3). What
	matters: the data only names known shapes and keeps extra damage in budget; only damaging routes
	get a shape (the water freeze stays control: owner, 2026-11-13); a property beats its category,
	which beats the form's default; warnings are short enough to read but not to stall; the Composer
	says the shape; and the flight-steering shapes reach Delivery.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Data = require(Shared.Magic.Data.SpellShapes)
local SpellShape = require(Shared.Magic.SpellShape)
local SpellOutcome = require(Shared.Magic.SpellOutcome)
local Shapes = require(ServerScriptService.Server.Magic.Cast.Shapes)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	local function eachShape(fn: (any) -> ())
		for _, byForm in Data.forms do
			if byForm.default then
				fn(byForm.default)
			end
			for _, shape in (byForm.byCategory or {}) :: { [string]: any } do
				fn(shape)
			end
			for _, shape in (byForm.byProperty or {}) :: { [string]: any } do
				fn(shape)
			end
			for _, shape in (byForm.byVerb or {}) :: { [string]: any } do
				fn(shape)
			end
		end
	end

	describe("Spell shapes data", function()
		it("names only known shapes, each with Composer words", function()
			local known = {}
			for _, kind in Data.kinds do
				known[kind] = true
				expect(Data.words[kind] ~= nil).toBe(true)
			end
			eachShape(function(shape)
				expect(known[shape.kind] == true).toBe(true)
			end)
		end)

		it("keeps extra damage in budget and warnings readable", function()
			eachShape(function(shape)
				expect((shape.share or 0) <= 0.5).toBe(true)
				if shape.warn then
					expect(shape.warn >= 0.3 and shape.warn <= 1.5).toBe(true)
				end
				if shape.kind == "rain" then
					expect(shape.drops + 10 * shape.perPower <= Data.caps.maxDrops + 6).toBe(true)
				end
			end)
		end)
	end)

	describe("Which shape a spell gets", function()
		it("only damaging routes get a shape", function()
			expect(SpellShape.of({ form = "touch", property = "temperature" }, "freeze")).toBe(nil)
			expect(SpellShape.of({ form = "touch", property = "temperature" }, "ward")).toBe(nil)
			expect(SpellShape.of({ form = "touch", property = "temperature" }, nil)).toBe(nil)
			expect((SpellShape.of({ form = "touch", property = "momentum" }, "harm") :: any).kind).toBe("echo")
		end)

		it("a property beats its category, which beats the form's default", function()
			expect((SpellShape.of({ form = "projectile", property = "temperature", verb = "reduce" }, "thermal") :: any).kind).toBe("split")
			expect(SpellShape.of({ form = "projectile", property = "temperature", verb = "generate" }, "thermal")).toBe(nil)
			expect((SpellShape.of({ form = "projectile", property = "phase" }, "thermal") :: any).kind).toBe("split")
			expect((SpellShape.of({ form = "projectile", property = "cohesion" }, "harm") :: any).kind).toBe("lob")
			expect((SpellShape.of({ form = "projectile", property = "soul" }, "harm") :: any).kind).toBe("homing")
			expect(SpellShape.of({ form = "projectile", property = "charge" }, "harm")).toBe(nil) -- a plain bolt
			expect((SpellShape.of({ form = "ritual", property = "combustion" }, "ignite") :: any).kind).toBe("rain")
			expect((SpellShape.of({ form = "pillar", property = "charge" }, "harm") :: any).kind).toBe("erupt")
		end)

		it("the Composer says how it plays", function()
			local outcome = SpellOutcome.of({ branch = "energy", property = "radiation", verb = "generate", form = "burst", power = 4 })
			if outcome.route == "harm" then
				expect(string.find(outcome.text, Data.words.nova, 1, true) ~= nil).toBe(true)
			end
		end)
	end)

	describe("Shapes steer the flight", function()
		it("a lob arcs, a wisp homes, a ripple skips; warned shapes wait nowhere else", function()
			local ctx: any = { backfire = false, point = Vector3.zero, stats = { area = 6, recipe = { power = 3 } } }
			Shapes.before(ctx, { kind = "lob", gravityMult = 2.6, splash = 7, share = 0.35 })
			expect(ctx.shapeGravityMult).toBe(2.6)
			expect(ctx.speedMult < 1).toBe(true)
			Shapes.before(ctx, { kind = "homing" })
			expect(ctx.shapeHoming).toBe(true)
			Shapes.before(ctx, { kind = "skip", bounces = 2 })
			expect(ctx.shapeBounces).toBe(2)
			-- A backfire takes no shape at all.
			local backfired: any = { backfire = true }
			Shapes.before(backfired, { kind = "lob", gravityMult = 2 })
			expect(backfired.shapeGravityMult).toBe(nil)
		end)
	end)
end
