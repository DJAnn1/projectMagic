--!strict
--[[
	Repair: what mending an item costs, at a station or by magic (docs/Items.md §11). Pure and
	shared, so the Crafting screen and the Inventory's "Mend" button show the same numbers the
	server charges (Services/CraftingService, Services/InventoryService).

		Repair.missing(rec) -> (points, share)          durability missing (0, 0 when undamaged)
		Repair.quote(rec) -> Quote?                     at a station; nil when it can't wear or is full
		Repair.mendTier(earthTier, metallurgyTier) -> number
		Repair.mendQuote(rec, tier) -> MendQuote?       by Earth magic; nil when not allowed
]]

local ItemTypes = require(script.Parent.ItemTypes)
local ItemDatabase = require(script.Parent.ItemDatabase)
local ItemInstance = require(script.Parent.ItemInstance)
local ItemRules = require(script.Parent.Data.ItemRules)

type Record = ItemTypes.Record

export type Quote = {
	station: string, -- the station id that can mend it
	coins: number,
	material: string?, -- item tag
	materialCount: number,
	points: number, -- durability restored (to full)
}

export type MendQuote = {
	points: number, -- durability restored by one mend
	reservoir: number,
}

local Repair = {}

function Repair.missing(rec: Record): (number, number)
	local max = ItemInstance.maxDurability(rec)
	if not max then
		return 0, 0
	end
	local points = max - (ItemInstance.durability(rec) :: number)
	return points, points / max
end

local function rowFor(def: ItemTypes.ItemDef): { station: string, material: string? }
	for _, row in ItemRules.repair.byTag do
		if table.find(def.tags, row.tag) then
			return row
		end
	end
	return ItemRules.repair.fallback
end

function Repair.quote(rec: Record): Quote?
	local def = ItemDatabase.get(rec.i)
	local points, share = Repair.missing(rec)
	if not def or points <= 0 then
		return nil
	end
	local R = ItemRules.repair
	local row = rowFor(def)
	return {
		station = row.station,
		coins = math.max(1, math.ceil(def.value * share * R.coinShare)),
		material = row.material,
		materialCount = if row.material then math.max(1, math.ceil(share * R.materialPerFull)) else 0,
		points = points,
	}
end

-- The tier that counts for mending: the Earth root, or Metallurgy plus its bonus.
function Repair.mendTier(earthTier: number, metallurgyTier: number): number
	local M = ItemRules.mend
	local metal = if metallurgyTier > 0 then metallurgyTier + M.metallurgyBonus else 0
	return math.max(earthTier, metal)
end

function Repair.mendQuote(rec: Record, tier: number): MendQuote?
	local M = ItemRules.mend
	local def = ItemDatabase.get(rec.i)
	local points = Repair.missing(rec)
	if not def or points <= 0 or tier < M.minTier then
		return nil
	end
	local mendable = false
	for _, tag in M.tags do
		if table.find(def.tags, tag) then
			mendable = true
			break
		end
	end
	if not mendable then
		return nil
	end
	local share = 0
	for t, s in M.shareByTier do
		if tier >= t and s > share then
			share = s
		end
	end
	local max = ItemInstance.maxDurability(rec) :: number
	local restored = math.min(points, math.max(1, math.floor(max * share + 0.5)))
	return { points = restored, reservoir = M.reservoirBase + M.reservoirPerPoint * restored }
end

return Repair
