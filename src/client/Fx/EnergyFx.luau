--!strict
--[[
	EnergyFx: what Energy's spells look like (docs/DomainIdeas.md, "Energy"). Cosmetic only: the server
	(Effects/EnergyArt, Cast/EnergyRuntime) decides everything. Three ways in:

		EnergyFx.cue(effect)      one-shot "energy" WorldEffect cues, by `fx`:
		    embers   embers arcing out of a burst onto the ground       whip   a lash of flame sweeping an arc
		    coil     fire coiling round someone                         spikes ice spikes erupting in a line
		    shatter  a lance breaking into shards                       mirror_turn  a bolt turning off the ice
		    steam    scalding steam                                     prism  coloured rays fanning out
		    reveal   a veil burnt away                                  flash  a blinding pop
		    glow     someone glowing a sickly green (seen through walls) grasp shadow hands round the feet
		    cloak    you darkening                                      puppet_strike  the shadow copying a blow
		    stomp    a shockwave along the ground                       ricochet  a bolt bouncing on
		    repel    a bolt curving off a Repulse                       slide  someone sliding, unable to stop
		    launch   a burst of force under someone                     zap / snap  lightning between two points
		    pop      a ball of lightning bursting                       arcs   sparks between pairs of bodies
		Bodies tagged "EnergyBody" (Cast/EnergyRuntime): lasting things, drawn by their EnergyLook attribute
		    while their part exists. Followers (an ObjectValue "Model") are drawn at that body's root every
		    frame, so they move smoothly; free bodies ease toward their part (a drifting ball of lightning).
		EnergyFx.flight(look, anchor, coreSize)   a projectile's own body (SpellFx.launch, route `look`):
		    serpent, lance, prism, ricochet, ball. Returns a stop function SpellFx calls when it lands.

	Reduce spell effects keeps what carries information (rings, fences, mirrors, tethers, the puppet)
	and thins the particles.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage").Shared
local E = require(Shared.Magic.Data.EnergyTuning)

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)
local DomainFx = require(script.Parent.DomainFx)
local FxLayers = require(script.Parent.FxLayers)

local TEX = DomainFx.textures
local L = E.looks
local UP = Vector3.new(0, 1, 0)

local EnergyFx = {}

local rng = Random.new()

local function reduced(): boolean
	return Theme.settings.reducedEffects == true
end

local function rate(n: number): number
	return if reduced() then n * 0.35 else n
end

local function holder(): Instance
	return workspace:FindFirstChild("MagicFx") or workspace
end

local function part(props: { [string]: any }): Part
	local p = Instance.new("Part")
	p.Name = "EnergyFx"
	p.Anchored = true
	p.CanCollide = false
	p.CanQuery = false
	p.CanTouch = false
	p.CastShadow = false
	p.Material = Enum.Material.Neon
	p.Size = Vector3.one * 0.4
	for k, v in props do
		(p :: any)[k] = v
	end
	if not props.Parent then
		p.Parent = holder()
	end
	return p
end

local function seq(...: number): NumberSequence
	return FxLayers.seq(...)
end

-- A plain (unpooled) emitter: bodies own theirs and are destroyed with them.
local function emitter(parent: Instance, spec: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Texture = spec.texture or TEX.sparkles
	e.Color = spec.color or ColorSequence.new(Color3.new(1, 1, 1))
	e.Size = spec.size or seq(0, 1, 1, 0)
	e.Transparency = spec.transparency or seq(0, 0, 1, 1)
	e.Lifetime = spec.lifetime or NumberRange.new(0.5, 1)
	e.Speed = spec.speed or NumberRange.new(0)
	local spread = spec.spread or 0
	e.SpreadAngle = Vector2.new(spread, spread)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = spec.rotSpeed or NumberRange.new(-40, 40)
	e.Acceleration = spec.acceleration or Vector3.zero
	e.Drag = spec.drag or 0
	e.LightEmission = spec.emission or 1
	e.LightInfluence = 0
	e.Shape = spec.shape or Enum.ParticleEmitterShape.Box
	e.ShapeStyle = spec.style or Enum.ParticleEmitterShapeStyle.Volume
	e.EmissionDirection = spec.direction or Enum.NormalId.Top
	e.Rate = rate(spec.rate or 10)
	e.LockedToPart = spec.locked == true
	e.ZOffset = spec.zOffset or 0
	e.Parent = parent
	return e
end

local function burst(position: Vector3, spec: { [string]: any }, count: number, life: number?)
	local p = part({ Transparency = 1, Size = spec.box or Vector3.one, CFrame = CFrame.new(position) })
	local e = emitter(p, spec)
	e.Rate = 0
	e:Emit(math.max(1, math.floor(rate(count))))
	Debris:AddItem(p, life or 2)
end

local function fadeOut(p: BasePart, seconds: number, grow: Vector3?)
	local goal: { [string]: any } = { Transparency = 1 }
	if grow then
		goal.Size = grow
	end
	TweenService:Create(p, TweenInfo.new(seconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), goal):Play()
	Debris:AddItem(p, seconds + 0.05)
end

local function rootOf(model: any): BasePart?
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return nil
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function flatDisc(center: Vector3, radius: number, color: Color3, transparency: number, material: Enum.Material?): Part
	return part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.15, radius * 2, radius * 2),
		CFrame = CFrame.new(center + Vector3.new(0, 0.08, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = color,
		Transparency = transparency,
		Material = material or Enum.Material.Neon,
	})
end

-- A jagged bolt of lightning between two points, gone in a blink.
local function bolt(a: Vector3, b: Vector3, color: Color3, width: number, life: number)
	local d = b - a
	local length = d.Magnitude
	if length < 0.2 then
		return
	end
	local n = math.clamp(math.floor(length / 3), 3, 12)
	local side = d:Cross(UP)
	side = if side.Magnitude > 0.01 then side.Unit else Vector3.new(1, 0, 0)
	local up2 = side:Cross(d.Unit)
	local prev = a
	for i = 1, n do
		local t = i / n
		local point = a + d * t
		if i < n then
			local jitter = length * 0.06
			point += side * rng:NextNumber(-jitter, jitter) + up2 * rng:NextNumber(-jitter, jitter)
		end
		local seg = point - prev
		local p = part({
			Size = Vector3.new(width, width, seg.Magnitude),
			CFrame = CFrame.lookAt(prev + seg / 2, point),
			Color = color,
		})
		fadeOut(p, life)
		prev = point
	end
	FxLayers.light(a:Lerp(b, 0.5), color, 3, math.clamp(length, 8, 24), life + 0.1, 0.5)
end

local function sound(position: Vector3, property: string, which: string, volume: number?)
	local look = DomainFx.look("energy", property)
	local s = (look.sounds :: any)[which]
	if s then
		FxLayers.sound(position, s, volume or 0.7)
	end
end

-- ─── One-shot cues ──────────────────────────────────────────────────────────

local function embers(cue: any)
	local from: Vector3 = cue.from
	burst(from, {
		texture = TEX.fireSparks,
		color = ColorSequence.new(L.fireHot, L.fire),
		size = seq(0, 0.6, 1, 0),
		lifetime = NumberRange.new(0.4, 0.8),
		speed = NumberRange.new(14, 28),
		spread = 180,
		acceleration = Vector3.new(0, -30, 0),
	}, 40)
	FxLayers.light(from, L.fire, 4, 18, 0.6, 0.6)
	sound(from, "combustion", "impact")
	for _, spot in (cue.spots or {}) :: { Vector3 } do
		local p = part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 0.5, Color = L.ember, CFrame = CFrame.new(from) })
		emitter(p, {
			texture = TEX.fire,
			color = ColorSequence.new(L.fireHot, L.fire),
			size = seq(0, 0.9, 1, 0),
			lifetime = NumberRange.new(0.2, 0.35),
			rate = 40,
		})
		local apex = (from + spot) / 2 + UP * rng:NextNumber(5, 10)
		local duration = 0.55 + rng:NextNumber() * 0.25
		FxLayers.animate(duration, function(t)
			local q = from:Lerp(apex, t):Lerp(apex:Lerp(spot, t), t)
			p.CFrame = CFrame.new(q)
		end, function()
			burst(spot, {
				texture = TEX.fire,
				color = ColorSequence.new(L.fireHot, L.fire),
				size = seq(0, 1.2, 1, 0),
				lifetime = NumberRange.new(0.3, 0.6),
				speed = NumberRange.new(2, 6),
				spread = 60,
			}, 8)
			p:Destroy()
		end)
	end
