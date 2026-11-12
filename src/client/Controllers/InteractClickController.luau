--!strict
--[[
	InteractClickController: you use things by clicking them, not by pressing a key at a popup.

	PROMPTS   The server still makes a ProximityPrompt for every door, bed, chest, station, NPC,
	          Rift gate and so on, and registers its action with Interact/PromptRouter. Here every
	          prompt is made local-only "Custom" (no popup is drawn) and keyless (E and F do
	          nothing), so Roblox's own prompt input is out of the picture.
	          Version 1 triggered prompts with prompt:InputHoldBegin(). In play that fired late or
	          not at all, and a later click (even on a menu's Close) set off an earlier one. Now a
	          click is a UsePrompt(prompt, "begin" | "end") intent: the server checks reach and
	          line of sight and times holds itself (PromptRouter). People are the exception: their
	          Talk prompt was always client-side, so a click on someone calls
	          NpcDialogueController:greet() (NpcTalk re-checks reach on the server).
	REACH     ours, not Roblox's shown state: the prompt is enabled and its part is within
	          MaxActivationDistance of the body (the server allows a little more).
	HOVER     20 times a second, unless the pointer is over a menu, a ray from the mouse (the screen
	          centre on a gamepad) finds the part under it; the first reachable prompt on that part
	          or up to 6 ancestors is "hovered". It gets a soft outline (one Highlight) and a small
	          label by the cursor: what a click does, and the second action if there is one.
	CLICK     left mouse: begin on press, end on release, so held prompts need the click held (the
	          label fills while you hold). Shift-click uses the second action (prompts whose server
	          key was not E: the old F prompts). Gamepad: X uses, Y the second action (claimed ahead
	          of the screen keys through InterfaceController:setInputClaim). Touch: tap it (held
	          prompts are held for you).
	GATE      CastClient registers setGate(fn) -> (busy, armed). Busy (a readied spell, a raised
	          guard, a charge): no hover, every click stays combat. Armed (a weapon drawn): objects
	          still work, but a click on a person attacks; the label says to put the weapon away.
	CastClient asks claimsClick() before treating a left click as an attack or a cast.

	Cost: one ray at 20 Hz, an ancestor walk of at most 6 levels, a GUI hit test, one Highlight,
	one label.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)

local HOVER_HZ = 20
local RAY_LENGTH = 80
local MAX_DEPTH = 6 -- ancestor levels searched above the part under the pointer
local LABEL_OFFSET = Vector2.new(18, 14)
local HINT_GUI = "InteractHint"

local InteractClickController = {
	name = "InteractClickController",
	dependencies = { "InterfaceController", "NpcDialogueController" },
}

local interface: any = nil
local dialogue: any = nil
local gate: (() -> (boolean, boolean))? = nil

local isAlt: { [ProximityPrompt]: boolean } = setmetatable({}, { __mode = "k" }) :: any -- server key wasn't E

type Hover = { primary: ProximityPrompt, alt: ProximityPrompt?, person: boolean, blocked: boolean, adornee: Instance }
local hover: Hover? = nil
-- A hold the server is timing. `input` ends it on release (nil: a tap, which ends on its own).
type Hold = { prompt: ProximityPrompt, started: number, input: any }
local holding: Hold? = nil

local highlight: Highlight? = nil
local label: TextLabel? = nil
local holdBar: Frame? = nil

-- ─── Prompts ────────────────────────────────────────────────────────────────

-- Local-only: no popup, no key. The server never changes these properties afterwards.
local function configure(prompt: ProximityPrompt)
	if isAlt[prompt] ~= nil then
		return
	end
	isAlt[prompt] = prompt.KeyboardKeyCode ~= Enum.KeyCode.E
	prompt.Style = Enum.ProximityPromptStyle.Custom
	prompt.KeyboardKeyCode = Enum.KeyCode.None
	prompt.GamepadKeyCode = Enum.KeyCode.None
end

local function rootPosition(): Vector3?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

-- Where the prompt is, and the part or model it belongs to.
local function holderOf(prompt: ProximityPrompt): (Vector3?, Instance?)
	local holder = prompt.Parent
	if holder and holder:IsA("Attachment") then
		return holder.WorldPosition, holder.Parent
	elseif holder and holder:IsA("BasePart") then
		return holder.Position, holder
	elseif holder and holder:IsA("Model") then
		return holder:GetPivot().Position, holder
	end
	return nil, nil
end

local function reachable(prompt: ProximityPrompt, from: Vector3): boolean
	if not prompt.Enabled then
		return false
	end
	local point, holder = holderOf(prompt)
	if not point or not holder then
		return false
	end
	local reach = prompt.MaxActivationDistance
	if holder:IsA("BasePart") then
		reach += math.min(holder.Size.Magnitude / 2, 6) -- big parts: measure nearer their surface
	end
	return (point - from).Magnitude <= reach
end

local function promptsOn(node: Instance, from: Vector3, out: { ProximityPrompt })
	for _, child in node:GetChildren() do
		if child:IsA("ProximityPrompt") then
			configure(child)
			if reachable(child, from) then
				table.insert(out, child)
			end
		elseif child:IsA("BasePart") or child:IsA("Attachment") then
			-- One level down: an NPC's Talk prompt sits in its HumanoidRootPart.
			for _, grand in child:GetChildren() do
				if grand:IsA("ProximityPrompt") then
					configure(grand)
					if reachable(grand, from) then
						table.insert(out, grand)
					end
				end
			end
		end
	end
end

-- What gets the outline: the part itself, or the whole model when the prompt sits on an
-- invisible part (an NPC's root, a seat's hit box).
local function adorneeFor(prompt: ProximityPrompt): Instance
	local _, holder = holderOf(prompt)
	if holder and holder:IsA("BasePart") and holder.Transparency < 0.9 then
		return holder
	end
	return prompt:FindFirstAncestorOfClass("Model") or holder or prompt
end

local function npcIdOf(prompt: ProximityPrompt): string?
	local model = prompt:FindFirstAncestorOfClass("Model")
	local id = model and model:GetAttribute("NpcId")
	return if typeof(id) == "string" then id else nil
end

local function isPerson(prompt: ProximityPrompt): boolean
	local model = prompt:FindFirstAncestorOfClass("Model")
	return model ~= nil and model:FindFirstChildOfClass("Humanoid") ~= nil
end

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude

-- The usable thing under a ray, or nil.
local function pick(ray: Ray): Hover?
	local from = rootPosition()
	if not from then
		return nil
	end
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
		promptsOn(node, from, found)
		node = node.Parent
		depth += 1
	end
	if #found == 0 then
		return nil
	end
	-- The plain click: the first non-alt prompt; the second action: the first alt one.
	local primary: ProximityPrompt? = nil
	local alt: ProximityPrompt? = nil
	for _, prompt in found do
		if isAlt[prompt] then
			alt = alt or prompt
		else
			primary = primary or prompt
		end
	end
	if not primary then
		primary, alt = alt, nil -- only a second-action prompt here: a plain click uses it
	end
	local chosen = primary :: ProximityPrompt
	local person = isPerson(chosen)
	local armed = false
	if gate then
		local _, out = gate()
		armed = out
	end
	return { primary = chosen, alt = alt, person = person, blocked = person and armed, adornee = adorneeFor(chosen) }
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

-- Is the pointer over a menu or a button (anything solid but our own label)?
local function overGui(at: Vector2): boolean
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return false
	end
	local inset = GuiService:GetGuiInset()
	for _, object in playerGui:GetGuiObjectsAtPosition(at.X - inset.X, at.Y - inset.Y) do
		local screen = object:FindFirstAncestorOfClass("ScreenGui")
		if screen and screen.Name ~= HINT_GUI and screen.Enabled and object.Visible then
			if object:IsA("GuiButton") or object:IsA("TextBox") or object.BackgroundTransparency < 0.95 then
				return true
			end
		end
	end
	return false
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
		return nil -- no pointer to hover with; taps are picked where they land
	end
	local at = UserInputService:GetMouseLocation()
	if overGui(at) then
		return nil
	end
	return camera:ViewportPointToRay(at.X, at.Y)
end

local function pointerPick(): Hover?
	if gated() then
		return nil
	end
	local ray = pointerRay()
	return if ray then pick(ray) else nil
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
	gui.Name = HINT_GUI
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true -- positions match GetMouseLocation
	gui.DisplayOrder = 5
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")

	local text = Instance.new("TextLabel")
	text.Name = "Label"
	text.Active = false
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
	bar.Size = UDim2.fromOffset(0, 3)
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
			local alt = current.alt
			if alt then
				local key = if gamepadMode() then "Y" else "Shift-click"
				table.insert(lines, string.format("<font size=\"%d\">%s: %s</font>", Theme.text("caption"), key, escape(alt.ActionText)))
			end
		end
		text.Text = table.concat(lines, "\n")
	end
	text.Visible = true
	local camera = workspace.CurrentCamera
	local at = if gamepadMode() and camera then camera.ViewportSize / 2 else UserInputService:GetMouseLocation()
	text.Position = UDim2.fromOffset(at.X + LABEL_OFFSET.X, at.Y + LABEL_OFFSET.Y)
	if held and held.prompt.HoldDuration > 0 then
		local share = math.clamp((os.clock() - held.started) / held.prompt.HoldDuration, 0, 1)
		bar.Size = UDim2.new(share, 0, 0, 3)
		if share >= 1 then
			holding = nil -- the server has finished it
		end
	else
		bar.Size = UDim2.fromOffset(0, 3)
	end
end

-- ─── Using ──────────────────────────────────────────────────────────────────

local function endHold()
	local held = holding
	holding = nil
	if held and held.prompt.HoldDuration > 0 then
		Net.send("UsePrompt", held.prompt, "end")
	end
end

-- Uses a picked thing; returns true if it took the input.
local function use(target: Hover?, wantAlt: boolean, input: any, tap: boolean): boolean
	if not target or target.blocked or gated() then
		return false
	end
	local prompt = if wantAlt and target.alt then target.alt else target.primary
	local npcId = npcIdOf(prompt)
	if npcId and target.person then
		dialogue:greet(npcId) -- Talk is client-side; NpcTalk checks reach on the server
		return true
	end
	if holding then
		endHold()
	end
	Net.send("UsePrompt", prompt, "begin")
	if prompt.HoldDuration > 0 then
		-- A tap is held for you: the server finishes it unless we say "end".
		holding = { prompt = prompt, started = os.clock(), input = if tap then nil else input }
	end
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
	if gamepadMode() then
		return false
	end
	local target = pointerPick()
	hover = target
	return target ~= nil and not target.blocked
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function InteractClickController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	dialogue = ctx.get("NpcDialogueController")
end

function InteractClickController.start(_self: any, _ctx: any)
	-- No popup and no key on any prompt, from the start (the hover also configures lazily).
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

	buildLook()

	-- Mouse: the click (CastClient has already stood aside: claimsClick). A click on a menu is
	-- `processed`, and the pick refuses anything under a menu as well.
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or input.UserInputType ~= Enum.UserInputType.MouseButton1 or gamepadMode() then
			return
		end
		local target = pointerPick()
		hover = target
		use(target, shiftDown(), Enum.UserInputType.MouseButton1, false)
	end)
	UserInputService.InputEnded:Connect(function(input)
		local held = holding
		if held and held.input ~= nil and (input.UserInputType == held.input or input.KeyCode == held.input) then
			endHold()
		end
	end)

	-- Gamepad X / Y: taken ahead of the screen keys only while looking at something usable.
	interface:setInputClaim(function(input: InputObject): boolean
		if not gamepadMode() or (input.KeyCode ~= Enum.KeyCode.ButtonX and input.KeyCode ~= Enum.KeyCode.ButtonY) then
			return false
		end
		return use(pointerPick(), input.KeyCode == Enum.KeyCode.ButtonY, input.KeyCode, false)
	end)

	-- Touch: a tap on the thing.
	UserInputService.TouchTap:Connect(function(positions: { Vector2 }, processed: boolean)
		local camera = workspace.CurrentCamera
		local at = positions[1]
		if processed or not camera or not at or gated() then
			return
		end
		use(pick(camera:ScreenPointToRay(at.X, at.Y)), false, nil, true)
	end)

	-- Hover and the label.
	local elapsed = 0
	RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if elapsed >= 1 / HOVER_HZ then
			elapsed = 0
			hover = pointerPick()
			local held = holding
			if held and (gated() or not held.prompt:IsDescendantOf(workspace)) then
				endHold()
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
