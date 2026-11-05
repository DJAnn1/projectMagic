--!strict
--[[
	Verbs: WHAT YOU DO to a property.

	requirement (enforced by the cast pipeline against the live world, not by MagicCore):
		None   - works anywhere
		Target - needs a target that has the property (a body to heal, a wall to harden)
		Source - needs existing matter/energy of that property nearby (water to redirect, heat to move)
		Stored - needs a charge previously captured with Store
]]
local Types = require(script.Parent.Parent.Types)

local Verbs: { [string]: Types.VerbDef } = {
	generate = {
		name = "Generate",
		description = "Create the property from raw power. Flexible but pays full price.",
		minTier = 0,
		requirement = "None",
		costMult = 1.0,
		powerMult = 1.0,
		instability = 0.05,
		castTimeMult = 1.0,
		durationMult = 1.0,
	},
	amplify = {
		name = "Amplify",
		description = "Increase a property something already has.",
		minTier = 0,
		requirement = "Target",
		costMult = 0.8,
		powerMult = 1.0,
		instability = 0.04,
		castTimeMult = 0.9,
		durationMult = 1.2,
	},
	reduce = {
		name = "Reduce",
		description = "Decrease or suppress a property something already has.",
		minTier = 0,
		requirement = "Target",
		costMult = 0.8,
		powerMult = 1.0,
		instability = 0.03,
		castTimeMult = 0.9,
		durationMult = 1.2,
	},
	transfer = {
		name = "Transfer",
		description = "Move a property from one thing to another. Conservative and cheap.",
		minTier = 1,
		requirement = "Source",
		costMult = 0.7,
		powerMult = 0.9,
		instability = 0.05,
		castTimeMult = 1.0,
		durationMult = 1.0,
	},
	redirect = {
		name = "Redirect",
		description = "Steer existing force or flow. Cheapest way to move a lot of something.",
		minTier = 1,
		requirement = "Source",
		costMult = 0.6,
		powerMult = 1.1,
		instability = 0.07,
		castTimeMult = 0.8,
		durationMult = 1.0,
	},
	transmute = {
		name = "Transmute",
		description = "Change a property into a different state or kind.",
		minTier = 2,
		requirement = "Source",
		costMult = 1.4,
		powerMult = 1.0,
		instability = 0.12,
		castTimeMult = 1.4,
		durationMult = 1.5,
	},
	bind = {
		name = "Bind",
		description = "Fix a property in place, or tie it to another thing.",
		minTier = 2,
		requirement = "Target",
		costMult = 1.2,
		powerMult = 0.9,
		instability = 0.08,
		castTimeMult = 1.2,
		durationMult = 2.0,
	},
	sense = {
		name = "Sense",
		description = "Perceive a property at a distance.",
		minTier = 0,
		requirement = "None",
		costMult = 0.4,
		powerMult = 0.6,
		instability = 0.01,
		castTimeMult = 0.8,
		durationMult = 1.5,
	},
	store = {
		name = "Store",
		description = "Capture a property (incoming or ambient) for later release.",
		minTier = 1,
		requirement = "Source",
		costMult = 0.9,
		powerMult = 0.8,
		instability = 0.06,
		castTimeMult = 1.0,
		durationMult = 3.0,
	},
	release = {
		name = "Release",
		description = "Unleash a previously stored charge, all at once.",
		minTier = 1,
		requirement = "Stored",
		costMult = 0.5,
		powerMult = 1.25,
		instability = 0.10,
		castTimeMult = 0.7,
		durationMult = 0.5,
	},
}

return Verbs
