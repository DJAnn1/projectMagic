--!strict
--[[
	Aliases
	When an id has to change, DON'T rename it in place: add `oldId = "newId"` here.
	Saved recipes and mastery tables are resolved through these maps on load, so old saves
	keep working forever. Chains (a -> b -> c) are followed.

	Example:
		branches = { cryomancy = "cryothermy" },
]]

return {
	domains = {} :: { [string]: string },
	branches = {} :: { [string]: string },
	properties = {} :: { [string]: string },
	verbs = {} :: { [string]: string },
	forms = {} :: { [string]: string },
	modifiers = {} :: { [string]: string },
	costProfiles = {} :: { [string]: string },
}
