--!strict
--[[
	PropertyLooks.spec: every property looks like itself (docs/SpellOverhaul.md §2C, stage 2). What
	matters: every property with a behaviour has a look; looks only name texture roles, flourishes,
	lingering effects, marks and beam styles the client knows; every status a behaviour applies shows
	on the body (knockdown and slow show already, by falling and walking slowly); and the
	StatusEffects tag the client watches is the one it names.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Behaviours = require(Shared.Magic.Data.PropertyBehaviours)
local PropertyLooks = require(Shared.Magic.Data.PropertyLooks)
local StatusLooks = require(Shared.Magic.Data.StatusLooks)
local StatusInfo = require(Shared.Magic.Data.StatusInfo)
local StatusEffects = require(ServerScriptService.Server.Magic.Cast.StatusEffects)

local SHOWN_OTHERWISE = { knockdown = true, slow = true }

local function set(list: { string }): { [string]: boolean }
	local out = {}
	for _, v in list do
		out[v] = true
	end
	return out
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect
	local roles = set(PropertyLooks.roles)

	describe("Property looks", function()
		it("every property with a behaviour has a look of its own", function()
			for id in Behaviours do
				expect(PropertyLooks.looks[id] ~= nil).toBe(true)
			end
		end)

		it("looks only name things the client draws", function()
			local flourishes, lingers, marks, beams = set(PropertyLooks.flourishes), set(PropertyLooks.lingers), set(PropertyLooks.marks), set(PropertyLooks.beams)
			for _, look in PropertyLooks.looks do
				for _, part in { look.body, look.sparks } :: { any } do
					if part and part.texture then
						expect(roles[part.texture] == true).toBe(true)
					end
				end
				for _, kind in (look.flourish or {}) :: { string } do
					expect(flourishes[kind] == true).toBe(true)
				end
				if look.linger then
					expect(lingers[look.linger.kind] == true).toBe(true)
					expect(look.linger.seconds > 0 and look.linger.seconds <= 6).toBe(true)
				end
				if typeof(look.mark) == "string" then
					expect(marks[look.mark] == true).toBe(true)
				end
				if look.beam then
					expect(beams[look.beam] == true).toBe(true)
				end
				if look.tint then
					expect(look.tint.share > 0 and look.tint.share <= 0.6).toBe(true)
				end
			end
		end)

		it("lightning stays lightning, and sound ripples", function()
			expect(PropertyLooks.looks.charge.beam).toBe("lightning")
			expect(PropertyLooks.looks.sound.beam).toBe("ripple")
			expect(PropertyLooks.looks.cold.mark).toBe("frost")
		end)
	end)

	describe("Status looks on bodies", function()
		it("every status a behaviour applies shows on the body", function()
			for _, behaviour in Behaviours do
				for _, effect in behaviour.effects do
					for _, id in { effect.id, effect.at and effect.at.id } :: { any } do
						if id and not SHOWN_OTHERWISE[id] then
							expect(StatusLooks.looks[id] ~= nil).toBe(true)
						end
					end
				end
			end
		end)

		it("status looks are real statuses, on real parts, with known textures", function()
			local parts = set(StatusLooks.parts)
			for id, look in StatusLooks.looks do
				expect(StatusInfo[id] ~= nil and StatusEffects.defs[id] ~= nil).toBe(true)
				expect(look.emit ~= nil or look.shell ~= nil).toBe(true)
				for _, spec in (look.emit or {}) :: { any } do
					expect(parts[spec.at] == true).toBe(true)
					expect(roles[spec.texture] == true).toBe(true)
					expect(spec.rate > 0 and spec.rate <= 30).toBe(true)
				end
			end
			expect(StatusLooks.looks.frozen.shell ~= nil).toBe(true)
		end)

		it("a status tags the body while it lasts, and the tag goes with the last status", function()
			local CollectionService = game:GetService("CollectionService")
			expect(StatusEffects.TAG).toBe("MagicStatused")
			local model = Instance.new("Model")
			local humanoid = Instance.new("Humanoid")
			humanoid.Parent = model
			model.Parent = workspace
			StatusEffects.apply(humanoid, "chilled", { duration = 5 })
			StatusEffects.apply(humanoid, "burning", { duration = 5 })
			expect(CollectionService:HasTag(humanoid, StatusEffects.TAG)).toBe(true)
			StatusEffects.remove(humanoid, "chilled")
			expect(CollectionService:HasTag(humanoid, StatusEffects.TAG)).toBe(true)
			StatusEffects.remove(humanoid, "burning")
			expect(CollectionService:HasTag(humanoid, StatusEffects.TAG)).toBe(false)
			model:Destroy()
		end)
	end)
end
