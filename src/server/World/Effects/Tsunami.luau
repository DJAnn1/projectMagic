--!strict
--[[
	Tsunami: a Grandmaster Tsunamancy working. The worked example from docs/World.md §10.

	1. ORIGIN     must be open sea: a WorldIndex ocean cell connected to the world edge.
	              A lake or a lagoon can't make a tsunami.
	2. MEASURE    world:castContext(origin, 400): waterVolume comes from the ocean cells around
	              the origin; EnvironmentRules "great_wave" needs ~112k studs³ at P10.
	3. COASTLINE  march from origin toward the target across the coarse grid: the path must stay
	              on connected ocean until it reaches land at an OPEN coast (coastDistance 0)
	              within reach. Otherwise there's no fetch for the wave to build over.
	4. WAVE       World/WaveSimulator: a height field of columns across the front, shoaling over
	              the rising sea floor, running up the land and dying column by column; water
	              slabs are written per contiguous run and cleared above sea level only.
	5. DAMAGE     structures, characters (NPCs too, through Damage), pushes and wooden debris.
	6. AFTERMATH  a short-lived flood that drains; PERSISTENT coastal erosion (grass -> sand,
	              recorded ops), salted farmland (vegetation 0.3, recovers over days), a chronicle
	              entry, and magic pressure for the EventDirector.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local Types = require(Shared.Magic.Types)
local C = require(script.Parent.Parent.WorldConfig)
local WorldIndex = require(script.Parent.Parent.WorldIndex)
local Scheduler = require(script.Parent.Parent.Parent.Core.Scheduler)
local WaveSimulator = require(script.Parent.Parent.WaveSimulator)

export type Report = {
	ok: boolean,
	reason: string?,
	crest: number,
	runup: number,
	landfall: Vector3?,
	collapsed: number,
	hits: number,
	erosionOps: number,
}

local Tsunami = {}

local STEP = 16 -- studs per wave step
local SPEED = 70 -- studs per second
local MAX_REACH = 1800 -- studs from origin to landfall
local ERODIBLE = { "Grass", "LeafyGrass", "Ground", "Mud" }

local function surfaceAt(world: any, x: number, z: number): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	-- Ignore water: we want the ground under it.
	params.IgnoreWater = true
	local hit = workspace:Raycast(Vector3.new(x, 900, z), Vector3.new(0, -1200, 0), params)
	return if hit then hit.Position.Y else world:surfaceHeight(x, z)
end

--[[
	Checks the path from origin toward target: connected open sea, then landfall on an open
	coast within MAX_REACH. Returns (landfall point?, reason?).
]]
function Tsunami.checkCoastline(world: any, origin: Vector3, direction: Vector3): (Vector3?, string?)
	local index = world:index()
	local start = index:cellAt(origin.X, origin.Z)
	if not start.ocean or not start.openSea then
		return nil, "NOT_OPEN_SEA"
	end
	for s = 0, MAX_REACH, C.REGION_SIZE / 2 do
		local p = origin + direction * s
		local cell = index:cellAt(p.X, p.Z)
		if not cell.ocean then
			if cell.coastDistance > 0 then
				return nil, "NO_OPEN_COAST" -- reached land that isn't a shoreline (e.g. through a cliff wall)
			end
			return Vector3.new(p.X, C.SEA_LEVEL, p.Z), nil
		end
		if not cell.openSea then
			return nil, "ENCLOSED_WATER"
		end
	end
	return nil, "NO_LANDFALL_IN_REACH"
end

--[[
	Resolves a validated tsunami. `stats` must come from MagicCore.computeStats with
	world:castContext(origin, ...). Yields for the wave's travel time.
]]
function Tsunami.resolve(world: any, caster: Player?, stats: Types.SpellStats, origin: Vector3, target: Vector3): Report
	local flat = Vector3.new(target.X - origin.X, 0, target.Z - origin.Z)
	local report: Report = { ok = false, crest = 0, runup = 0, collapsed = 0, hits = 0, erosionOps = 0 }
	if flat.Magnitude < 1 then
		report.reason = "NO_DIRECTION"
		return report
	end
	local direction = flat.Unit
	local landfall, reason = Tsunami.checkCoastline(world, origin, direction)
	if not landfall then
		report.reason = reason
		return report
	end
	report.ok, report.landfall = true, landfall

	-- Wave size from spell power: P10 Tsunamancy (~500 power) gives a ~40-stud crest.
	local crest = math.clamp(6 + 34 * math.sqrt(stats.power / 520), 4, 44)
	local width = math.clamp(stats.area * 1.2, 60, 480)
	local maxRunup = math.clamp(stats.area * 1.1, 60, 420)
	report.crest = crest
	Net.fireAll("WorldEffect", { kind = "tsunami", origin = origin, direction = direction, crest = crest, width = width, speed = SPEED })

	-- 4-5. The front itself: WaveSimulator (height-field columns, shoaling, run-up, damage, debris).
	local landfallDistance = (landfall - Vector3.new(origin.X, C.SEA_LEVEL, origin.Z)).Magnitude
	local wave = WaveSimulator.run(world, {
		origin = origin,
		direction = direction,
		width = width,
		crest = crest,
		maxRunup = maxRunup,
		maxDistance = landfallDistance + maxRunup + STEP,
		startAt = math.max(0, landfallDistance - 240), -- the wave rises from open water just before the coast
		writeTerrain = true,
		damagePerStud = 3.2,
		structurePerStud = 4,
		caster = caster,
	})
	report.runup = wave.runup
	report.collapsed = wave.collapsed
	report.hits = wave.hits
	local flooded = wave.flooded
	local terrain = workspace.Terrain

	-- 6. Aftermath: a shallow flood that drains (temporary, not saved)...
	local floodBoxes = {}
	for i = 1, #flooded, 3 do
		local p = flooded[i]
		local ground = surfaceAt(world, p.X, p.Z)
		local cf = CFrame.new(p.X, ground + 2, p.Z)
		terrain:FillBlock(cf, Vector3.new(width * 0.8, 4, 48), Enum.Material.Water)
		table.insert(floodBoxes, { cf = cf, size = Vector3.new(width * 0.8 + 8, 12, 56) })
	end
	task.delay(25, function()
		for _, box in floodBoxes do
			local half = box.size / 2
			local centre = box.cf.Position
			terrain:ReplaceMaterial(Region3.new(centre - half, centre + half):ExpandToGrid(C.VOXEL), C.VOXEL, Enum.Material.Water, Enum.Material.Air)
		end
	end)

	-- ...and PERSISTENT scars: the first stretch of coast turns to sand; farmland is salted.
	local ops = {}
	for i = 1, math.min(#flooded, 10) do
		local p = flooded[i]
		local ground = surfaceAt(world, p.X, p.Z)
		for _, material in ERODIBLE do
			table.insert(ops, { k = "replace", f = material, m = "Sand", x = p.X, y = ground, z = p.Z, sx = width * 0.8, sy = 12, sz = STEP * 3 })
		end
	end
	report.erosionOps = #ops
	if #ops > 0 then
		Scheduler.await(Scheduler.spawn("tsunami erosion", function()
			world:edit("tsunami", ops)
		end, Scheduler.Priority.High))
	end
	local salted: { [string]: boolean } = {}
	for _, p in flooded do
		local rx, rz = WorldIndex.regionOf(p.X, p.Z)
		local id = WorldIndex.regionId(rx, rz)
		if not salted[id] then
			salted[id] = true
			world:setVegetation(p.X, p.Z, 0.3)
		end
	end

	world:noteMagic(origin, stats.domains, stats.power)
	local services = world:services()
	if stats.recipe.power >= 8 then
		task.spawn(services.chronicle.recordEvent, services.chronicle, "tsunami", {
			x = math.floor(landfall.X), z = math.floor(landfall.Z), crest = math.floor(crest),
		})
	end
	return report
end

-- Nearest open-sea point from `position`, scanning 16 bearings outward.
function Tsunami.findOpenSea(world: any, position: Vector3): Vector3?
	local index = world:index()
	local best: Vector3? = nil
	local bestDistance = math.huge
	for b = 0, 15 do
		local angle = b * math.pi / 8
		local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
		for s = 64, MAX_REACH, 64 do
			local p = position + dir * s
			local cell = index:cellAt(p.X, p.Z)
			if cell.ocean and cell.openSea and cell.sample.height < C.SEA_LEVEL - 8 then
				if s < bestDistance then
					best, bestDistance = Vector3.new(p.X, C.SEA_LEVEL, p.Z), s
				end
				break
			end
		end
	end
	return best
end

--[[
	Admin/test entry point (console: `tsunami [power]`): a Grandmaster Tsunamancy caster
	raises a wave from the nearest open sea toward your position.
]]
function Tsunami.adminCast(world: any, player: Player, position: Vector3, power: number): string
	local origin = Tsunami.findOpenSea(world, position)
	if not origin then
		return "no open sea within reach"
	end
	-- Look out from the coast a little further, so the wave has open water to build over.
	local back = (Vector3.new(origin.X, 0, origin.Z) - Vector3.new(position.X, 0, position.Z))
	if back.Magnitude > 0 then
		origin += back.Unit * 200
	end
	local caster: Types.CasterProfile = {
		id = "admin:" .. player.UserId,
		affinities = { water = 0.9 },
		awakened = { water = true },
		mastery = { tsunamancy = 90 },
		unlocked = { water = true, hydromancy = true, tidal = true, tsunamancy = true },
	}
	local recipe = table.clone(Registry.techniques.tsunami.recipe) :: any
	recipe.power = math.clamp(math.floor(power), 1, 10)
	local ctx = world:castContext(origin, 400)
	local stats, errors = MagicCore.computeStats(recipe, caster, ctx)
	if not stats then
		return "invalid: " .. (errors[1] and errors[1].code or "?")
	end
	local env = ctx.environment or {}
	if stats.blockedBy then
		return string.format("blocked by %s (water volume %.0f studs³)", stats.blockedBy, env.waterVolume or 0)
	end
	world:requestArea(position.X, position.Z, 1)
	local report = Tsunami.resolve(world, player, stats, origin, position)
	if not report.ok then
		return "no tsunami: " .. tostring(report.reason)
	end
	return string.format(
		"tsunami P%d: water %.0f studs³ (env x%.2f, resonance x%.2f), crest %.0f, run-up %.0f studs, %d structures collapsed, %d characters hit, %d erosion ops",
		recipe.power, env.waterVolume or 0, stats.environmentFactor, stats.resonance, report.crest, report.runup,
		report.collapsed, report.hits, report.erosionOps
	)
end

return Tsunami
