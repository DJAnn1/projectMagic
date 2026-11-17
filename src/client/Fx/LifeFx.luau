--!strict
--[[
	LifeFx: what Life's spells look like (docs/DomainIdeas.md, "Life"). Cosmetic only: the server
	(Effects/LifeArt, Cast/ArtRuntime) decides everything and grows the real tree itself.

		LifeFx.cue(effect)   one-shot "life" WorldEffect cues, by `fx`:
		    lifeline  a green ribbon from you to them        second_wind  a breath of green round you
		    raise     light lifting someone back up          vine     a thorny vine lashing out
		    roots     roots wrapping someone's legs          thorns   thorns bursting out
		    grow      leaves bursting as a tree shoots up    bounce   a puff where someone's thrown up
		    flock     birds bursting out and wheeling        claw     claw marks hanging in the air
		    rot       black spreading over the ground        flies    a buzzing cloud on someone
		    bloom_burst  the corpse bloom bursting
		Bodies (Fx/ArtFx, by ArtLook): healing_grove, petal_ward, bramble_wall, spore_cloud, fairy_ring,
		    swarm, beast_claws, withering_field, corpse_bloom.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local E = require(Shared.Magic.Data.LifeTuning)

local DomainFx = require(script.Parent.DomainFx)
local FxLayers = require(script.Parent.FxLayers)
local A = require(script.Parent.ArtFx)

local TEX = DomainFx.textures
local L = E.looks
local UP = Vector3.new(0, 1, 0)

local part, seq, emitter = A.part, A.seq, A.emitter
local burst, fadeOut, rootOf, flatDisc, limb = A.burst, A.fadeOut, A.rootOf, A.flatDisc, A.limb
local own = A.own
type Visual = A.Visual

local LifeFx = {}

local rng = Random.new()

local function sound(position: Vector3, property: string, which: string, volume: number?)
	A.sound(position, "life", property, which, volume)
end

local function leaves(at: Vector3, count: number, color: Color3?)
	burst(at, {
		texture = TEX.spore,
		color = ColorSequence.new(color or L.leafLight, L.leaf),
		size = seq(0, 0.6, 1, 0.3),
		lifetime = NumberRange.new(0.8, 1.4),
		speed = NumberRange.new(4, 10),
		spread = 180,
		acceleration = Vector3.new(0, -8, 0),
		rotSpeed = NumberRange.new(-200, 200),
		drag = 1,
		emission = 0.2,
	}, count)
end

-- A thin bent rope of parts between two points (a vine), grown out over `grow` seconds.
local function rope(from: Vector3, to: Vector3, color: Color3, width: number, grow: number, life: number)
	local d = to - from
	local n = math.clamp(math.floor(d.Magnitude / 2.5), 3, 12)
	local side = d:Cross(UP)
	side = if side.Magnitude > 0.01 then side.Unit else Vector3.new(1, 0, 0)
	local bend = rng:NextNumber(-1, 1) * d.Magnitude * 0.08
	local prev = from
	for i = 1, n do
		local t = i / n
		local p = from + d * t + side * math.sin(t * math.pi) * bend + UP * math.sin(t * math.pi) * d.Magnitude * 0.05
		local seg = p - prev
		local segPrev = prev
		task.delay(grow * (i - 1) / n, function()
			local piece = part({
				Size = Vector3.new(width, width, seg.Magnitude + 0.2),
				CFrame = CFrame.lookAt(segPrev + seg / 2, segPrev + seg),
				Color = color,
				Material = Enum.Material.Grass,
			})
			task.delay(life, function()
				fadeOut(piece, 0.4)
			end)
		end)
		prev = p
	end
end

-- ─── One-shot cues ──────────────────────────────────────────────────────────

local function lifeline(cue: any)
	local from: Vector3 = cue.from
	local to: Vector3 = cue.to
	local d = to - from
	local ribbon = part({
		Size = Vector3.new(0.35, 0.35, d.Magnitude),
		CFrame = CFrame.lookAt(from + d / 2, to),
		Color = L.heal,
		Transparency = 0.2,
	})
	fadeOut(ribbon, 0.8, Vector3.new(0.05, 0.05, d.Magnitude))
	burst(to, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.heal),
		size = seq(0, 0.6, 1, 0),
		lifetime = NumberRange.new(0.6, 1),
		speed = NumberRange.new(1, 4),
		spread = 180,
		acceleration = Vector3.new(0, 4, 0),
	}, 20)
	sound(to, "vitality", "impact", 0.6)
