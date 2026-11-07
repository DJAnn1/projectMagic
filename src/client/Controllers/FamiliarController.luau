--!strict
--[[
	FamiliarController: your familiar from the player's side (docs/Familiars.md). The server decides
	everything (Services/FamiliarService); `view` is the last state it sent, and buttons are intents.

		screen   Familiar [O]: what it is, how it's grown, its abilities, your orders, and its name.
		notes    bonding, growing and knockouts arrive with the state, as ordinary toasts.

	The name box sits outside the dynamic region, so an update never wipes what you're typing.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Controls = require(Shared.UI.Controls)
local F = require(Shared.Familiars.Data.Familiars)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local FamiliarAnimator = require(script.Parent.Parent:WaitForChild("Fx"):WaitForChild("FamiliarAnimator"))

local FamiliarController = {
	name = "FamiliarController",
	dependencies = { "InterfaceController", "MagicStateController" },
}

local interface: any = nil
local magic: any = nil

local view = Kit.value({ bonded = false } :: { [string]: any })
FamiliarController.view = view

local REFUSALS: { [string]: string } = {
	OFF = "Familiars are switched off right now.",
	NOT_BONDED = "Nothing has answered your magic yet.",
	NO_ROOM = "There are too many familiars out on this server. Try again in a moment.",
	BAD_MODE = "That didn't work.",
}

local function act(op: string, value: string?)
	task.spawn(function()
		local ok, result = Net.invoke("FamiliarAction", op, value)
		if not ok or typeof(result) ~= "table" then
			magic.events:Fire({ kind = "notify", text = "That didn't work. Try again in a moment." })
		elseif not result.ok then
			magic.events:Fire({ kind = "notify", text = REFUSALS[result.reason or ""] or "That didn't work." })
		end
	end)
end

local function receive(next: any)
	if typeof(next) ~= "table" then
		return
	end
	view:set(next)
	if typeof(next.note) == "string" then
		magic.events:Fire({ kind = "notify", text = next.note })
	end
end

-- ─── The screen ─────────────────────────────────────────────────────────────

local function section(parent: Instance, title: string, order: number): Frame
	local frame = C.panel({
		BackgroundTransparency = Theme.glass,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	C.padding(Theme.space.m).Parent = frame
	C.list("y", Theme.space.s).Parent = frame
	C.text(title, "heading", { LayoutOrder = 0, Parent = frame })
	return frame
end

local function waiting(parent: Instance, v: { [string]: any })
	local frame = section(parent, "Nothing has answered yet", 1)
	if v.off then
		C.text("Familiars are switched off on this server.", "body", { LayoutOrder = 1, Parent = frame })
		return
	end
	local left = tonumber(v.castsLeft) or 0
	local line = if left > 0
		then string.format("Keep using your magic. Something is paying attention. (%d more spell%s)", left, if left == 1 then "" else "s")
		else "Cast a spell. Something is very close."
	C.text(line, "body", { LayoutOrder = 1, Parent = frame })
end

local function about(parent: Instance, v: { [string]: any })
	local frame = section(parent, tostring(v.name), 1)
	C.text(string.format("%s %s familiar. %s", tostring(v.word), tostring(v.domainName), tostring(v.line)), "body", { LayoutOrder = 1, Parent = frame })

	if typeof(v.koSeconds) == "number" then
		C.text(string.format("Knocked out. Back in about %d s.", v.koSeconds), "label", { LayoutOrder = 2, Parent = frame })
	elseif not v.summoned then
		C.text("Resting. It isn't with you right now.", "label", { LayoutOrder = 2, Parent = frame })
	else
		C.text(string.format("Health: %d%%", tonumber(v.health) or 0), "label", { LayoutOrder = 2, Parent = frame })
		local health = C.bar(nil, math.clamp((tonumber(v.health) or 0) / 100, 0, 1), Theme.color.good, 8)
		health.LayoutOrder = 3
		health.Parent = frame
	end

	local from, to, xp = tonumber(v.xpFrom) or 0, tonumber(v.xpTo), tonumber(v.xp) or 0
	if to then
		C.text(string.format("Stage %d of %d: %s. %d of %d XP to the next.", tonumber(v.stage) or 1, tonumber(v.stages) or 5, tostring(v.stageName), xp, to), "label", { LayoutOrder = 4, Parent = frame })
		local growth = C.bar(nil, math.clamp((xp - from) / math.max(1, to - from), 0, 1), Theme.color.accent, 8)
		growth.LayoutOrder = 5
		growth.Parent = frame
	else
		C.text(string.format("Stage %d of %d: %s. It has grown as far as it can.", tonumber(v.stage) or 1, tonumber(v.stages) or 5, tostring(v.stageName)), "label", { LayoutOrder = 4, Parent = frame })
	end
	C.text("It grows from your casts and from fights it helps with, while you're playing.", "caption", { LayoutOrder = 6, Parent = frame })
end

local function abilities(parent: Instance, v: { [string]: any })
	local frame = section(parent, "What it can do", 2)
	C.text("Bite: it attacks up close.", "body", { LayoutOrder = 1, Parent = frame })
	local list = if typeof(v.abilities) == "table" then v.abilities else {}
	for i, ability in list do
		C.text(string.format("%s: %s", tostring(ability.name), tostring(ability.text)), "body", { LayoutOrder = 1 + i, Parent = frame })
	end
	if (tonumber(v.stage) or 1) < F.tuning.abilityStage then
		C.text(string.format("It learns its first ability at %s.", F.stages[F.tuning.abilityStage].name), "caption", { LayoutOrder = 10, Parent = frame })
	elseif (tonumber(v.stage) or 1) < F.tuning.learnStage then
		C.text(string.format("At %s it learns a second, from the magic you use most.", F.stages[F.tuning.learnStage].name), "caption", { LayoutOrder = 10, Parent = frame })
	end
end

local function orders(parent: Instance, v: { [string]: any })
	local frame = section(parent, "Your orders", 3)
	for i, mode in F.modes do
		local row: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = i,
			Parent = frame,
		})
		C.list("x", Theme.space.m, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = row
		local chosen = v.mode == mode.id
		local button = C.button(if chosen then "✓ " .. mode.label else mode.label, function()
			act("mode", mode.id)
		end, { kind = if chosen then "primary" else "ghost" }, {
			Size = UDim2.fromOffset(110, Theme.minTouch),
			LayoutOrder = 1,
		})
		button.Parent = row
		C.text(mode.text, "caption", {
			Size = UDim2.new(1, -(110 + Theme.space.m), 0, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			TextWrapped = true,
			LayoutOrder = 2,
			Parent = row,
		})
	end
	local toggle = C.button(if v.summoned then "Send it to rest" else "Call it back", function()
		act(if v.summoned then "dismiss" else "summon")
	end, { kind = "ghost" }, {
		Size = UDim2.fromOffset(170, Theme.minTouch),
		LayoutOrder = 20,
	})
	toggle.Parent = frame
end

local function nameSection(scope: Kit.Scope, parent: Instance)
	local frame = section(parent, "Its name", 4)
	frame.Visible = false
	local box: TextBox = Kit.create(nil, "TextBox", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, Theme.minTouch),
		BackgroundColor3 = Theme.color.panel,
		TextColor3 = Theme.color.ink,
		PlaceholderText = "Give it a name (blank for its own)",
		PlaceholderColor3 = Theme.color.inkFaint,
		Text = "",
		ClearTextOnFocus = false,
		FontFace = Theme.font.body,
		TextSize = Theme.text("body"),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = frame,
	})
	C.corner().Parent = box
	C.stroke().Parent = box
	C.padding(0, Theme.space.s).Parent = box
	box:GetPropertyChangedSignal("Text"):Connect(function()
		local length = utf8.len(box.Text)
		if length and length > F.tuning.nameChars then
			box.Text = string.sub(box.Text, 1, (utf8.offset(box.Text, F.tuning.nameChars + 1) or #box.Text + 1) - 1)
		end
	end)
	local save = C.button("Save the name", function()
		act("rename", if box.Text ~= "" then box.Text else nil)
	end, { kind = "ghost" }, {
		Size = UDim2.fromOffset(170, Theme.minTouch),
		LayoutOrder = 2,
	})
	save.Parent = frame
	-- Only useful once there's a familiar to name.
	Kit.dynamic(scope, { view }, function(_s)
		frame.Visible = view:get().bonded == true
	end)
end

local function buildScreen(scope: Kit.Scope, container: Frame, _args: any?)
	local scroll = C.scroll({ Parent = container })
	C.list("y", Theme.space.l).Parent = scroll
	C.padding(Theme.space.xs).Parent = scroll
	local holder: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 1,
		Parent = scroll,
	})
	C.list("y", Theme.space.l).Parent = holder
	Kit.dynamic(scope, { view }, function(s)
		local v = view:get()
		local body: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = holder,
		})
		s:add(body)
		C.list("y", Theme.space.l).Parent = body
		if v.bonded then
			about(body, v)
			abilities(body, v)
			orders(body, v)
		else
			waiting(body, v)
		end
	end)
	local nameHolder: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = scroll,
	})
	C.list("y", Theme.space.s).Parent = nameHolder
	nameSection(scope, nameHolder)
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function FamiliarController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	interface:registerScreen({
		id = "Familiar",
		title = "Familiar",
		order = 52,
		key = Controls.key("open_familiar", "keyboard"),
		build = buildScreen,
	})
end

function FamiliarController.start(_self: any, _ctx: any)
	FamiliarAnimator.start()
	Net.listen("FamiliarState", receive)
	task.spawn(function()
		local ok, result = Net.invoke("FamiliarAction", "state")
		if ok and typeof(result) == "table" and typeof(result.view) == "table" then
			view:set(result.view)
		end
	end)
end

return FamiliarController
