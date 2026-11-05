--!strict
--[[
	SettlementLayout: Step 2 of procedural settlements, a settlement's streets and lots.
	Pure and deterministic: (worldSeed, settlement, seeded height field) -> Layout. No Instances,
	no raycasts, so every server computes the same town without talking.

	1. PLAZA      a square of the tier's plaza radius at the average ground height of its centre
	2. MAIN ROADS radiate from the plaza: first toward the inter-settlement roads that arrive
	              here, then seeded bearings spread as far apart as possible, up to the tier's
	              count. Each walks outward in 10-stud steps, choosing at every step the heading
	              (straight, or 14 degrees either way) that climbs least: roads follow contours.
	              They stop at the settlement radius or at water. Heights are smoothed.
	3. SIDE STREETS (Village and Town tiers) branch off main roads every `branchEvery` studs,
	              alternating sides, contour-following the same way, stopping near other roads.
	4. BUILDINGS  a seeded list: the tier's fixed buildings, then weighted picks (tier weights +
	              the culture's trade) up to a count in the tier's range, sorted plaza-outward
	              (SettlementStyles.ring). The first plaza feature (well or shrine) stands in the
	              plaza centre.
	5. LOTS       every street side is a frontage with a cursor. Each building goes on the
	              frontage whose next spot is nearest the plaza, set back 2-4 studs from the
	              street edge, facing it. A spot is rejected (and the cursor nudged on) when the
	              lot leaves the radius, touches the plaza, another lot or any road (inter-
	              settlement roads included), stands in water, or its ground varies more than the
	              tier's flatTolerance. Buildings that find no spot are reported as failures.
	6. TERRAIN OPS  plaza and streets paved (terrain material at the smoothed height, air cleared
	              above), every lot levelled to its average height, then every lot's voxel-snapped
	              foundation, yard apron and downhill steps (FoundationBuilder) last. Applied by
	              WorldStateService when the chunks they touch are built, each op clipped to the
	              chunk being built (c = true), so build order never matters (generated, never saved).
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)

local C = require(script.Parent.WorldConfig)
local Biomes = require(script.Parent.Biomes)
local Styles = require(script.Parent.SettlementStyles)
local FoundationBuilder = require(script.Parent.FoundationBuilder)

local STEP = 10
local TURN = math.rad(14)
local SETBACK = { 2, 4 }
local LOT_GAP = 3
local LOT_MARGIN = 1.5
local MIN_DRY = 2
local ATTEMPTS_PER_FRONTAGE = 6
local NUDGE = 4

export type Road = { kind: string, width: number, material: string, points: { Vector3 } }
export type Lot = {
	id: string,
	index: number,
	type: string,
	cframe: CFrame, -- ground level, lot centre; LookVector = the street the front faces
	w: number,
	d: number,
	level: number,
	low: number, -- lowest ground sample under the lot (FoundationBuilder steps the downhill side)
	seed: number,
}
export type Failure = { type: string, reason: string, x: number, z: number }
-- c = true: clip to the chunk being built (every generated op; see TerrainBuilder.applyOp).
export type Op = { i: string, k: string, m: string, x: number, y: number, z: number, sx: number, sy: number, sz: number, t: number, c: boolean? }
type Frontage = { road: Road, side: number, cursor: number, length: number }

export type Layout = {
	id: string,
	name: string,
	culture: string,
	size: string,
	tier: Styles.Tier,
	center: Vector3,
	plaza: number,
	roads: { Road },
	lots: { Lot },
	failures: { Failure },
	wanted: number,
	ops: { Op },
}

local SettlementLayout = {}

-- ─── Geometry helpers ───────────────────────────────────────────────────────

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

-- Oriented rectangle (centre, right axis, forward axis, half sizes) for the separating-axis test.
type Rect = { c: Vector3, r: Vector3, f: Vector3, hw: number, hd: number }

local function rectOf(cframe: CFrame, w: number, d: number, margin: number): Rect
	return { c = flat(cframe.Position), r = flat(cframe.RightVector).Unit, f = flat(cframe.LookVector).Unit, hw = w / 2 + margin, hd = d / 2 + margin }
end

local function projectRadius(rect: Rect, axis: Vector3): number
	return math.abs(rect.r:Dot(axis)) * rect.hw + math.abs(rect.f:Dot(axis)) * rect.hd
end

local function rectsOverlap(a: Rect, b: Rect): boolean
	local delta = b.c - a.c
	for _, axis in { a.r, a.f, b.r, b.f } do
		if math.abs(delta:Dot(axis)) > projectRadius(a, axis) + projectRadius(b, axis) then
			return false
		end
	end
	return true
end

-- Point at arclength `s` along a polyline, with its unit tangent (flat).
local function along(points: { Vector3 }, s: number): (Vector3?, Vector3?)
	local remaining = s
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local seg = flat(b - a)
		local length = seg.Magnitude
		if length > 0 and remaining <= length then
			local t = remaining / length
			return a:Lerp(b, t), seg.Unit
		end
		remaining -= length
	end
	return nil, nil
end

local function lengthOf(points: { Vector3 }): number
	local total = 0
	for i = 1, #points - 1 do
		total += flat(points[i + 1] - points[i]).Magnitude
	end
	return total
end

-- ─── Roads ──────────────────────────────────────────────────────────────────

local function smooth(points: { Vector3 }, passes: number)
	for _ = 1, passes do
		local heights = {}
		for i, p in points do
			local prev = points[math.max(1, i - 1)]
			local nextP = points[math.min(#points, i + 1)]
			heights[i] = (prev.Y + p.Y * 2 + nextP.Y) / 4
		end
		for i, p in points do
			if i > 1 then -- the first point keeps its join height (plaza or parent road)
				points[i] = Vector3.new(p.X, heights[i], p.Z)
			end
		end
	end
end

-- Walks outward from `start` along `heading`, following contours. Stops at the radius, water,
-- maxLength, or (with `avoid`) near another road.
local function walk(gen: any, center: Vector3, start: Vector3, heading: number, radius: number, maxLength: number, avoid: ((Vector3) -> boolean)?): { Vector3 }
	local points = { start }
	local base = heading
	local current = start
	local travelled = 0
	while travelled < maxLength do
		local best, bestCost, bestHeading = nil :: Vector3?, math.huge, heading
		for _, turn in { 0, -TURN, TURN } do
			local h = heading + turn
			local nx, nz = current.X + math.cos(h) * STEP, current.Z + math.sin(h) * STEP
			local y = gen:height(nx, nz)
			-- Climb as little as possible, but don't wander far from the intended bearing.
			local cost = math.abs(y - current.Y) + math.abs(h - base) * 3
			if cost < bestCost then
				best, bestCost, bestHeading = Vector3.new(nx, y, nz), cost, h
			end
		end
		local nextPoint = best :: Vector3
		if nextPoint.Y < C.SEA_LEVEL + MIN_DRY or flat(nextPoint - center).Magnitude > radius then
			break
		end
		if avoid and #points > 2 and avoid(nextPoint) then
			break
		end
		table.insert(points, nextPoint)
		current, heading = nextPoint, bestHeading
		travelled += STEP
	end
	return points
end

-- ─── Building list ──────────────────────────────────────────────────────────

local function buildingList(rng: Random, size: string, culture: Styles.Culture, tier: Styles.Tier): { string }
	local mix = Styles.mix[size]
	local count = rng:NextInteger(tier.buildings[1], tier.buildings[2])
	local list = table.clone(mix.always)
	local weights: { [string]: number } = table.clone(mix.weights)
	for kind, w in culture.extra do
		-- Hamlets don't get schools, taverns or towers just because the culture likes them.
		if size ~= "village" or (kind ~= "magic_school" and kind ~= "tavern" and kind ~= "watchtower") then
			weights[kind] = (weights[kind] or 0) + w
		end
	end
	local kinds = {}
	local total = 0
	for kind, w in weights do
		table.insert(kinds, kind)
		total += w
	end
	table.sort(kinds)
	while #list < count do
		local roll = rng:NextNumber() * total
		local pick = kinds[#kinds]
		for _, kind in kinds do
			roll -= weights[kind]
			if roll <= 0 then
				pick = kind
				break
			end
		end
		table.insert(list, pick)
	end
	-- Plaza-outward, stable for equal rings.
	local order = {}
	for i, kind in list do
		order[i] = { kind = kind, i = i }
	end
	table.sort(order, function(a, b)
		local ra, rb = Styles.ring[a.kind] or 5, Styles.ring[b.kind] or 5
		if ra ~= rb then
			return ra < rb
		end
		return a.i < b.i
	end)
	local out = {}
	for i, entry in order do
		out[i] = entry.kind
	end
	return out
end

-- ─── Generate ───────────────────────────────────────────────────────────────

--[[
	settlement   Settlements.Settlement (id, name, culture, size, x, z)
	gen          WorldGen (height, sample)
	highways     inter-settlement roads (TerrainBuilder.Road) touching this settlement
	yieldFn      Scheduler.checkpoint when run inside a job
]]
function SettlementLayout.generate(settlement: any, gen: any, worldSeed: number, highways: { any }, yieldFn: (() -> ())?): Layout
	local rng = Seed.random(worldSeed, settlement.id, "settlement.layout")
	local tier = Styles.tiers[settlement.size] or Styles.tiers.village
	local culture = Styles.cultures[settlement.culture] or Styles.cultures.wayfarer
	local cx, cz = settlement.x, settlement.z
	local yieldNow = yieldFn or function() end

	-- 1. Plaza level: the mean ground height over the plaza.
	local sum, count = 0, 0
	for dz = -tier.plaza, tier.plaza, tier.plaza / 2 do
		for dx = -tier.plaza, tier.plaza, tier.plaza / 2 do
			sum += gen:height(cx + dx, cz + dz)
			count += 1
		end
	end
	local plazaY = math.max(C.SEA_LEVEL + MIN_DRY, math.floor(sum / count * 2 + 0.5) / 2)
	local center = Vector3.new(cx, plazaY, cz)

	-- 2. Main road bearings: toward neighbours first, then spread out.
	local bearings: { number } = {}
	local function separation(angle: number): number
		local best = math.huge
		for _, b in bearings do
			local d = math.abs((angle - b + math.pi) % (2 * math.pi) - math.pi)
			best = math.min(best, d)
		end
		return best
	end
	for _, road in highways do
		local ox, oz = if math.abs(road.ax - cx) < 1 and math.abs(road.az - cz) < 1 then road.bx else road.ax, if math.abs(road.ax - cx) < 1 and math.abs(road.az - cz) < 1 then road.bz else road.az
		local angle = math.atan2(oz - cz, ox - cx)
		if separation(angle) > math.rad(40) then
			table.insert(bearings, angle)
		end
	end
	local wantRoads = math.max(rng:NextInteger(tier.mainRoads[1], tier.mainRoads[2]), math.min(#bearings, 6))
	while #bearings < wantRoads do
		local bestAngle, bestSep = 0, -1
		for _ = 1, 12 do
			local a = rng:NextNumber() * 2 * math.pi
			local sep = separation(a)
			if sep > bestSep then
				bestAngle, bestSep = a, sep
			end
		end
		table.insert(bearings, bestAngle)
	end

	local roads: { Road } = {}
	for _, angle in bearings do
		local start = Vector3.new(cx + math.cos(angle) * (tier.plaza + 1), plazaY, cz + math.sin(angle) * (tier.plaza + 1))
		local points = walk(gen, center, start, angle, tier.radius, tier.radius, nil)
		if #points >= 2 then
			smooth(points, 2)
			table.insert(roads, { kind = "main", width = tier.roadWidth, material = culture.street, points = points })
		end
		yieldNow()
	end

	-- Highways count as roads for lot placement (TerrainBuilder already paints them).
	local blockers: { Road } = table.clone(roads)
	for _, road in highways do
		local a, b = Vector3.new(road.ax, 0, road.az), Vector3.new(road.bx, 0, road.bz)
		local length = (b - a).Magnitude
		local points = {}
		for s = 0, length, 8 do
			local p = a:Lerp(b, s / math.max(length, 1))
			if flat(p - center).Magnitude <= tier.radius + 20 then
				table.insert(points, p)
			end
		end
		if #points > 0 then
			table.insert(blockers, { kind = "highway", width = road.width * 2, material = "", points = points })
		end
	end

	local function nearRoad(p: Vector3, ignore: Road?, clearance: number): boolean
		for _, road in blockers do
			if road ~= ignore then
				for _, q in road.points do
					if flat(q - p).Magnitude < road.width / 2 + clearance then
						return true
					end
				end
			end
		end
		return false
	end

	-- 3. Side streets.
	if tier.branchEvery > 0 then
		for _, main in table.clone(roads) do
			local total = lengthOf(main.points)
			local side = if rng:NextNumber() < 0.5 then 1 else -1
			local s = tier.branchEvery
			while s < total - 16 do
				local p, tangent = along(main.points, s)
				if p and tangent then
					local base = math.atan2(tangent.Z, tangent.X) + side * math.pi / 2
					local start = p + Vector3.new(math.cos(base), 0, math.sin(base)) * (main.width / 2 + 1)
					start = Vector3.new(start.X, p.Y, start.Z)
					local length = rng:NextNumber(tier.branchLength[1], tier.branchLength[2])
					local points = walk(gen, center, start, base, tier.radius, length, function(q)
						return nearRoad(q, main, 10)
					end)
					if #points >= 3 then
						smooth(points, 2)
						local street: Road = { kind = "street", width = tier.streetWidth, material = culture.street, points = points }
						table.insert(roads, street)
						table.insert(blockers, street)
					end
				end
				side = -side
				s += tier.branchEvery
			end
			yieldNow()
		end
	end

	-- 4. What to build.
	local list = buildingList(rng, settlement.size, culture, tier)

	-- 5. Lots.
	local lots: { Lot } = {}
	local rects: { Rect } = {}
	local failures: { Failure } = {}
	local plazaRect: Rect = { c = flat(center), r = Vector3.xAxis, f = Vector3.zAxis, hw = tier.plaza + 1, hd = tier.plaza + 1 }

	local function addLot(kind: string, cframe: CFrame, w: number, d: number, level: number, low: number)
		local index = #lots + 1
		local id = string.format("%s_L%02d", settlement.id, index)
		table.insert(lots, { id = id, index = index, type = kind, cframe = cframe, w = w, d = d, level = level, low = math.min(low, level), seed = Seed.derive(worldSeed, id, "building") })
		table.insert(rects, rectOf(cframe, w, d, LOT_MARGIN))
	end

	-- Ground check: nine samples; returns (level, nil, lowest) or (nil, reason).
	local function ground(cframe: CFrame, w: number, d: number): (number?, string?, number?)
		local lo, hi, total = math.huge, -math.huge, 0
		for _, u in { -0.5, 0, 0.5 } do
			for _, v in { -0.5, 0, 0.5 } do
				local p = cframe * Vector3.new(u * w, 0, v * d)
				local h = gen:height(p.X, p.Z)
				if h < C.SEA_LEVEL + MIN_DRY then
					return nil, "in water"
				end
				lo, hi = math.min(lo, h), math.max(hi, h)
				total += h
			end
		end
		if hi - lo > tier.flatTolerance then
			return nil, string.format("too steep (%.0f studs of rise)", hi - lo)
		end
		return math.floor(total / 9 * 4 + 0.5) / 4, nil, lo
	end

	local function check(cframe: CFrame, w: number, d: number): (number?, string?, number?)
		local rect = rectOf(cframe, w, d, 0)
		if flat(cframe.Position - center).Magnitude + math.max(w, d) / 2 > tier.radius then
			return nil, "outside the settlement radius"
		end
		if rectsOverlap(rect, plazaRect) then
			return nil, "touches the plaza"
		end
		local padded = rectOf(cframe, w, d, LOT_MARGIN)
		for _, other in rects do
			if rectsOverlap(padded, other) then
				return nil, "overlaps another lot"
			end
		end
		for _, road in blockers do
			for _, q in road.points do
				local local_ = cframe:PointToObjectSpace(Vector3.new(q.X, cframe.Position.Y, q.Z))
				if math.abs(local_.X) <= w / 2 + road.width / 2 - 0.5 and math.abs(local_.Z) <= d / 2 + road.width / 2 - 0.5 then
					return nil, "on a road"
				end
			end
		end
		return ground(cframe, w, d)
	end

	-- The plaza feature (first well/shrine) stands in the plaza centre, facing the first road.
	local startIndex = 1
	if list[1] == "well" or list[1] == "shrine" then
		local fp = Styles.footprints[list[1]]
		local facing = if roads[1] then flat(roads[1].points[1] - center) else Vector3.new(0, 0, -1)
		local look = if facing.Magnitude > 0.1 then facing.Unit else Vector3.new(0, 0, -1)
		local cframe = CFrame.lookAt(center, center + look)
		addLot(list[1], cframe, fp.w, fp.d, plazaY, plazaY)
		startIndex = 2
	end

	local frontages: { Frontage } = {}
	for _, road in roads do
		for _, side in { 1, -1 } do
			table.insert(frontages, { road = road, side = side, cursor = 2, length = lengthOf(road.points) })
		end
	end

	-- Where a building of footprint w x d would stand at a frontage's cursor (+ extra).
	local function spot(f: Frontage, w: number, d: number, extra: number, setback: number): CFrame?
		local p, tangent = along(f.road.points, f.cursor + extra + w / 2)
		if not p or not tangent then
			return nil
		end
		local normal = Vector3.new(-tangent.Z, 0, tangent.X) * f.side
		local pos = p + normal * (f.road.width / 2 + setback + d / 2)
		pos = Vector3.new(pos.X, 0, pos.Z)
		return CFrame.lookAt(pos, pos - normal) -- the front looks back at the street
	end

	for n = startIndex, #list do
		local kind = list[n]
		local fp = Styles.footprints[kind] or Styles.footprints.house_small
		local setback = rng:NextNumber(SETBACK[1], SETBACK[2])
		-- Frontages ordered by how near the plaza their next spot is.
		local ordered = {}
		for _, f in frontages do
			if f.cursor + fp.w < f.length then
				local cf = spot(f, fp.w, fp.d, 0, setback)
				if cf then
					table.insert(ordered, { f = f, d = flat(cf.Position - center).Magnitude })
				end
			end
		end
		table.sort(ordered, function(a, b)
			return a.d < b.d
		end)
		local placed = false
		local lastReason = "no street frontage left"
		local lastAt = center
		for _, entry in ordered do
			local f = entry.f
			for attempt = 0, ATTEMPTS_PER_FRONTAGE - 1 do
				local cf = spot(f, fp.w, fp.d, attempt * NUDGE, setback)
				if not cf then
					break
				end
				local level, reason, low = check(cf, fp.w, fp.d)
				if level then
					addLot(kind, cf.Rotation + Vector3.new(cf.Position.X, level, cf.Position.Z), fp.w, fp.d, level, low or level)
					f.cursor += attempt * NUDGE + fp.w + LOT_GAP
					placed = true
					break
				end
				lastReason, lastAt = reason or "rejected", cf.Position
			end
			if placed then
				break
			end
			-- Every attempt failed: skip this stretch so later buildings don't retry the same spot.
			f.cursor += ATTEMPTS_PER_FRONTAGE * NUDGE
		end
		if not placed then
			table.insert(failures, { type = kind, reason = lastReason, x = lastAt.X, z = lastAt.Z })
		end
		yieldNow()
	end

	-- 6. Terrain ops: plaza, streets, lots (each levelled to its height), then every lot's
	-- foundation and yard (FoundationBuilder) LAST, so nothing earlier can bury a floor.
	local ops: { Op } = {}
	local function op(kind: string, material: string, x: number, y: number, z: number, sx: number, sy: number, sz: number)
		table.insert(ops, { i = string.format("%s:g%d", settlement.id, #ops + 1), k = kind, m = material, x = x, y = y, z = z, sx = sx, sy = sy, sz = sz, t = 0, c = true })
	end
	local side = tier.plaza * 2 + 2
	op("block", "Air", cx, plazaY + 12, cz, side, 24, side)
	op("block", culture.plaza, cx, plazaY - 4, cz, side, 8, side)
	for _, road in roads do
		-- Square blocks 60% of the width apart overlap into a continuous street, even on curves.
		local spacing = math.max(3, road.width * 0.6)
		local total = lengthOf(road.points)
		local s = 0
		while s <= total do
			local p = along(road.points, s) or road.points[#road.points]
			op("block", "Air", p.X, p.Y + 6, p.Z, road.width, 12, road.width)
			op("block", road.material, p.X, p.Y - 3, p.Z, road.width, 6, road.width)
			s += spacing
		end
	end
	for _, lot in lots do
		local cf = lot.cframe
		local r, l = cf.RightVector, cf.LookVector
		local hx = math.abs(r.X) * lot.w / 2 + math.abs(l.X) * lot.d / 2 + LOT_MARGIN
		local hz = math.abs(r.Z) * lot.w / 2 + math.abs(l.Z) * lot.d / 2 + LOT_MARGIN
		local p = cf.Position
		local biome = Biomes.defs[gen:sample(p.X, p.Z).biome]
		local topMaterial = if biome then biome.materials.top.Name else "Ground"
		op("block", "Air", p.X, lot.level + 15, p.Z, hx * 2, 30, hz * 2)
		op("block", topMaterial, p.X, lot.level - 5, p.Z, hx * 2, 10, hz * 2)
	end
	local foundationLots: { FoundationBuilder.LotInput } = {}
	for i, lot in lots do
		foundationLots[i] = { id = lot.id, cframe = lot.cframe, w = lot.w, d = lot.d, level = lot.level, low = lot.low,
			plazaFeature = i == 1 and startIndex == 2 }
	end
	for _, foundationOp in FoundationBuilder.ops({
		settlementId = settlement.id,
		lots = foundationLots,
		roads = blockers,
		plaza = { center = center, half = tier.plaza + 1 },
		foundation = culture.foundation.material.Name,
		yard = culture.street,
		plazaMaterial = culture.plaza,
		height = function(x, z)
			return gen:height(x, z)
		end,
		startIndex = #ops + 1,
		yieldFn = yieldFn,
	}) do
		table.insert(ops, foundationOp)
	end

	return {
		id = settlement.id,
		name = settlement.name,
		culture = settlement.culture,
		size = settlement.size,
		tier = tier,
		center = center,
		plaza = tier.plaza,
		roads = roads,
		lots = lots,
		failures = failures,
		wanted = #list,
		ops = ops,
	}
end

-- Geometry shared with SettlementDecor (props must avoid the same lots and roads).
SettlementLayout.rectOf = rectOf
SettlementLayout.rectsOverlap = rectsOverlap
SettlementLayout.along = along
SettlementLayout.lengthOf = lengthOf

return SettlementLayout
