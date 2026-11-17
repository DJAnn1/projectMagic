--!strict
--[[
	Ragdoll: a body knocked down goes limp (owner, 2026-11-17: "ragdoll physics ... after certain
	spells knock a player down"). StatusEffects calls Ragdoll.set whenever a humanoid's "knockdown"
	status begins or ends, so every spell that knocks down (HitReactions' heavy and kinetic hits,
	Earth/Energy/Water arts, spell struggles, the admin `knockdown`) ragdolls players, NPCs and
	Wildborn alike. Numbers in CombatTuning.reactions.ragdoll.

	ON   every Motor6D but the root joint is disabled and replaced by a BallSocketConstraint
	     (attachments at the joint's C0 / C1, cone and twist limits per joint). Each limb gets an
	     invisible, massless collider welded to it (R6 limbs don't collide, so they'd sink into the
	     ground), kept from fighting the torso by NoCollisionConstraints. RequiresNeck and
	     BreakJointsOnDeath are off while limp (a body that dies limp stays a whole, limp body).
	     Done on the server, so every client sees it. A player's body is still simulated by their
	     own client, which also takes the knockback push (HitReactions) and holds PlatformStand
	     (WorldEffectController), so the push throws a limp body. NPCs: StatusEffects holds
	     PlatformStand.
	OFF  the motors come back, everything added is removed, RequiresNeck is restored; getting up
	     (GettingUp) is StatusEffects' (NPCs) and the client's (players).
	Skipped: anchored bodies (far NPC rigs, stasis, dummies) and bodies with no motors (creatures).
	Flag: ragdoll_enabled.

		Ragdoll.set(humanoid, on)      Ragdoll.isLimp(humanoid) -> boolean
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)

local C = require(script.Parent.Parent.Data.CombatTuning)

local T = C.reactions.ragdoll

local FOLDER = "RagdollJoints"

type State = { motors: { Motor6D }, folder: Folder, requiresNeck: boolean, breakJoints: boolean }
local limp: { [Humanoid]: State } = setmetatable({}, { __mode = "k" }) :: any

local Ragdoll = {}

local function limbCollider(limb: BasePart, torso: BasePart?, folder: Folder)
	local part = Instance.new("Part")
	part.Name = limb.Name .. "Collider"
	part.Size = limb.Size * T.colliderShrink
	part.CFrame = limb.CFrame
	part.Transparency = 1
	part.Massless = true
	part.CanCollide = true
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Anchored = false
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = limb
	weld.Part1 = part
	weld.Parent = part
	if torso then
		local no = Instance.new("NoCollisionConstraint")
		no.Part0 = part
		no.Part1 = torso
		no.Parent = part
	end
	part.Parent = folder
end

local function on(humanoid: Humanoid, model: Model)
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and root.Anchored then
		return -- anchored bodies can't fall
	end
	local motors: { Motor6D } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("Motor6D") and d.Enabled and not T.keep[d.Name] and d.Part0 and d.Part1 then
			table.insert(motors, d)
		end
	end
	if #motors == 0 then
		return -- no limbs to let go (creature bodies)
	end
	local folder = Instance.new("Folder")
	folder.Name = FOLDER
	local torsoPart = model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso")
	local torso: BasePart? = if torsoPart and torsoPart:IsA("BasePart") then torsoPart else nil
	local collided: { [BasePart]: boolean } = {}
	for _, motor in motors do
		local part0, part1 = motor.Part0 :: BasePart, motor.Part1 :: BasePart
		local a0 = Instance.new("Attachment")
		a0.Name = "Ragdoll_" .. motor.Name .. "_0"
		a0.CFrame = motor.C0
		a0.Parent = part0
		local a1 = Instance.new("Attachment")
		a1.Name = "Ragdoll_" .. motor.Name .. "_1"
		a1.CFrame = motor.C1
		a1.Parent = part1
		local limits = T.joints[motor.Name] or T.default
		local socket = Instance.new("BallSocketConstraint")
		socket.Name = motor.Name
		socket.Attachment0 = a0
		socket.Attachment1 = a1
		socket.LimitsEnabled = true
		socket.UpperAngle = limits.upper
		socket.TwistLimitsEnabled = true
		socket.TwistLowerAngle = -limits.twist
		socket.TwistUpperAngle = limits.twist
		socket.Parent = folder
		-- The attachments live on the limbs: remember them so OFF removes them.
		a0:SetAttribute("Ragdoll", true)
		a1:SetAttribute("Ragdoll", true)
		if part1 ~= torso and not collided[part1] then
			collided[part1] = true
			limbCollider(part1, torso, folder)
		end
	end
	local state: State = { motors = motors, folder = folder, requiresNeck = humanoid.RequiresNeck, breakJoints = humanoid.BreakJointsOnDeath }
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	folder.Parent = model
	for _, motor in motors do
		motor.Enabled = false
	end
	limp[humanoid] = state
end

local function off(humanoid: Humanoid, model: Model?)
	local state = limp[humanoid]
	if not state then
		return
	end
	if humanoid.Parent and humanoid.Health <= 0 then
		return -- died while limp: the body stays a ragdoll until it's cleared away
	end
	limp[humanoid] = nil
	for _, motor in state.motors do
		if motor.Parent then
			motor.Enabled = true
		end
	end
	state.folder:Destroy()
	if model then
		for _, d in model:GetDescendants() do
			if d:IsA("Attachment") and d:GetAttribute("Ragdoll") then
				d:Destroy()
			end
		end
	end
	if humanoid.Parent then
		humanoid.RequiresNeck = state.requiresNeck
		humanoid.BreakJointsOnDeath = state.breakJoints
	end
end

function Ragdoll.set(humanoid: Humanoid, limpNow: boolean)
	local model = humanoid.Parent
	if not model or not model:IsA("Model") then
		return
	end
	if limpNow then
		if limp[humanoid] or FeatureFlags.get("ragdoll_enabled") == false or humanoid.Health <= 0 then
			return
		end
		local ok, err = pcall(on, humanoid, model)
		if not ok then
			warn("[Ragdoll] couldn't go limp: " .. tostring(err))
			off(humanoid, model)
		end
	else
		off(humanoid, model)
	end
end

function Ragdoll.isLimp(humanoid: Humanoid): boolean
	return limp[humanoid] ~= nil
end

return Ragdoll
