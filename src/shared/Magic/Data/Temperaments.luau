--!strict
--[[
	Temperaments: innate traits that change HOW a person's magic flows.
	Shared so the UI can show names and descriptions. The odds of rolling each one live
	server-side in ProfileTuning.temperamentWeights.

	effects: multipliers (1 = neutral) except ambientShareBonus / allyPower, which are additive.
	excludes: made symmetric by the generator; a later awakening that adds a conflicting
	temperament REPLACES the old one (a transformation, not a stack).
]]
local Types = require(script.Parent.Parent.Types)

local Temperaments: { [string]: Types.TemperamentDef } = {
	volatile = {
		name = "Volatile",
		description = "Magic surges out of you: bigger spells, far less control.",
		effects = { power = 1.15, instability = 1.35 },
		excludes = { "precise", "steadfast" },
	},
	precise = {
		name = "Precise",
		description = "Every thread placed exactly: efficient and controlled, a touch weaker and slower.",
		effects = { power = 0.95, cost = 0.88, instability = 0.75, castTime = 1.08 },
		excludes = { "volatile" },
	},
	resonant = {
		name = "Resonant",
		description = "Your magic hums in sympathy with others'; allies nearby cast stronger.",
		effects = { power = 0.97, allyPower = 0.08 },
	},
	hollow = {
		name = "Hollow",
		description = "You hold little, but refill almost as fast as you spend.",
		effects = { capacity = 0.6, regen = 1.8 },
		excludes = { "deepwell" },
	},
	deepwell = {
		name = "Deepwell",
		description = "A vast reservoir that refills slowly.",
		effects = { capacity = 1.4, regen = 0.7 },
		excludes = { "hollow" },
	},
	swift = {
		name = "Swift",
		description = "Spells leave you before you've finished thinking them.",
		effects = { castTime = 0.85, instability = 1.08 },
		excludes = { "patient" },
	},
	patient = {
		name = "Patient",
		description = "Slow, deliberate weaving that lands harder.",
		effects = { castTime = 1.15, power = 1.08 },
		excludes = { "swift" },
	},
	steadfast = {
		name = "Steadfast",
		description = "Your body forgives overreach: overdraw hurts you far less.",
		effects = { overdrawRisk = 0.7, instability = 0.92 },
		excludes = { "volatile", "brittle" },
	},
	brittle = {
		name = "Brittle",
		description = "A slightly larger well behind thin walls: overdraw hits you hard.",
		effects = { overdrawRisk = 1.5, capacity = 1.1 },
		excludes = { "steadfast" },
	},
	conduit = {
		name = "Conduit",
		description = "The world's ambient magic flows through you easily.",
		effects = { ambientShareBonus = 0.15, capacity = 0.9 },
	},
	bloodbound = {
		name = "Bloodbound",
		description = "Your life and your magic are one current; vital casting costs you less.",
		effects = { vitalCost = 0.7, regen = 0.9 },
	},
	subtle = {
		name = "Subtle",
		description = "Your magic barely ripples the world. Hard to sense, hard to trace.",
		effects = { detectability = 0.6, power = 0.97 },
		excludes = { "radiant" },
	},
	radiant = {
		name = "Radiant",
		description = "Your magic blazes for every sensitive within a mile to notice.",
		effects = { detectability = 1.6, power = 1.05 },
		excludes = { "subtle" },
	},
}

return Temperaments
