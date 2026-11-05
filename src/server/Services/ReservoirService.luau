--!strict
--[[
	ReservoirService: owns every player's live ReservoirState (Shared/Magic/Reservoir) and streams
	a read-only copy to its owner for the HUD.

		get(player) -> ReservoirState?        the authoritative state (CastService spends from it)
		setActivity(player, activity)         "Normal" | "Resting" | "Combat": the regen multiplier
		push(player)                          send the snapshot now (call after a spend)

	The state is per session and never saved: everyone rejoins full. One loop ticks regeneration
	for all players TICK_RATE times a second, using the ambient density under each player. A
	snapshot goes to the owner only when something they can see changed, over an
	UnreliableRemoteEvent: a lost packet is simply replaced by the next one.

	The maximum follows mastery (attunement), so it's refreshed from the caster every
	REFRESH_EVERY ticks rather than on every progression change. Items then scale it:
	(profile max + gear flat) x (1 + gear %), and regen by the gear regen % (Items/StatCache).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Types = require(Shared.Magic.Types)
local Reservoir = require(Shared.Magic.Reservoir)
local StatCache = require(script.Parent.Parent.Items.StatCache)

local TICK_RATE = 4 -- regen ticks per second
local REFRESH_EVERY = 4 -- ticks between max-capacity refreshes (1 s)

type Entry = {
	state: Types.ReservoirState,
	activity: string,
	signature: string, -- what the owner last received, for change detection
}

local ReservoirService = {
	name = "ReservoirService",
	dependencies = { "NetService", "PlayerDataService", "WorldStateService" },
}

local playerData: any = nil
local world: any = nil
local entries: { [Player]: Entry } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

-- Items on top of the profile values refreshMax/newState just set (keeps the current/max ratio).
local function applyItems(player: Player, state: Types.ReservoirState)
	local baseMax = state.max
	local max, regen = StatCache.reservoir(player, baseMax, state.regenMult)
	if max ~= baseMax and baseMax > 0 then
		state.current *= max / baseMax
		state.max = max
	end
	state.regenMult = regen
end

-- Creates the entry the first time the player's data is available.
local function entryFor(player: Player): Entry?
	local entry = entries[player]
	if entry then
		return entry
	end
	local data = playerData:get(player)
	if not data then
		return nil
	end
	local created: Entry = { state = Reservoir.newState(data.caster), activity = "Normal", signature = "" }
	applyItems(player, created.state)
	entries[player] = created
	return created
end

-- Whole numbers are enough for the HUD; sending only on a visible change keeps traffic near zero
-- for a full, idle reservoir.
local function snapshotOf(state: Types.ReservoirState): ({ [string]: any }, string)
	local lockouts: { [string]: number } = {}
	local lockoutParts: { string } = {}
	for domainId, untilTime in state.lockouts do
		lockouts[domainId] = math.ceil(untilTime)
		table.insert(lockoutParts, domainId .. math.ceil(untilTime))
	end
	table.sort(lockoutParts)
	local snapshot = {
		current = math.floor(state.current + 0.5),
		max = math.floor(state.max + 0.5),
		strain = math.floor(state.strain + 0.5),
		burnoutUntil = math.ceil(state.burnoutUntil),
		lockouts = lockouts,
	}
	local signature = string.format(
		"%d|%d|%d|%d|%s",
		snapshot.current,
		snapshot.max,
		snapshot.strain,
		snapshot.burnoutUntil,
		table.concat(lockoutParts, ",")
	)
	return snapshot, signature
end

local function send(player: Player, entry: Entry, force: boolean)
	local snapshot, signature = snapshotOf(entry.state)
	if force or signature ~= entry.signature then
		entry.signature = signature
		Net.fire("ReservoirState", player, snapshot)
	end
end

function ReservoirService.get(_self: any, player: Player): Types.ReservoirState?
	local entry = entryFor(player)
	return entry and entry.state
end

function ReservoirService.setActivity(_self: any, player: Player, activity: string)
	local entry = entryFor(player)
	if entry then
		entry.activity = activity
	end
end

function ReservoirService.push(_self: any, player: Player)
	local entry = entryFor(player)
	if entry then
		send(player, entry, false)
	end
end

local function tickAll(dt: number, refresh: boolean)
	local t = now()
	for _, player in Players:GetPlayers() do
		local entry = entryFor(player)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not entry or not root then
			continue
		end
		if refresh then
			local data = playerData:get(player)
			if data then
				Reservoir.refreshMax(entry.state, data.caster)
				applyItems(player, entry.state)
			end
		end
		local position = root.Position
		Reservoir.tick(entry.state, dt, t, entry.activity, world:densityAt(position.X, position.Z))
		send(player, entry, false)
	end
end

function ReservoirService.init(_self: any, ctx: any)
	playerData = ctx.get("PlayerDataService")
	world = ctx.get("WorldStateService")
end

function ReservoirService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		entries[player] = nil
	end)
	-- densityAt needs the magic map, which exists once the world is generated.
	world:awaitReady()
	local ticks = 0
	local last = os.clock()
	while true do
		task.wait(1 / TICK_RATE)
		local clock = os.clock()
		ticks += 1
		tickAll(clock - last, ticks % REFRESH_EVERY == 0)
		last = clock
	end
end

return ReservoirService
