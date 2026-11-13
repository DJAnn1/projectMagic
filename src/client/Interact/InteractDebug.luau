--!strict
--[[
	InteractDebug: the interaction debug overlay (admin `interactdebug`, which sets the Player
	attribute InteractDebug). Plain module, not a controller: InteractClickController and
	NpcDialogueController record into it, InteractClickController starts it.

		InteractDebug.record(source, what, result, ms?, combat?)   one attempt (kept: the last 20)
		InteractDebug.setProvider(fn)   fn() -> { target, why, state, combat } lines for the panel
		InteractDebug.enabled()         is the overlay on for this player?
		InteractDebug.start()           builds the overlay and its 10 Hz refresh

	THE PANEL (top left, never takes input)
		target     what a click would use right now, and why (ray hit, near the cursor, or none)
		raw ray    the first thing under the cursor with NO filter at all: an invisible wall, a
		           trigger box or your own accessory shows up here even when the pick skips it
		gui        every GuiObject under the cursor (PlayerGui:GetGuiObjectsAtPosition), with its
		           path, ZIndex, Active, Visible (including its ancestors), background transparency
		           and its ScreenGui's DisplayOrder: what is covering the screen or a button
		state      the click state machine (idle / pending seq, age, accepted hold)
		combat     readied spell, charging, blocking, weapon drawn, the Click to use setting
		attempts   the last 20 clicks, keys and dialogue buttons, with the result and latency
	Cost while off: nothing but an attribute read per record. While on: one unfiltered ray and one
	GUI hit test 10 times a second.
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local GUI_NAME = "InteractDebug"
local KEEP = 20
local REFRESH = 0.1

export type Lines = { target: string, why: string, state: string, combat: string }

local InteractDebug = {}

type Attempt = { at: number, source: string, what: string, result: string, ms: number?, combat: string? }
local attempts: { Attempt } = {}
local provider: (() -> Lines)? = nil
local label: TextLabel? = nil

function InteractDebug.enabled(): boolean
	return Players.LocalPlayer:GetAttribute("InteractDebug") == true
end

function InteractDebug.setProvider(fn: () -> Lines)
	provider = fn
end

function InteractDebug.record(source: string, what: string, result: string, ms: number?, combat: string?)
	table.insert(attempts, { at = os.clock(), source = source, what = what, result = result, ms = ms, combat = combat })
	while #attempts > KEEP do
		table.remove(attempts, 1)
	end
end

-- The GUI hit test, as text. Our own overlay and the hint label are left out.
local function guiUnder(at: Vector2): { string }
	local lines: { string } = {}
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return lines
	end
	local inset = GuiService:GetGuiInset()
	for _, object in playerGui:GetGuiObjectsAtPosition(at.X - inset.X, at.Y - inset.Y) do
		local screen = object:FindFirstAncestorOfClass("ScreenGui")
		if screen and (screen.Name == GUI_NAME or screen.Name == "InteractHint") then
			continue
		end
		local shown = object.Visible
		local node = object.Parent
		while shown and node and node:IsA("GuiObject") do
			shown = node.Visible
			node = node.Parent
		end
		local path = string.gsub(object:GetFullName(), "^Players%.[^%.]+%.PlayerGui%.", "")
		table.insert(lines, string.format("  %s [%s] Z%d Active=%s Visible=%s BgT=%.2f Display=%s", path, object.ClassName, object.ZIndex,
			tostring(object.Active), tostring(shown), object.BackgroundTransparency, if screen then tostring(screen.DisplayOrder) else "?"))
		if #lines >= 10 then
			table.insert(lines, "  ...")
			break
		end
	end
	if #lines == 0 then
		table.insert(lines, "  (none)")
	end
	return lines
end

-- The first thing under the cursor with no filter at all.
local function rawRay(at: Vector2): string
	local camera = workspace.CurrentCamera
	if not camera then
		return "(no camera)"
	end
	local ray = camera:ViewportPointToRay(at.X, at.Y)
	local hit = workspace:Raycast(ray.Origin, ray.Direction * 200)
	if not hit then
		return "(nothing within 200 studs)"
	end
	local part = hit.Instance
	return string.format("%s  CanCollide=%s Transparency=%.2f  %.1f studs", part:GetFullName(), tostring(part.CanCollide), part.Transparency,
		(hit.Position - ray.Origin).Magnitude)
end

local function render()
	local text = label
	if not text then
		return
	end
	local on = InteractDebug.enabled()
	text.Visible = on
	if not on then
		return
	end
	local at = UserInputService:GetMouseLocation()
	local info: Lines = if provider then provider() else { target = "?", why = "?", state = "?", combat = "?" }
	local out: { string } = {
		"<b>INTERACTION DEBUG</b>  (interactdebug off to hide)",
		"target   " .. info.target,
		"why      " .. info.why,
		"raw ray  " .. rawRay(at),
		"gui under the cursor:",
	}
	for _, line in guiUnder(at) do
		table.insert(out, line)
	end
	table.insert(out, "state    " .. info.state)
	table.insert(out, "combat   " .. info.combat)
	table.insert(out, "last attempts (newest last):")
	local now = os.clock()
	for _, a in attempts do
		table.insert(out, string.format("  -%5.1fs %-8s %s -> %s%s%s", now - a.at, a.source, a.what, a.result,
			if a.ms then string.format(" (%d ms)", math.floor(a.ms + 0.5)) else "",
			if a.combat then " [" .. a.combat .. "]" else ""))
	end
	-- RichText: escape what came from instance names.
	for i = 2, #out do
		out[i] = (string.gsub(string.gsub(string.gsub(out[i], "&", "&amp;"), "<", "&lt;"), ">", "&gt;"))
	end
	text.Text = table.concat(out, "\n")
end

function InteractDebug.start()
	local gui = Instance.new("ScreenGui")
	gui.Name = GUI_NAME
	gui.ResetOnSpawn = false
	gui.IgnoreGuiInset = true
	gui.DisplayOrder = 1000
	local text = Instance.new("TextLabel")
	text.Name = "Panel"
	text.Active = false
	text.Interactable = false
	text.Selectable = false
	text.AutomaticSize = Enum.AutomaticSize.XY
	text.Position = UDim2.fromOffset(10, 60)
	text.Size = UDim2.fromOffset(0, 0)
	text.BackgroundColor3 = Color3.new(0, 0, 0)
	text.BackgroundTransparency = 0.35
	text.TextColor3 = Color3.fromRGB(230, 240, 230)
	text.Font = Enum.Font.Code
	text.TextSize = 13
	text.RichText = true
	text.TextXAlignment = Enum.TextXAlignment.Left
	text.TextYAlignment = Enum.TextYAlignment.Top
	text.Visible = false
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, 6)
	pad.PaddingRight = UDim.new(0, 6)
	pad.PaddingTop = UDim.new(0, 4)
	pad.PaddingBottom = UDim.new(0, 4)
	pad.Parent = text
	text.Parent = gui
	gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	label = text

	local elapsed = 0
	RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if elapsed >= REFRESH then
			elapsed = 0
			render()
		end
	end)
end

return InteractDebug
