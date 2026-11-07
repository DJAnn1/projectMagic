--!strict
--[[
	SetPieces: what an activity leaves or uses at its spot, drawn on this client (docs/Activities.md §2, §4).
	Each one shows progress from the shared activity state, so every player sees the same amount done.

		furrows          farming: three rows of turned earth that lengthen as the work goes on
		swept            sweeping: a patch of dust that thins out as it's swept
		logpile          chopping: a block, and split logs stacking up beside it (chips fly on each blow)
		fishing          a line from the rod's tip to a bobber on the water, splashes, a basket that fills
		blanket          sleeping: a blanket over the body
		practice_energy  a small flame between the hands; rings of flame at higher mastery
		practice_earth   a pebble, and stone figures rising round it (more, steadier, with mastery)
		practice_water   two bowls and water arcing between them (more streams with mastery; novices spill)

	Mastery (`tier`, 1-9) changes the magic ones: a Grandmaster's casual practice is visibly impressive.
	Colours come from the NPC's Magical Signature (SpellFx.styleFor), so two Energy mages differ.

		SetPieces.create(kind, ctx) -> Piece?
		SetPieces.update(piece, ctx, progress, pieces, t)
		SetPieces.strike(piece)          a tool landed (chips, earth)
		SetPieces.destroy(piece)
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local ActivityPoses = require(Shared.Life.Data.ActivityPoses)

local Fx = script.Parent
local KenneyTextures = require(Fx.KenneyTextures)
local SpellFx = require(Fx.SpellFx)

local rgb = Color3.fromRGB
local SOIL = rgb(92, 66, 44)
local DUST = rgb(186, 168, 132)
local LOG = rgb(132, 96, 62)
local LOG_END = rgb(196, 160, 112)

export type Ctx = {
	model: Model,
	frame: CFrame, -- the spot: at the feet, facing where they face, captured when the work began
	body: CFrame?, -- sleeping: where the body is drawn
	tip: Attachment?, -- the right-hand tool's working end (fishing line)
	domain: string,
	tier: number,
	signature: string?,
	effects: boolean, -- false: reduced effects (no particles, fewer moving parts)
}

export type Piece = {
	kind: string,
	folder: Folder,
	parts: { [string]: BasePart },
	list: { BasePart },
	emitters: { [string]: ParticleEmitter },
	beam: Beam?,
	data: { [string]: any },
}

local SetPieces = {}

local holder: Folder? = nil
local function root(): Folder
	if holder and holder.Parent then
		return holder
	end
	local f = Instance.new("Folder")
	f.Name = "ActivitySetPieces"
	f.Parent = workspace
	holder = f
	return f
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

-- The ground (or water surface) under a point, ignoring people and effects.
local function groundY(at: Vector3, ignore: { Instance }): (number, boolean)
	local list = table.clone(ignore)
	local npcs = workspace:FindFirstChild("NPCs")
	if npcs then
		table.insert(list, npcs)
	end
	table.insert(list, root())
	rayParams.FilterDescendantsInstances = list
	rayParams.IgnoreWater = false
	local hit = workspace:Raycast(at + Vector3.new(0, 6, 0), Vector3.new(0, -24, 0), rayParams)
	if hit then
		return hit.Position.Y, hit.Material == Enum.Material.Water
	end
	return at.Y, false
end

local function part(piece: Piece, name: string, size: Vector3, color: Color3, material: Enum.Material, shape: Enum.PartType?): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = false
	p.CanTouch = false
	p.CanQuery = false
	p.CastShadow = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	if shape then
		p.Shape = shape
	end
	p.Parent = piece.folder
	piece.parts[name] = p
	table.insert(piece.list, p)
	return p
end

local function emitter(piece: Piece, name: string, parent: Instance, props: { [string]: any }): ParticleEmitter
	local e = Instance.new("ParticleEmitter")
	e.Name = name
	e.Rate = 0
	e.LightInfluence = 0.6
	for k, v in props do
		(e :: any)[k] = v
	end
	e.Parent = parent
	piece.emitters[name] = e
	return e
end

local function seq(a: number, b: number): NumberSequence
	return NumberSequence.new(a, b)
end

local function styleOf(ctx: Ctx)
	return SpellFx.styleFor(nil, ctx.domain, ctx.signature)
end

local function grounded(ctx: Ctx, offset: Vector3): (CFrame, boolean)
	local p = ctx.frame:PointToWorldSpace(offset)
	local y, water = groundY(p, { ctx.model })
	return CFrame.new(p.X, y, p.Z) * ctx.frame.Rotation, water
end

-- ─── Create ─────────────────────────────────────────────────────────────────

local builders: { [string]: (Piece, Ctx) -> () } = {}

builders.furrows = function(piece, ctx)
	for i = -1, 1 do
		local row = part(piece, "Row" .. (i + 2), Vector3.new(0.7, 0.18, 0.5), SOIL, Enum.Material.Ground)
		local at = grounded(ctx, Vector3.new(i * 1.3, 0, -2))
		piece.data["row" .. (i + 2)] = at
		row.CFrame = at
	end
end

builders.swept = function(piece, ctx)
	local patch = part(piece, "Dust", Vector3.new(4.5, 0.06, 3.5), DUST, Enum.Material.Sand)
	local at = grounded(ctx, Vector3.new(0, 0, -2.6))
	patch.CFrame = at * CFrame.new(0, 0.03, 0)
	patch.Transparency = 0.3
end

builders.logpile = function(piece, ctx)
	local blockAt = grounded(ctx, Vector3.new(0, 0, -2.3))
	local block = part(piece, "Block", Vector3.new(1.2, 1.8, 1.8), LOG, Enum.Material.Wood, Enum.PartType.Cylinder)
	block.CFrame = blockAt * CFrame.new(0, 0.6, 0) * CFrame.Angles(0, 0, math.rad(90))
	local pileAt = grounded(ctx, Vector3.new(2.4, 0, -1.6))
	piece.data.pile = pileAt
	for i = 1, 8 do
		local log = part(piece, "Log" .. i, Vector3.new(1.8, 0.55, 0.55), LOG_END, Enum.Material.Wood, Enum.PartType.Cylinder)
		local row = (i - 1) // 3
		local col = (i - 1) % 3
		log.CFrame = pileAt * CFrame.new((col - 1) * 0.58 + row * 0.29, 0.28 + row * 0.5, 0) * CFrame.Angles(0, math.rad(90), 0)
		log.Transparency = 1
	end
	if ctx.effects then
		local at = Instance.new("Attachment")
		at.Position = Vector3.new(0.6, 0, 0)
		at.Parent = block
		emitter(piece, "Chips", at, {
			Texture = KenneyTextures.dirt_01, Color = ColorSequence.new(LOG_END), Size = seq(0.25, 0.05),
			Lifetime = NumberRange.new(0.4, 0.7), Speed = NumberRange.new(6, 10), SpreadAngle = Vector2.new(60, 60),
			Acceleration = Vector3.new(0, -30, 0),
		})
	end
end

builders.fishing = function(piece, ctx)
	local bobAt, water = grounded(ctx, Vector3.new(0, 0, -8))
	local bob = part(piece, "Bobber", Vector3.new(0.35, 0.35, 0.35), rgb(200, 52, 40), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	bob.CFrame = bobAt * CFrame.new(0, 0.1, 0)
	piece.data.bob = bobAt
	piece.data.water = water
	local end1 = Instance.new("Attachment")
	end1.Parent = bob
	local beam = Instance.new("Beam")
	beam.Width0, beam.Width1 = 0.03, 0.03
	beam.Color = ColorSequence.new(rgb(230, 230, 220))
	beam.FaceCamera = true
	beam.CurveSize0 = -1.5
	beam.Segments = 8
	beam.Attachment1 = end1
	beam.Attachment0 = ctx.tip
	beam.Parent = bob
	piece.beam = beam
	local basket = part(piece, "Basket", Vector3.new(1.2, 0.8, 1.2), rgb(170, 130, 80), Enum.Material.Fabric)
	local basketAt = grounded(ctx, Vector3.new(1.6, 0, 0.6))
	basket.CFrame = basketAt * CFrame.new(0, 0.4, 0)
	for i = 1, 5 do
		local fish = part(piece, "Fish" .. i, Vector3.new(0.7, 0.18, 0.28), rgb(150, 170, 182), Enum.Material.SmoothPlastic)
		fish.CFrame = basketAt * CFrame.new(-0.3 + (i % 3) * 0.3, 0.85 + (i // 3) * 0.12, -0.2 + (i % 2) * 0.35) * CFrame.Angles(0, i * 0.8, 0)
		fish.Transparency = 1
	end
	if ctx.effects then
		emitter(piece, "Splash", end1, {
			Texture = KenneyTextures.circle_05, Color = ColorSequence.new(rgb(220, 236, 255)), Size = seq(0.2, 1.2),
			Lifetime = NumberRange.new(0.5, 0.8), Speed = NumberRange.new(1, 3), SpreadAngle = Vector2.new(70, 70),
			Transparency = seq(0.2, 1), Acceleration = Vector3.new(0, -8, 0),
		})
	end
end

builders.blanket = function(piece, _ctx)
	local blanket = part(piece, "Blanket", Vector3.new(2.5, 0.22, 4.1), rgb(116, 92, 140), Enum.Material.Fabric)
	blanket.Transparency = 1 -- shown once there's a bed to lie in (update)
end

builders.practice_energy = function(piece, ctx)
	local style = styleOf(ctx)
	local core = part(piece, "Core", Vector3.new(0.4, 0.4, 0.4), style.primary, Enum.Material.Neon, Enum.PartType.Ball)
	core.Transparency = 0.15
	local light = Instance.new("PointLight")
	light.Color = style.primary
	light.Range = 6 + ctx.tier
	light.Brightness = 1.2
	light.Shadows = false
	light.Parent = core
	if ctx.effects then
		local a = Instance.new("Attachment")
		a.Parent = core
		emitter(piece, "Flame", a, {
			Texture = KenneyTextures.flame_03, Color = ColorSequence.new(style.secondary, style.primary),
			Size = seq(0.5 + ctx.tier * 0.08, 0.05), Lifetime = NumberRange.new(0.35, 0.6), Speed = NumberRange.new(1, 2),
			Acceleration = Vector3.new(0, 4, 0), LightEmission = 1, LightInfluence = 0, Rate = 18 + ctx.tier * 4,
			Transparency = seq(0.1, 1),
		})
	end
	-- Rings at Adept and above: small flames circling the core.
	for i = 1, math.clamp(ctx.tier - 3, 0, 6) do
		local orb = part(piece, "Orb" .. i, Vector3.new(0.22, 0.22, 0.22), style.accent, Enum.Material.Neon, Enum.PartType.Ball)
		orb.Transparency = 0.1
	end
end

builders.practice_earth = function(piece, ctx)
	local style = styleOf(ctx)
	local at = grounded(ctx, Vector3.new(0, 0, -2.2))
	piece.data.at = at
	local pebble = part(piece, "Pebble", Vector3.new(0.5, 0.4, 0.5), rgb(120, 112, 100), Enum.Material.Slate, Enum.PartType.Ball)
	pebble.CFrame = at * CFrame.new(0, 0.2, 0)
	for i = 1, math.clamp(ctx.tier, 1, 7) do
		local fig = part(piece, "Figure" .. i, Vector3.new(0.35, 0.9, 0.35), style.primary:Lerp(rgb(130, 118, 100), 0.6), Enum.Material.Slate)
		fig.Transparency = 1
	end
end

builders.practice_water = function(piece, ctx)
	local style = styleOf(ctx)
	local left = grounded(ctx, Vector3.new(-1.6, 0, -2.2))
	local right = grounded(ctx, Vector3.new(1.6, 0, -2.2))
	piece.data.left, piece.data.right = left, right
	for name, at in { BowlL = left, BowlR = right } do
		local bowl = part(piece, name, Vector3.new(0.5, 1.3, 1.3), rgb(168, 112, 78), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		bowl.CFrame = at * CFrame.new(0, 0.25, 0) * CFrame.Angles(0, 0, math.rad(90))
	end
	local streams = if ctx.tier >= 7 then 4 elseif ctx.tier >= 4 then 2 else 1
	piece.data.streams = streams
	for i = 1, streams do
		local blob = part(piece, "Water" .. i, Vector3.new(0.6, 0.6, 0.6), style.primary:Lerp(rgb(90, 150, 220), 0.5), Enum.Material.Glass, Enum.PartType.Ball)
		blob.Transparency = 0.25
	end
	if ctx.effects then
		local drip = Instance.new("Attachment")
		drip.Parent = piece.parts.Water1
		emitter(piece, "Drip", drip, {
			Texture = KenneyTextures.circle_05, Color = ColorSequence.new(rgb(200, 226, 255)), Size = seq(0.15, 0.05),
			Lifetime = NumberRange.new(0.3, 0.5), Speed = NumberRange.new(0, 1), Acceleration = Vector3.new(0, -20, 0),
			Rate = if ctx.tier <= 2 then 6 else 0, Transparency = seq(0.2, 1),
		})
	end
end

function SetPieces.create(kind: string, ctx: Ctx): Piece?
	local build = builders[kind]
	if not build then
		return nil
	end
	local folder = Instance.new("Folder")
	folder.Name = kind
	folder.Parent = root()
	local piece: Piece = { kind = kind, folder = folder, parts = {}, list = {}, emitters = {}, beam = nil, data = {} }
	build(piece, ctx)
	return piece
end

-- ─── Update ─────────────────────────────────────────────────────────────────

local function hands(ctx: Ctx): CFrame
	-- Between the hands, in front of the chest.
	local r = ctx.model:FindFirstChild("HumanoidRootPart")
	local base = if r and r:IsA("BasePart") then r.CFrame else ctx.frame * CFrame.new(0, 3, 0)
	return base * CFrame.new(0, 0.1, -1.6)
end

function SetPieces.update(piece: Piece, ctx: Ctx, progress: number, pieces: number, t: number)
	local kind = piece.kind
	local done = math.clamp(pieces + progress, 0, 1e6)
	if kind == "furrows" then
		local length = 0.6 + 4.4 * math.clamp(done / 2, 0, 1)
		for i = 1, 3 do
			local row = piece.parts["Row" .. i]
			local at: CFrame = piece.data["row" .. i]
			row.Size = Vector3.new(0.7, 0.18, length)
			row.CFrame = at * CFrame.new(0, 0.05, -length / 2 + 0.3)
		end
	elseif kind == "swept" then
		piece.parts.Dust.Transparency = 0.3 + 0.68 * progress
	elseif kind == "logpile" then
		local logs = math.clamp(math.floor(done * 3), 0, 8)
		for i = 1, 8 do
			piece.parts["Log" .. i].Transparency = if i <= logs then 0 else 1
		end
	elseif kind == "fishing" then
		local bob = piece.parts.Bobber
		local at: CFrame = piece.data.bob
		local bite = (math.floor(t / 7) * 7919) % 5 == 0 and (t % 7) < 1.2
		bob.CFrame = at * CFrame.new(0, 0.1 + math.sin(t * 2) * 0.05 - (if bite then 0.25 else 0), 0)
		local splash = piece.emitters.Splash
		if splash and bite and piece.data.lastBite ~= math.floor(t / 7) then
			piece.data.lastBite = math.floor(t / 7)
			splash:Emit(10)
		end
		for i = 1, 5 do
			piece.parts["Fish" .. i].Transparency = if i <= pieces then 0 else 1
		end
		if piece.beam and piece.beam.Attachment0 ~= ctx.tip then
			piece.beam.Attachment0 = ctx.tip
		end
	elseif kind == "blanket" then
		local blanket = piece.parts.Blanket
		local body = ctx.body
		if body then
			blanket.Transparency = 0
			-- The body lies along the bed with its feet toward -Z; the blanket covers chest to feet.
			blanket.CFrame = body * CFrame.new(0, 0.6 + math.sin(t * 1.5) * 0.03, -1.3)
		else
			blanket.Transparency = 1
		end
	elseif kind == "practice_energy" then
		local at = hands(ctx)
		local tier = ctx.tier
		local wobble = if tier <= 2 then math.sin(t * 13) * 0.12 else 0 -- a novice's flame gutters
		local size = 0.3 + tier * 0.07 + math.sin(t * 4) * 0.04 + wobble
		local core = piece.parts.Core
		core.Size = Vector3.new(size, size, size)
		core.CFrame = at * CFrame.new(0, wobble, 0)
		local n = math.clamp(tier - 3, 0, 6)
		for i = 1, n do
			local a = t * (1.2 + tier * 0.12) + i / n * math.pi * 2
			local r = 0.7 + tier * 0.06
			piece.parts["Orb" .. i].CFrame = at * CFrame.new(math.cos(a) * r, math.sin(a * 2) * 0.15, math.sin(a) * r)
		end
	elseif kind == "practice_earth" then
		local at: CFrame = piece.data.at
		local tier = ctx.tier
		local count = math.clamp(tier, 1, 7)
		-- Figures stand up one after another over each piece of work; a novice's topple now and then.
		local raised = math.clamp(progress * count * 1.2, 0, count)
		for i = 1, count do
			local fig = piece.parts["Figure" .. i]
			local a = (i / count) * math.pi * 2
			local h = math.clamp(raised - (i - 1), 0, 1)
			local topple = tier <= 2 and math.sin(t * 0.9 + i) > 0.85
			fig.Transparency = if h <= 0 then 1 else 0
			fig.Size = Vector3.new(0.35, 0.2 + 0.7 * h * (0.7 + tier * 0.05), 0.35)
			local tilt = if topple then CFrame.Angles(0, 0, math.rad(80)) else CFrame.Angles(0, 0, math.sin(t + i) * 0.05)
			fig.CFrame = at * CFrame.new(math.cos(a) * 0.9, fig.Size.Y / 2, math.sin(a) * 0.9) * tilt
		end
		piece.parts.Pebble.CFrame = at * CFrame.new(0, 0.2 + math.abs(math.sin(t * 2)) * 0.15 * math.min(tier, 4), 0)
	elseif kind == "practice_water" then
		local left: CFrame, right: CFrame = piece.data.left, piece.data.right
		local pose = ActivityPoses.poses.cast_pour
		local period = pose.period
		local tier = ctx.tier
		for i = 1, piece.data.streams do
			local u = ((t / period) + (i - 1) / piece.data.streams) % 1
			local forward = math.floor((t / period) + (i - 1) / piece.data.streams) % 2 == 0
			local from, to = if forward then left else right, if forward then right else left
			local p = from.Position:Lerp(to.Position, u) + Vector3.new(0, 0.6 + math.sin(u * math.pi) * (1.4 + tier * 0.15), 0)
			local blob = piece.parts["Water" .. i]
			local stretch = if tier <= 2 then 0.5 + math.abs(math.sin(t * 6)) * 0.3 else 0.55
			blob.Size = Vector3.new(stretch, stretch, stretch)
			blob.CFrame = CFrame.new(p)
		end
	end
end

function SetPieces.strike(piece: Piece)
	local chips = piece.emitters.Chips
	if chips then
		chips:Emit(6)
	end
end

function SetPieces.destroy(piece: Piece)
	piece.folder:Destroy()
end

return SetPieces
