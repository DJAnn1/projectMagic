--!strict
--[[
	SideCards: one column down the right edge of the screen, for cards about what's going on around you:
	a shared event, a Titan, a wild zone, a Rift. They stack, so two at once can't overlap, and the middle of
	the screen stays clear for the fight. Owner, 2026-11-06: the middle "gets hard to read or see".

		holder(scope, root, order, name) -> Frame     where one controller puts its card
		SideCards.background                          how solid a card is, so it reads over a bright world

	Each layer gets its own frame from InterfaceController, so the column lives beside them, in their
	shared parent, and is made by whichever layer builds first. It goes when the layers are rebuilt: the
	scope that first made it owns it.
]]

local UI = script.Parent
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

local COLUMN = "SideCards"
local TOP = 120 -- under the mastery tracker
local WIDTH = 300

local SideCards = {
	background = 0.08,
}

local function columnOf(scope: Kit.Scope, root: Frame): Frame
	local parent = root.Parent :: Instance
	local existing = parent:FindFirstChild(COLUMN)
	if existing and existing:IsA("Frame") then
		return existing
	end
	local column: Frame = Kit.create(nil, "Frame", {
		Name = COLUMN,
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Theme.space.m, 0, TOP),
		Size = UDim2.fromOffset(WIDTH, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		ZIndex = 2, -- above the layer frames beside it
		Parent = parent,
	})
	C.list("y", Theme.space.s).Parent = column
	scope:add(column)
	return column
end

-- `order` decides who sits above whom when several are up.
function SideCards.holder(scope: Kit.Scope, root: Frame, order: number, name: string): Frame
	local holder: Frame = Kit.create(nil, "Frame", {
		Name = name,
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = columnOf(scope, root),
	})
	C.list("y", Theme.space.xs).Parent = holder
	scope:add(holder)
	return holder
end

return SideCards
