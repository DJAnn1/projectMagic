--!strict
--[[
	Melee: spellblade timing and weapon rules, shared by the server (Services/MeleeService) and the
	client's prediction (CastClient). Numbers in Data/MeleeTuning; docs/Combat.md §13.

		Melee.swing(index) -> Swing
		Melee.nextIndex(last, sinceStart, speed) -> (index?, wait)
		    last: the swing in progress (nil = none). Returns the swing a press makes now, or nil and
		    how long until the combo window opens (a press that early is buffered by the client and
		    refused by the server).
		Melee.weaponBonus(itemDef?, attackPower, attackSpeedPct) -> Bonus
]]

local Data = require(script.Parent.Data.MeleeTuning)

local Melee = {}

Melee.data = Data

export type Bonus = {
	speed: number, -- swing speed (times divide by it)
	reach: number, -- extra studs of reach
	flat: number, -- flat damage added to each hit
	powerMult: number, -- multiplier on the spell-power part
}

function Melee.swing(index: number): Data.Swing
	return Data.swings[math.clamp(index, 1, #Data.swings)]
end

function Melee.nextIndex(last: number?, sinceStart: number, speed: number): (number?, number)
	if not last then
		return 1, 0
	end
	local swing = Melee.swing(last)
	local openAt = swing.comboFrom / speed
	local closeAt = swing.duration / speed + Data.comboGrace
	if sinceStart < openAt then
		return nil, openAt - sinceStart
	end
	if sinceStart <= closeAt then
		return last % #Data.swings + 1, 0
	end
	return 1, 0 -- the combo lapsed: start again
end

local NO_BONUS: Bonus = { speed = 1, reach = 0, flat = 0, powerMult = 1 }

-- What the main-hand item adds. Weapons (except bows) bring their reach, speed and damage; a
-- focus sharpens the spell's edge instead.
function Melee.weaponBonus(def: any?, attackPower: number?, attackSpeedPct: number?): Bonus
	local W = Data.weapons
	local speedPct = 1 + (attackSpeedPct or 0)
	if not def then
		return { speed = math.clamp(speedPct, W.minSpeed, W.maxSpeed), reach = 0, flat = attackPower or 0, powerMult = 1 }
	end
	local weapon = def.weapon
	if weapon and weapon.kind ~= "bow" then
		return {
			speed = math.clamp(weapon.speed / W.speedRef * speedPct, W.minSpeed, W.maxSpeed),
			reach = math.max(0, weapon.reach - Data.swings[1].reach),
			flat = weapon.damage + (attackPower or 0),
			powerMult = if def.category == "focus" then W.focusPower else 1,
		}
	end
	if def.category == "focus" then
		return { speed = math.clamp(speedPct, W.minSpeed, W.maxSpeed), reach = 0, flat = attackPower or 0, powerMult = W.focusPower }
	end
	return NO_BONUS
end

return Melee
