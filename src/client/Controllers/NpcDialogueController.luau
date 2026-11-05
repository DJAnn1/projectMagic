--!strict
--[[
	NpcDialogueController: talking to NPCs.

		"Talk" ProximityPrompt on an NPC rig (server-made, model attribute NpcId)
		    -> NpcTalk(npcId, "greet") -> a dialogue panel above the hotbar
		topic buttons (greet, self, magic, rumor, work, learn, farewell) -> NpcTalk(npcId, topic)
		NpcSpeech { npcId, text } -> a chat bubble over that NPC (TextChatService:DisplayBubble)

	The server decides everything: distance (<= 14 studs), what the NPC says, whether it teaches.
	The panel closes on farewell, on walking away (> 18 studs) or with the close button.
	Mood and relationship are shown as words, never as colour alone.
]]

local Players = game:GetService("Players")
local ProximityPromptService = game:GetService("ProximityPromptService")
local TextChatService = game:GetService("TextChatService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Registry = require(Shared.Magic.Registry)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

local WALK_AWAY = 18
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
	npcId: string,
	name: string,
	occupation: string,
	text: string,
	mood: string,
	rel: string,
	topics: { string },
	note: string?,
}

local NpcDialogueController = {
	name = "NpcDialogueController",
	dependencies = { "InterfaceController" },
}

local log: any = nil
local current = Kit.value(nil :: Dialogue?)
local busy = false

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

local function talk(npcId: string, topic: string)
	if busy then
		return
	end
	busy = true
	local ok, payload = Net.invoke("NpcTalk", npcId, topic)
	busy = false
	if not ok or typeof(payload) ~= "table" or not payload.ok then
		if current:get() and typeof(payload) == "table" and payload.reason == "too_far" then
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
		npcId = payload.npcId,
		name = payload.name,
		occupation = payload.occupation,
		text = payload.text,
		mood = payload.mood,
		rel = payload.rel,
		topics = payload.topics,
		note = note,
	})
	if topic == "farewell" then
		task.delay(2.5, function()
			local d = current:get()
			if d and d.npcId == npcId then
				current:set(nil)
			end
		end)
	end
end

local function build(scope: Kit.Scope, root: Frame)
	Kit.dynamic(scope, { current }, function(inner: Kit.Scope)
		local d = current:get()
		if not d then
			return
		end
		local panel = C.panel({
			Name = "NpcDialogue",
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -150),
			Size = UDim2.fromOffset(520, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = root,
		})
		inner:add(panel)
		C.padding(Theme.space.l).Parent = panel
		C.list(nil, Theme.space.s).Parent = panel
		C.text(d.name, "heading", { LayoutOrder = 1 }).Parent = panel
		C.text(string.format("%s · %s · %s", d.occupation, MOOD_GLYPHS[d.mood] or d.mood, d.rel), "caption", { LayoutOrder = 2 }).Parent = panel
		C.text("“" .. d.text .. "”", "body", { LayoutOrder = 3 }).Parent = panel
		if d.note then
			C.text(d.note, "caption", { LayoutOrder = 4, TextColor3 = Theme.color.accent }).Parent = panel
		end
		local buttons = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 5,
			Parent = panel,
		})
		C.grid(118, Theme.minTouch, Theme.space.s).Parent = buttons
		for _, topic in d.topics do
			C.button(TOPIC_LABELS[topic] or topic, function()
				task.spawn(talk, d.npcId, topic)
			end, { kind = if topic == "farewell" then "ghost" else "secondary" }).Parent = buttons
		end
		C.button("Close", function()
			current:set(nil)
		end, { kind = "ghost" }).Parent = buttons
	end)
end

-- Closes the panel once the player walks away from the NPC.
local function watchDistance()
	while true do
		task.wait(0.5)
		local d = current:get()
		if d then
			local model = npcModel(d.npcId)
			local character = Players.LocalPlayer.Character
			local root = character and character:FindFirstChild("HumanoidRootPart")
			if not model or not root or not root:IsA("BasePart") or (model:GetPivot().Position - root.Position).Magnitude > WALK_AWAY then
				current:set(nil)
			end
		end
	end
end

function NpcDialogueController.init(_self: any, ctx: any)
	log = ctx.log
	ctx.get("InterfaceController"):registerLayer({ id = "NpcDialogue", build = build })
end

function NpcDialogueController.start(_self: any, _ctx: any)
	ProximityPromptService.PromptTriggered:Connect(function(prompt: ProximityPrompt, player: Player)
		if player ~= Players.LocalPlayer then
			return
		end
		local model = prompt:FindFirstAncestorOfClass("Model")
		local npcId = model and model:GetAttribute("NpcId")
		if typeof(npcId) == "string" then
			task.spawn(talk, npcId, "greet")
		end
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

	task.spawn(watchDistance)
end

return NpcDialogueController
