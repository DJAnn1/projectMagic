--!strict
--[[
	DataService: all persistence goes through here.

	Two kinds of store:

	SessionStore (players): one server owns a key at a time.
		local store = DataService:openSessionStore(Schemas.Player)
		local session, err = store:load("player_123", { userIds = { 123 } })
		session.data.stats.joins += 1        -- mutate freely; autosave persists it
		session.released:Connect(function(reason) ... end)  -- "RELEASED" | "LOCK_LOST" | ...
		session:release()                    -- final save + unlock (on leave)

	Store (world, NPCs): no lock; optimistic read-modify-write through UpdateAsync.
		local store = DataService:openStore(Schemas.World)
		store:update("world_main", function(world) world.flags.x = true; return world end)
		Transforms may run several times (on write conflicts), so they must be pure.

	Session locking
	- The record carries meta.lock = { jobId, placeId, at }. load() takes the lock only if it's
	  free, ours, or stale (not refreshed for LOCK_STALE_SECONDS, i.e. the owner crashed).
	- Every save refreshes `at` and first checks the lock is still ours. If another server
	  stole a stale lock, our save is refused and the session ends with "LOCK_LOST".
	  Two servers can never both write the same player's data.
	- Records written by a newer schema version are never loaded (prevents downgrades during
	  rolling updates); the player is asked to rejoin.

	Shutdown: BindToClose releases every session in parallel, within Roblox's 30 s window.
	Studio: with flag `data_use_mock_in_studio` (default on), an in-memory store is used instead.
]]

local DataStoreService = game:GetService("DataStoreService")
local HttpService = game:GetService("HttpService")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Signal = require(Shared.Core.Signal)
local Persistence = script.Parent.Parent.Persistence
local Retry = require(Persistence.Retry)
local Codec = require(Persistence.Codec)
local MockDataStore = require(Persistence.MockDataStore)
local Schemas = require(Persistence.Schemas)

type StoreConfig = Schemas.StoreConfig

local LOCK_STALE_SECONDS = 180 -- 3x the default autosave interval
local LOCK_ATTEMPTS = 6
local LOCK_RETRY_SECONDS = 5
local MAX_RECORD_CHARS = 3_900_000 -- DataStore limit is 4,194,304; keep headroom
local SHUTDOWN_BUDGET_SECONDS = 25

local DataService = {
	name = "DataService",
	dependencies = {},
}

local log: any = nil
local flags: any = nil
local useMock = false
local closing = false
local activeSessions: { [any]: boolean } = {}

-- ─── Record helpers ─────────────────────────────────────────────────────────

local function deepCopy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

-- Fill keys missing from `target` with copies from `template`, recursing into nested
-- dictionaries. Never overwrites existing values.
local function reconcile(target: any, template: any)
	for key, value in template do
		if target[key] == nil then
			target[key] = deepCopy(value)
		elseif typeof(value) == "table" and typeof(target[key]) == "table" and next(value) ~= nil and value[1] == nil then
			reconcile(target[key], value)
		end
	end
end

local function getDataStore(config: StoreConfig): any
	if useMock then
		return MockDataStore.get(config.name .. "/" .. (config.scope or "global"))
	end
	return DataStoreService:GetDataStore(config.name, config.scope)
end

local function newRecord(config: StoreConfig): any
	return {
		schema = config.version,
		meta = { createdAt = os.time(), updatedAt = 0, saves = 0 },
		data = config.template(),
	}
end

local function encodeData(config: StoreConfig, data: any): any
	local out = table.clone(data)
	local allow = flags.get("data_compression") ~= false
	for _, field in config.compress or {} do
		if out[field] ~= nil then
			out[field] = Codec.encode(out[field], allow)
		end
	end
	return out
end

