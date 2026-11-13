--!strict
--[[
	WildbornController: draws what the Wildborn do (docs/Wildborn.md). The server decides every hit
	(Wildborn/WildbornMoves) and sends cues only to players near it (remote WildbornCue); this draws
	them with client-only parts that tween and go, in the enemy's theme colours.

		marks    ground warnings: a ring and a fill that grows until the hit lands (always shown first
		         for anything that lands later, so every big move can be dodged)
		strike   what rises or lands on the marks: spikes, vines, a wave, a blast
		fall     something falling onto a mark: a meteor, an anvil (lightning strikes on landing)
		bolt / boltEnd   a projectile flown here along the server's path, ended where the server says
		lob      an arcing boulder
		chain    lightning jumping between points (also after-images firing)
		dash     a burning trail along a dash
		blink    an after-image where it was, a ripple where it lands, clones around its target
		slash    a slash ring at a point (echo strikes, plain blows)
		burst    rings out from it (bloom, slam, frost, dread, eclipse, flare)
		zone     a lingering area: whirlpool, maelstrom, static, tear, blizzard, petals
		tether   beams from it to whoever it's draining or pulling
		stasis   a time bubble on everyone caught
		rally    a pillar and rings when a boss rallies

	Cost: everything is pooled to a folder under the camera and destroyed when its tween ends; a
	busy boss fight is a few dozen short-lived parts. Projectiles step once per frame.
]]

local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local WildbornController = {
	name = "WildbornController",
	dependencies = {},
}

type Bolt = { part: BasePart, velocity: Vector3, expires: number }

local folder: Folder? = nil
local bolts: { [number]: Bolt } = {}

local function folderOf(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "WildbornFx"
	made.Parent = workspace.CurrentCamera or workspace
	folder = made
	return made
end

local function part(props: { [string]: any }): BasePart
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(p :: any)[key] = value
	end
	p.Parent = folderOf()
	return p
end

local function fade(p: Instance, seconds: number, extra: { [string]: any }?)
	local goal: { [string]: any } = { Transparency = 1 }
	for key, value in (extra or {}) :: { [string]: any } do
		goal[key] = value
	end
	TweenService:Create(p, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
	Debris:AddItem(p, seconds + 0.1)
end

-- A flat disc lying on the ground (a Cylinder part turned on its side).
local function disc(at: Vector3, radius: number, color: Color3, transparency: number, thickness: number?): BasePart
	return part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(thickness or 0.2, radius * 2, radius * 2),
		CFrame = CFrame.new(at + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = color,
		Transparency = transparency,
	})
end

local function ring(at: Vector3, from: number, to: number, color: Color3, seconds: number)
	local d = disc(at, from, color, 0.15, 0.3)
	fade(d, seconds, { Size = Vector3.new(0.3, to * 2, to * 2) })
end

local function c3(value: any, fallback: Color3): Color3
	return if typeof(value) == "Color3" then value else fallback
end

local function v3(value: any): Vector3?
	return if typeof(value) == "Vector3" then value else nil
end

local function torsoOf(model: any): BasePart?
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil
	end
	local t = model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso") or model:FindFirstChild("HumanoidRootPart")
	return if t and t:IsA("BasePart") then t else nil
end

-- ─── Pieces by style ────────────────────────────────────────────────────────

local function spike(at: Vector3, color: Color3, metal: boolean)
	local height = 9 + math.random() * 3
	local p = part({
		Size = Vector3.new(1.4, 0.3, 1.4),
		CFrame = CFrame.new(at - Vector3.new(0, 1, 0)) * CFrame.Angles(math.rad(math.random(-12, 12)), math.rad(math.random(0, 360)), 0),
		Color = color,
		Material = if metal then Enum.Material.Metal else Enum.Material.Grass,
		Shape = if metal then Enum.PartType.Block else Enum.PartType.Cylinder,
	})
	if not metal then
		p.CFrame = CFrame.new(at - Vector3.new(0, 1, 0)) * CFrame.Angles(0, math.rad(math.random(0, 360)), math.rad(90 + math.random(-15, 15)))
		p.Size = Vector3.new(0.3, 0.7, 0.7)
		TweenService:Create(p, TweenInfo.new(0.25, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = Vector3.new(height, 0.7, 0.7),
			CFrame = p.CFrame * CFrame.new(height / 2, 0, 0),
		}):Play()
	else
		TweenService:Create(p, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), {
			Size = Vector3.new(1.4, height, 1.4),
			CFrame = p.CFrame * CFrame.new(0, height / 2, 0),
		}):Play()
	end
	task.delay(1.2, function()
		fade(p, 0.35)
	end)
