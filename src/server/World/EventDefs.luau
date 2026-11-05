--!strict
--[[
	EventDefs: dynamic world events. The EventDirector picks among these every minute, weighted
	by biome, by what magic people have been using nearby ("pressure"), and by what's already
	happening. Events change the world (WorldState modifiers), create quest hooks, and can be
	ended early by the right kind of magic (`relief`).

	weight(ctx)  -> number, where ctx = { biome, pressure = {domain = recent power}, active = {type = count}, density }
	modifiers    applied in a circle of `radius` while active (see WorldStateService.Modifier)
	relief       casting this domain in the area adds the cast's power; reaching `amount` ends it early
	grants       what being there can give (POIService/awakenings read these)
	at           where it happens: "player" (near an active player) | "nexus" | "poi:<type>" | "settlement"
]]

export type EventDef = {
	name: string,
	scope: string, -- "region" | "global"
	at: string,
	radius: number,
	duration: { number }, -- {min, max} seconds
	weight: (any) -> number,
	modifiers: { density: number?, temperature: number?, moisture: number?, stormCharge: number?, fuel: number? },
	stress: number?, -- tectonic stress added at the centre when it starts
	relief: { domain: string, amount: number }?,
	grants: { catalyst: string?, insight: string?, awakening: string? }?,
	hook: string, -- quest hook text; {place} is replaced with the nearest settlement's name
}

local function biomeIn(list: { string }): (any) -> number
	return function(ctx)
		return if table.find(list, ctx.biome) then 1 else 0
	end
end

local function pressure(ctx: any, domain: string, scale: number): number
	return 1 + (ctx.pressure[domain] or 0) / scale
end

local EventDefs: { [string]: EventDef } = {
	drought = {
		name = "Drought",
		scope = "region", at = "player", radius = 700, duration = { 1800, 3600 },
		weight = function(ctx)
			return biomeIn({ "grasslands", "badlands", "desert_dunes", "deep_forest" })(ctx) * pressure(ctx, "energy", 400) / pressure(ctx, "water", 400)
		end,
		modifiers = { moisture = -0.3, fuel = 0.3, density = 0.9 },
		relief = { domain = "water", amount = 600 },
		hook = "Wells are failing around {place}. Anyone who can call water is begged to help.",
	},
	wildfire = {
		name = "Wildfire",
		scope = "region", at = "player", radius = 400, duration = { 600, 1500 },
		weight = function(ctx)
			local dry = if (ctx.active.drought or 0) > 0 then 3 else 1
			return biomeIn({ "deep_forest", "grasslands" })(ctx) * 0.4 * dry * pressure(ctx, "energy", 300)
		end,
		modifiers = { fuel = 0.4, temperature = 0.2 },
		relief = { domain = "water", amount = 400 },
		grants = { catalyst = "wildfire" },
		hook = "Fire is running through the woods near {place}.",
	},
	magic_storm = {
		name = "Magic Storm",
		scope = "region", at = "player", radius = 600, duration = { 900, 1800 },
		weight = function(ctx)
			local total = 0
			for _, v in ctx.pressure do
				total += v
			end
			return 0.3 + total / 800
		end,
		modifiers = { density = 1.6, stormCharge = 0.6 },
		hook = "Raw magic is storming over {place}. Spells surge, and sometimes misfire.",
	},
	tempest = {
		name = "Tempest",
		scope = "region", at = "player", radius = 700, duration = { 900, 1800 },
		weight = function(ctx)
			return biomeIn({ "tidal_flats", "frozen_coast", "skyreach", "mountains", "frostpeaks" })(ctx) * 0.6 * pressure(ctx, "air", 400)
		end,
		modifiers = { stormCharge = 0.8, density = 1.2, moisture = 0.2 },
		grants = { insight = "air:storm_eye", awakening = "stormEye" },
		hook = "A great storm is coming in over {place}. Its eye is said to be eerily calm.",
	},
	volcanic_unrest = {
		name = "Volcanic Unrest",
		scope = "region", at = "player", radius = 800, duration = { 1800, 3600 },
		weight = function(ctx)
			return biomeIn({ "volcanic_highlands", "badlands" })(ctx) * 0.8 * pressure(ctx, "earth", 300)
		end,
		modifiers = { temperature = 0.25, fuel = 0.2, density = 1.2 },
		stress = 0.2,
		relief = { domain = "earth", amount = 800 },
		grants = { catalyst = "heat" },
		hook = "The ground near {place} is hot and shaking. The vents are waking.",
	},
	monster_migration = {
		name = "Migration",
		scope = "region", at = "player", radius = 900, duration = { 1200, 2400 },
		weight = function(ctx)
			return biomeIn({ "grasslands", "tundra", "deep_forest", "swamp" })(ctx) * 0.5 * pressure(ctx, "life", 500)
		end,
		modifiers = {},
		relief = { domain = "life", amount = 500 },
		hook = "Great herds, and the things that hunt them, are moving past {place}.",
	},
	plague = {
		name = "Plague",
		scope = "region", at = "settlement", radius = 400, duration = { 2400, 5400 },
		weight = function(ctx)
			return biomeIn({ "swamp", "grasslands", "tidal_flats" })(ctx) * 0.25 * pressure(ctx, "life", 250)
		end,
		modifiers = { density = 0.9 },
		relief = { domain = "life", amount = 700 },
		hook = "Sickness has come to {place}. Healers are needed.",
	},
	ley_surge = {
		name = "Ley Surge",
		scope = "region", at = "nexus", radius = 300, duration = { 900, 1800 },
		weight = function(ctx)
			local total = 0
			for _, v in ctx.pressure do
				total += v
			end
			return 0.2 + total / 1000
		end,
		modifiers = { density = 2.0 },
		hook = "The ley nexus near {place} is overflowing. Rituals there are easier, and awakenings likelier.",
	},
	eclipse = {
		name = "Eclipse",
		scope = "global", at = "player", radius = 1e6, duration = { 600, 900 },
		weight = function(_ctx)
			return 0.03
		end,
		modifiers = { density = 1.1 },
		hook = "The sun goes dark. Scholars whisper about a ruin where time stopped.",
	},
	starfall = {
		name = "Starfall",
		scope = "global", at = "poi:mythic_starfall_crater", radius = 200, duration = { 300, 600 },
		weight = function(_ctx)
			return 0.02
		end,
		modifiers = { density = 1.5 },
		hook = "A star is falling, somewhere far from any road.",
	},
}

return EventDefs
