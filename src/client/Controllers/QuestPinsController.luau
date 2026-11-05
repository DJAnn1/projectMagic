--!strict
--[[
	QuestPinsController: map pins for quest objectives, drawn in the world (docs/Quests.md §6).
	There is no map screen yet, so the "map" is the world itself:

		marker   a beacon over every open objective: ◆ for the tracked quest, ◇ for others,
		         ▼ over a person. Shows the distance; the objective's text shows for the tracked
		         quest, and for any pin within TEXT_RANGE. Never colour alone: glyph + words.
		arrow    when the tracked quest's nearest pin is off-screen (or behind you), an arrow on
		         the screen edge points to it, with the distance.
	Data: MagicStateController.questPins (QuestPins pushes from QuestDirector: only your quests,
	only steps you can act on now; people pins move with the NPC). The Journal's Track button
	picks the tracked quest; a newly started quest is tracked when nothing else is.
	Setting: Quest markers (On/Off). Reduce motion stops the tracked marker's pulse.
	Budget: at most 10 pins (server cap); one RenderStepped at 10 Hz for labels and the arrow.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local UI = script.Parent.Parent:WaitForChild("UI")
local Theme = require(UI.Theme)

local TEXT_RANGE = 80 -- studs: untracked pins show their objective text this close
local UNTRACKED_RANGE = 900 -- studs: untracked pins vanish beyond this
local REACHED = 8 -- studs: a place pin this close fades (you're there)
local EDGE_MARGIN = 56 -- pixels from the screen edge for the arrow

local QuestPinsController = {
	name = "QuestPinsController",
	dependencies = { "MagicStateController" },
}

local magic: any = nil
local localPlayer = Players.LocalPlayer

type Marker = {
	holder: Attachment,
	gui: BillboardGui,
	glyph: TextLabel,
	label: TextLabel,
	pin: any,
}

local markers: { Marker } = {}
local arrowGui: ScreenGui? = nil
local arrow: TextLabel? = nil
local arrowText: TextLabel? = nil

-- Read from the settings Value itself: an observer here may run before Theme.apply does.
local function markersOn(): boolean
	return magic.settings:get().questMarkers ~= false
end

local function playerGui(): PlayerGui
	return localPlayer:WaitForChild("PlayerGui") :: PlayerGui
end

local function clearMarkers()
	for _, m in markers do
		m.gui:Destroy()
		m.holder:Destroy()
	end
	table.clear(markers)
end

local function makeMarker(pin: any): Marker
	local holder = Instance.new("Attachment")
	holder.Name = "QuestPin"
	holder.WorldPosition = pin.p + Vector3.new(0, if pin.person then 3 else 5, 0)
	holder.Parent = workspace.Terrain

	local gui = Instance.new("BillboardGui")
	gui.Name = "QuestPin"
	gui.Adornee = holder
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false -- straight under PlayerGui: survives respawns
	gui.Size = UDim2.fromOffset(220, 72)
	gui.MaxDistance = if pin.tracked then math.huge else UNTRACKED_RANGE
	gui.Parent = playerGui()

	local color = if pin.tracked then Theme.color.accent else Theme.color.inkDim
	local glyph = Instance.new("TextLabel")
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.new(1, 0, 0, 30)
	glyph.Font = Enum.Font.GothamBlack
	glyph.TextScaled = true
	glyph.TextColor3 = color
	glyph.TextStrokeTransparency = 0.3
	glyph.Text = if pin.person then "▼" elseif pin.tracked then "◆" else "◇"
	glyph.Parent = gui

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(0, 30)
	label.Size = UDim2.new(1, 0, 0, 40)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 14
	label.TextWrapped = true
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.35
	label.Parent = gui

	return { holder = holder, gui = gui, glyph = glyph, label = label, pin = pin }
end

local function rebuild(pins: { any })
	clearMarkers()
	if not markersOn() then
		return
	end
	for _, pin in pins do
		if typeof(pin) == "table" and typeof(pin.p) == "Vector3" then
			table.insert(markers, makeMarker(pin))
		end
	end
end

local function ensureArrow()
	if arrowGui and arrowGui.Parent then
		return
	end
	local gui = Instance.new("ScreenGui")
	gui.Name = "QuestArrow"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 4
	gui.Parent = playerGui()
	arrowGui = gui
	local a = Instance.new("TextLabel")
	a.BackgroundTransparency = 1
	a.AnchorPoint = Vector2.new(0.5, 0.5)
	a.Size = UDim2.fromOffset(40, 40)
	a.Font = Enum.Font.GothamBlack
	a.TextScaled = true
	a.Text = "➤"
	a.TextColor3 = Theme.color.accent
	a.TextStrokeTransparency = 0.2
	a.Visible = false
	a.Parent = gui
	arrow = a
	local t = Instance.new("TextLabel")
	t.BackgroundTransparency = 1
	t.AnchorPoint = Vector2.new(0.5, 0)
	t.Size = UDim2.fromOffset(120, 20)
	t.Font = Enum.Font.GothamMedium
	t.TextSize = 14
	t.TextColor3 = Color3.new(1, 1, 1)
	t.TextStrokeTransparency = 0.3
	t.Visible = false
	t.Parent = gui
	arrowText = t
end

local function distanceText(d: number): string
	return if d >= 1000 then string.format("%.1fk studs", d / 1000) else string.format("%d studs", math.floor(d))
end

local function update()
	local character = localPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local camera = workspace.CurrentCamera
	if not root or not root:IsA("BasePart") or not camera then
		return
	end
	local here = root.Position
	local pulse = if Theme.settings.reducedMotion then 0 else math.sin(os.clock() * 4) * 0.15
	local nearestTracked: Marker? = nil
	local nearestD = math.huge
	for _, m in markers do
		local d = (m.holder.WorldPosition - here).Magnitude
		local close = d <= TEXT_RANGE
		local reached = not m.pin.person and d <= REACHED
		m.gui.Enabled = not reached
		m.label.Text = if m.pin.tracked or close then string.format("%s\n%s", m.pin.text, distanceText(d)) else distanceText(d)
		if m.pin.tracked then
			m.glyph.TextTransparency = pulse + 0.15
			if d < nearestD then
				nearestTracked, nearestD = m, d
			end
		end
	end

	-- The edge arrow, for the tracked quest's nearest pin when you can't see it.
	ensureArrow()
	local a, t = arrow :: TextLabel, arrowText :: TextLabel
	if not nearestTracked or not markersOn() then
		a.Visible, t.Visible = false, false
		return
	end
	local target = (nearestTracked :: Marker).holder.WorldPosition
	local screen, onScreen = camera:WorldToViewportPoint(target)
	local view = camera.ViewportSize
	if onScreen and screen.Z > 0 then
		a.Visible, t.Visible = false, false
		return
	end
	-- Direction on screen from the centre; behind the camera, flip it.
	local center = view / 2
	local dir = Vector2.new(screen.X, screen.Y) - center
	if screen.Z < 0 then
		dir = -dir
	end
	if dir.Magnitude < 1 then
		dir = Vector2.new(0, -1)
	end
	dir = dir.Unit
	local halfW, halfH = center.X - EDGE_MARGIN, center.Y - EDGE_MARGIN
	local scale = math.min(halfW / math.max(math.abs(dir.X), 1e-3), halfH / math.max(math.abs(dir.Y), 1e-3))
	local pos = center + dir * scale
	a.Position = UDim2.fromOffset(pos.X, pos.Y)
	a.Rotation = math.deg(math.atan2(dir.Y, dir.X))
	t.Position = UDim2.fromOffset(pos.X, pos.Y + 22)
	t.Text = distanceText(nearestD)
	a.Visible, t.Visible = true, true
end

function QuestPinsController.init(_self: any, ctx: any)
	magic = ctx.get("MagicStateController")
end

function QuestPinsController.start(_self: any, _ctx: any)
	magic.questPins:observe(rebuild)
	-- The setting can change any time: rebuild when it does.
	magic.settings:observe(function()
		rebuild(magic.questPins:get())
	end)
	local acc = 0
	RunService.RenderStepped:Connect(function(dt)
		acc += dt
		if acc < 0.1 then
			return
		end
		acc = 0
		if #markers == 0 and not (arrow and arrow.Visible) then
			return
		end
		local ok = pcall(update)
		if not ok and arrow then
			arrow.Visible = false
		end
	end)
end

return QuestPinsController
