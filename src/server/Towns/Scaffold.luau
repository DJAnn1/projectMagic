--!strict
--[[
	Scaffold: poles and planks around a building going back up (docs/TownRepair.md). The plan comes from
	RepairRules.scaffoldPlan. It's only for looking at: nothing here collides, or can be aimed at or burned, so
	it can't trap anyone or get in the way of a spell.
]]

local Data = require(script.Parent.Data.Repair)
local Rules = require(script.Parent.RepairRules)

local Scaffold = {}

function Scaffold.build(footprint: Rules.Footprint, baseY: number, topY: number, parent: Instance): Model
	local model = Instance.new("Model")
	model.Name = "Scaffold"
	for _, piece in Rules.scaffoldPlan(footprint, baseY, topY) do
		local part = Instance.new("Part")
		part.Name = piece.kind
		part.Size = piece.size
		part.Position = piece.position
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.Material = Enum.Material.WoodPlanks
		part.Color = if piece.kind == "Pole" then Data.scaffold.poleColor else Data.scaffold.plankColor
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part:SetAttribute("Flammability", 0)
		part.Parent = model
	end
	model.Parent = parent
	return model
end

return Scaffold
