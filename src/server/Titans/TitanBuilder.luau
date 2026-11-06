--!strict
--[[
	TitanBuilder: the bones a Titan leaves where it falls (docs/Titans.md). Seeded from the fall's id, so
	they look the same on every server. It only builds; Services/TitanService decides when, and adds the
	prompt.

	Anchored, tagged NoMagicEdit and unburnable: spells can't move them. They reach well below the ground
	line, because the crater is carved around them after the generator's height was read.
	Budget: about 20 parts, only while someone is near.
]]

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)
local T = require(Shared.Titans.Data.Titans)

local Rules = require(script.Parent.TitanRules)

local M = Enum.Material

local TitanBuilder = {}

function TitanBuilder.landmark(fall: Rules.Fall, worldSeed: number, ground: number): (Model, BasePart)
	local kind = T.kinds[fall.kind]
	local model = Instance.new("Model")
	model.Name = "TitanFall_" .. fall.id
	local rng = Seed.random(worldSeed, fall.id, "bones")
	local facing = rng:NextNumber() * 2 * math.pi
	local base = CFrame.new(fall.x, ground, fall.z) * CFrame.Angles(0, facing, 0)
	local color = kind.bone

	local function bone(name: string, size: Vector3, cframe: CFrame, material: Enum.Material, tint: Color3): Part
		local p = Instance.new("Part")
		p.Name = name
		p.Size = size
		p.CFrame = cframe
		p.Color = tint
		p.Material = material
		p.Anchored = true
		p.CanTouch = false
		p.TopSurface = Enum.SurfaceType.Smooth
		p.BottomSurface = Enum.SurfaceType.Smooth
		p:SetAttribute("Flammability", 0)
		CollectionService:AddTag(p, "NoMagicEdit")
		p.Parent = model
		return p
	end

	-- The spine, half buried, and ribs arching over it, as if it fell on its side.
	bone("Spine", Vector3.new(7, 7, 74), base * CFrame.new(0, 1, 0), M.Slate, color)
	for i = -3, 3 do
		for _, side in { -1, 1 } do
			local height = 26 + rng:NextNumber() * 6
			local lean = math.rad(14 + rng:NextNumber() * 8) * side
			bone("Rib", Vector3.new(3.4, height, 4.6), base * CFrame.new(side * 7, height / 2 - 6, i * 10) * CFrame.Angles(0, 0, -lean), M.Slate, color)
		end
	end

	-- The skull, and the one part of it that hasn't gone out.
	bone("Skull", Vector3.new(18, 15, 18), base * CFrame.new(0, 5, -46) * CFrame.Angles(math.rad(12), 0.4, 0.2), M.Slate, color)
	local ember = bone("Ember", Vector3.new(5, 5, 5), base * CFrame.new(0, 7, -56), M.Neon, kind.color)
	ember.Shape = Enum.PartType.Ball
	ember.CanCollide = false
	local glow = Instance.new("PointLight")
	glow.Color = kind.color
	glow.Range = 30
	glow.Brightness = 1.4
	glow.Shadows = false
	glow.Parent = ember
	local motes = Instance.new("ParticleEmitter")
	motes.Color = ColorSequence.new(kind.color)
	motes.Rate = 6
	motes.Lifetime = NumberRange.new(1, 2.5)
	motes.Speed = NumberRange.new(1, 3)
	motes.SpreadAngle = Vector2.new(180, 180)
	motes.Size = NumberSequence.new(0.5, 0)
	motes.LightEmission = 0.8
	motes.Parent = ember

	model.PrimaryPart = ember
	model.Parent = workspace
	return model, ember
end

return TitanBuilder
