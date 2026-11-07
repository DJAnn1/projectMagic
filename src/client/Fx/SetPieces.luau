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

local function hands(ctx: Ctx): CFrame
	-- Between the hands, in front of the chest.
	local r = ctx.model:FindFirstChild("HumanoidRootPart")
	local base = if r and r:IsA("BasePart") then r.CFrame else ctx.frame * CFrame.new(0, 3, 0)
	return base * CFrame.new(0, 0.1, -1.6)
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

-- ─── Stage 2 builders (2026-11-07) ──────────────────────────────────────────
-- Everything here is a handful of plain parts (at most ~16 per piece), moved in `updaters` below.

local STONE = rgb(128, 122, 112)
local TIMBER = rgb(150, 112, 72)
local LEAF = rgb(86, 140, 60)

-- A stable 0..1 per index, so heaps and patches look scattered but the same on every client.
local function hash(i: number, salt: number): number
	return ((i * 7919 + salt * 104729) % 1000) / 1000
end

builders.rubble = function(piece, ctx)
	local at = grounded(ctx, Vector3.new(1.2, 0, -2.2))
	piece.data.at = at
	for i = 1, 9 do
		local s = 0.45 + hash(i, 1) * 0.5
		local rock = part(piece, "Rock" .. i, Vector3.new(s, s * 0.7, s), STONE:Lerp(rgb(96, 88, 80), hash(i, 2)), Enum.Material.Slate)
		local ring = (i - 1) // 4
		local a = hash(i, 3) * math.pi * 2
		local r = if ring == 0 then 0.9 elseif ring == 1 then 0.5 else 0
		rock.CFrame = at * CFrame.new(math.cos(a) * r, s * 0.35 + ring * 0.35, math.sin(a) * r) * CFrame.Angles(hash(i, 4), hash(i, 5) * 3, 0)
		rock.Transparency = 1
	end
end

builders.frame = function(piece, ctx)
	local at = grounded(ctx, Vector3.new(0, 0, -2.6))
	piece.data.at = at
	local corners = { Vector3.new(-1.8, 0, 0), Vector3.new(1.8, 0, 0), Vector3.new(-1.8, 0, -2.8), Vector3.new(1.8, 0, -2.8) }
	for i, c in corners do
		local post = part(piece, "Post" .. i, Vector3.new(0.4, 4, 0.4), TIMBER, Enum.Material.Wood)
		post.CFrame = at * CFrame.new(c + Vector3.new(0, 2, 0))
		post.Transparency = 1
	end
	local beamA = part(piece, "Beam1", Vector3.new(4, 0.35, 0.35), TIMBER, Enum.Material.Wood)
	beamA.CFrame = at * CFrame.new(0, 4.1, 0)
	local beamB = part(piece, "Beam2", Vector3.new(4, 0.35, 0.35), TIMBER, Enum.Material.Wood)
	beamB.CFrame = at * CFrame.new(0, 4.1, -2.8)
	beamA.Transparency, beamB.Transparency = 1, 1
end

builders.herbs = function(piece, ctx)
	local at = grounded(ctx, Vector3.new(0, 0, -1.8))
	for i = 1, 8 do
		local a = hash(i, 7) * math.pi * 2
		local r = 0.4 + hash(i, 8) * 1.1
		local plant = part(piece, "Plant" .. i, Vector3.new(0.5, 0.5, 0.5), LEAF:Lerp(rgb(150, 170, 70), hash(i, 9)), Enum.Material.Grass, Enum.PartType.Ball)
		plant.CFrame = at * CFrame.new(math.cos(a) * r, 0.2, math.sin(a) * r)
	end
end

