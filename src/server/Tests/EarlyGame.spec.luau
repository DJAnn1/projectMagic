--!strict
-- Unit specs for the early-game guarantees (docs/Combat.md §14, docs/Prompts-EarlyGame.md):
-- every domain can attack from its root branch at Sensing, with touch and at range, and the
-- strike route never steals a spell that already had a job.

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Server = ServerScriptService.Server
local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local MagicCore = require(ReplicatedStorage.Shared.Magic.MagicCore)
local Strike = require(ReplicatedStorage.Shared.Magic.Strike)
local StatusInfo = require(ReplicatedStorage.Shared.Magic.Data.StatusInfo)
local CastService = require(Server.Services.CastService)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)

-- Routes that injure a character (their resolvers call DamageModel.hit).
local DAMAGING: { [string]: boolean } = {
	strike = true, harm = true, thermal = true, ignite = true, afflict = true, siphon = true,
}

-- A fresh caster with only the domain's root branch, at the given mastery.
local function casterAt(domainId: string, mastery: number): any
	return {
		id = "spec_early_" .. domainId,
		affinities = { [domainId] = 0.5 },
		awakened = { [domainId] = true },
		mastery = { [domainId] = mastery },
		unlocked = { [domainId] = true },
	}
end

local function strikeRecipe(domainId: string, form: string): any
	local def = Registry.strikes[domainId]
	return { branch = domainId, property = def.property, verb = def.verbs[1], form = form, power = 1 }
end

-- Validates against the caster and routes; errors with the reason so the failure names the domain.
local function routeAs(domainId: string, recipe: any, caster: any): string
	local ok, errors, normalized = MagicCore.validateRecipe(recipe, caster)
	if not ok or not normalized then
		error(domainId .. ": " .. MagicCore.describe(recipe) .. " is invalid (" .. (errors[1] and errors[1].code or "?") .. ")", 2)
	end
	return CastService.routeFor(normalized).id
end

