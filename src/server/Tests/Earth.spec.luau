--!strict
--[[
	Earth.spec: Earth's spells (docs/DomainIdeas.md "Earth", Effects/EarthArt). What matters most:
	every new spell is reached by its own recipe and the old Earth spells still route as before (Raise
	Stone, Pebble Rise, Slip, Tremor, the quake, Iron Pull, the Earth strike); every route has a move, a
	Composer line and an example; the ramp builds and the dust devil summons; curves grow and stop at caps.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MagicCore = require(Shared.Magic.MagicCore)
local E = require(Shared.Magic.Data.EarthTuning)
local EffectLibrary = require(Shared.Magic.Data.EffectLibrary)
local RouteSummaries = require(Shared.Magic.Data.RouteSummaries)
local SpellExamples = require(Shared.Magic.Data.SpellExamples)

local Server = ServerScriptService.Server
local CastService = require(Server.Services.CastService)
local EarthArt = require(Server.Magic.Cast.Effects.EarthArt)
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

	describe("Earth's spells (docs/DomainIdeas.md)", function()
		it("each spell has its own recipe; the old Earth spells route as before", function()
			expect(routeOf({ branch = "lithomancy", property = "contour", verb = "generate", form = "pillar", power = 4 })).toBe("earth_spike_trail")
			expect(routeOf({ branch = "crystallurgy", property = "resonance", verb = "bind", form = "touch", power = 4 })).toBe("earth_crystal_prison")
			expect(routeOf({ branch = "faultwork", property = "seismicity", verb = "redirect", form = "beam", power = 4 })).toBe("earth_fissure")
			expect(routeOf({ branch = "dunecalling", property = "cohesion", verb = "bind", form = "summon", power = 4 })).toBe("earth_dust_devil")
			-- Unchanged at the root and in Geomancy, Seismic and Ferromancy.
			expect(routeOf({ branch = "geomancy", property = "contour", verb = "generate", form = "wall", power = 4 })).toBe("stoneshape")
			expect(routeOf({ branch = "earth", property = "contour", verb = "generate", form = "touch", power = 1 })).toBe("stonetouch")
			expect(routeOf({ branch = "geomancy", property = "contour", verb = "reduce", form = "burst", power = 5 })).toBe("landslide")
			expect(routeOf({ branch = "seismic", property = "seismicity", verb = "generate", form = "burst", power = 3 })).toBe("tremor")
			expect(routeOf({ branch = "faultwork", property = "seismicity", verb = "generate", form = "zone", power = 7 })).toBe("earthquake")
			expect(routeOf({ branch = "ferromancy", property = "magnetism", verb = "redirect", form = "projectile", power = 4 })).toBe("metal")
			expect(routeOf({ branch = "earth", property = "hardness", verb = "generate", form = "projectile", power = 2 })).toBe("strike")
			-- A big metal ritual is still Earth's ultimate; Blade Rain stops below it.
			expect(string.sub(routeOf({ branch = "ferromancy", property = "magnetism", verb = "generate", form = "ritual", power = 8 }), 1, 4)).toBe("ult_")
		end)

		it("every Earth route has a move, a Composer line and an example", function()
			local examples: { [string]: boolean } = {}
			for _, ex in SpellExamples do
				examples[ex.effect] = true
			end
			local count = 0
			for _, route in EffectLibrary.routes do
				if route.effect == "EarthArt" then
					count += 1
					local params: any = route.params or {}
					expect(EarthArt.moves[params.move] ~= nil).toBe(true)
					expect(route.id).toBe("earth_" .. params.move)
					expect((RouteSummaries.routes :: any)[route.id] ~= nil).toBe(true)
					expect(examples[route.id]).toBe(true)
					expect((E :: any)[params.move] ~= nil).toBe(true)
				end
			end
			expect(count).toBe(21)
			expect((Flags :: any).earth_arts_enabled ~= nil).toBe(true)
			expect(RouteSummaries.builds.earth_ramp).toBe(true)
			expect(RouteSummaries.summons.earth_dust_devil).toBe(true)
		end)

		it("curves grow with power and stop at their caps; holds on players stay short", function()
			for _, curve in { E.spike_trail.length, E.stone_step.height, E.boulder.roll, E.iron_storm.radius, E.fissure.length, E.quicksand.seconds } :: { E.Curve } do
				expect(E.at(curve, 0)).toBe(curve.base)
				expect(E.at(curve, 10) >= E.at(curve, 1)).toBe(true)
				expect(E.at(curve, 100)).toBe(curve.max)
			end
			expect(E.stone_grip.pvpSeconds <= 2).toBe(true)
			expect(E.crystal_prison.pvpSeconds <= 2).toBe(true)
			expect(E.quicksand.rootSeconds <= 1.5).toBe(true)
		end)
	end)
end
