--!strict
--[[
	RealityFx: what Reality looks like (docs/Reality.md). Cosmetic: the server decides everything, and
	Cast/RealityRuntime sends a "reality" cue with `fx`:

		favor, doom, twist, undying, fray   a shell on someone for the duration (colour and material
		                                     differ; the status word over their head names it)
		seal         a quick ring on someone whose next hits are certain
		edict        the law's boundary: a thin glassy cylinder for its duration, following its caster
		             for an aura; Worldlaw draws only its rim (it's huge)
		conjure      a flash where matter appeared
		cage         a flash around the cage
		unmake       a ring of fragments where things stopped existing
		poof         a puff where someone changed shape (both ways)
		exchange     a streak each way between two people
		twist_hit    a flash where a blow was turned back
		severed      a pop where a projectile stopped existing
		end          removes whatever carries this id

	Palette: Reality's white, magenta and cyan. Reduce spell effects keeps the boundaries and rings,
	and drops the shells and streaks. There's no Reality audio yet.
]]

local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)

local WHITE = Color3.fromRGB(255, 255, 255)
local PINK = Color3.fromRGB(255, 80, 200)
local CYAN = Color3.fromRGB(80, 255, 220)
local DARK = Color3.fromRGB(40, 10, 50)

-- Each law has its own colour, so two overlapping edicts can be told apart; the status words say which.
local LAW_COLOURS: { [string]: Color3 } = {
	hush = Color3.fromRGB(150, 150, 170),
	sanctuary = WHITE,
	severance = CYAN,
	reversal = PINK,
}

local SHELLS: { [string]: { color: Color3, material: Enum.Material, transparency: number } } = {
	favor = { color = Color3.fromRGB(255, 230, 140), material = Enum.Material.ForceField, transparency = 0.5 },
	doom = { color = DARK, material = Enum.Material.ForceField, transparency = 0.4 },
	twist = { color = PINK, material = Enum.Material.ForceField, transparency = 0.5 },
	undying = { color = WHITE, material = Enum.Material.ForceField, transparency = 0.35 },
	fray = { color = CYAN, material = Enum.Material.Glass, transparency = 0.7 },
}

local RealityFx = {}

local alive: { [number]: () -> () } = {}

local function reduced(): boolean
	return Theme.settings.reducedEffects == true
end

local function holder(): Instance
	return workspace:FindFirstChild("MagicFx") or workspace
end

local function part(shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = "RealityFx"
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

local function groundUnder(position: Vector3): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(position + Vector3.new(0, 6, 0), Vector3.new(0, -60, 0), params)
	return if hit then hit.Position + Vector3.new(0, 0.2, 0) else position
end

local function ring(position: Vector3, from: number, to: number, seconds: number, color: Color3)
	local cframe = CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2)
	local disc = part(Enum.PartType.Cylinder, Vector3.new(0.2, from, from), cframe, color, Enum.Material.Neon, 0.4)
	TweenService:Create(disc, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.1, to, to), Transparency = 1 }):Play()
	Debris:AddItem(disc, seconds + 0.1)
end

local function flash(position: Vector3, size: number, color: Color3)
	local ball = part(Enum.PartType.Ball, Vector3.new(1, 1, 1), CFrame.new(position), color, Enum.Material.Neon, 0.2)
	TweenService:Create(ball, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(size, size, size), Transparency = 1 }):Play()
	Debris:AddItem(ball, 0.45)
end

-- Something that follows a model's root every frame until `seconds` pass or `stop` is called.
local function follow(p: BasePart, model: Model, seconds: number, offset: CFrame?): () -> ()
	local root = model:FindFirstChild("HumanoidRootPart")
	local expires = os.clock() + seconds
	local connection: RBXScriptConnection? = nil
	local function stop()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		p:Destroy()
	end
	connection = RunService.Heartbeat:Connect(function()
		if os.clock() >= expires or not root or not root.Parent then
			stop()
			return
		end
		p.CFrame = (root :: BasePart).CFrame * (offset or CFrame.identity)
	end)
	return stop
end

local function shell(name: string, model: any, duration: number)
	local look = SHELLS[name]
	if reduced() or not look or typeof(model) ~= "Instance" or not model:IsA("Model") then
		return
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local ball = part(Enum.PartType.Ball, Vector3.new(6.5, 6.5, 6.5), root.CFrame, look.color, look.material, look.transparency)
	follow(ball, model, duration)
