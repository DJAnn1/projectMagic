--!strict
--[[
	StruggleRules: the pure maths of spells meeting in the air (docs/SpellStruggle.md; numbers in
	Data/Struggle). No instances, no services: Cast/Delivery, CastService and Cast/Struggle call it,
	and Tests/Struggle.spec checks it.

		matchup(tagsA, tagsB) -> number             A's multiplier against B (counters table)
		weight(power, form, tier, matchup) -> number
		outcome(wA, wB, headOnDot, canStruggle) -> kind, ratio
		                                            "cut_a" (A cuts through B), "cut_b", "shatter",
		                                            "struggle", "glance"
		push(weight, feed, surges, hurt) -> number
		step(point, pushA, pushB, dt) -> point       the knot moves toward the weaker side
		overwhelmed(point, gap) -> "a" | "b" | nil   the knot has reached a caster
		lineGap(a0, a1, b0, b1) -> (distance, pointOnA, pointOnB)   closest approach of two segments
]]

local Data = require(script.Parent.Data.Struggle)

local StruggleRules = {}

local function beats(tags: { string }, others: { string }): boolean
	for _, tag in tags do
		local list = Data.counters[tag]
		if list then
			for _, other in others do
				if table.find(list, other) then
					return true
				end
			end
		end
	end
	return false
end

function StruggleRules.matchup(tagsA: { string }, tagsB: { string }): number
	local forA, forB = beats(tagsA, tagsB), beats(tagsB, tagsA)
	if forA and not forB then
		return Data.matchupFor
	elseif forB and not forA then
		return Data.matchupAgainst
	end
	return 1
end

function StruggleRules.weight(power: number, form: string, tier: number, matchup: number?): number
	local f = Data.form[form] or 1
	return math.max(power, 0.1) ^ Data.powerExponent * f * (1 + Data.perTier * math.max(tier, 0)) * (matchup or 1)
end

function StruggleRules.outcome(wA: number, wB: number, headOnDot: number, canStruggle: boolean, band: number?): (string, number)
	local heavy, light = math.max(wA, wB), math.max(math.min(wA, wB), 1e-3)
	local ratio = heavy / light
	if ratio >= Data.cutAt then
		return if wA >= wB then "cut_a" else "cut_b", ratio
	end
	local struggleBand = band or Data.struggleBand
	if ratio < struggleBand then
		if headOnDot <= Data.headOnDot then
			return if canStruggle then "struggle" else "shatter", ratio
		end
		return "glance", ratio
	end
	return "shatter", ratio
end

function StruggleRules.push(weight: number, feed: number, surges: number, hurt: boolean): number
	local s = math.clamp(surges, 0, Data.surgeCap)
	return weight * feed * (1 + s * Data.surgeBoost) * (if hurt then Data.hurtFactor else 1)
end

function StruggleRules.step(point: number, pushA: number, pushB: number, dt: number): number
	local total = pushA + pushB
	if total <= 0 then
		return point
	end
	return math.clamp(point + (pushA - pushB) / total * Data.drift * dt, 0, 1)
end

-- `gap` is the distance between the casters, in studs.
function StruggleRules.overwhelmed(point: number, gap: number): string?
	local reach = math.clamp(Data.overwhelmStuds / math.max(gap, 1e-3), 0, 0.5)
	if point >= 1 - reach then
		return "b" -- the knot has reached B
	elseif point <= reach then
		return "a"
	end
	return nil
end

-- Closest approach of segments a0-a1 and b0-b1 (clamped), and the closest points on each.
function StruggleRules.lineGap(a0: Vector3, a1: Vector3, b0: Vector3, b1: Vector3): (number, Vector3, Vector3)
	local d1, d2 = a1 - a0, b1 - b0
	local r = a0 - b0
	local a, e, f = d1:Dot(d1), d2:Dot(d2), d2:Dot(r)
	local s, t = 0, 0
	if a <= 1e-6 and e <= 1e-6 then
		return r.Magnitude, a0, b0
	end
	if a <= 1e-6 then
		t = math.clamp(f / e, 0, 1)
	else
		local c = d1:Dot(r)
		if e <= 1e-6 then
			s = math.clamp(-c / a, 0, 1)
		else
			local b = d1:Dot(d2)
			local denom = a * e - b * b
			s = if denom > 1e-6 then math.clamp((b * f - c * e) / denom, 0, 1) else 0
			t = (b * s + f) / e
			if t < 0 then
				t = 0
				s = math.clamp(-c / a, 0, 1)
			elseif t > 1 then
				t = 1
				s = math.clamp((b - c) / a, 0, 1)
			end
		end
	end
	local pa, pb = a0 + d1 * s, b0 + d2 * t
	return (pa - pb).Magnitude, pa, pb
end

return StruggleRules
