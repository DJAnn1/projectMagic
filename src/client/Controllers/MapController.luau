--!strict
--[[
	MapController: the map screen (M) (docs/Map.md). The server decides what you've uncovered
	(Services/MapService); this draws it.

		canvas    The island, drawn as one frame per run of same-coloured cells in a row, so it's hundreds of
		          frames, not thousands. Dark where you haven't been.
		pins      You (an arrow turning with your camera), places you've found, your quests, your house,
		          your party, a shared event, and your waypoint. Every pin is a glyph with words: colour
		          is never the only cue.
		zoom      The buttons or the mouse wheel. Zoomed in, it stays centred on you.
		waypoint  Click the map or a place on the list. Click near it again to clear it. QuestPinsController
		          draws it in the world, with an arrow to it, and clears it when you arrive.

	Budget: the frames exist only while the screen is open, and pins redraw twice a second.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Controls = require(Shared.UI.Controls)
local MapData = require(Shared.World.MapData)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

local PIN_REFRESH = 0.5
local ZOOMS = { 1, 2, 4 }
local CLEAR_RADIUS = 80 -- studs: clicking this near your waypoint clears it
local FOG = Color3.fromRGB(20, 18, 28)

local MapController = {
	name = "MapController",
	dependencies = { "InterfaceController", "MagicStateController", "HousingController", "SharedEventController", "PartyController" },
}

local interface: any = nil
local magic: any = nil
local housing: any = nil
local events: any = nil
local party: any = nil
local localPlayer = Players.LocalPlayer

-- Where you've chosen to go, or nil. QuestPinsController draws it in the world.
MapController.waypoint = Kit.value(nil :: Vector3?)

local cells: { string } = {}
local pois: { [string]: MapData.KnownPoi } = {}
local revision = Kit.value(0) -- bumps when new ground comes in, so an open map redraws
local zoomIndex = 1

local function rootOf(): BasePart?
	local root = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function distanceText(d: number): string
	return if d >= 1000 then string.format("%.1fk studs", d / 1000) else string.format("%d studs", math.floor(d))
end

local function setWaypoint(x: number, z: number)
	local root = rootOf()
	local y = if root then root.Position.Y else 60
	MapController.waypoint:set(Vector3.new(x, y, z))
	C.sound("confirm")
end

-- ─── Getting the data ───────────────────────────────────────────────────────

local function setPois(list: any)
	if typeof(list) ~= "table" then
		return
	end
	for _, poi in list do
		if typeof(poi) == "table" and typeof(poi.id) == "string" then
			pois[poi.id] = poi
		end
	end
end

local function load(): boolean
	local ok, view = Net.invoke("RequestMap")
	if not ok or typeof(view) ~= "table" or typeof(view.cells) ~= "string" then
		return false
	end
	local grid: string = view.cells
	cells = table.create(#grid)
	for i = 1, #grid do
		cells[i] = string.sub(grid, i, i)
	end
	setPois(view.pois)
	revision:set(revision:get() + 1)
	return true
end

local function onReveal(update: any)
	if typeof(update) ~= "table" or typeof(update.cells) ~= "table" then
		return
	end
	local list = update.cells
	for i = 1, #list, 2 do
		local index, code = list[i], list[i + 1]
		if typeof(index) == "number" and typeof(code) == "string" then
			cells[index + 1] = code
		end
	end
	setPois(update.pois)
	revision:set(revision:get() + 1)
end

-- ─── Drawing ────────────────────────────────────────────────────────────────

local function drawGround(canvas: Frame)
	local cols = MapData.cols
	local unit = 1 / cols
	for row = 0, cols - 1 do
		local start = 0
		while start < cols do
			local code = cells[row * cols + start + 1] or MapData.unknown
			local stop = start + 1
			while stop < cols and (cells[row * cols + stop + 1] or MapData.unknown) == code do
				stop += 1
			end
			local color = MapData.colorOf(code)
			if color then
				Kit.create(nil, "Frame", {
					BackgroundColor3 = color,
					BorderSizePixel = 0,
					Position = UDim2.fromScale(start * unit, row * unit),
					Size = UDim2.fromScale((stop - start) * unit, unit),
					Parent = canvas,
				})
			end
			start = stop
		end
	end
end

local function pinLabel(parent: Instance, u: number, v: number, glyph: string, text: string?, color: Color3, order: number)
	local holder: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(u, v),
		Size = UDim2.fromOffset(150, 34),
		ZIndex = order,
		Parent = parent,
	})
	Kit.create(nil, "TextLabel", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, 18),
		Font = Enum.Font.GothamBlack,
		TextSize = 16,
		TextColor3 = color,
		TextStrokeTransparency = 0.25,
		Text = glyph,
		ZIndex = order,
		Parent = holder,
	})
	if text then
		Kit.create(nil, "TextLabel", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, 17),
			Size = UDim2.new(1, 0, 0, 15),
			Font = Enum.Font.GothamMedium,
			TextSize = 12,
			TextColor3 = Color3.new(1, 1, 1),
			TextStrokeTransparency = 0.25,
			Text = text,
			ZIndex = order,
			Parent = holder,
		})
	end
