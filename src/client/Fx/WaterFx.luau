--!strict
--[[
	WaterFx: what Water's spells look like (docs/DomainIdeas.md, "Water"). Cosmetic only: the server
	(Effects/WaterArt, Cast/ArtRuntime) decides everything and raises the real ice and cloud itself.

		WaterFx.cue(effect)   one-shot "water" WorldEffect cues, by `fx`:
		    whip      a lash of water sweeping an arc        jet      a white high-pressure stream
		    bubble    a shimmering sphere round someone     geyser_warn / geyser   a bubbling spot, then a column
		    riptide   a current dragging someone in         icicles_warn / icicles   frost marks, then falling ice
		    dome      frost bursting round the ice ring     steam    scalding steam
		    cloud     a puff of cloud forming
		Bodies (Fx/ArtFx, by ArtLook): mire, wave_surge, whirlpool, ice_slide, permafrost, fog_bank,
		    cleansing_rain, water_shield, fountain.
]]

local Debris = game:GetService("Debris")

local Shared = game:GetService("ReplicatedStorage").Shared
local E = require(Shared.Magic.Data.WaterTuning)

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

local WaterFx = {}

local rng = Random.new()

local function sound(position: Vector3, property: string, which: string, volume: number?)
	A.sound(position, "water", property, which, volume)
end

local function splash(at: Vector3, count: number, speed: number?)
	burst(at, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.foam, L.waterLight),
		size = seq(0, 0.6, 1, 0.2),
		transparency = seq(0, 0.1, 1, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(6, speed or 18),
		spread = 60,
		acceleration = Vector3.new(0, -50, 0),
		emission = 0.4,
	}, count)
end

local function mist(at: Vector3, size: number, count: number, color: Color3?)
	burst(at, {
		texture = TEX.smoke,
		color = ColorSequence.new(color or L.steam),
		size = seq(0, size, 1, size * 2.5),
		transparency = seq(0, 0.3, 1, 1),
		lifetime = NumberRange.new(1, 2),
		speed = NumberRange.new(2, 6),
		spread = 80,
		acceleration = Vector3.new(0, 3, 0),
		drag = 1.5,
		emission = 0.1,
	}, count, 3)
end

-- ─── One-shot cues ──────────────────────────────────────────────────────────

local function whip(cue: any)
	local from: Vector3 = cue.from + UP * 1.4
	local dir: Vector3 = cue.dir
	local reach: number = cue.reach or 12
	local arc: number = cue.arc or 100
	local tip = part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 0.8, Color = L.waterLight, Material = Enum.Material.Glass, Transparency = 0.3 })
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0.5, 0)
	a0.Parent = tip
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -0.5, 0)
	a1.Parent = tip
	local trail = Instance.new("Trail")
	trail.Attachment0, trail.Attachment1 = a0, a1
	trail.Lifetime = 0.35
	trail.Color = ColorSequence.new(L.foam, L.water)
	trail.Transparency = seq(0, 0.1, 1, 1)
	trail.LightEmission = 0.3
	trail.FaceCamera = true
	trail.WidthScale = seq(0, 1.3, 1, 0)
	trail.Parent = tip
	emitter(tip, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.foam),
		size = seq(0, 0.4, 1, 0),
		lifetime = NumberRange.new(0.3, 0.5),
		speed = NumberRange.new(2, 5),
		spread = 180,
		acceleration = Vector3.new(0, -30, 0),
		emission = 0.3,
		rate = 80,
	})
	FxLayers.animate(0.24, function(t)
		local angle = (t - 0.5) * arc
		local out = CFrame.Angles(0, math.rad(-angle), 0):VectorToWorldSpace(dir)
		local r = reach * (0.55 + 0.45 * math.sin(t * math.pi))
		tip.CFrame = CFrame.new(from + out * r + UP * math.sin(t * math.pi))
	end, function()
		task.delay(0.4, function()
			tip:Destroy()
		end)
	end)
	sound(from, "flow", "launch", 0.7)
end

local function jet(cue: any)
	local from: Vector3 = cue.from
	local to: Vector3 = cue.to
	local d = to - from
	local stream = part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(d.Magnitude, 1.1, 1.1),
		CFrame = CFrame.lookAt(from + d / 2, to) * CFrame.Angles(0, math.rad(90), 0),
		Color = L.foam,
		Material = Enum.Material.Glass,
		Transparency = 0.25,
	})
	fadeOut(stream, 0.35, Vector3.new(d.Magnitude, 0.2, 0.2))
	splash(to, 20, 24)
	sound(from, "pressure", "launch", 0.9)
end

