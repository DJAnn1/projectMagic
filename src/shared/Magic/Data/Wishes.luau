--!strict
--[[
	Wishes: what a Reality wish can ask for (docs/Reality.md "Conjured beings"). Read by
	Shared/Magic/Wishes (the rules) and the Composer's "Conjure:" picker.

	A recipe's `wish` (Types.Recipe) is one of:
		"aim"       read the world where the spell lands (the default when a wish is left out)
		"self"      a double of you
		<being id>  any elemental: a domain id (Data/Elementals.domains), a branch id
		            (Data/Elementals.byBranch), or a Reality-only being (Data/Elementals.conjured)

	Land wishes (route remake_land) pick from `lands`, thing wishes (route conjure_things) from
	`things`; see Cast/WorldWishes.

	`materials`: what "aim" raises from what the spell lands on (Enum.Material names). A body under
	the aim is copied instead (Cast/Conjuring); a burning part gives fire; open sky gives air.
	TUNING STATUS  First pass, 2026-11-13.
]]

return table.freeze({
	materials = table.freeze({
		CrackedLava = "magmacraft",
		Basalt = "magmacraft",
		Water = "tidal",
		Ice = "glaciation",
		Glacier = "glaciation",
		Snow = "cryothermy",
		Sand = "sandshaping",
		Sandstone = "sandshaping",
		Grass = "life",
		LeafyGrass = "life",
		Wood = "flora",
		WoodPlanks = "flora",
		Mud = "earth",
		Ground = "earth",
		Rock = "earth",
		Slate = "earth",
		Granite = "earth",
		Cobblestone = "earth",
		Brick = "earth",
		Concrete = "earth",
		Asphalt = "earth",
		Pavement = "earth",
		Limestone = "time",
		Marble = "warding",
		Metal = "metallurgy",
		DiamondPlate = "metallurgy",
		CorrodedMetal = "metallurgy",
		Foil = "metallurgy",
		Glass = "crystallurgy",
		Salt = "crystallurgy",
		Neon = "luminous",
		Fabric = "fauna",
		Plastic = "reality",
		SmoothPlastic = "reality",
	}),
	fire = "energy", -- a burning part under the aim
	sky = "air", -- nothing under the aim
	night = "umbramancy", -- nothing under the aim, at night
	fallback = "reality", -- anything else

	-- Remake the land (route remake_land): what the ground becomes. `material` is the terrain
	-- material written; `name` reads in the Composer and the Journal.
	lands = table.freeze({
		grass = { name = "green grass", material = "Grass" },
		meadow = { name = "a wild meadow", material = "LeafyGrass" },
		stone = { name = "bare stone", material = "Rock" },
		lava = { name = "cooling lava", material = "CrackedLava" },
		basalt = { name = "black basalt", material = "Basalt" },
		water = { name = "open water", material = "Water" },
		ice = { name = "ice", material = "Ice" },
		glacier = { name = "glacier", material = "Glacier" },
		snow = { name = "deep snow", material = "Snow" },
		sand = { name = "sand", material = "Sand" },
		salt = { name = "a salt flat", material = "Salt" },
		mud = { name = "mud", material = "Mud" },
		marble = { name = "white limestone", material = "Limestone" },
		cobble = { name = "a cobbled square", material = "Cobblestone" },
	}),
	landDefault = "grass",
	-- What the land wish replaces: every natural ground material (never Granite, which is magic
	-- stone and reverts on its own, and never building materials placed as parts).
	landSources = { "Grass", "LeafyGrass", "Ground", "Rock", "Slate", "Mud", "Sand", "Sandstone", "Snow", "Ice", "Glacier", "CrackedLava", "Basalt", "Salt", "Limestone", "Cobblestone", "Water" },

	-- Conjure things (route conjure_things): what appears, for a while.
	things = table.freeze({
		forest = { name = "a forest" },
		fire = { name = "a field of fire" },
		lights = { name = "floating lights" },
		spring = { name = "a spring of water" },
		crystals = { name = "crystal spires" },
		boulders = { name = "boulders" },
	}),
	thingDefault = "forest",

	-- The Composer's groups, in order. Each lists being ids; names come from Data/Elementals.
	groups = {
		{ name = "Reality's own", ids = { "colossus", "seraph", "leviathan", "tempest", "worldtree", "sunborn", "horror", "paradox", "knight" } },
		{ name = "Energy", ids = { "energy", "cryothermy", "electric", "kinetic", "luminous", "umbramancy" } },
		{ name = "Earth", ids = { "earth", "metallurgy", "crystallurgy", "seismic", "sandshaping", "magmacraft" } },
		{ name = "Water", ids = { "water", "glaciation", "vapor", "tidal" } },
		{ name = "Air", ids = { "air", "sonics", "weathercraft" } },
		{ name = "Life", ids = { "life", "flora", "mycology", "fauna", "blight" } },
		{ name = "Mind", ids = { "mind", "empathy", "illusion" } },
		{ name = "Spirit", ids = { "spirit", "necromancy", "warding", "hexcraft" } },
		{ name = "Void", ids = { "void", "absorption" } },
		{ name = "Space, Time, Gravity", ids = { "space", "time", "gravity", "attraction" } },
		{ name = "Reality", ids = { "reality", "fortune" } },
	},
})
