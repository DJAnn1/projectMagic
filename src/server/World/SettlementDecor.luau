--!strict
--[[
	SettlementDecor: Step 4 of procedural settlements, the life between the buildings.

		SettlementDecor.plan(layout, gen, worldSeed) -> { Item }    pure, seeded, no Instances
		SettlementDecor.build(item, culture, parent) -> (Model?, partCount)

	PLAN (Seed.random(worldSeed, settlementId, "settlement.decor"))
	  anchor     an invisible part on the plaza holding four "NPCSpawn" attachments (NPC system)
	  lamp       lamp posts along every street, alternating sides; the first `lampLights` per
	             tier get a PointLight from the shared budget (BuildingGenerator), the rest glow
	  fence      back and sides of some house lots (more in farming and frontier cultures)
	  goods      crate and barrel clusters beside workplaces and at the plaza corners
	  tree/rock  scattered around the settlement, never on a lot, road, plaza or water; counts
	             and tree shapes follow the biome (conifers in cold lands). With a ground plan
	             (SettlementGround) wild ones respect the town mask: none in the core, one in four
	             in the inner ring, freely in the outer ring, never in a garden or green
	  street     planted trees in stone rings along main roads in the inner ring (tidy rows)
	  patches    the ground plan's deliberate grass: gardens (low fence, crop rows), the village
	             green (a shade tree and a bench), orchards (a fenced 3 x 3 grid of fruit trees)
	  ground     plaza curbs (gaps where streets leave), hay by barns, puddles on street shoulders
	             (tag "Puddle": shown when the weather is wet, always in wet biomes), cart tracks
	             along packed-earth main streets
	  flavour by culture, at the plaza corners:
	             forgehold/emberclan  open-air forge (brazier + anvil, glowing)
	             loreseat             crystal spires (glowing)
	             tidecall             (docks below)        verdant   flower beds
	             skywarden            banner poles          frostfolk braziers
	             wayfarer             hand carts
	  dock       water towns (tidecall, and some other coastal towns): a pier on posts where a
	             main road meets deep water, with a moored boat and a lantern
	Every candidate spot is checked against the layout's lots (padded), roads, plaza and the
	sea, using the same geometry as SettlementLayout, so props never block a door or street.
]]

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)

local C = require(script.Parent.WorldConfig)
local Styles = require(script.Parent.SettlementStyles)
local Layout = require(script.Parent.SettlementLayout)
local BuildingGenerator = require(script.Parent.BuildingGenerator)
local SettlementGround = require(script.Parent.SettlementGround)

local LAMP_SPACING = { main = 26, street = 32 }
local LAMP_LIGHTS = { village = 2, town = 6, city = 10 }
local TREES = { village = 14, town = 24, city = 36 }
local FENCE_CHANCE: { [string]: number } = { verdant = 0.7, frostfolk = 0.6, wayfarer = 0.5, tidecall = 0.35, forgehold = 0.25, emberclan = 0.25, skywarden = 0.3, loreseat = 0.15 }
local FOREST: { [string]: number } = { deep_forest = 1.6, swamp = 1.2, grasslands = 1, tundra = 0.7, frozen_coast = 0.5, badlands = 0.4, desert_dunes = 0.25, tidal_flats = 0.5, ruinlands = 0.8, mountains = 0.7 }
local CONIFER: { [string]: boolean } = { tundra = true, frozen_coast = true, mountains = true, frostpeaks = true }
local ROCKY: { [string]: number } = { mountains = 1.6, badlands = 1.5, tundra = 1.2, ruinlands = 1.3, desert_dunes = 1, frozen_coast = 1.1 }
local STREET_TREES = { village = 4, town = 10, city = 16 }
local STREET_TREE_SPACING = 24
local PUDDLES = { village = 3, town = 6, city = 10 }
local INNER_TREE_SHARE = 0.25
local TRACK_PIECE = 4 -- road segments per cart-track item (each item builds with its own chunk)

export type Item = { id: string, kind: string, cframe: CFrame, data: { [string]: any } }

local SettlementDecor = {}

-- ─── Planning ───────────────────────────────────────────────────────────────

