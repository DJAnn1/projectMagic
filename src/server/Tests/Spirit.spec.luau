--!strict
--[[
	Spirit.spec: Spirit's spells (docs/DomainIdeas.md "Spirit", Effects/SpiritArt). What matters most:
	every new spell is reached by its own recipe and the old Spirit spells still route as before (the
	Ward, the hex bolt, Soul Prick, Sense); every route has a move, a Composer line and an example; the
	runtime's victim hook and Shared Fate table exist; curves grow and stop at caps; holds stay short.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MagicCore = require(Shared.Magic.MagicCore)
local E = require(Shared.Magic.Data.SpiritTuning)
local EffectLibrary = require(Shared.Magic.Data.EffectLibrary)
local RouteSummaries = require(Shared.Magic.Data.RouteSummaries)
local SpellExamples = require(Shared.Magic.Data.SpellExamples)

local Server = ServerScriptService.Server
local CastService = require(Server.Services.CastService)
local SpiritArt = require(Server.Magic.Cast.Effects.SpiritArt)
local Flags = require(Server.Config.Flags)

local function routeOf(recipe: any): string
	local ok, errors, normalized = MagicCore.validateRecipe(recipe)
	if not ok or not normalized then
		error("invalid recipe: " .. (errors[1] and errors[1].message or "?"))
	end
	return CastService.routeFor(normalized).id
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Spirit's spells (docs/DomainIdeas.md)", function()
		it("each spell has its own recipe; the old Spirit spells route as before", function()
			expect(routeOf({ branch = "warding", property = "warding", verb = "generate", form = "wall", power = 4 })).toBe("spirit_glyph_shield")
			expect(routeOf({ branch = "hexcraft", property = "malediction", verb = "amplify", form = "touch", power = 4 })).toBe("spirit_doom_mark")
			expect(routeOf({ branch = "pactcraft", property = "will", verb = "bind", form = "touch", power = 4 })).toBe("spirit_shared_fate")
			expect(routeOf({ branch = "revenancy", property = "soul", verb = "generate", form = "summon", power = 5 })).toBe("spirit_spirit_wolves")
			-- Unchanged.
			expect(routeOf({ branch = "warding", property = "warding", verb = "generate", form = "aura", power = 4 })).toBe("ward")
			expect(routeOf({ branch = "hexcraft", property = "malediction", verb = "generate", form = "projectile", power = 4 })).toBe("afflict")
			expect(routeOf({ branch = "spirit", property = "essence", verb = "sense", form = "aura", power = 2 })).toBe("sense")
			expect(routeOf({ branch = "spirit", property = "essence", verb = "generate", form = "touch", power = 1 })).toBe("harm")
		end)

		it("every Spirit route has a move, a Composer line and an example; the runtime hooks exist", function()
			local examples: { [string]: boolean } = {}
			for _, ex in SpellExamples do
				examples[ex.effect] = true
			end
			local count = 0
			for _, route in EffectLibrary.routes do
				if route.effect == "SpiritArt" then
					count += 1
					local params: any = route.params or {}
					expect(SpiritArt.moves[params.move] ~= nil).toBe(true)
					expect(route.id).toBe("spirit_" .. params.move)
					expect((RouteSummaries.routes :: any)[route.id] ~= nil).toBe(true)
					expect(examples[route.id]).toBe(true)
					expect((E :: any)[params.move] ~= nil).toBe(true)
				end
			end
			expect(count).toBe(15)
			expect((Flags :: any).spirit_arts_enabled ~= nil).toBe(true)
			expect(RouteSummaries.builds.spirit_glyph_shield).toBe(true)
			expect(RouteSummaries.summons.spirit_spirit_wolves).toBe(true)
			local ArtRuntime = require(Server.Magic.Cast.ArtRuntime)
			expect(typeof(ArtRuntime.oaths)).toBe("table")
		end)

		it("curves grow with power and stop at their caps; holds on players stay short", function()
			for _, curve in { E.glyph_shield.width, E.sigil_trap.seconds, E.doom_mark.seconds, E.shared_fate.seconds, E.spirit_wolves.seconds, E.wail.radius } :: { E.Curve } do
				expect(E.at(curve, 0)).toBe(curve.base)
				expect(E.at(curve, 10) >= E.at(curve, 1)).toBe(true)
				expect(E.at(curve, 100)).toBe(curve.max)
			end
			expect(E.spirit_chains.pvpSeconds <= 2).toBe(true)
			expect(E.grave_hand.pvpSeconds <= 2).toBe(true)
			expect(E.shared_fate.split > 0 and E.shared_fate.split < 1).toBe(true)
			expect(E.ghost_form.resist < 1).toBe(true)
		end)
	end)
end
