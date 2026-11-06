--!strict
--[[
	Doors: swinging, locking and auto-closing the door leaves BuildingGenerator makes
	(docs/Buildings.md §2). Server-side; the leaf's CFrame and CanCollide replicate.

	A door is a tagged "Door" part with attributes
		ClosedCFrame / OpenCFrame   world poses (the hinge swing is baked into them)
		Locked                      the lock is engaged (opening needs a key, a pick or magic)
		OwnerLocks                  the owner keeps it locked: it relocks whenever it closes
		LockTier                    1 (simple) .. 2 (good): harder to pick, dearer to unlock by magic
		KeyId                       key items whose definition has data.opens == KeyId open it
		Open                        set here: true while open (clients and NPCs can read it)

		Doors.register(leaf) / unregister(leaf)
		Doors.open(leaf) / Doors.close(leaf) -> boolean     (close refuses while someone stands in it)
		Doors.isOpen(leaf) / Doors.unlock(leaf) / Doors.lock(leaf)
		Doors.near(position, radius) -> { leaf }            spatial lookup (32-stud grid)
		Doors.tick(now)                                      auto-close open doors after AUTO_CLOSE s
		Doors.onChanged = fn(leaf)                           (InteractionService: prompt text)

	Opening sets CanCollide off at once and tweens the leaf 0.4 s; closing tweens back and turns
	collision on at the end. A collapsed building (leaf no longer anchored) never animates.
]]

local TweenService = game:GetService("TweenService")

local AUTO_CLOSE = 7 -- seconds an unattended door stays open
local SWING = TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
local CELL = 32

local Doors = {}

Doors.AUTO_CLOSE = AUTO_CLOSE
Doors.onChanged = nil :: ((BasePart) -> ())?

local openedAt: { [BasePart]: number } = {}
local tweens: { [BasePart]: Tween } = {}
local grid: { [string]: { BasePart } } = {}
local cellOf: { [BasePart]: string } = {}

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude

local function key(x: number, z: number): string
	return math.floor(x / CELL) .. "," .. math.floor(z / CELL)
end

local function closedCFrame(leaf: BasePart): CFrame?
	local cf = leaf:GetAttribute("ClosedCFrame")
	return if typeof(cf) == "CFrame" then cf else nil
end

local function changed(leaf: BasePart)
	local fn = Doors.onChanged
	if fn then
		fn(leaf)
	end
end

function Doors.register(leaf: BasePart)
	local cf = closedCFrame(leaf)
	if not cf or cellOf[leaf] then
		return
	end
	local k = key(cf.Position.X, cf.Position.Z)
	cellOf[leaf] = k
	local list = grid[k] or {}
	grid[k] = list
	table.insert(list, leaf)
	leaf:SetAttribute("Open", false)
	-- Routes may cross a closed door: NPCs open it when they reach it (NPC/NavigationService, which
	-- also refuses a route through a door locked to that NPC). Without this, every building interior
	-- is walled off from the pathfinder.
	if not leaf:FindFirstChildOfClass("PathfindingModifier") then
		local modifier = Instance.new("PathfindingModifier")
		modifier.Label = "NpcDoor"
		modifier.PassThrough = true
		modifier.Parent = leaf
	end
end

function Doors.unregister(leaf: BasePart)
	local k = cellOf[leaf]
	if k then
		local list = grid[k]
		local i = list and table.find(list, leaf)
		if list and i then
			table.remove(list, i)
		end
		cellOf[leaf] = nil
	end
	openedAt[leaf] = nil
	local t = tweens[leaf]
	if t then
		t:Cancel()
		tweens[leaf] = nil
	end
end

function Doors.isOpen(leaf: BasePart): boolean
	return leaf:GetAttribute("Open") == true
end

local function swing(leaf: BasePart, target: CFrame, onDone: (() -> ())?)
	local previous = tweens[leaf]
	if previous then
		previous:Cancel()
	end
	if not leaf.Anchored then
		return -- the building collapsed; the leaf is loose rubble now
	end
	local tween = TweenService:Create(leaf, SWING, { CFrame = target })
	tweens[leaf] = tween
	tween.Completed:Connect(function(state)
		if tweens[leaf] == tween then
			tweens[leaf] = nil
		end
		if state == Enum.PlaybackState.Completed and onDone then
			onDone()
		end
	end)
	tween:Play()
end

function Doors.open(leaf: BasePart): boolean
	local target = leaf:GetAttribute("OpenCFrame")
	if typeof(target) ~= "CFrame" or Doors.isOpen(leaf) then
		return false
	end
	leaf:SetAttribute("Open", true)
	leaf.CanCollide = false
	openedAt[leaf] = os.clock()
	swing(leaf, target)
	changed(leaf)
	return true
end

-- Anyone (player or NPC) standing where the closed leaf would be?
function Doors.occupied(leaf: BasePart): boolean
	local cf = closedCFrame(leaf)
	if not cf then
		return false
	end
	overlap.FilterDescendantsInstances = { leaf }
	for _, p in workspace:GetPartBoundsInBox(cf, leaf.Size + Vector3.new(0.4, -0.5, 2.4), overlap) do
		local model = p:FindFirstAncestorOfClass("Model")
		if model and model:FindFirstChildOfClass("Humanoid") then
			return true
		end
	end
	return false
end

function Doors.close(leaf: BasePart): boolean
	local target = closedCFrame(leaf)
	if not target or not Doors.isOpen(leaf) then
		return false
	end
	if Doors.occupied(leaf) then
		return false
	end
	leaf:SetAttribute("Open", false)
	openedAt[leaf] = nil
	if leaf:GetAttribute("OwnerLocks") == true then
		leaf:SetAttribute("Locked", true)
	end
	swing(leaf, target, function()
		if not Doors.isOpen(leaf) then
			leaf.CanCollide = true
		end
	end)
	changed(leaf)
	return true
end

function Doors.unlock(leaf: BasePart)
	leaf:SetAttribute("Locked", false)
	changed(leaf)
end

function Doors.lock(leaf: BasePart)
	leaf:SetAttribute("Locked", true)
	changed(leaf)
end

-- Doors whose closed position is within `radius` of a point (grid lookup, no physics query).
function Doors.near(position: Vector3, radius: number): { BasePart }
	local out: { BasePart } = {}
	local cx, cz = math.floor(position.X / CELL), math.floor(position.Z / CELL)
	for dz = -1, 1 do
		for dx = -1, 1 do
			for _, leaf in (grid[(cx + dx) .. "," .. (cz + dz)] or {}) :: { BasePart } do
				local cf = closedCFrame(leaf)
				if cf and (cf.Position - position).Magnitude <= radius then
					table.insert(out, leaf)
				end
			end
		end
	end
	return out
end

function Doors.count(): number
	local n = 0
	for _ in cellOf do
		n += 1
	end
	return n
end

-- Closes doors left open longer than AUTO_CLOSE (retries next tick while someone stands in one).
function Doors.tick(now: number)
	for leaf, t in openedAt do
		if not leaf.Parent then
			Doors.unregister(leaf)
		elseif now - t >= AUTO_CLOSE then
			Doors.close(leaf)
		end
	end
end

return Doors
