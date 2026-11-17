--!strict
--[[
	EarthFx: what Earth's spells look like (docs/DomainIdeas.md, "Earth"). Cosmetic only: the server
	(Effects/EarthArt, Cast/ArtRuntime) decides everything, and raises the real stone itself (spikes,
	steps, ramps, spires are server parts). Three ways in:

		EarthFx.cue(effect)   one-shot "earth" WorldEffect cues, by `fx`:
		    rubble   stone and dust bursting up            gravel  the ground bursting into flying stones
		    spikes   dust where each spike breaks through  grip    stone climbing someone's legs
		    blades_warn  glinting marks where blades will fall   blades  the blades falling
		    lash     liquid metal sweeping an arc           spires / spires_shatter  crystals up, then bursting
		    shard_ring  a stuck shard ringing               prison  a crystal shell round someone
		    fissure  a glowing crack running along the ground   ripple  a ring of heaving ground
		    sandblast  a cone of sand
		Bodies (Fx/ArtFx, by ArtLook): boulder, iron_storm, geode_shell, dust_cloud, quicksand, dust_devil,
		    sand_shroud.
		Bolt looks (ArtFx.flight): fist (a lump of rock), boulder, shard (a crystal).
]]

local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage").Shared
local E = require(Shared.Magic.Data.EarthTuning)

local DomainFx = require(script.Parent.DomainFx)
local FxLayers = require(script.Parent.FxLayers)
local A = require(script.Parent.ArtFx)

local TEX = DomainFx.textures
local L = E.looks
local UP = Vector3.new(0, 1, 0)

local reduced, rate, part, seq, emitter = A.reduced, A.rate, A.part, A.seq, A.emitter
local burst, fadeOut, rootOf, flatDisc = A.burst, A.fadeOut, A.rootOf, A.flatDisc
local own = A.own
type Visual = A.Visual

local EarthFx = {}

local rng = Random.new()

local function sound(position: Vector3, property: string, which: string, volume: number?)
	A.sound(position, "earth", property, which, volume)
end

local function dust(at: Vector3, size: number, count: number, color: Color3?)
	burst(at, {
		texture = TEX.dust,
		color = ColorSequence.new(color or L.dust),
		size = seq(0, size, 1, size * 2.2),
		transparency = seq(0, 0.35, 1, 1),
		lifetime = NumberRange.new(0.7, 1.4),
		speed = NumberRange.new(3, 9),
		spread = 70,
		acceleration = Vector3.new(0, -3, 0),
		drag = 2,
		emission = 0,
	}, count)
end

local function chips(at: Vector3, color: Color3, count: number, speed: number?)
	burst(at, {
		texture = TEX.debris,
		color = ColorSequence.new(color),
		size = seq(0, 0.5, 1, 0.3),
		lifetime = NumberRange.new(0.5, 1),
		speed = NumberRange.new(8, speed or 22),
		spread = 60,
		acceleration = Vector3.new(0, -60, 0),
		emission = 0,
		rotSpeed = NumberRange.new(-300, 300),
	}, count)
end

-- A chunk of rock that flies up and falls back (purely a look).
local function flyingRock(from: Vector3, color: Color3, size: number)
	local rock = part({
		Size = Vector3.one * size,
		CFrame = CFrame.new(from) * CFrame.Angles(rng:NextNumber(0, 6), rng:NextNumber(0, 6), 0),
		Color = color,
		Material = Enum.Material.Slate,
	})
	local v = Vector3.new(rng:NextNumber(-8, 8), rng:NextNumber(18, 30), rng:NextNumber(-8, 8))
	local spin = CFrame.Angles(rng:NextNumber(-6, 6), rng:NextNumber(-6, 6), 0)
	local p = from
	FxLayers.animate(1.1, function(t)
		local time = t * 1.1
		p = from + v * time + Vector3.new(0, -45 * time * time, 0)
		rock.CFrame = CFrame.new(p) * spin:Lerp(CFrame.identity, 1 - t)
	end, function()
		fadeOut(rock, 0.25)
	end)
end

-- ─── One-shot cues ──────────────────────────────────────────────────────────

