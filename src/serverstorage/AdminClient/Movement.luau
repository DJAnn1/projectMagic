--!strict
--[[
	Movement: fly and noclip for the admin's own character. They run here because the client
	owns its character's physics; the server only grants them (Teleport.luau's fly / noclip reply
	with { kind = "movement", fly, flySpeed, noclip }). Survives respawns.

	Fly: WASD (or the thumbstick's MoveDirection), Space up, LeftControl/C down, camera-relative.
	Noclip: every character part stops colliding each physics step.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Movement = {}

local state = { fly = false, flySpeed = 80, noclip = false }
local flyParts: { velocity: LinearVelocity?, align: AlignOrientation?, attachment: Attachment? } = {}

local function character(): (Model?, BasePart?, Humanoid?)
	local c = Players.LocalPlayer.Character
	local root = c and c:FindFirstChild("HumanoidRootPart")
	local humanoid = c and c:FindFirstChildOfClass("Humanoid")
	return c, if root and root:IsA("BasePart") then root else nil, humanoid
end

local function stopFlying()
	for _, inst in flyParts :: { [string]: Instance? } do
		if inst then
			inst:Destroy()
		end
	end
	table.clear(flyParts)
	local _, _, humanoid = character()
	if humanoid then
		humanoid.PlatformStand = false
	end
end

local function startFlying()
	stopFlying()
	local _, root, humanoid = character()
	if not root or not humanoid then
		return
	end
	local attachment = Instance.new("Attachment")
	attachment.Name = "AdminFly"
	attachment.Parent = root
	local velocity = Instance.new("LinearVelocity")
	velocity.Attachment0 = attachment
	velocity.MaxForce = math.huge
	velocity.VectorVelocity = Vector3.zero
	velocity.RelativeTo = Enum.ActuatorRelativeTo.World
	velocity.Parent = root
	local align = Instance.new("AlignOrientation")
	align.Mode = Enum.OrientationAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.MaxTorque = math.huge
	align.Responsiveness = 60
	align.Parent = root
	flyParts.attachment, flyParts.velocity, flyParts.align = attachment, velocity, align
	humanoid.PlatformStand = true
end

function Movement.apply(data: any)
	state.fly = data.fly == true
	state.flySpeed = tonumber(data.flySpeed) or state.flySpeed
	local wasNoclip = state.noclip
	state.noclip = data.noclip == true
	if wasNoclip and not state.noclip then
		-- Restore the parts a character normally collides with (limbs never do).
		local c = character()
		for _, name in { "HumanoidRootPart", "UpperTorso", "LowerTorso", "Torso", "Head" } do
			local p = c and c:FindFirstChild(name)
			if p and p:IsA("BasePart") then
				p.CanCollide = true
			end
		end
	end
	if state.fly then
		startFlying()
	else
		stopFlying()
	end
end

function Movement.start()
	Players.LocalPlayer.CharacterAdded:Connect(function()
		task.wait(0.5)
		if state.fly then
			startFlying()
		end
	end)

	RunService.RenderStepped:Connect(function()
		local velocity, align = flyParts.velocity, flyParts.align
		if not state.fly or not velocity or not align then
			return
		end
		local camera = workspace.CurrentCamera
		local _, _, humanoid = character()
		local look = camera.CFrame.LookVector
		local right = camera.CFrame.RightVector
		local direction = Vector3.zero
		if UserInputService:GetFocusedTextBox() == nil then
			if UserInputService:IsKeyDown(Enum.KeyCode.W) then
				direction += look
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.S) then
				direction -= look
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.D) then
				direction += right
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.A) then
				direction -= right
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.Space) then
				direction += Vector3.yAxis
			end
			if UserInputService:IsKeyDown(Enum.KeyCode.LeftControl) or UserInputService:IsKeyDown(Enum.KeyCode.C) then
				direction -= Vector3.yAxis
			end
		end
		if direction.Magnitude < 0.01 and humanoid and humanoid.MoveDirection.Magnitude > 0 then
			direction = humanoid.MoveDirection -- touch thumbstick
		end
		velocity.VectorVelocity = if direction.Magnitude > 0.01 then direction.Unit * state.flySpeed else Vector3.zero
		align.CFrame = CFrame.lookAt(Vector3.zero, Vector3.new(look.X, 0, look.Z).Unit)
	end)

	RunService.Stepped:Connect(function()
		if not state.noclip then
			return
		end
		local c = Players.LocalPlayer.Character
		if c then
			for _, p in c:GetDescendants() do
				if p:IsA("BasePart") then
					p.CanCollide = false
				end
			end
		end
	end)
end

return Movement
