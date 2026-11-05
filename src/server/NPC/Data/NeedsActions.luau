--!strict
--[[
	NeedsActions: the data behind NPCBrain's utility AI.

	NEEDS are 0..1 where 1 = fully satisfied. They drain every game hour (`decay`, scaled by
	personality and quirks) and actions refill them (`satisfies`, per game hour spent).
	safety is different: it RECOVERS on its own toward 1 and is knocked down by threats.

	ACTIONS list what they satisfy, where they happen (a district, see ScheduleService), which
	traits make them appealing (personality affinity, centred so 0.5 = neutral), and how well
	they fit each schedule BLOCK (1 = neutral, >1 = expected now, <1 = out of place).

	SCHEDULES are 24-hour templates of blocks, per occupation.
]]

local NeedsActions = {}

NeedsActions.needs = { "rest", "food", "safety", "social", "purpose", "wealth" }

-- Base drain per game hour (safety: recovery per hour instead).
NeedsActions.decay = {
	rest = 0.045,
	food = 0.07,
	safety = -0.15, -- negative: recovers
	social = 0.04,
	purpose = 0.035,
	wealth = 0.02,
} :: { [string]: number }

export type ActionDef = {
	name: string,
	satisfies: { [string]: number }, -- need -> gain per game hour
	district: string, -- "home" | "work" (occupation district) | a district id | "here"
	traits: { [string]: number }?, -- trait -> affinity weight
	blocks: { [string]: number }, -- block -> schedule fit (missing = 1)
	requires: string?, -- "magic" | "hobby" | "student" | "child" | "adult" | "threat" | "work"
	minutes: number, -- typical commitment before re-deciding
	verb: string, -- for traces: "is sleeping"
}

local NO_SLEEP = { sleep = 0.15 }

NeedsActions.actions = {
	sleep = { name = "Sleep", verb = "sleeping", satisfies = { rest = 0.14 }, district = "home", blocks = { sleep = 2.2, meal = 0.25, work = 0.2, school = 0.2, free = 0.5, worship = 0.3, study = 0.3 }, minutes = 120 },
	eat = { name = "Eat", verb = "eating", satisfies = { food = 0.65, social = 0.04 }, district = "home", blocks = { meal = 2.0, sleep = 0.15, work = 0.6, school = 0.5 }, minutes = 40 },
	work = { name = "Work", verb = "working", satisfies = { purpose = 0.08 }, district = "work", traits = { conscientiousness = 0.6, greed = 0.3 }, requires = "work", blocks = { work = 2.0, free = 0.45, meal = 0.4, sleep = 0.05, worship = 0.5 }, minutes = 90 },
	study = { name = "Study", verb = "studying", satisfies = { purpose = 0.12 }, district = "library", traits = { openness = 0.5, curiosity = 0.5, ambition = 0.5, conscientiousness = 0.3 }, requires = "magic", blocks = { study = 2.0, free = 1.15, work = 0.55, sleep = 0.1 }, minutes = 60 },
	practice = { name = "Practise magic", verb = "practising magic", satisfies = { purpose = 0.1 }, district = "training", traits = { ambition = 0.6, pride = 0.3, patience = 0.2 }, requires = "magic", blocks = { free = 1.2, study = 1.4, work = 0.5, sleep = 0.1 }, minutes = 45 },
	socialize = { name = "Socialise", verb = "socialising", satisfies = { social = 0.28 }, district = "tavern", traits = { extraversion = 0.9, agreeableness = 0.3, humor = 0.3 }, blocks = { free = 1.7, meal = 0.9, work = 0.4, sleep = 0.1 }, minutes = 60 },
	worship = { name = "Worship", verb = "at worship", satisfies = { purpose = 0.06, safety = 0.12, social = 0.05 }, district = "temple", traits = { loyalty = 0.4, neuroticism = 0.2, openness = -0.2 }, blocks = { worship = 2.2, free = 0.8, sleep = 0.1 }, minutes = 60 },
	wander = { name = "Wander", verb = "wandering", satisfies = { purpose = 0.03, social = 0.02 }, district = "wilds", traits = { curiosity = 0.7, openness = 0.5, conscientiousness = -0.3 }, blocks = { free = 1.0, work = 0.3, sleep = 0.1 }, minutes = 45 },
	hobby = { name = "Hobby", verb = "on their hobby", satisfies = { purpose = 0.06, rest = 0.02 }, district = "home", traits = { patience = 0.3 }, requires = "hobby", blocks = { free = 1.45, sleep = 0.1, work = 0.3 }, minutes = 45 },
	teach = { name = "Teach", verb = "teaching", satisfies = { purpose = 0.12, social = 0.08 }, district = "school", traits = { compassion = 0.4, patience = 0.5 }, requires = "student", blocks = { work = 1.3, free = 1.0, study = 1.3, sleep = 0.1 }, minutes = 60 },
	attend = { name = "Lessons", verb = "at lessons", satisfies = { purpose = 0.1, social = 0.1 }, district = "school", requires = "child", blocks = { school = 2.4, free = 0.3, sleep = 0.05 }, minutes = 90 },
	play = { name = "Play", verb = "playing", satisfies = { social = 0.2, purpose = 0.03 }, district = "market", traits = { extraversion = 0.5, curiosity = 0.3 }, requires = "child", blocks = { free = 1.7, school = 0.3, sleep = 0.1 }, minutes = 45 },
	trade = { name = "Trade", verb = "trading", satisfies = { wealth = 0.05, social = 0.06 }, district = "market", traits = { greed = 0.6, extraversion = 0.3 }, requires = "adult", blocks = { free = 1.0, work = 0.9, sleep = 0.05 }, minutes = 45 },
	help = { name = "Help someone", verb = "helping a neighbour", satisfies = { purpose = 0.08, social = 0.06 }, district = "street", traits = { compassion = 0.8, agreeableness = 0.3 }, requires = "adult", blocks = { free = 1.1, work = 0.6, sleep = 0.1 }, minutes = 40 },
	idle = { name = "Idle", verb = "taking it easy", satisfies = { rest = 0.04 }, district = "here", blocks = NO_SLEEP, minutes = 20 },
	shelter = { name = "Take shelter", verb = "sheltering", satisfies = { safety = 0.5 }, district = "home", traits = { neuroticism = 0.6 }, requires = "threat", blocks = {}, minutes = 30 },
} :: { [string]: ActionDef }

