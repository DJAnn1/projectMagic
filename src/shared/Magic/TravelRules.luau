--!strict
--[[
	TravelRules: the decisions behind Domain Travel, with no Instances, so Tests/Travel.spec can check them
	(docs/Travel.md). Services/TravelService does the checking and Controllers/TravelClient does the moving.
]]

local T = require(script.Parent.Data.TravelTuning)
local GravityRules = require(script.Parent.GravityRules)

local byTier = GravityRules.byTier

local TravelRules = {}

export type Known = { domain: string, tier: number, xp: number }

-- Which domain you ride in. A readied spell's domain wins, at your best tier in it. Otherwise it's your
-- best domain, with XP settling a tie, then the alphabet, so it's always the same one.
function TravelRules.pick(known: { Known }, readied: string?): (string, number)
	local best: Known? = nil
	local readiedTier = 0
	for _, entry in known do
		if entry.domain == readied then
			readiedTier = math.max(readiedTier, entry.tier)
		end
		local current = best
		if
			not current
			or entry.tier > current.tier
			or (entry.tier == current.tier and entry.xp > current.xp)
			or (entry.tier == current.tier and entry.xp == current.xp and entry.domain < current.domain)
		then
			best = entry
		end
	end
	if readied and readiedTier > 0 and T.styles[readied] then
		return readied, readiedTier
	end
	if best and T.styles[best.domain] then
		return best.domain, best.tier
	end
	return T.fallbackDomain, 1
end

function TravelRules.speed(domain: string, tier: number): number
	local style = T.styles[domain] or T.styles[T.fallbackDomain]
	return byTier(T.speed, tier) * style.speedMult
end

function TravelRules.drainPerSecond(maxReservoir: number, tier: number): number
	return maxReservoir * byTier(T.drainShare, tier)
end

function TravelRules.canSetOff(current: number, maxReservoir: number, infinite: boolean): boolean
	return infinite or current >= maxReservoir * T.minReservoir
end

function TravelRules.knockedOff(amount: number, maxHealth: number): boolean
	return maxHealth > 0 and amount >= maxHealth * T.knockShare
end

-- Is this movement more than travel allows? Knockback, dashes, roofs and cliffs all fit in the margins.
function TravelRules.violation(domain: string, tier: number, speed: number, height: number): boolean
	local style = T.styles[domain] or T.styles[T.fallbackDomain]
	return speed > TravelRules.speed(domain, tier) * T.speedSlack + T.speedMargin or height > style.hover + style.lift + T.heightMargin
end

-- How fast to rise or sink to stay `target` high: quick to correct, and never faster than you travel.
function TravelRules.verticalSpeed(currentY: number, targetY: number, maxSpeed: number): number
	return math.clamp((targetY - currentY) * 6, -maxSpeed, maxSpeed)
end

-- Space climbs and Shift sinks, within the style's lift. Letting go settles you back down, so a glide
-- ends gently and a hop is only a hop.
function TravelRules.nextLift(lift: number, maxLift: number, up: boolean, down: boolean, dt: number): number
	local rate = if up then 18 elseif down then -24 else -6
	return math.clamp(lift + rate * dt, 0, maxLift)
end

return TravelRules
