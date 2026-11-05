--!strict
--[[
	WeaponRules: the pure maths of item weapons, shared by the server (Services/WeaponService,
	Services/GuardService, Services/StaminaService) and the client's prediction
	(Controllers/WeaponClient). Numbers in Data/WeaponTuning; docs/Items.md §10.

		WeaponRules.classify(def?) -> ("melee" | "ranged" | nil, MeleeKind | RangedKind | nil)
		WeaponRules.speed(weapon, attackSpeedPct?) -> number          swing speed (times divide by it)
		WeaponRules.swing(kind, index) -> Swing
		WeaponRules.nextIndex(kind, last?, sinceStart, speed) -> (index?, wait)
		WeaponRules.swingStamina(weapon, swing) -> number
		WeaponRules.drawShare(ranged, held) -> number?                nil = not drawn enough
		WeaponRules.holdDrain(ranged, held) -> number                  stamina/s while over-holding
		WeaponRules.reload(weapon, ranged) -> number                   seconds between shots
		WeaponRules.baseHit(weapon, attackPower?, share) -> number
		WeaponRules.defenseReduction(defense) -> number                0..maxDefenseReduction
		WeaponRules.canBlock(def?) -> boolean
]]

local ItemTypes = require(script.Parent.ItemTypes)
local Data = require(script.Parent.Data.WeaponTuning)

type WeaponDef = ItemTypes.WeaponDef

local WeaponRules = {}

WeaponRules.data = Data

function WeaponRules.classify(def: ItemTypes.ItemDef?): (string?, any)
	local weapon = def and def.weapon
	if not weapon then
		return nil, nil
	end
	local melee = Data.melee[weapon.kind]
	if melee then
		return "melee", melee
	end
	local ranged = Data.ranged[weapon.kind]
	if ranged then
		return "ranged", ranged
	end
	return nil, nil
end

function WeaponRules.speed(weapon: WeaponDef, attackSpeedPct: number?): number
	return math.clamp(weapon.speed / Data.speedRef * (1 + (attackSpeedPct or 0)), Data.minSpeed, Data.maxSpeed)
end

function WeaponRules.swing(kind: Data.MeleeKind, index: number): Data.Swing
	return kind.swings[math.clamp(index, 1, #kind.swings)]
end

-- The swing a press makes now (nil + seconds to wait when the combo window isn't open yet).
function WeaponRules.nextIndex(kind: Data.MeleeKind, last: number?, sinceStart: number, speed: number): (number?, number)
	if not last then
		return 1, 0
	end
	local swing = WeaponRules.swing(kind, last)
	local openAt = swing.comboFrom / speed
	local closeAt = swing.duration / speed + Data.comboGrace
	if sinceStart < openAt then
		return nil, openAt - sinceStart
	end
	if sinceStart <= closeAt then
		return last % #kind.swings + 1, 0
	end
	return 1, 0 -- the combo lapsed: start again
end

function WeaponRules.swingStamina(weapon: WeaponDef, swing: Data.Swing): number
	return weapon.stamina * swing.stamina
end

-- A bow's hit share for a draw held `held` seconds: nil below drawMin, rising to 1 at drawFull,
-- then sagging back toward minShare after holdMax (arms tire). Other ranged kinds: always 1.
function WeaponRules.drawShare(ranged: Data.RangedKind, held: number): number?
	local d = ranged.draw
	if not d then
		return 1
	end
	if held < d.drawMin then
		return nil
	end
	if held <= d.drawFull then
		local t = (held - d.drawMin) / math.max(0.01, d.drawFull - d.drawMin)
		return d.minShare + (1 - d.minShare) * t
	end
	if held <= d.holdMax then
		return 1
	end
	return math.max(d.minShare, 1 - (held - d.holdMax) * 0.25)
end

function WeaponRules.holdDrain(ranged: Data.RangedKind, held: number): number
	local d = ranged.draw
	return if d and held > d.holdMax then d.holdDrainPerSecond else 0
end

function WeaponRules.reload(weapon: WeaponDef, ranged: Data.RangedKind): number
	return math.max(ranged.reload, 1 / math.max(0.1, weapon.speed))
end

function WeaponRules.baseHit(weapon: WeaponDef, attackPower: number?, share: number): number
	return (weapon.damage + (attackPower or 0)) * share
end

function WeaponRules.defenseReduction(defense: number): number
	local d = math.max(0, defense)
	return math.min(Data.hits.maxDefenseReduction, d / (d + Data.hits.defenseK))
end

function WeaponRules.canBlock(def: ItemTypes.ItemDef?): boolean
	local class, kind = WeaponRules.classify(def)
	return class == "melee" and kind.canBlock == true
end

return WeaponRules
