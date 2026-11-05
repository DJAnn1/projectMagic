--!strict
--[[
	POIRules: what goes where. Processed in order (rarest and most constrained first), each
	placing up to `count` sites on the best-scoring WorldIndex cells that satisfy its filters.

	biomes       allowed surface biomes (nil = any land)
	spacing      min distance to another POI of the same type (studs)
	clearance    min distance to ANY POI already placed (studs)
	filter(c)    extra hard conditions on a WorldIndex cell
	score(c)     preference; highest first (ties broken by position, so deterministic)
	hidden       never replicated as a visible marker (mythic sites)
	grants       what a visit can give (handled by POIService): catalyst/insight/lore/awakening
	radius       interaction radius (studs)
]]

export type Rule = {
	type: string,
	count: number,
	biomes: { string }?,
	spacing: number,
	clearance: number,
	filter: ((any) -> boolean)?,
	score: (any) -> number,
	hidden: boolean?,
	radius: number,
	grants: { catalyst: string?, insight: string?, awakening: string?, mythic: string?, lore: string? }?,
	description: string,
}

local function remoteness(c: any): number
	return c.coastDistance * 0.05 + c.sample.height / 400
end

local Rules: { Rule } = {
	-- ─── Mythic sites: one each, hidden, found only through lore hints ──────
	{
		type = "mythic_stopped_clock", count = 1, biomes = { "ruinlands", "grasslands" }, spacing = 0, clearance = 400,
		score = function(c) return c.sample.ancient * 2 + c.density end,
		hidden = true, radius = 30, grants = { mythic = "time", awakening = "stoppedClock" },
		description = "A ruin where one instant never ended. Only reachable during an eclipse.",
	},
	{
		type = "mythic_starfall_crater", count = 1, biomes = { "badlands", "desert_dunes", "tundra" }, spacing = 0, clearance = 500,
		score = function(c) return remoteness(c) + (1 - c.slope) end,
		hidden = true, radius = 60, grants = { mythic = "gravity", awakening = "starfall" },
		description = "The world's starfall target; starfall events land here.",
	},
	{
		type = "mythic_seam", count = 1, spacing = 0, clearance = 400,
		filter = function(c) return not c.ocean end,
		score = function(c) return c.density * 2 + c.sample.ancient end,
		hidden = true, radius = 20, grants = { mythic = "reality", awakening = "theSeam" },
		description = "A hairline crack in the world at its most magical point.",
	},

	-- ─── Settlements (culture chosen by Settlements.chooseCulture) ──────────
	{
		type = "settlement", count = 14, spacing = 420, clearance = 200,
		filter = function(c)
			local b = c.sample.biome
			return not c.ocean and c.slope < 0.35 and b ~= "frostpeaks" and b ~= "volcanic_highlands" and b ~= "skyreach" and b ~= "crystal_caverns"
		end,
		score = function(c) return (1 - c.slope) + (if c.coastDistance <= 1 then 0.6 else 0) + (1 - math.abs(c.sample.moisture - 0.55)) end,
		radius = 120, description = "Villages, towns and cities.",
	},

	-- ─── Schools, towers, knowledge ─────────────────────────────────────────
	{
		type = "academy", count = 3, spacing = 1000, clearance = 150,
		filter = function(c) return not c.ocean and c.slope < 0.4 end,
		score = function(c) return c.density + (1 - c.slope) end,
		radius = 80, grants = { lore = "academy" },
		description = "Magic schools. Lectures and mentors; primers for many branches.",
	},
	{
		type = "hermit_tower", count = 6, spacing = 500, clearance = 300,
		filter = function(c) return not c.ocean and c.sample.height > 150 and c.sample.magic > 0.55 end,
		score = function(c) return remoteness(c) + c.sample.magic end,
		radius = 30, grants = { lore = "hermit" },
		description = "Solitary masters; rare treatises and mentorship.",
	},
	{
		type = "ruined_library", count = 5, biomes = { "ruinlands", "grasslands", "deep_forest" }, spacing = 450, clearance = 150,
		filter = function(c) return c.sample.ancient > 0.62 end,
		score = function(c) return c.sample.ancient end,
		radius = 40, grants = { lore = "library" },
		description = "Lost knowledge: treatises, codices and mythic lore hints.",
	},

	-- ─── Resources and catalysts ────────────────────────────────────────────
	{
		type = "mine", count = 8, biomes = { "mountains", "badlands", "volcanic_highlands", "frostpeaks" }, spacing = 350, clearance = 120,
		score = function(c) return c.ore end,
		radius = 40, grants = { catalyst = "ore" },
		description = "Ore-rich mines (Metallurgy catalyst: raw ore).",
	},
	{
		type = "volcanic_vent", count = 2, biomes = { "volcanic_highlands" }, spacing = 600, clearance = 120,
		score = function(c) return c.sample.fault end,
		radius = 35, grants = { insight = "energy:volcanic_vent", catalyst = "heat" },
		description = "Insight site for Energy; real heat for Metallurgy.",
	},
	{
		type = "fault_zone", count = 2, biomes = { "mountains", "badlands", "volcanic_highlands" }, spacing = 800, clearance = 120,
		filter = function(c) return c.sample.fault > 0.8 end,
		score = function(c) return c.sample.fault end,
		radius = 60, grants = { insight = "earth:fault_zone" },
		description = "Insight site for Earth (Master breakthrough; Cataclysm catalyst).",
	},
	{
		type = "ocean_trench", count = 1, spacing = 0, clearance = 200,
		filter = function(c) return c.openSea end,
		score = function(c) return -c.sample.height end,
		radius = 80, grants = { insight = "water:ocean_trench" },
		description = "Insight site for Water (Master breakthrough; Tsunamancy catalyst).",
	},

	-- ─── Awakening sites ────────────────────────────────────────────────────
	{
		type = "singing_caverns", count = 1, biomes = { "mountains", "badlands", "frostpeaks" }, spacing = 0, clearance = 150,
		score = function(c) return c.ore + c.density end,
		radius = 50, grants = { awakening = "singingCaverns", insight = "earth:singing_caverns", catalyst = "geode" },
		description = "Resonant crystal halls (Crystalline Caverns entrance).",
	},
	{
		type = "hollow_grove", count = 1, biomes = { "deep_forest", "swamp" }, spacing = 0, clearance = 200,
		score = function(c) return 1 - c.sample.magic end,
		radius = 50, grants = { awakening = "hollowGrove" },
		description = "A dead forest where nothing rots.",
	},
	{
		type = "sunken_shrine", count = 1, spacing = 0, clearance = 200,
		filter = function(c) return c.ocean and c.coastDistance == 0 and c.sample.height > 10 end,
		score = function(c) return c.density end,
		radius = 30, grants = { awakening = "sunkenShrine" },
		description = "An altar in the shallows.",
	},
	{
		type = "quiet_place", count = 1, spacing = 0, clearance = 200,
		filter = function(c) return not c.ocean end,
		score = function(c) return -c.density end,
		radius = 60, grants = { awakening = "quietPlace" },
		description = "The deadest spot in the world (density near 0).",
	},

	-- ─── Danger ─────────────────────────────────────────────────────────────
	{
		type = "dungeon", count = 10, biomes = { "mountains", "badlands", "swamp", "deep_forest", "frostpeaks", "volcanic_highlands" }, spacing = 300, clearance = 150,
		score = function(c) return c.density + c.slope end,
		radius = 40, description = "Caves with magical ecosystems.",
	},
}

-- Shrines: one per non-mythic domain, where that domain resonates most.
for _, domain in { "energy", "earth", "water", "air", "life", "mind", "spirit", "void", "space" } do
	table.insert(Rules, {
		type = "shrine_" .. domain, count = 1, spacing = 0, clearance = 200,
		filter = function(c) return not c.ocean end,
		score = function(c) return (c.resonance[domain] or 1) * 2 + c.density end,
		radius = 30, grants = { lore = "shrine:" .. domain },
		description = "A shrine of " .. domain .. "; pilgrims, lore hints, and study.",
	})
end

return Rules
