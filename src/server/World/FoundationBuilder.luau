--!strict
--[[
	FoundationBuilder: the ground under and around every building. Pure, seeded terrain ops at
	layout time plus a verification pass after a building is built (docs/Settlements.md §5b).

		FoundationBuilder.ops(input) -> { Op }          pure; SettlementLayout appends these last
		FoundationBuilder.verify(model) -> Report        raycasts + voxel read under the floor
		FoundationBuilder.flag(model, report, show)      red markers at failing points (Studio)

	WHY (the grass-through-the-floor bug)
	  Lots were levelled with the biome's TOP material (Grass in most biomes) exactly up to the lot
	  height, and the floor was a 0.4-stud slab whose top sat 1.25 studs above that grass. Grass
	  decoration renders on the terrain surface whatever Parts cover it, so blades poked through.
	  The levelling boxes were also axis-aligned and unsnapped, overlapped neighbouring lots, and
	  were replayed whole by whichever chunk built last, so a neighbour's (higher) level could
	  refill terrain over a floor.

	WHAT IT EMITS, per lot, rasterised into 4-stud voxel columns (snapped OUTWARD to the grid)
	  core   columns touching the lot rectangle (the building sits inside it): air cleared from
	         FOUNDATION_DEPTH below the lot level to CLEAR_ABOVE over it, then solid foundation
	         stone (the culture's foundation material) up to level - FILL_DROP. No grass inside.
	  yard   columns within MARGIN studs of the lot: same heights, the culture's street/yard
	         material, so the building stands on a clean apron instead of turf.
	  steps  on lots whose lowest ground is more than STEP_RISE below the level: up to
	         STEP_RINGS rings of stone terrace, each STEP_RISE lower, only where the original
	         ground is below the step (the downhill side).
	  Yard and step columns skip roads, the plaza (except for the plaza's own feature), the sea,
	  and anything touching another lot's rectangle, so a neighbour's apron can never rise under
	  a floor. Every op is an axis-aligned, voxel-aligned "block" with c = true, so
	  WorldStateService clips it to the chunk being built: each column is only ever written by
	  its own chunk, in layout order, whatever order the chunks build in (no seams, no fights).

	HEIGHTS (lot-local, 0 = the lot level)
	  terrain under the floor   up to -FILL_DROP (-0.25)
	  floor slab                bottom FLOOR_BOTTOM (+0.35), top FLOOR_TOP (+1.55)  (BuildingGenerator)
	  plinth (Foundation part)  from -2 (deeper on slopes) up to +1.5, visible 1.75 studs
]]

local C = require(script.Parent.WorldConfig)

local VOXEL = 4
local MARGIN = 4 -- yard apron around the lot (studs)
local FOUNDATION_DEPTH = 8 -- solid stone below the lot level
local CLEAR_ABOVE = 24 -- air cleared above the lot level (rooms are cleared again per building)
local FILL_DROP = 0.25 -- terrain top below the lot level, under and around the building
local STEP_RISE = 2
local STEP_RINGS = 2
local ROAD_CLEARANCE = 1 -- yard columns stay this far off a road's edge

-- Floor geometry, mirrored from BuildingGenerator (Buildings.spec asserts they agree).
local FLOOR_TOP = 1.55
local FLOOR_BOTTOM = 0.35

local VERIFY_STEP = 2 -- studs between verification rays
local VERIFY_ABOVE = 6 -- rays start this far above the floor top
--[[
	Terrain may sit inside the floor slab (the Part hides it); it only shows when it rises through
	the floor's TOP. Smooth terrain's surface also lands up to ~0.5 stud off the FillBlock target
	(partial voxels), so the line is the floor top + this margin. First play run (2026-11-05):
	terrain tops measured floorTop - 0.8 .. + 0.48 with clean floors in play.
]]
local SHOW_THROUGH = 0.6

-- Terrain-legal, grass-free materials for foundations; anything else falls back to Slate.
-- (Never Granite: that is reserved for temporary magic terrain, Cast.spec checks it.)
local STONE: { [string]: boolean } = {
	Slate = true, Rock = true, Cobblestone = true, Concrete = true, Limestone = true, Sandstone = true,
	Basalt = true, Brick = true, Pavement = true, Asphalt = true,
}
local GRASSY: { [string]: boolean } = { Grass = true, LeafyGrass = true }
local TERRAIN_MATERIALS: { [string]: boolean } = {
	Asphalt = true, Basalt = true, Brick = true, Cobblestone = true, Concrete = true, CrackedLava = true, Glacier = true,
	Ground = true, Ice = true, Limestone = true, Mud = true, Pavement = true, Rock = true, Salt = true, Sand = true,
	Sandstone = true, Slate = true, Snow = true, WoodPlanks = true,
}

export type Op = { i: string, k: string, m: string, x: number, y: number, z: number, sx: number, sy: number, sz: number, t: number, c: boolean? }

export type LotInput = {
	id: string,
	cframe: CFrame,
	w: number,
	d: number,
	level: number,
	low: number, -- lowest ground sample under the lot (stepped foundations below the level)
	plazaFeature: boolean?, -- the well/shrine in the plaza: its yard is plaza paving
}

export type Input = {
	settlementId: string,
	lots: { LotInput },
	roads: { { width: number, points: { Vector3 } } }, -- streets AND highways
	plaza: { center: Vector3, half: number },
	foundation: string, -- culture foundation material name
	yard: string, -- culture street material name
	plazaMaterial: string,
	height: (x: number, z: number) -> number, -- the generated ground height
	startIndex: number, -- op ids continue the layout's numbering
	yieldFn: (() -> ())?,
}

export type Report = {
	ok: boolean,
	checked: boolean, -- false for buildings without an interior (stalls, wells, shrines)
	floorTop: number,
	ground: number, -- the lot level
	terrainTop: number?, -- highest terrain surface found under the footprint
	points: number,
	hits: { Vector3 }, -- rays that met terrain poking up through the floor (above top + SHOW_THROUGH)
	grass: number, -- grass voxels under or in the floor
	lines: { string },
}

local FoundationBuilder = {}

FoundationBuilder.MARGIN = MARGIN
FoundationBuilder.FILL_DROP = FILL_DROP
FoundationBuilder.FLOOR_TOP = FLOOR_TOP
FoundationBuilder.FLOOR_BOTTOM = FLOOR_BOTTOM

local function snapDown(y: number): number
	return math.floor(y / VOXEL) * VOXEL
end

local function snapUp(y: number): number
	return math.ceil(y / VOXEL) * VOXEL
end

function FoundationBuilder.stoneFor(name: string): string
	return if STONE[name] then name else "Slate"
end

function FoundationBuilder.yardFor(name: string): string
	return if TERRAIN_MATERIALS[name] and not GRASSY[name] then name else "Ground"
end

-- ─── Geometry (same separating-axis test as SettlementLayout) ───────────────

type Rect = { c: Vector3, r: Vector3, f: Vector3, hw: number, hd: number }

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function rectOf(cframe: CFrame, w: number, d: number, margin: number): Rect
	return { c = flat(cframe.Position), r = flat(cframe.RightVector).Unit, f = flat(cframe.LookVector).Unit, hw = w / 2 + margin, hd = d / 2 + margin }
end

local function projectRadius(rect: Rect, axis: Vector3): number
	return math.abs(rect.r:Dot(axis)) * rect.hw + math.abs(rect.f:Dot(axis)) * rect.hd
end

local function overlap(a: Rect, b: Rect): boolean
	local delta = b.c - a.c
	for _, axis in { a.r, a.f, b.r, b.f } do
		if math.abs(delta:Dot(axis)) > projectRadius(a, axis) + projectRadius(b, axis) then
			return false
		end
	end
	return true
end

local function contains(rect: Rect, p: Vector3): boolean
	local delta = flat(p) - rect.c
	return math.abs(delta:Dot(rect.r)) <= rect.hw and math.abs(delta:Dot(rect.f)) <= rect.hd
end

local function columnRect(x: number, z: number): Rect
	return { c = Vector3.new(x, 0, z), r = Vector3.xAxis, f = Vector3.zAxis, hw = VOXEL / 2, hd = VOXEL / 2 }
end

-- Half extents of a rect's axis-aligned bounding box.
local function aabb(rect: Rect): (number, number)
	return math.abs(rect.r.X) * rect.hw + math.abs(rect.f.X) * rect.hd, math.abs(rect.r.Z) * rect.hw + math.abs(rect.f.Z) * rect.hd
end

local function segmentDistance(p: Vector3, a: Vector3, b: Vector3): number
	local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local ap = Vector3.new(p.X - a.X, 0, p.Z - a.Z)
	local lengthSq = ab:Dot(ab)
	local t = if lengthSq > 0 then math.clamp(ap:Dot(ab) / lengthSq, 0, 1) else 0
	return (ap - ab * t).Magnitude
end

type RoadBox = { width: number, points: { Vector3 }, x0: number, z0: number, x1: number, z1: number }

local function roadBoxes(roads: { { width: number, points: { Vector3 } } }): { RoadBox }
	local out: { RoadBox } = {}
	for _, road in roads do
		local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
		for _, p in road.points do
			x0, z0, x1, z1 = math.min(x0, p.X), math.min(z0, p.Z), math.max(x1, p.X), math.max(z1, p.Z)
		end
		local pad = road.width / 2 + ROAD_CLEARANCE
		if #road.points > 0 then
			table.insert(out, { width = road.width, points = road.points, x0 = x0 - pad, z0 = z0 - pad, x1 = x1 + pad, z1 = z1 + pad })
		end
	end
	return out
end

local function onRoad(p: Vector3, roads: { RoadBox }): boolean
	for _, road in roads do
		local pts = road.points
		local reach = road.width / 2 + ROAD_CLEARANCE
		if #pts == 1 then
			if segmentDistance(p, pts[1], pts[1]) < reach then
				return true
			end
		else
			for i = 1, #pts - 1 do
				if segmentDistance(p, pts[i], pts[i + 1]) < reach then
					return true
				end
			end
		end
	end
	return false
end

-- ─── Ops ────────────────────────────────────────────────────────────────────

-- Column classes. Steps are STEP_BASE + ring number.
local CORE, YARD, STEP_BASE = 1, 2, 10

function FoundationBuilder.ops(input: Input): { Op }
	local ops: { Op } = {}
	local yieldNow = input.yieldFn or function() end
	local roads = roadBoxes(input.roads)
	local stone = FoundationBuilder.stoneFor(input.foundation)
	local yard = FoundationBuilder.yardFor(input.yard)
	local plazaYard = FoundationBuilder.yardFor(input.plazaMaterial)
	local plazaRect: Rect = { c = flat(input.plaza.center), r = Vector3.xAxis, f = Vector3.zAxis, hw = input.plaza.half, hd = input.plaza.half }
	local lotRects: { Rect } = {}
	for i, lot in input.lots do
		lotRects[i] = rectOf(lot.cframe, lot.w, lot.d, 0)
	end
	local nextIndex = input.startIndex

	local function emit(material: string, x0: number, x1: number, z: number, y0: number, y1: number)
		if y1 - y0 <= 0 then
			return
		end
		table.insert(ops, {
			i = string.format("%s:g%d", input.settlementId, nextIndex), k = "block", m = material,
			x = (x0 + x1) / 2, y = (y0 + y1) / 2, z = z, sx = x1 - x0, sy = y1 - y0, sz = VOXEL, t = 0, c = true,
		})
		nextIndex += 1
	end

	for index, lot in input.lots do
		local level = lot.level
		local fillTop = level - FILL_DROP
		local bottom = snapDown(level - FOUNDATION_DEPTH)
		local clearTop = snapUp(level + CLEAR_ABOVE)
		local own = lotRects[index]
		local apron = rectOf(lot.cframe, lot.w, lot.d, MARGIN)
		local stepped = level - lot.low > STEP_RISE
		local rings = if stepped then STEP_RINGS else 0
		local outer = rectOf(lot.cframe, lot.w, lot.d, MARGIN + rings * VOXEL)
		local hx, hz = aabb(outer)
		local p = flat(lot.cframe.Position)
		local i0, i1 = math.floor((p.X - hx) / VOXEL), math.floor((p.X + hx) / VOXEL)
		local k0, k1 = math.floor((p.Z - hz) / VOXEL), math.floor((p.Z + hz) / VOXEL)
		local ringRects: { Rect } = {}
		for n = 1, rings do
			ringRects[n] = rectOf(lot.cframe, lot.w, lot.d, MARGIN + n * VOXEL)
		end
		-- Roads near this lot only (keeps the per-column test cheap in big towns).
		local near: { RoadBox } = {}
		for _, road in roads do
			if road.x1 >= p.X - hx and road.x0 <= p.X + hx and road.z1 >= p.Z - hz and road.z0 <= p.Z + hz then
				table.insert(near, road)
			end
		end

		for k = k0, k1 do
			local z = (k + 0.5) * VOXEL
			-- Classify every column of the row: class, plus the ground height for steps.
			local classes: { [number]: number } = {}
			local grounds: { [number]: number } = {}
			for i = i0, i1 do
				local x = (i + 0.5) * VOXEL
				local col = columnRect(x, z)
				local centre = Vector3.new(x, 0, z)
				local class = 0
				if overlap(col, own) then
					class = CORE
				elseif overlap(col, apron) then
					class = YARD
				else
					for n = 1, rings do
						if overlap(col, ringRects[n]) then
							class = STEP_BASE + n
							break
						end
					end
				end
				if class ~= 0 then
					-- Never touch another lot: core yields only to a lot that owns the centre,
					-- aprons and steps keep off every other lot entirely.
					for j, other in lotRects do
						if j ~= index and (if class == CORE then contains(other, centre) else overlap(col, other)) then
							class = 0
							break
						end
					end
				end
				if class ~= 0 and class ~= CORE then
					if (not lot.plazaFeature and overlap(col, plazaRect)) or onRoad(centre, near) then
						class = 0
					else
						local h = input.height(x, z)
						grounds[i] = h
						-- No aprons into the sea; steps only where the ground falls away below them.
						local wet = h < C.SEA_LEVEL + 0.5
						local notDownhill = class > STEP_BASE and h >= fillTop - (class - STEP_BASE) * STEP_RISE - 0.5
						if wet or notDownhill then
							class = 0
						end
					end
				end
				classes[i] = class
			end

			-- Air first (core and yard), then fills, as runs of equal class along X.
			local i = i0
			while i <= i1 do
				local class = classes[i]
				if class == CORE or class == YARD then
					local j = i
					while j + 1 <= i1 and (classes[j + 1] == CORE or classes[j + 1] == YARD) do
						j += 1
					end
					emit("Air", i * VOXEL, (j + 1) * VOXEL, z, bottom, clearTop)
					i = j + 1
				else
					i += 1
				end
			end
			i = i0
			while i <= i1 do
				local class = classes[i]
				if class ~= 0 then
					local j = i
					local lowest = grounds[i] or level
					while j + 1 <= i1 and classes[j + 1] == class do
						j += 1
						lowest = math.min(lowest, grounds[j] or level)
					end
					if class == CORE then
						emit(stone, i * VOXEL, (j + 1) * VOXEL, z, bottom, fillTop)
					elseif class == YARD then
						emit(if lot.plazaFeature then plazaYard else yard, i * VOXEL, (j + 1) * VOXEL, z, bottom, fillTop)
					else
						local stepTop = fillTop - (class - STEP_BASE) * STEP_RISE
						emit(stone, i * VOXEL, (j + 1) * VOXEL, z, snapDown(lowest - VOXEL), stepTop)
					end
					i = j + 1
				else
					i += 1
				end
			end
		end
		yieldNow()
	end
	return ops
end

-- ─── Verification ───────────────────────────────────────────────────────────

local function terrainOnly(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	return params
end

--[[
	After a building is built: for a grid of points over the interior footprint (every 2 studs),
	cast a terrain-only ray from VERIFY_ABOVE over the floor down past the floor's bottom. Terrain
	more than SHOW_THROUGH above the floor TOP fails (it pokes up through the floor; terrain inside
	the slab is hidden by it). Then read the
	voxels in a band around the floor: any grass there fails (blades render through Parts).
	Parts never block these rays, so furniture can't hide a problem.
]]
function FoundationBuilder.verify(model: Model): Report
	local cf = model:GetAttribute("InteriorCFrame")
	local size = model:GetAttribute("InteriorSize")
	local lotCf = model:GetAttribute("LotCFrame")
	local ground = if typeof(lotCf) == "CFrame" then lotCf.Position.Y else 0
	local report: Report = { ok = true, checked = false, floorTop = ground + FLOOR_TOP, ground = ground, terrainTop = nil, points = 0, hits = {}, grass = 0, lines = {} }
	if typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
		table.insert(report.lines, "· no interior to check (an open structure)")
		return report
	end
	report.checked = true
	local floor = model:FindFirstChild("Floor")
	local floorTop = cf.Position.Y - size.Y / 2 - 0.1
	local floorBottom = floorTop - (FLOOR_TOP - FLOOR_BOTTOM)
	if floor and floor:IsA("BasePart") then
		floorTop = floor.Position.Y + floor.Size.Y / 2
		floorBottom = floor.Position.Y - floor.Size.Y / 2
	end
	report.floorTop = floorTop

	local params = terrainOnly()
	local floorFrame = CFrame.new(cf.Position.X, floorTop, cf.Position.Z) * cf.Rotation
	local hx, hz = size.X / 2 - 0.25, size.Z / 2 - 0.25
	local x = -hx
	while x <= hx + 1e-3 do
		local z = -hz
		while z <= hz + 1e-3 do
			local origin = (floorFrame * CFrame.new(x, VERIFY_ABOVE, z)).Position
			local hit = workspace:Raycast(origin, Vector3.new(0, -(VERIFY_ABOVE + 6), 0), params)
			report.points += 1
			if hit then
				local top = hit.Position.Y
				report.terrainTop = math.max(report.terrainTop or -math.huge, top)
				if top > floorTop + SHOW_THROUGH then
					table.insert(report.hits, hit.Position)
				end
			end
			z += VERIFY_STEP
		end
		x += VERIFY_STEP
	end

	-- Grass voxels in the band [floorBottom - 4, floorTop + 4] under the footprint's AABB.
	local corners = { Vector3.new(-hx, 0, -hz), Vector3.new(hx, 0, -hz), Vector3.new(-hx, 0, hz), Vector3.new(hx, 0, hz) }
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for _, corner in corners do
		local w = floorFrame * corner
		x0, z0, x1, z1 = math.min(x0, w.X), math.min(z0, w.Z), math.max(x1, w.X), math.max(z1, w.Z)
	end
	local region = Region3.new(Vector3.new(x0, floorBottom - 4, z0), Vector3.new(x1, floorTop + 4, z1)):ExpandToGrid(VOXEL)
	local ok, materials, occupancy = pcall(function()
		return workspace.Terrain:ReadVoxels(region, VOXEL)
	end)
	if ok then
		local min = region.CFrame.Position - region.Size / 2
		-- ReadVoxels' arrays carry a `Size` (Vector3) field next to the numeric indices, so walk
		-- them by index; a generic `for … in` would reach `Size` and try to iterate a Vector3.
		local dims: Vector3 = (materials :: any).Size
		for xi = 1, dims.X do
			local slabX = materials[xi]
			for yi = 1, dims.Y do
				local row = slabX[yi]
				for zi = 1, dims.Z do
					local material = row[zi]
					if (material == Enum.Material.Grass or material == Enum.Material.LeafyGrass) and occupancy[xi][yi][zi] > 0.05 then
						-- Only voxels whose centre lies under the actual (rotated) footprint count.
						local centre = min + Vector3.new((xi - 0.5) * VOXEL, (yi - 0.5) * VOXEL, (zi - 0.5) * VOXEL)
						local l = floorFrame:PointToObjectSpace(Vector3.new(centre.X, floorTop, centre.Z))
						if math.abs(l.X) <= hx + VOXEL / 2 and math.abs(l.Z) <= hz + VOXEL / 2 then
							report.grass += 1
						end
					end
				end
			end
		end
	end

	report.ok = #report.hits == 0 and report.grass == 0
	local terrainText = if report.terrainTop then string.format("%.2f (%.2f below the floor top)", report.terrainTop, floorTop - report.terrainTop) else "none found"
	table.insert(report.lines, string.format("%s floor top %.2f, lot ground %.2f (+%.2f), floor bottom %.2f", if report.ok then "✓" else "✗", floorTop, ground, floorTop - ground, floorBottom))
	table.insert(report.lines, string.format("%s terrain under the footprint: top %s", if #report.hits == 0 then "✓" else "✗", terrainText))
	table.insert(report.lines, string.format("%s %d of %d rays met terrain poking through the floor", if #report.hits == 0 then "✓" else "✗", #report.hits, report.points))
	table.insert(report.lines, string.format("%s %d grass voxel(s) under or in the floor", if report.grass == 0 then "✓" else "✗", report.grass))
	return report
end

-- Red markers where verification failed (one folder per building, replaced on every check).
function FoundationBuilder.flag(model: Model, report: Report, show: boolean)
	local root = workspace:FindFirstChild("FoundationFlags")
	local key = tostring(model:GetAttribute("LotId") or model.Name)
	local existing = root and root:FindFirstChild(key)
	if existing then
		existing:Destroy()
	end
	if not show or (#report.hits == 0 and report.grass == 0) then
		return
	end
	if not root then
		local folder = Instance.new("Folder")
		folder.Name = "FoundationFlags"
		folder.Parent = workspace
		root = folder
	end
	local folder = Instance.new("Folder")
	folder.Name = key
	local function marker(at: Vector3, size: Vector3)
		local p = Instance.new("Part")
		p.Name = "FoundationFail"
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Material = Enum.Material.Neon
		p.Color = Color3.fromRGB(255, 40, 40)
		p.Transparency = 0.2
		p.Size = size
		p.Position = at
		p.Parent = folder
	end
	for n, at in report.hits do
		if n > 40 then
			break
		end
		marker(at + Vector3.new(0, 0.6, 0), Vector3.new(0.5, 1.2, 0.5))
	end
	if report.grass > 0 then
		local cf = model:GetAttribute("InteriorCFrame")
		if typeof(cf) == "CFrame" then
			marker(Vector3.new(cf.Position.X, report.floorTop + 9, cf.Position.Z), Vector3.new(1.5, 1.5, 1.5)) -- a beacon: grass under this floor
		end
	end
	folder.Parent = root
end

return FoundationBuilder
