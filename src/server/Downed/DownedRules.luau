--!strict
--[[
	DownedRules: what happens after you lose (docs/LivingHistory.md §7). Pure decisions; the doing is
	Services/DownedService. Kept free of services so CreatureService, WildbornService and NPCCombat can
	require it for `ignored`.

		DownedRules.choose(ctx, roll) -> outcome
		    "death"    another player beat you, or you're in a Rift: as before
		    "capture"  deep wilds, a Wildborn did it, not captured lately, and the roll allows
		    "carry"    a free townsperson is within reach
		    "wake"     come round where you fell
		    "spawn"    nothing else fits: wake at the spawn, as before
		  Never the same outcome twice in a row (spawn excepted: it's the floor).
		DownedRules.purse(coins, lastHadPurse, roll) -> coins dropped (0 = no purse)
		DownedRules.returns(traits, affinity, roll) -> bool: does the finder give it back?
		DownedRules.ignored(humanoid) -> bool: down, or just up (enemies leave them be)
]]

local T = require(script.Parent.Data.DownedTuning)

local DownedRules = {}

DownedRules.Tuning = T

export type Outcome = "death" | "capture" | "carry" | "wake" | "spawn"

export type Context = {
	pvp: boolean, -- another player landed the blow
	rift: boolean, -- inside a Rift's pocket, or a Rift enemy did it
	carrier: boolean, -- a free townsperson is within carryReach
	deep: boolean, -- deepFrom or more from the nearest town
	wildborn: boolean, -- a living Wildborn did it
	captureReady: boolean, -- not captured within captureGap
	last: string?, -- the outcome last time
}

function DownedRules.choose(ctx: Context, roll: number): Outcome
	if ctx.pvp or ctx.rift then
		return "death"
	end
	local order: { Outcome } = {}
	if ctx.deep and ctx.wildborn and ctx.captureReady and roll < T.captureChance then
		table.insert(order, "capture")
	end
	if ctx.carrier then
		table.insert(order, "carry")
	end
	table.insert(order, "wake")
	for _, outcome in order do
		if outcome ~= ctx.last then
			return outcome
		end
	end
	return "spawn"
end

function DownedRules.deep(distanceToTown: number): boolean
	return distanceToTown >= T.deepFrom
end

function DownedRules.purse(coins: number, lastHadPurse: boolean, roll: number): number
	if lastHadPurse or coins < T.purseMin then
		return 0
	end
	local share = T.purseShare[1] + math.clamp(roll, 0, 1) * (T.purseShare[2] - T.purseShare[1])
	return math.clamp(math.floor(coins * share), 1, coins)
end

-- Honest, conscientious people and people who like you give it back; a little luck either way.
function DownedRules.returns(traits: { [string]: number }, affinity: number, roll: number): boolean
	local honesty = 0.45 * (traits.agreeableness or 0.5) + 0.35 * (traits.conscientiousness or 0.5) + 0.6 * affinity + 0.3 * math.clamp(roll, 0, 1)
	return honesty >= T.returnAt
end

function DownedRules.ignored(humanoid: Humanoid): boolean
	if humanoid:GetAttribute("Downed") == true then
		return true
	end
	local grace = humanoid:GetAttribute("DownedGraceUntil")
	return typeof(grace) == "number" and grace > workspace:GetServerTimeNow()
end

return DownedRules
