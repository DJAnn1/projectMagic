--!strict
--[[
	SurgeRules: the decisions behind Surge, with no Instances, so Tests/Moments.spec can check them
	(docs/Moments.md). Services/SurgeService does the running.
]]

local S = require(script.Parent.Data.SurgeTuning)
local GravityRules = require(script.Parent.GravityRules)

local byTier = GravityRules.byTier

local SurgeRules = {}

SurgeRules.byTier = byTier

-- How much of the meter this much damage dealt is worth. Stronger mages need more, as they hit harder.
function SurgeRules.gainFromDealing(amount: number, tier: number): number
	if amount <= 0 then
		return 0
	end
	return math.min(S.maxPerHit, amount / byTier(S.fillDamage, tier))
end

function SurgeRules.gainFromTaking(amount: number, maxHealth: number): number
	if amount <= 0 or maxHealth <= 0 then
		return 0
	end
	return math.min(S.maxPerHit, amount / maxHealth * S.takenShare)
end

function SurgeRules.addMeter(meter: number, gain: number): number
	return math.clamp(meter + gain, 0, 1)
end

-- A second passing with no fighting: only fades after a while.
function SurgeRules.fade(meter: number, secondsIdle: number, dt: number): number
	if secondsIdle < S.idleSeconds then
		return meter
	end
	return math.max(0, meter - S.fadePerSecond * dt)
end

function SurgeRules.ready(meter: number): boolean
	return meter >= 1
end

-- The domain you've fought with most. Ties go to the alphabetically first, so it's always the same.
function SurgeRules.favourite(tally: { [string]: number }, fallback: string): string
	local best, bestAmount = fallback, 0
	local ids: { string } = {}
	for id in tally do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		if tally[id] > bestAmount then
			best, bestAmount = id, tally[id]
		end
	end
	return best
end

function SurgeRules.finisherFor(domain: string): S.Finisher
	return S.finishers[domain] or S.fallback
end

-- The blast at this distance from the centre, before resistance.
function SurgeRules.finisherAmount(fullHit: number, tier: number, distance: number, radius: number): number
	local t = if radius > 0 then math.clamp(distance / radius, 0, 1) else 0
	return fullHit * byTier(S.finisherShare, tier) * (1 - (1 - S.finisherRim) * t)
end

return SurgeRules
