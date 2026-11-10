--!strict
--[[
	WeatherFuel: the weather feeds some magic and starves other magic (docs/WeatherFuel.md).

	A storm overhead makes lightning stronger; rain makes water easier to move and fire harder to
	light; a heatwave helps flame and fights frost. Nothing announces it: your spell simply comes out
	stronger or weaker, and the first time a kind of weather noticeably does that to you, you write
	it in your Journal in your own words.

	Facts come from WorldStateService.environmentAt (biome climate + active world events), all 0..1:
		stormCharge   biomes give 0 .. 0.5 on their own; storm events add 0.6 .. 0.8
		moisture      wet climates sit high; rain adds, drought takes away
		temperature   0 frozen .. 1 scorching; heatwaves and eruptions add

	A rule matches on property (required), and optionally on verbs and on the spell's domains (any
	one). Its strength ramps from 0 at `from` to full at `to` (either direction: a `to` below `from`
	means "the lower, the stronger"), with a smoothstep. `bonus` is the share added to power at full
	strength (negative weakens).

	Matching rules ADD, then the total is clamped to [minFactor, maxFactor]. Thresholds sit above
	what climate alone gives (storm `from` 0.55 > every biome's 0.5) so it's weather, not geography,
	that does most of it. Extreme places (deserts, tundra) still lean their own way, which is fine.

	`noticeAt`: a factor at least this far from 1 is worth a Journal line (once per rule, ever).
]]

export type Rule = {
	id: string,
	fact: string,
	properties: { string },
	verbs: { string }?,
	domains: { string }?,
	from: number,
	to: number,
	bonus: number,
	-- First-person Journal line, written once per rule the first time it noticeably acts on you.
	journal: string,
}

local HEATING = { "generate", "amplify", "release" }
local COOLING = { "reduce" }
local WATERY = { "flow", "pressure", "humidity", "viscosity", "phase", "buoyancy" }

local WeatherFuel = {
	minFactor = 0.8,
	maxFactor = 1.3,
	noticeAt = 0.08,

	rules = {
		-- Lightning ─────────────────────────────────────────────────────────────
		{
			id = "storm_charge", fact = "stormCharge", properties = { "charge" },
			from = 0.55, to = 1.0, bonus = 0.25,
			journal = "There was a storm overhead and my lightning wanted to go. It came out of me stronger than I meant it to, like the sky was pulling.",
		},
		{
			id = "storm_wind", fact = "stormCharge", properties = { "flow", "pressure", "buoyancy" }, domains = { "air" },
			from = 0.55, to = 1.0, bonus = 0.12,
			journal = "The wind was already moving in the storm. I only had to lean on it, and it leaned back harder.",
		},

		-- Water ─────────────────────────────────────────────────────────────────
		{
			id = "rain_water", fact = "moisture", properties = WATERY, domains = { "water" },
			from = 0.7, to = 1.0, bonus = 0.15,
			journal = "Everything was wet. The water came to me easily today, out of the air and the ground both.",
		},
		{
			id = "drought_water", fact = "moisture", properties = WATERY, domains = { "water" },
			from = 0.2, to = 0.0, bonus = -0.15,
			journal = "The air was so dry my water spell came out thin. I had to drag every drop of it.",
		},

		-- Fire ──────────────────────────────────────────────────────────────────
		{
			id = "rain_fire", fact = "moisture", properties = { "combustion", "temperature" }, verbs = HEATING,
			from = 0.7, to = 1.0, bonus = -0.15,
			journal = "I tried fire in the wet and it sputtered. The rain was eating it before it could catch.",
		},
		{
			id = "dry_fire", fact = "moisture", properties = { "combustion" }, verbs = HEATING,
			from = 0.25, to = 0.0, bonus = 0.10,
			journal = "Everything around me was bone dry. The fire caught faster than I've ever felt it catch.",
		},
		{
			id = "heat_fire", fact = "temperature", properties = { "combustion", "temperature" }, verbs = HEATING,
			from = 0.75, to = 1.0, bonus = 0.12,
			journal = "The heat was already in the air. My fire just gathered it up.",
		},
		{
			id = "cold_fire", fact = "temperature", properties = { "combustion", "temperature" }, verbs = HEATING,
			from = 0.25, to = 0.0, bonus = -0.08,
			journal = "Fire in that cold was hard work. The air kept taking the warmth back.",
		},

		-- Frost ─────────────────────────────────────────────────────────────────
		{
			id = "cold_ice", fact = "temperature", properties = { "temperature", "phase" }, verbs = COOLING,
			from = 0.25, to = 0.0, bonus = 0.15,
			journal = "In the cold, freezing things felt like letting go rather than pushing. The frost wanted to come.",
		},
		{
			id = "heat_ice", fact = "temperature", properties = { "temperature", "phase" }, verbs = COOLING,
			from = 0.75, to = 1.0, bonus = -0.10,
			journal = "Frost in that heat melted almost as fast as I made it.",
		},

		-- Growth ────────────────────────────────────────────────────────────────
		{
			id = "rain_growth", fact = "moisture", properties = { "growth" },
			from = 0.7, to = 1.0, bonus = 0.08,
			journal = "After the rain, green things answered me quicker. They were already halfway to growing.",
		},
	} :: { Rule },
}

return WeatherFuel