end

local function secondWind(cue: any)
	local at: Vector3 = cue.at
	FxLayers.shockwave(at, UP, cue.radius or 12, L.heal, 0.5)
	leaves(at, 20, L.heal)
end

local function raise(cue: any)
	local at: Vector3 = cue.at
	local column = part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(14, 4, 4),
		CFrame = CFrame.new(at + UP * 5) * CFrame.Angles(0, 0, math.rad(90)),
		Color = L.heal,
		Transparency = 0.5,
	})
	fadeOut(column, 1.2, Vector3.new(20, 1, 1))
	burst(at, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.heal, Color3.new(1, 1, 1)),
		size = seq(0, 0.8, 1, 0),
		lifetime = NumberRange.new(1, 1.6),
		speed = NumberRange.new(3, 8),
		spread = 40,
		acceleration = Vector3.new(0, 6, 0),
	}, 40)
	FxLayers.light(at, L.heal, 5, 20, 1.2)
	sound(at, "vitality", "impact", 0.9)
end

local function vine(cue: any)
	rope(cue.from, cue.to, L.thorn, 0.35, 0.12, 0.6)
	leaves(cue.to, 8)
	sound(cue.from, "growth", "launch", 0.6)
end

local function roots(cue: any)
	local root = rootOf(cue.model)
	if not root then
		return
	end
	local seconds = math.clamp(tonumber(cue.seconds) or 1.6, 0.5, 4)
	local feet = root.Position - UP * 2.8
	for i = 1, 5 do
		local angle = i / 5 * math.pi * 2
		local base = feet + Vector3.new(math.cos(angle) * 1.6, 0, math.sin(angle) * 1.6)
		local tip = root.Position + Vector3.new(math.cos(angle + 1) * 0.6, rng:NextNumber(-1.5, 0), math.sin(angle + 1) * 0.6)
		rope(base, tip, L.wood, 0.3, 0.2, seconds)
	end
	leaves(feet, 6, L.thorn)
end

local function thorns(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 7
	for _ = 1, 14 do
		local dir = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(0, 0.6), rng:NextNumber(-1, 1))
		if dir.Magnitude > 0.1 then
			dir = dir.Unit
			local spike = part({
				Size = Vector3.new(0.2, 0.2, 2),
				CFrame = CFrame.lookAt(at, at + dir),
				Color = L.thorn,
				Material = Enum.Material.Wood,
			})
			local start = spike.CFrame
			FxLayers.animate(0.25, function(t)
				spike.CFrame = start + dir * radius * t
			end, function()
				fadeOut(spike, 0.3)
			end)
		end
	end
	leaves(at, 10, L.thorn)
	sound(at, "growth", "impact", 0.8)
end

local function grow(cue: any)
	local at: Vector3 = cue.at
	local height = tonumber(cue.height) or 9
	leaves(at + UP * height, 40)
	burst(at, {
		texture = TEX.dust,
		color = ColorSequence.new(Color3.fromRGB(110, 90, 60)),
		size = seq(0, 1.5, 1, 3),
		transparency = seq(0, 0.4, 1, 1),
		lifetime = NumberRange.new(0.6, 1),
		speed = NumberRange.new(3, 8),
		spread = 70,
		emission = 0,
	}, 14)
	sound(at, "growth", "impact", 0.8)
end

local function bounce(cue: any)
	local at: Vector3 = cue.at
	burst(at, {
		texture = TEX.spore,
		color = ColorSequence.new(L.spore, L.bloom),
		size = seq(0, 0.6, 1, 0),
		lifetime = NumberRange.new(0.5, 1),
		speed = NumberRange.new(4, 10),
		spread = 60,
		acceleration = Vector3.new(0, -10, 0),
	}, 16)
	sound(at, "decay", "launch", 0.5)
end

