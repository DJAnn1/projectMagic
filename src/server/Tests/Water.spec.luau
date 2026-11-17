--!strict
--[[
	Water.spec: Water's spells (docs/DomainIdeas.md "Water", Effects/WaterArt). What matters most:
	every new spell is reached by its own recipe and the old Water spells still route as before (Pour,
	Freeze, Undertow, Breaker, the tsunami, the cantrip's Scald); every route has a move, a Composer line
	and an example; the wave and the dome build; curves grow and stop at caps; holds on players stay short.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MagicCore = require(Shared.Magic.MagicCore)
local E = require(Shared.Magic.Data.WaterTuning)
local EffectLibrary = require(Shared.Magic.Data.EffectLibrary)
local RouteSummaries = require(Shared.Magic.Data.RouteSummaries)
local SpellExamples = require(Shared.Magic.Data.SpellExamples)

local Server = ServerScriptService.Server
local CastService = require(Server.Services.CastService)
local WaterArt = require(Server.Magic.Cast.Effects.WaterArt)
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

	describe("Water's spells (docs/DomainIdeas.md)", function()
		it("each spell has its own recipe; the old Water spells route as before", function()
			expect(routeOf({ branch = "hydrostatics", property = "pressure", verb = "generate", form = "beam", power = 4 })).toBe("water_pressure_jet")
			expect(routeOf({ branch = "tidal", property = "flow", verb = "generate", form = "wall", power = 4 })).toBe("water_wave_surge")
			expect(routeOf({ branch = "permafrost", property = "phase", verb = "bind", form = "zone", power = 5 })).toBe("water_permafrost")
			expect(routeOf({ branch = "wellspring", property = "humidity", verb = "generate", form = "pillar", power = 4 })).toBe("water_fountain")
			-- Unchanged.
			expect(routeOf({ branch = "water", property = "humidity", verb = "generate", form = "burst", power = 2 })).toBe("pour")
			expect(routeOf({ branch = "glaciation", property = "phase", verb = "reduce", form = "zone", power = 4 })).toBe("freeze")
			expect(routeOf({ branch = "tidal", property = "flow", verb = "redirect", form = "zone", power = 4 })).toBe("current")
			expect(routeOf({ branch = "tidal", property = "flow", verb = "redirect", form = "burst", power = 5 })).toBe("wave")
			expect(routeOf({ branch = "hydromancy", property = "flow", verb = "generate", form = "touch", power = 1 })).toBe("pour")
			expect(routeOf({ branch = "water", property = "temperature", verb = "generate", form = "touch", power = 1 })).toBe("thermal")
			-- A big ice ritual is still Water's ultimate; Icicle Rain stops below it.
			expect(string.sub(routeOf({ branch = "permafrost", property = "phase", verb = "transmute", form = "ritual", power = 8 }), 1, 4)).toBe("ult_")
		end)

		it("every Water route has a move, a Composer line and an example", function()
			local examples: { [string]: boolean } = {}
			for _, ex in SpellExamples do
				examples[ex.effect] = true
			end
			local count = 0
			for _, route in EffectLibrary.routes do
				if route.effect == "WaterArt" then
					count += 1
					local params: any = route.params or {}
					expect(WaterArt.moves[params.move] ~= nil).toBe(true)
					expect(route.id).toBe("water_" .. params.move)
					expect((RouteSummaries.routes :: any)[route.id] ~= nil).toBe(true)
					expect(examples[route.id]).toBe(true)
					expect((E :: any)[params.move] ~= nil).toBe(true)
				end
			end
			expect(count).toBe(18)
			expect((Flags :: any).water_arts_enabled ~= nil).toBe(true)
			expect(RouteSummaries.builds.water_wave_surge).toBe(true)
			expect(RouteSummaries.builds.water_ice_dome).toBe(true)
		end)

		it("curves grow with power and stop at their caps; holds on players stay short", function()
			for _, curve in { E.pressure_jet.length, E.geyser.lift, E.wave_surge.distance, E.ice_slide.length, E.fog_bank.radius, E.fountain.seconds } :: { E.Curve } do
				expect(E.at(curve, 0)).toBe(curve.base)
				expect(E.at(curve, 10) >= E.at(curve, 1)).toBe(true)
				expect(E.at(curve, 100)).toBe(curve.max)
			end
			expect(E.bubble.pvpSeconds <= 2).toBe(true)
			expect(E.permafrost.rootSeconds <= 1.2).toBe(true)
		end)
	end)
end
