--!strict
--[[
	Cantrips.spec: the awakening's innate spells (Shared/Magic/Cantrips, Services/CantripService).
	For EVERY domain a fresh Sensing caster gets a Strike that is valid and actually damages, a
	utility spell, and the thrown Strike (a projectile that damages); the utility is seeded.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Registry = require(ReplicatedStorage.Shared.Magic.Registry)
local MagicCore = require(ReplicatedStorage.Shared.Magic.MagicCore)
local Cantrips = require(ReplicatedStorage.Shared.Magic.Cantrips)
local CastService = require(ServerScriptService.Server.Services.CastService)

local DAMAGING: { [string]: boolean } = {
	strike = true, harm = true, thermal = true, ignite = true, afflict = true, siphon = true,
}

local function sensingCaster(domainId: string): any
	local sensing = Registry.masteryTiers.tiers[2].minMastery
	return {
		id = "spec_cantrip_" .. domainId,
		affinities = { [domainId] = 0.5 },
		awakened = { [domainId] = true },
		mastery = { [domainId] = sensing },
		unlocked = { [domainId] = true },
	}
end

return function(t: any)
	t.describe("Cantrips", function()
		t.it("gives every domain a damaging Strike and a utility at Sensing", function()
			for _, domainId in Registry.domainIds do
				local caster = sensingCaster(domainId)
				local spells = Cantrips.forDomain(domainId, caster, Random.new(7))
				local strike, utility = nil, nil
				for _, spell in spells do
					if spell.kind == "strike" then
						strike = spell
					elseif spell.kind == "utility" then
						utility = spell
					end
				end
				if not strike then
					error(domainId .. ": no castable Strike at Sensing")
				end
				if not utility then
					error(domainId .. ": no utility spell at Sensing")
				end
				local ok, errors, normalized = MagicCore.validateRecipe(strike.recipe, caster)
				if not ok or not normalized then
					error(domainId .. ": strike invalid (" .. (errors[1] and errors[1].code or "?") .. ")")
				end
				local route = CastService.routeFor(normalized).id
				if not DAMAGING[route] then
					error(domainId .. ": strike routes to " .. route .. ", which doesn't damage")
				end
				t.expect(strike.name ~= "").toBe(true)
				t.expect(utility.name ~= "").toBe(true)
				t.expect((MagicCore.validateRecipe(utility.recipe, caster))).toBe(true)
			end
		end)

		t.it("gives every domain a damaging projectile at Sensing, after strike and utility", function()
			for _, domainId in Registry.domainIds do
				local caster = sensingCaster(domainId)
				local spells = Cantrips.forDomain(domainId, caster, Random.new(7))
				local bolt = spells[#spells]
				if not bolt or bolt.kind ~= "bolt" then
					error(domainId .. ": no thrown Strike at Sensing (or not last)")
				end
				t.expect(#spells).toBe(3)
				t.expect(bolt.recipe.form).toBe("projectile")
				t.expect(bolt.name).toBe(Registry.strikes[domainId].rangedName)
				local ok, errors, normalized = MagicCore.validateRecipe(bolt.recipe, caster)
				if not ok or not normalized then
					error(domainId .. ": bolt invalid (" .. (errors[1] and errors[1].code or "?") .. ")")
				end
				local route = CastService.routeFor(normalized).id
				if not DAMAGING[route] then
					error(domainId .. ": bolt routes to " .. route .. ", which doesn't damage")
				end
			end
		end)

		t.it("picks the same utility for the same seed", function()
			for _, domainId in Registry.domainIds do
				local caster = sensingCaster(domainId)
				local a = Cantrips.forDomain(domainId, caster, Random.new(1234))
				local b = Cantrips.forDomain(domainId, caster, Random.new(1234))
				t.expect(#a).toBe(#b)
				for i = 1, #a do
					-- recipeKey needs a normalized recipe (version, cost profile); these are raw.
					local _, _, na = MagicCore.validateRecipe(a[i].recipe, caster)
					local _, _, nb = MagicCore.validateRecipe(b[i].recipe, caster)
					t.expect(MagicCore.recipeKey(na :: any)).toBe(MagicCore.recipeKey(nb :: any))
				end
			end
		end)

		t.it("names the Strike after the domain's strike", function()
			local _, name = Cantrips.strike("energy")
			t.expect(name).toBe(Registry.strikes.energy.name)
			t.expect((Cantrips.strike("not_a_domain"))).toBe(nil)
		end)
	end)
end
