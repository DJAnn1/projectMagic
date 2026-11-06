--!strict
--[[
	TimeClient: the keys and panel for Time's powers (docs/Time.md). The server decides everything
	(Cast/TimeRuntime), and tells this through Player attributes: TimeMarkUntil, TimeRecallReady,
	TimeMarks, TimeHeld, TimeStoredUntil.

	N   back to your mark
	L   marked targets snap back and hanging spells fly, at where you're looking

	The panel appears only while you have something to recall or release, and has buttons for touch and
	gamepad. Colour is never the only cue: everything reads as words and seconds.
	Budget: one Heartbeat at 5 Hz, which does nothing with no attributes set.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Controls = require(Shared.UI.Controls)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

local AIM_RANGE = 1000
local UPDATE_SECONDS = 0.2

local TimeClient = {
	name = "TimeClient",
	dependencies = { "InterfaceController" },
}

local interface: any = nil
local localPlayer = Players.LocalPlayer

local active = Kit.value(false) -- is there anything to show?
local text = Kit.value("")

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

-- Where you're looking: the mouse, or the middle of the screen with no mouse.
local function aimPoint(): Vector3?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	local ray
	if UserInputService.MouseEnabled then
		local mouse = UserInputService:GetMouseLocation()
		ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	else
		local size = camera.ViewportSize
		ray = camera:ViewportPointToRay(size.X / 2, size.Y / 2)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if localPlayer.Character then { localPlayer.Character } else {}
	local hit = workspace:Raycast(ray.Origin, ray.Direction * AIM_RANGE, params)
	return if hit then hit.Position else ray.Origin + ray.Direction * AIM_RANGE
end

local function recall()
	Net.send("TimeIntent", "recall")
end

local function release()
	Net.send("TimeIntent", "release", aimPoint())
end

local function update()
	local t = serverNow()
	local parts: { string } = {}
	local markUntil = localPlayer:GetAttribute("TimeMarkUntil")
	if typeof(markUntil) == "number" and markUntil > t then
		local ready = localPlayer:GetAttribute("TimeRecallReady")
		local wait = if typeof(ready) == "number" then ready - t else 0
		table.insert(parts, if wait > 0
			then string.format("⟲ Mark: %d s left (recall ready in %d s)", math.ceil(markUntil - t), math.ceil(wait))
			else string.format("⟲ Mark: %d s left · N returns", math.ceil(markUntil - t)))
	end
	local marks = localPlayer:GetAttribute("TimeMarks")
	if typeof(marks) == "number" and marks > 0 then
		table.insert(parts, string.format("⟳ %d marked · L brings them back", marks))
	end
	local storedUntil = localPlayer:GetAttribute("TimeStoredUntil")
	if typeof(storedUntil) == "number" and storedUntil > t then
		local held = localPlayer:GetAttribute("TimeHeld")
		table.insert(parts, string.format("◌ %d held · %d s · L sends them", if typeof(held) == "number" then held else 0, math.ceil(storedUntil - t)))
	end
	local joined = table.concat(parts, "\n")
	text:set(joined)
	active:set(#parts > 0)
end

local function buildLayer(scope: Kit.Scope, root: Frame)
	Kit.dynamic(scope, { active }, function(s)
		if not active:get() then
			return
		end
		local panel: Frame = Kit.create(nil, "Frame", {
			Name = "TimePanel",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0, 1),
			Position = UDim2.new(0, Theme.space.m, 1, -(Theme.minTouch * 4)),
			Size = UDim2.fromOffset(Theme.minTouch * 6, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = root,
		})
		s:add(panel)
		C.list("y", Theme.space.xs).Parent = panel
		local label = C.text(text:get(), "caption", { TextStrokeTransparency = 0.4, LayoutOrder = 1, Parent = panel })
		s:add(text:observe(function(value: string)
			label.Text = value
		end))
		if UserInputService.TouchEnabled or UserInputService.GamepadEnabled then
			local row: Frame = Kit.create(nil, "Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.new(1, 0, 0, Theme.minTouch),
				LayoutOrder = 2,
				Parent = panel,
			})
			C.list("x", Theme.space.xs).Parent = row
			C.button("⟲ Recall", recall, { kind = "ghost" }, { Size = UDim2.fromOffset(Theme.minTouch * 2, Theme.minTouch), LayoutOrder = 1 }).Parent = row
			C.button("⟳ Release", release, { kind = "primary" }, { Size = UDim2.fromOffset(Theme.minTouch * 2, Theme.minTouch), LayoutOrder = 2 }).Parent = row
		end
	end)
end

function TimeClient.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	interface:registerLayer({ id = "Time", build = buildLayer })
end

function TimeClient.start(_self: any, _ctx: any)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or interface:isInputBlocked() then
			return
		end
		if Controls.matches("time_recall", input) then
			recall()
		elseif Controls.matches("time_release", input) then
			release()
		end
	end)
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= UPDATE_SECONDS then
			elapsed = 0
			update()
		end
	end)
end

return TimeClient
