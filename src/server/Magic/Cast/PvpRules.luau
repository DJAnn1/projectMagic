--!strict
--[[
	PvpRules: the ONE answer to "may this player hurt that player?" (docs/Social.md §2).

	Asked in two places, on purpose: Targeting.canHarm (who a spell or swing picks) and Damage.apply
	(the last gate every magic hit passes), so damage that never goes through targeting (fire
	ticks, reactions, damage over time) follows the same rules.

	Order, first match wins:
		1. yourself                always allowed (backfires)
		2. either is in a duel     only the two fighters, only once the fight has begun. Nobody else
		                           can touch a duellist, and a duellist can't touch anyone else.
		3. a duel just ended       the same two can't hurt each other for a few seconds
		4. the same party          never (friendly fire is off)
		5. everyone else           the `pvp_enabled` flag

	State only: PartyService and DuelService write it, and it requires nothing but flags, so anything
	in the combat layer can ask without a dependency cycle. Nothing here is saved: parties and duels
	live and die with the server.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)

type DuelEntry = { id: string, fighting: boolean }

local PvpRules = {}

local partyOf: { [number]: string } = {}
local duelOf: { [number]: DuelEntry } = {}
local grace: { [string]: number } = {} -- "low|high" userIds -> os.clock() it ends

local function pairKey(a: number, b: number): string
	return if a < b then a .. "|" .. b else b .. "|" .. a
end

function PvpRules.setParty(userId: number, partyId: string?)
	partyOf[userId] = partyId
end

function PvpRules.sameParty(a: number, b: number): boolean
	local party = partyOf[a]
	return party ~= nil and party == partyOf[b]
end

-- `fighting` false is the countdown: nobody can hurt them yet, not even each other.
function PvpRules.setDuel(userId: number, duelId: string?, fighting: boolean?)
	duelOf[userId] = if duelId then { id = duelId, fighting = fighting == true } else nil
end

function PvpRules.inDuel(userId: number): boolean
	return duelOf[userId] ~= nil
end

function PvpRules.setGrace(a: number, b: number, seconds: number, now: number?)
	grace[pairKey(a, b)] = (now or os.clock()) + seconds
end

function PvpRules.clearGrace(a: number, b: number)
	grace[pairKey(a, b)] = nil
end

-- Pure of flags and clocks, so the specs can drive it. Returns (allowed, why).
function PvpRules.canHurt(attacker: number, victim: number, pvpOn: boolean, now: number): (boolean, string)
	if attacker == victim then
		return true, "self"
	end
	local a, v = duelOf[attacker], duelOf[victim]
	if a or v then
		if a and v and a.id == v.id and a.fighting and v.fighting then
			return true, "duel"
		end
		return false, "duel_isolated"
	end
	local key = pairKey(attacker, victim)
	local ends = grace[key]
	if ends then
		if now < ends then
			return false, "duel_grace"
		end
		grace[key] = nil
	end
	if PvpRules.sameParty(attacker, victim) then
		return false, "party"
	end
	return pvpOn, if pvpOn then "pvp" else "pvp_off"
end

function PvpRules.allowed(attacker: number, victim: number): boolean
	local ok = PvpRules.canHurt(attacker, victim, FeatureFlags.get("pvp_enabled") == true, os.clock())
	return ok
end

-- May `helper` heal or buff `target`? Yes, unless one of them is in a duel (outside help would
-- decide it, and a fighter healing their opponent makes no sense).
function PvpRules.canHelp(helper: number, target: number): boolean
	return helper == target or (duelOf[helper] == nil and duelOf[target] == nil)
end

return PvpRules
