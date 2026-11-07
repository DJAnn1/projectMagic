--!strict
--[[
	ReadabilityReport: is every activity fully visible? (docs/Activities.md §8)

	library()  checks the activity data alone: a station type or a spot, props that exist, an animation
	           (a filled clip slot or a procedural pose), a sound, and tooltip text.
	run(settlementId, npcs, pick)  simulates one day for every NPC in a settlement (the same 15-minute
	           steps as NPCService's npcday trace) and reports, for each activity that came up, whether
	           this town can show it: stations of its kind that have a use point, plus the library checks.
	           Brain actions with no activity yet are listed too, with their share of the town's day.

	VERDICT  FAIL  something visual is missing: no usable station, a missing prop, no animation or pose,
	               no tooltip text, or an action with no activity at all (someone just standing there)
	         WARN  only the sound is missing (audio is a later stage)
	         PASS  everything
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local ActivityLibrary = require(Shared.Life.Data.ActivityLibrary)
local ActivityPoses = require(Shared.Life.Data.ActivityPoses)
local HeldProps = require(Shared.Life.Data.HeldProps)
local StationTypes = require(Shared.Life.Data.StationTypes)
local AudioLibrary = require(Shared.Audio.AudioLibrary)

local Server = script.Parent.Parent
local NPCBrain = require(Server.NPC.NPCBrain)
local ScheduleService = require(Server.NPC.ScheduleService)
local WorldClock = require(Server.NPC.WorldClock)
local StationRegistry = require(script.Parent.StationRegistry)

type Activity = ActivityLibrary.Activity

local ReadabilityReport = {}

export type Check = { ok: boolean, text: string }

local function hasSound(role: string?): boolean
	return role ~= nil and AudioLibrary.get(role) ~= nil
end

-- The data checks for one activity: props, animation, sound, text (stations are per town).
function ReadabilityReport.checks(def: Activity): { [string]: Check }
	local out: { [string]: Check } = {}
	local missing: { string } = {}
	for _, id in { def.props.right, def.props.left } :: { string? } do
		if id and not HeldProps.get(id) then
			table.insert(missing, id)
		end
	end
	local propCount = (if def.props.right then 1 else 0) + (if def.props.left then 1 else 0)
	out.props = if #missing > 0 then { ok = false, text = "✗ unknown " .. table.concat(missing, ", ") }
		elseif propCount == 0 then { ok = true, text = "— none needed" }
		else { ok = true, text = "✓ " .. (if def.props.right and def.props.left then def.props.right .. " + " .. def.props.left else def.props.right or def.props.left or "") }
	local clip = def.clip and ActivityPoses.hasClip(def.clip)
	local pose = ActivityPoses.poses[def.pose] ~= nil
	out.animation = if clip then { ok = true, text = "✓ clip " .. tostring(def.clip) }
		elseif pose then { ok = true, text = "✓ pose " .. def.pose }
		else { ok = false, text = "✗ no clip or pose" }
	out.sound = if hasSound(def.sound) then { ok = true, text = "✓ " .. tostring(def.sound) } else { ok = false, text = "… none yet" }
	local needsItem = string.find(def.doing, "{item}", 1, true) ~= nil
	local textOk = def.seen ~= "" and def.doing ~= "" and (not needsItem or (def.items ~= nil and #def.items > 0)) and def.tell ~= ""
	out.tooltip = if textOk then { ok = true, text = "✓" } else { ok = false, text = "✗ missing seen/doing/items/tell" }
	if def.station then
		out.station = if StationTypes.types[def.station] then { ok = true, text = "✓ " .. def.station } else { ok = false, text = "✗ unknown type " .. def.station }
	else
		out.station = if def.spot then { ok = true, text = "— spot: " .. def.spot } else { ok = false, text = "✗ neither station nor spot" }
	end
	return out
end

local COLUMNS = { "station", "props", "animation", "sound", "tooltip" }

local function verdict(checks: { [string]: Check }): string
	for _, k in COLUMNS do
		if k ~= "sound" and not checks[k].ok then
			return "FAIL"
		end
	end
	return if checks.sound.ok then "PASS" else "WARN"
end

local function row(name: string, checks: { [string]: Check }, extra: string?): string
	local cells = {}
	for _, k in COLUMNS do
		table.insert(cells, k .. " " .. checks[k].text)
	end
	return string.format("[%s] %s%s  |  %s", verdict(checks), name, extra or "", table.concat(cells, "  |  "))
end

function ReadabilityReport.library(): { string }
	local lines = { string.format("%d activities in the library", #ActivityLibrary.list) }
	local pass, warn, fail = 0, 0, 0
	for _, def in ActivityLibrary.list do
		local checks = ReadabilityReport.checks(def)
		local v = verdict(checks)
		if v == "PASS" then
			pass += 1
		elseif v == "WARN" then
			warn += 1
		else
			fail += 1
		end
		table.insert(lines, row(def.id, checks))
	end
	table.insert(lines, 2, string.format("pass %d · warn %d (sound only) · fail %d", pass, warn, fail))
	return lines
end

-- Every NPC's day in 15-minute steps: { activity id or "action:<name>" -> quarter-hours }.
local function simulate(npcs: { any }, pick: (any, string, number) -> Activity?): ({ [string]: number }, { [string]: Activity }, number)
	local quarters: { [string]: number } = {}
	local defs: { [string]: Activity } = {}
	local total = 0
	local start = math.floor(WorldClock.now())
	for _, npc in npcs do
		if npc.compiled then
			local shadow = setmetatable({ needs = NPCBrain.freshNeeds(npc.seed), action = "sleep", actionUntil = 0 }, { __index = npc }) :: any
			for step = 0, 95 do
				local t = start + step / 96
				if step > 0 then
					NPCBrain.integrate(shadow, 0.25, shadow.action)
				end
				if t >= shadow.actionUntil then
					NPCBrain.decide(shadow, t, ScheduleService.blockAt(npc, WorldClock.hourOf(t), false), false)
				end
				local def = pick(shadow, shadow.action, start)
				local key = if def then def.id else "action:" .. tostring(shadow.action)
				if def then
					defs[key] = def
				end
				quarters[key] = (quarters[key] or 0) + 1
				total += 1
			end
		end
	end
	return quarters, defs, total
end

function ReadabilityReport.run(settlementId: string, npcs: { any }, pick: (any, string, number) -> Activity?): ({ string }, number, number, number)
	local quarters, defs, total = simulate(npcs, pick)
	local keys: { string } = {}
	for k in quarters do
		table.insert(keys, k)
	end
	table.sort(keys, function(a, b)
		return quarters[a] > quarters[b]
	end)
	local pass, warn, fail = 0, 0, 0
	local lines: { string } = {}
	for _, key in keys do
		local share = string.format(" (%d%% of the day)", math.floor(quarters[key] / math.max(total, 1) * 100 + 0.5))
		local def = defs[key]
		if def then
			local checks = ReadabilityReport.checks(def)
			if def.station then
				local function count(kind: string): (number, number)
					local usable, all = 0, 0
					for _, station in StationRegistry.inTown(settlementId, kind) do
						all += 1
						if StationRegistry.usable(station) then
							usable += 1
						end
					end
					return usable, all
				end
				local usable, all = count(def.station)
				if usable > 0 then
					checks.station = { ok = true, text = string.format("✓ %d/%d %s", usable, all, def.station) }
				elseif def.altStation and (count(def.altStation)) > 0 then
					local altUsable, altAll = count(def.altStation)
					checks.station = { ok = true, text = string.format("✓ no %s here: %d/%d %s instead", def.station, altUsable, altAll, def.altStation) }
				else
					checks.station = { ok = false, text = string.format("✗ 0/%d %s with a use point", all, def.station) }
				end
			end
			local v = verdict(checks)
			if v == "PASS" then
				pass += 1
			elseif v == "WARN" then
				warn += 1
			else
				fail += 1
			end
			table.insert(lines, row(def.id, checks, share))
		else
			fail += 1
			table.insert(lines, string.format("[FAIL] %s%s  |  no activity in the library yet: shown as plain standing", string.sub(key, 8), share))
		end
	end
	table.insert(lines, 1, string.format("Readability Report: %s, %d NPCs, one simulated day · pass %d · warn %d (sound only) · fail %d", settlementId, #npcs, pass, warn, fail))
	return lines, pass, warn, fail
end

return ReadabilityReport