-- Decodes compressed fields, runs migrations and reconciles with the template.
-- Returns (data, nil) or (nil, reason). Never mutates the stored record.
local function readData(config: StoreConfig, record: any): (any, string?)
	local version = record.schema or 1
	if version > config.version then
		return nil, "NEWER_SCHEMA"
	end
	local ok, result = pcall(function()
		local data = deepCopy(record.data or {})
		for field, value in data do
			if Codec.isEncoded(value) then
				data[field] = Codec.decode(value)
			end
		end
		local v = version
		while v < config.version do
			local migrate = config.migrations[v]
			assert(migrate, "missing migration from v" .. v)
			data = migrate(data)
			v += 1
		end
		reconcile(data, config.template())
		return data
	end)
	if not ok then
		log:error("read_failed", { store = config.name, err = result })
		return nil, "CORRUPT_OR_MIGRATION_FAILED"
	end
	return result, nil
end

-- Encoded data ready to write, or nil if it fails validation, isn't serializable, or is too big.
local function prepareWrite(config: StoreConfig, data: any): any?
	if config.validate then
		local ok, why = config.validate(data)
		if not ok then
			log:error("validate_failed", { store = config.name, reason = why })
			return nil
		end
	end
	local okEncode, encoded = pcall(encodeData, config, data)
	if not okEncode then
		log:error("encode_failed", { store = config.name, err = encoded })
		return nil
	end
	local okJson, json = pcall(HttpService.JSONEncode, HttpService, encoded)
	if not okJson then
		log:error("not_serializable", { store = config.name, err = json })
		return nil
	end
	if #json > MAX_RECORD_CHARS then
		log:error("record_too_large", { store = config.name, chars = #json })
		return nil
	end
	return encoded
end

-- ─── Session ────────────────────────────────────────────────────────────────

local Session = {}
Session.__index = Session

type SessionData = {
	key: string,
	data: any,
	released: Signal.Signal,
	_store: any,
	_userIds: { number }?,
	_active: boolean,
	_saving: boolean,
}
export type Session = typeof(setmetatable({} :: SessionData, Session))

local function endSession(self: Session, reason: string)
	if not self._active then
		return
	end
	self._active = false
	activeSessions[self] = nil
	self._store._loaded[self.key] = nil
	log:info("session_ended", { key = self.key, reason = reason })
	self.released:Fire(reason)
end

function Session.isActive(self: Session): boolean
	return self._active
end

-- Writes the data and refreshes the lock (or clears it when `releasing`). Yields.
-- Returns true on success. A lost lock ends the session.
function Session.save(self: Session, releasing: boolean?): boolean
	while self._saving do
		task.wait()
	end
	if not self._active then
		return false
	end
	self._saving = true

	local config: StoreConfig = self._store.config
	local encoded = prepareWrite(config, self.data)
	local lost = false
	local ok = false
	if encoded ~= nil then
		ok = Retry.call(function()
			return self._store._ds:UpdateAsync(self.key, function(record)
				lost = false
				local lock = record and record.meta and record.meta.lock
				if not lock or lock.jobId ~= game.JobId then
					lost = true
					return nil
				end
				local now = os.time()
				record.schema = config.version
				record.data = encoded
				record.meta.updatedAt = now
				record.meta.saves = (record.meta.saves or 0) + 1
				record.meta.lock = if releasing then nil else { jobId = game.JobId, placeId = game.PlaceId, at = now }
				return record, self._userIds
			end)
		end, { label = "save " .. self.key, budget = Enum.DataStoreRequestType.UpdateAsync, attempts = if closing then 3 else 5 })
	end
	self._saving = false

	if lost then
		log:error("lock_lost", { key = self.key })
		endSession(self, "LOCK_LOST")
		return false
	end
	if not ok then
		return false
	end
	if releasing then
		endSession(self, "RELEASED")
	end
	return true
end

-- Final save + unlock. Safe to call more than once. If the save fails, the lock simply goes
-- stale and the next server takes over after LOCK_STALE_SECONDS.
function Session.release(self: Session)
	if not self._active then
		return
	end
	if not self:save(true) and self._active then
		endSession(self, "RELEASE_FAILED")
	end
end

-- ─── SessionStore ───────────────────────────────────────────────────────────

local SessionStore = {}
SessionStore.__index = SessionStore

type SessionStoreData = { config: StoreConfig, _ds: any, _loaded: { [string]: Session } }
export type SessionStore = typeof(setmetatable({} :: SessionStoreData, SessionStore))

function DataService.openSessionStore(_self: any, config: StoreConfig): SessionStore
	return setmetatable({ config = config, _ds = getDataStore(config), _loaded = {} }, SessionStore)
end

-- Yields until the lock is acquired or LOCK_ATTEMPTS run out. Returns (session, nil) or (nil, reason).
-- Reasons: SHUTTING_DOWN, ALREADY_LOADED, DATASTORE_ERROR, NEWER_SCHEMA, SESSION_LOCKED,
-- CORRUPT_OR_MIGRATION_FAILED.
function SessionStore.load(self: SessionStore, key: string, options: { userIds: { number }? }?): (Session?, string?)
	if closing then
		return nil, "SHUTTING_DOWN"
	end
	if self._loaded[key] then
		return nil, "ALREADY_LOADED"
	end
	local userIds = options and options.userIds
	local config = self.config

	for attempt = 1, LOCK_ATTEMPTS do
		local acquired, newer = false, false
		local lockedBy: any = nil
		local snapshot: any = nil

		local ok = Retry.call(function()
			return self._ds:UpdateAsync(key, function(record)
				acquired, newer, lockedBy, snapshot = false, false, nil, nil
				record = record or newRecord(config)
				record.meta = record.meta or {}
				if (record.schema or 1) > config.version then
					newer = true
					return nil
				end
				local lock = record.meta.lock
				local now = os.time()
				if lock and lock.jobId ~= game.JobId and now - (lock.at or 0) < LOCK_STALE_SECONDS then
					lockedBy = lock
					return nil
				end
				record.meta.lock = { jobId = game.JobId, placeId = game.PlaceId, at = now }
				acquired = true
				snapshot = record
				return record, userIds
			end)
		end, { label = "load " .. key, budget = Enum.DataStoreRequestType.UpdateAsync })

		if not ok then
			return nil, "DATASTORE_ERROR"
		end
		if newer then
			return nil, "NEWER_SCHEMA"
		end
		if acquired and snapshot then
			local data, why = readData(config, snapshot)
			if not data then
				-- We hold the lock but can't use the data: unlock without touching the record.
				Retry.call(function()
					return self._ds:UpdateAsync(key, function(record)
						if record and record.meta and record.meta.lock and record.meta.lock.jobId == game.JobId then
							record.meta.lock = nil
							return record, userIds
						end
						return nil
					end)
				end, { label = "unlock " .. key, attempts = 3 })
				return nil, why
			end
			local session: Session = setmetatable({
				key = key,
				data = data,
				released = Signal.new(),
				_store = self,
				_userIds = userIds,
				_active = true,
				_saving = false,
			}, Session)
			self._loaded[key] = session
			activeSessions[session] = true
			log:info("session_loaded", { key = key, attempt = attempt })
			return session, nil
		end

		log:info("locked_elsewhere", {
			key = key,
			attempt = attempt,
			ownerAge = lockedBy and (os.time() - (lockedBy.at or 0)) or -1,
		})
		if attempt < LOCK_ATTEMPTS and not closing then
			task.wait(LOCK_RETRY_SECONDS)
		end
	end
	return nil, "SESSION_LOCKED"
end

function SessionStore.get(self: SessionStore, key: string): Session?
	return self._loaded[key]
end

-- ─── Store (no lock) ────────────────────────────────────────────────────────

local Store = {}
Store.__index = Store

type StoreData = { config: StoreConfig, _ds: any }
export type Store = typeof(setmetatable({} :: StoreData, Store))

function DataService.openStore(_self: any, config: StoreConfig): Store
	return setmetatable({ config = config, _ds = getDataStore(config) }, Store)
end

-- Returns (data, nil); (template, nil) when the key doesn't exist; (nil, reason) on failure.
function Store.read(self: Store, key: string): (any, string?)
	local ok, record = Retry.call(function()
		return self._ds:GetAsync(key)
	end, { label = "read " .. key, budget = Enum.DataStoreRequestType.GetAsync })
	if not ok then
		return nil, "DATASTORE_ERROR"
	end
	return readData(self.config, record or newRecord(self.config))
end

--[[
	Read-modify-write. `transform(data)` returns the new data, or nil to cancel.
	It may run more than once, so it must be pure. Returns (newData, nil) or (nil, reason).
]]
function Store.update(self: Store, key: string, transform: (any) -> any?, options: { userIds: { number }? }?): (any, string?)
	local config = self.config
	local result: any = nil
	local failure: string? = nil
	local ok = Retry.call(function()
		return self._ds:UpdateAsync(key, function(record)
			result, failure = nil, nil
			record = record or newRecord(config)
			local data, why = readData(config, record)
			if not data then
				failure = why
				return nil
			end
			local nextData = transform(data)
			if nextData == nil then
				failure = "CANCELLED"
				return nil
			end
			local encoded = prepareWrite(config, nextData)
			if encoded == nil then
				failure = "INVALID"
				return nil
			end
			record.schema = config.version
			record.data = encoded
			record.meta = record.meta or {}
			record.meta.updatedAt = os.time()
			record.meta.saves = (record.meta.saves or 0) + 1
			result = nextData
			return record, options and options.userIds
		end)
	end, { label = "update " .. key, budget = Enum.DataStoreRequestType.UpdateAsync })
	if not ok then
		return nil, "DATASTORE_ERROR"
	end
	return result, failure
end

-- Permanent deletion (right-to-erasure requests). Yields.
function Store.erase(self: Store, key: string): boolean
	local ok = Retry.call(function()
		return self._ds:RemoveAsync(key)
	end, { label = "erase " .. key })
	return ok
end

-- ─── Service lifecycle ──────────────────────────────────────────────────────

function DataService.isMock(_self: any): boolean
	return useMock
end

function DataService.activeSessionCount(_self: any): number
	local count = 0
	for _ in activeSessions do
		count += 1
	end
	return count
end

--[[
	Deletes everything stored for a user, for right-to-erasure requests. Add a call for every
	store keyed by this user. The player must not be in this server; kick them first.
]]
function DataService.eraseUser(self: any, userId: number): boolean
	local players = self:openStore(Schemas.Player)
	local ok = players:erase("player_" .. userId)
	log:warn("user_erased", { userId = userId, ok = ok })
	return ok
end

function DataService.init(_self: any, ctx: any)
	log = ctx.log
	flags = ctx.flags
	useMock = RunService:IsStudio() and flags.get("data_use_mock_in_studio") == true
	log:info("mode", { mock = useMock, compression = Codec.isCompressionAvailable() })

	game:BindToClose(function()
		closing = true
		local pending = 0
		for session in activeSessions do
			pending += 1
			task.spawn(function()
				(session :: Session):release()
				pending -= 1
			end)
		end
		local deadline = os.clock() + SHUTDOWN_BUDGET_SECONDS
		while pending > 0 and os.clock() < deadline do
			task.wait(0.1)
		end
		log:info("shutdown_flushed", { remaining = pending })
	end)
end

-- Autosave: spreads saves evenly across the interval so they never burst the request budget.
function DataService.start(_self: any, _ctx: any)
	while not closing do
		local interval = math.max(15, flags.get("data_autosave_seconds") or 60)
		local list = {}
		for session in activeSessions do
			table.insert(list, session)
		end
		if #list == 0 then
			task.wait(interval)
			continue
		end
		local gap = interval / #list
		for _, session in list do
			if closing then
				break
			end
			if (session :: Session):isActive() then
				task.spawn(Session.save, session :: Session)
			end
			task.wait(gap)
		end
	end
end

return DataService
