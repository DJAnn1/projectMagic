--!strict
--[[
	ChronicleRules: what the world remembers, and how much (docs/LivingHistory.md §4, stage 1).
	Pure: no Instances, no clocks, so Tests/Chronicle.spec runs it directly. Services/ChronicleService
	feeds it deeds and plays what comes out.

	THREE LEVELS
		memory      a deed scoring under keepAt stays in the NPC memories it already makes
		chronicle   keepAt and up: this server's chronicle (in memory, at most serverCap, the
		            lowest score goes first); people talk about it, and the town remembers who
		legend      legendAt and up: written to the World record for every server (at most legendCap,
		            oldest first out), with the top doer's name and UserId so it can be taken off

	SCORE   kind.base + firstBonus (a first) + powerBonus per power over 7 + townBonus (in a town),
	        clamped 0..1, then x repeatFactor ^ (times the same kind, doer and place scored within
	        repeatWindow). Nothing a dummy, duel or quest-sanctioned target did reaches here.

		ChronicleRules.score(kind, opts, repeats) -> number
		ChronicleRules.repeatKey(kind, actor, place) -> string
		ChronicleRules.add(list, entry, cap) -> Entry?           the entry pushed out, if any
		ChronicleRules.isLegend(score) / ChronicleRules.legendOf(entry) -> Legend
		ChronicleRules.addLegend(list, legend, cap) -> boolean   false when already there
		ChronicleRules.forget(list, userId) -> number            names taken off (the deed stays)
		ChronicleRules.townFor(towns, x, z) -> (townId?, inTown)
		ChronicleRules.choose(entries, x, z, heard, roll) -> Entry?
		ChronicleRules.categories(entry) -> say, reply, told, greet, journal
		ChronicleRules.evening(hour) -> boolean
]]

local Kinds = require(script.Parent.Data.ChronicleKinds)

local ChronicleRules = {}

ChronicleRules.Tuning = table.freeze({
	keepAt = 0.3, -- below this a deed stays in NPC memory only
	legendAt = 0.75, -- at or above: a legend for every server
	serverCap = 120,
	legendCap = 60,
	firstBonus = 0.25,
	powerBonus = 0.05, -- per point of power over 7
	townBonus = 0.1, -- it happened in the town itself
	repeatFactor = 0.5,
	repeatWindow = 86400, -- real seconds
	townReach = 600, -- studs from a town's centre for a deed to be that town's
	tellReach = 900, -- studs from a town's centre that people there talk about
	memoryAt = 0.4, -- at or above: everyone in that town remembers who did it
	legendWriteGap = 300, -- real seconds between legend writes from one server
	-- Evening talk (two relaxing people, after dusk, near a player).
	talkTick = 5,
	talkTownGap = 240,
	talkPlayerGap = 150,
	pairRadius = 9,
	hearRadius = 24,
	speakRadius = 28,
	replyDelay = { 2.2, 3.2 },
	facing = 6,
	eveningFrom = 18, -- game hours, wrapping past midnight
	eveningTo = 2,
	-- Greetings: someone who remembers your deed may bring it up.
	greetChance = 0.35,
})

local T = ChronicleRules.Tuning

export type Entry = {
	id: string, -- stable within a server: "<kind>:<counter>", legends keep their own ids
	kind: string,
	t: number, -- unix time
	x: number,
	z: number,
	town: string?, -- settlement id, when it belongs to a town
	inTown: boolean?,
	by: { number }?, -- UserIds of the players in it (top doer first)
	names: { string }?, -- their names when it happened, same order (never sent anywhere but bubbles)
	what: string?, -- a display name from our own data ("The Ashwalker", "drought")
	score: number,
	legend: boolean?,
	old: boolean?, -- a legend read from the World record (it happened before this server)
}

-- The compact record every server shares (World.legends). Short keys: it's one DataStore value.
export type Legend = {
	id: string,
	k: string, -- kind
	t: number,
	x: number,
	z: number,
	town: string?,
	by: string?, -- the top doer's name, nil once taken off
	u: number?, -- their UserId, nil once taken off
	w: string?, -- what
	s: number, -- score
}

export type Town = { id: string, x: number, z: number, radius: number? }

function ChronicleRules.score(kind: string, opts: { first: boolean?, power: number?, inTown: boolean? }, repeats: number): number
	local def = Kinds[kind]
	if not def then
		return 0
	end
	local s = def.base
	if opts.first then
		s += T.firstBonus
	end
	if opts.power and opts.power > 7 then
		s += (opts.power - 7) * T.powerBonus
	end
	if opts.inTown then
		s += T.townBonus
	end
	return math.clamp(s, 0, 1) * T.repeatFactor ^ math.max(0, repeats)
end

