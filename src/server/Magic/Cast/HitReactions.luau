--!strict
--[[
	HitReactions: how a body answers a hit. Called by EffectRunner for every damage event (players
	and NPCs alike), after Cast/Damage has applied it. Numbers in CombatTuning.reactions.

	KNOCKDOWN  one hit of knockdownShare of MaxHealth, or kinetic magic (momentum, seismicity, weight,
	           pressure, crush, landslide, wave) of recipe power >= kineticMinPower dealing
	           kineticShare. Applies the "knockdown" status (no walking or jumping) for
	           knockdownSeconds and pushes the body away from the attack:
	               NPCs   PlatformStand while down (StatusEffects), velocity set here
	               players their client falls (status cue) and takes the push (knockback cue)
	           Then knockdownImmunity seconds of immunity, so nobody is stun-locked.
	FLINCH     NPC rigs only (players get camera cues on their client): the torso recoils
	           (R15 Waist or R6 RootJoint Motor6D C0, up to flinchDegrees at a heavy hit) for flinchSeconds, and the
	           NPC pauses (attribute "FlinchUntil", which NPCService's walking loop respects).
	Damage over time never knocks down or flinches.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)

local Cast = script.Parent
local C = require(Cast.Parent.Data.CombatTuning)
local StatusEffects = require(Cast.StatusEffects)
local Damage = require(Cast.Damage)
local ActionState = require(Cast.ActionState)

local R = C.reactions

local HitReactions = {}

-- Weak keys: a destroyed rig's motors drop out on their own.
local restingC0: { [Motor6D]: CFrame } = setmetatable({}, { __mode = "k" }) :: any

local function now(): number
	return workspace:GetServerTimeNow()
end

local function rootOf(humanoid: Humanoid): BasePart?
	local model = humanoid.Parent
	local root = model and model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- Away from where the attack came from, flattened, with a little lift.
local function awayFrom(root: BasePart, from: Vector3?): Vector3
	local away = if from then root.Position - from else -root.CFrame.LookVector
	away = Vector3.new(away.X, 0, away.Z)
	local dir = if away.Magnitude > 0.1 then away.Unit else -root.CFrame.LookVector
	return (dir + Vector3.new(0, 0.45, 0)).Unit
end

function HitReactions.shouldKnockDown(humanoid: Humanoid, dealt: number, kind: string, info: Damage.Info): boolean
	local share = dealt / math.max(1, humanoid.MaxHealth)
	if share >= R.knockdownShare then
		return true
	end
	return R.knockdownKinds[kind] == true and (info.power or 0) >= R.kineticMinPower and share >= R.kineticShare
end

local function knockDown(humanoid: Humanoid, info: Damage.Info)
	local t = now()
	local immune = humanoid:GetAttribute("KnockdownImmuneUntil")
	if (typeof(immune) == "number" and immune > t) or StatusEffects.has(humanoid, "knockdown") then
		return
	end
	StatusEffects.apply(humanoid, "knockdown", { duration = R.knockdownSeconds })
	humanoid:SetAttribute("KnockdownImmuneUntil", t + R.knockdownSeconds + R.knockdownImmunity)
	local body = humanoid.Parent
	if body and body:IsA("Model") then
		-- Forced: a knockdown interrupts anything (casting, blocking, a dash).
		ActionState.set(body, "staggered", { duration = R.knockdownSeconds, force = true })
	end
	local root = rootOf(humanoid)
	if not root then
		return
	end
	local push = awayFrom(root, info.from) * R.knockdownLaunch
	local player = Players:GetPlayerFromCharacter(humanoid.Parent)
	if player then
		Net.fire("WorldEffect", player, { kind = "knockback", velocity = push })
	elseif not root.Anchored then
		root.AssemblyLinearVelocity += push
	end
end

local function flinch(humanoid: Humanoid, share: number)
	-- R15 bends at the Waist (UpperTorso); R6 has no waist, so the whole body tilts at the
	-- RootJoint (HumanoidRootPart), whose C0 frame is turned so the recoil sign flips.
	local model = humanoid.Parent
	local torso = model and model:FindFirstChild("UpperTorso")
	local root = model and model:FindFirstChild("HumanoidRootPart")
	local waist = (torso and torso:FindFirstChild("Waist")) or (root and root:FindFirstChild("RootJoint"))
	if not waist or not waist:IsA("Motor6D") then
		return
	end
	local sign = if waist.Name == "RootJoint" then 1 else -1
	local rest = restingC0[waist]
	if not rest then
		rest = waist.C0
		restingC0[waist] = rest
	end
	local degrees = R.flinchDegrees * math.clamp(share / R.knockdownShare, 0.35, 1)
	waist.C0 = (rest :: CFrame) * CFrame.Angles(math.rad(sign * degrees), 0, 0)
	local untilTime = now() + R.flinchSeconds
	humanoid:SetAttribute("FlinchUntil", untilTime)
	task.delay(R.flinchSeconds, function()
		if waist.Parent and humanoid:GetAttribute("FlinchUntil") == untilTime then
			waist.C0 = rest :: CFrame
			humanoid:SetAttribute("FlinchUntil", nil)
		end
	end)
end

-- Called for every damage event. `dot` = damage over time (never reacts).
function HitReactions.react(humanoid: Humanoid, dealt: number, kind: string, info: Damage.Info, dot: boolean)
	if dot or humanoid.Health <= 0 or not humanoid.Parent then
		return
	end
	if HitReactions.shouldKnockDown(humanoid, dealt, kind, info) then
		knockDown(humanoid, info)
		return
	end
	local share = dealt / math.max(1, humanoid.MaxHealth)
	if share >= R.flinchShare and not Players:GetPlayerFromCharacter(humanoid.Parent) then
		flinch(humanoid, share)
	end
end

return HitReactions
