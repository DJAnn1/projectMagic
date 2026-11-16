--!strict
--[[
	AgendaRules: the world's own business, day by day (docs/LivingHistory.md §5 and §8). Pure: no
	services, no Instances, so every server computes the same history from the world seed alone.

		AgendaRules.plan(seed, day, towns, haunts) -> { Agenda }   that game day's agendas (at most perDay)
		AgendaRules.fallen(seed, now, towns, haunts) -> { [townId]: Fall }
		    towns fallen to an unattended siege and not yet back (now is game days, fractional)
		AgendaRules.nearestHaunt(town, haunts) -> (Haunt?, distance)

	An Agenda: { id, day, kind, town, other?, theme?, at (game days), hours, outcome, retake? }
		siege     outcome "held" | "fell"; theme from the nearest haunt; retake = game day it frees itself
		raid      outcome "burned" | "driven_off"; `other` raids `town`
		alliance  outcome "sworn"; `other` is the friend
		trade     outcome "boom" | "bust"
]]

local Data = require(script.Parent.Data.Agendas)
local Seed = require(game:GetService("ReplicatedStorage").Shared.Magic.Seed)

local T = Data.tuning

export type Town = { id: string, x: number, z: number, radius: number, relations: { [string]: number } }
export type Haunt = { theme: string, x: number, z: number }
export type Agenda = {
	id: string,
	day: number,
	kind: string,
	town: string,
	other: string?,
	theme: string?,
	at: number,
	hours: number,
	outcome: string,
	retake: number?,
}
export type Fall = { agenda: string, theme: string, at: number, retake: number }

local AgendaRules = {}

AgendaRules.Tuning = T
AgendaRules.KINDS = { "siege", "raid", "alliance", "trade" }

-- Deterministic for (seed, day, salt): the same draws on every server.
local function rngFor(seed: number, day: number, salt: string): Random
	return Seed.random(seed, "agenda:" .. day, salt)
end

local function sortedTowns(towns: { Town }): { Town }
	local list = table.clone(towns)
	table.sort(list, function(a, b)
		return a.id < b.id
	end)
	return list
end

function AgendaRules.nearestHaunt(town: Town, haunts: { Haunt }): (Haunt?, number)
	local best, bestD = nil, math.huge
	for _, haunt in haunts do
		local d = math.sqrt((haunt.x - town.x) ^ 2 + (haunt.z - town.z) ^ 2)
		if d < bestD or (d == bestD and best and haunt.theme < best.theme) then
			best, bestD = haunt, d
		end
	end
	return best, bestD
end

local function startAt(rng: Random, day: number, kind: string): number
	local window = T.hours[kind] or { 9, 17 }
	return day + (window[1] + rng:NextNumber() * (window[2] - window[1])) / 24
end

function AgendaRules.plan(seed: number, day: number, towns: { Town }, haunts: { Haunt }): { Agenda }
	local list = sortedTowns(towns)
	local out: { Agenda } = {}
	local used: { [string]: boolean } = {}
	local function pick(rng: Random, candidates: { any }): any?
		if #candidates == 0 then
			return nil
		end
		return candidates[rng:NextInteger(1, #candidates)]
	end
	for _, kind in AgendaRules.KINDS do
		if #out >= T.perDay then
			break
		end
		local rng = rngFor(seed, day, kind)
		if rng:NextNumber() < (T.chance[kind] or 0) then
			local agenda: Agenda? = nil
			if kind == "siege" then
				local candidates = {}
				for _, town in list do
					local haunt, d = AgendaRules.nearestHaunt(town, haunts)
					if haunt and d <= T.siegeHaunt and not used[town.id] then
						table.insert(candidates, { town = town, theme = haunt.theme })
					end
				end
				local chosen = pick(rng, candidates)
				if chosen then
					local fell = rng:NextNumber() < T.siegeFalls
					agenda = {
						id = string.format("siege_%d_%s", day, chosen.town.id), day = day, kind = kind, town = chosen.town.id,
						theme = chosen.theme, at = startAt(rng, day, kind), hours = T.lasts.siege,
						outcome = if fell then "fell" else "held",
						retake = if fell then day + rng:NextInteger(T.retakeDays[1], T.retakeDays[2]) else nil,
					}
				end
			elseif kind == "raid" or kind == "alliance" then
				local candidates = {}
				for i, a in list do
					for j = i + 1, #list do
						local b = list[j]
						local relation = a.relations[b.id] or b.relations[a.id] or 0
						local d = math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
						local fits = if kind == "raid" then relation <= T.feud and d <= T.raidReach else relation >= T.friends
						if fits and not used[a.id] and not used[b.id] then
							table.insert(candidates, { a = a, b = b })
						end
					end
				end
				local chosen = pick(rng, candidates)
				if chosen then
					local target, from = chosen.a, chosen.b
					if rng:NextNumber() < 0.5 then
						target, from = chosen.b, chosen.a
					end
					local outcome = if kind == "alliance" then "sworn" elseif rng:NextNumber() < T.raidBurns then "burned" else "driven_off"
					agenda = {
						id = string.format("%s_%d_%s", kind, day, target.id), day = day, kind = kind, town = target.id,
						other = from.id, at = startAt(rng, day, kind), hours = T.lasts[kind], outcome = outcome,
					}
					used[from.id] = true
				end
			else
				local candidates = {}
				for _, town in list do
					if not used[town.id] then
						table.insert(candidates, town)
					end
				end
				local town = pick(rng, candidates)
				if town then
					agenda = {
						id = string.format("trade_%d_%s", day, town.id), day = day, kind = kind, town = town.id,
						at = startAt(rng, day, kind), hours = T.lasts.trade, outcome = if rng:NextNumber() < 0.5 then "boom" else "bust",
					}
				end
			end
			if agenda then
				used[agenda.town] = true
				table.insert(out, agenda)
			end
		end
	end
	return out
end

-- Towns that fell to an unattended siege in the last lookBack days and haven't freed themselves yet.
function AgendaRules.fallen(seed: number, now: number, towns: { Town }, haunts: { Haunt }): { [string]: Fall }
	local out: { [string]: Fall } = {}
	local today = math.floor(now)
	for day = today - T.lookBack, today do
		for _, agenda in AgendaRules.plan(seed, day, towns, haunts) do
			local done = agenda.at + agenda.hours / 24
			if agenda.kind == "siege" and agenda.outcome == "fell" and now >= done and agenda.retake and now < agenda.retake then
				out[agenda.town] = { agenda = agenda.id, theme = agenda.theme :: string, at = done, retake = agenda.retake }
			end
		end
	end
	return out
end

return AgendaRules
