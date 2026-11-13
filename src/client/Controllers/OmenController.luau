--!strict
--[[
	OmenController: draws the omens you could see from where you stand (docs/Omens.md). The server
	decides what is coming and how strong its omen is (Services/OmenService, remote Omens); this
	only draws the signs, stronger as the strength rises. Nothing is written on screen.

		birds   now and then a flock passes over you, flying hard away from the place
		smoke   dark columns rising at the place, seen from far off
		tremor  now and then the ground shivers (a small camera shake), more the closer you are
		tint    the light around you changes colour (strongest omen near you wins)
		star    a new light low in the sky, in the direction of the place, brighter as it nears
		motes   glowing motes rising out of the ground at the place

	Everything is client-only (parts under the camera, a ColorCorrectionEffect, a camera offset).
	Cost: at most one smoke and one motes emitter per omen, a flock of 7 parts every few seconds,
	one star billboard, and a short loop per frame while any omen is showing.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Data = require(Shared.Magic.Data.Omens)

local FLOCK = 7
local FLOCK_SPEED = 45
local FLOCK_LIFE = 4
local SHAKE_TIME = 0.6
local STAR_DISTANCE = 1500
local TREMOR_ACTION = "OmenTremor"

type Shown = {
	id: string,
	source: string,
	position: Vector3,
	s: number,
	parts: { Instance },
	nextFlock: number,
	nextTremor: number,
}
type Bird = { part: BasePart, born: number, dir: Vector3, phase: number }

local OmenController = {
	name = "OmenController",
	dependencies = {},
}

local shown: { [string]: Shown } = {}
local birds: { Bird } = {}
local folder: Folder? = nil
local grade: ColorCorrectionEffect? = nil
local star: BillboardGui? = nil
local starAnchor: Part? = nil
local shakeUntil = 0
local shakeAmount = 0

local function folderOf(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "Omens"
	made.Parent = workspace.CurrentCamera or workspace
	folder = made
	return made
end

local function anchorPart(position: Vector3, size: Vector3): Part
	local p = Instance.new("Part")
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.Transparency = 1
	p.Size = size
	p.Position = position
	p.Parent = folderOf()
	return p
end

local function signsOf(source: string): { Data.Sign }
	local out: { Data.Sign } = {}
	local def = Data.sources[source]
	for _, id in (if def then def.signs else {}) :: { string } do
		local sign = Data.signs[id]
		if sign then
			table.insert(out, sign)
		end
	end
	return out
end

local function hasStyle(source: string, style: string): Data.Sign?
	for _, sign in signsOf(source) do
		if sign.style == style then
			return sign
		end
	end
	return nil
end

-- ─── Emitters at the place ──────────────────────────────────────────────────

local function smokeAt(o: Shown, sign: Data.Sign)
	local base = anchorPart(o.position, Vector3.new(24, 1, 24))
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Smoke"
	emitter.Color = ColorSequence.new(sign.color)
	emitter.LightInfluence = 0.6
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 12), NumberSequenceKeypoint.new(1, 55) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.35), NumberSequenceKeypoint.new(0.7, 0.6), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(14, 20)
	emitter.Speed = NumberRange.new(10, 16)
	emitter.SpreadAngle = Vector2.new(8, 8)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Acceleration = Vector3.new(2, 1, 0)
	emitter.RotSpeed = NumberRange.new(-10, 10)
	emitter.Rate = 0
	emitter.Parent = base
	table.insert(o.parts, base)
end

local function motesAt(o: Shown, sign: Data.Sign)
	local base = anchorPart(o.position + Vector3.new(0, 0.5, 0), Vector3.new(40, 1, 40))
	local emitter = Instance.new("ParticleEmitter")
	emitter.Name = "Motes"
	emitter.Shape = Enum.ParticleEmitterShape.Box
	emitter.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	emitter.Color = ColorSequence.new(sign.color)
	emitter.LightEmission = 1
	emitter.LightInfluence = 0
	emitter.Size = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.5), NumberSequenceKeypoint.new(1, 0.1) })
	emitter.Transparency = NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.2), NumberSequenceKeypoint.new(1, 1) })
	emitter.Lifetime = NumberRange.new(4, 7)
	emitter.Speed = NumberRange.new(2, 5)
	emitter.EmissionDirection = Enum.NormalId.Top
	emitter.Rate = 0
	emitter.Parent = base
	table.insert(o.parts, base)
