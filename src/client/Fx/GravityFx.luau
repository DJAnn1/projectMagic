--!strict
--[[
	GravityFx: what gravity looks like (docs/Gravity.md). Cosmetic: the server decides everything, and
	Cast/GravityRuntime sends a "gravity" cue with `fx`:

		grip         a warped shell closing on the victim, pressing rings at their feet
		lift         a pale column under the rising body
		slam         a shockwave and cracked-ground ring (+ a screen shake close by; bigger with `heavy`)
		well         a warped sphere with rings falling inward
		singularity  a black sphere growing inside a warped shell, rings falling inward
		detonate     the flash and the blast ring
		implode      a body crushed: a sphere snapping inward
		orbit        rocks circling you, one per projectile it can stop (orbit_hit removes one)
		bend         a faint warped bubble around you
		takeoff      a ring blown outward at your feet
		end          removes whatever carries this id
	gravity_pull (a separate cue, to the one being pulled): your own body is dragged toward the well.
	A heavy gravity field also throws a ring down every second (fieldPulse).

	Reduce spell effects keeps the shapes that warn or inform (well, singularity, orbit, grip) and
	drops the flourishes. Everything is local parts on no collision, cleaned up by duration.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)
local SpellFx = require(script.Parent.SpellFx)
local Audio = require(Client:WaitForChild("Audio").Audio)

local WARP = Color3.fromRGB(150, 120, 255)
local DARK = Color3.fromRGB(10, 6, 22)
local DUST = Color3.fromRGB(150, 135, 115)
local ROCK = Color3.fromRGB(95, 88, 84)

local GravityFx = {}

-- id -> what to remove when the server says it's over
local alive: { [number]: { destroy: () -> () } } = {}
local pullCenter: Vector3? = nil
local pullSpeed = 0
local pullUntil = 0
local pullConnection: RBXScriptConnection? = nil

local function reduced(): boolean
	return Theme.settings.reducedEffects == true
end

local function holder(): Instance
	return workspace:FindFirstChild("MagicFx") or workspace
end

local function part(shape: Enum.PartType, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, transparency: number): Part
	local p = Instance.new("Part")
	p.Name = "GravityFx"
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

local function flatOn(position: Vector3): CFrame
	return CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2)
end

-- A ring-like disc that grows from `from` to `to` studs across and fades.
local function ring(position: Vector3, from: number, to: number, seconds: number, color: Color3, transparency: number)
	local disc = part(Enum.PartType.Cylinder, Vector3.new(0.3, from, from), flatOn(position), color, Enum.Material.Neon, transparency)
	TweenService:Create(disc, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(0.1, to, to), Transparency = 1 }):Play()
	Debris:AddItem(disc, seconds + 0.1)
end

local function groundUnder(position: Vector3): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(position + Vector3.new(0, 4, 0), Vector3.new(0, -160, 0), params)
	return if hit then hit.Position + Vector3.new(0, 0.2, 0) else position
end

local function shakeNear(position: Vector3, strength: number, duration: number, reach: number)
	local camera = workspace.CurrentCamera
	if camera and (camera.CFrame.Position - position).Magnitude <= reach then
		SpellFx.shake(strength, duration)
	end
end

local function rootOf(model: any): BasePart?
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- A warped shell that follows a body (or stays put) until `seconds` pass or the server ends it.
local function shell(id: number?, model: any, position: Vector3, from: number, to: number, seconds: number, inward: boolean): Part
	local ball = part(Enum.PartType.Ball, Vector3.new(from, from, from), CFrame.new(position), WARP, Enum.Material.ForceField, 0.35)
	TweenService:Create(ball, TweenInfo.new(seconds, Enum.EasingStyle.Linear), { Size = Vector3.new(to, to, to) }):Play()
	local connection: RBXScriptConnection? = nil
	local stop = function()
		if connection then
			connection:Disconnect()
			connection = nil
		end
		ball:Destroy()
	end
	if typeof(id) == "number" then
		alive[id] = { destroy = stop }
	end
	local expires = os.clock() + seconds
	local nextRing = 0
	connection = RunService.Heartbeat:Connect(function()
		local t = os.clock()
		if t >= expires or not ball.Parent then
			stop()
			if typeof(id) == "number" then
				alive[id] = nil
			end
			return
		end
		local root = rootOf(model)
		if root then
			ball.CFrame = root.CFrame
		end
		if inward and t >= nextRing and not reduced() then
			nextRing = t + 0.45
			local at = groundUnder(ball.Position)
			local size = ball.Size.X * 1.4
			local disc = part(Enum.PartType.Cylinder, Vector3.new(0.2, size, size), flatOn(at), WARP, Enum.Material.Neon, 0.75)
			TweenService:Create(disc, TweenInfo.new(0.45, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = Vector3.new(0.2, 1, 1), Transparency = 1 }):Play()
			Debris:AddItem(disc, 0.55)
		end
	end)
	return ball
