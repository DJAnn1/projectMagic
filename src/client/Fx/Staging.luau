--!strict
--[[
	Staging: plays a spell's beats once it lands (docs/Smoothness.md stage 3; data in
	Shared/Magic/Data/Stagings). Purely visual and local.

		Staging.play(form, centre, normal, radius, style, power, opts?)
			the form's beats from Data.forms, on the spot the server resolved
			opts.root   the caster's root part (crescent slashes whirl round it)
			opts.look   the domain's look (shard texture)
		Staging.ultimate(centre, normal, reach, style, reveal, length, sigil?)
			an ultimate's long sequence: build until `reveal - pause`, stillness, then on `reveal`
			(the first hit, seconds from now) a flash, the field-sized dome and a ring stream that
			lasts until `length`. `sigil` is the caster's sigil spec (Fx/Sigils).

	PIECES
		dome     a ForceField-material ball centred on the ground (so a dome above it), grown,
		         held, faded. Standing inside one tints the view toward its colour (capped; less
		         with Reduce spell effects), because a ball isn't drawn from the inside.
		rings    a flat part with a SurfaceGui ring (crisp at any size), running out and fading;
		         lifted above grass like sigils.
		rays     Beams from the spot up and slightly out, rising then fading.
		slashes  SlashFx crescents round the caster.
		shards   a one-shot burst of the domain's spark texture.
		flash    FxLayers.flash.
	Caps (Data caps): domes, rings, range from the camera. Reduce spell effects: fewer rays,
	shards and rings, a weaker inside tint.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Data = require(Shared.Magic.Data.Stagings)

local FxPool = require(script.Parent.FxPool)
local FxLayers = require(script.Parent.FxLayers)
local DomainFx = require(script.Parent.DomainFx)
local SlashFx = require(script.Parent.SlashFx)
local Sigils = require(script.Parent.Sigils)
local Theme = require(script.Parent.Parent:WaitForChild("UI").Theme)

type Style = FxLayers.Style

local TEX = DomainFx.textures
local P = Data.pieces

local Staging = {}

local folder: Folder? = nil
local function folderOf(): Folder
	local f = folder
	if f and f.Parent then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "StagingFx"
	made.Parent = workspace
	folder = made
	return made
end

local function reduced(): boolean
	return Theme.settings.reducedEffects == true
end

local function inRange(position: Vector3): boolean
	local camera = workspace.CurrentCamera
	return camera == nil or (camera.CFrame.Position - position).Magnitude <= Data.caps.range
end

-- ─── Domes and the view inside them ─────────────────────────────────────────

type Dome = { part: Part, color: Color3 }
local domes: { Dome } = {}
local tint: ColorCorrectionEffect? = nil
local tintLoop: RBXScriptConnection? = nil

local function updateTint()
	local camera = workspace.CurrentCamera
	local eye = if camera then camera.CFrame.Position else nil
	local best, color = 0, Color3.new(1, 1, 1)
	if eye then
		for _, dome in domes do
			local part = dome.part
			local r = part.Size.X / 2
			local d = (part.Position - eye).Magnitude
			if r > 1 and d < r then
				local k = (1 - part.Transparency) * math.clamp((r - d) / math.max(2, r * 0.25), 0, 1)
				if k > best then
					best, color = k, dome.color
				end
			end
		end
	end
	local cap = if reduced() then Data.caps.insideTintReduced else Data.caps.insideTint
	local cc = tint
	if best > 0.01 then
		if not cc then
			local made = Instance.new("ColorCorrectionEffect")
			made.Name = "StagingTint"
			made.Parent = Lighting
			tint = made
			cc = made
		end
		local c = cc :: ColorCorrectionEffect
		c.Enabled = true
		c.TintColor = Color3.new(1, 1, 1):Lerp(color, best * cap)
	elseif cc then
		cc.Enabled = false
	end
	if #domes == 0 then
		if cc then
			cc.Enabled = false
		end
		local loop = tintLoop
		if loop then
			loop:Disconnect()
			tintLoop = nil
		end
	end
end

local function dome(centre: Vector3, radius: number, style: Style, grow: number, hold: number, fade: number)
	if #domes >= Data.caps.domes or radius < 0.5 then
		return
	end
	local part = Instance.new("Part")
	part.Name = "Dome"
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.ForceField
	part.Color = style.primary
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Size = Vector3.one * 0.5
	part.CFrame = CFrame.new(centre)
	part.Transparency = 0
	part.Parent = folderOf()
	local entry: Dome = { part = part, color = style.primary }
	table.insert(domes, entry)
	if not tintLoop then
		tintLoop = RunService.RenderStepped:Connect(updateTint)
	end
	local size = radius * 2
	local total = grow + hold + fade
	FxLayers.animate(total, function(t)
		local s = t * total
		if s <= grow then
			local e = 1 - (1 - s / grow) ^ 3
			part.Size = Vector3.one * (0.5 + (size - 0.5) * e)
			part.Transparency = 0.1
		elseif s <= grow + hold then
			part.Size = Vector3.one * size
			part.Transparency = 0.1
		else
			local f = (s - grow - hold) / math.max(0.01, fade)
			part.Size = Vector3.one * size * (1 + 0.08 * f)
			part.Transparency = 0.1 + 0.9 * f
		end
	end, function()
		local i = table.find(domes, entry)
		if i then
			table.remove(domes, i)
		end
		part:Destroy()
	end)
end

-- ─── Rings ──────────────────────────────────────────────────────────────────

local ringsLive = 0

local function ring(centre: Vector3, normal: Vector3, radius: number, color: Color3, life: number)
	if ringsLive >= Data.caps.rings or radius < 0.5 then
		return
	end
	ringsLive += 1
	local up = if normal.Magnitude > 0.1 then normal.Unit else Vector3.yAxis
	local ref = if math.abs(up.Y) < 0.95 then Vector3.yAxis else Vector3.xAxis
	local cf = CFrame.fromMatrix(centre + up * (Sigils.groundLift(centre) + 0.02), ref:Cross(up).Unit, up)
	local part = Instance.new("Part")
	part.Name = "Ring"
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.CastShadow = false
	part.Transparency = 1
	part.Size = Vector3.new(1, 0.05, 1)
	part.CFrame = cf
	local gui = Instance.new("SurfaceGui")
	gui.Face = Enum.NormalId.Top
	gui.SizingMode = Enum.SurfaceGuiSizingMode.FixedSize
	gui.CanvasSize = Vector2.new(256, 256)
	gui.LightInfluence = 0
	gui.Brightness = 2
	local frame = Instance.new("Frame")
	frame.AnchorPoint = Vector2.new(0.5, 0.5)
	frame.Position = UDim2.fromScale(0.5, 0.5)
	frame.Size = UDim2.fromScale(0.94, 0.94)
	frame.BackgroundTransparency = 1
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0.5, 0)
	corner.Parent = frame
	local stroke = Instance.new("UIStroke")
	stroke.Thickness = math.max(2, 256 * P.ringThickness)
	stroke.Color = color
	stroke.Parent = frame
	frame.Parent = gui
	gui.Parent = part
	part.Parent = folderOf()
	local size = radius * 2
	FxLayers.animate(life, function(t)
		local e = 1 - (1 - t) ^ 2.4
		local d = math.max(0.3, size * (0.08 + 0.92 * e))
		part.Size = Vector3.new(d, 0.05, d)
		stroke.Transparency = t ^ 1.6
	end, function()
		ringsLive -= 1
		part:Destroy()
	end)
