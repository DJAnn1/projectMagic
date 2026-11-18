--!strict
--[[
	PlaceHistory: the seeded past of a place in the wilds (docs/WorldPlaces.md §2). Pure: the same
	world seed, POI and context give the same history on every server, so every server agrees on what
	the old works were and who holds them now.

		PlaceHistory.of(worldSeed, poi, context) -> History?    nil when the POI isn't a place
		PlaceHistory.fill(pattern, tokens) -> string            {family} {first} {town} {word}
		PlaceHistory.ageSays(yearsAgo) -> string                "in my grandparents' time"

	What it decides, in this order (the order of the seeded draws; don't reorder, or every world's
	histories change):
		1. the kind     deep places: one of PlaceKinds.deep by biome, nearby town and magic density;
		                sites: fixed by the POI type
		2. the builder  who made it (BUILDERS)
		3. the fate     what happened (FATES)
		4. the occupant who's there now (the fate's own weights)
		5. how long ago, the name, the danger, and for deep places how many depths and rooms

	Later stages read the rest of the record: `leaves` keys the loot tables (stage 1), `signs` is what
	PlaceBuilder shows outside (stage 2), `writes` says whether letters can be found, and `lines`
	is the short history people tell. Lines hold words, never digits.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Seed = require(ReplicatedStorage.Shared.Magic.Seed)
local NpcData = require(ServerScriptService.Server.NPC.Data.NpcData)
local Kinds = require(script.Parent.Data.PlaceKinds)

export type Context = {
	town: { id: string, name: string, culture: string, distance: number },
	density: number, -- magic density at the place, 0..2
}

export type History = {
	id: string, -- the POI id
	poiType: string,
	size: string, -- "site" | "deep"
	kind: string, -- deep kind id or site kind
	label: string, -- "an old mine works", "a library"
	name: string, -- "the Ironwell works"
	builder: string,
	fate: string,
	occupant: string,
	yearsAgo: number,
	age: string, -- "in my grandparents' time"
	town: string, -- nearest town's name
	townId: string,
	culture: string, -- the builders' culture (the nearest town's)
	danger: number, -- 0..1
	depths: number?, -- deep places only
	rooms: number?, -- deep places only
	leaves: { string },
	signs: { string },
	writes: boolean,
	lines: { string },
}

local PlaceHistory = {}

local SITE_LABELS: { [string]: string } = {
	library = "a library",
	tower = "a tower",
	academy = "an academy",
	mine = "a mine",
	shrine = "a shrine",
}

-- Fates where the place is still alive: no "Nothing lives there now" afterwards.
local LIVING_FATES: { [string]: boolean } = { standing = true, working = true, tended = true }

