--!strict
--[[
	VoidFx: what Void's spells look like (docs/DomainIdeas.md, "Void"). Cosmetic only: the server
	(Effects/VoidArt, Cast/ArtRuntime) decides everything. Void reads as absence: black cores with a pale
	violet rim, light bending inward, things coming apart into threads.

		VoidFx.cue(effect)   one-shot "void" WorldEffect cues, by `fx`:
		    null      a black pop on someone               unravel  a beam of unmaking
		    unmade    something coming apart into threads   hush     sound draining away from someone
		    fizzle    a bolt dying in grounded air         swallow  a bolt sucked into nothing
		    step      out of one shadow, into another      collapse a tear closing on itself
		    black_flame  cold black fire on someone        unseen   you fading from view
		Bodies (Fx/ArtFx, by ArtLook): antimagic_shell, null_ground, black_sun, ground_out, sponge,
		    hungry_mouth, rift_mote.
]]

local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage").Shared
local E = require(Shared.Magic.Data.VoidTuning)

local DomainFx = require(script.Parent.DomainFx)
local FxLayers = require(script.Parent.FxLayers)
local A = require(script.Parent.ArtFx)

local TEX = DomainFx.textures
local L = E.looks
local UP = Vector3.new(0, 1, 0)

local part, seq, emitter = A.part, A.seq, A.emitter
local burst, fadeOut, rootOf, flatDisc = A.burst, A.fadeOut, A.rootOf, A.flatDisc
local own = A.own
type Visual = A.Visual

local VoidFx = {}


local function sound(position: Vector3, property: string, which: string, volume: number?)
	A.sound(position, "void", property, which, volume)
end

local function implodeAt(at: Vector3, size: number, count: number)
	local p = part({ Shape = Enum.PartType.Ball, Transparency = 1, Size = Vector3.one * size * 2, CFrame = CFrame.new(at) })
	local e = emitter(p, {
		texture = TEX.implode,
		color = ColorSequence.new(L.rim, L.void),
		size = seq(0, size * 0.6, 1, 0.1),
		transparency = seq(0, 0.2, 1, 0.6),
		lifetime = NumberRange.new(0.35, 0.5),
		speed = NumberRange.new(size * 2.5),
		shape = Enum.ParticleEmitterShape.Sphere,
		emission = 0.4,
	})
	e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward
	e.Rate = 0
	e:Emit(math.floor(A.rate(count)))
	Debris:AddItem(p, 1)
end

local function blackPop(at: Vector3, size: number)
	FxLayers.flash(at, size, L.void, 0.3, true)
	FxLayers.shockwave(at, UP, size * 1.6, L.rim, 0.3)
end

-- ─── One-shot cues ──────────────────────────────────────────────────────────

local function threads(at: Vector3, count: number)
	burst(at, {
		texture = TEX.streak ~= "" and TEX.streak or TEX.wisp,
		color = ColorSequence.new(L.thread, L.rim),
		size = seq(0, 0.25, 1, 0.05),
		transparency = seq(0, 0.1, 1, 1),
		lifetime = NumberRange.new(0.6, 1.1),
		speed = NumberRange.new(2, 7),
		spread = 180,
		rotSpeed = NumberRange.new(-200, 200),
		acceleration = Vector3.new(0, 3, 0),
		emission = 0.6,
	}, count)
end

local function null(cue: any)
	blackPop(cue.at, 2)
	threads(cue.at, 16)
	sound(cue.at, "aether", "impact", 0.7)
end

local function unravel(cue: any)
	local from: Vector3 = cue.from
	local to: Vector3 = cue.to
	local d = to - from
	local core = part({
		Size = Vector3.new(0.6, 0.6, d.Magnitude),
		CFrame = CFrame.lookAt(from + d / 2, to),
		Color = L.void,
		Material = Enum.Material.SmoothPlastic,
		Transparency = 0.1,
	})
	local rim = part({
		Size = Vector3.new(1.2, 1.2, d.Magnitude),
		CFrame = core.CFrame,
		Color = L.rim,
		Transparency = 0.7,
	})
	fadeOut(core, 0.5, Vector3.new(0.05, 0.05, d.Magnitude))
	fadeOut(rim, 0.5, Vector3.new(2.4, 2.4, d.Magnitude))
	sound(from, "aether", "launch", 0.8)
end

local function hush(cue: any)
	local root = rootOf(cue.model)
	if not root then
		return
	end
	implodeAt(root.Position + UP, 3, 24)
end

local function fizzle(cue: any)
	burst(cue.at, {
		texture = TEX.crackle,
		color = ColorSequence.new(L.pale, L.void),
		size = seq(0, 0.6, 1, 0),
		lifetime = NumberRange.new(0.2, 0.4),
		speed = NumberRange.new(1, 4),
		spread = 180,
		emission = 0.3,
	}, 12)
end

