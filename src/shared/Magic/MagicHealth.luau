--!strict
--[[
	MagicHealth: how much health your magic gives you (numbers in Data/MagicHealth). Pure, so the
	same rule serves players (InventoryService's "Your magic" stat layer), NPC rigs (NPC/NPCLOD) and
	the spec.

		MagicHealth.of(caster) -> Parts
			best      tier of your best branch (0..8)
			tierFlat  byTier[best]
			breadth   other branches at breadthMinTier or above
			breadthFlat  breadth x breadthPerBranch, at most breadthCap
			flat      tierFlat + breadthFlat (added to health)
			pct       lifePct x your Life affinity (multiplies health, after gear: StatCalc step 7)
]]

local MagicCore = require(script.Parent.MagicCore)
local Data = require(script.Parent.Data.MagicHealth)

export type Parts = { best: number, tierFlat: number, breadth: number, breadthFlat: number, flat: number, pct: number }

local MagicHealth = {}

function MagicHealth.of(caster: any?): Parts
	local best, tiers = 0, {} :: { number }
	if caster and caster.mastery then
		for branchId in caster.mastery :: { [string]: number } do
			local tier = MagicCore.masteryTier(caster, branchId)
			table.insert(tiers, tier)
			best = math.max(best, tier)
		end
	end
	-- Breadth: every branch at Novice or above but the best one.
	table.sort(tiers, function(a, b)
		return a > b
	end)
	local breadth = 0
	for i = 2, #tiers do
		if tiers[i] >= Data.breadthMinTier then
			breadth += 1
		end
	end
	local tierFlat = Data.byTier[best] or 0
	local breadthFlat = math.min(Data.breadthCap, breadth * Data.breadthPerBranch)
	local life = if caster and caster.affinities then (caster.affinities.life or 0) else 0
	return {
		best = best,
		tierFlat = tierFlat,
		breadth = breadth,
		breadthFlat = breadthFlat,
		flat = tierFlat + breadthFlat,
		pct = Data.lifePct * math.clamp(life, 0, 1),
	}
end

-- Total maximum health for a body with `base` health and no gear (NPC rigs).
function MagicHealth.maxFor(caster: any?, base: number): number
	local parts = MagicHealth.of(caster)
	return math.floor((base + parts.flat) * (1 + parts.pct) + 0.5)
end

return MagicHealth
