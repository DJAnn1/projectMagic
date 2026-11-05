--!strict
--[[
	Growth curves: how fast mastery is gained relative to current mastery.
	points = { {mastery, gainMultiplier}, ... }, linearly interpolated, ascending mastery.
	A "breakthrough" person plateaus around 50 until an awakening event flips them onto
	afterBreakthrough.
]]
local Types = require(script.Parent.Parent.Types)

local GrowthCurves: { [string]: Types.GrowthCurveDef } = {
	early = {
		name = "Early Bloomer",
		description = "Learns fast at first, then slows.",
		points = { { 0, 1.6 }, { 40, 1.0 }, { 70, 0.65 }, { 100, 0.5 } },
	},
	steady = {
		name = "Steady",
		description = "Even progress all the way.",
		points = { { 0, 1.0 }, { 100, 1.0 } },
	},
	late = {
		name = "Late Bloomer",
		description = "A slow start that accelerates with depth.",
		points = { { 0, 0.6 }, { 40, 0.9 }, { 70, 1.4 }, { 100, 1.5 } },
	},
	breakthrough = {
		name = "Plateau, then Breakthrough",
		description = "Stalls around the middle until something cracks them open.",
		points = { { 0, 1.1 }, { 40, 1.0 }, { 50, 0.25 }, { 100, 0.25 } },
		afterBreakthrough = { { 0, 1.1 }, { 40, 1.0 }, { 50, 1.7 }, { 80, 1.3 }, { 100, 1.1 } },
	},
}

return GrowthCurves
