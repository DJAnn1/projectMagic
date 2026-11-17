--!strict
--[[
	SpiritFx: what Spirit's spells look like (docs/DomainIdeas.md, "Spirit"). Cosmetic only: the server
	(Effects/SpiritArt, Cast/ArtRuntime) decides everything. Spirit reads as runes and pale light: golden
	sigils for wards, violet for curses, cold blue for souls and the dead.

		SpiritFx.cue(effect)   one-shot "spirit" WorldEffect cues, by `fx`:
		    glyph_stop  a bolt stopping on a rune ring    sigil_burst  a trap's sigil going off
		    mirror      a bolt turned home                 doom         a doom mark landing
		    thorns      a thorn curse biting               chains       chains rising round someone
		    grave_hand  a bony hand from the ground         ghost        you fading half out of the world
		    wail        a scream rippling out
		Bodies (Fx/ArtFx, by ArtLook): glyph_shield, sigil_trap, hallowed_ground, mirror_ward, doom_mark,
		    ill_luck, thorn_curse, soul_tether, shared_fate, spirit_wolves, grave_mist.
]]

local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage").Shared
local E = require(Shared.Magic.Data.SpiritTuning)

local DomainFx = require(script.Parent.DomainFx)
local FxLayers = require(script.Parent.FxLayers)
local A = require(script.Parent.ArtFx)

local TEX = DomainFx.textures
local L = E.looks
local UP = Vector3.new(0, 1, 0)

local part, seq, emitter = A.part, A.seq, A.emitter
local burst, fadeOut, rootOf, flatDisc, linked = A.burst, A.fadeOut, A.rootOf, A.flatDisc, A.linked
local own = A.own
type Visual = A.Visual

local SpiritFx = {}


local function sound(position: Vector3, property: string, which: string, volume: number?)
	A.sound(position, "spirit", property, which, volume)
end

local function motes(at: Vector3, color: Color3, count: number)
	burst(at, {
		texture = TEX.mote,
		color = ColorSequence.new(color),
		size = seq(0, 0.5, 1, 0),
		lifetime = NumberRange.new(0.6, 1.1),
		speed = NumberRange.new(2, 7),
		spread = 180,
		acceleration = Vector3.new(0, 3, 0),
	}, count)
end

-- A flat rune disc: the decal-less look of a sigil (a neon ring with a pale centre).
local function runeDisc(at: Vector3, radius: number, color: Color3, transparency: number): (Part, Part)
	local ring = flatDisc(at + UP * 0.05, radius, color, transparency)
	local inner = flatDisc(at + UP * 0.07, radius * 0.7, L.hexDark, 0.6, Enum.Material.SmoothPlastic)
	return ring, inner
end

-- ─── One-shot cues ──────────────────────────────────────────────────────────

local function chains(cue: any)
	local root = rootOf(cue.model)
	if not root then
		return
	end
	local seconds = math.clamp(tonumber(cue.seconds) or 2, 0.5, 4)
	for i = 1, 4 do
		local angle = i / 4 * math.pi * 2
		local base = root.Position - UP * 2.8 + Vector3.new(math.cos(angle) * 3, 0, math.sin(angle) * 3)
		local links: { BasePart } = {}
		for k = 1, 6 do
			local t = k / 6
			local p = base:Lerp(root.Position, t)
			table.insert(links, part({
				Shape = Enum.PartType.Cylinder,
				Size = Vector3.new(0.2, 0.55, 0.55),
				CFrame = CFrame.lookAt(p, root.Position) * CFrame.Angles(0, if k % 2 == 0 then math.rad(90) else 0, 0),
				Color = L.chain,
				Transparency = 0.15,
			}))
		end
		task.delay(seconds, function()
			for _, l in links do
				fadeOut(l, 0.3)
			end
		end)
	end
	motes(root.Position, L.chain, 14)
	sound(root.Position, "bond", "impact", 0.7)
end

