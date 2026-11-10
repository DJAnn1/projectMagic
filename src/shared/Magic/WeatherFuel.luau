--!strict
--[[
	WeatherFuel: how much the weather at a place feeds or starves a spell (rules in
	Data/WeatherFuel, docs/WeatherFuel.md). Pure and deterministic: the same recipe, domains and
	environment always give the same answer, so MagicCore stays pure.

		WeatherFuel.factor(property, verb, domains, environment) -> (factor, ruleId?, contributions)
			factor         multiplier on power, clamped to [minFactor, maxFactor]; 1 with no environment
			ruleId         the rule that did the most (largest |share|), for logs and the Journal
			contributions  rule id -> signed share it added (for the admin readout)
		WeatherFuel.strength(rule, value) -> 0..1   how far into its ramp a fact is
]]

local Data = require(script.Parent.Data.WeatherFuel)

local WeatherFuel = {}

local function smoothstep(t: number): number
	t = math.clamp(t, 0, 1)
	return t * t * (3 - 2 * t)
end

function WeatherFuel.strength(rule: Data.Rule, value: number): number
	if rule.to == rule.from then
		return if value >= rule.to then 1 else 0
	end
	return smoothstep((value - rule.from) / (rule.to - rule.from))
end

local function matches(rule: Data.Rule, property: string, verb: string, domains: { string }): boolean
	if not table.find(rule.properties, property) then
		return false
	end
	if rule.verbs and not table.find(rule.verbs, verb) then
		return false
	end
	if rule.domains then
		for _, d in domains do
			if table.find(rule.domains, d) then
				return true
			end
		end
		return false
	end
	return true
end

function WeatherFuel.factor(
	property: string,
	verb: string,
	domains: { string },
	environment: { [string]: number }?
): (number, string?, { [string]: number })
	local contributions: { [string]: number } = {}
	if not environment then
		return 1, nil, contributions
	end
	local total, best, bestSize = 0, nil :: string?, 0
	for _, rule in Data.rules do
		if not matches(rule, property, verb, domains) then
			continue
		end
		local value = environment[rule.fact]
		if typeof(value) ~= "number" or value ~= value then
			continue
		end
		local share = rule.bonus * WeatherFuel.strength(rule, value)
		if share ~= 0 then
			contributions[rule.id] = share
			total += share
			if math.abs(share) > bestSize then
				best, bestSize = rule.id, math.abs(share)
			end
		end
	end
	return math.clamp(1 + total, Data.minFactor, Data.maxFactor), best, contributions
end

-- The rule definition by id (nil if unknown).
function WeatherFuel.rule(id: string): Data.Rule?
	for _, rule in Data.rules do
		if rule.id == id then
			return rule
		end
	end
	return nil
end

return WeatherFuel
