--!strict
--[[
	Elemental: which elemental a Summon spell gives a body to, and how strong it is
	(docs/SpellOverhaul.md §8, stage 3b; data in Data/Elementals). Pure and shared, so the server
	(Cast/Elementals) and the Composer (Magic/SpellOutcome) always agree.

		Elemental.forBranch(branchId) -> (Elemental, styleDef)
		Elemental.health(def, power, tier) -> number
		Elemental.share(style, tier) -> number        one blow as a share of the spell's base hit
		Elemental.limit(tier) -> number               how many one summoner keeps at once
		Elemental.words(branchId) -> string           the Composer's line
]]

local Registry = require(script.Parent.Registry)
local Data = require(script.Parent.Data.Elementals)

local T = Data.tuning

local Elemental = {}

function Elemental.forBranch(branchId: string): (Data.Elemental, { [string]: any })
	local node: any = Registry.branches[branchId]
	local def: Data.Elemental? = nil
	while node do
		def = Data.byBranch[node.id]
		if def then
			break
		end
		node = if node.parent then Registry.branches[node.parent] else nil
	end
	if not def then
		local branch: any = Registry.branches[branchId]
		local domain = if branch and branch.domains then branch.domains[1] else nil
		def = (domain and Data.domains[domain]) or Data.domains.energy
	end
	local found = def :: Data.Elemental
	return found, Data.styles[found.style] or Data.styles.strike
end

function Elemental.health(def: Data.Elemental, power: number, tier: number): number
	local h = T.health
	return math.floor((h.base + math.max(1, power) * h.perPower + math.max(0, tier) * h.perTier) * (def.health or 1))
end

function Elemental.share(style: { [string]: any }, tier: number): number
	return style.share * (1 + math.max(0, tier) * T.shareTier)
end

function Elemental.limit(tier: number): number
	return if tier >= T.masterTier then T.perPlayerMaster else T.perPlayer
end

local STYLE_WORDS: { [string]: string } = {
	strike = "walks in and strikes",
	bolt = "keeps its distance and throws the spell",
	slam = "walks in and strikes the ground around it",
}

function Elemental.words(branchId: string): string
	local def = Elemental.forBranch(branchId)
	local name = def.name
	return string.format(
		"%s%s takes shape where you aim and fights beside you for %d s: it %s at whoever fights you, or you fight.",
		string.upper(string.sub(name, 1, 1)), string.sub(name, 2), T.seconds, STYLE_WORDS[def.style] or "fights"
	)
end

return Elemental
