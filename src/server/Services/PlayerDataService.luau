--!strict
--[[
	PlayerDataService: owns each player's session and their runtime magic state.

	On join: load the session-locked record, then generate the innate profile on first ever join
	(or restore it), then build the CasterProfile. On leave: release (final save + unlock).
	If the lock is lost (the player's data was taken over by another server), the player is
	kicked here, because continuing would make the two copies diverge.

		local state = PlayerDataService:get(player)   -- nil while loading
		state.data      -- the saved table (mutate; autosave persists it)
		state.innate    -- InnateProfile (same table as state.data.profile)
		state.caster    -- CasterProfile for MagicCore / Reservoir; refreshCaster() after changes
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Types = require(Shared.Magic.Types)
local Schemas = require(script.Parent.Parent.Persistence.Schemas)
local ServerMagic = ServerScriptService.Server.Magic
local ProfileGenerator = require(ServerMagic.ProfileGenerator)
local InnateProfile = require(ServerMagic.InnateProfile)

export type PlayerState = {
	player: Player,
	session: any,
	data: any,
	innate: Types.InnateProfile,
	caster: Types.CasterProfile,
	joinedAt: number,
}

local KICK_MESSAGES: { [string]: string } = {
	SESSION_LOCKED = "Your data is still saving on another server. Please rejoin in a minute.",
	NEWER_SCHEMA = "This server is out of date. Please rejoin to get the latest version.",
	SHUTTING_DOWN = "This server is shutting down. Please rejoin.",
}
local DEFAULT_KICK = "We couldn't load your data safely. Please rejoin. Your progress is safe."

local PlayerDataService = {
	name = "PlayerDataService",
	dependencies = { "DataService", "WorldService", "NetService" },
}

local log: any = nil
local bus: any = nil
local store: any = nil
local world: any = nil
local states: { [Player]: PlayerState } = {}
local loadedSignals: { [Player]: { thread } } = {}

local function keyFor(player: Player): string
	return "player_" .. player.UserId
end

local function wakeWaiters(player: Player)
	local waiting = loadedSignals[player]
	loadedSignals[player] = nil
	if waiting then
		for _, thread in waiting do
			task.spawn(thread, states[player])
		end
	end
end

local function restoreProfile(player: Player, data: any): Types.InnateProfile
	if data.profile ~= nil then
		local profile, why = InnateProfile.deserialize(data.profile)
		if profile then
			return profile
		end
		-- Earned awakenings are lost; the base profile is regenerated identically from the seed.
		log:error("profile_corrupt_regenerating", { userId = player.UserId, reason = why })
	end
	return ProfileGenerator.generate(world:getSeed(), "player:" .. player.UserId, { kind = "Player" })
end

local function onJoin(player: Player)
	local session, err = store:load(keyFor(player), { userIds = { player.UserId } })
	if not session then
		log:warn("load_failed", { userId = player.UserId, reason = err })
		if player.Parent then
			player:Kick(KICK_MESSAGES[err or ""] or DEFAULT_KICK)
		end
		wakeWaiters(player)
		return
	end
	if not player.Parent then
		session:release() -- left while loading
		wakeWaiters(player)
		return
	end

	local data = session.data
	local firstJoin = data.profile == nil
	local innate = restoreProfile(player, data)
	data.profile = innate -- the profile IS save data; mutations persist with the session
	local now = os.time()
	if firstJoin then
		data.stats.firstJoin = now
	end
	data.stats.joins += 1
	data.stats.lastJoin = now

	local state: PlayerState = {
		player = player,
		session = session,
		data = data,
		innate = innate,
		caster = InnateProfile.toCasterProfile(innate, data.progression),
		joinedAt = now,
	}
	states[player] = state

	session.released:Connect(function(reason: string)
		if states[player] == state then
			states[player] = nil
		end
		bus:publish(Topics.PlayerDataReleased, { player = player, userId = player.UserId, reason = reason })
		if reason == "LOCK_LOST" and player.Parent then
			player:Kick("Your session was opened on another server. Please rejoin.")
		end
	end)

	log:info("player_ready", { userId = player.UserId, firstJoin = firstJoin, tier = InnateProfile.getRarityTier(innate, false) })
	wakeWaiters(player)
	bus:publish(Topics.PlayerDataLoaded, { player = player })
end

local function onLeave(player: Player)
	local state = states[player]
	if state then
		state.data.stats.playtime += os.time() - state.joinedAt
		state.session:release()
	end
end

function PlayerDataService.init(_self: any, ctx: any)
	log, bus = ctx.log, ctx.bus
	world = ctx.get("WorldService")
	store = ctx.get("DataService"):openSessionStore(Schemas.Player)

	-- What this player knows about themselves; never the raw profile (it holds hidden latents).
	Net.handle("RequestProfileView", function(player: Player)
		local state = states[player]
		if not state then
			return nil
		end
		return InnateProfile.getVisibleProfile(state.innate, state.data.progression.knowledge or 0)
	end)
end

function PlayerDataService.start(_self: any, _ctx: any)
	Players.PlayerAdded:Connect(onJoin)
	Players.PlayerRemoving:Connect(onLeave)
	for _, player in Players:GetPlayers() do
		task.spawn(onJoin, player)
	end
end

function PlayerDataService.get(_self: any, player: Player): PlayerState?
	return states[player]
end

-- Yields until the player's data is ready (or failed). Returns nil on failure or timeout.
function PlayerDataService.await(_self: any, player: Player, timeout: number?): PlayerState?
	if states[player] then
		return states[player]
	end
	local thread = coroutine.running()
	local list = loadedSignals[player] or {}
	loadedSignals[player] = list
	table.insert(list, thread)
	task.delay(timeout or 30, function()
		local index = table.find(list, thread)
		if index then
			table.remove(list, index)
			task.spawn(thread, nil)
		end
	end)
	return coroutine.yield()
end

-- Call after mastery, temperaments or affinities change (e.g. after applyAwakening).
function PlayerDataService.refreshCaster(_self: any, player: Player)
	local state = states[player]
	if state then
		state.caster = InnateProfile.toCasterProfile(state.innate, state.data.progression)
	end
end

function PlayerDataService.saveNow(_self: any, player: Player): boolean
	local state = states[player]
	return state ~= nil and state.session:save()
end

function PlayerDataService.list(_self: any): { PlayerState }
	local out = {}
	for _, state in states do
		table.insert(out, state)
	end
	return out
end

return PlayerDataService