local function bubble(cue: any)
	local root = rootOf(cue.model)
	if not root then
		return
	end
	local seconds = math.clamp(tonumber(cue.seconds) or 1.5, 0.5, 4)
	local ball = part({
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * 7,
		CFrame = CFrame.new(root.Position),
		Color = L.waterLight,
		Material = Enum.Material.Glass,
		Transparency = 0.6,
		Reflectance = 0.2,
	})
	local started = os.clock()
	FxLayers.animate(seconds, function(t)
		local rr = rootOf(cue.model)
		local wobble = 1 + math.sin((os.clock() - started) * 9) * 0.04
		ball.Size = Vector3.one * 7 * wobble
		if rr then
			ball.CFrame = CFrame.new(rr.Position)
		end
		ball.Transparency = 0.6 + 0.3 * t ^ 6
	end, function()
		splash(ball.Position, 24, 16)
		ball:Destroy()
	end)
	sound(root.Position, "pressure", "impact", 0.6)
end

local function geyserWarn(cue: any)
	local at: Vector3 = cue.at
	local delay = tonumber(cue.delay) or 0.6
	local mark = flatDisc(at, cue.radius or 4, L.water, 0.5)
	local p = part({ Transparency = 1, Size = Vector3.new((cue.radius or 4) * 1.5, 0.5, (cue.radius or 4) * 1.5), CFrame = CFrame.new(at) })
	emitter(p, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.foam),
		size = seq(0, 0.5, 1, 0),
		lifetime = NumberRange.new(0.3, 0.5),
		speed = NumberRange.new(2, 6),
		spread = 30,
		rate = 40,
	})
	Debris:AddItem(mark, delay)
	Debris:AddItem(p, delay)
end

local function geyser(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 4
	local height = 22
	local column = part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.5, radius * 1.6, radius * 1.6),
		CFrame = CFrame.new(at) * CFrame.Angles(0, 0, math.rad(90)),
		Color = L.waterLight,
		Material = Enum.Material.Glass,
		Transparency = 0.25,
	})
	FxLayers.animate(0.25, function(t)
		local h = height * t
		column.Size = Vector3.new(h, radius * 1.6, radius * 1.6)
		column.CFrame = CFrame.new(at + UP * (h / 2)) * CFrame.Angles(0, 0, math.rad(90))
	end, function()
		fadeOut(column, 0.6)
	end)
	burst(at + UP * height, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.foam, L.waterLight),
		size = seq(0, 0.8, 1, 0.3),
		lifetime = NumberRange.new(0.8, 1.4),
		speed = NumberRange.new(8, 20),
		spread = 80,
		acceleration = Vector3.new(0, -50, 0),
		emission = 0.3,
	}, 50)
	mist(at, 2, 12, L.foam)
	sound(at, "pressure", "impact", 1)
end

local function riptide(cue: any)
	local from: Vector3 = cue.from
	local to: Vector3 = cue.to
	local d = to - from
	for i = 0, 5 do
		task.delay(i * 0.04, function()
			local at = from + d * (i / 6)
			splash(at, 6, 10)
		end)
	end
end

local function icicles(cue: any)
	for i, spot in (cue.spots or {}) :: { Vector3 } do
		task.delay((i - 1) * 0.05, function()
			local top = spot + UP * 28
			local ice = part({
				Size = Vector3.new(0.6, 3.4, 0.6),
				CFrame = CFrame.new(top),
				Color = L.ice,
				Material = Enum.Material.Ice,
				Transparency = 0.2,
			})
			FxLayers.animate(0.2, function(t)
				ice.CFrame = CFrame.new(top - UP * (28 - 1.4) * t)
			end, function()
				burst(spot, {
					texture = TEX.shard,
					color = ColorSequence.new(L.foam, L.ice),
					size = seq(0, 0.5, 1, 0),
					lifetime = NumberRange.new(0.4, 0.8),
					speed = NumberRange.new(8, 18),
					spread = 70,
					acceleration = Vector3.new(0, -40, 0),
				}, 10)
				task.delay(0.8, function()
					fadeOut(ice, 0.4)
				end)
			end)
		end)
	end
	if cue.spots and cue.spots[1] then
		sound(cue.spots[1], "phase", "impact", 0.9)
	end
end

local function icicleWarn(cue: any)
	local delay = tonumber(cue.delay) or 0.9
	for _, spot in (cue.spots or {}) :: { Vector3 } do
		local mark = flatDisc(spot, cue.radius or 2.6, L.foam, 0.55)
		FxLayers.animate(delay, function(t)
			mark.Transparency = 0.75 - 0.4 * math.abs(math.sin(t * math.pi * 3))
		end, function()
			mark:Destroy()
		end)
	end