local function graveHand(cue: any)
	local root = rootOf(cue.model)
	if not root then
		return
	end
	local seconds = math.clamp(tonumber(cue.seconds) or 1.5, 0.5, 4)
	local feet = root.Position - UP * 3
	local fingers: { BasePart } = {}
	for i = 1, 5 do
		local angle = i / 5 * math.pi * 1.6 - 0.8
		local p = part({
			Size = Vector3.new(0.35, 2.4, 0.35),
			Color = L.bone,
			Material = Enum.Material.SmoothPlastic,
		})
		local base = feet + Vector3.new(math.cos(angle) * 1.4, 0, math.sin(angle) * 1.4)
		local cf = CFrame.lookAt(base, root.Position) * CFrame.Angles(math.rad(-60), 0, 0)
		FxLayers.animate(0.2, function(t)
			p.CFrame = cf * CFrame.new(0, -1.2 + 1.4 * t, 0)
		end)
		table.insert(fingers, p)
	end
	burst(feet, {
		texture = TEX.dust,
		color = ColorSequence.new(Color3.fromRGB(90, 75, 60)),
		size = seq(0, 1.2, 1, 2.4),
		transparency = seq(0, 0.4, 1, 1),
		lifetime = NumberRange.new(0.6, 1),
		speed = NumberRange.new(2, 6),
		spread = 60,
		emission = 0,
	}, 12)
	task.delay(seconds, function()
		for _, f in fingers do
			fadeOut(f, 0.3)
		end
	end)
	sound(feet, "unlife", "impact", 0.8)
end

local function ghost(cue: any)
	local model = cue.model
	local root = rootOf(model)
	if not root then
		return
	end
	local seconds = math.clamp(tonumber(cue.seconds) or 2.5, 0.5, 6)
	local h = Instance.new("Highlight")
	h.FillColor = L.ghost
	h.FillTransparency = 0.55
	h.OutlineColor = L.soul
	h.OutlineTransparency = 0.2
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Parent = model
	Debris:AddItem(h, seconds)
	motes(root.Position, L.ghost, 20)
end

local function wail(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 10
	for k = 0, 2 do
		task.delay(k * 0.12, function()
			FxLayers.shockwave(at + UP * (1 + k), UP, radius * (0.6 + k * 0.2), L.soul, 0.45)
		end)
	end
	burst(at + UP * 2, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.ghost, L.soul),
		size = seq(0, 1.5, 1, 3),
		transparency = seq(0, 0.5, 1, 1),
		lifetime = NumberRange.new(0.6, 1),
		speed = NumberRange.new(radius, radius * 1.6),
		spread = 180,
		emission = 0.4,
	}, 30)
	sound(at, "soul", "launch", 1)
end

local function doom(cue: any)
	local at: Vector3 = cue.at
	local hits = tonumber(cue.hits) or 0
	FxLayers.flash(at, 2 + hits * 0.3, L.hex, 0.3)
	FxLayers.shockwave(at, UP, 4 + hits * 0.8, L.hex, 0.4)
	burst(at, {
		texture = TEX.implode,
		color = ColorSequence.new(L.hex, L.hexDark),
		size = seq(0, 2, 1, 0.2),
		lifetime = NumberRange.new(0.4, 0.6),
		speed = NumberRange.new(1, 3),
		spread = 180,
		emission = 0.3,
	}, 12 + hits * 3)
	sound(at, "malediction", "impact", 1)
end

local CUES: { [string]: (any) -> () } = {
	glyph_stop = function(cue: any)
		motes(cue.at, L.rune, 14)
		FxLayers.flash(cue.at, 1.2, L.rune, 0.2)
	end,
	sigil_burst = function(cue: any)
		FxLayers.shockwave(cue.at, UP, (cue.radius or 4) * 2, L.rune, 0.4)
		FxLayers.flash(cue.at + UP, 2.5, L.rune, 0.25)
		motes(cue.at + UP, L.rune, 24)
		sound(cue.at, "warding", "impact", 0.9)
	end,
	mirror = function(cue: any)
		FxLayers.flash(cue.at, 1.4, L.chain, 0.2)
		motes(cue.at, L.chain, 10)
	end,
	doom = doom,
	thorns = function(cue: any)
		burst(cue.at, {
			texture = TEX.shard,
			color = ColorSequence.new(L.hex),
			size = seq(0, 0.6, 1, 0),
			lifetime = NumberRange.new(0.3, 0.6),
			speed = NumberRange.new(6, 12),
			spread = 180,
		}, 10)
	end,
	chains = chains,
	grave_hand = graveHand,
	ghost = ghost,
	wail = wail,
}

