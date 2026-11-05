--!strict
--[[
	Cantrips: the spells your awakening gives you (docs/EarlyGamePlan.md, plan item 1). Pure and
	shared: Services/CantripService grants them, the Composer's Guided "First spark" uses strike().

	For each awakened domain, three spells at the Sensing tier (in this order, so a new player's
	first domain fills hotbar slots 1-3):
		strike   the domain's Strike (Data/Strikes: Scorch, Stone Shot...): generate <property> as
		         touch, power 1. Every domain can attack with it from its root branch at Sensing
		         (Tests/EarlyGame.spec guarantees it).
		utility  a Sensing technique of that domain if it has one (Glow Mote, Pebble Nudge, Dew
		         Sense), otherwise "Sense <property>" on a seeded property of the root branch, as an
		         aura (or touch). Named after the technique or the property.
		bolt     the same Strike thrown: form projectile, power 1, named by the strike's
		         `rangedName` (Ember Dart, Pebble Sling...). Ranged magic from minute one
		         (docs/EarlyGamePlan.md item 3); power 1 keeps it weak.
	Seeded per player and domain (Seed.random(worldSeed, "player:<id>", "cantrip:<domain>")), so
	two Fire players don't always get the same utility.
]]

local Registry = require(script.Parent.Registry)
local MagicCore = require(script.Parent.MagicCore)

export type Spell = { kind: string, name: string, recipe: { [string]: any } }

local Cantrips = {}

-- The domain's Strike as a Sensing spell: touch, power 1.
function Cantrips.strike(domainId: string): ({ [string]: any }?, string?)
	local def = Registry.strikes[domainId]
	if not def then
		return nil, nil
	end
	return { branch = domainId, property = def.property, verb = def.verbs[1], form = "touch", power = 1, modifiers = {} }, def.name
end

-- The domain's Strike thrown: projectile, power 1.
function Cantrips.bolt(domainId: string): ({ [string]: any }?, string?)
	local def = Registry.strikes[domainId]
	if not def then
		return nil, nil
	end
	return { branch = domainId, property = def.property, verb = def.verbs[1], form = "projectile", power = 1, modifiers = {} }, def.rangedName
end

local function valid(recipe: { [string]: any }, caster: any): boolean
	local ok = MagicCore.validateRecipe(recipe, caster)
	return ok == true
end

-- A utility spell for the domain: a Sensing technique, else Sense <property>.
function Cantrips.utility(domainId: string, caster: any, rng: Random): ({ [string]: any }?, string?)
	-- A named technique of this domain the caster can already cast.
	local ids: { string } = {}
	for id, technique in Registry.techniques do
		if technique.domain == domainId then
			table.insert(ids, id)
		end
	end
	table.sort(ids)
	for _, id in ids do
		local technique = Registry.techniques[id]
		if valid(technique.recipe, caster) then
			return table.clone(technique.recipe), technique.name
		end
	end
	-- Otherwise: sense a property of the root branch, picked by the seed.
	local root = Registry.branches[domainId]
	if not root then
		return nil, nil
	end
	local properties = table.clone(root.ownProperties)
	table.sort(properties)
	for i = #properties, 2, -1 do -- seeded shuffle
		local j = rng:NextInteger(1, i)
		properties[i], properties[j] = properties[j], properties[i]
	end
	for _, property in properties do
		for _, form in { "aura", "touch" } do
			local recipe = { branch = domainId, property = property, verb = "sense", form = form, power = 1, modifiers = {} }
			if valid(recipe, caster) then
				local def = Registry.properties[property]
				return recipe, "Sense " .. (if def then def.name else property)
			end
		end
	end
	return nil, nil
end

-- All cantrips for a domain (only the ones the caster can actually cast).
function Cantrips.forDomain(domainId: string, caster: any, rng: Random): { Spell }
	local out: { Spell } = {}
	local strike, strikeName = Cantrips.strike(domainId)
	if strike and strikeName and valid(strike, caster) then
		table.insert(out, { kind = "strike", name = strikeName, recipe = strike })
	end
	local utility, utilityName = Cantrips.utility(domainId, caster, rng)
	if utility and utilityName then
		table.insert(out, { kind = "utility", name = utilityName, recipe = utility })
	end
	local bolt, boltName = Cantrips.bolt(domainId)
	if bolt and boltName and valid(bolt, caster) then
		table.insert(out, { kind = "bolt", name = boltName, recipe = bolt })
	end
	return out
end

return Cantrips