local function swallow(cue: any)
	implodeAt(cue.at, 2, 20)
	blackPop(cue.at, 1.2)
	sound(cue.at, "essence", "impact", 0.6)
end

local function step(cue: any)
	local from: Vector3 = cue.from
	local to: Vector3 = cue.to
	for _, at in { from, to } do
		burst(at, {
			texture = TEX.smoke,
			color = ColorSequence.new(L.void, L.rim),
			size = seq(0, 2, 1, 4),
			transparency = seq(0, 0.2, 1, 1),
			lifetime = NumberRange.new(0.5, 0.9),
			speed = NumberRange.new(2, 6),
			spread = 180,
			emission = 0,
			box = Vector3.new(2, 4, 2),
		}, 20)
	end
	sound(from, "presence", "launch", 0.7)
end

local function collapse(cue: any)
	implodeAt(cue.at, cue.radius or 4, 40)
	task.delay(0.2, function()
		blackPop(cue.at, cue.radius or 4)
	end)
	sound(cue.at, "presence", "impact", 1)
end

local function blackFlame(cue: any)
	local root = rootOf(cue.model)
	if not root then
		return
	end
	local p = part({ Transparency = 1, Size = Vector3.new(2, 4, 2), CFrame = root.CFrame })
	local e = emitter(p, {
		texture = TEX.fire,
		color = ColorSequence.new(L.void, L.rim),
		size = seq(0, 1.6, 1, 0.3),
		transparency = seq(0, 0.05, 1, 1),
		lifetime = NumberRange.new(0.4, 0.7),
		speed = NumberRange.new(2, 4),
		emission = 0,
		influence = 1,
		rate = 50,
	})
	e.LightInfluence = 1
	FxLayers.animate(1.4, function(_t)
		local rr = rootOf(cue.model)
		if rr then
			p.CFrame = rr.CFrame
		end
	end, function()
		e.Enabled = false
		Debris:AddItem(p, 0.8)
	end)
	sound(root.Position, "presence", "impact", 0.8)
end

local function unseen(cue: any)
	implodeAt(cue.at, 2.5, 18)
end

local CUES: { [string]: (any) -> () } = {
	null = null,
	unmade = function(cue: any)
		threads(cue.at, 24)
		blackPop(cue.at, 1.5)
	end,
	unravel = unravel,
	hush = hush,
	fizzle = fizzle,
	swallow = swallow,
	step = step,
	collapse = collapse,
	black_flame = blackFlame,
	unseen = unseen,
}

function VoidFx.cue(cue: { [string]: any })
	local fn = CUES[cue.fx]
	if not fn then
		return
	end
	local ok, err = pcall(fn, cue)
	if not ok then
		warn("[VoidFx] " .. tostring(cue.fx) .. ": " .. tostring(err))
	end
end

-- ─── Lasting bodies (drawn by Fx/ArtFx) ─────────────────────────────────────

local BUILD: { [string]: (Visual) -> () } = {}

local function radiusOf(v: Visual, default: number): number
	return (v.part:GetAttribute("Radius") :: number?) or default
end

-- A black sphere with a pale rim: the shape of an absence.
local function hole(v: Visual, size: number): (BasePart, BasePart)
	local core = own(v, part({ Shape = Enum.PartType.Ball, Size = Vector3.one * size, Color = L.void, Material = Enum.Material.SmoothPlastic }))
	local rim = own(v, part({ Shape = Enum.PartType.Ball, Size = Vector3.one * size * 1.35, Color = L.rim, Material = Enum.Material.ForceField, Transparency = 0.4 }))
	return core, rim
end

BUILD.antimagic_shell = function(v)
	local shell = own(v, part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 6.2, Color = L.void, Material = Enum.Material.ForceField, Transparency = 0.35 }))
	v.update = function(vis, _dt)
		shell.CFrame = CFrame.new(vis.root.Position) * CFrame.Angles(0, os.clock(), 0)
	end
end

BUILD.null_ground = function(v)
	local radius = radiusOf(v, 8)
	v.fixed = true
	own(v, flatDisc(v.root.Position, radius, L.void, 0.25, Enum.Material.SmoothPlastic))
	own(v, flatDisc(v.root.Position + UP * 0.02, radius + 0.6, L.rim, 0.6))
	v.root.Size = Vector3.new(radius * 1.5, 0.5, radius * 1.5)
	emitter(v.root, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.void),
		size = seq(0, 1, 1, 2),
		transparency = seq(0, 0.5, 1, 1),
		lifetime = NumberRange.new(1, 1.6),
		speed = NumberRange.new(0.5, 1.5),
		acceleration = Vector3.new(0, 1, 0),
		emission = 0,
		influence = 1,
		rate = 14,
	})
end