local function flock(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 10
	for i = 1, 14 do
		local bird = part({ Size = Vector3.new(1.2, 0.15, 0.6), Color = L.bird, Material = Enum.Material.SmoothPlastic })
		local phase = i / 14 * math.pi * 2
		local r = radius * rng:NextNumber(0.4, 1)
		local h = rng:NextNumber(2, 6)
		FxLayers.animate(1.6, function(t)
			local angle = phase + t * math.pi * 3
			local rr = r * math.min(1, t * 3)
			local flap = math.sin(t * 60) * 0.6
			bird.CFrame = CFrame.new(at + Vector3.new(math.cos(angle) * rr, h + t * 8, math.sin(angle) * rr)) * CFrame.Angles(0, -angle, flap)
			bird.Transparency = math.max(0, (t - 0.75) * 4)
		end, function()
			bird:Destroy()
		end)
	end
	sound(at, "instinct", "launch", 1)
end

local function claw(cue: any)
	local at: Vector3 = cue.at
	for k = -1, 1 do
		local mark = part({
			Size = Vector3.new(0.15, 2.4, 0.15),
			CFrame = CFrame.new(at + Vector3.new(k * 0.5, 0, 0)) * CFrame.Angles(0, 0, math.rad(25)),
			Color = Color3.fromRGB(200, 40, 40),
		})
		fadeOut(mark, 0.4)
	end
end

local function rot(cue: any)
	local at: Vector3 = cue.at
	local stain = flatDisc(at, cue.radius or 6, L.rot, 0.3, Enum.Material.Mud)
	task.delay(4, function()
		fadeOut(stain, 1.5)
	end)
	burst(at, {
		texture = TEX.spore,
		color = ColorSequence.new(L.rot),
		size = seq(0, 0.6, 1, 1.2),
		transparency = seq(0, 0.4, 1, 1),
		lifetime = NumberRange.new(1, 1.6),
		speed = NumberRange.new(0.5, 2),
		spread = 60,
		emission = 0,
	}, 14)
end

local function flies(cue: any)
	local root = rootOf(cue.model)
	if not root then
		return
	end
	local cloud = part({ Transparency = 1, Size = Vector3.new(3, 4, 3), CFrame = root.CFrame })
	emitter(cloud, {
		texture = TEX.debris,
		color = ColorSequence.new(L.insect),
		size = seq(0, 0.15, 1, 0.1),
		lifetime = NumberRange.new(0.3, 0.6),
		speed = NumberRange.new(3, 6),
		spread = 180,
		rotSpeed = NumberRange.new(-600, 600),
		emission = 0,
		rate = 80,
	})
	local seconds = math.clamp(tonumber(cue.seconds) or 2, 0.5, 6)
	FxLayers.animate(seconds, function(_t)
		local rr = rootOf(cue.model)
		if rr then
			cloud.CFrame = rr.CFrame
		end
	end, function()
		cloud:Destroy()
	end)
end

local function bloomBurst(cue: any)
	local at: Vector3 = cue.at
	burst(at, {
		texture = TEX.smoke,
		color = ColorSequence.new(L.plague, L.rot),
		size = seq(0, 3, 1, 7),
		transparency = seq(0, 0.3, 1, 1),
		lifetime = NumberRange.new(1.2, 2),
		speed = NumberRange.new(4, 9),
		spread = 180,
		emission = 0,
	}, 30, 3)
	FxLayers.shockwave(at, UP, cue.radius or 7, L.plague, 0.4)
	sound(at, "toxin", "impact", 1)
end

local CUES: { [string]: (any) -> () } = {
	lifeline = lifeline,
	second_wind = secondWind,
	raise = raise,
	vine = vine,
	roots = roots,
	thorns = thorns,
	grow = grow,
	bounce = bounce,
	flock = flock,
	claw = claw,
	rot = rot,
	flies = flies,
	bloom_burst = bloomBurst,
}

function LifeFx.cue(cue: { [string]: any })
	local fn = CUES[cue.fx]
	if not fn then
		return
	end
	local ok, err = pcall(fn, cue)
	if not ok then
		warn("[LifeFx] " .. tostring(cue.fx) .. ": " .. tostring(err))
	end
end

-- ─── Lasting bodies (drawn by Fx/ArtFx) ─────────────────────────────────────

local BUILD: { [string]: (Visual) -> () } = {}

local function radiusOf(v: Visual, default: number): number
	return (v.part:GetAttribute("Radius") :: number?) or default
end

BUILD.healing_grove = function(v)
	local radius = radiusOf(v, 8)
	v.fixed = true
	own(v, flatDisc(v.root.Position, radius, L.leafLight, 0.55, Enum.Material.Grass))
	for _ = 1, math.clamp(math.floor(radius * 1.5), 6, 20) do
		local angle = rng:NextNumber(0, math.pi * 2)
		local r = math.sqrt(rng:NextNumber()) * radius
		local at = v.root.Position + Vector3.new(math.cos(angle) * r, 0.4, math.sin(angle) * r)
		own(v, part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 0.7, CFrame = CFrame.new(at), Color = if rng:NextNumber() < 0.5 then L.bloom else L.petal, Material = Enum.Material.SmoothPlastic }))
	end
	v.root.Size = Vector3.new(radius * 1.5, 0.5, radius * 1.5)
	emitter(v.root, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.heal),
		size = seq(0, 0.35, 1, 0),
		lifetime = NumberRange.new(1, 1.6),
		speed = NumberRange.new(1, 2.5),
		acceleration = Vector3.new(0, 1.5, 0),
		rate = 18,
	})
