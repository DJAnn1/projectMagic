--!strict
--[[
	MindlinkController: the Mindlink from the player's side (docs/Space.md "Mindlink"; the server decides
	everything in Services/MindlinkService).

		pick      after a cast, a card in the right-hand column (UI/SideCards) lists the minds you can reach:
		          your party, then the people you've talked to, with where they are in words. An NPC opens
		          the ordinary conversation panel through the link (NpcDialogueController, source "mindlink");
		          a party member shows the thoughts you can send them. It closes itself after `seconds`.
		thought   a party member's thought arrives as a quiet line low in the middle of the screen, in their
		          name and from where, then fades. No card, no sound beyond a breath of one.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local SideCards = require(UI.SideCards)

local THOUGHT_SECONDS = 7
local CARD_ORDER = 5 -- under the event cards, above the toasts

local MindlinkController = {
	name = "MindlinkController",
	dependencies = { "InterfaceController", "MagicStateController", "NpcDialogueController" },
}

local interface: any = nil
local magic: any = nil
local dialogue: any = nil

-- { people, thoughts, closesAt, mate? }: the open choice (nil = none). `mate` = a party member picked.
MindlinkController.pick = Kit.value(nil :: { [string]: any }?)
-- { from, text, where, at }: the last thought heard.
MindlinkController.heard = Kit.value(nil :: { [string]: any }?)

local REFUSALS: { [string]: string } = {
	NOT_OFFERED = "The link has slipped. Cast it again.",
	GONE = "That mind is out of reach now.",
	ASLEEP = "They're asleep: your thought finds only dreams.",
	TOO_SOON = "Give it a moment.",
	NO_THOUGHT = "That thought didn't form.",
}

local function notify(reason: string?)
	magic.events:Fire({ kind = "notify", text = REFUSALS[reason or ""] or "No answer." })
end

local function close()
	MindlinkController.pick:set(nil)
end

local function reachNpc(id: string)
	task.spawn(function()
		local ok, result = Net.invoke("MindlinkIntent", "npc", id)
		if ok and typeof(result) == "table" and result.ok then
			close()
			dialogue:open(id, "mindlink")
		else
			notify(if typeof(result) == "table" then result.reason else nil)
		end
	end)
end

local function sendThought(userId: string, thought: string)
	task.spawn(function()
		local ok, result = Net.invoke("MindlinkIntent", "player", userId, thought)
		if ok and typeof(result) == "table" and result.ok then
			close()
			magic.events:Fire({ kind = "notify", text = "Your thought goes out." })
		else
			notify(if typeof(result) == "table" then result.reason else nil)
		end
	end)
end

local function personButton(parent: Instance, order: number, person: any)
	local label = if person.kind == "player"
		then string.format("%s (party), %s", tostring(person.name), tostring(person.where))
		else string.format("%s%s, %s%s", tostring(person.name), if person.role then " the " .. string.lower(tostring(person.role)) else "", tostring(person.where), if person.asleep then " (asleep)" else "")
	local button = C.button(label, function()
		if person.kind == "player" then
			local pick = MindlinkController.pick:get()
			if pick then
				local next = table.clone(pick)
				next.mate = person
				MindlinkController.pick:set(next)
			end
		else
			reachNpc(person.id)
		end
	end, { kind = if person.asleep then "ghost" else "secondary" }, {
		Size = UDim2.new(1, 0, 0, Theme.minTouch + 12), -- two lines fit: names and directions run long
		TextWrapped = true,
		LayoutOrder = order,
	})
	button.Parent = parent
end

local function renderPick(scope: Kit.Scope, holder: Frame)
	Kit.dynamic(scope, { MindlinkController.pick }, function(s)
		local pick = MindlinkController.pick:get()
		if not pick then
			return
		end
		local card = C.panel({
			BackgroundTransparency = SideCards.background,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
			Parent = holder,
		})
		s:add(card)
		C.padding(Theme.space.m).Parent = card
		C.list("y", Theme.space.xs).Parent = card
		local left = C.text("", "caption", { LayoutOrder = 2, Parent = card })
		s:add(RunService.Heartbeat:Connect(function()
			local remaining = math.max(0, math.ceil(pick.closesAt - os.clock()))
			left.Text = string.format("The link holds for %d s", remaining)
			if remaining <= 0 then
				close()
			end
		end))
		local mate = pick.mate
		if mate then
			C.text("A thought for " .. tostring(mate.name), "heading", { LayoutOrder = 1, Parent = card })
			for i, t in pick.thoughts do
				local button = C.button(t.text, function()
					sendThought(mate.id, t.id)
				end, { kind = "secondary" }, { Size = UDim2.new(1, 0, 0, Theme.minTouch), LayoutOrder = 2 + i })
				button.Parent = card
			end
			local back = C.button("Someone else", function()
				local next = table.clone(pick)
				next.mate = nil
				MindlinkController.pick:set(next)
			end, { kind = "ghost" }, { Size = UDim2.new(1, 0, 0, Theme.minTouch), LayoutOrder = 100 })
			back.Parent = card
			return
		end
		C.text("Whose mind do you reach for?", "heading", { LayoutOrder = 1, Parent = card })
		for i, person in pick.people do
			personButton(card, 2 + i, person)
		end
		local cancel = C.button("Let it go", close, { kind = "ghost" }, { Size = UDim2.new(1, 0, 0, Theme.minTouch), LayoutOrder = 1000 })
		cancel.Parent = card
	end)
end

-- A heard thought: low in the middle, quiet, then gone.
local function renderHeard(scope: Kit.Scope, root: Frame)
	Kit.dynamic(scope, { MindlinkController.heard }, function(s)
		local heard = MindlinkController.heard:get()
		if not heard then
			return
		end
		local label: TextLabel = C.text(string.format("%s, %s: \u{201C}%s\u{201D}", tostring(heard.from), tostring(heard.where), tostring(heard.text)), "body", {
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -160),
			Size = UDim2.fromOffset(560, 0),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextStrokeTransparency = 0.5,
			Parent = root,
		})
		label.FontFace = Font.new(label.FontFace.Family, label.FontFace.Weight, Enum.FontStyle.Italic)
		s:add(label)
		s:add(RunService.Heartbeat:Connect(function()
			local age = os.clock() - heard.at
			local fade = math.clamp((age - (THOUGHT_SECONDS - 1.5)) / 1.5, 0, 1)
			label.TextTransparency = fade
			label.TextStrokeTransparency = 0.5 + 0.5 * fade
		end))
	end)
