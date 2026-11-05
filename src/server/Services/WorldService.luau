--!strict
--[[
	WorldService: the shared world record and cross-server world events.

	Architecture (see docs/Backend.md §4): every server runs the SAME world (one seed, the same
	NPCs, the same generated places). Live world state such as NPC positions, fires and
	spells is per-server and temporary. What all servers share:
	- the world record (seed, epoch, flags, chronicle) in the "World" DataStore
	- live announcements of notable events via MessagingService

	RESEED (owner-only admin command): writes a new seed and epoch and bumps `generation`.
	Every world-keyed record (terrain deltas, regions, settlement state, NPC towns) is stored
	under scopedKey(), which prefixes "g<generation>_" from generation 1 on, so the new world
	starts clean while generation 0 keeps its original, unprefixed keys. Every server then
	closes (MessagingService) so players rejoin the new world. Player saves are not touched:
	reputation and NPC relationships keyed by settlement/NPC ids will point at the new world's
	places of the same ids.
]]

local MessagingService = game:GetService("MessagingService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Signal = require(Shared.Core.Signal)
local Topics = require(Shared.Core.Topics)
local Schemas = require(script.Parent.Parent.Persistence.Schemas)
local Retry = require(script.Parent.Parent.Persistence.Retry)

local WORLD_KEY = "world_main"
local CHRONICLE_CAP = 200
local MESSAGE_TOPIC = "WorldEvents"
local MAX_MESSAGE_CHARS = 900 -- MessagingService limit is 1 KB per message
local RESEED_TOPIC = "WorldReseeded"
local CLOSED_MESSAGE = "The world has been regenerated. Please rejoin."

local WorldService = {
	name = "WorldService",
	dependencies = { "DataService" },
}

local log: any = nil
local bus: any = nil
local flags: any = nil
local store: any = nil
local dataService: any = nil
local world: any = nil
local ready = Signal.new()
local counter = 0
local closed = false
local reseeding = false -- one reseed per server: it closes right after

function WorldService.init(_self: any, ctx: any)
	log, bus, flags = ctx.log, ctx.bus, ctx.flags
	dataService = ctx.get("DataService")
	store = dataService:openStore(Schemas.World)
end

-- Creates the world exactly once across all servers: the transform cancels if another
-- server got there first.
local function loadOrCreate(): any?
	local existing = store:read(WORLD_KEY)
	if existing and existing.seed ~= 0 then
		return existing
	end
	if existing == nil then
		return nil
	end
	local studioSeed = if dataService:isMock() then flags.get("world_studio_seed") else nil
	local created = store:update(WORLD_KEY, function(w)
		if w.seed ~= 0 then
			return nil
		end
		w.seed = studioSeed or Random.new():NextInteger(1, 2 ^ 31 - 2)
		w.createdAt = os.time()
		w.epoch = w.createdAt
		return w
	end)
	return created or store:read(WORLD_KEY)
end

-- Kicks everyone and refuses new joins: this server's world is stale (a reseed happened).
local function closeServer(reason: string)
	if closed then
		return
	end
	closed = true
	log:warn("server_closing", { reason = reason })
	local Players = game:GetService("Players")
	Players.PlayerAdded:Connect(function(player)
		player:Kick(CLOSED_MESSAGE)
	end)
	for _, player in Players:GetPlayers() do
		player:Kick(CLOSED_MESSAGE)
	end
end

function WorldService.start(_self: any, _ctx: any)
	-- Nothing can generate a profile without the seed, so keep trying. Joining players wait in getSeed().
	while not world do
		world = loadOrCreate()
		if not world then
			log:error("world_load_failed", { retryIn = 10 })
			task.wait(10)
		end
	end
	log:info("world_ready", { epoch = world.epoch, chronicle = #world.chronicle })
	ready:Fire()

	if flags.get("world_messaging") and not dataService:isMock() then
		local ok, err = pcall(function()
			MessagingService:SubscribeAsync(MESSAGE_TOPIC, function(message)
				local event = message.Data
				if typeof(event) ~= "table" or event.origin == game.JobId then
					return
				end
				bus:publish(Topics.WorldEventRecorded, event)
			end)
			MessagingService:SubscribeAsync(RESEED_TOPIC, function(message)
				local data = message.Data
				if typeof(data) == "table" and data.origin ~= game.JobId then
					closeServer("reseeded on " .. tostring(data.origin))
				end
			end)
		end)
		if not ok then
			log:warn("messaging_unavailable", { err = err })
		end
	end
end

-- Yields until the world record is loaded.
function WorldService.getSeed(_self: any): number
	if not world then
		ready:Wait()
	end
	return world.seed
end

-- Unix time of world day 0 (yields until loaded). NPC game clocks count from it.
function WorldService.getEpoch(_self: any): number
	if not world then
		ready:Wait()
	end
	return world.epoch
end

-- The world's generation: 0 for the original world, +1 per reseed (yields until loaded).
function WorldService.getGeneration(_self: any): number
	if not world then
		ready:Wait()
	end
	return world.generation or 0
end

-- A storage key for world-keyed data, unique to this generation of the world. Yields until loaded.
function WorldService.scopedKey(self: any, key: string): string
	local generation = self:getGeneration()
	return if generation > 0 then "g" .. generation .. "_" .. key else key
end

--[[
	OWNER-ONLY (checked by the admin command, and again here by the caller's UserId).
	Writes a new seed, epoch and generation, records it, and closes every server. Yields.
	Returns (ok, message).
]]
function WorldService.reseed(self: any, newSeed: number, byUserId: number, ownerUserId: number): (boolean, string)
	if byUserId ~= ownerUserId then
		return false, "owner only"
	end
	if reseeding or closed then
		return false, "a reseed already happened on this server; it is closing"
	end
	if newSeed % 1 ~= 0 or newSeed < 1 or newSeed > 2 ^ 31 - 2 then
		return false, "seed must be a whole number from 1 to 2147483646"
	end
	reseeding = true
	local now = os.time()
	local updated, err = store:update(WORLD_KEY, function(w)
		w.seed = newSeed
		w.epoch = now
		w.generation = (w.generation or 0) + 1
		return w
	end)
	if not updated then
		reseeding = false
		return false, "world record update failed: " .. tostring(err)
	end
	world = updated
	log:warn("world_reseeded", { seed = newSeed, generation = updated.generation, by = byUserId })
	self:recordEvent("world_reseeded", { generation = updated.generation, by = byUserId })
	if not dataService:isMock() then
		Retry.call(function()
			MessagingService:PublishAsync(RESEED_TOPIC, { origin = game.JobId, generation = updated.generation })
		end, { attempts = 3, label = "publish reseed" })
	end
	task.delay(3, closeServer, "reseeded here")
	return true, string.format("world reseeded to %d (generation %d). Every server is closing; rejoin to play the new world.%s",
		newSeed, updated.generation, if dataService:isMock() then " (Studio mock store: it forgets this when Play stops. Set world_studio_seed in Config/Flags to keep a Studio seed.)" else "")
end

-- World day since the epoch (one real day per world day by default).
function WorldService.getWorldDay(_self: any): number
	if not world then
		ready:Wait()
	end
	return math.floor((os.time() - world.epoch) / 86400)
end

--[[
	Records a notable global event: appended to the chronicle (deduplicated by id, capped) and
	announced to every server. `data` must be small and JSON-safe. Yields.
]]
function WorldService.recordEvent(_self: any, kind: string, data: { [string]: any })
	counter += 1
	local event = { id = game.JobId .. ":" .. counter, kind = kind, t = os.time(), data = data, origin = game.JobId }
	store:update(WORLD_KEY, function(w)
		for _, existing in w.chronicle do
			if existing.id == event.id then
				return nil -- already written (a retried transform)
			end
		end
		table.insert(w.chronicle, event)
		while #w.chronicle > CHRONICLE_CAP do
			table.remove(w.chronicle, 1)
		end
		return w
	end)
	bus:publish(Topics.WorldEventRecorded, event)

	if flags.get("world_messaging") and not dataService:isMock() then
		local ok, encoded = pcall(game:GetService("HttpService").JSONEncode, game:GetService("HttpService"), event)
		if ok and #encoded <= MAX_MESSAGE_CHARS then
			Retry.call(function()
				MessagingService:PublishAsync(MESSAGE_TOPIC, event)
			end, { attempts = 3, label = "publish " .. kind })
		else
			log:warn("event_too_large_to_broadcast", { kind = kind })
		end
	end
end

return WorldService
