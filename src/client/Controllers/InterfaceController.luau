--!strict
--[[
	InterfaceController: owns the GUI roots, responsive scaling, input-mode detection, the screen
	stack and keybinds. Feature controllers register with it in :init; it builds them in :start.

		registerScreen(def)   a full-screen page (Grimoire, Composer, Settings...). One open at a time.
		registerLayer(def)    an always-on layer (the HUD)
		open(id, args?) / close() / toggle(id)
		isInputBlocked()      true while a screen, the console or a text box has the keyboard
		hint(screenId)        the key to show for a screen: "G" / "Y" / "" (touch shows buttons instead)

	Values: layout ("Wide" | "Compact"), inputMode ("Keyboard" | "Gamepad" | "Touch"), openScreen.

	Responsiveness: every root has a UIScale computed from the viewport against a reference size
	(1280x720 Wide, 760x400 Compact). Layout switches to Compact on small viewports (phones),
	where screens go full-bleed and the HUD moves into thumb reach (docs/UI.md §7).
	Rebuild-on-change: a layout, input-mode or settings change rebuilds the HUD and the open
	screen from scratch. These changes are rare, and it keeps every builder simple.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Topics = require(Shared.Core.Topics)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local UISettings = require(Shared.UI.Settings)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

export type ScreenDef = {
	id: string,
	title: string,
	order: number,
	key: Enum.KeyCode?,
	gamepadKey: Enum.KeyCode?,
	hidden: boolean?, -- opened by the game (a container, a station), not from the tab bar
	build: (scope: Kit.Scope, container: Frame, args: any?) -> (),
}

export type LayerDef = {
	id: string,
	build: (scope: Kit.Scope, root: Frame) -> (),
}

local WIDE_REFERENCE = Vector2.new(1280, 720)
local COMPACT_REFERENCE = Vector2.new(760, 400)
local HEADER_HEIGHT = 56

local InterfaceController = {
	name = "InterfaceController",
	dependencies = { "MagicStateController" },
}

local I = InterfaceController
I.layout = Kit.value("Wide")
I.inputMode = Kit.value("Keyboard")
I.openScreen = Kit.value(nil :: string?)

local bus: any = nil
local magic: any = nil
local screens: { [string]: ScreenDef } = {}
local layers: { LayerDef } = {}
local screenArgs: any = nil

local hudRoot: Frame? = nil
local screenRoot: Frame? = nil
local scales: { UIScale } = {}
local layerScope: Kit.Scope? = nil
local screenScope: Kit.Scope? = nil

-- ─── Registration ───────────────────────────────────────────────────────────

function I.registerScreen(_self: any, def: ScreenDef)
	assert(screens[def.id] == nil, "duplicate screen " .. def.id)
	screens[def.id] = def
end

function I.registerLayer(_self: any, def: LayerDef)
	table.insert(layers, def)
end

-- ─── Input ──────────────────────────────────────────────────────────────────

local function modeFor(inputType: Enum.UserInputType): string?
	if inputType == Enum.UserInputType.Touch then
		return "Touch"
	elseif string.sub(inputType.Name, 1, 7) == "Gamepad" then
		return "Gamepad"
	elseif inputType == Enum.UserInputType.Keyboard or string.sub(inputType.Name, 1, 5) == "Mouse" then
		return "Keyboard"
	end
	return nil
end

local DIGITS: { [string]: string } = {
	One = "1", Two = "2", Three = "3", Four = "4", Five = "5",
	Six = "6", Seven = "7", Eight = "8", Nine = "9", Zero = "0",
}

-- Short display name for a key: One -> "1", ButtonY -> "Y", DPadLeft -> "D-Left".
function I.keyName(_self: any, keyCode: Enum.KeyCode): string
	local name = keyCode.Name
	if DIGITS[name] then
		return DIGITS[name]
	elseif string.sub(name, 1, 6) == "Button" then
		return string.sub(name, 7)
	elseif string.sub(name, 1, 4) == "DPad" then
		return "D-" .. string.sub(name, 5)
	end
	return name
end

function I.hint(self: any, screenId: string): string
	local def = screens[screenId]
	local mode = I.inputMode:get()
	if not def or mode == "Touch" then
		return ""
	end
	local key = if mode == "Gamepad" then def.gamepadKey else def.key
	return if key then self:keyName(key) else ""
end

-- The Admin Panel (admins only, not a controller) marks itself open with a local attribute.
local function adminPanelOpen(): boolean
	return Players.LocalPlayer:GetAttribute("AdminPanelOpen") == true
end

function I.isInputBlocked(_self: any): boolean
	return adminPanelOpen() or I.openScreen:get() ~= nil or UserInputService:GetFocusedTextBox() ~= nil
end

-- ─── Open / close ───────────────────────────────────────────────────────────

local function renderScreen()
	if screenScope then
		screenScope:destroy()
		screenScope = nil
	end
	local root = screenRoot
	local id = I.openScreen:get()
	local def = id and screens[id]
	if not root or not def then
		return
	end
	local scope = Kit.scope()
	screenScope = scope
	local compact = I.layout:get() == "Compact"

	-- Backdrop: dims the world and, being Modal, frees the mouse even in first person.
	local backdrop: TextButton = Kit.create(nil, "TextButton", {
		Name = "Backdrop",
		Text = "",
		AutoButtonColor = false,
		Modal = true,
		Selectable = false,
		BackgroundColor3 = Theme.color.backdrop,
		BackgroundTransparency = 0.35,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = root,
	})
	scope:add(backdrop)

	local panel: Frame = Kit.create(nil, "Frame", {
		Name = def.id,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = if compact then UDim2.fromScale(1, 1) else UDim2.fromScale(0.94, 0.92),
		BackgroundColor3 = Theme.color.bg,
		BorderSizePixel = 0,
		Parent = backdrop,
	})
	if not compact then
		C.sizeLimit(1200, 780).Parent = panel
		C.corner(Theme.radius.l).Parent = panel
		C.stroke(Theme.color.line, 2).Parent = panel
	end

	-- Header: one tab per registered screen, then the close button.
	local header: Frame = Kit.create(nil, "Frame", {
		Name = "Header",
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, HEADER_HEIGHT),
		Parent = panel,
	})
	C.padding(Theme.space.s).Parent = header
	local tabs: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -(Theme.minTouch + Theme.space.s), 1, 0),
		Parent = header,
	})
	C.list("x", Theme.space.s, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = tabs

	local ordered: { ScreenDef } = {}
	for _, s in screens do
		if not s.hidden or s.id == def.id then
			table.insert(ordered, s)
		end
	end
	table.sort(ordered, function(a, b)
		return a.order < b.order
	end)
	for index, s in ordered do
		local hint = I:hint(s.id)
		local label = if hint ~= "" and not compact then string.format("%s  [%s]", s.title, hint) else s.title
		local tab = C.button(label, function()
			I:open(s.id)
		end, { kind = "ghost", selected = s.id == def.id }, {
			Size = UDim2.new(0, 0, 1, 0),
			AutomaticSize = Enum.AutomaticSize.X,
			LayoutOrder = index,
		})
		C.padding(0, Theme.space.m).Parent = tab
		tab.Parent = tabs
	end

	local closeButton = C.button("✕", function()
		I:close()
	end, { kind = "ghost", sound = "close" }, {
		AnchorPoint = Vector2.new(1, 0.5),
		Position = UDim2.fromScale(1, 0.5),
		Size = UDim2.fromOffset(Theme.minTouch, Theme.minTouch),
		Parent = header,
	})
	closeButton.Name = "Close"

	local content: Frame = Kit.create(nil, "Frame", {
		Name = "Content",
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, HEADER_HEIGHT),
		Size = UDim2.new(1, 0, 1, -HEADER_HEIGHT),
		ClipsDescendants = true,
		Parent = panel,
	})
	C.padding(if compact then Theme.space.s else Theme.space.l).Parent = content

	def.build(scope, content, screenArgs)

	if I.inputMode:get() == "Gamepad" then
		pcall(function()
			GuiService:Select(content)
		end)
	end
