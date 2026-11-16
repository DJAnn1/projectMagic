--!strict
--[[
	HistoryRules: things with a past (docs/LivingHistory.md §6, Living History stage 2). Pure: no
	services, no Instances. Names and lines: Chronicle/Data/DeedNames.

		HistoryRules.root(entry) -> "Ashwalker"
		HistoryRules.epithet(entry, roll) -> "Ashwalker's Bane"
		HistoryRules.placeName(entry, roll) -> "Ashwalker's Fall"
		HistoryRules.historyLine(entry, where) -> "Struck down The Ashwalker out north of Glenhold."
		HistoryRules.monumentLine(entry, where) -> the line cut into the stone
		HistoryRules.places(wild, spacing) -> { entry } the legends that name their spot: biggest
		    first, none within `spacing` studs of a bigger one, ties by id (every server agrees)
		HistoryRules.top(entries) -> entry? the biggest (ties by id)
]]

local Kinds = require(script.Parent.Data.ChronicleKinds)
local Names = require(script.Parent.Data.DeedNames)

export type Entry = {
	id: string,
	kind: string,
	x: number,
	z: number,
	score: number,
	what: string?,
	names: { string }?,
	town: string?,
}

local HistoryRules = {}

HistoryRules.Tuning = table.freeze({
	placeSpacing = 400, -- studs: one named place at most per this many
	recogniseChance = 0.35, -- someone who knows the legend says so when they see the item
	monumentRing = { 16, 30 }, -- studs from the town centre a monument may stand
})

local function pick(list: { string }, roll: number): string
	return list[math.clamp(math.floor(roll * #list) + 1, 1, #list)]
end

local function groupOf(entry: Entry): string
	local def = Kinds[entry.kind]
	return if def then def.group else "feat"
end

function HistoryRules.root(entry: Entry): string
	local what = entry.what
	if typeof(what) ~= "string" or what == "" then
		return Names.rootByKind[entry.kind] or "Old"
	end
	local stripped = string.gsub(what, "^[Tt]he%s+", "")
	return string.upper(string.sub(stripped, 1, 1)) .. string.sub(stripped, 2)
end

local function fillRoot(pattern: string, root: string): string
	return (string.gsub(pattern, "{Root}", function()
		return root
	end))
end

function HistoryRules.epithet(entry: Entry, roll: number): string
	local list = Names.epithets[groupOf(entry)] or Names.epithets.feat
	return fillRoot(pick(list, roll), HistoryRules.root(entry))
end

function HistoryRules.placeName(entry: Entry, roll: number): string
	local list = Names.places[groupOf(entry)] or Names.places.feat
	return fillRoot(pick(list, roll), HistoryRules.root(entry))
end

local function fill(text: string, vars: { [string]: string }): string
	return (string.gsub(text, "{(%w+)}", function(key)
		return vars[key] or ""
	end))
end

function HistoryRules.historyLine(entry: Entry, where: string): string
	local pattern = Names.history[entry.kind] or "Was there {where}."
	local text = fill(pattern, { what = entry.what or HistoryRules.root(entry), where = where })
	text = string.gsub(text, "%s+([,.])", "%1")
	return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

function HistoryRules.monumentLine(entry: Entry, where: string): string
	local group = groupOf(entry)
	local who = entry.names and entry.names[1]
	local key = if who then group else group .. "_nameless"
	local pattern = Names.monument[key] or Names.monument.feat_nameless
	return fill(pattern, { what = entry.what or HistoryRules.root(entry), where = where, who = who or "" })
end

local function bigger(a: Entry, b: Entry): boolean
	if a.score ~= b.score then
		return a.score > b.score
	end
	return a.id < b.id
end

function HistoryRules.places(wild: { Entry }, spacing: number): { Entry }
	local sorted = table.clone(wild)
	table.sort(sorted, bigger)
	local out: { Entry } = {}
	for _, entry in sorted do
		local clear = true
		for _, kept in out do
			if (kept.x - entry.x) ^ 2 + (kept.z - entry.z) ^ 2 < spacing * spacing then
				clear = false
				break
			end
		end
		if clear then
			table.insert(out, entry)
		end
	end
	return out
end

function HistoryRules.top(entries: { Entry }): Entry?
	local best: Entry? = nil
	for _, entry in entries do
		if not best or bigger(entry, best) then
			best = entry
		end
	end
	return best
end

return HistoryRules
