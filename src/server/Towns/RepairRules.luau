--!strict
--[[
	RepairRules: the decisions behind how places recover, with no Instances beyond colours, so
	Tests/TownRepair.spec can check every case (docs/TownRepair.md). Services/TownRepairService runs it.

		scorches(materialName) -> boolean           does this ground burn bare and regrow?
		quarters(x, z, size) -> { {x, z} }          the patches a scar regrows in
		healTimes(now, rng) -> { number }           when each one comes back, seeded
		freshColor(original) -> Color3              a repaired part stays a little paler
		rebuildOrder(pieces)                        sorts so the lowest comes off the end first
		mended(integrity) -> (integrity, gained)    a standing building's slow recovery
		isLiving(modelName) -> boolean              recovers by itself: nobody comes to fix it
		pickWorker(candidates) -> id?               who comes to fix it
		footprint(positions) / footprintOf(cf, size)   the ground a building covers
		inside(footprint, position) -> boolean
		heightsWithin(footprint, places, margin) -> (baseY, topY, strays)   ignoring what's nowhere near it
		spotAround(footprint, from, turn) -> Vector3   where they stand: outside it, on some side
		scaffoldPlan(footprint, baseY, topY) -> pieces  poles and planks
]]

local Data = require(script.Parent.Data.Repair)

local T = Data.tuning

export type Footprint = { x: number, z: number, hx: number, hz: number }
export type ScaffoldPiece = { kind: string, size: Vector3, position: Vector3 }

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

-- From the ground up. The list is worked from its end, so the lowest piece goes last in the list.
function RepairRules.rebuildOrder(pieces: { any })
	table.sort(pieces, function(a, b)
		if a.at.Position.Y ~= b.at.Position.Y then
			return a.at.Position.Y > b.at.Position.Y
		end
		return a.part.Name > b.part.Name
	end)
end

function RepairRules.mended(integrity: number): (number, number)
	local after = math.min(T.wholeIntegrity, integrity + T.mendAmount)
	return after, after - integrity
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

-- The ground covered by these points. A collapsed building's real places, not where its rubble landed.
function RepairRules.footprint(positions: { Vector3 }): Footprint
	local x0, x1, z0, z1 = math.huge, -math.huge, math.huge, -math.huge
	for _, p in positions do
		x0, x1 = math.min(x0, p.X), math.max(x1, p.X)
		z0, z1 = math.min(z0, p.Z), math.max(z1, p.Z)
	end
	if x0 > x1 then
		return { x = 0, z = 0, hx = 0, hz = 0 }
	end
	return { x = (x0 + x1) / 2, z = (z0 + z1) / 2, hx = (x1 - x0) / 2, hz = (z1 - z0) / 2 }
end

-- The same for a standing model's bounding box, which may be turned.
function RepairRules.footprintOf(cf: CFrame, size: Vector3): Footprint
	local r, u, l = cf.RightVector, cf.UpVector, cf.LookVector
	return {
		x = cf.Position.X,
		z = cf.Position.Z,
		hx = (math.abs(r.X) * size.X + math.abs(u.X) * size.Y + math.abs(l.X) * size.Z) / 2,
		hz = (math.abs(r.Z) * size.X + math.abs(u.Z) * size.Y + math.abs(l.Z) * size.Z) / 2,
	}
end

function RepairRules.inside(footprint: Footprint, position: Vector3): boolean
	return math.abs(position.X - footprint.x) <= footprint.hx and math.abs(position.Z - footprint.z) <= footprint.hz
end

-- How high a building goes, from the places inside its footprint. Strays are left out and counted: one far-off
-- part stretched a scaffold across the sea (seen in play, 2026-11-07).
function RepairRules.heightsWithin(footprint: Footprint, places: { Vector3 }, margin: number): (number, number, number)
	local grown: Footprint = { x = footprint.x, z = footprint.z, hx = footprint.hx + margin, hz = footprint.hz + margin }
	local base, top, strays = math.huge, -math.huge, 0
	for _, at in places do
		if RepairRules.inside(grown, at) then
			base, top = math.min(base, at.Y), math.max(top, at.Y)
		else
			strays += 1
		end
	end
	if base > top then
		return 0, 0, strays
	end
	return base, top, strays
end

-- Somewhere to stand outside the building: the side nearest `from`, then `turn` sides round from there.
-- Always outside, so nobody gets built into it.
function RepairRules.spotAround(footprint: Footprint, from: Vector3, turn: number): Vector3
	local dx, dz = from.X - footprint.x, from.Z - footprint.z
	local rx, rz = math.abs(dx) / math.max(footprint.hx, 1), math.abs(dz) / math.max(footprint.hz, 1)
	-- Sides in order round the building: +X, +Z, -X, -Z.
	local side = if rx >= rz then (if dx >= 0 then 0 else 2) else (if dz >= 0 then 1 else 3)
	side = (side + turn) % 4
	local x, z = footprint.x, footprint.z
	if side == 0 then
		x += footprint.hx + T.stepOff
	elseif side == 1 then
		z += footprint.hz + T.stepOff
	elseif side == 2 then
		x -= footprint.hx + T.stepOff
	else
		z -= footprint.hz + T.stepOff
	end
	return Vector3.new(x, from.Y, z)
end

function RepairRules.scaffoldPlan(footprint: Footprint, baseY: number, topY: number): { ScaffoldPiece }
	local s = Data.scaffold
	local hx, hz = footprint.hx + s.margin, footprint.hz + s.margin
	local bottom = baseY - s.groundBelow
	local height = math.max(4, topY - bottom)
	local midY = bottom + height / 2
	local out: { ScaffoldPiece } = {}
	local function pole(x: number, z: number)
		table.insert(out, { kind = "Pole", size = Vector3.new(s.poleWidth, height, s.poleWidth), position = Vector3.new(x, midY, z) })
	end
	for _, sx in { -1, 1 } do
		for _, sz in { -1, 1 } do
			pole(footprint.x + sx * hx, footprint.z + sz * hz)
		end
		if hz * 2 > s.midPoleOver then
			pole(footprint.x + sx * hx, footprint.z)
		end
	end
	if hx * 2 > s.midPoleOver then
		for _, sz in { -1, 1 } do
			pole(footprint.x, footprint.z + sz * hz)
		end
	end
	local level = 1
	local y = baseY + s.levelEvery
	while y < topY and level <= s.maxLevels do
		for _, sz in { -1, 1 } do
			table.insert(out, { kind = "Plank", size = Vector3.new(hx * 2, s.plankThick, s.plankWide), position = Vector3.new(footprint.x, y, footprint.z + sz * hz) })
		end
		for _, sx in { -1, 1 } do
			table.insert(out, { kind = "Plank", size = Vector3.new(s.plankWide, s.plankThick, hz * 2), position = Vector3.new(footprint.x + sx * hx, y, footprint.z) })
		end
		level += 1
		y += s.levelEvery
	end
	return out
end

return RepairRules
