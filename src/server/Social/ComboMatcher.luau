--!strict
--[[
	ComboMatcher: do these two spells make a combo? Pure, so the rules can be specced
	(Tests/Social.spec). Services/ComboService supplies the recent casts and fires the result.

	Two spells match when: two different people cast them, neither backfired, neither is an excluded
	verb, they landed within the combo's window and reach, and one fills each role.
]]

local Combos = require(game:GetService("ReplicatedStorage").Shared.Social.Data.Combos)

export type Cast = {
	userId: number,
	domains: { string },
	tags: { string },
	verb: string,
	power: number,
	branch: string,
	point: Vector3,
	at: number,
	backfired: boolean,
}

local ComboMatcher = {}

function ComboMatcher.fills(role: Combos.Role, cast: Cast): boolean
	if not table.find(cast.domains, role.domain) then
		return false
	end
	if role.tags then
		for _, tag in role.tags do
			if table.find(cast.tags, tag) then
				return true
			end
		end
		return false
	end
	return true
end

function ComboMatcher.matches(combo: Combos.Combo, a: Cast, b: Cast): boolean
	if a.userId == b.userId or a.backfired or b.backfired then
		return false
	end
	if table.find(combo.excludeVerbs, a.verb) or table.find(combo.excludeVerbs, b.verb) then
		return false
	end
	if math.abs(a.at - b.at) > combo.window or (a.point - b.point).Magnitude > combo.reach then
		return false
	end
	local first, second = combo.roles[1], combo.roles[2]
	return (ComboMatcher.fills(first, a) and ComboMatcher.fills(second, b))
		or (ComboMatcher.fills(first, b) and ComboMatcher.fills(second, a))
end

-- The role a partner would need to finish a combo this cast starts, or nil.
function ComboMatcher.neededRole(combo: Combos.Combo, cast: Cast): Combos.Role?
	if cast.backfired or table.find(combo.excludeVerbs, cast.verb) then
		return nil
	end
	if ComboMatcher.fills(combo.roles[1], cast) then
		return combo.roles[2]
	elseif ComboMatcher.fills(combo.roles[2], cast) then
		return combo.roles[1]
	end
	return nil
end

-- How hard a combo hits: the two spells' average recipe power plus its bonus, capped at 10.
function ComboMatcher.powerOf(combo: Combos.Combo, a: Cast, b: Cast): number
	return math.min(10, (a.power + b.power) / 2 + combo.powerBonus)
end

function ComboMatcher.radiusOf(combo: Combos.Combo, power: number): number
	return combo.radius + combo.radiusPerPower * power
end

return ComboMatcher
