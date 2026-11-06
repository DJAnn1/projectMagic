--!strict
--[[
	EventFx: what shared-event warnings and landings look like (docs/Social.md "Shared events").
	Cosmetic only: the server decides who gets hit, after the same delay.

		telegraph(cue)   a ring at full size with a disc growing to fill it: when the disc reaches the
		                 ring, it lands. Shown even with Reduce spell effects on, because it's how you
		                 know to move. The shape says it, not just the colour.
		comet(cue)       the same warning, plus a burning ball falling from the sky
		impact(cue, reduced)  a flash, shaped by style: slam, bolt, pulse, comet. Skipped when reduced.

	Budget: a few parts per cue, unanchored from nothing, all removed by Debris within a few seconds.
	Attacks are at most a handful per second across one event.
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local WARNING_COLOR = Color3.fromRGB(255, 120, 50)
local BOLT_COLOR = Color3.fromRGB(190, 215, 255)
local COMET_COLOR = Color3.fromRGB(170, 215, 255)
local COMET_HEIGHT = 260
local FLASH_SECONDS = 0.45

local EventFx = {}

local function groundY(x: number, y: number, z: number): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(Vector3.new(x, y + 30, z), Vector3.new(0, -90, 0), params)
	return if hit then hit.Position.Y else y
end

local function part(shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = "SharedEventFx"
	p.Shape = shape
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = Enum.Material.Neon
	p.Transparency = transparency
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = workspace
	return p
end

-- A flat disc on the ground. A cylinder's axis is its X, so it's turned to stand on end.
local function disc(x: number, y: number, z: number, diameter: number, color: Color3, transparency: number): Part
	return part(Enum.PartType.Cylinder, Vector3.new(0.25, diameter, diameter), CFrame.new(x, y + 0.2, z) * CFrame.Angles(0, 0, math.pi / 2), color, transparency)
end

function EventFx.telegraph(cue: any)
	local y = groundY(cue.x, cue.y, cue.z)
	local diameter = cue.radius * 2
	local duration = math.max(0.1, cue.duration)
	local color = if cue.style == "bolt" then BOLT_COLOR else WARNING_COLOR
	local outer = disc(cue.x, y, cue.z, diameter, color, 0.75)
	local inner = disc(cue.x, y + 0.05, cue.z, 1, color, 0.35)
	TweenService:Create(inner, TweenInfo.new(duration, Enum.EasingStyle.Linear), { Size = Vector3.new(0.25, diameter, diameter) }):Play()
	Debris:AddItem(outer, duration + 0.1)
	Debris:AddItem(inner, duration + 0.1)
end

function EventFx.comet(cue: any)
	EventFx.telegraph(cue)
	local y = groundY(cue.x, cue.y, cue.z)
	local duration = math.max(0.1, cue.duration)
	local ball = part(Enum.PartType.Ball, Vector3.new(9, 9, 9), CFrame.new(cue.x + 70, y + COMET_HEIGHT, cue.z + 40), COMET_COLOR, 0)
	TweenService:Create(ball, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = CFrame.new(cue.x, y, cue.z) }):Play()
	Debris:AddItem(ball, duration + 0.1)
end

function EventFx.impact(cue: any, reduced: boolean)
	if reduced then
		return
	end
	local y = groundY(cue.x, cue.y, cue.z)
	local info = TweenInfo.new(FLASH_SECONDS, Enum.EasingStyle.Quad, Enum.EasingDirection.Out)
	if cue.style == "bolt" then
		local beam = part(Enum.PartType.Block, Vector3.new(1.2, 200, 1.2), CFrame.new(cue.x, y + 100, cue.z), BOLT_COLOR, 0)
		TweenService:Create(beam, info, { Transparency = 1, Size = Vector3.new(0.2, 200, 0.2) }):Play()
		Debris:AddItem(beam, FLASH_SECONDS + 0.1)
	end
	local color = if cue.style == "bolt" then BOLT_COLOR elseif cue.style == "comet" then COMET_COLOR else WARNING_COLOR
	local start = cue.radius * 0.5
	local burst = part(Enum.PartType.Ball, Vector3.new(start, start, start), CFrame.new(cue.x, y, cue.z), color, 0.2)
	local final = cue.radius * 2
	TweenService:Create(burst, info, { Size = Vector3.new(final, final, final), Transparency = 1 }):Play()
	Debris:AddItem(burst, FLASH_SECONDS + 0.1)
end

return EventFx