end

local function ringStream(centre: Vector3, normal: Vector3, radius: number, style: Style, count: number, every: number)
	for i = 1, count do
		task.delay((i - 1) * every, function()
			local color = if i % 2 == 1 then FxLayers.whiten(style.primary, 0.6) else style.secondary
			ring(centre, normal, radius, color, P.ringLife)
		end)
	end
end

-- ─── Rays ───────────────────────────────────────────────────────────────────

local function rays(centre: Vector3, radius: number, style: Style, count: number, life: number)
	local anchor = FxPool.anchor(CFrame.new(centre))
	if not anchor then
		return
	end
	local height = P.rayHeightBase + radius * P.rayHeightPerRadius
	local beams: { { beam: Beam, top: Attachment, dir: Vector3 } } = {}
	local rng = Random.new()
	for i = 1, count do
		local beam = FxPool.beam(anchor)
		if not beam then
			break
		end
		local a = (i - 1) / count * math.pi * 2 + rng:NextNumber(-0.3, 0.3)
		local tilt = math.rad(rng:NextNumber(8, 28))
		local dir = Vector3.new(math.cos(a) * math.sin(tilt), math.cos(tilt), math.sin(a) * math.sin(tilt))
		local base = Instance.new("Attachment")
		base.Position = Vector3.new(math.cos(a), 0, math.sin(a)) * radius * 0.25
		base.Parent = anchor
		local top = Instance.new("Attachment")
		top.Position = base.Position
		top.Parent = anchor
		beam.Attachment0, beam.Attachment1 = base, top
		local w = 0.6 + radius * 0.07
		beam.Width0 = w
		beam.Width1 = w * 2.6
		beam.FaceCamera = true
		beam.LightEmission = 1
		beam.LightInfluence = 0
		beam.Texture = ""
		beam.Color = ColorSequence.new(FxLayers.whiten(style.primary, 0.7), style.primary)
		beam.Transparency = FxLayers.seq(0, 0.35, 1, 1)
		beam.Segments = 1
		table.insert(beams, { beam = beam, top = top, dir = dir })
	end
	FxLayers.animate(life, function(t)
		local rise = math.min(1, t * life / P.rayRise)
		local fadeK = math.clamp((t - 0.45) / 0.55, 0, 1)
		for _, r in beams do
			local base = r.beam.Attachment0
			if base then
				r.top.Position = base.Position + r.dir * height * rise
			end
			r.beam.Transparency = FxLayers.seq(0, 0.35 + 0.65 * fadeK, 1, 1)
		end
	end, function()
		FxPool.release(anchor)
	end)
