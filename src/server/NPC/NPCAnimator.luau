--!strict
--[[
	NPCAnimator: what an NPC's body is doing, on T0 rigs (docs/NPCMovement.md). The only code that
	starts or stops the walk and idle tracks.

		NPCAnimator.Step(npc, clock)     10 Hz: picks the state and applies it
		NPCAnimator.Emote(npc, slot)     one clip now (opening a door, a nod)
		NPCAnimator.Release(npc)         gives back the neck when the rig goes away
		NPCAnimator.nextMoving(moving, speed)   the hysteresis rule (pure)

	STATES  Idle · Walk · Run · Talk · Listen, plus activity and combat clips, which already play at
	Action priority on top (DailyLife, NPCLOD.followState). The state is on the model as the attribute
	NpcAnimState, for the overlay and for clients.

	WALK IS READ FROM REAL VELOCITY, not from what anything asked for, so a walk cycle can't play on a
	body that isn't moving, whoever stopped it and however. Playback speed follows real speed, so feet
	don't slide.

	TALKING  Talk while the words last, then Listen. Each has an animation slot in Data/Activities.Clips
	(`talk`, `listen`). Empty slots use the procedural fallback: head turned to the speaker, with a bob
	while speaking. It works with no animations at all, and only runs on NPCs in a conversation.

	Runs on the server for now: at most 40 T0 rigs, and tracks already replicate. Moving it to clients
	is possible because the state is an attribute.
]]

local Activities = require(script.Parent.Data.Activities)
local LOD = require(script.Parent.NPCLOD)

local START_MOVING, STOP_MOVING = 1.5, 0.6 -- studs per second
local RUN_FROM = 13
local WALK_CLIP_SPEED = 13 -- the walk clip's feet match about this speed
local NECK_EVERY = 0.2 -- procedural head updates: each one is a replicated joint write
local NECK_TURN = math.rad(55)
local NECK_TILT = math.rad(25)
local NECK_BOB = 0.09

local NPCAnimator = {}

-- ─── Pure ───────────────────────────────────────────────────────────────────

function NPCAnimator.nextMoving(moving: boolean, speed: number): boolean
	if moving then
		return speed > STOP_MOVING
	end
	return speed > START_MOVING
end

function NPCAnimator.clipSpeed(speed: number): number
	return math.clamp(speed / WALK_CLIP_SPEED, 0.5, 1.5)
end

-- ─── Rig ────────────────────────────────────────────────────────────────────

local function setState(npc: any, rig: any, state: string)
	if npc.animState ~= state then
		npc.animState = state
		rig.model:SetAttribute("NpcAnimState", state)
	end
end

local function hasSlot(slot: string): boolean
	local id = Activities.Clips[slot]
	return id ~= nil and id ~= ""
end

-- ─── The procedural head ────────────────────────────────────────────────────

local function neckOf(rig: any): Motor6D?
	local torso = rig.model:FindFirstChild("Torso") or rig.model:FindFirstChild("Head")
	local neck = torso and torso:FindFirstChild("Neck")
	return if neck and neck:IsA("Motor6D") then neck else nil
end

local function restoreNeck(npc: any, rig: any)
	local rest = npc.neckRest
	if rest then
		local neck = neckOf(rig)
		if neck then
			neck.C0 = rest
		end
		npc.neckRest = nil
	end
end

local function aimHead(npc: any, rig: any, target: Vector3, bob: number)
	local neck = neckOf(rig)
	local torso = rig.model:FindFirstChild("Torso")
	local head = rig.model:FindFirstChild("Head")
	if not neck or not torso or not head or not torso:IsA("BasePart") or not head:IsA("BasePart") then
		return
	end
	if not npc.neckRest then
		npc.neckRest = neck.C0
	end
	local rest: CFrame = npc.neckRest
	local offset = target - head.Position
	if offset.Magnitude < 0.5 then
		return
	end
	local dir = torso.CFrame:VectorToObjectSpace(offset.Unit)
	local yaw = math.clamp(-math.atan2(dir.X, -dir.Z), -NECK_TURN, NECK_TURN)
	local pitch = math.clamp(math.asin(math.clamp(dir.Y, -1, 1)), -NECK_TILT, NECK_TILT) + bob
	-- A turn in the torso's own axes, applied before the joint's fixed rotation: works on any rig.
	neck.C0 = CFrame.new(rest.Position) * CFrame.Angles(0, yaw, 0) * CFrame.Angles(pitch, 0, 0) * rest.Rotation
end

-- ─── Locomotion ─────────────────────────────────────────────────────────────

local function locomotion(npc: any, rig: any)
	local velocity = rig.root.AssemblyLinearVelocity
	local speed = Vector3.new(velocity.X, 0, velocity.Z).Magnitude
	local moving = NPCAnimator.nextMoving(npc.animMoving == true, speed)
	npc.animMoving = moving
	local walk: AnimationTrack? = rig.tracks.walk
	local idle: AnimationTrack? = rig.tracks.idle
	if moving then
		if walk then
			if not walk.IsPlaying then
				walk:Play(0.2)
			end
			walk:AdjustSpeed(NPCAnimator.clipSpeed(speed))
		end
		if idle and idle.IsPlaying then
			idle:Stop(0.2)
		end
		setState(npc, rig, if speed >= RUN_FROM then "Run" else "Walk")
	else
		if walk and walk.IsPlaying then
			walk:Stop(0.25)
		end
		if idle and not idle.IsPlaying then
			idle:Play(0.25)
		end
		setState(npc, rig, "Idle")
	end
end

-- ─── Step ───────────────────────────────────────────────────────────────────

function NPCAnimator.Step(npc: any, clock: number)
	local rig = npc.rig
	if not rig or rig.root.Anchored then
		return
	end
	-- Locomotion always runs: a talking NPC still sliding to a stop keeps its feet honest.
	locomotion(npc, rig)
	local talk = npc.talk
	if not talk then
		if npc.neckRest then
			restoreNeck(npc, rig)
			LOD.stopActivity(npc)
		end
		return
	end
	if npc.animMoving then
		return
	end
	local speaking = clock < talk.speakingUntil
	setState(npc, rig, if speaking then "Talk" else "Listen")
	local slot = if speaking then "talk" else "listen"
	if hasSlot(slot) then
		LOD.playActivity(npc, slot, Activities.Clips[slot], true)
	else
		LOD.stopActivity(npc)
	end
	if clock >= (npc.neckNext or 0) then
		npc.neckNext = clock + NECK_EVERY
		local target: Vector3? = talk.lookAt
		if target then
			local bob = if speaking then math.sin(clock * 9) * NECK_BOB else 0
			aimHead(npc, rig, target, bob)
		end
	end
end

function NPCAnimator.Emote(npc: any, slot: string)
	if hasSlot(slot) then
		LOD.playActivity(npc, slot, Activities.Clips[slot], false)
	end
end

function NPCAnimator.Release(npc: any)
	local rig = npc.rig
	if rig then
		restoreNeck(npc, rig)
		rig.model:SetAttribute("NpcAnimState", nil)
	end
	npc.animState, npc.animMoving = nil, nil
end

return NPCAnimator
