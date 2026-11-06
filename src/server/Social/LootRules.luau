--!strict
--[[
	LootRules: how a pooled drop is divided. Pure, so Tests/Economy.spec can check every case.

		splitCoins(coins, n) -> { number }             as even as whole coins allow; none lost or made
		decideRoll(entries, rng) -> userId?            who wins a need-or-greed roll
]]

export type RollEntry = { userId: number, choice: string? } -- "need" | "greed" | "pass" | nil (no answer)

local LootRules = {}

function LootRules.splitCoins(coins: number, n: number): { number }
	local out: { number } = {}
	local count = math.max(1, n)
	local each = math.floor(coins / count)
	local extra = coins - each * count
	for i = 1, count do
		out[i] = each + (if i <= extra then 1 else 0)
	end
	return out
end

-- Need beats Greed. Ties are decided by `rng` over a stable order, so the same seed gives the same
-- winner on any server. Nobody answering (or everyone passing) means nobody wins.
function LootRules.decideRoll(entries: { RollEntry }, rng: Random): number?
	local function among(choice: string): { number }
		local out: { number } = {}
		for _, entry in entries do
			if entry.choice == choice then
				table.insert(out, entry.userId)
			end
		end
		table.sort(out)
		return out
	end
	local needs = among("need")
	local pool = if #needs > 0 then needs else among("greed")
	if #pool == 0 then
		return nil
	end
	return pool[rng:NextInteger(1, #pool)]
end

return LootRules
