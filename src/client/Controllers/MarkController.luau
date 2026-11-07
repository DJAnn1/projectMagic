--!strict
--[[
	MarkController: draws everyone's Magic Marks (docs/MagicMarks.md). The server decides who is
	marked (Services/MarkService) and says so with the tag "MagicMarked" and the attribute
	"MagicMarks" on the character or NPC rig; this only draws what it's told.

	DRAWING   Bodies within drawWithin studs of the camera get Fx/MarkFx; past dropBeyond the drawing
	          goes. Checked twice a second, so a crowd costs nothing until you're near it.
	PRINTS    From stage 2, a mark with `prints` leaves a footprint every printEvery studs walked,
	          for bodies within printsWithin studs, fading over its life. At most printsMax at once.

	No remotes, no settings: marks are part of how people look.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local MarkRules = require(Shared.Magic.MarkRules)
local MarkData = require(Shared.Magic.Data.Marks)

local MarkFx = require(script.Parent.Parent:WaitForChild("Fx"):WaitForChild("MarkFx"))

local T = MarkData.tuning
local TAG = "MagicMarked"
local ATTRIBUTE = "MagicMarks"

local MarkController = {
	name = "MarkController",
	dependencies = {},
}

type Tracked = {
	model: Model,
	raw: string?,
	handle: MarkFx.Handle?,
	prints: MarkData.Prints?,
	lastStep: Vector3?,
	foot: number,
	changed: RBXScriptConnection?,
}

local tracked: { [Model]: Tracked } = {}
local folder: Folder? = nil
local printQueue: { BasePart } = {}

local function folderOf(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "MarkFx"
	made.Parent = workspace
	folder = made
	return made
end

local function undraw(t: Tracked)
	local handle = t.handle
	if handle then
		t.handle = nil
		handle:destroy()
	end
end

local function draw(t: Tracked)
	undraw(t)
	local marks = MarkRules.decode(t.raw)
	t.handle = MarkFx.build(t.model, marks, folderOf())
end

-- The footprint style: the strongest mark at stage 2+ that leaves prints.
local function printsFor(raw: string?): MarkData.Prints?
	for _, mark in MarkRules.decode(raw) do
		local def = MarkData.domains[mark.domain]
		if mark.stage >= 2 and def and def.look.prints then
			return def.look.prints
		end
	end
	return nil
end

local function refreshMarks(t: Tracked)
	local raw = t.model:GetAttribute(ATTRIBUTE)
	t.raw = if typeof(raw) == "string" and raw ~= "" then raw else nil
	t.prints = printsFor(t.raw)
	t.lastStep = nil
	if t.handle then
		draw(t) -- already in view: redraw at the new stage
	end
end

local function track(instance: Instance)
	if not instance:IsA("Model") or tracked[instance] then
		return
	end
	local t: Tracked = { model = instance, raw = nil, handle = nil, prints = nil, lastStep = nil, foot = 1, changed = nil }
	tracked[instance] = t
	t.changed = instance:GetAttributeChangedSignal(ATTRIBUTE):Connect(function()
		refreshMarks(t)
	end)
	refreshMarks(t)
end

local function untrack(instance: Instance)
	local t = tracked[instance :: Model]
	if not t then
		return
	end
	tracked[instance :: Model] = nil
	undraw(t)
	if t.changed then
		t.changed:Disconnect()
	end
end

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Which bodies are close enough to draw.
local function cull()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	for model, t in tracked do
		local root = rootOf(model)
		local distance = if root then (root.Position - eye).Magnitude else math.huge
		if t.raw and not t.handle and distance <= T.drawWithin then
			draw(t)
		elseif t.handle and (distance > T.dropBeyond or not t.raw) then
			undraw(t)
		end
	end
end

local function fadePrint(part: BasePart, life: number)
	table.insert(printQueue, part)
	while #printQueue > T.printsMax do
		local oldest = table.remove(printQueue, 1)
		if oldest then
			oldest:Destroy()
		end
	end
	task.delay(life * 0.6, function()
		if part.Parent then
			TweenService:Create(part, TweenInfo.new(life * 0.4), { Transparency = 1 }):Play()
		end
	end)
	task.delay(life, function()
		local index = table.find(printQueue, part)
		if index then
			table.remove(printQueue, index)
		end
		part:Destroy()
	end)
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude
rayParams.IgnoreWater = false

local function stepPrints()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	for model, t in tracked do
		local prints = t.prints
		local root = rootOf(model)
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if prints and root and humanoid and t.handle and (root.Position - eye).Magnitude <= T.printsWithin then
			local here = root.Position
			local last = t.lastStep
			local onGround = humanoid.FloorMaterial ~= Enum.Material.Air
			if not last or not onGround then
				t.lastStep = here
			elseif (Vector3.new(here.X - last.X, 0, here.Z - last.Z)).Magnitude >= T.printEvery then
				local flat = Vector3.new(here.X - last.X, 0, here.Z - last.Z).Unit
				t.lastStep = here
				t.foot = -t.foot
				local side = flat:Cross(Vector3.yAxis) * 0.5 * t.foot
				rayParams.FilterDescendantsInstances = { model, folderOf() }
				local hit = workspace:Raycast(here + side, Vector3.new(0, -8, 0), rayParams)
				if hit and hit.Material ~= Enum.Material.Water then
					local at = CFrame.lookAt(hit.Position + Vector3.new(0, 0.03, 0), hit.Position + Vector3.new(0, 0.03, 0) + flat)
					fadePrint(MarkFx.print(at, prints, folderOf()), prints.life)
				end
			end
		end
	end
end

function MarkController.init(_self: any, _ctx: any) end

function MarkController.start(_self: any, _ctx: any)
	CollectionService:GetInstanceAddedSignal(TAG):Connect(track)
	CollectionService:GetInstanceRemovedSignal(TAG):Connect(untrack)
	for _, instance in CollectionService:GetTagged(TAG) do
		track(instance)
	end
	task.spawn(function()
		while true do
			task.wait(0.5)
			local ok = pcall(cull)
			if not ok then
				task.wait(2)
			end
		end
	end)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt)
		acc += dt
		if acc >= 0.1 then
			acc = 0
			pcall(stepPrints)
		end
	end)
end

return MarkController
