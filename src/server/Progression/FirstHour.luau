--!strict
--[[
	FirstHour: the targets for a new player's first hour, and how a set of measurements is judged
	(docs/EarlyGamePlan.md §10). Pure. Tests/FirstHourSim and Services/FirstHourService both report
	through it, so the simulation and live play are held to the same numbers.

	Times are seconds of play since the first join. nil = hasn't happened.
]]

export type Row = {
	damage: number?, -- first blow on anything but yourself
	ranged: number?, -- first harmful hit with a projectile, beam or chain
	novice: number?, -- best branch reaches Novice
	novelty: number?, -- first new verb + property + form (the target's "discovery")
	recipe: number?, -- first recipe discovery: needs power 2, so Novice first
	quest: number?, -- first quest completed
	casts: number?,
	idle: number?, -- seconds with nothing to do
}

local FirstHour = {}

FirstHour.TARGETS = table.freeze({
	damage = 120,
	ranged = 600,
	novice = 1800,
	novelty = 1200,
})

FirstHour.MAX_SLOWER_THAN_ENERGY = 1.25
FirstHour.ORDER = table.freeze({ "damage", "ranged", "novice", "novelty", "recipe", "quest" })
FirstHour.NOVICE_TIER = 2 -- Progression.getMasteryTier: Sensing 1, Novice 2, Adept 3

function FirstHour.format(seconds: number?): string
	if seconds == nil then
		return "-"
	end
	return string.format("%.1fm", seconds / 60)
end

-- The targets a row misses. A milestone that never happened misses too, once the row's time has
-- passed its target (`elapsed`; a player eight minutes in hasn't missed the Novice target yet).
function FirstHour.misses(row: { [string]: any }, elapsed: number): { string }
	local out: { string } = {}
	for _, name in FirstHour.ORDER do
		local target = (FirstHour.TARGETS :: any)[name]
		if target then
			local at = row[name]
			if (at and at > target) or (not at and elapsed > target) then
				table.insert(out, name)
			end
		end
	end
	return out
end

-- Is this time more than the allowed margin slower than Energy's? Never reaching it counts as
-- slower when Energy did; if Energy didn't either, there's nothing to compare.
function FirstHour.tooSlow(at: number?, energy: number?): boolean
	if not energy then
		return false
	end
	return at == nil or at > energy * FirstHour.MAX_SLOWER_THAN_ENERGY
end

function FirstHour.median(values: { number }): number?
	if #values == 0 then
		return nil
	end
	local sorted = table.clone(values)
	table.sort(sorted)
	local middle = (#sorted + 1) / 2
	local low, high = sorted[math.floor(middle)], sorted[math.ceil(middle)]
	return (low + high) / 2
end

return FirstHour