end

local function lightning(at: Vector3, color: Color3)
	local top = at + Vector3.new(0, 80, 0)
	local previous = top
	for i = 1, 6 do
		local t = i / 6
		local nextPoint = top:Lerp(at, t) + (if i < 6 then Vector3.new(math.random(-3, 3), 0, math.random(-3, 3)) else Vector3.zero)
		local mid = (previous + nextPoint) / 2
		local seg = part({
			Size = Vector3.new(0.6, 0.6, (nextPoint - previous).Magnitude),
			CFrame = CFrame.lookAt(mid, nextPoint),
			Color = color,
		})
		fade(seg, 0.3)
		previous = nextPoint
	end
	ring(at, 2, 8, color, 0.4)
end

local function wave(at: Vector3, color: Color3, radius: number, dir: Vector3?)
	local facing = dir or Vector3.new(0, 0, 1)
	local crest = part({
		Size = Vector3.new(radius * 2, radius * 1.1, 1.5),
		CFrame = CFrame.lookAt(at + Vector3.new(0, radius * 0.5, 0), at + Vector3.new(0, radius * 0.5, 0) + facing),
		Color = color,
		Material = Enum.Material.ForceField,
		Transparency = 0.15,
	})
	fade(crest, 0.5, { Size = Vector3.new(radius * 2.8, radius * 1.6, 1.5) })
end

local function blast(at: Vector3, radius: number, primary: Color3, secondary: Color3)
	ring(at, radius * 0.3, radius, secondary, 0.45)
	local flash = part({ Shape = Enum.PartType.Ball, Size = Vector3.new(3, 3, 3), Position = at + Vector3.new(0, 1.5, 0), Color = primary, Transparency = 0.1 })
	fade(flash, 0.35, { Size = Vector3.new(radius, radius, radius) })
end

-- ─── Cues ───────────────────────────────────────────────────────────────────

local handlers: { [string]: (any, Color3, Color3) -> () } = {}

handlers.marks = function(cue, primary, secondary)
	local radius = tonumber(cue.radius) or 4
	local delay = math.max(0.1, tonumber(cue.delay) or 0.5)
	for _, at in (if typeof(cue.spots) == "table" then cue.spots else {}) :: { any } do
		local spot = v3(at)
		if spot then
			local outer = disc(spot, radius, secondary, 0.55, 0.12)
			local fill = disc(spot, 0.3, primary, 0.35, 0.16)
			TweenService:Create(fill, TweenInfo.new(delay, Enum.EasingStyle.Linear), { Size = Vector3.new(0.16, radius * 2, radius * 2) }):Play()
			Debris:AddItem(outer, delay + 0.05)
			Debris:AddItem(fill, delay + 0.05)
		end
	end
end

handlers.strike = function(cue, primary, secondary)
	local radius = tonumber(cue.radius) or 4
	local style = tostring(cue.style)
	for _, at in (if typeof(cue.spots) == "table" then cue.spots else {}) :: { any } do
		local spot = v3(at)
		if spot then
			if style == "spike" then
				spike(spot, primary, true)
			elseif style == "vine" then
				for _ = 1, 4 do
					spike(spot + Vector3.new(math.random(-2, 2), 0, math.random(-2, 2)), primary, false)
				end
			elseif style == "wave" then
				wave(spot, primary, radius, nil)
			elseif style == "lightning" then
				lightning(spot, secondary)
			else
				blast(spot, radius, primary, secondary)
			end
		end
	end
end

handlers.fall = function(cue, primary, secondary)
	local at = v3(cue.at)
	local time = math.max(0.2, tonumber(cue.time) or 1)
	local style = tostring(cue.style)
	if not at or style == "lightning" then
		return
	end
	local anvil = style == "anvil"
	local body = part({
		Shape = if anvil then Enum.PartType.Block else Enum.PartType.Ball,
		Size = if anvil then Vector3.new(8, 6, 12) else Vector3.new(4, 4, 4),
		Position = at + Vector3.new(0, 90, 0),
		Color = primary,
		Material = if anvil then Enum.Material.Metal else Enum.Material.Neon,
	})
	if not anvil then
		local light = Instance.new("PointLight")
		light.Color = secondary
		light.Range = 18
		light.Brightness = 3
		light.Parent = body
	end
	TweenService:Create(body, TweenInfo.new(time, Enum.EasingStyle.Quad, Enum.EasingDirection.In), { Position = at + Vector3.new(0, 2, 0) }):Play()
	Debris:AddItem(body, time + 0.05)
end

