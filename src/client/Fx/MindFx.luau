--!strict
--[[
	MindFx: what Mind's spells look like (docs/DomainIdeas.md, "Mind"). Cosmetic only: the server
	(Effects/MindArt, Cast/ArtRuntime) decides everything. Mind reads as violet light and things that
	aren't quite real: shimmers, copies, a wall with no weight.

		MindFx.cue(effect)   one-shot "mind" WorldEffect cues, by `fx`:
		    far_eye    the caster's camera looks out of the thrown eye for a few seconds (caster only)
		    weak_spot  red marks on where they're weak     rally    a warm ring and lift round you
		    phantom_blade  a pale blade flashing in           vanish   you shimmering out of notice
		    forget     memory motes leaving a head            push     an invisible ripple shoving forward
		    puppet     violet strings from you to them
		Bodies (Fx/ArtFx, by ArtLook): despair, pacify, mirror_images, false_wall, phantom_beast (drawn only
		    for its victim), mirage_pit, whispers.
		Bolt looks (ArtFx.flight): eye, blade, spike.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local E = require(Shared.Magic.Data.MindTuning)

local DomainFx = require(script.Parent.DomainFx)
local FxLayers = require(script.Parent.FxLayers)
local A = require(script.Parent.ArtFx)

local TEX = DomainFx.textures
local L = E.looks
local UP = Vector3.new(0, 1, 0)

local rate, part, seq, emitter = A.rate, A.part, A.seq, A.emitter
local burst, fadeOut, rootOf, flatDisc = A.burst, A.fadeOut, A.rootOf, A.flatDisc
local own = A.own
type Visual = A.Visual

local localPlayer = Players.LocalPlayer

local MindFx = {}

local function sound(position: Vector3, property: string, which: string, volume: number?)
	A.sound(position, "mind", property, which, volume)
end

local function motes(at: Vector3, color: Color3, count: number, spread: number?)
	burst(at, {
		texture = TEX.mote,
		color = ColorSequence.new(color),
		size = seq(0, 0.45, 1, 0),
		lifetime = NumberRange.new(0.6, 1.1),
		speed = NumberRange.new(2, 6),
		spread = spread or 180,
		acceleration = Vector3.new(0, 2, 0),
	}, count)
end

-- ─── One-shot cues ──────────────────────────────────────────────────────────

-- The caster's camera looks out of the eye, then comes home.
local farEyeToken = 0
local function farEye(cue: any)
	if not localPlayer or cue.caster ~= localPlayer.UserId then
		return
	end
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local at: Vector3 = cue.at
	local dir: Vector3 = cue.dir or Vector3.new(0, 0, -1)
	local seconds = math.clamp(tonumber(cue.seconds) or 4, 1, 10)
	farEyeToken += 1
	local token = farEyeToken
	local before = camera.CameraType
	camera.CameraType = Enum.CameraType.Scriptable
	local started = os.clock()
	FxLayers.animate(seconds, function(_t)
		if token ~= farEyeToken then
			return
		end
		-- A slow look round from where the eye fell.
		local sweep = math.sin((os.clock() - started) * 0.8) * 0.6
		local look = CFrame.Angles(0, sweep, 0):VectorToWorldSpace(dir)
		camera.CFrame = CFrame.lookAt(at, at + look + Vector3.new(0, -0.15, 0))
	end, function()
		if token == farEyeToken then
			camera.CameraType = if before == Enum.CameraType.Scriptable then Enum.CameraType.Custom else before
		end
	end)
	motes(at, L.psychic, 10)
end

local function weakSpot(cue: any)
	local model = cue.model
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return
	end
	local h = Instance.new("Highlight")
	h.FillTransparency = 1
	h.OutlineColor = Color3.fromRGB(255, 70, 70)
	h.OutlineTransparency = 0.1
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Parent = model
	Debris:AddItem(h, math.clamp(tonumber(cue.seconds) or 6, 1, 15))
end

local function rally(cue: any)
	local at: Vector3 = cue.at
	FxLayers.shockwave(at, UP, cue.radius or 14, L.warm, 0.5)
	motes(at + UP, L.warm, 24, 60)
	sound(at, "emotion", "launch", 0.8)
end

local function phantomBlade(cue: any)
	local at: Vector3 = cue.at
	local blade = part({ Size = Vector3.new(0.3, 4, 0.9), CFrame = CFrame.new(at + UP * 2) * CFrame.Angles(0, math.random() * 6, math.rad(30)), Color = L.pale, Transparency = 0.2 })
	fadeOut(blade, 0.35, Vector3.new(0.05, 5, 0.2))
	motes(at, L.pale, 12)
end

local function vanish(cue: any)
	burst(cue.at, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.shimmer, L.illusion),
		size = seq(0, 2, 1, 4),
		transparency = seq(0, 0.6, 1, 1),
		lifetime = NumberRange.new(0.6, 1),
		speed = NumberRange.new(1, 4),
		spread = 180,
		emission = 0.5,
		box = Vector3.new(2, 4, 2),
	}, 24)
