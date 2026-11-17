--!strict
--[[
	Ragdoll.spec: knocked-down bodies go limp (Server/Magic/Cast/Ragdoll). What matters most: the
	limb joints let go into ball sockets and the root joint holds, limbs get colliders, everything
	comes back exactly as it was on getting up, and anchored bodies are left alone. Built on a real
	R6 rig made here, far from the world, and destroyed after.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Ragdoll = require(ServerScriptService.Server.Magic.Cast.Ragdoll)
local Flags = require(ServerScriptService.Server.Config.Flags)

local LIMBS = {
	{ name = "Head", size = Vector3.new(2, 1, 1), joint = "Neck", c0 = CFrame.new(0, 1, 0), c1 = CFrame.new(0, -0.5, 0) },
	{ name = "Left Arm", size = Vector3.new(1, 2, 1), joint = "Left Shoulder", c0 = CFrame.new(-1, 0.5, 0), c1 = CFrame.new(0.5, 0.5, 0) },
	{ name = "Right Arm", size = Vector3.new(1, 2, 1), joint = "Right Shoulder", c0 = CFrame.new(1, 0.5, 0), c1 = CFrame.new(-0.5, 0.5, 0) },
	{ name = "Left Leg", size = Vector3.new(1, 2, 1), joint = "Left Hip", c0 = CFrame.new(-1, -1, 0), c1 = CFrame.new(-0.5, 1, 0) },
	{ name = "Right Leg", size = Vector3.new(1, 2, 1), joint = "Right Hip", c0 = CFrame.new(1, -1, 0), c1 = CFrame.new(0.5, 1, 0) },
}

local function makeRig(anchored: boolean): (Model, Humanoid)
	local model = Instance.new("Model")
	model.Name = "RagdollSpecRig"
	local origin = CFrame.new(0, 20000, 0)
	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = Vector3.new(2, 2, 1)
	root.CFrame = origin
	root.Anchored = anchored
	root.Parent = model
	local torso = Instance.new("Part")
	torso.Name = "Torso"
	torso.Size = Vector3.new(2, 2, 1)
	torso.CFrame = origin
	torso.Parent = model
	local rootJoint = Instance.new("Motor6D")
	rootJoint.Name = "RootJoint"
	rootJoint.Part0, rootJoint.Part1 = root, torso
	rootJoint.Parent = root
	for _, limb in LIMBS do
		local part = Instance.new("Part")
		part.Name = limb.name
		part.Size = limb.size
		part.CFrame = origin * limb.c0 * limb.c1:Inverse()
		part.Parent = model
		local motor = Instance.new("Motor6D")
		motor.Name = limb.joint
		motor.Part0, motor.Part1 = torso, part
		motor.C0, motor.C1 = limb.c0, limb.c1
		motor.Parent = torso
	end
	local humanoid = Instance.new("Humanoid")
	humanoid.Parent = model
	model.PrimaryPart = root
	model.Parent = workspace
	return model, humanoid
end

local function count(model: Model, class: string): number
	local n = 0
	for _, d in model:GetDescendants() do
		if d:IsA(class) then
			n += 1
		end
	end
	return n
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Ragdoll", function()
		it("lets the limbs go and keeps the root joint", function()
			expect((Flags :: any).ragdoll_enabled ~= nil).toBe(true)
			local model, humanoid = makeRig(false)
			Ragdoll.set(humanoid, true)
			expect(Ragdoll.isLimp(humanoid)).toBe(true)
			expect(count(model, "BallSocketConstraint")).toBe(5)
			local torso = model:FindFirstChild("Torso") :: BasePart
			for _, limb in LIMBS do
				expect((torso:FindFirstChild(limb.joint) :: Motor6D).Enabled).toBe(false)
			end
			local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
			expect((root:FindFirstChild("RootJoint") :: Motor6D).Enabled).toBe(true)
			local folder = model:FindFirstChild("RagdollJoints")
			expect(folder ~= nil and folder:FindFirstChild("Left ArmCollider") ~= nil).toBe(true)
			expect(humanoid.RequiresNeck).toBe(false)
			model:Destroy()
		end)

		it("puts everything back on getting up", function()
			local model, humanoid = makeRig(false)
			local attachmentsBefore = count(model, "Attachment")
			local breakJoints = humanoid.BreakJointsOnDeath
			Ragdoll.set(humanoid, true)
			Ragdoll.set(humanoid, false)
			expect(Ragdoll.isLimp(humanoid)).toBe(false)
			expect(count(model, "BallSocketConstraint")).toBe(0)
			expect(count(model, "Attachment")).toBe(attachmentsBefore)
			expect(model:FindFirstChild("RagdollJoints") == nil).toBe(true)
			local torso = model:FindFirstChild("Torso") :: BasePart
			for _, limb in LIMBS do
				expect((torso:FindFirstChild(limb.joint) :: Motor6D).Enabled).toBe(true)
			end
			expect(humanoid.RequiresNeck).toBe(true)
			expect(humanoid.BreakJointsOnDeath).toBe(breakJoints)
			-- Asking twice either way changes nothing.
			Ragdoll.set(humanoid, false)
			expect(count(model, "BallSocketConstraint")).toBe(0)
			model:Destroy()
		end)

		it("leaves anchored bodies alone", function()
			local model, humanoid = makeRig(true)
			Ragdoll.set(humanoid, true)
			expect(Ragdoll.isLimp(humanoid)).toBe(false)
			expect(count(model, "BallSocketConstraint")).toBe(0)
			model:Destroy()
		end)
	end)
end
