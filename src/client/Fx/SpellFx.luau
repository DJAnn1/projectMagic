--!strict
--[[
	SpellFx: renders the server's cosmetic cues on this client. Nothing here affects gameplay.

	Every spell visual is LAYERS (Fx/FxLayers) chosen by FORM, made of the DOMAIN's material
	(Fx/DomainFx), tinted by the caster's SIGNATURE and refined by their mastery TIER:
		cast       runic circle at the feet (rotating, domain-coloured) + inward charge glow at the
		           chest + a light that swells over the cast time + the domain's cast sound
		projectile Neon core (white-hot primary) + glow halo + body particles shed behind (hot to cool)
		           + sparks with gravity + trail + travelling light. Flies the SAME path the server
		           simulates (the "launch" cue's velocity, gravity, homing) and bursts where the
		           server's impact cue says
		           + a muzzle flash standing along the shot; the trail carries a streak texture
		beam       white-hot core beam + wide textured signature beam + muzzle flare + impact at the end
		chain      the beam to the first target, then arcs between the struck (server "chain" cue)
		lightning  `charge` spells (and conduction arcs) draw beams and chains as LIGHTNING instead: a
		           jagged white-hot core re-struck every ~50 ms inside a crackling bolt texture
		impact     flash sphere + core burst + body cloud + sparks/debris + smoke + shockwave ring +
		           light pulse + ground mark (scorch, crack, puddle, bloom, rune, void) + camera shake
		           + sound; strength scales with power, size with the spell's area
		areas      burst (impact at area size), aura (ring at the caster), zone (rune circle that
		           holds + rising motes), pillar (column of light), wall/summon/ritual (rune + column)
	Tier: low tiers are wild (wide spread, wobbling beams, flicker); high tiers are tight and add
	detail (second ring at Expert+, runes on impacts at Master+). Every tier is BRIGHT: refinement
	never dims the core (the old LightEmission ramp made new players' magic look dead).

	Budget = quality() x LOD:
		quality()  0.25..1 from the graphics level, x0.7 on touch devices, x0.35 with Reduce spell
		           effects (which also disables shake, marks and lights)
		lod        from the server cue: 2 near (full), 1 mid (45%, no lights/marks/smoke), 0 far
		           (15%, only area forms and big impacts)
		FxPool caps live anchors / emitters / beams / trails / lights; past a cap a layer is skipped.

	Entry points (called by WorldEffectController):
		spell(cue)  [stages begin / launch / resolve / chain]  field / fieldEnd  wave  tsunami
		quake  reaction(kind, cue)  backlash  status  casting(...)  cancel(anchor) (CastClient)
]]

local HttpService = game:GetService("HttpService")
local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Registry = require(Shared.Magic.Registry)
local FxPool = require(script.Parent.FxPool)
local FxLayers = require(script.Parent.FxLayers)
local DomainFx = require(script.Parent.DomainFx)
local Recipes = require(script.Parent.FxRecipes)
local Theme = require(script.Parent.Parent:WaitForChild("UI").Theme)

export type Style = FxLayers.Style

local LOD_FACTOR: { [number]: number } = { [2] = 1, [1] = 0.45, [0] = 0.15 }
local TEX = DomainFx.textures

local SpellFx = {}

local rng = Random.new()

-- ─── Quality and style ──────────────────────────────────────────────────────

function SpellFx.quality(): number
	local q = 0.7
	local ok, level = pcall(function()
		return (UserSettings():GetService("UserGameSettings") :: any).SavedQualityLevel.Value
	end)
	if ok and typeof(level) == "number" and level > 0 then
		q = math.clamp(level / 10, 0.25, 1)
	end
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		q *= 0.7
	end
	if Theme.settings.reducedEffects then
		q *= 0.35
	end
	return q
end

local function domainStyle(domain: string): Style
	local def = Registry.domains[domain]
	local palette = if def then def.feel.palette else { Color3.new(1, 1, 1) }
	return {
		primary = palette[1],
		secondary = palette[2] or palette[1],
		accent = palette[3] or palette[1],
		particle = "motes",
		motion = "drifting",
	}
end

local function fromHex(hex: any, fallback: Color3): Color3
	if typeof(hex) ~= "string" then
		return fallback
	end
	local ok, color = pcall(Color3.fromHex, hex)
	return if ok then color else fallback
end

--[[
	How far a caster's Signature pulls each colour away from the domain's palette (0 = pure domain,
	1 = pure signature). The domain decides what a spell reads as (earth is brown, void is dark);
	the signature makes it recognisably *yours*: it tints the main colours and owns the accent
	(rings, the cast circle's counter-ring, cooling sparks), plus the particle shape and motion.
]]
local SIGNATURE_TINT = {
	primary = 0.25,
	secondary = 0.4,
	accent = 1,
}

-- Decodes a Signature JSON into a style for one domain, cached by signature + domain.
local signatureCache: { [string]: Style } = {}
local signatureCacheSize = 0

local function styleFromSignature(raw: string, domain: string, base: Style): Style
	local key = domain .. "|" .. raw
	local cached = signatureCache[key]
	if cached then
		return cached
	end
	local ok, sig = pcall(HttpService.JSONDecode, HttpService, raw)
	if not ok or typeof(sig) ~= "table" then
		return base
	end
	local style: Style = {
		primary = base.primary:Lerp(fromHex(sig.primary, base.primary), SIGNATURE_TINT.primary),
		secondary = base.secondary:Lerp(fromHex(sig.secondary, base.secondary), SIGNATURE_TINT.secondary),
		accent = base.accent:Lerp(fromHex(sig.accent, base.accent), SIGNATURE_TINT.accent),
		particle = if Recipes.particles[sig.particle] then sig.particle else base.particle,
		motion = if Recipes.motions[sig.motion] then sig.motion else base.motion,
	}
	if signatureCacheSize >= 512 then
		table.clear(signatureCache)
		signatureCacheSize = 0
	end
	signatureCache[key] = style
	signatureCacheSize += 1
	return style
end

-- `signature` (an NPC's Signature JSON, sent in its cue) wins over the player attribute.
function SpellFx.styleFor(userId: number?, domain: string, signature: string?): Style
	local base = domainStyle(domain)
	if typeof(signature) == "string" then
		return styleFromSignature(signature, domain, base)
	end
	local player = userId and Players:GetPlayerByUserId(userId)
	local raw = player and player:GetAttribute("MagicSignature")
	if not userId or typeof(raw) ~= "string" then
		return base
	end
	return styleFromSignature(raw, domain, base)
end

local function tierOf(index: any): Recipes.Refinement
	local n = if typeof(index) == "number" then math.clamp(math.floor(index), 0, 8) else 2
	return Recipes.tiers[n]
end

local function tierIndex(index: any): number
	return if typeof(index) == "number" then math.clamp(math.floor(index), 0, 8) else 2
end

-- ─── Emitter recipe (signature particles; reactions, quakes and backlash use it) ─

-- Transparency with flicker: a Novice's particles stutter; a Grandmaster's fade smoothly.
local function transparencySeq(flicker: number): NumberSequence
	if flicker <= 0.01 then
		return NumberSequence.new({ NumberSequenceKeypoint.new(0, 0.1), NumberSequenceKeypoint.new(0.7, 0.3), NumberSequenceKeypoint.new(1, 1) })
	end
	local points = { NumberSequenceKeypoint.new(0, 0.1) }
	for i = 1, 6 do
		local t = i / 7
		local base = 0.1 + t * 0.6
		table.insert(points, NumberSequenceKeypoint.new(t, math.clamp(base + (rng:NextNumber() - 0.5) * flicker * 1.6, 0, 1)))
	end
	table.insert(points, NumberSequenceKeypoint.new(1, 1))
	return NumberSequence.new(points)
end

local function sizeSeq(size: number, jitter: number): NumberSequence
	local mid = size * (1 + (rng:NextNumber() - 0.5) * jitter * 1.5)
	return NumberSequence.new({
		NumberSequenceKeypoint.new(0, size * 0.6, size * jitter * 0.5),
		NumberSequenceKeypoint.new(0.4, mid, size * jitter * 0.5),
		NumberSequenceKeypoint.new(1, 0),
	})
end

type EmitOpts = { lifetime: number, sizeMult: number?, speedMult: number?, spreadMult: number?, color: Color3?, texture: string?, rate: number? }

local function configure(e: ParticleEmitter, style: Style, tier: Recipes.Refinement, opts: EmitOpts)
	local particle = Recipes.particles[style.particle] or Recipes.particles.motes
	local motion = Recipes.motions[style.motion] or Recipes.motions.drifting
	local c0 = opts.color or style.primary
	e.Texture = opts.texture or particle.texture
	e.Color = ColorSequence.new({
		ColorSequenceKeypoint.new(0, c0),
		ColorSequenceKeypoint.new(0.5, opts.color or style.secondary),
		ColorSequenceKeypoint.new(1, opts.color or style.accent),
	})
	e.LightEmission = math.max(0.5, tier.emission)
	e.LightInfluence = particle.lightInfluence
	e.Size = sizeSeq(particle.size * (opts.sizeMult or 1), tier.sizeJitter)
	e.Transparency = transparencySeq(tier.flicker)
	e.Lifetime = NumberRange.new(opts.lifetime * (1 - tier.lifeSpread * 0.8), opts.lifetime * (1 + tier.lifeSpread))
	local speed = motion.speed * (opts.speedMult or 1)
	e.Speed = NumberRange.new(speed * 0.6, speed * 1.4)
	local spread = math.clamp(motion.spread * tier.spread * (opts.spreadMult or 1), 0, 180)
	e.SpreadAngle = Vector2.new(spread, spread)
	e.Rotation = NumberRange.new(0, 360)
	e.RotSpeed = NumberRange.new(-motion.rotSpeed, motion.rotSpeed)
	e.Drag = tier.drag
	e.Acceleration = Vector3.new(0, motion.accelerationUp, 0)
	e.EmissionDirection = Enum.NormalId.Top
	e.Shape = Enum.ParticleEmitterShape.Box
	e.ShapeStyle = Enum.ParticleEmitterShapeStyle.Volume
	e.LockedToPart = false
	e.ZOffset = 0.5
	e.Rate = opts.rate or 0
	e.TimeScale = 1
end

-- A one-shot burst: particles thrown out of a box of `radius` around `position`.
function SpellFx.burstAt(position: Vector3, radius: number, style: Style, tier: Recipes.Refinement, count: number, opts: EmitOpts)
	local anchor = FxPool.anchor(CFrame.new(position), Vector3.new(radius * 2, math.max(1, radius * 0.5), radius * 2))
	if not anchor then
		return
	end
	local e = FxPool.emitter(anchor)
	if not e then
		FxPool.release(anchor)
		return
	end
	configure(e, style, tier, opts)
	e:Emit(count)
	FxPool.releaseAfter(anchor, opts.lifetime * 2 + 0.5)
end

-- ─── Camera shake (CameraOffset is the local humanoid's own; never replicated) ─

local shakeUntil, shakeStrength = 0, 0
local shaking = false

function SpellFx.shake(strength: number, duration: number)
	if Theme.settings.reducedEffects or Theme.settings.reducedMotion then
		return
	end
	shakeStrength = math.max(shakeStrength, math.min(strength, 2.5))
	shakeUntil = math.max(shakeUntil, os.clock() + duration)
	if shaking then
		return
	end
	shaking = true
	local connection: RBXScriptConnection? = nil
	connection = RunService.RenderStepped:Connect(function()
		local character = Players.LocalPlayer.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		local remaining = shakeUntil - os.clock()
		if remaining <= 0 or not humanoid then
			if humanoid then
				humanoid.CameraOffset = Vector3.zero
			end
			shaking, shakeStrength = false, 0;
			(connection :: RBXScriptConnection):Disconnect()
			return
		end
		local s = shakeStrength * math.min(1, remaining)
		humanoid.CameraOffset = Vector3.new(rng:NextNumber(-s, s), rng:NextNumber(-s, s) * 0.6, rng:NextNumber(-s, s) * 0.3)
	end)
end

local function distanceToMe(position: Vector3): number
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then (root.Position - position).Magnitude else math.huge
end

-- ─── Shared sizing ──────────────────────────────────────────────────────────

local function powerOf(cue: { [string]: any }): number
	return if typeof(cue.power) == "number" then math.clamp(cue.power, 1, 10) else 3
end

-- Visual scale by recipe power: P1 0.74x .. P5 1.3x .. P10 2x.
local function scaleFor(power: number): number
	return 0.6 + power * 0.14
end

local function lodOf(cue: { [string]: any }): number
	return if typeof(cue.lod) == "number" then cue.lod else 2
end

-- Particle count = base x power x quality x LOD (x tier rate: masters are denser, not dimmer).
local function count(base: number, power: number, tier: Recipes.Refinement, lod: number): number
	return math.max(1, math.floor(base * scaleFor(power) * tier.rate * SpellFx.quality() * (LOD_FACTOR[lod] or 1)))
end

-- The character model a cue's caster is (players only; NPC work casts send their origin).
local function casterModel(userId: any): Model?
	local player = if typeof(userId) == "number" then Players:GetPlayerByUserId(userId) else nil
	return if player then player.Character else nil
end

-- ─── Impact ─────────────────────────────────────────────────────────────────

export type ImpactOpts = {
	position: Vector3,
	normal: Vector3?,
	radius: number, -- visual radius (studs)
	power: number,
	style: Style,
	look: DomainFx.Look,
	tier: Recipes.Refinement,
	tierIndex: number,
	lod: number,
	sound: boolean?,
	harmful: boolean?,
}

--[[
	The impact: every layer at once, scaled by power and radius. Marks, light and smoke are near-LOD
	only; far LOD keeps just the flash and shockwave of big impacts.
]]
function SpellFx.impact(o: ImpactOpts)
	local style, look, tier = o.style, o.look, o.tier
	local p = o.power
	local r = o.radius
	local scale = scaleFor(p)
	local near = o.lod >= 2 and not Theme.settings.reducedEffects
	local hotCore = FxLayers.whiten(style.primary, 0.55)

	-- 1. Flash core
	FxLayers.flash(o.position, r * 0.8, hotCore, 0.12 + 0.015 * p, look.core.dark)
	if o.lod == 0 then
		if r >= 6 then
			local ground, normal = FxLayers.ground(o.position, r)
			FxLayers.shockwave(ground or o.position, normal or Vector3.yAxis, r * 1.2, style.accent, 0.5)
		end
		return
	end

	local anchor = FxPool.anchor(CFrame.new(o.position), Vector3.one * math.max(0.5, r * 0.5))
	if not anchor then
		return
	end
	anchor.Shape = Enum.PartType.Ball

	-- 2. Core burst (bright, short, big)
	local core = FxLayers.emitter(anchor, {
		texture = if look.core.dark then TEX.implode else TEX.core,
		color = if look.core.dark then FxLayers.ramp(style, true) else ColorSequence.new(hotCore, style.primary),
		size = FxLayers.seq(0, r * 0.6, 0.3, r * 1.6, 1, r * 2),
		transparency = FxLayers.seq(0, 0, 0.5, 0.35, 1, 1),
		lifetime = NumberRange.new(0.22, 0.35),
		rotation = NumberRange.new(0, 360),
		rotSpeed = NumberRange.new(-60, 60),
		emission = if look.core.dark then 0 else 1,
		influence = if look.core.dark then 1 else 0,
		zOffset = 1,
	})
	if core then
		core:Emit(math.max(2, math.floor(3 + p * 0.4)))
	end

	-- 3. Body cloud: the domain's material thrown outward, cooling as it goes
	local body = FxLayers.emitter(anchor, {
		texture = look.body.texture,
		color = FxLayers.ramp(style, look.core.dark),
		size = FxLayers.seq(0, look.body.size * scale * 0.6, 0.35, look.body.size * scale * 1.3, 1, look.body.size * scale * 0.4),
		transparency = FxLayers.seq(0, 0.05, 0.6, 0.35, 1, 1),
		lifetime = NumberRange.new(look.body.lifetime * 0.7, look.body.lifetime * 1.3),
		speed = NumberRange.new(look.body.speed * 0.6 * scale + r * 2, look.body.speed * 1.2 * scale + r * 4),
		spread = 180,
		drag = 3 + tier.drag * 0.5,
		emission = if look.body.additive then 1 else 0.15,
		influence = if look.body.additive then 0 else 0.8,
		shape = Enum.ParticleEmitterShape.Sphere,
		style = Enum.ParticleEmitterShapeStyle.Surface,
		rotSpeed = NumberRange.new(-90, 90),
	})
	if body then
		body:Emit(count(22, p, tier, o.lod))
	end

	-- 4. Sparks / debris with gravity (wild at low tiers, tight at high)
	local sparks = FxLayers.emitter(anchor, {
		texture = look.sparks.texture,
		color = ColorSequence.new(FxLayers.whiten(style.secondary, 0.4), style.accent),
		size = FxLayers.seq(0, look.sparks.size * scale, 1, 0),
		transparency = FxLayers.seq(0, 0, 0.8, 0.2, 1, 1),
		lifetime = NumberRange.new(look.sparks.lifetime * 0.5, look.sparks.lifetime * (1 + tier.lifeSpread)),
		speed = NumberRange.new(look.sparks.speed * 0.5 * scale, look.sparks.speed * scale),
		spread = 180,
		acceleration = Vector3.new(0, -look.sparks.gravity, 0),
		drag = 1 + tier.drag * 0.3,
		emission = 1,
		shape = Enum.ParticleEmitterShape.Sphere,
		style = Enum.ParticleEmitterShapeStyle.Surface,
		rotSpeed = NumberRange.new(-200, 200),
		squash = if look.sparks.texture == TEX.fireSparks then FxLayers.seq(0, -0.6, 1, -0.2) else nil,
	})
	if sparks then
		sparks:Emit(count(18, p, tier, o.lod))
	end

	-- 5. After-smoke (near only)
	local smoke = look.smoke
	if smoke and near then
		local s = FxLayers.emitter(anchor, {
			texture = smoke.texture,
			color = FxLayers.solid(smoke.tint),
			size = FxLayers.seq(0, smoke.size * scale * 0.5, 1, smoke.size * scale * 1.6),
			transparency = FxLayers.seq(0, 0.45, 0.4, 0.6, 1, 1),
			lifetime = NumberRange.new(smoke.lifetime * 0.7, smoke.lifetime),
			speed = NumberRange.new(1, 3),
			spread = 180,
			acceleration = Vector3.new(0, 2.5, 0),
			drag = 1.5,
			influence = 1,
			rotSpeed = NumberRange.new(-25, 25),
		})
		if s then
			s:Emit(count(5, p, tier, o.lod))
		end
	end
	FxPool.releaseAfter(anchor, 2.6)

	-- 6. Shockwave ring on the ground (+ a second, inner ring at Expert and above)
	local ground, normal = FxLayers.ground(o.position, math.max(4, r))
	local surface = ground or o.position
	local up = o.normal or normal or Vector3.yAxis
	if ground or o.normal then
		FxLayers.shockwave(surface, up, r * 1.3, style.accent, 0.35 + 0.02 * p)
		if o.tierIndex >= 5 then
			FxLayers.shockwave(surface, up, r * 0.8, style.primary, 0.25 + 0.015 * p)
		end
	end

	-- 7. Light pulse, ground mark, Master+ runes (near only)
	if near then
		FxLayers.light(o.position, style.primary, look.light.brightness * (0.6 + p * 0.12), (8 + r * 3) * look.light.range, 0.35 + p * 0.03, look.light.flicker)
		if look.mark and (ground or o.normal) and (o.harmful ~= false or look.mark == "bloom" or look.mark == "rune") then
			FxLayers.groundMark(look.mark, surface, up, math.max(1.2, r * 0.8), style)
		end
		if o.tierIndex >= 6 and (ground or o.normal) then
			FxLayers.groundMark("rune", surface, up, r * 1.1, style)
		end
	end

	-- 8. Shake and sound
	local d = distanceToMe(o.position)
	local reach = 20 + r * 4
	if d < reach then
		SpellFx.shake(look.shake * (0.12 + p * 0.06) * (1 - d / reach), 0.2 + p * 0.03)
	end
	if o.sound ~= false and o.lod >= 1 then
		FxLayers.sound(o.position, look.sounds.impact, 0.6 + p * 0.06)
	end
end

-- ─── Casting ────────────────────────────────────────────────────────────────

local castExtras: { [Part]: Part } = {} -- circle anchor -> chest glow anchor

--[[
	The charge-up while the cast time runs: runic circle at the feet, inward-pulling glow at the
	chest, a swelling light and the cast sound. Returns the circle anchor (CastClient cancels it on
	a refused prediction).
]]
function SpellFx.casting(origin: Vector3, style: Style, tier: Recipes.Refinement, castTime: number, lod: any, domain: string?, power: number?): Part?
	local look = DomainFx.look(domain)
	local p = power or 3
	local hold = math.clamp(castTime, 0.3, 8)
	local q = SpellFx.quality() * (LOD_FACTOR[lod or 2] or 1)
	local feet, normal = FxLayers.ground(origin, 5)
	local circle = FxLayers.castCircle(feet or (origin - Vector3.new(0, 3, 0)), normal or Vector3.yAxis, 2.2 + p * 0.25, style, hold, q)
	if not circle then
		return nil
	end

	local chest = FxPool.anchor(CFrame.new(origin + Vector3.new(0, 1, 0)), Vector3.one * 3)
	if chest then
		castExtras[circle] = chest
		local pull = FxLayers.emitter(chest, {
			texture = TEX.sparkles,
			color = FxLayers.ramp(style),
			size = FxLayers.seq(0, 0.5 * scaleFor(p), 1, 0.05),
			transparency = FxLayers.seq(0, 0.6, 0.3, 0, 1, 0.2),
			lifetime = NumberRange.new(0.35, 0.5),
			speed = NumberRange.new(5, 7),
			emission = 1,
			shape = Enum.ParticleEmitterShape.Sphere,
			inOut = Enum.ParticleEmitterShapeInOut.Inward,
			style = Enum.ParticleEmitterShapeStyle.Surface,
			rate = 40 * q * tier.rate,
		})
		if pull then
			pull.Enabled = true
		end
		local glow = FxLayers.emitter(chest, {
			texture = TEX.glow,
			color = FxLayers.solid(style.primary),
			size = FxLayers.seq(0, 0.5, 1, 1.4 + p * 0.15),
			transparency = FxLayers.seq(0, 0.4, 1, 1),
			lifetime = NumberRange.new(0.25),
			emission = 1,
			locked = true,
			rate = 14 * q,
		})
		if glow then
			glow.Enabled = true
		end
		local light = if (lod or 2) >= 2 and not Theme.settings.reducedEffects then FxPool.light(chest) else nil
		if light then
			light.Color = style.primary
			light.Range = 8 + p
			FxLayers.animate(hold, function(t)
				light.Brightness = (0.4 + 2.2 * t) * (1 - look.light.flicker * 0.5 * rng:NextNumber())
			end)
		end
		task.delay(hold, function()
			if chest:GetAttribute("Fx") then
				FxPool.release(chest)
			end
			castExtras[circle] = nil
		end)
	end
	if (lod or 2) >= 1 then
		FxLayers.sound(origin, look.sounds.cast, 0.8)
	end
	return circle
end

function SpellFx.cancel(anchor: Part?)
	if anchor then
		local chest = castExtras[anchor]
		castExtras[anchor] = nil
		if chest and chest:GetAttribute("Fx") then
			FxPool.release(chest)
		end
		FxPool.release(anchor)
	end
end

-- ─── Projectiles (mirroring the server's flight) ────────────────────────────

type FlightVisual = {
	anchor: Part,
	done: boolean,
	cue: { [string]: any },
	finish: (point: Vector3, normal: Vector3?, expired: boolean) -> (),
}
local flights: { [string]: FlightVisual } = {}
local pendingImpacts: { [string]: { [string]: any } } = {} -- impact cues that beat their launch cue

local function flightKey(cue: { [string]: any }): string?
	if typeof(cue.projectileId) ~= "number" then
		return nil
	end
	return tostring(cue.caster or "npc") .. ":" .. tostring(cue.projectileId)
end

local function homingRoot(model: any): BasePart?
	if typeof(model) == "Instance" and model:IsA("Model") then
		local root = model:FindFirstChild("HumanoidRootPart")
		return if root and root:IsA("BasePart") then root else nil
	end
	return nil
end

--[[
	A bolt that flies the server's path: same velocity, gravity and homing steering. Bursts where
	the server's impact cue says (it normally arrives as the bolt gets there; if it never does,
	the bolt fades at the end of its lifetime).
]]
function SpellFx.launch(cue: { [string]: any })
	local key = flightKey(cue)
	if not key or typeof(cue.origin) ~= "Vector3" or typeof(cue.velocity) ~= "Vector3" then
		return
	end
	local style = SpellFx.styleFor(cue.caster, cue.domain or "energy", cue.signature)
	local look = DomainFx.look(cue.domain)
	local tier = tierOf(cue.masteryTier)
	local lod = lodOf(cue)
	local p = powerOf(cue)
	local scale = scaleFor(p)
	local coreSize = 0.5 + p * 0.13
	local velocity0: Vector3 = cue.velocity

	local anchor = FxPool.anchor(CFrame.new(cue.origin), Vector3.one * coreSize)
	if not anchor then
		return
	end
	anchor.Shape = Enum.PartType.Ball
	anchor.Material = if look.core.dark then Enum.Material.SmoothPlastic else Enum.Material.Neon
	anchor.Color = if look.core.dark then Color3.fromRGB(12, 8, 18) else FxLayers.whiten(style.primary, 0.45)
	anchor.Transparency = 0

	local q = SpellFx.quality() * (LOD_FACTOR[lod] or 1)
	-- Halo around the core (locked: it moves with the bolt).
	local halo = FxLayers.emitter(anchor, {
		texture = TEX.glow,
		color = FxLayers.solid(style.primary),
		size = FxLayers.seq(0, coreSize * 2.6, 1, coreSize * 3.2),
		transparency = FxLayers.seq(0, 0.35, 1, 1),
		lifetime = NumberRange.new(0.12),
		emission = 1,
		locked = true,
		rate = 40,
	})
	if halo then
		halo.Enabled = true
	end
	-- Body shed behind the bolt: hot at the core, cooling into the signature colours.
	local body = FxLayers.emitter(anchor, {
		texture = look.body.texture,
		color = FxLayers.ramp(style, look.core.dark),
		size = FxLayers.seq(0, look.body.size * scale * 0.7, 1, 0),
		transparency = FxLayers.seq(0, 0.1, 0.7, 0.5, 1, 1),
		lifetime = NumberRange.new(look.body.lifetime * 0.4, look.body.lifetime * 0.7),
		speed = NumberRange.new(0.5, 2),
		spread = 25 * tier.spread,
		drag = 2,
		emission = if look.body.additive then 1 else 0.2,
		influence = if look.body.additive then 0 else 0.7,
		shape = Enum.ParticleEmitterShape.Sphere,
		rotSpeed = NumberRange.new(-120, 120),
		rate = 60 * q * tier.rate,
	})
	if body then
		body.Enabled = true
	end
	-- Sparks flicking off with gravity.
	local sparks = FxLayers.emitter(anchor, {
		texture = look.sparks.texture,
		color = ColorSequence.new(FxLayers.whiten(style.secondary, 0.4), style.accent),
		size = FxLayers.seq(0, look.sparks.size * scale * 0.7, 1, 0),
		transparency = FxLayers.seq(0, 0, 1, 1),
		lifetime = NumberRange.new(0.2, 0.45),
		speed = NumberRange.new(3, 9),
		spread = 180,
		acceleration = Vector3.new(0, -look.sparks.gravity, 0),
		emission = 1,
		rate = 24 * q,
	})
	if sparks then
		sparks.Enabled = true
	end
	-- Trail: two attachments across the bolt, facing the camera.
	local a0 = anchor:FindFirstChild("A") :: Attachment
	a0.Position = Vector3.new(0, coreSize * 0.45, 0)
	local a1 = Instance.new("Attachment")
	a1.Position = Vector3.new(0, -coreSize * 0.45, 0)
	a1.Parent = anchor
	local trail = FxPool.trail(anchor)
	if trail then
		trail.Attachment0, trail.Attachment1 = a0, a1
		trail.Lifetime = tier.trailLife + 0.05 * p
		trail.Color = ColorSequence.new(FxLayers.whiten(style.primary, 0.3), style.accent)
		trail.Transparency = FxLayers.seq(0, 0.15, 1, 1)
		trail.LightEmission = if look.core.dark then 0 else 1
		trail.FaceCamera = true
		trail.WidthScale = FxLayers.seq(0, 1, 1, 0)
		trail.MinLength = 0.05
		trail.Texture = TEX.streak -- "" (plain) until the streak texture is uploaded
		trail.TextureMode = Enum.TextureMode.Stretch
		trail.Brightness = if look.core.dark then 1 else 1.6
	end
	if lod >= 1 then
		SpellFx.muzzle(cue.origin, velocity0, style, p, look.core.dark)
	end
	local light = if lod >= 2 and not Theme.settings.reducedEffects then FxPool.light(anchor) else nil
	if light then
		light.Color = style.primary
		light.Range = (8 + p * 1.2) * look.light.range
		light.Brightness = look.light.brightness * 0.5
	end
	if lod >= 1 then
		FxLayers.sound(cue.origin, look.sounds.launch, 0.7)
	end

	-- Integrate exactly as Cast/Delivery does: gravity, then homing steering.
	local position: Vector3 = cue.origin
	local velocity: Vector3 = cue.velocity
	local gravity = if typeof(cue.gravity) == "number" then cue.gravity else 0
	local turnRate = if typeof(cue.turnRate) == "number" then cue.turnRate else 0
	local homing = homingRoot(cue.homing)
	local lifetime = (if typeof(cue.lifetime) == "number" then cue.lifetime else 4) + 0.5
	local wobble = tier.beamCurve * 0.15 -- a Novice's bolt weaves a little
	local started = os.clock()
	local last = started

	local visual: FlightVisual
	local connection: RBXScriptConnection? = nil
	local function finish(point: Vector3, _normal: Vector3?, expired: boolean)
		if visual.done then
			return
		end
		visual.done = true
		flights[key] = nil
		if connection then
			connection:Disconnect()
		end
		anchor.CFrame = CFrame.new(point)
		anchor.Transparency = 1
		for _, e in { halo, body, sparks } do
			if e then
				e.Enabled = false
			end
		end
		if light then
			light.Enabled = false
		end
		FxPool.releaseAfter(anchor, (if trail then trail.Lifetime else 0) + 0.6)
		if expired then
			-- Fizzled in the air: a small pop, no shockwave or mark.
			SpellFx.burstAt(point, 0.6, style, tier, count(10, p, tier, lod), { lifetime = 0.4, speedMult = 2 })
		end
	end
	visual = { anchor = anchor, done = false, cue = cue, finish = finish }
	flights[key] = visual

	connection = RunService.RenderStepped:Connect(function()
		local t = os.clock()
		local dt = math.min(t - last, 0.1)
		last = t
		if t - started > lifetime then
			finish(position, nil, true)
			return
		end
		if homing and homing.Parent and turnRate > 0 then
			local to = homing.Position - position
			local speed = velocity.Magnitude
			if to.Magnitude > 0.5 and speed > 0.1 then
				local current, desired = velocity.Unit, to.Unit
				local angle = math.acos(math.clamp(current:Dot(desired), -1, 1))
				local s = if angle > 1e-4 then math.min(1, turnRate * dt / angle) else 1
				local turned = current:Lerp(desired, s)
				velocity = (if turned.Magnitude > 1e-3 then turned.Unit else desired) * speed
			end
		end
		velocity -= Vector3.new(0, gravity * dt, 0)
		position += velocity * dt
		local weave = if wobble > 0 then Vector3.new(0, math.sin((t - started) * 18) * wobble, 0) else Vector3.zero
		local p0 = position + weave
		anchor.CFrame = if velocity.Magnitude > 0.1 then CFrame.lookAt(p0, p0 + velocity) else CFrame.new(p0)
	end)

	-- The impact cue arrived before this launch cue (a dropped or reordered packet): land now.
	local early = pendingImpacts[key]
	if early then
		pendingImpacts[key] = nil
		finish(early.point, early.normal, early.expired == true)
	end
end

-- ─── Muzzle flash ───────────────────────────────────────────────────────────

--[[
	A launch flash: a flame-shaped burst standing ALONG the shot (VelocityParallel turns the
	texture's up edge to the emitter's Top face, which points down the shot), plus a quick round
	glow at the hand. ~0.15 s; two emitters on one anchor.
]]
function SpellFx.muzzle(origin: Vector3, direction: Vector3, style: Style, power: number, dark: boolean)
	if direction.Magnitude < 0.01 then
		return
	end
	local dir = direction.Unit
	local size = 1.4 + power * 0.18
	-- LookVector = dir, then pitch -90° so the Top face (UpVector) points along dir. The flame
	-- texture is centred on the emitter, so step it forward to put its base at the hand.
	local at = origin + dir * size * 0.35
	local anchor = FxPool.anchor(CFrame.lookAt(at, at + dir) * CFrame.Angles(-math.pi / 2, 0, 0))
	if not anchor then
		return
	end
	local flame = FxLayers.emitter(anchor, {
		texture = TEX.muzzle,
		color = if dark then FxLayers.solid(style.primary:Lerp(Color3.new(0, 0, 0), 0.6)) else FxLayers.ramp(style),
		size = FxLayers.seq(0, size * 0.55, 1, size),
		transparency = FxLayers.seq(0, 0, 0.6, 0.3, 1, 1),
		lifetime = NumberRange.new(0.14),
		speed = NumberRange.new(0.01),
		rotation = NumberRange.new(0),
		emission = if dark then 0 else 1,
		influence = 0,
		orientation = Enum.ParticleOrientation.VelocityParallel,
	})
	if flame then
		flame.Brightness = if dark then 1 else 2
		flame:Emit(2)
	end
	local flash = FxLayers.emitter(anchor, {
		texture = TEX.glow,
		color = FxLayers.solid(if dark then style.secondary else FxLayers.whiten(style.primary, 0.5)),
		size = FxLayers.seq(0, size * 0.9, 1, size * 1.3),
		transparency = FxLayers.seq(0, 0.2, 1, 1),
		lifetime = NumberRange.new(0.1),
		emission = if dark then 0.3 else 1,
	})
	if flash then
		flash:Emit(1)
	end
	FxPool.releaseAfter(anchor, 0.4)
end

-- ─── Lightning ──────────────────────────────────────────────────────────────

local BOLT_TEXTURES = { TEX.lightning, TEX.lightningAlt, TEX.lightningAlt2 }

--[[
	Lightning from `origin` to `point`: a jagged white-hot core (one thin beam per segment between
	jittered joints) re-struck every 45–75 ms, inside a wide crackling beam whose bolt texture
	swaps on every strike. One anchor at the midpoint holds every joint (extra attachments are
	destroyed with it) and a flickering light. At most 6 beams per bolt (FxPool caps beams at 40).
]]
function SpellFx.lightning(origin: Vector3, point: Vector3, style: Style, tier: Recipes.Refinement, width: number, duration: number)
	local span = point - origin
	local length = span.Magnitude
	if length < 0.2 then
		return
	end
	local anchor = FxPool.anchor(CFrame.new(origin + span / 2))
	if not anchor then
		return
	end
	local segments = math.clamp(math.floor(length / 6) + 2, 3, 5)
	local joints: { Attachment } = { anchor:FindFirstChild("A") :: Attachment }
	for i = 1, segments do
		local joint = Instance.new("Attachment")
		joint.Parent = anchor
		joints[i + 1] = joint
	end
	-- Two axes across the bolt for the jitter.
	local dir = span.Unit
	local side = dir:Cross(Vector3.yAxis)
	if side.Magnitude < 0.1 then
		side = dir:Cross(Vector3.xAxis)
	end
	side = side.Unit
	local up = side:Cross(dir).Unit
	-- Low tiers fork wider (their wild beamCurve); every bolt stays pinned at both ends.
	local jag = math.clamp(length * 0.07, 0.35, 3) * (1 + tier.beamCurve * 0.25)
	local function strike()
		for i = 0, segments do
			local t = i / segments
			local offset = Vector3.zero
			if i > 0 and i < segments then
				local taper = math.sin(t * math.pi)
				offset = (side * (rng:NextNumber() - 0.5) + up * (rng:NextNumber() - 0.5)) * 2 * jag * taper
			end
			joints[i + 1].WorldPosition = origin + span * t + offset
		end
	end
	strike()

	local hot = FxLayers.whiten(style.primary, 0.85)
	local cores: { Beam } = {}
	for i = 1, segments do
		local b = FxPool.beam(anchor)
		if b then
			b.Attachment0, b.Attachment1 = joints[i], joints[i + 1]
			b.Color = ColorSequence.new(hot)
			b.Width0, b.Width1 = width * 0.32, width * 0.32
			b.LightEmission = 1
			b.LightInfluence = 0
			b.Brightness = 2.5
			b.FaceCamera = true
			b.Segments = 1
			b.Transparency = NumberSequence.new(0)
			table.insert(cores, b)
		end
	end
	local crackle = FxPool.beam(anchor)
	if crackle then
		crackle.Attachment0, crackle.Attachment1 = joints[1], joints[segments + 1]
		crackle.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, FxLayers.whiten(style.primary, 0.3)),
			ColorSequenceKeypoint.new(0.5, style.primary),
			ColorSequenceKeypoint.new(1, style.accent),
		})
		crackle.Width0, crackle.Width1 = width * 2.4, width * 2
		crackle.LightEmission = 1
		crackle.LightInfluence = 0
		crackle.Brightness = 3
		crackle.Texture = BOLT_TEXTURES[1]
		crackle.TextureMode = Enum.TextureMode.Stretch
		crackle.FaceCamera = true
		crackle.Segments = 12
	end
	local light = if Theme.settings.reducedEffects then nil else FxPool.light(anchor)
	if light then
		light.Color = style.primary
		light.Range = math.clamp(8 + length * 0.3, 8, 40)
	end

	local nextStrike = 0
	FxLayers.animate(duration, function(t)
		local now = t * duration
		if now >= nextStrike then
			nextStrike = now + 0.045 + rng:NextNumber() * 0.03
			strike()
			if crackle then
				crackle.Texture = BOLT_TEXTURES[rng:NextInteger(1, #BOLT_TEXTURES)]
				crackle.CurveSize0 = (rng:NextNumber() - 0.5) * jag * 2
				crackle.CurveSize1 = (rng:NextNumber() - 0.5) * jag * 2
			end
		end
		-- Fades out, with dark blinks between strikes (a real bolt flickers).
		local blink = if rng:NextNumber() < 0.2 then 0.55 else 0
		local fade = math.clamp(t ^ 2 + blink * (0.3 + t), 0, 1)
		for _, b in cores do
			b.Transparency = NumberSequence.new(fade)
		end
		if crackle then
			crackle.Transparency = NumberSequence.new(math.clamp(0.1 + fade, 0, 1))
		end
		if light then
			light.Brightness = 4 * (1 - fade)
		end
	end, function()
		FxPool.release(anchor)
	end)
end

-- ─── Beams and chains ───────────────────────────────────────────────────────

-- A two-layer beam: white-hot narrow core inside a wide textured beam in the signature colours.
function SpellFx.beam(origin: Vector3, point: Vector3, style: Style, tier: Recipes.Refinement, width: number, duration: number, look: DomainFx.Look?)
	local from = FxPool.anchor(CFrame.new(origin))
	local to = FxPool.anchor(CFrame.new(point))
	if not from or not to then
		if from then
			FxPool.release(from)
		end
		if to then
			FxPool.release(to)
		end
		return
	end
	local a0 = from:FindFirstChild("A") :: Attachment
	local a1 = to:FindFirstChild("A") :: Attachment
	local dark = look ~= nil and look.core.dark
	local outer = FxPool.beam(from)
	local inner = FxPool.beam(from)
	if outer then
		outer.Attachment0, outer.Attachment1 = a0, a1
		outer.Color = ColorSequence.new({
			ColorSequenceKeypoint.new(0, style.primary),
			ColorSequenceKeypoint.new(0.5, style.secondary),
			ColorSequenceKeypoint.new(1, style.accent),
		})
		outer.Width0, outer.Width1 = width * 1.6, width * 1.2
		outer.LightEmission = if dark then 0 else 1
		outer.LightInfluence = if dark then 0.6 else 0
		outer.Texture = if look then look.body.texture else TEX.sparkles
		outer.TextureMode = Enum.TextureMode.Wrap
		outer.TextureLength = 3
		outer.TextureSpeed = 3 + tier.drag * 0.4
		outer.FaceCamera = true
		outer.Segments = 16
		outer.CurveSize0 = (rng:NextNumber() - 0.5) * 2 * tier.beamCurve
		outer.CurveSize1 = (rng:NextNumber() - 0.5) * 2 * tier.beamCurve
	end
	if inner then
		inner.Attachment0, inner.Attachment1 = a0, a1
		inner.Color = ColorSequence.new(if dark then Color3.fromRGB(10, 6, 16) else FxLayers.whiten(style.primary, 0.75))
		inner.Width0, inner.Width1 = width * 0.45, width * 0.35
		inner.LightEmission = if dark then 0 else 1
		inner.LightInfluence = 0
		inner.Texture = ""
		inner.FaceCamera = true
		inner.Segments = 16
		inner.CurveSize0, inner.CurveSize1 = 0, 0
	end
	local wobble = tier.beamCurve
	FxLayers.animate(duration, function(t)
		local noise = if tier.flicker > 0 then rng:NextNumber() * tier.flicker * 0.6 else 0
		local fade = math.clamp(t ^ 3 + noise, 0, 1)
		if outer then
			outer.Transparency = NumberSequence.new(math.clamp(0.1 + fade, 0, 1))
			if wobble > 0 then
				outer.CurveSize0 = (rng:NextNumber() - 0.5) * 2 * wobble
				outer.CurveSize1 = (rng:NextNumber() - 0.5) * 2 * wobble
			end
		end
		if inner then
			inner.Transparency = NumberSequence.new(fade)
			inner.Width0 = width * 0.45 * (1 - t * 0.6)
		end
	end, function()
		FxPool.release(from)
		FxPool.release(to)
	end)
end

-- ─── The spell cue ──────────────────────────────────────────────────────────

local AREA_FORMS: { [string]: boolean } = { burst = true, zone = true, ritual = true, pillar = true, wall = true, summon = true }

-- A column of light rising from the ground (pillar, ritual, summon).
local function column(base: Vector3, radius: number, height: number, style: Style, duration: number)
	local anchor = FxPool.anchor(CFrame.new(base + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2), Vector3.new(0.2, radius * 2, radius * 2))
	if not anchor then
		return
	end
	anchor.Shape = Enum.PartType.Cylinder
	anchor.Material = Enum.Material.Neon
	anchor.Color = FxLayers.whiten(style.primary, 0.3)
	anchor.Transparency = 0.3
	local rising = FxLayers.emitter(anchor, {
		texture = TEX.sparkles,
		color = FxLayers.ramp(style),
		size = FxLayers.seq(0, 0.6, 1, 0),
		transparency = FxLayers.seq(0, 0.1, 1, 1),
		lifetime = NumberRange.new(0.6, 1),
		speed = NumberRange.new(height * 0.6, height),
		emission = 1,
		direction = Enum.NormalId.Right, -- the cylinder's axis is its X (rotated upright)
		shape = Enum.ParticleEmitterShape.Disc,
		rate = 50 * SpellFx.quality(),
	})
	if rising then
		rising.Enabled = true
	end
	FxLayers.animate(duration, function(t)
		local rise = math.min(1, t * 4)
		anchor.Size = Vector3.new(height * rise, radius * 2 * (1 - t * 0.5), radius * 2 * (1 - t * 0.5))
		anchor.CFrame = CFrame.new(base + Vector3.new(0, height * rise / 2, 0)) * CFrame.Angles(0, 0, math.pi / 2)
		anchor.Transparency = 0.3 + 0.7 * t ^ 1.5
	end, function()
		FxPool.release(anchor)
	end)
end

local function impactRadius(form: string, cue: { [string]: any }, power: number): number
	local area = if typeof(cue.radius) == "number" then cue.radius else 0
	if AREA_FORMS[form] or form == "aura" then
		return math.clamp(area, 2, 60)
	end
	return 1 + power * 0.32 + math.min(area, 4) * 0.25
end

function SpellFx.spell(cue: { [string]: any })
	local style = SpellFx.styleFor(cue.caster, cue.domain or "energy", cue.signature)
	local look = DomainFx.look(cue.domain)
	local tier = tierOf(cue.masteryTier)
	local tIndex = tierIndex(cue.masteryTier)
	local form: string = if typeof(cue.form) == "string" then cue.form else "touch"
	local origin: Vector3 = if typeof(cue.origin) == "Vector3" then cue.origin else cue.position
	local point: Vector3 = if typeof(cue.point) == "Vector3" then cue.point else cue.position
	local lod = lodOf(cue)
	local p = powerOf(cue)
	local stage = cue.stage

	if stage == "begin" then
		SpellFx.casting(origin, style, tier, cue.castTime or 0.5, lod, cue.domain, p)
		return
	elseif stage == "launch" then
		SpellFx.launch(cue)
		return
	elseif stage == "chain" then
		-- Arcs between everyone the chain struck, in order.
		local points = cue.points
		if typeof(points) == "table" and lod >= 1 then
			local width = 0.25 + p * 0.05
			local electric = cue.property == "charge"
			for i = 1, #points - 1 do
				local a, b = points[i], points[i + 1]
				if typeof(a) == "Vector3" and typeof(b) == "Vector3" then
					task.delay((i - 1) * 0.06, function()
						if electric then
							SpellFx.lightning(a, b, style, tier, width, 0.32)
						else
							SpellFx.beam(a, b, style, tier, width, 0.3, look)
						end
						SpellFx.impact({ position = b, radius = 0.9 + p * 0.12, power = math.max(1, p - i), style = style, look = look, tier = tier, tierIndex = tIndex, lod = lod, sound = false })
					end)
				end
			end
		end
		return
	end

	-- Resolve.
	if cue.backfire then
		-- Loss of control: the caster's own magic bursts in their face, wild and in the accent colour.
		SpellFx.impact({ position = origin + Vector3.new(0, 1, 0), radius = 1.5 + p * 0.25, power = p, style = { primary = style.accent, secondary = style.primary, accent = style.secondary, particle = style.particle, motion = style.motion }, look = look, tier = Recipes.tiers[0], tierIndex = 0, lod = lod })
		return
	end
	if lod == 0 and not (AREA_FORMS[form] or form == "aura") then
		return -- far away: only the big shapes are worth drawing
	end

	local key = flightKey(cue)
	local radius = impactRadius(form, cue, p)
	local normal: Vector3? = if typeof(cue.normal) == "Vector3" then cue.normal else nil
	local impactOpts: ImpactOpts = {
		position = point,
		normal = normal,
		radius = radius,
		power = p,
		style = style,
		look = look,
		tier = tier,
		tierIndex = tIndex,
		lod = lod,
		harmful = cue.harmful,
	}

	if form == "projectile" then
		if key then
			local flight = flights[key]
			if flight then
				flight.finish(point, normal, cue.expired == true)
			else
				pendingImpacts[key] = { point = point, normal = normal, expired = cue.expired }
				task.delay(2, function()
					pendingImpacts[key :: string] = nil
				end)
			end
		end
		if cue.expired then
			return
		end
		SpellFx.impact(impactOpts)
	elseif form == "beam" or form == "chain" then
		local width = (0.35 + p * 0.09) * (if form == "chain" then 0.7 else 1)
		local model = casterModel(cue.caster)
		local hand = model and (model:FindFirstChild("RightHand") or model:FindFirstChild("Right Arm"))
		local from = if hand and hand:IsA("BasePart") then hand.Position else origin + Vector3.new(0, 1.5, 0)
		if cue.property == "charge" then
			SpellFx.lightning(from, point, style, tier, width, 0.35 + p * 0.04)
		else
			SpellFx.beam(from, point, style, tier, width, 0.35 + p * 0.04, look)
		end
		SpellFx.burstAt(from, 0.4, style, tier, count(8, p, tier, lod), { lifetime = 0.25, texture = TEX.glow, speedMult = 0.5 })
		impactOpts.radius = 0.8 + p * 0.22
		SpellFx.impact(impactOpts)
	elseif form == "aura" then
		local model = casterModel(cue.caster)
		local root = model and model:FindFirstChild("HumanoidRootPart")
		local centre = if root and root:IsA("BasePart") then root.Position else origin
		local ground, up = FxLayers.ground(centre, 5)
		FxLayers.shockwave(ground or centre, up or Vector3.yAxis, radius, style.primary, 0.5)
		FxLayers.shockwave(ground or centre, up or Vector3.yAxis, radius * 0.7, style.accent, 0.4)
		SpellFx.burstAt(centre, radius * 0.6, style, tier, count(30, p, tier, lod), { lifetime = 0.9, speedMult = 1.5 })
		FxLayers.light(centre, style.primary, look.light.brightness * 0.6, 8 + radius * 2, 0.6, look.light.flicker)
		FxLayers.sound(centre, look.sounds.impact, 0.5)
	elseif form == "touch" then
		impactOpts.radius = 0.9 + p * 0.2
		SpellFx.impact(impactOpts)
	elseif form == "zone" then
		local ground, up = FxLayers.ground(point, 8)
		local at = ground or point
		FxLayers.groundMark("rune", at, up or Vector3.yAxis, radius, style)
		FxLayers.shockwave(at, up or Vector3.yAxis, radius, style.accent, 0.6)
		SpellFx.burstAt(at + Vector3.new(0, 1, 0), radius * 0.8, style, tier, count(40, p, tier, lod), { lifetime = 1.6, speedMult = 0.6 })
		impactOpts.radius = math.min(radius, 6)
		impactOpts.sound = true
		SpellFx.impact(impactOpts)
	elseif form == "pillar" or form == "ritual" or form == "summon" or form == "wall" then
		local ground, up = FxLayers.ground(point, 8)
		local at = ground or point
		local height = if form == "ritual" then 40 + p * 4 else 10 + p * 2
		FxLayers.groundMark("rune", at, up or Vector3.yAxis, math.min(radius, 30), style)
		if form ~= "wall" then
			column(at, math.clamp(radius * 0.35, 1, 8), height, style, if form == "ritual" then 2.5 else 1.2)
		end
		impactOpts.radius = math.min(radius, 12)
		SpellFx.impact(impactOpts)
	else -- burst
		SpellFx.impact(impactOpts)
	end
end

-- Persistent zone rings (fields). Kept by id until field_end or their duration.
local fieldVisuals: { [number]: Part } = {}

function SpellFx.field(cue: { [string]: any })
	local recipe = Recipes.fields[cue.field] or Recipes.fields.time
	local radius = if typeof(cue.radius) == "number" then cue.radius else 10
	local height = if typeof(cue.height) == "number" then cue.height else radius
	local ring = Instance.new("Part")
	ring.Name = "FieldVisual"
	ring.Anchored = true
	ring.CanCollide = false
	ring.CanQuery = false
	ring.CanTouch = false
	ring.CastShadow = false
	ring.Shape = Enum.PartType.Cylinder
	ring.Material = Enum.Material.ForceField
	ring.Color = recipe.color
	ring.Transparency = if Theme.settings.reducedEffects then 0.95 else recipe.transparency
	ring.Size = Vector3.new(height * 2, radius * 2, radius * 2)
	local position: Vector3 = cue.position
	ring.CFrame = CFrame.new(position) * CFrame.Angles(0, 0, math.pi / 2)
	ring.Parent = workspace:FindFirstChild("MagicFx") or workspace
	local id = cue.id
	if typeof(id) == "number" then
		fieldVisuals[id] = ring
	end
	local followUser = cue.followUserId
	local expires = os.clock() + (if typeof(cue.duration) == "number" then cue.duration else 10)
	local connection: RBXScriptConnection? = nil
	connection = RunService.Heartbeat:Connect(function()
		if not ring.Parent or os.clock() >= expires then
			(connection :: RBXScriptConnection):Disconnect()
			ring:Destroy()
			if typeof(id) == "number" then
				fieldVisuals[id] = nil
			end
			return
		end
		if typeof(followUser) == "number" then
			local player = Players:GetPlayerByUserId(followUser)
			local root = player and player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				ring.CFrame = CFrame.new(root.Position) * CFrame.Angles(0, 0, math.pi / 2)
			end
		end
	end)
end

function SpellFx.fieldEnd(cue: { [string]: any })
	local ring = fieldVisuals[cue.id]
	if ring then
		ring:Destroy()
		fieldVisuals[cue.id] = nil
	end
end

-- A spell wave (Breaker): a translucent wall of water rolling along the ground.
function SpellFx.wave(cue: { [string]: any })
	local origin: Vector3 = cue.origin
	local direction: Vector3 = cue.direction
	local width: number = cue.width or 20
	local crest: number = cue.crest or 4
	local reach: number = cue.reach or 60
	local speed = 70
	local wall = Instance.new("Part")
	wall.Anchored = true
	wall.CanCollide = false
	wall.CanQuery = false
	wall.CanTouch = false
	wall.Material = Enum.Material.Glass
	wall.Color = Color3.fromRGB(70, 150, 235)
	wall.Transparency = 0.35
	wall.Size = Vector3.new(width, crest, 4)
	wall.Parent = workspace:FindFirstChild("MagicFx") or workspace
	-- The wall owns its foam emitter (not pooled): both go when the wave ends.
	local foam = Instance.new("ParticleEmitter")
	local style: Style = { primary = Color3.new(1, 1, 1), secondary = Color3.fromRGB(200, 230, 255), accent = Color3.fromRGB(150, 200, 255), particle = "bubbles", motion = "drifting" }
	configure(foam, style, Recipes.tiers[5], { lifetime = 0.8, rate = 80 * SpellFx.quality(), sizeMult = 1.4 })
	foam.Parent = wall
	foam.Enabled = true
	local started = os.clock()
	local connection: RBXScriptConnection? = nil
	connection = RunService.RenderStepped:Connect(function()
		local s = (os.clock() - started) * speed
		if s >= reach then
			(connection :: RBXScriptConnection):Disconnect()
			wall:Destroy()
			return
		end
		local p = origin + direction * s
		wall.CFrame = CFrame.lookAt(p + Vector3.new(0, crest / 2, 0), p + direction + Vector3.new(0, crest / 2, 0))
	end)
end

-- Tsunami: the server writes the water itself; the client adds spray along the front and a rumble.
function SpellFx.tsunami(cue: { [string]: any })
	local origin: Vector3 = cue.origin
	local direction: Vector3 = cue.direction
	local speed: number = cue.speed or 70
	local width: number = cue.width or 200
	local anchor = FxPool.anchor(CFrame.new(origin), Vector3.new(width, 2, 6))
	if not anchor then
		return
	end
	local spray = FxPool.emitter(anchor)
	local style: Style = { primary = Color3.new(1, 1, 1), secondary = Color3.fromRGB(210, 235, 255), accent = Color3.fromRGB(120, 180, 240), particle = "smoke", motion = "drifting" }
	if spray then
		configure(spray, style, Recipes.tiers[6], { lifetime = 1.5, rate = 160 * SpellFx.quality(), sizeMult = 3, speedMult = 3 })
		spray.Enabled = true
	end
	local started = os.clock()
	local connection: RBXScriptConnection? = nil
	connection = RunService.RenderStepped:Connect(function()
		local elapsed = os.clock() - started
		if elapsed > 30 then
			(connection :: RBXScriptConnection):Disconnect()
			FxPool.release(anchor)
			return
		end
		local p = origin + direction * (elapsed * speed)
		anchor.CFrame = CFrame.lookAt(p + Vector3.new(0, (cue.crest or 20), 0), p + direction + Vector3.new(0, (cue.crest or 20), 0))
		if distanceToMe(p) < 200 then
			SpellFx.shake(0.4, 0.3)
		end
	end)
end

function SpellFx.quake(cue: { [string]: any })
	local position: Vector3 = cue.position
	local radius: number = cue.radius or 60
	local magnitude: number = cue.magnitude or 3
	local d = distanceToMe(position)
	if d < radius * 2.5 then
		SpellFx.shake(magnitude * 0.35 * (1 - d / (radius * 2.5)), cue.duration or 3)
	end
	local dust = Recipes.reactions.tremor
	local style: Style = { primary = dust.color, secondary = dust.color, accent = dust.color, particle = "dust", motion = "drifting" }
	SpellFx.burstAt(position, math.min(radius, 60), style, Recipes.tiers[4], math.floor(dust.count * SpellFx.quality() * math.clamp(magnitude / 3, 0.5, 3)), { lifetime = dust.lifetime, texture = dust.texture, sizeMult = 2 })
end

function SpellFx.reaction(kind: string, cue: { [string]: any })
	local recipe = Recipes.reactions[kind]
	if not recipe then
		return
	end
	local style: Style = { primary = recipe.color, secondary = recipe.color, accent = recipe.color, particle = "motes", motion = "swirling" }
	local radius = if typeof(cue.radius) == "number" then math.clamp(cue.radius, 2, 40) else 6
	SpellFx.burstAt(cue.position, radius, style, Recipes.tiers[4], math.floor(recipe.count * SpellFx.quality() * (LOD_FACTOR[cue.lod or 2] or 1)), {
		lifetime = recipe.lifetime,
		texture = recipe.texture,
		color = recipe.color,
		sizeMult = 1.5,
	})
	if kind == "tremor" then
		local d = distanceToMe(cue.position)
		if d < radius * 2 then
			SpellFx.shake((cue.magnitude or 1) * 0.3, 1.2)
		end
	end
end

function SpellFx.backlash(cue: { [string]: any })
	SpellFx.reaction("backlash", cue)
	if cue.caster == Players.LocalPlayer.UserId then
		SpellFx.shake(0.6 * math.clamp(cue.severity or 1, 0.5, 2), 0.5)
	end
end

-- ─── Status overlays (only ever for the local player) ───────────────────────

local overlays: { [string]: number } = {} -- status -> expiry (os.clock)
local correction: ColorCorrectionEffect? = nil
local blur: BlurEffect? = nil

local function applyOverlays()
	if not correction then
		local cc = Instance.new("ColorCorrectionEffect")
		cc.Name = "MagicStatus"
		cc.Parent = Lighting
		correction = cc
		local b = Instance.new("BlurEffect")
		b.Name = "MagicStatusBlur"
		b.Size = 0
		b.Parent = Lighting
		blur = b
	end
	local cc = correction :: ColorCorrectionEffect
	local b = blur :: BlurEffect
	local now = os.clock()
	local function on(id: string): boolean
		return (overlays[id] or 0) > now
	end
	cc.Brightness = if on("blind") then -0.35 elseif on("fear") then -0.1 else 0
	cc.Contrast = if on("fear") then 0.3 else 0
	cc.Saturation = if on("silence") then -0.8 elseif on("stasis") then -0.6 elseif on("time_slow") then -0.4 elseif on("time_haste") then 0.25 else 0
	cc.TintColor = if on("burning") then Color3.fromRGB(255, 205, 175)
		elseif on("stasis") then Color3.fromRGB(205, 230, 255)
		elseif on("time_slow") then Color3.fromRGB(255, 238, 205)
		else Color3.new(1, 1, 1)
	b.Size = if on("blind") and not Theme.settings.reducedEffects then 18 else 0
end

function SpellFx.status(cue: { [string]: any })
	local id = cue.status
	if typeof(id) ~= "string" then
		return
	end
	if cue.active then
		overlays[id] = os.clock() + (if typeof(cue.duration) == "number" then cue.duration else 5)
		task.delay((cue.duration or 5) + 0.05, applyOverlays)
	else
		overlays[id] = nil
	end
	applyOverlays()
end

return SpellFx