builders.wares = function(piece, ctx)
	local at = grounded(ctx, Vector3.new(0, 0, -2.4))
	local cloth = part(piece, "Cloth", Vector3.new(4, 0.08, 2.4), rgb(150, 60, 52), Enum.Material.Fabric)
	cloth.CFrame = at * CFrame.new(0, 0.04, 0)
	local goods = {
		{ Vector3.new(0.6, 0.7, 0.6), rgb(168, 112, 78), Enum.PartType.Cylinder },
		{ Vector3.new(0.7, 0.6, 0.7), rgb(196, 176, 130), nil },
		{ Vector3.new(0.5, 0.5, 0.5), rgb(220, 150, 60), Enum.PartType.Ball },
		{ Vector3.new(0.9, 0.3, 0.5), rgb(70, 90, 140), nil },
		{ Vector3.new(0.5, 0.8, 0.5), rgb(130, 150, 120), Enum.PartType.Cylinder },
		{ Vector3.new(0.5, 0.5, 0.5), rgb(190, 60, 50), Enum.PartType.Ball },
		{ Vector3.new(0.8, 0.4, 0.6), rgb(150, 130, 100), nil },
		{ Vector3.new(0.4, 0.6, 0.4), rgb(200, 200, 210), nil },
	}
	for i, g in goods do
		local col = (i - 1) % 4
		local row = (i - 1) // 4
		local good = part(piece, "Good" .. i, g[1], g[2], Enum.Material.SmoothPlastic, g[3] :: Enum.PartType?)
		local lift = if g[3] == Enum.PartType.Cylinder then g[1].X / 2 else g[1].Y / 2
		good.CFrame = at * CFrame.new(-1.4 + col * 0.95, 0.08 + lift, -0.5 + row * 1) * (if g[3] == Enum.PartType.Cylinder then CFrame.Angles(0, 0, math.rad(90)) else CFrame.new())
	end
end

