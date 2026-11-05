--!strict
--[[
	AdminPanel: the client half of the Admin/Developer Panel. It only exists on an admin's
	client: AdminService clones this folder (ServerStorage/AdminClient) into the admin's PlayerGui
	next to the private AdminLink remotes. Everything it does is a request; the server re-checks,
	parses and runs every command (see Services/AdminService).

	UI   toggle with the configured key (default F2) or the ADMIN button (touch). The window drags
	     by its title bar and resizes from its corner. Tabs: Log, Inspector, History and one per
	     command category. The search box filters every command. Each command card builds its
	     inputs from the argument schema: dropdowns (with a filter) for options, sliders for
	     ranged numbers, toggles, @cursor pickers for positions.
	CONSOLE  the bar at the bottom: "/tp village 3", Tab completes (commands, then each argument's
	     options), Up/Down walk the history, the hint line shows the usage with the current
	     argument marked. @cursor = the world point under the mouse, @selected = the inspected NPC.
	LOCAL commands (never sent): clear, cperf, book, learn, rename, forget.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")
local Stats = game:GetService("Stats")
local UserInputService = game:GetService("UserInputService")

local player = Players.LocalPlayer
local playerGui = player:WaitForChild("PlayerGui")
local link = playerGui:WaitForChild("AdminLink")
local commandRemote = link:WaitForChild("Command") :: RemoteEvent
local replyRemote = link:WaitForChild("Reply") :: RemoteEvent
local Overlay = require(script.Parent:WaitForChild("Overlay"))
local Movement = require(script.Parent:WaitForChild("Movement"))

local C = {
	bg = Color3.fromRGB(18, 17, 24),
	panel = Color3.fromRGB(30, 28, 38),
	raised = Color3.fromRGB(44, 41, 55),
	line = Color3.fromRGB(70, 66, 86),
	ink = Color3.fromRGB(236, 232, 220),
	dim = Color3.fromRGB(165, 160, 150),
	accent = Color3.fromRGB(214, 178, 94),
	good = Color3.fromRGB(110, 200, 255),
	bad = Color3.fromRGB(240, 140, 60),
	audit = Color3.fromRGB(150, 150, 165),
}
local MAX_LOG = 300
local MIN_SIZE = Vector2.new(520, 340)
local LOCAL_COMMANDS = {
	clear = "clear the log",
	cperf = "client FPS, ping and memory",
	book = "list your spellbook (numbered)",
	learn = "learn <branch> <property> <verb> <form> <power> [name] - save a recipe",
	rename = "rename <n> <name> - rename spell n from book",
	forget = "forget <n> - remove spell n from book",
}

-- ─── State ──────────────────────────────────────────────────────────────────

local catalog: any = nil
local byName: { [string]: any } = {}
local optionCache: { [string]: { string } } = {}
local nextId = 0
local pending: { [number]: (any) -> () } = {}
local history: { string } = {}
local historyIndex = 0
local selectedNpc: string? = nil
local pickCallback: ((Vector3) -> ())? = nil
local open = false
local activeTab = "Log"
local toggleKey = Enum.KeyCode.F2
local frameTimes: { number } = {}
local lastBookKeys: { string } = {}

-- ─── Tiny UI helpers ────────────────────────────────────────────────────────

local function make(className: string, props: { [string]: any }, children: { Instance }?): any
	local inst = Instance.new(className)
	for k, v in props do
		if k ~= "Parent" then
			(inst :: any)[k] = v
		end
	end
	for _, child in (children or {}) :: { Instance } do
		child.Parent = inst
	end
	if props.Parent then
		inst.Parent = props.Parent
	end
	return inst
end

local function corner(r: number?): UICorner
	return make("UICorner", { CornerRadius = UDim.new(0, r or 6) })
end

local function stroke(color: Color3?): UIStroke
	return make("UIStroke", { Color = color or C.line, Thickness = 1, ApplyStrokeMode = Enum.ApplyStrokeMode.Border })
end

local function text(parent: Instance, s: string, size: number?, color: Color3?, props: { [string]: any }?): TextLabel
	local p: { [string]: any } = {
		BackgroundTransparency = 1,
		Text = s,
		TextColor3 = color or C.ink,
		Font = Enum.Font.BuilderSans,
		TextSize = size or 15,
		TextWrapped = true,
		TextXAlignment = Enum.TextXAlignment.Left,
		TextYAlignment = Enum.TextYAlignment.Top,
		AutomaticSize = Enum.AutomaticSize.Y,
		Size = UDim2.new(1, 0, 0, 0),
		Parent = parent,
	}
	for k, v in (props or {}) :: { [string]: any } do
		p[k] = v
	end
	return make("TextLabel", p)
end

local function button(parent: Instance, s: string, onClick: () -> (), props: { [string]: any }?): TextButton
	local p: { [string]: any } = {
		AutoButtonColor = true,
		BackgroundColor3 = C.raised,
		Text = s,
		TextColor3 = C.ink,
		Font = Enum.Font.BuilderSansMedium,
		TextSize = 14,
		Size = UDim2.fromOffset(math.max(44, #s * 8 + 16), 28),
		Parent = parent,
	}
	for k, v in (props or {}) :: { [string]: any } do
		p[k] = v
	end
	local b = make("TextButton", p, { corner(5), stroke() })
	b.Activated:Connect(onClick)
	return b
end

local function input(parent: Instance, placeholder: string, props: { [string]: any }?): TextBox
	local p: { [string]: any } = {
		BackgroundColor3 = C.bg,
		Text = "",
		PlaceholderText = placeholder,
		PlaceholderColor3 = C.dim,
		TextColor3 = C.ink,
		Font = Enum.Font.Code,
		TextSize = 14,
		ClearTextOnFocus = false,
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.new(1, 0, 0, 28),
		Parent = parent,
	}
	for k, v in (props or {}) :: { [string]: any } do
		p[k] = v
	end
	return make("TextBox", p, { corner(5), stroke(), make("UIPadding", { PaddingLeft = UDim.new(0, 6) }) })
end

local function list(parent: Instance, horizontal: boolean?, gap: number?, wraps: boolean?): UIListLayout
	return make("UIListLayout", {
		FillDirection = if horizontal then Enum.FillDirection.Horizontal else Enum.FillDirection.Vertical,
		Padding = UDim.new(0, gap or 6),
		SortOrder = Enum.SortOrder.LayoutOrder,
		Wraps = wraps == true,
		Parent = parent,
	})
end

local function scroll(parent: Instance, props: { [string]: any }?): ScrollingFrame
	local p: { [string]: any } = {
		BackgroundTransparency = 1,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		CanvasSize = UDim2.new(),
		AutomaticCanvasSize = Enum.AutomaticSize.Y,
		ScrollingDirection = Enum.ScrollingDirection.Y,
		ScrollBarThickness = 6,
		ScrollBarImageColor3 = C.line,
		Parent = parent,
	}
	for k, v in (props or {}) :: { [string]: any } do
		p[k] = v
	end
	return make("ScrollingFrame", p)
end

-- A draggable slider; onChange fires while dragging, onRelease once at the end.
local function slider(parent: Instance, min: number, max: number, integer: boolean, initial: number, onChange: (number) -> (), onRelease: ((number) -> ())?): Frame
	local barFrame = make("Frame", { BackgroundColor3 = C.bg, Size = UDim2.new(1, 0, 0, 10), Parent = parent }, { corner(5), stroke() })
	local fill = make("Frame", { BackgroundColor3 = C.accent, Size = UDim2.fromScale(0, 1), Parent = barFrame }, { corner(5) })
	local value = initial
	local function set(v: number, notify: boolean)
		v = math.clamp(v, min, max)
		if integer then
			v = math.floor(v + 0.5)
		end
		value = v
		fill.Size = UDim2.fromScale((v - min) / math.max(max - min, 1e-6), 1)
		if notify then
			onChange(v)
		end
	end
	set(initial, false)
	local dragging = false
	local function fromX(x: number)
		local t = (x - barFrame.AbsolutePosition.X) / math.max(barFrame.AbsoluteSize.X, 1)
		set(min + t * (max - min), true)
	end
	barFrame.InputBegan:Connect(function(io: InputObject)
		if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
			dragging = true
			fromX(io.Position.X)
		end
	end)
	UserInputService.InputChanged:Connect(function(io: InputObject)
		if dragging and (io.UserInputType == Enum.UserInputType.MouseMovement or io.UserInputType == Enum.UserInputType.Touch) then
			fromX(io.Position.X)
		end
	end)
	UserInputService.InputEnded:Connect(function(io: InputObject)
		if dragging and (io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch) then
			dragging = false
			if onRelease then
				onRelease(value)
			end
		end
	end)
	barFrame:GetAttributeChangedSignal("SetValue"):Connect(function()
		local v = barFrame:GetAttribute("SetValue")
		if typeof(v) == "number" then
			set(v, false)
		end
	end)
	return barFrame
end

-- ─── Window ─────────────────────────────────────────────────────────────────

local screen = make("ScreenGui", { Name = "AdminPanel", ResetOnSpawn = false, DisplayOrder = 200, ZIndexBehavior = Enum.ZIndexBehavior.Sibling, Parent = playerGui })
local window = make("Frame", {
	BackgroundColor3 = C.panel,
	Size = UDim2.fromOffset(800, 520),
	Position = UDim2.new(0.5, -400, 0.5, -260),
	Visible = false,
	Active = true,
	Parent = screen,
}, { corner(8), stroke() })

local titleBar = make("Frame", { BackgroundColor3 = C.bg, Size = UDim2.new(1, 0, 0, 34), Active = true, Parent = window }, { corner(8) })
local titleLabel = text(titleBar, "Admin Panel", 17, C.accent, { Font = Enum.Font.BuilderSansBold, Position = UDim2.fromOffset(12, 8), Size = UDim2.new(1, -60, 0, 20), AutomaticSize = Enum.AutomaticSize.None })
button(titleBar, "×", function()
	open = false
	window.Visible = false
	player:SetAttribute("AdminPanelOpen", false)
end, { Size = UDim2.fromOffset(28, 26), Position = UDim2.new(1, -32, 0, 4), TextSize = 18 })

local search = input(window, "search commands...", { Position = UDim2.fromOffset(140, 40), Size = UDim2.new(1, -148, 0, 26) })
local tabsFrame = scroll(window, { Position = UDim2.fromOffset(6, 40), Size = UDim2.new(0, 128, 1, -118) })
list(tabsFrame, false, 4)
local content = make("Frame", { BackgroundTransparency = 1, Position = UDim2.fromOffset(140, 72), Size = UDim2.new(1, -148, 1, -150), ClipsDescendants = true, Parent = window })

local hint = text(window, "", 13, C.dim, { Font = Enum.Font.Code, Position = UDim2.new(0, 8, 1, -70), Size = UDim2.new(1, -16, 0, 30), AutomaticSize = Enum.AutomaticSize.None, TextYAlignment = Enum.TextYAlignment.Bottom })
local consoleBox = input(window, "/command args   (Tab completes, Up/Down history, @cursor, @selected)", { Position = UDim2.new(0, 8, 1, -36), Size = UDim2.new(1, -16, 0, 28) })
local suggestions = make("Frame", { BackgroundColor3 = C.bg, Visible = false, ZIndex = 20, Size = UDim2.new(1, -16, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, AnchorPoint = Vector2.new(0, 1), Position = UDim2.new(0, 8, 1, -72), Parent = window }, { corner(5), stroke() })
list(suggestions, false, 0)

local grip = make("TextButton", { Text = "◢", TextColor3 = C.dim, BackgroundTransparency = 1, Size = UDim2.fromOffset(18, 18), Position = UDim2.new(1, -18, 1, -18), TextSize = 14, Parent = window })

local mobileButton = button(screen, "ADMIN", function()
	open = not open
	window.Visible = open
	player:SetAttribute("AdminPanelOpen", open)
end, { Position = UDim2.new(0, 8, 0.5, -14), BackgroundColor3 = C.bg, TextColor3 = C.accent, Visible = UserInputService.TouchEnabled })

-- Drag (title) and resize (grip), mouse or touch.
local function dragWith(handle: GuiObject, apply: (Vector2) -> ())
	local dragging, start = false, Vector2.zero
	handle.InputBegan:Connect(function(io: InputObject)
		if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
			dragging, start = true, Vector2.new(io.Position.X, io.Position.Y)
		end
	end)
	UserInputService.InputChanged:Connect(function(io: InputObject)
		if dragging and (io.UserInputType == Enum.UserInputType.MouseMovement or io.UserInputType == Enum.UserInputType.Touch) then
			local now = Vector2.new(io.Position.X, io.Position.Y)
			apply(now - start)
			start = now
		end
	end)
	UserInputService.InputEnded:Connect(function(io: InputObject)
		if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
			dragging = false
		end
	end)
end
dragWith(titleBar, function(delta)
	window.Position += UDim2.fromOffset(delta.X, delta.Y)
end)
dragWith(grip, function(delta)
	local size = window.AbsoluteSize + delta
	window.Size = UDim2.fromOffset(math.max(MIN_SIZE.X, size.X), math.max(MIN_SIZE.Y, size.Y))
end)

-- ─── Pages ──────────────────────────────────────────────────────────────────

local pages: { [string]: GuiObject } = {}
local tabButtons: { [string]: TextButton } = {}

local logPage = scroll(content, { Visible = true })
list(logPage, false, 2)
pages.Log = logPage
local logCount = 0

local function addLog(s: string, color: Color3?)
	for _, line in string.split(s, "\n") do
		logCount += 1
		text(logPage, line, 14, color or C.ink, { Font = Enum.Font.Code, LayoutOrder = logCount, RichText = false })
	end
	local labels = {}
	for _, child in logPage:GetChildren() do
		if child:IsA("GuiObject") then
			table.insert(labels, child)
		end
	end
	if #labels > MAX_LOG then
		table.sort(labels, function(a, b)
			return a.LayoutOrder < b.LayoutOrder
		end)
		for i = 1, #labels - MAX_LOG do
			labels[i]:Destroy()
		end
	end
	task.defer(function()
		logPage.CanvasPosition = Vector2.new(0, math.huge)
	end)
end

local historyPage = scroll(content, { Visible = false })
list(historyPage, false, 3)
pages.History = historyPage

local inspectorPage = scroll(content, { Visible = false })
list(inspectorPage, false, 6)
pages.Inspector = inspectorPage

local searchPage = scroll(content, { Visible = false })
list(searchPage, false, 8)

local function showTab(name: string)
	activeTab = name
	searchPage.Visible = false
	for tabName, page in pages do
		page.Visible = tabName == name
	end
	for tabName, b in tabButtons do
		b.BackgroundColor3 = if tabName == name then C.line else C.raised
	end
end

-- ─── Requests ───────────────────────────────────────────────────────────────

local function mouseHit(): Vector3
	local mouse = player:GetMouse()
	return mouse.Hit.Position
end

local function fmtVec(v: Vector3): string
	return string.format("%d,%d,%d", math.floor(v.X + 0.5), math.floor(v.Y + 0.5), math.floor(v.Z + 0.5))
end

local function substitute(tokens: { string }): { string }
	local out = {}
	for i, t in tokens do
		if t == "@cursor" then
			out[i] = fmtVec(mouseHit())
		elseif t == "@selected" then
			out[i] = selectedNpc or "nearest"
		else
			out[i] = t
		end
	end
	return out
end

local function send(name: string, tokens: { string }, callback: ((any) -> ())?)
	nextId += 1
	if callback then
		pending[nextId] = callback
	end
	commandRemote:FireServer(nextId, name, tokens)
end

local function remember(line: string)
	if history[#history] ~= line then
		table.insert(history, line)
		while #history > 100 do
			table.remove(history, 1)
		end
		local b = button(historyPage, line, function()
			consoleBox.Text = line
			consoleBox:CaptureFocus()
		end, { Size = UDim2.new(1, -8, 0, 24), TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.Code, LayoutOrder = -#history })
		b.TextTruncate = Enum.TextTruncate.AtEnd
	end
	historyIndex = #history + 1
end

-- Runs a server command visibly: echo, then its reply in the log.
local function run(name: string, tokens: { string }, quiet: boolean?)
	local final = substitute(tokens)
	local line = name .. (if #final > 0 then " " .. table.concat(final, " ") else "")
	if not quiet then
		addLog("> " .. line, C.accent)
		remember(line)
	end
	send(name, final, function(msg)
		if msg.text and msg.text ~= "" then
			addLog(msg.text, if msg.ok then C.ink else C.bad)
		end
	end)
end

-- Dropdown options for a type (cached; dynamic ones re-fetched every time they're asked for).
local function withOptions(typeName: string, callback: ({ string }) -> ())
	send("__options", { typeName }, function(msg)
		local options = if msg.data and msg.data.options then msg.data.options else {}
		optionCache[typeName] = options
		callback(options)
	end)
end

-- ─── Option picker (dropdown with a filter) ─────────────────────────────────

local picker = make("Frame", { BackgroundColor3 = C.bg, Visible = false, ZIndex = 30, Size = UDim2.fromOffset(260, 300), Parent = window }, { corner(6), stroke(C.accent) })
local pickerFilter = input(picker, "filter... (Enter uses typed text)", { ZIndex = 31, Position = UDim2.fromOffset(6, 6), Size = UDim2.new(1, -12, 0, 26) })
local pickerList = scroll(picker, { ZIndex = 31, Position = UDim2.fromOffset(6, 38), Size = UDim2.new(1, -12, 1, -44) })
list(pickerList, false, 2)
local pickerOptions: { string } = {}
local pickerChoose: ((string) -> ())? = nil

local function renderPicker()
	for _, child in pickerList:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	local filter = string.lower(pickerFilter.Text)
	local shown = 0
	for _, option in pickerOptions do
		if filter == "" or string.find(string.lower(option), filter, 1, true) then
			shown += 1
			if shown > 250 then
				break
			end
			button(pickerList, option, function()
				picker.Visible = false
				if pickerChoose then
					pickerChoose(option)
				end
			end, { ZIndex = 32, Size = UDim2.new(1, -8, 0, 22), TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.Code, TextSize = 13, LayoutOrder = shown })
		end
	end
end
pickerFilter:GetPropertyChangedSignal("Text"):Connect(renderPicker)
pickerFilter.FocusLost:Connect(function(enter)
	if enter and picker.Visible and pickerFilter.Text ~= "" then
		picker.Visible = false
		if pickerChoose then
			pickerChoose(pickerFilter.Text)
		end
	end
end)

local function openPicker(anchor: GuiObject, options: { string }, choose: (string) -> ())
	pickerOptions, pickerChoose = options, choose
	pickerFilter.Text = ""
	local rel = anchor.AbsolutePosition - window.AbsolutePosition
	local x = math.clamp(rel.X, 0, math.max(0, window.AbsoluteSize.X - 260))
	local y = math.clamp(rel.Y + anchor.AbsoluteSize.Y, 0, math.max(0, window.AbsoluteSize.Y - 300))
	picker.Position = UDim2.fromOffset(x, y)
	picker.Visible = true
	renderPicker()
	pickerFilter:CaptureFocus()
end

-- ─── Command cards ──────────────────────────────────────────────────────────

local function argWidget(parent: Instance, arg: any, order: number): () -> string
	local wide = arg.type == "text" or arg.type == "vector3"
	local box = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(if wide then 300 else 170, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent })
	list(box, false, 2)
	local optional = arg.optional or arg.default ~= nil
	local range = if arg.min or arg.max then string.format(" %s..%s", tostring(arg.min or ""), tostring(arg.max or "")) else ""
	text(box, string.format("%s%s · %s%s", arg.name, if optional then "?" else "", arg.type, range), 12, C.dim, { LayoutOrder = 1 })
	if arg.hint then
		text(box, arg.hint, 11, C.dim, { LayoutOrder = 2 })
	end

	if arg.type == "boolean" then
		local states = if optional and arg.default == nil then { "", "on", "off" } else { "on", "off" }
		local index = if arg.default == false then 2 else 1
		local labels = { [""] = "(toggle)", on = "on", off = "off" }
		local b: TextButton
		b = button(box, labels[states[index]], function()
			index = index % #states + 1
			b.Text = labels[states[index]]
		end, { Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 3 })
		return function()
			return states[index]
		end
	elseif arg.options or arg.dynamic then
		local value = if arg.default ~= nil then tostring(arg.default) else ""
		local b: TextButton
		b = button(box, if value ~= "" then value else "(choose)", function()
			local function show(options: { string })
				openPicker(b, options, function(choice)
					value = choice
					b.Text = choice
				end)
			end
			if arg.options then
				show(arg.options)
			else
				withOptions(arg.type, show)
			end
		end, { Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 3, TextXAlignment = Enum.TextXAlignment.Left })
		b.TextTruncate = Enum.TextTruncate.AtEnd
		return function()
			return value
		end
	end

	local field = input(box, if arg.default ~= nil then tostring(arg.default) else (if arg.type == "vector3" then "@cursor or x,y,z" else ""), { LayoutOrder = 3 })
	if arg.type == "vector3" then
		local row = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 26), LayoutOrder = 4, Parent = box })
		list(row, true, 4)
		button(row, "◎ pick in world", function()
			addLog("click a point in the world...", C.dim)
			pickCallback = function(p)
				field.Text = fmtVec(p)
			end
		end, { Size = UDim2.fromOffset(120, 24) })
		button(row, "@cursor", function()
			field.Text = "@cursor"
		end, { Size = UDim2.fromOffset(70, 24) })
	elseif (arg.type == "number" or arg.type == "integer") and arg.slider and arg.min and arg.max then
		local initial = tonumber(arg.default) or arg.min
		slider(box, arg.min, arg.max, arg.type == "integer", initial, function(v)
			field.Text = if arg.type == "integer" then tostring(v) else string.format("%.2f", v)
		end).LayoutOrder = 4
	end
	return function()
		return field.Text
	end
end

local function buildCard(parent: Instance, def: any, order: number)
	local card = make("Frame", { BackgroundColor3 = C.raised, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = parent }, {
		corner(6),
		make("UIPadding", { PaddingLeft = UDim.new(0, 8), PaddingRight = UDim.new(0, 8), PaddingTop = UDim.new(0, 6), PaddingBottom = UDim.new(0, 8) }),
	})
	list(card, false, 4)
	local aliases = if #def.aliases > 0 then "  (" .. table.concat(def.aliases, ", ") .. ")" else ""
	text(card, def.name .. aliases, 16, if def.unavailable or def.locked then C.dim else C.accent, { Font = Enum.Font.BuilderSansBold, LayoutOrder = 1 })
	text(card, def.description, 13, C.dim, { LayoutOrder = 2 })
	if def.unavailable then
		text(card, "Not available yet: " .. def.unavailable, 13, C.bad, { LayoutOrder = 3 })
		return
	end
	if def.locked then
		text(card, if def.ownerOnly then "Owner only." else "Studio only.", 13, C.bad, { LayoutOrder = 3 })
		return
	end
	local argsRow = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 4, Parent = card })
	list(argsRow, true, 8, true)
	local getters: { () -> string } = {}
	for i, arg in def.args do
		table.insert(getters, argWidget(argsRow, arg, i))
	end
	button(card, "Run " .. def.name, function()
		local tokens: { string } = {}
		for _, get in getters do
			table.insert(tokens, get())
		end
		while #tokens > 0 and tokens[#tokens] == "" do
			table.remove(tokens)
		end
		run(def.name, tokens)
	end, { LayoutOrder = 5, BackgroundColor3 = C.line })
end

local categoryPages: { [string]: ScrollingFrame } = {}

local function buildCategory(category: string)
	if categoryPages[category] then
		return
	end
	local page = scroll(content, { Visible = false })
	list(page, false, 8)
	categoryPages[category] = page
	pages[category] = page
	for i, def in catalog.commands do
		if def.category == category then
			buildCard(page, def, i)
		end
	end
end

local function renderSearch(query: string)
	for _, child in searchPage:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	if query == "" or not catalog then
		searchPage.Visible = false
		showTab(activeTab)
		return
	end
	for _, page in pages do
		page.Visible = false
	end
	searchPage.Visible = true
	local q = string.lower(query)
	local shown = 0
	for i, def in catalog.commands do
		local hay = string.lower(def.name .. " " .. table.concat(def.aliases, " ") .. " " .. def.description .. " " .. def.category)
		if string.find(hay, q, 1, true) then
			shown += 1
			if shown <= 40 then
				buildCard(searchPage, def, i)
			end
		end
	end
	if shown == 0 then
		text(searchPage, "no command matches '" .. query .. "'", 14, C.dim)
	end
end
search:GetPropertyChangedSignal("Text"):Connect(function()
	renderSearch(search.Text)
end)

local function addTab(name: string, order: number)
	tabButtons[name] = button(tabsFrame, name, function()
		if name ~= "Log" and name ~= "History" and name ~= "Inspector" then
			buildCategory(name)
		end
		search.Text = ""
		showTab(name)
	end, { Size = UDim2.new(1, -8, 0, 26), LayoutOrder = order, TextXAlignment = Enum.TextXAlignment.Left })
end

-- ─── NPC list rows and the inspector ────────────────────────────────────────

local function renderNpcList(rows: { any })
	for _, row in rows do
		logCount += 1
		local f = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 22), LayoutOrder = logCount, Parent = logPage })
		list(f, true, 4)
		button(f, "tp", function()
			run("tpnpc", { row.id })
		end, { Size = UDim2.fromOffset(30, 20), TextSize = 12 })
		button(f, "inspect", function()
			selectedNpc = row.id
			showTab("Inspector")
		end, { Size = UDim2.fromOffset(56, 20), TextSize = 12 })
		text(f, string.format("%s · %s · %s · %s %s %d (T%d) · LOD %d", row.name, row.town, row.occupation, row.domains, row.best, row.mastery, row.tier, row.lod), 13, C.ink,
			{ Font = Enum.Font.Code, Size = UDim2.new(1, -100, 0, 20), AutomaticSize = Enum.AutomaticSize.None, TextTruncate = Enum.TextTruncate.AtEnd })
	end
end

local inspectorHeader = text(inspectorPage, "Open this tab, then click an NPC in the world (or npcinspect / an npclist row).", 14, C.dim, { LayoutOrder = 1 })
local actionsRow = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 2, Parent = inspectorPage })
list(actionsRow, true, 4, true)
for _, entry in {
	{ "freeze", "npcfreeze" }, { "heal", "npcheal" }, { "knock out", "npckill" }, { "gossip", "npcgossip" },
	{ "go home", "npcdo", "home" }, { "flee", "npcdo", "flee" }, { "duel", "npcdo", "duel" }, { "teach me", "npcdo", "teachme" },
	{ "make teacher", "npcbond", "teacher" }, { "make apprentice", "npcbond", "apprentice" },
	{ "T0", "npctier", "0" }, { "T1", "npctier", "1" }, { "T2", "npctier", "2" }, { "auto LOD", "npctier", "auto" },
	{ "tp to", "tpnpc" }, { "day trace", "npcday" }, { "delete", "npcdelete" },
} do
	button(actionsRow, entry[1], function()
		if not selectedNpc then
			addLog("select an NPC first", C.bad)
			return
		end
		local tokens = { selectedNpc :: string }
		if entry[3] then
			table.insert(tokens, entry[3])
		end
		run(entry[2], tokens)
		if entry[2] ~= "npcday" then
			showTab("Inspector")
		end
	end, { TextSize = 12, Size = UDim2.fromOffset(math.max(44, #entry[1] * 7 + 14), 24) })
end

local slidersFrame = make("Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, -8, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Parent = inspectorPage })
list(slidersFrame, true, 8, true)
local liveSliders: { [string]: Frame } = {}
local function editSlider(label: string, key: string, command: string)
	local box = make("Frame", { BackgroundTransparency = 1, Size = UDim2.fromOffset(150, 34), Parent = slidersFrame })
	local caption = text(box, label, 12, C.dim, { Size = UDim2.new(1, 0, 0, 14), AutomaticSize = Enum.AutomaticSize.None })
	local s = slider(box, 0, 1, false, 0.5, function(v)
		caption.Text = string.format("%s %.2f", label, v)
	end, function(v)
		if selectedNpc then
			run(command, { selectedNpc :: string, key, string.format("%.2f", v) }, true)
		end
	end)
	s.Position = UDim2.fromOffset(0, 18)
	liveSliders[command .. ":" .. key] = s
end
for _, need in { "rest", "food", "safety", "social", "purpose", "wealth" } do
	editSlider("need " .. need, need, "npcneed")
end
for _, trait in { "openness", "conscientiousness", "extraversion", "agreeableness", "neuroticism", "ambition", "curiosity", "pride", "loyalty", "greed", "compassion", "humor", "patience" } do
	editSlider(trait, trait, "npctrait")
end
local inspectorBody = text(inspectorPage, "", 14, C.ink, { Font = Enum.Font.Code, LayoutOrder = 4 })

local function renderInspector(v: any)
	if typeof(v) ~= "table" then
		return
	end
	selectedNpc = v.id
	inspectorHeader.Text = string.format("%s, %d, %s of %s (%s)   %s   T%d   %s", v.name, v.age, v.occupation, v.settlement, v.culture, v.id, v.tier, v.clock)
	for need, value in v.needs do
		local s = liveSliders["npcneed:" .. need]
		if s then
			s:SetAttribute("SetValue", value)
		end
	end
	for trait, value in v.traits do
		local s = liveSliders["npctrait:" .. trait]
		if s then
			s:SetAttribute("SetValue", value)
		end
	end
	local m = v.magic
	local lines = {
		string.format("doing: %s (%s block), mood %s%s", v.action, tostring(v.block), v.mood, if v.knockedOut then ", KNOCKED OUT" else ""),
		"lives: " .. tostring(v.home) .. "  ·  works: " .. tostring(v.work),
		"goal: " .. v.goal,
		"ambition: " .. v.ambition,
		"quirks: " .. table.concat(v.quirks, ", "),
		"values: " .. table.concat(v.values, ", ") .. " · fears: " .. table.concat(v.fears, ", "),
		if v.secret then "secret: " .. v.secret else "",
		"",
		"SCORES",
	}
	for _, s in v.scores do
		table.insert(lines, "  " .. s)
	end
	table.insert(lines, "")
	table.insert(lines, string.format("MAGIC %s (%s) best %s %.1f (tier %d) focus %s", table.concat(m.manifest, "/"), m.rarity, tostring(m.best), m.mastery or 0, m.tier or 0, tostring(m.focus)))
	table.insert(lines, string.format("  school %s · mentor %s · students %d · rival %s%s%s", tostring(m.school), tostring(m.mentor), m.students or 0, tostring(m.rival),
		if m.hiddenMythic then " · HIDDEN " .. m.hiddenMythic else "", if m.rogue then " · ROGUE" else ""))
	if #m.techniques > 0 then
		table.insert(lines, "  techniques: " .. table.concat(m.techniques, ", "))
	end
	for _, h in m.history do
		table.insert(lines, "  " .. h)
	end
	table.insert(lines, "")
	table.insert(lines, "MEMORIES")
	for _, s in v.memories do
		table.insert(lines, "  " .. s)
	end
	table.insert(lines, "RELATIONSHIPS")
	for _, s in v.relations do
		table.insert(lines, "  " .. s)
	end
	inspectorBody.Text = table.concat(lines, "\n")
end

-- ─── Reply handling ─────────────────────────────────────────────────────────

local function handleData(data: any)
	if typeof(data) ~= "table" then
		return
	end
	local kind = data.kind
	if kind == "movement" then
		Movement.apply(data)
	elseif kind == "overlay" then
		Overlay.apply(data)
	elseif kind == "npclist" then
		renderNpcList(data.rows)
	elseif kind == "npcinspect" then
		renderInspector(data.npc)
		showTab("Inspector")
	elseif kind == "select" then
		selectedNpc = data.npcId
	end
end

local function setCatalog(c: any)
	if catalog then
		return -- already built (a second __catalog request raced the first)
	end
	catalog = c
	table.clear(byName)
	for _, def in c.commands do
		byName[def.name] = def
		for _, alias in def.aliases do
			byName[string.lower(alias)] = def
		end
	end
	local key = (Enum.KeyCode :: any)[c.toggleKey]
	if key then
		toggleKey = key
	end
	titleLabel.Text = string.format("Admin Panel  ·  %d commands%s%s  ·  %s to toggle", #c.commands, if c.isOwner then "  ·  owner" else "", if c.studio then "  ·  Studio" else "  ·  LIVE", c.toggleKey)
	addTab("Log", 1)
	addTab("Inspector", 2)
	addTab("History", 3)
	local order = 10
	for _, category in c.categories do
		for _, def in c.commands do
			if def.category == category then
				addTab(category, order)
				order += 1
				break
			end
		end
	end
	for _, entry in c.audit do
		if entry.userId ~= player.UserId then
			addLog(string.format("[%s] %s: %s %s", os.date("%H:%M:%S", entry.t), entry.who, entry.command, entry.args), C.audit)
		end
	end
	addLog("Ready. help lists commands; Tab completes in the console.", C.good)
end

replyRemote.OnClientEvent:Connect(function(msg: any)
	if typeof(msg) ~= "table" then
		return
	end
	if msg.kind == "audit" then
		local e = msg.entry
		if e and e.userId ~= player.UserId then
			addLog(string.format("[%s] %s: %s %s%s", os.date("%H:%M:%S", e.t), e.who, e.command, e.args, if e.ok then "" else " (failed)"), C.audit)
		end
	elseif msg.kind == "reply" then
		if msg.data and msg.data.kind == "catalog" then
			setCatalog(msg.data.catalog)
		else
			handleData(msg.data)
		end
		local callback = pending[msg.id]
		pending[msg.id] = nil
		if callback then
			callback(msg)
		end
	end
end)

-- ─── Local commands ─────────────────────────────────────────────────────────

local function clientPerf(): string
	local total = 0
	for _, dt in frameTimes do
		total += dt
	end
	local fps = if #frameTimes > 0 then #frameTimes / total else 0
	return string.format("client: %.0f fps | ping %.0f ms | memory %.0f MB", fps, player:GetNetworkPing() * 1000, Stats:GetTotalMemoryUsageMb())
end

local function invokeShared(name: string, ...: any): (boolean, ...any)
	local ok, Net = pcall(require, ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Net"))
	if not ok then
		return false, "Net unavailable"
	end
	return (Net :: any).invoke(name, ...)
end

local function localCommand(name: string, args: { string }): boolean
	if name == "clear" then
		for _, child in logPage:GetChildren() do
			if child:IsA("GuiObject") then
				child:Destroy()
			end
		end
	elseif name == "cperf" then
		addLog(clientPerf())
	elseif name == "book" then
		task.spawn(function()
			local ok, spells = invokeShared("RequestSpellbook")
			if not ok or typeof(spells) ~= "table" then
				addLog("spellbook request failed", C.bad)
				return
			end
			table.clear(lastBookKeys)
			if #spells == 0 then
				addLog("(spellbook empty - try: learn energy temperature generate touch 1 Candle)")
			end
			for i, spell in spells do
				table.insert(lastBookKeys, spell.key)
				addLog(string.format("%d. %s%s  [%s]", i, spell.name, if spell.favorite then " *" else "", spell.key))
			end
		end)
	elseif name == "learn" then
		if #args < 5 then
			addLog("usage: " .. LOCAL_COMMANDS.learn, C.bad)
			return true
		end
		local recipe = { branch = args[1], property = args[2], verb = args[3], form = args[4], power = tonumber(args[5]) }
		local spellName = if #args > 5 then table.concat(args, " ", 6) else nil
		task.spawn(function()
			local ok, saved, a, b = invokeShared("SaveSpell", recipe, spellName)
			addLog(if ok and saved then "learned: " .. tostring(a) else "refused: " .. tostring(a or saved), if ok and saved then C.ink else C.bad)
			if b then
				addLog("name refused: " .. tostring(b), C.bad)
			end
		end)
	elseif name == "rename" or name == "forget" then
		local key = lastBookKeys[tonumber(args[1]) or 0]
		if not key then
			addLog("run book first, then use a number from it", C.bad)
			return true
		end
		task.spawn(function()
			-- Separate calls: an if-expression would keep only the first of the returned values.
			local ok, done, why
			if name == "rename" then
				ok, done, why = invokeShared("RenameSpell", key, table.concat(args, " ", 2))
			else
				ok, done, why = invokeShared("RemoveSpell", key)
			end
			addLog(if ok and done then name .. " ok" else "refused: " .. tostring(why or done), if ok and done then C.ink else C.bad)
		end)
	else
		return false
	end
	return true
end

-- ─── Console ────────────────────────────────────────────────────────────────

-- Splits on spaces; "double quotes" keep spaces together.
local function tokenize(line: string): { string }
	local tokens = {}
	local current, quoted = "", false
	for i = 1, #line do
		local ch = string.sub(line, i, i)
		if ch == '"' then
			quoted = not quoted
		elseif string.match(ch, "%s") and not quoted then -- any whitespace: Enter can leave a stray carriage return after refocus
			if current ~= "" then
				table.insert(tokens, current)
				current = ""
			end
		else
			current ..= ch
		end
	end
	if current ~= "" then
		table.insert(tokens, current)
	end
	return tokens
end

local function execute(line: string)
	local trimmed = string.gsub(line, "^%s*/", "")
	local tokens = tokenize(trimmed)
	local name = table.remove(tokens, 1)
	if not name then
		return
	end
	name = string.lower(name)
	if LOCAL_COMMANDS[name] then
		addLog("> " .. trimmed, C.accent)
		remember(trimmed)
		localCommand(name, tokens)
		return
	end
	run(name, tokens)
end

local currentSuggestions: { string } = {}

local function setSuggestions(items: { string })
	currentSuggestions = items
	for _, child in suggestions:GetChildren() do
		if child:IsA("GuiObject") then
			child:Destroy()
		end
	end
	for i, item in items do
		button(suggestions, item, function()
			local trimmed = consoleBox.Text
			local lastSpace = string.match(trimmed, "^.*() ")
			consoleBox.Text = (if lastSpace then string.sub(trimmed, 1, lastSpace) else "") .. item .. " "
			consoleBox:CaptureFocus()
			consoleBox.CursorPosition = #consoleBox.Text + 1
		end, { ZIndex = 21, Size = UDim2.new(1, 0, 0, 20), TextXAlignment = Enum.TextXAlignment.Left, Font = Enum.Font.Code, TextSize = 13, LayoutOrder = i, BackgroundTransparency = 0.2 })
	end
	suggestions.Visible = #items > 0 and consoleBox:IsFocused()
end

local function usageMarked(def: any, index: number): string
	local parts = { def.name }
	for i, arg in def.args do
		local label = arg.name .. ":" .. arg.type
		local wrapped = if arg.optional or arg.default ~= nil then "[" .. label .. "]" else "<" .. label .. ">"
		table.insert(parts, if i == index then "▸" .. wrapped else wrapped)
	end
	local current = def.args[index]
	local tail = if current and current.hint then "   " .. current.hint elseif current and current.min then string.format("   %s..%s", tostring(current.min), tostring(current.max)) else ""
	return table.concat(parts, " ") .. tail .. "\n" .. def.description
end

local function updateSuggestions()
	local raw = string.gsub(consoleBox.Text, "^%s*/", "")
	local tokens = tokenize(raw)
	local endsWithSpace = string.sub(raw, -1) == " "
	if #tokens == 0 or (#tokens == 1 and not endsWithSpace) then
		local prefix = string.lower(tokens[1] or "")
		local out = {}
		local names = {}
		for name in LOCAL_COMMANDS do
			table.insert(names, name)
		end
		for _, def in (if catalog then catalog.commands else {}) :: { any } do
			if not def.unavailable then
				table.insert(names, def.name)
			end
		end
		table.sort(names)
		for _, name in names do
			if prefix ~= "" and string.sub(name, 1, #prefix) == prefix then
				table.insert(out, name)
			end
		end
		local exact = byName[prefix]
		hint.Text = if exact then usageMarked(exact, 0) elseif LOCAL_COMMANDS[prefix] then LOCAL_COMMANDS[prefix] else ""
		setSuggestions({ table.unpack(out, 1, math.min(#out, 8)) })
		return
	end
	local def = byName[string.lower(tokens[1])]
	if not def then
		hint.Text = if LOCAL_COMMANDS[string.lower(tokens[1])] then LOCAL_COMMANDS[string.lower(tokens[1])] else "unknown command (help lists them)"
		setSuggestions({})
		return
	end
	local index = #tokens - 1 + (if endsWithSpace then 1 else 0)
	local partial = if endsWithSpace then "" else string.lower(tokens[#tokens])
	local last = def.args[#def.args]
	local arg = def.args[index] or (if last and last.type == "text" then last else nil)
	hint.Text = usageMarked(def, index)
	if not arg then
		setSuggestions({})
		return
	end
	local options: { string }? = arg.options or optionCache[arg.type]
	if not options and arg.dynamic then
		withOptions(arg.type, function()
			if consoleBox:IsFocused() then
				updateSuggestions()
			end
		end)
		optionCache[arg.type] = {}
		return
	end
	if arg.type == "boolean" then
		options = { "on", "off" }
	elseif arg.type == "vector3" then
		options = { "@cursor" }
	elseif arg.type == "npc" and options then
		options = { "@selected", table.unpack(options :: { string }) }
	end
	local out = {}
	for _, option in (options or {}) :: { string } do
		if partial == "" or string.sub(string.lower(option), 1, #partial) == partial then
			table.insert(out, option)
			if #out >= 8 then
				break
			end
		end
	end
	setSuggestions(out)
end

consoleBox:GetPropertyChangedSignal("Text"):Connect(function()
	if string.find(consoleBox.Text, "\t", 1, true) then
		-- Tab: accept the first suggestion.
		local withoutTab = string.gsub(consoleBox.Text, "\t", "")
		consoleBox.Text = withoutTab
		local first = currentSuggestions[1]
		if first then
			local lastSpace = string.match(withoutTab, "^.*() ")
			consoleBox.Text = (if lastSpace then string.sub(withoutTab, 1, lastSpace) else "") .. first .. " "
			consoleBox.CursorPosition = #consoleBox.Text + 1
		end
		return
	end
	updateSuggestions()
end)
consoleBox.Focused:Connect(updateSuggestions)
consoleBox.FocusLost:Connect(function(enter)
	if enter and consoleBox.Text ~= "" then
		local line = consoleBox.Text
		consoleBox.Text = ""
		execute(line)
		if activeTab ~= "Log" and activeTab ~= "Inspector" then
			showTab("Log")
		end
		task.defer(function()
			consoleBox:CaptureFocus()
		end)
	end
	task.delay(0.15, function()
		if not consoleBox:IsFocused() then
			suggestions.Visible = false
		end
	end)
end)

-- ─── Input ──────────────────────────────────────────────────────────────────

local function setOpen(value: boolean)
	open = value
	window.Visible = value
	player:SetAttribute("AdminPanelOpen", value)
	if value and not catalog then
		send("__catalog", {})
	end
end

UserInputService.InputBegan:Connect(function(io: InputObject, processed: boolean)
	if io.KeyCode == toggleKey and (not processed or consoleBox:IsFocused()) then
		setOpen(not open)
		return
	end
	if consoleBox:IsFocused() then
		if io.KeyCode == Enum.KeyCode.Up and #history > 0 then
			historyIndex = math.max(1, historyIndex - 1)
			consoleBox.Text = history[historyIndex]
		elseif io.KeyCode == Enum.KeyCode.Down and #history > 0 then
			historyIndex = math.min(#history + 1, historyIndex + 1)
			consoleBox.Text = history[historyIndex] or ""
		end
		return
	end
	if processed then
		return
	end
	if io.UserInputType == Enum.UserInputType.MouseButton1 or io.UserInputType == Enum.UserInputType.Touch then
		if pickCallback then
			local callback = pickCallback
			pickCallback = nil
			callback(mouseHit())
			addLog("picked " .. fmtVec(mouseHit()), C.dim)
		elseif open and activeTab == "Inspector" then
			local target = player:GetMouse().Target
			while target and target ~= workspace do
				local id = target:GetAttribute("NpcId")
				if typeof(id) == "string" then
					selectedNpc = id
					send("__npcinspect", { id })
					break
				end
				target = target.Parent :: any
			end
		end
	end
end)

RunService.RenderStepped:Connect(function(dt)
	table.insert(frameTimes, dt)
	if #frameTimes > 60 then
		table.remove(frameTimes, 1)
	end
end)

-- Live refresh: the inspected NPC (1 s) and live overlays such as npclod (2 s).
task.spawn(function()
	local tick = 0
	while true do
		task.wait(1)
		tick += 1
		if open and activeTab == "Inspector" and selectedNpc then
			send("__npcinspect", { selectedNpc :: string })
		end
		if tick % 2 == 0 then
			for layer, radius in Overlay.active() do
				send("__overlay", { layer, "on", tostring(radius) })
			end
		end
	end
end)

Movement.start()
send("__catalog", {})
mobileButton.Visible = UserInputService.TouchEnabled
UserInputService.LastInputTypeChanged:Connect(function(kind)
	if kind == Enum.UserInputType.Touch then
		mobileButton.Visible = true
	end
end)