end

local function whip(cue: any)
	local from: Vector3 = cue.from + UP * 1.5
	local dir: Vector3 = cue.dir
	local reach: number = cue.reach or 12
	local arc: number = cue.arc or 110
	local tip = part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 0.7, Color = L.fireHot })
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, 0.5, 0)
	a0.Parent = tip
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -0.5, 0)
	a1.Parent = tip
	local trail = Instance.new("Trail")
	trail.Attachment0, trail.Attachment1 = a0, a1
	trail.Lifetime = 0.35
	trail.Color = ColorSequence.new(L.fireHot, L.fire)
	trail.Transparency = seq(0, 0, 1, 1)
	trail.LightEmission = 1
	trail.FaceCamera = true
	trail.WidthScale = seq(0, 1.4, 1, 0)
	trail.Texture = TEX.streak
	trail.Parent = tip
	emitter(tip, {
		texture = TEX.fire,
		color = ColorSequence.new(L.fireHot, L.fire),
		size = seq(0, 1.4, 1, 0),
		lifetime = NumberRange.new(0.2, 0.4),
		speed = NumberRange.new(1, 3),
		spread = 180,
		rate = 120,
	})
	sound(from, "combustion", "launch")
	FxLayers.animate(0.22, function(t)
		local angle = (t - 0.5) * arc
		local out = CFrame.Angles(0, math.rad(-angle), 0):VectorToWorldSpace(dir)
		-- The lash goes out and comes back a little as it sweeps.
		local r = reach * (0.55 + 0.45 * math.sin(t * math.pi))
		tip.CFrame = CFrame.new(from + out * r + UP * math.sin(t * math.pi) * 1.2)
	end, function()
		task.delay(0.4, function()
			tip:Destroy()
		end)
	end)
end

local function coil(cue: any)
	local center: Vector3 = cue.at
	local ring = part({ Transparency = 1, CFrame = CFrame.new(center) })
	for i = 1, 8 do
		local a = Instance.new("Attachment")
		local angle = i / 8 * math.pi * 2
		a.Position = Vector3.new(math.cos(angle) * 2, (i % 3) - 1, math.sin(angle) * 2)
		a.Parent = ring
		local e = emitter(a, {
			texture = TEX.fire,
			color = ColorSequence.new(L.fireHot, L.fire),
			size = seq(0, 1.2, 1, 0),
			lifetime = NumberRange.new(0.25, 0.45),
			speed = NumberRange.new(2, 4),
			spread = 20,
		})
		e.Rate = 0
		e:Emit(math.floor(rate(6)))
	end
	FxLayers.light(center, L.fire, 3, 12, 0.4, 0.5)
	FxLayers.animate(0.4, function(t)
		ring.CFrame = CFrame.new(center) * CFrame.Angles(0, t * math.pi * 2, 0)
	end)
	Debris:AddItem(ring, 1.2)
end

