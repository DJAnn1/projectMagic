--!strict
--[[
	InteractClickController: you use things by clicking them, not by pressing a key at a popup.

	PROMPTS   The server still makes a ProximityPrompt for every door, bed, chest, station, NPC,
	          Rift gate and so on, and still runs every effect from prompt.Triggered: nothing on
	          the server changed, so every server check (distance, locks, ownership) still applies.
	          Here, every prompt is made local-only "Custom" (no popup is drawn), keyless (E and F
	          no longer fire it), and AlwaysShow (so every prompt in range can be used, not just the
	          nearest per key). Roblox still decides which prompts are in range and in sight
	          (PromptShown / PromptHidden), and we only ever use one of those.
	HOVER     20 times a second, a ray from the mouse (the screen centre on a gamepad) finds the
	          part under it; the first in-range prompt on that part or its model is "hovered". It
	          gets a soft outline (one Highlight) and a small label by the cursor: what a click does,
	          and the second action if there is one ("Shift-click: Light fire").
	CLICK     left mouse on a hovered thing: prompt:InputHoldBegin(), and InputHoldEnd() on release,
	          so held prompts need the click held (the label fills while you hold). Shift-click
	          uses the second action (prompts whose server key was not E: the old F prompts).
	          Gamepad: X uses, Y the second action (claimed ahead of the screen keys through
	          InterfaceController:setInputClaim). Touch: tap it (held prompts finish on their own).
	GATE      CastClient registers setGate(fn) -> (busy, armed). Busy (a readied spell, a raised
	          guard, a charge): no hover, every click stays combat. Armed (a weapon drawn): objects
	          still work, but a click on a person attacks; the label says to put the weapon away.
	CastClient asks claimsClick() before treating a left click as an attack or a cast.

	Cost: one ray at 20 Hz, an ancestor walk of at most 6 levels, one Highlight, one label.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)

local HOVER_HZ = 20
local RAY_LENGTH = 80
local MAX_DEPTH = 6 -- ancestor levels searched above the part under the pointer
local MAX_VISIBLE = 64 -- prompts Roblox may consider shown at once (default 16)
local LABEL_OFFSET = Vector2.new(18, 14)

local InteractClickController = {
	name = "InteractClickController",
	dependencies = { "InterfaceController" },
}

local interface: any = nil
local gate: (() -> (boolean, boolean))? = nil

local shown: { [ProximityPrompt]: boolean } = {}
local isAlt: { [ProximityPrompt]: boolean } = {} -- its server key wasn't E: the "second action"

type Hover = { primary: ProximityPrompt, alt: ProximityPrompt?, person: boolean, blocked: boolean, adornee: Instance }
local hover: Hover? = nil
-- `input` is what ends the hold when released (nil: a tap, which finishes on its own).
local holding: { prompt: ProximityPrompt, started: number, input: any }? = nil

local highlight: Highlight? = nil
local label: TextLabel? = nil
local holdBar: Frame? = nil

-- ─── Prompts ────────────────────────────────────────────────────────────────

-- Local-only changes: the server never sees them, and it never changes these properties later.
local function configure(prompt: ProximityPrompt)
	if isAlt[prompt] ~= nil then
		return
	end
	isAlt[prompt] = prompt.KeyboardKeyCode ~= Enum.KeyCode.E
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.AlwaysShow
	prompt.KeyboardKeyCode = Enum.KeyCode.None
	prompt.GamepadKeyCode = Enum.KeyCode.None
	prompt.Destroying:Connect(function()
		isAlt[prompt] = nil
		shown[prompt] = nil
	end)
end

local function promptsOn(node: Instance, out: { ProximityPrompt })
	for _, child in node:GetChildren() do
		if child:IsA("ProximityPrompt") then
			if shown[child] and child.Enabled then
				table.insert(out, child)
			end
		elseif child:IsA("BasePart") or child:IsA("Attachment") then
			-- One level down: an NPC's Talk prompt sits in its HumanoidRootPart.
			for _, grand in child:GetChildren() do
				if grand:IsA("ProximityPrompt") and shown[grand] and grand.Enabled then
					table.insert(out, grand)
				end
			end
		end
	end
end

-- What gets the outline: the part itself, or the whole model when the prompt sits on an
-- invisible part (an NPC's root, a seat's hit box).
local function adorneeFor(prompt: ProximityPrompt): Instance
	local holder = prompt.Parent
	if holder and holder:IsA("Attachment") then
		holder = holder.Parent
	end
	if holder and holder:IsA("BasePart") and holder.Transparency < 0.9 then
		return holder
	end
	local model = prompt:FindFirstAncestorOfClass("Model")
	return model or holder or prompt
end

local function isPerson(prompt: ProximityPrompt): boolean
	local model = prompt:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude

-- The usable thing under a ray, or nil.
local function pick(ray: Ray): Hover?
	local character = Players.LocalPlayer.Character
	params.FilterDescendantsInstances = if character then { character } else {}
	local result = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)
	if not result then
		return nil
	end
	local found: { ProximityPrompt } = {}
	local node: Instance? = result.Instance
	local depth = 0
	while node and node ~= workspace and depth < MAX_DEPTH and #found == 0 do
		promptsOn(node, found)
		node = node.Parent
		depth += 1
	end
	if #found == 0 then
		return nil
	end
	local primary, alt = found[1], nil
	for _, prompt in found do
		if isAlt[prompt] then
			alt = alt or prompt
		else
			primary = prompt
		end
	end
	if primary == alt then
		alt = nil -- only a second-action prompt here: a plain click uses it
	end
	if alt and isAlt[primary] then
		alt = nil
	end
	local person = isPerson(primary)
	local armed = false
	if gate then
		local _, out = gate()
		armed = out
	end
	return { primary = primary, alt = alt, person = person, blocked = person and armed, adornee = adorneeFor(primary) }
