--!strict
--[[
	StruggleController: draws spells meeting in the air and spell struggles (docs/SpellStruggle.md).
	The server decides everything (Cast/Struggle, remote Struggle); this only draws it. There is no
	meter: the knot's position, size and colour, and the two beams' widths, are the meter.

		clash   a flash in both spells' colours where they met, sparks, bigger for a shatter
		start / tick   a beam from each caster to the knot; the knot sits at `point` along the line
		        (lerped between updates), grows with the two weights, takes the colour of whoever is
		        winning, and the losing side's beam thins. Within 40 studs the camera shakes a little.
		        If you're one of the two, the edges darken as the knot comes for you.
		end     the knot bursts and everything is removed
	Input while struggling (Struggling attribute on your character): the cast button is routed by
	CastClient (surge / feed); a jump lets go (StruggleIntent "break").

	Client-only parts under the camera; at most Data.maxStruggles knots.
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Domains = require(Shared.Magic.Data.Domains)
local Client = script.Parent.Parent
local SpellFx = require(Client:WaitForChild("Fx").SpellFx)

local STALE = 1.5
local DIM = 0.7 -- Neon under Bloom blows out to white: keep colours dimmer

local StruggleController = {
	name = "StruggleController",
	dependencies = {},
}

type Shown = {
	id: number,
	a: Model,
	b: Model,
	colorA: Color3,
	colorB: Color3,
	size: number,
	target: number,
	point: number,
	seen: number,
	folder: Folder,
	knot: Part,
	knotAttach: Attachment,
	beamA: Beam,
	beamB: Beam,
	attachA: Attachment,
	attachB: Attachment,
	sparks: ParticleEmitter,
}

local shown: { [number]: Shown } = {}
local grade: ColorCorrectionEffect? = nil
local lastBreak = 0

local function colorOf(domain: any): Color3
	local def = typeof(domain) == "string" and (Domains :: any)[domain]
	local palette = def and def.feel and def.feel.palette
	local c: Color3 = if palette and palette[1] then palette[1] else Color3.fromRGB(220, 220, 255)
	return Color3.new(c.R * DIM, c.G * DIM, c.B * DIM)
end

local function rootOf(model: Model?): BasePart?
	local root = model and model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function anchorPart(name: string, size: number, color: Color3, parent: Instance): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Shape = Enum.PartType.Ball
	part.Size = Vector3.one * size
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Color = color
	part.Parent = parent
	return part
end

local function beamBetween(a0: Attachment, a1: Attachment, color: Color3, parent: Instance): Beam
	local beam = Instance.new("Beam")
	beam.Attachment0 = a0
	beam.Attachment1 = a1
	beam.Color = ColorSequence.new(color)
	beam.LightEmission = 0.8
	beam.LightInfluence = 0
	beam.FaceCamera = true
	beam.Segments = 12
	beam.Width0, beam.Width1 = 1, 1
	beam.Transparency = NumberSequence.new(0.15)
	beam.Parent = parent
	return beam
end

local function flash(at: Vector3, colorA: Color3, colorB: Color3, size: number)
	local ball = anchorPart("Clash", 0.5, colorA:Lerp(colorB, 0.5), workspace.CurrentCamera or workspace)
	ball.Position = at
	ball.Transparency = 0.1
	local tween = TweenService:Create(ball, TweenInfo.new(0.35, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { Size = Vector3.one * size, Transparency = 1 })
	tween:Play()
	local attach = Instance.new("Attachment")
	attach.Parent = ball
	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(colorA, colorB)
	sparks.LightEmission = 1
	sparks.Size = NumberSequence.new(0.35, 0)
	sparks.Lifetime = NumberRange.new(0.25, 0.5)
	sparks.Speed = NumberRange.new(size * 3, size * 6)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Rate = 0
	sparks.Parent = attach
	sparks:Emit(math.floor(10 + size * 3))
	task.delay(0.8, function()
		ball:Destroy()
	end)
end

local function remove(s: Shown, burst: boolean)
	shown[s.id] = nil
	if burst and s.knot.Parent then
		flash(s.knot.Position, s.colorA, s.colorB, s.size * 3)
	end
	s.folder:Destroy()
end

local function ensure(msg: any): Shown?
	local existing = shown[msg.id]
	if existing then
		return existing
	end
	local a, b = msg.a, msg.b
	local ra, rb = rootOf(a), rootOf(b)
	if not ra or not rb then
		return nil
	end
	local folder = Instance.new("Folder")
	folder.Name = "Struggle" .. tostring(msg.id)
	folder.Parent = workspace.CurrentCamera or workspace
	local colorA, colorB = colorOf(msg.domainA), colorOf(msg.domainB)
	local size = math.clamp(1.5 + 0.25 * ((msg.wa or 2) + (msg.wb or 2)), 2, 7)
	local knot = anchorPart("Knot", size, colorA:Lerp(colorB, 0.5), folder)
	knot.Transparency = 0.2
	local knotAttach = Instance.new("Attachment")
	knotAttach.Parent = knot
	local attachA = Instance.new("Attachment")
	attachA.Position = Vector3.new(0, 0.8, -1)
	attachA.Parent = ra
	local attachB = Instance.new("Attachment")
	attachB.Position = Vector3.new(0, 0.8, -1)
	attachB.Parent = rb
	local sparks = Instance.new("ParticleEmitter")
	sparks.Color = ColorSequence.new(colorA, colorB)
	sparks.LightEmission = 1
	sparks.Size = NumberSequence.new(0.3, 0)
	sparks.Lifetime = NumberRange.new(0.2, 0.45)
	sparks.Speed = NumberRange.new(8, 18)
	sparks.SpreadAngle = Vector2.new(180, 180)
	sparks.Rate = 40
	sparks.Parent = knotAttach
	local s: Shown = {
		id = msg.id,
		a = a,
		b = b,
		colorA = colorA,
		colorB = colorB,
		size = size,
		target = msg.point or 0.5,
		point = msg.point or 0.5,
		seen = os.clock(),
		folder = folder,
		knot = knot,
		knotAttach = knotAttach,
		beamA = beamBetween(attachA, knotAttach, colorA, folder),
		beamB = beamBetween(attachB, knotAttach, colorB, folder),
		attachA = attachA,
		attachB = attachB,
		sparks = sparks,
	}
	-- the caster-side attachments live on the casters; clean them up with the folder
	folder.Destroying:Connect(function()
		attachA:Destroy()
		attachB:Destroy()
	end)
	shown[msg.id] = s
	return s
end

local function onMessage(msg: any)
	if typeof(msg) ~= "table" then
		return
	end
	if msg.t == "clash" then
		if typeof(msg.at) == "Vector3" then
			flash(msg.at, colorOf(msg.domainA), colorOf(msg.domainB), if msg.kind == "shatter" or msg.kind == "struggle" then 7 else 4)
		end
		return
	end
	if msg.t == "end" then
		local s = shown[msg.id]
		if s then
			remove(s, true)
		elseif typeof(msg.at) == "Vector3" then
			flash(msg.at, colorOf(msg.domainA), colorOf(msg.domainB), 9)
		end
		return
	end
	local s = ensure(msg)
	if s then
		s.target = msg.point or s.target
		s.seen = os.clock()
	end
end

local function step(dt: number)
	local me = Players.LocalPlayer.Character
	local danger = 0
	local now = os.clock()
	for _, s in shown do
		local ra, rb = rootOf(s.a), rootOf(s.b)
		if not ra or not rb or now - s.seen > STALE then
			remove(s, false)
			continue
		end
		s.point += (s.target - s.point) * math.min(1, dt * 8)
		local from = ra.Position + Vector3.new(0, 0.8, 0)
		local to = rb.Position + Vector3.new(0, 0.8, 0)
		local at = from:Lerp(to, s.point) + Vector3.new(0, 0.4, 0)
		local pulse = 1 + 0.08 * math.sin(now * 18)
		s.knot.Size = Vector3.one * s.size * pulse
		s.knot.Position = at
		-- The knot shows whoever is winning: near B means A is winning.
		s.knot.Color = s.colorB:Lerp(s.colorA, s.point)
		s.beamA.Width0, s.beamA.Width1 = 0.4 + 1.4 * s.point, 0.6 + 1.6 * s.point
		s.beamB.Width0, s.beamB.Width1 = 0.4 + 1.4 * (1 - s.point), 0.6 + 1.6 * (1 - s.point)
		local myRoot = rootOf(me)
		if myRoot then
			local d = (myRoot.Position - at).Magnitude
			if d < 40 and math.random() < 0.25 then
				SpellFx.shake(0.25 * (1 - d / 40), 0.15)
			end
		end
		if me and me == s.a then
			danger = math.max(danger, math.clamp((0.5 - s.point) / 0.5, 0, 1))
		elseif me and me == s.b then
			danger = math.max(danger, math.clamp((s.point - 0.5) / 0.5, 0, 1))
		end
	end
	local g = grade
	if g then
		g.Enabled = danger > 0.01
		g.Brightness = -0.22 * danger
		g.Contrast = 0.15 * danger
	end
end

function StruggleController.init(_self: any, _ctx: any) end

function StruggleController.start(_self: any, _ctx: any)
	local g = Instance.new("ColorCorrectionEffect")
	g.Name = "Struggle"
	g.Enabled = false
	g.Parent = Lighting
	grade = g
	Net.listen("Struggle", onMessage)
	RunService.RenderStepped:Connect(step)
	-- Jump lets go.
	UserInputService.JumpRequest:Connect(function()
		local character = Players.LocalPlayer.Character
		if character and character:GetAttribute("Struggling") ~= nil and os.clock() - lastBreak > 0.5 then
			lastBreak = os.clock()
			Net.send("StruggleIntent", "break")
		end
	end)
end

return StruggleController
