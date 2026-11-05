--!strict
--[[
	SettlementStyles: data for procedural settlements. Pure data; SettlementLayout and
	BuildingGenerator read it.

	TIERS   keyed by the settlement's size id. The ids are permanent (NPC data and saves use them),
	        so the player-facing tier names are labels: village = Hamlet, town = Village,
	        city = Town.
	        buildings  {min, max} buildings (well/shrine included)
	        radius     open radius the layout may use (also the settlement POI radius)
	        plaza      central plaza radius (square)
	        mainRoads  {min, max} roads radiating from the plaza
	        branchEvery / branchLength   side streets off main roads (0 = none)
	        flatTolerance  studs a lot may deviate from flat before it's rejected
	FOOTPRINTS   lot size per building type (width along the street x depth), studs
	MIX     per tier: buildings every settlement of that tier gets, then weights for the rest
	CULTURES     architecture per culture (Settlements.cultures ids): wall/roof/foundation
	        palettes, roof style (gabled | flat), pitch, chimney odds, shutters, timber framing,
	        street material, plus extra building weights for the culture's trade
]]

local SettlementStyles = {}

export type Tier = {
	label: string,
	buildings: { number },
	radius: number,
	plaza: number,
	mainRoads: { number },
	branchEvery: number,
	branchLength: { number },
	roadWidth: number,
	streetWidth: number,
	flatTolerance: number,
}

SettlementStyles.tiers = {
	village = { label = "Hamlet", buildings = { 4, 8 }, radius = 75, plaza = 9, mainRoads = { 2, 2 }, branchEvery = 0, branchLength = { 0, 0 }, roadWidth = 6, streetWidth = 5, flatTolerance = 6 },
	town = { label = "Village", buildings = { 10, 25 }, radius = 115, plaza = 13, mainRoads = { 3, 4 }, branchEvery = 44, branchLength = { 36, 60 }, roadWidth = 8, streetWidth = 6, flatTolerance = 6 },
	city = { label = "Town", buildings = { 30, 60 }, radius = 165, plaza = 18, mainRoads = { 4, 5 }, branchEvery = 36, branchLength = { 44, 80 }, roadWidth = 10, streetWidth = 7, flatTolerance = 7 },
} :: { [string]: Tier }

-- Lot sizes (width along the street, depth back from it). Buildings are generated to fit.
SettlementStyles.footprints = {
	house_small = { w = 18, d = 16 },
	house_medium = { w = 22, d = 18 },
	house_large = { w = 28, d = 22 },
	smithy = { w = 24, d = 20 },
	tavern = { w = 30, d = 24 },
	market_stall = { w = 10, d = 8 },
	well = { w = 8, d = 8 },
	watchtower = { w = 12, d = 12 },
	barn = { w = 26, d = 20 },
	magic_school = { w = 30, d = 30 },
	shrine = { w = 14, d = 14 },
} :: { [string]: { w: number, d: number } }

-- Model names: <Label>_<NN> (House_03, Smithy_01...).
SettlementStyles.labels = {
	house_small = "House", house_medium = "HouseMedium", house_large = "HouseLarge", smithy = "Smithy",
	tavern = "Tavern", market_stall = "MarketStall", well = "Well", watchtower = "Watchtower",
	barn = "Barn", magic_school = "MagicSchool", shrine = "Shrine",
} :: { [string]: string }

-- What each tier always has (placed nearest the plaza first), then weights for the rest.
SettlementStyles.mix = {
	village = { always = { "well" }, weights = { house_small = 6, house_medium = 2, barn = 1.5, smithy = 0.4 } },
	town = { always = { "well", "shrine", "tavern", "smithy" }, weights = { house_small = 5, house_medium = 3, house_large = 1, barn = 1, market_stall = 1.2, watchtower = 0.4 } },
	city = {
		always = { "shrine", "tavern", "smithy", "market_stall", "market_stall", "market_stall", "watchtower", "watchtower" },
		weights = { house_small = 4, house_medium = 4, house_large = 2, market_stall = 1, barn = 0.5, tavern = 0.3, smithy = 0.3, watchtower = 0.3 },
	},
} :: { [string]: { always: { string }, weights: { [string]: number } } }

