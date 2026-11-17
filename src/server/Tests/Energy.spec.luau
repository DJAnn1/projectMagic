--!strict
--[[
	Energy.spec: Energy's spells (docs/DomainIdeas.md "Energy", Effects/EnergyArt). What matters most:
	every new spell is reached by its own recipe and the old Energy spells still route as before (Candle,
	Warmth Draw, Searing Ray, Kindle, a low Fire Whip, the cantrips' heat); every route has a move, a
	Composer line and an example; walls and summons say they build; the curves grow and stop at caps.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MagicCore = require(Shared.Magic.MagicCore)
local E = require(Shared.Magic.Data.EnergyTuning)
local EffectLibrary = require(Shared.Magic.Data.EffectLibrary)
local RouteSummaries = require(Shared.Magic.Data.RouteSummaries)
local SpellExamples = require(Shared.Magic.Data.SpellExamples)

local Server = ServerScriptService.Server
local CastService = require(Server.Services.CastService)
local EnergyArt = require(Server.Magic.Cast.Effects.EnergyArt)
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

	describe("Energy's spells (docs/DomainIdeas.md)", function()
		it("each spell has its own recipe; the old Energy spells route as before", function()
			expect(routeOf({ branch = "pyromancy", property = "combustion", verb = "generate", form = "burst", power = 4 })).toBe("energy_ember_swarm")
			expect(routeOf({ branch = "cryothermy", property = "temperature", verb = "reduce", form = "pillar", power = 4 })).toBe("energy_ice_spike_line")
			expect(routeOf({ branch = "umbramancy", property = "shadow", verb = "generate", form = "summon", power = 4 })).toBe("energy_shadow_puppet")
			expect(routeOf({ branch = "arcweaving", property = "charge", verb = "bind", form = "chain", power = 4 })).toBe("energy_arc_tether")
			-- Unchanged: a fire bolt, the cantrips' heat, a light beam, warmth drawn, a fire zone, a weak touch.
			expect(routeOf({ branch = "pyromancy", property = "combustion", verb = "generate", form = "projectile", power = 4 })).toBe("ignite")
			expect(routeOf({ branch = "energy", property = "temperature", verb = "generate", form = "touch", power = 1 })).toBe("thermal")
			expect(routeOf({ branch = "photomancy", property = "luminosity", verb = "generate", form = "beam", power = 5 })).toBe("harm")
			expect(routeOf({ branch = "calefaction", property = "temperature", verb = "transfer", form = "touch", power = 3 })).toBe("heat_transfer")
			expect(routeOf({ branch = "pyromancy", property = "combustion", verb = "generate", form = "zone", power = 3 })).toBe("ignite")
			expect(routeOf({ branch = "pyromancy", property = "combustion", verb = "generate", form = "touch", power = 1 })).toBe("ignite")
			-- Outside its branch a recipe keeps the ordinary route: plain Thermal frost on a pillar.
			expect(routeOf({ branch = "thermal", property = "temperature", verb = "reduce", form = "pillar", power = 4 })).toBe("thermal")
			-- Energy's ultimate still answers a big ritual.
			expect(string.sub(routeOf({ branch = "conflagration", property = "combustion", verb = "generate", form = "ritual", power = 8 }), 1, 4)).toBe("ult_")
		end)

		it("every Energy route has a move, a Composer line and an example", function()
			local examples: { [string]: boolean } = {}
			for _, ex in SpellExamples do
				examples[ex.effect] = true
			end
			local count = 0
			for _, route in EffectLibrary.routes do
				if route.effect == "EnergyArt" then
					count += 1
					local params: any = route.params or {}
					expect(EnergyArt.moves[params.move] ~= nil).toBe(true)
					expect(route.id).toBe("energy_" .. params.move)
					expect((RouteSummaries.routes :: any)[route.id] ~= nil).toBe(true)
					expect(examples[route.id]).toBe(true)
					expect((E :: any)[params.move] ~= nil).toBe(true)
				end
			end
			expect(count).toBe(32)
			expect((Flags :: any).energy_arts_enabled ~= nil).toBe(true)
		end)

		it("walls and summons say they build; projectiles with a look name one the client draws", function()
			for _, id in { "energy_ring_of_fire", "energy_ice_mirror", "energy_arc_fence" } do
				expect(RouteSummaries.builds[id]).toBe(true)
			end
			for _, id in { "energy_wisps", "energy_shadow_puppet" } do
				expect(RouteSummaries.summons[id]).toBe(true)
			end
			local looks = { serpent = true, lance = true, prism = true, ricochet = true, ball = true }
			for _, route in EffectLibrary.routes do
				local look = route.params and route.params.look
				if route.effect == "EnergyArt" and look then
					expect(looks[look]).toBe(true)
					expect(route.forms ~= nil and table.find(route.forms, "projectile") ~= nil).toBe(true)
				end
			end
		end)

		it("curves grow with power and stop at their caps; the caps hold together", function()
			for _, curve in { E.ember_swarm.embers, E.ring_of_fire.radius, E.ice_spike_line.length, E.static_field.seconds, E.arc_fence.length, E.wisps.seconds } :: { E.Curve } do
				expect(E.at(curve, 0)).toBe(curve.base)
				expect(E.at(curve, 10) >= E.at(curve, 1)).toBe(true)
				expect(E.at(curve, 100)).toBe(curve.max)
			end
			local ArtRuntime = require(Server.Magic.Cast.ArtRuntime)
			expect(ArtRuntime.caps.perPlayer < ArtRuntime.caps.server).toBe(true)
			expect(E.shadow_grasp.pvpSeconds <= E.shadow_grasp.seconds.max).toBe(true)
			expect(E.ball_lightning.speed < 1 and E.flame_serpent.speed <= 1).toBe(true)
		end)
	end)
end
