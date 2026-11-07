--!strict
--[[
	ActivityRules: pure decisions behind ActivityService (docs/Activities.md §1). No instances, no clock:
	everything is a function of the NPC record and the numbers passed in, so specs and the Readability
	Report can run it without a live world.

		candidates(npc, action) -> { Activity }       every library activity this person could be doing
		pick(npc, action, day) -> Activity?           the one they are, seeded per person per day
		reason(npc, action, block) -> string          a reason id (ActivityLibrary.reasons)
		minutes(def, npc, day, n) -> number           how long one piece of work takes, in game minutes
		item(def, npc, day) -> number                 which item the first piece makes
		variant(def, npc) -> number                   which pose variant they move with
		knowledge(band, mindTier, watched) -> number  0 stranger · 1 recognised · 2 known (Observe)
		describe(npc, def, state, level, opts) -> (title, line)   the Observe tooltip's words
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local ActivityLibrary = require(Shared.Life.Data.ActivityLibrary)
local ActivityPoses = require(Shared.Life.Data.ActivityPoses)

type Activity = ActivityLibrary.Activity

local ActivityRules = {}

-- The NPC's strongest domain and its tier (practice), from the record alone.
function ActivityRules.bestDomain(npc: any): (string?, number)
	local magic = npc.magic
	if not magic or not magic.mastery then
		return nil, 0
	end
	local bestId, bestM = nil, -1
	for id, m in magic.mastery :: { [string]: number } do
		if m > bestM or (m == bestM and bestId and id < bestId) then
			bestId, bestM = id, m
		end
	end
	if not bestId then
		for id in (magic.unlocked or {}) :: { [string]: any } do
			if not bestId or id < bestId then
				bestId, bestM = id, 0
			end
		end
	end
	local branch = bestId and Registry.branches[bestId]
	if not branch then
		return nil, 0
	end
	-- An unlocked branch with no mastery yet is tier 1, as in NPCMagicLife.tierOf.
	return branch.domains[1], math.max(1, MagicCore.tierForMastery(math.max(bestM, 0)))
end

function ActivityRules.candidates(npc: any, action: string): { Activity }
	local out: { Activity } = {}
	local domain = nil
	if action == "practice" then
		domain = ActivityRules.bestDomain(npc)
	end
	for _, def in ActivityLibrary.list do
		if table.find(def.actions, action) then
			local jobOk = def.occupations == nil or table.find(def.occupations, npc.occupation) ~= nil
			local domainOk = def.domain == nil or def.domain == domain
			-- Hobbies: the one this person actually has (their hobby quirk), nobody else's.
			local quirkOk = true
			if def.quirks then
				quirkOk = false
				for _, q in (npc.quirks or {}) :: { string } do
					if table.find(def.quirks, q) then
						quirkOk = true
					end
				end
			end
			-- Eating: sociable people eat at the tavern, the rest at home (ScheduleService.districtFor's rule).
			local eatOk = true
			if def.id == "eating_tavern" then
				eatOk = (npc.traits and npc.traits.extraversion or 0.5) > 0.65
			elseif def.id == "eating_home" then
				eatOk = not ((npc.traits and npc.traits.extraversion or 0.5) > 0.65)
			end
			if jobOk and domainOk and quirkOk and eatOk then
				table.insert(out, def)
			end
		end
	end
	return out
end

-- Seeded per person and per day among the candidates, by weight. Nil = nothing in the library yet.
function ActivityRules.pick(npc: any, action: string, day: number): Activity?
	local list = ActivityRules.candidates(npc, action)
	if #list == 0 then
		return nil
	elseif #list == 1 then
		return list[1]
	end
	local total = 0
	for _, def in list do
		total += def.weight or 1
	end
	local roll = (Seed.derive(npc.seed or 1, tostring(day), "activity:" .. action) % 10000) / 10000 * total
	for _, def in list do
		roll -= def.weight or 1
		if roll < 0 then
			return def
		end
	end
	return list[#list]
end

function ActivityRules.reason(npc: any, action: string, block: string?): string
	local needs = npc.needs or {}
	local traits = npc.traits or {}
	if action == "sleep" then
		return if (needs.rest or 1) < 0.3 then "tired" else "bedtime"
	elseif action == "eat" then
		return if (needs.food or 1) < 0.35 then "hungry" else "mealtime"
	elseif action == "work" then
		if npc.occupation == "guard" then
			return "watch"
		elseif npc.occupation == "lamplighter" then
			return "lamps"
		end
		return if block == "work" or block == nil then "shift" else "overtime"
	elseif action == "study" then
		local magic = npc.magic
		return if magic and (magic.teacher or magic.school) then "lesson" else "curious"
	elseif action == "practice" then
		return if (traits.ambition or 0.5) > 0.65 then "ambition" else "practice"
	elseif action == "worship" then
		return if (needs.safety or 1) < 0.6 then "frightened" else "prayers"
	elseif action == "help" then
		return "helping"
	elseif action == "socialize" then
		return "company"
	elseif action == "trade" then
		return "bargain"
	elseif action == "teach" then
		return "teaching"
	elseif action == "attend" then
		return "lessons"
	elseif action == "play" then
		return "playing"
	elseif action == "idle" then
		return "resting"
	elseif action == "wander" then
		return "walking"
	elseif action == "hobby" then
		return "pastime"
	elseif action == "shelter" then
		return "afraid"
	end
	return "told"
end

local function unit(npc: any, day: number, what: string): number
	return (Seed.derive(npc.seed or 1, tostring(day), what) % 10000) / 10000
end

function ActivityRules.minutes(def: Activity, npc: any, day: number, n: number): number
	local lo, hi = def.minutes[1], def.minutes[2]
	return lo + (hi - lo) * unit(npc, day, "minutes:" .. def.id .. ":" .. n)
end

function ActivityRules.item(def: Activity, npc: any, day: number): number
	local items = def.items
	if not items or #items == 0 then
		return 1
	end
	return math.floor(unit(npc, day, "item:" .. def.id) * #items) + 1
end

function ActivityRules.variant(def: Activity, npc: any): number
	local pose = ActivityPoses.poses[def.pose]
	local n = if pose then #pose.variants else 1
	return ((npc.seed or 1) % math.max(n, 1)) + 1
end

--[[
	How much the viewer can read off this person (Observe):
		0  a stranger, glanced at: what they're doing, not who they are
		1  recognised: name and trade; a stranger watched for a while (WATCH_SECONDS) also gets here
		2  known: why they're doing it too. A friend, or a sharp Mind (tier 4+), or watching a
		   recognised person for a while.
	Hostile and wary people are read like strangers you've met: level 1 at most.
]]
ActivityRules.WATCH_SECONDS = 4

function ActivityRules.knowledge(band: string, mindTier: number, watched: number): number
	local level = if band == "stranger" then 0 elseif band == "friend" or band == "close" then 2 else 1
	if watched >= ActivityRules.WATCH_SECONDS then
		level += 1
	end
	if mindTier >= 4 then
		level += 1
	end
	if band == "hostile" or band == "wary" then
		level = math.min(level, 1)
	end
	return math.clamp(level, 0, 2)
end

-- A word or two of personality on how they're going about it (empty when nothing stands out).
function ActivityRules.manner(npc: any, def: Activity): string
	local t = npc.traits or {}
	if def.id == "sleeping" then
		return if (t.neuroticism or 0.5) > 0.75 then "tossing and turning" else ""
	end
	if (t.conscientiousness or 0.5) > 0.78 then
		return "with great care"
	elseif (t.patience or 0.5) < 0.22 then
		return "impatiently"
	elseif (t.extraversion or 0.5) > 0.8 then
		return "humming as they go"
	elseif (t.neuroticism or 0.5) > 0.8 then
		return "anxiously"
	elseif (t.conscientiousness or 0.5) < 0.2 then
		return "half-heartedly"
	elseif (t.pride or 0.5) > 0.8 then
		return "showing off a little"
	end
	return ""
end

local function capitalise(s: string): string
	return (string.upper(string.sub(s, 1, 1)) .. string.sub(s, 2))
end

export type DescribeOpts = {
	detail: string, -- "Minimal" | "Standard" | "Detailed"
	progress: number?, -- 0..1 of the current piece
	phase: string?,
	item: number,
	reason: string,
}

--[[
	The tooltip: (title, line).
		level 0   title "A smith"            line "Someone working at an anvil"
		level 1   title "Marta · Smith"      line "Hammering out a plowshare"
		level 2   title "Marta · Smith"      line "Hammering out a plowshare, with great care · on shift"
	Detailed adds how far along (level 1+). Minimal is the line alone, no reason or manner.
]]
function ActivityRules.describe(npc: any, def: Activity?, level: number, opts: DescribeOpts): (string, string)
	local occupation = tostring(npc.occupationName or npc.occupation or "")
	local title = if level >= 1 then string.format("%s · %s", tostring(npc.name), occupation)
		elseif npc.ageBand == "child" then "A child"
		else "Someone"
	if not def then
		return title, if level >= 1 then "Going about their day" else "Going about their day"
	end
	if level == 0 then
		return title, def.seen
	end
	local line = ActivityLibrary.doingText(def, opts.item)
	if opts.phase == "T" then
		line = "On the way: " .. string.lower(string.sub(line, 1, 1)) .. string.sub(line, 2)
	elseif opts.phase == "I" then
		line = "Paused: " .. string.lower(string.sub(line, 1, 1)) .. string.sub(line, 2)
	end
	if opts.detail ~= "Minimal" and level >= 2 then
		local manner = ActivityRules.manner(npc, def)
		if manner ~= "" and opts.phase ~= "T" then
			line ..= ", " .. manner
		end
		local why = ActivityLibrary.reasons[opts.reason]
		if why then
			line ..= " · " .. why
		end
	end
	if opts.detail == "Detailed" and opts.progress and (opts.phase == "W" or opts.phase == "I") and def.items then
		line ..= " (" .. ActivityLibrary.progressWord(opts.progress) .. ")"
	end
	return title, capitalise(line)
end

return ActivityRules
