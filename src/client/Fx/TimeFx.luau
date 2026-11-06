--!strict
--[[
	TimeFx: what Time looks like (docs/Time.md). Cosmetic: the server decides everything, and
	Cast/TimeRuntime sends a "time" cue with `fx`:

		afterimage   a ghost of someone, frozen where they were marked, until the mark ends
		recall       a pale streak from where they were to where they're returned; a ring at each end
		stop         the world loses its colour for anyone inside. Everyone but the caster stops animating,
		             and smoke, sparks and flames stop in mid-air. A ring shows the edge.
		wound        a dark shell on someone holding back their hits
		wound_land   it all lands at once
		loop         a ring where someone will keep ending up
		foresee      a ring where a nearby spell is aimed (only sent to people with Future Sight)
		end          removes whatever carries this id

	Reduce spell effects keeps what informs you (ghosts, rings, the colour change at half strength) and
	drops the streaks and shells. There's no Time audio yet: the sound library has no pick for it.
]]

local Debris = game:GetService("Debris")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)

local PALE = Color3.fromRGB(200, 225, 255)
local GOLD = Color3.fromRGB(240, 210, 130)
local DARK = Color3.fromRGB(30, 20, 50)
local GHOST_TRANSPARENCY = 0.55

local TimeFx = {}

local alive: { [number]: () -> () } = {}

local function reduced(): boolean
	return Theme.settings.reducedEffects == true
end

local function holder(): Instance
	return workspace:FindFirstChild("MagicFx") or workspace
end