BUILD.black_sun = function(v)
	local radius = radiusOf(v, 9)
	local height = (v.part:GetAttribute("Height") :: number?) or 18
	v.fixed = true
	local core, rim = hole(v, math.max(4, radius * 0.5))
	core.CFrame = CFrame.new(v.root.Position + UP * height)
	rim.CFrame = core.CFrame
	own(v, part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, radius * 2, radius * 2),
		CFrame = CFrame.new(v.root.Position + UP * height / 2) * CFrame.Angles(0, 0, math.rad(90)),
		Color = L.void,
		Material = Enum.Material.SmoothPlastic,
		Transparency = 0.82,
	}))
	own(v, flatDisc(v.root.Position, radius, L.void, 0.5, Enum.Material.SmoothPlastic))
	emitter(core, {
		texture = TEX.sparkles,
		color = ColorSequence.new(Color3.fromRGB(220, 235, 255)),
		size = seq(0, 0.25, 1, 0.1),
		lifetime = NumberRange.new(1.4, 2),
		speed = NumberRange.new(4, 7),
		spread = 50,
		direction = Enum.NormalId.Bottom,
		emission = 0.3,
		rate = 20,
	})
end

BUILD.ground_out = function(v)
	local radius = radiusOf(v, 9)
	v.fixed = true
	own(v, flatDisc(v.root.Position, radius, Color3.fromRGB(60, 60, 70), 0.55, Enum.Material.Slate))
	v.root.Size = Vector3.new(radius * 1.5, 0.5, radius * 1.5)
	emitter(v.root, {
		texture = TEX.crackle,
		color = ColorSequence.new(L.pale, Color3.fromRGB(90, 90, 110)),
		size = seq(0, 0.3, 1, 0),
		lifetime = NumberRange.new(0.15, 0.3),
		speed = NumberRange.new(0.5, 2),
		emission = 0.2,
		rate = 10,
	})
end

BUILD.sponge = function(v)
	local orb = own(v, part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 1.2, Color = L.void, Material = Enum.Material.SmoothPlastic }))
	emitter(orb, {
		texture = TEX.implode,
		color = ColorSequence.new(L.rim, L.void),
		size = seq(0, 1.6, 1, 0.2),
		transparency = seq(0, 0.4, 1, 1),
		lifetime = NumberRange.new(0.4),
		emission = 0.3,
		rate = 10,
	})
	v.update = function(vis, _dt)
		local root = vis.model and rootOf(vis.model)
		local hand = vis.model and A.limb(vis.model, { "Right Arm", "RightHand" })
		if hand then
			orb.CFrame = hand.CFrame * CFrame.new(0, -hand.Size.Y / 2 - 0.6, 0)
		elseif root then
			orb.CFrame = root.CFrame * CFrame.new(1.5, 0, -1)
		end
	end
end

BUILD.hungry_mouth = function(v)
	local core, rim = hole(v, 1.4)
	local radius = radiusOf(v, 7)
	emitter(core, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.rim, L.void),
		size = seq(0, 1.6, 1, 0.2),
		transparency = seq(0, 0.6, 1, 0.2),
		lifetime = NumberRange.new(0.6, 0.9),
		emission = 0.2,
		rate = 0,
	})
	local swirl = own(v, part({ Shape = Enum.PartType.Ball, Transparency = 1, Size = Vector3.one * radius * 2 }))
	local e = emitter(swirl, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.rim, L.void),
		size = seq(0, 1.2, 1, 0.2),
		transparency = seq(0, 0.7, 1, 0.3),
		lifetime = NumberRange.new(0.7),
		speed = NumberRange.new(radius * 1.4),
		shape = Enum.ParticleEmitterShape.Sphere,
		emission = 0.2,
		rate = 30,
	})
	e.ShapeInOut = Enum.ParticleEmitterShapeInOut.Inward
	v.update = function(vis, _dt)
		local wobble = 1 + math.sin(os.clock() * 7) * 0.08
		core.CFrame = CFrame.new(vis.root.Position)
		rim.CFrame = core.CFrame
		rim.Size = Vector3.one * 1.9 * wobble
		swirl.CFrame = core.CFrame
	end
end

BUILD.rift_mote = function(v)
	local tear = own(v, part({ Size = Vector3.new(0.3, 3.4, 1.2), Color = L.void, Material = Enum.Material.SmoothPlastic }))
	local glow = own(v, part({ Size = Vector3.new(0.5, 3.8, 1.6), Color = L.rim, Transparency = 0.5 }))
	v.update = function(vis, _dt)
		local t = os.clock()
		local frame = CFrame.new(vis.root.Position) * CFrame.Angles(0, t * 0.6, math.sin(t * 5) * 0.15)
		tear.CFrame = frame
		glow.CFrame = frame
		local s = 1 + math.sin(t * 9) * 0.1
		tear.Size = Vector3.new(0.3, 3.4 * s, 1.2 * s)
	end
	implodeAt(v.root.Position, radiusOf(v, 7), 30)
end

A.register(BUILD)


return VoidFx
