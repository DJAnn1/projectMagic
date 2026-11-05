--!strict
--[[
	Techniques: named milestones that show how a domain's magic grows with mastery.
	Each is an ordinary recipe from the grammar, so nothing here is hard-coded behaviour;
	these are reference points for UI, NPC teachers and balance tests.

	`tier` is the mastery tier where the technique becomes a dependable part of a caster's
	kit. The Progression spec checks that every technique is castable by someone at the
	minimum mastery of that tier in the recipe's branch.
	`environment` names what the world must provide (see EnvironmentRules).
]]
local Types = require(script.Parent.Parent.Types)

local Techniques: { [string]: Types.TechniqueDef } = {
	-- ─── Energy: glow → light → beam → heat transfer → controlled flame → inferno ──
	glow_mote = {
		name = "Glow Mote", domain = "energy", tier = 1,
		recipe = { branch = "energy", property = "luminosity", verb = "generate", form = "touch", power = 1 },
		description = "Spark a tiny glow on a fingertip.",
	},
	lantern = {
		name = "Lantern", domain = "energy", tier = 2,
		recipe = { branch = "energy", property = "luminosity", verb = "generate", form = "aura", power = 2 },
		description = "A steady light that follows you.",
	},
	searing_beam = {
		name = "Searing Beam", domain = "energy", tier = 3,
		recipe = { branch = "luminous", property = "luminosity", verb = "generate", form = "beam", power = 3 },
		description = "Focus light into a line hot enough to sting.",
	},
	warmth_draw = {
		name = "Warmth Draw", domain = "energy", tier = 3,
		recipe = { branch = "thermal", property = "temperature", verb = "transfer", form = "touch", power = 3 },
		description = "Draw warmth out of one thing and into another.",
	},
	hearthflame = {
		name = "Hearthflame", domain = "energy", tier = 4,
		recipe = { branch = "pyromancy", property = "combustion", verb = "generate", form = "pillar", power = 5, modifiers = { "channeled" } },
		description = "A controlled column of flame you can hold and steer.",
	},
	sustained_inferno = {
		name = "Sustained Inferno", domain = "energy", tier = 6,
		recipe = { branch = "conflagration", property = "combustion", verb = "generate", form = "zone", power = 8, modifiers = { "channeled", "lingering" } },
		description = "Set an area ablaze and keep it burning.",
		environment = "fuel",
	},
	firestorm = {
		name = "Firestorm", domain = "energy", tier = 7,
		recipe = { branch = "conflagration", property = "combustion", verb = "generate", form = "ritual", power = 10, modifiers = { "efficient" }, costProfile = "ambient" },
		description = "A self-feeding firestorm across a landscape.",
		environment = "fuel",
	},

	-- ─── Earth: pebble → stone → metal sense → forging & magnetism → tremor → quake → cataclysm ──
	pebble_nudge = {
		name = "Pebble Nudge", domain = "earth", tier = 1,
		recipe = { branch = "earth", property = "contour", verb = "generate", form = "touch", power = 1 },
		description = "Lift and roll a pebble.",
	},
	shape_stone = {
		name = "Shape Stone", domain = "earth", tier = 2,
		recipe = { branch = "geomancy", property = "contour", verb = "generate", form = "touch", power = 2 },
		description = "Press stone like clay.",
	},
	ore_sense = {
		name = "Ore Sense", domain = "earth", tier = 3,
		recipe = { branch = "metallurgy", property = "purity", verb = "sense", form = "aura", power = 3 },
		description = "Feel veins of metal in the ground around you.",
	},
	forge_hand = {
		name = "Forge Hand", domain = "earth", tier = 4,
		recipe = { branch = "alloycraft", property = "purity", verb = "transmute", form = "touch", power = 4 },
		description = "Refine and alloy metal in your bare hands.",
	},
	magnetic_grip = {
		name = "Magnetic Grip", domain = "earth", tier = 5,
		recipe = { branch = "ferromancy", property = "magnetism", verb = "redirect", form = "projectile", power = 5 },
		description = "Seize a blade mid-swing and throw it back.",
	},
	tremor = {
		name = "Tremor", domain = "earth", tier = 4,
		recipe = { branch = "seismic", property = "seismicity", verb = "generate", form = "burst", power = 4 },
		description = "Shake the ground around you; enemies stumble.",
	},
	localized_quake = {
		name = "Localized Quake", domain = "earth", tier = 6,
		recipe = { branch = "faultwork", property = "seismicity", verb = "generate", form = "zone", power = 7 },
		description = "Release a fault's stress across a district.",
		environment = "groundMass, seismicStress",
	},
	cataclysm = {
		name = "Cataclysm", domain = "earth", tier = 7,
		recipe = { branch = "cataclysm", property = "seismicity", verb = "generate", form = "ritual", power = 10, modifiers = { "efficient" }, costProfile = "ambient" },
		description = "A region-scale earthquake. Giant cost, giant cooldown.",
		environment = "groundMass, seismicStress",
	},

	-- ─── Water: moisture sense → pouring → ice → currents → swell → tsunami ──
	dew_sense = {
		name = "Dew Sense", domain = "water", tier = 1,
		recipe = { branch = "water", property = "humidity", verb = "sense", form = "aura", power = 1 },
		description = "Feel moisture in air and soil.",
	},
	pour = {
		name = "Pour", domain = "water", tier = 2,
		recipe = { branch = "water", property = "flow", verb = "generate", form = "touch", power = 2 },
		description = "Draw water out of the air and pour it from your hands.",
	},
	ice_wall = {
		name = "Ice Wall", domain = "water", tier = 3,
		recipe = { branch = "glaciation", property = "temperature", verb = "reduce", form = "wall", power = 3 },
		description = "Freeze moisture into a barrier.",
	},
	currents = {
		name = "Currents", domain = "water", tier = 4,
		recipe = { branch = "hydromancy", property = "flow", verb = "redirect", form = "beam", power = 4 },
		description = "Steer a stream or river current.",
		environment = "waterVolume",
	},
	swell = {
		name = "Swell", domain = "water", tier = 5,
		recipe = { branch = "tidal", property = "flow", verb = "redirect", form = "wall", power = 6 },
		description = "Raise a wave from open water.",
		environment = "waterVolume",
	},
	tsunami = {
		name = "Tsunami", domain = "water", tier = 7,
		recipe = { branch = "tsunamancy", property = "flow", verb = "redirect", form = "ritual", power = 10, modifiers = { "efficient" }, costProfile = "ambient" },
		description = "Turn the sea against the land. Needs an ocean.",
		environment = "waterVolume",
	},
}

return Techniques
