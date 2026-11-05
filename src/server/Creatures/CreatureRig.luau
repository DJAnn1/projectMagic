--!strict
--[[
	CreatureRig: builds one creature's Model from its data.

	It's a real Humanoid + HumanoidRootPart, so Cast/Targeting, Delivery, DamageModel, statuses
	(slows write Humanoid.WalkSpeed), knockdowns and lock-on all work with no creature-specific code.

	- RigType R15 regardless of the project's R6 avatars: that's the rig type where HipHeight sets
	  the float height of a body with no legs. These bodies have no limbs, no Motor6Ds and no
	  animations, so CombatAnimations.rigType doesn't apply.
	- RequiresNeck off: the part called Head is welded on, there's no neck to break.
	- One assembly: the body parts are welded and massless, so physics and replication see one body.
	- ModelStreamingMode Atomic: clients get the whole creature or none of it.
	- Flammability 0 on every part: a fire spell mustn't start a grass fire from a burning rat
	  (ThermalSim reads the attribute).
]]

local Creatures = require(script.Parent.Data.Creatures)

local DISABLED_STATES = {
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.Flying,
	Enum.HumanoidStateType.GettingUp,
}

local CreatureRig = {}

-- Draws a part as an ellipsoid filling its Size. A Ball part can't do this: Roblox forces a Ball's
-- size to be uniform, which would turn every flattened body round.
function CreatureRig.ellipsoid(part: BasePart)
	local mesh = Instance.new("SpecialMesh")
	mesh.MeshType = Enum.MeshType.Sphere
	mesh.Parent = part
end

-- Not parented: the caller parents it, then gives the server network ownership of the root.
function CreatureRig.build(def: Creatures.Def, at: CFrame): (Model, Humanoid, BasePart)
	local model = Instance.new("Model")
	model.Name = def.name
	model.ModelStreamingMode = Enum.ModelStreamingMode.Atomic
	model:SetAttribute("Creature", def.id)

	local root = Instance.new("Part")
	root.Name = "HumanoidRootPart"
	root.Size = def.hitbox
	root.CFrame = at
	root.Transparency = 1
	root.CanCollide = true
	root.CanTouch = false
	root.CastShadow = false
	root:SetAttribute("Flammability", 0)
	root.Parent = model
	model.PrimaryPart = root

	for _, spec in def.body do
		local part = Instance.new("Part")
		part.Name = spec.name
		part.Size = spec.size
		if spec.shape == "Ball" then
			CreatureRig.ellipsoid(part)
		end
		part.CFrame = at * CFrame.new(spec.offset)
		part.Color = spec.color
		part.Material = spec.material
		part.Transparency = spec.transparency or 0
		part.CanCollide = false
		part.CanTouch = false
		part.Massless = true
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part:SetAttribute("Flammability", 0)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = part
		weld.Parent = part
		part.Parent = model
	end

	local emit = def.emit
	if emit then
		local emitter = Instance.new("ParticleEmitter")
		emitter.Color = ColorSequence.new(emit.color)
		emitter.Rate = emit.rate
		emitter.Lifetime = NumberRange.new(0.4, 0.8)
		emitter.Speed = NumberRange.new(1, 2.5)
		emitter.SpreadAngle = Vector2.new(180, 180)
		emitter.Size = NumberSequence.new(0.35, 0)
		emitter.LightEmission = 0.8
		emitter.Parent = root
	end

	local humanoid = Instance.new("Humanoid")
	humanoid.RigType = Enum.HumanoidRigType.R15
	humanoid.AutomaticScalingEnabled = false
	humanoid.HipHeight = def.hipHeight
	humanoid.RequiresNeck = false
	humanoid.BreakJointsOnDeath = false
	humanoid.MaxHealth = def.health
	humanoid.Health = def.health
	humanoid.WalkSpeed = def.walk
	humanoid.JumpPower = 0
	humanoid.UseJumpPower = true
	humanoid.DisplayName = def.name
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.NameDisplayDistance = 50
	humanoid.HealthDisplayDistance = 50
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.DisplayWhenDamaged
	for _, state in DISABLED_STATES do
		humanoid:SetStateEnabled(state, false)
	end
	for key, value in def.resist do
		humanoid:SetAttribute("Resist_" .. key, value)
	end
	humanoid.Parent = model
	return model, humanoid, root
end

return CreatureRig
