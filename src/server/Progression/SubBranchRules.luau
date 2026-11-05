--!strict
--[[
	SubBranchRules: data-driven conditions for unlocking a branch.

	Every non-root branch needs a mix of four things:
		parentTier   mastery tier in the parent branch
		affinity     innate affinity for the branch's line (InnateProfile.branchAffinity)
		lore         a knowledge item: found via NPCs, books or discovery (progression.lore)
		catalyst     sometimes: exposure to something in the world. Ids are prefixed by where they're recorded:
		             "exposure:<id>" (records.catalysts), "insight:<id>" (records.insights),
		             "awakening:<eventId>" (the innate profile's awakenings)

	Defaults depend on the branch's depth; `overrides` replace any part per branch.
	Hybrids additionally need their two prerequisite branches (from Branches data).
	Mythic sub-branches need "fragment:" lore instead of primers and treatises.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Magic = ReplicatedStorage.Shared.Magic
local Types = require(Magic.Types)
local Registry = require(Magic.Registry)
local MagicCore = require(Magic.MagicCore)
local InnateProfile = require(ServerScriptService.Server.Magic.InnateProfile)

export type Condition = {
	parentTier: number?,
	affinity: number?,
	lore: { anyOf: { string }?, allOf: { string }? }?,
	catalyst: { anyOf: { string }?, allOf: { string }? }?,
}

export type Check = {
	kind: string, -- "parent" | "prerequisite" | "affinity" | "lore" | "catalyst" | "domain"
	met: boolean,
	text: string,
}

local SubBranchRules = {}

-- Defaults by branch depth (tier). Lore ids are generated from the branch id.
local DEFAULTS: { [number]: Condition } = {
	[1] = { parentTier = 2, affinity = 0.1 },
	[2] = { parentTier = 3, affinity = 0.2, lore = { anyOf = { "primer:%s" } } },
	[3] = { parentTier = 4, affinity = 0.3, lore = { anyOf = { "treatise:%s" } } },
	[4] = { parentTier = 5, affinity = 0.35, lore = { anyOf = { "treatise:%s" } } },
}
local HYBRID_DEFAULT: Condition = { affinity = 0.2, lore = { anyOf = { "codex:%s" } } }

-- Showcase overrides. Fields given here replace the defaults for that branch.
SubBranchRules.overrides = {
	metallurgy = {
		parentTier = 3, -- Adept Geomancy
		affinity = 0.25,
		lore = { anyOf = { "primer:metallurgy", "tome:iron_and_flame", "mentor:metallurgy" } },
		catalyst = { allOf = { "exposure:ore", "exposure:heat" } }, -- handle raw ore near real heat
	},
	crystallurgy = {
		catalyst = { anyOf = { "exposure:geode", "insight:earth:singing_caverns" } },
	},
	cataclysm = {
		catalyst = { allOf = { "insight:earth:fault_zone" } },
	},
	conflagration = {
		catalyst = { anyOf = { "exposure:wildfire", "insight:energy:volcanic_vent" } },
	},
	tsunamancy = {
		catalyst = { allOf = { "insight:water:ocean_trench" } },
	},
	stormcalling = {
		catalyst = { anyOf = { "awakening:lightningStrike", "insight:air:storm_eye" } },
	},
	necromancy = {
		catalyst = { allOf = { "exposure:grave" } },
	},
} :: { [string]: Condition }

local function fill(list: { string }, branchId: string): { string }
	local out = {}
	for _, id in list do
		table.insert(out, (string.gsub(id, "%%s", branchId)))
	end
	return out
end

-- The effective condition for a branch (defaults merged with overrides).
function SubBranchRules.conditionFor(branchId: string): Condition
	local branch = Registry.branches[branchId]
	local base: Condition
	if branch.isHybrid and not branch.parent then
		base = HYBRID_DEFAULT
	else
		base = DEFAULTS[math.clamp(branch.tier, 1, 4)]
	end
	local override = SubBranchRules.overrides[branchId] or {}
	local mythic = Registry.domains[branch.domains[1]].rarity == "Mythic"

	local lore = override.lore or base.lore
	if lore and not override.lore then
		lore = {
			anyOf = lore.anyOf and fill(lore.anyOf, branchId),
			allOf = lore.allOf and fill(lore.allOf, branchId),
		}
		if mythic then
			lore = { anyOf = { "fragment:" .. branchId } }
		end
	end
	return {
		parentTier = override.parentTier or base.parentTier,
		affinity = override.affinity or base.affinity,
		lore = lore,
		catalyst = override.catalyst or base.catalyst,
	}
end

local function hasCatalyst(progression: any, innate: Types.InnateProfile, id: string): boolean
	local prefix, rest = string.match(id, "^(%a+):(.+)$")
	if prefix == "exposure" then
		return progression.records.catalysts[rest] ~= nil
	elseif prefix == "insight" then
		return progression.records.insights[rest] ~= nil
	elseif prefix == "awakening" then
		return innate.awakenings[rest :: string] ~= nil
	end
	return false
end

local function checkSet(set: { anyOf: { string }?, allOf: { string }? }, has: (string) -> boolean): boolean
	if set.allOf then
		for _, id in set.allOf do
			if not has(id) then
				return false
			end
		end
	end
	if set.anyOf then
		for _, id in set.anyOf do
			if has(id) then
				return true
			end
		end
		return false
	end
	return true
end

local function describeSet(label: string, set: { anyOf: { string }?, allOf: { string }? }): string
	if set.allOf then
		return label .. ": all of " .. table.concat(set.allOf, ", ")
	end
	return label .. ": any of " .. table.concat(set.anyOf or {}, ", ")
end

-- Innate affinity relevant to unlocking: the branch line's affinity, or the hybrid's geometric mean.
local function affinityFor(innate: Types.InnateProfile, branchId: string): number
	local branch = Registry.branches[branchId]
	if branch.isHybrid then
		local product = 1
		for _, d in branch.domains do
			product *= innate.domains[d] or 0
		end
		return product ^ (1 / #branch.domains)
	end
	return InnateProfile.branchAffinity(innate, branchId)
end

--[[
	Evaluates every condition for unlocking `branchId`. Returns (ok, checks) where checks lists
	each condition with whether it's met. Shown to the player as hints.
]]
function SubBranchRules.evaluate(progression: any, innate: Types.InnateProfile, branchId: string): (boolean, { Check })
	local branch = Registry.branches[branchId]
	local checks: { Check } = {}
	if not branch then
		return false, { { kind = "domain", met = false, text = "Unknown branch." } }
	end

	local function add(kind: string, met: boolean, text: string)
		table.insert(checks, { kind = kind, met = met, text = text })
	end

	for _, d in branch.domains do
		add("domain", table.find(innate.manifest, d) ~= nil, Registry.domains[d].name .. " must be awakened in you.")
	end

	if branch.isRoot then
		return checks[1].met, checks
	end

	local condition = SubBranchRules.conditionFor(branchId)
	local parentId = branch.parent
	if parentId and condition.parentTier then
		local parentMastery = progression.mastery[parentId] or 0
		local parentTier = MagicCore.tierForMastery(parentMastery)
		if progression.unlocked[parentId] and parentTier < 1 then
			parentTier = 1
		end
		add("parent", progression.unlocked[parentId] == true and parentTier >= condition.parentTier, string.format(
			"%s in %s.", MagicCore.tierDef(condition.parentTier).name, Registry.branches[parentId].name))
	end
	for _, pre in branch.prerequisites do
		add("prerequisite", (progression.mastery[pre.branch] or 0) >= pre.mastery, string.format(
			"%d mastery in %s.", pre.mastery, Registry.branches[pre.branch].name))
	end
	if condition.affinity then
		add("affinity", affinityFor(innate, branchId) >= condition.affinity, "A natural affinity for this path.")
	end
	if condition.lore then
		add("lore", checkSet(condition.lore, function(id)
			return progression.lore[id] ~= nil
		end), describeSet("Knowledge", condition.lore))
	end
	if condition.catalyst then
		add("catalyst", checkSet(condition.catalyst, function(id)
			return hasCatalyst(progression, innate, id)
		end), describeSet("Experience", condition.catalyst))
	end

	for _, check in checks do
		if not check.met then
			return false, checks
		end
	end
	return true, checks
end

return SubBranchRules