end

function I.open(_self: any, id: string, args: any?)
	if not screens[id] then
		return
	end
	screenArgs = args
	if I.openScreen:get() == id then
		renderScreen() -- same screen, new arguments (e.g. Composer opened from the Grimoire)
	else
		C.sound("open")
		I.openScreen:set(id)
	end
end

function I.close(_self: any)
	if I.openScreen:get() ~= nil then
		C.sound("close")
		screenArgs = nil
		I.openScreen:set(nil)
		GuiService.SelectedObject = nil
	end
end

function I.toggle(self: any, id: string)
	if I.openScreen:get() == id then
		self:close()
	else
		self:open(id)
	end
end

-- ─── Roots, scale and rebuilds ──────────────────────────────────────────────

local function renderLayers()
	if layerScope then
		layerScope:destroy()
		layerScope = nil
	end
	local root = hudRoot
	if not root then
		return
	end
	local scope = Kit.scope()
	layerScope = scope
	for _, layer in layers do
		local frame: Frame = Kit.create(nil, "Frame", {
			Name = layer.id,
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Parent = root,
		})
		scope:add(frame)
		layer.build(scope, frame)
	end
end

local function rebuildAll()
	renderLayers()
	renderScreen()
end

local function makeRoot(name: string, order: number, insets: Enum.ScreenInsets): Frame
	local gui: ScreenGui = Kit.create(nil, "ScreenGui", {
		Name = name,
		ResetOnSpawn = false,
		DisplayOrder = order,
		ScreenInsets = insets,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	local root: Frame = Kit.create(nil, "Frame", {
		Name = "Root",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	local scale: UIScale = Kit.create(nil, "UIScale", { Parent = root })
	table.insert(scales, scale)
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	return root
end

-- UIScale scales the root too, so the root is sized 1/scale to still fill the screen exactly.
local function measure()
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local viewport = camera.ViewportSize
	if viewport.X < 1 or viewport.Y < 1 then
		return
	end
	local compact = viewport.Y < 520 or viewport.X < 760
	local reference = if compact then COMPACT_REFERENCE else WIDE_REFERENCE
	local scale = math.clamp(math.min(viewport.X / reference.X, viewport.Y / reference.Y), 0.7, 1.6)
	for _, uiScale in scales do
		uiScale.Scale = scale
		local root = uiScale.Parent :: Frame
		root.Size = UDim2.fromScale(1 / scale, 1 / scale)
	end
	I.layout:set(if compact then "Compact" else "Wide")
end

-- ─── Settings screen (generated from Shared/UI/Settings) ────────────────────

local function buildSettings(_scope: Kit.Scope, container: Frame)
	local scroll = C.scroll({ Parent = container })
	C.list("y", Theme.space.l).Parent = scroll
	C.padding(Theme.space.xs).Parent = scroll

	local ids: { string } = {}
	for id in UISettings do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		return UISettings[a].order < UISettings[b].order
	end)

	local current = magic.settings:get()
	for index, id in ids do
		local def = UISettings[id]
		local block: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = index,
			Parent = scroll,
		})
		C.list("y", Theme.space.xs).Parent = block
		C.text(def.label, "heading", { LayoutOrder = 1 }).Parent = block
		C.text(def.description, "caption", { LayoutOrder = 2 }).Parent = block
		local row: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 3,
			Parent = block,
		})
		C.list("x", Theme.space.s, { Wraps = true }).Parent = row
		local value = current[id]
		if value == nil then
			value = def.default
		end
		for optionIndex, option in def.options do
			local button = C.button(def.labels[optionIndex] or tostring(option), function()
				task.spawn(magic.setSetting, magic, id, option)
			end, { kind = "ghost", selected = option == value }, {
				Size = UDim2.fromOffset(0, Theme.minTouch),
				AutomaticSize = Enum.AutomaticSize.X,
				LayoutOrder = optionIndex,
			})
			C.padding(0, Theme.space.l).Parent = button
			button.Parent = row
		end
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function InterfaceController.init(_self: any, ctx: any)
	bus = ctx.bus
	magic = ctx.get("MagicStateController")
	I:registerScreen({ id = "Settings", title = "Settings", order = 99, build = buildSettings })