function SettlementDecor.plan(layout: Layout.Layout, gen: any, worldSeed: number, groundPlan: SettlementGround.Plan?): { Item }
	local rng = Seed.random(worldSeed, layout.id, "settlement.decor")
	local items: { Item } = {}
	local center = layout.center
	local tier = layout.tier
	local culture = layout.culture
	local rects = {}
	for _, lot in layout.lots do
		table.insert(rects, Layout.rectOf(lot.cframe, lot.w, lot.d, 1))
	end
	local taken: { { p: Vector3, r: number } } = {}

	local function add(kind: string, cframe: CFrame, data: { [string]: any }?)
		table.insert(items, { id = string.format("%s_D%03d", layout.id, #items + 1), kind = kind, cframe = cframe, data = data or {} })
	end

	-- Is a circle of radius r at p clear of lots, roads, the plaza, water and other props?
	local function clear(p: Vector3, r: number, allowPlaza: boolean?): boolean
		local flatP = Vector3.new(p.X, 0, p.Z)
		if not allowPlaza and math.abs(p.X - center.X) < layout.plaza + r + 1 and math.abs(p.Z - center.Z) < layout.plaza + r + 1 then
			return false
		end
		local probe = { c = flatP, r = Vector3.xAxis, f = Vector3.zAxis, hw = r, hd = r }
		for _, rect in rects do
			if Layout.rectsOverlap(probe, rect) then
				return false
			end
		end
		for _, road in layout.roads do
			for _, q in road.points do
				if (Vector3.new(q.X, 0, q.Z) - flatP).Magnitude < road.width / 2 + r then
					return false
				end
			end
		end
		for _, t in taken do
			if (t.p - flatP).Magnitude < t.r + r then
				return false
			end
		end
		if gen:height(p.X, p.Z) < C.SEA_LEVEL + 1 then
			return false
		end
		return true
	end

	local function claim(p: Vector3, r: number)
		table.insert(taken, { p = Vector3.new(p.X, 0, p.Z), r = r })
	end

	local function ground(x: number, z: number): number
		return gen:height(x, z)
	end

	-- NPC spawn anchor on the plaza.
	add("anchor", CFrame.new(center), { plaza = layout.plaza, name = layout.name })

	local conifer = CONIFER[gen:sample(center.X, center.Z).biome] == true
	local function zoneAt(x: number, z: number): number
		return if groundPlan then (SettlementGround.zoneAt(groundPlan, x, z)) else 3
	end

	-- The ground plan's deliberate grass patches: planted and fenced, and kept clear of other props.
	local patches: { SettlementGround.Patch } = if groundPlan then groundPlan.patches else {}
	for _, patch in patches do
		table.insert(rects, patch.rect)
		local cf = patch.cframe
		if patch.kind == "garden" then
			add("garden", cf, { w = patch.w, d = patch.d, crops = true })
		elseif patch.kind == "orchard" then
			add("garden", cf, { w = patch.w, d = patch.d, crops = false })
			for gx = -1, 1 do
				for gz = -1, 1 do
					local at = cf * Vector3.new(gx * 6, 0, gz * 4.6)
					add("tree", CFrame.new(at.X, gen:height(at.X, at.Z), at.Z) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
						{ scale = rng:NextNumber(0.6, 0.75), conifer = false, fruit = true, seed = rng:NextInteger(1, 1e6) })
				end
			end
		elseif patch.kind == "green" then
			local treeAt = cf * Vector3.new(patch.w * 0.25, 0, 0)
			add("tree", CFrame.new(treeAt.X, gen:height(treeAt.X, treeAt.Z), treeAt.Z), { scale = 1.2, conifer = conifer, green = true, seed = rng:NextInteger(1, 1e6) })
			local benchAt = cf * Vector3.new(-patch.w * 0.15, 0, patch.d * 0.2)
			local benchY = gen:height(benchAt.X, benchAt.Z)
			add("bench", CFrame.lookAt(Vector3.new(benchAt.X, benchY, benchAt.Z), Vector3.new(treeAt.X, benchY, treeAt.Z)), {})
		end
	end

	-- Lamp posts along streets.
	local lit = 0
	for _, road in layout.roads do
		local spacing = LAMP_SPACING[road.kind] or 30
		local total = Layout.lengthOf(road.points)
		local side = if rng:NextNumber() < 0.5 then 1 else -1
		local s = spacing / 2
		while s < total do
			local p, tangent = Layout.along(road.points, s)
			if p and tangent then
				local normal = Vector3.new(-tangent.Z, 0, tangent.X) * side
				local at = p + normal * (road.width / 2 + 1.2)
				-- Lamps stand on the street edge, so only lots and props can block them.
				local probe = { c = Vector3.new(at.X, 0, at.Z), r = Vector3.xAxis, f = Vector3.zAxis, hw = 0.8, hd = 0.8 }
				local blocked = false
				for _, rect in rects do
					if Layout.rectsOverlap(probe, rect) then
						blocked = true
						break
					end
				end
				if not blocked then
					local y = math.max(p.Y, ground(at.X, at.Z))
					add("lamp", CFrame.lookAt(Vector3.new(at.X, y, at.Z), Vector3.new(p.X, y, p.Z)), { light = lit < (LAMP_LIGHTS[layout.size] or 4) })
					lit += 1
					claim(at, 1)
				end
			end
			side = -side
			s += spacing
		end
	end

	-- Fences around some house lots (back and sides; the front stays open to the street).
	for _, lot in layout.lots do
		if string.sub(lot.type, 1, 5) == "house" and rng:NextNumber() < (FENCE_CHANCE[culture] or 0.3) then
			add("fence", lot.cframe, { w = lot.w, d = lot.d })
		end
	end

	-- Goods beside workplaces (on whichever side is free), and at plaza corners.
	for _, lot in layout.lots do
		if lot.type == "smithy" or lot.type == "tavern" or lot.type == "market_stall" or lot.type == "barn" then
			for _, sideSign in { 1, -1 } do
				local at = lot.cframe * Vector3.new(sideSign * (lot.w / 2 + 2), 0, lot.d / 2 - 2.5)
				if clear(at, 1.4) then
					add("goods", CFrame.new(at.X, ground(at.X, at.Z), at.Z) * CFrame.Angles(0, rng:NextNumber() * math.pi, 0), { barrels = rng:NextInteger(1, 2), crates = rng:NextInteger(1, 3) })
					claim(at, 1.4)
					break
				end
			end
		end
	end

	-- Plaza corners: goods and the culture's flavour.
	local inner = layout.plaza - 2
	local corners = { Vector3.new(-1, 0, -1), Vector3.new(1, 0, -1), Vector3.new(1, 0, 1), Vector3.new(-1, 0, 1) }
	for i, c in corners do
		local at = center + Vector3.new(c.X * inner, 0, c.Z * inner)
		local facing = CFrame.lookAt(at, Vector3.new(center.X, at.Y, center.Z))
		local flavour = if culture == "forgehold" or culture == "emberclan" then (if i % 2 == 1 then "forge" else "goods")
			elseif culture == "loreseat" then "spire"
			elseif culture == "verdant" then "flowers"
			elseif culture == "skywarden" then "banner"
			elseif culture == "frostfolk" then "brazier"
			elseif culture == "wayfarer" then (if i % 2 == 1 then "cart" else "goods")
			else "goods"
		if clear(at, 1.2, true) then
			add(flavour, facing, { light = i <= 2, barrels = 1, crates = 2 })
			claim(at, 1.6)
		end
	end
	-- Scholar enclaves also ring the town with taller spires.
	if culture == "loreseat" then
		for k = 0, 3 do
			local a = k / 4 * math.pi * 2 + rng:NextNumber() * 0.5
			local at = center + Vector3.new(math.cos(a), 0, math.sin(a)) * tier.radius * 0.8
			if clear(at, 2) then
				add("spire", CFrame.new(at.X, ground(at.X, at.Z), at.Z), { tall = true, light = k == 0 })
				claim(at, 2)
			end
		end
	end

	-- Docks where a main road meets deep water (always for water towns, sometimes elsewhere).
	local docks = 0
	local wantDocks = if culture == "tidecall" then 2 elseif rng:NextNumber() < 0.35 then 1 else 0
	for _, road in layout.roads do
		if docks >= wantDocks then
			break
		end
		if road.kind == "main" and #road.points >= 2 then
			local last = road.points[#road.points]
			local before = road.points[#road.points - 1]
			local dir = Vector3.new(last.X - before.X, 0, last.Z - before.Z)
			if dir.Magnitude > 0.1 then
				dir = dir.Unit
				local near, far = last + dir * 10, last + dir * 28
				if ground(near.X, near.Z) < C.SEA_LEVEL and ground(far.X, far.Z) < C.SEA_LEVEL - 2 then
					local start = Vector3.new(last.X, C.SEA_LEVEL + 1.2, last.Z)
					add("dock", CFrame.lookAt(start, start + dir), { length = rng:NextInteger(22, 30), boat = rng:NextNumber() < 0.8 })
					docks += 1
				end
			end
		end
	end

	-- Planted street trees: tidy rows along main roads through the inner ring, in stone rings.
	if groundPlan then
		local planted = 0
		for _, road in layout.roads do
			if road.kind == "main" then
				local total = Layout.lengthOf(road.points)
				local side = 1
				local s = STREET_TREE_SPACING
				while s < total and planted < (STREET_TREES[layout.size] or 6) do
					local p, tangent = Layout.along(road.points, s)
					if p and tangent then
						local normal = Vector3.new(-tangent.Z, 0, tangent.X) * side
						local at = p + normal * (road.width / 2 + 3.2)
						if zoneAt(at.X, at.Z) == 2 and clear(at, 2.2) then
							add("tree", CFrame.new(at.X, math.max(p.Y, ground(at.X, at.Z)), at.Z) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0),
								{ scale = rng:NextNumber(0.65, 0.8), conifer = conifer, planted = true, seed = rng:NextInteger(1, 1e6) })
							claim(at, 2.2)
							planted += 1
						end
					end
					side = -side
					s += STREET_TREE_SPACING
				end
			end
		end
	end

	-- Plaza curbs: a low stone edge round the paving, with gaps where the streets leave.
	if groundPlan then
		local half = layout.plaza + 1
		for sideIndex = 0, 3 do
			local rot = CFrame.Angles(0, sideIndex * math.pi / 2, 0)
			local function flush(u0: number, u1: number)
				local length = u1 - u0
				if length >= 1.5 then
					local mid = center + rot:VectorToWorldSpace(Vector3.new((u0 + u1) / 2, 0, -half))
					local outward = rot:VectorToWorldSpace(Vector3.new(0, 0, -1))
					add("curb", CFrame.lookAt(mid, mid + outward), { length = length })
				end
			end
			local runStart: number? = nil
			local u = -half
			while u <= half do
				local at = center + rot:VectorToWorldSpace(Vector3.new(u, 0, -half))
				local gap = false
				for _, road in layout.roads do
					for _, q in road.points do
						if (Vector3.new(q.X, 0, q.Z) - Vector3.new(at.X, 0, at.Z)).Magnitude < road.width / 2 + 1.5 then
							gap = true
							break
						end
					end
					if gap then
						break
					end
				end
				if gap then
					if runStart then
						flush(runStart, u)
						runStart = nil
					end
				elseif not runStart then
					runStart = u
				end
				u += 1
			end
			if runStart then
				flush(runStart, half)
			end
		end
	end

	-- Hay beside barns.
	for _, lot in layout.lots do
		if lot.type == "barn" then
			for _, sideSign in { -1, 1 } do
				local at = lot.cframe * Vector3.new(sideSign * (lot.w / 2 + 2.5), 0, -lot.d / 4)
				if clear(at, 1.8) then
					add("hay", CFrame.new(at.X, ground(at.X, at.Z), at.Z) * CFrame.Angles(0, rng:NextNumber() * math.pi, 0), { bales = rng:NextInteger(2, 4) })
					claim(at, 1.8)
					break
				end
			end
		end
	end

	-- Puddles on street shoulders, and cart tracks along packed-earth main streets.
	if groundPlan then
		local want = PUDDLES[layout.size] or 4
		if groundPlan.dirtStreets or groundPlan.wet then
			want = math.floor(want * 1.5)
		end
		local placed, tries = 0, 0
		while placed < want and tries < want * 8 and #layout.roads > 0 do
			tries += 1
			local road = layout.roads[rng:NextInteger(1, #layout.roads)]
			local total = Layout.lengthOf(road.points)
			local p, tangent = Layout.along(road.points, rng:NextNumber(0, total))
			if p and tangent then
				local side = if rng:NextNumber() < 0.5 then 1 else -1
				local normal = Vector3.new(-tangent.Z, 0, tangent.X) * side
				local at = p + normal * (road.width / 2 + rng:NextNumber(0.8, 2.2))
				if zoneAt(at.X, at.Z) ~= 0 and clear(at, 1.6) then
					add("puddle", CFrame.new(at.X, p.Y, at.Z) * CFrame.Angles(0, rng:NextNumber() * math.pi, 0),
						{ size = rng:NextNumber(2.4, 4), always = groundPlan.wet, seed = rng:NextInteger(1, 1e6) })
					claim(at, 1.6)
					placed += 1
				end
			end
		end
		if groundPlan.dirtStreets then
			for _, road in layout.roads do
				if road.kind == "main" and #road.points >= 2 then
					local i = 1
					while i < #road.points do
						local last = math.min(i + TRACK_PIECE, #road.points)
						local points = {}
						for j = i, last do
							table.insert(points, road.points[j])
						end
						add("tracks", CFrame.new(road.points[i]), { points = points })
						i = last
					end
				end
			end
		end
	end

	-- Wild trees and rocks, in and around the settlement (respecting the ground mask).
	local sample = gen:sample(center.X, center.Z)
	local trees = math.floor((TREES[layout.size] or 20) * (FOREST[sample.biome] or 0.6))
	local rocks = math.floor((TREES[layout.size] or 20) * 0.4 * (ROCKY[sample.biome] or 0.6))
	for _, entry in { { kind = "tree", count = trees, r = 3 }, { kind = "rock", count = rocks, r = 2 } } do
		local placed, tries = 0, 0
		while placed < entry.count and tries < entry.count * 6 do
			tries += 1
			local a = rng:NextNumber() * math.pi * 2
			-- Within radius + 25: SettlementService only builds what lies in chunks it watches (+30).
			local d = rng:NextNumber(layout.plaza + 6, tier.radius + 25)
			local x, z = center.X + math.cos(a) * d, center.Z + math.sin(a) * d
			local at = Vector3.new(x, 0, z)
			local zone = zoneAt(x, z)
			local inPatch = groundPlan ~= nil and SettlementGround.inPatch(groundPlan, x, z) ~= nil
			local allowed = zone ~= 1 and not inPatch and (zone ~= 2 or rng:NextNumber() < INNER_TREE_SHARE)
			if allowed and clear(at, entry.r) then
				local y = ground(x, z)
				add(entry.kind, CFrame.new(x, y, z) * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0), {
					scale = rng:NextNumber(0.8, 1.3),
					conifer = conifer,
					seed = rng:NextInteger(1, 1e6),
				})
				claim(at, entry.r)
				placed += 1
			end
		end
	end

	return items
end

-- ─── Building ───────────────────────────────────────────────────────────────

type Kit = { model: Model, base: CFrame, parts: number }

local function vary(rng: Random, color: Color3, amount: number): Color3
	local h, s, v = color:ToHSV()
	return Color3.fromHSV(h, math.clamp(s + rng:NextNumber(-amount, amount) * 0.5, 0, 1), math.clamp(v + rng:NextNumber(-amount, amount), 0, 1))
end

local function part(k: Kit, name: string, size: Vector3, offset: CFrame, material: Enum.Material, color: Color3, opts: { [string]: any }?): BasePart
	local o = opts or {}
	local p: BasePart = if o.wedge then Instance.new("WedgePart") else Instance.new("Part")
	p.Name = name
	p.Anchored = true
	p.CanTouch = false
	p.Size = size
	p.CFrame = k.base * offset
	p.Material = material
	p.Color = color
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if o.collide == false then
		p.CanCollide = false
		p.CanQuery = false
	end
	if o.transparency then
		p.Transparency = o.transparency
	end
	if o.shape then
		(p :: Part).Shape = o.shape
	end
	p.CastShadow = o.shadow ~= false
	p.Parent = k.model
	k.parts += 1
	return p
end

local WOOD = Enum.Material.Wood
local WOOD_COLOR = Color3.fromRGB(110, 78, 52)
local CYL = Enum.PartType.Cylinder
local BALL = Enum.PartType.Ball
local UPRIGHT = CFrame.Angles(0, 0, math.pi / 2) -- turns a Cylinder's X axis vertical

local function upright(k: Kit, name: string, height: number, diameter: number, at: Vector3, material: Enum.Material, color: Color3): BasePart
	return part(k, name, Vector3.new(height, diameter, diameter), CFrame.new(at + Vector3.new(0, height / 2, 0)) * UPRIGHT, material, color, { shape = CYL })
end

local function barrel(k: Kit, at: Vector3, rng: Random)
	upright(k, "Barrel", 2.6, 2.2, at, WOOD, vary(rng, Color3.fromRGB(120, 84, 52), 0.08))
end

local function crate(k: Kit, at: Vector3, size: number, rng: Random)
	part(k, "Crate", Vector3.new(size, size, size), CFrame.new(at + Vector3.new(0, size / 2, 0)) * CFrame.Angles(0, rng:NextNumber() * 0.6, 0), Enum.Material.WoodPlanks, vary(rng, Color3.fromRGB(150, 116, 76), 0.08))
end

local BUILDERS: { [string]: (Kit, Item, Styles.Culture, Random) -> () } = {}

BUILDERS.anchor = function(k, item)
	local p = part(k, "SettlementAnchor", Vector3.new(1, 1, 1), CFrame.new(0, 0.5, 0), Enum.Material.SmoothPlastic, Color3.new(1, 1, 1), { collide = false, transparency = 1, shadow = false })
	CollectionService:AddTag(p, "Settlement")
	local r = item.data.plaza * 0.75
	for i, offset in { Vector3.new(r, 0, 0), Vector3.new(-r, 0, 0), Vector3.new(0, 0, r), Vector3.new(0, 0, -r) } do
		local a = Instance.new("Attachment")
		a.Name = "NPCSpawn" .. i
		a.Position = offset + Vector3.new(0, 2.5, 0)
		a.Parent = p
		CollectionService:AddTag(a, "NPCSpawn")
	end
end

BUILDERS.lamp = function(k, item, style, rng)
	local metal = Color3.fromRGB(40, 40, 44)
	upright(k, "Pole", 10, 0.6, Vector3.zero, Enum.Material.Metal, metal)
	part(k, "Base", Vector3.new(1.4, 0.6, 1.4), CFrame.new(0, 0.3, 0), style.foundation.material, vary(rng, style.foundation.color, 0.05))
	part(k, "Arm", Vector3.new(0.3, 0.3, 2), CFrame.new(0, 9.6, -1), Enum.Material.Metal, metal, { shadow = false })
	local glow = part(k, "Lantern", Vector3.new(0.9, 1.3, 0.9), CFrame.new(0, 8.8, -1.9), Enum.Material.Neon, Color3.fromRGB(255, 214, 150), { collide = false, shadow = false })
	if item.data.light then
		BuildingGenerator.light(glow, Color3.fromRGB(255, 200, 140), 20, 1.3)
	end
end

BUILDERS.fence = function(k, item, style, rng)
	local w, d = item.data.w + 0.6, item.data.d + 0.6
	local color = vary(rng, style.trim.color, 0.06)
	local function run(name: string, a: Vector3, b: Vector3)
		local length = (b - a).Magnitude
		local mid = (a + b) / 2
		local look = CFrame.lookAt(mid, b)
		for _, h in { 1.2, 2.6 } do
			part(k, name .. "Rail", Vector3.new(0.25, 0.3, length), look + Vector3.new(0, h, 0), WOOD, color, { shadow = false })
		end
		local posts = math.max(1, math.floor(length / 6))
		for i = 0, posts do
			local p = a:Lerp(b, i / posts)
			part(k, name .. "Post", Vector3.new(0.45, 3.2, 0.45), CFrame.new(p + Vector3.new(0, 1.6, 0)), WOOD, color, { shadow = false })
		end
	end
	local fl, fr = Vector3.new(-w / 2, 0, -d / 2), Vector3.new(w / 2, 0, -d / 2)
	local bl, br = Vector3.new(-w / 2, 0, d / 2), Vector3.new(w / 2, 0, d / 2)
	run("Back", bl, br)
	run("Left", fl, bl)
	run("Right", fr, br)
end

BUILDERS.goods = function(k, item, _style, rng)
	for i = 1, item.data.barrels or 1 do
		barrel(k, Vector3.new(-1.4 + (i - 1) * 2.4, 0, 0.8), rng)
	end
	for i = 1, item.data.crates or 1 do
		crate(k, Vector3.new(-1 + (i - 1) * 1.9, if i == 3 then 1.9 else 0, -1.3), rng:NextNumber(1.6, 2), rng)
	end
end

BUILDERS.forge = function(k, item, style, rng)
	local stone = style.foundation
	part(k, "Hearth", Vector3.new(3, 2.4, 3), CFrame.new(0, 1.2, 1.5), stone.material, vary(rng, stone.color, 0.05))
	local coals = part(k, "Coals", Vector3.new(2.2, 0.4, 2.2), CFrame.new(0, 2.6, 1.5), Enum.Material.Neon, Color3.fromRGB(255, 110, 30), { collide = false, shadow = false })
	if item.data.light then
		BuildingGenerator.light(coals, Color3.fromRGB(255, 140, 60), 16, 1.8)
	end
	part(k, "AnvilBase", Vector3.new(1.2, 2, 1.2), CFrame.new(0, 1, -1.5), WOOD, vary(rng, WOOD_COLOR, 0.08))
	part(k, "Anvil", Vector3.new(2.8, 0.8, 1.1), CFrame.new(0, 2.4, -1.5), Enum.Material.DiamondPlate, Color3.fromRGB(60, 62, 68))
end

BUILDERS.spire = function(k, item, style, rng)
	local tall = item.data.tall == true
	local h = if tall then rng:NextNumber(12, 18) else rng:NextNumber(5, 8)
	part(k, "Plinth", Vector3.new(2.6, 1, 2.6), CFrame.new(0, 0.5, 0), style.foundation.material, vary(rng, style.foundation.color, 0.05))
	part(k, "Spire", Vector3.new(1.4, h, 1.4), CFrame.new(0, 1 + h / 2, 0) * CFrame.Angles(0, math.rad(45), math.rad(rng:NextNumber(-6, 6))), Enum.Material.Glass, style.glass, { transparency = 0.2 })
	local tip = part(k, "SpireTip", Vector3.new(0.9, 1.6, 0.9), CFrame.new(0, 1 + h + 0.6, 0) * CFrame.Angles(math.rad(45), math.rad(45), 0), Enum.Material.Neon, style.glass, { collide = false, shadow = false })
	if item.data.light then
		BuildingGenerator.light(tip, style.glass, if tall then 26 else 14, 1.2)
	end
end

BUILDERS.flowers = function(k, _item, style, rng)
	part(k, "Planter", Vector3.new(3.4, 1, 1.6), CFrame.new(0, 0.5, 0), WOOD, vary(rng, style.trim.color, 0.05))
	local colors = { Color3.fromRGB(230, 90, 120), Color3.fromRGB(250, 210, 80), Color3.fromRGB(170, 120, 240), Color3.fromRGB(255, 255, 255) }
	for i = 1, 3 do
		part(k, "Flowers", Vector3.new(1, 0.8, 1.2), CFrame.new(-1.1 + (i - 1) * 1.1, 1.3, 0), Enum.Material.Grass, colors[rng:NextInteger(1, #colors)], { collide = false, shadow = false })
	end
end

BUILDERS.banner = function(k, _item, style, rng)
	upright(k, "Pole", 12, 0.5, Vector3.zero, WOOD, vary(rng, style.trim.color, 0.05))
	local cloth = style.roof[rng:NextInteger(1, #style.roof)].color
	part(k, "Banner", Vector3.new(0.1, 3.4, 2.2), CFrame.new(0, 10, -1.2), Enum.Material.Fabric, vary(rng, cloth, 0.06), { collide = false, shadow = false })
	part(k, "Finial", Vector3.new(0.7, 0.7, 0.7), CFrame.new(0, 12.3, 0), Enum.Material.Metal, Color3.fromRGB(210, 180, 100), { shape = BALL, shadow = false })
end

BUILDERS.brazier = function(k, item, style, rng)
	part(k, "Stand", Vector3.new(0.8, 3, 0.8), CFrame.new(0, 1.5, 0), style.foundation.material, vary(rng, style.foundation.color, 0.05))
	part(k, "Bowl", Vector3.new(0.8, 2.2, 2.2), CFrame.new(0, 3.3, 0) * UPRIGHT, Enum.Material.Metal, Color3.fromRGB(50, 50, 54), { shape = CYL })
	local fire = part(k, "Fire", Vector3.new(1.4, 1, 1.4), CFrame.new(0, 4.1, 0), Enum.Material.Neon, Color3.fromRGB(255, 150, 60), { collide = false, shadow = false })
	if item.data.light then
		BuildingGenerator.light(fire, Color3.fromRGB(255, 160, 80), 18, 1.6)
	end
end

BUILDERS.cart = function(k, _item, _style, rng)
	local wood = vary(rng, WOOD_COLOR, 0.08)
	part(k, "CartBed", Vector3.new(3, 1.2, 4.4), CFrame.new(0, 1.8, 0), Enum.Material.WoodPlanks, wood)
	for _, sideSign in { -1, 1 } do
		part(k, "Wheel", Vector3.new(0.4, 2.4, 2.4), CFrame.new(sideSign * 1.7, 1.2, 0.4), WOOD, vary(rng, wood, 0.05), { shape = CYL })
	end
	part(k, "Handle", Vector3.new(0.3, 0.3, 3), CFrame.new(0, 1.4, -3.4) * CFrame.Angles(math.rad(-12), 0, 0), WOOD, wood, { shadow = false })
	crate(k, Vector3.new(0, 2.4, 0.6), 1.4, rng)
end

BUILDERS.dock = function(k, item, style, rng)
	local length = item.data.length
	local wood = vary(rng, Color3.fromRGB(120, 90, 62), 0.06)
	-- The deck runs forward (-Z in the item's frame) out over the water.
	part(k, "Deck", Vector3.new(6, 0.6, length), CFrame.new(0, 0, -length / 2), Enum.Material.WoodPlanks, wood)
	local postDepth = 10
	for z = 2, length, 6 do
		for _, sideSign in { -1, 1 } do
			part(k, "Pile", Vector3.new(postDepth, 0.8, 0.8), CFrame.new(sideSign * 2.8, -postDepth / 2 + 0.6, -z) * UPRIGHT, WOOD, vary(rng, wood, 0.06), { shape = CYL })
		end
	end
	for _, sideSign in { -1, 1 } do
		part(k, "Bollard", Vector3.new(1.2, 0.7, 0.7), CFrame.new(sideSign * 2.4, 0.9, -length + 1) * UPRIGHT, WOOD, wood, { shape = CYL })
	end
	upright(k, "LampPost", 5, 0.4, Vector3.new(2.6, 0.3, -length + 0.6), WOOD, wood)
	local lantern = part(k, "Lantern", Vector3.new(0.8, 1, 0.8), CFrame.new(2.6, 5.6, -length + 0.6), Enum.Material.Neon, Color3.fromRGB(255, 214, 150), { collide = false, shadow = false })
	BuildingGenerator.light(lantern, Color3.fromRGB(255, 200, 140), 18, 1.2)
	if item.data.boat then
		-- A rowing boat moored alongside, floating at the waterline.
		local boatAt = CFrame.new(-5.6, C.SEA_LEVEL + 0.3 - (C.SEA_LEVEL + 1.2), -length + 6)
		local hull = vary(rng, style.trim.color, 0.08)
		part(k, "Hull", Vector3.new(3.4, 1.4, 8), boatAt, WOOD, hull)
		part(k, "Bow", Vector3.new(3.4, 1.4, 2.6), boatAt * CFrame.new(0, 0, -5.3), WOOD, hull, { wedge = true }) -- tall against the hull, sloping forward
		part(k, "Thwart", Vector3.new(3, 0.3, 0.8), boatAt * CFrame.new(0, 0.6, 0), Enum.Material.WoodPlanks, vary(rng, wood, 0.05), { shadow = false })
	end
end

BUILDERS.tree = function(k, item, style, rng)
	local s = item.data.scale or 1
	local trunk = vary(rng, Color3.fromRGB(96, 70, 48), 0.06)
	local trunkH = 7 * s
	upright(k, "Trunk", trunkH + 1, 1.2 * s, Vector3.new(0, -1, 0), WOOD, trunk)
	if item.data.planted then
		-- A stone ring round a street tree.
		part(k, "TreeRing", Vector3.new(0.5, 3.2, 3.2), CFrame.new(0, 0.1, 0) * UPRIGHT, style.foundation.material, vary(rng, style.foundation.color, 0.05), { shape = CYL, shadow = false })
	end
	if item.data.fruit then
		local fruitColor = if rng:NextNumber() < 0.5 then Color3.fromRGB(200, 50, 40) else Color3.fromRGB(235, 190, 60)
		for i = 1, 3 do
			local a = i / 3 * math.pi * 2
			part(k, "Fruit", Vector3.one * 0.6, CFrame.new(math.cos(a) * 2.6 * s, trunkH + 0.6 * s, math.sin(a) * 2.6 * s), Enum.Material.SmoothPlastic, fruitColor, { shape = BALL, collide = false, shadow = false })
		end
	end
	if item.data.conifer then
		local green = vary(rng, Color3.fromRGB(50, 92, 60), 0.06)
		for i, diameter in { 7, 5, 3 } do
			part(k, "Needles", Vector3.new(3 * s, diameter * s, diameter * s), CFrame.new(0, trunkH - 1 + (i - 1) * 2.6 * s, 0) * UPRIGHT, Enum.Material.Grass, vary(rng, green, 0.04), { shape = CYL })
		end
	else
		local green = vary(rng, Color3.fromRGB(80, 130, 60), 0.08)
		part(k, "Canopy", Vector3.one * 7 * s, CFrame.new(0, trunkH + 1.5 * s, 0), Enum.Material.Grass, green, { shape = BALL })
		part(k, "Canopy", Vector3.one * 5 * s, CFrame.new(1.8 * s, trunkH + 0.6 * s, 1 * s), Enum.Material.Grass, vary(rng, green, 0.05), { shape = BALL })
	end
end

BUILDERS.rock = function(k, item, _style, rng)
	local s = item.data.scale or 1
	local grey = vary(rng, Color3.fromRGB(110, 108, 104), 0.08)
	part(k, "Rock", Vector3.new(3.4, 2.4, 2.8) * s, CFrame.new(0, 0.6 * s, 0) * CFrame.Angles(rng:NextNumber(-0.3, 0.3), 0, rng:NextNumber(-0.3, 0.3)), Enum.Material.Rock, grey)
	part(k, "Rock", Vector3.new(2, 1.6, 1.8) * s, CFrame.new(1.6 * s, 0.4 * s, 0.8 * s) * CFrame.Angles(0, rng:NextNumber(0, 3), rng:NextNumber(-0.4, 0.4)), Enum.Material.Rock, vary(rng, grey, 0.05))
end

-- A low fence round a garden or orchard (gate gap at the front), and crop rows in gardens.
BUILDERS.garden = function(k, item, style, rng)
	local w, d = item.data.w, item.data.d
	local color = vary(rng, style.trim.color, 0.06)
	local function run(name: string, a: Vector3, b: Vector3)
		local length = (b - a).Magnitude
		if length < 0.5 then
			return
		end
		local mid = (a + b) / 2
		part(k, name .. "Rail", Vector3.new(0.2, 0.25, length), CFrame.lookAt(mid, b) + Vector3.new(0, 1.3, 0), WOOD, color, { shadow = false })
		local posts = math.max(1, math.floor(length / 5))
		for i = 0, posts do
			local p = a:Lerp(b, i / posts)
			part(k, name .. "Post", Vector3.new(0.35, 1.8, 0.35), CFrame.new(p + Vector3.new(0, 0.9, 0)), WOOD, color, { shadow = false })
		end
	end
	local fl, fr = Vector3.new(-w / 2, 0, -d / 2), Vector3.new(w / 2, 0, -d / 2)
	local bl, br = Vector3.new(-w / 2, 0, d / 2), Vector3.new(w / 2, 0, d / 2)
	local gate = 1.6
	run("Front", fl, Vector3.new(-gate, 0, -d / 2))
	run("FrontB", Vector3.new(gate, 0, -d / 2), fr)
	run("Back", bl, br)
	run("Left", fl, bl)
	run("Right", fr, br)
	if item.data.crops then
		local leaf = vary(rng, Color3.fromRGB(86, 140, 60), 0.08)
		local soil = Color3.fromRGB(92, 70, 50)
		local rows = math.max(2, math.floor((w - 2) / 2.6))
		for i = 1, rows do
			local x = -w / 2 + 1 + (i - 0.5) * (w - 2) / rows
			part(k, "Bed", Vector3.new(1.4, 0.35, d - 2.4), CFrame.new(x, 0.1, 0), Enum.Material.Ground, soil, { collide = false, shadow = false })
			part(k, "Crop", Vector3.new(1, 0.7, d - 3), CFrame.new(x, 0.55, 0), Enum.Material.Grass, vary(rng, leaf, 0.06), { collide = false, shadow = false })
		end
	end
end

BUILDERS.bench = function(k, _item, style, rng)
	local wood = vary(rng, style.trim.color, 0.06)
	local seatPart = part(k, "Seat", Vector3.new(4, 0.3, 1.2), CFrame.new(0, 1.5, 0), WOOD, wood)
	part(k, "Back", Vector3.new(4, 1.2, 0.25), CFrame.new(0, 2.2, 0.55), WOOD, wood, { shadow = false })
	for _, x in { -1.6, 1.6 } do
		part(k, "Leg", Vector3.new(0.3, 1.5, 1), CFrame.new(x, 0.75, 0), WOOD, wood, { shadow = false })
	end
	local seat = Instance.new("Attachment")
	seat.Name = "NPCSeat1"
	seat.Position = Vector3.new(0, 0.5, 0)
	seat.Parent = seatPart
	CollectionService:AddTag(seat, "NPCSeat")
end

BUILDERS.curb = function(k, item, style, rng)
	-- Lies along the plaza edge, its outer face on the edge line; sunk so it stands 0.4 proud.
	part(k, "Curb", Vector3.new(item.data.length, 0.9, 0.8), CFrame.new(0, -0.05, 0.4), style.foundation.material, vary(rng, style.foundation.color, 0.05), { shadow = false })
end

BUILDERS.hay = function(k, item, _style, rng)
	local hay = Color3.fromRGB(214, 186, 96)
	for i = 1, item.data.bales or 2 do
		local y = if i > 2 then 2.6 else 0.9
		local x = if i > 2 then 0 else (i - 1.5) * 2.3
		part(k, "Hay", Vector3.new(2.2, 1.8, 1.6), CFrame.new(x, y, 0) * CFrame.Angles(0, rng:NextNumber(-0.2, 0.2), 0), Enum.Material.Fabric, vary(rng, hay, 0.07))
	end
end

-- A puddle: two flat discs of glassy water. Hidden unless the biome is wet; SettlementService
-- shows it while the weather is wet (WorldStateService.wetnessAt).
BUILDERS.puddle = function(k, item, _style, rng)
	local size = item.data.size or 3
	local water = Color3.fromRGB(88, 108, 122)
	local transparency = if item.data.always then 0.35 else 1
	for i, scale in { 1, 0.65 } do
		local offset = if i == 1 then Vector3.zero else Vector3.new(size * 0.35, 0, rng:NextNumber(-0.4, 0.4) * size)
		local p = part(k, "Puddle", Vector3.new(0.06, size * scale, size * scale * 0.75), CFrame.new(offset + Vector3.new(0, 0.05, 0)) * UPRIGHT, Enum.Material.Glass, water,
			{ shape = CYL, collide = false, shadow = false, transparency = transparency })
		p.Reflectance = 0.15
	end
	k.model:SetAttribute("AlwaysWet", item.data.always == true)
end

-- Two dark ruts along a packed-earth street, through the item's (world) road points.
BUILDERS.tracks = function(k, item, _style, rng)
	local points = item.data.points :: { Vector3 }
	local rut = vary(rng, Color3.fromRGB(78, 60, 44), 0.04)
	local inverse = k.base:Inverse()
	for i = 1, #points - 1 do
		local a, b = points[i], points[i + 1]
		local flatDir = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
		if flatDir.Magnitude > 0.5 then
			local mid = (a + b) / 2
			local look = CFrame.lookAt(mid, mid + flatDir)
			for _, sideSign in { -1, 1 } do
				local world = look * CFrame.new(sideSign * 1.5, 0.04, 0)
				part(k, "Rut", Vector3.new(0.5, 0.08, flatDir.Magnitude + 0.4), inverse * world, Enum.Material.Ground, rut, { collide = false, shadow = false })
			end
		end
	end
end

local TAGS: { [string]: string } = {
	anchor = "SettlementAnchor", lamp = "LampPost", fence = "Fence", goods = "Goods", forge = "OpenForge", spire = "CrystalSpire",
	flowers = "Planter", banner = "Banner", brazier = "Brazier", cart = "Cart", dock = "Dock", tree = "Tree", rock = "Rock",
	garden = "Garden", bench = "Bench", curb = "Curb", hay = "Hay", puddle = "Puddle", tracks = "CartTracks",
}

function SettlementDecor.build(item: Item, culture: string, parent: Instance): (Model?, number)
	local builder = BUILDERS[item.kind]
	if not builder then
		return nil, 0
	end
	local model = Instance.new("Model")
	model.Name = item.kind
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	local k: Kit = { model = model, base = item.cframe, parts = 0 }
	builder(k, item, Styles.cultures[culture] or Styles.cultures.wayfarer, Random.new(item.data.seed or Seed.derive(0, item.id, "decor")))
	local first = model:FindFirstChildWhichIsA("BasePart")
	model.PrimaryPart = first
	model:SetAttribute("DecorId", item.id)
	CollectionService:AddTag(model, "Decor")
	CollectionService:AddTag(model, TAGS[item.kind] or item.kind)
	model.Parent = parent
	return model, k.parts
end

return SettlementDecor
