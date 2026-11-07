--!strict
--[[
	MarkRules: the decisions behind Magic Marks (docs/MagicMarks.md). Pure: no Instances, no clock of
	its own (callers pass the day), so Tests/Marks.spec runs it directly and the client can decode.

	THE RECORD (PlayerData.marks, saved)
		points     domain -> points (decayed, fractional)
		day        the day `dayPoints` counts
		dayPoints  domain -> points gained that day (the daily cap)
		decayDay   the last day decay was applied
		shown      domain -> stage currently on your body (1..3)

	THE WIRE FORMAT (Model attribute "MagicMarks")
		"energy:2,water:1"   strongest first; nil/"" = unmarked. Players and NPC rigs both carry it.

		MarkRules.newRecord() -> Record
		MarkRules.dayOf(unixTime) -> number
		MarkRules.decay(record, today)                       fade what you haven't used
		MarkRules.addCast(record, domains, today) -> number  points actually added (cap aware)
		MarkRules.stageFor(points, shown) -> 0..3            with hysteresis
		MarkRules.evaluate(record) -> { [domain]: stage }    the marks you should show
		MarkRules.changes(old, new) -> { { domain, from, to } }
		MarkRules.encode(map) -> string?   MarkRules.decode(string?) -> { { domain, stage } }
		MarkRules.resist(string?) -> { [domain]: number }    Cast/Resistances "marks" source
		MarkRules.unsettle(string?) -> number                0..1, GreetingRules
		MarkRules.npcStage(tierIndex) -> 0..3
		MarkRules.journalLine(domain, from, to) -> string?
		MarkRules.seen(domain, stage) -> string?
]]

local Data = require(script.Parent.Data.Marks)

local T = Data.tuning
local D = Data.domains

export type Record = {
	points: { [string]: number },
	day: number,
	dayPoints: { [string]: number },
	decayDay: number,
	shown: { [string]: number },
}
export type Mark = { domain: string, stage: number }
export type Change = { domain: string, from: number, to: number }

local MarkRules = {}

MarkRules.tuning = T

function MarkRules.newRecord(): Record
	return { points = {}, day = 0, dayPoints = {}, decayDay = 0, shown = {} }
end

function MarkRules.dayOf(unixTime: number): number
	return math.floor(unixTime / 86400)
end

-- What you stop using fades: each real day takes decayPerDay of every domain's points.
function MarkRules.decay(record: Record, today: number)
	if record.decayDay == 0 then
		record.decayDay = today
		return
	end
	local days = today - record.decayDay
	if days <= 0 then
		return
	end
	local keep = (1 - T.decayPerDay) ^ math.min(days, 3650)
	for domain, points in record.points do
		local left = points * keep
		record.points[domain] = if left < 1 then nil else left
	end
	record.decayDay = today
end

-- One working spell. A hybrid splits its points between its domains. Returns what was added.
function MarkRules.addCast(record: Record, domains: { string }, today: number): number
	local valid: { string } = {}
	for _, domain in domains do
		if D[domain] and not table.find(valid, domain) then
			table.insert(valid, domain)
		end
	end
	if #valid == 0 then
		return 0
	end
	if record.day ~= today then
		record.day = today
		record.dayPoints = {}
	end
	local each = T.perCast / #valid
	local added = 0
	for _, domain in valid do
		local room = T.dayCap - (record.dayPoints[domain] or 0)
		local gain = math.clamp(each, 0, math.max(0, room))
		if gain > 0 then
			record.dayPoints[domain] = (record.dayPoints[domain] or 0) + gain
			record.points[domain] = (record.points[domain] or 0) + gain
			added += gain
		end
	end
	return added
end

-- The stage a domain's points earn. A shown stage only drops once points fall below its
-- threshold x dropAt, so a mark doesn't flicker on a boundary.
function MarkRules.stageFor(points: number, shown: number?): number
	local raw = 0
	for i, need in T.stages do
		if points >= need then
			raw = i
		end
	end
	local current = shown or 0
	if raw >= current then
		return raw
	end
	for i = current, 1, -1 do
		if points >= T.stages[i] * T.dropAt then
			return math.max(raw, i)
		end
	end
	return raw
end

