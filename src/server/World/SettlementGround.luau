--!strict
--[[
	SettlementGround: Step 2 of the town ground fix, believable ground instead of wall-to-wall grass
	(docs/Settlements.md §5c).

		SettlementGround.plan(layout, gen, worldSeed, highways?) -> Plan     pure, seeded
		SettlementGround.zoneAt(plan, x, z) -> (zone, blend)                0 none, 1 core, 2 inner, 3 outer
		SettlementGround.inPatch(plan, x, z) -> Patch?                       a deliberate grass patch
		SettlementGround.context(plan, x0, z0, x1, z1) -> Context            per-tile prefilter
		SettlementGround.materialAt(plan, ctx, x, z) -> (Material?, mode)    what a column's surface becomes
		SettlementGround.paint(plan, clip, gen, yieldFn)                     runtime: rewrite surface voxels

	THE MASK (Seed.random / Noise layers from (worldSeed, settlementId, "settlement.ground"))
	  Three rings around the plaza, their radii wobbled ±15% by seeded noise so edges aren't circles:
	    core   max(plaza + 10, 0.36 R)   paved: the culture's plaza material, blended with its street
	                                     material and packed earth; wealthy streets (near a magic school
	                                     or a large house) in limestone or brick
	    inner  0.8 R                     packed earth with worn patches, about a third left as grass
	    outer  R + 24                    back to the biome: dirt patches thinning out with distance
	  Materials follow the biome's top: grassy -> Ground/Mud, sand -> Sand/Sandstone, snow ->
	  Ground/Slate in the core only (snow stays elsewhere), mud -> Mud/Ground.

	WHAT IS LEFT ALONE  roads (their own paint), the plaza, every lot's foundation and yard apron
	  (FoundationBuilder), water, and any non-natural surface. The core may replace natural ground
	  (grass, leafy grass, ground, mud, sand, snow); the inner and outer rings only replace grass.

	WHAT IS ADDED
	  road shoulders   1.5-4.5 studs of worn earth beside every street, the width wandering by noise
	  desire paths     from houses, taverns, smithies and barns to the nearest well, stall or shrine
	                   (or the plaza), 3-4.5 studs wide, crossing open ground only
	  grass patches    deliberate, sized and placed, and always grass (forced): a village green by the
	                   plaza, kitchen gardens behind some houses, orchards in the outer ring (farming
	                   cultures). Only in grassy biomes. SettlementDecor fences them and plants them.
	  frontPaths       house lots in the core and inner ring that get flagstones to the street
	                   (BuildingGenerator lays them from the door steps).

	PAINTING (WorldStateService runs it inside the chunk job, after the generated ops and before
	  saved edits; each call is clipped to the chunk being built, so neighbours never fight)
	  Per 128-stud tile: decide every column first (pure, may yield), then read the surface band once
	  (ReadVoxels), swap the top solid voxel (and the one under it) where allowed, and write it back
	  (WriteVoxels) only if something changed. Occupancy is never touched: heights stay exactly as
	  the ops left them. Grass decoration only grows on Grass, so the blades go with the material.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)

local C = require(script.Parent.WorldConfig)
local Biomes = require(script.Parent.Biomes)
local Noise = require(script.Parent.Noise)
local Styles = require(script.Parent.SettlementStyles)
local Layout = require(script.Parent.SettlementLayout)
local FoundationBuilder = require(script.Parent.FoundationBuilder)

local M = Enum.Material
local VOXEL = 4
local TILE = 128 -- studs per painting tile (32 x 32 columns)
local BAND_PAD = 8 -- studs above and below the sampled ground the surface may sit
local MAX_BAND = 192 -- studs: the tallest band read in one go
local EDGE_WOBBLE = 0.15
local OUTER_EXTRA = 24
local WEALTH_REACH = 10
local PATH_REACH = 80

-- How far a column may be rewritten.
local NATURAL, GRASS_ONLY = 1, 2

local NATURAL_TOPS: { [Enum.Material]: boolean } = {
	[M.Grass] = true, [M.LeafyGrass] = true, [M.Ground] = true, [M.Mud] = true, [M.Sand] = true, [M.Snow] = true,
}
local GRASS_TOPS: { [Enum.Material]: boolean } = { [M.Grass] = true, [M.LeafyGrass] = true }

local GARDEN_CHANCE: { [string]: number } = { verdant = 0.65, wayfarer = 0.45, frostfolk = 0.3, tidecall = 0.3, forgehold = 0.2, emberclan = 0.15, skywarden = 0.25, loreseat = 0.3 }
local ORCHARDS: { [string]: number } = { verdant = 2, wayfarer = 1, frostfolk = 1 }
local GREEN_CHANCE: { [string]: number } = { village = 0.5, town = 1, city = 1 }
local FRONT_PATH_CHANCE = 0.75
local WET_BIOMES: { [string]: boolean } = { swamp = true, deep_forest = true, tidal_flats = true }
local WEALTHY_KINDS: { [string]: boolean } = { magic_school = true, house_large = true }
local PATH_FROM: { [string]: boolean } = { house_small = true, house_medium = true, house_large = true, tavern = true, smithy = true, barn = true }
local PATH_TO: { [string]: boolean } = { well = true, market_stall = true, shrine = true }

type Rect = { c: Vector3, r: Vector3, f: Vector3, hw: number, hd: number }

export type Patch = { id: string, kind: string, cframe: CFrame, w: number, d: number, rect: Rect }
export type RoadLine = { width: number, points: { Vector3 }, x0: number, z0: number, x1: number, z1: number }
export type Path = { a: Vector3, b: Vector3, half: number }

export type Plan = {
	id: string,
	culture: string,
	biome: string,
	center: Vector3,
	plaza: number,
	coreR: number,
	innerR: number,
	outerR: number,
	x0: number, -- the mask's bounding box (wobble included)
	z0: number,
	x1: number,
	z1: number,
	grassy: boolean,
	wet: boolean,
	dirtStreets: boolean, -- the culture's streets are packed earth or sand (cart tracks, puddles)
	materials: { pave: Enum.Material, street: Enum.Material, earth: Enum.Material, worn: Enum.Material, wealth: Enum.Material, grass: Enum.Material },
	layers: { edge: Noise.Layer, patch: Noise.Layer, fine: Noise.Layer, shoulder: Noise.Layer },
	aprons: { Rect },
	wealthy: { Rect },
	roads: { RoadLine },
	paths: { Path },
	patches: { Patch },
	frontPaths: { [string]: boolean },
}

export type Context = { aprons: { Rect }, wealthy: { Rect }, roads: { RoadLine }, paths: { Path }, patches: { Patch } }

local SettlementGround = {}
SettlementGround.NATURAL = NATURAL
SettlementGround.GRASS_ONLY = GRASS_ONLY

-- ─── Geometry ───────────────────────────────────────────────────────────────

local function flat(v: Vector3): Vector3
	return Vector3.new(v.X, 0, v.Z)
end

local function contains(rect: Rect, p: Vector3): boolean
	local delta = flat(p) - rect.c
	return math.abs(delta:Dot(rect.r)) <= rect.hw and math.abs(delta:Dot(rect.f)) <= rect.hd
end

local function columnRect(x: number, z: number): Rect
	return { c = Vector3.new(x, 0, z), r = Vector3.xAxis, f = Vector3.zAxis, hw = VOXEL / 2, hd = VOXEL / 2 }
end

local function boxRect(x0: number, z0: number, x1: number, z1: number): Rect
	return { c = Vector3.new((x0 + x1) / 2, 0, (z0 + z1) / 2), r = Vector3.xAxis, f = Vector3.zAxis, hw = (x1 - x0) / 2, hd = (z1 - z0) / 2 }
end

local function segmentDistance(p: Vector3, a: Vector3, b: Vector3): number
	local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
	local ap = Vector3.new(p.X - a.X, 0, p.Z - a.Z)
	local lengthSq = ab:Dot(ab)
	local t = if lengthSq > 0 then math.clamp(ap:Dot(ab) / lengthSq, 0, 1) else 0
	return (ap - ab * t).Magnitude
end

local function roadDistance(p: Vector3, road: RoadLine): number
	local pts = road.points
	if #pts == 1 then
		return (flat(p) - flat(pts[1])).Magnitude
	end
	local best = math.huge
	for i = 1, #pts - 1 do
		best = math.min(best, segmentDistance(p, pts[i], pts[i + 1]))
	end
	return best
end

local function roadLine(width: number, points: { Vector3 }): RoadLine?
	if #points == 0 then
		return nil
	end
	local x0, z0, x1, z1 = math.huge, math.huge, -math.huge, -math.huge
	for _, p in points do
		x0, z0, x1, z1 = math.min(x0, p.X), math.min(z0, p.Z), math.max(x1, p.X), math.max(z1, p.Z)
	end
	local pad = width / 2 + 6 -- shoulders included
	return { width = width, points = points, x0 = x0 - pad, z0 = z0 - pad, x1 = x1 + pad, z1 = z1 + pad }
end

local function material(name: string, fallback: Enum.Material): Enum.Material
	local m = (Enum.Material :: any)[name]
	if typeof(m) == "EnumItem" and m ~= M.Granite and m ~= M.Air and m ~= M.Water then
		return m :: Enum.Material
	end
	return fallback
end

-- ─── Plan ───────────────────────────────────────────────────────────────────

--[[
	layout    SettlementLayout.Layout
	gen       WorldGen (height, sample)
	highways  inter-settlement roads touching the settlement ({ ax, az, bx, bz, width }), optional
]]
function SettlementGround.plan(layout: Layout.Layout, gen: any, worldSeed: number, highways: { any }?): Plan
	local seed = Seed.derive(worldSeed, layout.id, "settlement.ground")
	local rng = Seed.random(worldSeed, layout.id, "settlement.ground")
	local culture = Styles.cultures[layout.culture] or Styles.cultures.wayfarer
	local center = layout.center
	local radius = layout.tier.radius
	local biome = gen:sample(center.X, center.Z).biome
	local def = Biomes.defs[biome]
	local top = if def then def.materials.top else M.Grass
	local grassy = top == M.Grass or top == M.LeafyGrass

	-- The palette: paving from the culture, earth from the biome.
	local earth, worn = M.Ground, M.Mud
	if top == M.Sand or top == M.Sandstone then
		earth, worn = M.Sand, M.Sandstone
	elseif top == M.Mud then
		earth, worn = M.Mud, M.Ground
	elseif not grassy then
		earth, worn = M.Ground, M.Slate -- snow, ice, rock and lava lands: frozen or stony earth
	end
	local foundationName = culture.foundation.material.Name
	local wealth = if foundationName == "Limestone" or foundationName == "Sandstone" then M.Limestone else M.Brick
	local materials = {
		pave = material(FoundationBuilder.yardFor(culture.plaza), M.Pavement),
		street = material(FoundationBuilder.yardFor(culture.street), M.Ground),
		earth = earth,
		worn = worn,
		wealth = wealth,
		grass = if grassy then top else M.Grass,
	}

	local coreR = math.max(layout.plaza + 10, radius * 0.36)
	local innerR = radius * 0.8
	local outerR = radius + OUTER_EXTRA
	local reach = outerR * (1 + EDGE_WOBBLE)

	local aprons: { Rect } = {}
	local wealthy: { Rect } = {}
	for _, lot in layout.lots do
		table.insert(aprons, Layout.rectOf(lot.cframe, lot.w, lot.d, FoundationBuilder.MARGIN))
		if WEALTHY_KINDS[lot.type] then
			table.insert(wealthy, Layout.rectOf(lot.cframe, lot.w, lot.d, FoundationBuilder.MARGIN + WEALTH_REACH))
		end
	end
	local roads: { RoadLine } = {}
	for _, road in layout.roads do
		local line = roadLine(road.width, road.points)
		if line then
			table.insert(roads, line)
		end
	end
	for _, road in (highways or {}) :: { any } do
		local line = roadLine(road.width * 2, { Vector3.new(road.ax, 0, road.az), Vector3.new(road.bx, 0, road.bz) })
		if line then
			table.insert(roads, line)
		end
	end

	local plan: Plan = {
		id = layout.id,
		culture = layout.culture,
		biome = biome,
		center = center,
		plaza = layout.plaza,
		coreR = coreR,
		innerR = innerR,
		outerR = outerR,
		x0 = center.X - reach,
		z0 = center.Z - reach,
		x1 = center.X + reach,
		z1 = center.Z + reach,
		grassy = grassy,
		wet = WET_BIOMES[biome] == true,
		dirtStreets = culture.street == "Ground" or culture.street == "Sand" or culture.street == "Mud",
		materials = materials,
		layers = {
			edge = Noise.layer(seed, "edge", { scale = 1 / 55, octaves = 2 }),
			patch = Noise.layer(seed, "patch", { scale = 1 / 16, octaves = 2 }),
			fine = Noise.layer(seed, "fine", { scale = 1 / 6, octaves = 1 }),
			shoulder = Noise.layer(seed, "shoulder", { scale = 1 / 24, octaves = 1 }),
		},
		aprons = aprons,
		wealthy = wealthy,
		roads = roads,
		paths = {},
		patches = {},
		frontPaths = {},
	}

	-- Is this rectangle free for a deliberate patch? (dry, fairly flat, off lots, roads and plaza)
	local plazaRect: Rect = { c = flat(center), r = Vector3.xAxis, f = Vector3.zAxis, hw = layout.plaza + 3, hd = layout.plaza + 3 }
	local function free(rect: Rect, cframe: CFrame, w: number, d: number): boolean
		if Layout.rectsOverlap(rect, plazaRect) then
			return false
		end
		for _, apron in aprons do
			if Layout.rectsOverlap(rect, apron) then
				return false
			end
		end
		for _, patch in plan.patches do
			if Layout.rectsOverlap(rect, patch.rect) then
				return false
			end
		end
		local reachOut = math.max(w, d) / 2
		for _, road in roads do
			if roadDistance(rect.c, road) < road.width / 2 + reachOut + 1.5 then
				-- Close: check the rectangle's edge points properly.
				for _, u in { -0.5, 0, 0.5 } do
					for _, v in { -0.5, 0, 0.5 } do
						if roadDistance(cframe * Vector3.new(u * w, 0, v * d), road) < road.width / 2 + 1.5 then
							return false
						end
					end
				end
			end
		end
		local lo, hi = math.huge, -math.huge
		for _, u in { -0.5, 0, 0.5 } do
			for _, v in { -0.5, 0, 0.5 } do
				local p = cframe * Vector3.new(u * w, 0, v * d)
				local h = gen:height(p.X, p.Z)
				lo, hi = math.min(lo, h), math.max(hi, h)
			end
		end
		return lo > C.SEA_LEVEL + 1 and hi - lo < 4
	end

	local function addPatch(kind: string, cframe: CFrame, w: number, d: number): boolean
		local rect = Layout.rectOf(cframe, w, d, 0)
		if not free(rect, cframe, w, d) then
			return false
		end
		local p = cframe.Position
		local level = gen:height(p.X, p.Z)
		table.insert(plan.patches, {
			id = string.format("%s_P%02d", layout.id, #plan.patches + 1), kind = kind,
			cframe = cframe.Rotation + Vector3.new(p.X, level, p.Z), w = w, d = d, rect = rect,
		})
		return true
	end

	if grassy then
		-- A village green beside the plaza, between its roads.
		if rng:NextNumber() < (GREEN_CHANCE[layout.size] or 0.5) then
			local gw, gd = if layout.size == "village" then 14 else 20, if layout.size == "village" then 10 else 14
			local start = rng:NextNumber() * math.pi * 2
			local placed = false
			for _, distance in { layout.plaza + 4 + gd / 2, layout.plaza + 12 + gd / 2, layout.plaza + 22 + gd / 2 } do
				for step = 0, 11 do
					local a = start + step * math.pi / 6
					local at = center + Vector3.new(math.cos(a), 0, math.sin(a)) * distance
					local cf = CFrame.lookAt(flat(at), flat(center))
					if addPatch("green", cf, gw, gd) then
						placed = true
						break
					end
				end
				if placed then
					break
				end
			end
		end
		-- Kitchen gardens behind some houses.
		for _, lot in layout.lots do
			if string.sub(lot.type, 1, 5) == "house" and rng:NextNumber() < (GARDEN_CHANCE[layout.culture] or 0.3) then
				local gw, gd = math.min(lot.w - 4, 12), 7
				local cf = lot.cframe * CFrame.new(0, 0, lot.d / 2 + FoundationBuilder.MARGIN + 1.5 + gd / 2)
				addPatch("garden", CFrame.new(cf.Position.X, 0, cf.Position.Z) * lot.cframe.Rotation, gw, gd)
			end
		end
		-- Orchards in the outer ring.
		local wantOrchards = ORCHARDS[layout.culture] or 0
		local orchards, tries = 0, 0
		while orchards < wantOrchards and tries < 24 do
			tries += 1
			local a = rng:NextNumber() * math.pi * 2
			local distance = rng:NextNumber(innerR, radius + 8)
			local at = center + Vector3.new(math.cos(a), 0, math.sin(a)) * distance
			local cf = CFrame.lookAt(flat(at), flat(center))
			if addPatch("orchard", cf, 20, 16) then
				orchards += 1
			end
		end
	end

	-- Desire paths: from homes and workplaces to the nearest well, stall or shrine (else the plaza).
	local targets: { Vector3 } = { flat(center) }
	for _, lot in layout.lots do
		if PATH_TO[lot.type] then
			table.insert(targets, flat(lot.cframe * Vector3.new(0, 0, -lot.d / 2 - 1)))
		end
	end
	for _, lot in layout.lots do
		if PATH_FROM[lot.type] then
			local from = flat(lot.cframe * Vector3.new(0, 0, -lot.d / 2 - 1))
			local best, bestD = nil :: Vector3?, PATH_REACH
			for _, target in targets do
				local dist = (target - from).Magnitude
				if dist < bestD and dist > 12 then
					best, bestD = target, dist
				end
			end
			if best then
				table.insert(plan.paths, { a = from, b = best, half = rng:NextNumber(1.5, 2.25) })
			end
		end
	end

	-- Flagstones from the door to the street for most homes near the centre.
	for _, lot in layout.lots do
		if string.sub(lot.type, 1, 5) == "house" then
			local zone = SettlementGround.zoneAt(plan, lot.cframe.Position.X, lot.cframe.Position.Z)
			if (zone == 1 or zone == 2) and rng:NextNumber() < FRONT_PATH_CHANCE then
				plan.frontPaths[lot.id] = true
			end
		end
	end

	return plan
end

-- ─── Queries ────────────────────────────────────────────────────────────────

-- The ring a point falls in (0 = outside the mask) and how far across it (0..1).
function SettlementGround.zoneAt(plan: Plan, x: number, z: number): (number, number)
	local dx, dz = x - plan.center.X, z - plan.center.Z
	local d = math.sqrt(dx * dx + dz * dz)
	local wobble = 1 + EDGE_WOBBLE * math.clamp(Noise.fbm(plan.layers.edge, x, z), -1, 1)
	local core, inner, outer = plan.coreR * wobble, plan.innerR * wobble, plan.outerR * wobble
	if d <= core then
		return 1, d / core
	elseif d <= inner then
		return 2, (d - core) / (inner - core)
	elseif d <= outer then
		return 3, (d - inner) / (outer - inner)
	end
	return 0, 1
end

function SettlementGround.inPatch(plan: Plan, x: number, z: number): Patch?
	local p = Vector3.new(x, 0, z)
	for _, patch in plan.patches do
		if contains(patch.rect, p) then
			return patch
		end
	end
	return nil
end

-- Everything within reach of a tile (x0..x1, z0..z1), so per-column tests stay cheap.
function SettlementGround.context(plan: Plan, x0: number, z0: number, x1: number, z1: number): Context
	local box = boxRect(x0 - 8, z0 - 8, x1 + 8, z1 + 8)
	local ctx: Context = { aprons = {}, wealthy = {}, roads = {}, paths = {}, patches = {} }
	for _, rect in plan.aprons do
		if Layout.rectsOverlap(box, rect) then
			table.insert(ctx.aprons, rect)
		end
	end
	for _, rect in plan.wealthy do
		if Layout.rectsOverlap(box, rect) then
			table.insert(ctx.wealthy, rect)
		end
	end
	for _, patch in plan.patches do
		if Layout.rectsOverlap(box, patch.rect) then
			table.insert(ctx.patches, patch)
		end
	end
	for _, road in plan.roads do
		if road.x1 >= x0 and road.x0 <= x1 and road.z1 >= z0 and road.z0 <= z1 then
			table.insert(ctx.roads, road)
		end
	end
	for _, path in plan.paths do
		local px0, px1 = math.min(path.a.X, path.b.X) - path.half, math.max(path.a.X, path.b.X) + path.half
		local pz0, pz1 = math.min(path.a.Z, path.b.Z) - path.half, math.max(path.a.Z, path.b.Z) + path.half
		if px1 >= x0 and px0 <= x1 and pz1 >= z0 and pz0 <= z1 then
			table.insert(ctx.paths, path)
		end
	end
	return ctx
end

--[[
	What the surface of the column centred at (x, z) should become: (material, mode), or nil to
	leave it. mode NATURAL may replace any natural top; GRASS_ONLY only replaces grass.
]]
function SettlementGround.materialAt(plan: Plan, ctx: Context, x: number, z: number): (Enum.Material?, number)
	local p = Vector3.new(x, 0, z)
	-- Deliberate grass first: gardens, greens and orchards are always grass.
	for _, patch in ctx.patches do
		if contains(patch.rect, p) then
			return plan.materials.grass, NATURAL
		end
	end
	local zone, blend = SettlementGround.zoneAt(plan, x, z)
	if zone == 0 then
		return nil, 0
	end
	-- Foundations and yards belong to FoundationBuilder; the plaza to its paving op.
	local col = columnRect(x, z)
	for _, apron in ctx.aprons do
		if Layout.rectsOverlap(col, apron) then
			return nil, 0
		end
	end
	local half = plan.plaza + 1
	if math.abs(x - plan.center.X) < half and math.abs(z - plan.center.Z) < half then
		return nil, 0
	end
	local mode = if zone == 1 then NATURAL else GRASS_ONLY
	-- Roads keep their paint; their shoulders wear to earth, the width wandering by noise.
	-- Two passes: a column on one road's shoulder can be on another road's paint (every junction).
	for _, road in ctx.roads do
		if roadDistance(p, road) < road.width / 2 + 0.5 then
			return nil, 0
		end
	end
	for _, road in ctx.roads do
		local dist = roadDistance(p, road)
		local shoulder = 1.5 + 1.5 * (math.clamp(Noise.fbm(plan.layers.shoulder, x, z), -1, 1) + 1)
		if dist < road.width / 2 + shoulder then
			return plan.materials.worn, mode
		end
	end
	for _, path in ctx.paths do
		if segmentDistance(p, path.a, path.b) < path.half then
			return plan.materials.worn, mode
		end
	end
	local n = Noise.fbm(plan.layers.patch, x, z)
	local fine = Noise.fbm(plan.layers.fine, x, z)
	for _, rect in ctx.wealthy do
		if zone <= 2 and contains(rect, p) then
			return plan.materials.wealth, NATURAL
		end
	end
	if zone == 1 then
		if n > 0.35 then
			return plan.materials.street, NATURAL
		elseif n < -0.45 then
			return plan.materials.earth, NATURAL
		end
		return plan.materials.pave, NATURAL
	elseif zone == 2 then
		if n < -0.2 then
			return nil, 0 -- patchy grass stays
		end
		return if fine > 0.55 then plan.materials.worn else plan.materials.earth, GRASS_ONLY
	end
	-- Outer ring: dirt patches that thin out toward the wild.
	local share = (1 - blend) * 0.55
	if (math.clamp(n, -1, 1) + 1) / 2 < share then
		return if fine > 0.5 then plan.materials.worn else plan.materials.earth, GRASS_ONLY
	end
	return nil, 0
end

-- ─── Painting (runtime) ─────────────────────────────────────────────────────

local function replaceable(m: Enum.Material, mode: number): boolean
	return if mode == NATURAL then NATURAL_TOPS[m] == true else GRASS_TOPS[m] == true
end

-- Clip = TerrainBuilder.Clip ({ x0, z0, x1, z1 }); `gen` gives ground heights for the read band.
function SettlementGround.paint(plan: Plan, clip: { x0: number, z0: number, x1: number, z1: number }, gen: any, yieldFn: (() -> ())?): number
	local yieldNow = yieldFn or function() end
	local x0 = math.floor(math.max(plan.x0, clip.x0) / VOXEL) * VOXEL
	local z0 = math.floor(math.max(plan.z0, clip.z0) / VOXEL) * VOXEL
	local x1 = math.ceil(math.min(plan.x1, clip.x1) / VOXEL) * VOXEL
	local z1 = math.ceil(math.min(plan.z1, clip.z1) / VOXEL) * VOXEL
	-- Never past the clip (chunk borders are on the grid, so this is exact).
	x0, z0, x1, z1 = math.max(x0, clip.x0), math.max(z0, clip.z0), math.min(x1, clip.x1), math.min(z1, clip.z1)
	if x1 <= x0 or z1 <= z0 then
		return 0
	end
	local terrain = workspace.Terrain
	local changedColumns = 0
	local tz = z0
	while tz < z1 do
		local tx = x0
		local tz1 = math.min(tz + TILE, z1)
		while tx < x1 do
			local tx1 = math.min(tx + TILE, x1)
			local nx, nz = (tx1 - tx) / VOXEL, (tz1 - tz) / VOXEL
			local ctx = SettlementGround.context(plan, tx, tz, tx1, tz1)
			-- 1. Decide every column (pure; may yield).
			local want: { [number]: Enum.Material } = {}
			local modes: { [number]: number } = {}
			local any = false
			for xi = 1, nx do
				for zi = 1, nz do
					local m, mode = SettlementGround.materialAt(plan, ctx, tx + (xi - 0.5) * VOXEL, tz + (zi - 0.5) * VOXEL)
					if m then
						local key = (xi - 1) * nz + zi
						want[key], modes[key] = m, mode
						any = true
					end
				end
				if xi % 8 == 0 then
					yieldNow()
				end
			end
			if any then
				-- 2. The band the surface can be in: sampled ground ± pad (ops stay within it).
				local lo, hi = math.huge, -math.huge
				local sx = tx + 2
				while sx < tx1 do
					local sz = tz + 2
					while sz < tz1 do
						local h = gen:height(sx, sz)
						lo, hi = math.min(lo, h), math.max(hi, h)
						sz += 8
					end
					sx += 8
				end
				local yTop = math.ceil((hi + BAND_PAD) / VOXEL) * VOXEL
				local yBottom = math.floor((math.max(lo, C.BEDROCK_Y) - BAND_PAD) / VOXEL) * VOXEL
				yBottom = math.max(yBottom, yTop - MAX_BAND)
				-- 3. Read, swap the top solid voxel (and the one under it), write. No yields in here.
				local region = Region3.new(Vector3.new(tx, yBottom, tz), Vector3.new(tx1, yTop, tz1))
				local materials, occupancy = terrain:ReadVoxels(region, VOXEL)
				local changed = false
				local ny = #materials[1]
				for xi = 1, nx do
					local mx, ox = materials[xi], occupancy[xi]
					for zi = 1, nz do
						local key = (xi - 1) * nz + zi
						local target = want[key]
						if target then
							local mode = modes[key]
							for yi = ny, 1, -1 do
								local current = mx[yi][zi]
								if current ~= M.Air and ox[yi][zi] > 0 then
									if current ~= M.Water and current ~= target and replaceable(current, mode) then
										mx[yi][zi] = target
										changed = true
										changedColumns += 1
										if yi > 1 and ox[yi - 1][zi] > 0 and replaceable(mx[yi - 1][zi], mode) then
											mx[yi - 1][zi] = target
										end
									end
									break
								end
							end
						end
					end
				end
				if changed then
					terrain:WriteVoxels(region, VOXEL, materials, occupancy)
				end
			end
			yieldNow()
			tx = tx1
		end
		tz = tz1
	end
	return changedColumns
end

return SettlementGround
