--!strict
--[[
	Conjure: a spell visibly forming while its caster charges it (docs/SpellHand.md). Client only;
	Controllers/AttuneGlowController starts one when a nearby body starts charging and feeds it the
	charge progress each frame.

	WHERE (Magic/SpellHand.modeFor, by the attuned form)
		hand      touch, projectile, beam, chain: in front of the palm
		overhead  burst, summon: above the head
		ground    aura, wall, zone, pillar, ritual: a rune circle at the feet, with the core rising
		          from its centre
	WHAT
		core      the domain's look (Data/SpellHand: material, transparency; lightning is not
		          fire), in the caster's Signature colours, swirled by the domain's own spell texture
		shape     the caster's hand: orb (one core), shards (crystals around a small core), halo
		          (a ring of beads), helix (two strands winding round it); spun their way
		rune      the caster's rune pattern on a disc behind or under it
		detail    from their tier: orbiting motes, a second counter-turning rune at Expert, and a
		          crown of beads at Grandmaster
	GROWTH    Grows over the safe charge stages (SpellHand.sizeAt). Overcharged, it shakes,
	          flickers toward the accent colour and throws sparks.
	TELLS     (Read the cast, Magic/CastTells) it moves by what it will DO (opts.kind: an attack
	          spins fast and spits sparks outward, a heal breathes slowly and drifts up, a ward is
	          still...) and forms bigger the stronger it is (opts.power). No label: people learn it.
	ENDINGS   release(): a flash, gone in a blink (the real cast's visuals take over).
	          cancel(): it falls apart in a puff.

	Parts are anchored, can't collide, be touched or be hit by raycasts, and are moved here every
	frame. No Neon (Bloom whitens it). With Reduce spell effects: no light, fewer particles, no
	detail pieces.

		Conjure.begin(character, palm, opts) -> Conjuring?
		c:update(progress 0..3, overcharged, now)   c:release()   c:cancel()
]]

local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local SpellHand = require(Shared.Magic.SpellHand)
local CastTells = require(Shared.Magic.CastTells)

local DomainFx = require(script.Parent.DomainFx)
local KenneyTextures = require(script.Parent.KenneyTextures)
local FxLayers = require(script.Parent.FxLayers)

local Data = SpellHand.data
local TEX = DomainFx.textures

export type Opts = {
	domain: string,
	property: string?,
	form: string?,
	style: FxLayers.Style,
	hand: SpellHand.Hand?,
	reduced: boolean,
	kind: string?, -- what it will do (AttunedKind): how it moves
	power: number?, -- how strong (AttunedPower): how big it forms
}

export type Conjuring = {
	update: (Conjuring, number, boolean, number) -> (),
	release: (Conjuring) -> (),
	cancel: (Conjuring) -> (),
}

type Piece = { part: BasePart, kind: string, index: number, count: number }

local Conjure = {}

local folder: Folder? = nil