local function rubble(cue: any)
	local at: Vector3 = cue.at
	local radius = cue.radius or 3
	dust(at, 2 + radius * 0.3, 18)
	chips(at, L.stone, 16)
	if not reduced() then
		for _ = 1, 4 do
			flyingRock(at + Vector3.new(rng:NextNumber(-1, 1), 0.5, rng:NextNumber(-1, 1)), L.stoneDark, rng:NextNumber(0.5, 1.1))
		end
	end
	sound(at, "hardness", "impact", 0.8)
end

local function gravel(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 8
	FxLayers.shockwave(at, UP, radius, L.dust, 0.4)
	burst(at, {
		texture = TEX.debris,
		color = ColorSequence.new(L.stone, L.stoneDark),
		size = seq(0, 0.7, 1, 0.4),
		lifetime = NumberRange.new(0.7, 1.3),
		speed = NumberRange.new(16, 34),
		spread = 35,
		acceleration = Vector3.new(0, -70, 0),
		emission = 0,
		rotSpeed = NumberRange.new(-300, 300),
		box = Vector3.new(radius, 0.5, radius),
	}, 50)
	dust(at, 3, 24)
	if not reduced() then
		for _ = 1, 8 do
			local off = Vector3.new(rng:NextNumber(-radius, radius), 0, rng:NextNumber(-radius, radius)) * 0.7
			flyingRock(at + off, if rng:NextNumber() < 0.5 then L.stone else L.stoneDark, rng:NextNumber(0.5, 1.3))
		end
	end
	sound(at, "cohesion", "impact", 1)
end

local function spikes(cue: any)
	local delay: number = cue.delay or 0.06
	for i, spot in (cue.spots or {}) :: { Vector3 } do
		task.delay(i * delay, function()
			dust(spot, 1.6, 6)
			chips(spot, L.stone, 6, 16)
		end)
	end
	if cue.spots and cue.spots[1] then
		sound(cue.spots[1], "contour", "impact", 0.9)
	end
end

local function grip(cue: any)
	local model = cue.model
	local root = rootOf(model)
	if not root then
		return
	end
	local seconds = math.clamp(tonumber(cue.seconds) or 1.6, 0.5, 4)
	local feet = root.Position - UP * 2.6
	local shell = part({
		Size = Vector3.new(3, 0.2, 3),
		CFrame = CFrame.new(feet),
		Color = L.stone,
		Material = Enum.Material.Slate,
	})
	FxLayers.animate(0.25, function(t)
		shell.Size = Vector3.new(2.8, 0.2 + 2.6 * t, 2.8)
		shell.CFrame = CFrame.new(feet + UP * (shell.Size.Y / 2 - 0.4))
	end)
	task.delay(seconds, function()
		chips(shell.Position, L.stone, 14)
		dust(shell.Position, 1.5, 8)
		shell:Destroy()
	end)
	dust(feet, 1.5, 10)
end

local function bladesWarn(cue: any)
	local delay = tonumber(cue.delay) or 0.9
	for _, spot in (cue.spots or {}) :: { Vector3 } do
		local mark = flatDisc(spot, cue.radius or 2.6, L.silver, 0.6)
		FxLayers.animate(delay, function(t)
			mark.Transparency = 0.75 - 0.45 * math.abs(math.sin(t * math.pi * 3))
		end, function()
			mark:Destroy()
		end)
	end
end

local function blades(cue: any)
	for i, spot in (cue.spots or {}) :: { Vector3 } do
		task.delay((i - 1) * 0.05, function()
			local top = spot + UP * 30
			local blade = part({
				Size = Vector3.new(0.25, 3.2, 0.9),
				CFrame = CFrame.lookAt(top, spot) * CFrame.Angles(math.rad(90), 0, 0),
				Color = L.iron,
				Material = Enum.Material.Metal,
				Reflectance = 0.3,
			})
			local from = blade.CFrame
			FxLayers.animate(0.18, function(t)
				blade.CFrame = from - UP * (30 - 1.2) * t
			end, function()
				chips(spot, L.iron, 6, 14)
				task.delay(1.2, function()
					fadeOut(blade, 0.4)
				end)
			end)
		end)
	end
	if cue.spots and cue.spots[1] then
		sound(cue.spots[1], "magnetism", "impact", 0.9)
	end
end

local function lash(cue: any)
	local from: Vector3 = cue.from + UP * 1.4
	local dir: Vector3 = cue.dir
	local reach: number = cue.reach or 12
	local arc: number = cue.arc or 90
	local tip = part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 0.8, Color = L.silver, Material = Enum.Material.Metal, Reflectance = 0.6 })
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0.4, 0)
	a0.Parent = tip
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -0.4, 0)
	a1.Parent = tip
	local trail = Instance.new("Trail")
	trail.Attachment0, trail.Attachment1 = a0, a1
	trail.Lifetime = 0.3
	trail.Color = ColorSequence.new(L.silver, L.iron)
	trail.Transparency = seq(0, 0, 1, 1)
	trail.LightEmission = 0.4
	trail.FaceCamera = true
	trail.WidthScale = seq(0, 1.2, 1, 0)
	trail.Parent = tip
	FxLayers.animate(0.24, function(t)
		local angle = (t - 0.5) * arc
		local out = CFrame.Angles(0, math.rad(-angle), 0):VectorToWorldSpace(dir)
		local r = reach * (0.5 + 0.5 * math.sin(t * math.pi))
		tip.CFrame = CFrame.new(from + out * r)
	end, function()
		task.delay(0.35, function()
			tip:Destroy()
		end)
	end)
	sound(from, "purity", "launch", 0.7)
