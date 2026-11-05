--!strict
--[[
	ControlsController: the Controls screen (H), every control in the game, built entirely from
	Shared/UI/Controls (the same table the main controllers read their keys from).

	LAYOUT   a device switch (Keyboard & mouse / Gamepad / Touch, starting on the one you're
	         using), then one card per group (Movement, Casting, Combat, Items and the world,
	         Menus, Placing furniture, Admin). Each row: the action, its keys as chips, when it
	         applies (context), and a note. Rows with nothing on the chosen device are left out.
	GREYED   an action whose replicated feature flag is off shows "(off right now)" in faint ink.
	ADMIN    the Admin group shows only if this player has the admin link (PlayerGui.AdminLink).
	HINT     once per player, a few seconds after the first spawn: "Press H to see every control"
	         (saved in the hidden setting controlsHintSeen, so it never repeats).
	Colour is never the only cue: off rows also say so in words.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Controls = require(Shared.UI.Controls)
local FeatureFlags = require(Shared.Core.FeatureFlags)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

type Scope = Kit.Scope

local HINT_DELAY = 6 -- seconds after settings load before the one-time hint

local ControlsController = {
	name = "ControlsController",
	dependencies = { "InterfaceController", "MagicStateController" },
}

local interface: any = nil
local magic: any = nil

local DEVICES = {
	{ id = "keyboard", label = "Keyboard & mouse", mode = "Keyboard" },
	{ id = "gamepad", label = "Gamepad", mode = "Gamepad" },
	{ id = "touch", label = "Touch", mode = "Touch" },
}
local device = Kit.value("keyboard")

local function isAdmin(): boolean
	local gui = Players.LocalPlayer:FindFirstChild("PlayerGui")
	return gui ~= nil and gui:FindFirstChild("AdminLink") ~= nil
end

local function flagOff(action: Controls.Action): boolean
	return action.flag ~= nil and FeatureFlags.get(action.flag) == false
end

-- The key names (or the touch description) an action has on a device; nil if none.
local function bindingFor(action: Controls.Action, deviceId: string): { string }?
	if deviceId == "touch" then
		return if action.touch then { action.touch } else nil
	end
	local names = if deviceId == "gamepad" then action.gamepad else action.keyboard
	if not names or #names == 0 then
		return nil
	end
	local out: { string } = {}
	for _, name in names do
		table.insert(out, Controls.display(name))
	end
	return out
end

local function contextText(action: Controls.Action): string
	local parts: { string } = {}
	for _, id in action.contexts do
		table.insert(parts, Controls.contexts[id] or id)
	end
	return table.concat(parts, " · ")
end

-- A key chip: the key's name in a small bordered box.
local function chip(text: string, order: number, faint: boolean): Frame
	local box: Frame = Kit.create(nil, "Frame", {
		BackgroundColor3 = Theme.color.bg,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(0, 28),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = order,
	})
	C.corner(Theme.radius.s).Parent = box
	C.stroke(Theme.color.line, 1).Parent = box
	C.padding(0, Theme.space.s).Parent = box
	Kit.create(nil, "TextLabel", {
		BackgroundTransparency = 1,
		Text = text,
		FontFace = Theme.font.bold,
		TextSize = Theme.text("label"),
		TextColor3 = if faint then Theme.color.inkFaint else Theme.color.ink,
		Size = UDim2.fromScale(0, 1),
		AutomaticSize = Enum.AutomaticSize.X,
		Parent = box,
	})
	return box
end

local function actionRow(parent: Instance, action: Controls.Action, keys: { string }, order: number)
	local off = flagOff(action)
	local row: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	C.list("y", 4).Parent = row

	C.text(action.label .. (if off then "  (off right now)" else ""), "label", {
		TextColor3 = if off then Theme.color.inkFaint else Theme.color.ink,
		LayoutOrder = 1,
		Parent = row,
	})

	local chips: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = row,
	})
	C.list("x", Theme.space.xs, { Wraps = true }).Parent = chips
	if device:get() == "touch" then
		C.text(keys[1], "body", { TextColor3 = if off then Theme.color.inkFaint else Theme.color.ink, Parent = chips })
	else
		for i, key in keys do
			chip(key, i, off).Parent = chips
		end
	end

	local caption = contextText(action)
	if action.note then
		caption ..= " — " .. action.note
	end
	C.text(caption, "caption", { LayoutOrder = 3, Parent = row })