local function pick(rng: Random, list: { Kinds.Pick }): string
	local total = 0
	for _, p in list do
		total += math.max(p.w, 0)
	end
	if total <= 0 then
		return list[1].id
	end
	local roll = rng:NextNumber() * total
	for _, p in list do
		roll -= math.max(p.w, 0)
		if roll <= 0 then
			return p.id
		end
	end
	return list[#list].id
end

local function one<T>(rng: Random, list: { T }): T
	return list[rng:NextInteger(1, #list)]
end

local function capitalise(text: string): string
	return (string.gsub(text, "^%l", string.upper))
end

function PlaceHistory.fill(pattern: string, tokens: { [string]: string }): string
	return (string.gsub(pattern, "{(%w+)}", function(key: string)
		return tokens[key] or ("{" .. key .. "}")
	end))
end

function PlaceHistory.ageSays(yearsAgo: number): string
	for _, band in Kinds.ages do
		if yearsAgo <= band.upTo then
			return band.says
		end
	end
	return Kinds.ages[#Kinds.ages].says
end

-- The weights of the deep kinds for this spot.
function PlaceHistory.deepWeights(biome: string, context: Context): { Kinds.Pick }
	local out: { Kinds.Pick } = {}
	for _, def in Kinds.deep do
		local w = def.biomes[biome] or def.anywhere or 0
		if def.nearTown and context.town.distance < 700 then
			w += def.nearTown
		end
		if def.dense then
			w += def.dense * math.clamp(context.density, 0, 2) / 2
		end
		table.insert(out, { id = def.id, w = w })
	end
	return out
end

local function addAll(into: { string }, from: { string })
	for _, v in from do
		if not table.find(into, v) then
			table.insert(into, v)
		end
	end
end

function PlaceHistory.of(worldSeed: number, poi: { id: string, type: string, biome: string, hidden: boolean }, context: Context): History?
	if poi.hidden then
		return nil
	end
	local site = Kinds.siteFor(poi.type)
	if not site then
		return nil
	end
	local rng = Seed.random(worldSeed, "site:" .. poi.id, "history")

	-- 1. The kind.
	local deep: Kinds.DeepDef? = nil
	local kind: string
	if site.size == "deep" then
		deep = Kinds.deepById[pick(rng, PlaceHistory.deepWeights(poi.biome, context))]
		kind = (deep :: Kinds.DeepDef).id
	else
		kind = site.kind or poi.type
	end

	-- 2–4. Builder, fate, occupant.
	local builderList = if deep then deep.builders else (site.builders or { { id = "old_ones", w = 1 } })
	local fateList = if deep then deep.fates else (site.fates or { { id = "abandoned", w = 1 } })
	local builderId = pick(rng, builderList)
	local fateId = pick(rng, fateList)
	local builder = Kinds.builders[builderId]
	local fate = Kinds.fates[fateId]
	local occupantId = pick(rng, fate.occupants)
	local occupant = Kinds.occupants[occupantId]

	-- 5. Age, name, danger, size.
	local range = if builder.old then Kinds.ageRange.old else Kinds.ageRange.recent
	local yearsAgo = if LIVING_FATES[fateId] and not builder.old then rng:NextInteger(20, range[2]) else rng:NextInteger(range[1], range[2])
	local names = NpcData.names[context.town.culture] or NpcData.names.wayfarer
	local tokens = {
		family = one(rng, names.family),
		first = one(rng, names.first) .. one(rng, names.firstEnd),
		town = context.town.name,
		word = "",
	}
	local words = if deep then deep.words else Kinds.siteWords[kind]
	if words then
		tokens.word = one(rng, words)
	end
	local patterns = if deep then deep.names else (Kinds.siteNames[kind] or { "the old place" })
	local name = PlaceHistory.fill(one(rng, patterns), tokens)

	local baseDanger = if deep then deep.danger else 0.2
	local danger = math.clamp(baseDanger + fate.danger + occupant.danger + (rng:NextNumber() - 0.5) * 0.2, 0, 1)
	local depths, rooms = nil, nil
	if deep then
		-- The more dangerous, the deeper it goes.
		depths = if danger >= 0.55 then deep.depths[2] else deep.depths[1]
		rooms = rng:NextInteger(deep.rooms[1], deep.rooms[2])
	end

	-- What's left and what shows.
	local leaves: { string } = {}
	addAll(leaves, builder.leaves)
	addAll(leaves, fate.leaves)
	local signs: { string } = {}
	addAll(signs, fate.signs)
	addAll(signs, occupant.signs)

	-- The lines people tell.
	local age = PlaceHistory.ageSays(yearsAgo)
	local lines: { string } = {}
	if builderId == "wildborn" then
		table.insert(lines, one(rng, fate.says))
	else
		local who = PlaceHistory.fill(builder.who, tokens)
		table.insert(lines, string.format("%s was made by %s, %s.", capitalise(name), who, age))
		table.insert(lines, one(rng, fate.says))
	end
	if not LIVING_FATES[fateId] and occupantId ~= "keepers" then
		table.insert(lines, one(rng, occupant.says))
	end

	return {
		id = poi.id,
		poiType = poi.type,
		size = site.size,
		kind = kind,
		label = if deep then deep.label else (SITE_LABELS[kind] or "a place"),
		name = name,
		builder = builderId,
		fate = fateId,
		occupant = occupantId,
		yearsAgo = yearsAgo,
		age = age,
		town = context.town.name,
		townId = context.town.id,
		culture = context.town.culture,
		danger = danger,
		depths = depths,
		rooms = rooms,
		leaves = leaves,
		signs = signs,
		writes = builder.writes,
		lines = lines,
	}
end

return PlaceHistory