local function spikes(cue: any)
	local delay: number = cue.delay or 0.07
	local radius: number = cue.radius or 3
	for i, spot in (cue.spots or {}) :: { Vector3 } do
		task.delay(i * delay, function()
			local height = 4 + rng:NextNumber() * 3
			local tilt = CFrame.Angles(rng:NextNumber(-0.25, 0.25), rng:NextNumber(0, math.pi * 2), rng:NextNumber(-0.25, 0.25))
			for k = 1, 3 do
				local h = height * (if k == 1 then 1 else 0.55)
				local offset = if k == 1 then Vector3.zero else Vector3.new(rng:NextNumber(-radius, radius) * 0.4, 0, rng:NextNumber(-radius, radius) * 0.4)
				local base = CFrame.new(spot + offset) * tilt
				local spike = part({
					Size = Vector3.new(0.9, 0.2, 0.9),
					CFrame = base,
					Color = L.ice,
					Material = Enum.Material.Ice,
					Transparency = 0.15,
				})
				local mesh = Instance.new("SpecialMesh")
				mesh.MeshType = Enum.MeshType.FileMesh
				mesh.MeshId = "rbxassetid://1033714" -- Roblox's built-in cone
				mesh.Scale = Vector3.new(1.2, h, 1.2)
				mesh.Parent = spike
				spike.Size = Vector3.new(1, h, 1)
				FxLayers.animate(0.12, function(t)
					spike.CFrame = base * CFrame.new(0, -h / 2 + h / 2 * t, 0)
				end)
				task.delay(1.4 + rng:NextNumber() * 0.4, function()
					fadeOut(spike, 0.5)
				end)
			end
			burst(spot, {
				texture = TEX.shard,
				color = ColorSequence.new(L.frost, L.ice),
				size = seq(0, 0.5, 1, 0),
				lifetime = NumberRange.new(0.4, 0.8),
				speed = NumberRange.new(6, 14),
				spread = 70,
				acceleration = Vector3.new(0, -40, 0),
			}, 10)
		end)
	end
	if cue.spots and cue.spots[1] then
		sound(cue.spots[1], "temperature", "impact")
	end
end

local function shatter(cue: any)
	local at: Vector3 = cue.at
	burst(at, {
		texture = TEX.shard,
		color = ColorSequence.new(L.frost, L.iceDeep),
		size = seq(0, 0.8, 1, 0),
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(14, 30),
		spread = 180,
		acceleration = Vector3.new(0, -50, 0),
	}, 40)
	FxLayers.flash(at, 2.5, L.ice, 0.25)
	FxLayers.shockwave(at, UP, cue.radius or 6, L.frost, 0.4)
	sound(at, "temperature", "impact")
end

