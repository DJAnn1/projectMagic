--!strict
--[[
	AirFx: what Air's spells look like (docs/DomainIdeas.md, "Air"). Cosmetic only: the server
	(Effects/AirArt, Cast/ArtRuntime) decides everything.

		AirFx.cue(effect)   one-shot "air" WorldEffect cues, by `fx`:
		    slice     a wind blade cutting on through        gale     a cone of wind and dust
		    airless   a clear airless bubble round a head     implode / blast   air rushing in, then out
		    ring      a ring of sound running along a line   shatter  breaking stone, ice and crystal
		    echo      outlines of everyone near, for the caster only (through walls)
		    boom      a thunderclap                          strike_warn / strike   a darkening spot, then lightning
		    hail_warn / hail   frost marks, then hailstones
		Bodies (Fx/ArtFx, by ArtLook): twister, updraft, tailwind, windwall, raincloud.
		Bolt look (ArtFx.flight): windblade.
]]

local Debris = game:GetService("Debris")
local Players = game:GetService("Players")

local localPlayer = Players.LocalPlayer

local Shared = game:GetService("ReplicatedStorage").Shared
local E = require(Shared.Magic.Data.AirTuning)

local DomainFx = require(script.Parent.DomainFx)
local FxLayers = require(script.Parent.FxLayers)
local A = require(script.Parent.ArtFx)

local TEX = DomainFx.textures
local L = E.looks
local UP = Vector3.new(0, 1, 0)

local rate, part, seq, emitter = A.rate, A.part, A.seq, A.emitter
local burst, fadeOut, rootOf, flatDisc, bolt = A.burst, A.fadeOut, A.rootOf, A.flatDisc, A.bolt
local own = A.own
type Visual = A.Visual

local AirFx = {}

local rng = Random.new()

local function sound(position: Vector3, property: string, which: string, volume: number?)
	A.sound(position, "air", property, which, volume)
end

local function streaks(at: Vector3, dir: Vector3, count: number, speed: number, spread: number)
	local p = part({ Transparency = 1, CFrame = CFrame.lookAt(at, at + dir) })
	local e = emitter(p, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.wind, L.windEdge),
		size = seq(0, 0.8, 1, 2.4),
		transparency = seq(0, 0.45, 1, 1),
		lifetime = NumberRange.new(0.35, 0.6),
		speed = NumberRange.new(speed * 0.7, speed),
		spread = spread,
		direction = Enum.NormalId.Front,
		emission = 0.3,
		drag = 1,
	})
	e.Rate = 0
	e:Emit(math.floor(rate(count)))
	Debris:AddItem(p, 1.2)
end

-- ─── One-shot cues ──────────────────────────────────────────────────────────

local function slice(cue: any)
	local from: Vector3 = cue.from
	local to: Vector3 = cue.to
	local d = to - from
	if d.Magnitude < 0.5 then
		return
	end
	local blade = part({
		Size = Vector3.new(4, 0.15, 1.2),
		CFrame = CFrame.lookAt(from, to),
		Color = L.wind,
		Transparency = 0.35,
	})
	local start = blade.CFrame
	FxLayers.animate(0.25, function(t)
		blade.CFrame = start + d * t
		blade.Transparency = 0.35 + 0.65 * t
	end, function()
		blade:Destroy()
	end)
	streaks(from, d.Unit, 20, 40, 10)
	sound(from, "flow", "launch", 0.6)
end

local function gale(cue: any)
	local from: Vector3 = cue.from + UP * 1.4
	local dir: Vector3 = cue.dir
	local reach: number = cue.reach or 16
	streaks(from, dir, 60, reach * 2.4, (cue.arc or 80) / 2)
	local p = part({ Transparency = 1, CFrame = CFrame.lookAt(from - UP, from - UP + dir) })
	local e = emitter(p, {
		texture = TEX.dust,
		color = ColorSequence.new(L.dust),
		size = seq(0, 1.2, 1, 4),
		transparency = seq(0, 0.5, 1, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(reach * 1.5, reach * 2),
		spread = (cue.arc or 80) / 2,
		direction = Enum.NormalId.Front,
		emission = 0,
	})
	e.Rate = 0
	e:Emit(math.floor(rate(30)))
	Debris:AddItem(p, 1.5)
	sound(from, "pressure", "launch", 0.9)
end

local function airless(cue: any)
	local root = rootOf(cue.model)
	local head = cue.model and cue.model:FindFirstChild("Head")
	local anchor = if head and head:IsA("BasePart") then head else root
	if not anchor then
		return
	end
	local seconds = math.clamp(tonumber(cue.seconds) or 1.5, 0.5, 4)
	local ball = part({
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * 2.8,
		Color = L.wind,
		Material = Enum.Material.Glass,
		Transparency = 0.75,
	})
	FxLayers.animate(seconds, function(_t)
		if anchor.Parent then
			ball.CFrame = anchor.CFrame
		end
		ball.Size = Vector3.one * (2.8 + math.sin(os.clock() * 14) * 0.08)
	end, function()
		ball:Destroy()
	end)
end

local function implode(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 8
	local p = part({ Shape = Enum.PartType.Ball, Transparency = 1, Size = Vector3.one * radius * 2, CFrame = CFrame.new(at) })
	local e = emitter(p, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.wind),
		size = seq(0, 2, 1, 0.3),
		transparency = seq(0, 0.6, 1, 0.2),
		lifetime = NumberRange.new(0.45),
		speed = NumberRange.new(radius * 2),
		shape = Enum.ParticleEmitterShape.Sphere,
		emission = 0.3,
	})
	e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward -- born on the shell, rushing to the middle
	e.Rate = 0
	e:Emit(math.floor(rate(50)))
	Debris:AddItem(p, 1)
	sound(at, "pressure", "launch", 0.7)