end

BUILD.petal_ward = function(v)
	local petals: { BasePart } = {}
	for _ = 1, 6 do
		table.insert(petals, own(v, part({ Size = Vector3.new(0.8, 0.12, 0.5), Color = L.petal, Material = Enum.Material.SmoothPlastic })))
	end
	v.update = function(vis, _dt)
		local t = os.clock()
		for i, petal in petals do
			local angle = t * 2 + i / #petals * math.pi * 2
			petal.CFrame = CFrame.new(vis.root.Position + Vector3.new(math.cos(angle) * 2.6, math.sin(t * 3 + i) * 0.6, math.sin(angle) * 2.6)) * CFrame.Angles(0, -angle, 0.4)
		end
	end
end

BUILD.bramble_wall = function(v)
	v.fixed = true
	local frame = v.part.CFrame
	local length = v.part.Size.X
	for i = 1, math.clamp(math.floor(length / 1.6), 4, 16) do
		local x = -length / 2 + (i - 0.5) * length / math.clamp(math.floor(length / 1.6), 4, 16)
		own(v, part({
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(2.4, 2.2 + rng:NextNumber() * 1.2, 2.4),
			CFrame = frame * CFrame.new(x, rng:NextNumber(-0.6, 0.4), rng:NextNumber(-0.4, 0.4)),
			Color = if i % 2 == 0 then L.thorn else L.leaf,
			Material = Enum.Material.LeafyGrass,
		}))
	end
end

BUILD.spore_cloud = function(v)
	local radius = radiusOf(v, 8)
	v.fixed = true
	v.root.Size = Vector3.new(radius * 1.6, 3, radius * 1.6)
	emitter(v.root, {
		texture = TEX.spore,
		color = ColorSequence.new(L.spore),
		size = seq(0, 1.5, 1, 3.5),
		transparency = seq(0, 0.4, 1, 1),
		lifetime = NumberRange.new(1.6, 2.6),
		speed = NumberRange.new(0.3, 1.2),
		spread = 80,
		emission = 0.1,
		rate = 24,
	})
	for _ = 1, 6 do
		local angle = rng:NextNumber(0, math.pi * 2)
		local r = rng:NextNumber(0.3, 1) * radius
		local at = v.root.Position + Vector3.new(math.cos(angle) * r, 0.5, math.sin(angle) * r)
		own(v, part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 1.2, CFrame = CFrame.new(at), Color = L.spore, Material = Enum.Material.SmoothPlastic }))
	end
end

