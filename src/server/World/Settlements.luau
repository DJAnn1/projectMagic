--!strict
--[[
	Settlements: cultures, how a settlement picks one, neighbour relations, and how
	reputation/relations evolve with player and NPC actions.

	A settlement's static identity (culture, size, laws) is generated from the seed. Its mutable
	state (prosperity, mood, relations drift, per-player reputation) lives in WorldStateService
	and is saved as ADDITIVE deltas, so concurrent servers merge cleanly.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)

export type Culture = {
	name: string,
	description: string,
	values: { [string]: number }, -- domain -> esteem (>1 revered, <1 distrusted)
	biomes: { string }, -- preferred surroundings
	coastal: boolean?, -- strongly prefers the coast
	laws: {
		castingInTown: string, -- "free" | "licensed" | "banned"
		bannedDomains: { string },
		forbiddenTagsPunished: boolean, -- branches tagged "forbidden" (necromancy, dominion...)
	},
	guilds: { string },
	exports: { string },
	imports: { string },
	openness: number, -- 0 insular .. 1 welcoming (reputation gain rate, outsider prices)
}

export type Settlement = {
	id: string,
	name: string,
	culture: string,
	size: string, -- "village" | "town" | "city"
	x: number,
	z: number,
	population: number,
	relations: { [string]: number }, -- settlementId -> -1..1 (base; drift is stored separately)
}

local Cultures: { [string]: Culture } = {
	forgehold = {
		name = "Forgehold Guild-City",
		description = "Smiths and miners under a guild charter. Metal is law.",
		values = { earth = 1.5, energy = 1.2, water = 0.9 },
		biomes = { "mountains", "badlands", "volcanic_highlands" },
		laws = { castingInTown = "licensed", bannedDomains = {}, forbiddenTagsPunished = true },
		guilds = { "Smiths' Guild", "Miners' Union", "Assayers" },
		exports = { "steel", "ore", "tools" },
		imports = { "grain", "timber" },
		openness = 0.45,
	},
	tidecall = {
		name = "Tide-Priest Port",
		description = "A harbour that prays to the sea and pays its tithe in salt.",
		values = { water = 1.5, spirit = 1.15, energy = 0.8 },
		biomes = { "tidal_flats", "frozen_coast", "grasslands" },
		coastal = true,
		laws = { castingInTown = "licensed", bannedDomains = { "void" }, forbiddenTagsPunished = true },
		guilds = { "Tide Priests", "Shipwrights", "Net-Menders" },
		exports = { "fish", "salt", "pearls" },
		imports = { "steel", "grain" },
		openness = 0.7,
	},
	loreseat = {
		name = "Scholar Enclave",
		description = "Archivists and researchers. Any study is legal; some results are not.",
		values = { mind = 1.4, spirit = 1.2, time = 1.3, reality = 1.2 },
		biomes = { "ruinlands", "grasslands", "deep_forest" },
		laws = { castingInTown = "free", bannedDomains = {}, forbiddenTagsPunished = true },
		guilds = { "Archivists", "The Collegium", "Cartographers" },
		exports = { "books", "scrolls", "maps" },
		imports = { "paper", "food" },
		openness = 0.8,
	},
	verdant = {
		name = "Verdant Circle",
		description = "Forest wardens who answer to the oldest trees.",
		values = { life = 1.5, earth = 1.1, spirit = 1.1, energy = 0.75 },
		biomes = { "deep_forest", "swamp", "grasslands" },
		laws = { castingInTown = "licensed", bannedDomains = {}, forbiddenTagsPunished = true },
		guilds = { "Wardens of the Green", "Herbalists" },
		exports = { "herbs", "timber", "remedies" },
		imports = { "tools", "salt" },
		openness = 0.5,
	},
	emberclan = {
		name = "Ember Clans",
		description = "Fire-sworn clans of the ash lands. Duels settle disputes.",
		values = { energy = 1.5, earth = 1.2, water = 0.7 },
		biomes = { "volcanic_highlands", "badlands", "desert_dunes" },
		laws = { castingInTown = "free", bannedDomains = { "water" }, forbiddenTagsPunished = false },
		guilds = { "Flamekeepers", "Glassblowers" },
		exports = { "glass", "obsidian", "dyes" },
		imports = { "water", "grain" },
		openness = 0.35,
	},
	skywarden = {
		name = "Skywarden Aerie",
		description = "Wind-riders of the high places. Gravity magic is holy, and feared.",
		values = { air = 1.5, space = 1.2, gravity = 1.4 },
		biomes = { "skyreach", "mountains", "frostpeaks" },
		laws = { castingInTown = "licensed", bannedDomains = {}, forbiddenTagsPunished = true },
		guilds = { "Windriders", "Crystal Cutters" },
		exports = { "feathers", "crystals" },
		imports = { "food", "steel" },
		openness = 0.45,
	},
	frostfolk = {
		name = "Frostfolk Hold",
		description = "Patient, insular people of the ice. Spirit binding is anathema.",
		values = { water = 1.3, air = 1.2, void = 1.1, spirit = 0.8 },
		biomes = { "tundra", "frozen_coast", "frostpeaks" },
		laws = { castingInTown = "banned", bannedDomains = { "spirit" }, forbiddenTagsPunished = true },
		guilds = { "Icecutters", "Hunters' Lodge" },
		exports = { "furs", "ice", "whale oil" },
		imports = { "grain", "timber" },
		openness = 0.3,
	},
	wayfarer = {
		name = "Wayfarer Crossroads",
		description = "A trading town at the meeting of roads. Business first, magic outside.",
		values = {},
		biomes = { "grasslands", "tidal_flats", "desert_dunes" },
		laws = { castingInTown = "banned", bannedDomains = {}, forbiddenTagsPunished = true },
		guilds = { "Merchants' League", "Caravan Masters" },
		exports = { "trade goods" },
		imports = { "everything" },
		openness = 0.9,
	},
}

local NAME_A = { "Ash", "Brine", "Cold", "Deep", "Elder", "Fall", "Glen", "Hollow", "Iron", "Lark", "Moss", "North", "Oak", "Raven", "Salt", "Thorn", "Vale", "West", "Wind", "Ember" }
local NAME_B = { "ford", "haven", "mere", "stead", "watch", "hold", "brook", "reach", "gate", "fall", "crest", "march", "spire", "well", "moor" }

local Settlements = {}
Settlements.cultures = Cultures

-- Similarity of two cultures' values: -1..1 (shared reverence → friendlier).
local function affinity(a: Culture, b: Culture): number
	local score, count = 0, 0
	for domain, value in a.values do
		local other = b.values[domain]
		if other then
			score += (value - 1) * (other - 1) * 4
			count += 1
		end
	end
	return math.clamp(if count > 0 then score / count else 0, -1, 1)
end

--[[
	Picks the culture best suited to a site. `biome` and `coastal` describe the location; `used`
	(culture -> settlements already founded, in placement order) makes each repeat less likely,
	so a coast-heavy world doesn't become one culture everywhere.
]]
function Settlements.chooseCulture(rng: Random, biome: string, coastal: boolean, used: { [string]: number }?): string
	local ids = {}
	for id in Cultures do
		table.insert(ids, id)
	end
	table.sort(ids)
	local best, bestScore = "wayfarer", -math.huge
	for _, id in ids do
		local culture = Cultures[id]
		local score = (if table.find(culture.biomes, biome) then 1 else 0)
			+ (if culture.coastal and coastal then 1.2 elseif culture.coastal then -2 else 0)
			+ rng:NextNumber() * 0.6
			- (if used then (used[id] or 0) * 0.9 else 0)
		if score > bestScore then
			best, bestScore = id, score
		end
	end
	return best
end

function Settlements.makeName(rng: Random): string
	return NAME_A[rng:NextInteger(1, #NAME_A)] .. NAME_B[rng:NextInteger(1, #NAME_B)]
end

-- Base relations: culture affinity, minus a little for distance, plus a seeded grudge or friendship.
function Settlements.computeRelations(list: { Settlement }, worldSeed: number)
	for _, a in list do
		for _, b in list do
			if a ~= b and a.id < b.id then
				local d = math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
				local rng = Seed.random(worldSeed, a.id .. "|" .. b.id, "relations")
				local value = affinity(Cultures[a.culture], Cultures[b.culture]) * 0.6
					- math.clamp(d / 4000, 0, 0.3)
					+ (rng:NextNumber() - 0.5) * 0.5
				value = math.clamp(value, -1, 1)
				a.relations[b.id], b.relations[a.id] = value, value
			end
		end
	end
end

--[[
	How a settlement reacts to magic cast inside it. Returns a reputation delta for the caster
	(negative = crime) and a short reason. Called by CastService with the cast's domains/tags.
]]
function Settlements.judgeCast(settlement: Settlement, domains: { string }, tags: { string }, harmful: boolean): (number, string?)
	local culture = Cultures[settlement.culture]
	local laws = culture.laws
	if laws.forbiddenTagsPunished and table.find(tags, "forbidden") then
		return -25, "forbidden magic"
	end
	for _, d in domains do
		if table.find(laws.bannedDomains, d) then
			return -12, "banned domain"
		end
	end
	if laws.castingInTown == "banned" then
		return if harmful then -10 else -4, "casting in town"
	end
	if harmful and laws.castingInTown == "licensed" then
		return -6, "unlicensed harmful casting"
	end
	-- Revered magic used peacefully earns a little respect.
	local best = 1
	for _, d in domains do
		best = math.max(best, culture.values[d] or 1)
	end
	return if not harmful and best > 1.2 then 0.5 else 0, nil
end

-- Reputation gain scales with openness; losses don't.
function Settlements.scaleReputation(settlement: Settlement, delta: number): number
	if delta > 0 then
		return delta * (0.5 + Cultures[settlement.culture].openness)
	end
	return delta
end

return Settlements
