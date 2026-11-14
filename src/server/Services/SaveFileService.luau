--!strict
--[[
	SaveFileService: the main menu's server side (docs/SaveFiles.md; owner, 2026-11-13: "add a
	file select, main menu, and a reset character option"). Owner's choices: 3 files per player,
	each file its own character with its own seeded innate magic, and Reset wipes a file's
	progress but keeps its magic.

	Nothing loads on join any more: the client's main menu (src/client/Menu/MainMenu) shows the
	files and asks for one.
		FileList()              -> { last, files = { [1..3] = summary? } }   what the menu shows
		FileChoose(slot)        -> (ok, reason?)   loads that file (PlayerDataService:loadFile);
		                                           characters spawn once it's loaded (WorldStateService)
		FileReset(slot, "RESET")-> (ok, reason?)   wipes a file that isn't loaded; its next load
		                                           regenerates the same innate magic from its seed
		FileReturn              leave for the menu: a rejoin (TeleportAsync to this place) on live
		                        servers; in Studio, the session ends (no teleports there)

	FILES: file 1 is the original save key ("player_<id>") and profile seed ("player:<id>"), so
	everyone's existing character is their File 1. Files 2 and 3 are "player_<id>_f<n>" and
	"player:<id>#f<n>" (PlayerDataService). All keys go through WorldService:progressKey, so a
	progress reset covers every file; DataService.eraseUser erases every file and the account.

	THE ACCOUNT RECORD (Schemas.Account, "account_<id>"): a small summary per file (created, last
	played, playtime, spells, best branch), so the menu never opens or locks the files themselves.
	Written when a file loads and when its player leaves.

	Known limits: a house belongs to the account, not the file (resetting the file that bought it
	releases it); other world records keyed by the account (Titan falls, world-firsts) stay with it.
	Log: file_listed, file_chosen, file_reset, file_return.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TeleportService = game:GetService("TeleportService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Schemas = require(ServerScriptService.Server.Persistence.Schemas)

local SaveFileService = {
	name = "SaveFileService",
	dependencies = { "DataService", "WorldService", "PlayerDataService", "HousingService" },
}

local FILES = 3
local RESET_WORD = "RESET"

local log: any = nil
local world: any = nil
local playerData: any = nil
local housing: any = nil
local accounts: any = nil
local legacy: any = nil -- the Player store, read-only, for File 1 of players from before save files
local busy: { [Player]: boolean } = {}

export type Summary = {
	created: number,
	lastPlayed: number,
	playtime: number,
	spells: number,
	best: string, -- branch id with the highest mastery ("" when none)
	bestMastery: number,
	resets: number,
}

local function accountKey(userId: number): string
	return world:progressKey("account_" .. userId)
end

-- What the menu shows about a loaded file's data.
local function summarize(data: any, previous: Summary?): Summary
	local best, bestMastery = "", 0
	for branch, mastery in (data.progression and data.progression.mastery or {}) :: { [string]: number } do
		if typeof(mastery) == "number" and mastery > bestMastery then
			best, bestMastery = branch, mastery
		end
	end
	local spells = 0
	for _ in (data.spellbook or {}) :: { [string]: any } do
		spells += 1
	end
	local stats = data.stats or {}
	return {
		created = (previous and previous.created) or stats.firstJoin or os.time(),
		lastPlayed = os.time(),
		playtime = stats.playtime or 0,
		spells = spells,
		best = best,
		bestMastery = math.floor(bestMastery),
		resets = (previous and previous.resets) or 0,
	}
end

local function writeSummary(userId: number, slot: number, summary: Summary?, last: boolean)
	local _, err = accounts:update(accountKey(userId), function(account: any): any
		account.files[tostring(slot)] = summary
		if last then
			account.last = slot
		end
		return account
	end, { userIds = { userId } })
	if err then
		log:warn("account_write_failed", { userId = userId, file = slot, reason = err })
	end
end

local function list(player: Player): any
	local account, err = accounts:read(accountKey(player.UserId))
	if not account then
		return { ok = false, reason = err or "DATASTORE_ERROR" }
	end
	local files: { [number]: any } = {}
	for slot = 1, FILES do
		files[slot] = account.files[tostring(slot)] or false
	end
	-- No account record yet (everyone who played before save files): File 1 may hold their
	-- existing character under the original key. Say so; the summary fills in on its first load.
	if account.last == 0 and next(account.files) == nil then
		local old = legacy:read(playerData:fileKey(player.UserId, 1)) -- read only: no lock taken
		if old and old.profile ~= nil then
			local summary = summarize(old, nil)
			summary.lastPlayed = (old.stats and old.stats.lastJoin) or 0
			files[1] = summary
		end
	end
	log:info("file_listed", { userId = player.UserId, last = account.last })
	return { ok = true, last = account.last, files = files }
end

local function choose(player: Player, slot: number): (boolean, string?)
	if busy[player] then
		return false, "BUSY"
	end
	if playerData:get(player) then
		return false, "ALREADY_PLAYING"
	end
	busy[player] = true
	local ok, reason = playerData:loadFile(player, slot)
	busy[player] = nil
	if ok then
		local state = playerData:get(player)
		local account = accounts:read(accountKey(player.UserId))
		local previous = account and account.files[tostring(slot)] or nil
		if state then
			writeSummary(player.UserId, slot, summarize(state.data, previous), true)
		end
		log:info("file_chosen", { userId = player.UserId, file = slot })
	end
	return ok, reason
end

local function reset(player: Player, slot: number, word: string): (boolean, string?)
	if word ~= RESET_WORD then
		return false, "CONFIRM"
	end
	if busy[player] then
		return false, "BUSY"
	end
	local playing = playerData:get(player)
	if playing then
		return false, "IN_GAME" -- reset from the main menu only, with no file open
	end
	busy[player] = true
	local store = playerData:sessionStore()
	local session, err = store:load(playerData:fileKey(player.UserId, slot), { userIds = { player.UserId } })
	if not session then
		busy[player] = nil
		return false, err or "DATASTORE_ERROR"
	end
	-- The house this file bought goes back on the market (houses are claimed per account).
	local lot = session.data.housing and session.data.housing.lot or ""
	if typeof(lot) == "string" and lot ~= "" then
		pcall(housing.releaseClaim, housing, player.UserId, lot)
	end
	-- Everything goes back to a fresh save. The profile is left out, so the next load regenerates
	-- the same innate magic from this file's seed (owner: "wipe, same magic").
	local fresh = Schemas.Player.template()
	for key in table.clone(session.data) do
		session.data[key] = nil
	end
	for key, value in fresh do
		session.data[key] = value
	end
	local saved = session:save() -- keeps the lock; release() below writes once more and unlocks
	session:release()
	busy[player] = nil
	if not saved then
		return false, "DATASTORE_ERROR"
	end
	writeSummary(player.UserId, slot, nil, false)
	log:info("file_reset", { userId = player.UserId, file = slot, released = lot ~= "" })
	return true, nil
end

local function returnToMenu(player: Player)
	log:info("file_return", { userId = player.UserId, file = player:GetAttribute("SaveFile") })
	if RunService:IsStudio() then
		-- No teleports in Studio: end the session; press Play again to see the menu.
		player:Kick("Returning to the main menu. In Studio, press Play again to choose a file.")
		return
	end
	local ok, err = pcall(function()
		TeleportService:TeleportAsync(game.PlaceId, { player })
	end)
	if not ok then
		log:warn("file_return_failed", { userId = player.UserId, reason = tostring(err) })
		player:Kick("Returning to the main menu: rejoin to choose a file.")
	end
end

function SaveFileService.init(_self: any, ctx: any)
	log = ctx.log
	world = ctx.get("WorldService")
	playerData = ctx.get("PlayerDataService")
	housing = ctx.get("HousingService")
	accounts = ctx.get("DataService"):openStore(Schemas.Account)
	legacy = ctx.get("DataService"):openStore(Schemas.Player)

	Net.handle("FileList", function(player: Player)
		return list(player)
	end)
	Net.handle("FileChoose", function(player: Player, slot: number)
		return choose(player, slot)
	end)
	Net.handle("FileReset", function(player: Player, slot: number, word: string)
		return reset(player, slot, word)
	end)
	Net.on("FileReturn", function(player: Player)
		returnToMenu(player)
	end)

	-- On leaving, the file's summary catches up (playtime, spells, best branch). Connected in init,
	-- so it runs before PlayerDataService (connected in start) releases the session.
	Players.PlayerRemoving:Connect(function(player: Player)
		busy[player] = nil
		local state = playerData:get(player)
		local slot = player:GetAttribute("SaveFile")
		if state and typeof(slot) == "number" then
			local data = state.data
			local summary = summarize(data, nil)
			summary.playtime = (data.stats.playtime or 0) + (os.time() - state.joinedAt)
			task.spawn(function()
				local account = accounts:read(accountKey(player.UserId))
				local previous = account and account.files[tostring(slot)] or nil
				if previous then
					summary.created, summary.resets = previous.created, previous.resets
				end
				writeSummary(player.UserId, slot, summary, true)
			end)
		end
	end)
end

function SaveFileService.start(_self: any, _ctx: any) end

return SaveFileService