end

-- ─── Shards ─────────────────────────────────────────────────────────────────

local function shards(centre: Vector3, style: Style, count: number, look: DomainFx.Look?)
	local anchor = FxPool.anchor(CFrame.new(centre + Vector3.new(0, 0.5, 0)))
	if not anchor then
		return
	end
	local texture = if look then look.sparks.texture else TEX.square
	local e = FxLayers.emitter(anchor, {
		texture = texture,
		color = ColorSequence.new(FxLayers.whiten(style.primary, 0.4), style.accent),
		size = FxLayers.seq(0, 0.6, 1, 0),
		transparency = FxLayers.seq(0, 0, 0.8, 0.2, 1, 1),
		lifetime = NumberRange.new(0.5, 0.9),
		speed = NumberRange.new(P.shardSpeed * 0.6, P.shardSpeed),
		spread = 180,
		acceleration = Vector3.new(0, -30, 0),
		emission = 1,
		rotSpeed = NumberRange.new(-300, 300),
	})
	if e then
		e:Emit(count)
	end
	FxPool.releaseAfter(anchor, 1.2)
end

-- ─── Playing ────────────────────────────────────────────────────────────────

export type PlayOpts = { root: BasePart?, look: DomainFx.Look? }

local function beat(b: Data.Beat, centre: Vector3, normal: Vector3, radius: number, style: Style, opts: PlayOpts)
	local r = radius * (b.scale or 1)
	local red = reduced()
	local kind = b.kind
	if kind == "dome" then
		dome(centre, r, style, b.grow or 0.2, b.hold or 0.1, b.fade or 0.5)
	elseif kind == "rings" then
		local n = b.count or 1
		ringStream(centre, normal, r, style, if red then math.min(n, 1) else n, b.every or 0.2)
	elseif kind == "rays" then
		local n = b.count or 3
		rays(centre, r, style, if red then math.max(1, n // 2) else n, P.rayLife)
	elseif kind == "slashes" then
		local root = opts.root
		if root then
			for i = 1, b.count or 1 do
				task.delay((i - 1) * 0.08, function()
					if root.Parent then
						SlashFx.arc(root, {
							clip = nil,
							swing = i + math.random(0, 3),
							primary = style.primary,
							secondary = style.secondary,
							glow = true,
							reach = P.slashReachBase + r * P.slashReachPerRadius,
							duration = 0.35,
						})
					end
				end)
			end
		end
	elseif kind == "shards" then
		local n = b.count or 12
		shards(centre, style, if red then n // 3 else n, opts.look)
	elseif kind == "flash" then
		FxLayers.flash(centre + Vector3.new(0, 0.5, 0), math.max(1, r), FxLayers.whiten(style.primary, 0.5), 0.22)
	end
end

function Staging.play(form: string, centre: Vector3, normal: Vector3, radius: number, style: Style, power: number, opts: PlayOpts?)
	local beats = Data.forms[form]
	if not beats or #beats == 0 or not inRange(centre) then
		return
	end
	local o = opts or {}
	for _, b in beats do
		if power >= (b.minPower or 0) then
			local at = b.at or 0
			if at <= 0 then
				beat(b, centre, normal, radius, style, o)
			else
				task.delay(at, beat, b, centre, normal, radius, style, o)
			end
		end
	end
end

-- An ultimate: build, stillness, reveal on the first hit, linger, fade.
function Staging.ultimate(centre: Vector3, normal: Vector3, reach: number, style: Style, reveal: number, length: number, sigil: Sigils.Spec?)
	if not inRange(centre) then
		return
	end
	local U = Data.ultimate
	local r = math.clamp(reach, 6, U.maxReach)
	local revealAt = math.max(reveal, U.minBuild)
	local buildEnd = math.max(0.2, revealAt - U.pause)
	local lasting = math.max(revealAt + 1, length)

	-- BUILD: the sigil spreads under it and light rises, until the stillness.
	local handle: Sigils.Handle? = nil
	if sigil then
		local up = if normal.Magnitude > 0.1 then normal.Unit else Vector3.yAxis
		local ref = if math.abs(up.Y) < 0.95 then Vector3.yAxis else Vector3.xAxis
		local cf = CFrame.fromMatrix(centre + up * Sigils.groundLift(centre), ref:Cross(up).Unit, up)
		handle = Sigils.create(sigil, cf, r * U.sigilMult, { grow = buildEnd, from = 2 })
	end
	rays(centre, r * 0.5, style, if reduced() then 3 else U.buildRays, buildEnd)

	-- REVEAL on the first hit.
	task.delay(revealAt, function()
		FxLayers.flash(centre + Vector3.new(0, 1, 0), r * 0.6, FxLayers.whiten(style.primary, 0.6), 0.35)
		local hold = math.max(0, lasting - revealAt - U.domeGrow)
		dome(centre, r * U.domeScale, style, U.domeGrow, hold, U.domeFade)
		local count = math.clamp(math.floor((lasting - revealAt) / U.ringEvery), 1, if reduced() then 3 else 14)
		ringStream(centre, normal, r * 1.1, style, count, U.ringEvery)
		shards(centre, style, if reduced() then 8 else U.revealShards, nil)
	end)
	-- FADE when it's over.
	task.delay(lasting, function()
		if handle then
			Sigils.burst(handle)
		end
	end)
end

return Staging