BUILD.fairy_ring = function(v)
	local radius = radiusOf(v, 5)
	v.fixed = true
	for i = 1, 12 do
		local angle = i / 12 * math.pi * 2
		local at = v.root.Position + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		own(v, part({ Size = Vector3.new(0.35, 0.8, 0.35), CFrame = CFrame.new(at + UP * 0.4), Color = Color3.fromRGB(235, 225, 200), Material = Enum.Material.SmoothPlastic }))
		own(v, part({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(0.35, 1.3, 1.3),
			CFrame = CFrame.new(at + UP * 0.9) * CFrame.Angles(0, 0, math.rad(90)),
			Color = L.mushroom,
			Material = Enum.Material.SmoothPlastic,
		}))
	end
	v.root.Size = Vector3.new(radius * 1.5, 0.5, radius * 1.5)
	emitter(v.root, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.spore, L.bloom),
		size = seq(0, 0.25, 1, 0),
		lifetime = NumberRange.new(1, 1.8),
		speed = NumberRange.new(0.5, 1.5),
		acceleration = Vector3.new(0, 1, 0),
		rate = 10,
	})
end

BUILD.swarm = function(v)
	v.root.Size = Vector3.new(3, 4, 3)
	emitter(v.root, {
		texture = TEX.debris,
		color = ColorSequence.new(Color3.fromRGB(200, 170, 40), L.insect),
		size = seq(0, 0.18, 1, 0.12),
		lifetime = NumberRange.new(0.3, 0.6),
		speed = NumberRange.new(3, 7),
		spread = 180,
		rotSpeed = NumberRange.new(-600, 600),
		emission = 0,
		rate = 90,
	})
end

BUILD.beast_claws = function(v)
	local model = v.model
	if not model then
		return
	end
	for _, names in { { "Right Arm", "RightHand" }, { "Left Arm", "LeftHand" } } do
		local arm = limb(model, names)
		if arm then
			for k = -1, 1 do
				local talon = own(v, Instance.new("Part"))
				talon.Name = "BeastClaw"
				talon.Size = Vector3.new(0.12, 0.9, 0.12)
				talon.Color = Color3.fromRGB(235, 225, 205)
				talon.Material = Enum.Material.SmoothPlastic
				talon.CanCollide = false
				talon.CanQuery = false
				talon.CanTouch = false
				talon.Massless = true
				talon.CFrame = arm.CFrame * CFrame.new(k * 0.3, -arm.Size.Y / 2 - 0.35, -0.2) * CFrame.Angles(math.rad(-20), 0, 0)
				local weld = Instance.new("WeldConstraint")
				weld.Part0, weld.Part1 = talon, arm
				weld.Parent = talon
				talon.Parent = model
			end
		end
	end
end

BUILD.withering_field = function(v)
	local radius = radiusOf(v, 8)
	v.fixed = true
	own(v, flatDisc(v.root.Position, radius, L.wither, 0.35, Enum.Material.Ground))
	v.root.Size = Vector3.new(radius * 1.5, 0.5, radius * 1.5)
	emitter(v.root, {
		texture = TEX.dust,
		color = ColorSequence.new(L.wither),
		size = seq(0, 0.8, 1, 1.6),
		transparency = seq(0, 0.5, 1, 1),
		lifetime = NumberRange.new(1.2, 2),
		speed = NumberRange.new(0.3, 1),
		acceleration = Vector3.new(0, 1, 0),
		emission = 0,
		rate = 12,
	})
end

BUILD.corpse_bloom = function(v)
	v.fixed = true
	local at = v.root.Position
	own(v, part({ Size = Vector3.new(0.5, 2.2, 0.5), CFrame = CFrame.new(at + UP * 1.1), Color = L.thorn, Material = Enum.Material.Grass }))
	local head = own(v, part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 2.4, CFrame = CFrame.new(at + UP * 2.6), Color = L.plague, Material = Enum.Material.SmoothPlastic }))
	emitter(head, {
		texture = TEX.spore,
		color = ColorSequence.new(L.plague),
		size = seq(0, 0.4, 1, 0.8),
		transparency = seq(0, 0.5, 1, 1),
		lifetime = NumberRange.new(1, 1.6),
		speed = NumberRange.new(0.3, 1),
		emission = 0,
		rate = 6,
	})
	v.update = function(_vis, _dt)
		local pulse = 2.4 + math.sin(os.clock() * 3) * 0.2
		head.Size = Vector3.one * pulse
	end
end

A.register(BUILD)

return LifeFx