end

function InterfaceController.start(_self: any, _ctx: any)
	if FeatureFlags.get("ui_enabled") == false then
		return
	end
	-- Our hotbar replaces the backpack (and uses the same number keys); items live in the
	-- Inventory screen and the item quickbar (InventoryController), never in Roblox Tools.
	pcall(function()
		StarterGui:SetCoreGuiEnabled(Enum.CoreGuiType.Backpack, false)
	end)

	hudRoot = makeRoot("MagicHUD", 5, Enum.ScreenInsets.CoreUISafeInsets)
	screenRoot = makeRoot("MagicScreens", 10, Enum.ScreenInsets.DeviceSafeInsets)

	I.inputMode:set(modeFor(UserInputService:GetLastInputType()) or (if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then "Touch" else "Keyboard"))
	UserInputService.LastInputTypeChanged:Connect(function(inputType)
		local mode = modeFor(inputType)
		if mode then
			I.inputMode:set(mode)
		end
	end)

	measure()
	local function watchCamera()
		local camera = workspace.CurrentCamera
		if camera then
			camera:GetPropertyChangedSignal("ViewportSize"):Connect(measure)
		end
		measure()
	end
	watchCamera()
	workspace:GetPropertyChangedSignal("CurrentCamera"):Connect(watchCamera)

	Theme.apply(magic.settings:get())
	magic.settings:observe(function(settings)
		Theme.apply(settings)
		rebuildAll()
	end)
	I.layout:observe(rebuildAll)
	I.inputMode:observe(rebuildAll)
	I.openScreen:observe(function(id)
		renderScreen()
		bus:publish(Topics.ScreenChanged, { screen = id })
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or adminPanelOpen() or UserInputService:GetFocusedTextBox() then
			return
		end
		if input.KeyCode == Enum.KeyCode.ButtonB and I.openScreen:get() then
			I:close()
			return
		end
		for id, def in screens do
			if (def.key and input.KeyCode == def.key) or (def.gamepadKey and input.KeyCode == def.gamepadKey) then
				I:toggle(id)
				return
			end
		end
	end)

	rebuildAll()
end

return InterfaceController