end

local function forget(cue: any)
	local at: Vector3 = cue.at
	burst(at, {
		texture = TEX.mote,
		color = ColorSequence.new(L.memory, L.pale),
		size = seq(0, 0.5, 1, 0),
		lifetime = NumberRange.new(1, 1.6),
		speed = NumberRange.new(2, 5),
		spread = 50,
		acceleration = Vector3.new(0, 4, 0),
		rotSpeed = NumberRange.new(-200, 200),
	}, 20)
	sound(at, "memory", "launch", 0.6)
end

local function push(cue: any)
	local from: Vector3 = cue.from + UP * 1.4
	local dir: Vector3 = cue.dir
	local reach: number = cue.reach or 14
	local ring = part({ Shape = Enum.PartType.Cylinder, Size = Vector3.new(0.1, 2, 2), Color = L.psychic, Transparency = 0.6 })
	FxLayers.animate(0.3, function(t)
		local p = from + dir * reach * t
		local s = 2 + t * reach * 0.8
		ring.Size = Vector3.new(0.1, s, s)
		ring.CFrame = CFrame.lookAt(p, p + dir) * CFrame.Angles(0, math.rad(90), 0)
		ring.Transparency = 0.6 + 0.4 * t
	end, function()
		ring:Destroy()
	end)
	sound(from, "thought", "launch", 0.8)
end

local function puppet(cue: any)
	local root = rootOf(cue.model)
	local from: Vector3 = cue.from
	if not root or not from then
		return
	end
	local seconds = math.clamp(tonumber(cue.seconds) or 1.5, 0.3, 4)
	local strings: { BasePart } = {}
	for k = -1, 1 do
		table.insert(strings, part({ Size = Vector3.new(0.06, 0.06, 1), Color = L.psychic, Transparency = 0.2 }))
		local _ = k
	end
	FxLayers.animate(seconds, function(_t)
		local r = rootOf(cue.model)
		if not r then
			return
		end
		for i, s in strings do
			local a = from + UP * 2 + Vector3.new(0, (i - 2) * 0.4, 0)
			local b = r.Position + Vector3.new((i - 2) * 0.8, 1.5, 0)
			local d = b - a
			s.Size = Vector3.new(0.06, 0.06, d.Magnitude)
			s.CFrame = CFrame.lookAt(a + d / 2, b)
		end
	end, function()
		for _, s in strings do
			fadeOut(s, 0.2)
		end
	end)
end

local CUES: { [string]: (any) -> () } = {
	far_eye = farEye,
	weak_spot = weakSpot,
	rally = rally,
	phantom_blade = phantomBlade,
	vanish = vanish,
	forget = forget,
	push = push,
	puppet = puppet,
}

function MindFx.cue(cue: { [string]: any })
	local fn = CUES[cue.fx]
	if not fn then
		return
	end
	local ok, err = pcall(fn, cue)
	if not ok then
		warn("[MindFx] " .. tostring(cue.fx) .. ": " .. tostring(err))
	end
