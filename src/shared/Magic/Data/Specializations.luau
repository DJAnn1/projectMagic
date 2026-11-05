--!strict
--[[
	Specialization Commitments: optional deep-focus oaths. Each boosts one branch (and all its
	descendants) and weakens opposing branches (and their descendants).

	Limits (enforced by SpecializationService):
	- requires `minMastery` in the committed branch
	- 1 commitment at Skilled, 2 at Master, 3 at Grandmaster (counted on your best branch)
	- you can't commit to an oath whose boosted branch another of your oaths weakens, or vice versa
	- Renouncing needs the "rite:unbinding" lore, costs 35% of the XP in the committed branch
	  (and its descendants), and starts a 30-day cooldown before any new commitment
]]
local Types = require(script.Parent.Parent.Types)

local BOOST = { power = 1.2, cost = 0.85, xp = 1.25 }
local PENALTY = { power = 0.8, cost = 1.2, xp = 0.6 }

local Specializations: { [string]: Types.SpecializationDef } = {
	pyre_oath = {
		name = "Oath of the Pyre",
		description = "You burn hot and never cold. Flame answers faster; frost resents you.",
		branch = "pyromancy", minMastery = 40, boost = BOOST,
		weakens = { "cryothermy" }, penalty = PENALTY,
	},
	frost_vow = {
		name = "Vow of Stillfrost",
		description = "You draw heat out of the world. Fire gutters in your hands.",
		branch = "cryothermy", minMastery = 40, boost = BOOST,
		weakens = { "pyromancy" }, penalty = PENALTY,
	},
	lightbearer = {
		name = "Lightbearer",
		description = "You live in clarity. Shadows slip from your grasp.",
		branch = "photomancy", minMastery = 40, boost = BOOST,
		weakens = { "umbramancy" }, penalty = PENALTY,
	},
	forgeheart = {
		name = "Forgeheart",
		description = "Metal is your language. Loose earth, sand and erosion feel foreign.",
		branch = "metallurgy", minMastery = 40, boost = BOOST,
		weakens = { "sandshaping" }, penalty = PENALTY,
	},
	stonesinger = {
		name = "Stonesinger",
		description = "You build. Breaking the ground's stresses feels like betrayal.",
		branch = "lithomancy", minMastery = 40, boost = BOOST,
		weakens = { "seismic" }, penalty = PENALTY,
	},
	faultwalker = {
		name = "Faultwalker",
		description = "You listen to the ground's stresses and release them. Patient building bores you.",
		branch = "seismic", minMastery = 40, boost = BOOST,
		weakens = { "lithomancy" }, penalty = PENALTY,
	},
	tidebound = {
		name = "Tidebound",
		description = "Water must move. Ice feels like a cage.",
		branch = "tidal", minMastery = 40, boost = BOOST,
		weakens = { "glaciation" }, penalty = PENALTY,
	},
	winterheart = {
		name = "Winterheart",
		description = "Water should be still and hard. Steam and flame are your enemies.",
		branch = "glaciation", minMastery = 40, boost = BOOST,
		weakens = { "vapor", "thermal" }, penalty = PENALTY,
	},
	stormborn = {
		name = "Stormborn",
		description = "You ride the wind. Stillness and vacuum are against your nature.",
		branch = "aeromancy", minMastery = 40, boost = BOOST,
		weakens = { "vacuity" }, penalty = PENALTY,
	},
	greenwarden = {
		name = "Greenwarden",
		description = "You tend living things. Rot and plague recoil from you.",
		branch = "flora", minMastery = 40, boost = BOOST,
		weakens = { "blight" }, penalty = PENALTY,
	},
	plaguebearer = {
		name = "Plaguebearer",
		description = "You are decay's patient servant. Healing comes hard.",
		branch = "blight", minMastery = 40, boost = BOOST,
		weakens = { "restoration" }, penalty = PENALTY,
	},
	warden = {
		name = "Warden",
		description = "You protect. Curses sour in your mouth.",
		branch = "warding", minMastery = 40, boost = BOOST,
		weakens = { "hexcraft" }, penalty = PENALTY,
	},
	hexbound = {
		name = "Hexbound",
		description = "You curse. Wards you weave come out thin.",
		branch = "hexcraft", minMastery = 40, boost = BOOST,
		weakens = { "warding" }, penalty = PENALTY,
	},
	nullbound = {
		name = "Nullbound",
		description = "You unmake magic. Spirit magic of every kind withers near you.",
		branch = "negation", minMastery = 40, boost = BOOST,
		weakens = { "spirit" }, penalty = PENALTY,
	},
}

return Specializations
