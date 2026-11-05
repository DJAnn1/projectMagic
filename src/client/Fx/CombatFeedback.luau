--!strict
--[[
	CombatFeedback: what a hit FEELS like on this client. Driven by the server's "hit", "heal" and
	"statusTag" cues (EffectRunner, from Cast/Damage and StatusEffects), never by local guesses.

		hit(cue)        floating damage number in the domain's colour; crits are bigger and end in
		                "!", kills end in "✕" (shape and glyph, never colour alone); damage over time
		                is smaller and dimmer.
		                Your hit: a hit marker at your aim (crit: wider, kill: red X + heavier tick) and
		                hit-stop on heavy hits (a short FOV punch + shake).
		                Hit on you: a red edge flash scaled by the share of your health it took, a
		                small shake.
		heal(cue)       "+N" in green over the healed.
		statusTag(cue)  the status name over the target ("▼ Burning" harmful, "▲ Warded" helpful).

	Settings: Damage numbers off hides numbers, markers and status words; Reduce motion disables
	the FOV punch and shake; High contrast draws white text on black.
	Budget: MAX_NUMBERS live billboards (oldest recycled); numbers only within NUMBER_RANGE studs;
	other people's numbers are smaller and fainter, so your own fight reads first in a crowd.
]]

local Players = game:GetService("Players")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Registry = require(Shared.Magic.Registry)
local FxLayers = require(script.Parent.FxLayers)
local Audio = require(script.Parent.Parent:WaitForChild("Audio").Audio)
local DomainFx = require(script.Parent.DomainFx)
local Theme = require(script.Parent.Parent:WaitForChild("UI").Theme)

local MAX_NUMBERS = 40
local NUMBER_RANGE = 140
local STATUS_RANGE = 80
local FONT = Enum.Font.GothamBlack

local HEAL = Color3.fromRGB(110, 235, 130)
local HARMFUL_STATUS = Color3.fromRGB(255, 170, 90)
local HELPFUL_STATUS = Color3.fromRGB(120, 220, 255)
local DOT_COLORS: { [string]: Color3 } = {
	burning = Color3.fromRGB(255, 140, 50),
	poison = Color3.fromRGB(150, 220, 70),
	rot = Color3.fromRGB(150, 120, 80),
	hexed = Color3.fromRGB(190, 110, 255),
}

local CombatFeedback = {}

local localPlayer = Players.LocalPlayer
local rng = Random.new()

-- ─── Damage numbers (pooled BillboardGuis on Terrain attachments) ───────────

type Number = { gui: BillboardGui, label: TextLabel, holder: Attachment, busy: boolean, started: number }
local pool: { Number } = {}

local function newNumber(): Number
	local holder = Instance.new("Attachment")
	holder.Name = "CombatNumber"
	local gui = Instance.new("BillboardGui")
	gui.Size = UDim2.fromOffset(220, 64)
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.MaxDistance = NUMBER_RANGE
	gui.ResetOnSpawn = false -- straight under PlayerGui: plain folders there are wiped on respawn
	gui.Enabled = false
	gui.Adornee = holder
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = FONT
	label.TextScaled = true
	label.TextStrokeTransparency = 0.2
	label.Parent = gui
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	return { gui = gui, label = label, holder = holder, busy = false, started = 0 }
end

-- A free slot, or the oldest busy one (recycled), never more than MAX_NUMBERS.
local function acquire(): Number
	local oldest: Number? = nil
	for _, n in pool do
		if not n.busy then
			return n
		end
		if not oldest or n.started < oldest.started then
			oldest = n
		end
	end
	if #pool < MAX_NUMBERS then
		local n = newNumber()
		table.insert(pool, n)
		return n
	end
	return oldest :: Number
end

local function distanceToMe(position: Vector3): number
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then (root.Position - position).Magnitude else math.huge
end

local function highContrast(): boolean
	return Theme.settings.palette == "highContrast"
end

type FloatOpts = { text: string, color: Color3, scale: number, alpha: number, duration: number, pop: number }

-- Floats a text up from `position`, pops it in and fades it out.
local function float(position: Vector3, o: FloatOpts)
	local n = acquire()
	n.busy = true
	local started = os.clock()
	n.started = started
	n.holder.WorldPosition = position + Vector3.new(rng:NextNumber(-0.8, 0.8), rng:NextNumber(0, 0.6), rng:NextNumber(-0.8, 0.8))
	n.holder.Parent = workspace.Terrain
	n.gui.Enabled = true
	n.gui.Size = UDim2.fromOffset(math.floor(220 * o.scale), math.floor(64 * o.scale))
	n.label.Text = o.text
	n.label.TextColor3 = if highContrast() then Color3.new(1, 1, 1) else o.color
	n.label.TextStrokeColor3 = Color3.new(0, 0, 0)
	local drift = rng:NextNumber(-0.6, 0.6)
	FxLayers.animate(o.duration, function(t)
		if n.started ~= started then
			return -- recycled by a newer number
		end
		local pop = if t < 0.12 then 1 + o.pop * (1 - t / 0.12) else 1
		n.gui.StudsOffsetWorldSpace = Vector3.new(drift * t, 1.8 * t + 0.6 * math.sin(t * math.pi), 0)
		n.gui.Size = UDim2.fromOffset(math.floor(220 * o.scale * pop), math.floor(64 * o.scale * pop))
		local fade = if t > 0.6 then (t - 0.6) / 0.4 else 0
		n.label.TextTransparency = 1 - o.alpha + o.alpha * fade
		n.label.TextStrokeTransparency = 0.2 + 0.8 * fade
	end, function()
		if n.started == started then
			n.busy = false
			n.gui.Enabled = false
			n.holder.Parent = nil
		end
	end)
