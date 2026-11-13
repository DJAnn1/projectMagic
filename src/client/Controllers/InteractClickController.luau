--!strict
--[[
	InteractClickController: the ONE place world-interaction input is decided (docs/Buildings.md,
	docs/UI.md). You use things by clicking them (or E, gamepad X, a tap), not at a popup.

	WHO HANDLES WHAT (one input router, no double handling)
		left mouse   CastClient's single MouseButton1 handler asks tryClick(shift) FIRST; true means
		             the click went to something usable and CastClient does nothing else with it.
		             This controller has no mouse listener of its own any more (it used to have one
		             beside CastClient's, and both re-picked independently).
		E            CastClient asks tryKey() before the spellblade slash: true = used.
		gamepad X/Y  InterfaceController:setInputClaim (ahead of the screen keys).
		touch        a tap on the thing (TouchTap), here.
		NPCs         a person target opens NpcDialogueController:open() (the only way a dialogue
		             starts; the old ProximityPromptService listener is gone).

	PRIORITY WITH CASTING (Combat comes from CastClient's gate)
		charging a spell or blocking   nothing interacts; the input stays combat
		spell readied, not charging    E, gamepad X and taps interact; a click interacts only when
		                               Settings › Click to use is "always" (default "unreadied": the
		                               click casts, and the label says "E")
		weapon drawn                   objects work; a click on a person attacks (label says so)
		in a conversation              the world isn't used (label: leave it first); the panel
		                               itself sinks clicks over its own area

	TARGETING (one function, pick, for the label, the outline, a click, E, X and taps, so what
	you see is always what you get)
		1. A ray from the camera through the cursor (the screen centre on a gamepad, the tap point
		   on touch), excluding your character. A hit on a see-through non-collidable part or one
		   tagged NoInteract is skipped and the ray goes on past it (at most RAY_PASSES).
		2. The prompts that belong to the part hit: on the part itself (or its attachments), else
		   on the nearest model above it: prompts directly on that model, its HumanoidRootPart (a
		   person, a dummy) or PrimaryPart (not for buildings). The walk STOPS at that model. The
		   old walk scanned every child of every ancestor, so a click on a floor, wall or table
		   beside a barrel picked whichever door, bed or lamp in the building came first.
		3. Gamepad and touch only: missed? The usable thing in reach nearest the aim point within
		   NEAR_PIXELS on screen, if the camera can see it. The mouse never uses this: a click
		   (and E, and the outline) is only ever what's really under the cursor.
		Reach is to the thing's nearest surface (Shared/World/Reach, the server's rule too). Out
		of reach but under the cursor within FAR_SHOW studs extra: the label says "too far" and a
		click says so, instead of falling through to a swing or a cast.

	STATE (one object, always reset)
		idle -> pending { seq, prompt } on send -> answered by UsePromptResult (same seq) or reset
		by: its timeout (HoldDuration + TIMEOUT_EXTRA), death/respawn, the prompt leaving the
		world, starting a charge or a block. A hold the server accepted shows a filling bar.
		Clicking the same thing while pending does nothing (never a toggle); something else
		replaces it. COOLDOWN between sends (the server has the same). NOT_READY retries once.
		Every refusal is said in words (REASON_TEXT); RATE_LIMITED, DEAD and DENIED (the server
		already said it) stay quiet but show in the debug overlay.

	DEBUG  admin `interactdebug` (Client/Interact/InteractDebug): target and why, raw ray, GUI
	       under the cursor, state, combat, the last 20 attempts with latency.

	Cost: one or a few rays at 20 Hz, a scan of known prompts for the near-cursor fallback (a
	distance check each, a box distance and a projection for those close), one GUI hit test,
	one Highlight, one label.
]]

local CollectionService = game:GetService("CollectionService")
local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Reach = require(Shared.World.Reach)

local Client = script.Parent.Parent
local Theme = require(Client:WaitForChild("UI").Theme)
local InteractDebug = require(Client:WaitForChild("Interact").InteractDebug)

local HOVER_HZ = 20
local RAY_LENGTH = 80
local RAY_PASSES = 4
local MAX_DEPTH = 6 -- levels walked up from the part hit to find its model
local NEAR_PIXELS = 36
local FAR_SHOW = 12 -- studs past its reach that a thing under the cursor still shows "too far"
local COOLDOWN = 0.15
local TIMEOUT_EXTRA = 2
local RETRY_DELAY = 0.3
local LABEL_OFFSET = Vector2.new(18, 14)
local HINT_GUI = "InteractHint"
local DEBUG_GUI = "InteractDebug"

local REASON_TEXT: { [string]: string } = {
	TOO_FAR = "Too far away.",
	NO_SIGHT = "You can't reach it from here.",
	LOCKED = "Locked.",
	IN_USE = "Someone else is using that.",
	NOT_READY = "That isn't ready yet. Try again in a moment.",
	DISABLED = "That can't be used right now.",
	INVALID = "That can't be used.",
	NOT_A_CONTAINER = "That can't be opened.",
	ERROR = "That didn't work (it's been logged).",
	REFUSED = "That didn't work.",
	TIMEOUT = "No answer. Try again.",
	DROPPED = "Too many clicks. Try again.",
}

export type Combat = { attuned: boolean, charging: boolean, guarding: boolean, armed: boolean }

local InteractClickController = {
	name = "InteractClickController",
	dependencies = { "InterfaceController", "NpcDialogueController", "MagicStateController" },
}

local interface: any = nil
local dialogue: any = nil
local magic: any = nil
local gate: (() -> Combat)? = nil

local isAlt: { [ProximityPrompt]: boolean } = setmetatable({}, { __mode = "k" }) :: any -- server key wasn't E
local known: { [ProximityPrompt]: boolean } = setmetatable({}, { __mode = "k" }) :: any -- for the near-cursor fallback

type Target = {
	primary: ProximityPrompt,
	alt: ProximityPrompt?,
	person: boolean,
	npcId: string?,
	distance: number,
	far: boolean,
	blocked: string?, -- "armed" (a click attacks) | "talking" (in a conversation)
	adornee: Instance,
	how: string,
}
local hover: Target? = nil
local hoverWhy = "not looked yet"

type Pending = {
	seq: number,
	prompt: ProximityPrompt,
	source: string,
	sentAt: number,
	deadline: number,
	accepted: boolean,
	hold: number,
	retried: boolean,
	combat: string,
}
local pending: Pending? = nil
local seqCounter = 0
local lastSend = -math.huge
local workingUntil = 0
local lastFeedback: { text: string, at: number }? = nil

local highlight: Highlight? = nil
local label: TextLabel? = nil
local holdBar: Frame? = nil

-- ─── Small helpers ──────────────────────────────────────────────────────────

-- Local-only: no popup, no key. The server never changes these properties afterwards.
local function configure(prompt: ProximityPrompt)
	known[prompt] = true
	if isAlt[prompt] ~= nil then
		return
	end
	isAlt[prompt] = prompt.KeyboardKeyCode ~= Enum.KeyCode.E
	prompt.Style = Enum.ProximityPromptStyle.Custom
	-- Keys are left alone. They used to be set to KeyCode.None, which is the KeyCode every MOUSE
	-- button carries: Roblox's prompt input then claimed every click (left and right) while a
	-- prompt was in range, so clicks arrived game-processed, buttons got no events, right-drag
	-- couldn't turn the camera and the nearest prompt fired by itself (2026-11-12).
	-- ProximityPromptService is switched off in start() instead.
end

local function rootPosition(): Vector3?
	local character = Players.LocalPlayer.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

local function combat(): Combat
	if gate then
		return gate()
	end
	return { attuned = false, charging = false, guarding = false, armed = false }
end

local function combatText(c: Combat): string
	local parts: { string } = {}
	if c.attuned then
		table.insert(parts, "readied")
	end
	if c.charging then
		table.insert(parts, "charging")
	end
	if c.guarding then
		table.insert(parts, "blocking")
	end
	if c.armed then
		table.insert(parts, "weapon out")
	end
	return if #parts > 0 then table.concat(parts, ",") else "free"
end

local function clickSetting(): string
	local settings = magic.settings:get()
	return if settings and settings.interactClick == "always" then "always" else "unreadied"
end

local function gamepadMode(): boolean
	return interface.inputMode:get() == "Gamepad"
end

-- May this kind of input interact right now? (allowed, why not)
local function allowed(source: string): (boolean, string?)
	if interface:isInputBlocked() then
		return false, "a screen is open"
	end
	local c = combat()
	if c.charging then
		return false, "charging a spell"
	end
	if c.guarding then
		return false, "blocking"
	end
	if source == "click" and c.attuned and clickSetting() ~= "always" then
		return false, "spell readied: the click casts (E uses)"
	end
	return true, nil
end

local function feedback(text: string?)
	if not text then
		return
	end
	local now = os.clock()
	local last = lastFeedback
	if last and last.text == text and now - last.at < 1 then
		return
	end
	lastFeedback = { text = text, at = now }
	magic.events:Fire({ kind = "notify", text = text })
end

-- ─── Targeting ──────────────────────────────────────────────────────────────

local function promptsDirectlyOn(node: Instance, out: { ProximityPrompt })
	for _, child in node:GetChildren() do
		if child:IsA("ProximityPrompt") then
			configure(child)
			table.insert(out, child)
		elseif child:IsA("Attachment") then
			for _, grand in child:GetChildren() do
				if grand:IsA("ProximityPrompt") then
					configure(grand)
					table.insert(out, grand)
				end
			end
		end
	end
end

-- The prompts that belong to the thing this part is part of (see TARGETING 2).
local function promptsFor(part: BasePart): { ProximityPrompt }
	local out: { ProximityPrompt } = {}
	promptsDirectlyOn(part, out)
	if #out > 0 then
		return out
	end
	local node: Instance? = part.Parent
	local depth = 0
	while node and node ~= workspace and depth < MAX_DEPTH do
		if node:IsA("Model") then
			promptsDirectlyOn(node, out)
			local humanoid = node:FindFirstChildOfClass("Humanoid")
			local anchor: Instance? = if humanoid then node:FindFirstChild("HumanoidRootPart")
				elseif not CollectionService:HasTag(node, "Building") then node.PrimaryPart
				else nil
			if anchor and anchor ~= part then
				promptsDirectlyOn(anchor, out)
			end
			return out -- stop at the first model: a building's other parts are other things
		elseif node:IsA("BasePart") then
			promptsDirectlyOn(node, out) -- a part parented under the part that holds the prompt
			if #out > 0 then
				return out
			end
		end
		node = node.Parent
		depth += 1
	end
	return out
end

local function hasPrompt(part: BasePart): boolean
	return part:FindFirstChildOfClass("ProximityPrompt") ~= nil
end

-- Parts the ray goes straight through: tagged NoInteract, or a see-through, non-collidable
-- part that isn't itself usable (trigger boxes, glows, effect shells).
local function passThrough(part: BasePart): boolean
	if CollectionService:HasTag(part, "NoInteract") then
		return true
	end
	return not part.CanCollide and part.Transparency >= 0.9 and not hasPrompt(part)
end

local params = RaycastParams.new()
params.FilterType = Enum.RaycastFilterType.Exclude

local function castRay(ray: Ray): BasePart?
	local character = Players.LocalPlayer.Character
	local exclude: { Instance } = if character then { character } else {}
	for _ = 1, RAY_PASSES do
		params.FilterDescendantsInstances = exclude
		local result = workspace:Raycast(ray.Origin, ray.Direction * RAY_LENGTH, params)
		if not result then
			return nil
		end
		local part = result.Instance
		if not passThrough(part) then
			return part
		end
		table.insert(exclude, part)
	end
	return nil
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

-- What gets the outline: the part itself, or the whole model when the prompt sits on an
-- invisible part (an NPC's root, a seat's hit box).
local function adorneeFor(prompt: ProximityPrompt): Instance
	local _, holder = Reach.holderOf(prompt)
	if holder and holder:IsA("BasePart") and holder.Transparency < 0.9 then
		return holder
	end
	return prompt:FindFirstAncestorOfClass("Model") or holder or prompt
end

-- A target from the prompts of one thing, or nil (none enabled, too far to even show, or the
-- person you're already talking to).
local function targetFrom(found: { ProximityPrompt }, from: Vector3, how: string): Target?
	local primary: ProximityPrompt? = nil
	local alt: ProximityPrompt? = nil
	for _, prompt in found do
		if prompt.Enabled then
			if isAlt[prompt] then
				alt = alt or prompt
			else
				primary = primary or prompt
			end
		end
	end
	if not primary then
		primary, alt = alt, nil -- only a second-action prompt here: a plain click uses it
	end
	local chosen = primary
	if not chosen then
		return nil
	end
	local distance = Reach.toPrompt(chosen, from)
	if distance > chosen.MaxActivationDistance + FAR_SHOW then
		return nil
	end
	local person = isPerson(chosen)
	local npcId = if person then npcIdOf(chosen) else nil
	if npcId and dialogue:isTalkingTo(npcId) then
		return nil -- already talking: no outline, no second greeting
	end
	local blocked: string? = nil
	if dialogue:isOpen() then
		blocked = "talking"
	elseif person and combat().armed then
		blocked = "armed"
	end
	return {
		primary = chosen,
		alt = alt,
		person = person,
		npcId = npcId,
		distance = distance,
		far = distance > chosen.MaxActivationDistance,
		blocked = blocked,
		adornee = adorneeFor(chosen),
		how = how,
	}
end

-- Can the camera see this prompt's thing? (the fallback must not pick through walls)
local function cameraSees(camera: Camera, prompt: ProximityPrompt, point: Vector3): boolean
	local _, holder = Reach.holderOf(prompt)
	if not holder then
		return false
	end
	local origin = camera.CFrame.Position
	local offset = point - origin
	if offset.Magnitude < 0.01 then
		return true
	end
	local character = Players.LocalPlayer.Character
	params.FilterDescendantsInstances = if character then { character } else {}
	local result = workspace:Raycast(origin, offset.Unit * (offset.Magnitude + 1), params)
	if not result then
		return true
	end
	local part = result.Instance
	local owner = holder:FindFirstAncestorOfClass("Model")
	return part == holder or part:IsDescendantOf(holder) or (owner ~= nil and not CollectionService:HasTag(owner, "Building") and part:IsDescendantOf(owner))
end

-- The fallback: the usable thing in reach nearest the cursor on screen (TARGETING 3).
local function nearCursor(at: Vector2, from: Vector3, camera: Camera): Target?
	type Candidate = { prompt: ProximityPrompt, point: Vector3, px: number }
	local candidates: { Candidate } = {}
	for prompt in known do
		if not prompt.Enabled or not prompt:IsDescendantOf(workspace) then
			continue
		end
		local point = Reach.holderOf(prompt)
		if not point or (point - from).Magnitude > prompt.MaxActivationDistance + 8 then
			continue -- cheap first cut before the box distance
		end
		if Reach.toPrompt(prompt, from) > prompt.MaxActivationDistance then
			continue
		end
		local screen, onScreen = camera:WorldToViewportPoint(point)
		if onScreen and screen.Z > 0 then
			local px = (Vector2.new(screen.X, screen.Y) - at).Magnitude
			if px <= NEAR_PIXELS then
				table.insert(candidates, { prompt = prompt, point = point, px = px })
			end
		end
	end
	table.sort(candidates, function(a, b)
		return a.px < b.px
	end)
	for i = 1, math.min(#candidates, 3) do
		local c = candidates[i]
		if cameraSees(camera, c.prompt, c.point) then
			local holderPart = c.prompt.Parent
			local found: { ProximityPrompt } = {}
			if holderPart then
				promptsDirectlyOn(holderPart, found)
			end
			if #found == 0 then
				found = { c.prompt }
			end
			local target = targetFrom(found, from, string.format("near cursor (%d px)", math.floor(c.px)))
			if target then
				return target
			end
		end
	end
	return nil
end

-- THE pick: everything that shows or uses a target goes through here. (target, why)
-- `exact`: the mouse. Only what the ray under the cursor hits, never the near-cursor fallback
-- (2026-11-12, owner: "I click things even though I'm not hovering over it"). The fallback
-- stays for the gamepad's screen centre and touch taps, which can't point that precisely.
local function pickAt(at: Vector2, exact: boolean?): (Target?, string)
	local from = rootPosition()
	local camera = workspace.CurrentCamera
	if not from or not camera then
		return nil, "no character or camera"
	end
	local part = castRay(camera:ViewportPointToRay(at.X, at.Y))
	if part then
		local found = promptsFor(part)
		if #found > 0 then
			local target = targetFrom(found, from, "ray: " .. part.Name)
			if target then
				return target, "ray hit " .. part:GetFullName()
			end
		end
	end
	local near = if exact then nil else nearCursor(at, from, camera)
	if near then
		return near, near.how
	end
	return nil, if part then "ray hit " .. part:GetFullName() .. " (nothing usable)" else "ray hit nothing"
end

-- Is the pointer over a menu or a button? (our own label and the debug overlay don't count)
local function overGui(at: Vector2): boolean
	local playerGui = Players.LocalPlayer:FindFirstChildOfClass("PlayerGui")
	if not playerGui then
		return false
	end
	local inset = GuiService:GetGuiInset()
	for _, object in playerGui:GetGuiObjectsAtPosition(at.X - inset.X, at.Y - inset.Y) do
		local screen = object:FindFirstAncestorOfClass("ScreenGui")
		if not screen or screen.Name == HINT_GUI or screen.Name == DEBUG_GUI or not screen.Enabled then
			continue
		end
		-- Only what's really drawn: the object and every GuiObject above it visible.
		local shown = object.Visible
		local node = object.Parent
		while shown and node and node:IsA("GuiObject") do
			shown = node.Visible
			node = node.Parent
		end
		if shown and (object:IsA("GuiButton") or object:IsA("TextBox") or object.Active or object.BackgroundTransparency < 0.95) then
			return true
		end
	end
	return false
end

-- Where the pointer is in viewport pixels, or nil (over a menu; touch has no pointer).
local function pointer(): (Vector2?, string)
	local camera = workspace.CurrentCamera
	if not camera then
		return nil, "no camera"
	end
	if gamepadMode() then
		return camera.ViewportSize / 2, "screen centre"
	end
	if interface.inputMode:get() == "Touch" then
		return nil, "touch: taps only"
	end
	local at = UserInputService:GetMouseLocation()
	if overGui(at) then
		return nil, "pointer over a menu"
	end
	return at, "cursor"
end

-- ─── Using ──────────────────────────────────────────────────────────────────

local function resetPending(result: string, say: boolean)
	local p = pending
	pending = nil
	if not p then
		return
	end
	if p.accepted and p.hold > 0 and os.clock() - p.sentAt < p.hold then
		Net.send("UsePrompt", p.prompt, "end", p.seq) -- let the server drop the hold too
	end
	InteractDebug.record(p.source, p.prompt.ActionText .. " " .. p.prompt.ObjectText, result, (os.clock() - p.sentAt) * 1000, p.combat)
	if say then
		feedback(REASON_TEXT[result])
	end
end

local function send(prompt: ProximityPrompt, source: string, combatState: string, retried: boolean): boolean
	seqCounter += 1
	local now = os.clock()
	local p: Pending = {
		seq = seqCounter,
		prompt = prompt,
		source = source,
		sentAt = now,
		deadline = now + prompt.HoldDuration + TIMEOUT_EXTRA,
		accepted = false,
		hold = prompt.HoldDuration,
		retried = retried,
		combat = combatState,
	}
	lastSend = now
	if not Net.send("UsePrompt", prompt, "begin", p.seq) then
		InteractDebug.record(source, prompt.ActionText .. " " .. prompt.ObjectText, "DROPPED (client limiter)", nil, combatState)
		feedback(REASON_TEXT.DROPPED)
		return false
	end
	pending = p
	return true
end

-- Uses a target; true if the input was taken (CastClient then leaves it alone).
local function use(target: Target?, wantAlt: boolean, source: string, why: string): boolean
	local c = combat()
	local cText = combatText(c)
	if not target then
		InteractDebug.record(source, "(nothing)", "passed on: " .. why, nil, cText)
		return false
	end
	local prompt = if wantAlt and target.alt then target.alt else target.primary
	local what = prompt.ActionText .. " " .. prompt.ObjectText
	if target.blocked == "armed" then
		InteractDebug.record(source, what, "passed on: weapon drawn (a click on a person attacks)", nil, cText)
		return false
	elseif target.blocked == "talking" then
		InteractDebug.record(source, what, "refused: in a conversation", nil, cText)
		feedback("You're in a conversation. Leave it first (✕).")
		return true
	end
	if target.far then
		InteractDebug.record(source, what, string.format("TOO_FAR (client, %.1f studs)", target.distance), nil, cText)
		feedback(REASON_TEXT.TOO_FAR)
		return true
	end
	if target.person and target.npcId then
		local ok, refusal = dialogue:open(target.npcId, source)
		InteractDebug.record(source, "Talk " .. target.npcId, if ok then "dialogue opening" else "refused: " .. tostring(refusal), nil, cText)
		return true
	end
	local p = pending
	if p and p.prompt == prompt then
		InteractDebug.record(source, what, "ignored: already under way (seq " .. p.seq .. ")", nil, cText)
		return true -- a second click never restarts or toggles it
	end
	if os.clock() - lastSend < COOLDOWN then
		InteractDebug.record(source, what, "ignored: client cooldown", nil, cText)
		return true
	end
	if p then
		resetPending("CANCELLED (replaced)", false)
	end
	send(prompt, source, cText, false)
	return true
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
	text.Interactable = false
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

-- The key hint in front of the action: what will use it right now.
local function keyHint(): string
	if gamepadMode() then
		return "[X] "
	end
	if interface.inputMode:get() == "Touch" then
		return ""
	end
	return if allowed("click") then "[Click / E] " else "[E] "
end

local function render()
	local h, text, bar = highlight, label, holdBar
	if not h or not text or not bar then
		return
	end
	local current = hover
	local held = pending
	if not current and not held then
		h.Enabled = false
		text.Visible = false
		return
	end
	if current then
		h.Adornee = current.adornee
		h.Enabled = current.blocked == nil and not current.far
		local lines: { string } = {}
		if current.blocked == "armed" then
			table.insert(lines, "<font transparency=\"0.3\">Put your weapon away (Q) to talk</font>")
		elseif current.blocked == "talking" then
			table.insert(lines, "<font transparency=\"0.3\">In a conversation (✕ to leave it)</font>")
		elseif current.far then
			table.insert(lines, lineFor(current.primary) .. "  <font transparency=\"0.3\">too far</font>")
		else
			table.insert(lines, escape(keyHint()) .. lineFor(current.primary))
			local alt = current.alt
			if alt then
				local key = if gamepadMode() then "Y" else "Shift-click"
				table.insert(lines, string.format("<font size=\"%d\">%s: %s</font>", Theme.text("caption"), key, escape(alt.ActionText)))
			end
		end
		if os.clock() < workingUntil then
			table.insert(lines, string.format("<font size=\"%d\">Working…</font>", Theme.text("caption")))
		end
		text.Text = table.concat(lines, "\n")
	end
	text.Visible = true
	local camera = workspace.CurrentCamera
	local at = if gamepadMode() and camera then camera.ViewportSize / 2 else UserInputService:GetMouseLocation()
	text.Position = UDim2.fromOffset(at.X + LABEL_OFFSET.X, at.Y + LABEL_OFFSET.Y)
	if held and held.accepted and held.hold > 0 then
		bar.Size = UDim2.new(math.clamp((os.clock() - held.sentAt) / held.hold, 0, 1), 0, 0, 3)
	else
		bar.Size = UDim2.fromOffset(0, 3)
	end
end

-- ─── Answers from the server ────────────────────────────────────────────────

local function onResult(result: any)
	if typeof(result) ~= "table" or typeof(result.seq) ~= "number" then
		return
	end
	local p = pending
	if not p or p.seq ~= result.seq then
		InteractDebug.record("server", "seq " .. tostring(result.seq), "stale answer ignored: " .. tostring(result.reason or (if result.ok then "ok" else "?")))
		return
	end
	local ms = (os.clock() - p.sentAt) * 1000
	local what = p.prompt.ActionText .. " " .. p.prompt.ObjectText
	if result.ok and result.pending then
		p.accepted = true
		p.deadline = os.clock() + (tonumber(result.hold) or p.hold) + TIMEOUT_EXTRA
		InteractDebug.record(p.source, what, "accepted, hold running", ms, p.combat)
		return
	end
	pending = nil
	if result.ok then
		InteractDebug.record(p.source, what, "OK", ms, p.combat)
		return
	end
	local reason = if typeof(result.reason) == "string" then result.reason else "REFUSED"
	InteractDebug.record(p.source, what, reason, ms, p.combat)
	if reason == "NOT_READY" and not p.retried then
		-- Streaming or a service still setting the thing up: once more, shortly.
		workingUntil = os.clock() + RETRY_DELAY + 0.6
		local prompt = p.prompt
		task.delay(RETRY_DELAY, function()
			if pending == nil and prompt:IsDescendantOf(workspace) then
				send(prompt, p.source, p.combat, true)
			end
		end)
		return
	end
	if typeof(result.text) == "string" then
		feedback(result.text)
	else
		feedback(REASON_TEXT[reason])
	end
end

-- ─── Public ─────────────────────────────────────────────────────────────────

-- CastClient: the combat state every decision reads.
function InteractClickController.setGate(_self: any, fn: () -> Combat)
	gate = fn
end

-- CastClient's left click. True: it was used here, so don't cast or attack with it.
function InteractClickController.tryClick(_self: any, shift: boolean): boolean
	if gamepadMode() then
		return false
	end
	local ok, whyNot = allowed("click")
	if not ok then
		InteractDebug.record("click", "-", "passed on: " .. tostring(whyNot), nil, combatText(combat()))
		return false
	end
	local at, how = pointer()
	if not at then
		InteractDebug.record("click", "-", "passed on: " .. how, nil, combatText(combat()))
		return false
	end
	local target, why = pickAt(at, true)
	hover, hoverWhy = target, why
	return use(target, shift, "click", why)
end

-- CastClient's E. True: used here, so no spellblade slash.
function InteractClickController.tryKey(_self: any): boolean
	local ok, whyNot = allowed("key")
	if not ok then
		InteractDebug.record("E", "-", "passed on: " .. tostring(whyNot), nil, combatText(combat()))
		return false
	end
	local at, how = pointer()
	if not at then
		InteractDebug.record("E", "-", "passed on: " .. how, nil, combatText(combat()))
		return false
	end
	local target, why = pickAt(at, not gamepadMode())
	hover, hoverWhy = target, why
	return use(target, false, "E", why)
end

-- CastClient: Roblox marked a left click as handled by a GUI. Was it really ours (a menu,
-- a button or a panel in the PlayerGui under the cursor)? If not, something invisible outside
-- the PlayerGui swallowed a click meant for the world (a trace on 2026-11-12 showed clicks on
-- NPCs arriving "processed" with nothing of ours there), and CastClient still offers it to
-- tryClick, never to casting.
function InteractClickController.guiTookClick(_self: any): boolean
	return overGui(UserInputService:GetMouseLocation())
end

-- CastClient: a dialogue is open (gamepad B closes it instead of slashing).
function InteractClickController.dialogueOpen(_self: any): boolean
	return dialogue:isOpen()
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function InteractClickController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	dialogue = ctx.get("NpcDialogueController")
	magic = ctx.get("MagicStateController")
end

function InteractClickController.start(_self: any, _ctx: any)
	-- No popup and no key on any prompt, from the start (the pick also configures lazily).
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
	Net.listen("UsePromptResult", onResult)

	-- Roblox's own prompt system is OFF on this client: nothing is shown, no key or mouse button
	-- is bound, and nothing can fire Triggered. Every use goes through UsePrompt (PromptRouter).
	local promptService = game:GetService("ProximityPromptService")
	local offOk, offErr = pcall(function()
		promptService.Enabled = false
	end)
	require(Shared.Core.Logger).new("InteractTrace"):info("prompt_service_off", { ok = offOk, enabled = promptService.Enabled, err = if offOk then nil else tostring(offErr) })

	-- Gamepad X / Y: taken ahead of the screen keys only while looking at something usable.
	interface:setInputClaim(function(input: InputObject): boolean
		if not gamepadMode() or (input.KeyCode ~= Enum.KeyCode.ButtonX and input.KeyCode ~= Enum.KeyCode.ButtonY) then
			return false
		end
		if not allowed("gamepad") then
			return false
		end
		local camera = workspace.CurrentCamera
		if not camera then
			return false
		end
		local target, why = pickAt(camera.ViewportSize / 2)
		return use(target, input.KeyCode == Enum.KeyCode.ButtonY, "gamepad", why)
	end)

	-- Touch: a tap on the thing (tap positions are GUI space: add the top-bar inset).
	UserInputService.TouchTap:Connect(function(positions: { Vector2 }, processed: boolean)
		local at = positions[1]
		if processed or not at or not allowed("touch") then
			return
		end
		local target, why = pickAt(at + GuiService:GetGuiInset())
		use(target, false, "tap", why)
	end)

	-- Hover, the label, and the state machine's timeouts.
	local elapsed = 0
	RunService.RenderStepped:Connect(function(dt)
		elapsed += dt
		if elapsed >= 1 / HOVER_HZ then
			elapsed = 0
			local ok, whyNot = allowed("key")
			if ok then
				local at, how = pointer()
				if at then
					hover, hoverWhy = pickAt(at, not gamepadMode()) -- the outline matches what a click uses
				else
					hover, hoverWhy = nil, how
				end
			else
				hover, hoverWhy = nil, tostring(whyNot)
			end
			local p = pending
			if p then
				local c = combat()
				if os.clock() > p.deadline then
					resetPending("TIMEOUT", true)
				elseif not p.prompt:IsDescendantOf(workspace) then
					resetPending("CANCELLED (gone from the world)", false)
				elseif c.charging or c.guarding then
					resetPending("CANCELLED (combat)", false)
				end
			end
		end
		render()
	end)

	-- Death and respawn always clear the state.
	local function watch(character: Model)
		local humanoid = character:WaitForChild("Humanoid", 10)
		if humanoid and humanoid:IsA("Humanoid") then
			humanoid.Died:Connect(function()
				resetPending("CANCELLED (died)", false)
				hover = nil
			end)
		end
	end
	Players.LocalPlayer.CharacterAdded:Connect(function(character)
		resetPending("CANCELLED (respawned)", false)
		hover = nil
		task.spawn(watch, character)
	end)
	if Players.LocalPlayer.Character then
		task.spawn(watch, Players.LocalPlayer.Character)
	end

	-- The debug overlay reads its live lines from here.
	InteractDebug.setProvider(function(): InteractDebug.Lines
		local t = hover
		local p = pending
		local c = combat()
		return {
			target = if t
				then string.format("%s %s on %s  %.1f studs (reach %.0f)%s%s", t.primary.ActionText, t.primary.ObjectText, t.primary.Parent and t.primary.Parent:GetFullName() or "?",
					t.distance, t.primary.MaxActivationDistance, if t.far then "  TOO FAR" else "", if t.blocked then "  blocked: " .. t.blocked else "")
				else "(none)",
			why = hoverWhy,
			state = if p
				then string.format("pending seq %d  %s %s  %.2fs%s", p.seq, p.prompt.ActionText, p.prompt.ObjectText, os.clock() - p.sentAt, if p.accepted then "  hold accepted" else "  awaiting answer")
				else "idle",
			combat = string.format("%s  click setting: %s  dialogue: %s", combatText(c), clickSetting(), if dialogue:isOpen() then "open" else "closed"),
		}
	end)
	InteractDebug.start()
end

return InteractClickController