function SpiritFx.cue(cue: { [string]: any })
	local fn = CUES[cue.fx]
	if not fn then
		return
	end
	local ok, err = pcall(fn, cue)
	if not ok then
		warn("[SpiritFx] " .. tostring(cue.fx) .. ": " .. tostring(err))
	end
end

-- ─── Lasting bodies (drawn by Fx/ArtFx) ─────────────────────────────────────

local BUILD: { [string]: (Visual) -> () } = {}

local function radiusOf(v: Visual, default: number): number
	return (v.part:GetAttribute("Radius") :: number?) or default
end

BUILD.glyph_shield = function(v)
	v.fixed = true
	local frame = v.part.CFrame
	local size = v.part.Size
	local pane = own(v, part({
		Size = Vector3.new(size.X, size.Y, 0.15),
		CFrame = frame,
		Color = L.rune,
		Material = Enum.Material.ForceField,
		Transparency = 0.45,
	}))
	-- Runes drifting on its face.
	emitter(pane, {
		texture = TEX.rune,
		color = ColorSequence.new(L.rune),
		size = seq(0, 1, 1, 0.6),
		transparency = seq(0, 0.3, 1, 1),
		lifetime = NumberRange.new(0.8, 1.4),
		speed = NumberRange.new(0.2, 0.6),
		emission = 1,
		rate = 14,
	})
end

BUILD.sigil_trap = function(v)
	v.fixed = true
	local radius = radiusOf(v, 4)
	local ring, inner = runeDisc(v.root.Position, radius, L.rune, 0.4)
	own(v, ring)
	own(v, inner)
	v.update = function(_vis, _dt)
		ring.Transparency = 0.45 + math.sin(os.clock() * 2) * 0.15
	end
end

BUILD.hallowed_ground = function(v)
	v.fixed = true
	local radius = radiusOf(v, 8)
	own(v, flatDisc(v.root.Position, radius, L.holy, 0.65))
	v.root.Size = Vector3.new(radius * 1.5, 0.5, radius * 1.5)
	emitter(v.root, {
		texture = TEX.mote,
		color = ColorSequence.new(L.holy, L.rune),
		size = seq(0, 0.4, 1, 0),
		lifetime = NumberRange.new(1.5, 2.5),
		speed = NumberRange.new(1, 3),
		acceleration = Vector3.new(0, 2, 0),
		emission = 1,
		rate = 20,
	})
	local light = Instance.new("PointLight")
	light.Color = L.holy
	light.Range = math.min(30, radius * 2)
	light.Brightness = 1.2
	light.Parent = v.root
end

BUILD.mirror_ward = function(v)
	local shards: { BasePart } = {}
	for _ = 1, 5 do
		table.insert(shards, own(v, part({ Size = Vector3.new(0.9, 1.4, 0.1), Color = L.chain, Material = Enum.Material.Glass, Transparency = 0.25, Reflectance = 0.6 })))
	end
	v.update = function(vis, _dt)
		local t = os.clock()
		for i, shard in shards do
			local angle = t * 1.6 + i / #shards * math.pi * 2
			local at = vis.root.Position + Vector3.new(math.cos(angle) * 3, math.sin(t * 2 + i) * 0.5, math.sin(angle) * 3)
			shard.CFrame = CFrame.lookAt(at, vis.root.Position)
		end
	end
end

BUILD.doom_mark = function(v)
	local seal = own(v, part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.1, 2.2, 2.2),
		Color = L.hex,
		Transparency = 0.25,
	}))
	v.update = function(vis, _dt)
		local hits = (vis.part:GetAttribute("Hits") :: number?) or 0
		local s = 2.2 + hits * 0.25
		seal.Size = Vector3.new(0.1, s, s)
		seal.CFrame = CFrame.new(vis.root.Position + UP * 4.2) * CFrame.Angles(0, os.clock() * 2, math.rad(90))
	end
end

BUILD.ill_luck = function(v)
	v.root.Shape = Enum.PartType.Ball
	v.root.Size = Vector3.one * 8
	emitter(v.root, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.hexDark, L.hex),
		size = seq(0, 1, 1, 2),
		transparency = seq(0, 0.6, 1, 1),
		lifetime = NumberRange.new(0.8, 1.2),
		speed = NumberRange.new(1, 3),
		shape = Enum.ParticleEmitterShape.Sphere,
		emission = 0,
		influence = 1,
		rate = 18,
	})
end

