--!strict
--[[
	RepairRules: the decisions behind how places recover, with no Instances beyond colours, so
	Tests/TownRepair.spec can check every case (docs/TownRepair.md). Services/TownRepairService runs it.

		scorches(materialName) -> boolean           does this ground burn bare and regrow?
		quarters(x, z, size) -> { {x, z} }          the patches a scar regrows in
		healTimes(now, rng) -> { number }           when each one comes back, seeded
		freshColor(original) -> Color3              a repaired part stays a little paler
		isLiving(modelName) -> boolean              recovers by itself: nobody comes to fix it
		pickWorker(candidates) -> id?               who comes to fix it
		workSpot(part, from) -> Vector3             where they stand to do it
]]

local Data = require(script.Parent.Data.Repair)

local T = Data.tuning

export type Candidate = { id: string, occupation: string, available: boolean, distance: number }

local RepairRules = {}

function RepairRules.scorches(materialName: string): boolean
	return T.scorchable[materialName] == true
end

function RepairRules.quarters(x: number, z: number, size: number): { { x: number, z: number } }
	local step = size / 4
	return {
		{ x = x - step, z = z - step },
		{ x = x + step, z = z - step },
		{ x = x - step, z = z + step },
		{ x = x + step, z = z + step },
	}
end

function RepairRules.healTimes(now: number, rng: Random): { number }
	local times = {}
	for i = 1, 4 do
		times[i] = now + T.healMin + rng:NextNumber() * T.healSpread
	end
	return times
end

function RepairRules.freshColor(original: Color3): Color3
	return original:Lerp(T.freshColor, T.freshShare)
end

function RepairRules.isLiving(modelName: string): boolean
	local lower = string.lower(modelName)
	for _, word in T.livingNames do
		if string.find(lower, word, 1, true) then
			return true
		end
	end
	return false
end

-- The right trade first, then whoever's closest. Children, the retired and guards on duty aren't asked.
function RepairRules.pickWorker(candidates: { Candidate }): string?
	local best: Candidate? = nil
	local bestRank = math.huge
	for _, c in candidates do
		if c.available and not Data.neverAsked[c.occupation] then
			local rank = Data.trades[c.occupation] or Data.anyoneElse
			if rank < bestRank or (best and rank == bestRank and (c.distance < best.distance or (c.distance == best.distance and c.id < best.id))) then
				best, bestRank = c, rank
			end
		end
	end
	return if best then best.id else nil
end

function RepairRules.workSpot(part: Vector3, from: Vector3): Vector3
	local flat = Vector3.new(from.X - part.X, 0, from.Z - part.Z)
	local away = if flat.Magnitude > 0.5 then flat.Unit else Vector3.new(1, 0, 0)
	return Vector3.new(part.X, from.Y, part.Z) + away * T.stepOff
end

return RepairRules
