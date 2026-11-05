--!strict
--[[
	ItemRules: the item system's tuning and fixed vocabularies, as data (docs/Items.md §3-5).

		categories      every item category: display name, glyph, grid filter group
		equipSlots      the 15 equipment slots, in paper-doll order, with the attachment (same names on R6 and R15)
		                their gear model hangs from
		inventory       grid size, quickslots, stack cap, log sizes
		encumbrance     carried weight / carry capacity -> movement and stamina penalties
		focus           the no-focus tradeoff at high power
		durability      how gear wears
		starterKit      what a brand-new inventory holds

	Ids are permanent (renames go through ItemDatabase.aliases).
]]

local ItemRules = {}

-- ─── Categories ─────────────────────────────────────────────────────────────
-- filter: the inventory's filter chip the category falls under.

ItemRules.categories = {
	weapon = { name = "Weapon", glyph = "⚔", filter = "gear" },
	focus = { name = "Focus", glyph = "✧", filter = "gear" },
	armor = { name = "Armor", glyph = "⛨", filter = "gear" },
	clothing = { name = "Clothing", glyph = "◫", filter = "gear" },
	jewelry = { name = "Jewelry", glyph = "◎", filter = "gear" },
	tool = { name = "Tool", glyph = "⚒", filter = "gear" },
	consumable = { name = "Consumable", glyph = "◉", filter = "use" },
	material = { name = "Material", glyph = "▣", filter = "materials" },
	reagent = { name = "Reagent", glyph = "✺", filter = "materials" },
	quest = { name = "Quest item", glyph = "§", filter = "other" },
	key = { name = "Key", glyph = "⚿", filter = "other" },
	book = { name = "Book", glyph = "▤", filter = "use" },
	furniture = { name = "Furniture", glyph = "⌂", filter = "other" },
	treasure = { name = "Treasure", glyph = "◈", filter = "other" },
	container = { name = "Container", glyph = "▢", filter = "gear" },
	artifact = { name = "Artifact", glyph = "✷", filter = "gear" },
}

ItemRules.filters = {
	{ id = "all", name = "All" },
	{ id = "gear", name = "Gear" },
	{ id = "use", name = "Use" },
	{ id = "materials", name = "Materials" },
	{ id = "other", name = "Other" },
}

-- ─── Equipment slots ────────────────────────────────────────────────────────
-- attach: the body attachment the generated model welds to (GearVisuals; R6 and R15 share these names).
-- side: paper-doll column ("left" | "right" | "bottom").

export type SlotDef = { id: string, name: string, glyph: string, attach: string?, side: string, order: number }

ItemRules.equipSlots = {
	{ id = "head", name = "Head", glyph = "◠", attach = "HatAttachment", side = "left", order = 1 },
	{ id = "amulet", name = "Amulet", glyph = "◎", attach = "NeckAttachment", side = "left", order = 2 },
	{ id = "cloak", name = "Cloak", glyph = "◜", attach = "BodyBackAttachment", side = "left", order = 3 },
	{ id = "chest", name = "Chest", glyph = "⛨", attach = "BodyFrontAttachment", side = "left", order = 4 },
	{ id = "belt", name = "Belt", glyph = "═", attach = "WaistCenterAttachment", side = "left", order = 5 },
	{ id = "legs", name = "Legs", glyph = "∏", attach = "WaistFrontAttachment", side = "left", order = 6 },
	{ id = "feet", name = "Feet", glyph = "▁", attach = nil, side = "left", order = 7 },
	{ id = "hands", name = "Hands", glyph = "✋", attach = nil, side = "right", order = 8 },
	{ id = "ring1", name = "Ring", glyph = "○", attach = nil, side = "right", order = 9 },
	{ id = "ring2", name = "Ring", glyph = "○", attach = nil, side = "right", order = 10 },
	{ id = "trinket", name = "Trinket", glyph = "✦", attach = "WaistBackAttachment", side = "right", order = 11 },
	{ id = "mainHand", name = "Main hand", glyph = "⚔", attach = "RightGripAttachment", side = "right", order = 12 },
	{ id = "offHand", name = "Off hand / focus", glyph = "✧", attach = "LeftGripAttachment", side = "right", order = 13 },
	{ id = "bag1", name = "Bag", glyph = "▢", attach = nil, side = "bottom", order = 14 },
	{ id = "bag2", name = "Bag", glyph = "▢", attach = nil, side = "bottom", order = 15 },
} :: { SlotDef }

ItemRules.slotById = {} :: { [string]: SlotDef }
for _, slot in ItemRules.equipSlots do
	ItemRules.slotById[slot.id] = slot
end

-- ─── Inventory ──────────────────────────────────────────────────────────────

