--!strict
--[[
	WaveSimulator: a moving wave front, simulated as a 1D height field of COLUMNS across the
	front (wave.columnWidth studs each), advancing wave.step studs per step. Cheap enough for a
	server, rich enough that coastlines shape the wave instead of it being one flat wall.

	Per column, per step:
		at sea     Green's law shoaling: crest = crest0 * (depth0 / depth)^(1/4), so the wave
		           steepens as the sea floor rises (capped at 2.2x the open-water crest)
		on land    run-up: the crest loses wave.runupFriction per stud travelled inland and
		           wave.slopeLoss per stud of ground above sea level; a column dies at <= 1 stud
		laterally  diffusion between neighbouring live columns (wave.smoothing), so a headland
		           bends the front instead of slicing it
	Writing terrain (tsunamis only): live columns are merged into contiguous RUNS; each run is one
	FillBlock of water, and the previous step's runs are cleared (water -> air, ONLY above sea
	level, so the sea itself is never touched). A 30-column wave costs a few FillBlocks per step.
	Damage, pushes and debris are applied per run on land, through Damage and the parts budget.

	run() yields for the wave's travel time and returns a Report.
]]

local Players = game:GetService("Players")

local Server = script.Parent.Parent
local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local C = require(script.Parent.WorldConfig)
local T = require(Server.Magic.Data.CastTuning)
local Targeting = require(Server.Magic.Cast.Targeting)
local Damage = require(Server.Magic.Cast.Damage)
local EffectBudget = require(Server.Magic.Cast.EffectBudget)

local W = T.wave
local MAX_DEBRIS = 16

export type Params = {
	origin: Vector3, -- start of the front's centre line (y ignored)
	direction: Vector3, -- unit, horizontal
	width: number,
	crest: number, -- open-water crest height (studs)
	maxRunup: number, -- studs inland before every column dies
	maxDistance: number, -- studs from origin before the run ends regardless
	startAt: number, -- studs along the line where simulation starts
	baseLevel: number?, -- the "sea level" the wave rides on (default C.SEA_LEVEL; small spell waves use the ground at their origin)
	writeTerrain: boolean,
	damagePerStud: number, -- character damage per stud of crest
	structurePerStud: number, -- structure damage per stud of crest
	caster: Player?,
	onLand: ((p: Vector3) -> ())?, -- called once per run per step on land (flooded points)
}

export type Report = {
	runup: number,
	landed: number, -- columns that reached land
	collapsed: number,
	hits: number,
	debris: number,
	flooded: { Vector3 },
}

type Column = { offset: number, crest: number, inland: number, alive: boolean, depth0: number?, effective: number, ground: number }
type Run = { first: number, last: number, centre: Vector3, height: number, bottom: number, onLand: boolean }

local WaveSimulator = {}

local function groundAt(world: any, x: number, z: number): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	params.IgnoreWater = true
	local hit = workspace:Raycast(Vector3.new(x, 900, z), Vector3.new(0, -1200, 0), params)
	return if hit then hit.Position.Y else world:surfaceHeight(x, z)
end

-- Clears the water slabs a step wrote: each run's axis-aligned bounds, padded, and never below
-- sea level + 1 (ExpandToGrid then snaps to the sea surface voxel at worst, never into the sea).
local function clearRuns(runs: { Run }, direction: Vector3)
	for _, run in runs do
		local runWidth = (run.last - run.first + 1) * W.columnWidth
		-- The slab is runWidth along `across` (= (-dz, 0, dx)) and 12 studs along `direction`.
		local hx = math.abs(direction.Z) * runWidth / 2 + math.abs(direction.X) * 6 + 4
		local hz = math.abs(direction.X) * runWidth / 2 + math.abs(direction.Z) * 6 + 4
		local lo = Vector3.new(run.centre.X - hx, math.max(C.SEA_LEVEL + 1, run.bottom - 2), run.centre.Z - hz)
		local hi = Vector3.new(run.centre.X + hx, run.bottom + run.height + 6, run.centre.Z + hz)
		if hi.Y > lo.Y then
			workspace.Terrain:ReplaceMaterial(Region3.new(lo, hi):ExpandToGrid(C.VOXEL), C.VOXEL, Enum.Material.Water, Enum.Material.Air)
		end
	end
end

