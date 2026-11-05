--!strict
--[[
	FxLayers: the building blocks every spell visual is assembled from (Fx/SpellFx composes them by
	form; Fx/DomainFx says what each domain is made of). Client-only, cosmetic, pooled.

		animate(duration, step(alpha), done?)   one shared RenderStepped loop for every tween
		emitter(parent, spec) -> ParticleEmitter?   a pooled emitter with EVERY property set from spec
		ramp(style, dark?) -> ColorSequence     hot-to-cool: white-hot core -> primary -> secondary ->
		                                        dimmed accent (dark looks invert: black core)
		ground(position, drop?) -> (Vector3?, Vector3?)   the surface under a point and its normal
		flat(position, normal, spec)            one particle lying flat on a surface (rings, runes,
		                                        scorch): Orientation = VelocityPerpendicular
		flash(position, radius, color, duration)   Neon sphere that pops and fades (impact core)
		shockwave(position, normal, radius, color, duration)   expanding ground ring
		groundMark(kind, position, normal, radius, style)      scorch / crack / puddle / frost /
		                                        bloom / rune / void, fading over seconds
		light(position, color, brightness, range, duration, flicker)   pooled PointLight (global budget)
		sound(position, sound, volumeMult?)     positional one-shot (budgeted)
		castCircle(feet, normal, radius, style, castTime) -> Part?   rotating runic circle + rising motes

	Budgets: FxPool caps (anchors / emitters / beams / trails / lights) + MAX_SOUNDS here; past a
	cap a layer is skipped, never queued. Everything respects Theme.settings.reducedEffects.
]]

local RunService = game:GetService("RunService")
local Players = game:GetService("Players")

local FxPool = require(script.Parent.FxPool)
local DomainFx = require(script.Parent.DomainFx)
local Theme = require(script.Parent.Parent:WaitForChild("UI").Theme)

export type Style = {
	primary: Color3,
	secondary: Color3,
	accent: Color3,
	particle: string,
	motion: string,
}

export type EmitterSpec = {
	texture: string,
	color: ColorSequence,
	size: NumberSequence,
	transparency: NumberSequence,
	lifetime: NumberRange,
	speed: NumberRange?,
	spread: number?,
	rotation: NumberRange?,
	rotSpeed: NumberRange?,
	acceleration: Vector3?,
	drag: number?,
	emission: number?, -- LightEmission
	influence: number?, -- LightInfluence
	shape: Enum.ParticleEmitterShape?,
	inOut: Enum.ParticleEmitterShapeInOut?,
	style: Enum.ParticleEmitterShapeStyle?,
	orientation: Enum.ParticleOrientation?,
	direction: Enum.NormalId?,
	zOffset: number?,
	rate: number?,
	locked: boolean?,
	squash: NumberSequence?,
}

local MAX_SOUNDS = 12
local TEX = DomainFx.textures

local FxLayers = {}

local rng = Random.new()

-- ─── Animation scheduler ────────────────────────────────────────────────────

type Anim = { started: number, duration: number, step: (number) -> (), done: (() -> ())? }
local anims: { Anim } = {}
local loop: RBXScriptConnection? = nil

function FxLayers.animate(duration: number, step: (number) -> (), done: (() -> ())?)
	table.insert(anims, { started = os.clock(), duration = math.max(1e-3, duration), step = step, done = done })
	if loop then
		return
	end
	loop = RunService.RenderStepped:Connect(function()
		local t = os.clock()
		for i = #anims, 1, -1 do
			local a = anims[i]
			local alpha = math.clamp((t - a.started) / a.duration, 0, 1)
			local ok = pcall(a.step, alpha)
			if alpha >= 1 or not ok then
				table.remove(anims, i)
				if a.done then
					pcall(a.done)
				end
			end
		end
		if #anims == 0 and loop then
			loop:Disconnect()
			loop = nil
		end
	end)
end

