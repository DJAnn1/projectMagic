--!strict
--[[
	CharacterSafety: keeps players from being trapped in, or dropped through, changing terrain.

	Terrain changes under people: quakes, landslides and fault ruptures fill rock, stone walls rise,
	admin tools carve and rebuild chunks. When solid terrain appears where a character stands,
	physics shoves it out, sometimes DOWN, through the floor and out of the world. So:

	  checkArea(center, radius)   right after an edit: any character whose root sits inside solid
	                              terrain is lifted onto the surface above (WorldStateService.edit,
	                              TerrainDeform.raiseStone)
	  holdArea(min, max) -> release()   freezes characters in a box (anchored roots) while that box
	                              is rebuilt (resetChunk), then puts them on the new surface
	  start(world)                a 0.5 s safety net: anyone embedded for two checks in a row, or
	                              below bedrock (falling into the void), goes back onto dry land
	                              before FallenPartsDestroyHeight kills them
	  guardSpawns(getSpawn)       1 s and 3 s after every spawn, anyone in water (or standing
	                              over it) is moved to the spawn point
	Caves are fine: a character in a cave stands in an AIR voxel, so it is never "embedded".
	Ice is ignored on purpose: freezing water around swimmers traps them (InteractionMatrix
	"freeze"); that ice reverts on its own.
]]

local Players = game:GetService("Players")

local C = require(script.Parent.WorldConfig)

local CHECK_INTERVAL = 0.5
local VOID_MARGIN = 16 -- studs below bedrock that count as "fell out of the world"
local SOLID = 0.5 -- voxel occupancy that counts as stuck

local CharacterSafety = {}

local world: any = nil
local strikes: { [Player]: number } = {}
local rescued = 0

local terrainOnly = RaycastParams.new()
terrainOnly.FilterType = Enum.RaycastFilterType.Include
terrainOnly.FilterDescendantsInstances = { workspace.Terrain }
terrainOnly.IgnoreWater = false

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- True when the voxel at a point is solid terrain (not air, water or ice).
local PASSABLE: { [Enum.Material]: boolean } = {
	[Enum.Material.Air] = true,
	[Enum.Material.Water] = true,
	[Enum.Material.Ice] = true,
}

function CharacterSafety.embedded(position: Vector3): boolean
	local half = Vector3.new(0.1, 0.1, 0.1)
	local region = Region3.new(position - half, position + half):ExpandToGrid(C.VOXEL)
	local ok, materials, occupancies = pcall(function()
		return workspace.Terrain:ReadVoxels(region, C.VOXEL)
	end)
	if not ok then
		return false
	end
	local m = materials[1] and materials[1][1] and materials[1][1][1]
	local o = occupancies[1] and occupancies[1][1] and occupancies[1][1][1]
	return m ~= nil and not PASSABLE[m] and (o or 0) > SOLID
end

-- The top terrain surface at (x, z) (water counts: a rescued swimmer floats), or nil.
local function surfaceAt(x: number, z: number): number?
	local from = Vector3.new(x, C.MAX_HEIGHT + 300, z)
	local hit = workspace:Raycast(from, Vector3.new(0, C.BEDROCK_Y - from.Y - 10, 0), terrainOnly)
	return if hit then hit.Position.Y else nil
end

-- Puts a character on the surface above where it is (or the nearest dry land), stopped.
function CharacterSafety.rescue(player: Player, reason: string)
	local root = rootOf(player)
	local character = player.Character
	if not root or not character then
		return
	end
	local p = root.Position
	local y = surfaceAt(p.X, p.Z)
	local target: Vector3
	if y then
		target = Vector3.new(p.X, y + 4, p.Z)
	elseif world then
		local x, gy, z = world:findDryLand(p.X, p.Z, 128)
		target = Vector3.new(x, gy + 4, z)
	else
		return
	end
	character:PivotTo(CFrame.new(target) * (root.CFrame - root.Position))
	root.AssemblyLinearVelocity = Vector3.zero
	strikes[player] = nil
	rescued += 1
	if world and world.logRescue then
		world:logRescue(player, reason, p, target)
	end
end

-- After a terrain edit: lift anyone now standing inside solid terrain near it.
function CharacterSafety.checkArea(center: Vector3, radius: number)
	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		if root and (root.Position - center).Magnitude <= radius + 8 and CharacterSafety.embedded(root.Position) then
			CharacterSafety.rescue(player, "embedded after terrain edit")
		end
	end