local function push(position: Vector3, radius: number, direction: Vector3, speed: number)
	local params = OverlapParams.new()
	params.MaxParts = 120
	local pushed: { [BasePart]: boolean } = {}
	local candidates: { BasePart } = {}
	for _, part in workspace:GetPartBoundsInRadius(position, radius, params) do
		local root = if part.Anchored then nil else part.AssemblyRootPart
		if root and not pushed[root] then
			pushed[root] = true
			table.insert(candidates, root)
		end
	end
	local granted = EffectBudget.takeParts(#candidates)
	for i = 1, granted do
		local root = candidates[i]
		local velocity = direction * speed + Vector3.new(0, speed * 0.3, 0)
		local hit = Targeting.characterOf(root)
		local player = hit and Players:GetPlayerFromCharacter(hit.model)
		if player then
			Net.fire("WorldEffect", player, { kind = "knockback", velocity = velocity })
		else
			root.AssemblyLinearVelocity += velocity
		end
	end
end

local function spawnDebris(position: Vector3, direction: Vector3): boolean
	if EffectBudget.takeParts(1) < 1 then
		return false
	end
	local plank = Instance.new("Part")
	plank.Name = "WaveDebris"
	plank.Size = Vector3.new(6, 0.6, 1.2)
	plank.Material = Enum.Material.WoodPlanks
	plank.Color = Color3.fromRGB(110, 82, 55)
	plank.CFrame = CFrame.new(position + Vector3.new(0, 4, 0)) * CFrame.Angles(math.random() * 3, math.random() * 3, 0)
	plank.AssemblyLinearVelocity = direction * 40 + Vector3.new(0, 15, 0)
	plank.Parent = workspace
	game:GetService("Debris"):AddItem(plank, 30)
	return true
end

function WaveSimulator.run(world: any, p: Params): Report
	local report: Report = { runup = 0, landed = 0, collapsed = 0, hits = 0, debris = 0, flooded = {} }
	local direction = Vector3.new(p.direction.X, 0, p.direction.Z).Unit
	local across = Vector3.new(-direction.Z, 0, direction.X)
	local count = math.max(1, math.floor(p.width / W.columnWidth))
	local level = p.baseLevel or C.SEA_LEVEL
	local columns: { Column } = {}
	for i = 1, count do
		table.insert(columns, {
			offset = (i - (count + 1) / 2) * W.columnWidth,
			crest = p.crest,
			inland = 0,
			alive = true,
			depth0 = nil,
			effective = p.crest,
			ground = level,
		})
	end
	local hitHumanoids: { [Humanoid]: boolean } = {}
	local previousRuns: { Run } = {}
	local base = Vector3.new(p.origin.X, level, p.origin.Z)

	local s = p.startAt
	while s <= p.maxDistance do
		-- 1. Advance every live column.
		local anyAlive = false
		for _, col in columns do
			if not col.alive then
				continue
			end
			local point = base + direction * s + across * col.offset
			local ground = groundAt(world, point.X, point.Z)
			col.ground = ground
			local depth = level - ground
			if depth > 0 then
				col.depth0 = col.depth0 or math.max(depth, W.minDepth)
				local shoal = ((col.depth0 :: number) / math.max(depth, W.minDepth)) ^ W.shoalingExponent
				col.effective = math.min(p.crest * 2.2, col.crest * shoal)
			else
				if col.inland == 0 then
					report.landed += 1
				end
				col.inland += W.step
				col.crest -= W.runupFriction * W.step * math.sqrt(p.crest)
				col.effective = col.crest - W.slopeLoss * (ground - level)
				report.runup = math.max(report.runup, col.inland)
			end
			if col.effective <= 1 or col.inland >= p.maxRunup then
				col.alive = false
			else
				anyAlive = true
			end
		end
		if not anyAlive then
			break
		end

		-- 2. Lateral diffusion between live neighbours.
		local smoothed: { number } = {}
		for i, col in columns do
			if col.alive then
				local left = columns[i - 1]
				local right = columns[i + 1]
				local l = if left and left.alive then left.effective else col.effective
				local r = if right and right.alive then right.effective else col.effective
				smoothed[i] = col.effective * (1 - W.smoothing) + (l + r) * 0.5 * W.smoothing
			end
		end
		for i, value in smoothed do
			columns[i].effective = value
		end

		-- 3. Merge live columns into runs.
		local runs: { Run } = {}
		local current: Run? = nil
		for i, col in columns do
			if col.alive then
				local onLand = col.inland > 0
				local cur = current
				if cur and cur.last == i - 1 and cur.onLand == onLand then
					cur.last = i
					cur.height = math.max(cur.height, col.effective)
					cur.bottom = math.min(cur.bottom, math.max(level, col.ground))
				else
					current = { first = i, last = i, centre = Vector3.zero, height = col.effective, bottom = math.max(level, col.ground), onLand = onLand }
					table.insert(runs, current :: Run)
				end
			else
				current = nil
			end
		end
		for _, run in runs do
			local mid = (columns[run.first].offset + columns[run.last].offset) / 2
			run.centre = base + direction * s + across * mid
		end

		-- 4. Terrain: clear last step's water above sea level, write this step's slabs.
		if p.writeTerrain then
			clearRuns(previousRuns, direction)
			for _, run in runs do
				local runWidth = (run.last - run.first + 1) * W.columnWidth
				local cf = CFrame.lookAt(
					Vector3.new(run.centre.X, run.bottom + run.height / 2, run.centre.Z),
					Vector3.new(run.centre.X + direction.X, run.bottom + run.height / 2, run.centre.Z + direction.Z)
				)
				workspace.Terrain:FillBlock(cf, Vector3.new(runWidth, run.height, 12), Enum.Material.Water)
			end
			previousRuns = runs
		end

		-- 5. Damage, push and debris where the wave is on land.
		for _, run in runs do
			if run.onLand then
				local runWidth = (run.last - run.first + 1) * W.columnWidth
				local radius = math.max(runWidth / 2, 12)
				table.insert(report.flooded, run.centre)
				if p.onLand then
					p.onLand(run.centre)
				end
				local collapsed = world:damageStructures(run.centre, radius, p.structurePerStud * run.height, "wave")
				report.collapsed += collapsed
				for _ = 1, collapsed do
					if report.debris < MAX_DEBRIS and spawnDebris(run.centre, direction) then
						report.debris += 1
					end
				end
				for _, hit in Targeting.inRadius(run.centre, radius, 20) do
					local player = Players:GetPlayerFromCharacter(hit.model)
					-- The sea doesn't spare its caller; other players only with PvP (Targeting).
					if hit.model == (p.caster and p.caster.Character) or not player or (p.caster and Targeting.canHarm(p.caster, hit.model)) then
						Damage.apply(hit.humanoid, p.damagePerStud * run.height * 0.25, p.caster and p.caster.UserId, "wave")
						hitHumanoids[hit.humanoid] = true
					end
				end
				push(run.centre, radius, direction, 20 + run.height)
			end
		end

		s += W.step
		task.wait(W.step / W.speed)
	end
	if p.writeTerrain then
		clearRuns(previousRuns, direction)
	end
	for _ in hitHumanoids do
		report.hits += 1
	end
	return report
end

return WaveSimulator
