--!strict
--[[
	Space.spec: Space's powers, stage 1 (docs/Space.md). What matters most: each power is reached by its own
	branch and nothing else moved (blink, Displace and Fold route as before); every power has a resolver, a
	Composer line and its statuses; the tier curves grow and stop at their caps; seals on players are short.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local MagicCore = require(Shared.Magic.MagicCore)
local S = require(Shared.Magic.Data.SpaceTuning)
local EffectLibrary = require(Shared.Magic.Data.EffectLibrary)
local RouteSummaries = require(Shared.Magic.Data.RouteSummaries)
local StatusInfo = require(Shared.Magic.Data.StatusInfo)

local Server = ServerScriptService.Server
local CastService = require(Server.Services.CastService)
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

	describe("Space powers (docs/Space.md)", function()
		it("each power is reached by its own branch; blink, Displace and Fold are unchanged", function()
			expect(routeOf({ branch = "gatecraft", property = "boundary", verb = "transfer", form = "zone", power = 4 })).toBe("space_gate")
			expect(routeOf({ branch = "sealing", property = "boundary", verb = "bind", form = "touch", power = 3 })).toBe("space_seal")
			-- Transmute needs a tier 2 branch, release a tier 1 (log 2026-11-16): Blinking and Translocation.
			expect(routeOf({ branch = "blinking", property = "position", verb = "transmute", form = "touch", power = 3 })).toBe("space_swap")
			expect(routeOf({ branch = "folding", property = "distance", verb = "reduce", form = "aura", power = 3 })).toBe("space_stride")
			expect(routeOf({ branch = "translocation", property = "distance", verb = "release", form = "beam", power = 4 })).toBe("space_cut")
			expect(routeOf({ branch = "blinking", property = "position", verb = "redirect", form = "projectile", power = 4 })).toBe("blink")
			expect(routeOf({ branch = "translocation", property = "position", verb = "transfer", form = "touch", power = 3 })).toBe("blink")
			expect(routeOf({ branch = "folding", property = "volume", verb = "reduce", form = "burst", power = 4 })).toBe("fold")
		end)

		it("stage 2: pocket, anchor, recall and stretch each have their own recipe", function()
			expect(routeOf({ branch = "pocketcraft", property = "volume", verb = "amplify", form = "aura", power = 3 })).toBe("space_pocket")
			expect(routeOf({ branch = "blinking", property = "position", verb = "bind", form = "touch", power = 3 })).toBe("space_anchor")
			expect(routeOf({ branch = "blinking", property = "position", verb = "release", form = "aura", power = 3 })).toBe("space_recall")
			expect(routeOf({ branch = "folding", property = "distance", verb = "amplify", form = "zone", power = 4 })).toBe("space_stretch")
			-- Folding Stride still answers on the aura, and Cut on a beam
			expect(routeOf({ branch = "folding", property = "distance", verb = "amplify", form = "aura", power = 3 })).toBe("space_stride")
			expect(routeOf({ branch = "blinking", property = "position", verb = "release", form = "beam", power = 3 })).toBe("space_cut")
			-- Recall reaches the whole island from Grandmaster; the pocket only grows
			expect(S.anchorReach(6) >= 4096 * 1.5).toBe(true)
			expect(S.anchorReach(0) > 0).toBe(true)
			expect(S.byTier(S.pocket.slots, 8) > S.byTier(S.pocket.slots, 0)).toBe(true)
			expect(StatusInfo.space_stretched ~= nil and StatusInfo.space_stretched.harmful).toBe(true)
		end)

		it("stage 3: worldgate, hideaway and Starfall Gate; a big gate ritual stays a gate", function()
			expect(routeOf({ branch = "worldgates", property = "boundary", verb = "transfer", form = "ritual", power = 9 })).toBe("space_worldgate")
			expect(routeOf({ branch = "pocketcraft", property = "volume", verb = "bind", form = "touch", power = 4 })).toBe("space_hideaway")
			expect(routeOf({ branch = "space", property = "presence", verb = "amplify", form = "ritual", power = 8 })).toBe("ult_starfall_gate")
			expect(routeOf({ branch = "space", property = "distance", verb = "amplify", form = "ritual", power = 8 })).toBe("ult_fold_of_worlds")
			-- Space's own powers still answer a ritual at power 8: boundary and position belong to them
			expect(routeOf({ branch = "gatecraft", property = "boundary", verb = "amplify", form = "ritual", power = 8 })).toBe("space_gate")
			expect(S.byTier(S.hideaway.seconds, S.hideaway.fromTier) >= 20).toBe(true)
			expect(S.worldgate.seconds >= 3600).toBe(true)
			-- The hideaway rooms sit clear of the Rift pocket and of the island
			expect(S.hideaway.origin.X > 4096 or S.hideaway.origin.Z > 4096).toBe(true)
		end)

		it("every power has a resolver, a Composer line, its statuses and a flag", function()
			for _, route in EffectLibrary.routes do
				if route.effect == "SpacePower" then
					expect(Server.Magic.Cast.Effects:FindFirstChild("SpacePower") ~= nil).toBe(true)
					expect((RouteSummaries.routes :: any)[route.id] ~= nil).toBe(true)
				end
			end
			expect(StatusInfo.space_sealed ~= nil and StatusInfo.space_sealed.harmful).toBe(true)
			expect(StatusInfo.space_stride ~= nil and not StatusInfo.space_stride.harmful).toBe(true)
			expect((Flags :: any).space_powers_enabled ~= nil).toBe(true)
		end)

		it("tier curves grow and stop at their caps; player seals stay short", function()
			for _, curve in { S.gate.seconds, S.seal.seconds, S.stride.seconds, S.stride.walk, S.cut.length } :: { S.Curve } do
				expect(S.byTier(curve, 0)).toBe(curve.base)
				expect(S.byTier(curve, 8) >= S.byTier(curve, 0)).toBe(true)
				expect(S.byTier(curve, 50)).toBe(curve.max)
			end
			expect(S.seal.pvpSeconds <= S.byTier(S.seal.seconds, 0)).toBe(true)
			expect(S.gate.exitOffset > S.gate.radius).toBe(true) -- you come out clear of the far ring
			-- Long gates: none early, growing, and the whole island (4,096 studs) from Grandmaster.
			expect(S.waypointReach(0)).toBe(0)
			expect(S.waypointReach(5) > S.waypointReach(4)).toBe(true)
			expect(S.waypointReach(6) >= 4096 * 1.5).toBe(true)
			expect(S.waypointReach(99)).toBe(S.waypointReach(8))
		end)
	end)
end
