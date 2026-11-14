--!strict
--[[
	RumorRules: what townspeople talk about among themselves (docs/Rumors.md, idea #39 "Overheard
	rumours"). Pure: no Instances, no clocks, so Tests/Rumors.spec runs it directly.
	Services/RumorService gathers the facts from the world and plays the conversations.

	A FACT is something real near a town: a place (a visible POI, never a hidden mythic site or a
	town), a creature den, a wild zone, a Wildborn lair whose boss is alive, a loose feral.

		RumorRules.poiKind(poiType) -> kind?            NoticedLines' kind for a POI type, nil if not talked about
		RumorRules.shrinePlace(domain) -> string        "the fire shrine"
		RumorRules.choose(facts, x, z, heard, roll) -> Fact?   nearer is likelier; never one already heard
		RumorRules.categories(fact) -> say, reply, told        RumorLines categories (told is empty
		                                                        for facts another service tells)
]]

local RumorRules = {}

RumorRules.Tuning = table.freeze({
	tick = 4, -- seconds between looks for a conversation to overhear
	townGap = 90, -- seconds between two overheard conversations in one town
	playerGap = 45, -- a player overhears at most this often
	pairRadius = 9, -- two people this close can be talking
	hearRadius = 24, -- you overhear within this of both of them
	reach = 900, -- studs from the town's centre that people talk about
	minReach = 40, -- nothing this close: it's not a rumour, it's in the square
	nearWeight = 200, -- weight = 1 / (1 + distance / nearWeight)
	replyDelay = { 2.2, 3.2 }, -- seconds before the second person answers
	facing = 6, -- seconds they stand facing each other
	askKeep = 1800, -- real seconds after overhearing that asking still gets the story
	reveal = 80, -- studs of map uncovered around a place you were told about
	speakRadius = 28,
})

export type Fact = {
	id: string, -- stable: "poi:<id>", "den:<id>", "zone:<id>", "lair:<id>", "feral:<id>"
	kind: string, -- RumorLines kind
	group: string, -- reply group: place | den | danger
	x: number,
	z: number,
	place: string?, -- {place} in the lines
	tellable: boolean, -- RumorService tells the story itself when asked
}

local POI_KINDS: { [string]: string } = {
	ruined_library = "library",
	academy = "academy",
	hermit_tower = "hermit",
	mine = "mine",
	volcanic_vent = "vent",
	fault_zone = "fault",
	ocean_trench = "trench",
	singing_caverns = "caverns",
	hollow_grove = "grove",
	sunken_shrine = "sunken",
	quiet_place = "quiet",
	dungeon = "dungeon",
}

local SHRINE_WORDS: { [string]: string } = {
	energy = "fire",
	earth = "stone",
	water = "water",
	air = "wind",
	life = "green",
	mind = "still",
	spirit = "spirit",
	void = "dark",
	space = "far",
}

function RumorRules.poiKind(poiType: string): string?
	if POI_KINDS[poiType] then
		return POI_KINDS[poiType]
	end
	if string.sub(poiType, 1, 7) == "shrine_" then
		return "shrine"
	end
	return nil -- towns and mythic sites (and anything new) aren't talked about
end

function RumorRules.shrinePlace(domain: string): string
	return "the " .. (SHRINE_WORDS[domain] or "old") .. " shrine"
end

-- Nearer facts are likelier. `roll` is 0..1 from a seeded rng.
function RumorRules.choose(facts: { Fact }, x: number, z: number, heard: { [string]: any }, roll: number): Fact?
	local T = RumorRules.Tuning
	local pool: { { fact: Fact, weight: number } } = {}
	local total = 0
	for _, fact in facts do
		if not heard[fact.id] then
			local d = math.sqrt((fact.x - x) ^ 2 + (fact.z - z) ^ 2)
			if d >= T.minReach and d <= T.reach then
				local weight = 1 / (1 + d / T.nearWeight)
				total += weight
				table.insert(pool, { fact = fact, weight = weight })
			end
		end
	end
	if #pool == 0 then
		return nil
	end
	-- A stable order, so the same roll picks the same fact whatever order the sources came in.
	table.sort(pool, function(a, b)
		return a.fact.id < b.fact.id
	end)
	local left = math.clamp(roll, 0, 1) * total
	for _, entry in pool do
		left -= entry.weight
		if left <= 0 then
			return entry.fact
		end
	end
	return pool[#pool].fact
end

function RumorRules.categories(fact: Fact): ({ string }, { string }, { string })
	local told = if fact.tellable then { "told_" .. fact.kind } else {}
	return { "say_" .. fact.kind }, { "reply_" .. fact.group, "reply_any" }, told
end

return RumorRules