end

local function dome(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 8
	for k = 1, 12 do
		local angle = k / 12 * math.pi * 2
		mist(at + Vector3.new(math.cos(angle) * radius, 1, math.sin(angle) * radius), 1.2, 3, L.foam)
	end
	sound(at, "phase", "impact", 0.8)
end

local function steam(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 8
	burst(at, {
		texture = TEX.smoke,
		color = ColorSequence.new(L.steam),
		size = seq(0, 3, 1, radius * 0.9),
		transparency = seq(0, 0.2, 1, 1),
		lifetime = NumberRange.new(1.2, 2.2),
		speed = NumberRange.new(6, 14),
		spread = 90,
		acceleration = Vector3.new(0, 5, 0),
		drag = 1.5,
		emission = 0.2,
	}, 40, 3)
	sound(at, "phase", "impact", 0.8)
end

local function cloud(cue: any)
	local at: Vector3 = cue.at
	mist(at, 2.2, 14, L.cloud)
end

local CUES: { [string]: (any) -> () } = {
	whip = whip,
	jet = jet,
	bubble = bubble,
	geyser_warn = geyserWarn,
	geyser = geyser,
	riptide = riptide,
	icicles_warn = icicleWarn,
	icicles = icicles,
	dome = dome,
	steam = steam,
	cloud = cloud,
}

function WaterFx.cue(cue: { [string]: any })
	local fn = CUES[cue.fx]
	if not fn then
		return
	end
	local ok, err = pcall(fn, cue)
	if not ok then
		warn("[WaterFx] " .. tostring(cue.fx) .. ": " .. tostring(err))
	end
end

-- ─── Lasting bodies (drawn by Fx/ArtFx) ─────────────────────────────────────

local BUILD: { [string]: (Visual) -> () } = {}

local function radiusOf(v: Visual, default: number): number
	return (v.part:GetAttribute("Radius") :: number?) or default
end

BUILD.mire = function(v)
	local radius = radiusOf(v, 8)
	v.fixed = true
	own(v, flatDisc(v.root.Position, radius, L.mud, 0.15, Enum.Material.Mud))
	v.root.Size = Vector3.new(radius * 1.5, 0.5, radius * 1.5)
	emitter(v.root, {
		texture = TEX.spore,
		color = ColorSequence.new(L.mud),
		size = seq(0, 0.4, 1, 0.8),
		transparency = seq(0, 0.4, 1, 1),
		lifetime = NumberRange.new(0.8, 1.4),
		speed = NumberRange.new(0.3, 1),
		emission = 0,
		rate = 10,
	})
end

BUILD.wave_surge = function(v)
	local width = (v.part:GetAttribute("Width") :: number?) or 10
	local dir = Vector3.new((v.part:GetAttribute("DirX") :: number?) or 0, 0, (v.part:GetAttribute("DirZ") :: number?) or -1)
	dir = if dir.Magnitude > 0.01 then dir.Unit else Vector3.new(0, 0, -1)
	local wall = own(v, part({
		Size = Vector3.new(width, 5, 2.5),
		Color = L.water,
		Material = Enum.Material.Glass,
		Transparency = 0.3,
	}))
	local crest = own(v, part({ Transparency = 1, Size = Vector3.new(width, 0.5, 1) }))
	emitter(crest, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.foam),
		size = seq(0, 0.9, 1, 0.3),
		lifetime = NumberRange.new(0.4, 0.8),
		speed = NumberRange.new(4, 9),
		spread = 50,
		acceleration = Vector3.new(0, -30, 0),
		emission = 0.3,
		rate = 90,
	})
	v.update = function(vis, _dt)
		local frame = CFrame.lookAt(vis.root.Position + UP * 2.2, vis.root.Position + UP * 2.2 + dir) * CFrame.Angles(math.rad(-18), 0, 0)
		wall.CFrame = frame
		crest.CFrame = frame * CFrame.new(0, 2.6, -0.8)
	end
end

BUILD.whirlpool = function(v)
	local radius = radiusOf(v, 8)
	v.fixed = true
	local disc = own(v, flatDisc(v.root.Position, radius, L.deep, 0.35))
	v.root.Shape = Enum.PartType.Cylinder
	v.root.Size = Vector3.new(1, radius * 1.8, radius * 1.8)
	v.root.CFrame = v.root.CFrame * CFrame.Angles(0, 0, math.rad(90))
	emitter(v.root, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.foam, L.waterLight),
		size = seq(0, 0.6, 1, 0.2),
		lifetime = NumberRange.new(0.8, 1.2),
		speed = NumberRange.new(6, 10),
		rotSpeed = NumberRange.new(-300, 300),
		shape = Enum.ParticleEmitterShape.Cylinder,
		emission = 0.3,
		rate = 50,
	})
	v.update = function(_vis, dt)
		disc.CFrame = disc.CFrame * CFrame.Angles(math.rad(90) * dt, 0, 0)
	end