end

local function setRates(o: Shown)
	for _, part in o.parts do
		local smoke = part:FindFirstChild("Smoke")
		if smoke and smoke:IsA("ParticleEmitter") then
			smoke.Rate = 0.5 + 3.5 * o.s
		end
		local motes = part:FindFirstChild("Motes")
		if motes and motes:IsA("ParticleEmitter") then
			motes.Rate = 6 + 40 * o.s
		end
	end
end

-- ─── Receiving ──────────────────────────────────────────────────────────────

local function drop(id: string)
	local o = shown[id]
	shown[id] = nil
	if o then
		for _, part in o.parts do
			part:Destroy()
		end
	end
end

local function onOmens(payload: any)
	local list = if typeof(payload) == "table" and typeof(payload.list) == "table" then payload.list else {}
	local seen: { [string]: boolean } = {}
	local now = os.clock()
	for _, entry in list do
		if typeof(entry) ~= "table" or typeof(entry.id) ~= "string" or not Data.sources[entry.source] then
			continue
		end
		local id = entry.id
		seen[id] = true
		local s = math.clamp(tonumber(entry.s) or 0, 0, 1)
		local o = shown[id]
		if not o then
			local position = Vector3.new(tonumber(entry.x) or 0, tonumber(entry.y) or 0, tonumber(entry.z) or 0)
			local made: Shown = { id = id, source = entry.source, position = position, s = s, parts = {}, nextFlock = now + 1, nextTremor = now + 2 }
			o = made
			shown[id] = made
			local smoke = hasStyle(entry.source, "smoke")
			if smoke then
				smokeAt(made, smoke)
			end
			local motes = hasStyle(entry.source, "motes")
			if motes then
				motesAt(made, motes)
			end
		end
		(o :: Shown).s = s
		setRates(o :: Shown)
	end
	for id in shown do
		if not seen[id] then
			drop(id)
		end
	end
end

-- ─── Per frame ──────────────────────────────────────────────────────────────

local function here(): Vector3?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

-- 1 at the place, falling to 0 at the edge of where it can be seen (1 everywhere for seen-anywhere).
local function closeness(o: Shown, at: Vector3): number
	local def = Data.sources[o.source]
	if def.seen == math.huge then
		return 1
	end
	local d = (Vector2.new(o.position.X, o.position.Z) - Vector2.new(at.X, at.Z)).Magnitude
	return math.clamp(1 - d / def.seen, 0, 1)
end

local function launchFlock(o: Shown, sign: Data.Sign, at: Vector3)
	local away = Vector3.new(at.X - o.position.X, 0, at.Z - o.position.Z)
	local dir = if away.Magnitude > 20 then away.Unit else Vector3.new(math.random() - 0.5, 0, math.random() - 0.5).Unit
	local side = Vector3.new(-dir.Z, 0, dir.X)
	local start = at - dir * 70 + side * (math.random() * 40 - 20) + Vector3.new(0, 28 + math.random() * 14, 0)
	local now = os.clock()
	for i = 1, FLOCK do
		local bird = Instance.new("Part")
		bird.Anchored = true
		bird.CanCollide = false
		bird.CanQuery = false
		bird.CanTouch = false
		bird.Size = Vector3.new(1.3, 0.12, 0.6)
		bird.Color = sign.color
		bird.Material = Enum.Material.SmoothPlastic
		local offset = side * ((i - FLOCK / 2) * 2.2) - dir * (math.abs(i - FLOCK / 2) * 1.6) + Vector3.new(0, math.random() * 2, 0)
		bird.CFrame = CFrame.lookAt(start + offset, start + offset + dir)
		bird.Parent = folderOf()
		table.insert(birds, { part = bird, born = now, dir = dir, phase = math.random() * math.pi * 2 })
	end
end

local function stepBirds(dt: number)
	local now = os.clock()
	for i = #birds, 1, -1 do
		local b = birds[i]
		if now - b.born > FLOCK_LIFE then
			b.part:Destroy()
			table.remove(birds, i)
		else
			local flap = math.sin((now - b.born) * 14 + b.phase) * 0.6
			local position = b.part.Position + b.dir * FLOCK_SPEED * dt
			b.part.CFrame = CFrame.lookAt(position, position + b.dir) * CFrame.Angles(0, 0, flap)
		end
	end
