--!strict
--[[
	Mind.spec: Mind's spells (docs/DomainIdeas.md "Mind", Effects/MindArt). What matters most: every new
	spell is reached by its own recipe and the old Mind spells still route as before (fear, charm, the
	blinding illusion, the veil, Sense, Psychic Spike); every route has a move, a Composer line and an
	example; the runtime's forget and screen hooks exist; curves grow and stop at caps; holds stay short.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MagicCore = require(Shared.Magic.MagicCore)
local E = require(Shared.Magic.Data.MindTuning)
local EffectLibrary = require(Shared.Magic.Data.EffectLibrary)
local RouteSummaries = require(Shared.Magic.Data.RouteSummaries)
local SpellExamples = require(Shared.Magic.Data.SpellExamples)

local Server = ServerScriptService.Server
local CastService = require(Server.Services.CastService)
local MindArt = require(Server.Magic.Cast.Effects.MindArt)
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

	describe("Mind's spells (docs/DomainIdeas.md)", function()
		it("each spell has its own recipe; the old Mind spells route as before", function()
			expect(routeOf({ branch = "farsight", property = "perception", verb = "amplify", form = "projectile", power = 4 })).toBe("mind_far_eye")
			expect(routeOf({ branch = "phantasm", property = "illusion", verb = "transmute", form = "wall", power = 4 })).toBe("mind_false_wall")
			expect(routeOf({ branch = "oblivion", property = "memory", verb = "reduce", form = "touch", power = 4 })).toBe("mind_forget_me")
			expect(routeOf({ branch = "dominion", property = "will", verb = "bind", form = "touch", power = 5 })).toBe("mind_puppet")
			-- Unchanged.
			expect(routeOf({ branch = "dread", property = "emotion", verb = "amplify", form = "burst", power = 5 })).toBe("fear")
			expect(routeOf({ branch = "charm", property = "emotion", verb = "generate", form = "touch", power = 4 })).toBe("charm")
			expect(routeOf({ branch = "illusion", property = "illusion", verb = "generate", form = "burst", power = 4 })).toBe("illusion_blind")
			expect(routeOf({ branch = "veiling", property = "illusion", verb = "reduce", form = "aura", power = 4 })).toBe("veil")
			expect(routeOf({ branch = "insight", property = "thought", verb = "sense", form = "beam", power = 3 })).toBe("sense")
			expect(routeOf({ branch = "mind", property = "perception", verb = "generate", form = "projectile", power = 2 })).toBe("strike")
			expect(routeOf({ branch = "mind", property = "perception", verb = "sense", form = "aura", power = 1 })).toBe("sense")
		end)

		it("every Mind route has a move, a Composer line and an example; the runtime hooks exist", function()
			local examples: { [string]: boolean } = {}
			for _, ex in SpellExamples do
				examples[ex.effect] = true
			end
			local count = 0
			for _, route in EffectLibrary.routes do
				if route.effect == "MindArt" then
					count += 1
					local params: any = route.params or {}
					expect(MindArt.moves[params.move] ~= nil).toBe(true)
					expect(route.id).toBe("mind_" .. params.move)
					expect((RouteSummaries.routes :: any)[route.id] ~= nil).toBe(true)
					expect(examples[route.id]).toBe(true)
					expect((E :: any)[params.move] ~= nil).toBe(true)
				end
			end
			expect(count).toBe(16)
			expect((Flags :: any).mind_arts_enabled ~= nil).toBe(true)
			expect(RouteSummaries.builds.mind_false_wall).toBe(true)
			expect(RouteSummaries.summons.mind_phantom_beast).toBe(true)
			local ArtRuntime = require(Server.Magic.Cast.ArtRuntime)
			expect(typeof(ArtRuntime.forget)).toBe("function")
			expect(typeof(ArtRuntime.screened)).toBe("function")
			-- Nothing stands anywhere: an empty runtime screens nothing.
			expect(ArtRuntime.screened(Vector3.new(0, 1e5, 0), Vector3.new(10, 1e5, 0))).toBe(false)
		end)

		it("curves grow with power and stop at their caps; holds on players stay short", function()
			for _, curve in { E.far_eye.seconds, E.despair.radius, E.false_wall.width, E.vanish.seconds, E.forget_me.seconds, E.psychic_push.push, E.puppet.reach } :: { E.Curve } do
				expect(E.at(curve, 0)).toBe(curve.base)
				expect(E.at(curve, 10) >= E.at(curve, 1)).toBe(true)
				expect(E.at(curve, 100)).toBe(curve.max)
			end
			expect(E.puppet.pvpSeconds <= 2).toBe(true)
			expect(E.puppet.pvpReach < E.at(E.puppet.reach, 0)).toBe(true)
		end)
	end)
end