-- Placement preference: lower = nearer the plaza.
SettlementStyles.ring = {
	well = 0, shrine = 0, market_stall = 1, tavern = 1, magic_school = 2, smithy = 2,
	house_large = 3, house_medium = 4, house_small = 5, barn = 7, watchtower = 8,
} :: { [string]: number }

export type Swatch = { material: Enum.Material, color: Color3 }

export type Culture = {
	walls: { Swatch },
	trim: Swatch, -- timber frame, door, shutters
	roof: { Swatch },
	roofStyle: string, -- "gabled" | "flat"
	pitch: { number }, -- roof height as a fraction of the house depth {min, max}
	foundation: Swatch,
	floor: Swatch,
	glass: Color3,
	chimney: number, -- chance per house
	shutters: boolean,
	timber: boolean, -- corner posts and a top beam in the trim swatch
	street: string, -- terrain material for streets
	plaza: string, -- terrain material for the plaza
	extra: { [string]: number }, -- added building weights (the culture's trade)
}

local function rgb(r: number, g: number, b: number): Color3
	return Color3.fromRGB(r, g, b)
end

local M = Enum.Material

SettlementStyles.cultures = {
	forgehold = {
		walls = { { material = M.Brick, color = rgb(120, 82, 66) }, { material = M.Slate, color = rgb(96, 96, 104) }, { material = M.Cobblestone, color = rgb(118, 112, 106) } },
		trim = { material = M.Wood, color = rgb(70, 52, 40) },
		roof = { { material = M.Slate, color = rgb(62, 66, 74) }, { material = M.Slate, color = rgb(80, 72, 70) } },
		roofStyle = "gabled", pitch = { 0.5, 0.65 },
		foundation = { material = M.Cobblestone, color = rgb(90, 88, 86) },
		floor = { material = M.WoodPlanks, color = rgb(110, 84, 62) },
		glass = rgb(255, 196, 120), chimney = 0.9, shutters = false, timber = false,
		street = "Cobblestone", plaza = "Pavement", extra = { smithy = 1.5 },
	},
	tidecall = {
		walls = { { material = M.SmoothPlastic, color = rgb(232, 228, 214) }, { material = M.SmoothPlastic, color = rgb(214, 226, 230) }, { material = M.Limestone, color = rgb(220, 214, 196) } },
		trim = { material = M.Wood, color = rgb(52, 88, 120) },
		roof = { { material = M.Wood, color = rgb(54, 96, 140) }, { material = M.Slate, color = rgb(70, 110, 130) } },
		roofStyle = "gabled", pitch = { 0.35, 0.5 },
		foundation = { material = M.Limestone, color = rgb(196, 188, 170) },
		floor = { material = M.WoodPlanks, color = rgb(150, 128, 98) },
		glass = rgb(170, 220, 255), chimney = 0.3, shutters = true, timber = false,
		street = "Sand", plaza = "Pavement", extra = { shrine = 0.6, market_stall = 0.8 },
	},
	loreseat = {
		walls = { { material = M.Sandstone, color = rgb(214, 196, 158) }, { material = M.Limestone, color = rgb(226, 218, 196) } },
		trim = { material = M.Wood, color = rgb(96, 70, 48) },
		roof = { { material = M.Sandstone, color = rgb(190, 170, 132) } },
		roofStyle = "flat", pitch = { 0, 0 },
		foundation = { material = M.Sandstone, color = rgb(176, 156, 120) },
		floor = { material = M.Marble, color = rgb(214, 206, 190) },
		glass = rgb(200, 180, 255), chimney = 0.2, shutters = false, timber = false,
		street = "Pavement", plaza = "Pavement", extra = { magic_school = 0.8 },
	},
	verdant = {
		walls = { { material = M.Wood, color = rgb(120, 92, 62) }, { material = M.WoodPlanks, color = rgb(138, 108, 72) } },
		trim = { material = M.Wood, color = rgb(76, 58, 40) },
		roof = { { material = M.Grass, color = rgb(92, 120, 60) }, { material = M.Fabric, color = rgb(168, 146, 92) } },
		roofStyle = "gabled", pitch = { 0.55, 0.75 },
		foundation = { material = M.Rock, color = rgb(100, 98, 90) },
		floor = { material = M.WoodPlanks, color = rgb(120, 94, 66) },
		glass = rgb(220, 255, 190), chimney = 0.4, shutters = true, timber = true,
		street = "Ground", plaza = "Mud", extra = { barn = 1 },
	},
	emberclan = {
		walls = { { material = M.Basalt, color = rgb(58, 52, 50) }, { material = M.Brick, color = rgb(98, 50, 40) } },
		trim = { material = M.Wood, color = rgb(46, 32, 26) },
		roof = { { material = M.Brick, color = rgb(150, 56, 40) }, { material = M.Slate, color = rgb(70, 40, 36) } },
		roofStyle = "gabled", pitch = { 0.45, 0.6 },
		foundation = { material = M.Basalt, color = rgb(44, 40, 40) },
		floor = { material = M.Slate, color = rgb(70, 64, 60) },
		glass = rgb(255, 140, 80), chimney = 0.8, shutters = false, timber = false,
		street = "Basalt", plaza = "Basalt", extra = { smithy = 1 },
	},
	skywarden = {
		walls = { { material = M.Limestone, color = rgb(232, 232, 236) }, { material = M.Marble, color = rgb(220, 224, 232) } },
		trim = { material = M.Wood, color = rgb(90, 96, 120) },
		roof = { { material = M.Slate, color = rgb(70, 92, 140) }, { material = M.Slate, color = rgb(100, 110, 150) } },
		roofStyle = "gabled", pitch = { 0.75, 1.0 },
		foundation = { material = M.Limestone, color = rgb(200, 200, 206) },
		floor = { material = M.Marble, color = rgb(220, 220, 226) },
		glass = rgb(180, 220, 255), chimney = 0.3, shutters = false, timber = false,
		street = "Limestone", plaza = "Pavement", extra = { watchtower = 0.8, magic_school = 0.3 },
	},
	frostfolk = {
		walls = { { material = M.Wood, color = rgb(88, 64, 46) }, { material = M.WoodPlanks, color = rgb(100, 76, 56) } },
		trim = { material = M.Wood, color = rgb(58, 42, 32) },
		roof = { { material = M.Snow, color = rgb(236, 240, 246) }, { material = M.Wood, color = rgb(70, 52, 40) } },
		roofStyle = "gabled", pitch = { 0.8, 1.05 },
		foundation = { material = M.Rock, color = rgb(96, 100, 106) },
		floor = { material = M.WoodPlanks, color = rgb(110, 84, 62) },
		glass = rgb(255, 210, 140), chimney = 1, shutters = true, timber = true,
		street = "Ground", plaza = "Slate", extra = { barn = 0.5 },
	},
	wayfarer = {
		walls = { { material = M.WoodPlanks, color = rgb(150, 118, 84) }, { material = M.SmoothPlastic, color = rgb(214, 196, 168) }, { material = M.Brick, color = rgb(150, 92, 70) } },
		trim = { material = M.Wood, color = rgb(92, 64, 44) },
		roof = { { material = M.Fabric, color = rgb(160, 60, 52) }, { material = M.Wood, color = rgb(110, 76, 52) }, { material = M.Slate, color = rgb(80, 80, 88) } },
		roofStyle = "gabled", pitch = { 0.45, 0.6 },
		foundation = { material = M.Cobblestone, color = rgb(110, 104, 96) },
		floor = { material = M.WoodPlanks, color = rgb(130, 100, 70) },
		glass = rgb(255, 230, 170), chimney = 0.5, shutters = true, timber = true,
		street = "Ground", plaza = "Cobblestone", extra = { market_stall = 1.5, tavern = 0.4 },
	},
} :: { [string]: Culture }

return SettlementStyles
