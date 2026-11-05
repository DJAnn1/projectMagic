--!strict
--[[
	Logger
	Structured logging: every entry is (level, scope, event, fields), not a free-form string.
	That keeps logs greppable and lets the admin console filter them.

		local log = Logger.new("DataService")
		log:info("load_ok", { key = key, ms = 120 })
		log:throttled("budget", 30, "Warn", "budget_low", { left = 3 })  -- at most once per 30 s

	Output: "[INFO][DataService] load_ok key=player_1 ms=120"
	The last RING_SIZE entries are kept in memory for the admin console (`log` command).
	Never log personal data (chat text, display names in bulk); log UserIds instead.
]]

local Logger = {}

Logger.Level = table.freeze({ Debug = 1, Info = 2, Warn = 3, Error = 4 })
local LEVEL_NAMES = { "DEBUG", "INFO", "WARN", "ERROR" }
local RING_SIZE = 500
local MAX_VALUE_LENGTH = 300

export type Entry = {
	time: number, -- os.clock()
	level: number,
	scope: string,
	event: string,
	fields: { [string]: any }?,
}

local minLevel = Logger.Level.Info
local ring: { Entry } = {}
local ringNext = 1
local counts = { 0, 0, 0, 0 }
local sinks: { (Entry) -> () } = {}
local throttles: { [string]: number } = {}

local function formatValue(value: any): string
	local text = if typeof(value) == "string" then value else tostring(value)
	if #text > MAX_VALUE_LENGTH then
		text = string.sub(text, 1, MAX_VALUE_LENGTH) .. "…"
	end
	if string.find(text, "%s") then
		text = string.format("%q", text)
	end
	return text
end

function Logger.format(entry: Entry): string
	local parts = { string.format("[%s][%s] %s", LEVEL_NAMES[entry.level], entry.scope, entry.event) }
	if entry.fields then
		local keys: { string } = {}
		for key in entry.fields do
			table.insert(keys, key)
		end
		table.sort(keys)
		for _, key in keys do
			table.insert(parts, key .. "=" .. formatValue(entry.fields[key]))
		end
	end
	return table.concat(parts, " ")
end

local function emit(level: number, scope: string, event: string, fields: { [string]: any }?)
	counts[level] += 1
	if level < minLevel then
		return
	end
	local entry: Entry = { time = os.clock(), level = level, scope = scope, event = event, fields = fields }
	ring[ringNext] = entry
	ringNext = ringNext % RING_SIZE + 1

	local line = Logger.format(entry)
	if level >= Logger.Level.Warn then
		warn(line)
	else
		print(line)
	end
	for _, sink in sinks do
		task.spawn(sink, entry)
	end
end

-- Accepts a level name ("Info") or number.
function Logger.setLevel(level: string | number)
	local value = if typeof(level) == "number" then level else (Logger.Level :: any)[level]
	if typeof(value) == "number" then
		minLevel = value
	end
end

-- Extra destinations (e.g. AnalyticsService for errors). Sinks must be cheap and must not log.
function Logger.addSink(sink: (Entry) -> ())
	table.insert(sinks, sink)
end

-- Most recent entries, oldest first.
function Logger.recent(count: number): { Entry }
	local out: { Entry } = {}
	for i = 0, RING_SIZE - 1 do
		local entry = ring[(ringNext + i - 1) % RING_SIZE + 1]
		if entry then
			table.insert(out, entry)
		end
	end
	if #out > count then
		return { table.unpack(out, #out - count + 1, #out) }
	end
	return out
end

-- Totals per level since boot, including entries below the current level.
function Logger.counts(): { [string]: number }
	return { debug = counts[1], info = counts[2], warn = counts[3], error = counts[4] }
end

local Scoped = {}
Scoped.__index = Scoped
type ScopedData = { scope: string }
export type ScopedLogger = typeof(setmetatable({} :: ScopedData, Scoped))

function Logger.new(scope: string): ScopedLogger
	return setmetatable({ scope = scope }, Scoped)
end

function Scoped.debug(self: ScopedLogger, event: string, fields: { [string]: any }?)
	emit(Logger.Level.Debug, self.scope, event, fields)
end

function Scoped.info(self: ScopedLogger, event: string, fields: { [string]: any }?)
	emit(Logger.Level.Info, self.scope, event, fields)
end

function Scoped.warn(self: ScopedLogger, event: string, fields: { [string]: any }?)
	emit(Logger.Level.Warn, self.scope, event, fields)
end

function Scoped.error(self: ScopedLogger, event: string, fields: { [string]: any }?)
	emit(Logger.Level.Error, self.scope, event, fields)
end

-- Logs at most once per `seconds` for the given key; use in hot paths and for abuse reports.
function Scoped.throttled(self: ScopedLogger, key: string, seconds: number, level: string, event: string, fields: { [string]: any }?)
	local fullKey = self.scope .. ":" .. key
	local now = os.clock()
	local last = throttles[fullKey]
	if last and now - last < seconds then
		return
	end
	throttles[fullKey] = now
	emit((Logger.Level :: any)[level] or Logger.Level.Info, self.scope, event, fields)
end

return Logger