end

local function buildLayer(scope: Kit.Scope, root: Frame)
	renderPick(scope, SideCards.holder(scope, root, CARD_ORDER, "MindlinkCard"))
	renderHeard(scope, root)
end

function MindlinkController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	dialogue = ctx.get("NpcDialogueController")
	interface:registerLayer({ id = "Mindlink", build = buildLayer })
end

function MindlinkController.start(_self: any, _ctx: any)
	Net.listen("Mindlink", function(message: any)
		if typeof(message) ~= "table" then
			return
		end
		if message.t == "open" and typeof(message.people) == "table" then
			MindlinkController.pick:set({
				people = message.people,
				thoughts = message.thoughts or {},
				closesAt = os.clock() + (tonumber(message.seconds) or 30),
			})
		elseif message.t == "talk" and typeof(message.npcId) == "string" then
			-- Aimed straight at someone you know: the conversation opens at once.
			close()
			dialogue:open(message.npcId, "mindlink")
		elseif message.t == "thought" and typeof(message.text) == "string" then
			local heard = { from = message.from, text = message.text, where = message.where, at = os.clock() }
			MindlinkController.heard:set(heard)
			C.sound("confirm")
			task.delay(THOUGHT_SECONDS, function()
				if MindlinkController.heard:get() == heard then
					MindlinkController.heard:set(nil)
				end
			end)
		end
	end)
	Players.LocalPlayer.CharacterAdded:Connect(close)
end

return MindlinkController