end

local function blast(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 8
	FxLayers.shockwave(at, UP, radius, L.wind, 0.4)
	FxLayers.flash(at, 2, L.wind, 0.2)
	streaks(at, UP, 50, radius * 3, 180)
	sound(at, "pressure", "impact", 1)
end

local function ring(cue: any)
	local from: Vector3 = cue.from
	local to: Vector3 = cue.to
	local d = to - from
	local disc = part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.15, 3, 3),
		Color = L.sound,
		Transparency = 0.4,
	})
	FxLayers.animate(d.Magnitude / 70, function(t)
		local at = from + d * t
		disc.CFrame = CFrame.lookAt(at, at + d) * CFrame.Angles(0, math.rad(90), 0)
		local s = 3 + t * 4
		disc.Size = Vector3.new(0.15, s, s)
		disc.Transparency = 0.4 + 0.6 * t
	end, function()
		disc:Destroy()
	end)
	sound(from, "sound", "launch", 0.8)
end

local function shatter(cue: any)
	local at: Vector3 = cue.at
	FxLayers.shockwave(at, UP, cue.radius or 6, L.sound, 0.3)
	for _, spot in (cue.spots or {}) :: { Vector3 } do
		burst(spot, {
			texture = TEX.shard,
			color = ColorSequence.new(Color3.new(1, 1, 1), L.echo),
			size = seq(0, 0.7, 1, 0),
			lifetime = NumberRange.new(0.5, 1),
			speed = NumberRange.new(10, 26),
			spread = 180,
			acceleration = Vector3.new(0, -50, 0),
		}, 24)
	end
	sound(at, "sound", "impact", 1)
end

-- Only the caster sees who the echo found.
local function echo(cue: any)
	local me = Players.LocalPlayer
	local at: Vector3 = cue.at
	FxLayers.shockwave(at, UP, math.min(cue.radius or 40, 60), L.echo, 0.8)
	if not me or cue.caster ~= me.UserId then
		return
	end
	local seconds = math.clamp(tonumber(cue.seconds) or 4, 1, 10)
	for _, model in (cue.models or {}) :: { any } do
		if typeof(model) == "Instance" and model:IsA("Model") then
			local h = Instance.new("Highlight")
			h.Name = "EchoPulse"
			h.FillTransparency = 1
			h.OutlineColor = L.echo
			h.OutlineTransparency = 0
			h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
			h.Parent = model
			Debris:AddItem(h, seconds)
		end
	end
end

