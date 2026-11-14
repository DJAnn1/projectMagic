--!strict
--[[
	FileController: the in-game side of save files (docs/SaveFiles.md). A "File" screen in the
	tab bar says which file you're playing and offers "Return to main menu" (UI/ReturnToMenu, the
	same block the Settings screen ends with).
]]

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local ReturnToMenu = require(UI.ReturnToMenu)

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
	ReturnToMenu.build(column, 1)
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
