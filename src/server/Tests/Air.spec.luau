--!strict
--[[
	Air.spec: Air's spells (docs/DomainIdeas.md "Air", Effects/AirArt). What matters most: every new
	spell is reached by its own recipe and the old Air spells still route as before (Gust, the Thunderclap
	example, Vacuity's choke, the weathercraft bolt, the root's Sense); Echo Pulse beats the general Sense;
	every route has a move, a Composer line and an example; curves grow and stop at caps.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MagicCore = require(Shared.Magic.MagicCore)
local E = require(Shared.Magic.Data.AirTuning)
local EffectLibrary = require(Shared.Magic.Data.EffectLibrary)
local RouteSummaries = require(Shared.Magic.Data.RouteSummaries)
local SpellExamples = require(Shared.Magic.Data.SpellExamples)

local Server = ServerScriptService.Server
local CastService = require(Server.Services.CastService)
local AirArt = require(Server.Magic.Cast.Effects.AirArt)
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

	describe("Air's spells (docs/DomainIdeas.md)", function()
		it("each spell has its own recipe; the old Air spells route as before", function()
			expect(routeOf({ branch = "windshaping", property = "flow", verb = "generate", form = "projectile", power = 4 })).toBe("air_wind_blade")
			expect(routeOf({ branch = "tempest", property = "flow", verb = "bind", form = "summon", power = 5 })).toBe("air_twister")
			expect(routeOf({ branch = "echolocation", property = "sound", verb = "sense", form = "burst", power = 3 })).toBe("air_echo_pulse")
			expect(routeOf({ branch = "stormbrewing", property = "charge", verb = "release", form = "pillar", power = 4 })).toBe("air_call_lightning")
			-- Unchanged.
			expect(routeOf({ branch = "air", property = "flow", verb = "generate", form = "projectile", power = 3 })).toBe("force")
			expect(routeOf({ branch = "thunderclap", property = "sound", verb = "amplify", form = "burst", power = 5 })).toBe("harm")
			expect(routeOf({ branch = "weathercraft", property = "charge", verb = "generate", form = "projectile", power = 4 })).toBe("harm")
			expect(routeOf({ branch = "air", property = "pressure", verb = "sense", form = "aura", power = 2 })).toBe("sense")
			expect(routeOf({ branch = "sonics", property = "sound", verb = "sense", form = "aura", power = 2 })).toBe("sense")
			-- A storm ritual Stormbrewing can reach (power 7 at most) is Hail.
			expect(string.sub(routeOf({ branch = "stormbrewing", property = "temperature", verb = "reduce", form = "ritual", power = 7 }), 1, 4)).toBe("air_")
		end)

		it("every Air route has a move, a Composer line and an example", function()
			local examples: { [string]: boolean } = {}
			for _, ex in SpellExamples do
				examples[ex.effect] = true
			end
			local count = 0
			for _, route in EffectLibrary.routes do
				if route.effect == "AirArt" then
					count += 1
					local params: any = route.params or {}
					expect(AirArt.moves[params.move] ~= nil).toBe(true)
					expect(route.id).toBe("air_" .. params.move)
					expect((RouteSummaries.routes :: any)[route.id] ~= nil).toBe(true)
					expect(examples[route.id]).toBe(true)
					expect((E :: any)[params.move] ~= nil).toBe(true)
				end
			end
			expect(count).toBe(15)
			expect((Flags :: any).air_arts_enabled ~= nil).toBe(true)
			expect(RouteSummaries.builds.air_windwall).toBe(true)
			expect(RouteSummaries.summons.air_twister).toBe(true)
		end)

		it("curves grow with power and stop at their caps; holds on players stay short", function()
			for _, curve in { E.gale.push, E.twister.seconds, E.windwall.width, E.sonic_ring.length, E.echo_pulse.radius, E.hail.stones } :: { E.Curve } do
				expect(E.at(curve, 0)).toBe(curve.base)
				expect(E.at(curve, 10) >= E.at(curve, 1)).toBe(true)
				expect(E.at(curve, 100)).toBe(curve.max)
			end
			expect(E.airless.pvpSeconds <= 2).toBe(true)
			expect(E.call_lightning.soakedMult > 1).toBe(true)
		end)
	end)
end