end

-- Everything that moves or changes: redrawn twice a second.
local function drawPins(layer: Frame)
	layer:ClearAllChildren()
	for _, poi in pois do
		local style = MapData.poiStyle(poi.type)
		local u, v = MapData.toMap(poi.x, poi.z)
		pinLabel(layer, u, v, style.glyph, poi.name, Theme.color.ink, 2)
	end
	for _, pin in (magic.questPins:get() or {}) :: { any } do
		if typeof(pin) == "table" and typeof(pin.p) == "Vector3" then
			local u, v = MapData.toMap(pin.p.X, pin.p.Z)
			pinLabel(layer, u, v, if pin.tracked then "◆" else "◇", if pin.tracked then "Quest" else nil, Theme.color.accent, 3)
		end
	end
	local home = housing.state:get()
	if typeof(home) == "table" and typeof(home.home) == "Vector3" then
		local u, v = MapData.toMap(home.home.X, home.home.Z)
		pinLabel(layer, u, v, "⌂", "Home", Theme.color.good, 3)
	end
	local event = events.view:get()
	if typeof(event.x) == "number" and typeof(event.z) == "number" and (event.phase == "warning" or event.phase == "fight") then
		local u, v = MapData.toMap(event.x, event.z)
		pinLabel(layer, u, v, "✦", tostring(event.name), Theme.color.warn, 4)
	end
	for _, member in (party.state:get().members or {}) :: { any } do
		local vital = party.vitals:get()[member.u]
		if vital and member.u ~= localPlayer.UserId and typeof(vital.x) == "number" and typeof(vital.z) == "number" then
			local u, v = MapData.toMap(vital.x, vital.z)
			pinLabel(layer, u, v, "●", tostring(member.name), Theme.color.good, 4)
		end
	end
	local waypoint = MapController.waypoint:get()
	if waypoint then
		local u, v = MapData.toMap(waypoint.X, waypoint.Z)
		pinLabel(layer, u, v, "✚", "Waypoint", Theme.color.accent, 5)
	end
end