local function folderOf(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "ConjureFx"
	made.Parent = workspace
	folder = made
	return made
end

local function material(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and value then value else Enum.Material.SmoothPlastic
end

local function newPart(shape: Enum.PartType, color: Color3, mat: Enum.Material, alpha: number): Part
	local part = Instance.new("Part")
	part.Shape = shape
	part.Anchored = true
	part.CanCollide = false
	part.CanTouch = false
	part.CanQuery = false
	part.CastShadow = false
	part.Size = Vector3.one * 0.2
	part.Color = color
	part.Material = mat
	part.Transparency = alpha
	part.Parent = folderOf()
	return part
end

local function runeDisc(texture: string, color: Color3, alpha: number): Part
	local disc = newPart(Enum.PartType.Block, color, Enum.Material.SmoothPlastic, 1)
	for _, face in { Enum.NormalId.Top, Enum.NormalId.Bottom } do
		local decal = Instance.new("Decal")
		decal.Texture = texture
		decal.Color3 = color
		decal.Transparency = alpha
		decal.Face = face
		decal.Parent = disc
	end
	return disc
end

local function setDiscAlpha(disc: BasePart, alpha: number)
	for _, child in disc:GetChildren() do
		if child:IsA("Decal") then
			child.Transparency = alpha
		end
	end
end

-- Conjure makes and destroys its own emitters: pooled ones (FxPool) must go back to the pool,
-- and these die with their parts.
local function emitter(parent: Instance, spec: FxLayers.EmitterSpec): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Enabled = false
	e.Texture = spec.texture
	e.Color = spec.color
	e.Size = spec.size
	e.Transparency = spec.transparency
	e.Lifetime = spec.lifetime
	e.Speed = spec.speed or NumberRange.new(0)
	e.Rotation = spec.rotation or NumberRange.new(0, 360)
	e.RotSpeed = spec.rotSpeed or NumberRange.new(-60, 60)
	e.Acceleration = spec.acceleration or Vector3.zero
	e.LightEmission = spec.emission or 0
	e.LightInfluence = spec.influence or 0
	e.Shape = spec.shape or Enum.ParticleEmitterShape.Box
	e.ShapeInOut = spec.inOut or Enum.ParticleEmitterShapeInOut.Outward
	e.ShapeStyle = spec.style or Enum.ParticleEmitterShapeStyle.Volume
	e.Rate = spec.rate or 0
	e.LockedToPart = spec.locked == true
	e.SpreadAngle = Vector2.new(180, 180)
	e.Parent = parent
	return e
end

function Conjure.begin(character: Model, palm: Attachment, opts: Opts): Conjuring?
	local root = character:FindFirstChild("HumanoidRootPart")
	local head = character:FindFirstChild("Head")
	if not root or not root:IsA("BasePart") then
		return nil
	end
	local style = opts.style
	local hand = opts.hand
	local mode = SpellHand.modeFor(opts.form)
	local look = SpellHand.lookFor(opts.domain, opts.property)
	local domainLook = DomainFx.look(opts.domain)
	local shape = SpellHand.shapeName(hand)
	local detail = if hand and not opts.reduced then SpellHand.detail(hand.tier) else { motes = 0, secondRing = false, crown = false }
	local tell = CastTells.tellFor(opts.kind)
	local scale = CastTells.scaleFor(opts.power)
	local spin = (if hand then hand.spin * hand.speed else 0.8) * tell.spin
	local runeTexture = if hand then KenneyTextures[Data.runes[hand.rune]] or TEX.rune else TEX.rune
	local mat = material(look.material)
	local pieceMat = if look.solid then mat else Enum.Material.Glass
	local made: { Instance } = {}
	local pieces: { Piece } = {}

	-- The core: always there, small inside shards and helices.
	local coreScale = if shape == "orb" then 1 elseif shape == "halo" then 0.6 else 0.45
	local core = newPart(Enum.PartType.Ball, style.primary, mat, look.alpha)
	table.insert(made, core)
	local coreAt = Instance.new("Attachment")
	coreAt.Parent = core

	local bodyTexture = if look.body then (TEX :: any)[look.body] or domainLook.body.texture else domainLook.body.texture
	local swirl = emitter(core, {
		texture = bodyTexture,
		color = FxLayers.ramp(style),
		size = FxLayers.seq(0, 0.6, 1, 0.1),
		transparency = FxLayers.seq(0, 0.35, 1, 1),
		lifetime = NumberRange.new(0.3, 0.5),
		speed = NumberRange.new(0.3, 1),
		emission = if domainLook.body.additive then 0.8 else 0.2,
		locked = true,
		rate = if opts.reduced then 8 else 22,
	})
	if swirl then
		swirl.Enabled = true
		table.insert(made, swirl)
	end
	-- Magic being drawn in from around it.
	local pull = emitter(core, {
		texture = TEX.sparkles,
		color = FxLayers.solid(style.secondary),
		size = FxLayers.seq(0, 0.08, 0.5, 0.18, 1, 0.02),
		transparency = FxLayers.seq(0, 0.6, 0.5, 0.1, 1, 1),
		lifetime = NumberRange.new(0.35, 0.5),
		speed = NumberRange.new(4 * tell.pullSpeed, 6 * tell.pullSpeed),
		emission = 1,
		shape = Enum.ParticleEmitterShape.Sphere,
		inOut = if tell.pull == "out" then Enum.ParticleEmitterShapeInOut.Outward else Enum.ParticleEmitterShapeInOut.Inward,
		style = Enum.ParticleEmitterShapeStyle.Surface,
		rate = if opts.reduced then 6 else 18,
	})
	if pull then
		pull.Enabled = true
		table.insert(made, pull)
	end
	-- Overcharge sparks: off until it's unstable.
	local sparks = emitter(core, {
		texture = TEX.fireSparks,
		color = FxLayers.solid(style.accent),
		size = FxLayers.seq(0, 0.15, 1, 0),
		transparency = FxLayers.seq(0, 0, 1, 1),
		lifetime = NumberRange.new(0.2, 0.4),
		speed = NumberRange.new(6, 12),
		emission = 1,
		rate = if opts.reduced then 10 else 40,
	})
	if sparks then
		sparks.Enabled = false
		table.insert(made, sparks)
	end
	local light: PointLight? = nil
	if not opts.reduced then
		local l = Instance.new("PointLight")
		l.Color = style.primary
		l.Range = 6
		l.Brightness = 0.6
		l.Shadows = false
		l.Parent = core
		light = l
	end

	-- The shape's pieces.
	local function addPieces(kind: string, count: number, partShape: Enum.PartType, color: Color3, pm: Enum.Material, alpha: number)
		for i = 1, count do
			local part = newPart(partShape, color, pm, alpha)
			table.insert(made, part)
			table.insert(pieces, { part = part, kind = kind, index = i, count = count })
		end
	end
	if shape == "shards" then
		addPieces("shard", 5, Enum.PartType.Block, style.primary, pieceMat, if look.solid then 0 else 0.3)
	elseif shape == "halo" then
		addPieces("bead", 8, Enum.PartType.Ball, style.secondary, pieceMat, 0.2)
	elseif shape == "helix" then
		addPieces("helix", 8, Enum.PartType.Ball, style.secondary, pieceMat, 0.2)
	end
	addPieces("mote", detail.motes, Enum.PartType.Ball, style.accent, Enum.Material.Glass, 0.25)
	if detail.crown then
		addPieces("crown", 6, Enum.PartType.Ball, style.accent, Enum.Material.Glass, 0.3)
	end

	-- The caster's rune.
	local rune = runeDisc(runeTexture, style.primary, 0.35)
	table.insert(made, rune)
	local rune2: Part? = nil
	if detail.secondRing then
		rune2 = runeDisc(runeTexture, style.accent, 0.6)
		table.insert(made, rune2)
	end

	local groundY: number? = nil
	local groundAt = -math.huge
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { character, folderOf() }

	local self: any = {}
	local finished = false

	local function destroyAll()
		for _, instance in made do
			instance:Destroy()
		end
		table.clear(made)
	end

	function self.update(_self: any, progress: number, overcharged: boolean, now: number)
		if finished or not root.Parent then
			return
		end
		local size = SpellHand.sizeAt(mode, progress) * scale
		local turn = now * spin * math.pi * 2
		local shake = (if overcharged then 0.15 else 0) + tell.jitter
		local jitter = if shake > 0 then Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * size * shake else Vector3.zero
		-- Read the cast: a breath, and a drift up (heals) or down (heavy land magic) as it charges.
		local breath = if tell.pulseRate > 0 then 1 + tell.pulseDepth * math.sin(now * tell.pulseRate * math.pi * 2) else 1
		local drift = Vector3.new(0, tell.rise * math.clamp(progress / 2, 0, 1), 0)
		local facing = root.CFrame.LookVector

		-- Where it forms.
		local center: Vector3
		local discCFrame: CFrame
		local coreSize: number
		if mode == "ground" then
			if now - groundAt > 0.25 then
				groundAt = now
				local hit = workspace:Raycast(root.Position, Vector3.new(0, -12, 0), params)
				groundY = if hit then hit.Position.Y else root.Position.Y - 3
			end
			local feet = Vector3.new(root.Position.X, (groundY or root.Position.Y - 3) + 0.06, root.Position.Z)
			discCFrame = CFrame.new(feet) * CFrame.Angles(0, turn * 0.5, 0)
			rune.Size = Vector3.new(size, 0.02, size)
			coreSize = 0.3 + size * 0.12
			center = feet + Vector3.new(0, 0.6 + progress * 0.5, 0) + drift
		else
			local origin = if mode == "overhead" and head and head:IsA("BasePart")
				then head.Position + Vector3.new(0, Data.overheadHeight, 0)
				else palm.WorldPosition + facing * Data.handReach
			center = origin + jitter + drift
			coreSize = size * coreScale
			-- The rune stands behind a hand spell (facing out) and lies under an overhead one.
			local base = if mode == "overhead"
				then CFrame.new(center - Vector3.new(0, size * 0.75, 0))
				else CFrame.lookAt(center - facing * size * 0.45, center + facing) * CFrame.Angles(math.pi / 2, 0, 0)
			discCFrame = base * CFrame.Angles(0, turn * 0.5, 0)
			rune.Size = Vector3.new(size * 1.7, 0.02, size * 1.7)
		end
		rune.CFrame = discCFrame
		setDiscAlpha(rune, 0.65 - 0.3 * math.clamp(progress / 2, 0, 1))
		local r2 = rune2
		if r2 then
			r2.Size = rune.Size * 1.35
			r2.CFrame = discCFrame * CFrame.Angles(0, -turn, 0)
		end

		-- The core and its light.
		local flicker = if overcharged then 0.85 + math.random() * 0.3 else 1
		core.Size = Vector3.one * coreSize * flicker * breath
		core.CFrame = CFrame.new(center) * CFrame.Angles(turn * 0.3, turn, 0)
		core.Color = if overcharged and math.random() < 0.35 then style.accent else style.primary
		if swirl then
			swirl.Size = FxLayers.seq(0, coreSize * 1.4, 1, coreSize * 0.3)
		end
		if pull then
			pull.Rate = (if opts.reduced then 6 else 18) * (1 + progress)
		end
		if sparks then
			sparks.Enabled = overcharged
		end
		local l = light
		if l then
			l.Brightness = (0.6 + progress * 0.8) * tell.light
			l.Range = 6 + size * 2
		end

		-- The pieces, spun the caster's way.
		local r = math.max(coreSize, 0.3)
		for _, piece in pieces do
			local a = turn + (piece.index - 1) / piece.count * math.pi * 2
			local part = piece.part
			if piece.kind == "shard" then
				local out = Vector3.new(math.cos(a), math.sin(a * 0.5) * 0.4, math.sin(a))
				part.Size = Vector3.new(r * 0.35, r * 1.1, r * 0.35)
				part.CFrame = CFrame.lookAt(center + out * r * 1.1, center + out * r * 3) * CFrame.Angles(math.pi / 2, 0, 0)
			elseif piece.kind == "bead" then
				part.Size = Vector3.one * r * 0.28
				part.Position = center + Vector3.new(math.cos(a), 0, math.sin(a)) * r * 1.5
			elseif piece.kind == "helix" then
				local strand = if piece.index % 2 == 0 then math.pi else 0
				local h = ((piece.index - 1) // 2) / (piece.count / 2 - 1) - 0.5
				local b = turn * 1.5 + strand + h * math.pi * 2
				part.Size = Vector3.one * r * 0.25
				part.Position = center + Vector3.new(math.cos(b) * r * 1.1, h * r * 2.4, math.sin(b) * r * 1.1)
			elseif piece.kind == "mote" then
				local b = -turn * 0.7 + (piece.index - 1) / piece.count * math.pi * 2
				part.Size = Vector3.one * 0.14
				part.Position = center + Vector3.new(math.cos(b), math.sin(b * 2) * 0.3, math.sin(b)) * (r * 2 + 0.4)
			elseif piece.kind == "crown" then
				local b = turn * 0.4 + (piece.index - 1) / piece.count * math.pi * 2
				part.Size = Vector3.one * 0.12
				part.Position = center + Vector3.new(math.cos(b) * r * 1.3, r * 1.6 + 0.2, math.sin(b) * r * 1.3)
			end
		end
	end

	function self.release(_self: any)
		if finished then
			return
		end
		finished = true
		-- A flash where it was, then gone: the cast's own visuals take it from here.
		local flash = emitter(core, {
			texture = TEX.core,
			color = FxLayers.solid(style.secondary),
			size = FxLayers.seq(0, core.Size.X * 1.5, 1, core.Size.X * 3.5),
			transparency = FxLayers.seq(0, 0.1, 1, 1),
			lifetime = NumberRange.new(0.15),
			emission = 1,
		})
		if flash then
			flash:Emit(1)
		end
		for _, instance in made do
			if instance:IsA("BasePart") and instance ~= core then
				instance:Destroy()
			elseif instance:IsA("ParticleEmitter") then
				instance.Enabled = false
			end
		end
		core.Transparency = 1
		task.delay(0.3, destroyAll)
	end

	function self.cancel(_self: any)
		if finished then
			return
		end
		finished = true
		-- It falls apart: everything shrinks and fades, with a puff of the domain's smoke.
		local puff = emitter(core, {
			texture = TEX.smoke,
			color = FxLayers.solid(style.secondary),
			size = FxLayers.seq(0, core.Size.X, 1, core.Size.X * 2.5),
			transparency = FxLayers.seq(0, 0.5, 1, 1),
			lifetime = NumberRange.new(0.5, 0.8),
			speed = NumberRange.new(1, 2),
			emission = 0,
		})
		if puff then
			puff:Emit(6)
		end
		local info = TweenInfo.new(0.3, Enum.EasingStyle.Quad, Enum.EasingDirection.In)
		for _, instance in made do
			if instance:IsA("BasePart") then
				TweenService:Create(instance, info, { Size = instance.Size * 0.1, Transparency = 1 }):Play()
			elseif instance:IsA("ParticleEmitter") and instance ~= puff then
				instance.Enabled = false
			end
		end
		setDiscAlpha(rune, 1)
		if rune2 then
			setDiscAlpha(rune2, 1)
		end
		task.delay(0.9, destroyAll)
	end

	self.update(self, 0, false, os.clock())
	return self :: Conjuring
end

return Conjure