end

BUILD.ice_slide = function(v)
	v.fixed = true
	own(v, part({
		Size = v.part.Size,
		CFrame = v.part.CFrame,
		Color = L.ice,
		Material = Enum.Material.Ice,
		Transparency = 0.25,
		Reflectance = 0.2,
	}))
end

BUILD.permafrost = function(v)
	local radius = radiusOf(v, 8)
	v.fixed = true
	own(v, flatDisc(v.root.Position, radius, L.ice, 0.3, Enum.Material.Ice))
	v.root.Size = Vector3.new(radius * 1.5, 0.5, radius * 1.5)
	emitter(v.root, {
		texture = TEX.shard,
		color = ColorSequence.new(L.foam),
		size = seq(0, 0.3, 1, 0),
		lifetime = NumberRange.new(0.6, 1.2),
		speed = NumberRange.new(0.2, 1),
		rate = 16,
	})
end

BUILD.fog_bank = function(v)
	local radius = radiusOf(v, 10)
	v.fixed = true
	v.root.Size = Vector3.new(radius * 1.7, 6, radius * 1.7)
	emitter(v.root, {
		texture = TEX.smoke,
		color = ColorSequence.new(L.fog),
		size = seq(0, 6, 1, 11),
		transparency = seq(0, 0.25, 0.6, 0.35, 1, 1),
		lifetime = NumberRange.new(3, 4.5),
		speed = NumberRange.new(0.3, 1.2),
		spread = 80,
		emission = 0,
		rate = 14,
	})
end

BUILD.cleansing_rain = function(v)
	local radius = radiusOf(v, 8)
	v.fixed = true
	local sky = own(v, part({ Transparency = 1, Size = Vector3.new(radius * 1.6, 1, radius * 1.6), CFrame = CFrame.new(v.root.Position + UP * 18) }))
	emitter(sky, {
		texture = TEX.streak ~= "" and TEX.streak or TEX.sparkles,
		color = ColorSequence.new(L.pure),
		size = seq(0, 0.25, 1, 0.15),
		transparency = seq(0, 0.2, 1, 0.6),
		lifetime = NumberRange.new(0.8, 1),
		speed = NumberRange.new(20, 26),
		direction = Enum.NormalId.Bottom,
		emission = 0.4,
		rate = 70,
	})
	own(v, flatDisc(v.root.Position, radius, L.pure, 0.75))
end

BUILD.water_shield = function(v)
	local shell = own(v, part({
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * 6.5,
		Color = L.waterLight,
		Material = Enum.Material.Glass,
		Transparency = 0.7,
		Reflectance = 0.15,
	}))
	v.update = function(vis, _dt)
		local wobble = 1 + math.sin(os.clock() * 5) * 0.03
		shell.Size = Vector3.one * 6.5 * wobble
		shell.CFrame = CFrame.new(vis.root.Position)
	end
end

BUILD.fountain = function(v)
	v.fixed = true
	local spout = own(v, part({ Transparency = 1, Size = Vector3.new(1.5, 0.5, 1.5), CFrame = CFrame.new(v.root.Position) }))
	emitter(spout, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.foam, L.waterLight),
		size = seq(0, 0.7, 1, 0.3),
		transparency = seq(0, 0.1, 1, 0.8),
		lifetime = NumberRange.new(1.1, 1.5),
		speed = NumberRange.new(16, 22),
		spread = 14,
		acceleration = Vector3.new(0, -28, 0),
		emission = 0.3,
		rate = 120,
	})
	own(v, flatDisc(v.root.Position, 3, L.water, 0.4))
	local light = Instance.new("PointLight")
	light.Color = L.waterLight
	light.Range = 10
	light.Brightness = 0.6
	light.Parent = spout
	v.extra.next = 0
	v.update = function(vis, _dt)
		if os.clock() >= vis.extra.next then
			vis.extra.next = os.clock() + 0.6
			splash(vis.root.Position + Vector3.new(rng:NextNumber(-2.5, 2.5), 0.2, rng:NextNumber(-2.5, 2.5)), math.floor(rate(4)), 6)
		end
	end
end

A.register(BUILD)

return WaterFx
