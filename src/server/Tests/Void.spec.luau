--!strict
--[[
	Void.spec: Void's spells (docs/DomainIdeas.md "Void", Effects/VoidArt). What matters most: every new
	spell is reached by its own recipe and the old Void spells still route as before (Dispel, Silence,
	darkness, Still, Siphon, Unmake the strike); every route has a move, a Composer line and an example;
	curves grow and stop at caps; holds on players stay short.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MagicCore = require(Shared.Magic.MagicCore)
local E = require(Shared.Magic.Data.VoidTuning)
local EffectLibrary = require(Shared.Magic.Data.EffectLibrary)
local RouteSummaries = require(Shared.Magic.Data.RouteSummaries)
local SpellExamples = require(Shared.Magic.Data.SpellExamples)

local Server = ServerScriptService.Server
local CastService = require(Server.Services.CastService)
local VoidArt = require(Server.Magic.Cast.Effects.VoidArt)
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

	describe("Void's spells (docs/DomainIdeas.md)", function()
		it("each spell has its own recipe; the old Void spells route as before", function()
			expect(routeOf({ branch = "dispelling", property = "aether", verb = "transmute", form = "beam", power = 5 })).toBe("void_unravel")
			expect(routeOf({ branch = "eclipse", property = "luminosity", verb = "reduce", form = "pillar", power = 5 })).toBe("void_black_sun")
			expect(routeOf({ branch = "siphoning", property = "essence", verb = "bind", form = "aura", power = 5 })).toBe("void_sponge")
			expect(routeOf({ branch = "obscurance", property = "presence", verb = "redirect", form = "touch", power = 3 })).toBe("void_shadow_step")
			-- Unchanged.
			expect(routeOf({ branch = "negation", property = "aether", verb = "reduce", form = "burst", power = 4 })).toBe("dispel")
			expect(routeOf({ branch = "silence", property = "sound", verb = "reduce", form = "zone", power = 5 })).toBe("silence")
			expect(routeOf({ branch = "eclipse", property = "luminosity", verb = "reduce", form = "zone", power = 5 })).toBe("darken")
			expect(routeOf({ branch = "stillness", property = "momentum", verb = "reduce", form = "zone", power = 5 })).toBe("still")
			expect(routeOf({ branch = "siphoning", property = "essence", verb = "transfer", form = "touch", power = 4 })).toBe("siphon")
			expect(routeOf({ branch = "void", property = "aether", verb = "generate", form = "touch", power = 1 })).toBe("strike")
		end)

		it("every Void route has a move, a Composer line and an example", function()
			local examples: { [string]: boolean } = {}
			for _, ex in SpellExamples do
				examples[ex.effect] = true
			end
			local count = 0
			for _, route in EffectLibrary.routes do
				if route.effect == "VoidArt" then
					count += 1
					local params: any = route.params or {}
					expect(VoidArt.moves[params.move] ~= nil).toBe(true)
					expect(route.id).toBe("void_" .. params.move)
					expect((RouteSummaries.routes :: any)[route.id] ~= nil).toBe(true)
					expect(examples[route.id]).toBe(true)
					expect((E :: any)[params.move] ~= nil).toBe(true)
				end
			end
			expect(count).toBe(13)
			expect((Flags :: any).void_arts_enabled ~= nil).toBe(true)
			local ArtRuntime = require(Server.Magic.Cast.ArtRuntime)
			expect(typeof(ArtRuntime.all())).toBe("table")
		end)

		it("curves grow with power and stop at their caps; holds on players stay short", function()
			for _, curve in { E.unravel.length, E.antimagic_shell.resist, E.null_ground.radius, E.sponge.charges, E.shadow_step.reach, E.black_flame.burn } :: { E.Curve } do
				expect(E.at(curve, 0)).toBe(curve.base)
				expect(E.at(curve, 10) >= E.at(curve, 1)).toBe(true)
				expect(E.at(curve, 100)).toBe(curve.max)
			end
			expect(E.hush.pvpSeconds <= 2).toBe(true)
			expect(E.antimagic_shell.resist.max <= 0.6).toBe(true)
			expect(E.null_ground.silenceSeconds <= 1).toBe(true)
		end)
	end)
end