-- ─── Colour and sequences ───────────────────────────────────────────────────

local WHITE = Color3.new(1, 1, 1)
local BLACK = Color3.new(0, 0, 0)

function FxLayers.whiten(c: Color3, t: number): Color3
	return c:Lerp(WHITE, math.clamp(t, 0, 1))
end

-- Hot-to-cool over a particle's life: the core burns white, cools through the signature colours.
function FxLayers.ramp(style: Style, dark: boolean?): ColorSequence
	if dark then
		return ColorSequence.new({
			ColorSequenceKeypoint.new(0, style.accent:Lerp(BLACK, 0.75)),
			ColorSequenceKeypoint.new(0.4, style.primary:Lerp(BLACK, 0.35)),
			ColorSequenceKeypoint.new(1, style.secondary),
		})
	end
	return ColorSequence.new({
		ColorSequenceKeypoint.new(0, FxLayers.whiten(style.primary, 0.7)),
		ColorSequenceKeypoint.new(0.3, style.primary),
		ColorSequenceKeypoint.new(0.7, style.secondary),
		ColorSequenceKeypoint.new(1, style.accent:Lerp(BLACK, 0.35)),
	})
end

function FxLayers.seq(...: number): NumberSequence
	local values = { ... }
	local points = {}
	for i = 1, #values, 2 do
		table.insert(points, NumberSequenceKeypoint.new(values[i], values[i + 1]))
	end
	return NumberSequence.new(points)
end

function FxLayers.solid(color: Color3): ColorSequence
	return ColorSequence.new(color)
end

-- ─── Emitters ───────────────────────────────────────────────────────────────

function FxLayers.emitter(parent: Instance, spec: EmitterSpec): ParticleEmitter?
	local e = FxPool.emitter(parent)
	if not e then
		return nil
	end
	e.Texture = spec.texture
	e.Color = spec.color
	e.Size = spec.size
	e.Transparency = spec.transparency
	e.Lifetime = spec.lifetime
	e.Speed = spec.speed or NumberRange.new(0)
	local spread = spec.spread or 0
	e.SpreadAngle = Vector2.new(spread, spread)
	e.Rotation = spec.rotation or NumberRange.new(0, 360)
	e.RotSpeed = spec.rotSpeed or NumberRange.new(0)
	e.Acceleration = spec.acceleration or Vector3.zero
	e.Drag = spec.drag or 0
	e.LightEmission = spec.emission or 0
	e.LightInfluence = spec.influence or 0
	e.Shape = spec.shape or Enum.ParticleEmitterShape.Box
	e.ShapeInOut = spec.inOut or Enum.ParticleEmitterShapeInOut.Outward
	e.ShapeStyle = spec.style or Enum.ParticleEmitterShapeStyle.Volume
	e.Orientation = spec.orientation or Enum.ParticleOrientation.FacingCamera
	e.EmissionDirection = spec.direction or Enum.NormalId.Top
	e.ZOffset = spec.zOffset or 0
	e.Rate = spec.rate or 0
	e.LockedToPart = spec.locked == true
	e.Squash = spec.squash or NumberSequence.new(0)
	e.TimeScale = 1
	return e
end

-- ─── Surfaces ───────────────────────────────────────────────────────────────

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude

-- The solid surface under `position` (within `drop` studs) and its normal. Characters and
-- effects are ignored, so a mark lands on the floor, not on someone's head.
function FxLayers.ground(position: Vector3, drop: number?): (Vector3?, Vector3?)
	local ignore: { Instance } = {}
	local fx = workspace:FindFirstChild("MagicFx")
	if fx then
		table.insert(ignore, fx)
	end
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	groundParams.FilterDescendantsInstances = ignore
	local result = workspace:Raycast(position + Vector3.new(0, 1.5, 0), Vector3.new(0, -((drop or 6) + 1.5), 0), groundParams)
	if result then
		return result.Position, result.Normal
	end
	return nil, nil
end

