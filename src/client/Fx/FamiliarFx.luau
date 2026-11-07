--!strict
--[[
	FamiliarFx: what a familiar's actions look like (docs/Familiars.md). Cosmetic only, from the
	"familiar" WorldEffect cue.

		bolt   a small glowing shot from it to where it's going (abilities, and help for you)
		bite   a short snap to the target
		born, grow, ko   a burst of light where it is

	Budget: at most MAX_ACTIVE at once on this client; past that, a new one is skipped. Far-away cues
	(lod 0) draw nothing.
]]

local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local F = require(Shared.Familiars.Data.Familiars)

local MAX_ACTIVE = 24
local FOLDER_NAME = "FamiliarFx"

local BURSTS: { [string]: { size: number, seconds: number } } = {
	born = { size = 11, seconds = 0.8 },
	grow = { size = 8, seconds = 0.6 },
	ko = { size = 5, seconds = 0.4 },
}

local active = 0

local FamiliarFx = {}

local function holder(): Instance
	local existing = workspace.CurrentCamera and workspace.CurrentCamera:FindFirstChild(FOLDER_NAME)
	if existing then
		return existing
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME
	folder.Parent = workspace.CurrentCamera or workspace
	return folder
end

local function ball(size: number, at: Vector3, color: Color3): Part
	local part = Instance.new("Part")
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * size
	part.Position = at
	part.Color = color
	part.Material = Enum.Material.Neon
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Parent = holder()
	return part
end

local function play(part: Part, seconds: number, goal: { [string]: any })
	active += 1
	local tween = TweenService:Create(part, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal)
	tween.Completed:Once(function()
		active -= 1
		part:Destroy()
	end)
	tween:Play()
end

function FamiliarFx.cue(effect: { [string]: any })
	if effect.lod == 0 or active >= MAX_ACTIVE or typeof(effect.position) ~= "Vector3" then
		return
	end
	local look = F.looks[effect.domain] or F.looks.energy
	local burst = BURSTS[effect.fx]
	if burst then
		local part = ball(1, effect.position, look.glow)
		part.Transparency = 0.25
		play(part, burst.seconds, { Size = Vector3.one * burst.size, Transparency = 1 })
	elseif typeof(effect.to) == "Vector3" then
		local isBite = effect.fx == "bite"
		local distance = (effect.to - effect.position).Magnitude
		local seconds = if isBite then 0.1 else math.clamp(distance / 90, 0.08, 0.35)
		local part = ball(if isBite then 0.5 else 0.8, effect.position, look.glow)
		play(part, seconds, { Position = effect.to, Transparency = 0.5 })
	end
end

return FamiliarFx
