--!strict
--[[
	Charge: hold-to-charge maths, shared by the server (which applies it) and the client (which
	predicts and shows it). Numbers in Data/ChargeTuning; docs/Casting.md §8.

		step(castTime) -> seconds per stage step
		maxHold(castTime) -> seconds a charge can count
		stageIndex(held, castTime) -> 1..#stages     stage(index) -> Stage
		releaseCastTime(index, castTime, held) -> seconds from release to effect
		apply(stats, index, held) -> Applied         mutates a SpellStats copy for the cast
]]

local Data = require(script.Parent.Data.ChargeTuning)

local Charge = {}

Charge.data = Data

export type Applied = {
	stage: Data.Stage,
	speedMult: number,
}

-- Slow spells (rituals, quakes) don't charge: their long cast time IS their wind-up, and a
-- shorter stage step would let a charge skip it.
function Charge.chargeable(castTime: number): boolean
	return castTime <= Data.maxChargeableCastTime
end

function Charge.step(castTime: number): number
	return math.max(castTime, Data.minStep)
end

function Charge.maxHold(castTime: number): number
	return Charge.step(castTime) * Data.maxSteps
end

function Charge.stageIndex(held: number, castTime: number): number
	local steps = math.clamp(held, 0, Charge.maxHold(castTime)) / Charge.step(castTime)
	local index = 1
	for i, stage in Data.stages do
		if steps >= stage.at then
			index = i
		end
	end
	return index
end

function Charge.stage(index: number): Data.Stage
	return Data.stages[math.clamp(index, 1, #Data.stages)]
end

-- Seconds between release and the effect. A tap still waits part of its cast time (minus what
-- it already held); a charged spell was wound up while held, so only the release motion is left.
function Charge.releaseCastTime(index: number, castTime: number, held: number): number
	local stage = Charge.stage(index)
	if stage.castTime then
		return math.max(0.1, castTime * stage.castTime - held)
	end
	return Data.releaseTime
end

-- Applies a stage to freshly computed stats (the cast's own copy). Power always scales; area,
-- targets and speed only for forms that take them; overcharge adds cost and backfire risk.
function Charge.apply(stats: any, index: number, held: number): Applied
	local stage = Charge.stage(index)
	local scales = Data.formScales[stats.recipe.form] or {}
	stats.power *= stage.power
	stats.castTime = Charge.releaseCastTime(index, stats.castTime, held)
	if scales.area and stage.area then
		stats.area *= stage.area
	end
	if scales.targets and stage.targets then
		stats.maxTargets += stage.targets
	end
	if stage.overcharge then
		local o = Data.overcharge
		stats.cost *= o.costMult
		stats.costBreakdown.reservoir *= o.costMult
		stats.backfireChance = math.clamp(stats.backfireChance + o.backfireAdd, 0, 0.95)
	end
	return {
		stage = stage,
		speedMult = if scales.speed and stage.speed then stage.speed else 1,
	}
end

return Charge