-- A CFrame whose top face (UpVector) points along `normal`.
local function onSurface(position: Vector3, normal: Vector3): CFrame
	local up = if normal.Magnitude > 0.01 then normal.Unit else Vector3.yAxis
	local side = if math.abs(up.Y) < 0.95 then up:Cross(Vector3.yAxis).Unit else up:Cross(Vector3.xAxis).Unit
	local back = side:Cross(up).Unit
	return CFrame.fromMatrix(position + up * 0.08, side, up, back)
end

export type FlatSpec = {
	texture: string,
	color: ColorSequence,
	size: NumberSequence, -- diameter over life (studs)
	transparency: NumberSequence,
	duration: number,
	rotSpeed: number?,
	emission: number?,
	influence: number?,
}

-- One particle lying flat on the surface: rings, runes, scorch and puddles without decals.
function FxLayers.flat(position: Vector3, normal: Vector3, spec: FlatSpec): Part?
	local anchor = FxPool.anchor(onSurface(position, normal))
	if not anchor then
		return nil
	end
	local rot = spec.rotSpeed or 0
	local e = FxLayers.emitter(anchor, {
		texture = spec.texture,
		color = spec.color,
		size = spec.size,
		transparency = spec.transparency,
		lifetime = NumberRange.new(spec.duration),
		speed = NumberRange.new(0.001),
		rotSpeed = NumberRange.new(rot, rot),
		emission = spec.emission or 0,
		influence = spec.influence or 0,
		orientation = Enum.ParticleOrientation.VelocityPerpendicular,
		direction = Enum.NormalId.Top,
		zOffset = -0.1,
	})
	if not e then
		FxPool.release(anchor)
		return nil
	end
	e:Emit(1)
	FxPool.releaseAfter(anchor, spec.duration + 0.2)
	return anchor
end

function FxLayers.shockwave(position: Vector3, normal: Vector3, radius: number, color: Color3, duration: number)
	FxLayers.flat(position, normal, {
		texture = TEX.shock,
		color = FxLayers.solid(color),
		size = FxLayers.seq(0, radius * 0.3, 1, radius * 2.6),
		transparency = FxLayers.seq(0, 0.05, 0.6, 0.45, 1, 1),
		duration = duration,
		emission = 1,
	})
end