local function steam(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 8
	burst(at, {
		texture = TEX.smoke,
		color = ColorSequence.new(L.steam),
		size = seq(0, 3, 1, radius * 0.9),
		transparency = seq(0, 0.2, 1, 1),
		lifetime = NumberRange.new(1.4, 2.4),
		speed = NumberRange.new(4, 12),
		spread = 80,
		acceleration = Vector3.new(0, 4, 0),
		drag = 1.5,
		emission = 0.2,
	}, 36, 3)
end

local function prism(cue: any)
	local from: Vector3 = cue.from
	local colors = L.prism
	for i, to in (cue.ends or {}) :: { Vector3 } do
		local c = colors[((i - 1) % #colors) + 1]
		local d = to - from
		local beam = part({
			Size = Vector3.new(0.35, 0.35, d.Magnitude),
			CFrame = CFrame.lookAt(from + d / 2, to),
			Color = c,
			Transparency = 0.1,
		})
		fadeOut(beam, 0.45, Vector3.new(0.05, 0.05, d.Magnitude))
	end
	FxLayers.flash(from, 2, L.light, 0.25)
	FxLayers.light(from, L.light, 5, 20, 0.5)
end

local function flash(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 12
	FxLayers.flash(at, math.min(6, radius * 0.4), L.light, 0.35)
	FxLayers.light(at, L.light, 12, math.min(60, radius * 2.5), 0.6)
	FxLayers.shockwave(at, UP, radius, L.light, 0.35)
	sound(at, "luminosity", "impact")
end

local function glow(cue: any)
	local model = cue.model
	if typeof(model) ~= "Instance" or not model:IsA("Model") then
		return
	end
	local old = model:FindFirstChild("EnergyGlow")
	if old then
		old:Destroy()
	end
	local h = Instance.new("Highlight")
	h.Name = "EnergyGlow"
	h.FillColor = L.radiation
	h.OutlineColor = L.radiation
	h.FillTransparency = 0.65
	h.OutlineTransparency = 0.1
	h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
	h.Parent = model
	Debris:AddItem(h, math.clamp(tonumber(cue.seconds) or 8, 1, 20))
end

local function grasp(cue: any)
	local at: Vector3 = cue.at
	local seconds = math.clamp(tonumber(cue.seconds) or 1.5, 0.5, 4)
	for i = 1, 5 do
		local angle = i / 5 * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local base = at + Vector3.new(math.cos(angle) * 1.2, 0, math.sin(angle) * 1.2)
		local hand = part({
			Size = Vector3.new(0.35, 2.4, 0.35),
			CFrame = CFrame.lookAt(base, at + UP * 2) * CFrame.Angles(math.rad(-90), 0, 0) * CFrame.new(0, -1.2, 0),
			Color = L.shadow,
			Material = Enum.Material.SmoothPlastic,
			Transparency = 0.1,
		})
		local from = hand.CFrame
		FxLayers.animate(0.18, function(t)
			hand.CFrame = from * CFrame.new(0, 2.2 * t, 0)
		end)
		task.delay(seconds, function()
			fadeOut(hand, 0.3)
		end)
	end
	burst(at, {
		texture = TEX.smoke,
		color = ColorSequence.new(L.shadow, L.shadowEdge),
		size = seq(0, 2, 1, 3),
		transparency = seq(0, 0.3, 1, 1),
		lifetime = NumberRange.new(0.6, 1.2),
		speed = NumberRange.new(1, 3),
		spread = 60,
		emission = 0,
	}, 14)
end

local function cloak(cue: any)
	local root = rootOf(cue.model)
	if not root then
		return
	end
	burst(root.Position, {
		texture = TEX.smoke,
		color = ColorSequence.new(L.shadow, L.shadowEdge),
		size = seq(0, 3, 1, 5),
		transparency = seq(0, 0.25, 1, 1),
		lifetime = NumberRange.new(0.8, 1.4),
		speed = NumberRange.new(2, 5),
		spread = 180,
		emission = 0,
		box = Vector3.new(2, 4, 2),
	}, 24)
end

local function puppetStrike(cue: any)
	local from: Vector3 = cue.from + UP
	local to: Vector3 = cue.to
	local d = to - from
	local slash = part({
		Size = Vector3.new(0.5, 0.15, d.Magnitude),
		CFrame = CFrame.lookAt(from + d / 2, to),
		Color = L.shadowEdge,
		Material = Enum.Material.SmoothPlastic,
	})
	fadeOut(slash, 0.3)
	burst(to, {
		texture = TEX.smoke,
		color = ColorSequence.new(L.shadow, L.shadowEdge),
		size = seq(0, 1.5, 1, 0),
		lifetime = NumberRange.new(0.3, 0.6),
		speed = NumberRange.new(4, 9),
		spread = 180,
		emission = 0,
	}, 10)
end

local function stomp(cue: any)
	local at: Vector3 = cue.at
	local radius: number = cue.radius or 10
	FxLayers.shockwave(at, UP, radius, L.force, 0.45)
	burst(at, {
		texture = TEX.dust,
		color = ColorSequence.new(Color3.fromRGB(150, 130, 110)),
		size = seq(0, 2, 1, 4),
		transparency = seq(0, 0.3, 1, 1),
		lifetime = NumberRange.new(0.6, 1.1),
		speed = NumberRange.new(10, radius * 2),
		spread = 10,
		direction = Enum.NormalId.Top,
		emission = 0,
		acceleration = Vector3.new(0, -6, 0),
		box = Vector3.new(radius, 0.5, radius),
	}, 30)
	sound(at, "momentum", "impact", 1)
end

local function ricochet(cue: any)
	local from: Vector3 = cue.from
	local to: Vector3 = cue.to
	local d = to - from
	local streak = part({ Size = Vector3.new(0.3, 0.3, d.Magnitude), CFrame = CFrame.lookAt(from + d / 2, to), Color = L.force })
	fadeOut(streak, 0.25, Vector3.new(0.05, 0.05, d.Magnitude))
	FxLayers.flash(to, 1.4, L.force, 0.2)
	sound(to, "momentum", "impact", 0.5)
end

local function smallRing(at: Vector3, color: Color3)
	FxLayers.shockwave(at, UP, 3, color, 0.25)
	FxLayers.flash(at, 1, color, 0.15)
end

local function slide(cue: any)
	local root = rootOf(cue.model)
	if not root then
		return
	end
	local a0 = Instance.new("Attachment")
	a0.Position = Vector3.new(0, -2.5, 0)
	a0.Parent = root
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, 0.5, 0)
	a1.Parent = root
	local trail = Instance.new("Trail")
	trail.Attachment0, trail.Attachment1 = a0, a1
	trail.Lifetime = 0.5
	trail.Color = ColorSequence.new(L.force)
	trail.Transparency = seq(0, 0.3, 1, 1)
	trail.LightEmission = 1
	trail.Parent = root
	local seconds = math.clamp(tonumber(cue.seconds) or 1.5, 0.3, 4)
	Debris:AddItem(trail, seconds + 0.5)
	Debris:AddItem(a0, seconds + 0.5)
	Debris:AddItem(a1, seconds + 0.5)
end

local function launchFx(cue: any)
	local at: Vector3 = cue.at
	FxLayers.shockwave(at - UP * 2.5, UP, 5, L.force, 0.35)
	burst(at - UP * 2.5, {
		texture = TEX.dust,
		color = ColorSequence.new(L.force),
		size = seq(0, 1.5, 1, 3),
		transparency = seq(0, 0.4, 1, 1),
		lifetime = NumberRange.new(0.4, 0.8),
		speed = NumberRange.new(6, 14),
		spread = 50,
		emission = 0.5,
	}, 16)
	sound(at, "momentum", "launch")
end

local function pop(cue: any)
	local at: Vector3 = cue.at
	FxLayers.flash(at, 3, L.chargeHot, 0.25)
	for _ = 1, 6 do
		local dir = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-0.3, 1), rng:NextNumber(-1, 1))
		if dir.Magnitude > 0.1 then
			bolt(at, at + dir.Unit * (cue.radius or 6), L.charge, 0.2, 0.18)
		end
	end
	sound(at, "charge", "impact", 0.9)
end

local CUES: { [string]: (any) -> () } = {
	embers = embers,
	whip = whip,
	coil = coil,
	spikes = spikes,
	shatter = shatter,
	mirror_turn = function(cue: any)
		smallRing(cue.at, L.ice)
	end,
	steam = steam,
	prism = prism,
	reveal = function(cue: any)
		burst(cue.at, { texture = TEX.sparkles, color = ColorSequence.new(L.light), size = seq(0, 0.8, 1, 0), lifetime = NumberRange.new(0.4, 0.8), speed = NumberRange.new(2, 6), spread = 180 }, 16)
	end,
	flash = flash,
	glow = glow,
	grasp = grasp,
	cloak = cloak,
	puppet_strike = puppetStrike,
	stomp = stomp,
	ricochet = ricochet,
	repel = function(cue: any)
		smallRing(cue.at, L.force)
	end,
	slide = slide,
	launch = launchFx,
	zap = function(cue: any)
		bolt(cue.from, cue.to, L.charge, 0.18, 0.15)
		sound(cue.to, "charge", "impact", 0.4)
	end,
	snap = function(cue: any)
		bolt(cue.from, cue.to, L.chargeHot, 0.35, 0.3)
		FxLayers.flash((cue.from + cue.to) / 2, 2.5, L.chargeHot, 0.25)
		sound(cue.to, "charge", "impact", 1)
	end,
	pop = pop,
	arcs = function(cue: any)
		local points = cue.points or {}
		for i = 1, #points - 1, 2 do
			bolt(points[i], points[i + 1], L.charge, 0.15, 0.2)
		end
	end,
}

function EnergyFx.cue(cue: { [string]: any })
	local fn = CUES[cue.fx]
	if not fn then
		return
	end
	local ok, err = pcall(fn, cue)
	if not ok then
		warn("[EnergyFx] " .. tostring(cue.fx) .. ": " .. tostring(err))
	end
end

-- ─── Lasting bodies ─────────────────────────────────────────────────────────

type Visual = {
	part: BasePart, -- the server's body part
	root: Part, -- our own, moved every frame
	model: Model?, -- a follower's body
	look: string,
	extra: { [string]: any }, -- state a look keeps between frames
	owned: { Instance }, -- everything it made, destroyed with it
	update: ((Visual, number) -> ())?,
}

local function own<T>(v: Visual, inst: T): T
	table.insert(v.owned, inst :: any)
	return inst
end

local visuals: { [BasePart]: Visual } = {}

local function anchorPart(at: CFrame): Part
	return part({ Transparency = 1, Size = Vector3.one, CFrame = at })
end

local function linked(bodyPart: BasePart, name: string): Instance?
	local v = bodyPart:FindFirstChild(name)
	return if v and v:IsA("ObjectValue") then v.Value else nil
end

local function limb(model: Model, names: { string }): BasePart?
	for _, n in names do
		local p = model:FindFirstChild(n)
		if p and p:IsA("BasePart") then
			return p
		end
	end
	return nil
end

local BUILD: { [string]: (Visual) -> () } = {}

BUILD.ring_of_fire = function(v)
	local radius = v.part:GetAttribute("Radius") :: number? or 8
	local center = v.root.Position
	own(v, part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(0.2, radius * 2 + 1.5, radius * 2 + 1.5),
		CFrame = CFrame.new(center + Vector3.new(0, 0.1, 0)) * CFrame.Angles(0, 0, math.rad(90)),
		Color = L.fire,
		Transparency = 0.82,
	}))
	local count = math.clamp(math.floor(radius * 2.2), 12, 30)
	for i = 1, count do
		local a = Instance.new("Attachment")
		local angle = i / count * math.pi * 2
		a.Position = Vector3.new(math.cos(angle) * radius, 0.3, math.sin(angle) * radius)
		a.Parent = v.root
		emitter(a, {
			texture = TEX.fire,
			color = ColorSequence.new(L.fireHot, L.fire),
			size = seq(0, 2.2, 1, 0.4),
			transparency = seq(0, 0.1, 1, 1),
			lifetime = NumberRange.new(0.5, 0.9),
			speed = NumberRange.new(3, 6),
			spread = 12,
			rate = 9,
		})
	end
	local light = Instance.new("PointLight")
	light.Color = L.fire
	light.Range = math.min(40, radius * 2.5)
	light.Brightness = 2
	light.Parent = v.root
