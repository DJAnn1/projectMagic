--!strict
--[[
	FirstHourService: how a real new player's first hour goes (docs/EarlyGamePlan.md §10). Records,
	in seconds of play since the first join: first damage, first ranged damage, Novice, the first new
	combination, the first recipe discovery, the first finished quest, plus casts and idle time.

	Only players whose first join happens now are measured: an old save can't say when its firsts
	were. Saved in PlayerData.firstHour, so a player who leaves and returns carries on.
	Milestones count for WINDOW_SECONDS of play (Novice can be late); casts and idle for the first hour.

	Logged without a user id (`first_hour`), so the log can be read in aggregate without identifying
	anyone. Per-player numbers are only in the admin `firsthour <player>` report.

	Idle: a gap of over IDLE_GAP seconds between casts, the part beyond it. That also counts walking
	and reading, so it's a ceiling on "nothing to do", not a measure of it.

	Admin: firsthour [player], firsthoursim [minutes]
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Topics = require(Shared.Core.Topics)

local Server = script.Parent.Parent
local FirstHour = require(Server.Progression.FirstHour)
local Progression = require(Server.Progression.Progression)

local WINDOW_SECONDS = 3 * 3600
local HOUR = 3600
local IDLE_GAP = 60
local MAX_ROWS = 200 -- players kept for this server's report
local RANGED: { [string]: boolean } = { projectile = true, beam = true, chain = true }

local FirstHourService = {
	name = "FirstHourService",
	dependencies = { "AdminService", "PlayerDataService" },
}

local log: any = nil
local playerData: any = nil
local rows: { any } = {} -- this server's rows, shared with the saves
local rowOf: { [Player]: any } = {}
local lastAction: { [Player]: number } = {}

local function played(state: any): number
	return (state.data.stats.playtime or 0) + (os.time() - state.joinedAt)
end

local function mark(player: Player, state: any, milestone: string)
	local row = rowOf[player]
	if not row or row[milestone] then
		return
	end
	local at = played(state)
	if at > WINDOW_SECONDS then
		return
	end
	row[milestone] = at
	log:info("first_hour", { milestone = milestone, seconds = at })
end

local function onLoaded(payload: any)
	local player: Player = payload.player
	local state = playerData:get(player)
	if not state then
		return
	end
	local data = state.data
	data.firstHour = data.firstHour or {}
	local row = data.firstHour
	if data.stats.joins == 1 then
		row.measuring = true
	end
	if row.measuring then
		row.casts = row.casts or 0
		row.idle = row.idle or 0
		rowOf[player] = row
		lastAction[player] = played(state)
		if #rows < MAX_ROWS then
			table.insert(rows, row)
		end
	end
end

local function checkProgress(player: Player, state: any)
	local p = state.data.progression
	for branchId in p.unlocked do
		if (Progression.getMasteryTier(p, branchId)) >= FirstHour.NOVICE_TIER then
			mark(player, state, "novice")
			break
		end
	end
	local d = state.data.discoveries
	if (d.noveltyCount or 0) > 0 then
		mark(player, state, "novelty")
	end
	if next(d.recipes) ~= nil then
		mark(player, state, "recipe")
	end
end

local function onResolved(payload: any)
	local player = Players:GetPlayerByUserId(payload.casterUserId)
	local row = player and rowOf[player]
	local state = player and playerData:get(player)
	if not player or not row or not state then
		return
	end
	local at = played(state)
	if at <= HOUR then
		row.casts += 1
		local gap = at - (lastAction[player] or at)
		if gap > IDLE_GAP then
			row.idle += gap - IDLE_GAP
		end
	end
	lastAction[player] = at
	if payload.harmful and payload.effective and (payload.hits or 0) > 0 and RANGED[payload.form] then
		mark(player, state, "ranged")
	end
	checkProgress(player, state)
end

local function onDamaged(payload: any)
	local source = payload.sourceUserId
	local player = if source then Players:GetPlayerByUserId(source) else nil
	if player and rowOf[player] and payload.model ~= player.Character then
		local state = playerData:get(player)
		if state then
			mark(player, state, "damage")
		end
	end
end

local function onQuestEnded(payload: any)
	if payload.success then
		for _, player in payload.players do
			local state = playerData:get(player)
			if state then
				mark(player, state, "quest")
				checkProgress(player, state) -- a lesson can reach Novice with no cast after it
			end
		end
	end
end

-- One player's numbers against the targets.
local function reportOne(player: Player): string
	local row = rowOf[player]
	local state = playerData:get(player)
	if not row or not state then
		return player.Name .. ": not measured (only players on their first join are)"
	end
	local at = played(state)
	local minutes = math.min(at, HOUR) / 60
	local lines = { string.format("%s, %.1f min played", player.Name, at / 60) }
	for _, name in FirstHour.ORDER do
		local target = (FirstHour.TARGETS :: any)[name]
		table.insert(lines, string.format("  %s: %s%s", name, FirstHour.format(row[name]), if target then " (target " .. FirstHour.format(target) .. ")" else ""))
	end
	table.insert(lines, string.format("  casts/min %.1f, idle at most %s", row.casts / math.max(minutes, 1 / 60), FirstHour.format(row.idle)))
	local misses = FirstHour.misses(row, at)
	table.insert(lines, if #misses == 0 then "  no target missed so far" else "  missed: " .. table.concat(misses, ", "))
	return table.concat(lines, "\n")
end

-- This server's medians. No names: only milestones and how many players reached them.
local function reportServer(): string
	if #rows == 0 then
		return "nobody measured on this server yet (only players on their first join are)"
	end
	local lines = { string.format("%d new player(s) on this server", #rows) }
	for _, name in FirstHour.ORDER do
		local values: { number } = {}
		for _, row in rows do
			if row[name] then
				table.insert(values, row[name])
			end
		end
		local target = (FirstHour.TARGETS :: any)[name]
		table.insert(lines, string.format("  %s: median %s, reached by %d%s", name, FirstHour.format(FirstHour.median(values)), #values, if target then " (target " .. FirstHour.format(target) .. ")" else ""))
	end
	return table.concat(lines, "\n")
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "firsthour",
		category = "World",
		description = "New-player milestones against the first-hour targets: this server's medians, or one player",
		args = { { name = "player", type = "player", optional = true } },
		handler = function(_ctx: any, a: any)
			return if a.player then reportOne(a.player) else reportServer()
		end,
	})
	admin:Register({
		name = "firsthoursim",
		category = "World",
		description = "Simulate a new player's first hour per domain and gift tier (prints to the Output)",
		args = { { name = "minutes", type = "number", min = 5, max = 60, default = 60 } },
		handler = function(_ctx: any, a: any)
			task.spawn(function()
				-- Only needed here, so a live server never loads it unless asked.
				require(Server.Tests.FirstHourSim).report(math.floor(a.minutes))
			end)
			return "running; the table prints to the Output"
		end,
	})
end

function FirstHourService.init(_self: any, ctx: any)
	log = ctx.log
	playerData = ctx.get("PlayerDataService")
	registerAdmin(ctx.get("AdminService"))
	ctx.bus:subscribe(Topics.PlayerDataLoaded, onLoaded)
	ctx.bus:subscribe(Topics.SpellResolved, onResolved)
	ctx.bus:subscribe(Topics.TargetDamaged, onDamaged)
	ctx.bus:subscribe(Topics.QuestEnded, onQuestEnded)
	Players.PlayerRemoving:Connect(function(player)
		rowOf[player] = nil
		lastAction[player] = nil
	end)
end

function FirstHourService.start(_self: any, _ctx: any) end

return FirstHourService
