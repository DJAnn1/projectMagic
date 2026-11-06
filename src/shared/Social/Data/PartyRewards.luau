--!strict
--[[
	PartyRewards: how a party shares what it earns (docs/Social.md §3). Shared so the Party screen can
	describe a loot mode in the words the server enforces.

	SHARE   Everyone near a kill earns shareFor(n) of a solo reward, so a party earns more in total
	        but each member earns less per kill:
	            1 player 100% · 2 players 67% each · 3 players 57% · 4 players 51% · 5 players 48%
	        A party is rewarded for being together, and five friends can't multiply a farm by five.
	LOOT    The leader picks. All three apply to creature drops and quest item drops:
	        free_for_all   each member rolls their own loot, at their share
	        round_robin    one roll for the group; each drop goes to the next member in turn; coins split
	        need_greed     one roll for the group; gear is rolled for (Need beats Greed, ties are
	                       seeded), and everything stackable goes round robin as it would be spam
	                       to ask about every scrap of hide
]]

export type Mode = { id: string, name: string, text: string, order: number }

local modes: { [string]: Mode } = {
	free_for_all = { id = "free_for_all", name = "Free for all", order = 1, text = "Everyone rolls their own loot." },
	round_robin = { id = "round_robin", name = "Round robin", order = 2, text = "One roll for the group. Each drop goes to the next person in turn, and coins are split." },
	need_greed = { id = "need_greed", name = "Need or greed", order = 3, text = "One roll for the group. Gear is rolled for: Need beats Greed. Materials go round robin." },
}

local ordered: { Mode } = {}
for _, mode in modes do
	table.insert(ordered, mode)
end
table.sort(ordered, function(a, b)
	return a.order < b.order
end)

local PartyRewards = {
	modes = modes,
	ordered = ordered,
	default = "free_for_all",
	assistRadius = 120, -- studs from a kill: closer than this counts as being in the fight
	bonusPerExtra = 0.35, -- the group's total grows by this share of a solo reward per extra member
	rollSeconds = 15, -- how long a need-or-greed roll stays open
}

function PartyRewards.shareFor(members: number): number
	local n = math.max(1, math.floor(members))
	return (1 + PartyRewards.bonusPerExtra * (n - 1)) / n
end

return PartyRewards