end

local function slam(position: Vector3, radius: number, heavy: boolean)
	local at = groundUnder(position)
	ring(at, radius * 0.4, radius * 2, 0.4, WARP, 0.3)
	if not reduced() then
		ring(at, 1, radius * 1.3, 0.6, DUST, 0.45)
		Debris:AddItem(part(Enum.PartType.Cylinder, Vector3.new(0.15, radius * 1.1, radius * 1.1), flatOn(at), DARK, Enum.Material.Slate, 0.45), 4)
	end
	Audio.play("combat.knockdown", { position = at })
	shakeNear(at, if heavy then 1.6 else 0.9, if heavy then 0.6 else 0.35, radius * 6 + 40)
end

local function orbit(id: number?, model: any, pieces: number, radius: number, seconds: number)
	local rocks: { Part } = {}
	for i = 1, math.max(1, pieces) do
		local size = 1.6 + (i % 3) * 0.5
		rocks[i] = part(Enum.PartType.Block, Vector3.new(size, size * 0.8, size), CFrame.new(), ROCK, Enum.Material.Slate, 0)
	end
	local connection: RBXScriptConnection? = nil
	local entry = {
		rocks = rocks,
		destroy = function()
			if connection then
				connection:Disconnect()
				connection = nil
			end
			for _, rock in rocks do
				rock:Destroy()
			end
		end,
	}
	if typeof(id) == "number" then
		alive[id] = entry :: any
	end
	local expires = os.clock() + seconds
	connection = RunService.Heartbeat:Connect(function()
		local t = os.clock()
		local root = rootOf(model)
		if t >= expires or not root then
			entry.destroy()
			if typeof(id) == "number" then
				alive[id] = nil
			end
			return
		end
		local count = #rocks
		for i, rock in rocks do
			local angle = t * 2.2 + (i / count) * 2 * math.pi
			rock.CFrame = CFrame.new(root.Position + Vector3.new(math.cos(angle) * radius, 1 + math.sin(t * 1.7 + i), math.sin(angle) * radius)) * CFrame.Angles(t + i, t * 0.7, 0)
		end
	end)
end

local function endById(id: any)
	local entry = if typeof(id) == "number" then alive[id] else nil
	if entry then
		alive[id] = nil
		entry.destroy()
	end
end

