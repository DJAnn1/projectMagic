--!strict
--[[
	ScheduleService: where and when. Pure functions; NPCService owns the state.

	DISTRICTS. Every settlement gets the same district kinds laid out around its centre, rotated
	by the settlement's seed (no prefabs yet; when buildings exist, swap `districtPoint` for
	tagged building doors). Distances scale with the settlement's POI radius.

	DAY PLAN. An occupation's template (Data/NeedsActions.schedules), adapted per person:
		quirk scheduleShift      night owls +3 h, early risers -2 h, ...
		conscientiousness        > 0.75: work starts an hour earlier; < 0.25: an hour later
		retired former workers   keep a little of their old trade in the free blocks
		interruptions            a dangerous world event overrides every block with "danger"
		                         (NPCBrain treats that as shelter-or-help time)
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)
local NeedsActions = require(script.Parent.Data.NeedsActions)
local NpcData = require(script.Parent.Data.NpcData)
local Quirks = require(script.Parent.Data.Quirks)

local ScheduleService = {}

-- district -> { distance (x radius), angle (radians), spread (studs of per-person jitter) }
local LAYOUT: { [string]: { d: number, a: number, spread: number } } = {
	market = { d = 0, a = 0, spread = 14 },
	street = { d = 0.25, a = 0.6, spread = 30 },
	tavern = { d = 0.28, a = 0.2, spread = 8 },
	temple = { d = 0.42, a = 1.05, spread = 10 },
	library = { d = 0.32, a = 5.2, spread = 8 },
	school = { d = 0.3, a = 5.75, spread = 10 },
	clinic = { d = 0.36, a = 4.7, spread = 8 },
	forge = { d = 0.5, a = 2.1, spread = 10 },
	guardpost = { d = 0.7, a = 0, spread = 12 },
	training = { d = 0.6, a = 4.2, spread = 14 },
	harbor = { d = 0.95, a = 1.6, spread = 16 },
	farm = { d = 1.15, a = 3.6, spread = 30 },
	mine = { d = 1.25, a = 2.6, spread = 12 },
	wilds = { d = 1.6, a = 0, spread = 60 },
}

export type Place = { x: number, z: number, radius: number, seed: number }

-- Every district id, sorted (overlays and admin tools).
ScheduleService.districts = (function()
	local ids = {}
	for id in LAYOUT do
		table.insert(ids, id)
	end
	table.sort(ids)
	return ids
end)()

-- A district's anchor point in a settlement (x, z).
function ScheduleService.districtPoint(place: Place, district: string): (number, number)
	local layout = LAYOUT[district] or LAYOUT.market
	local turn = (place.seed % 6283) / 1000 -- the settlement's rotation, 0..2π
	local angle = layout.a + turn
	local r = layout.d * math.max(place.radius, 40)
	return place.x + math.cos(angle) * r, place.z + math.sin(angle) * r
end

-- A person's own spot in a district (their bench at the forge, their pew, their house).
function ScheduleService.spot(place: Place, district: string, npcSeed: number, household: string?): (number, number)
	if district == "home" then
		-- Homes ring the centre; a household shares one home.
		local h = Seed.derive(place.seed, household or tostring(npcSeed), "home")
		local angle = (h % 6283) / 1000
		local r = (0.45 + (h % 1000) / 4000) * math.max(place.radius, 40)
		return place.x + math.cos(angle) * r, place.z + math.sin(angle) * r
	end
	local x, z = ScheduleService.districtPoint(place, district)
	local layout = LAYOUT[district] or LAYOUT.market
	local h = Seed.derive(place.seed, tostring(npcSeed), district)
	local angle = (h % 6283) / 1000
	local dist = ((h // 6283) % 1000) / 1000 * layout.spread
	return x + math.cos(angle) * dist, z + math.sin(angle) * dist
end

-- Hours this NPC's day is shifted (quirks + conscientiousness).
function ScheduleService.shift(npc: any): number
	local shift = 0
	for _, q in npc.quirks do
		shift += Quirks.defs[q].effects.scheduleShift or 0
	end
	local c = npc.traits.conscientiousness or 0.5
	if c > 0.75 then
		shift -= 1
	elseif c < 0.25 then
		shift += 1
	end
	return shift
end

-- The block for an hour of the day (0..23.99), with interruptions.
function ScheduleService.blockAt(npc: any, hour: number, danger: boolean): string
	if danger then
		return "danger"
	end
	local template = NeedsActions.schedules[NpcData.occupations[npc.occupation].schedule] or NeedsActions.schedules.day
	local h = math.floor(hour - (npc.scheduleShift or 0)) % 24
	return template[h + 1]
end

-- Where an action takes this NPC: "work" resolves to the occupation's district; social NPCs eat
-- at the tavern, quiet ones at home; wanderers pick a spot in the wilds.
function ScheduleService.districtFor(npc: any, action: string, actionDistrict: string): string
	if actionDistrict == "work" then
		return NpcData.occupations[npc.occupation].district
	elseif action == "eat" and (npc.traits.extraversion or 0.5) > 0.65 then
		return "tavern"
	elseif action == "socialize" and npc.ageBand == "child" then
		return "market"
	elseif action == "practice" and npc.magic and npc.magic.school then
		return "school"
	end
	return actionDistrict
end

return ScheduleService
