--!strict
--[[
	CastPoseController: bodies cast differently by what the spell does (docs/CastPoses.md).

	For every nearby body that is charging, casting or channelling (players, and NPC mages in their
	wind-up), it reads what the spell is (AttunedKind, AttunedForm; NPCs' are remembered from their
	conjure, since the attributes clear as the bolt flies) and poses the body through Fx/ActivityPoser:
		charging    the kind's gather pose, eased in
		casting     gather blended into release, held, then let go as the state ends
		channeling  the release pose, held
	The pose REPLACES the CastSpell clip on the arms, neck and torso (the legs keep walking), and
	takes the body from any activity pose until it lets go. Client only; nothing replicates.

	Cost: at most a few attribute reads per tracked body per frame, and only bodies within
	CastPoses.range of the camera that are in one of those three states are posed.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local FeatureFlags = require(Shared.Core.FeatureFlags)
local ActionRules = require(Shared.Magic.ActionRules)
local SpellHand = require(Shared.Magic.SpellHand)
local CastPoses = require(Shared.Magic.Data.CastPoses)
local ActivityPoses = require(Shared.Life.Data.ActivityPoses)

local ActivityPoser = require(script.Parent.Parent:WaitForChild("Fx").ActivityPoser)

local OWNER = "cast"
local NPC_TAG = "NpcConjuring"
local NPC_KEEP = 6 -- seconds an NPC stays tracked after its wind-up (its cast follows)

local CastPoseController = {
	name = "CastPoseController",
	dependencies = {},
}

type Tracked = {
	model: Model,
	rp: ActivityPoser.RigPose?,
	kind: string?,
	form: string?,
	keepUntil: number?, -- NPCs only
	posed: boolean,
	inCast: string?, -- "charging", "casting" or "channeling" last frame (nil = none)
	releasedAt: number?, -- os.clock() when the cast ended (the follow-through runs from it)
}

local tracked: { [Model]: Tracked } = {}

local function track(model: Model, keepUntil: number?)
	local entry = tracked[model]
	if entry then
		entry.keepUntil = if keepUntil then math.max(entry.keepUntil or 0, keepUntil) else nil
		return
	end
	tracked[model] = { model = model, rp = nil, kind = nil, form = nil, keepUntil = keepUntil, posed = false, inCast = nil, releasedAt = nil }
end

local function untrack(model: Model)
	local entry = tracked[model]
	if entry then
		if entry.rp then
			ActivityPoser.release(entry.rp, OWNER)
		end
		tracked[model] = nil
	end
end

local function lerp(a: number, b: number, k: number): number
	return a + (b - a) * k
end

-- The gather and release poses of a kind, blended by k (past 1 = the follow-through's overshoot),
-- shifted by the form's mode. `depth` scales the gather (a charge deepens it); `shake` trembles
-- both arms (overcharged).
local function blended(kind: string, form: string?, k: number, depth: number, shake: boolean): ActivityPoses.Pose
	local poses = CastPoses.kinds[kind] or CastPoses.kinds[CastPoses.fallback]
	local mode = CastPoses.modes[SpellHand.modeFor(form)] or CastPoses.modes.hand
	local a, b = poses.gather, poses.release
	local joints: { [string]: { number } } = {}
	for joint, rot in a.joints do
		local other = b.joints[joint] or { 0, 0, 0 }
		local g = { rot[1] * depth, rot[2] * depth, rot[3] * depth }
		joints[joint] = { lerp(g[1], other[1], k), lerp(g[2], other[2], k), lerp(g[3], other[3], k) }
	end
	for joint, rot in b.joints do
		if not joints[joint] then
			joints[joint] = { rot[1] * k, rot[2] * k, rot[3] * k }
		end
	end
	-- The form: arms raised overhead or lowered to the ground, a lean, a crouch.
	local function addX(joint: string, degrees: number)
		local j = joints[joint] or { 0, 0, 0 }
		j[1] += degrees
		joints[joint] = j
	end
	if mode.arm ~= 0 then
		addX("Right Shoulder", mode.arm)
		if poses.twoHanded then
			addX("Left Shoulder", mode.arm)
		end
	end
	if mode.lean ~= 0 then
		addX("RootJoint", mode.lean)
	end
	local lower = lerp(a.lower or 0, b.lower or 0, k) + mode.lower
	local motion = if k < 0.5 then a.motion else {} -- the gather's tremor or breath fades as it's cast
	local period = a.period
	if shake and k < 0.5 then
		motion = {
			{ joint = "Right Shoulder", axis = "x", amp = CastPoses.shakeAmp, shape = "sine" },
			{ joint = "Left Shoulder", axis = "x", amp = CastPoses.shakeAmp, shape = "sine", phase = 0.5 },
		}
		period = CastPoses.shakePeriod
	end
	return {
		joints = joints,
		motion = motion,
		period = period,
		lower = lower,
		body = if lower > 0 then "crouch" else nil,
		variants = a.variants,
		simple = a.simple,
	}
end

--[[
	How much of the pose shows (nil = none), how far into the release (0 gather .. 1 release, a
	little past 1 at the moment of casting), how deep the gather is, and whether it trembles:
		charging    the gather, eased in, deepening with the charge; trembling when overcharged
		casting     the gather held until the last `snap` seconds, then snapped to the release, so
		            the release lands as the spell leaves
		channeling  the release, held
		after       the follow-through: past the release and easing back for `follow`, then settling
]]
local function phase(entry: Tracked, model: Model, t: number, now: number): (number?, number, number, boolean)
	local snapshot = ActionRules.read(model)
	local state = ActionRules.effective(snapshot, t)
	local live = state == snapshot.state
	local started = if snapshot.untilTime > 0 then snapshot.untilTime - snapshot.duration else t
	local elapsed = math.max(0, t - started)
	if live and state == "charging" then
		entry.inCast, entry.releasedAt = "charging", nil
		local depth, shake = 1, false
		local start, stepSize = model:GetAttribute("ChargeStart"), model:GetAttribute("ChargeStep")
		if typeof(start) == "number" and typeof(stepSize) == "number" then
			local progress = SpellHand.progress(t - start, stepSize) -- 0..3; 2 = full, past it overcharged
			depth = lerp(CastPoses.depthMin, 1, math.clamp(progress / 2, 0, 1))
			shake = progress > 2
		end
		return math.clamp(elapsed / CastPoses.fadeIn, 0, 1), 0, depth, shake
	elseif live and state == "casting" then
		entry.inCast, entry.releasedAt = "casting", nil
		local remaining = if snapshot.untilTime > 0 then snapshot.untilTime - t else 0
		local k = if remaining >= CastPoses.snap then 0 else 1 - remaining / CastPoses.snap
		return 1, k, 1, false
	elseif live and state == "channeling" then
		entry.inCast, entry.releasedAt = "channeling", nil
		return 1, 1, 1, false
	end
	-- No longer casting: the follow-through after a cast or channel, then settling. A charge that
	-- was dropped (charging straight back to holding) just lets go, with no thrust.
	local was = entry.inCast
	if was then
		entry.inCast = nil
		entry.releasedAt = if was ~= "charging" then now else nil
	end
	local released = entry.releasedAt
	if released then
		local a = now - released
		if a < CastPoses.follow then
			local swing = math.clamp(1 - a / (CastPoses.follow * 0.5), 0, 1)
			return 1, 1 + CastPoses.overshoot * swing, 1, false
		elseif a < CastPoses.follow + CastPoses.settle then
			return 1 - (a - CastPoses.follow) / CastPoses.settle, 1, 1, false
		end
		entry.releasedAt = nil
	end
	return nil, 0, 1, false
end

local function update()
	local enabled = FeatureFlags.get("cast_poses_enabled") ~= false
	local t = workspace:GetServerTimeNow()
	local camera = workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else nil
	local now = os.clock()
	for model, entry in tracked do
		if not model.Parent or (entry.keepUntil and now > entry.keepUntil) then
			untrack(model)
			continue
		end
		-- Remember what the spell is while the body says so (NPCs' attributes clear on release).
		local kind = model:GetAttribute("AttunedKind")
		local form = model:GetAttribute("AttunedForm")
		if typeof(kind) == "string" then
			entry.kind = kind
		end
		if typeof(form) == "string" then
			entry.form = form
		end
		local root = model:FindFirstChild("HumanoidRootPart")
		local near = eye ~= nil and root ~= nil and root:IsA("BasePart") and (root.Position - eye).Magnitude <= CastPoses.range
		local weight, k, depth, shake = phase(entry, model, t, now)
		if not enabled or not near or not weight or weight <= 0 then
			if entry.posed and entry.rp then
				ActivityPoser.release(entry.rp, OWNER)
			end
			entry.posed = false
			continue
		end
		if not entry.rp then
			entry.rp = ActivityPoser.prepare(model)
		end
		local rp = entry.rp
		if rp then
			ActivityPoser.setPose(rp, blended(entry.kind or CastPoses.fallback, entry.form, k, depth, shake), t, weight, OWNER)
			entry.posed = true
		end
	end
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(function(character)
		track(character)
	end)
	player.CharacterRemoving:Connect(untrack)
	if player.Character then
		track(player.Character)
	end
end

function CastPoseController.init(_self: any, _ctx: any) end

function CastPoseController.start(_self: any, _ctx: any)
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	-- NPC mages: tracked from the start of their wind-up until a little after their cast.
	local function onNpc(instance: Instance)
		if instance:IsA("Model") then
			track(instance, os.clock() + NPC_KEEP)
		end
	end
	CollectionService:GetInstanceAddedSignal(NPC_TAG):Connect(onNpc)
	CollectionService:GetInstanceRemovedSignal(NPC_TAG):Connect(onNpc) -- the cast follows: keep it a while
	for _, instance in CollectionService:GetTagged(NPC_TAG) do
		onNpc(instance)
	end

	-- Targets are set before the Animator runs; the poser applies them after it (once per frame,
	-- shared with ActivityController).
	RunService.RenderStepped:Connect(update)
	RunService.PreAnimation:Connect(ActivityPoser.restore)
	RunService.PreSimulation:Connect(ActivityPoser.step)
end

return CastPoseController
