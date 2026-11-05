--!strict
--[[
	Net: the ONLY way code talks across the client/server boundary.

	Server
		Net.start(bus?)                  create remotes from Remotes.luau (call once, at boot)
		Net.on(name, fn(player, ...))    handle a client Event / Unreliable remote
		Net.handle(name, fn(player, ...) -> ...)  handle a client Function remote
		Net.fire(name, player, ...) / Net.fireAll(name, ...) / Net.fireList(name, players, ...)

	Client
		Net.start()                      bind to the server's remotes
		Net.send(name, ...)              fire a client Event / Unreliable remote
		Net.invoke(name, ...) -> (ok, ...)  call a client Function remote
		Net.listen(name, fn(...))        receive a server remote

	Every client -> server message passes these checks before any handler runs, cheapest first:
		1. argument count  2. per-player rate limit  3. payload size  4. schema of every argument
	Rejections are counted per player. With the `net_kick_on_abuse` flag on, a player who
	exceeds `net_violation_threshold` rejections in a minute is kicked, with a neutral message.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Core = script.Parent:WaitForChild("Core")
local Logger = require(Core.Logger)
local RateLimiter = require(Core.RateLimiter)
local FeatureFlags = require(Core.FeatureFlags)
local Topics = require(Core.Topics)
local Schema = require(script.Schema)
local Remotes = require(script.Remotes)

type RemoteDef = Remotes.RemoteDef

local FOLDER_NAME = "NetRemotes"
local MAX_DEPTH = 6
local DEFAULT_MAX_BYTES = 512

local Net = {}
Net.Schema = Schema
Net.Remotes = Remotes

local isServer = RunService:IsServer()
local log = Logger.new("Net")
local started = false
local instances: { [string]: Instance } = {}
local limiters: { [string]: RateLimiter.RateLimiter } = {}
local handlers: { [string]: (...any) -> ...any } = {}
local violations: { [Player]: { count: number, windowStart: number } } = {}
local bus: any = nil

local function def(name: string): RemoteDef
	local d = Remotes[name]
	if not d then
		error("Net: unknown remote " .. tostring(name), 3)
	end
	return d
end

-- Rough serialized size of a remote argument. Stops counting once over `budget`.
local function estimateSize(value: any, budget: number, depth: number): number
	local kind = typeof(value)
	if kind == "string" then
		return #value + 2
	elseif kind == "number" then
		return 9
	elseif kind == "boolean" or kind == "nil" then
		return 1
	elseif kind == "Vector3" then
		return 13
	elseif kind == "CFrame" then
		return 49
	elseif kind == "Instance" then
		return 8
	elseif kind == "table" then
		if depth >= MAX_DEPTH then
			return math.huge
		end
		local size = 2
		for k, v in value do
			size += estimateSize(k, budget - size, depth + 1) + estimateSize(v, budget - size, depth + 1)
			if size > budget then
				return size
			end
		end
		return size
	end
	return 16
end
Net.estimateSize = estimateSize

-- ─── Server ─────────────────────────────────────────────────────────────────

local function reject(player: Player, name: string, reason: string, detail: string?)
	local now = os.clock()
	local record = violations[player]
	if not record or now - record.windowStart > 60 then
		record = { count = 0, windowStart = now }
		violations[player] = record
	end
	record.count += 1
	log:throttled(tostring(player.UserId) .. ":" .. name .. ":" .. reason, 10, "Warn", "rejected", {
		userId = player.UserId,
		remote = name,
		reason = reason,
		detail = detail,
		minuteCount = record.count,
	})
	if bus then
		bus:publish(Topics.NetViolation, { player = player, remote = name, reason = reason })
	end
	if FeatureFlags.get("net_kick_on_abuse") and record.count >= (FeatureFlags.get("net_violation_threshold") or 50) then
		log:warn("kicked_for_abuse", { userId = player.UserId, remote = name })
		player:Kick("Connection problem detected. Please rejoin.")
	end
end

local function guard(player: Player, name: string, d: RemoteDef, ...: any): boolean
	local argCount = select("#", ...)
	local schema = d.args or {}
	if argCount > #schema then
		reject(player, name, "TOO_MANY_ARGS")
		return false
	end
	if not limiters[name]:take(player.UserId) then
		reject(player, name, "RATE_LIMITED")
		return false
	end
	local maxBytes = d.maxBytes or DEFAULT_MAX_BYTES
	local size = 0
	for i = 1, argCount do
		size += estimateSize((select(i, ...)), maxBytes - size, 0)
		if size > maxBytes then
			reject(player, name, "PAYLOAD_TOO_LARGE")
			return false
		end
	end
	for i, validator in schema do
		local ok, why = validator((select(i, ...)))
		if not ok then
			reject(player, name, "BAD_ARGUMENT", string.format("arg %d: %s", i, why or "invalid"))
			return false
		end
	end
	return true
end

local function startServer()
	local folder = Instance.new("Folder")
	folder.Name = FOLDER_NAME

	local names: { string } = {}
	for name in Remotes do
		table.insert(names, name)
	end
	table.sort(names)

	for _, name in names do
		local d = Remotes[name]
		assert(d.from == "Client" or d.from == "Server", "Net: bad `from` for " .. name)
		assert(not (d.kind == "Function" and d.from == "Server"), "Net: server-invoked functions are forbidden: " .. name)
		local className = if d.kind == "Function"
			then "RemoteFunction"
			elseif d.kind == "Unreliable" then "UnreliableRemoteEvent"
			else "RemoteEvent"
		local remote = Instance.new(className)
		remote.Name = name
		remote.Parent = folder
		instances[name] = remote

		if d.from ~= "Client" then
			continue
		end
		local rate = d.rate or { capacity = 5, perSecond = 1 }
		limiters[name] = RateLimiter.new(rate.capacity, rate.perSecond)

		if d.kind == "Function" then
			(remote :: RemoteFunction).OnServerInvoke = function(player: Player, ...: any): ...any
				if not guard(player, name, d, ...) then
					return nil
				end
				local handler = handlers[name]
				if not handler then
					log:throttled("nohandler:" .. name, 60, "Warn", "no_handler", { remote = name })
					return nil
				end
				local results = table.pack(xpcall(handler, debug.traceback, player, ...))
				if not results[1] then
					log:error("handler_error", { remote = name, err = results[2] })
					return nil
				end
				return table.unpack(results, 2, results.n)
			end
		else
			(remote :: any).OnServerEvent:Connect(function(player: Player, ...: any)
				if not guard(player, name, d, ...) then
					return
				end
				local handler = handlers[name]
				if not handler then
					log:throttled("nohandler:" .. name, 60, "Warn", "no_handler", { remote = name })
					return
				end
				local ok, err = xpcall(handler, debug.traceback, player, ...)
				if not ok then
					log:error("handler_error", { remote = name, err = err })
				end
			end)
		end
	end

	folder.Parent = ReplicatedStorage

	Players.PlayerRemoving:Connect(function(player)
		violations[player] = nil
		for _, limiter in limiters do
			limiter:reset(player.UserId)
		end
	end)
end

function Net.on(name: string, handler: (Player, ...any) -> ())
	local d = def(name)
	assert(isServer and d.from == "Client" and d.kind ~= "Function", "Net.on: " .. name .. " is not a client event")
	assert(handlers[name] == nil, "Net.on: handler already registered for " .. name)
	handlers[name] = handler
end

function Net.handle(name: string, handler: (Player, ...any) -> ...any)
	local d = def(name)
	assert(isServer and d.from == "Client" and d.kind == "Function", "Net.handle: " .. name .. " is not a client function")
	assert(handlers[name] == nil, "Net.handle: handler already registered for " .. name)
	handlers[name] = handler
end

local function serverRemote(name: string): any
	local d = def(name)
	assert(isServer and d.from == "Server", "Net: " .. name .. " is not a server->client remote")
	return instances[name]
end

function Net.fire(name: string, player: Player, ...: any)
	serverRemote(name):FireClient(player, ...)
end

function Net.fireAll(name: string, ...: any)
	serverRemote(name):FireAllClients(...)
end

function Net.fireList(name: string, players: { Player }, ...: any)
	local remote = serverRemote(name)
	for _, player in players do
		remote:FireClient(player, ...)
	end
end

-- ─── Client ─────────────────────────────────────────────────────────────────

local clientFolder: Instance? = nil
local clientLimiters: { [string]: RateLimiter.RateLimiter } = {}

local function clientRemote(name: string): any
	local folder = clientFolder or ReplicatedStorage:WaitForChild(FOLDER_NAME)
	clientFolder = folder
	local remote = folder:WaitForChild(name, 10)
	if not remote then
		error("Net: remote " .. name .. " never replicated", 3)
	end
	return remote
end

-- Drops sends locally when over the server's limit, so a spamming UI can't get its own player kicked.
local function clientAllowed(name: string, d: RemoteDef): boolean
	local limiter = clientLimiters[name]
	if not limiter then
		local rate = d.rate or { capacity = 5, perSecond = 1 }
		limiter = RateLimiter.new(rate.capacity, rate.perSecond)
		clientLimiters[name] = limiter
	end
	return limiter:take("self")
end

function Net.send(name: string, ...: any)
	local d = def(name)
	assert(not isServer and d.from == "Client" and d.kind ~= "Function", "Net.send: " .. name .. " is not a client event")
	if clientAllowed(name, d) then
		clientRemote(name):FireServer(...)
	end
end

-- Returns (true, results...) or (false, reason). Never errors.
function Net.invoke(name: string, ...: any): (boolean, ...any)
	local d = def(name)
	assert(not isServer and d.from == "Client" and d.kind == "Function", "Net.invoke: " .. name .. " is not a client function")
	if not clientAllowed(name, d) then
		return false, "RATE_LIMITED"
	end
	local remote = clientRemote(name)
	return pcall(remote.InvokeServer, remote, ...)
end

function Net.listen(name: string, handler: (...any) -> ()): RBXScriptConnection
	local d = def(name)
	assert(not isServer and d.from == "Server", "Net.listen: " .. name .. " is not a server->client remote")
	return clientRemote(name).OnClientEvent:Connect(handler)
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function Net.start(signalBus: any?)
	if started then
		return
	end
	started = true
	bus = signalBus
	if isServer then
		startServer()
	end
end

return Net