local function part(shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = "TimeFx"
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

-- A frozen copy of someone: their shape, pale and see-through, posed as they were. It's a local copy
-- with its scripts and joints gone, anchored in place.
local function afterimage(id: number?, model: any, duration: number)
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "TimeAfterimage"
	for _, child in model:GetChildren() do
		if child:IsA("BasePart") and child.Transparency < 1 then
			local copy = part(Enum.PartType.Block, child.Size, child.CFrame, PALE, Enum.Material.ForceField, GHOST_TRANSPARENCY)
			if child.Name == "Head" then
				copy.Shape = Enum.PartType.Ball
			end
			copy.Parent = folder
		end
	end
	folder.Parent = holder()
	local function stop()
		folder:Destroy()
	end
	if typeof(id) == "number" then
		alive[id] = stop
	end
	task.delay(duration, function()
		if typeof(id) == "number" and alive[id] == stop then
			alive[id] = nil
		end
		stop()
	end)
end

local function recall(from: Vector3, to: Vector3)
	ring(groundUnder(from), 2, 12, 0.35, PALE)
	ring(groundUnder(to), 12, 2, 0.35, GOLD)
	if reduced() then
		return
	end
	local distance = (to - from).Magnitude
	if distance > 1 then
		local streak = part(Enum.PartType.Block, Vector3.new(0.8, 0.8, distance), CFrame.lookAt((from + to) / 2, to), PALE, Enum.Material.Neon, 0.2)
		TweenService:Create(streak, TweenInfo.new(0.4, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Transparency = 1, Size = Vector3.new(0.1, 0.1, distance) }):Play()
		Debris:AddItem(streak, 0.5)
	end
end

-- ─── Timestop ───────────────────────────────────────────────────────────────

-- Everyone in the zone stops moving. Animation is client-side, so this client freezes what it sees.
local function freezeTracks(center: Vector3, radius: number, casterId: any): { AnimationTrack }
	local params = OverlapParams.new()
	params.MaxParts = 400
	local seen: { [Humanoid]: boolean } = {}
	local frozen: { AnimationTrack } = {}
	local caster = if typeof(casterId) == "number" then Players:GetPlayerByUserId(casterId) else nil
	local casterModel = caster and caster.Character
	for _, p in workspace:GetPartBoundsInRadius(center, radius, params) do
		local model = p:FindFirstAncestorOfClass("Model")
		local humanoid = model and model:FindFirstChildOfClass("Humanoid")
		if humanoid and model ~= casterModel and not seen[humanoid] then
			seen[humanoid] = true
			local animator = humanoid:FindFirstChildOfClass("Animator")
			if animator then
				for _, track in animator:GetPlayingAnimationTracks() do
					track:AdjustSpeed(0)
					table.insert(frozen, track)
				end
			end
		end
	end
	return frozen
end

-- Smoke, sparks and flames stop in mid-air too: every emitter on a part in the zone, including this
-- client's own effect parts, which a spatial query can't see (they don't accept queries).
local function freezeEmitters(center: Vector3, radius: number): { [ParticleEmitter]: number }
	local frozen: { [ParticleEmitter]: number } = {}
	local function freeze(p: Instance)
		for _, child in p:GetChildren() do
			if child:IsA("ParticleEmitter") and not frozen[child] then
				frozen[child] = child.TimeScale
				child.TimeScale = 0
			end
		end
	end
	local params = OverlapParams.new()
	params.MaxParts = 400
	for _, p in workspace:GetPartBoundsInRadius(center, radius, params) do
		freeze(p)
	end
	local magicFx = workspace:FindFirstChild("MagicFx")
	if magicFx then
		for _, p in magicFx:GetChildren() do
			if p:IsA("BasePart") and (p.Position - center).Magnitude <= radius then
				freeze(p)
			end
		end
	end
	return frozen
end

local function stopWorld(id: number?, center: Vector3, radius: number, duration: number, casterId: any)
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local inside = root and root:IsA("BasePart") and (root.Position - center).Magnitude <= radius * 1.5
	local tint: ColorCorrectionEffect? = nil
	if inside then
		local cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "TimestopTint"
		cc.Saturation = 0
		cc.Parent = Lighting
		TweenService:Create(cc, TweenInfo.new(0.2), { Saturation = if reduced() then -0.5 else -1, Contrast = 0.15 }):Play()
		tint = cc
	end
	ring(groundUnder(center), radius * 2, radius * 2, math.max(duration, 0.5), PALE)
	ring(groundUnder(center), 2, radius * 2, 0.3, PALE)
	local frozen = freezeTracks(center, radius, casterId)
	local emitters = freezeEmitters(center, radius)
	local done = false
	local function resume()
		if done then
			return
		end
		done = true
		for _, track in frozen do
			if track.IsPlaying then
				track:AdjustSpeed(1)
			end
		end
		for emitter, scale in emitters do
			if emitter.Parent then
				emitter.TimeScale = scale
			end
		end
		if tint then
			tint:Destroy()
		end
	end
	if typeof(id) == "number" then
		alive[id] = resume
	end
	task.delay(duration + 0.5, function() -- in case the end cue is lost: nobody stays grey
		if typeof(id) == "number" and alive[id] == resume then
			alive[id] = nil
		end
		resume()
	end)
end

-- ─── The wound shell ────────────────────────────────────────────────────────

local function woundShell(model: any, duration: number)
	if reduced() or typeof(model) ~= "Instance" or not model:IsA("Model") then
		return
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return
	end
	local shell = part(Enum.PartType.Ball, Vector3.new(7, 7, 7), root.CFrame, DARK, Enum.Material.ForceField, 0.45)
	local expires = os.clock() + duration
	local connection: RBXScriptConnection? = nil
	connection = RunService.Heartbeat:Connect(function()
		if os.clock() >= expires or not root.Parent then
			shell:Destroy()
			if connection then
				connection:Disconnect()
			end
			return
		end
		shell.CFrame = root.CFrame
	end)
end

function TimeFx.cue(cue: { [string]: any })
	local name = cue.fx
	local position: Vector3 = cue.position
	local duration: number = if typeof(cue.duration) == "number" then cue.duration else 3
	local radius: number = if typeof(cue.radius) == "number" then cue.radius else 8
	if name == "afterimage" then
		afterimage(cue.id, cue.model, duration)
	elseif name == "recall" then
		if typeof(cue.to) == "Vector3" then
			recall(position, cue.to)
		end
	elseif name == "stop" then
		stopWorld(cue.id, position, radius, duration, cue.caster)
	elseif name == "wound" then
		woundShell(cue.model, duration)
	elseif name == "wound_land" then
		ring(groundUnder(position), 1, radius * 2, 0.35, DARK)
	elseif name == "loop" then
		ring(groundUnder(position), radius * 2, 2, 0.5, GOLD)
	elseif name == "foresee" then
		ring(groundUnder(position), radius * 2, radius * 0.5, 0.9, GOLD)
	elseif name == "end" then
		local stop = if typeof(cue.id) == "number" then alive[cue.id] else nil
		if stop then
			alive[cue.id] = nil
			stop()
		end
	end
end

return TimeFx
