--!strict
--[[
	TerrainDeform: every way magic reshapes terrain, in two strictly separated kinds.

	TEMPORARY (applied directly, NOT saved, reverted on a timer; per server only)
		raiseStone   walls, pillars and spikes of MAGIC STONE (Granite: no biome uses it, so the
		             revert, Granite -> Air in the same box, can never eat natural terrain)
		pour         a ball of water where there was no water (the revert only runs if the spot was
		             dry when poured, so a lake is never drained)
		freeze       the water surface turns to Ice; melt/revert turns that Ice back to Water
	PERSISTENT (recorded through WorldStateService:edit, replayed by every server, forever)
		faultRupture fissure + uplift + subsidence along the local fault (Earthquake)
		landslide    the slope's top is carved away and deposited downhill
		scorch       burned grass becomes ground (FireSim)
	Only carving and natural materials are persistent; nothing persistent is ever additive magic
	stone, so the saved world never fills up with spell junk.

	Budget: every op spends one token from EffectBudget.takeTerrainOps; when the bucket is dry,
	builders return fewer ops (smaller deformation) instead of stalling the server.
	commit() runs inside a Scheduler job because WorldStateService:edit checkpoints.
]]

local Server = script.Parent.Parent
local C = require(script.Parent.WorldConfig)
local Scheduler = require(Server.Core.Scheduler)
local EffectBudget = require(Server.Magic.Cast.EffectBudget)
local CharacterSafety = require(script.Parent.CharacterSafety)

local STONE = Enum.Material.Granite
local ICE = Enum.Material.Ice

type Freeze = { region: Region3, expires: number }

local TerrainDeform = {}

local frozen: { Freeze } = {}

local function terrainParams(ignoreWater: boolean): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	params.IgnoreWater = ignoreWater
	return params
end

-- Ground height (ignoring water), and the material there.
function TerrainDeform.surfaceAt(world: any, x: number, z: number): (number, Enum.Material?)
	local hit = workspace:Raycast(Vector3.new(x, 900, z), Vector3.new(0, -1200, 0), terrainParams(true))
	if hit then
		return hit.Position.Y, hit.Material
	end
	return world:surfaceHeight(x, z), nil
end

local function regionOf(cframe: CFrame, size: Vector3): Region3
	-- Axis-aligned bounds of a possibly rotated box, padded one voxel, snapped to the grid.
	local half = size / 2
	local corners = {}
	for _, sx in { -1, 1 } do
		for _, sy in { -1, 1 } do
			for _, sz in { -1, 1 } do
				table.insert(corners, cframe:PointToWorldSpace(Vector3.new(half.X * sx, half.Y * sy, half.Z * sz)))
			end
		end
	end
	local min, max = corners[1], corners[1]
	for _, c in corners do
		min = min:Min(c)
		max = max:Max(c)
	end
	local pad = Vector3.new(C.VOXEL, C.VOXEL, C.VOXEL)
	return Region3.new(min - pad, max + pad):ExpandToGrid(C.VOXEL)
end

-- ─── Temporary ──────────────────────────────────────────────────────────────

-- A block of magic stone that sinks back after `lifetime`. False when the budget is dry.
function TerrainDeform.raiseStone(cframe: CFrame, size: Vector3, lifetime: number): boolean
	if EffectBudget.takeTerrainOps(2) < 2 then -- the fill and its revert
		return false
	end
	workspace.Terrain:FillBlock(cframe, size, STONE)
	-- Anyone the stone rose inside stands on top of it instead of being shoved through the floor.
	CharacterSafety.checkArea(cframe.Position, size.Magnitude / 2)
	local region = regionOf(cframe, size)
	task.delay(lifetime, function()
		workspace.Terrain:ReplaceMaterial(region, C.VOXEL, STONE, Enum.Material.Air)
	end)
	return true
end