handlers.bolt = function(cue, primary, secondary)
	local from, velocity = v3(cue.from), v3(cue.velocity)
	local id = tonumber(cue.id)
	if not from or not velocity or not id then
		return
	end
	local size = tonumber(cue.size) or 2
	local p = part({
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(size, size, size),
		Position = from,
		Color = primary,
		Material = if cue.style == "water" then Enum.Material.ForceField else Enum.Material.Neon,
	})
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, size * 0.4, 0)
	a0.Parent = p
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -size * 0.4, 0)
	a1.Parent = p
	local trail = Instance.new("Trail")
	trail.Attachment0 = a0
	trail.Attachment1 = a1
	trail.Color = ColorSequence.new(secondary, primary)
	trail.Lifetime = 0.4
	trail.LightEmission = 0.9
	trail.Transparency = NumberSequence.new(0.2, 1)
	trail.Parent = p
	local light = Instance.new("PointLight")
	light.Color = secondary
	light.Range = 12
	light.Brightness = 2
	light.Parent = p
	bolts[id] = { part = p, velocity = velocity, expires = os.clock() + (tonumber(cue.life) or 1.5) }
end

handlers.boltEnd = function(cue, primary, secondary)
	local id = tonumber(cue.id)
	local bolt = id and bolts[id]
	if bolt and id then
		bolts[id] = nil
		bolt.part:Destroy()
	end
	local at = v3(cue.at)
	if at then
		blast(at, 6, primary, secondary)
	end
end

handlers.lob = function(cue, primary, _secondary)
	local from, to = v3(cue.from), v3(cue.to)
	local time = math.max(0.3, tonumber(cue.time) or 1)
	if not from or not to then
		return
	end
	local size = tonumber(cue.size) or 3
	local rock = part({
		Shape = Enum.PartType.Ball,
		Size = Vector3.new(size, size, size),
		Position = from,
		Color = Color3.fromRGB(95, 75, 55),
		Material = Enum.Material.Slate,
	})
	local height = (to - from).Magnitude * 0.3
	local started = os.clock()
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function()
		local t = (os.clock() - started) / time
		if t >= 1 or not rock.Parent then
			connection:Disconnect()
			if rock.Parent then
				rock:Destroy()
				ring(to, 2, size * 2.5, primary, 0.5)
			end
			return
		end
		local p = from:Lerp(to, t)
		rock.Position = p + Vector3.new(0, math.sin(t * math.pi) * height, 0)
	end)
end

handlers.chain = function(cue, _primary, secondary)
	local points = if typeof(cue.points) == "table" then cue.points else {}
	for i = 1, #points - 1 do
		local a, b = v3(points[i]), v3(points[i + 1])
		if a and b then
			local mid = (a + b) / 2 + Vector3.new(math.random(-1, 1), math.random(-1, 1), math.random(-1, 1))
			for _, segment in { { a, mid }, { mid, b } } do
				local s, e = segment[1], segment[2]
				local seg = part({ Size = Vector3.new(0.5, 0.5, (e - s).Magnitude), CFrame = CFrame.lookAt((s + e) / 2, e), Color = secondary })
				fade(seg, 0.25)
			end
		end
	end
end

handlers.dash = function(cue, primary, secondary)
	local from, to = v3(cue.from), v3(cue.to)
	local time = tonumber(cue.time) or 0.4
	if not from or not to then
		return
	end
	local steps = math.max(1, math.floor((to - from).Magnitude / 4))
	for i = 0, steps do
		local t = i / steps
		task.delay(t * time, function()
			local d = disc(from:Lerp(to, t) - Vector3.new(0, 2.5, 0), 2.2, if i % 2 == 0 then primary else secondary, 0.1, 0.3)
			fade(d, 0.9)
		end)
	end
end

handlers.blink = function(cue, primary, secondary)
	local from, to = v3(cue.from), v3(cue.to)
	local delay = tonumber(cue.delay) or 0
	local scale = tonumber(cue.scale) or 1
	if from then
		local ghost = part({ Size = Vector3.new(2, 5, 1) * scale, CFrame = CFrame.new(from), Color = primary, Material = Enum.Material.ForceField, Transparency = 0.35 })
		fade(ghost, 0.7)
	end
	if to then
		task.delay(delay, function()
			ring(to - Vector3.new(0, 2.5 * scale, 0), 2, 8, secondary, 0.4)
		end)
	end
	for _, spot in (if typeof(cue.clones) == "table" then cue.clones else {}) :: { any } do
		local at = v3(spot)
		if at then
			local clone = part({ Size = Vector3.new(3, 6, 3), CFrame = CFrame.new(at + Vector3.new(0, 3, 0)), Color = primary, Material = Enum.Material.ForceField, Transparency = 0.4 })
			fade(clone, 0.9)
		end
	end
