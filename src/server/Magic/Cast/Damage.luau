--!strict
--[[
	Damage: the ONE way magic hurts or heals a Humanoid (players and NPCs alike). Going through here
	guarantees that wards absorb, hexes amplify, ForceFields protect (TakeDamage), NPC brains learn
	who hit them, and every client nearby sees the number.

		Damage.apply(humanoid, amount, sourceUserId?, kind, info?) -> dealt
		Damage.heal(humanoid, amount, sourceUserId?, info?) -> healed
		Damage.onDamage   hook(humanoid, dealt, kind, sourceUserId, info) set by EffectRunner:
		                  MagicDamage / TargetDamaged / TargetKilled topics + the "hit" cue
		Damage.onHeal     hook(humanoid, healed, sourceUserId, info): the "heal" cue
		Damage.record() / Damage.stopRecord(record)
		                  collects every hit dealt ON THIS THREAD between the two calls (CastService's
		                  per-cast debug log). Other threads' damage is never mixed in, even when a
		                  resolver yields.

	Order: quest ward -> a raised guard (Cast/Guard: block or parry, frontal hits with `from`;
	damage over time and environment damage carry no `from` and are never blocked) -> hexes and
	wards (StatusEffects) -> health.

	Spells compute `amount` with Cast/DamageModel (crit, resistance, falloff, caps); environment
	damage (fire ticks, waves, scalding) passes raw amounts with no info.

	Sets Humanoid attributes "LastMagicAttacker" (UserId) and "LastMagicHitAt" (server time).
]]

local StatusEffects = require(script.Parent.StatusEffects)
local Guard = require(script.Parent.Guard)

export type Info = {
	domain: string?, -- colours the damage number
	crit: boolean?,
	killed: boolean?, -- set by apply when this hit took the target from alive to dead
	power: number?, -- the spell's recipe power (knockdown rules)
	from: Vector3?, -- where the attack came from (knockdown direction, NPC aggro, guard arc)
	-- Guards (Cast/Guard): what kind of spell this is, and who cast it (parried touch staggers).
	property: string?,
	pierce: boolean?,
	form: string?,
	attacker: Model?,
	blocked: boolean?, -- set by apply: a guard turned part of it away
}

-- `practice`: the target is a practice dummy (model attribute PracticeTarget), not a person.
export type RecordEntry = { name: string, dealt: number, crit: boolean, killed: boolean, kind: string, position: Vector3?, practice: boolean }

local Damage = {}

Damage.onDamage = nil :: ((Humanoid, number, string, number?, Info) -> ())?
Damage.onHeal = nil :: ((Humanoid, number, number?, Info) -> ())?

local recorders: { [thread]: { RecordEntry } } = {}

function Damage.record(): { RecordEntry }
	local list: { RecordEntry } = {}
	recorders[coroutine.running()] = list
	return list
end

function Damage.stopRecord(list: { RecordEntry })
	local thread = coroutine.running()
	if recorders[thread] == list then
		recorders[thread] = nil
	end
end

function Damage.apply(humanoid: Humanoid, amount: number, sourceUserId: number?, kind: string, info: Info?): number
	if amount <= 0 or humanoid.Health <= 0 then
		return 0
	end
	-- Quest ward (QuestDirector): an escorted or protected NPC can't be hurt by other players, so
	-- nobody can grief someone else's quest by killing its people.
	local ward = humanoid:GetAttribute("QuestWard")
	if typeof(ward) == "number" and sourceUserId and sourceUserId ~= ward then
		return 0
	end
	-- A raised guard turns frontal hits away first (Cast/Guard; wards and hexes come after).
	local guarded, outcome = Guard.mitigate(humanoid, amount, info)
	if outcome == "parry" then
		return 0
	end
	local scaled = guarded * StatusEffects.damageTakenMult(humanoid)
	local remaining = StatusEffects.absorb(humanoid, scaled)
	if remaining <= 0 then
		return 0
	end
	local before = humanoid.Health
	humanoid:TakeDamage(remaining)
	local dealt = before - humanoid.Health
	if sourceUserId then
		humanoid:SetAttribute("LastMagicAttacker", sourceUserId)
	end
	humanoid:SetAttribute("LastMagicHitAt", workspace:GetServerTimeNow())
	if dealt <= 0 then
		return 0
	end
	local hitInfo: Info = if info then table.clone(info) else {}
	hitInfo.killed = humanoid.Health <= 0
	hitInfo.blocked = outcome == "block" or nil
	hitInfo.attacker = nil -- an Instance: never forwarded into cues
	local list = recorders[coroutine.running()]
	if list then
		local model = humanoid.Parent
		table.insert(list, {
			name = if model then model.Name else "?",
			dealt = dealt,
			crit = hitInfo.crit == true,
			killed = hitInfo.killed == true,
			kind = kind,
			position = if humanoid.RootPart then humanoid.RootPart.Position else nil,
			practice = model ~= nil and model:GetAttribute("PracticeTarget") == true,
		})
	end
	local hook = Damage.onDamage
	if hook then
		hook(humanoid, dealt, kind, sourceUserId, hitInfo)
	end
	return dealt
end

function Damage.heal(humanoid: Humanoid, amount: number, sourceUserId: number?, info: Info?): number
	if amount <= 0 or humanoid.Health <= 0 then
		return 0
	end
	local before = humanoid.Health
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + amount)
	local healed = humanoid.Health - before
	local hook = Damage.onHeal
	if hook and healed > 0 then
		hook(humanoid, healed, sourceUserId, info or {})
	end
	return healed
end

return Damage
