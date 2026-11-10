--!strict
--[[
	RealityRules: the decisions behind the Reality powers, with no Instances, so Tests/Reality.spec can
	check them (docs/Reality.md). Server/Magic/Cast/RealityRuntime does the running.
]]

local R = require(script.Parent.Data.RealityTuning)
local GravityRules = require(script.Parent.GravityRules)

local byTier = GravityRules.byTier

local RealityRules = {}

RealityRules.byTier = byTier

-- The law an edict lays down, by its verb. Nil: not an edict (the old reality field handles it).
local EDICTS: { [string]: string } = {
	reduce = "hush", -- nobody but you may cast
	amplify = "sanctuary", -- nobody but you can hurt anyone inside
	bind = "severance", -- hostile projectiles vanish
	transmute = "reversal", -- harm heals you and your allies
}
RealityRules.edicts = EDICTS

function RealityRules.edictKind(verb: string): string?
	return EDICTS[verb]
end

-- What Conjure builds, by form.
local SHAPES: { [string]: string } = {
	touch = "step",
	beam = "bridge",
	wall = "wall",
	pillar = "pillar",
	zone = "bastion",
	burst = "bastion",
	ritual = "bastion",
}

function RealityRules.conjureShape(form: string): string?
	return SHAPES[form]
end

-- Exchange: you and the target trade health percentages. Nil when you'd gain nothing.
-- Returns the health each of you ends with.
function RealityRules.exchange(casterHealth: number, casterMax: number, targetHealth: number, targetMax: number): (number?, number?)
	if casterMax <= 0 or targetMax <= 0 then
		return nil, nil
	end
	local mine, theirs = casterHealth / casterMax, targetHealth / targetMax
	if theirs <= mine then
		return nil, nil
	end
	return theirs * casterMax, math.max(1, mine * targetMax)
end

-- Undying: what still lands when nothing may take you below 1 health.
function RealityRules.undyingClamp(amount: number, health: number): number
	return math.clamp(health - 1, 0, amount)
end

-- Crit chance with a Reality bonus: a bonus of 1 or more is certain, and the bonus lifts the cap too.
function RealityRules.critChance(chance: number, cap: number, bonus: number): number
	if bonus >= 1 then
		return 1
	end
	return math.min(cap + math.max(0, bonus), chance + bonus)
end

function RealityRules.edictRadius(area: number, tier: number): number
	return math.clamp(area, R.edict.radiusMin, math.max(R.edict.radiusMin, byTier(R.edict.radiusMax, tier)))
end

-- A bridge from your feet to the aim, never longer than `maxLength`: its middle, length and facing.
function RealityRules.bridge(from: Vector3, to: Vector3, maxLength: number): (Vector3, number, Vector3)
	local offset = to - from
	local length = offset.Magnitude
	if length < 0.1 then
		return from, 0, Vector3.new(0, 0, -1)
	end
	local direction = offset.Unit
	length = math.min(length, maxLength)
	return from + direction * (length / 2), length, direction
end

-- The panels of a ring (a bastion or a cage): where each goes around `center` and how wide it is.
function RealityRules.ring(radius: number, panels: number): { { angle: number, offset: Vector3, width: number } }
	local out = {}
	local count = math.max(3, math.floor(panels))
	local width = 2 * radius * math.sin(math.pi / count) + 0.6 -- a little overlap, so no gaps at the joins
	for i = 0, count - 1 do
		local angle = (i / count) * math.pi * 2
		table.insert(out, { angle = angle, offset = Vector3.new(math.sin(angle) * radius, 0, math.cos(angle) * radius), width = width })
	end
	return out
end

-- Can a Worldlaw be laid down now?
function RealityRules.worldlawRefusal(active: number, readyAt: number, now: number): string?
	if active >= R.worldlaw.maxActive then
		return "WORLD_STRAINED"
	elseif now < readyAt then
		return "REALITY_COOLDOWN"
	end
	return nil
end

return RealityRules
