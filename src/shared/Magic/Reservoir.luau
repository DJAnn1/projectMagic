--!strict
--[[
	Reservoir
	The resource model (Layer 4): capacity, regeneration, ambient density and overdraw.

	Pure state transitions over a ReservoirState table. The SERVER owns the only real
	instance per caster; clients may receive a replicated copy for UI. Time is passed in
	(`now`, e.g. workspace:GetServerTimeNow()) and randomness is passed in as a seeded Random,
	so every outcome is reproducible from (worldSeed, casterId, "overdraw", castCounter).
]]

local Types = require(script.Parent.Types)
local Registry = require(script.Parent.Registry)

local R = Registry.Tuning.Reservoir

type CasterProfile = Types.CasterProfile
type ReservoirState = Types.ReservoirState
type SpellStats = Types.SpellStats
type SpendResult = Types.SpendResult
type Consequence = Types.Consequence

local Reservoir = {}

-- 0..100 overall magical development. Explicit value wins; otherwise derived from total mastery.
function Reservoir.computeAttunement(caster: CasterProfile): number
	if caster.attunement then
		return math.clamp(caster.attunement, 0, 100)
	end
	local total = 0
	for _, m in caster.mastery do
		total += math.clamp(m, 0, 100)
	end
	return 100 * (1 - math.exp(-total / R.attunementScale))
end

local function traitsOf(caster: CasterProfile): Types.CasterTraits
	return caster.traits or Registry.Tuning.neutralTraits
end

function Reservoir.maxReservoir(caster: CasterProfile): number
	local a = Reservoir.computeAttunement(caster) / 100
	return (R.base + R.span * a ^ R.curve) * traitsOf(caster).capacity
end

function Reservoir.newState(caster: CasterProfile): ReservoirState
	local max = Reservoir.maxReservoir(caster)
	local traits = traitsOf(caster)
	return {
		current = max,
		max = max,
		strain = 0,
		burnoutUntil = 0,
		lockouts = {},
		regenMult = traits.regen,
		riskMult = traits.overdrawRisk,
	}
end

-- Call after mastery or innate traits change; keeps the current/max ratio.
function Reservoir.refreshMax(state: ReservoirState, caster: CasterProfile)
	local newMax = Reservoir.maxReservoir(caster)
	if state.max > 0 then
		state.current *= newMax / state.max
	end
	state.max = newMax
	local traits = traitsOf(caster)
	state.regenMult = traits.regen
	state.riskMult = traits.overdrawRisk
end

function Reservoir.isLockedOut(state: ReservoirState, domainId: string, now: number): boolean
	local untilTime = state.lockouts[domainId]
	return untilTime ~= nil and now < untilTime
end

function Reservoir.regenPerSecond(state: ReservoirState, activity: string, ambientDensity: number, now: number): number
	if now < state.burnoutUntil then
		return 0
	end
	local activityMult = R.activity[activity] or 1
	local density = math.max(0, ambientDensity)
	local strainPenalty = 1 - R.strainRegenPenalty * math.clamp(state.strain / 100, 0, 1)
	-- sqrt: rich places help, but a nexus (3) only regenerates ~1.7x faster than normal ground.
	return state.max * R.regenFraction * math.sqrt(density) * activityMult * strainPenalty * state.regenMult
end

-- Advance regen and decay. Server calls this on a throttled loop (e.g. every 0.5s), not per frame.
function Reservoir.tick(state: ReservoirState, dt: number, now: number, activity: string, ambientDensity: number)
	local regen = Reservoir.regenPerSecond(state, activity, ambientDensity, now)
	state.current = math.min(state.max, state.current + regen * dt)
	state.strain = math.max(0, state.strain - R.strainDecayPerSecond * dt)
	for domainId, untilTime in state.lockouts do
		if now >= untilTime then
			state.lockouts[domainId] = nil
		end
	end
end

-- For hybrids, the worst multiplier of each kind applies.
local function combinedRisk(domains: { string }): Types.RiskDef
	local first = Registry.domains[domains[1]].risk
	local combined: Types.RiskDef = table.clone(first)
	for i = 2, #domains do
		local r = Registry.domains[domains[i]].risk
		combined.backlashMult = math.max(combined.backlashMult, r.backlashMult)
		combined.burnoutMult = math.max(combined.burnoutMult, r.burnoutMult)
		combined.lockoutMult = math.max(combined.lockoutMult, r.lockoutMult)
		combined.mutationMult = math.max(combined.mutationMult, r.mutationMult)
	end
	return combined
end

--[[
	Attempts to pay for a spell. Mutates `state` only on success.
	Overdraw (going below zero, down to -overdrawLimit * max) is allowed but produces
	consequences scaled by how deep the caster ends up. The caller (server cast pipeline)
	applies them: HP damage, status effects, mutation rolls into the Progression system.
]]
function Reservoir.trySpend(state: ReservoirState, stats: SpellStats, now: number, rng: Random): SpendResult
	local result: SpendResult = {
		ok = false,
		reason = nil,
		overdraw = 0,
		hpCost = stats.costBreakdown.vitalHp,
		consequences = {},
	}

	for _, d in stats.domains do
		if Reservoir.isLockedOut(state, d, now) then
			result.reason = "DOMAIN_LOCKED"
			return result
		end
	end

	local cost = stats.costBreakdown.reservoir
	local after = state.current - cost
	if after < -R.overdrawLimit * state.max then
		result.reason = "INSUFFICIENT_RESERVOIR"
		return result
	end
	if after < 0 and now < state.burnoutUntil then
		result.reason = "BURNED_OUT"
		return result
	end

	-- Only the part of the cost that pushes further below zero counts as new overdraw.
	local newDeficit = math.max(0, -after) - math.max(0, -state.current)
	state.current = after
	result.ok = true
	if newDeficit <= 0 then
		return result
	end

	local depth = -after / state.max -- 0 .. overdrawLimit
	local risk = combinedRisk(stats.domains)
	local innate = state.riskMult -- temperament (Steadfast < 1 < Brittle)
	result.overdraw = newDeficit

	table.insert(result.consequences, {
		kind = "Backlash",
		riskId = risk.id,
		amount = newDeficit * R.backlashHpPerMana * risk.backlashMult * innate,
		duration = 0,
	})

	if depth > R.burnoutThreshold then
		local duration = (R.burnoutBase + R.burnoutPerDepth * depth) * risk.burnoutMult * innate
		state.burnoutUntil = math.max(state.burnoutUntil, now + duration)
		table.insert(result.consequences, { kind = "Burnout", riskId = risk.id, amount = 0, duration = duration })
	end

	if depth > R.lockoutThreshold then
		local duration = (R.lockoutBase + R.lockoutPerDepth * depth) * risk.lockoutMult * innate
		for _, d in stats.domains do
			state.lockouts[d] = math.max(state.lockouts[d] or 0, now + duration)
			table.insert(result.consequences, { kind = "Lockout", riskId = risk.id, amount = 0, duration = duration, domain = d })
		end
	end

	if depth > R.mutationThreshold then
		local chance = math.min(R.mutationMaxChance, (depth - R.mutationThreshold) * R.mutationPerDepth * risk.mutationMult * innate)
		if rng:NextNumber() < chance then
			table.insert(result.consequences, { kind = "Mutation", riskId = risk.id, amount = chance, duration = 0, domain = stats.domains[1] })
		end
	end

	state.strain = math.min(100, state.strain + depth * R.strainPerDepth)
	return result
end

return Reservoir
