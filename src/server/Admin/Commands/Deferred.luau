--!strict
--[[
	Commands whose systems don't exist yet. They are registered so the panel lists them (greyed
	out, with the reason) and the console explains instead of saying "unknown command". When a
	system lands, replace its entry here with a real one (a single Register call each).
]]

local PENDING: { { name: string, category: string, description: string, needs: string, args: { any }? } } = {
	{ name = "weather", category = "World", description = "Set the weather", needs = "a weather system (today only events change storm charge and moisture)",
		args = { { name = "kind", type = "string" } } },
	{ name = "spawnbuilding", category = "World", description = "Place a building of a type at the cursor", needs = "building prefabs (CLAUDE.md: Later)",
		args = { { name = "type", type = "string" } } },
}

return function(admin: any, _deps: any)
	for _, entry in PENDING do
		admin:Register({
			name = entry.name,
			category = entry.category,
			description = entry.description,
			args = entry.args,
			unavailable = "needs " .. entry.needs,
			handler = function()
				return "not available yet"
			end,
		})
	end
end
