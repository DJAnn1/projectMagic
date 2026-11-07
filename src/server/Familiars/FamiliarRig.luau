--!strict
--[[
	FamiliarRig: builds a familiar's body from FamiliarRules.body.

	No Humanoid, on purpose. Every part is CanCollide, CanQuery and CanTouch off, so:
	- spells, aim, projectiles and lock-on can't see it: your own bolts pass through it, and nobody can
	  grief you by killing it;
	- walls never stop it, so it never needs pathfinding and never gets stuck;
	- 60 of them cost 60 small floating assemblies, not 60 Humanoids.
	AlignPosition and AlignOrientation move it, so clients get the engine's smooth physics replication.

	Not parented: the caller parents it, then gives the server network ownership of the root.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local FamiliarRules = require(Shared.Familiars.FamiliarRules)

local CreatureRig = require(script.Parent.Parent.Creatures.CreatureRig)

export type Rig = {
	model: Model,
	root: BasePart,
	align: AlignPosition,
	orient: AlignOrientation,
	nameLabel: TextLabel,
	healthBar: Frame,
}

local FORCE = 200000

local function quiet(part: BasePart)
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part:SetAttribute("Flammability", 0)
end

local FamiliarRig = {}

function FamiliarRig.build(body: FamiliarRules.Body, at: CFrame, ownerId: number): Rig
	local model = Instance.new("Model")
	model.Name = "Familiar"
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model:SetAttribute("FamiliarOwner", ownerId)

	local root = Instance.new("Part")
	root.Name = "Root"
	root.Size = Vector3.new(1, 1, 1)
	root.CFrame = at
	root.Transparency = 1
	root.Massless = false
	quiet(root)
	root.Parent = model
	model.PrimaryPart = root

	for _, spec in body.parts do
		local part = Instance.new("Part")
		part.Name = spec.name
		part.Size = spec.size
		if spec.shape == "Ball" then
			CreatureRig.ellipsoid(part)
		end
		part.CFrame = at * CFrame.new(spec.offset)
		part.Color = spec.color
		part.Material = spec.material
		part.Transparency = spec.transparency
		part.Massless = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		quiet(part)
		-- A Weld, not a WeldConstraint: Fx/FamiliarAnimator poses parts through C0, on each client only.
		local weld = Instance.new("Weld")
		weld.Name = "Pose"
		weld.Part0 = root
		weld.Part1 = part
		weld.C0 = CFrame.new(spec.offset)
		weld.Parent = part
		local anim = spec.anim
		if anim then
			part:SetAttribute("Anim", anim.kind)
			part:SetAttribute("AnimAmount", anim.amount)
			part:SetAttribute("AnimSpeed", anim.speed)
			part:SetAttribute("AnimPhase", anim.phase or 0)
		end
		part.Parent = model
	end

	local attachment = Instance.new("Attachment")
	attachment.Parent = root

	local align = Instance.new("AlignPosition")
	align.Mode = Enum.PositionAlignmentMode.OneAttachment
	align.Attachment0 = attachment
	align.ApplyAtCenterOfMass = true
	align.MaxForce = FORCE
	align.Responsiveness = 30
	align.Position = at.Position
	align.Parent = root

	local orient = Instance.new("AlignOrientation")
	orient.Mode = Enum.OrientationAlignmentMode.OneAttachment
	orient.Attachment0 = attachment
	orient.MaxTorque = FORCE
	orient.Responsiveness = 20
	orient.CFrame = at.Rotation
	orient.Parent = root

	if body.emit then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Color = ColorSequence.new(body.glow)
		emitter.Rate = 4
		emitter.Lifetime = NumberRange.new(0.5, 0.9)
		emitter.Speed = NumberRange.new(0.5, 1.5)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Size = NumberSequence.new(0.28, 0)
		emitter.LightEmission = 0.7
		emitter.Parent = root
	end

	if body.light then
		local light = Instance.new("PointLight")
		light.Color = body.glow
		light.Brightness = 1.2
		light.Range = 12
		light.Parent = root
	end

	if body.trail then
		-- Only shows while it moves, so it reads as speed and not as clutter.
		local top = Instance.new("Attachment")
		top.Position = Vector3.new(0, body.hover * 0.12 + 0.25, 0)
		top.Parent = root
		local bottom = Instance.new("Attachment")
		bottom.Position = Vector3.new(0, -(body.hover * 0.12 + 0.25), 0)
		bottom.Parent = root
		local trail = Instance.new("Trail")
		trail.Attachment0 = top
		trail.Attachment1 = bottom
		trail.Color = ColorSequence.new(body.glow)
		trail.Transparency = NumberSequence.new(0.55, 1)
		trail.Lifetime = 0.45
		trail.LightEmission = 0.6
		trail.FaceCamera = true
		trail.Parent = root
	end

	-- Name and health over its head. Words as well as a bar, so colour isn't the only cue.
	local gui = Instance.new("BillboardGui")
	gui.Name = "Tag"
	gui.Size = UDim2.fromOffset(120, 26)
	gui.StudsOffset = Vector3.new(0, body.top + 1.4, 0) -- from its height: a serpent is long, not tall
	gui.MaxDistance = 70
	gui.LightInfluence = 0
	gui.Parent = root

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.new(1, 0, 0, 18)
	label.Font = Enum.Font.GothamMedium
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.5
	label.TextSize = 13
	label.Text = ""
	label.Parent = gui

	local track = Instance.new("Frame")
	track.BackgroundColor3 = Color3.new(0, 0, 0)
	track.BackgroundTransparency = 0.5
	track.BorderSizePixel = 0
	track.Position = UDim2.new(0.2, 0, 0, 20)
	track.Size = UDim2.new(0.6, 0, 0, 4)
	track.Parent = gui

	local bar = Instance.new("Frame")
	bar.BackgroundColor3 = body.glow
	bar.BorderSizePixel = 0
	bar.Size = UDim2.fromScale(1, 1)
	bar.Parent = track

	return { model = model, root = root, align = align, orient = orient, nameLabel = label, healthBar = bar }
end

return FamiliarRig