ItemRules.inventory = {
	baseSlots = 24, -- grid slots without bags
	maxSlots = 72, -- hard ceiling, whatever bags say
	quickSlots = 4,
	maxStack = 999, -- no definition may stack higher
	auditKept = 30, -- recent operations saved with the player (support)
	memoryLog = 200, -- recent operations kept in server memory per player
	maxCurrency = 1e9,
	maxRare = 1e6,
}

-- Keyboard keys for the quickslots (spells own 1-8; G, C, J, I open screens).
ItemRules.quickKeys = { "Z", "X", "V", "B" }

-- ─── Encumbrance ────────────────────────────────────────────────────────────
-- ratio = carried weight / carry capacity. First matching row (ascending `upTo`) applies.

ItemRules.encumbrance = {
	{ id = "light", name = "Light", upTo = 0.75, moveSpeedPct = 0, staminaRegenPct = 0 },
	{ id = "burdened", name = "Burdened", upTo = 1.0, moveSpeedPct = -0.1, staminaRegenPct = -0.25 },
	{ id = "overloaded", name = "Overloaded", upTo = 1.5, moveSpeedPct = -0.35, staminaRegenPct = -0.6 },
	{ id = "immobile", name = "Crushed by weight", upTo = math.huge, moveSpeedPct = -0.6, staminaRegenPct = -1 },
}

-- ─── Foci (docs/Items.md §5) ────────────────────────────────────────────────
-- Casting without a matching focus is free at low power and costs more, and is less stable, at
-- high power. A major focus (held) matching the spell removes the penalty; a minor focus (ring,
-- amulet) or a held focus of the wrong domain halves it.

ItemRules.focus = {
	penaltyFromPower = 6, -- recipe power at which the bare-handed penalty starts
	costPerPower = 0.06, -- +6% reservoir cost per power from penaltyFromPower up (P10 = +30%)
	backfirePerPower = 0.02, -- +2% absolute backfire chance per power (P10 = +10%)
	instabilityPerPower = 0.05, -- extra instability (feeds overdraw risk display)
	partialShare = 0.5, -- minor or mismatched focus: this share of the penalty
}

-- ─── Durability ─────────────────────────────────────────────────────────────

ItemRules.durability = {
	armorHitShare = 0.05, -- a hit worth >= this share of max health wears one armor piece by 1
	focusPerCastPower = 7, -- a focus loses 1 point per this much recipe power cast (P7 = 1/cast)
	brokenValueMult = 0.25,
}

-- ─── Repair (Shared/Items/Repair) ──────────────────────────────────────────

-- At a station: the first `byTag` row whose tag the item carries says where it's mended and with
-- what; anything else goes to `fallback` (coins only). Costs scale with how worn it is:
--   coins     ceil(value x missingShare x coinShare), at least 1
--   material  ceil(missingShare x materialPerFull) items carrying the row's material tag, at least 1
-- A broken item repairs the same way (missing share 1).
ItemRules.repair = {
	coinShare = 0.3,
	materialPerFull = 2,
	byTag = {
		{ tag = "metal", station = "forge", material = "metal_ingot" },
		{ tag = "glass", station = "forge", material = "gem" },
		{ tag = "leather", station = "workbench", material = "hide" },
		{ tag = "bone", station = "workbench", material = nil },
		{ tag = "wood", station = "workbench", material = "plank" },
		{ tag = "cloth", station = "loom", material = "cloth" },
		{ tag = "paper", station = "workbench", material = "paper" },
	},
	fallback = { station = "workbench", material = nil },
}

-- Magic mending (InventoryAction "mend"): Earth magic knits metal, stone and glass back together.
-- The caster's tier in `branch` (or the Earth root) sets how much of the item's max durability one
-- mend restores; Metallurgy counts `metallurgyBonus` tiers higher. Costs reservoir:
--   reservoirBase + reservoirPerPoint x points restored
ItemRules.mend = {
	tags = { "metal", "glass", "stone", "gem" },
	domainBranch = "earth",
	metallurgy = "metallurgy",
	metallurgyBonus = 1,
	minTier = 2, -- Novice
	shareByTier = { [2] = 0.25, [3] = 0.4, [4] = 0.6, [5] = 0.8, [6] = 1 }, -- Expert+ = 0.8, Master+ = full
	reservoirBase = 3,
	reservoirPerPoint = 0.15,
	cooldown = 2,
}

-- ─── Stats ──────────────────────────────────────────────────────────────────

ItemRules.masteryHealthPerTier = 5 -- +health per tier of your best branch (Expert = +25)

-- ─── Starter kit (a brand-new inventory) ───────────────────────────────────

ItemRules.starterKit = {
	{ id = "bread_loaf", n = 3 },
	{ id = "healing_draught", n = 2 },
	{ id = "torch", n = 1 },
	{ id = "traveler_boots", n = 1 },
	{ id = "small_pouch", n = 1 },
}
ItemRules.starterCurrency = 25

return ItemRules