end

-- ─── Lasting bodies (drawn by Fx/ArtFx) ─────────────────────────────────────

local BUILD: { [string]: (Visual) -> () } = {}

local function radiusOf(v: Visual, default: number): number
	return (v.part:GetAttribute("Radius") :: number?) or default
end

local function zoneMist(v: Visual, color: Color3, transparency: number)
	v.fixed = true
	local radius = radiusOf(v, 8)
	v.root.Size = Vector3.new(radius * 1.6, 3, radius * 1.6)
	emitter(v.root, {
		texture = TEX.wisp,
		color = ColorSequence.new(color),
		size = seq(0, 2.5, 1, 5),
		transparency = seq(0, transparency, 1, 1),
		lifetime = NumberRange.new(1.4, 2.2),
		speed = NumberRange.new(0.3, 1.2),
		spread = 80,
		emission = 0.3,
		rate = 14,
	})
	own(v, flatDisc(v.root.Position, radius, color, 0.75))
end

BUILD.despair = function(v)
	zoneMist(v, L.dread, 0.45)
end

BUILD.pacify = function(v)
	zoneMist(v, L.warm, 0.65)
end

BUILD.whispers = function(v)
	zoneMist(v, L.psychic, 0.6)
end

-- Translucent copies of you, circling.
BUILD.mirror_images = function(v)
	local model = v.model
	if not model then
		return
	end
	local count = math.clamp((v.part:GetAttribute("Images") :: number?) or 3, 1, 5)
	local images: { { parts: { { copy: BasePart, source: BasePart } } } } = {}
	for _ = 1, count do
		local pieces: { { copy: BasePart, source: BasePart } } = {}
		for _, d in model:GetChildren() do
			if d:IsA("BasePart") and d.Name ~= "HumanoidRootPart" and d.Transparency < 0.95 then
				local copy = own(v, part({ Size = d.Size, Color = L.illusion, Material = Enum.Material.ForceField, Transparency = 0.3 }))
				local mesh = d:FindFirstChildOfClass("SpecialMesh")
				if mesh then
					local m = mesh:Clone()
					m.TextureId = ""
					m.Parent = copy
				end
				table.insert(pieces, { copy = copy :: BasePart, source = d :: BasePart })
			end
		end
		table.insert(images, { parts = pieces })
	end
	v.update = function(vis, _dt)
		local root = rootOf(model)
		if not root then
			return
		end
		local left = (vis.part:GetAttribute("Left") :: number?) or count
		local t = os.clock()
		for i, image in images do
			local visible = i <= left
			local angle = t * 1.3 + i / count * math.pi * 2
			local base = CFrame.new(root.Position + Vector3.new(math.cos(angle) * 3.5, 0, math.sin(angle) * 3.5)) * root.CFrame.Rotation
			for _, pair in image.parts do
				pair.copy.Transparency = if visible then 0.3 else 1
				pair.copy.CFrame = base * root.CFrame:ToObjectSpace(pair.source.CFrame)
			end
		end
	end
end

BUILD.false_wall = function(v)
	v.fixed = true
	-- It looks like plain stone from every side; only a faint shimmer at the edges gives it away.
	local wall = own(v, part({
		Size = v.part.Size,
		CFrame = v.part.CFrame,
		Color = Color3.fromRGB(118, 112, 104),
		Material = Enum.Material.Slate,
		Transparency = 0.05,
	}))
	emitter(wall, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.shimmer),
		size = seq(0, 0.3, 1, 0),
		transparency = seq(0, 0.6, 1, 1),
		lifetime = NumberRange.new(0.6, 1),
		emission = 0.4,
		rate = 4,
	})
end