end

local function spires(cue: any)
	for _, spot in (cue.spots or {}) :: { Vector3 } do
		dust(spot, 1.4, 6)
		burst(spot + UP * 2, {
			texture = TEX.shard,
			color = ColorSequence.new(L.crystalCore, L.crystal),
			size = seq(0, 0.5, 1, 0),
			lifetime = NumberRange.new(0.4, 0.8),
			speed = NumberRange.new(4, 10),
			spread = 180,
		}, 10)
	end
	if cue.spots and cue.spots[1] then
		sound(cue.spots[1], "resonance", "impact", 0.8)
	end
end

local function spiresShatter(cue: any)
	for _, spot in (cue.spots or {}) :: { Vector3 } do
		local at = spot + UP * 2.5
		burst(at, {
			texture = TEX.shard,
			color = ColorSequence.new(L.crystalCore, L.crystal),
			size = seq(0, 0.8, 1, 0),
			lifetime = NumberRange.new(0.5, 1),
			speed = NumberRange.new(14, 30),
			spread = 180,
			acceleration = Vector3.new(0, -40, 0),
		}, 24)
		FxLayers.flash(at, 2, L.crystal, 0.2)
	end
	if cue.spots and cue.spots[1] then
		sound(cue.spots[1], "resonance", "impact", 1)
	end
end

local function shardRing(cue: any)
	local at: Vector3 = cue.at
	FxLayers.shockwave(at, UP, 3, L.crystal, 0.3)
	burst(at, {
		texture = TEX.ring,
		color = ColorSequence.new(L.crystalCore),
		size = seq(0, 1, 1, 4),
		transparency = seq(0, 0.2, 1, 1),
		lifetime = NumberRange.new(0.3),
		speed = NumberRange.new(0),
	}, 2)
	sound(at, "resonance", "impact", 0.5)
end

local function prison(cue: any)
	local root = rootOf(cue.model)
	if not root then
		return
	end
	local seconds = math.clamp(tonumber(cue.seconds) or 1.5, 0.5, 4)
	local pieces: { BasePart } = {}
	for i = 1, 6 do
		local angle = i / 6 * math.pi * 2
		local p = part({
			Size = Vector3.new(1.6, 6, 0.6),
			CFrame = CFrame.new(root.Position) * CFrame.Angles(0, angle, 0) * CFrame.new(0, 0, -1.6) * CFrame.Angles(math.rad(rng:NextNumber(-8, 8)), 0, 0),
			Color = L.crystal,
			Material = Enum.Material.Glass,
			Transparency = 0.35,
		})
		table.insert(pieces, p)
	end
	task.delay(seconds, function()
		for _, p in pieces do
			chips(p.Position, L.crystal, 4, 18)
			p:Destroy()
		end
		FxLayers.flash(root.Position, 2.5, L.crystal, 0.25)
	end)
	sound(root.Position, "resonance", "impact", 0.8)
