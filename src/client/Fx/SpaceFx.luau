--!strict
--[[
	SpaceFx: what Space looks like (docs/Space.md, stage 1). Cosmetic: Cast/SpaceRuntime and
	Effects/SpacePower decide everything and send a "space" cue with `fx`:

		gate_open    two standing rings, each a dark hole with a pale rim and drifting stars, facing out
		gate_close   both collapse to a point
		gate_pass    a flash where someone came out
		seal         a crisp glass box with bright edges around a body, until seal_end
		swap         two flashes and a thread between them
		cut          a thin white tear along the aim that closes
		stride       ripples left at your feet while it lasts
		dislocate    a tear where you were and where you landed

	Reduce spell effects keeps gates and seals (they're information) and drops the rest's flourishes.
]]

local Debris = game:GetService("Debris")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage").Shared
local S = require(Shared.Magic.Data.SpaceTuning)

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)

local RIM, DEEP, STAR = S.looks.rim, S.looks.deep, S.looks.star

local SpaceFx = {}

local alive: { [number]: { Instance } } = {}

local function reduced(): boolean
	return Theme.settings.reducedEffects == true
end

local function holder(): Instance
	return workspace:FindFirstChild("MagicFx") or workspace
end

local function part(shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = "SpaceFx"
	p.Shape = shape
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	p.Transparency = transparency
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Parent = holder()
	return p
end

local function stars(parent: BasePart, rate: number)
	local e = Instance.new("ParticleEmitter")
	e.Color = ColorSequence.new(STAR)
	e.LightEmission = 1
	e.Size = NumberSequence.new(0.18, 0)
	e.Lifetime = NumberRange.new(0.6, 1.2)
	e.Speed = NumberRange.new(0.5, 2)
	e.SpreadAngle = Vector2.new(180, 180)
	e.Rate = rate
	e.Parent = parent
end

local function flash(position: Vector3, size: number)
	local ball = part(Enum.PartType.Ball, Vector3.new(size, size, size), CFrame.new(position), RIM, Enum.Material.Neon, 0.2)
	TweenService:Create(ball, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.2, 0.2, 0.2), Transparency = 1 }):Play()
	Debris:AddItem(ball, 0.4)
end

-- A standing ring at `cf` (its LookVector is the face): a dark disc inside a pale rim.
local function ring(cf: CFrame, radius: number, seconds: number): { Instance }
	local center = cf * CFrame.new(0, 1, 0)
	-- A Cylinder's axis is its X: turn it so the axis runs along the gate's face.
	local face = center * CFrame.Angles(0, math.pi / 2, 0)
	local d = radius * 2
	local rim = part(Enum.PartType.Cylinder, Vector3.new(0.15, d + 0.6, d + 0.6), face, RIM, Enum.Material.Neon, 0.15)
	local hole = part(Enum.PartType.Cylinder, Vector3.new(0.2, d, d), face, DEEP, Enum.Material.Glass, 0.05)
	if not reduced() then
		stars(hole, 14)
	end
	rim.Size = Vector3.new(0.15, 0.2, 0.2)
	hole.Size = Vector3.new(0.2, 0.1, 0.1)
	TweenService:Create(rim, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = Vector3.new(0.15, d + 0.6, d + 0.6) }):Play()
	TweenService:Create(hole, TweenInfo.new(0.35, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Size = Vector3.new(0.2, d, d) }):Play()
	Debris:AddItem(rim, seconds + 1)
	Debris:AddItem(hole, seconds + 1)
	return { rim, hole }
end

local function close(id: number)
	local list = alive[id]
	if not list then
		return
	end
	alive[id] = nil
	for _, inst in list do
		if inst:IsA("BasePart") and inst.Parent then
			for _, child in inst:GetChildren() do
				if child:IsA("ParticleEmitter") then
					child.Enabled = false
				end
			end
			TweenService:Create(inst, TweenInfo.new(0.3), { Size = Vector3.new(inst.Size.X, 0.1, 0.1), Transparency = 1 }):Play()
			Debris:AddItem(inst, 0.35)
		end
	end
end

local function thread(a: Vector3, b: Vector3, seconds: number, width: number)
	local length = (b - a).Magnitude
	if length < 0.5 then
		return
	end
	local line = part(Enum.PartType.Block, Vector3.new(width, width, length), CFrame.lookAt((a + b) / 2, b), STAR, Enum.Material.Neon, 0.1)
	TweenService:Create(line, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = Vector3.new(0.02, 0.02, length), Transparency = 1 }):Play()
	Debris:AddItem(line, seconds + 0.1)
end

function SpaceFx.cue(cue: { [string]: any })
	local name = cue.fx
	if name == "gate_open" then
		if typeof(cue.a) ~= "CFrame" or typeof(cue.b) ~= "CFrame" then
			return
		end
		local seconds = tonumber(cue.seconds) or 20
		local radius = tonumber(cue.radius) or 2.8
		local list = ring(cue.a, radius, seconds)
		for _, inst in ring(cue.b, radius, seconds) do
			table.insert(list, inst)
		end
		alive[cue.id] = list
		task.delay(seconds, close, cue.id)
	elseif name == "gate_close" or name == "seal_end" then
		close(cue.id)
	elseif name == "gate_pass" then
		if typeof(cue.to) == "Vector3" then
			flash(cue.to + Vector3.new(0, 1, 0), 4)
		end
	elseif name == "seal" then
		if typeof(cue.center) ~= "Vector3" then
			return
		end
		local half = tonumber(cue.half) or 4
		local box = part(Enum.PartType.Block, Vector3.new(half * 2, half * 2 + 1, half * 2), CFrame.new(cue.center), RIM, Enum.Material.ForceField, 0.2)
		local selection = Instance.new("SelectionBox")
		selection.Adornee = box
		selection.Color3 = STAR
		selection.LineThickness = 0.06
		selection.SurfaceTransparency = 1
		selection.Parent = box
		alive[cue.id] = { box }
		local seconds = tonumber(cue.seconds) or 4
		Debris:AddItem(box, seconds + 1)
	elseif name == "swap" then
		if typeof(cue.a) == "Vector3" and typeof(cue.b) == "Vector3" then
			flash(cue.a, 5)
			flash(cue.b, 5)
			if not reduced() then
				thread(cue.a, cue.b, 0.4, 0.15)
			end
		end
	elseif name == "cut" then
		if typeof(cue.from) == "Vector3" and typeof(cue.to) == "Vector3" then
			thread(cue.from, cue.to, 0.5, 0.35)
		end
	elseif name == "stride" then
		local model = cue.model
		local root = if typeof(model) == "Instance" then model:FindFirstChild("HumanoidRootPart") else nil
		if root and root:IsA("BasePart") and not reduced() then
			local seconds = tonumber(cue.seconds) or 12
			local e = Instance.new("ParticleEmitter")
			e.Color = ColorSequence.new(RIM)
			e.LightEmission = 0.8
			e.Size = NumberSequence.new(0.6, 1.6)
			e.Transparency = NumberSequence.new(0.4, 1)
			e.Lifetime = NumberRange.new(0.4, 0.6)
			e.Speed = NumberRange.new(0, 0.5)
			e.Rate = 10
			e.EmissionDirection = Enum.NormalId.Bottom
			e.Parent = root
			Debris:AddItem(e, seconds)
		end
	elseif name == "dislocate" then
		if typeof(cue.from) == "Vector3" then
			flash(cue.from, 4)
		end
		if typeof(cue.to) == "Vector3" then
			flash(cue.to, 4)
		end
	end
end

return SpaceFx
