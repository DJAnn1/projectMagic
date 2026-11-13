--!strict
--[[
	PropertyFx: the parts of a spell's look that belong to its PROPERTY, not its domain or form
	(docs/SpellOverhaul.md §2C, stage 2; data in Shared/Magic/Data/PropertyLooks). Fx/SpellFx calls:

		PropertyFx.tint(style, property) -> Style
			the caster's palette pulled toward the property's colour (frost reads icy in any domain)
		PropertyFx.flourish(look, o)
			the extra impact layers the look lists: ice shards, sound rings, lightning forks, a flare,
			sick motes, a gust, a crushing slam, dust, a warp, a splash, life drawn back to the caster,
			spores, soul wisps; then the lingering effect (frost mist, embers, motes, spores, dust)
		PropertyFx.ripples(from, to, style)
			rings riding along a beam ("ripple" beams: sound, resonance)

	Everything is cosmetic, pooled (FxPool) and skipped past the pool's caps. Far LOD (lod 0) draws
	nothing here; reduced effects keep the flourish small and skip lingering effects.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local FxPool = require(script.Parent.FxPool)
local FxLayers = require(script.Parent.FxLayers)
local DomainFx = require(script.Parent.DomainFx)
local Theme = require(script.Parent.Parent:WaitForChild("UI").Theme)
local PropertyLooks = require(ReplicatedStorage:WaitForChild("Shared").Magic.Data.PropertyLooks)

local TEX = DomainFx.textures

local PropertyFx = {}

type Style = FxLayers.Style

export type FlourishOpts = {
	position: Vector3,
	origin: Vector3?, -- where the caster stood (drains flow back there)
	radius: number,
	power: number,
	style: Style,
	lod: number,
	-- SpellFx.lightning, passed in (SpellFx requires this module, so no require back).
	lightning: ((Vector3, Vector3, Style, any, number, number) -> ())?,
	tier: any,
}

function PropertyFx.tint(style: Style, property: string?): Style
	local look = property and PropertyLooks.looks[property]
	local tint = look and look.tint
	if not tint then
		return style
	end
	local out = table.clone(style)
	out.primary = style.primary:Lerp(tint.color, tint.share)
	out.secondary = style.secondary:Lerp(tint.color, tint.share * 0.8)
	out.accent = style.accent:Lerp(tint.color, tint.share * 0.5)
	return out
end

-- A one-shot burst on its own anchor (released when the particles are gone).
local function burst(position: Vector3, count: number, spec: FxLayers.EmitterSpec, life: number)
	if count <= 0 then
		return
	end
	local anchor = FxPool.anchor(CFrame.new(position), Vector3.one)
	if not anchor then
		return
	end
	local e = FxLayers.emitter(anchor, spec)
	if e then
		e:Emit(count)
	end
	FxPool.releaseAfter(anchor, life + 0.3)
end

local function n(base: number, power: number, reduced: boolean): number
	local count = math.floor(base * (0.6 + power * 0.08))
	return if reduced then math.max(1, math.floor(count * 0.4)) else count
end

local draw: { [string]: (o: FlourishOpts, reduced: boolean) -> () } = {}

draw.shards = function(o, reduced)
	-- Ice or crystal shards flung out and falling, catching the light.
	burst(o.position, n(14, o.power, reduced), {
		texture = TEX.shard,
		color = ColorSequence.new(Color3.new(1, 1, 1), o.style.primary),
		size = FxLayers.seq(0, 0.5 + o.power * 0.05, 1, 0.1),
		transparency = FxLayers.seq(0, 0, 0.8, 0.3, 1, 1),
		lifetime = NumberRange.new(0.6, 1.1),
		speed = NumberRange.new(14, 30),
		spread = 180,
		acceleration = Vector3.new(0, -70, 0),
		rotSpeed = NumberRange.new(-300, 300),
		emission = 0.6,
		influence = 0.4,
		shape = Enum.ParticleEmitterShape.Sphere,
	}, 1.1)
end

draw.rings = function(o, reduced)
	-- Sound bending the air: rings that grow one after another, standing up and lying down.
	local count = if reduced then 1 else 3
	for i = 1, count do
		task.delay((i - 1) * 0.09, function()
			burst(o.position, 1, {
				texture = TEX.ring,
				color = FxLayers.solid(FxLayers.whiten(o.style.primary, 0.5)),
				size = FxLayers.seq(0, o.radius * 0.4, 1, o.radius * (2.4 + i * 0.6)),
				transparency = FxLayers.seq(0, 0.15, 0.7, 0.6, 1, 1),
				lifetime = NumberRange.new(0.4),
				emission = 1,
				zOffset = 1,
			}, 0.4)
			local ground, normal = FxLayers.ground(o.position, 6)
			if ground then
				FxLayers.shockwave(ground, normal or Vector3.yAxis, o.radius * (0.9 + i * 0.4), o.style.accent, 0.35)
			end
		end)
	end
end

draw.fork = function(o, reduced)
	-- Lightning forking from the impact down into the ground around it.
	if not o.lightning then
		return
	end
	local count = if reduced then 1 else math.clamp(math.floor(1 + o.power / 3), 1, 4)
	for _ = 1, count do
		local angle = math.random() * math.pi * 2
		local reach = o.radius * (1.2 + math.random())
		local at = o.position + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)
		local ground = FxLayers.ground(at + Vector3.new(0, 4, 0), 12) or at
		o.lightning(o.position, ground, o.style, o.tier, 0.12 + o.power * 0.02, 0.22)
	end
end

draw.flare = function(o, reduced)
	-- A blinding white flare and a long bright light.
	FxLayers.flash(o.position, o.radius * 1.4, Color3.new(1, 1, 0.94), 0.18, false)
	if not reduced then
		FxLayers.light(o.position, Color3.new(1, 0.98, 0.9), 10, 16 + o.radius * 4, 0.5, 0)
	end
end

draw.motes = function(o, reduced)
	burst(o.position, n(16, o.power, reduced), {
		texture = TEX.mote,
		color = FxLayers.solid(o.style.primary),
		size = FxLayers.seq(0, 0.35, 0.5, 0.45, 1, 0),
		transparency = FxLayers.seq(0, 0.1, 1, 1),
		lifetime = NumberRange.new(1.2, 2),
		speed = NumberRange.new(2, 6),
		spread = 180,
		acceleration = Vector3.new(0, 1.5, 0),
		drag = 1.5,
		emission = 1,
		shape = Enum.ParticleEmitterShape.Sphere,
	}, 2)
end

draw.gust = function(o, reduced)
	-- Air thrown outward along the ground.
	burst(o.position, n(12, o.power, reduced), {
		texture = TEX.smoke,
		color = FxLayers.solid(Color3.fromRGB(235, 240, 245)),
		size = FxLayers.seq(0, 1, 1, 3.5),
		transparency = FxLayers.seq(0, 0.55, 1, 1),
		lifetime = NumberRange.new(0.35, 0.6),
		speed = NumberRange.new(28, 45),
		spread = 180,
		drag = 4,
		influence = 1,
		shape = Enum.ParticleEmitterShape.Disc,
	}, 0.6)
end

draw.crush = function(o, _reduced)
	-- Weight landing: a flat heavy ring and a hard shake.
	local ground, normal = FxLayers.ground(o.position, 8)
	if ground then
		FxLayers.shockwave(ground, normal or Vector3.yAxis, o.radius * 1.8, Color3.fromRGB(60, 50, 45), 0.25)
		FxLayers.groundMark("crack", ground, normal or Vector3.yAxis, o.radius * 1.2, o.style)
	end
end

draw.dust = function(o, reduced)
	burst(o.position, n(12, o.power, reduced), {
		texture = TEX.dust,
		color = FxLayers.solid(o.style.secondary:Lerp(Color3.fromRGB(190, 170, 135), 0.6)),
		size = FxLayers.seq(0, 0.8, 1, 2.4),
		transparency = FxLayers.seq(0, 0.3, 1, 1),
		lifetime = NumberRange.new(0.9, 1.6),
		speed = NumberRange.new(3, 9),
		spread = 180,
		acceleration = Vector3.new(0, -4, 0),
		drag = 2,
		influence = 1,
		shape = Enum.ParticleEmitterShape.Sphere,
	}, 1.6)
end

draw.warp = function(o, reduced)
	-- Down twisting: a spinning vortex that pulls in and lets go.
	burst(o.position, if reduced then 1 else 2, {
		texture = TEX.vortex,
		color = FxLayers.solid(o.style.primary),
		size = FxLayers.seq(0, o.radius * 2.2, 1, o.radius * 0.3),
		transparency = FxLayers.seq(0, 0.2, 1, 1),
		lifetime = NumberRange.new(0.6),
		rotSpeed = NumberRange.new(360, 540),
		emission = 1,
	}, 0.6)
end

draw.splash = function(o, reduced)
	burst(o.position, n(18, o.power, reduced), {
		texture = TEX.sparkles,
		color = ColorSequence.new(Color3.new(1, 1, 1), o.style.primary),
		size = FxLayers.seq(0, 0.5, 1, 0.15),
		transparency = FxLayers.seq(0, 0.1, 1, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(10, 22),
		spread = 60,
		acceleration = Vector3.new(0, -80, 0),
		influence = 0.6,
		direction = Enum.NormalId.Top,
	}, 0.9)
end

draw.drain = function(o, reduced)
	-- Life or magic pulled out of them and drawn back toward the caster.
	local back = if o.origin then (o.origin + Vector3.new(0, 1.5, 0)) - o.position else Vector3.new(0, 4, 0)
	local dist = back.Magnitude
	if dist < 0.5 then
		return
	end
	local anchor = FxPool.anchor(CFrame.lookAt(o.position, o.position + back) * CFrame.Angles(-math.pi / 2, 0, 0), Vector3.one)
	if not anchor then
		return
	end
	local life = math.clamp(dist / 30, 0.4, 1.2)
	local e = FxLayers.emitter(anchor, {
		texture = TEX.mote,
		color = FxLayers.solid(o.style.primary),
		size = FxLayers.seq(0, 0.45, 1, 0.1),
		transparency = FxLayers.seq(0, 0, 0.8, 0.2, 1, 1),
		lifetime = NumberRange.new(life),
		speed = NumberRange.new(dist / life * 0.9, dist / life),
		spread = 8,
		emission = 1,
		direction = Enum.NormalId.Top,
	})
	if e then
		e:Emit(n(14, o.power, reduced))
	end
	FxPool.releaseAfter(anchor, life + 0.3)
end

draw.spores = function(o, reduced)
	burst(o.position, n(14, o.power, reduced), {
		texture = TEX.spore,
		color = FxLayers.solid(o.style.primary),
		size = FxLayers.seq(0, 0.2, 0.5, 0.4, 1, 0.1),
		transparency = FxLayers.seq(0, 0.2, 1, 1),
		lifetime = NumberRange.new(1.4, 2.4),
		speed = NumberRange.new(1, 4),
		spread = 180,
		acceleration = Vector3.new(0, 0.6, 0),
		drag = 1,
		influence = 0.7,
		rotSpeed = NumberRange.new(-40, 40),
		shape = Enum.ParticleEmitterShape.Sphere,
	}, 2.4)
end

draw.wisps = function(o, reduced)
	-- Pale shapes leaving them and rising.
	burst(o.position, n(6, o.power, reduced), {
		texture = TEX.wisp,
		color = FxLayers.solid(FxLayers.whiten(o.style.primary, 0.3)),
		size = FxLayers.seq(0, 0.6, 0.5, 1.4, 1, 0.4),
		transparency = FxLayers.seq(0, 0.4, 0.5, 0.3, 1, 1),
		lifetime = NumberRange.new(1.2, 1.8),
		speed = NumberRange.new(1, 3),
		spread = 50,
		acceleration = Vector3.new(0, 6, 0),
		emission = 1,
		rotSpeed = NumberRange.new(-60, 60),
		direction = Enum.NormalId.Top,
	}, 1.8)
end

draw.embers = function(o, reduced)
	burst(o.position, n(16, o.power, reduced), {
		texture = TEX.fireSparks,
		color = ColorSequence.new(Color3.fromRGB(255, 220, 140), o.style.primary),
		size = FxLayers.seq(0, 0.3, 1, 0),
		transparency = FxLayers.seq(0, 0, 0.7, 0.2, 1, 1),
		lifetime = NumberRange.new(0.8, 1.6),
		speed = NumberRange.new(4, 12),
		spread = 180,
		acceleration = Vector3.new(0, 8, 0),
		emission = 1,
		shape = Enum.ParticleEmitterShape.Sphere,
	}, 1.6)
end

-- Lingering effects: a slow emitter left at the impact that runs for `seconds`, then stops.
local LINGER: { [string]: (style: Style) -> FxLayers.EmitterSpec } = {
	mist = function(_style)
		return { texture = TEX.smoke, color = FxLayers.solid(Color3.fromRGB(225, 240, 255)), size = FxLayers.seq(0, 1.5, 1, 3.5),
			transparency = FxLayers.seq(0, 0.65, 1, 1), lifetime = NumberRange.new(1.5, 2.2), speed = NumberRange.new(0.3, 1),
			spread = 180, acceleration = Vector3.new(0, -0.3, 0), influence = 1, rate = 5, shape = Enum.ParticleEmitterShape.Disc }
	end,
	embers = function(style)
		return { texture = TEX.fireSparks, color = ColorSequence.new(Color3.fromRGB(255, 200, 120), style.primary), size = FxLayers.seq(0, 0.25, 1, 0),
			transparency = FxLayers.seq(0, 0, 1, 1), lifetime = NumberRange.new(0.8, 1.4), speed = NumberRange.new(1, 3),
			spread = 40, acceleration = Vector3.new(0, 5, 0), emission = 1, rate = 8, shape = Enum.ParticleEmitterShape.Disc }
	end,
	motes = function(style)
		return { texture = TEX.mote, color = FxLayers.solid(style.primary), size = FxLayers.seq(0, 0.3, 1, 0),
			transparency = FxLayers.seq(0, 0.1, 1, 1), lifetime = NumberRange.new(1.4, 2), speed = NumberRange.new(0.3, 1),
			spread = 180, acceleration = Vector3.new(0, 1, 0), emission = 1, rate = 6, shape = Enum.ParticleEmitterShape.Disc }
	end,
	spores = function(style)
		return { texture = TEX.spore, color = FxLayers.solid(style.primary), size = FxLayers.seq(0, 0.25, 1, 0.1),
			transparency = FxLayers.seq(0, 0.3, 1, 1), lifetime = NumberRange.new(1.6, 2.6), speed = NumberRange.new(0.2, 0.8),
			spread = 180, acceleration = Vector3.new(0, 0.5, 0), influence = 0.7, rate = 5, shape = Enum.ParticleEmitterShape.Disc }
	end,
	dust = function(style)
		return { texture = TEX.dust, color = FxLayers.solid(style.secondary:Lerp(Color3.fromRGB(190, 170, 135), 0.6)), size = FxLayers.seq(0, 0.6, 1, 1.8),
			transparency = FxLayers.seq(0, 0.5, 1, 1), lifetime = NumberRange.new(1.2, 1.8), speed = NumberRange.new(0.3, 1),
			spread = 180, acceleration = Vector3.new(0, -1, 0), influence = 1, rate = 4, shape = Enum.ParticleEmitterShape.Disc }
	end,
}

local function linger(kind: string, seconds: number, o: FlourishOpts)
	local spec = LINGER[kind]
	if not spec then
		return
	end
	local ground, normal = FxLayers.ground(o.position, 6)
	local at = ground or o.position
	local up = normal or Vector3.yAxis
	local size = math.clamp(o.radius * 1.4, 2, 14)
	local anchor = FxPool.anchor(CFrame.lookAt(at, at + up) * CFrame.Angles(-math.pi / 2, 0, 0) + up * 0.3, Vector3.new(size, 0.2, size))
	if not anchor then
		return
	end
	local e = FxLayers.emitter(anchor, spec(o.style))
	if not e then
		FxPool.release(anchor)
		return
	end
	e.Enabled = true
	task.delay(seconds, function()
		if e.Parent then
			e.Enabled = false
		end
	end)
	FxPool.releaseAfter(anchor, seconds + 2.8)
end

-- Every flourish the look lists, then its lingering effect.
function PropertyFx.flourish(look: DomainFx.Look, o: FlourishOpts)
	if o.lod <= 0 or not look.flourish and not look.linger then
		return
	end
	local reduced = Theme.settings.reducedEffects == true
	for _, kind in (look.flourish or {}) :: { string } do
		local fn = draw[kind]
		if fn then
			local ok, err = pcall(fn, o, reduced)
			if not ok then
				warn("[PropertyFx] " .. kind .. ": " .. tostring(err))
			end
		end
	end
	local lingers = look.linger
	if lingers and not reduced and o.lod >= 2 then
		linger(lingers.kind, lingers.seconds, o)
	end
end

-- Rings riding along a beam from `from` to `to` (sound and resonance beams).
function PropertyFx.ripples(from: Vector3, to: Vector3, style: Style, width: number)
	local along = to - from
	local dist = along.Magnitude
	if dist < 1 then
		return
	end
	local count = math.clamp(math.floor(dist / 6), 2, 6)
	for i = 1, count do
		task.delay(i * 0.035, function()
			local at = from + along * (i / (count + 1))
			-- Facing along the beam: a ring the beam passes through.
			local anchor = FxPool.anchor(CFrame.lookAt(at, at + along) * CFrame.Angles(-math.pi / 2, 0, 0), Vector3.one)
			if not anchor then
				return
			end
			local e = FxLayers.emitter(anchor, {
				texture = TEX.ring,
				color = FxLayers.solid(FxLayers.whiten(style.primary, 0.5)),
				size = FxLayers.seq(0, width * 2, 1, width * 7),
				transparency = FxLayers.seq(0, 0.2, 1, 1),
				lifetime = NumberRange.new(0.3),
				speed = NumberRange.new(0.001),
				emission = 1,
				orientation = Enum.ParticleOrientation.VelocityPerpendicular,
				direction = Enum.NormalId.Top,
			})
			if e then
				e:Emit(1)
			end
			FxPool.releaseAfter(anchor, 0.5)
		end)
	end
end

-- The kinds this module draws (Tests/PropertyLooks.spec checks the data names only these).
PropertyFx.kinds = draw
PropertyFx.lingerKinds = LINGER

return PropertyFx