-- Only its victim sees it.
BUILD.phantom_beast = function(v)
	local model = v.model
	if not model or not localPlayer or localPlayer.Character ~= model then
		return
	end
	local body = own(v, part({ Size = Vector3.new(3, 3, 6), Color = L.dread, Material = Enum.Material.SmoothPlastic, Transparency = 0.2 }))
	local head = own(v, part({ Size = Vector3.new(2.4, 2.2, 2.6), Color = L.dread, Material = Enum.Material.SmoothPlastic, Transparency = 0.2 }))
	local eyes = own(v, part({ Size = Vector3.new(1.6, 0.3, 0.2), Color = Color3.fromRGB(255, 60, 60) }))
	emitter(body, {
		texture = TEX.smoke,
		color = ColorSequence.new(L.dread),
		size = seq(0, 2, 1, 3),
		transparency = seq(0, 0.4, 1, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(0.5, 1.5),
		emission = 0,
		influence = 1,
		rate = 14,
	})
	v.update = function(_vis, _dt)
		local root = rootOf(model)
		if not root then
			return
		end
		-- Always just behind them, turning to face them.
		local t = os.clock()
		local behind = root.Position - root.CFrame.LookVector * (6 + math.sin(t * 3)) + UP * 0.5
		local frame = CFrame.lookAt(behind, root.Position)
		body.CFrame = frame
		head.CFrame = frame * CFrame.new(0, 1, -3.6)
		eyes.CFrame = head.CFrame * CFrame.new(0, 0.3, -1.35)
	end
end

BUILD.mirage_pit = function(v)
	v.fixed = true
	local radius = radiusOf(v, 6)
	own(v, flatDisc(v.root.Position + UP * 0.02, radius, Color3.fromRGB(8, 6, 10), 0, Enum.Material.SmoothPlastic))
	own(v, flatDisc(v.root.Position, radius + 0.8, Color3.fromRGB(70, 60, 50), 0.2, Enum.Material.Rock))
	v.root.Size = Vector3.new(radius * 1.4, 0.5, radius * 1.4)
	emitter(v.root, {
		texture = TEX.dust,
		color = ColorSequence.new(Color3.fromRGB(90, 80, 70)),
		size = seq(0, 0.5, 1, 0.2),
		transparency = seq(0, 0.5, 1, 1),
		lifetime = NumberRange.new(0.8, 1.2),
		speed = NumberRange.new(1, 2),
		direction = Enum.NormalId.Bottom,
		emission = 0,
		rate = 8,
	})
end

A.register(BUILD)

-- ─── Bolt looks (SpellFx.launch through ArtFx.flight) ───────────────────────

local function glow(anchor: Part, color: Color3, size: number): ParticleEmitter?
	local e = FxLayers.emitter(anchor, {
		texture = TEX.glow,
		color = ColorSequence.new(color),
		size = seq(0, size, 1, 0),
		transparency = seq(0, 0.3, 1, 1),
		lifetime = NumberRange.new(0.2, 0.35),
		speed = NumberRange.new(0.2, 0.8),
		emission = 1,
		rate = rate(40),
	})
	if e then
		e.Enabled = true
	end
	return e
end

A.registerFlights({
	eye = function(anchor: Part, coreSize: number)
		anchor.Color = L.pale
		anchor.Size = Vector3.one * math.max(1, coreSize * 1.6)
		local e = glow(anchor, L.psychic, coreSize * 3)
		return function()
			if e then
				e.Enabled = false
			end
		end, 0.3
	end,
	blade = function(anchor: Part, coreSize: number)
		anchor.Shape = Enum.PartType.Block
		anchor.Size = Vector3.new(0.25, 0.8, 3) * math.max(1, coreSize)
		anchor.Color = L.pale
		anchor.Transparency = 0.3
		local e = glow(anchor, L.illusion, coreSize * 2)
		return function()
			if e then
				e.Enabled = false
			end
		end, 0
	end,
	spike = function(anchor: Part, coreSize: number)
		anchor.Shape = Enum.PartType.Block
		anchor.Size = Vector3.new(0.2, 0.2, 2.4) * math.max(1, coreSize)
		anchor.Color = L.psychic
		local e = glow(anchor, L.psychic, coreSize * 2)
		return function()
			if e then
				e.Enabled = false
			end
		end, 0
	end,
})

return MindFx