end

--[[
	Freezes every character inside a box (e.g. a chunk being rebuilt, which is empty for a few
	frames). Returns release(), which unanchors them and puts them on the rebuilt surface.
]]
function CharacterSafety.holdArea(min: Vector3, max: Vector3): () -> ()
	local held: { [Player]: BasePart } = {}
	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		local p = root and root.Position
		if root and p and p.X >= min.X and p.X <= max.X and p.Z >= min.Z and p.Z <= max.Z then
			root.Anchored = true
			held[player] = root
		end
	end
	return function()
		for player, root in held do
			if root.Parent then
				root.Anchored = false
				if CharacterSafety.embedded(root.Position) or not surfaceAt(root.Position.X, root.Position.Z) or root.Position.Y < (surfaceAt(root.Position.X, root.Position.Z) or 0) - 2 then
					CharacterSafety.rescue(player, "chunk rebuilt under them")
				end
			end
		end
	end
end

-- True when a character root is in water or just above it (feet in the water).
local function inWater(position: Vector3): boolean
	local half = Vector3.new(0.1, 0.1, 0.1)
	for _, offset in { Vector3.zero, Vector3.new(0, -3, 0) } do
		local p = position + offset
		local region = Region3.new(p - half, p + half):ExpandToGrid(C.VOXEL)
		local ok, materials, occupancies = pcall(function()
			return workspace.Terrain:ReadVoxels(region, C.VOXEL)
		end)
		if ok then
			local m = materials[1] and materials[1][1] and materials[1][1][1]
			local o = occupancies[1] and occupancies[1][1] and occupancies[1][1][1]
			if m == Enum.Material.Water and (o or 0) > 0.5 then
				return true
			end
		end
	end
	return false
end

-- After every spawn: anyone who appears in water is moved to the spawn point (`getSpawn`).
function CharacterSafety.guardSpawns(getSpawn: () -> Vector3?)
	local function watch(player: Player, character: Model)
		for _, delay in { 1, 2 } do
			task.wait(delay)
			if player.Character ~= character then
				return
			end
			local root = rootOf(player)
			local spawnAt = getSpawn()
			if root and spawnAt and inWater(root.Position) then
				local from = root.Position -- before the move, or the log reports the destination
				character:PivotTo(CFrame.new(spawnAt + Vector3.new(0, 3, 0)))
				root.AssemblyLinearVelocity = Vector3.zero
				rescued += 1
				if world and world.logRescue then
					world:logRescue(player, "spawned in water", from, spawnAt)
				end
				return
			end
		end
	end
	local function track(player: Player)
		player.CharacterAdded:Connect(function(character)
			task.spawn(watch, player, character)
		end)
		if player.Character then
			task.spawn(watch, player, player.Character)
		end
	end
	Players.PlayerAdded:Connect(track)
	for _, player in Players:GetPlayers() do
		track(player)
	end
end

function CharacterSafety.rescuedCount(): number
	return rescued
end

-- The safety net loop.
function CharacterSafety.start(worldService: any)
	world = worldService
	-- The void line sits well above Roblox's kill plane, so the net always catches first.
	if workspace.FallenPartsDestroyHeight > C.BEDROCK_Y - VOID_MARGIN - 200 then
		workspace.FallenPartsDestroyHeight = C.BEDROCK_Y - VOID_MARGIN - 200
	end
	Players.PlayerRemoving:Connect(function(player)
		strikes[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(CHECK_INTERVAL)
			for _, player in Players:GetPlayers() do
				local root = rootOf(player)
				if not root or root.Anchored then
					continue
				end
				local p = root.Position
				if p.Y < C.BEDROCK_Y - VOID_MARGIN then
					CharacterSafety.rescue(player, "fell below the world")
				elseif CharacterSafety.embedded(p) then
					-- Two checks in a row, so a character merely brushing a wall isn't moved.
					strikes[player] = (strikes[player] or 0) + 1
					if strikes[player] >= 2 then
						CharacterSafety.rescue(player, "stuck in terrain")
					end
				else
					strikes[player] = nil
				end
			end
		end
	end)
end

return CharacterSafety