-- The marks you should carry: enough points, a big enough share of your magic, the strongest few.
function MarkRules.evaluate(record: Record): { [string]: number }
	local total = 0
	for _, points in record.points do
		total += points
	end
	local out: { [string]: number } = {}
	if total <= 0 then
		return out
	end
	local candidates: { { domain: string, points: number, stage: number } } = {}
	for domain, points in record.points do
		if D[domain] then
			local shown = record.shown[domain]
			local stage = MarkRules.stageFor(points, shown)
			local share = points / total
			local need = if shown and shown > 0 then T.keepShare else T.share
			if stage > 0 and share >= need then
				table.insert(candidates, { domain = domain, points = points, stage = stage })
			end
		end
	end
	table.sort(candidates, function(a, b)
		if a.points ~= b.points then
			return a.points > b.points
		end
		return a.domain < b.domain
	end)
	for i = 1, math.min(#candidates, T.maxMarks) do
		out[candidates[i].domain] = candidates[i].stage
	end
	return out
end

function MarkRules.changes(old: { [string]: number }, new: { [string]: number }): { Change }
	local out: { Change } = {}
	for domain, stage in new do
		local from = old[domain] or 0
		if stage ~= from then
			table.insert(out, { domain = domain, from = from, to = stage })
		end
	end
	for domain, stage in old do
		if not new[domain] and stage > 0 then
			table.insert(out, { domain = domain, from = stage, to = 0 })
		end
	end
	table.sort(out, function(a, b)
		return a.domain < b.domain
	end)
	return out
end

local function sorted(map: { [string]: number }): { Mark }
	local list: { Mark } = {}
	for domain, stage in map do
		if D[domain] and stage >= 1 then
			table.insert(list, { domain = domain, stage = math.clamp(math.floor(stage), 1, #T.stages) })
		end
	end
	table.sort(list, function(a, b)
		if a.stage ~= b.stage then
			return a.stage > b.stage
		end
		return a.domain < b.domain
	end)
	return list
end

function MarkRules.encode(map: { [string]: number }): string?
	local parts: { string } = {}
	for i, mark in sorted(map) do
		if i > T.maxMarks then
			break
		end
		table.insert(parts, mark.domain .. ":" .. mark.stage)
	end
	return if #parts > 0 then table.concat(parts, ",") else nil
end

-- Decoded strings are cached: Resistances asks on every hit.
local cache: { [string]: { Mark } } = {}
local cached = 0

function MarkRules.decode(raw: string?): { Mark }
	if typeof(raw) ~= "string" or raw == "" then
		return {}
	end
	local hit = cache[raw]
	if hit then
		return hit
	end
	local map: { [string]: number } = {}
	for domain, stage in string.gmatch(raw, "(%a+):(%d)") do
		local n = tonumber(stage) or 0
		if D[domain] and n >= 1 then
			map[domain] = math.max(map[domain] or 0, n)
		end
	end
	local list = sorted(map)
	while #list > T.maxMarks do
		table.remove(list)
	end
	table.freeze(list)
	if cached > 200 then
		table.clear(cache)
		cached = 0
	end
	cache[raw] = list
	cached += 1
	return list
end

-- The perk: your body gets used to its own magic.
function MarkRules.resist(raw: string?): { [string]: number }
	local out: { [string]: number } = {}
	for _, mark in MarkRules.decode(raw) do
		out[mark.domain] = mark.stage * T.resistPerStage
	end
	return out
end

-- The quirk: some marks bother nervous people. 0..1, strongest mark wins.
function MarkRules.unsettle(raw: string?): number
	local worst = 0
	for _, mark in MarkRules.decode(raw) do
		worst = math.max(worst, D[mark.domain].unsettle * mark.stage / #T.stages)
	end
	return worst
end

function MarkRules.npcStage(tierIndex: number): number
	local stage = 0
	for i, need in T.npcTiers do
		if tierIndex >= need then
			stage = i
		end
	end
	return stage
end

function MarkRules.journalLine(domain: string, from: number, to: number): string?
	local def = D[domain]
	if not def or from == to then
		return nil
	end
	if to > from then
		return def.journal[to]
	end
	return def.journal[#T.stages + 1]
end

function MarkRules.seen(domain: string, stage: number): string?
	local def = D[domain]
	return if def then def.seen[math.clamp(stage, 1, #T.stages)] else nil
end

return MarkRules
