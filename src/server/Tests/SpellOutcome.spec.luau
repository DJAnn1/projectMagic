--!strict
--[[
	SpellOutcome.spec: the Composer's "what will this do?" (Shared/Magic/SpellOutcome). Every route
	must have words, and the words must follow the same routing the server casts with.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local SpellRoute = require(Shared.Magic.SpellRoute)
local SpellOutcome = require(Shared.Magic.SpellOutcome)
local EffectLibrary = require(Shared.Magic.Data.EffectLibrary)
local Summaries = require(Shared.Magic.Data.RouteSummaries)
local CastService = require(game:GetService("ServerScriptService").Server.Services.CastService)

local function template(branch: string, property: string, verb: string, form: string, maxPower: number): any
	return { branch = branch, property = property, verb = verb, form = form, maxPower = maxPower, comfortPower = maxPower, modifierSlots = 1, modifiers = {} }
end

return function(t: any)
	t.describe("SpellOutcome", function()
		t.it("has a summary of a known kind for every route, and only manifest is dead", function()
			for _, route in EffectLibrary.routes do
				local summary = Summaries.routes[route.id]
				if not summary or summary.text == "" or not Summaries.kinds[summary.kind] then
					error("no usable summary for route " .. route.id)
				end
				t.expect(summary.kind == "none").toBe(route.id == "manifest")
			end
		end)

		t.it("has no summary for a route that doesn't exist", function()
			local ids: { [string]: boolean } = {}
			for _, route in EffectLibrary.routes do
				ids[route.id] = true
			end
			for id in Summaries.routes do
				t.expect(ids[id]).toBe(true)
			end
		end)

		t.it("lists every useful kind in the display order", function()
			for id in Summaries.kinds do
				t.expect(id == "none" or table.find(Summaries.kindOrder, id) ~= nil).toBe(true)
			end
		end)

		t.it("names only real modifiers as dead or wasted", function()
			for id in Summaries.deadModifiers do
				t.expect(Registry.modifiers[id] ~= nil).toBe(true)
			end
			for id in Summaries.wasted do
				t.expect(Registry.modifiers[id] ~= nil).toBe(true)
			end
		end)

		t.it("is the routing CastService casts with", function()
			local recipe = { branch = "pyromancy", property = "combustion", verb = "generate", form = "zone", power = 3 }
			t.expect(SpellRoute.find(recipe).id).toBe((CastService :: any).routeFor(recipe).id)
			t.expect(SpellOutcome.of(recipe).route).toBe(SpellRoute.find(recipe).id)
		end)

		t.it("tells a real spell from a dead one", function()
			local bolt = SpellOutcome.of({ branch = "thermal", property = "temperature", verb = "generate", form = "projectile", power = 2 })
			t.expect(bolt.useful).toBe(true)
			t.expect(SpellOutcome.tag(bolt)).toBe("⚔ Attack")
			local dead = SpellOutcome.of({ branch = "void", property = "presence", verb = "redirect", form = "touch", power = 2 })
			t.expect(dead.route).toBe("manifest")
			t.expect(dead.useful).toBe(false)
		end)

		t.it("applies verb and form variants", function()
			local chill = SpellOutcome.of({ branch = "thermal", property = "temperature", verb = "reduce", form = "touch", power = 1 })
			t.expect(chill.kind).toBe("control")
			local wound = SpellOutcome.of({ branch = "causality", property = "sequence", verb = "amplify", form = "aura", power = 1 })
			t.expect(wound.kind).toBe("protect")
		end)

		t.it("finds the power where a spell starts working, and where it changes", function()
			local slide = { branch = "earth", property = "contour", verb = "reduce", form = "burst", power = 3 }
			t.expect(SpellOutcome.of(slide).useful).toBe(false)
			t.expect(SpellOutcome.usefulFrom(slide)).toBe(4)
			local steps = SpellOutcome.steps(slide, 6)
			t.expect(#steps).toBe(1)
			t.expect(steps[1].power).toBe(4)
			t.expect(steps[1].outcome.route).toBe("landslide")
			t.expect(#SpellOutcome.steps(slide, 3)).toBe(0)
		end)

		t.it("warns about modifiers that would be wasted", function()
			local fire = SpellOutcome.of({ branch = "thermal", property = "temperature", verb = "generate", form = "projectile", power = 2 })
			t.expect(fire.repeatable).toBe(true)
			t.expect(SpellOutcome.modifierProblem("echoing", fire)).toBe(nil)
			t.expect(SpellOutcome.modifierProblem("homing", fire)).toBe(nil)
			t.expect(SpellOutcome.modifierProblem("lingering", fire) ~= nil).toBe(true)
			t.expect(SpellOutcome.modifierProblem("linked", fire) ~= nil).toBe(true)
			t.expect(SpellOutcome.modifierProblem("silent", fire) ~= nil).toBe(true)
			local charge = SpellOutcome.of({ branch = "thermal", property = "temperature", verb = "store", form = "touch", power = 1 })
			t.expect(SpellOutcome.modifierProblem("echoing", charge) ~= nil).toBe(true)
		end)

		t.it("only claims a wall when one is built", function()
			local stone = SpellOutcome.of({ branch = "earth", property = "contour", verb = "generate", form = "wall", power = 2 })
			t.expect(stone.shape).toBe(nil)
			local fire = SpellOutcome.of({ branch = "thermal", property = "temperature", verb = "generate", form = "wall", power = 2 })
			t.expect(fire.shape).toBe(Summaries.areaShape)
		end)

		t.it("summarizes a choice at the caster's best power", function()
			local list = { template("earth", "contour", "reduce", "burst", 3) }
			local low = SpellOutcome.summarize(list, function()
				return true
			end)
			t.expect(low.useful).toBe(false)
			list[1].maxPower = 5
			-- Same recipe at a power it can now reach: the key differs, so this isn't the cached answer.
			local high = SpellOutcome.summarize(list, function()
				return true
			end)
			t.expect(high.useful).toBe(true)
			t.expect(high.tag).toBe("▲ Shape the world")
		end)

		t.it("offers the nearest working spells, one per kind", function()
			local dead = { branch = "void", property = "presence", verb = "redirect", form = "touch", power = 2 }
			local list = {
				template("void", "presence", "redirect", "touch", 3), -- the dead spell itself
				template("void", "presence", "reduce", "touch", 3), -- veil: same property
				template("void", "presence", "reduce", "beam", 3), -- also protect: skipped
				template("void", "aether", "generate", "touch", 1), -- a different kind (Void's strike)
			}
			local found = SpellOutcome.alternatives(dead, list, 3)
			t.expect(#found).toBe(2)
			t.expect(found[1].recipe.verb).toBe("reduce")
			t.expect(found[2].recipe.property).toBe("aether")
			t.expect(found[2].recipe.power).toBe(1) -- clamped to what that template allows
			t.expect(#SpellOutcome.alternatives(dead, list, 1)).toBe(1)
		end)
	end)
end
