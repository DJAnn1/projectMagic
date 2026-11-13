--!strict
--[[
	PropertyBehaviours.spec: no harmful spell is plain damage any more (docs/SpellOverhaul.md §2A,
	stage 1). What matters most: every harmful property either has a behaviour or a route of its
	own; every behaviour names real statuses with display entries and keeps its extra damage in
	budget; the variants pick right; chills really build into a freeze; a hit that dealt nothing
	adds nothing; and the full grammar has no recipe left that is only damage.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local Behaviours = require(Shared.Magic.Data.PropertyBehaviours)
local StatusInfo = require(Shared.Magic.Data.StatusInfo)
local SpellAudit = require(Shared.Magic.SpellAudit)
local SpellOutcome = require(Shared.Magic.SpellOutcome)
local Cast = ServerScriptService.Server.Magic.Cast
local PropertyBehaviour = require(Cast.PropertyBehaviour)
local StatusEffects = require(Cast.StatusEffects)

-- Harmful properties that have routes of their own (they never reach plain damage).
local OWN_ROUTES = { seismicity = true, magnetism = true, decay = true, toxin = true, malediction = true, substance = true, identity = true }
local KINDS = { status = true, stack = true, knockback = true, echo = true, drain = true, spread = true, grow = true }

local function dummy(): (Model, Humanoid, BasePart)
	local model = Instance.new("Model")
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Anchored = true
	root.Position = Vector3.new(0, -400, 0)
	root.Parent = model
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = workspace
	return model, humanoid, root
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Property behaviours data", function()
		it("every harmful property has a behaviour or a route of its own", function()
			for id, property in Registry.properties do
				if property.harmful then
					expect(Behaviours[id] ~= nil or OWN_ROUTES[id] == true).toBe(true)
				end
			end
		end)

		it("every behaviour is well formed: real statuses, known kinds, variants, words, budget", function()
			for _, behaviour in Behaviours do
				expect(#behaviour.summary > 20).toBe(true)
				expect(#behaviour.effects >= 1).toBe(true)
				for _, effect in behaviour.effects do
					expect(KINDS[effect.kind] == true).toBe(true)
					for _, statusId in { effect.id, effect.at and effect.at.id } :: { any } do
						if statusId then
							expect(StatusEffects.defs[statusId] ~= nil and StatusInfo[statusId] ~= nil).toBe(true)
						end
					end
					expect((effect.dotShare or 0) <= 0.45 and (effect.share or 0) <= 0.6).toBe(true)
				end
				for _, variant in (behaviour.byVerb or {}) :: { [string]: string } do
					expect(Behaviours[variant] ~= nil).toBe(true)
				end
			end
		end)

		it("variants and the Composer's words follow the behaviour", function()
			expect(PropertyBehaviour.idFor({ property = "phase", verb = "amplify" })).toBe("heat")
			expect(PropertyBehaviour.idFor({ property = "phase", verb = "reduce" })).toBe("phase")
			expect(PropertyBehaviour.idFor({ property = "sound", verb = "generate" })).toBe("sound")
			expect(PropertyBehaviour.idFor({ property = "warding", verb = "generate" })).toBe(nil)
			local outcome = SpellOutcome.of({ branch = "energy", property = "radiation", verb = "generate", form = "projectile", power = 3 })
			expect(outcome.route).toBe("harm")
			expect(string.find(outcome.text, Behaviours.radiation.summary, 1, true) ~= nil).toBe(true)
		end)
	end)

	describe("Property behaviours in play", function()
		it("three chills freeze; a hit that dealt nothing adds nothing", function()
			local model, humanoid, root = dummy()
			local ctx: any = {
				power = 5, rng = Random.new(1), origin = Vector3.new(0, -400, 10), root = root, character = model,
				player = nil, stats = { recipe = { property = "temperature", verb = "reduce" } }, services = {},
			}
			local hit: any = { model = model, humanoid = humanoid, root = root, distance = 0 }
			PropertyBehaviour.apply(ctx, hit, 0, nil, "cold")
			expect(StatusEffects.has(humanoid, "chilled")).toBe(false)
			PropertyBehaviour.apply(ctx, hit, 5, nil, "cold")
			PropertyBehaviour.apply(ctx, hit, 5, nil, "cold")
			expect(StatusEffects.has(humanoid, "chilled")).toBe(true)
			expect(StatusEffects.has(humanoid, "frozen")).toBe(false)
			PropertyBehaviour.apply(ctx, hit, 5, nil, "cold")
			expect(StatusEffects.has(humanoid, "frozen")).toBe(true)
			expect(StatusEffects.has(humanoid, "chilled")).toBe(false)
			model:Destroy()
		end)

		it("the whole grammar has no recipe left that is only damage", function()
			local report = SpellAudit.run({ power = 5 })
			for propertyId, n in report.harmByProperty do
				if n > 0 then
					expect(Behaviours[propertyId] ~= nil).toBe(true)
				end
			end
		end)
	end)
end