end

BUILD.smother = function(v)
	local radius = v.part:GetAttribute("Radius") :: number? or 8
	v.root.Size = Vector3.new(radius * 1.6, 3, radius * 1.6)
	emitter(v.root, {
		texture = TEX.smoke,
		color = ColorSequence.new(L.smoke, Color3.fromRGB(70, 66, 62)),
		size = seq(0, 4, 1, 9),
		transparency = seq(0, 0.15, 0.7, 0.3, 1, 1),
		lifetime = NumberRange.new(2, 3.5),
		speed = NumberRange.new(0.5, 2),
		spread = 60,
		acceleration = Vector3.new(0, 1.2, 0),
		emission = 0,
		rate = 18,
		rotSpeed = NumberRange.new(-20, 20),
	})
end

BUILD.kindle = function(v)
	local model = v.model
	if not model then
		return
	end
	for _, names in { { "Right Arm", "RightHand" }, { "Left Arm", "LeftHand" } } do
		local arm = limb(model, names)
		if arm then
			local a = Instance.new("Attachment")
			a.Name = "EnergyKindle"
			a.Position = Vector3.new(0, -arm.Size.Y / 2, 0)
			a.Parent = arm
			emitter(a, {
				texture = TEX.fire,
				color = ColorSequence.new(L.fireHot, L.fire),
				size = seq(0, 1, 1, 0),
				lifetime = NumberRange.new(0.25, 0.45),
				speed = NumberRange.new(1, 3),
				spread = 25,
				rate = 30,
			})
			own(v, a)
		end
	end
end

BUILD.hoarfrost = function(v)
	local radius = v.part:GetAttribute("Radius") :: number? or 8
	own(v, flatDisc(v.root.Position, radius, L.frost, 0.45, Enum.Material.Ice))
	v.root.Size = Vector3.new(radius * 1.6, 0.5, radius * 1.6)
	emitter(v.root, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.frost),
		size = seq(0, 0.35, 1, 0),
		lifetime = NumberRange.new(0.6, 1.2),
		speed = NumberRange.new(0.2, 0.8),
		rate = 14,
	})
end

BUILD.ice_mirror = function(v)
	local pane = part({
		Size = v.part.Size,
		CFrame = v.part.CFrame,
		Color = L.ice,
		Material = Enum.Material.Glass,
		Transparency = 0.45,
		Reflectance = 0.35,
	})
	own(v, pane)
	emitter(pane, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.frost),
		size = seq(0, 0.4, 1, 0),
		lifetime = NumberRange.new(0.5, 1),
		rate = 10,
	})
	pane.Size = Vector3.new(v.part.Size.X, 0.2, v.part.Size.Z)
	local full = v.part.Size
	local cf = v.part.CFrame
	FxLayers.animate(0.25, function(t)
		pane.Size = Vector3.new(full.X, math.max(0.2, full.Y * t), full.Z)
		pane.CFrame = cf * CFrame.new(0, -full.Y / 2 + full.Y * t / 2, 0)
	end)
end

BUILD.flurry = function(v)
	local radius = v.part:GetAttribute("Radius") :: number? or 8
	v.root.Shape = Enum.PartType.Ball
	v.root.Size = Vector3.one * radius * 1.6
	emitter(v.root, {
		texture = TEX.sparkles,
		color = ColorSequence.new(L.frost, L.ice),
		size = seq(0, 0.45, 1, 0.2),
		lifetime = NumberRange.new(1, 1.6),
		speed = NumberRange.new(4, 8),
		rotSpeed = NumberRange.new(-200, 200),
		shape = Enum.ParticleEmitterShape.Sphere,
		acceleration = Vector3.new(0, -2, 0),
		rate = 60,
		emission = 0.6,
	})
