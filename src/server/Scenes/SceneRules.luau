--!strict
--[[
	SceneRules: the pure decisions of Services/SceneDirector, so Tests/LivingWorld.spec can run them.

		timeFits(template, hour, weekday) -> boolean
		pickTemplate(hour, weekday, rng, only?) -> template?
		outcomeWhenAlone(template, rng) -> id          nobody stepped in
		tellStory(text, names) -> string
		validate() -> { problem }                      every template, checked against the real data
]]

local Activities = require(script.Parent.Parent.NPC.Data.Activities)
local Creatures = require(script.Parent.Parent.Creatures.Data.Creatures)
local MemoryService = require(script.Parent.Parent.NPC.MemoryService)
local NpcData = require(script.Parent.Parent.NPC.Data.NpcData)
local Templates = require(script.Parent.Data.SceneTemplates)

local SceneRules = {}

function SceneRules.timeFits(template: Templates.Template, hour: number, weekday: number): boolean
	if template.weekday and template.weekday ~= weekday then
		return false
	end
	local from, to = template.hours[1], template.hours[2]
	if from <= to then
		return hour >= from and hour < to
	end
	return hour >= from or hour < to
end

function SceneRules.pickTemplate(hour: number, weekday: number, rng: Random): Templates.Template?
	local total = 0
	local fits: { Templates.Template } = {}
	for _, template in Templates do
		if SceneRules.timeFits(template, hour, weekday) then
			table.insert(fits, template)
			total += template.weight
		end
	end
	local roll = rng:NextNumber() * total
	for _, template in fits do
		roll -= template.weight
		if roll <= 0 then
			return template
		end
	end
	return fits[#fits]
end

function SceneRules.outcomeWhenAlone(template: Templates.Template, rng: Random): string
	local ids: { string } = {}
	local total = 0
	for id, outcome in template.outcomes do
		if (outcome.weight or 0) > 0 then
			table.insert(ids, id)
			total += outcome.weight :: number
		end
	end
	table.sort(ids) -- `pairs` order isn't stable: the same seed must give the same ending
	local roll = rng:NextNumber() * total
	for _, id in ids do
		roll -= template.outcomes[id].weight :: number
		if roll <= 0 then
			return id
		end
	end
	return ids[#ids]
end

function SceneRules.tellStory(text: string, names: { [string]: string }): string
	return (string.gsub(text, "{(%a+)}", function(key: string): string
		return names[key] or "someone"
	end))
end

local MARKS = { center = true, left = true, right = true, front = true, back = true, far = true }

function SceneRules.validate(): { string }
	local problems: { string } = {}
	local function bad(template: Templates.Template, text: string)
		table.insert(problems, template.id .. ": " .. text)
	end
	local function checkSteps(template: Templates.Template, steps: { any })
		for _, step in steps do
			local kind = step[1]
			if kind == "go" then
				if not template.actors[step[2]] then
					bad(template, "go: no actor " .. tostring(step[2]))
				elseif not MARKS[step[3]] then
					bad(template, "go: no mark " .. tostring(step[3]))
				end
			elseif kind == "say" then
				if not template.actors[step[2]] then
					bad(template, "say: no actor " .. tostring(step[2]))
				end
			elseif kind == "clip" or kind == "hold" then
				if not template.actors[step[2]] then
					bad(template, kind .. ": no actor " .. tostring(step[2]))
				elseif not Activities.Clips[step[3]] then
					bad(template, kind .. ": no clip slot " .. tostring(step[3]))
				end
			elseif kind == "cast" then
				if not template.actors[step[2]] or not template.actors[step[3]] then
					bad(template, "cast: unknown actor")
				end
			elseif kind == "creatures" then
				if not Creatures.defs[step[2]] then
					bad(template, "no creature " .. tostring(step[2]))
				end
			elseif kind ~= "wait" then
				bad(template, "unknown step " .. tostring(kind))
			end
		end
	end
	for _, template in Templates do
		checkSteps(template, template.intro)
		for role, actor in template.actors do
			for _, id in (actor.occupations or {}) :: { string } do
				if not NpcData.occupations[id] then
					bad(template, role .. ": no occupation " .. id)
				end
			end
			if actor.spawn and not NpcData.occupations[actor.spawn] then
				bad(template, role .. ": can't spawn " .. actor.spawn)
			end
		end
		local chance = 0
		for id, outcome in template.outcomes do
			chance += outcome.weight or 0
			checkSteps(template, outcome.steps or {})
			if outcome.story == "" then
				bad(template, id .. ": no story")
			end
			if outcome.bond then
				if not template.actors[outcome.bond.role] then
					bad(template, id .. ": bond with no actor " .. outcome.bond.role)
				end
				local memory = outcome.bond.memory
				if memory and not MemoryService.KINDS[memory] then
					bad(template, id .. ": unknown memory " .. memory)
				end
			end
			for _, m in (outcome.remember or {}) :: { any } do
				if not template.actors[m.role] or not template.actors[m.about] then
					bad(template, id .. ": remember with an unknown actor")
				end
				if not MemoryService.KINDS[m.kind] then
					bad(template, id .. ": unknown memory " .. m.kind)
				end
			end
		end
		if chance <= 0 then
			bad(template, "no outcome can happen when nobody steps in")
		end
		for _, i in template.interventions do
			if not template.outcomes[i.outcome] then
				bad(template, "intervention leads to no outcome: " .. tostring(i.outcome))
			end
			if i.role and not template.actors[i.role] then
				bad(template, "intervention names no actor: " .. tostring(i.role))
			end
		end
	end
	return problems
end

return SceneRules
