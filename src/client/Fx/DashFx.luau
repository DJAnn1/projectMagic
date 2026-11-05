--!strict
--[[
	DashFx: what a dash looks like, per style (docs/Combat.md §15). Purely visual: the server
	(Services/MovementService) sends a "dash" WorldEffect cue to everyone nearby:
		{ caster, domain?, style, kind, from, to, duration }
	Colours come from the caster's style (SpellFx.styleFor: domain palette tinted by the Signature);
	a plain dash (no spell readied) is grey dust.

		impulse styles (roll, jet, slide, wave, glide, flip)
		         a particle trail that follows the body for the dash, in the style's texture
		         (dust, sparks, water, wind); flip adds a ring on the ground where you jumped
		blink    an afterimage of the body where you left (fading Neon copies of its parts),
		         a flash at both ends and a streak of sparkles along the line
		rewind   the afterimage where you were, a rune circle where you land, and a reversed
		         streak (it reads as being pulled back)
	Budget: pooled anchors and emitters (FxPool caps); afterimages are at most 8 parts and live
	0.35 s; nothing is drawn past DRAW_RANGE from the camera.
]]

local Players = game:GetService("Players")

local FxPool = require(script.Parent.FxPool)
local FxLayers = require(script.Parent.FxLayers)
local DomainFx = require(script.Parent.DomainFx)
local SpellFx = require(script.Parent.SpellFx)

local TEX = DomainFx.textures
local DRAW_RANGE = 220
local AFTERIMAGE_SECONDS = 0.35
local MAX_AFTERIMAGE_PARTS = 8

local DUST: FxLayers.Style = {
	primary = Color3.fromRGB(190, 180, 165),
	secondary = Color3.fromRGB(150, 140, 128),
	accent = Color3.fromRGB(110, 102, 94),
	particle = "dust",
	motion = "drifting",
}

-- The trail texture for each impulse style (domain looks fill in the rest).
local TRAIL: { [string]: string } = {
	roll = TEX.smoke,
	slide = TEX.debris,
	wave = TEX.sparkles,
	glide = TEX.smoke,
	flip = TEX.vortex,
}

local DashFx = {}

local function casterModel(userId: any): Model?
	if typeof(userId) ~= "number" then
		return nil
	end
	local player = Players:GetPlayerByUserId(userId)
	return player and player.Character
end

local function inRange(position: Vector3): boolean
	local camera = workspace.CurrentCamera
	return camera ~= nil and (camera.CFrame.Position - position).Magnitude <= DRAW_RANGE
end

-- Fading copies of the body's parts at its current pose, left behind at `offset` from it.
local function afterimage(model: Model, offset: Vector3, color: Color3)
	local count = 0
	for _, part in model:GetChildren() do
		if count >= MAX_AFTERIMAGE_PARTS then
			break
		end
		if part:IsA("BasePart") and part.Name ~= "HumanoidRootPart" and part.Transparency < 1 then
			local ghost = FxPool.anchor(part.CFrame + offset, part.Size)
			if ghost then
				count += 1
				ghost.Material = Enum.Material.Neon
				ghost.Color = color
				ghost.Transparency = 0.45
				FxLayers.animate(AFTERIMAGE_SECONDS, function(t)
					ghost.Transparency = 0.45 + 0.55 * t
				end, function()
					FxPool.release(ghost)
				end)
			end
		end
	end
end

-- A short streak of particles along a line (blink and rewind).
local function streak(from: Vector3, to: Vector3, style: FxLayers.Style, reversed: boolean)
	local span = to - from
	if span.Magnitude < 0.5 then
		return
	end
	local anchor = FxPool.anchor(CFrame.lookAt(from + span / 2, to), Vector3.new(0.6, 0.6, span.Magnitude))
	if not anchor then
		return
	end
	local e = FxLayers.emitter(anchor, {
		texture = TEX.sparkles,
		color = FxLayers.ramp(style),
		size = FxLayers.seq(0, 0.5, 1, 0),
		transparency = FxLayers.seq(0, 0.1, 1, 1),
		lifetime = NumberRange.new(0.25, 0.45),
		speed = NumberRange.new(if reversed then 4 else 1, if reversed then 7 else 3),
		emission = 1,
		direction = if reversed then Enum.NormalId.Back else Enum.NormalId.Front,
		shape = Enum.ParticleEmitterShape.Box,
	})
	if e then
		e:Emit(math.clamp(math.floor(span.Magnitude * 1.5), 6, 40))
	end
	FxPool.releaseAfter(anchor, 0.6)
