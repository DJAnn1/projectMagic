--!strict
--[[
	NpcDialogueController: talking to NPCs.

		a click / E / X / tap on someone (InteractClickController) -> open(npcId)
		    -> NpcTalk(npcId, "greet") -> a dialogue panel above the hotbar
		option buttons (topics: greet, self, magic, rumor, work, learn, quest, farewell)
		    -> NpcTalk(npcId, topic)
		✕ in the panel's top-right corner, Goodbye, Escape (the Roblox menu), gamepad B, walking
		away, the NPC going away or busy, dying -> close -> NpcTalkEnd(npcId)
		NpcSpeech { npcId, text } -> a chat bubble over that NPC (TextChatService:DisplayBubble)

	The server decides everything: distance (<= 14 studs), what the NPC says, whether it teaches.
	Mood and relationship are shown as words, never as colour alone.

	SESSIONS  A conversation is a session { id, npcId }. Every request remembers the session it
	          was sent from; a reply that comes back after that session closed (or switched to
	          someone else) is DROPPED. Before, talk() set the panel from any reply, so a reply
	          still on its way when you pressed Close reopened the panel with the NPC's answer.
	OPTIONS   One list per reply: the server's topics, plus Goodbye if it's missing. Each button
	          is made once per render and calls choose(sessionId, optionId) with values captured
	          for that button (Activated: press and release on the same button).
	CLOSE     Not one of the options: a ✕ fixed in the panel's top-right corner, outside the
	          option grid, so no layout of options can ever put another button where it is.
	GUARD     After every render (open, new reply, rebuild) the buttons ignore activation for
	          ARM_SECONDS and until the mouse button that was down has been released, so the
	          click that opened or changed the panel can't also press what appears under it.
	REOPEN    After a close, this NPC can't be re-opened for REOPEN_BLOCK seconds or while the
	          closing click's button is still held (the server refuses a greet within 0.5 s of
	          NpcTalkEnd too). While a conversation is open the NPC isn't clickable at all.
	KEYS      No default selection (GuiService.SelectedObject stays clear), so Enter or Space
	          never press "Hello". The panel is Active: a click on its background stays in the
	          panel instead of casting or swinging into the world.

	Debug: every button handler that fires (or is ignored, and why), every stale reply and every
	open/close goes to the interaction debug overlay (admin `interactdebug`).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Registry = require(Shared.Magic.Registry)

local Client = script.Parent.Parent
local UI = Client:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local InteractDebug = require(Client:WaitForChild("Interact").InteractDebug)

local WALK_AWAY = 18
local ARM_SECONDS = 0.2
local REOPEN_BLOCK = 0.6
local FAREWELL_LINGER = 2.5

local TOPIC_LABELS: { [string]: string } = {
	greet = "Hello",
	self = "About you",
	magic = "Your magic",
	rumor = "Any news?",
	work = "Your work",
	learn = "Teach me",
	quest = "About the trouble",
	farewell = "Goodbye",
}
local MOOD_GLYPHS: { [string]: string } = {
	cheerful = "☀ cheerful",
	content = "• content",
	tired = "☾ tired",
	hungry = "◌ hungry",
	anxious = "! anxious",
	angry = "✗ angry",
	grieving = "▽ grieving",
}
local STUDY_REASONS: { [string]: string } = {
	ON_COOLDOWN = "You've had a lesson from them recently. Come back tomorrow.",
	ALREADY_STUDIED = "You've already learned what they can teach.",
}

type Dialogue = {
	sessionId: number,
	npcId: string,
	name: string,
	occupation: string,
	text: string,
	mood: string,
	rel: string,
	topics: { string },
	note: string?,
}

type Session = { id: number, npcId: string, inFlight: boolean, linked: boolean? } -- linked: through a Mindlink (no body nearby)

local NpcDialogueController = {
	name = "NpcDialogueController",
	dependencies = { "InterfaceController" },
}

local log: any = nil
local current = Kit.value(nil :: Dialogue?)
local session: Session? = nil
local sessionSeq = 0
local blockedUntil: { [string]: number } = {}
local waitRelease = false -- a close happened with the mouse button down: no re-open until it's up
local armAt = 0
local needRelease = false

local function npcModel(npcId: string): Model?
	local folder = workspace:FindFirstChild("NPCs")
	if not folder then
		return nil
	end
	for _, child in folder:GetChildren() do
		if child:IsA("Model") and child:GetAttribute("NpcId") == npcId then
			return child
		end
	end
	return nil
end

local function mouseDown(): boolean
	return UserInputService:IsMouseButtonPressed(Enum.UserInputType.MouseButton1)
end

local function closeSession(reason: string)
	local s = session
	if not s then
		return
	end
	session = nil
	Net.send("NpcTalkEnd", s.npcId) -- so they don't stand waiting for you
	blockedUntil[s.npcId] = os.clock() + REOPEN_BLOCK
	waitRelease = mouseDown()
	GuiService.SelectedObject = nil
	current:set(nil)
	InteractDebug.record("dialogue", s.npcId, "closed: " .. reason)
end

-- One request for one session. A reply for a session that is no longer the open one is dropped.
local function request(s: Session, topic: string, source: string)
	if s.inFlight then
		InteractDebug.record("dialogue", topic, "ignored: waiting for the last answer")
		return
	end
	s.inFlight = true
	task.spawn(function()
		local started = os.clock()
		local ok, payload = Net.invoke("NpcTalk", s.npcId, topic)
		s.inFlight = false
		local ms = (os.clock() - started) * 1000
		if session ~= s then
			InteractDebug.record("dialogue", topic, "stale reply dropped (the conversation was closed)", ms)
			return
		end
		if not ok or typeof(payload) ~= "table" or not payload.ok then
			local reason = if typeof(payload) == "table" then tostring(payload.reason) else tostring(payload)
			InteractDebug.record(source, "NpcTalk " .. topic, "refused: " .. reason, ms)
			local shown = current:get()
			if reason == "linked_learn" and shown then
				local note = table.clone(shown)
				note.note = "Nobody can teach you through a Mindlink. Go and see them."
				current:set(note)
				return
			end
			if current:get() == nil or reason == "too_far" then
				-- Nothing on screen yet (the greeting itself was refused), or they're out of reach.
				session = nil
				current:set(nil)
			end
			return
		end
		local note: string? = nil
		local studied = payload.studied
		if typeof(studied) == "table" then
			local branch = Registry.branches[studied.branch]
			local branchName = if branch then branch.name else tostring(studied.branch)
			note = if studied.ok then "You learned something about " .. branchName .. "." else STUDY_REASONS[studied.reason] or nil
		end
		current:set({
			sessionId = s.id,
			npcId = payload.npcId,
			name = payload.name,
			occupation = if payload.linked then tostring(payload.occupation) .. " · through Mindlink" else payload.occupation,
			text = payload.text,
			mood = payload.mood,
			rel = payload.rel,
			topics = payload.topics,
			note = note,
		})
		InteractDebug.record(source, "NpcTalk " .. topic, "shown", ms)
		if topic == "farewell" then
			task.delay(FAREWELL_LINGER, function()
				if session == s then
					closeSession("goodbye said")
				end
			end)
		end
	end)
end

-- Every button goes through here: the session it was drawn for, and the option's id.
local function choose(sessionId: number, optionId: string, label: string)
	local s = session
	if not s or s.id ~= sessionId then
		InteractDebug.record("dialogue", label, "ignored: a button from an old panel")
		return
	end
	if os.clock() < armAt or needRelease then
		InteractDebug.record("dialogue", label, "ignored: click-through guard")
		return
	end
	InteractDebug.record("dialogue", label, "handler fired (" .. optionId .. ")")
	if optionId == "close" then
		closeSession("✕ button")
	else
		request(s, optionId, "button")
	end
end

local function optionsFor(d: Dialogue): { { id: string, label: string } }
	local options: { { id: string, label: string } } = {}
	local hasFarewell = false
	for _, topic in d.topics do
		hasFarewell = hasFarewell or topic == "farewell"
		table.insert(options, { id = topic, label = TOPIC_LABELS[topic] or topic })
	end
	if not hasFarewell then
		table.insert(options, { id = "farewell", label = TOPIC_LABELS.farewell })
	end
	return options
end

local function build(scope: Kit.Scope, root: Frame)
	Kit.dynamic(scope, { current }, function(inner: Kit.Scope)
		local d = current:get()
		local s = session
		if not d or not s or s.id ~= d.sessionId then
			return
		end
		-- New buttons: they wait out the guard before they answer (see GUARD).
		armAt = os.clock() + ARM_SECONDS
		needRelease = mouseDown()
		GuiService.SelectedObject = nil
		local sessionId = s.id

		local panel = C.panel({
			Name = "NpcDialogue",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -150),
			Size = UDim2.fromOffset(520, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Active = true, -- sinks clicks on the panel itself: they never reach the world
			Parent = root,
		})
		inner:add(panel)

		-- The content (laid out top to bottom) and the ✕ (placed by hand, outside the layout).
		local body: Frame = Kit.create(nil, "Frame", {
			Name = "Body",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = panel,
		})
		C.padding(Theme.space.l).Parent = body
		C.list(nil, Theme.space.s).Parent = body
		C.text(d.name, "heading", { LayoutOrder = 1, Size = UDim2.new(1, -(Theme.minTouch + Theme.space.s), 0, 0) }).Parent = body
		C.text(string.format("%s · %s · %s", d.occupation, MOOD_GLYPHS[d.mood] or d.mood, d.rel), "caption", { LayoutOrder = 2 }).Parent = body
		C.text("“" .. d.text .. "”", "body", { LayoutOrder = 3 }).Parent = body
		if d.note then
			C.text(d.note, "caption", { LayoutOrder = 4, TextColor3 = Theme.color.accent }).Parent = body
		end
		local buttons = Kit.create(nil, "Frame", {
			Name = "Options",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 5,
			Parent = body,
		})
		C.grid(118, Theme.minTouch, Theme.space.s).Parent = buttons
		for index, option in optionsFor(d) do
			local optionId, optionLabel = option.id, option.label
			C.button(optionLabel, function()
				choose(sessionId, optionId, optionLabel)
			end, { kind = if optionId == "farewell" then "ghost" else "secondary" }, {
				Name = "Option_" .. optionId,
				LayoutOrder = index,
			}).Parent = buttons
		end

		C.button("✕", function()
			choose(sessionId, "close", "✕")
		end, { kind = "ghost" }, {
			Name = "Close",
			AnchorPoint = Vector2.new(1, 0),
			Position = UDim2.new(1, -Theme.space.s, 0, Theme.space.s),
			Size = UDim2.fromOffset(Theme.minTouch, Theme.minTouch),
			ZIndex = 3,
			Parent = panel,
		})
	end)
end

-- Closes the panel when you walk off, the NPC goes away or gets busy, or you die.
local function watch()
	while true do
		task.wait(0.5)
		local s = session
		if not s or not current:get() then
			continue
		end
		local model = npcModel(s.npcId)
		local character = Players.LocalPlayer.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if s.linked then
			-- Through a Mindlink: they're wherever they are. The server ends it when the link lapses.
			if not humanoid or humanoid.Health <= 0 then
				closeSession("you're down")
			end
			continue
		end
		if not model then
			closeSession("the NPC went away")
		elseif not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
			closeSession("you're down")
		elseif (model:GetPivot().Position - root.Position).Magnitude > WALK_AWAY then
			closeSession("walked away")
		else
			-- Their Talk prompt goes off when they can't talk (asleep, knocked out, rig released).
			local npcRoot = model:FindFirstChild("HumanoidRootPart")
			local prompt = npcRoot and npcRoot:FindFirstChildOfClass("ProximityPrompt")
			if prompt and not prompt.Enabled then
				closeSession("the NPC can't talk now")
			end
		end
	end
end

-- ─── Public ─────────────────────────────────────────────────────────────────

-- Starts a conversation (InteractClickController). (true) or (false, why not).
function NpcDialogueController.open(_self: any, npcId: string, source: string): (boolean, string?)
	local s = session
	if s and s.npcId == npcId then
		return false, "already talking to them"
	end
	if (blockedUntil[npcId] or 0) > os.clock() then
		return false, "just closed"
	end
	if waitRelease then
		return false, "the closing click is still held"
	end
	if s then
		closeSession("switched to someone else")
	end
	sessionSeq += 1
	local fresh: Session = { id = sessionSeq, npcId = npcId, inFlight = false, linked = source == "mindlink" or nil }
	session = fresh
	request(fresh, "greet", source)
	return true, nil
end

-- Kept for older callers: the same as open().
function NpcDialogueController.greet(self: any, npcId: string)
	self:open(npcId, "greet")
end

function NpcDialogueController.isOpen(_self: any): boolean
	return session ~= nil
end

function NpcDialogueController.isTalkingTo(_self: any, npcId: string): boolean
	local s = session
	return s ~= nil and s.npcId == npcId
end

function NpcDialogueController.close(_self: any, reason: string?)
	closeSession(reason or "closed by code")
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function NpcDialogueController.init(_self: any, ctx: any)
	log = ctx.log
	ctx.get("InterfaceController"):registerLayer({ id = "NpcDialogue", build = build })
end

function NpcDialogueController.start(_self: any, _ctx: any)
	-- The mouse button that was down when the panel changed (or closed) has come up.
	UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 then
			needRelease = false
			waitRelease = false
		end
	end)
	-- Escape opens the Roblox menu (the game never gets the key reliably): close with it, and
	-- with the key itself when it does arrive. Gamepad B closes too (CastClient skips its slash).
	GuiService.MenuOpened:Connect(function()
		closeSession("Escape / menu")
	end)
	UserInputService.InputBegan:Connect(function(input)
		if not session then
			return
		end
		if input.KeyCode == Enum.KeyCode.Escape then
			closeSession("Escape")
		elseif input.KeyCode == Enum.KeyCode.ButtonB then
			closeSession("gamepad B")
		end
	end)
	Players.LocalPlayer.CharacterAdded:Connect(function()
		closeSession("respawned")
	end)

	Net.listen("NpcSpeech", function(message: any)
		if typeof(message) ~= "table" or typeof(message.npcId) ~= "string" or typeof(message.text) ~= "string" then
			return
		end
		local model = npcModel(message.npcId)
		if model then
			local ok, err = pcall(TextChatService.DisplayBubble, TextChatService, model:FindFirstChild("Head") or model, message.text)
			if not ok then
				log:debug("bubble_failed", { err = err })
			end
		end
	end)

	task.spawn(watch)
end

return NpcDialogueController
