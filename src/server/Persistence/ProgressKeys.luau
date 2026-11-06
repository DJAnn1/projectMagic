--!strict
--[[
	ProgressKeys: how a progress reset works, with no Instances, so Tests/ProgressReset.spec can check it
	(docs/Backend.md, "Resetting progress").

	Every record that belongs to players' progress is stored under key(baseKey, generation). Generation 0
	is the original, with no prefix, so saves from before this existed keep their exact keys. A reset moves
	everyone to a new generation: their next load finds nothing, so they start fresh. Nothing is deleted,
	so an earlier generation can be put back. Generation numbers are never reused, or a later reset could
	land on an old generation's saves.

		key(base, generation) -> string
		allKeys(base, highest) -> { string }      every generation of a record (for erasure requests)
		nextGeneration(highest) -> number
		canRestore(generation, current, highest) -> reason?
]]

local ProgressKeys = {}

function ProgressKeys.key(base: string, generation: number): string
	return if generation > 0 then "p" .. generation .. "_" .. base else base
end

function ProgressKeys.allKeys(base: string, highest: number): { string }
	local keys: { string } = {}
	for generation = 0, math.max(0, highest) do
		table.insert(keys, ProgressKeys.key(base, generation))
	end
	return keys
end

function ProgressKeys.nextGeneration(highest: number): number
	return math.max(0, highest) + 1
end

-- Why this generation can't be put back, or nil if it can.
function ProgressKeys.canRestore(generation: number, current: number, highest: number): string?
	if generation % 1 ~= 0 or generation < 0 or generation > highest then
		return "there is no generation " .. tostring(generation) .. " (0 to " .. highest .. " exist)"
	elseif generation == current then
		return "generation " .. generation .. " is already the one in use"
	end
	return nil
end

return ProgressKeys