BUILD.thorn_curse = function(v)
	local thorns: { BasePart } = {}
	for _ = 1, 6 do
		table.insert(thorns, own(v, part({ Size = Vector3.new(0.15, 0.15, 1.2), Color = L.hex })))
	end
	v.update = function(vis, _dt)
		local t = os.clock()
		for i, thorn in thorns do
			local angle = -t * 1.2 + i / #thorns * math.pi * 2
			local at = vis.root.Position + Vector3.new(math.cos(angle) * 1.8, -0.5 + (i % 2), math.sin(angle) * 1.8)
			thorn.CFrame = CFrame.lookAt(at, vis.root.Position)
		end
	end
end

local function beamBetween(v: Visual, color: Color3, width: number, curve: number)
	local a = linked(v.part, "A")
	local b = linked(v.part, "B")
	if not (a and a:IsA("BasePart") and b and b:IsA("BasePart")) then
		return
	end
	local a0 = own(v, Instance.new("Attachment"))
	a0.Parent = a
	local a1 = own(v, Instance.new("Attachment"))
	a1.Parent = b
	local beam = Instance.new("Beam")
	beam.Attachment0, beam.Attachment1 = a0, a1
	beam.Color = ColorSequence.new(color)
	beam.LightEmission = 1
	beam.Width0, beam.Width1 = width, width
	beam.FaceCamera = true
	beam.Segments = 12
	beam.CurveSize0, beam.CurveSize1 = curve, -curve
	beam.Transparency = seq(0, 0.2, 1, 0.2)
	beam.Parent = a0
end

BUILD.soul_tether = function(v)
	beamBetween(v, L.soul, 0.35, 1.5)
end

BUILD.shared_fate = function(v)
	beamBetween(v, L.rune, 0.25, 0.8)
end

BUILD.spirit_wolves = function(v)
	local count = math.clamp((v.part:GetAttribute("Count") :: number?) or 3, 1, 5)
	local wolves: { any } = {}
	for i = 1, count do
		local body = own(v, part({ Size = Vector3.new(1.2, 1.1, 2.6), Color = L.ghost, Transparency = 0.45 }))
		local head = own(v, part({ Size = Vector3.new(0.9, 0.8, 1.1), Color = L.soul, Transparency = 0.35 }))
		local angle = i / count * math.pi * 2
		table.insert(wolves, { body = body, head = head, offset = Vector3.new(math.cos(angle) * 2.2, 0, math.sin(angle) * 2.2) })
	end
	v.root.Size = Vector3.new(4, 2, 4)
	emitter(v.root, {
		texture = TEX.wisp,
		color = ColorSequence.new(L.ghost),
		size = seq(0, 1, 1, 2),
		transparency = seq(0, 0.6, 1, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(0.5, 1.5),
		emission = 0.5,
		rate = 20,
	})
	v.extra.last = v.root.Position
	v.update = function(vis, _dt)
		local pos = vis.root.Position
		local moved = pos - (vis.extra.last :: Vector3)
		vis.extra.last = pos
		local dir = Vector3.new(moved.X, 0, moved.Z)
		if dir.Magnitude > 0.01 then
			vis.extra.dir = dir.Unit
		end
		local facing: Vector3 = vis.extra.dir or Vector3.new(0, 0, -1)
		local t = os.clock()
		for i, w in wolves do
			local bob = math.abs(math.sin(t * 9 + i)) * 0.5
			local at = pos + w.offset + Vector3.new(0, 0.9 + bob, 0)
			local frame = CFrame.lookAt(at, at + facing)
			w.body.CFrame = frame
			w.head.CFrame = frame * CFrame.new(0, 0.4, -1.6)
		end
	end
end

BUILD.grave_mist = function(v)
	v.fixed = true
	local radius = radiusOf(v, 8)
	v.root.Size = Vector3.new(radius * 1.6, 3, radius * 1.6)
	emitter(v.root, {
		texture = TEX.smoke,
		color = ColorSequence.new(L.mist),
		size = seq(0, 4, 1, 8),
		transparency = seq(0, 0.35, 0.6, 0.45, 1, 1),
		lifetime = NumberRange.new(2.5, 3.5),
		speed = NumberRange.new(0.3, 1),
		spread = 80,
		emission = 0,
		rate = 16,
	})
end

A.register(BUILD)


return SpiritFx