-- Lingering marks an impact leaves on the ground (the kinds DomainFx.mark names).
function FxLayers.groundMark(kind: string, position: Vector3, normal: Vector3, radius: number, style: Style)
	if Theme.settings.reducedEffects then
		return
	end
	local d = radius * 2
	if kind == "scorch" then
		FxLayers.flat(position, normal, {
			texture = TEX.scorch, color = FxLayers.solid(Color3.fromRGB(18, 14, 12)),
			size = FxLayers.seq(0, d * 0.7, 0.05, d, 1, d * 1.05),
			transparency = FxLayers.seq(0, 0.15, 0.7, 0.35, 1, 1),
			duration = 10, influence = 1,
		})
		FxLayers.flat(position, normal, { -- embers glowing in the scorch for a moment
			texture = TEX.fireSparks, color = FxLayers.solid(Color3.fromRGB(255, 120, 40)),
			size = FxLayers.seq(0, d * 0.6, 1, d * 0.7),
			transparency = FxLayers.seq(0, 0.3, 1, 1),
			duration = 2.5, emission = 1,
		})
	elseif kind == "crack" then
		FxLayers.flat(position, normal, {
			texture = TEX.crack, color = FxLayers.solid(Color3.fromRGB(40, 32, 26)),
			size = FxLayers.seq(0, d * 0.9, 1, d),
			transparency = FxLayers.seq(0, 0.1, 0.75, 0.3, 1, 1),
			duration = 12, influence = 1,
		})
	elseif kind == "puddle" then
		FxLayers.flat(position, normal, {
			texture = TEX.glow, color = FxLayers.solid(style.primary:Lerp(Color3.fromRGB(60, 120, 200), 0.5)),
			size = FxLayers.seq(0, d * 0.5, 0.1, d, 1, d * 1.1),
			transparency = FxLayers.seq(0, 0.35, 0.6, 0.55, 1, 1),
			duration = 7, emission = 0.3, influence = 0.6,
		})
	elseif kind == "frost" then
		FxLayers.flat(position, normal, {
			texture = TEX.sparkles, color = FxLayers.solid(Color3.fromRGB(215, 240, 255)),
			size = FxLayers.seq(0, d * 0.8, 1, d),
			transparency = FxLayers.seq(0, 0.2, 0.7, 0.4, 1, 1),
			duration = 8, emission = 0.4,
		})
	elseif kind == "bloom" then
		FxLayers.flat(position, normal, {
			texture = TEX.sparkles, color = FxLayers.solid(style.primary),
			size = FxLayers.seq(0, 0, 0.15, d, 1, d * 1.1),
			transparency = FxLayers.seq(0, 0.3, 0.7, 0.5, 1, 1),
			duration = 6, emission = 0.6, rotSpeed = 15,
		})
	elseif kind == "rune" then
		FxLayers.flat(position, normal, {
			texture = TEX.rune, color = FxLayers.solid(style.primary),
			size = FxLayers.seq(0, d * 0.4, 0.12, d, 1, d),
			transparency = FxLayers.seq(0, 0.1, 0.7, 0.4, 1, 1),
			duration = 4, emission = 1, rotSpeed = 60,
		})
	elseif kind == "void" then
		FxLayers.flat(position, normal, {
			texture = TEX.implode, color = FxLayers.solid(Color3.fromRGB(20, 12, 30)),
			size = FxLayers.seq(0, d, 1, d * 0.5),
			transparency = FxLayers.seq(0, 0.1, 1, 1),
			duration = 4, influence = 1, rotSpeed = -40,
		})
	end
end

-- ─── Flash, light, sound ────────────────────────────────────────────────────

-- The impact core: a Neon sphere that pops to `radius` and fades in `duration`.
function FxLayers.flash(position: Vector3, radius: number, color: Color3, duration: number, dark: boolean?)
	local anchor = FxPool.anchor(CFrame.new(position), Vector3.one * 0.5)
	if not anchor then
		return
	end
	anchor.Shape = Enum.PartType.Ball
	anchor.Material = if dark then Enum.Material.SmoothPlastic else Enum.Material.Neon
	anchor.Color = if dark then Color3.fromRGB(10, 6, 16) else color
	anchor.Transparency = 0
	local size = math.max(0.6, radius * 2)
	FxLayers.animate(duration, function(t)
		local eased = 1 - (1 - t) ^ 3
		anchor.Size = Vector3.one * (0.5 + (size - 0.5) * eased)
		anchor.Transparency = t ^ 0.6
	end, function()
		FxPool.release(anchor)
	end)
end

-- A pooled PointLight that peaks and decays (flicker 0..1 for fire). Skipped past the budget.
function FxLayers.light(position: Vector3, color: Color3, brightness: number, range: number, duration: number, flicker: number?)
	if Theme.settings.reducedEffects then
		return
	end
	local anchor = FxPool.anchor(CFrame.new(position))
	if not anchor then
		return
	end
	local light = FxPool.light(anchor)
	if not light then
		FxPool.release(anchor)
		return
	end
	light.Color = color
	light.Range = math.clamp(range, 4, 60)
	local f = flicker or 0
	FxLayers.animate(duration, function(t)
		local decay = (1 - t) ^ 2
		local noise = if f > 0 then 1 - f * rng:NextNumber() else 1
		light.Brightness = brightness * decay * noise
	end, function()
		FxPool.release(anchor)
	end)
end

local liveSounds = 0

