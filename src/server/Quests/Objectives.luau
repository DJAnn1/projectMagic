--!strict
--[[
	Objectives: the pure rules for quest objectives (docs/Quests.md §2). QuestDirector feeds it
	events and positions and stores the progress; nothing here touches the world.

		Objectives.required(spec) -> number            progress needed to complete
		Objectives.castMatches(match, cast) -> boolean
		Objectives.tagsMeet(needs, tags) -> boolean
		Objectives.castGain(spec, cast) -> (gain, creative)   what one cast is worth to an objective
		Objectives.current(option, progress, key) -> ObjectiveSpec?   the first unfinished one
		Objectives.predicates[name](ctx) -> boolean    `state` objectives

	A RESOLVED CAST (Topics.SpellResolved) looks like:
		{ casterUserId, point, domains, branch, branchPath (branch + ancestors), property, verb,
		  form, route, power (recipe power), tags (InteractionMatrix), effective, hits, harmful }

	CREATIVE SOLUTIONS: a cast that doesn't match the objective's `match` but whose interaction
	tags meet its `needs` still counts (at 75%), and is recorded as creative. That's how
	"freeze the flood", "a firebreak of stone" or "dry the river with heat" are recognised without
	anyone listing them.
]]

local QuestTypes = require(script.Parent.QuestTypes)

type ObjectiveSpec = QuestTypes.ObjectiveSpec
type CastMatch = QuestTypes.CastMatch

export type Cast = {
	casterUserId: number,
	point: Vector3,
	domains: { string },
	branch: string,
	branchPath: { string },
	property: string,
	verb: string,
	form: string,
	route: string,
	power: number,
	tags: { string },
	effective: boolean,
	hits: number,
	harmful: boolean,
}

local CREATIVE_SHARE = 0.75

local Objectives = {}

function Objectives.required(spec: ObjectiveSpec): number
	if spec.kind == "cast" then
		return spec.amount or spec.count or 1
	elseif spec.kind == "reach" or spec.kind == "collect" then
		return math.max(1, spec.seconds or 1)
	elseif spec.kind == "demonstrate" then
		return spec.count or 1
	end
	return 1
end

local function anyIn(list: { string }?, values: { string }): boolean
	if not list then
		return true
	end
	for _, v in values do
		if table.find(list, v) then
			return true
		end
	end
	return false
end

local function oneIn(list: { string }?, value: string): boolean
	return list == nil or table.find(list, value) ~= nil
end

function Objectives.castMatches(match: CastMatch?, cast: Cast): boolean
	if not match then
		return true
	end
	return anyIn(match.domains, cast.domains)
		and oneIn(match.properties, cast.property)
		and oneIn(match.verbs, cast.verb)
		and oneIn(match.forms, cast.form)
		and oneIn(match.routes, cast.route)
		and anyIn(match.branches, cast.branchPath)
		and (match.harmful == nil or match.harmful == cast.harmful)
		and (match.minPower == nil or cast.power >= match.minPower)
		and (match.maxPower == nil or cast.power <= match.maxPower)
end

function Objectives.tagsMeet(needs: { string }?, tags: { string }): boolean
	if not needs then
		return false
	end
	for _, tag in tags do
		if table.find(needs, tag) then
			return true
		end
	end
	return false
end

--[[
	What one cast is worth to a cast/demonstrate objective (position checks are the caller's).
	Amount objectives gain the recipe power; count objectives gain 1. Ineffective casts (that hit
	nothing and changed nothing) don't count, so spamming at empty air achieves nothing, unless
	the objective is a show (`anyEffect`: "show me your magic", a lesson).
]]
function Objectives.castGain(spec: ObjectiveSpec, cast: Cast): (number, boolean)
	if not cast.effective and spec.kind ~= "demonstrate" and not spec.anyEffect then
		return 0, false
	end
	local unit = if spec.amount then cast.power else 1
	if Objectives.castMatches(spec.match, cast) then
		return unit, false
	end
	if Objectives.tagsMeet(spec.needs, cast.tags) then
		return unit * CREATIVE_SHARE, true
	end
	return 0, false
end

function Objectives.key(optionId: string, objectiveId: string): string
	return optionId .. "/" .. objectiveId
end

function Objectives.done(spec: ObjectiveSpec, optionId: string, progress: { [string]: number }): boolean
	return (progress[Objectives.key(optionId, spec.id)] or 0) >= Objectives.required(spec)
end

-- The objectives that may take progress now: all unfinished ones, or (ordered) only the first.
function Objectives.open(option: QuestTypes.Option, progress: { [string]: number }): { ObjectiveSpec }
	local out: { ObjectiveSpec } = {}
	for _, spec in option.objectives do
		if not Objectives.done(spec, option.id, progress) then
			table.insert(out, spec)
			if option.ordered then
				break
			end
		end
	end
	return out
end

function Objectives.optionDone(option: QuestTypes.Option, progress: { [string]: number }): boolean
	for _, spec in option.objectives do
		if not Objectives.done(spec, option.id, progress) then
			return false
		end
	end
	return true
end

export type PredicateContext = {
	hour: number, -- world clock hour 0..23
	eventActive: boolean, -- the quest's situation event is still running
}

Objectives.predicates = {
	night = function(ctx: PredicateContext): boolean
		return ctx.hour >= 21 or ctx.hour < 5
	end,
	eventEnded = function(ctx: PredicateContext): boolean
		return not ctx.eventActive
	end,
} :: { [string]: (PredicateContext) -> boolean }

return Objectives
