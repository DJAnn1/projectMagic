--!strict
--[[
	WildbornRig: a Wildborn's body (docs/Wildborn.md). Always a real R6 HUMANOID character rig
	(Players:CreateHumanoidModelFromDescription, the same as NPC rigs: Head, Torso, arms, legs,
	HumanoidRootPart, Motor6Ds), never a welded creature body, so it walks, poses and plays the
	combat clips like a person, and every spell, status and lock-on treats it as one.

	Dressed by its data `look`: skin and cloth colours (the land shows in the skin), a dimmed glowing
	band at the waist and glowing eyes in the theme's colour, a catalog hood (NPC/NpcLooks, Roblox-made
	items only) for ordinary Wildborn, a crown of glowing points for bosses, and a particle aura from
	the torso. Bosses are scaled up (Model:ScaleTo through NpcLooks.apply).

	Marked as a creature (attribute Creature = id), so hitting one is never a crime (Cast/Damage),
	and `Wildborn` = id for everything else. Resist_<key> on the Humanoid (Cast/Resistances "manual").

	Animation: the default Animate script is removed; WildbornService plays idle/walk and the combat
	clips (CastSpell, Slash1) from the tracks returned here.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local CombatAnimations = require(ReplicatedStorage.Shared.Magic.Data.CombatAnimations)
local NpcLooks = require(script.Parent.Parent.NPC.NpcLooks)
local NpcLooksData = require(script.Parent.Parent.NPC.Data.NpcLooks)
local Data = require(script.Parent.Data.Wildborn)

local WildbornRig = {}

local AMBIENT = {
	idle = "rbxassetid://180435571",
	walk = "rbxassetid://180426354",
}
local CLIPS = { "CastSpell", "Slash1" }
local SKIN = { "Head", "Left Arm", "Right Arm" }
local CLOTH = { "Torso", "Left Leg", "Right Leg" }
local GLOW_DIM = 0.45 -- Neon under Bloom blows out to white: keep accents dim (as NPC accents)

local DISABLED_STATES = {
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.Flying,
	Enum.HumanoidStateType.GettingUp,
}

export type Rig = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	tracks: { [string]: AnimationTrack },
}

local function dim(color: Color3): Color3
	return Color3.new(color.R * GLOW_DIM, color.G * GLOW_DIM, color.B * GLOW_DIM)
end

local function glowPart(name: string, size: Vector3, color: Color3, parent: BasePart, offset: CFrame, shape: Enum.PartType?): BasePart
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = shape or Enum.PartType.Block
	part.Size = size
	part.Color = dim(color)
	part.Material = Enum.Material.Neon
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.CFrame = parent.CFrame * offset
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = parent
	weld.Part1 = part
	weld.Parent = part
	part.Parent = parent.Parent
	return part
end

local function hoodId(seed: number): number?
	local pool = (NpcLooksData :: any).headwear and (NpcLooksData :: any).headwear.hood
	local ids = pool and pool.ids
	if not ids or #ids == 0 then
		return nil
	end
	return ids[(seed % #ids) + 1]
end

-- Builds the rig at `at` (not parented). `seed` picks small variations (which hood).
function WildbornRig.build(enemy: Data.Enemy, at: CFrame, seed: number): Rig?
	local ok, model = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R6)
	end)
	if not ok or not model then
		return nil
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		model:Destroy()
		return nil
	end
	local theme = Data.themes[enemy.theme]
	model.Name = enemy.name
	model:SetAttribute("Creature", enemy.id)
	model:SetAttribute("Wildborn", enemy.id)
	local animate = model:FindFirstChild("Animate")
	if animate then
		animate:Destroy()
	end

	-- Colours: the land in the skin, their old clothes darkened.
	for _, name in SKIN do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			part.Color = enemy.look.skin
		end
	end
	for _, name in CLOTH do
		local part = model:FindFirstChild(name)
		if part and part:IsA("BasePart") then
			part.Color = enemy.look.cloth
		end
	end
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") then
			part:SetAttribute("Flammability", 0)
		end
	end

	model:PivotTo(at)
	local torso = model:FindFirstChild("Torso") :: BasePart?
	local head = model:FindFirstChild("Head") :: BasePart?
	if torso then
		glowPart("WildBand", Vector3.new(2.05, 0.25, 1.05), enemy.look.accent, torso, CFrame.new(0, -0.7, 0))
		local aura = Instance.new("ParticleEmitter")
		aura.Name = "WildAura"
		aura.Color = ColorSequence.new(theme.primary, theme.secondary)
		aura.Size = NumberSequence.new(if enemy.boss then 1.3 else 0.8, 0)
		aura.Transparency = NumberSequence.new(0.25, 1)
		aura.Lifetime = NumberRange.new(0.8, 1.6)
		aura.Rate = if enemy.boss then 30 else 12
		aura.Speed = NumberRange.new(2, 6)
		aura.SpreadAngle = Vector2.new(60, 60)
		aura.LightEmission = 0.6
		local attachment = Instance.new("Attachment")
		attachment.Parent = torso
		aura.Parent = attachment
	end
	if head then
		for side = -1, 1, 2 do
			glowPart("WildEye", Vector3.new(0.18, 0.12, 0.05), theme.secondary, head, CFrame.new(side * 0.2, 0.15, -0.6))
		end
		if enemy.look.crown then
			for i = 0, 4 do
				local angle = (i / 5) * math.pi * 2
				glowPart("WildCrown", Vector3.new(0.18, 0.55, 0.18), enemy.look.accent, head,
					CFrame.new(math.cos(angle) * 0.55, 0.75, math.sin(angle) * 0.55) * CFrame.Angles(0, -angle, math.rad(10)))
			end
		end
	end

	-- Accessories and scale (NpcLooks loads Roblox-made catalog items once; missing ones are skipped).
	local id = if enemy.look.hood then hoodId(seed) else nil
	NpcLooks.apply(model, humanoid, { ids = if id then { id } else {}, scale = enemy.scale, garments = {}, accent = nil } :: any)

	humanoid.MaxHealth = enemy.health
	humanoid.Health = enemy.health
	humanoid.WalkSpeed = enemy.walk
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayName = if enemy.title then (string.gsub(enemy.title, "^the ", "The ")) else enemy.name
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.Viewer
	humanoid.NameDisplayDistance = if enemy.boss then 90 else 50
	humanoid.HealthDisplayDistance = if enemy.boss then 90 else 50
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.DisplayWhenDamaged
	for _, state in DISABLED_STATES do
		humanoid:SetStateEnabled(state, false)
	end
	for key, value in enemy.resist do
		humanoid:SetAttribute("Resist_" .. key, value)
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		local made = Instance.new("Animator")
		made.Parent = humanoid
		animator = made
	end
	local tracks: { [string]: AnimationTrack } = {}
	local function load(name: string, id2: string, looped: boolean, priority: Enum.AnimationPriority)
		local animation = Instance.new("Animation")
		animation.AnimationId = id2
		local ok2, track = pcall(function()
			return (animator :: Animator):LoadAnimation(animation)
		end)
		if ok2 and track then
			track.Looped = looped
			track.Priority = priority
			tracks[name] = track
		end
	end
	load("idle", AMBIENT.idle, true, Enum.AnimationPriority.Idle)
	load("walk", AMBIENT.walk, true, Enum.AnimationPriority.Movement)
	for _, clip in CLIPS do
		local def = CombatAnimations.animations[clip]
		if def then
			load(clip, "rbxassetid://" .. tostring(def.id), false, Enum.AnimationPriority.Action2)
		end
	end
	return { model = model, humanoid = humanoid, root = root, tracks = tracks }
end

return WildbornRig
