--!strict
--[[
	MarkFx: draws Magic Marks on one body (docs/MagicMarks.md). Data: Shared/Magic/Data/Marks.
	Client only and cosmetic; Controllers/MarkController decides which bodies get drawn.

	THE STRONGEST MARK covers both arms from the hand up, further each stage:
		R6   a skin-tight overlay over the bottom 30% / 60% / 100% of "Left Arm" and "Right Arm"
		R15  hands / + lower arms / + upper arms
	Every mark sends a few particles off the hands (fewer for a second mark), and at stage 3 a
	mark whose look has `head` adds a faint haze at the head.

	Parts are welded, massless, and can't collide, be touched or be hit by raycasts. They live in
	a client folder, not inside the character, so nothing else that scans characters sees them.
	No Neon: Bloom turns it white.

		MarkFx.build(model, marks, folder) -> Handle?     marks from MarkRules.decode
		handle:destroy()
		MarkFx.print(at: CFrame, prints, folder) -> BasePart   one footprint (the caller fades it)
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local MarkData = require(Shared.Magic.Data.Marks)
local DomainFx = require(script.Parent.DomainFx)

export type Handle = { destroy: (Handle) -> () }

local MarkFx = {}

local R6_ARMS = { "Left Arm", "Right Arm" }
local R15_ARMS = {
	{ "LeftHand", "RightHand" },
	{ "LeftLowerArm", "RightLowerArm" },
	{ "LeftUpperArm", "RightUpperArm" },
}
local R6_COVER = { 0.3, 0.6, 1 } -- share of the arm covered, from the hand up
local EMIT_RATE = { 0.8, 2, 4 } -- particles a second per hand, by stage
local SECOND_MARK_RATE = 0.6
local GROW = 1.04 -- overlays sit just outside the skin

local function material(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else Enum.Material.SmoothPlastic
end

local function overlay(folder: Instance, base: BasePart, size: Vector3, offset: CFrame, look: MarkData.Look, stage: number): BasePart
	local part = Instance.new("Part")
	part.Name = "Mark"
	part.Size = size
	part.CFrame = base.CFrame * offset
	part.Color = look.skin
	part.Material = material(look.material)
	-- Earlier stages are fainter: the colour is only starting to come through.
	part.Transparency = math.clamp(look.alpha + (3 - stage) * 0.12, 0, 0.95)
	part.CastShadow = false
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.Massless = true
	part.Anchored = false
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = base
	weld.Part1 = part
	weld.Parent = part
	part.Parent = folder
	return part
end

local function emitter(attachment: Attachment, look: MarkData.Look, rate: number): ParticleEmitter
	local e = look.emit
	local p = Instance.new("ParticleEmitter")
	p.Texture = (DomainFx.textures :: any)[e.texture] or DomainFx.textures.sparkles
	p.Color = ColorSequence.new(e.color)
	p.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, e.size), NumberSequenceKeypoint.new(1, e.size * 0.3) })
	p.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(1, 1) })
	p.Lifetime = NumberRange.new(e.life * 0.7, e.life)
	p.Rate = rate
	p.Speed = NumberRange.new(e.drift * 0.6, e.drift)
	p.SpreadAngle = Vector2.new(180, 180)
	p.Acceleration = Vector3.new(0, -e.gravity, 0)
	p.Rotation = NumberRange.new(0, 360)
	p.RotSpeed = NumberRange.new(-40, 40)
	p.LightEmission = 0.2
	p.LightInfluence = 0.6
	p.Parent = attachment
	return p
end

local function hands(model: Model): { { part: BasePart, at: Vector3 } }
	local out: { { part: BasePart, at: Vector3 } } = {}
	for _, name in R6_ARMS do
		local arm = model:FindFirstChild(name)
		if arm and arm:IsA("BasePart") then
			table.insert(out, { part = arm, at = Vector3.new(0, -arm.Size.Y / 2, 0) })
		end
	end
	if #out == 0 then
		for _, name in R15_ARMS[1] do
			local hand = model:FindFirstChild(name)
			if hand and hand:IsA("BasePart") then
				table.insert(out, { part = hand, at = Vector3.zero })
			end
		end
	end
	return out
end

local function coverArms(model: Model, folder: Instance, look: MarkData.Look, stage: number, made: { Instance })
	local r6 = false
	for _, name in R6_ARMS do
		local arm = model:FindFirstChild(name)
		if arm and arm:IsA("BasePart") then
			r6 = true
			local h = arm.Size.Y * R6_COVER[stage]
			local size = Vector3.new(arm.Size.X * GROW, h + 0.02, arm.Size.Z * GROW)
			local offset = CFrame.new(0, -arm.Size.Y / 2 + h / 2 - 0.01, 0)
			table.insert(made, overlay(folder, arm, size, offset, look, stage))
		end
	end
	if r6 then
		return
	end
	for level = 1, stage do
		for _, name in R15_ARMS[level] do
			local part = model:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				table.insert(made, overlay(folder, part, part.Size * GROW, CFrame.identity, look, stage))
			end
		end
	end
end

function MarkFx.build(model: Model, marks: { { domain: string, stage: number } }, folder: Instance): Handle?
	if #marks == 0 then
		return nil
	end
	local made: { Instance } = {}
	for i, mark in marks do
		local def = MarkData.domains[mark.domain]
		if def then
			local look = def.look
			if i == 1 then
				coverArms(model, folder, look, mark.stage, made)
			end
			local rate = EMIT_RATE[mark.stage] * (if i == 1 then 1 else SECOND_MARK_RATE)
			for _, hand in hands(model) do
				local attachment = Instance.new("Attachment")
				attachment.Name = "MarkEmit"
				attachment.Position = hand.at
				attachment.Parent = hand.part
				emitter(attachment, look, rate)
				table.insert(made, attachment)
			end
			local head = model:FindFirstChild("Head")
			if mark.stage >= 3 and look.head and head and head:IsA("BasePart") then
				local attachment = Instance.new("Attachment")
				attachment.Name = "MarkHaze"
				attachment.Parent = head
				local haze = emitter(attachment, look, 1.2)
				haze.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.9), NumberSequenceKeypoint.new(1, 1.4) })
				haze.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.8), NumberSequenceKeypoint.new(1, 1) })
				haze.Speed = NumberRange.new(0.2, 0.5)
				table.insert(made, attachment)
			end
		end
	end
	local handle = {}
	function handle.destroy(_self: Handle)
		for _, instance in made do
			instance:Destroy()
		end
		table.clear(made)
	end
	return handle :: any
end

function MarkFx.print(at: CFrame, prints: MarkData.Prints, folder: Instance): BasePart
	local part = Instance.new("Part")
	part.Name = "MarkPrint"
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Size = Vector3.new(prints.size * 0.55, 0.05, prints.size)
	part.CFrame = at
	part.Color = prints.color
	part.Material = material(prints.material)
	part.Transparency = prints.alpha
	part.Parent = folder
	return part
end

return MarkFx
