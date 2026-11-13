--!strict
--[[
	Wishes: what a Reality wish can ask for (docs/Reality.md "Conjured beings"). Read by
	Shared/Magic/Wishes (the rules) and the Composer's "Conjure:" picker.

	A recipe's `wish` (Types.Recipe) is one of:
		"aim"       read the world where the spell lands (the default when a wish is left out)
		"self"      a double of you
		<being id>  any elemental: a domain id (Data/Elementals.domains), a branch id
		            (Data/Elementals.byBranch), or a Reality-only being (Data/Elementals.conjured)

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
