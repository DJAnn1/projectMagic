--!strict
--[[
	DownedController: lying on the ground after losing, and the fade while someone carries you
	(docs/LivingHistory.md §7). The server decides everything (Services/DownedService); this only
	draws it. Nothing is written on screen: no card, no timer.

	  Humanoid attribute Downed   our character lies down (PlatformStand) for as long as it's set,
	                              even if a knockdown ending tries to stand us up
	  remote Downed "down"        the world dims and greys a little
	                "fade"        to black (someone is carrying you, or dragging you off)
	                "wake"        back from black, colour returns, we get up
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local FADE_TIME = 1.4 -- matches DownedTuning.fadeSeconds
local WAKE_TIME = 2

local DownedController = {
	name = "DownedController",
	dependencies = {},
}

local grade: ColorCorrectionEffect? = nil
local blur: BlurEffect? = nil
local black: Frame? = nil

local function tween(object: Instance, seconds: number, goal: { [string]: any }): Tween
	local t = TweenService:Create(object, TweenInfo.new(seconds, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut), goal)
	t:Play()
	return t
end

local function dim(on: boolean)
	local g, b = grade, blur
	if not g or not b then
		return
	end
	if on then
		g.Enabled, b.Enabled = true, true
	end
	tween(b, if on then 1.2 else WAKE_TIME, { Size = if on then 6 else 0 })
	local t = tween(g, if on then 1.2 else WAKE_TIME, { Brightness = if on then -0.18 else 0, Saturation = if on then -0.7 else 0 })
	if not on then
		t.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				g.Enabled, b.Enabled = false, false
			end
		end)
	end
end

local function fade(toBlack: boolean)
	local frame = black
	if frame then
		tween(frame, if toBlack then FADE_TIME else WAKE_TIME, { BackgroundTransparency = if toBlack then 0 else 1 })
	end
end

local function humanoid(): Humanoid?
	local character = Players.LocalPlayer.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

function DownedController.init(_self: any, _ctx: any) end

function DownedController.start(_self: any, _ctx: any)
	local g = Instance.new("ColorCorrectionEffect")
	g.Name = "Downed"
	g.Enabled = false
	g.Parent = Lighting
	grade = g
	local b = Instance.new("BlurEffect")
	b.Name = "Downed"
	b.Size = 0
	b.Enabled = false
	b.Parent = Lighting
	blur = b

	local gui = Instance.new("ScreenGui")
	gui.Name = "Downed"
	gui.IgnoreGuiInset = true
	gui.ResetOnSpawn = false
	gui.DisplayOrder = 90
	local frame = Instance.new("Frame")
	frame.Size = UDim2.fromScale(1, 1)
	frame.BackgroundColor3 = Color3.new(0, 0, 0)
	frame.BackgroundTransparency = 1
	frame.BorderSizePixel = 0
	frame.Active = false
	frame.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	black = frame

	Net.listen("Downed", function(phase: any)
		if phase == "down" then
			dim(true)
		elseif phase == "fade" then
			fade(true)
		elseif phase == "wake" then
			fade(false)
			dim(false)
		end
	end)

	-- Lying down: held every frame while Downed is set, so nothing else stands us up early.
	local wasDown = false
	RunService.Heartbeat:Connect(function()
		local h = humanoid()
		local down = h ~= nil and h:GetAttribute("Downed") == true and h.Health > 0
		if down and h then
			if not h.PlatformStand then
				h.PlatformStand = true
			end
		elseif wasDown and h and h.Health > 0 then
			h.PlatformStand = false
			h:ChangeState(Enum.HumanoidStateType.GettingUp)
		end
		wasDown = down
	end)

	-- A new body (a death after all, or a respawn) never starts dimmed.
	Players.LocalPlayer.CharacterAdded:Connect(function()
		wasDown = false
		fade(false)
		dim(false)
	end)
end

return DownedController
