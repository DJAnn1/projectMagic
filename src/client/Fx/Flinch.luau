--!strict
--[[
	Flinch: a player hit by a spell tilts away from where it came from (docs/Smoothness.md stage 6;
	numbers in Shared/Magic/Data/Weight flinch). Every client does it for every player it sees hit,
	from the "hit" cue (CombatFeedback), by turning the body at its root joint's C0 for a moment and
	easing it back. Local only (C0 isn't replicated from a client), so it costs the network nothing.
	NPCs flinch on the server (Cast/HitReactions). The camera is never touched.

		Flinch.hit(userId, from, share)
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Data = require(Shared.Magic.Data.Weight)

local FxLayers = require(script.Parent.FxLayers)
local Theme = require(script.Parent.Parent:WaitForChild("UI").Theme)

local F = Data.flinch

local Flinch = {}

-- Each joint's resting C0 and the flinch currently playing on it (a new one replaces it).
local resting: { [Motor6D]: CFrame } = setmetatable({}, { __mode = "k" }) :: any
local playing: { [Motor6D]: number } = setmetatable({}, { __mode = "k" }) :: any

function Flinch.hit(userId: any, from: any, share: number)
	if typeof(userId) ~= "number" or typeof(from) ~= "Vector3" or share < F.minShare then
		return
	end
	if Theme.settings.reducedMotion then
		return
	end
	local player = Players:GetPlayerByUserId(userId)
	local character = player and player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or humanoid.PlatformStand or not root or not root:IsA("BasePart") then
		return -- down or ragdolled: no flinch on top
	end
	-- R6 turns at the RootJoint, R15 at the Waist.
	local joint = root:FindFirstChild("RootJoint")
	if not joint then
		local upper = character and character:FindFirstChild("UpperTorso")
		joint = upper and upper:FindFirstChild("Waist")
	end
	if not joint or not joint:IsA("Motor6D") then
		return
	end
	local motor = joint :: Motor6D
	local away = root.Position - from
	away = Vector3.new(away.X, 0, away.Z)
	if away.Magnitude < 0.1 then
		return
	end
	away = away.Unit
	local base = resting[motor] or motor.C0
	resting[motor] = base
	-- Turning about up x away moves the top of the body toward `away`; expressed in the C0's frame.
	local up = Vector3.new(0, 1, 0)
	local axisWorld = up:Cross(away)
	local partFrame = (motor.Part0 or root).CFrame
	local axis = base:VectorToObjectSpace(partFrame:VectorToObjectSpace(axisWorld))
	if axis.Magnitude < 1e-3 then
		return
	end
	axis = axis.Unit
	local angle = math.rad(F.degrees * math.clamp(share / F.fullShare, 0.3, 1))
	local token = (playing[motor] or 0) + 1
	playing[motor] = token
	FxLayers.animate(F.seconds, function(t)
		if playing[motor] ~= token or not motor.Parent then
			return
		end
		local s = t * F.seconds
		local k = if s < F.rise then s / F.rise else 1 - (s - F.rise) / (F.seconds - F.rise)
		motor.C0 = base * CFrame.fromAxisAngle(axis, angle * k * k)
	end, function()
		if playing[motor] == token then
			playing[motor] = nil
			if motor.Parent then
				motor.C0 = base
			end
		end
	end)
end

return Flinch
