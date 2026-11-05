--!strict
--[[
	ReticleController: shows where the readied spell will go (docs/Casting.md §7). Client-only and
	cosmetic: every number comes from the spell's previewed stats and Shared/Magic/Aim, the same
	maths the server uses, so the guide and the server agree on range, sight and flight.

	BY FORM (Aim.reticleKind)
		arc     projectile: dotted ballistic path from the muzzle (Aim.launchVelocity/positionAt,
		        the flight Delivery flies), stopping where it would hit; a ring at the impact
		line    beam: a thin line from the muzzle to the first thing it hits, faded past max range
		chain   the line to the first target, then ghost dots to the next hops (nearest characters
		        within Aim.chainJump), with an outline on each target
		cone    touch: the wedge in front of you (Aim.touchReach, touch.coneDegrees), on the ground
		ground  burst / zone / pillar / summon / ritual: a ring of the spell's area at the aim point,
		        each dot dropped onto the terrain so it follows slopes
		wall    a line across the aim of the wall's length (area = half-length), on the ground
		self    aura: a ring of the area around you
	CHARGE  while charging, the guide shows the current stage: area rings grow by the stage's
	        area, the arc flies at the stage's speed (Magic/Charge, the server's numbers).
	GUARDS  a spell guards can't stop (Mental, Temporal) or that pierces them (Piercing) says so
	        by the cursor ("⊘ Unblockable", "↣ Pierces guards"; Shared/Magic/GuardRules).
	STATES  in range and in sight: your Signature colour. Out of range or no line of sight: the
	        warning colour AND a label by the cursor ("✕ Out of range", "◌ No line of sight"), so
	        colour is never the only cue. A soft-locked target gets a ◎ marker.
	BUDGET  one reticle (only while a spell is attuned, setting Aim guide on); dots are pooled,
	        anchored, non-colliding, non-queryable parts in workspace.AimReticle moved with
	        BulkMoveTo; geometry is recomputed at UPDATE_HZ (at most ~40 short raycasts a tick).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Aim = require(Shared.Magic.Aim)
local Charge = require(Shared.Magic.Charge)
local GuardRules = require(Shared.Magic.GuardRules)
local Registry = require(Shared.Magic.Registry)

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)
local SpellFx = require(Client:WaitForChild("Fx").SpellFx)