local function boom(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 10
	FxLayers.flash(at, 2.5, Color3.new(1, 1, 1), 0.15)
	FxLayers.shockwave(at, UP, radius, L.sound, 0.35)
	FxLayers.shockwave(at + UP * 2, UP, radius * 0.7, Color3.new(1, 1, 1), 0.25)
	burst(at, {
		texture = TEX.dust,
		color = ColorSequence.new(L.dust),
		size = seq(0, 2, 1, 4),
		transparency = seq(0, 0.5, 1, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(radius, radius * 2),
		spread = 180,
		emission = 0,
	}, 24)
	sound(at, "sound", "impact", 1.2)
end

local function strikeWarn(cue: any)
	local at: Vector3 = cue.at
	local delay = tonumber(cue.delay) or 0.5
	local mark = flatDisc(at, cue.radius or 3.5, L.bolt, 0.6)
	FxLayers.animate(delay, function(t)
		mark.Transparency = 0.8 - 0.5 * t
	end, function()
		mark:Destroy()
	end)
end

local function strike(cue: any)
	local at: Vector3 = cue.at
	bolt(at + UP * 70 + Vector3.new(rng:NextNumber(-4, 4), 0, rng:NextNumber(-4, 4)), at, L.bolt, 0.6, 0.3)
	FxLayers.flash(at, 3.5, L.bolt, 0.25)
	FxLayers.shockwave(at, UP, 6, L.bolt, 0.3)
	FxLayers.light(at, L.bolt, 14, 40, 0.4, 0.6)
	sound(at, "charge", "impact", 1.2)
end

local function hailWarn(cue: any)
	local delay = tonumber(cue.delay) or 0.8
	for _, spot in (cue.spots or {}) :: { Vector3 } do
		local mark = flatDisc(spot, cue.radius or 2.4, L.hail, 0.6)
		FxLayers.animate(delay, function(t)
			mark.Transparency = 0.8 - 0.4 * math.abs(math.sin(t * math.pi * 3))
		end, function()
			mark:Destroy()
		end)
	end
end

local function hail(cue: any)
	for i, spot in (cue.spots or {}) :: { Vector3 } do
		task.delay((i - 1) * 0.04, function()
			local top = spot + UP * 30
			local stone = part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 0.9, Color = L.hail, Material = Enum.Material.Ice, CFrame = CFrame.new(top) })
			FxLayers.animate(0.18, function(t)
				stone.CFrame = CFrame.new(top - UP * 29.5 * t)
			end, function()
				burst(spot, {
					texture = TEX.shard,
					color = ColorSequence.new(L.hail),
					size = seq(0, 0.4, 1, 0),
					lifetime = NumberRange.new(0.3, 0.6),
					speed = NumberRange.new(6, 14),
					spread = 70,
					acceleration = Vector3.new(0, -40, 0),
				}, 6)
				fadeOut(stone, 0.5)
			end)
		end)
	end
	if cue.spots and cue.spots[1] then
		sound(cue.spots[1], "temperature", "impact", 0.8)
	end
end

local CUES: { [string]: (any) -> () } = {
	slice = slice,
	gale = gale,
	airless = airless,
	implode = implode,
	blast = blast,
	ring = ring,
	shatter = shatter,
	echo = echo,
	boom = boom,
	strike_warn = strikeWarn,
	strike = strike,
	hail_warn = hailWarn,
	hail = hail,
}

function AirFx.cue(cue: { [string]: any })
	local fn = CUES[cue.fx]
	if not fn then
		return
	end
	local ok, err = pcall(fn, cue)
	if not ok then
		warn("[AirFx] " .. tostring(cue.fx) .. ": " .. tostring(err))
	end
end

-- ─── Lasting bodies (drawn by Fx/ArtFx) ─────────────────────────────────────

local BUILD: { [string]: (Visual) -> () } = {}

BUILD.twister = function(v)
	local funnel = own(v, part({ Transparency = 1, Size = Vector3.new(3, 12, 3) }))
	emitter(funnel, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.wind, L.windEdge),
		size = seq(0, 1.5, 1, 4),
		transparency = seq(0, 0.4, 1, 1),
		lifetime = NumberRange.new(0.6, 1),
		speed = NumberRange.new(6, 10),
		rotSpeed = NumberRange.new(-400, 400),
		shape = Enum.ParticleEmitterShape.Cylinder,
		acceleration = Vector3.new(0, 10, 0),
		emission = 0.2,
		rate = 80,
	})
	emitter(funnel, {
		texture = TEX.debris,
		color = ColorSequence.new(L.leaf, L.dust),
		size = seq(0, 0.4, 1, 0.3),
		lifetime = NumberRange.new(0.6, 1.2),
		speed = NumberRange.new(8, 12),
		rotSpeed = NumberRange.new(-500, 500),
		shape = Enum.ParticleEmitterShape.Cylinder,
		acceleration = Vector3.new(0, 14, 0),
		emission = 0,
		rate = 30,
	})
	v.update = function(vis, _dt)
		funnel.CFrame = CFrame.new(vis.root.Position + UP * 6) * CFrame.Angles(0, os.clock() * 10, 0)
	end
end

