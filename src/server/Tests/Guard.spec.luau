--!strict
-- Unit specs for guards: the shared rules (Shared/Magic/GuardRules) and the server's blocks and
-- parries (Cast/Guard), on detached bodies. docs/Combat.md §12.

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local GuardRules = require(ReplicatedStorage.Shared.Magic.GuardRules)
local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local Guard = require(ServerScriptService.Server.Magic.Cast.Guard)
local ActionState = require(ServerScriptService.Server.Magic.Cast.ActionState)

local T = GuardRules.tuning

-- A body facing -Z at the origin, outside workspace (parented so ActionState keeps it).
local function body(): (Model, Humanoid)
	local holder = Instance.new("Folder")
	local model = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.CFrame = CFrame.new(0, 3, 0)
	root.Parent = model
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = holder
	return model, humanoid
end

local FRONT = Vector3.new(0, 3, -12)
local BEHIND = Vector3.new(0, 3, 12)

local function propertyIn(category: string): string?
	for id, def in Registry.properties do
		if (def :: any).category == category then
			return id
		end
	end
	return nil
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Guard rules", function()
		it("lets Mental and Temporal magic through, and halves for Piercing", function()
			expect(GuardRules.kindOf(propertyIn("Mental"), false)).toBe("unblockable")
			expect(GuardRules.kindOf(propertyIn("Temporal"), true)).toBe("unblockable")
			expect(GuardRules.kindOf(propertyIn("Thermal"), true)).toBe("pierces")
			expect(GuardRules.kindOf(propertyIn("Thermal"), false)).toBe("blockable")
			expect(GuardRules.reduction("pierces")).toBeNear(T.blockReduction * T.pierceMult, 1e-6)
			expect(GuardRules.reduction("unblockable")).toBe(0)
		end)
		it("covers the front arc only", function()
			local look = Vector3.new(0, 0, -1)
			expect(GuardRules.covers(look, Vector3.zero, Vector3.new(0, 0, -10))).toBe(true)
			expect(GuardRules.covers(look, Vector3.zero, Vector3.new(0, 0, 10))).toBe(false)
			expect(GuardRules.covers(look, Vector3.zero, Vector3.new(10, 0, -1))).toBe(false)
		end)
		it("labels every kind with a glyph and words", function()
			for _, kind in { "blockable", "pierces", "unblockable" } :: { GuardRules.Kind } do
				expect(#GuardRules.label(kind) > 3).toBe(true)
			end
		end)
	end)

	describe("Guard (server)", function()
		it("parries the first frontal hit of a fresh raise", function()
			local model, humanoid = body()
			expect((Guard.raise(model, "earth"))).toBe(true)
			local left, outcome = Guard.mitigate(humanoid, 40, { from = FRONT, property = propertyIn("Thermal") })
			expect(outcome).toBe("parry")
			expect(left).toBe(0)
			expect(model:GetAttribute("ParriedAt") ~= nil).toBe(true)
		end)
		it("blocks (no parry) after a quick re-raise, and drains the meter", function()
			local model, humanoid = body()
			Guard.raise(model, "earth")
			Guard.lower(model)
			Guard.raise(model, "earth") -- inside parryCooldown: no fresh window
			local left, outcome = Guard.mitigate(humanoid, 40, { from = FRONT, property = propertyIn("Thermal") })
			expect(outcome).toBe("block")
			expect(left).toBeNear(40 * (1 - T.blockReduction), 1e-6)
			expect(Guard.meter(model) < 1).toBe(true)
		end)
		it("doesn't stop hits from behind, unblockable magic, or damage over time", function()
			local model, humanoid = body()
			Guard.raise(model, "earth")
			Guard.lower(model)
			Guard.raise(model, "earth")
			expect((Guard.mitigate(humanoid, 40, { from = BEHIND }))).toBe(40)
			expect((Guard.mitigate(humanoid, 40, { from = FRONT, property = propertyIn("Mental") }))).toBe(40)
			expect((Guard.mitigate(humanoid, 40, { from = FRONT, dot = true }))).toBe(40)
			expect((Guard.mitigate(humanoid, 40, nil))).toBe(40)
		end)
		it("breaks into a stagger when the meter runs out", function()
			local model, humanoid = body()
			Guard.raise(model, "earth")
			Guard.lower(model)
			Guard.raise(model, "earth")
			Guard.mitigate(humanoid, humanoid.MaxHealth * 10, { from = FRONT })
			expect(Guard.isGuarding(model)).toBe(false)
			expect(ActionState.get(model)).toBe("staggered")
			expect((Guard.raise(model, "earth"))).toBe(false) -- broken: locked out for a while
		end)
		it("is not guarding once something else takes over the body", function()
			local model = body()
			Guard.raise(model, "water")
			ActionState.set(model, "staggered", { force = true, duration = 1 })
			expect(Guard.isGuarding(model)).toBe(false)
			expect(model:GetAttribute("Guarding")).toBe(nil)
		end)
	end)
end