local function buildScreen(scope: Kit.Scope, container: Frame)
	local compact = interface.layout:get() == "Compact"
	local sideWidth = if compact then 0 else 280

	-- The view: a square that fits, clipping the canvas when you zoom.
	local view: Frame = Kit.create(nil, "Frame", {
		Name = "MapView",
		BackgroundColor3 = FOG,
		BorderSizePixel = 0,
		ClipsDescendants = true,
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.fromScale(0, 0.5),
		Size = UDim2.new(1, -sideWidth - Theme.space.m, 1, 0),
		Parent = container,
	})
	Kit.create(nil, "UIAspectRatioConstraint", { AspectRatio = 1, Parent = view })
	C.stroke(Theme.color.line, 2).Parent = view

	local canvas: Frame = Kit.create(nil, "Frame", {
		Name = "Canvas",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = view,
	})

	Kit.dynamic(scope, { revision }, function(s)
		local ground: Frame = Kit.create(nil, "Frame", { Name = "Ground", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = canvas })
		s:add(ground)
		drawGround(ground)
	end)

	local pins: Frame = Kit.create(nil, "Frame", { Name = "Pins", BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), ZIndex = 2, Parent = canvas })
	local you: TextLabel = Kit.create(nil, "TextLabel", {
		Name = "You",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Size = UDim2.fromOffset(24, 24),
		Font = Enum.Font.GothamBlack,
		TextSize = 22,
		TextColor3 = Color3.new(1, 1, 1),
		TextStrokeTransparency = 0,
		Text = "➤",
		ZIndex = 10,
		Parent = canvas,
	})

	local function applyZoom()
		local zoom = ZOOMS[zoomIndex]
		canvas.Size = UDim2.fromScale(zoom, zoom)
		local root = rootOf()
		if not root then
			return
		end
		local u, v = MapData.toMap(root.Position.X, root.Position.Z)
		local maxOffset = zoom - 1
		canvas.Position = UDim2.fromScale(-math.clamp(u * zoom - 0.5, 0, maxOffset), -math.clamp(v * zoom - 0.5, 0, maxOffset))
		you.Position = UDim2.fromScale(u, v)
		local camera = workspace.CurrentCamera
		if camera then
			local look = camera.CFrame.LookVector
			you.Rotation = math.deg(math.atan2(look.Z, look.X))
		end
	end

	-- Clicking the map sets a waypoint, or clears it if you click near it.
	local clicks: TextButton = Kit.create(nil, "TextButton", {
		Name = "Clicks",
		BackgroundTransparency = 1,
		Text = "",
		AutoButtonColor = false,
		Size = UDim2.fromScale(1, 1),
		ZIndex = 20,
		Parent = canvas,
	})
	scope:add(clicks.Activated:Connect(function(input: InputObject)
		local size = canvas.AbsoluteSize
		if size.X < 1 or size.Y < 1 then
			return
		end
		local x, z = MapData.fromMap((input.Position.X - canvas.AbsolutePosition.X) / size.X, (input.Position.Y - canvas.AbsolutePosition.Y) / size.Y)
		local current = MapController.waypoint:get()
		if current and Vector3.new(current.X - x, 0, current.Z - z).Magnitude <= CLEAR_RADIUS then
			MapController.waypoint:set(nil)
		else
			setWaypoint(x, z)
		end
		drawPins(pins)
	end))
	scope:add(clicks.MouseWheelForward:Connect(function()
		zoomIndex = math.min(#ZOOMS, zoomIndex + 1)
		applyZoom()
	end))
	scope:add(clicks.MouseWheelBackward:Connect(function()
		zoomIndex = math.max(1, zoomIndex - 1)
		applyZoom()
	end))

	-- The side: zoom, your waypoint, the places you've found.
	local side: Frame = Kit.create(nil, "Frame", {
		Name = "Side",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = if compact then UDim2.fromOffset(Theme.minTouch * 3, 0) else UDim2.new(0, sideWidth, 1, 0),
		AutomaticSize = if compact then Enum.AutomaticSize.Y else Enum.AutomaticSize.None,
		ZIndex = 30,
		Parent = container,
	})
	C.list("y", Theme.space.s).Parent = side

	local zoomRow: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, Theme.minTouch), LayoutOrder = 1, Parent = side })
	C.list("x", Theme.space.xs).Parent = zoomRow
	C.button("−", function()
		zoomIndex = math.max(1, zoomIndex - 1)
		applyZoom()
	end, { kind = "ghost" }, { Size = UDim2.fromOffset(Theme.minTouch, Theme.minTouch), LayoutOrder = 1 }).Parent = zoomRow
	C.button("+", function()
		zoomIndex = math.min(#ZOOMS, zoomIndex + 1)
		applyZoom()
	end, { kind = "ghost" }, { Size = UDim2.fromOffset(Theme.minTouch, Theme.minTouch), LayoutOrder = 2 }).Parent = zoomRow

	if not compact then
		local status = C.text("", "caption", { LayoutOrder = 2, Parent = side })
		C.text("Click the map to set a waypoint. Click near it again to clear it.", "caption", { LayoutOrder = 3, Parent = side })
		C.text("Places you've found", "heading", { LayoutOrder = 4, Parent = side })
		local list = C.scroll({ Size = UDim2.new(1, 0, 1, -190), LayoutOrder = 5, Parent = side })
		C.list("y", Theme.space.xs).Parent = list

		Kit.dynamic(scope, { revision }, function(s)
			local root = rootOf()
			local here = if root then root.Position else Vector3.zero
			local sorted: { MapData.KnownPoi } = {}
			for _, poi in pois do
				table.insert(sorted, poi)
			end
			table.sort(sorted, function(a, b)
				return (a.x - here.X) ^ 2 + (a.z - here.Z) ^ 2 < (b.x - here.X) ^ 2 + (b.z - here.Z) ^ 2
			end)
			if #sorted == 0 then
				local nothing = C.text("Nothing yet. Go exploring.", "caption", { Parent = list })
				s:add(nothing)
			end
			for i, poi in sorted do
				local style = MapData.poiStyle(poi.type)
				local distance = Vector3.new(poi.x - here.X, 0, poi.z - here.Z).Magnitude
				local button = C.button(string.format("%s %s · %s", style.glyph, poi.name or style.label, distanceText(distance)), function()
					setWaypoint(poi.x, poi.z)
					drawPins(pins)
				end, { kind = "ghost" }, { Size = UDim2.new(1, -Theme.space.s, 0, Theme.minTouch), LayoutOrder = i, Parent = list })
				s:add(button)
			end
		end)

		local elapsed = PIN_REFRESH
		scope:add(RunService.Heartbeat:Connect(function(dt)
			elapsed += dt
			if elapsed < PIN_REFRESH then
				return
			end
			elapsed = 0
			local waypoint = MapController.waypoint:get()
			local root = rootOf()
			status.Text = if waypoint and root
				then string.format("✚ Waypoint: %s away", distanceText(Vector3.new(waypoint.X - root.Position.X, 0, waypoint.Z - root.Position.Z).Magnitude))
				else "No waypoint set"
		end))
	end

	applyZoom()
	drawPins(pins)
	local acc = 0
	scope:add(RunService.Heartbeat:Connect(function(dt)
		acc += dt
		applyZoom()
		if acc >= PIN_REFRESH then
			acc = 0
			drawPins(pins)
		end
	end))
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function MapController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	housing = ctx.get("HousingController")
	events = ctx.get("SharedEventController")
	party = ctx.get("PartyController")
	interface:registerScreen({
		id = "Map",
		title = "Map",
		order = 15,
		key = Controls.key("open_map", "keyboard"),
		build = buildScreen,
	})
end

function MapController.start(_self: any, _ctx: any)
	Net.listen("MapReveal", onReveal)
	-- The world may still be generating on the first ask.
	task.spawn(function()
		while not load() do
			task.wait(3)
		end
	end)
end

return MapController