function FxLayers.sound(position: Vector3, sound: DomainFx.Sound, volumeMult: number?)
	if liveSounds >= MAX_SOUNDS then
		return
	end
	liveSounds += 1
	local holder = Instance.new("Attachment")
	holder.WorldPosition = position
	holder.Parent = workspace.Terrain
	local s = Instance.new("Sound")
	s.SoundId = sound.id
	s.Volume = sound.volume * (volumeMult or 1)
	s.PlaybackSpeed = sound.pitch * (0.94 + rng:NextNumber() * 0.12)
	s.RollOffMode = Enum.RollOffMode.InverseTapered
	s.RollOffMinDistance = 10
	s.RollOffMaxDistance = 220
	s.Parent = holder
	s:Play()
	local released = false
	local function cleanup()
		if not released then
			released = true
			liveSounds -= 1
			holder:Destroy()
		end
	end
	s.Ended:Once(cleanup)
	task.delay(6, cleanup) -- a sound that never loads still frees its slot
end

-- ─── Cast circle ────────────────────────────────────────────────────────────

--[[
	The charge-up under the caster: a rotating runic circle in the primary colour, a counter-rotating
	ring in the accent, and motes rising from the circle. It grows in over the first third of the
	cast time. Returns the anchor so a refused (predicted) cast can cancel it.
]]
function FxLayers.castCircle(feet: Vector3, normal: Vector3, radius: number, style: Style, castTime: number, quality: number): Part?
	local hold = math.clamp(castTime, 0.3, 8)
	local anchor = FxPool.anchor(onSurface(feet, normal), Vector3.new(radius * 2, 0.2, radius * 2))
	if not anchor then
		return nil
	end
	local d = radius * 2
	local grow = math.min(0.35, hold * 0.3) / (hold + 0.4)
	local runes = FxLayers.emitter(anchor, {
		texture = TEX.rune,
		color = FxLayers.solid(style.primary),
		size = FxLayers.seq(0, 0, grow, d, 1, d * 1.05),
		transparency = FxLayers.seq(0, 0.15, 0.85, 0.25, 1, 1),
		lifetime = NumberRange.new(hold + 0.4),
		speed = NumberRange.new(0.001),
		rotSpeed = NumberRange.new(70, 70),
		emission = 1,
		orientation = Enum.ParticleOrientation.VelocityPerpendicular,
		zOffset = -0.1,
	})
	if runes then
		runes:Emit(1)
	end
	local ring = FxLayers.emitter(anchor, {
		texture = TEX.shock,
		color = FxLayers.solid(style.accent),
		size = FxLayers.seq(0, 0, grow, d * 1.25, 1, d * 1.3),
		transparency = FxLayers.seq(0, 0.3, 0.85, 0.45, 1, 1),
		lifetime = NumberRange.new(hold + 0.4),
		speed = NumberRange.new(0.001),
		rotSpeed = NumberRange.new(-45, -45),
		emission = 1,
		orientation = Enum.ParticleOrientation.VelocityPerpendicular,
		zOffset = -0.12,
	})
	if ring then
		ring:Emit(1)
	end
	local motes = FxLayers.emitter(anchor, {
		texture = TEX.sparkles,
		color = FxLayers.ramp(style),
		size = FxLayers.seq(0, 0.35, 0.5, 0.5, 1, 0),
		transparency = FxLayers.seq(0, 0.2, 1, 1),
		lifetime = NumberRange.new(0.6, 1.1),
		speed = NumberRange.new(2, 5),
		acceleration = Vector3.new(0, 4, 0),
		emission = 1,
		shape = Enum.ParticleEmitterShape.Cylinder,
		style = Enum.ParticleEmitterShapeStyle.Surface,
		rate = 26 * quality,
	})
	if motes then
		motes.Enabled = true
		task.delay(hold, function()
			if motes.Parent == anchor then
				motes.Enabled = false
			end
		end)
	end
	FxPool.releaseAfter(anchor, hold + 0.5)
	return anchor
end

return FxLayers