end

-- The edge of a law: a thin glassy cylinder, or just its rim for a Worldlaw.
local function edict(id: any, position: Vector3, radius: number, duration: number, law: string, model: any)
	local color = LAW_COLOURS[law] or WHITE
	local ground = groundUnder(position)
	local huge = radius > 80
	local height = if huge then 2 else math.min(radius, 24)
	local cframe = CFrame.new(ground + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
	local wall = part(Enum.PartType.Cylinder, Vector3.new(height, radius * 2, radius * 2), cframe, color, Enum.Material.ForceField, if huge then 0.2 else 0.55)
	ring(ground, 2, radius * 2, 0.5, color)
	local stop: () -> ()
	if typeof(model) == "Instance" and model:IsA("Model") then
		local root = model:FindFirstChild("HumanoidRootPart")
		local drop = if root and root:IsA("BasePart") then ground.Y + height / 2 - root.Position.Y else 0
		stop = follow(wall, model, duration, CFrame.new(0, drop, 0) * CFrame.Angles(0, 0, math.pi / 2))
	else
		Debris:AddItem(wall, duration + 0.2)
		stop = function()
			wall:Destroy()
		end
	end
	if typeof(id) == "number" then
		alive[id] = stop
		task.delay(duration + 0.5, function()
			if alive[id] == stop then
				alive[id] = nil
			end
		end)
	end
end

local function fragments(position: Vector3, radius: number)
	ring(groundUnder(position), radius * 2, 2, 0.5, CYAN)
	if reduced() then
		return
	end
	for i = 1, 10 do
		local angle = (i / 10) * math.pi * 2
		local from = position + Vector3.new(math.cos(angle) * radius * 0.6, 1 + (i % 3), math.sin(angle) * radius * 0.6)
		local shard = part(Enum.PartType.Block, Vector3.new(0.6, 0.6, 0.6), CFrame.new(from), if i % 2 == 0 then PINK else CYAN, Enum.Material.Neon, 0.2)
		TweenService:Create(shard, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { CFrame = CFrame.new(from + Vector3.new(0, 3, 0)) * CFrame.Angles(i, i, i), Transparency = 1, Size = Vector3.new(0.1, 0.1, 0.1) }):Play()
		Debris:AddItem(shard, 0.7)
	end
end

local function streak(from: Vector3, to: Vector3, color: Color3)
	local distance = (to - from).Magnitude
	if distance < 1 then
		return
	end
	local beam = part(Enum.PartType.Block, Vector3.new(0.6, 0.6, distance), CFrame.lookAt((from + to) / 2, to), color, Enum.Material.Neon, 0.2)
	TweenService:Create(beam, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = 1, Size = Vector3.new(0.1, 0.1, distance) }):Play()
	Debris:AddItem(beam, 0.55)
end

function RealityFx.cue(cue: { [string]: any })
	local name = cue.fx
	local position: Vector3 = cue.position
	local duration: number = if typeof(cue.duration) == "number" then cue.duration else 3
	local radius: number = if typeof(cue.radius) == "number" then cue.radius else 6
	if SHELLS[name] then
		shell(name, cue.model, duration)
		ring(groundUnder(position), 2, 8, 0.4, SHELLS[name].color)
	elseif name == "seal" then
		ring(groundUnder(position), 8, 1, 0.5, WHITE)
	elseif name == "edict" then
		edict(cue.id, position, radius, duration, if typeof(cue.law) == "string" then cue.law else "", cue.model)
	elseif name == "conjure" or name == "cage" then
		flash(position, 10, WHITE)
	elseif name == "unmake" then
		fragments(position, radius)
	elseif name == "poof" then
		flash(position + Vector3.new(0, 1, 0), 6, PINK)
	elseif name == "exchange" then
		if typeof(cue.to) == "Vector3" and not reduced() then
			streak(position, cue.to, PINK)
			streak(cue.to + Vector3.new(0, 1, 0), position + Vector3.new(0, 1, 0), CYAN)
		end
		flash(position, 5, PINK)
	elseif name == "twist_hit" then
		flash(position, 7, PINK)
	elseif name == "severed" then
		flash(position, 3, CYAN)
	elseif name == "end" then
		local stop = if typeof(cue.id) == "number" then alive[cue.id] else nil
		if stop then
			alive[cue.id] = nil
			stop()
		end
	end
end

return RealityFx
