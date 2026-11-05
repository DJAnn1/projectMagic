--!strict
--[[
	Biomes: 15 biomes (14 surface + 1 underground). Assignment rules live in WorldGen.biomeFor;
	this table holds what each biome IS.

	materials   top / sub / deep / cliff terrain materials
	density     base ambient magic density (0 dead .. 3 nexus; ley lines add on top)
	resonance   domain multipliers fed to MagicCore as CastContext.ambientBias
	            (>1 aligned: cheaper ambient draw and stronger; <1 opposed: suppressed)
	fuel        0..1 combustible vegetation (fire spells; EnvironmentRules "fuel")
	ore         0..1 ore richness (mines, Metallurgy catalysts)
	stressBias  added to tectonic base stress (quakes)
	storm       0..1 base chance-weight of storms (stormCharge, lightning)
	insight     insight site this biome can host ("<domain>:<site>", see Progression Breakthroughs)
]]

export type Biome = {
	name: string,
	materials: { top: Enum.Material, sub: Enum.Material, deep: Enum.Material, cliff: Enum.Material },
	density: number,
	resonance: { [string]: number },
	fuel: number,
	ore: number,
	stressBias: number,
	storm: number,
	insight: string?,
	description: string,
}

local M = Enum.Material

local Biomes: { [string]: Biome } = {
	ocean = {
		name = "Open Ocean",
		materials = { top = M.Sand, sub = M.Sand, deep = M.Rock, cliff = M.Rock },
		density = 0.9, resonance = { water = 1.4, air = 1.1, energy = 0.7, earth = 0.85 },
		fuel = 0, ore = 0, stressBias = 0, storm = 0.5, insight = "water:ocean_trench",
		description = "Deep water ringing the continent. Tsunamis are born here.",
	},
	tidal_flats = {
		name = "Tidal Flats",
		materials = { top = M.Sand, sub = M.Mud, deep = M.Rock, cliff = M.Sandstone },
		density = 1.0, resonance = { water = 1.25, life = 1.1, energy = 0.85 },
		fuel = 0.1, ore = 0.05, stressBias = 0, storm = 0.35,
		description = "Wide, wet sands and pools exposed by the tide.",
	},
	frozen_coast = {
		name = "Frozen Coast",
		materials = { top = M.Snow, sub = M.Ice, deep = M.Rock, cliff = M.Glacier },
		density = 0.9, resonance = { water = 1.3, air = 1.15, energy = 0.75, life = 0.85 },
		fuel = 0.02, ore = 0.1, stressBias = 0, storm = 0.4,
		description = "Ice shelves and black water under a pale sky.",
	},
	tundra = {
		name = "Tundra",
		materials = { top = M.Snow, sub = M.Ground, deep = M.Rock, cliff = M.Slate },
		density = 0.7, resonance = { water = 1.1, void = 1.15, life = 0.8, energy = 0.85 },
		fuel = 0.1, ore = 0.2, stressBias = 0, storm = 0.3,
		description = "Frozen plains where sound carries forever and magic thins.",
	},
	grasslands = {
		name = "Grasslands",
		materials = { top = M.Grass, sub = M.Ground, deep = M.Rock, cliff = M.Rock },
		density = 1.0, resonance = { life = 1.05, air = 1.05 },
		fuel = 0.4, ore = 0.1, stressBias = 0, storm = 0.25,
		description = "Rolling plains: farms, roads, most of the world's people.",
	},
	deep_forest = {
		name = "Deep Forest",
		materials = { top = M.LeafyGrass, sub = M.Ground, deep = M.Rock, cliff = M.Rock },
		density = 1.25, resonance = { life = 1.35, spirit = 1.15, energy = 0.85, void = 0.8 },
		fuel = 0.85, ore = 0.05, stressBias = 0, storm = 0.2,
		description = "Old trees and older spirits.",
	},
	swamp = {
		name = "Swamp",
		materials = { top = M.Mud, sub = M.Mud, deep = M.Rock, cliff = M.Ground },
		density = 1.15, resonance = { water = 1.2, life = 1.2, mind = 1.1, energy = 0.8 },
		fuel = 0.35, ore = 0.05, stressBias = 0, storm = 0.3,
		description = "Fog, rot and things that whisper. Plagues start here.",
	},
	desert_dunes = {
		name = "Desert Dunes",
		materials = { top = M.Sand, sub = M.Sandstone, deep = M.Sandstone, cliff = M.Sandstone },
		density = 0.8, resonance = { energy = 1.2, earth = 1.1, air = 1.1, water = 0.6, life = 0.75 },
		fuel = 0.05, ore = 0.3, stressBias = 0.05, storm = 0.15,
		description = "Moving dunes; buried things under them.",
	},
	badlands = {
		name = "Red Badlands",
		materials = { top = M.Sandstone, sub = M.Ground, deep = M.Rock, cliff = M.Sandstone },
		density = 0.85, resonance = { earth = 1.15, energy = 1.1, life = 0.7 },
		fuel = 0.1, ore = 0.6, stressBias = 0.1, storm = 0.2,
		description = "Canyons and mesas striped with ore.",
	},
	mountains = {
		name = "Mountain Range",
		materials = { top = M.Rock, sub = M.Slate, deep = M.Rock, cliff = M.Slate },
		density = 1.05, resonance = { earth = 1.25, air = 1.1, water = 0.9 },
		fuel = 0.15, ore = 0.7, stressBias = 0.15, storm = 0.35, insight = "earth:fault_zone",
		description = "High ridges along the world's fault lines.",
	},
	frostpeaks = {
		name = "Frostpeaks",
		materials = { top = M.Snow, sub = M.Glacier, deep = M.Rock, cliff = M.Slate },
		density = 1.1, resonance = { air = 1.2, water = 1.15, energy = 0.75, life = 0.8 },
		fuel = 0, ore = 0.4, stressBias = 0.1, storm = 0.5,
		description = "Glaciers and thin air above the clouds.",
	},
	volcanic_highlands = {
		name = "Volcanic Highlands",
		materials = { top = M.Basalt, sub = M.CrackedLava, deep = M.Basalt, cliff = M.Basalt },
		density = 1.35, resonance = { energy = 1.35, earth = 1.25, water = 0.7, life = 0.75 },
		fuel = 0.1, ore = 0.8, stressBias = 0.35, storm = 0.3, insight = "energy:volcanic_vent",
		description = "Ash, vents and rivers of fire. The ground is never quite still.",
	},
	skyreach = {
		name = "Skyreach",
		materials = { top = M.Grass, sub = M.Limestone, deep = M.Rock, cliff = M.Limestone },
		density = 1.9, resonance = { air = 1.35, space = 1.2, gravity = 1.3, earth = 0.8 },
		fuel = 0.3, ore = 0.2, stressBias = 0, storm = 0.45, insight = "air:storm_eye",
		description = "High plateaus where the ground breaks loose and floats.",
	},
	ruinlands = {
		name = "Ancient Ruinlands",
		materials = { top = M.Grass, sub = M.Cobblestone, deep = M.Rock, cliff = M.Limestone },
		density = 1.3, resonance = { spirit = 1.3, mind = 1.2, time = 1.15, reality = 1.1, life = 0.9 },
		fuel = 0.3, ore = 0.15, stressBias = 0, storm = 0.2,
		description = "The bones of a civilization that knew more magic than ours.",
	},
	crystal_caverns = {
		name = "Crystalline Caverns",
		materials = { top = M.Glacier, sub = M.Salt, deep = M.Rock, cliff = M.Glacier },
		density = 1.6, resonance = { earth = 1.35, void = 1.15, mind = 1.1, air = 0.75, energy = 0.9 },
		fuel = 0, ore = 0.9, stressBias = 0, storm = 0, insight = "earth:singing_caverns",
		description = "Underground: resonant crystal halls beneath mountains and badlands.",
	},
}

-- Stable order for ids <-> small integers (used in compact per-chunk biome grids).
local order = {
	"ocean", "tidal_flats", "frozen_coast", "tundra", "grasslands", "deep_forest", "swamp", "desert_dunes",
	"badlands", "mountains", "frostpeaks", "volcanic_highlands", "skyreach", "ruinlands", "crystal_caverns",
}

return {
	defs = Biomes,
	order = order,
}
