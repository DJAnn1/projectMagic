--!strict
--[[
	EmotePoses: procedural R6 poses for emotes with no animation asset (docs/Social.md §5).

	Each viewer moves the joints on their own client, so a poser never owns anything the server sees:
	hitboxes and the character's position don't change. Changing a Motor6D's C0 stacks with
	whatever the default Animate script is playing, which only writes Transform.

	Every rotation is written in the parent part's own axes: +X is the part's right, and a positive
	turn about X swings something hanging DOWN toward the part's FRONT. So
		bow        the torso tips forward from the root (a negative turn: the top goes forward)
		meditate   the body drops to the ground and both legs swing forward at the hip; hands to knees

	R15 rigs (nothing uses them now; CombatAnimations.rigType) have other joint names, so the lookups
	fail and no pose plays.
]]

local TweenService = game:GetService("TweenService")

local UI = script.Parent.Parent:WaitForChild("UI")
local Theme = require(UI.Theme)

local BLEND = TweenInfo.new(0.35, Enum.EasingStyle.Sine, Enum.EasingDirection.Out)

type Joint = { part: string, name: string, change: (CFrame) -> CFrame }

-- Turns `c0` about a pivot written in the parent part's space.
local function pivot(position: Vector3, xDegrees: number): (CFrame) -> CFrame
	return function(c0: CFrame): CFrame
		return CFrame.new(position) * CFrame.Angles(math.rad(xDegrees), 0, 0) * CFrame.new(-position) * c0
	end
end

local POSES: { [string]: { Joint } } = {
	bow = {
		{ part = "HumanoidRootPart", name = "RootJoint", change = pivot(Vector3.zero, -38) },
	},
	meditate = {
		{ part = "HumanoidRootPart", name = "RootJoint", change = function(c0: CFrame): CFrame
			return CFrame.new(0, -1.5, 0) * c0
		end },
		{ part = "Torso", name = "Right Hip", change = pivot(Vector3.new(1, -1, 0), 85) },
		{ part = "Torso", name = "Left Hip", change = pivot(Vector3.new(-1, -1, 0), 85) },
		{ part = "Torso", name = "Right Shoulder", change = pivot(Vector3.new(1.5, 0.5, 0), 35) },
		{ part = "Torso", name = "Left Shoulder", change = pivot(Vector3.new(-1.5, 0.5, 0), 35) },
	},
}

type Held = { motor: Motor6D, original: CFrame }

local EmotePoses = {}

local holding: { [Model]: { Held } } = setmetatable({}, { __mode = "k" }) :: any

local function setC0(motor: Motor6D, target: CFrame)
	if Theme.settings.reducedMotion then
		motor.C0 = target
	else
		TweenService:Create(motor, BLEND, { C0 = target }):Play()
	end
end

function EmotePoses.start(character: Model, pose: string)
	EmotePoses.stop(character)
	local joints = POSES[pose]
	if not joints then
		return
	end
	local held: { Held } = {}
	for _, joint in joints do
		local part = character:FindFirstChild(joint.part)
		local motor = part and part:FindFirstChild(joint.name)
		if motor and motor:IsA("Motor6D") then
			table.insert(held, { motor = motor, original = motor.C0 })
			setC0(motor, joint.change(motor.C0))
		end
	end
	holding[character] = held
end

function EmotePoses.stop(character: Model)
	local held = holding[character]
	if not held then
		return
	end
	holding[character] = nil
	for _, h in held do
		if h.motor.Parent then
			setC0(h.motor, h.original)
		end
	end
end

return EmotePoses
