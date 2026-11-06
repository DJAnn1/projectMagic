--!strict
--[[
	BarkEngine: picks and fills a line from Data/Barks. Pure: no Instances, no clocks of its own, so
	Tests/LivingWorld.spec runs it directly.

		BarkEngine.eligible(line, ctx) -> boolean
		BarkEngine.pick(prefix, ctx, rng, recent, cooling?) -> (line?, text?)
		BarkEngine.fill(text, vars) -> string?        nil when a var isn't available

	ctx: { hour, occupation, action, mood, rel, traits, quirks = { [id] = true }, events = { [type] = true },
	       biome, culture, child, mage, deeds = { [kind] = true }, vars = { [name] = string } }

	Cooldowns are the caller's: `recent` is lines this NPC said lately, `cooling` is lines someone
	nearby said lately. Both are sets of line indices.
]]

local Barks = require(script.Parent.Data.Barks)

export type Context = {
	hour: number,
	occupation: string,
	action: string?,
	mood: string,
	rel: string,
	traits: { [string]: number },
	quirks: { [string]: boolean },
	events: { [string]: boolean },
	biome: string?,
	culture: string?,
	child: boolean,
	mage: boolean,
	deeds: { [string]: boolean },
	vars: { [string]: string },
}

local BarkEngine = {}

local CONDITIONS = { "hours", "occ", "action", "mood", "rel", "high", "low", "quirk", "event", "biome", "culture", "child", "deed", "mage" }

local function inHours(hours: { number }, hour: number): boolean
	local from, to = hours[1], hours[2]
	if from <= to then
		return hour >= from and hour < to
	end
	return hour >= from or hour < to
end

local function listed(list: { string }?, value: string?): boolean
	return list == nil or (value ~= nil and table.find(list, value) ~= nil)
end

local function anyIn(list: { string }?, set: { [string]: boolean }): boolean
	if list == nil then
		return true
	end
	for _, id in list do
		if set[id] then
			return true
		end
	end
	return false
end

function BarkEngine.fill(text: string, vars: { [string]: string }): string?
	local missing = false
	local out = string.gsub(text, "{(%a+)}", function(name: string): string
		local value = vars[name]
		if not value then
			missing = true
			return ""
		end
		return value
	end)
	if missing then
		return nil
	end
	-- A story var starts lower case: a line that opens with one still reads as a sentence.
	return (string.gsub(out, "^%l", string.upper))
end

function BarkEngine.eligible(line: Barks.Line, ctx: Context): boolean
	if line.hours and not inHours(line.hours, ctx.hour) then
		return false
	end
	if not listed(line.occ, ctx.occupation) or not listed(line.action, ctx.action) then
		return false
	end
	if not listed(line.mood, ctx.mood) or not listed(line.rel, ctx.rel) then
		return false
	end
	if not listed(line.biome, ctx.biome) or not listed(line.culture, ctx.culture) then
		return false
	end
	if line.child ~= nil and line.child ~= ctx.child then
		return false
	end
	if line.mage ~= nil and line.mage ~= ctx.mage then
		return false
	end
	if not anyIn(line.quirk, ctx.quirks) or not anyIn(line.event, ctx.events) or not anyIn(line.deed, ctx.deeds) then
		return false
	end
	for trait, atLeast in (line.high or {}) :: { [string]: number } do
		if (ctx.traits[trait] or 0.5) < atLeast then
			return false
		end
	end
	for trait, atMost in (line.low or {}) :: { [string]: number } do
		if (ctx.traits[trait] or 0.5) > atMost then
			return false
		end
	end
	return true
end

local function weightOf(line: any): number
	local weight = 1
	for _, key in CONDITIONS do
		if line[key] ~= nil then
			weight += 1
		end
	end
	-- News and memories are what make the world feel alive: they should come up when they can.
	if line.cat == "story" or line.cat == "deed" then
		weight += 3
	end
	return weight
end

--[[
	A line whose category starts with `prefix` ("greet_warm"), or for "ambient" any non-greeting line.
	Returns (index, text), or nil when nothing fits.
]]
function BarkEngine.pick(prefix: string, ctx: Context, rng: Random, recent: { [number]: boolean }, cooling: { [number]: boolean }?): (number?, string?)
	local ambient = prefix == "ambient"
	local total = 0
	local options: { { index: number, text: string, weight: number } } = {}
	for index, line in Barks do
		local matches = if ambient then string.sub(line.cat, 1, 6) ~= "greet_" else line.cat == prefix
		if matches and not recent[index] and not (cooling and cooling[index]) and BarkEngine.eligible(line, ctx) then
			local text = BarkEngine.fill(line.text, ctx.vars)
			if text then
				local weight = weightOf(line)
				total += weight
				table.insert(options, { index = index, text = text, weight = weight })
			end
		end
	end
	if #options == 0 then
		return nil, nil
	end
	local roll = rng:NextNumber() * total
	for _, option in options do
		roll -= option.weight
		if roll <= 0 then
			return option.index, option.text
		end
	end
	local last = options[#options]
	return last.index, last.text
end

return BarkEngine