end

local function fissure(cue: any)
	local from: Vector3 = cue.from
	local to: Vector3 = cue.to
	local speed: number = cue.speed or 60
	local d = to - from
	local length = d.Magnitude
	if length < 1 then
		return
	end
	local crack = part({
		Size = Vector3.new(0.6, 0.12, 0.1),
		CFrame = CFrame.lookAt(from + UP * 0.08, to + UP * 0.08),
		Color = L.crack,
		Transparency = 0.1,
	})
	local base = crack.CFrame
	FxLayers.animate(length / speed, function(t)
		local l = math.max(0.1, length * t)
		crack.Size = Vector3.new(0.6, 0.12, l)
		crack.CFrame = base * CFrame.new(0, 0, -l / 2)
	end, function()
		task.delay(1.5, function()
			fadeOut(crack, 0.6)
		end)
	end)
	for step = 0, length, 4 do
		task.delay(step / speed, function()
			local at = from + d.Unit * step
			dust(at, 1.6, 5)
			chips(at, L.stoneDark, 4, 14)
		end)
	end
	sound(from, "seismicity", "impact", 1)
end

local function ripple(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 16
	local speed: number = cue.speed or 28
	local seconds = radius / speed
	FxLayers.flat(at + UP * 0.2, UP, {
		texture = TEX.shock,
		color = FxLayers.solid(L.dust),
		size = seq(0, 1, 1, radius * 2.2),
		transparency = seq(0, 0.1, 0.8, 0.4, 1, 1),
		duration = seconds,
		emission = 0,
	})
	local steps = math.clamp(math.floor(radius / 3), 4, 10)
	for i = 1, steps do
		task.delay(seconds * i / steps, function()
			local r = radius * i / steps
			for k = 1, 6 do
				local angle = k / 6 * math.pi * 2 + i
				dust(at + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r), 1.2, 2)
			end
		end)
	end
	sound(at, "seismicity", "impact", 0.9)
end

local function sandblast(cue: any)
	local from: Vector3 = cue.from + UP * 1.4
	local dir: Vector3 = cue.dir
	local reach: number = cue.reach or 14
	local p = part({ Transparency = 1, CFrame = CFrame.lookAt(from, from + dir) })
	local e = emitter(p, {
		texture = TEX.dust,
		color = ColorSequence.new(L.sand, L.dust),
		size = seq(0, 1, 1, 4),
		transparency = seq(0, 0.25, 1, 1),
		lifetime = NumberRange.new(0.4, 0.7),
		speed = NumberRange.new(reach * 1.5, reach * 2.2),
		spread = (cue.arc or 70) / 2,
		direction = Enum.NormalId.Front,
		drag = 1,
		emission = 0,
	})
	e.Rate = 0
	e:Emit(math.floor(rate(60)))
	Debris:AddItem(p, 1.5)
	sound(from, "cohesion", "launch", 0.8)
end

local CUES: { [string]: (any) -> () } = {
	rubble = rubble,
	gravel = gravel,
	spikes = spikes,
	grip = grip,
	blades_warn = bladesWarn,
	blades = blades,
	lash = lash,
	spires = spires,
	spires_shatter = spiresShatter,
	shard_ring = shardRing,
	prison = prison,
	fissure = fissure,
	ripple = ripple,
	sandblast = sandblast,
}

function EarthFx.cue(cue: { [string]: any })
	local fn = CUES[cue.fx]
	if not fn then
		return
	end
	local ok, err = pcall(fn, cue)
	if not ok then
		warn("[EarthFx] " .. tostring(cue.fx) .. ": " .. tostring(err))
	end
end

-- ─── Lasting bodies (drawn by Fx/ArtFx) ─────────────────────────────────────

local BUILD: { [string]: (Visual) -> () } = {}

