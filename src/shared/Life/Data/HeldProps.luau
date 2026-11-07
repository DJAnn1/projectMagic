--!strict
--[[
	HeldProps: the things NPCs hold while they work (docs/Activities.md §2). Shared data; the client's
	Fx/ActivityProps builds and pools them.

	A PROP
		parts    the fallback, built from plain Parts: { size, offset, color, material, angles?, shape? }.
		         `offset` is from the CENTRE of an R6 arm (the hand is at y = -1, forward is -z), so a
		         tool's grip sits near (0, -1, z). `angles` (degrees) turns that part in the arm's axes.
		model    optional: a Model named this in ReplicatedStorage.Assets.Props replaces the parts. Its
		         PrimaryPart is placed at `grip` from the arm centre. None exist yet.
		grip     where a model's PrimaryPart sits (from the arm centre)
		tip      the working end, from the arm centre: where sparks, chips and a fishing line start

	Ids are permanent (activities and saves name them).
]]

export type PropPart = {
	size: Vector3,
	offset: Vector3,
	color: Color3,
	material: Enum.Material,
	angles: Vector3?,
	shape: string?, -- "ball" | "cylinder"
}

export type Prop = {
	name: string,
	parts: { PropPart },
	model: string?,
	grip: Vector3,
	tip: Vector3,
}

local rgb = Color3.fromRGB
local M = Enum.Material
local V = Vector3.new

local WOOD = rgb(120, 85, 55)
local DARK_WOOD = rgb(86, 60, 40)
local IRON = rgb(90, 90, 96)
local STRAW = rgb(196, 170, 104)
local CLAY = rgb(168, 112, 78)

local props: { [string]: Prop } = {
	hammer = {
		name = "Hammer",
		parts = {
			{ size = V(0.2, 0.2, 1.6), offset = V(0, -1, -0.7), color = WOOD, material = M.Wood },
			{ size = V(0.5, 0.4, 0.45), offset = V(0, -1, -1.5), color = IRON, material = M.Metal },
		},
		grip = V(0, -1, 0), tip = V(0, -1, -1.5),
	},
	tongs = {
		name = "Tongs",
		parts = {
			{ size = V(0.12, 0.12, 1.8), offset = V(0.07, -1, -0.8), color = IRON, material = M.Metal },
			{ size = V(0.12, 0.12, 1.8), offset = V(-0.07, -1, -0.8), color = IRON, material = M.Metal },
			{ size = V(0.5, 0.15, 0.3), offset = V(0, -1, -1.75), color = rgb(255, 140, 60), material = M.Neon },
		},
		grip = V(0, -1, 0), tip = V(0, -1, -1.75),
	},
	peel = {
		name = "Baker's peel",
		parts = {
			{ size = V(0.15, 0.15, 2.4), offset = V(0, -1, -1.1), color = WOOD, material = M.Wood },
			{ size = V(1.1, 0.08, 1), offset = V(0, -1, -2.7), color = rgb(178, 140, 96), material = M.Wood },
		},
		grip = V(0, -1, 0), tip = V(0, -1, -2.7),
	},
	hoe = {
		name = "Hoe",
		parts = {
			{ size = V(0.2, 0.2, 4), offset = V(0, -1, -1), color = WOOD, material = M.Wood },
			{ size = V(0.6, 0.5, 0.15), offset = V(0, -1.3, -3), color = IRON, material = M.Metal },
		},
		grip = V(0, -1, 0), tip = V(0, -1.4, -3),
	},
	broom = {
		name = "Broom",
		parts = {
			{ size = V(0.16, 0.16, 4.2), offset = V(0, -1, -1.2), color = WOOD, material = M.Wood },
			{ size = V(0.9, 0.35, 0.9), offset = V(0, -1, -3.4), color = STRAW, material = M.Fabric },
		},
		grip = V(0, -1, 0), tip = V(0, -1, -3.5),
	},
	axe = {
		name = "Axe",
		parts = {
			{ size = V(0.2, 0.2, 2.6), offset = V(0, -1, -1.1), color = WOOD, material = M.Wood },
			{ size = V(0.15, 0.8, 0.7), offset = V(0, -0.75, -2.2), color = IRON, material = M.Metal },
		},
		grip = V(0, -1, 0), tip = V(0, -0.7, -2.3),
	},
	quill = {
		name = "Quill",
		parts = {
			{ size = V(0.06, 0.06, 0.9), offset = V(0, -1.05, -0.35), color = rgb(240, 236, 226), material = M.SmoothPlastic, angles = V(-30, 0, 0) },
			{ size = V(0.18, 0.04, 0.5), offset = V(0, -0.85, -0.05), color = rgb(240, 236, 226), material = M.SmoothPlastic, angles = V(-30, 0, 0) },
		},
		grip = V(0, -1, 0), tip = V(0, -1.3, -0.75),
	},
	mug = {
		name = "Mug",
		parts = { { size = V(0.45, 0.55, 0.45), offset = V(0, -1, -0.5), color = rgb(150, 110, 70), material = M.Wood } },
		grip = V(0, -1, 0), tip = V(0, -0.7, -0.5),
	},
	bread = {
		name = "Bread",
		parts = { { size = V(0.7, 0.35, 0.4), offset = V(0, -1.05, -0.45), color = rgb(196, 146, 82), material = M.SmoothPlastic, shape = "ball" } },
		grip = V(0, -1, 0), tip = V(0, -1, -0.45),
	},
	spoon = {
		name = "Spoon",
		parts = {
			{ size = V(0.08, 0.08, 0.8), offset = V(0, -1, -0.4), color = DARK_WOOD, material = M.Wood },
			{ size = V(0.25, 0.08, 0.3), offset = V(0, -1, -0.85), color = DARK_WOOD, material = M.Wood },
		},
		grip = V(0, -1, 0), tip = V(0, -1, -0.85),
	},
	bowl = {
		name = "Bowl",
		parts = {
			{ size = V(0.9, 0.35, 0.9), offset = V(0, -1.1, -0.45), color = CLAY, material = M.SmoothPlastic, shape = "cylinder", angles = V(0, 0, 90) },
			{ size = V(0.7, 0.08, 0.7), offset = V(0, -0.95, -0.45), color = rgb(150, 96, 52), material = M.SmoothPlastic, shape = "cylinder", angles = V(0, 0, 90) },
		},
		grip = V(0, -1, 0), tip = V(0, -0.95, -0.45),
	},
	spear = {
		name = "Spear",
		parts = {
			{ size = V(0.2, 6, 0.2), offset = V(0, 0.6, -0.5), color = WOOD, material = M.Wood },
			{ size = V(0.3, 0.8, 0.15), offset = V(0, 3.9, -0.5), color = IRON, material = M.Metal },
		},
		grip = V(0, -1, -0.5), tip = V(0, 4.3, -0.5),
	},
	rod = {
		name = "Fishing rod",
		parts = {
			{ size = V(0.14, 0.14, 5), offset = V(0, -0.6, -2.4), color = WOOD, material = M.Wood, angles = V(18, 0, 0) },
			{ size = V(0.3, 0.3, 0.3), offset = V(0, -1, -0.1), color = IRON, material = M.Metal, shape = "cylinder", angles = V(0, 90, 0) },
		},
		grip = V(0, -1, 0), tip = V(0, 0.15, -4.75),
	},
}

local HeldProps = {}

HeldProps.props = props

-- Where a replacement model is looked for.
HeldProps.MODEL_FOLDER = "Props" -- ReplicatedStorage.Assets.Props.<id>

function HeldProps.get(id: string?): Prop?
	return if id then props[id] else nil
end

return HeldProps
