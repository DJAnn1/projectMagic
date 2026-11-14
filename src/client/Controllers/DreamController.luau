--!strict
--[[
	DreamController: the screen dims while you fall asleep in a bed and lifts when you wake
	(docs/Dreams.md). The server decides when (Services/DreamService, remote Dreaming "drift" |
	"wake"); the dream itself arrives only as a Journal line. Nothing is written on screen here.

	Client-only: one BlurEffect and one ColorCorrectionEffect under Lighting, tweened.
]]

local Lighting = game:GetService("Lighting")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local DRIFT_TIME = 3.5
local WAKE_TIME = 2

local DreamController = {
	name = "DreamController",
	dependencies = {},
}

local blur: BlurEffect? = nil
local grade: ColorCorrectionEffect? = nil

local function fade(asleep: boolean)
	local b, g = blur, grade
	if not b or not g then
		return
	end
	local info = TweenInfo.new(if asleep then DRIFT_TIME else WAKE_TIME, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut)
	if asleep then
		b.Enabled, g.Enabled = true, true
	end
	TweenService:Create(b, info, { Size = if asleep then 14 else 0 }):Play()
	local tween = TweenService:Create(g, info, {
		Brightness = if asleep then -0.45 else 0,
		Saturation = if asleep then -0.6 else 0,
		TintColor = if asleep then Color3.fromRGB(190, 200, 255) else Color3.new(1, 1, 1),
	})
	tween:Play()
	if not asleep then
		tween.Completed:Once(function(state)
			if state == Enum.PlaybackState.Completed then
				b.Enabled, g.Enabled = false, false
			end
		end)
	end
end

function DreamController.init(_self: any, _ctx: any) end

function DreamController.start(_self: any, _ctx: any)
	local b = Instance.new("BlurEffect")
	b.Name = "Dreaming"
	b.Size = 0
	b.Enabled = false
	b.Parent = Lighting
	blur = b
	local g = Instance.new("ColorCorrectionEffect")
	g.Name = "Dreaming"
	g.Enabled = false
	g.Parent = Lighting
	grade = g
	Net.listen("Dreaming", function(phase: any)
		fade(phase == "drift")
	end)
end

return DreamController