end

handlers.slash = function(cue, primary, secondary)
	local at = v3(cue.at)
	if not at then
		return
	end
	local size = tonumber(cue.size) or 6
	local p = part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.3, size, size),
		CFrame = CFrame.new(at + Vector3.new(0, 1, 0)) * CFrame.Angles(math.rad(math.random(-30, 30)), math.rad(math.random(0, 180)), 0),
		Color = if cue.echo then secondary else primary,
		Transparency = 0.1,
	})
	fade(p, 0.3, { Size = Vector3.new(0.3, size * 1.4, size * 1.4) })
end

handlers.burst = function(cue, primary, secondary)
	local at = v3(cue.at)
	if not at then
		return
	end
	local radius = tonumber(cue.radius) or 12
	local style = tostring(cue.style)
	for i = 0, 2 do
		task.delay(i * 0.12, function()
			ring(at - Vector3.new(0, 2.5, 0), radius * (0.3 + i * 0.2), radius * (0.9 + i * 0.15), if i % 2 == 0 then primary else secondary, 0.55)
		end)
	end
	if style == "eclipse" then
		local sphere = part({ Shape = Enum.PartType.Ball, Size = Vector3.new(4, 4, 4), Position = at + Vector3.new(0, 6, 0), Color = primary, Transparency = 0.2 })
		fade(sphere, 0.8, { Size = Vector3.new(radius * 1.3, radius * 1.3, radius * 1.3) })
	elseif style == "bloom" or style == "flare" or style == "frost" or style == "dread" then
		for i = 0, 11 do
			local angle = (i / 12) * math.pi * 2
			local shard = part({
				Size = if style == "frost" then Vector3.new(0.8, 3, 0.8) else Vector3.new(0.7, 0.15, 1.1),
				CFrame = CFrame.new(at + Vector3.new(0, 1.5, 0)),
				Color = if i % 2 == 0 then primary else secondary,
				Material = if style == "frost" then Enum.Material.Glass else Enum.Material.Neon,
			})
			fade(shard, 0.6, { CFrame = CFrame.new(at + Vector3.new(math.cos(angle) * radius, math.random(0, 3), math.sin(angle) * radius)) * CFrame.Angles(math.random(), math.random(), 0) })
		end
	end
end

handlers.zone = function(cue, primary, secondary)
	local at = v3(cue.at)
	if not at then
		return
	end
	local radius = tonumber(cue.radius) or 8
	local duration = tonumber(cue.duration) or 3
	local style = tostring(cue.style)
	local outer = disc(at, radius, primary, 0.35, 0.3)
	outer.Material = Enum.Material.ForceField
	local inner = disc(at + Vector3.new(0, 0.1, 0), radius * 0.55, secondary, 0.3, 0.3)
	local tear: BasePart? = nil
	if style == "tear" then
		tear = part({ Size = Vector3.new(2, 12, 2), CFrame = CFrame.new(at + Vector3.new(0, 6, 0)), Color = primary, Material = Enum.Material.ForceField, Transparency = 0.1 })
	end
	local started = os.clock()
	local nextBit = 0
	local connection: RBXScriptConnection
	connection = RunService.RenderStepped:Connect(function(dt)
		local t = os.clock() - started
		if t >= duration or not outer.Parent then
			connection:Disconnect()
			fade(outer, 0.3)
			fade(inner, 0.3)
			if tear then
				fade(tear, 0.3)
			end
			return
		end
		local spin = if style == "whirlpool" or style == "maelstrom" then 200 else 60
		outer.CFrame = CFrame.new(at + Vector3.new(0, 0.15, 0)) * CFrame.Angles(0, math.rad(t * spin), math.rad(90))
		inner.CFrame = CFrame.new(at + Vector3.new(0, 0.25, 0)) * CFrame.Angles(0, -math.rad(t * spin * 1.3), math.rad(90))
		if tear then
			tear.CFrame = tear.CFrame * CFrame.Angles(0, dt * 1.2, 0)
		end
		if t >= nextBit then
			nextBit = t + (if style == "petals" or style == "blizzard" then 0.08 else 0.35)
			local angle = math.random() * math.pi * 2
			local r = math.random() * radius
			local spot = at + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r)
			if style == "static" then
				lightning(spot, secondary)
			elseif style == "petals" or style == "blizzard" then
				local bit = part({
					Size = if style == "petals" then Vector3.new(0.8, 0.1, 1.2) else Vector3.new(1.2, 1.2, 1.2),
					Shape = if style == "blizzard" then Enum.PartType.Ball else Enum.PartType.Block,
					Position = spot + Vector3.new(0, 25, 0),
					Color = secondary,
					Material = if style == "blizzard" then Enum.Material.Glass else Enum.Material.Neon,
				})
				fade(bit, 1, { Position = spot })
			elseif style == "maelstrom" or style == "whirlpool" then
				local plume = part({ Shape = Enum.PartType.Ball, Size = Vector3.new(2, 1, 2), Position = spot, Color = secondary, Material = Enum.Material.ForceField, Transparency = 0.2 })
				fade(plume, 0.5, { Size = Vector3.new(2, 9, 2), Position = spot + Vector3.new(0, 5, 0) })
			end
		end
	end)
