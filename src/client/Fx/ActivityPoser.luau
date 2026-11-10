--!strict
--[[
	ActivityPoser: the procedural fallback that makes an activity readable with no animation asset
	(docs/Activities.md §3). Plays a Shared/Life/Data/ActivityPoses family on an R6 rig, on this client.

	HOW. Every frame, after the Animator has posed the body (RunService.PreSimulation), each joint's
	Motor6D.Transform gets the pose layered on top: a rotation in the parent part's axes about the joint,
	so an arm swings from the shoulder whatever the animation is doing. In PreAnimation the joints go back
	to what the Animator left last frame, so a joint no track touches never accumulates the offset.

		Transform = Q⁻¹ · (translate · Ry · Rx · Rz) · Q · Transform_animation      (Q = C0's rotation)

	BODY. Sitting and lying move the whole body through RootJoint to where it should be (the chair, the
	mattress), given as a world CFrame for the torso. The server's Humanoid stays standing beside the
	furniture, so nothing collides; only what you see moves.

		ActivityPoser.prepare(model) -> RigPose?          nil for a rig that isn't R6
		ActivityPoser.set(rp, poseId, variant, t, weight, simple, body)   what to show this frame
		ActivityPoser.clear(rp)
		ActivityPoser.step()      PreSimulation (ActivityController binds it)
		ActivityPoser.restore()   PreAnimation

	CAST POSES (Controllers/CastPoseController, docs/CastPoses.md) share this machinery:
		ActivityPoser.setPose(rp, pose, t, weight, owner)   a Pose table, REPLACING the clip on the
		                          joints it names (blended by weight) instead of adding to it, so a
		                          spell's pose isn't stacked on CastSpell's raised arm
		ActivityPoser.release(rp, owner)                    hand the body back
	A body has one RigPose (prepare caches it), and an owner: while "cast" holds it, activity
	set/clear calls leave it alone. Each body is stepped once per frame, whoever calls step().
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ActivityPoses = require(Shared.Life.Data.ActivityPoses)

local JOINTS = {
	["Right Shoulder"] = "Torso",
	["Left Shoulder"] = "Torso",
	["Right Hip"] = "Torso",
	["Left Hip"] = "Torso",
	["Neck"] = "Torso",
	["RootJoint"] = "HumanoidRootPart",
}
local MIRROR = { ["Right Shoulder"] = "Left Shoulder", ["Left Shoulder"] = "Right Shoulder", ["Right Hip"] = "Left Hip", ["Left Hip"] = "Right Hip" }
local MAX_BODY_SHIFT = 7 -- studs: further than this, the body is drawn where the rig stands

export type RigPose = {
	model: Model,
	root: BasePart,
	motors: { [string]: Motor6D },
	q: { [string]: CFrame },
	base: { [string]: CFrame }, -- the Animator's Transform this frame, before the pose
	target: { [string]: CFrame }?, -- per joint D (parent axes), or nil = not posed
	owner: string?, -- "cast" while a cast pose holds the body (activities wait)
	replace: boolean?, -- target replaces the Animator's Transform (blended by `blend`)
	blend: number?,
	frame: number?, -- the frame this body was last stepped
}

local active: { [RigPose]: boolean } = {}
local rigs: { [Model]: RigPose } = setmetatable({}, { __mode = "k" }) :: any
local frame = 0

local ActivityPoser = {}

function ActivityPoser.prepare(model: Model): RigPose?
	local cached = rigs[model]
	if cached and cached.root.Parent then
		return cached
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local motors: { [string]: Motor6D } = {}
	local q: { [string]: CFrame } = {}
	for name, parentName in JOINTS do
		local parent = model:FindFirstChild(parentName)
		local motor = parent and parent:FindFirstChild(name)
		if motor and motor:IsA("Motor6D") then
			motors[name] = motor
			q[name] = motor.C0.Rotation
		end
	end
	if not motors["Right Shoulder"] or not motors["RootJoint"] then
		return nil -- not R6
	end
	local rp: RigPose = { model = model, root = root, motors = motors, q = q, base = {}, target = nil }
	rigs[model] = rp
	return rp
end

local function rotation(x: number, y: number, z: number): CFrame
	return CFrame.Angles(0, math.rad(y), 0) * CFrame.Angles(math.rad(x), 0, 0) * CFrame.Angles(0, 0, math.rad(z))
end

--[[
	What to show this frame.
		t        seconds into the activity (the rhythm's clock)
		weight   0..1 how much of the pose shows (Preparing eases in, Finishing out)
		simple   the medium-distance loop: only the pose's `simple` joints move
		body     the torso's world CFrame for sit and lie (nil = in place)
]]
local compute: (RigPose, ActivityPoses.Pose, number, number, number, boolean, CFrame?) -> { [string]: CFrame }

function ActivityPoser.set(rp: RigPose, poseId: string, variant: number, t: number, weight: number, simple: boolean, body: CFrame?)
	if rp.owner then
		return -- a cast pose holds this body for now
	end
	local pose = ActivityPoses.poses[poseId]
	if not pose or weight <= 0 then
		ActivityPoser.clear(rp)
		return
	end
	rp.target = compute(rp, pose, variant, t, weight, simple, body)
	rp.replace = nil
	active[rp] = true
end

-- A cast pose: replaces the clip on the joints it names, blended in by `weight`.
function ActivityPoser.setPose(rp: RigPose, pose: ActivityPoses.Pose, t: number, weight: number, owner: string)
	if rp.owner and rp.owner ~= owner then
		return
	end
	if weight <= 0 then
		ActivityPoser.release(rp, owner)
		return
	end
	rp.owner = owner
	rp.target = compute(rp, pose, 1, t, 1, false, nil)
	rp.replace = true
	rp.blend = math.clamp(weight, 0, 1)
	active[rp] = true
end

function ActivityPoser.release(rp: RigPose, owner: string)
	if rp.owner ~= owner then
		return
	end
	rp.owner = nil
	ActivityPoser.clear(rp)
end

compute = function(rp: RigPose, pose: ActivityPoses.Pose, variant: number, t: number, weight: number, simple: boolean, body: CFrame?): { [string]: CFrame }
	local v = pose.variants[math.clamp(variant, 1, #pose.variants)] or pose.variants[1]
	local mirror = v.mirror == true
	local angles: { [string]: { number } } = {}
	for joint, rot in pose.joints do
		angles[joint] = { rot[1], rot[2], rot[3] }
	end
	local period = pose.period / v.speed
	for _, m in pose.motion do
		if not simple or table.find(pose.simple, m.joint) then
			local a = angles[m.joint] or { 0, 0, 0 }
			angles[m.joint] = a
			local value = ActivityPoses.wave(m.shape, t, period, m.phase)
			local i = if m.axis == "x" then 1 elseif m.axis == "y" then 2 else 3
			a[i] += m.amp * v.amp * value
		end
	end
	local target: { [string]: CFrame } = {}
	for joint, a in angles do
		local name = if mirror and MIRROR[joint] then MIRROR[joint] else joint
		local sign = if mirror then -1 else 1
		if rp.motors[name] then
			target[name] = rotation(a[1] * weight, a[2] * sign * weight, a[3] * sign * weight)
		end
	end
	-- The body: lowered (kneel, crouch), or moved onto a chair or a bed.
	local rootD = target["RootJoint"] or CFrame.new()
	local lower = pose.lower or 0
	if body and (pose.body == "sit" or pose.body == "lie") then
		local want = if pose.body == "lie" then body * CFrame.Angles(math.rad(90), 0, 0) else body
		local shift = rp.root.CFrame:ToObjectSpace(want)
		if shift.Position.Magnitude <= MAX_BODY_SHIFT then
			rootD = CFrame.new():Lerp(shift, weight) * rootD
		end
	elseif pose.body == "lie" then
		-- No bed: lie on the floor where they stand.
		rootD = CFrame.new():Lerp(CFrame.new(0, -2.4, 0) * CFrame.Angles(math.rad(90), 0, 0), weight) * rootD
	elseif lower > 0 then
		rootD = CFrame.new(0, -lower * weight, 0) * rootD
	end
	if target["RootJoint"] or rootD ~= CFrame.new() then
		target["RootJoint"] = rootD
	end
	return target
end

function ActivityPoser.clear(rp: RigPose)
	if rp.owner then
		return -- the cast pose lets go through release()
	end
	if rp.target then
		-- Hand the joints back as the Animator left them.
		for name, base in rp.base do
			local motor = rp.motors[name]
			if motor and motor.Parent then
				motor.Transform = base
			end
		end
	end
	rp.target = nil
	rp.replace = nil
	table.clear(rp.base)
	active[rp] = nil
end

function ActivityPoser.restore()
	frame += 1
	for rp in active do
		for name, base in rp.base do
			local motor = rp.motors[name]
			if motor and motor.Parent then
				motor.Transform = base
			end
		end
	end
end

function ActivityPoser.step()
	for rp in active do
		local target = rp.target
		if not target or not rp.model.Parent then
			active[rp] = nil
			continue
		end
		if rp.frame == frame then
			continue -- already stepped this frame (two controllers call step)
		end
		rp.frame = frame
		local blend = rp.blend or 1
		for name, d in target do
			local motor = rp.motors[name]
			if motor and motor.Parent then
				local base = motor.Transform
				rp.base[name] = base
				local q = rp.q[name]
				if rp.replace then
					motor.Transform = base:Lerp(q:Inverse() * d * q, blend)
				else
					motor.Transform = q:Inverse() * d * q * base
				end
			end
		end
	end
end

return ActivityPoser