end

local function gated(): boolean
	if interface:isInputBlocked() then
		return true
	end
	if gate then
		local busy = gate()
		return busy
	end
	return false
end

local function gamepadMode(): boolean
	return interface.inputMode:get() == "Gamepad"
end

local function pointerRay(): Ray?
	local camera = workspace.CurrentCamera
	if not camera then
		return nil
	end
	if gamepadMode() then
		local size = camera.ViewportSize
		return camera:ViewportPointToRay(size.X / 2, size.Y / 2)
	end
	if interface.inputMode:get() == "Touch" then
		return nil -- no pointer to hover with; taps are picked when they land
	end
	local at = UserInputService:GetMouseLocation()
	return camera:ViewportPointToRay(at.X, at.Y)
end

-- ─── Look ───────────────────────────────────────────────────────────────────

local function buildLook()
	local h = Instance.new("Highlight")
	h.Name = "InteractHover"
	h.FillTransparency = 1
	h.OutlineColor = Theme.color.ink
	h.OutlineTransparency = 0.35
	h.DepthMode = Enum.HighlightDepthMode.Occluded
	h.Enabled = false
	h.Parent = workspace.CurrentCamera or workspace
	highlight = h

	local gui = Instance.new("ScreenGui")
	gui.Name = "InteractHint"
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- positions match GetMouseLocation
	gui.DisplayOrder = 5
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local text = Instance.new("TextLabel")
	text.Name = "Label"
	text.AutomaticSize = Enum.AutomaticSize.XY
	text.Size = UDim2.fromOffset(0, 0)
	text.BackgroundColor3 = Theme.color.panel
	text.BackgroundTransparency = 0.15
	text.TextColor3 = Theme.color.ink
	text.FontFace = Theme.font.medium
	text.TextSize = Theme.text("body")
	text.RichText = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.Visible = false
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingTop = UDim.new(0, 3)
	pad.PaddingBottom = UDim.new(0, 5)
	pad.Parent = text
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.radius.s)
	corner.Parent = text
	text.Parent = gui
	label = text

	local bar = Instance.new("Frame")
	bar.Name = "Hold"
	bar.AnchorPoint = Vector2.new(0, 1)
	bar.Position = UDim2.fromScale(0, 1)
	bar.Size = UDim2.new(0, 0, 0, 3)
	bar.BackgroundColor3 = Theme.color.accent
	bar.BorderSizePixel = 0
	bar.Parent = text
	holdBar = bar
end

local function escape(s: string): string
	return (string.gsub(string.gsub(string.gsub(s, "&", "&amp;"), "<", "&lt;"), ">", "&gt;"))
end

local function lineFor(prompt: ProximityPrompt): string
	local action, object = prompt.ActionText, prompt.ObjectText
	if object ~= "" then
		return string.format("<b>%s</b>  %s", escape(action), escape(object))
	end
	return string.format("<b>%s</b>", escape(action))
end

local function render()
	local h, text, bar = highlight, label, holdBar
	if not h or not text or not bar then
		return
	end
	local current = hover
	local held = holding
	if not current and not held then
		h.Enabled = false
		text.Visible = false
		return
	end
	if current then
		h.Adornee = current.adornee
		h.Enabled = not current.blocked
		local lines: { string } = {}
		if current.blocked then
			table.insert(lines, "<font transparency=\"0.3\">Put your weapon away (Q) to talk</font>")
		else
			table.insert(lines, lineFor(current.primary))
			if current.alt then
				local key = if gamepadMode() then "Y" else "Shift-click"
				table.insert(lines, string.format("<font size=\"%d\">%s: %s</font>", Theme.text("caption"), key, escape(current.alt.ActionText)))
			end
		end
		text.Text = table.concat(lines, "\n")
	end
	text.Visible = true
	local at = if gamepadMode() and workspace.CurrentCamera
		then workspace.CurrentCamera.ViewportSize / 2
		else UserInputService:GetMouseLocation()
	text.Position = UDim2.fromOffset(at.X + LABEL_OFFSET.X, at.Y + LABEL_OFFSET.Y)
	if held and held.prompt.HoldDuration > 0 then
		local share = math.clamp((os.clock() - held.started) / held.prompt.HoldDuration, 0, 1)
		bar.Size = UDim2.new(share, 0, 0, 3)
	else
		bar.Size = UDim2.new(0, 0, 0, 3)
	end
