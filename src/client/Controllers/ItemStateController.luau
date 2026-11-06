--!strict
--[[
	ItemStateController: the client's item data (docs/Items.md §7). The inventory screen, the
	quickbar and future windows (containers, crafting, trade, shops) bind to these Values;
	only this controller talks to the item remotes.

	Values
		view    InventoryView?   RequestInventory once, then every InventoryChanged push
		sheet   stat sheet?      RequestStatSheet, on demand (fetchSheet), refetched after changes
		                         while someone is watching it (sheetWanted)
	Methods
		action(op, a?, b?, n?, aim?) -> (ok, reason?)   InventoryAction; failures become a toast
		find(ref) -> ItemView?          locate a place in the current view
		quickRef(key) -> ItemView?, number   what a quickslot points at, and how many you have
		reasonText(reason) -> string     player-facing words for a refusal code

	Gains (an item's total count going up between two views) become "+3 Iron Ore" toasts through
	MagicStateController's events, so loot, quest rewards and admin gives all announce themselves.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local ItemTypes = require(Shared.Items.ItemTypes)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)

type ItemView = ItemTypes.ItemView
type InventoryView = ItemTypes.InventoryView

local ItemStateController = {
	name = "ItemStateController",
	dependencies = { "MagicStateController" },
}

local S = ItemStateController
S.view = Kit.value(nil :: InventoryView?)
S.sheet = Kit.value(nil :: any)
S.sheetWanted = false

local magic: any = nil
local lastCounts: { [string]: number }? = nil
local sheetPending = false

local REASONS: { [string]: string } = {
	NOT_LOADED = "Your things are still being unpacked.",
	DISABLED = "Inventory changes are paused right now.",
	EMPTY = "There's nothing there.",
	BAD_REF = "That isn't a place for items.",
	NO_ROOM = "No room in your bags.",
	NO_SLOT = "That slot doesn't exist with your current bags.",
	BAG_NOT_EMPTY = "Empty that bag's slots first.",
	TWO_HANDED = "That needs both hands: free the off hand first.",
	WRONG_SLOT = "That doesn't go there.",
	NOT_EQUIPPABLE = "You can't wear or hold that.",
	NOT_USABLE = "That can't be used.",
	SPLIT_TARGET = "Split a stack onto an empty slot or the same item.",
	LOCKED = "That item is locked. Unlock it first.",
	QUEST_ITEM = "That belongs to a quest; you can't throw it away.",
	COOLDOWN = "Not yet.",
	NEEDS_AIM = "Aim it at something first.",
	ALREADY_BORROWING = "You're already holding borrowed power.",
	FULL_HEALTH = "You're already at full health.",
	RESERVOIR_FULL = "Your reservoir is already full.",
	NOTHING_TO_REPAIR = "Nothing you're wearing needs repair.",
	NOTHING_TO_CLEANSE = "There's nothing to cure.",
	ALREADY_STUDIED = "You've already learned what this teaches.",
	ON_COOLDOWN = "Not yet.",
	NOTHING_TO_DO = "That wouldn't do anything right now.",
	RATE_LIMITED = "Slow down a little.",
	-- Containers and crafting (ContainerService, CraftingService)
	TOO_FAR = "You're too far away.",
	NOT_OPEN = "That isn't open any more.",
	CONTAINER_FULL = "There's no room left in there.",
	MISSING_INGREDIENTS = "You don't have everything this needs.",
	STATION_TIER = "This station isn't good enough for that.",
	WRONG_STATION = "That can't be made here.",
	UNKNOWN = "That doesn't exist any more.",
	FIRE_OUT = "Light the fire first (F at the fireplace).",
	-- Housing
	NO_HOUSE = "You don't own a house.",
	NOT_HOME = "Stand inside your house to place furniture.",
	NOT_FURNITURE = "That isn't furniture.",
	DECOR_FULL = "Your house can't hold any more furniture.",
	OUTSIDE = "That doesn't fit there.",
	ERROR = "Something went wrong; nothing was changed.",
	-- Scroll casts refused by CastService
	OUT_OF_RANGE = "The scroll's spell can't reach that far.",
	NO_LINE_OF_SIGHT = "The scroll's spell needs a clear line.",
	INSUFFICIENT_RESERVOIR = "You don't have the reservoir to read it.",
	BUSY = "You're already casting.",
	SILENCED = "You can't speak the words right now.",
	-- Repair (CraftingService) and magic mending (InventoryService "mend")
	NOT_DAMAGED = "That isn't worn at all.",
	NOT_ENOUGH_COINS = "You can't pay for that repair.",
	MISSING_MATERIALS = "You don't have the materials for that repair.",
	MEND_UNSKILLED = "Mending needs Novice in Earth (or Metallurgy).",
	CANT_MEND = "Earth magic can only mend metal, stone and glass.",
	TOO_FAST = "Slow down a little.",
}

function S.reasonText(_self: any, reason: string?): string
	if not reason then
		return "That didn't work."
	end
	local req = string.match(reason, "^REQUIREMENTS: (.*)$")
	if req then
		return "You can't use that yet: " .. (if req ~= "" then req else "requirements not met") .. "."
	end
	return REASONS[reason] or ("That didn't work (" .. string.lower(reason) .. ").")
end

local function countsOf(view: InventoryView): { [string]: number }
	local counts: { [string]: number } = {}
	for _, item in view.items do
		counts[item.rec.i] = (counts[item.rec.i] or 0) + ItemInstance.count(item.rec)
	end
	return counts
end

-- "+3 Iron Ore" toasts for every item whose total (grid and body together, so equipping and
-- unequipping never count) went up between two views.
local function announceGains(view: InventoryView)
	local counts = countsOf(view)
	local before = lastCounts
	lastCounts = counts
	if not before then
		return
	end
	for id, n in counts do
		local gained = n - (before[id] or 0)
		if gained > 0 then
			local def = ItemDatabase.get(id)
			magic.events:Fire({ kind = "notify", text = string.format("+%d %s", gained, if def then def.name else id) })
		end
	end
end

function S.fetchSheet(_self: any)
	if sheetPending then
		return
	end
	sheetPending = true
	task.spawn(function()
		local ok, sheet = Net.invoke("RequestStatSheet")
		sheetPending = false
		if ok and typeof(sheet) == "table" then
			S.sheet:set(sheet)
		end
	end)
end

local function setView(view: any)
	if typeof(view) ~= "table" or typeof(view.items) ~= "table" then
		return
	end
	local current = S.view:get()
	if current and typeof(view.rev) == "number" and view.rev < current.rev then
		return -- an older answer arriving after a newer push
	end
	announceGains(view)
	S.view:set(view)
	if S.sheetWanted then
		S:fetchSheet()
	end
end

function S.action(_self: any, op: string, a: string?, b: string?, n: number?, aim: Vector3?): (boolean, string?)
	local ok, result = Net.invoke("InventoryAction", op, a, b, n, aim)
	if not ok then
		magic.events:Fire({ kind = "notify", text = S:reasonText(result) })
		return false, result
	end
	if typeof(result) ~= "table" then
		return false, "ERROR"
	end
	if not result.ok then
		magic.events:Fire({ kind = "notify", text = S:reasonText(result.reason) })
	end
	return result.ok == true, result.reason
end

function S.find(_self: any, ref: string): ItemView?
	local view = S.view:get()
	if not view then
		return nil
	end
	for _, item in view.items do
		if item.ref == ref then
			return item
		end
	end
	return nil
end

-- The record a quickslot points at (first stack of the item, or the unique) and the total count.
function S.quickRef(_self: any, key: string): (ItemView?, number)
	local view = S.view:get()
	local bind = view and view.quick[key]
	if not view or not bind then
		return nil, 0
	end
	local kind, value = string.sub(bind, 1, 1), string.sub(bind, 3)
	local first: ItemView? = nil
	local firstSlot = math.huge
	local total = 0
	for _, item in view.items do
		local match = if kind == "u" then item.rec.u == value else (item.rec.i == value and string.sub(item.ref, 1, 1) == "s")
		if match then
			total += ItemInstance.count(item.rec)
			local n = tonumber(string.sub(item.ref, 2)) or 0
			if kind == "u" or n < firstSlot then
				first, firstSlot = item, n
			end
		end
	end
	return first, total
end

-- The item id a quickslot is bound to, even when you have none left (to draw it greyed out).
function S.quickItemId(_self: any, key: string): string?
	local view = S.view:get()
	local bind = view and view.quick[key]
	if not bind then
		return nil
	end
	if string.sub(bind, 1, 1) == "i" then
		return string.sub(bind, 3)
	end
	local item = S:quickRef(key)
	return item and item.rec.i
end

function ItemStateController.init(_self: any, ctx: any)
	magic = ctx.get("MagicStateController")
end

function ItemStateController.start(_self: any, _ctx: any)
	Net.listen("InventoryChanged", setView)
	for _ = 1, 20 do
		local ok, view = Net.invoke("RequestInventory")
		if ok and typeof(view) == "table" then
			setView(view)
			return
		end
		task.wait(2)
	end
end

return ItemStateController
