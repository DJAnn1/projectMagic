--!strict
--[[
	Life.spec: Life's spells (docs/DomainIdeas.md "Life", Effects/LifeArt). What matters most: every new
	spell is reached by its own recipe and the old Life spells still route as before (healing, Thornlash,
	Purgation's cleanse, Beastspeech's calm, Blight's poison bolt); every route has a move, a Composer line
	and an example; the downed-revive hook is wired; curves grow and stop at caps; holds on players stay short.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MagicCore = require(Shared.Magic.MagicCore)
local E = require(Shared.Magic.Data.LifeTuning)
local EffectLibrary = require(Shared.Magic.Data.EffectLibrary)
local RouteSummaries = require(Shared.Magic.Data.RouteSummaries)
local SpellExamples = require(Shared.Magic.Data.SpellExamples)

local Server = ServerScriptService.Server
local CastService = require(Server.Services.CastService)
local LifeArt = require(Server.Magic.Cast.Effects.LifeArt)
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

	describe("Life's spells (docs/DomainIdeas.md)", function()
		it("each spell has its own recipe; the old Life spells route as before", function()
			expect(routeOf({ branch = "mending", property = "vitality", verb = "generate", form = "zone", power = 4 })).toBe("life_healing_grove")
			expect(routeOf({ branch = "arborism", property = "growth", verb = "generate", form = "pillar", power = 4 })).toBe("life_sapling")
			expect(routeOf({ branch = "resurgence", property = "vitality", verb = "amplify", form = "touch", power = 5 })).toBe("life_raise_them")
			expect(routeOf({ branch = "pestilence", property = "toxin", verb = "generate", form = "projectile", power = 4 })).toBe("life_plague_flies")
			-- Unchanged.
			expect(routeOf({ branch = "restoration", property = "vitality", verb = "amplify", form = "touch", power = 3 })).toBe("restore")
			expect(routeOf({ branch = "life", property = "growth", verb = "generate", form = "aura", power = 1 })).toBe("restore")
			expect(routeOf({ branch = "life", property = "growth", verb = "generate", form = "touch", power = 1 })).toBe("strike")
			expect(routeOf({ branch = "flora", property = "growth", verb = "generate", form = "projectile", power = 2 })).toBe("strike")
			expect(routeOf({ branch = "purgation", property = "toxin", verb = "reduce", form = "touch", power = 4 })).toBe("cleanse")
			expect(routeOf({ branch = "beastspeech", property = "instinct", verb = "reduce", form = "touch", power = 3 })).toBe("soothe")
			expect(routeOf({ branch = "blight", property = "toxin", verb = "generate", form = "projectile", power = 4 })).toBe("afflict")
		end)

		it("every Life route has a move, a Composer line and an example; the revive hook is wired", function()
			local examples: { [string]: boolean } = {}
			for _, ex in SpellExamples do
				examples[ex.effect] = true
			end
			local count = 0
			for _, route in EffectLibrary.routes do
				if route.effect == "LifeArt" then
					count += 1
					local params: any = route.params or {}
					expect(LifeArt.moves[params.move] ~= nil).toBe(true)
					expect(route.id).toBe("life_" .. params.move)
					expect((RouteSummaries.routes :: any)[route.id] ~= nil).toBe(true)
					expect(examples[route.id]).toBe(true)
					expect((E :: any)[params.move] ~= nil).toBe(true)
				end
			end
			expect(count).toBe(19)
			expect((Flags :: any).life_arts_enabled ~= nil).toBe(true)
			expect(RouteSummaries.builds.life_bramble_wall).toBe(true)
			local ArtRuntime = require(Server.Magic.Cast.ArtRuntime)
			expect(ArtRuntime.revive ~= nil).toBe(true)
		end)

		it("curves grow with power and stop at their caps; holds on players stay short", function()
			for _, curve in { E.healing_grove.radius, E.root_snare.seconds, E.sapling.height, E.fairy_ring.bounce, E.withering_field.seconds, E.corpse_bloom.seconds } :: { E.Curve } do
				expect(E.at(curve, 0)).toBe(curve.base)
				expect(E.at(curve, 10) >= E.at(curve, 1)).toBe(true)
				expect(E.at(curve, 100)).toBe(curve.max)
			end
			expect(E.root_snare.pvpSeconds <= 2).toBe(true)
			expect(E.lifeline.mult > 1 and E.lifeline.floor > 0).toBe(true)
			expect(E.plague_flies.jumps <= 3).toBe(true)
		end)
	end)
end
