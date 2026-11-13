--!strict
--[[
	StatusFx: draws one status on one body (data in Shared/Magic/Data/StatusLooks; driven by
	Controllers/StatusLookController). A body gets particle layers on its torso, head or feet, and
	a frozen body a translucent ice shell over the torso and limbs. Everything here is created on
	this client only: it never collides, weighs nothing, and is removed with the status.

		StatusFx.draw(model, statusId, reduced) -> Handle?
		StatusFx.undraw(handle)

	Works on R6 and R15 bodies (Torso or UpperTorso; limbs found by name).
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local StatusLooks = require(ReplicatedStorage:WaitForChild("Shared").Magic.Data.StatusLooks)
local FxLayers = require(script.Parent.FxLayers)
local DomainFx = require(script.Parent.DomainFx)

local TEX = DomainFx.textures

local StatusFx = {}

export type Handle = { made: { Instance } }

local LIMBS = { "Torso", "UpperTorso", "LowerTorso", "Left Arm", "Right Arm", "Left Leg", "Right Leg", "LeftUpperArm", "RightUpperArm", "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg", "LeftLowerArm", "RightLowerArm" }

local function partFor(model: Model, at: string): BasePart?
	local names = if at == "head" then { "Head" } elseif at == "feet" then { "HumanoidRootPart" } else { "Torso", "UpperTorso", "HumanoidRootPart" }
	for _, name in names do
		local p = model:FindFirstChild(name)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	return nil
end

local function emitterOn(part: BasePart, spec: StatusLooks.Emit, reduced: boolean, feet: boolean): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = "StatusFx"
	e.Texture = (TEX :: any)[spec.texture] or TEX.sparkles
	e.Color = FxLayers.solid(spec.color)
	e.Size = FxLayers.seq(0, spec.size * 0.6, 0.4, spec.size, 1, spec.size * 0.3)
	e.Transparency = FxLayers.seq(0, 0.25, 0.7, 0.5, 1, 1)
	e.Lifetime = NumberRange.new(spec.lifetime * 0.7, spec.lifetime)
	local speed = spec.speed or 0
	e.Speed = NumberRange.new(speed * 0.5, speed)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Acceleration = Vector3.new(0, spec.rise or 0, 0)
	e.RotSpeed = NumberRange.new(-60, 60)
	e.Rotation = NumberRange.new(0, 360)
	e.LightEmission = if spec.additive then 1 else 0
	e.LightInfluence = if spec.additive then 0 else 0.8
	e.Rate = spec.rate * (if reduced then 0.4 else 1)
	if spec.orbit then
		e.Shape = Enum.ParticleEmitterShape.Sphere
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Surface
		e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Outward
	else
		e.Shape = Enum.ParticleEmitterShape.Box
		e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	end
	e.Parent = part
	if feet then
		-- The root sits at the waist; feet effects start lower via an attachment.
		local at = Instance.new("Attachment")
		at.Name = "StatusFxFeet"
		at.Position = Vector3.new(0, -2.6, 0)
		at.Parent = part
		e.Parent = at
		return e
	end
	return e
end

local function shellOn(model: Model, shell: { color: Color3, transparency: number, material: string }, made: { Instance })
	local material = (Enum.Material :: any)[shell.material] or Enum.Material.Ice
	for _, name in LIMBS do
		local limb = model:FindFirstChild(name)
		if limb and limb:IsA("BasePart") then
			local part = Instance.new("Part")
			part.Name = "StatusShell"
			part.Size = limb.Size + Vector3.new(0.35, 0.35, 0.35)
			part.CFrame = limb.CFrame
			part.Color = shell.color
			part.Material = material
			part.Transparency = shell.transparency
			part.CanCollide = false
			part.CanQuery = false
			part.CanTouch = false
			part.Massless = true
			part.CastShadow = false
			part.Anchored = false
			local weld = Instance.new("WeldConstraint")
			weld.Part0 = part
			weld.Part1 = limb
			weld.Parent = part
			part.Parent = model
			table.insert(made, part)
		end
	end
end

function StatusFx.draw(model: Model, statusId: string, reduced: boolean): Handle?
	local look = StatusLooks.looks[statusId]
	if not look then
		return nil
	end
	local made: { Instance } = {}
	for _, spec in (look.emit or {}) :: { StatusLooks.Emit } do
		local part = partFor(model, spec.at)
		if part then
			local e = emitterOn(part, spec, reduced, spec.at == "feet")
			table.insert(made, if spec.at == "feet" then e.Parent :: Instance else e)
		end
	end
	if look.shell then
		shellOn(model, look.shell, made)
	end
	return if #made > 0 then { made = made } else nil
end

function StatusFx.undraw(handle: Handle?)
	if not handle then
		return
	end
	for _, instance in handle.made do
		if instance:IsA("ParticleEmitter") then
			-- Let the last particles finish instead of popping out.
			instance.Enabled = false
			task.delay(1.5, function()
				instance:Destroy()
			end)
		elseif instance:IsA("Attachment") then
			for _, child in instance:GetChildren() do
				if child:IsA("ParticleEmitter") then
					child.Enabled = false
				end
			end
			task.delay(1.5, function()
				instance:Destroy()
			end)
		else
			instance:Destroy()
		end
	end
end

return StatusFx