-- Water called out of nothing. Refused where water already is (we'd drain it on revert).
function TerrainDeform.pour(world: any, position: Vector3, radius: number, lifetime: number): boolean
	if world:waterVolumeAt(position, radius * 2) > 1 or position.Y < C.SEA_LEVEL + 2 then
		return false
	end
	if EffectBudget.takeTerrainOps(2) < 2 then
		return false
	end
	workspace.Terrain:FillBall(position, radius, Enum.Material.Water)
	local size = Vector3.new(radius, radius, radius) * 2
	local region = regionOf(CFrame.new(position), size)
	task.delay(lifetime, function()
		workspace.Terrain:ReplaceMaterial(region, C.VOXEL, Enum.Material.Water, Enum.Material.Air)
	end)
	return true
end

-- Freezes the water surface around a point (a slab from 4 studs under the surface to just above).
function TerrainDeform.freeze(_world: any, position: Vector3, radius: number, lifetime: number): boolean
	local hit = workspace:Raycast(position + Vector3.new(0, 30, 0), Vector3.new(0, -80, 0), terrainParams(false))
	if not hit or hit.Material ~= Enum.Material.Water then
		return false
	end
	if EffectBudget.takeTerrainOps(2) < 2 then
		return false
	end
	local y = hit.Position.Y
	local region = Region3.new(
		Vector3.new(position.X - radius, y - 4, position.Z - radius),
		Vector3.new(position.X + radius, y + 1, position.Z + radius)
	):ExpandToGrid(C.VOXEL)
	workspace.Terrain:ReplaceMaterial(region, C.VOXEL, Enum.Material.Water, ICE)
	local entry: Freeze = { region = region, expires = os.clock() + lifetime }
	table.insert(frozen, entry)
	task.delay(lifetime, function()
		local index = table.find(frozen, entry)
		if index then
			table.remove(frozen, index)
			workspace.Terrain:ReplaceMaterial(region, C.VOXEL, ICE, Enum.Material.Water)
		end
	end)
	return true
end

-- Melts magic ice early (heat or fire on it). Returns how many frozen patches melted.
function TerrainDeform.meltAt(position: Vector3, radius: number): number
	local melted = 0
	for i = #frozen, 1, -1 do
		local entry = frozen[i]
		local centre = entry.region.CFrame.Position
		if Vector3.new(centre.X - position.X, 0, centre.Z - position.Z).Magnitude <= radius + entry.region.Size.X / 2 then
			table.remove(frozen, i)
			workspace.Terrain:ReplaceMaterial(entry.region, C.VOXEL, ICE, Enum.Material.Water)
			melted += 1
		end
	end
	return melted
end

-- ─── Persistent ─────────────────────────────────────────────────────────────

--[[
	A fault rupture: an open fissure along `along`, uplift on one side, subsidence on the other,
	and scattered cracks. Op count scales with magnitude, capped by maxOps and the budget.
]]
function TerrainDeform.faultRupture(world: any, epicenter: Vector3, along: Vector3, radius: number, magnitude: number, rng: Random, maxOps: number): { any }
	local ops = {}
	local cap = EffectBudget.takeTerrainOps(maxOps)
	local function add(op: any)
		if #ops < cap then
			table.insert(ops, op)
		end
	end
	local across = Vector3.new(-along.Z, 0, along.X)
	local length = radius * 0.9
	local fissureRadius = 3 + magnitude * 0.8
	local uplift = magnitude * 1.5
	for s = -length, length, 10 do
		local jitter = (rng:NextNumber() - 0.5) * magnitude * 2
		local p = epicenter + along * s + across * jitter
		local ground = TerrainDeform.surfaceAt(world, p.X, p.Z)
		add({ k = "ball", m = "Air", x = p.X, y = ground - fissureRadius * 0.3, z = p.Z, r = fissureRadius })
		if math.abs(s) % 20 < 10 then
			local up = p + across * (fissureRadius * 2.5)
			add({ k = "ball", m = "Rock", x = up.X, y = TerrainDeform.surfaceAt(world, up.X, up.Z) + uplift * 0.5, z = up.Z, r = 4 + uplift })
			local down = p - across * (fissureRadius * 2.5)
			add({ k = "ball", m = "Air", x = down.X, y = TerrainDeform.surfaceAt(world, down.X, down.Z) + 2, z = down.Z, r = 3 + uplift * 0.7 })
		end
	end
	for _ = 1, math.floor(magnitude * 4) do
		local angle, distance = rng:NextNumber() * math.pi * 2, rng:NextNumber() * radius
		local cx, cz = epicenter.X + math.cos(angle) * distance, epicenter.Z + math.sin(angle) * distance
		add({ k = "ball", m = "Air", x = cx, y = TerrainDeform.surfaceAt(world, cx, cz), z = cz, r = rng:NextNumber(2, 4) })
	end
	return ops
end

--[[
	A landslide on the slope at `center`: carves the upper slope and deposits the same material
	downhill. Returns (ops, downhill direction) or (nil, reason) when the ground is too flat.
]]
function TerrainDeform.landslide(world: any, center: Vector3, radius: number, rng: Random): ({ any }?, Vector3 | string)
	local step = 8
	local hx1 = TerrainDeform.surfaceAt(world, center.X + step, center.Z)
	local hx0 = TerrainDeform.surfaceAt(world, center.X - step, center.Z)
	local hz1 = TerrainDeform.surfaceAt(world, center.X, center.Z + step)
	local hz0 = TerrainDeform.surfaceAt(world, center.X, center.Z - step)
	local gradient = Vector3.new(hx1 - hx0, 0, hz1 - hz0) / (2 * step)
	if gradient.Magnitude < 0.15 then
		return nil, "TOO_FLAT"
	end
	local downhill = -gradient.Unit
	local _, material = TerrainDeform.surfaceAt(world, center.X, center.Z)
	local deposit = if material and material ~= Enum.Material.Water then material.Name else "Ground"
	local ops = {}
	local cap = EffectBudget.takeTerrainOps(24)
	local r = math.clamp(radius, 6, 40)
	for i = 1, 6 do
		if #ops + 2 > cap then
			break
		end
		local offset = Vector3.new((rng:NextNumber() - 0.5) * r, 0, (rng:NextNumber() - 0.5) * r)
		local top = center - downhill * r * 0.4 + offset
		local topY = TerrainDeform.surfaceAt(world, top.X, top.Z)
		table.insert(ops, { k = "ball", m = "Air", x = top.X, y = topY - 1, z = top.Z, r = r * 0.35 })
		local bottom = center + downhill * r * (1.2 + 0.15 * i) + offset * 0.6
		local bottomY = TerrainDeform.surfaceAt(world, bottom.X, bottom.Z)
		table.insert(ops, { k = "ball", m = deposit, x = bottom.X, y = bottomY + r * 0.1, z = bottom.Z, r = r * 0.3 })
	end
	return ops, downhill
end

-- Burned grass under a point becomes bare ground (FireSim aftermath).
function TerrainDeform.scorchOps(world: any, position: Vector3): { any }
	if EffectBudget.takeTerrainOps(2) < 2 then
		return {}
	end
	local y = TerrainDeform.surfaceAt(world, position.X, position.Z)
	return {
		{ k = "replace", f = "Grass", m = "Ground", x = position.X, y = y, z = position.Z, sx = 8, sy = 6, sz = 8 },
		{ k = "replace", f = "LeafyGrass", m = "Ground", x = position.X, y = y, z = position.Z, sx = 8, sy = 6, sz = 8 },
	}
end

-- Records persistent ops (yields until written). Returns how many were applied.
function TerrainDeform.commit(world: any, cause: string, ops: { any }): number
	if #ops == 0 then
		return 0
	end
	Scheduler.await(Scheduler.spawn("terrain " .. cause, function()
		world:edit(cause, ops)
	end, Scheduler.Priority.High))
	return #ops
end

return TerrainDeform