end

BUILD.heat_haze = function(v)
	v.root.Size = Vector3.new(4, 6, 4)
	emitter(v.root, {
		texture = TEX.glow,
		color = ColorSequence.new(L.heat),
		size = seq(0, 3, 1, 5),
		transparency = seq(0, 0.9, 0.5, 0.82, 1, 1),
		lifetime = NumberRange.new(0.8, 1.3),
		speed = NumberRange.new(1, 3),
		acceleration = Vector3.new(0, 3, 0),
		emission = 0.4,
		rate = 16,
	})
end

BUILD.searing_ground = function(v)
	local radius = v.part:GetAttribute("Radius") :: number? or 8
	own(v, flatDisc(v.root.Position, radius, Color3.fromRGB(200, 60, 20), 0.55))
	v.root.Size = Vector3.new(radius * 1.6, 0.5, radius * 1.6)
	emitter(v.root, {
		texture = TEX.fireSparks,
		color = ColorSequence.new(L.fireHot, L.fire),
		size = seq(0, 0.35, 1, 0),
		lifetime = NumberRange.new(0.8, 1.6),
		speed = NumberRange.new(2, 5),
		acceleration = Vector3.new(0, 2, 0),
		rate = 24,
	})
	local light = Instance.new("PointLight")
	light.Color = L.fire
	light.Range = math.min(36, radius * 2.2)
	light.Brightness = 1.5
	light.Parent = v.root
end

BUILD.sunspot = function(v)
	local radius = v.part:GetAttribute("Radius") :: number? or 8
	local height = 60
	own(v, part({
		Shape = Enum.PartType.Cylinder,
		Size = Vector3.new(height, radius * 2, radius * 2),
		CFrame = CFrame.new(v.root.Position + UP * height / 2) * CFrame.Angles(0, 0, math.rad(90)),
		Color = L.sun,
		Transparency = 0.82,
	}))
	own(v, flatDisc(v.root.Position, radius, L.sun, 0.6))
	local top = own(v, anchorPart(CFrame.new(v.root.Position + UP * 24)))
	top.Size = Vector3.new(radius * 1.6, 1, radius * 1.6)
	emitter(top, {
		texture = TEX.mote,
		color = ColorSequence.new(L.light),
		size = seq(0, 0.4, 1, 0.1),
		lifetime = NumberRange.new(2, 3),
		speed = NumberRange.new(6, 10),
		direction = Enum.NormalId.Bottom,
		rate = 20,
	})
	local light = Instance.new("PointLight")
	light.Color = L.sun
	light.Range = math.min(40, radius * 2.6)
	light.Brightness = 3
	light.Parent = v.root
end

BUILD.wisps = function(v)
	local count = math.clamp((v.part:GetAttribute("Count") :: number?) or 3, 1, 6)
	v.extra.motes = {}
	for _ = 1, count do
		local mote = own(v, part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 0.5, Color = L.light, Transparency = 0.1 }))
		emitter(mote, {
			texture = TEX.glow,
			color = ColorSequence.new(L.light),
			size = seq(0, 1.4, 1, 0),
			transparency = seq(0, 0.4, 1, 1),
			lifetime = NumberRange.new(0.3, 0.5),
			locked = true,
			rate = 12,
		})
		local light = Instance.new("PointLight")
		light.Color = L.light
		light.Range = 12
		light.Brightness = 1.2
		light.Parent = mote
		table.insert(v.extra.motes, mote)
	end
	v.update = function(vis, _dt)
		local t = os.clock()
		for i, mote in vis.extra.motes do
			local angle = t * 1.4 + i / #vis.extra.motes * math.pi * 2
			mote.CFrame = CFrame.new(vis.root.Position + Vector3.new(math.cos(angle) * 2.6, 2.4 + math.sin(t * 2 + i) * 0.5, math.sin(angle) * 2.6))
		end
	end
end