end

-- ─── Using ──────────────────────────────────────────────────────────────────

local function endHold()
	local held = holding
	holding = nil
	if held then
		pcall(function()
			held.prompt:InputHoldEnd()
		end)
	end
end

local function beginHold(prompt: ProximityPrompt, input: any, autoRelease: boolean)
	endHold()
	local ok = pcall(function()
		prompt:InputHoldBegin()
	end)
	if not ok then
		return
	end
	local held = { prompt = prompt, started = os.clock(), input = if autoRelease then nil else input }
	holding = held
	if autoRelease then
		-- A tap can't be held: finish a held prompt on its own.
		task.delay(prompt.HoldDuration + 0.05, function()
			if holding == held then
				endHold()
			end
		end)
	end
end

-- Uses what's hovered (or what `at` hits); returns true if it took the input.
local function use(target: Hover?, wantAlt: boolean, input: any, autoRelease: boolean): boolean
	if not target or target.blocked or gated() then
		return false
	end
	local prompt = if wantAlt and target.alt then target.alt else target.primary
	if not shown[prompt] then
		return false
	end
	beginHold(prompt, input, autoRelease)
	return true
end

local function shiftDown(): boolean
	return UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift)
end

-- ─── Public ─────────────────────────────────────────────────────────────────

-- CastClient: what we may do right now. busy = no interaction at all; armed = a weapon is out.
function InteractClickController.setGate(_self: any, fn: () -> (boolean, boolean))
	gate = fn
end

-- True when a left click right now goes to something usable (CastClient then doesn't attack).
function InteractClickController.claimsClick(_self: any): boolean
	if gated() then
		return false
	end
	local ray = pointerRay()
	local target = if ray then pick(ray) else nil
	hover = target
	return target ~= nil and not target.blocked
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function InteractClickController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
end

function InteractClickController.start(_self: any, _ctx: any)
	ProximityPromptService.MaxPromptsVisible = MAX_VISIBLE
	for _, d in workspace:GetDescendants() do
		if d:IsA("ProximityPrompt") then
			configure(d)
		end
	end
	workspace.DescendantAdded:Connect(function(d)
		if d:IsA("ProximityPrompt") then
			configure(d)
		end
	end)
	ProximityPromptService.PromptShown:Connect(function(prompt: ProximityPrompt)
		configure(prompt) -- in case it showed before we saw it added
		shown[prompt] = true
	end)
	ProximityPromptService.PromptHidden:Connect(function(prompt: ProximityPrompt)
		shown[prompt] = nil
		local held = holding
		if held and held.prompt == prompt then
			endHold()
		end
	end)

	buildLook()

	-- Mouse: the click itself (CastClient has already stood aside: claimsClick).
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed then
			return
		end
		if input.UserInputType == Enum.UserInputType.MouseButton1 and not gamepadMode() then
			local ray = pointerRay()
			use(if ray then pick(ray) else nil, shiftDown(), Enum.UserInputType.MouseButton1, false)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		local held = holding
		if held and held.input ~= nil and (input.UserInputType == held.input or input.KeyCode == held.input) then
			endHold()
		end
	end)

	-- Gamepad X / Y: taken ahead of the screen keys only while looking at something usable.
	interface:setInputClaim(function(input: InputObject): boolean
		if input.KeyCode ~= Enum.KeyCode.ButtonX and input.KeyCode ~= Enum.KeyCode.ButtonY then
			return false
		end
		local ray = pointerRay()
		return use(if ray then pick(ray) else nil, input.KeyCode == Enum.KeyCode.ButtonY, input.KeyCode, false)
	end)

	-- Touch: a tap on the thing.
	UserInputService.TouchTap:Connect(function(positions: { Vector2 }, processed: boolean)
		local camera = workspace.CurrentCamera
		local at = positions[1]
		if processed or not camera or not at then
			return
		end
		use(pick(camera:ScreenPointToRay(at.X, at.Y)), false, Enum.UserInputType.Touch, true)
	end)

	-- Hover and the label.
	local elapsed = 0
	RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if elapsed >= 1 / HOVER_HZ then
			elapsed = 0
			if gated() then
				hover = nil
				if holding then
					endHold()
				end
			else
				local ray = pointerRay()
				hover = if ray then pick(ray) else nil
			end
		end
		render()
	end)
	Players.LocalPlayer.CharacterAdded:Connect(function()
		endHold()
		hover = nil
	end)
end

return InteractClickController
