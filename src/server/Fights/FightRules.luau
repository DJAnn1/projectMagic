--!strict
--[[
	FightRules: the pure parts of NPCs fighting each other (docs/NpcFights.md). No services, no
	Instances: Services/NpcFightService and Tests/Fights.spec call these.

	grudge(a, b, edgeAB, edgeBA)  0..~2: how close two people are to blows. Rivalry and dislike from
	                              the relationship graph (both directions, the worse counts), plus
	                              friction: clashing temperaments, worse when one of them is short
	                              tempered. Family never: a bond other than rival/coworker is 0.
	friction(a, b)                (1 - compatibility) x (1 - the lower agreeableness): 0..1
	canBrawl(npc)                 an adult, awake, not busy with anything else
	inHours(hour, hours)          hours = { from, to }, to over 24 wraps past midnight
	brawlOver(state)              why a running brawl ends, or nil while it goes on
	raidCount(seedRoll, count)    how many come
	rankRaiders(candidates)       who comes first: guards and hunters, then by courage, then id
]]

local FightRules = {}

export type Edge = { affinity: number, trust: number, rivalry: number, bond: string? }

local TRAITS = { "agreeableness", "extraversion", "openness", "humor", "conscientiousness" }

local function compatibility(a: any, b: any): number
	local diff = 0
	for _, t in TRAITS do
		diff += math.abs((a.traits[t] or 0.5) - (b.traits[t] or 0.5))
	end
	return math.clamp(1 - diff / #TRAITS, 0, 1)
end

function FightRules.friction(a: any, b: any): number
	local temper = 1 - math.min(a.traits.agreeableness or 0.5, b.traits.agreeableness or 0.5)
	return math.clamp((1 - compatibility(a, b)) * temper, 0, 1)
end

local FAMILY = { spouse = true, parent = true, child = true, sibling = true, mentor = true, student = true }

function FightRules.grudge(a: any, b: any, edgeAB: Edge?, edgeBA: Edge?): number
	if (edgeAB and edgeAB.bond and FAMILY[edgeAB.bond]) or (edgeBA and edgeBA.bond and FAMILY[edgeBA.bond]) then
		return 0
	end
	local worst = 0
	for _, e in { edgeAB, edgeBA } do
		if e then
			worst = math.max(worst, e.rivalry + math.max(0, -e.affinity))
		end
	end
	return worst + FightRules.friction(a, b)
end

local BUSY = { sleep = true, shelter = true, flee = true }

function FightRules.canBrawl(npc: any): boolean
	return npc.ageBand ~= "child"
		and npc.occupation ~= "child"
		and npc.occupation ~= "retired"
		and not npc.knockedOut
		and not npc.frozen
		and npc.leash == nil
		and npc.combat == nil
		and not BUSY[npc.action or ""]
end

function FightRules.inHours(hour: number, hours: { number }): boolean
	local from, to = hours[1], hours[2]
	if to > 24 then
		return hour >= from or hour < to - 24
	end
	return hour >= from and hour < to
end

export type BrawlState = {
	elapsed: number, -- real seconds since the first spell
	lasts: number,
	shareA: number, -- health share of each
	shareB: number,
	floor: number,
	apart: number, -- studs between them
	apartLimit: number,
	guardDistance: number?, -- the nearest guard on the way, if any
	breakAt: number,
	goneA: boolean, -- knocked out, despawned or out of sight
	goneB: boolean,
}

-- "a_won" / "b_won" (the other is at the floor), "broken" (a guard got there), "ran" (too far
-- apart), "gone" (one of them isn't there any more), "spent" (time's up), or nil.
function FightRules.brawlOver(s: BrawlState): string?
	if s.goneA or s.goneB then
		return "gone"
	end
	local margin = 0.02
	if s.shareB <= s.floor + margin then
		return "a_won"
	end
	if s.shareA <= s.floor + margin then
		return "b_won"
	end
	if s.guardDistance and s.guardDistance <= s.breakAt then
		return "broken"
	end
	if s.apart > s.apartLimit then
		return "ran"
	end
	if s.elapsed >= s.lasts then
		return "spent"
	end
	return nil
end

function FightRules.raidCount(roll: number, count: { number }): number
	local span = count[2] - count[1] + 1
	return count[1] + math.clamp(math.floor(roll * span), 0, span - 1)
end

export type Candidate = { id: string, fighter: boolean, courage: number }

-- Sorted copy: guards and hunters first, then the bravest, then by id (deterministic).
function FightRules.rankRaiders(candidates: { Candidate }): { Candidate }
	local out = table.clone(candidates)
	table.sort(out, function(x, y)
		if x.fighter ~= y.fighter then
			return x.fighter
		end
		if math.abs(x.courage - y.courage) > 1e-6 then
			return x.courage > y.courage
		end
		return x.id < y.id
	end)
	return out
end

return FightRules
