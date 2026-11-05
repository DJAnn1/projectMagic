--!strict
--[[
	EnvironmentRules: big magic needs the world to cooperate. A tsunami needs an ocean;
	an earthquake needs ground mass and built-up stress.

	For a matching cast at power P >= minPower:
		required = base * growth ^ (P - minPower)
		ratio    = environment[fact] / required
		ratio < hardFraction  -> the cast is blocked (stats.blockedBy = rule id)
		ratio < 1             -> power *= ratio ^ 0.5 (weaker, but possible)
		ratio > 1             -> rich conditions help a little: min(1.15, 1 + 0.05 * (ratio - 1)).
		                         Only the best surplus bonus applies; shortfalls from several rules multiply.

	Facts are measured by the server near the cast (CastContext.environment). Units:
		waterVolume   studs³ of water within the spell's area
		groundMass    0..1 share of solid terrain beneath the area
		seismicStress 0..1 from the world's fault map (built up over time, released by quakes)
		fuel          0..1 share of combustible material in the area
		stormCharge   0..1 atmospheric charge (storm weather events raise it)
]]
local Types = require(script.Parent.Parent.Types)

-- Order matters only for reporting: the first blocking rule is the one named in stats.blockedBy,
-- so specific rules come before general ones.
local EnvironmentRules: { Types.EnvironmentRuleDef } = {
	{
		id = "great_wave",
		description = "Swells and tsunamis need a large body of water nearby.",
		branches = { "tidal" }, properties = { "flow" },
		minPower = 6, fact = "waterVolume", base = 4000, growth = 2.3, hardFraction = 0.3,
	},
	{
		id = "water_source",
		description = "Steering water needs water to steer.",
		branches = { "water" }, properties = { "flow", "pressure" }, verbs = { "redirect", "transfer" },
		minPower = 1, fact = "waterVolume", base = 8, growth = 2.0, hardFraction = 0.25,
	},
	{
		id = "ground_mass",
		description = "Shaping earth at scale needs solid ground under you.",
		branches = { "earth" }, properties = { "contour", "cohesion", "seismicity" },
		minPower = 3, fact = "groundMass", base = 0.3, growth = 1.08, hardFraction = 0.4,
	},
	{
		id = "fault_stress",
		description = "Quakes release stress the ground has stored. No stress, no quake.",
		branches = { "seismic" }, properties = { "seismicity" },
		minPower = 5, fact = "seismicStress", base = 0.12, growth = 1.25, hardFraction = 0.35,
	},
	{
		id = "fuel",
		description = "Great fires need something to burn.",
		branches = { "pyromancy" }, properties = { "combustion" },
		minPower = 6, fact = "fuel", base = 0.15, growth = 1.2, hardFraction = 0.3,
	},
	{
		id = "sky_charge",
		description = "Calling down lightning at scale needs a charged sky.",
		branches = { "stormcalling" }, properties = { "charge" },
		minPower = 7, fact = "stormCharge", base = 0.3, growth = 1.15, hardFraction = 0.3,
	},
}

return EnvironmentRules