end

local function domainColor(domain: any): Color3
	local def = if typeof(domain) == "string" then Registry.domains[domain] else nil
	return if def then def.feel.palette[1] else Color3.fromRGB(255, 230, 200)
end

-- ─── Screen layer: hit markers and the hurt flash ───────────────────────────

local screen: ScreenGui? = nil
local marker: Frame? = nil
local hurtEdges: { Frame } = {}

local function ensureScreen(): ScreenGui
	if screen and screen.Parent then
		return screen
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "CombatFeedback"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 5
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	screen = gui

	-- Hit marker: four short bars in an X around the aim point.
	local m = Instance.new("Frame")
	m.Name = "HitMarker"
	m.BackgroundTransparency = 1
	m.AnchorPoint = Vector2.new(0.5, 0.5)
	m.Size = UDim2.fromOffset(34, 34)
	m.Visible = false
	m.Parent = gui
	for i = 0, 3 do
		local bar = Instance.new("Frame")
		bar.Name = "Bar"
		bar.BorderSizePixel = 0
		bar.BackgroundColor3 = Color3.new(1, 1, 1)
		bar.AnchorPoint = Vector2.new(0.5, 0.5)
		bar.Size = UDim2.fromOffset(12, 3)
		local angle = math.rad(45 + 90 * i)
		bar.Position = UDim2.new(0.5, math.cos(angle) * 11, 0.5, math.sin(angle) * 11)
		bar.Rotation = 45 + 90 * i
		local stroke = Instance.new("UIStroke")
		stroke.Thickness = 1
		stroke.Color = Color3.new(0, 0, 0)
		stroke.Transparency = 0.4
		stroke.Parent = bar
		bar.Parent = m
	end
	marker = m

	-- Hurt flash: four gradient edges (no image assets needed).
	local sides = {
		{ UDim2.new(1, 0, 0.18, 0), UDim2.fromScale(0, 0), 90 },
		{ UDim2.new(1, 0, 0.18, 0), UDim2.fromScale(0, 0.82), -90 },
		{ UDim2.new(0.12, 0, 1, 0), UDim2.fromScale(0, 0), 0 },
		{ UDim2.new(0.12, 0, 1, 0), UDim2.fromScale(0.88, 0), 180 },
	}
	for _, s in sides do
		local edge = Instance.new("Frame")
		edge.BorderSizePixel = 0
		edge.BackgroundColor3 = Color3.fromRGB(200, 20, 20)
		edge.BackgroundTransparency = 1
		edge.Size = s[1] :: UDim2
		edge.Position = s[2] :: UDim2
		local gradient = Instance.new("UIGradient")
		gradient.Rotation = s[3] :: number
		gradient.Transparency = NumberSequence.new(0, 1)
		gradient.Parent = edge
		edge.Parent = gui
		table.insert(hurtEdges, edge)
	end
	return gui
end

local function aimPoint(): Vector2
	local camera = workspace.CurrentCamera
	if UserInputService.MouseEnabled and not UserInputService.TouchEnabled and UserInputService.MouseBehavior ~= Enum.MouseBehavior.LockCenter then
		return UserInputService:GetMouseLocation()
	end
	return camera.ViewportSize / 2
end

local markerToken = 0

local function showMarker(crit: boolean, killed: boolean)
	ensureScreen()
	local m = marker :: Frame
	markerToken += 1
	local token = markerToken
	local color = if killed then Color3.fromRGB(255, 70, 60) elseif crit then Color3.fromRGB(255, 220, 90) else Color3.new(1, 1, 1)
	for _, bar in m:GetChildren() do
		if bar:IsA("Frame") then
			bar.BackgroundColor3 = color
			bar.Size = UDim2.fromOffset(if killed then 18 elseif crit then 15 else 12, if killed then 4 else 3)
		end
	end
	local at = aimPoint()
	m.Position = UDim2.fromOffset(at.X, at.Y)
	m.Visible = true
	local size = if killed then 46 elseif crit then 40 else 34
	FxLayers.animate(if killed then 0.45 else 0.25, function(t)
		if token ~= markerToken then
			return
		end
		local s = size * (1.25 - 0.25 * math.min(1, t * 4))
		m.Size = UDim2.fromOffset(s, s)
		for _, bar in m:GetChildren() do
			if bar:IsA("Frame") then
				bar.BackgroundTransparency = if t > 0.5 then (t - 0.5) * 2 else 0
			end
		end
	end, function()
		if token == markerToken then
			m.Visible = false
		end
	end)
	-- Your hit landed: a body hit, a heavier one for a crit, a fall for a kill (Combat group).
	Audio.play(if killed then "combat.kill" elseif crit then "combat.crit" else "combat.hit", { fallback = DomainFx.sounds.tick, vary = true })