BUILD.boulder = function(v)
	local radius = (v.part:GetAttribute("Radius") :: number?) or 3
	local dir = Vector3.new((v.part:GetAttribute("DirX") :: number?) or 0, 0, (v.part:GetAttribute("DirZ") :: number?) or -1)
	local axis = if dir.Magnitude > 0.01 then dir.Unit:Cross(UP) else Vector3.new(1, 0, 0)
	local rock = own(v, part({
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * radius * 2,
		Color = L.stone,
		Material = Enum.Material.Slate,
	}))
	emitter(rock, {
		texture = TEX.dust,
		color = ColorSequence.new(L.dust),
		size = seq(0, 1.5, 1, 3.5),
		transparency = seq(0, 0.45, 1, 1),
		lifetime = NumberRange.new(0.6, 1),
		speed = NumberRange.new(0.5, 2),
		emission = 0,
		rate = 20,
	})
	v.extra.spin = 0
	v.update = function(vis, dt)
		vis.extra.spin -= dt * 30 / radius
		rock.CFrame = CFrame.new(vis.root.Position) * CFrame.fromAxisAngle(axis, vis.extra.spin)
	end
end

BUILD.iron_storm = function(v)
	local radius = (v.part:GetAttribute("Radius") :: number?) or 8
	v.root.Shape = Enum.PartType.Cylinder
	v.root.Size = Vector3.new(5, radius * 1.8, radius * 1.8)
	v.root.CFrame = v.root.CFrame * CFrame.Angles(0, 0, math.rad(90))
	v.fixed = true
	emitter(v.root, {
		texture = TEX.debris,
		color = ColorSequence.new(L.iron, L.silver),
		size = seq(0, 0.3, 1, 0.2),
		lifetime = NumberRange.new(0.8, 1.4),
		speed = NumberRange.new(10, 18),
		rotSpeed = NumberRange.new(-500, 500),
		shape = Enum.ParticleEmitterShape.Cylinder,
		emission = 0.3,
		rate = 90,
	})
	emitter(v.root, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.silver),
		size = seq(0, 0.25, 1, 0),
		lifetime = NumberRange.new(0.2, 0.5),
		rate = 30,
	})
end