end

local function updateStar(o: Shown?, at: Vector3)
	local camera = workspace.CurrentCamera
	local gui, anchor = star, starAnchor
	if not o or not camera or not gui or not anchor then
		if gui then
			gui.Enabled = false
		end
		return
	end
	local flat = Vector3.new(o.position.X - at.X, 0, o.position.Z - at.Z)
	local dir = (if flat.Magnitude > 1 then flat.Unit else Vector3.new(0, 0, -1)) * math.cos(math.rad(28)) + Vector3.new(0, math.sin(math.rad(28)), 0)
	anchor.Position = camera.CFrame.Position + dir * STAR_DISTANCE
	gui.Enabled = true
	local size = 10 + 34 * o.s + math.sin(os.clock() * 3) * 2 * o.s
	gui.Size = UDim2.fromOffset(size, size)
end

local function frame(dt: number)
	stepBirds(dt)
	local at = here()
	if not at or next(shown) == nil then
		updateStar(nil, Vector3.zero)
		local g = grade
		if g and g.Enabled then
			g.Enabled = false
		end
		return
	end
	local now = os.clock()
	local tintWeight, tintColor = 0, Color3.new(1, 1, 1)
	local brightest: Shown? = nil
	for _, o in shown do
		local near = closeness(o, at)
		local weight = o.s * near
		local tint = hasStyle(o.source, "tint")
		if tint and weight > tintWeight then
			tintWeight, tintColor = weight, tint.color
		end
		if hasStyle(o.source, "star") and (not brightest or o.s > (brightest :: Shown).s) then
			brightest = o
		end
		local birdSign = hasStyle(o.source, "birds")
		if birdSign and near > 0 and now >= o.nextFlock then
			o.nextFlock = now + (9 - 6.5 * o.s) * (0.7 + math.random() * 0.6)
			launchFlock(o, birdSign, at)
		end
		if hasStyle(o.source, "tremor") and near > 0 and now >= o.nextTremor then
			o.nextTremor = now + (14 - 9 * o.s) * (0.7 + math.random() * 0.6)
			shakeUntil = now + SHAKE_TIME
			shakeAmount = math.max(0.004, 0.02 * o.s * near)
		end
	end
	updateStar(brightest, at)
	local g = grade
	if g then
		g.Enabled = tintWeight > 0.01
		g.TintColor = Color3.new(1, 1, 1):Lerp(tintColor, 0.45 * tintWeight)
		g.Brightness = -0.06 * tintWeight
		g.Saturation = -0.25 * tintWeight
	end
end

-- After the camera has moved: the tremor's small shake (the camera scripts reset it every frame).
local function shake()
	local now = os.clock()
	if now >= shakeUntil then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local fade = (shakeUntil - now) / SHAKE_TIME
	local a = shakeAmount * fade
	camera.CFrame *= CFrame.Angles(math.sin(now * 61) * a, math.sin(now * 47 + 1) * a, math.sin(now * 53 + 2) * a * 0.5)
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function OmenController.init(_self: any, _ctx: any) end

function OmenController.start(_self: any, _ctx: any)
	local g = Instance.new("ColorCorrectionEffect")
	g.Name = "Omens"
	g.Enabled = false
	g.Parent = Lighting
	grade = g

	local anchor = anchorPart(Vector3.zero, Vector3.new(1, 1, 1))
	anchor.Name = "OmenStar"
	starAnchor = anchor
	local gui = Instance.new("BillboardGui")
	gui.Name = "OmenStar"
	gui.AlwaysOnTop = false
	gui.LightInfluence = 0
	gui.Enabled = false
	gui.Size = UDim2.fromOffset(16, 16)
	gui.Adornee = anchor
	local glow = Instance.new("ImageLabel")
	glow.BackgroundTransparency = 1
	glow.Size = UDim2.fromScale(1, 1)
	glow.Image = "rbxasset://textures/particles/sparkles_main.dds"
	glow.ImageColor3 = Data.signs.new_star.color
	glow.Parent = gui
	gui.Parent = anchor
	star = gui

	Net.listen("Omens", onOmens)
	RunService.RenderStepped:Connect(frame)
	RunService:BindToRenderStep(TREMOR_ACTION, Enum.RenderPriority.Camera.Value + 1, shake)
end

return OmenController
