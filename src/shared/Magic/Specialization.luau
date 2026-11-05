--!strict
--[[
	Specialization: pure helpers over commitment data (no saving, no remotes).
	Shared so the client can preview what an oath would do.

		Specialization.branchMods(commitments) -> { [branchId] = { power, cost, xp } }
		Specialization.conflicts(commitments, id) -> string?   (reason an oath can't be added)
]]

local Types = require(script.Parent.Types)
local Registry = require(script.Parent.Registry)
local Specializations = require(script.Parent.Data.Specializations)

local Specialization = {}

-- The branch and every branch below it.
function Specialization.subtree(branchId: string): { string }
	local out: { string } = {}
	local function walk(id: string)
		local branch = Registry.branches[id]
		if not branch then
			return
		end
		table.insert(out, id)
		for _, child in branch.children do
			walk(child)
		end
	end
	walk(branchId)
	return out
end

local function multiply(into: { [string]: Types.BranchMod }, branchIds: { string }, mod: Types.BranchMod)
	for _, id in branchIds do
		local current = into[id] or { power = 1, cost = 1, xp = 1 }
		into[id] = { power = current.power * mod.power, cost = current.cost * mod.cost, xp = current.xp * mod.xp }
	end
end

-- Combined effect of every commitment, expanded over subtrees. Missing branch = neutral.
function Specialization.branchMods(commitments: { [string]: number }?): { [string]: Types.BranchMod }
	local mods: { [string]: Types.BranchMod } = {}
	if not commitments then
		return mods
	end
	local ids: { string } = {}
	for id in commitments do
		table.insert(ids, id)
	end
	table.sort(ids) -- deterministic multiplication order
	for _, id in ids do
		local def = Specializations[id]
		if def then
			multiply(mods, Specialization.subtree(def.branch), def.boost)
			for _, weakened in def.weakens do
				multiply(mods, Specialization.subtree(weakened), def.penalty)
			end
		end
	end
	return mods
end

local function overlaps(a: { string }, b: { string }): boolean
	local set: { [string]: boolean } = {}
	for _, id in a do
		set[id] = true
	end
	for _, id in b do
		if set[id] then
			return true
		end
	end
	return false
end

local function weakenedSet(def: Types.SpecializationDef): { string }
	local out: { string } = {}
	for _, weakened in def.weakens do
		for _, id in Specialization.subtree(weakened) do
			table.insert(out, id)
		end
	end
	return out
end

-- Nil if `id` can be added alongside the existing commitments, otherwise the reason.
function Specialization.conflicts(commitments: { [string]: number }, id: string): string?
	local def = Specializations[id]
	if not def then
		return "UNKNOWN_SPECIALIZATION"
	end
	if commitments[id] then
		return "ALREADY_COMMITTED"
	end
	local boosted = Specialization.subtree(def.branch)
	local weakened = weakenedSet(def)
	for otherId in commitments do
		local other = Specializations[otherId]
		if other then
			if overlaps(boosted, weakenedSet(other)) or overlaps(weakened, Specialization.subtree(other.branch)) then
				return "OPPOSES_" .. string.upper(otherId)
			end
		end
	end
	return nil
end

return Specialization
