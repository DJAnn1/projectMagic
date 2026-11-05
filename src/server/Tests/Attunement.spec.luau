--!strict
-- Unit specs for equip-mode attunement's pure parts: the stance walk multiplier
-- (StatusEffects.setWalkMultiplier), the castMode setting and the attune remote's shape.
-- docs/Casting.md §6.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local T = require(Server.Magic.Data.CastTuning)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local UISettings = require(ReplicatedStorage.Shared.UI.Settings)
local Remotes = require(ReplicatedStorage.Shared.Net.Remotes)
local ActionRules = require(ReplicatedStorage.Shared.Magic.ActionRules)

-- A detached humanoid (never in workspace) with the default walk speed.
local function body(): Humanoid
	local model = Instance.new("Model")
	local humanoid = Instance.new("Humanoid")
	humanoid.WalkSpeed = 16
	humanoid.Parent = model
	return humanoid
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Attunement stance", function()
		it("slows walking while attuned and restores it exactly", function()
			local humanoid = body()
			StatusEffects.setWalkMultiplier(humanoid, "attuned", T.attunedWalkMult)
			expect(humanoid.WalkSpeed).toBeNear(16 * T.attunedWalkMult, 1e-4)
			StatusEffects.setWalkMultiplier(humanoid, "attuned", nil)
			expect(humanoid.WalkSpeed).toBeNear(16, 1e-4)
			expect(humanoid:GetAttribute("MagicBaseWalk")).toBe(nil)
		end)
		it("stacks with a status and survives the status ending", function()
			local humanoid = body()
			StatusEffects.setWalkMultiplier(humanoid, "attuned", 0.5)
			StatusEffects.apply(humanoid, "slow", { duration = 30 })
			expect(humanoid.WalkSpeed < 16 * 0.5).toBe(true)
			StatusEffects.remove(humanoid, "slow")
			expect(humanoid.WalkSpeed).toBeNear(8, 1e-4)
			StatusEffects.setWalkMultiplier(humanoid, "attuned", nil)
			expect(humanoid.WalkSpeed).toBeNear(16, 1e-4)
		end)
		it("offers Equip and Quick, defaulting to Equip", function()
			local def = UISettings.castMode
			expect(def ~= nil).toBe(true)
			expect(def.default).toBe("equip")
			expect(table.find(def.options, "quick") ~= nil).toBe(true)
		end)
		it("declares the attune remote as a client function", function()
			local def = Remotes.AttuneSpell
			expect(def.kind).toBe("Function")
			expect(def.from).toBe("Client")
		end)
		it("lets a body equip only when it's free", function()
			expect(ActionRules.allows("idle", "equip")).toBe(true)
			expect(ActionRules.allows("holding", "equip")).toBe(true)
			expect(ActionRules.allows("casting", "equip")).toBe(false)
			expect(ActionRules.allows("staggered", "equip")).toBe(false)
		end)
	end)
end