local function route(recipe: any): string
	local _, errors, normalized = MagicCore.validateRecipe(recipe)
	if not normalized then
		error("recipe is invalid: " .. MagicCore.describe(recipe) .. " (" .. (errors[1] and errors[1].code or "?") .. ")", 2)
	end
	return CastService.routeFor(normalized).id
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Domain strikes", function()
		it("gives every domain a strike on a root-branch property", function()
			for _, domainId in Registry.domainIds do
				local def = Registry.strikes[domainId]
				expect(def ~= nil).toBe(true)
				if def then
					expect(Registry.branches[domainId].propertySet[def.property] == true).toBe(true)
				end
			end
		end)

		it("lets a Sensing caster attack with touch from the root branch, in every domain", function()
			local sensing = Registry.masteryTiers.tiers[2].minMastery
			for _, domainId in Registry.domainIds do
				local def = Registry.strikes[domainId]
				local id = routeAs(domainId, strikeRecipe(domainId, "touch"), casterAt(domainId, sensing))
				expect(DAMAGING[id] == true).toBe(true)
				expect(id).toBe(def.native or "strike")
			end
		end)

		it("lets a Sensing caster attack at range from the root branch, in every domain", function()
			local sensing = Registry.masteryTiers.tiers[2].minMastery
			for _, domainId in Registry.domainIds do
				local def = Registry.strikes[domainId]
				local id = routeAs(domainId, strikeRecipe(domainId, "projectile"), casterAt(domainId, sensing))
				expect(DAMAGING[id] == true).toBe(true)
				expect(id).toBe(def.native or "strike")
			end
		end)

		it("marks every strike as harmful (safe zones, crimes, witnesses)", function()
			for _, domainId in Registry.domainIds do
				local stats = MagicCore.computeStats(strikeRecipe(domainId, "touch"), casterAt(domainId, 10))
				expect(stats ~= nil and stats.harmful == true).toBe(true)
			end
		end)

		it("keeps damage parity: share + rider DoT between 0.8 and 1.0 of a plain hit", function()
			for _, def in Registry.strikes do
				if not def.native then
					local total = (def.share or 0) + (if def.rider then def.rider.dotShare or 0 else 0)
					expect(total >= 0.8 and total <= 1.0).toBe(true)
				end
			end
		end)

		it("only names rider statuses that exist on the server and in the HUD", function()
			for _, def in Registry.strikes do
				local status = def.rider and def.rider.status
				if status then
					expect(StatusEffects.defs[status] ~= nil).toBe(true)
					expect(StatusInfo[status] ~= nil).toBe(true)
				end
			end
		end)

		it("never steals a spell that already had a job", function()
			-- Candle (thermal), healing touch, a bloom of growth, fortune on allies, raised stone,
			-- dispel, blink, a tempo haste: all unchanged.
			expect(route({ branch = "energy", property = "temperature", verb = "generate", form = "touch", power = 1 })).toBe("thermal")
			expect(route({ branch = "restoration", property = "vitality", verb = "amplify", form = "touch", power = 3 })).toBe("restore")
			expect(route({ branch = "life", property = "growth", verb = "generate", form = "aura", power = 1 })).toBe("restore")
			expect(route({ branch = "fortune", property = "probability", verb = "amplify", form = "aura", power = 4 })).toBe("fortune")
			expect(route({ branch = "reality", property = "probability", verb = "generate", form = "aura", power = 1 })).toBe("fortune")
			expect(route({ branch = "geomancy", property = "contour", verb = "generate", form = "wall", power = 4 })).toBe("stoneshape")
			expect(route({ branch = "earth", property = "hardness", verb = "generate", form = "burst", power = 2 })).toBe("stoneshape")
			expect(route({ branch = "negation", property = "aether", verb = "reduce", form = "burst", power = 4 })).toBe("dispel")
			expect(route({ branch = "hastening", property = "tempo", verb = "amplify", form = "touch", power = 4 })).toBe("tempo")
			expect(route({ branch = "mind", property = "perception", verb = "sense", form = "aura", power = 1 })).toBe("sense")
		end)

		it("matches strikes through hybrid branches' domains too", function()
			for _, branchId in Registry.branchIds do
				local branch = Registry.branches[branchId]
				if #branch.domains > 1 then
					for _, d in branch.domains do
						local def = Registry.strikes[d]
						if branch.propertySet[def.property] then
							local domainId = Strike.find({ branch = branchId, property = def.property, verb = def.verbs[1], form = "touch" })
							expect(domainId ~= nil).toBe(true)
						end
					end
				end
			end
		end)
	end)

	describe("Strike riders", function()
		it("Unmake strips the longest blessing and leaves curses alone", function()
			local humanoid = Instance.new("Humanoid")
			StatusEffects.apply(humanoid, "ward", { duration = 20, magnitude = 10 })
			StatusEffects.apply(humanoid, "haste", { duration = 5 })
			StatusEffects.apply(humanoid, "slow", { duration = 20 })
			expect(StatusEffects.stripBeneficial(humanoid, 1)).toBe(1)
			expect(StatusEffects.has(humanoid, "ward")).toBe(false)
			expect(StatusEffects.has(humanoid, "haste")).toBe(true)
			expect(StatusEffects.has(humanoid, "slow")).toBe(true)
			StatusEffects.dispel(humanoid)
			humanoid:Destroy()
		end)

		it("Jinxed raises the crit chance against its target", function()
			local humanoid = Instance.new("Humanoid")
			expect(StatusEffects.critTakenBonus(humanoid)).toBe(0)
			StatusEffects.apply(humanoid, "jinxed", { duration = 4 })
			expect(StatusEffects.critTakenBonus(humanoid) > 0).toBe(true)
			StatusEffects.dispel(humanoid)
			humanoid:Destroy()
		end)
	end)
end
