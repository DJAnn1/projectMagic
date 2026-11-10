--!strict
--[[
	Reality.spec: the Reality powers' routing, rules and statuses, with no live players
	(docs/Reality.md).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Cast = Server.Magic.Cast
local StatusEffects = require(Cast.StatusEffects)
local RealityRuntime = require(Cast.RealityRuntime)
local CastService = require(Server.Services.CastService)

local Shared = ReplicatedStorage.Shared
local EffectLibrary = require(Shared.Magic.Data.EffectLibrary)
local Rules = require(Shared.Magic.RealityRules)
local R = require(Shared.Magic.Data.RealityTuning)
local MagicCore = require(Shared.Magic.MagicCore)

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

-- Must be grammar the Composer accepts, and reach the route named.
local CASES: { { recipe: any, route: string } } = {
	{ recipe = { branch = "fortune", property = "probability", verb = "amplify", form = "aura", power = 3 }, route = "favor" },
	{ recipe = { branch = "fatebending", property = "probability", verb = "reduce", form = "chain", power = 5 }, route = "doom" },
	{ recipe = { branch = "fatebending", property = "probability", verb = "bind", form = "beam", power = 5 }, route = "certainty" },
	{ recipe = { branch = "fatebending", property = "probability", verb = "transmute", form = "aura", power = 5 }, route = "twist_of_fate" },
	{ recipe = { branch = "conjuration", property = "substance", verb = "generate", form = "touch", power = 3 }, route = "conjure" },
	{ recipe = { branch = "conjuration", property = "substance", verb = "generate", form = "pillar", power = 5 }, route = "conjure" },
	{ recipe = { branch = "conjuration", property = "substance", verb = "generate", form = "wall", power = 5 }, route = "conjure" },
	{ recipe = { branch = "conjuration", property = "substance", verb = "bind", form = "touch", power = 5 }, route = "cage" },
	{ recipe = { branch = "unmaking", property = "substance", verb = "reduce", form = "touch", power = 3 }, route = "unmake" },
	{ recipe = { branch = "unmaking", property = "persistence", verb = "bind", form = "aura", power = 5 }, route = "undying" },
	{ recipe = { branch = "substantiation", property = "persistence", verb = "reduce", form = "projectile", power = 4 }, route = "fray" },
	{ recipe = { branch = "polymorphy", property = "identity", verb = "transmute", form = "projectile", power = 5 }, route = "polymorph" },
	{ recipe = { branch = "lawcraft", property = "identity", verb = "transfer", form = "touch", power = 4 }, route = "exchange" },
	{ recipe = { branch = "edict", property = "law", verb = "reduce", form = "aura", power = 5 }, route = "edict" },
	{ recipe = { branch = "edict", property = "law", verb = "bind", form = "burst", power = 5 }, route = "edict" },
	{ recipe = { branch = "edict", property = "law", verb = "transmute", form = "zone", power = 6 }, route = "edict" },
	{ recipe = { branch = "worldlaw", property = "law", verb = "amplify", form = "ritual", power = 9 }, route = "worldlaw" },
}

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Reality routes", function()
		it("each power has a route, on the one resolver", function()
			for _, id in { "favor", "doom", "certainty", "twist_of_fate", "conjure", "cage", "unmake", "undying", "fray", "polymorph", "exchange", "edict", "worldlaw" } do
				local found = false
				for _, r in EffectLibrary.routes do
					found = found or (r.id == id and r.effect == "RealityPower")
				end
				expect(found).toBe(true)
			end
		end)
		it("every power is a recipe the grammar accepts, and reaches its route", function()
			local problems: { string } = {}
			for _, case in CASES do
				local ok, errors, normalized = MagicCore.validateRecipe(case.recipe)
				if not ok or not normalized then
					table.insert(problems, string.format("%s/%s %s %s: %s", case.recipe.branch, case.recipe.property, case.recipe.verb, case.recipe.form, errors[1] and errors[1].code or "?"))
				else
					local got = CastService.routeFor(normalized).id
					if got ~= case.route then
						table.insert(problems, string.format("%s %s %s routes to %s, expected %s", case.recipe.branch, case.recipe.verb, case.recipe.form, got, case.route))
					end
				end
			end
			if #problems > 0 then
				error(table.concat(problems, "\n"))
			end
		end)
		it("the older Reality spells stay where they were", function()
			expect(CastService.routeFor({ branch = "polymorphy", property = "law", verb = "transmute", form = "zone", power = 5 }).id).toBe("reality")
			expect(CastService.routeFor({ branch = "substantiation", property = "substance", verb = "reduce", form = "touch", power = 4 }).id).toBe("reality")
			expect(CastService.routeFor({ branch = "reality", property = "probability", verb = "generate", form = "aura", power = 1 }).id).toBe("fortune")
			expect(CastService.routeFor({ branch = "stasis", property = "persistence", verb = "bind", form = "touch", power = 6 }).id).toBe("stasis")
		end)
		it("a Worldlaw needs power 9; below that it's an ordinary edict", function()
			expect(CastService.routeFor({ branch = "worldlaw", property = "law", verb = "reduce", form = "ritual", power = 8 }).id).toBe("edict")
			expect(CastService.routeFor({ branch = "worldlaw", property = "law", verb = "reduce", form = "ritual", power = 9 }).id).toBe("worldlaw")
		end)
		it("an edict with no law for its verb stays the old field", function()
			expect(Rules.edictKind("generate")).toBe(nil)
			expect(CastService.routeFor({ branch = "edict", property = "law", verb = "generate", form = "zone", power = 5 }).id).toBe("reality")
			for _, verb in { "reduce", "amplify", "bind", "transmute" } do
				expect(Rules.edictKind(verb) ~= nil).toBe(true)
			end
		end)
	end)

	describe("Reality rules", function()
		it("an exchange trades percentages, and only when you'd gain", function()
			local mine, theirs = Rules.exchange(20, 100, 90, 200)
			expect(mine).toBeNear(45, 1e-6)
			expect(theirs).toBeNear(40, 1e-6)
			expect((Rules.exchange(80, 100, 50, 100))).toBe(nil)
			local _, floor = Rules.exchange(0.1, 100, 100, 100)
			expect(floor).toBe(1) -- never kills
		end)
		it("undying lets everything land except the last point", function()
			expect(Rules.undyingClamp(500, 30)).toBe(29)
			expect(Rules.undyingClamp(10, 30)).toBe(10)
			expect(Rules.undyingClamp(10, 1)).toBe(0)
		end)
		it("a crit bonus adds, lifts the cap, and at 1 is certain", function()
			expect(Rules.critChance(0.2, 0.5, 0)).toBe(0.2)
			expect(Rules.critChance(0.9, 0.5, 0)).toBe(0.5)
			expect(Rules.critChance(0.9, 0.5, 0.2)).toBeNear(0.7, 1e-6)
			expect(Rules.critChance(0.1, 0.5, 1)).toBe(1)
		end)
		it("a bridge never runs past its length", function()
			local middle, length = Rules.bridge(Vector3.zero, Vector3.new(0, 0, -500), 40)
			expect(length).toBe(40)
			expect(middle.Z).toBeNear(-20, 1e-6)
			local _, short = Rules.bridge(Vector3.zero, Vector3.new(3, 4, 0), 40)
			expect(short).toBeNear(5, 1e-6)
		end)
		it("a ring's panels close the circle", function()
			local panels = Rules.ring(10, 10)
			expect(#panels).toBe(10)
			-- Side by side they cover at least the circumference of the polygon.
			expect(panels[1].width * #panels >= 2 * math.pi * 10 * 0.95).toBe(true)
		end)
		it("an edict's radius grows with mastery inside its bounds", function()
			expect(Rules.edictRadius(1, 1)).toBe(R.edict.radiusMin)
			expect(Rules.edictRadius(1000, 1)).toBe(R.edict.radiusMax[1])
			expect(Rules.edictRadius(1000, 8)).toBe(R.edict.radiusMax[8])
		end)
		it("one Worldlaw at a time, and a long wait between yours", function()
			expect(Rules.worldlawRefusal(0, 0, 100)).toBe(nil)
			expect(Rules.worldlawRefusal(R.worldlaw.maxActive, 0, 100)).toBe("WORLD_STRAINED")
			expect(Rules.worldlawRefusal(0, 200, 100)).toBe("REALITY_COOLDOWN")
		end)
		it("each conjured shape comes from a form", function()
			expect(Rules.conjureShape("touch")).toBe("step")
			expect(Rules.conjureShape("beam")).toBe("bridge")
			expect(Rules.conjureShape("zone")).toBe("bastion")
			expect(Rules.conjureShape("summon")).toBe(nil)
		end)
	end)

	describe("Reality statuses", function()
		it("every Reality status exists", function()
			for _, id in { "reality_favored", "reality_doomed", "reality_sealed", "reality_fated", "reality_undying", "reality_frayed", "reality_polymorphed" } do
				expect(StatusEffects.defs[id] ~= nil).toBe(true)
			end
		end)
		it("a polymorph stops casting, and a recall can't bring it back alone", function()
			local humanoid = body()
			StatusEffects.apply(humanoid, "reality_polymorphed", { duration = 5 })
			expect(StatusEffects.blocksCasting(humanoid)).toBe(true)
			local saved = StatusEffects.snapshot(humanoid)
			for _, entry in saved do
				expect((entry :: any).id ~= "reality_polymorphed").toBe(true)
			end
			StatusEffects.remove(humanoid, "reality_polymorphed")
			expect(StatusEffects.blocksCasting(humanoid)).toBe(false)
		end)
		it("overdraw and an empty slate pass through untouched", function()
			local humanoid = body()
			expect(RealityRuntime.before(humanoid, 12, nil, "internal", nil)).toBe(12)
			expect(RealityRuntime.before(humanoid, 12, 1, "harm", { from = Vector3.zero })).toBe(12)
			expect(RealityRuntime.after(humanoid, 500)).toBe(500)
		end)
	end)
end
