--!strict
--[[
	ReturnToMenu: the "Return to main menu" block (docs/SaveFiles.md), shared by the Settings
	screen (Controllers/InterfaceController) and the File tab (Controllers/FileController).

		ReturnToMenu.build(parent, order)   a heading, a line on what happens, and a two-click button

	The second click within 4 s sends FileReturn; the server rejoins you to this place, where the
	main menu runs again (Services/SaveFileService). In Studio the session ends instead.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Net = require(ReplicatedStorage:WaitForChild("Shared").Net)
local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)
local C = require(script.Parent.Components)

local ReturnToMenu = {}

local LABEL = "Return to main menu"

function ReturnToMenu.build(parent: Instance, order: number): Frame
	local block: Frame = Kit.create(nil, "Frame", {
		Name = "ReturnToMenu",
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	C.list("y", Theme.space.xs).Parent = block
	C.text("Main menu", "heading", { LayoutOrder = 1 }).Parent = block
	local slot = Players.LocalPlayer:GetAttribute("SaveFile")
	C.text(
		string.format("You're playing File %s. Your progress saves as you play; return to the main menu to switch files or reset one.", tostring(slot or "?"))
			.. (if RunService:IsStudio() then " In Studio this ends the session: press Play again." else ""),
		"caption",
		{ LayoutOrder = 2 }
	).Parent = block

	local armed = false
	local button: TextButton
	button = C.button(LABEL, function()
		if not armed then
			-- Two clicks, so a stray one doesn't end the session.
			armed = true
			button.Text = "Click again to leave"
			task.delay(4, function()
				armed = false
				if button.Parent and button.Text ~= "Leaving..." then
					button.Text = LABEL
				end
			end)
			return
		end
		button.Text = "Leaving..."
		Net.send("FileReturn")
	end, { kind = "secondary" }, { Size = UDim2.fromOffset(240, Theme.minTouch), LayoutOrder = 3 })
	button.Parent = block
	return block
end

return ReturnToMenu
