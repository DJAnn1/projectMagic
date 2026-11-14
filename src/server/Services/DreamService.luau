--!strict
--[[
	DreamService: you dream when you sleep in a bed (docs/Dreams.md; rules in Server/Magic/Dreams,
	lines in Server/Magic/Data/Dreams).

	SLEEP   Lie in a bed (InteractionService:bedOf) for Dreams.sleepNeeded(hour) real seconds: about
	        25 at night, 60 by day. `drift` seconds before that the screen starts to dim (remote
	        Dreaming "drift"); at the end you dream and wake ("wake"). Getting up first wakes you with
	        no dream. One dream per in-game day, and gapSeconds of real time between dreams.
	DREAM   Dreams.pick: usually one of your hidden, non-mythic latents, weighted by strength; on
	        some nights (and always without hidden latents) an ordinary dream, so dreaming never
	        proves a latent exists. Dreams about the same latent grow clearer: an image, then "it was
	        mine", then a hint at what might wake it. Mythic latents are never dreamt.
	TELLING A first-person Journal line (kind "dream", ☾); the HUD shows it as the Journal does. When
	        a latent you dreamt about later awakens (by any route), a second line: you'd dreamt this.

	SECRETS The latent, its kind and the clarity stay on the server (and in the server log); the
	        client receives only the finished line, and Dreaming carries no content at all.

	Save: data.dreams { count, lastAt, lastDay, seen, recalled } (Schemas; reconcile fills old saves).
	Admin: `dream [player]` dreams now (no bed, no wait); `dreams [player] [clear]` lists what they've
	dreamt about and the clarity of the next dream, or forgets it. Flag `dreams_enabled`.
	Log: `dream_had` { userId, ordinary, kind, clarity, count }, `dream_came_true` { userId, kind }.
	Cost: once a second, a scan of the resting beds per player; every 10 s a pass over at most three
	dreamt latents per player.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Net = require(Shared.Net)
local Server = ServerScriptService.Server
local Dreams = require(Server.Magic.Dreams)
local Data = require(Server.Magic.Data.Dreams)
local WorldClock = require(Server.NPC.WorldClock)

local DreamService = {
	name = "DreamService",
	dependencies = { "AdminService", "InteractionService", "JournalService", "NetService", "PlayerDataService", "WorldService" },
}

type Sleeper = { since: number, drifting: boolean, done: boolean }

local log: any = nil
local journal: any = nil
local playerData: any = nil
local interaction: any = nil
local worldService: any = nil

local sleepers: { [Player]: Sleeper } = {}

local function enabled(): boolean
	return FeatureFlags.get("dreams_enabled") == true
end

-- The save record (reconcile fills old saves; this guards a save loaded before that ran).
local function recordOf(player: Player): Dreams.Record?
	local state = playerData:get(player)
	if not state then
		return nil
	end
	local data = state.data
	local r = data.dreams
	if typeof(r) ~= "table" then
		r = {}
		data.dreams = r
	end
	r.count = r.count or 0
	r.lastAt = r.lastAt or 0
	r.lastDay = r.lastDay or -1
	r.seen = r.seen or {}
	r.recalled = r.recalled or {}
	return r :: Dreams.Record
end

local function canDream(record: Dreams.Record): boolean
	return os.time() - record.lastAt >= Data.gapSeconds and record.lastDay ~= WorldClock.day()
end

local function dream(player: Player): Dreams.Pick?
	local state = playerData:get(player)
	local record = recordOf(player)
	if not state or not record or not state.innate then
		return nil
	end
	local knowledge = (state.data.progression and state.data.progression.knowledge) or 0
	local pick = Dreams.pick(state.innate, record, knowledge, worldService:getSeed())
	record.count += 1
	record.lastAt = os.time()
	record.lastDay = WorldClock.day()
	if pick.latentId then
		record.seen[pick.latentId] = (record.seen[pick.latentId] or 0) + 1
	end
	journal:log(player, "dream", pick.text)
	log:info("dream_had", {
		userId = player.UserId,
		ordinary = pick.ordinary,
		kind = pick.kind,
		clarity = pick.clarity,
		count = record.count,
	})
	return pick
end

-- A latent you dreamt about has since awakened (any route): write that the dream came true, once.
local function checkRecalled(player: Player)
	local state = playerData:get(player)
	local record = recordOf(player)
	if not state or not record or not state.innate then
		return
	end
	for latentId in record.seen do
		if not record.recalled[latentId] then
			for _, latent in (state.innate.latents or {}) :: { any } do
				if latent.id == latentId and latent.revealed then
					record.recalled[latentId] = os.time()
					journal:log(player, "dream", Dreams.recalled(latent, worldService:getSeed(), state.innate.entityId))
					log:info("dream_came_true", { userId = player.UserId, kind = latent.kind })
					break
				end
			end
		end
	end
end

local function wake(player: Player)
	local sleeper = sleepers[player]
	if sleeper and sleeper.drifting then
		Net.fire("Dreaming", player, "wake")
	end
	sleepers[player] = nil
end

local function tick()
	local now = os.clock()
	for _, player in Players:GetPlayers() do
		local bed = enabled() and interaction:bedOf(player) or nil
		if not bed then
			if sleepers[player] then
				wake(player)
			end
			continue
		end
		local sleeper = sleepers[player]
		if not sleeper then
			sleeper = { since = now, drifting = false, done = false }
			sleepers[player] = sleeper
		end
		local record = recordOf(player)
		if sleeper.done or not record or not canDream(record) then
			continue
		end
		local need = Dreams.sleepNeeded(WorldClock.hour())
		local slept = now - sleeper.since
		if not sleeper.drifting and slept >= need - Data.sleep.drift then
			sleeper.drifting = true
			Net.fire("Dreaming", player, "drift")
		end
		if sleeper.drifting and slept >= need then
			sleeper.done = true
			dream(player)
			Net.fire("Dreaming", player, "wake")
			sleeper.drifting = false
		end
	end
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "dream",
		category = "Magic",
		description = "Have a player dream right now, without a bed or the once-a-day wait; the line goes to their Journal and the choice is printed here",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_ctx: any, a: any)
			local pick = dream(a.player)
			if not pick then
				return "no data for them yet"
			end
			local about = if pick.ordinary then "ordinary" else string.format("%s latent %s, clarity %d", tostring(pick.kind), tostring(pick.latentId), pick.clarity)
			return string.format("(%s) %s", about, pick.text)
		end,
	})
	admin:Register({
		name = "dreams",
		category = "Magic",
		description = "List what a player has dreamt about (hidden latents a dream can reach, dreams about each, the clarity of the next one, whether it came true), or clear it",
		args = {
			{ name = "player", type = "player", default = "me" },
			{ name = "clear", type = "string", default = "" },
		},
		handler = function(_ctx: any, a: any)
			local state = playerData:get(a.player)
			local record = recordOf(a.player)
			if not state or not record then
				return "no data for them yet"
			end
			if a.clear == "clear" then
				record.count, record.lastAt, record.lastDay = 0, 0, -1
				table.clear(record.seen)
				table.clear(record.recalled)
				return "cleared"
			end
			local knowledge = (state.data.progression and state.data.progression.knowledge) or 0
			local lines = {
				string.format(
					"%d dreams · last %s · can dream now: %s · flag %s",
					record.count,
					if record.lastAt > 0 then string.format("%ds ago", os.time() - record.lastAt) else "never",
					tostring(canDream(record)),
					tostring(enabled())
				),
			}
			local reachable = Dreams.eligible(state.innate)
			table.insert(lines, string.format("  hidden latents a dream can reach: %d", #reachable))
			for _, latent in (state.innate.latents or {}) :: { any } do
				local n = record.seen[latent.id] or 0
				table.insert(lines, string.format(
					"  %s %s %s: %d dream(s), next clarity %d%s%s",
					latent.id, latent.kind, latent.target, n, Dreams.clarity(n, knowledge),
					if latent.revealed then " · revealed" else "",
					if record.recalled[latent.id] then " · came true" else ""
				))
			end
			return table.concat(lines, "\n")
		end,
	})
end

function DreamService.init(_self: any, ctx: any)
	log = ctx.log
	journal = ctx.get("JournalService")
	playerData = ctx.get("PlayerDataService")
	interaction = ctx.get("InteractionService")
	worldService = ctx.get("WorldService")
	registerAdmin(ctx.get("AdminService"))
end

function DreamService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		sleepers[player] = nil
	end)
	task.spawn(function()
		local ticks = 0
		while true do
			task.wait(1)
			ticks += 1
			local ok, err = pcall(tick)
			if not ok then
				log:warn("dream_tick_failed", { error = tostring(err) })
			end
			if ticks % 10 == 0 and enabled() then
				for _, player in Players:GetPlayers() do
					pcall(checkRecalled, player)
				end
			end
		end
	end)
end

return DreamService