BUILD.updraft = function(v)
	local radius = (v.part:GetAttribute("Radius") :: number?) or 4
	v.fixed = true
	own(v, flatDisc(v.root.Position, radius, L.wind, 0.75))
	v.root.Shape = Enum.PartType.Cylinder
	v.root.Size = Vector3.new(1, radius * 1.8, radius * 1.8)
	v.root.CFrame = v.root.CFrame * CFrame.Angles(0, 0, math.rad(90))
	emitter(v.root, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.wind),
		size = seq(0, 0.8, 1, 1.6),
		transparency = seq(0, 0.5, 1, 1),
		lifetime = NumberRange.new(1.2, 1.8),
		speed = NumberRange.new(14, 20),
		direction = Enum.NormalId.Right, -- the cylinder's axis, turned up
		emission = 0.2,
		rate = 30,
	})
	emitter(v.root, {
		texture = TEX.debris,
		color = ColorSequence.new(L.leaf),
		size = seq(0, 0.3, 1, 0.2),
		lifetime = NumberRange.new(1.2, 1.8),
		speed = NumberRange.new(12, 18),
		direction = Enum.NormalId.Right,
		rotSpeed = NumberRange.new(-300, 300),
		emission = 0,
		rate = 8,
	})
	-- Riding it: the server only pushes NPCs; our own character is carried here, on the client that
	-- owns its physics. In freefall (a standing Humanoid pins itself to the ground), rising at
	-- RiseSpeed to Height above the base, then hovering there while you stay in the column.
	local base = v.part.Position
	local height = (v.part:GetAttribute("Height") :: number?) or 30
	local rise = (v.part:GetAttribute("RiseSpeed") :: number?) or 42
	v.update = function(_vis, _dt)
		local character = localPlayer and localPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if not character or not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") or root.Anchored then
			return
		end
		if character:GetAttribute("GravityFlight") or character:GetAttribute("TravelStyle") or character:GetAttribute("GravityHeld") then
			return
		end
		local rel = root.Position - base
		if Vector3.new(rel.X, 0, rel.Z).Magnitude > radius or rel.Y < -3 or rel.Y > height + 6 then
			return
		end
		local state = humanoid:GetState()
		if state ~= Enum.HumanoidStateType.Freefall and state ~= Enum.HumanoidStateType.Jumping then
			humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
		end
		-- Slow down near the top and hover: a gentle bob instead of overshooting.
		local left = height - rel.Y
		local want = if left > 4 then rise else math.clamp(left * 4, -6, rise) + math.sin(os.clock() * 3) * 1.5
		local vel = root.AssemblyLinearVelocity
		root.AssemblyLinearVelocity = Vector3.new(vel.X, want, vel.Z)
	end
end

BUILD.tailwind = function(v)
	v.root.Size = Vector3.new(3, 4, 3)
	emitter(v.root, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.wind),
		size = seq(0, 0.6, 1, 1.4),
		transparency = seq(0, 0.6, 1, 1),
		lifetime = NumberRange.new(0.3, 0.5),
		speed = NumberRange.new(2, 4),
		emission = 0.2,
		rate = 20,
	})
end

BUILD.windwall = function(v)
	v.fixed = true
	local sheet = own(v, part({
		Size = v.part.Size,
		CFrame = v.part.CFrame,
		Color = L.wind,
		Material = Enum.Material.ForceField,
		Transparency = 0.5,
	}))
	emitter(sheet, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.wind, L.windEdge),
		size = seq(0, 1, 1, 2.5),
		transparency = seq(0, 0.5, 1, 1),
		lifetime = NumberRange.new(0.5, 0.8),
		speed = NumberRange.new(8, 12),
		direction = Enum.NormalId.Right,
		emission = 0.2,
		rate = 50,
	})
end

BUILD.raincloud = function(v)
	local cloud = own(v, part({ Transparency = 1, Size = Vector3.new(5, 1.5, 5) }))
	emitter(cloud, {
		texture = TEX.smoke,
		color = ColorSequence.new(L.cloud),
		size = seq(0, 2.5, 1, 3.5),
		transparency = seq(0, 0.2, 1, 1),
		lifetime = NumberRange.new(1, 1.6),
		speed = NumberRange.new(0.2, 0.8),
		emission = 0,
		rate = 16,
	})
	emitter(cloud, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.rain),
		size = seq(0, 0.15, 1, 0.1),
		transparency = seq(0, 0.2, 1, 0.5),
		lifetime = NumberRange.new(0.35, 0.45),
		speed = NumberRange.new(18, 22),
		direction = Enum.NormalId.Bottom,
		emission = 0.3,
		rate = 50,
	})
	v.update = function(vis, _dt)
		cloud.CFrame = CFrame.new(vis.root.Position + UP * 5.5)
	end
end

A.register(BUILD)

A.registerFlights({
	windblade = function(anchor: Part, coreSize: number)
		anchor.Shape = Enum.PartType.Block
		anchor.Size = Vector3.new(2.6, 0.12, 0.8) * math.max(1, coreSize)
		anchor.Material = Enum.Material.Neon
		anchor.Color = L.wind
		anchor.Transparency = 0.4
		local e = FxLayers.emitter(anchor, {
			texture = TEX.wisp,
			color = ColorSequence.new(L.wind),
			size = seq(0, 1, 1, 2),
			transparency = seq(0, 0.6, 1, 1),
			lifetime = NumberRange.new(0.2, 0.35),
			speed = NumberRange.new(0.5, 1.5),
			emission = 0.2,
			rate = rate(40),
		})
		if e then
			e.Enabled = true
		end
		return function()
			if e then
				e.Enabled = false
			end
		end, 0
	end,
})

return AirFx
