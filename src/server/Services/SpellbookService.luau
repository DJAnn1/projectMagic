--!strict
--[[
	SpellbookService: players save recipes to their spellbook and give them their own names.

	Text safety (Roblox policy):
	- The RAW name is stored in the player's save, which never leaves the server.
	- Clients only ever receive the FILTERED name: TextService:FilterStringAsync, then
	  GetNonChatStringForBroadcastAsync, which is safe to show to anyone. It's cached per
	  session and recomputed after every load, so changes to Roblox's filter rules apply.
	- If filtering fails on a live server, the custom name is hidden and the auto-generated
	  name is shown instead. (Unpublished Studio sessions can't filter, so Studio shows the raw name.)
	- Any future feature that shows a spell name to OTHER players (cast announcements,
	  shared spellbooks) must use SpellbookService:displayName(), never the raw field.

	Hotbar: data.hotbar maps slot "1".."10" to a recipe key in the spellbook. A spell sits in at
	most one slot (placing it again moves it), and removing a spell empties its slot.
	RequestSpellbook returns (spells, hotbar).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextService = game:GetService("TextService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local MagicCore = require(Shared.Magic.MagicCore)

local MAX_SPELLS = 100
local MAX_NAME_CHARS = 32
local HOTBAR_SLOTS = 10

export type SpellView = {
	key: string,
	name: string, -- filtered custom name, or the generated description
	custom: boolean,
	recipe: any,
	favorite: boolean,
	casts: number,
}

local SpellbookService = {
	name = "SpellbookService",
	dependencies = { "NetService", "PlayerDataService" },
}

local log: any = nil
local playerData: any = nil
local filteredNames: { [Player]: { [string]: string } } = {}

-- Trims, collapses whitespace, strips control characters. Nil if empty, too long or invalid UTF-8.
local function cleanName(raw: string): string?
	local text = string.gsub(raw, "%c", "")
	text = string.gsub(text, "%s+", " ")
	text = string.match(text, "^%s*(.-)%s*$") or ""
	local length = utf8.len(text)
	if not length or length == 0 or length > MAX_NAME_CHARS then
		return nil
	end
	return text
end

-- Filtered for display to everyone. Yields (web call). Nil if filtering is unavailable.
local function filterForBroadcast(player: Player, text: string): string?
	local ok, result = pcall(function()
		local filtered = TextService:FilterStringAsync(text, player.UserId, Enum.TextFilterContext.PublicChat)
		return filtered:GetNonChatStringForBroadcastAsync()
	end)
	if ok then
		return result
	end
	if RunService:IsStudio() then
		return text
	end
	log:throttled("filter:" .. player.UserId, 30, "Warn", "filter_failed", { userId = player.UserId, err = result })
	return nil
end

local function bookOf(player: Player): { [string]: any }?
	local state = playerData:get(player)
	return state and state.data.spellbook
end

local function hotbarOf(player: Player): { [string]: string? }?
	local state = playerData:get(player)
	return state and state.data.hotbar
end

-- Empties every slot holding `key`.
local function clearFromHotbar(hotbar: { [string]: string? }, key: string)
	for slot, slotKey in hotbar do
		if slotKey == key then
			hotbar[slot] = nil
		end
	end
end

--[[
	The name to show for a spell: the filtered custom name, or the generated description when
	there's no custom name (or it couldn't be filtered). May yield on first use per spell.
]]
function SpellbookService.displayName(_self: any, player: Player, key: string): string?
	local book = bookOf(player)
	local entry = book and book[key]
	if not entry then
		return nil
	end
	if entry.name ~= "" then
		local cache = filteredNames[player]
		if not cache then
			cache = {}
			filteredNames[player] = cache
		end
		if cache[key] == nil then
			cache[key] = filterForBroadcast(player, entry.name)
		end
		if cache[key] then
			return cache[key]
		end
	end
	return MagicCore.describe(entry.recipe)
end

local function viewOf(player: Player, key: string, entry: any): SpellView
	return {
		key = key,
		name = SpellbookService:displayName(player, key) or MagicCore.describe(entry.recipe),
		custom = entry.name ~= "",
		recipe = entry.recipe,
		favorite = entry.favorite,
		casts = entry.casts,
	}
end

-- Favourites first, then alphabetical by displayed name.
local function listFor(player: Player): { SpellView }
	local book = bookOf(player)
	if not book then
		return {}
	end
	local list: { SpellView } = {}
	for key, entry in book do
		table.insert(list, viewOf(player, key, entry))
	end
	table.sort(list, function(a, b)
		if a.favorite ~= b.favorite then
			return a.favorite
		end
		if a.name ~= b.name then
			return a.name < b.name
		end
		return a.key < b.key
	end)
	return list
end

-- Returns (true, filteredName) or (false, reason).
local function rename(player: Player, key: string, rawName: string): (boolean, string)
	local book = bookOf(player)
	local entry = book and book[key]
	if not entry then
		return false, "NO_SUCH_SPELL"
	end
	local clean = cleanName(rawName)
	if not clean then
		return false, "INVALID_NAME"
	end
	local filtered = filterForBroadcast(player, clean)
	if not filtered then
		return false, "FILTER_UNAVAILABLE"
	end
	entry.name = clean
	local cache = filteredNames[player] or {}
	filteredNames[player] = cache
	cache[key] = filtered
	return true, filtered
end

--[[
	Gives a player a spell the game made for them (Services/CantripService): validated like a save,
	named with game text (no player input, so nothing to filter beyond the usual display pass),
	and put in the first empty hotbar slot from `fromSlot` (default 1) if it isn't on the bar yet.
	Returns the recipe key, or nil (invalid, or the spellbook is full). The caller pushes
	SpellbookChanged.
]]
function SpellbookService.grant(_self: any, player: Player, recipe: any, name: string, fromSlot: number?): string?
	local state = playerData:get(player)
	if not state then
		return nil
	end
	local ok, _, normalized = MagicCore.validateRecipe(recipe, state.caster)
	if not ok or not normalized then
		return nil
	end
	local book = state.data.spellbook
	local key = MagicCore.recipeKey(normalized)
	if not book[key] then
		local count = 0
		for _ in book do
			count += 1
		end
		if count >= MAX_SPELLS then
			return nil
		end
		book[key] = { recipe = normalized, name = cleanName(name) or "", favorite = false, casts = 0, addedAt = os.time() }
		local cache = filteredNames[player]
		if cache then
			cache[key] = nil
		end
	end
	local hotbar = state.data.hotbar
	for _, slotKey in hotbar do
		if slotKey == key then
			return key -- already on the bar
		end
	end
	for slot = fromSlot or 1, HOTBAR_SLOTS do
		if hotbar[tostring(slot)] == nil then
			hotbar[tostring(slot)] = key
			break
		end
	end
	return key
end

-- The recipe key in a hotbar slot (1..10), if any.
function SpellbookService.hotbarKey(_self: any, player: Player, slot: number): string?
	local hotbar = hotbarOf(player)
	return hotbar and hotbar[tostring(slot)]
end

-- The saved (normalized) recipe for a spellbook key, if the player has it.
function SpellbookService.recipeOf(_self: any, player: Player, key: string): any?
	local book = bookOf(player)
	local entry = book and book[key]
	return entry and entry.recipe
end

function SpellbookService.init(_self: any, ctx: any)
	log = ctx.log
	playerData = ctx.get("PlayerDataService")

	Net.handle("RequestSpellbook", function(player: Player)
		return listFor(player), table.clone(hotbarOf(player) or {})
	end)

	-- Puts a spellbook entry in a slot (moving it if it was elsewhere), or empties the slot.
	Net.handle("SetHotbarSlot", function(player: Player, slot: number, key: string?)
		local book, hotbar = bookOf(player), hotbarOf(player)
		if not book or not hotbar then
			return false, "NOT_LOADED"
		end
		if slot > HOTBAR_SLOTS then
			return false, "BAD_SLOT"
		end
		if key then
			if not book[key] then
				return false, "NO_SUCH_SPELL"
			end
			clearFromHotbar(hotbar, key)
		end
		hotbar[tostring(slot)] = key
		return true, table.clone(hotbar)
	end)

	-- Saves a recipe the player can cast right now. Returns (true, key, displayName) or (false, reason).
	Net.handle("SaveSpell", function(player: Player, recipe: any, name: string?)
		local state = playerData:get(player)
		if not state then
			return false, "NOT_LOADED"
		end
		local ok, errors, normalized = MagicCore.validateRecipe(recipe, state.caster)
		if not ok or not normalized then
			return false, errors[1] and errors[1].code or "INVALID_RECIPE"
		end
		local book = state.data.spellbook
		local key = MagicCore.recipeKey(normalized)
		if not book[key] then
			local count = 0
			for _ in book do
				count += 1
			end
			if count >= MAX_SPELLS then
				return false, "SPELLBOOK_FULL"
			end
			book[key] = { recipe = normalized, name = "", favorite = false, casts = 0, addedAt = os.time() }
		end
		if name then
			local renamed, result = rename(player, key, name)
			if not renamed then
				return true, key, MagicCore.describe(normalized), result -- saved, but the name was refused
			end
		end
		return true, key, SpellbookService:displayName(player, key)
	end)

	Net.handle("RenameSpell", function(player: Player, key: string, name: string)
		return rename(player, key, name)
	end)

	Net.handle("RemoveSpell", function(player: Player, key: string)
		local book = bookOf(player)
		if not book or not book[key] then
			return false, "NO_SUCH_SPELL"
		end
		book[key] = nil
		local hotbar = hotbarOf(player)
		if hotbar then
			clearFromHotbar(hotbar, key)
		end
		local cache = filteredNames[player]
		if cache then
			cache[key] = nil
		end
		return true, key
	end)
end

function SpellbookService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		filteredNames[player] = nil
	end)
end

return SpellbookService