-- A flat black figure: a head, a body, two arms, two legs.
BUILD.shadow_puppet = function(v)
	local pieces = {
		{ Vector3.new(1.2, 1.2, 0.2), Vector3.new(0, 1.5, 0) },
		{ Vector3.new(2, 2, 0.2), Vector3.new(0, 0, 0) },
		{ Vector3.new(0.9, 2, 0.2), Vector3.new(-1.5, 0, 0) },
		{ Vector3.new(0.9, 2, 0.2), Vector3.new(1.5, 0, 0) },
		{ Vector3.new(0.9, 2, 0.2), Vector3.new(-0.5, -2, 0) },
		{ Vector3.new(0.9, 2, 0.2), Vector3.new(0.5, -2, 0) },
	}
	v.extra.pieces = {}
	for _, piece in pieces do
		local p = own(v, part({ Size = piece[1], Color = L.shadow, Material = Enum.Material.SmoothPlastic, Transparency = 0.15 }))
		table.insert(v.extra.pieces, { part = p, offset = piece[2] })
	end
	emitter(v.root, {
		texture = TEX.smoke,
		color = ColorSequence.new(L.shadow, L.shadowEdge),
		size = seq(0, 1.2, 1, 2),
		transparency = seq(0, 0.5, 1, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(0.5, 1.5),
		emission = 0,
		rate = 10,
	})
	v.update = function(vis, _dt)
		local root = vis.model and rootOf(vis.model)
		local facing = if root then root.CFrame.LookVector else Vector3.new(0, 0, -1)
		local frame = CFrame.lookAt(vis.root.Position, vis.root.Position + Vector3.new(facing.X, 0, facing.Z))
		for _, entry in vis.extra.pieces do
			entry.part.CFrame = frame * CFrame.new(entry.offset)
		end
	end
end

BUILD.repulse = function(v)
	local radius = v.part:GetAttribute("Radius") :: number? or 9
	local shell = own(v, part({
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * radius * 2,
		Color = L.force,
		Material = Enum.Material.ForceField,
		Transparency = 0.6,
	}))
	v.update = function(vis, _dt)
		shell.CFrame = CFrame.new(vis.root.Position)
	end
end

BUILD.ball_lightning = function(v)
	local ball = own(v, part({ Shape = Enum.PartType.Ball, Size = Vector3.one * 1.8, Color = L.chargeHot, Transparency = 0.1 }))
	emitter(ball, {
		texture = TEX.crackle,
		color = ColorSequence.new(L.chargeHot, L.charge),
		size = seq(0, 1.4, 1, 0),
		lifetime = NumberRange.new(0.1, 0.25),
		speed = NumberRange.new(4, 10),
		spread = 180,
		rate = 50,
	})
	local light = Instance.new("PointLight")
	light.Color = L.charge
	light.Range = 16
	light.Brightness = 3
	light.Parent = ball
	v.extra.nextArc = 0
	v.update = function(vis, _dt)
		local t = os.clock()
		ball.CFrame = CFrame.new(vis.root.Position + UP * math.sin(t * 6) * 0.3)
		ball.Size = Vector3.one * (1.6 + math.sin(t * 23) * 0.25)
		if t >= vis.extra.nextArc and not reduced() then
			vis.extra.nextArc = t + 0.12
			local dir = Vector3.new(rng:NextNumber(-1, 1), rng:NextNumber(-1, 1), rng:NextNumber(-1, 1))
			if dir.Magnitude > 0.1 then
				bolt(ball.Position, ball.Position + dir.Unit * 2.5, L.charge, 0.08, 0.08)
			end
		end
	end
end

BUILD.static_field = function(v)
	local radius = v.part:GetAttribute("Radius") :: number? or 8
	own(v, flatDisc(v.root.Position, radius, L.charge, 0.85))
	v.root.Size = Vector3.new(radius * 1.6, 3, radius * 1.6)
	emitter(v.root, {
		texture = TEX.crackle,
		color = ColorSequence.new(L.chargeHot, L.charge),
		size = seq(0, 0.5, 1, 0),
		lifetime = NumberRange.new(0.1, 0.3),
		speed = NumberRange.new(1, 4),
		spread = 180,
		rate = 30,
	})
	v.extra.nextArc = 0
	v.update = function(vis, _dt)
		local t = os.clock()
		if t >= vis.extra.nextArc and not reduced() then
			vis.extra.nextArc = t + 0.25
			local center = vis.root.Position
			local a = center + Vector3.new(rng:NextNumber(-radius, radius) * 0.7, 0.3, rng:NextNumber(-radius, radius) * 0.7)
			bolt(a, a + Vector3.new(rng:NextNumber(-3, 3), rng:NextNumber(0.5, 2.5), rng:NextNumber(-3, 3)), L.charge, 0.08, 0.1)
		end
	end
end

BUILD.arc_tether = function(v)
	local a = linked(v.part, "A")
	local b = linked(v.part, "B")
	if not (a and a:IsA("BasePart") and b and b:IsA("BasePart")) then
		return
	end
	local a0 = Instance.new("Attachment")
	a0.Parent = a
	local a1 = Instance.new("Attachment")
	a1.Parent = b
	local beam = Instance.new("Beam")
	beam.Attachment0, beam.Attachment1 = a0, a1
	beam.Color = ColorSequence.new(L.chargeHot, L.charge)
	beam.LightEmission = 1
	beam.Width0, beam.Width1 = 0.5, 0.5
	beam.FaceCamera = true
	beam.Segments = 12
	beam.Texture = TEX.lightning
	beam.TextureSpeed = 4
	beam.Parent = a0
	own(v, a0)
	own(v, a1)
	v.update = function(_vis, _dt)
		beam.CurveSize0 = rng:NextNumber(-2, 2)
		beam.CurveSize1 = rng:NextNumber(-2, 2)
		beam.Width0 = rng:NextNumber(0.3, 0.7)
	end
end

BUILD.galvanise = function(v)
	v.root.Size = Vector3.new(2, 0.5, 2)
	emitter(v.root, {
		texture = TEX.crackle,
		color = ColorSequence.new(L.chargeHot, L.charge),
		size = seq(0, 0.6, 1, 0),
		lifetime = NumberRange.new(0.15, 0.3),
		speed = NumberRange.new(3, 7),
		spread = 60,
		rate = 30,
	})
	v.update = function(vis, _dt)
		vis.root.CFrame = CFrame.new(vis.root.Position - UP * 2.6)
	end
end

BUILD.arc_fence = function(v)
	local frame = v.part.CFrame
	local half = v.part.Size.X / 2
	local posts: { Attachment } = {}
	local count = math.clamp(math.floor(v.part.Size.X / 6) + 1, 2, 5)
	for i = 0, count - 1 do
		local x = -half + (2 * half) * i / (count - 1)
		local post = part({
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(5, 0.5, 0.5),
			CFrame = frame * CFrame.new(x, 0, 0) * CFrame.Angles(0, 0, math.rad(90)),
			Color = Color3.fromRGB(60, 70, 90),
			Material = Enum.Material.Metal,
		})
		own(v, post)
		for _, h in { 2.2, 0.4, -1.4 } do
			local a = Instance.new("Attachment")
			a.Position = Vector3.new(h, 0, 0)
			a.Parent = post
			table.insert(posts, a)
		end
	end
	local beams: { Beam } = {}
	for i = 1, #posts - 3 do
		local beam = Instance.new("Beam")
		beam.Attachment0, beam.Attachment1 = posts[i], posts[i + 3]
		beam.Color = ColorSequence.new(L.chargeHot, L.charge)
		beam.LightEmission = 1
		beam.Width0, beam.Width1 = 0.25, 0.25
		beam.FaceCamera = true
		beam.Segments = 10
		beam.Texture = TEX.lightning
		beam.TextureSpeed = 3
		beam.Parent = posts[i]
		table.insert(beams, beam)
	end
	v.update = function(_vis, _dt)
		for _, beam in beams do
			beam.CurveSize0 = rng:NextNumber(-0.8, 0.8)
			beam.CurveSize1 = rng:NextNumber(-0.8, 0.8)
		end
	end
end

local function cleanup(v: Visual)
	v.root:Destroy()
	for _, inst in v.owned do
		inst:Destroy()
	end
	table.clear(v.owned)
end

local function build(bodyPart: Instance)
	if not bodyPart:IsA("BasePart") or visuals[bodyPart] then
		return
	end
	local look = bodyPart:GetAttribute("EnergyLook")
	local builder = if typeof(look) == "string" then BUILD[look] else nil
	if not builder then
		return
	end
	local model = linked(bodyPart, "Model")
	local v: Visual = {
		part = bodyPart,
		root = anchorPart(bodyPart.CFrame),
		model = if model and model:IsA("Model") then model else nil,
		look = look :: string,
		extra = {},
		owned = {},
	}
	visuals[bodyPart] = v
	local ok, err = pcall(builder, v)
	if not ok then
		warn("[EnergyFx] " .. tostring(look) .. ": " .. tostring(err))
	end
end

local function unbuild(bodyPart: Instance)
	local v = if bodyPart:IsA("BasePart") then visuals[bodyPart :: BasePart] else nil
	if v then
		visuals[bodyPart :: BasePart] = nil
		cleanup(v)
	end
end

local function step(dt: number)
	for bodyPart, v in visuals do
		if not bodyPart.Parent then
			visuals[bodyPart] = nil
			cleanup(v)
			continue
		end
		-- Followers stand where their body is now; free bodies ease toward the server's part.
		local root = v.model and rootOf(v.model)
		if root then
			v.root.CFrame = CFrame.new(root.Position)
		elseif v.look ~= "ring_of_fire" and v.look ~= "ice_mirror" and v.look ~= "arc_fence" then
			v.root.CFrame = v.root.CFrame:Lerp(CFrame.new(bodyPart.Position), math.clamp(dt * 10, 0, 1))
		end
		if v.update then
			local ok, err = pcall(v.update, v, dt)
			if not ok then
				v.update = nil
				warn("[EnergyFx] " .. v.look .. ": " .. tostring(err))
			end
		end
	end
end

-- ─── Projectile bodies (SpellFx.launch) ─────────────────────────────────────

-- Adds a route's own look to a flying bolt. Returns a stop function (called when it lands) and,
-- for a winding flight, how far it weaves.
function EnergyFx.flight(look: string, anchor: Part, coreSize: number): ((() -> ())?, number?)
	local added: { ParticleEmitter } = {}
	local function add(spec: { [string]: any })
		local e = FxLayers.emitter(anchor, spec :: any)
		if e then
			e.Enabled = true
			table.insert(added, e)
		end
	end
	local weave: number? = nil
	if look == "serpent" then
		anchor.Color = L.fireHot
		add({
			texture = TEX.fire,
			color = ColorSequence.new(L.fireHot, L.fire),
			size = seq(0, coreSize * 3, 1, 0),
			transparency = seq(0, 0, 1, 1),
			lifetime = NumberRange.new(0.5, 0.8),
			speed = NumberRange.new(0.2, 1),
			emission = 1,
			rate = rate(90),
		})
		weave = 1.6
	elseif look == "lance" then
		anchor.Color = L.frost
		anchor.Size = Vector3.new(coreSize * 0.6, coreSize * 0.6, coreSize * 4)
		anchor.Shape = Enum.PartType.Block
		anchor.Material = Enum.Material.Ice
		add({
			texture = TEX.shard,
			color = ColorSequence.new(L.frost, L.ice),
			size = seq(0, 0.5, 1, 0),
			transparency = seq(0, 0, 1, 1),
			lifetime = NumberRange.new(0.3, 0.6),
			speed = NumberRange.new(1, 3),
			spread = 180,
			emission = 0.6,
			rate = rate(40),
		})
	elseif look == "prism" then
		anchor.Color = Color3.new(1, 1, 1)
		add({
			texture = TEX.sparkles,
			color = ColorSequence.new({
				ColorSequenceKeypoint.new(0, L.prism[1]),
				ColorSequenceKeypoint.new(0.25, L.prism[2]),
				ColorSequenceKeypoint.new(0.5, L.prism[3]),
				ColorSequenceKeypoint.new(0.75, L.prism[4]),
				ColorSequenceKeypoint.new(1, L.prism[5]),
			}),
			size = seq(0, coreSize * 1.6, 1, 0),
			transparency = seq(0, 0, 1, 1),
			lifetime = NumberRange.new(0.3, 0.5),
			speed = NumberRange.new(1, 4),
			spread = 180,
			emission = 1,
			rate = rate(60),
		})
	elseif look == "ricochet" then
		anchor.Color = L.force
		anchor.Size = Vector3.one * coreSize * 0.7
	elseif look == "ball" then
		anchor.Color = L.chargeHot
		anchor.Size = Vector3.one * math.max(1.6, coreSize * 2)
		add({
			texture = TEX.crackle,
			color = ColorSequence.new(L.chargeHot, L.charge),
			size = seq(0, coreSize * 2.2, 1, 0),
			transparency = seq(0, 0, 1, 1),
			lifetime = NumberRange.new(0.1, 0.25),
			speed = NumberRange.new(4, 10),
			spread = 180,
			emission = 1,
			rate = rate(60),
		})
	end
	if #added == 0 then
		return nil, weave
	end
	return function()
		for _, e in added do
			e.Enabled = false
		end
	end, weave
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

function EnergyFx.start()
	for _, p in CollectionService:GetTagged("EnergyBody") do
		task.spawn(build, p)
	end
	CollectionService:GetInstanceAddedSignal("EnergyBody"):Connect(function(p)
		-- Attributes and links arrive with the part; give them a frame in case they lag.
		task.defer(build, p)
	end)
	CollectionService:GetInstanceRemovedSignal("EnergyBody"):Connect(unbuild)
	RunService.RenderStepped:Connect(step)
end

return EnergyFx
