--!strict
--[[
	WorldClock: the game calendar every NPC lives by. Derived from server time (which all servers
	share) and the world epoch, so every server agrees on the hour without talking.

		WorldClock.setup(epoch, daySeconds)   called once by NPCService
		WorldClock.now() -> number            game days since the epoch (fractional)
		WorldClock.day() / hour() / minute() / weekday()   weekday 0 = Sunday
		WorldClock.stamp() -> string          "Tuesday 14:05, day 31"

	One game day = `npc_day_seconds` real seconds (default 1440 = 24 minutes), so a player sees
	whole days of NPC life in a session. NPC magic progresses by game day too (NPCMagicLife).

	TEST CONTROLS (admin panel; THIS server only, so it drifts from other servers until restart):
		setScale(s)        game time runs s x as fast (0 = paused); continuous, no jump
		advance(days)      jumps forward
		setHour(h)         jumps forward to the next h:00
		setDaySeconds(n)   a new day length without jumping the calendar
	The clock is piecewise linear: now = anchorDays + (serverTime - anchorTime) x scale / daySeconds.
]]

local WorldClock = {}

local WEEKDAYS = { "Sunday", "Monday", "Tuesday", "Wednesday", "Thursday", "Friday", "Saturday" }
WorldClock.weekdays = WEEKDAYS

local daySeconds = 1440
local scale = 1
local anchorTime = 0
local anchorDays = 0
local altered = false

local function serverTime(): number
	return workspace:GetServerTimeNow()
end

function WorldClock.setup(worldEpoch: number, secondsPerDay: number)
	daySeconds = math.max(60, secondsPerDay)
	scale = 1
	anchorTime = serverTime()
	anchorDays = (anchorTime - worldEpoch) / daySeconds
	altered = false
end

function WorldClock.daySeconds(): number
	return daySeconds
end

-- Game days since the epoch, fractional.
function WorldClock.now(): number
	return anchorDays + (serverTime() - anchorTime) * scale / daySeconds
end

local function reanchor()
	anchorDays = WorldClock.now()
	anchorTime = serverTime()
end

function WorldClock.scale(): number
	return scale
end

function WorldClock.setScale(s: number)
	reanchor()
	scale = math.clamp(s, 0, 1000)
	altered = true
end

function WorldClock.advance(days: number)
	reanchor()
	anchorDays += math.max(0, days)
	altered = true
end

-- Jumps forward (never back: NPC timers assume time only moves forward) to the next h:00.
function WorldClock.setHour(h: number)
	reanchor()
	local today = math.floor(anchorDays)
	local target = today + math.clamp(h, 0, 23.99) / 24
	if target < anchorDays then
		target += 1
	end
	anchorDays = target
	altered = true
end

function WorldClock.setDaySeconds(seconds: number)
	reanchor()
	daySeconds = math.max(60, seconds)
end

-- True once a test control has moved this server's clock away from the shared calendar.
function WorldClock.isAltered(): boolean
	return altered
end

function WorldClock.day(): number
	return math.floor(WorldClock.now())
end

function WorldClock.hourOf(t: number): number
	return (t - math.floor(t)) * 24
end

function WorldClock.hour(): number
	return WorldClock.hourOf(WorldClock.now())
end

function WorldClock.weekdayOf(day: number): number
	return day % 7
end

function WorldClock.weekday(): number
	return WorldClock.weekdayOf(WorldClock.day())
end

-- Real seconds per game hour (math.huge while paused).
function WorldClock.secondsPerHour(): number
	return if scale > 0 then daySeconds / 24 / scale else math.huge
end

function WorldClock.stamp(t: number?): string
	local now = t or WorldClock.now()
	local day = math.floor(now)
	local hour = WorldClock.hourOf(now)
	return string.format("%s %02d:%02d, day %d", WEEKDAYS[WorldClock.weekdayOf(day) + 1], math.floor(hour), math.floor((hour % 1) * 60), day)
end

return WorldClock
