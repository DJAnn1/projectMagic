--!strict
--[[
	JournalService: the player-facing log (docs/UI.md §4.7, docs/Quests.md §6).

	Stores PlayerData.journal = { log = { { t, kind, text, questId?, at? } } (newest last, capped),
	revealed = { [factionId] = unix } }. Other services write through it and register the tabs
	they own; it serves them to the client.

		log(player, kind, text, extra?)     appends an entry and pushes JournalChanged to the client
		                                    (the HUD toasts it). kinds: quest, outcome, reputation,
		                                    rumor, crime, faction, discovery
		setTab(tab, provider(player, page) -> payload)   QuestDirector: "quests"; ReputationService:
		                                    "factions"; this service: "log"
		reveal(player, factionId) / isRevealed(player, factionId)   secret factions you know about

	Remotes: RequestJournal(tab, page) -> payload (0.5/s, 20 entries per page);
	JournalChanged (server -> client) { kind, text, questId? }.
	Texts are server-authored (quest templates, NPC names, filtered spell names), never raw input.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)

local LOG_CAP = 200
local PAGE = 20

local JournalService = {
	name = "JournalService",
	dependencies = { "NetService", "PlayerDataService" },
}

local playerData: any = nil
local tabs: { [string]: (Player, number) -> any } = {}

local function journalOf(player: Player): any?
	local state = playerData:get(player)
	if not state then
		return nil
	end
	local j = state.data.journal
	if typeof(j) ~= "table" then
		j = { log = {}, revealed = {} }
		state.data.journal = j
	end
	j.log = j.log or {}
	j.revealed = j.revealed or {}
	return j
end

function JournalService.log(_self: any, player: Player, kind: string, text: string, extra: { [string]: any }?)
	local j = journalOf(player)
	if not j then
		return
	end
	local entry: { [string]: any } = { t = os.time(), kind = kind, text = text }
	for k, v in (extra or {}) :: { [string]: any } do
		entry[k] = v
	end
	table.insert(j.log, entry)
	while #j.log > LOG_CAP do
		table.remove(j.log, 1)
	end
	Net.fire("JournalChanged", player, { kind = kind, text = text, questId = entry.questId })
end

function JournalService.setTab(_self: any, tab: string, provider: (Player, number) -> any)
	tabs[tab] = provider
end

function JournalService.reveal(self: any, player: Player, factionId: string, name: string?): boolean
	local j = journalOf(player)
	if not j or j.revealed[factionId] then
		return false
	end
	j.revealed[factionId] = os.time()
	if name then
		self:log(player, "faction", "You've learned of " .. name .. ".")
	end
	return true
end

function JournalService.isRevealed(_self: any, player: Player, factionId: string): boolean
	local j = journalOf(player)
	return j ~= nil and j.revealed[factionId] ~= nil
end

local function logPage(player: Player, page: number): any
	local j = journalOf(player)
	if not j then
		return { entries = {}, pages = 0 }
	end
	local total = #j.log
	local pages = math.max(1, math.ceil(total / PAGE))
	local p = math.clamp(page, 1, pages)
	local entries = {}
	-- Newest first.
	local first = total - (p - 1) * PAGE
	for i = first, math.max(1, first - PAGE + 1), -1 do
		local e = j.log[i]
		table.insert(entries, { t = e.t, kind = e.kind, text = e.text, questId = e.questId })
	end
	return { entries = entries, page = p, pages = pages }
end

function JournalService.init(_self: any, ctx: any)
	playerData = ctx.get("PlayerDataService")
	tabs.log = logPage
	Net.handle("RequestJournal", function(player: Player, tab: string, page: number)
		local provider = tabs[tab]
		if not provider or not playerData:get(player) then
			return { ok = false }
		end
		local ok, payload = pcall(provider, player, page)
		if not ok then
			return { ok = false }
		end
		return { ok = true, tab = tab, data = payload }
	end)
end

function JournalService.start(_self: any, _ctx: any) end

return JournalService