end

local hurtToken = 0

local function hurtFlash(share: number)
	ensureScreen()
	-- You were hit: the body-hit sound, louder for a bigger share of your health.
	Audio.play("combat.hit", { volume = math.clamp(0.6 + share * 2, 0.6, 1.4), vary = true })
	hurtToken += 1
	local token = hurtToken
	local peak = math.clamp(0.35 + share * 2, 0.35, 0.85)
	FxLayers.animate(0.45 + share, function(t)
		if token ~= hurtToken then
			return
		end
		for _, edge in hurtEdges do
			edge.BackgroundTransparency = 1 - peak * (1 - t)
		end
	end)
end

-- ─── Hit-stop: a short FOV punch (the camera "catches" on a heavy hit) ──────

local punching = false

local function hitStop(strength: number)
	if Theme.settings.reducedMotion or Theme.settings.reducedEffects or punching then
		return
	end
	local camera = workspace.CurrentCamera
	local base = camera.FieldOfView
	punching = true
	FxLayers.animate(0.14, function(t)
		local k = if t < 0.25 then t / 0.25 else 1 - (t - 0.25) / 0.75
		camera.FieldOfView = base - strength * k
	end, function()
		camera.FieldOfView = base
		punching = false
	end)
end

-- ─── Cue handlers ───────────────────────────────────────────────────────────

local shakeFn: ((number, number) -> ())? = nil

-- SpellFx.shake, injected by WorldEffectController (avoids a require cycle).
function CombatFeedback.setShake(fn: (number, number) -> ())
	shakeFn = fn
end

function CombatFeedback.hit(cue: { [string]: any })
	local position = cue.position
	if typeof(position) ~= "Vector3" then
		return
	end
	local me = localPlayer.UserId
	local mine = cue.caster == me and cue.victim ~= me
	local onMe = cue.victim == me
	local amount = if typeof(cue.amount) == "number" then cue.amount else 0
	local crit, killed, dot = cue.crit == true, cue.killed == true, cue.dot == true
	local share = if typeof(cue.share) == "number" then cue.share else 0

	if Theme.settings.damageNumbers and (mine or onMe or (cue.lod == 2 and distanceToMe(position) <= NUMBER_RANGE)) then
		local color = if dot then (DOT_COLORS[cue.kind] or domainColor(cue.domain)) else domainColor(cue.domain)
		if crit then
			color = FxLayers.whiten(color, 0.35)
		end
		local text = tostring(amount) .. (if crit then "!" else "") .. (if killed then " ✕" else "")
		local scale = (if dot then 0.6 elseif crit then 1.25 else 0.9) * (if mine or onMe then 1 else 0.75)
		float(position, {
			text = text,
			color = color,
			scale = scale + math.min(0.4, share),
			alpha = if mine or onMe then 1 else 0.75,
			duration = if crit or killed then 1.1 else 0.85,
			pop = if crit then 0.6 elseif dot then 0.1 else 0.3,
		})
	end
	if mine and not dot and Theme.settings.damageNumbers then
		showMarker(crit, killed)
	end
	if mine and (cue.heavy or killed or crit) and not dot then
		hitStop(if killed then 4 elseif cue.heavy then 3 else 1.5)
		if shakeFn then
			shakeFn(if killed then 0.35 else 0.2, 0.15)
		end
	end
	if onMe then
		hurtFlash(share)
		if shakeFn and not dot then
			shakeFn(math.clamp(share * 2, 0.15, 0.9), 0.25)
		end
	end
end

function CombatFeedback.heal(cue: { [string]: any })
	local position = cue.position
	if typeof(position) ~= "Vector3" or not Theme.settings.damageNumbers then
		return
	end
	local me = localPlayer.UserId
	local mineOrMe = cue.caster == me or cue.victim == me
	if not mineOrMe and (cue.lod ~= 2 or distanceToMe(position) > NUMBER_RANGE) then
		return
	end
	float(position, {
		text = "+" .. tostring(cue.amount or 0),
		color = HEAL,
		scale = if mineOrMe then 0.9 else 0.7,
		alpha = if mineOrMe then 1 else 0.75,
		duration = 0.9,
		pop = 0.25,
	})
end

function CombatFeedback.statusTag(cue: { [string]: any })
	local position = cue.position
	if typeof(position) ~= "Vector3" or not Theme.settings.damageNumbers then
		return
	end
	if cue.lod ~= 2 or distanceToMe(position) > STATUS_RANGE then
		return
	end
	local harmful = cue.harmful == true
	float(position + Vector3.new(0, 1, 0), {
		text = (if harmful then "▼ " else "▲ ") .. tostring(cue.name or cue.status),
		color = if harmful then HARMFUL_STATUS else HELPFUL_STATUS,
		scale = 0.6,
		alpha = 0.95,
		duration = 1.3,
		pop = 0.15,
	})
end

return CombatFeedback
