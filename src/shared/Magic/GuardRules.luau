--!strict
--[[
	GuardRules: blocking, wards and parries, as data and pure rules (docs/Combat.md §12). Shared:
	the server applies them (Cast/Guard, Services/GuardService) and the client shows them (the
	ward, the guard meter, "unblockable" tags on the reticle and in the Composer).

	BLOCK    a raised guard turns away `blockReduction` of a hit that comes from the front
	         (within arcDegrees of where the body faces). What it turns away is taken from the
	         guard meter (capacity = capacityShare x MaxHealth) and, for players, from the
	         reservoir (reservoirPerPoint). An empty meter BREAKS the guard: a stagger, and no
	         guard again for brokenLockout seconds. The meter refills when not hit for regenDelay.
	PARRY    a hit within parryWindow seconds of raising the guard (server time; players get up
	         to latencyAllowanceMax more for their ping) is turned away completely: projectiles fly
	         back at their caster, touch spells stagger the attacker. Re-raising within
	         parryCooldown of lowering gives a block but no parry window (no parry spam).
	PIERCE   the Piercing modifier halves what a guard turns away (pierceMult).
	THROUGH  Mental and Temporal magic ignores guards entirely (a ward stops force, not thought
	         or time).
]]

local Registry = require(script.Parent.Registry)

local GuardRules = {}

GuardRules.tuning = {
	arcDegrees = 70, -- half-angle of the front a guard covers
	blockReduction = 0.7, -- share of a frontal hit turned away
	pierceMult = 0.5, -- Piercing spells: the reduction is multiplied by this
	capacityShare = 0.6, -- guard meter = this x MaxHealth worth of turned-away damage
	reservoirPerPoint = 0.5, -- players: reservoir drained per point turned away
	regenDelay = 1.0, -- seconds without a blocked hit before the meter refills
	regenPerSecond = 0.25, -- meter share refilled per second
	minRaiseMeter = 0.15, -- can't raise a guard with less meter than this
	breakStaggerSeconds = 1.5,
	brokenLockout = 2.5, -- seconds after a break before a guard can be raised again
	parryWindow = 0.18, -- seconds after raising
	latencyAllowanceMax = 0.12, -- extra window for a player's ping, at most this
	parryCooldown = 0.6, -- seconds after lowering before a fresh parry window
	parryStaggerSeconds = 1.2, -- a parried touch spell staggers its caster this long
	walkMult = 0.5, -- walk speed while guarding
	unblockableCategories = { Mental = true, Temporal = true } :: { [string]: boolean },
}

local T = GuardRules.tuning

export type Kind = "blockable" | "pierces" | "unblockable"

-- How guards treat a spell, from its property's category and its modifiers.
function GuardRules.kindOf(property: string?, piercing: boolean?): Kind
	local def = property and Registry.properties[property]
	if def and T.unblockableCategories[(def :: any).category] then
		return "unblockable"
	end
	return if piercing then "pierces" else "blockable"
end

function GuardRules.kindOfRecipe(recipe: any): Kind
	local piercing = false
	for _, m in (recipe.modifiers or {}) :: { string } do
		if m == "piercing" then
			piercing = true
		end
	end
	return GuardRules.kindOf(recipe.property, piercing)
end

-- The glyph + words the interface shows for a kind (never colour alone).
function GuardRules.label(kind: Kind): string
	if kind == "unblockable" then
		return "⊘ Unblockable"
	elseif kind == "pierces" then
		return "↣ Pierces guards"
	end
	return "⛨ Blockable"
end

-- Does a guard facing `look` from `rootPosition` cover an attack coming from `from`?
function GuardRules.covers(look: Vector3, rootPosition: Vector3, from: Vector3): boolean
	local toward = Vector3.new(from.X - rootPosition.X, 0, from.Z - rootPosition.Z)
	local facing = Vector3.new(look.X, 0, look.Z)
	if toward.Magnitude < 0.1 or facing.Magnitude < 0.1 then
		return true -- point blank: the guard is between you
	end
	return facing.Unit:Dot(toward.Unit) >= math.cos(math.rad(T.arcDegrees))
end

-- Share of `amount` a guard turns away for this kind of spell.
function GuardRules.reduction(kind: Kind): number
	if kind == "unblockable" then
		return 0
	end
	return T.blockReduction * (if kind == "pierces" then T.pierceMult else 1)
end

return GuardRules