function GravityFx.cue(cue: { [string]: any })
	local name = cue.fx
	local position: Vector3 = cue.position
	local radius: number = if typeof(cue.radius) == "number" then cue.radius else 8
	local duration: number = if typeof(cue.duration) == "number" then cue.duration else 3
	if name == "grip" then
		shell(cue.id, cue.model, position, 12, 6.5, duration, true)
		Audio.play("combat.knockdown", { position = position })
	elseif name == "lift" then
		if not reduced() then
			local at = groundUnder(position)
			local height = if typeof(cue.height) == "number" then cue.height else 10
			local column = part(Enum.PartType.Cylinder, Vector3.new(height, 5, 5), CFrame.new(at + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2), WARP, Enum.Material.ForceField, 0.5)
			Debris:AddItem(column, duration)
			ring(at, 2, 12, 0.4, DUST, 0.4)
		end
	elseif name == "slam" then
		slam(position, radius, cue.heavy == true)
	elseif name == "well" then
		shell(cue.id, nil, position + Vector3.new(0, 3, 0), radius * 2, radius * 2, duration, true)
		local core = part(Enum.PartType.Ball, Vector3.new(4, 4, 4), CFrame.new(position + Vector3.new(0, 3, 0)), DARK, Enum.Material.SmoothPlastic, 0)
		Debris:AddItem(core, duration)
		if typeof(cue.id) == "number" then
			local entry = alive[cue.id]
			if entry then
				local stop = entry.destroy
				entry.destroy = function()
					stop()
					core:Destroy()
				end
			end
		end
	elseif name == "singularity" then
		shell(cue.id, nil, position, radius * 2, 6, duration, true)
		local core = part(Enum.PartType.Ball, Vector3.new(1, 1, 1), CFrame.new(position), DARK, Enum.Material.SmoothPlastic, 0)
		TweenService:Create(core, TweenInfo.new(duration, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = Vector3.new(11, 11, 11) }):Play()
		Debris:AddItem(core, duration)
		shakeNear(position, 0.5, duration, radius * 5 + 40)
	elseif name == "detonate" then
		local flash = part(Enum.PartType.Ball, Vector3.new(6, 6, 6), CFrame.new(position), WARP, Enum.Material.Neon, 0.1)
		TweenService:Create(flash, TweenInfo.new(0.5, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.new(radius * 2, radius * 2, radius * 2), Transparency = 1 }):Play()
		Debris:AddItem(flash, 0.6)
		slam(position, radius, true)
	elseif name == "implode" then
		local ball = part(Enum.PartType.Ball, Vector3.new(radius * 2, radius * 2, radius * 2), CFrame.new(position), DARK, Enum.Material.Neon, 0.3)
		TweenService:Create(ball, TweenInfo.new(0.25, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Size = Vector3.new(0.5, 0.5, 0.5), Transparency = 0.8 }):Play()
		Debris:AddItem(ball, 0.3)
		shakeNear(position, 0.7, 0.3, 80)
	elseif name == "orbit" then
		orbit(cue.id, cue.model, if typeof(cue.pieces) == "number" then cue.pieces else 1, radius, duration)
	elseif name == "orbit_hit" then
		local entry: any = if typeof(cue.id) == "number" then alive[cue.id] else nil
		if entry and entry.rocks and #entry.rocks > 1 then
			(table.remove(entry.rocks) :: Part):Destroy()
		end
		ring(position, 1, 8, 0.25, DUST, 0.3)
	elseif name == "bend" then
		shell(cue.id, cue.model, position, radius * 2, radius * 2, duration, false).Transparency = 0.8
	elseif name == "takeoff" then
		if not reduced() then
			ring(groundUnder(position), 2, radius * 3, 0.5, WARP, 0.4)
		end
	elseif name == "end" then
		endById(cue.id)
	end
end

-- Heavy ground presses down: a ring falling across the field every second, while it lasts.
function GravityFx.fieldPulse(cue: { [string]: any })
	if reduced() or cue.mode ~= "heavy" or typeof(cue.radius) ~= "number" then
		return
	end
	local position: Vector3 = cue.position
	local seconds = if typeof(cue.duration) == "number" then cue.duration else 5
	task.spawn(function()
		local at = groundUnder(position)
		for _ = 1, math.floor(seconds) do
			ring(at, cue.radius * 2, cue.radius * 0.3, 0.8, WARP, 0.75)
			task.wait(1)
		end
	end)
end

-- The well has you. Your client owns your body, so it moves you itself; the server's cue keeps it
-- going, so it stops by itself shortly after the well ends or you get out of reach.
function GravityFx.pull(cue: { [string]: any })
	if typeof(cue.center) ~= "Vector3" or typeof(cue.speed) ~= "number" or typeof(cue.duration) ~= "number" then
		return
	end
	pullCenter, pullSpeed = cue.center, math.clamp(cue.speed, 0, 60)
	pullUntil = os.clock() + math.clamp(cue.duration, 0, 1)
	if pullConnection then
		return
	end
	pullConnection = RunService.Heartbeat:Connect(function(dt)
		local center = pullCenter
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if os.clock() >= pullUntil or not center or not root or not root:IsA("BasePart") then
			if pullConnection then
				pullConnection:Disconnect()
				pullConnection = nil
			end
			return
		end
		if root.Anchored then
			return
		end
		local to = Vector3.new(center.X - root.Position.X, 0, center.Z - root.Position.Z)
		if to.Magnitude > 2 then
			root.CFrame += to.Unit * math.min(pullSpeed * dt, to.Magnitude)
		end
	end)
end

return GravityFx