BUILD.geode_shell = function(v)
	local count = math.clamp((v.part:GetAttribute("Plates") :: number?) or 6, 3, 10)
	local plates: { any } = {}
	for i = 1, count do
		local plate = own(v, part({
			Size = Vector3.new(1.2, 1.6, 0.35),
			Color = L.crystal,
			Material = Enum.Material.Glass,
			Transparency = 0.25,
		}))
		table.insert(plates, { part = plate, angle = i / count * math.pi * 2, h = ((i % 3) - 1) * 1.1 })
	end
	v.update = function(vis, _dt)
		local root = vis.model and rootOf(vis.model)
		local left = (vis.part:GetAttribute("Left") :: number?) or 1
		local shown = math.ceil(left * #plates)
		local base = if root then root.CFrame else CFrame.new(vis.root.Position)
		for i, entry in plates do
			local visible = i <= shown
			if not visible and entry.part.Transparency < 1 then
				chips(entry.part.Position, L.crystal, 5, 14)
			end
			entry.part.Transparency = if visible then 0.25 else 1
			entry.part.CFrame = base * CFrame.Angles(0, entry.angle, 0) * CFrame.new(0, entry.h, -1.35)
		end
	end
end

BUILD.dust_cloud = function(v)
	local radius = (v.part:GetAttribute("Radius") :: number?) or 8
	v.fixed = true
	v.root.Size = Vector3.new(radius * 1.6, 4, radius * 1.6)
	emitter(v.root, {
		texture = TEX.dust,
		color = ColorSequence.new(L.dust, L.sand),
		size = seq(0, 4, 1, 8),
		transparency = seq(0, 0.2, 0.7, 0.35, 1, 1),
		lifetime = NumberRange.new(2, 3.2),
		speed = NumberRange.new(0.5, 2),
		spread = 80,
		emission = 0,
		rate = 16,
	})
end

BUILD.quicksand = function(v)
	local radius = (v.part:GetAttribute("Radius") :: number?) or 7
	v.fixed = true
	local disc = own(v, flatDisc(v.root.Position, radius, L.sand, 0.15, Enum.Material.Sand))
	v.root.Size = Vector3.new(radius * 1.5, 0.5, radius * 1.5)
	emitter(v.root, {
		texture = TEX.dust,
		color = ColorSequence.new(L.sand),
		size = seq(0, 0.8, 1, 0.3),
		transparency = seq(0, 0.5, 1, 1),
		lifetime = NumberRange.new(1, 1.6),
		speed = NumberRange.new(0.2, 0.6),
		emission = 0,
		rate = 12,
	})
	v.update = function(_vis, dt)
		disc.CFrame = disc.CFrame * CFrame.Angles(math.rad(12) * dt, 0, 0) -- slowly churning
	end
end

BUILD.dust_devil = function(v)
	local column = own(v, part({ Transparency = 1, Size = Vector3.new(2.5, 9, 2.5) }))
	emitter(column, {
		texture = TEX.dust,
		color = ColorSequence.new(L.sand, L.dust),
		size = seq(0, 1.2, 1, 3),
		transparency = seq(0, 0.3, 1, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(4, 8),
		rotSpeed = NumberRange.new(-400, 400),
		shape = Enum.ParticleEmitterShape.Cylinder,
		acceleration = Vector3.new(0, 6, 0),
		emission = 0,
		rate = 70,
	})
	v.update = function(vis, _dt)
		column.CFrame = CFrame.new(vis.root.Position + UP * 4.5) * CFrame.Angles(0, os.clock() * 8, 0)
	end
end

BUILD.sand_shroud = function(v)
	local radius = (v.part:GetAttribute("Radius") :: number?) or 6
	v.root.Shape = Enum.PartType.Ball
	v.root.Size = Vector3.one * radius * 1.4
	emitter(v.root, {
		texture = TEX.dust,
		color = ColorSequence.new(L.sand, L.dust),
		size = seq(0, 0.8, 1, 1.6),
		transparency = seq(0, 0.35, 1, 1),
		lifetime = NumberRange.new(0.8, 1.3),
		speed = NumberRange.new(5, 9),
		rotSpeed = NumberRange.new(-300, 300),
		shape = Enum.ParticleEmitterShape.Sphere,
		emission = 0,
		rate = 50,
	})
end

A.register(BUILD)

-- ─── Bolt looks (SpellFx.launch through ArtFx.flight) ───────────────────────

local function dressStone(anchor: Part, size: Vector3, shape: Enum.PartType)
	anchor.Shape = shape
	anchor.Size = size
	anchor.Material = Enum.Material.Slate
	anchor.Color = L.stone
end

A.registerFlights({
	fist = function(anchor: Part, coreSize: number)
		dressStone(anchor, Vector3.new(1.6, 1.6, 2.2) * math.max(1, coreSize), Enum.PartType.Block)
		local e = FxLayers.emitter(anchor, {
			texture = TEX.dust,
			color = ColorSequence.new(L.dust),
			size = seq(0, 1, 1, 2.5),
			transparency = seq(0, 0.4, 1, 1),
			lifetime = NumberRange.new(0.4, 0.7),
			speed = NumberRange.new(0.5, 1.5),
			emission = 0,
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
	boulder = function(anchor: Part, coreSize: number)
		dressStone(anchor, Vector3.one * math.max(3, coreSize * 4), Enum.PartType.Ball)
		return nil, 0
	end,
	shard = function(anchor: Part, coreSize: number)
		anchor.Shape = Enum.PartType.Block
		anchor.Size = Vector3.new(0.5, 0.5, 2.4) * math.max(1, coreSize)
		anchor.Material = Enum.Material.Glass
		anchor.Color = L.crystal
		anchor.Transparency = 0.15
		local e = FxLayers.emitter(anchor, {
			texture = TEX.shard,
			color = ColorSequence.new(L.crystalCore, L.crystal),
			size = seq(0, 0.4, 1, 0),
			transparency = seq(0, 0, 1, 1),
			lifetime = NumberRange.new(0.2, 0.4),
			speed = NumberRange.new(0.5, 2),
			spread = 180,
			emission = 1,
			rate = rate(30),
		})
		if e then
			e.Enabled = true
		end
		return function()
			if e then
				e.Enabled = false
			end
		end, nil
	end,
})

return EarthFx