-- The same kind, by the same doer, at the same place: a repeat. A place is a town, else a 400-stud cell.
function ChronicleRules.repeatKey(kind: string, actor: string, place: string): string
	return kind .. "|" .. actor .. "|" .. place
end

function ChronicleRules.cellOf(x: number, z: number): string
	return string.format("c%d_%d", math.floor(x / 400), math.floor(z / 400))
end

-- Inserts `entry`; past `cap`, the lowest score goes (the oldest of equal scores). Returns what went.
function ChronicleRules.add(list: { Entry }, entry: Entry, cap: number): Entry?
	table.insert(list, entry)
	if #list <= cap then
		return nil
	end
	local worst = 1
	for i, e in list do
		local w = list[worst]
		if e.score < w.score or (e.score == w.score and e.t < w.t) then
			worst = i
		end
	end
	return table.remove(list, worst)
end

function ChronicleRules.isLegend(score: number): boolean
	return score >= T.legendAt
end

function ChronicleRules.legendOf(entry: Entry): Legend
	return {
		id = entry.id,
		k = entry.kind,
		t = entry.t,
		x = math.floor(entry.x),
		z = math.floor(entry.z),
		town = entry.town,
		by = if entry.names then entry.names[1] else nil,
		u = if entry.by then entry.by[1] else nil,
		w = entry.what,
		s = math.floor(entry.score * 100) / 100,
	}
end

function ChronicleRules.entryOf(legend: Legend): Entry
	return {
		id = legend.id,
		kind = legend.k,
		t = legend.t,
		x = legend.x,
		z = legend.z,
		town = legend.town,
		by = if legend.u then { legend.u } else nil,
		names = if legend.by then { legend.by } else nil,
		what = legend.w,
		score = legend.s,
		legend = true,
		old = true,
	}
end

-- Oldest first out, like Titan falls. False when that id is already there (a retried write).
function ChronicleRules.addLegend(list: { Legend }, legend: Legend, cap: number): boolean
	for _, l in list do
		if l.id == legend.id then
			return false
		end
	end
	table.insert(list, legend)
	while #list > cap do
		table.remove(list, 1)
	end
	return true
end

-- Takes a player's name off every legend (data erasure). The deeds stay, credited to nobody.
function ChronicleRules.forget(list: { Legend }, userId: number): number
	local n = 0
	for _, l in list do
		if l.u == userId then
			l.u, l.by = nil, nil
			n += 1
		end
	end
	return n
end

-- The town a deed belongs to: the nearest whose centre is within townReach. inTown when it's
-- inside the town's own radius.
function ChronicleRules.townFor(towns: { Town }, x: number, z: number): (string?, boolean)
	local best, bestD = nil, math.huge
	local inside = false
	for _, town in towns do
		local d = math.sqrt((town.x - x) ^ 2 + (town.z - z) ^ 2)
		if d <= T.townReach and d < bestD then
			best, bestD = town.id, d
			inside = d <= (town.radius or 120)
		end
	end
	return best, inside
end

--[[
	Something people near (x, z) would bring up: unheard, within tellReach (a legend of this town
	always counts), likelier the bigger and nearer it is. The same inputs give the same pick,
	whatever order the entries come in.
]]
function ChronicleRules.choose(entries: { Entry }, x: number, z: number, heard: { [string]: any }, roll: number, townId: string?): Entry?
	local pool: { Entry } = {}
	for _, e in entries do
		local d = math.sqrt((e.x - x) ^ 2 + (e.z - z) ^ 2)
		if not heard[e.id] and (d <= T.tellReach or (townId ~= nil and e.town == townId)) then
			table.insert(pool, e)
		end
	end
	if #pool == 0 then
		return nil
	end
	table.sort(pool, function(a, b)
		return a.id < b.id
	end)
	local total = 0
	local weights: { number } = {}
	for i, e in pool do
		local d = math.sqrt((e.x - x) ^ 2 + (e.z - z) ^ 2)
		local w = e.score / (1 + d / 300)
		weights[i] = w
		total += w
	end
	local at = math.clamp(roll, 0, 0.999999) * total
	for i, w in weights do
		at -= w
		if at < 0 then
			return pool[i]
		end
	end
	return pool[#pool]
end

-- ChronicleLines categories for an entry.
function ChronicleRules.categories(entry: Entry): (string, string, string, string, string)
	local def = Kinds[entry.kind]
	local group = if def then def.group else "wonder"
	return "say_" .. entry.kind, "reply_" .. group, "told_" .. entry.kind, "greet_" .. entry.kind, "journal_" .. entry.kind
end

function ChronicleRules.evening(hour: number): boolean
	if T.eveningFrom <= T.eveningTo then
		return hour >= T.eveningFrom and hour < T.eveningTo
	end
	return hour >= T.eveningFrom or hour < T.eveningTo
end

return ChronicleRules
