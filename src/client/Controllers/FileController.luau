--!strict
--[[
	FileController: the in-game side of save files (docs/SaveFiles.md). A "File" screen in the
	tab bar says which file you're playing and offers "Return to main menu" (two steps, so a
	stray click doesn't end the session). The server rejoins you to this place, where the main
	menu runs again (Services/SaveFileService FileReturn); in Studio the session ends instead.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

local FileController = {
	name = "FileController",
	dependencies = { "InterfaceController" },
}

local function build(_scope: Kit.Scope, container: Frame)
	local column: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = container,
	})
	C.padding(Theme.space.l).Parent = column
	C.list("y", Theme.space.m).Parent = column
	local slot = Players.LocalPlayer:GetAttribute("SaveFile")
	C.text(string.format("You're playing File %s.", tostring(slot or "?")), "heading", { LayoutOrder = 1 }).Parent = column
	C.text(
		"Your progress saves as you play. Return to the main menu to switch files or reset one."
			.. (if RunService:IsStudio() then " (In Studio this ends the session: press Play again.)" else ""),
		"body",
		{ LayoutOrder = 2 }
	).Parent = column
	local row: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, Theme.minTouch), LayoutOrder = 3, Parent = column })
	C.list("x", Theme.space.s).Parent = row
	local armed = false
	local button: TextButton
	button = C.button("Return to main menu", function()
		if not armed then
			armed = true
			button.Text = "Click again to leave"
			task.delay(4, function()
				armed = false
				if button.Parent then
					button.Text = "Return to main menu"
				end
			end)
			return
		end
		button.Text = "Leaving..."
		Net.send("FileReturn")
	end, { kind = "secondary" }, { Size = UDim2.fromOffset(240, Theme.minTouch), LayoutOrder = 1 })
	button.Parent = row
end

function FileController.init(_self: any, ctx: any)
	ctx.get("InterfaceController"):registerScreen({
		id = "File",
		title = "File",
		order = 100, -- after Settings
		build = build,
	})
end

function FileController.start(_self: any, _ctx: any) end

return FileController
