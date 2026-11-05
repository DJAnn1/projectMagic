--!strict
--[[
	Gear: what NPCs wear and the resistances it gives (Cast/Resistances reads them).

	The garments themselves are items (Shared/Items/Data/Items, tag "npc_gear"): one definition for
	players and NPCs. This module maps them onto the four NPC gear slots and lists what each
	occupation wears. NPCs have no inventory yet, so their gear is set per character through
	Resistances.setGear, which writes a Humanoid attribute "Gear_<slot>" = item id. Players never
	use this path: their equipped items reach Resistances through InventoryService (the "items"
	source).

	Sources today: NPC occupations (`byOccupation`), and the admin command
	`gear <player> <slot> <item|none>` (a quick test outside the inventory).
]]

local ItemDatabase = require(game:GetService("ReplicatedStorage").Shared.Items.ItemDatabase)

export type Item = {
	name: string,
	slot: string, -- "body" | "head" | "hands" | "charm"
	resist: { [string]: number },
	description: string,
}

-- Item equipment slot -> NPC gear slot.
local SLOT_MAP: { [string]: string } = {
	chest = "body", cloak = "body", head = "head", hands = "hands",
	trinket = "charm", ring1 = "charm", amulet = "charm",
}

local items: { [string]: Item } = {}
for _, id in ItemDatabase.withTag("npc_gear") do
	local def = ItemDatabase.get(id)
	local equip = def and def.equip
	local slot = equip and SLOT_MAP[equip.slots[1]]
	assert(def and equip and slot, "Gear: npc_gear item " .. id .. " has no NPC slot")
	items[id] = { name = def.name, slot = slot, resist = table.clone(equip.resist or {}), description = def.description }
end

-- What each occupation wears (NPCs get these when their rig is dressed).
local byOccupation: { [string]: { string } } = {
	smith = { "leather_apron", "rubber_gloves" },
	miner = { "miner_helm", "padded_robe" },
	builder = { "padded_robe" },
	guard = { "chain_mail" },
	fisher = { "oilskin" },
	tidepriest = { "oilskin", "spirit_beads" },
	herbalist = { "herb_charm" },
	healer = { "herb_charm", "spirit_beads" },
	scholar = { "focus_ring" },
	hunter = { "padded_robe" },
}
for occupation, list in byOccupation do
	for _, id in list do
		assert(items[id], "Gear: " .. occupation .. " wears unknown gear " .. id)
	end
end

return table.freeze({
	items = items,
	byOccupation = byOccupation,
	slots = { "body", "head", "hands", "charm" },
})