end

local function build(scope: Scope, container: Frame, _args: any?)
	-- Start on the device the player is using right now.
	local mode = interface.inputMode:get()
	for _, d in DEVICES do
		if d.mode == mode then
			device:set(d.id)
		end
	end

	local bar: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, Theme.minTouch),
		Parent = container,
	})
	Kit.dynamic(scope, { device }, function(s)
		local holder: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Parent = bar,
		})
		s:add(holder)
		C.list("x", Theme.space.s).Parent = holder
		for i, d in DEVICES do
			local button = C.button(d.label, function()
				device:set(d.id)
			end, { kind = "ghost", selected = device:get() == d.id }, {
				Size = UDim2.fromOffset(0, Theme.minTouch),
				AutomaticSize = Enum.AutomaticSize.X,
				LayoutOrder = i,
			})
			C.padding(0, Theme.space.l).Parent = button
			button.Parent = holder
		end
	end)

	local scroll = C.scroll({
		Position = UDim2.fromOffset(0, Theme.minTouch + Theme.space.m),
		Size = UDim2.new(1, 0, 1, -(Theme.minTouch + Theme.space.m)),
		Parent = container,
	})
	Kit.dynamic(scope, { device }, function(s)
		local body: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = scroll,
		})
		s:add(body)
		C.list("y", Theme.space.l).Parent = body
		C.padding(Theme.space.xs).Parent = body

		local deviceId = device:get()
		local admin = isAdmin()
		for groupIndex, group in Controls.groups do
			if group.id == "admin" and not admin then
				continue
			end
			local rows: { { action: Controls.Action, keys: { string } } } = {}
			for _, action in Controls.list do
				local keys = if action.group == group.id then bindingFor(action, deviceId) else nil
				if keys then
					table.insert(rows, { action = action, keys = keys })
				end
			end
			if #rows == 0 then
				continue
			end
			table.sort(rows, function(a, b)
				return a.action.order < b.action.order
			end)

			local card = C.panel({
				BackgroundTransparency = Theme.glass,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = groupIndex,
				Parent = body,
			})
			C.padding(Theme.space.m).Parent = card
			C.list("y", Theme.space.m).Parent = card
			C.text(group.label, "heading", { LayoutOrder = 0, Parent = card })
			for i, entry in rows do
				actionRow(card, entry.action, entry.keys, i)
			end
		end
	end)
end

-- The one-time hint, once settings have loaded (an empty table means "not loaded yet").
local function maybeHint()
	local shown = false
	local function check(settings: { [string]: any })
		if shown or next(settings) == nil or settings.controlsHintSeen == true then
			return
		end
		shown = true
		task.delay(HINT_DELAY, function()
			local text = if interface.inputMode:get() == "Touch"
				then "Every control is listed in the menu, under Controls."
				else string.format("Press %s to see every control.", interface:hint("Controls"))
			magic.events:Fire({ kind = "notify", text = text })
			task.spawn(magic.setSetting, magic, "controlsHintSeen", true)
		end)
	end
	magic.settings:observe(check)
	check(magic.settings:get())
end

function ControlsController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	interface:registerScreen({
		id = "Controls",
		title = "Controls",
		order = 98, -- just before Settings
		key = Controls.key("open_controls", "keyboard"),
		gamepadKey = Controls.key("open_controls", "gamepad"),
		build = build,
	})
end

function ControlsController.start(_self: any, _ctx: any)
	maybeHint()
end

return ControlsController