end

handlers.tether = function(cue, _primary, secondary)
	local from = torsoOf(cue.from)
	local duration = math.max(0.2, tonumber(cue.duration) or 1)
	if not from then
		return
	end
	local a0 = Instance.new("Attachment")
	a0.Parent = from
	Debris:AddItem(a0, duration + 0.1)
	for _, model in (if typeof(cue.to) == "table" then cue.to else {}) :: { any } do
		local to = torsoOf(model)
		if to then
			local a1 = Instance.new("Attachment")
			a1.Parent = to
			local beam = Instance.new("Beam")
			beam.Attachment0 = a0
			beam.Attachment1 = a1
			beam.Color = ColorSequence.new(secondary)
			beam.LightEmission = 1
			beam.Width0 = 0.6
			beam.Width1 = 0.3
			beam.FaceCamera = true
			beam.CurveSize0 = math.random(-3, 3)
			beam.Parent = a0
			Debris:AddItem(a1, duration + 0.1)
		end
	end
end

handlers.stasis = function(cue, primary, secondary)
	local at = v3(cue.at)
	local duration = tonumber(cue.duration) or 1.2
	if at then
		ring(at - Vector3.new(0, 2.5, 0), 1, tonumber(cue.radius) or 8, primary, 0.6)
	end
	for _, model in (if typeof(cue.caught) == "table" then cue.caught else {}) :: { any } do
		local torso = torsoOf(model)
		if torso then
			local bubble = part({ Shape = Enum.PartType.Ball, Size = Vector3.new(7, 7, 7), CFrame = torso.CFrame, Color = secondary, Material = Enum.Material.ForceField, Transparency = 0.3 })
			local weld = Instance.new("WeldConstraint")
			bubble.Anchored = false
			bubble.Massless = true
			weld.Part0 = torso
			weld.Part1 = bubble
			weld.Parent = bubble
			task.delay(duration, function()
				if bubble.Parent then
					fade(bubble, 0.3)
				end
			end)
		end
	end
end

handlers.rally = function(cue, primary, secondary)
	local at = v3(cue.at)
	if not at then
		return
	end
	local pillar = part({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(60, 8, 8), CFrame = CFrame.new(at + Vector3.new(0, 25, 0)) * CFrame.Angles(0, 0, math.rad(90)), Color = primary, Transparency = 0.1 })
	fade(pillar, 0.9, { Size = Vector3.new(80, 14, 14) })
	local radius = tonumber(cue.radius) or 20
	for i = 0, 3 do
		task.delay(i * 0.1, function()
			ring(at - Vector3.new(0, 2.5, 0), radius * 0.4 + i * 3, radius + i * 4, if i % 2 == 0 then secondary else primary, 0.7)
		end)
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function WildbornController.init(_self: any, _ctx: any) end

function WildbornController.start(_self: any, _ctx: any)
	Net.listen("WildbornCue", function(cue: any)
		if typeof(cue) ~= "table" then
			return
		end
		local handler = handlers[tostring(cue.kind)]
		if handler then
			local primary = c3(cue.primary, Color3.new(1, 1, 1))
			local secondary = c3(cue.secondary, primary)
			local ok, err = pcall(handler, cue, primary, secondary)
			if not ok then
				warn("[WildbornController] " .. tostring(cue.kind) .. ": " .. tostring(err))
			end
		end
	end)
	RunService.RenderStepped:Connect(function(dt)
		if next(bolts) == nil then
			return
		end
		local now = os.clock()
		for id, bolt in bolts do
			if now >= bolt.expires or not bolt.part.Parent then
				bolts[id] = nil
				bolt.part:Destroy()
			else
				bolt.part.Position += bolt.velocity * dt
			end
		end
	end)
end

return WildbornController