NeedsActions.actionIds = (function()
	local ids = {}
	for id in NeedsActions.actions do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end)()

-- ─── Schedules: hour (0-23) -> block ────────────────────────────────────────

local function plan(spec: { { number | string } }): { string }
	local out: { string } = {}
	for _, span in spec do
		local from, to, block = span[1] :: number, span[2] :: number, span[3] :: string
		for h = from, to - 1 do
			out[h % 24 + 1] = block
		end
	end
	return out
end

NeedsActions.schedules = {
	day = plan({ { 0, 6, "sleep" }, { 6, 7, "meal" }, { 7, 12, "work" }, { 12, 13, "meal" }, { 13, 18, "work" }, { 18, 19, "meal" }, { 19, 22, "free" }, { 22, 24, "sleep" } }),
	early = plan({ { 0, 4, "sleep" }, { 4, 5, "meal" }, { 5, 11, "work" }, { 11, 12, "meal" }, { 12, 16, "work" }, { 16, 17, "meal" }, { 17, 21, "free" }, { 21, 24, "sleep" } }),
	night = plan({ { 0, 5, "work" }, { 5, 6, "meal" }, { 6, 14, "sleep" }, { 14, 15, "meal" }, { 15, 18, "free" }, { 18, 19, "meal" }, { 19, 24, "work" } }),
	evening = plan({ { 0, 2, "work" }, { 2, 10, "sleep" }, { 10, 11, "meal" }, { 11, 15, "free" }, { 15, 16, "meal" }, { 16, 24, "work" } }),
	shift = plan({ { 0, 6, "sleep" }, { 6, 7, "meal" }, { 7, 15, "work" }, { 15, 16, "meal" }, { 16, 22, "free" }, { 22, 24, "sleep" } }),
	priest = plan({ { 0, 5, "sleep" }, { 5, 7, "worship" }, { 7, 8, "meal" }, { 8, 12, "work" }, { 12, 13, "meal" }, { 13, 15, "study" }, { 15, 17, "work" }, { 17, 18, "worship" }, { 18, 19, "meal" }, { 19, 21, "free" }, { 21, 24, "sleep" } }),
	scholar = plan({ { 0, 7, "sleep" }, { 7, 8, "meal" }, { 8, 12, "study" }, { 12, 13, "meal" }, { 13, 17, "work" }, { 17, 18, "meal" }, { 18, 22, "free" }, { 22, 24, "sleep" } }),
	child = plan({ { 0, 7, "sleep" }, { 7, 8, "meal" }, { 8, 12, "school" }, { 12, 13, "meal" }, { 13, 15, "school" }, { 15, 18, "free" }, { 18, 19, "meal" }, { 19, 20, "free" }, { 20, 24, "sleep" } }),
	retired = plan({ { 0, 7, "sleep" }, { 7, 8, "meal" }, { 8, 10, "worship" }, { 10, 12, "free" }, { 12, 13, "meal" }, { 13, 17, "free" }, { 17, 18, "meal" }, { 18, 21, "free" }, { 21, 24, "sleep" } }),
} :: { [string]: { string } }

-- World events that threaten a settlement (safety drops, shelter becomes possible).
NeedsActions.dangerEvents = {
	wildfire = 0.5,
	tempest = 0.45,
	volcanic_unrest = 0.4,
	monster_migration = 0.5,
	plague = 0.25,
	magic_storm = 0.3,
} :: { [string]: number }

return NeedsActions