local UPDATE_HZ = 20
local STATS_REFRESH = 1 -- seconds: re-preview the spell (the place's density/resonance change it)
local MAX_DOTS = 64
local DOT_SIZE = 0.32
local RING_DOTS = 24
local ARC_STEP = 0.045 -- seconds of flight between arc dots
local ARC_MAX_DOTS = 36
local MAX_HIGHLIGHTS = 4
local HIDDEN = CFrame.new(0, -10000, 0)

local ReticleController = {
	name = "ReticleController",
	dependencies = { "CastClient", "AimController", "MagicStateController", "InterfaceController" },
}

local castClient: any = nil
local aimer: any = nil
local magic: any = nil
local interface: any = nil
local localPlayer = Players.LocalPlayer

local folder: Folder? = nil
local dots: { Part } = {}
local line: Part? = nil
local highlights: { Highlight } = {}
local label: TextLabel? = nil
local lockMarker: BillboardGui? = nil

type Cached = { key: string, stats: any, at: number, domain: string }
local cached: Cached? = nil

-- ─── Pooled pieces ──────────────────────────────────────────────────────────

local function reticleFolder(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local created = Instance.new("Folder")
	created.Name = "AimReticle" -- AimController's ray ignores this folder
	created.Parent = workspace
	folder = created
	return created
end

local function newPart(shape: Enum.PartType, size: Vector3): Part
	local part = Instance.new("Part")
	part.Shape = shape
	part.Size = size
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Material = Enum.Material.Neon
	part.Transparency = 1
	part.CFrame = HIDDEN
	part.Parent = reticleFolder()
	return part
end

local function dot(i: number): Part
	local part = dots[i]
	if not part then
		part = newPart(Enum.PartType.Ball, Vector3.one * DOT_SIZE)
		dots[i] = part
	end
	return part
end

local function linePart(): Part
	local part = line
	if not part then
		part = newPart(Enum.PartType.Block, Vector3.new(0.12, 0.12, 1))
		line = part
	end
	return part :: Part
end

local function statusLabel(): TextLabel
	local existing = label
	if existing then
		return existing
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "AimStatus"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	local text = Instance.new("TextLabel")
	text.BackgroundTransparency = 0.35
	text.BackgroundColor3 = Theme.color.bg
	text.TextColor3 = Theme.color.ink
	text.FontFace = Theme.font.medium
	text.TextSize = 14
	text.AutomaticSize = Enum.AutomaticSize.XY
	text.Size = UDim2.fromOffset(0, 0)
	text.Visible = false
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft, pad.PaddingRight = UDim.new(0, 6), UDim.new(0, 6)
	pad.PaddingTop, pad.PaddingBottom = UDim.new(0, 2), UDim.new(0, 2)
	pad.Parent = text
	text.Parent = gui
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	label = text
	return text
end

local function marker(): BillboardGui
	local existing = lockMarker
	if existing then
		return existing
	end
	local gui = Instance.new("BillboardGui")
	gui.Name = "LockMarker"
	gui.Size = UDim2.fromOffset(44, 44)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	local text = Instance.new("TextLabel")
	text.Name = "Glyph"
	text.BackgroundTransparency = 1
	text.Size = UDim2.fromScale(1, 1)
	text.Text = "◎"
	text.TextScaled = true
	text.FontFace = Theme.font.bold
	text.TextColor3 = Theme.color.accent
	text.TextStrokeTransparency = 0.3
	text.Parent = gui
	gui.Enabled = false
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	lockMarker = gui
	return gui
end

local function highlight(i: number): Highlight
	local h = highlights[i]
	if not h then
		h = Instance.new("Highlight")
		h.DepthMode = Enum.HighlightDepthMode.AlwaysOnTop
		h.Enabled = false
		h.Parent = reticleFolder()
		highlights[i] = h
	end
	return h
end

-- ─── Drawing helpers ────────────────────────────────────────────────────────

local placed: { BasePart } = {}
local placedAt: { CFrame } = {}

local function put(position: Vector3)
	local i = #placed + 1
	if i > MAX_DOTS then
		return
	end
	table.insert(placed, dot(i))
	table.insert(placedAt, CFrame.new(position))
end

-- Moves the used dots into place (one BulkMoveTo), colours them, hides the rest.
local function flush(color: Color3, transparency: number)
	for _, part in placed do
		part.Color = color
		part.Transparency = transparency
	end
	for i = #placed + 1, #dots do
		local part = dots[i]
		if part.Transparency < 1 then
			part.Transparency = 1
			table.insert(placed, part)
			table.insert(placedAt, HIDDEN)
		end
	end
	if #placed > 0 then
		workspace:BulkMoveTo(placed, placedAt, Enum.BulkMoveMode.FireCFrameChanged)
	end
	table.clear(placed)
	table.clear(placedAt)
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude

-- What the reticle's rays look through. Ground snapping also skips NPCs (dots belong on the
-- floor, not on heads); the projectile arc doesn't, so it stops at whoever it would hit.
local function ignoreList(skipNpcs: boolean): { Instance }
	local list: { Instance } = { reticleFolder() }
	if localPlayer.Character then
		table.insert(list, localPlayer.Character)
	end
	local fx = workspace:FindFirstChild("MagicFx")
	if fx then
		table.insert(list, fx)
	end
	local npcs = skipNpcs and workspace:FindFirstChild("NPCs")
	if npcs then
		table.insert(list, npcs)
	end
	return list
end

-- The ground under `position` (searching `up` above and `down` below), or the position itself.
local function ground(position: Vector3, up: number, down: number): Vector3
	local result = workspace:Raycast(position + Vector3.new(0, up, 0), Vector3.new(0, -(up + down), 0), groundParams)
	return if result then result.Position + Vector3.new(0, 0.15, 0) else position
end

local function ring(center: Vector3, radius: number, follow: boolean)
	for i = 1, RING_DOTS do
		local a = (i / RING_DOTS) * math.pi * 2
		local p = center + Vector3.new(math.cos(a) * radius, 0, math.sin(a) * radius)
		put(if follow then ground(p, 6, 10) else p)
	end
end

local function dottedLine(from: Vector3, to: Vector3, spacing: number)
	local delta = to - from
	local count = math.clamp(math.floor(delta.Magnitude / spacing), 1, 20)
	for i = 1, count do
		put(from + delta * (i / count))
	end
end

-- ─── Shapes ─────────────────────────────────────────────────────────────────

type Frame = {
	root: BasePart,
	character: Model,
	muzzle: Vector3,
	point: Vector3,
	target: Model?,
	stats: any,
	domain: string,
	areaMult: number, -- the charge stage's area (1 when not charging)
	speedMult: number, -- the charge stage's projectile speed
}

local function drawArc(f: Frame)
	local power = f.stats.recipe.power
	local speed = Aim.projectileSpeed(power) * f.speedMult
	local gravity = Aim.projectileGravity(f.domain)
	local velocity = Aim.launchVelocity(f.muzzle, f.point, speed, gravity, f.root.CFrame.LookVector)
	local maxDistance = Aim.flightDistance(f.stats.range)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignoreList(false)
	local previous = f.muzzle
	local travelled = 0
	for i = 1, ARC_MAX_DOTS do
		local p = Aim.positionAt(f.muzzle, velocity, gravity, i * ARC_STEP)
		local step = p - previous
		local hit = workspace:Raycast(previous, step, params)
		if hit then
			put(hit.Position)
			ring(hit.Position, math.max(1, Aim.projectileRadius(power)), true)
			return
		end
		travelled += step.Magnitude
		if travelled > maxDistance then
			return -- fizzles in the air: the arc just ends
		end
		put(p)
		previous = p
	end
end

local function drawLine(f: Frame, endAt: Vector3?, faded: boolean)
	local part = linePart()
	local to = endAt or f.point
	local delta = to - f.muzzle
	local length = math.min(delta.Magnitude, Aim.maxDistance(f.stats.range))
	if length < 0.5 then
		part.Transparency = 1
		return
	end
	part.Size = Vector3.new(0.12, 0.12, length)
	part.CFrame = CFrame.lookAt(f.muzzle, to) * CFrame.new(0, 0, -length / 2)
	part.Transparency = if faded then 0.75 else 0.35
end

local function drawCone(f: Frame)
	local reach = Aim.touchReach(f.stats.range)
	local half = math.rad(Aim.tuning.touch.coneDegrees)
	local flat = Vector3.new(f.point.X - f.root.Position.X, 0, f.point.Z - f.root.Position.Z)
	local forward = if flat.Magnitude > 0.3 then flat.Unit else f.root.CFrame.LookVector * Vector3.new(1, 0, 1)
	local base = f.root.Position
	local function at(angle: number, distance: number): Vector3
		local dir = (CFrame.Angles(0, angle, 0) * CFrame.lookAt(Vector3.zero, forward)).LookVector
		return ground(base + dir * distance, 4, 8)
	end
	for i = 1, 6 do
		put(at(half, reach * i / 6))
		put(at(-half, reach * i / 6))
	end
	for i = 0, 10 do
		put(at(-half + 2 * half * i / 10, reach))
	end
end

local function chainCandidates(): { Model }
	local list: { Model } = {}
	for _, player in Players:GetPlayers() do
		if player ~= localPlayer and player.Character then
			table.insert(list, player.Character)
		end
	end
	local npcs = workspace:FindFirstChild("NPCs")
	if npcs then
		for _, child in npcs:GetChildren() do
			if child:IsA("Model") then
				table.insert(list, child)
			end
		end
	end
	return list
end

local function rootOf(model: Model): BasePart?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	return if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") then root else nil
end

-- The first target and the ghost hops after it: { Model }.
local function drawChain(f: Frame): { Model }
	local chain: { Model } = {}
	local first = f.target
	local firstRoot = first and rootOf(first)
	drawLine(f, if firstRoot then firstRoot.Position else nil, false)
	if not first or not firstRoot then
		return chain
	end
	table.insert(chain, first)
	local hit: { [Model]: boolean } = { [first] = true }
	local jump = Aim.chainJump(f.stats.recipe.power)
	local last = firstRoot
	local max = math.min(f.stats.maxTargets or 1, MAX_HIGHLIGHTS)
	while #chain < max do
		local best: Model?, bestRoot: BasePart?, bestDistance = nil, nil, jump
		for _, model in chainCandidates() do
			local root = if hit[model] then nil else rootOf(model)
			if root then
				local d = (root.Position - last.Position).Magnitude
				if d <= bestDistance then
					best, bestRoot, bestDistance = model, root, d
				end
			end
		end
		if not best or not bestRoot then
			break
		end
		dottedLine(last.Position, bestRoot.Position, 1.6)
		table.insert(chain, best)
		hit[best] = true
		last = bestRoot
	end
	return chain
end

local function drawWall(f: Frame)
	local center = ground(f.point, 6, 12)
	local flat = Vector3.new(f.point.X - f.root.Position.X, 0, f.point.Z - f.root.Position.Z)
	local forward = if flat.Magnitude > 0.3 then flat.Unit else f.root.CFrame.LookVector
	local across = Vector3.new(-forward.Z, 0, forward.X)
	local half = math.max(2, f.stats.area * f.areaMult)
	for i = -8, 8 do
		put(ground(center + across * (half * i / 8), 6, 10))
	end
end

-- ─── The loop ───────────────────────────────────────────────────────────────

local function statsFor(key: string): Cached?
	local c = cached
	if c and c.key == key and os.clock() - c.at < STATS_REFRESH then
		return c
	end
	local spell = magic:spell(key)
	if not spell then
		return nil
	end
	local stats = magic:preview(spell.recipe)
	if not stats then
		return nil
	end
	local branch = Registry.branches[spell.recipe.branch]
	local fresh: Cached = { key = key, stats = stats, at = os.clock(), domain = if branch then branch.domains[1] else "energy" }
	cached = fresh
	return fresh
end

local function hideAll()
	flush(Color3.new(), 1)
	if line then
		line.Transparency = 1
	end
	for _, h in highlights do
		h.Enabled = false
	end
	if label then
		label.Visible = false
	end
	if lockMarker then
		lockMarker.Enabled = false
	end
end

local function setLabel(text: string?, color: Color3)
	local l = statusLabel()
	if not text then
		l.Visible = false
		return
	end
	l.Text = text
	l.TextColor3 = color
	l.Visible = true
	local camera = workspace.CurrentCamera
	local at = if interface.inputMode:get() == "Keyboard" then UserInputService:GetMouseLocation() else camera.ViewportSize / 2
	l.Position = UDim2.fromOffset(at.X + 18, at.Y + 14)
end

local function update()
	local held = castClient.attuned:get()
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not held or not character or not root or not root:IsA("BasePart") or magic.settings:get().aimGuide == false then
		hideAll()
		return
	end
	local c = statsFor(held.key)
	if not c then
		hideAll()
		return
	end
	groundParams.FilterDescendantsInstances = ignoreList(true)

	local point, target = aimer:current()
	local stats = c.stats
	local form = stats.recipe.form
	local f: Frame = {
		root = root,
		character = character,
		muzzle = Aim.muzzle(root.Position),
		point = point,
		target = target,
		stats = stats,
		domain = c.domain,
		areaMult = 1,
		speedMult = 1,
	}
	local charge = castClient.charging:get()
	if charge and charge.key == held.key then
		local stage = Charge.stage(Charge.stageIndex(os.clock() - charge.started, charge.castTime))
		local scales = Charge.data.formScales[form] or {}
		f.areaMult = if scales.area and stage.area then stage.area else 1
		f.speedMult = if scales.speed and stage.speed then stage.speed else 1
	end

	-- Range and sight, exactly as the server judges them.
	local selfCentred = Aim.tuning.selfCentred[form] == true
	local inRange = selfCentred or Aim.withinRange(f.muzzle, point, stats.range)
	local inSight = true
	if not selfCentred and not Aim.tuning.noLineOfSight[form] then
		local eye = Aim.eye(character) or root.Position
		local ignore: { Instance } = { character, reticleFolder() }
		if target then
			table.insert(ignore, target)
		end
		inSight = Aim.lineOfSight(eye, point, ignore)
	end

	local kind = Aim.reticleKind(form)
	local chain: { Model } = {}
	local showLine = false
	if kind == "arc" then
		drawArc(f)
	elseif kind == "line" then
		drawLine(f, nil, not inRange)
		showLine = true
	elseif kind == "chain" then
		chain = drawChain(f)
		showLine = true
	elseif kind == "cone" then
		drawCone(f)
	elseif kind == "wall" then
		drawWall(f)
	elseif kind == "self" then
		ring(ground(root.Position, 2, 6), math.max(1.5, stats.area * f.areaMult), true)
	else
		local center = ground(point, 6, 12)
		ring(center, math.max(1.5, stats.area * f.areaMult), true)
		put(center)
	end
	if not showLine and line then
		line.Transparency = 1
	end

	local ok = inRange and inSight
	local style = SpellFx.styleFor(localPlayer.UserId, c.domain)
	local color = if ok then style.primary else Theme.color.danger
	flush(color, if ok then 0.25 else 0.45)
	if line then
		line.Color = color
	end

	for i = 1, MAX_HIGHLIGHTS do
		local model = chain[i]
		if model then
			local h = highlight(i)
			h.Adornee = model
			h.OutlineColor = color
			h.FillColor = color
			h.FillTransparency = if i == 1 then 0.8 else 0.92
			h.OutlineTransparency = if i == 1 then 0 else 0.5
			h.Enabled = true
		elseif highlights[i] then
			highlights[i].Enabled = false
		end
	end

	local lockedModel = aimer.locked:get()
	local m = marker()
	local lockedRoot = lockedModel and rootOf(lockedModel)
	m.Adornee = lockedRoot
	m.Enabled = lockedRoot ~= nil

	if not inRange then
		setLabel("✕ Out of range", Theme.color.danger)
	elseif not inSight then
		setLabel("◌ No line of sight", Theme.color.warn)
	elseif lockedModel then
		setLabel("◎ " .. lockedModel.Name, Theme.color.accent)
	else
		-- How guards treat this spell, when it's not the ordinary "blockable".
		local guardKind = GuardRules.kindOfRecipe(stats.recipe)
		setLabel(if guardKind ~= "blockable" then GuardRules.label(guardKind) else nil, Theme.color.inkDim)
	end
end

function ReticleController.init(_self: any, ctx: any)
	castClient = ctx.get("CastClient")
	aimer = ctx.get("AimController")
	magic = ctx.get("MagicStateController")
	interface = ctx.get("InterfaceController")
end

function ReticleController.start(_self: any, _ctx: any)
	local elapsed = 0
	RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if elapsed < 1 / UPDATE_HZ then
			return
		end
		elapsed = 0
		update()
	end)
	castClient.attuned:observe(function(held)
		if not held then
			hideAll()
		end
	end)
end

return ReticleController