end

-- A trail that rides along with the body for the dash.
local function trail(root: BasePart, styleId: string, style: FxLayers.Style, domain: string?, duration: number)
	local anchor = FxPool.anchor(root.CFrame)
	if not anchor then
		return
	end
	local look = if domain then DomainFx.look(domain) else nil
	local texture = TRAIL[styleId] or (if look then look.body.texture else TEX.smoke)
	local additive = look ~= nil and look.body.additive
	local e = FxLayers.emitter(anchor, {
		texture = texture,
		color = if domain then FxLayers.ramp(style) else FxLayers.solid(style.primary),
		size = FxLayers.seq(0, 1.2, 1, 2.2),
		transparency = FxLayers.seq(0, 0.25, 1, 1),
		lifetime = NumberRange.new(0.3, 0.55),
		speed = NumberRange.new(0.5, 2),
		spread = 60,
		emission = if additive then 1 else 0,
		influence = if additive then 0 else 0.8,
		shape = Enum.ParticleEmitterShape.Sphere,
		rate = 70,
	})
	if e then
		e.Enabled = true
	end
	FxLayers.animate(duration, function()
		if root.Parent then
			anchor.CFrame = root.CFrame - Vector3.new(0, 1.5, 0)
		end
	end, function()
		if e then
			e.Enabled = false
		end
		FxPool.releaseAfter(anchor, 0.6)
	end)
end

function DashFx.cue(cue: { [string]: any })
	local from, to = cue.from, cue.to
	if typeof(from) ~= "Vector3" or typeof(to) ~= "Vector3" or not inRange(from) then
		return
	end
	local domain: string? = if typeof(cue.domain) == "string" then cue.domain else nil
	local style = if domain then SpellFx.styleFor(cue.caster, domain) else DUST
	local styleId: string = if typeof(cue.style) == "string" then cue.style else "roll"
	local kind = cue.kind
	local duration = if typeof(cue.duration) == "number" then math.clamp(cue.duration, 0.1, 1) else 0.28
	local model = casterModel(cue.caster)
	local root = model and model:FindFirstChild("HumanoidRootPart")

	if kind == "blink" or kind == "rewind" then
		-- The body is already at `to` (or about to be): leave an afterimage where it was.
		if model then
			local here = if root and root:IsA("BasePart") then root.Position else to
			afterimage(model, from - here, style.primary)
		end
		FxLayers.flash(from + Vector3.new(0, 1, 0), 1.6, FxLayers.whiten(style.primary, 0.4), 0.18)
		FxLayers.flash(to + Vector3.new(0, 1, 0), 1.2, FxLayers.whiten(style.secondary, 0.4), 0.15)
		streak(from + Vector3.new(0, 1, 0), to + Vector3.new(0, 1, 0), style, kind == "rewind")
		if kind == "rewind" then
			local ground, up = FxLayers.ground(to, 6)
			FxLayers.groundMark("rune", ground or to, up or Vector3.yAxis, 2.5, style)
		end
	elseif root and root:IsA("BasePart") then
		trail(root, styleId, style, domain, duration)
		if styleId == "flip" then
			local ground, up = FxLayers.ground(from, 6)
			FxLayers.shockwave(ground or from, up or Vector3.yAxis, 3, style.primary, 0.35)
		end
	end
	local look = if domain then DomainFx.look(domain) else nil
	FxLayers.sound(from, if look then look.sounds.launch else { id = DomainFx.sounds.whoosh, pitch = 1.3, volume = 0.4 }, 0.8)
end

return DashFx
