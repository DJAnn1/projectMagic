--!strict
--[[
	TimeRules: the decisions behind the Time powers, with no Instances, so Tests/Time.spec can check them
	(docs/Time.md). Server/Magic/Cast/TimeRuntime does the running.
]]

local T = require(script.Parent.Data.TimeTuning)
local GravityRules = require(script.Parent.GravityRules)

local byTier = GravityRules.byTier

local TimeRules = {}

TimeRules.byTier = byTier

export type Refusal = string?

-- Can you recall to your mark right now? Nil = yes, otherwise why not.
function TimeRules.recallRefusal(hasMark: boolean, markExpires: number, readyAt: number, now: number, inDuel: boolean, timeStopped: boolean): Refusal
	if not hasMark or now >= markExpires then
		return "NO_MARK"
	elseif inDuel then
		return "IN_DUEL"
	elseif timeStopped then
		return "TIME_STOPPED"
	elseif now < readyAt then
		return "TOO_SOON"
	end
	return nil
end

-- Does this blow trigger your mark instead of killing you?
function TimeRules.savesFromDeath(amount: number, health: number, hasMark: boolean, markExpires: number, markTier: number, readyAt: number, now: number): boolean
	return amount >= health and health > 0 and hasMark and now < markExpires and markTier >= T.lastMoment.minTier and now >= readyAt
end

-- Cooldowns as "seconds left", so a recall can put them back as they were when you marked.
function TimeRules.cooldownsLeft(cooldowns: { [string]: number }, now: number): { [string]: number }
	local out: { [string]: number } = {}
	for key, readyAt in cooldowns do
		if readyAt > now then
			out[key] = readyAt - now
		end
	end
	return out
end

-- Rebuilds a cooldown table from a snapshot: anything not in it is ready again.
function TimeRules.cooldownsRestored(left: { [string]: number }, now: number): { [string]: number }
	local out: { [string]: number } = {}
	for key, seconds in left do
		out[key] = now + seconds
	end
	return out
end

-- Adds a target mark. Marking the same person again refreshes them; past the cap, the oldest goes.
-- `same(a, b)` compares whoever the marks are on. Returns the mark that was pushed out, if any.
function TimeRules.addMark<M>(marks: { M }, mark: M, cap: number, same: (M, M) -> boolean): M?
	for i, existing in marks do
		if same(existing, mark) then
			marks[i] = mark
			return nil
		end
	end
	table.insert(marks, mark)
	if #marks > math.max(1, cap) then
		return table.remove(marks, 1)
	end
	return nil
end

-- What a borrowed wound finally deals.
function TimeRules.woundTotal(held: number, mult: number): number
	return math.max(0, held) * math.max(0, mult)
end

-- Does a Timestop take this body? Everything but the caster, except that a duel is its two fighters'
-- own: an outsider can't freeze a fighter and decide it.
function TimeRules.stopFreezes(isCaster: boolean, targetDuel: any, casterDuel: any): boolean
	if isCaster then
		return false
	end
	return targetDuel == nil or targetDuel == casterDuel
end

function TimeRules.stopRadius(area: number): number
	return math.clamp(area, T.timestop.radiusMin, T.timestop.radiusMax)
end

return TimeRules