builders.ball = function(piece, _ctx)
	part(piece, "Ball", Vector3.new(0.6, 0.6, 0.6), rgb(196, 64, 52), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
end

builders.pots = function(piece, ctx)
	for i = 1, 3 do
		local at = grounded(ctx, Vector3.new((i - 2) * 1.2, 0, -1.9))
		piece.data["pot" .. i] = at
		local pot = part(piece, "Pot" .. i, Vector3.new(0.8, 0.8, 0.8), rgb(176, 98, 64), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		pot.CFrame = at * CFrame.new(0, 0.4, 0) * CFrame.Angles(0, 0, math.rad(90))
		part(piece, "Leaves" .. i, Vector3.new(0.6, 0.6, 0.6), LEAF, Enum.Material.Grass, Enum.PartType.Ball)
	end
end

builders.birds = function(piece, ctx)
	piece.data.at = grounded(ctx, Vector3.new(0, 0, -2.6))
	for i = 1, 4 do
		part(piece, "Bird" .. i, Vector3.new(0.4, 0.35, 0.55), rgb(130, 120, 110):Lerp(rgb(90, 86, 80), hash(i, 11)), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
		part(piece, "Head" .. i, Vector3.new(0.24, 0.24, 0.24), rgb(110, 104, 96), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	end
end

builders.cairn = function(piece, ctx)
	local at = grounded(ctx, Vector3.new(0, 0, -1.9))
	piece.data.at = at
	for i = 1, 7 do
		local w = 1.1 - i * 0.1
		local stone = part(piece, "Stone" .. i, Vector3.new(w, 0.32, w * 0.85), STONE:Lerp(rgb(170, 160, 146), hash(i, 13)), Enum.Material.Slate, Enum.PartType.Ball)
		stone.Transparency = 1
	end
end

builders.practice_air = function(piece, ctx)
	local count = math.clamp(4 + ctx.tier, 5, 13)
	piece.data.count = count
	for i = 1, count do
		local leaf = part(piece, "Leaf" .. i, Vector3.new(0.3, 0.05, 0.2), LEAF:Lerp(rgb(170, 140, 70), hash(i, 17)), Enum.Material.SmoothPlastic)
		leaf.Transparency = 0.05
	end
	if ctx.effects then
		local a = Instance.new("Attachment")
		a.Parent = piece.parts.Leaf1
		emitter(piece, "Gust", a, {
			Texture = KenneyTextures.smoke_05, Color = ColorSequence.new(rgb(235, 245, 255)), Size = seq(0.4, 1.2),
			Lifetime = NumberRange.new(0.4, 0.8), Speed = NumberRange.new(1, 2), Transparency = seq(0.8, 1), Rate = 6, LightInfluence = 1,
		})
	end
end

builders.practice_life = function(piece, ctx)
	local style = styleOf(ctx)
	local at = grounded(ctx, Vector3.new(0, 0, -2))
	piece.data.at = at
	part(piece, "Stem", Vector3.new(0.12, 1, 0.12), LEAF, Enum.Material.Grass)
	part(piece, "LeafA", Vector3.new(0.5, 0.06, 0.25), LEAF, Enum.Material.Grass)
	part(piece, "LeafB", Vector3.new(0.5, 0.06, 0.25), LEAF, Enum.Material.Grass)
	local flowers = math.clamp(ctx.tier - 1, 1, 6)
	piece.data.flowers = flowers
	for i = 1, flowers do
		local f = part(piece, "Flower" .. i, Vector3.new(0.3, 0.3, 0.3), style.primary:Lerp(rgb(255, 255, 255), 0.15), Enum.Material.Neon, Enum.PartType.Ball)
		f.Transparency = 1
	end
end

builders.practice_mind = function(piece, ctx)
	local style = styleOf(ctx)
	local count = math.clamp(ctx.tier + 1, 2, 9)
	piece.data.count = count
	for i = 1, count do
		local rune = part(piece, "Rune" .. i, Vector3.new(0.3, 0.3, 0.04), style.primary, Enum.Material.Neon)
		rune.Transparency = 0.25
	end
end

builders.practice_spirit = function(piece, ctx)
	local style = styleOf(ctx)
	local count = math.clamp(ctx.tier, 2, 8)
	piece.data.count = count
	for i = 1, count do
		local wisp = part(piece, "Wisp" .. i, Vector3.new(0.3, 0.3, 0.3), style.primary:Lerp(rgb(255, 255, 255), 0.4), Enum.Material.Neon, Enum.PartType.Ball)
		wisp.Transparency = 0.35
	end
	local light = Instance.new("PointLight")
	light.Color = style.primary
	light.Range = 6 + ctx.tier
	light.Brightness = 0.8
	light.Shadows = false
	light.Parent = piece.parts.Wisp1
end

builders.practice_void = function(piece, ctx)
	part(piece, "Core", Vector3.new(0.5, 0.5, 0.5), rgb(8, 6, 12), Enum.Material.SmoothPlastic, Enum.PartType.Ball)
	local style = styleOf(ctx)
	for i = 1, 6 do
		local mote = part(piece, "Mote" .. i, Vector3.new(0.1, 0.1, 0.1), style.primary:Lerp(rgb(255, 255, 255), 0.5), Enum.Material.Neon, Enum.PartType.Ball)
		mote.Transparency = 0.2
	end
end

builders.practice_space = function(piece, ctx)
	local style = styleOf(ctx)
	for _, name in { "RingA", "RingB" } do
		local ring = part(piece, name, Vector3.new(0.08, 1.1, 1.1), style.primary, Enum.Material.Neon, Enum.PartType.Cylinder)
		ring.Transparency = 0.45
		local inner = part(piece, name .. "Hole", Vector3.new(0.09, 0.85, 0.85), rgb(20, 16, 40), Enum.Material.SmoothPlastic, Enum.PartType.Cylinder)
		inner.Transparency = 0.2
	end
	part(piece, "Pebble", Vector3.new(0.3, 0.3, 0.3), STONE, Enum.Material.Slate, Enum.PartType.Ball)
end

builders.practice_time = function(piece, ctx)
	local style = styleOf(ctx)
	part(piece, "Pebble", Vector3.new(0.32, 0.32, 0.32), STONE, Enum.Material.Slate, Enum.PartType.Ball)
	local ring = part(piece, "Halo", Vector3.new(0.05, 0.9, 0.9), style.primary, Enum.Material.Neon, Enum.PartType.Cylinder)
	ring.Transparency = 1
end

builders.practice_gravity = function(piece, ctx)
	local count = math.clamp(ctx.tier + 1, 2, 10)
	piece.data.count = count
	piece.data.at = grounded(ctx, Vector3.new(0, 0, 0))
	for i = 1, count do
		local s = 0.35 + hash(i, 19) * 0.35
		part(piece, "Stone" .. i, Vector3.new(s, s * 0.8, s), STONE:Lerp(rgb(90, 84, 78), hash(i, 23)), Enum.Material.Slate)
	end
end

builders.practice_reality = function(piece, ctx)
	local style = styleOf(ctx)
	local thing = part(piece, "Thing", Vector3.new(0.6, 0.6, 0.6), style.primary, Enum.Material.Neon)
	thing.Transparency = 0.15
end

-- ─── Stage 2 updaters ───────────────────────────────────────────────────────

type Updater = (piece: Piece, ctx: Ctx, progress: number, pieces: number, t: number, done: number) -> ()
local updaters: { [string]: Updater } = {}

local function headOf(ctx: Ctx): CFrame
	local head = ctx.model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.CFrame
	end
	return hands(ctx) * CFrame.new(0, 1.2, 1.6)
end

updaters.rubble = function(piece, _ctx, _progress, _pieces, _t, done)
	local shown = math.clamp(math.floor(done * 3) + 1, 1, 9)
	for i = 1, 9 do
		piece.parts["Rock" .. i].Transparency = if i <= shown then 0 else 1
	end
end

updaters.frame = function(piece, _ctx, _progress, _pieces, _t, done)
	-- Four posts, then the two beams across them; a finished frame stays up.
	local shown = math.clamp(math.floor(done * 3) + 1, 1, 6)
	for i = 1, 4 do
		piece.parts["Post" .. i].Transparency = if i <= shown then 0 else 1
	end
	piece.parts.Beam1.Transparency = if shown >= 5 then 0 else 1
	piece.parts.Beam2.Transparency = if shown >= 6 then 0 else 1
end

updaters.herbs = function(piece, _ctx, progress)
	local picked = math.floor(progress * 8)
	for i = 1, 8 do
		local plant = piece.parts["Plant" .. i]
		plant.Transparency = if i <= picked then 1 else 0
	end
end

updaters.wares = function(piece, _ctx, progress)
	local sold = math.floor(progress * 7) -- one always left on the cloth
	for i = 1, 8 do
		piece.parts["Good" .. i].Transparency = if i <= sold then 1 else 0
	end
end

updaters.ball = function(piece, ctx, _progress, _pieces, t)
	local pose = ActivityPoses.poses.toss
	local u = (t / pose.period) % 1
	local height = math.sin(u * math.pi) * 3.2
	piece.parts.Ball.CFrame = hands(ctx) * CFrame.new(0, 0.3 + height, 0.2)
end

updaters.pots = function(piece, _ctx, _progress, _pieces, t, done)
	for i = 1, 3 do
		local at: CFrame = piece.data["pot" .. i]
		local grow = 0.5 + math.clamp(done * 0.25, 0, 0.6) + math.sin(t * 0.8 + i) * 0.03
		local leaves = piece.parts["Leaves" .. i]
		leaves.Size = Vector3.new(grow, grow, grow)
		leaves.CFrame = at * CFrame.new(0, 0.8 + grow * 0.35, 0)
	end
end

updaters.birds = function(piece, _ctx, _progress, _pieces, t)
	local at: CFrame = piece.data.at
	for i = 1, 4 do
		local a = hash(i, 29) * math.pi * 2 + math.sin(t * 0.3 + i) * 0.6
		local r = 0.8 + hash(i, 31) * 0.8
		local hop = math.max(0, math.sin(t * 5 + i * 1.7)) * 0.25
		local peck = if math.sin(t * 3 + i) > 0.6 then -0.12 else 0
		local body = at * CFrame.new(math.cos(a) * r, 0.2 + hop, math.sin(a) * r) * CFrame.Angles(0, -a, 0)
		piece.parts["Bird" .. i].CFrame = body
		piece.parts["Head" .. i].CFrame = body * CFrame.new(0, 0.15 + peck, -0.3)
	end
end

updaters.cairn = function(piece, _ctx, progress, _pieces, t)
	local at: CFrame = piece.data.at
	local shown = math.clamp(math.floor(progress * 7) + 1, 1, 7)
	local y = 0
	for i = 1, 7 do
		local stone = piece.parts["Stone" .. i]
		stone.Transparency = if i <= shown then 0 else 1
		local sway = if i == shown then math.sin(t * 2.4) * 0.04 else 0
		stone.CFrame = at * CFrame.new(sway, y + 0.16, 0) * CFrame.Angles(0, i * 0.9, 0)
		y += 0.3
	end
end

updaters.practice_air = function(piece, ctx, _progress, _pieces, t)
	local base = hands(ctx)
	local tier = ctx.tier
	local count: number = piece.data.count
	local height = 0.6 + tier * 0.25 -- a master's whirlwind stands tall
	for i = 1, count do
		local u = i / count
		local a = t * (2 + tier * 0.25) + u * math.pi * 2 * 2
		local r = 0.35 + u * 0.5
		local scatter = if tier <= 2 then math.sin(t * 3 + i) * 0.35 else 0 -- a novice's leaves wander off
		local p = base * CFrame.new(math.cos(a) * (r + scatter), -0.4 + u * height, math.sin(a) * (r + scatter))
		piece.parts["Leaf" .. i].CFrame = p * CFrame.Angles(t * 4 + i, a, 0)
	end
end

updaters.practice_life = function(piece, ctx, progress, _pieces, t)
	local at: CFrame = piece.data.at
	local tier = ctx.tier
	local height = (0.3 + 0.5 * math.clamp(progress * 2, 0, 1)) * (0.8 + tier * 0.08)
	local droop = if tier <= 2 and progress > 0.6 then math.rad(35) else math.sin(t * 0.7) * 0.05 -- a novice's wilts
	local stem = piece.parts.Stem
	stem.Size = Vector3.new(0.12, height, 0.12)
	local tilt = at * CFrame.Angles(0, 0, droop)
	stem.CFrame = tilt * CFrame.new(0, height / 2, 0)
	piece.parts.LeafA.CFrame = tilt * CFrame.new(0.22, height * 0.45, 0) * CFrame.Angles(0, 0, 0.4)
	piece.parts.LeafB.CFrame = tilt * CFrame.new(-0.22, height * 0.6, 0) * CFrame.Angles(0, 0, -0.4)
	local flowers: number = piece.data.flowers
	local bloom = math.clamp((progress - 0.5) * 2.5, 0, 1)
	for i = 1, flowers do
		local f = piece.parts["Flower" .. i]
		local a = i / flowers * math.pi * 2
		f.Transparency = if bloom > 0 then 0.1 else 1
		local s = 0.12 + 0.2 * bloom
		f.Size = Vector3.new(s, s, s)
		f.CFrame = tilt * CFrame.new(math.cos(a) * 0.18 * (if flowers > 1 then 1 else 0), height + 0.05, math.sin(a) * 0.18 * (if flowers > 1 then 1 else 0))
	end
end

updaters.practice_mind = function(piece, ctx, _progress, _pieces, t)
	local head = headOf(ctx)
	local count: number = piece.data.count
	for i = 1, count do
		local a = t * (0.6 + ctx.tier * 0.05) + i / count * math.pi * 2
		local p = head.Position + Vector3.new(math.cos(a) * 1.3, 0.5 + math.sin(t + i) * 0.12, math.sin(a) * 1.3)
		piece.parts["Rune" .. i].CFrame = CFrame.lookAt(p, head.Position + Vector3.new(0, 0.5, 0)) * CFrame.Angles(0, 0, t + i)
	end
end

updaters.practice_spirit = function(piece, ctx, _progress, _pieces, t)
	local base = hands(ctx) * CFrame.new(0, 0, 1.6) -- the body's centre
	local count: number = piece.data.count
	for i = 1, count do
		local u = ((t * 0.12) + i / count) % 1
		local a = u * math.pi * 4 + i
		local r = 1.4 + math.sin(t * 0.5 + i) * 0.2
		local flicker = if ctx.tier <= 2 and math.sin(t * 7 + i * 3) > 0.7 then 0.9 else 0.35
		local wisp = piece.parts["Wisp" .. i]
		wisp.Transparency = flicker
		wisp.CFrame = base * CFrame.new(math.cos(a) * r, -1.5 + u * 4, math.sin(a) * r)
	end
end

updaters.practice_void = function(piece, ctx, _progress, _pieces, t)
	local at = hands(ctx)
	local tier = ctx.tier
	local fray = if tier <= 2 then math.abs(math.sin(t * 9)) * 0.15 else 0
	local s = 0.3 + tier * 0.06 + fray
	local core = piece.parts.Core
	core.Size = Vector3.new(s, s, s)
	core.CFrame = at
	for i = 1, 6 do
		local u = ((t * 0.7) + i / 6) % 1
		local dir = Vector3.new(math.cos(i * 1.7), math.sin(i * 2.3) * 0.6, math.sin(i * 1.7)).Unit
		local mote = piece.parts["Mote" .. i]
		mote.CFrame = at * CFrame.new(dir * (2.2 * (1 - u)))
		mote.Transparency = 0.2 + 0.8 * (1 - u) * 0.5
	end
end

updaters.practice_space = function(piece, ctx, _progress, _pieces, t)
	local at = hands(ctx)
	local apart = 0.8 + ctx.tier * 0.25 -- a master folds a longer distance
	local a = at * CFrame.new(-apart, 0, 0)
	local b = at * CFrame.new(apart, 0, 0)
	-- Flat rings (cylinders lie along X: turn them to face up).
	local flat = CFrame.Angles(0, 0, math.rad(90))
	piece.parts.RingA.CFrame = a * flat
	piece.parts.RingAHole.CFrame = a * flat
	piece.parts.RingB.CFrame = b * flat
	piece.parts.RingBHole.CFrame = b * flat
	local u = (t / 2.4) % 1
	local pebble = piece.parts.Pebble
	if u < 0.5 then
		pebble.CFrame = a * CFrame.new(0, 1.2 * (1 - u * 2), 0) -- falling into the first ring
	else
		pebble.CFrame = b * CFrame.new(0, -1.2 * (u - 0.5) * 2, 0) -- and out of the second
	end
end

updaters.practice_time = function(piece, ctx, _progress, _pieces, t)
	local at = hands(ctx)
	local tier = ctx.tier
	local hold = if tier <= 2 then 0.12 else 0.2 + math.min(tier, 9) * 0.02 -- how long the moment holds
	local u = (t / 4) % 1
	local fall = 1.6
	local y
	local frozen = false
	if u < 0.3 then
		y = -fall * (u / 0.3) ^ 2
	elseif u < 0.3 + hold then
		y = -fall
		frozen = true
	else
		local back = math.clamp((u - 0.3 - hold) / (1 - 0.3 - hold), 0, 1)
		y = -fall * (1 - back) ^ 2
	end
	local jitter = if frozen and tier <= 2 then math.sin(t * 40) * 0.04 else 0
	piece.parts.Pebble.CFrame = at * CFrame.new(jitter, y, 0)
	local halo = piece.parts.Halo
	halo.Transparency = if frozen then 0.4 else 1
	halo.CFrame = at * CFrame.new(0, y, 0) * CFrame.Angles(0, t, math.rad(90))
end

updaters.practice_gravity = function(piece, ctx, progress, _pieces, t)
	local at: CFrame = piece.data.at
	local tier = ctx.tier
	local count: number = piece.data.count
	local lift = math.clamp(progress * 5, 0, 1) -- they rise at the start of each piece of work
	for i = 1, count do
		local a = t * (0.4 + tier * 0.04) + i / count * math.pi * 2
		local r = 2 + hash(i, 37) * 0.6
		local drop = if tier <= 2 and math.sin(t * 0.8 + i * 2) > 0.8 then 0.7 else 0 -- a novice loses one now and then
		local h = (1.2 + tier * 0.15 + math.sin(t + i) * 0.15) * lift * (1 - drop)
		piece.parts["Stone" .. i].CFrame = at * CFrame.new(math.cos(a) * r, 0.2 + h, math.sin(a) * r) * CFrame.Angles(t * 0.5 + i, t * 0.3, 0)
	end
end

local REALITY_SHAPES = { Enum.PartType.Block, Enum.PartType.Ball, Enum.PartType.Cylinder, Enum.PartType.Wedge }

updaters.practice_reality = function(piece, ctx, _progress, _pieces, t)
	local style = styleOf(ctx)
	local tier = ctx.tier
	local beat = if tier <= 2 then math.floor(t / 0.7) else math.floor(t / 1.2)
	local thing = piece.parts.Thing
	-- A novice's shape snaps back to a cube half the time; a master's never repeats in a row.
	local index = if tier <= 2 and beat % 2 == 1 then 1 else (beat % #REALITY_SHAPES) + 1
	if piece.data.shape ~= index then
		piece.data.shape = index
		thing.Shape = REALITY_SHAPES[index]
		local colours = { style.primary, style.secondary, style.accent }
		thing.Color = colours[(beat % 3) + 1]
	end
	local s = 0.5 + math.sin(t * 3) * 0.05
	thing.Size = Vector3.new(s, s, s)
	thing.Transparency = 0.15 + (if math.sin(t * 11) > 0.92 then 0.6 else 0)
	thing.CFrame = hands(ctx) * CFrame.Angles(t * 0.7, t, 0)
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
	else
		local up = updaters[kind]
		if up then
			up(piece, ctx, progress, pieces, t, done)
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
