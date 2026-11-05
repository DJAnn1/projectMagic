--!strict
--[[
	Items: every item definition (docs/Items.md §2). Pure data; ItemDatabase validates it at boot.

	One entry per item id. `item{}` fills the defaults below, so an entry lists only what matters:
		rarity "common", stack 1, weight 1, value 1, icon "" (generated glyph icon), tags {}
	Field reference: Shared/Items/ItemTypes (ItemDef). Stat ids: Data/StatDefs. Resistance keys:
	a domain id, a property id, or "all" (Cast/Resistances). Affix classes: Data/Affixes.

	Starter content: 50 items over every category, sized for the Energy + Earth vertical slice.
	The nine occupation garments NPCs wear (Server/Magic/Data/Gear) are defined HERE, so players
	and NPCs share one definition (leather_apron, chain_mail, oilskin, padded_robe, rubber_gloves,
	miner_helm, herb_charm, spirit_beads, focus_ring).
]]

local ItemTypes = require(script.Parent.Parent.ItemTypes)

type ItemDef = ItemTypes.ItemDef

local rgb = Color3.fromRGB
local M = Enum.Material

local list: { ItemDef } = {}

local function item(def: { [string]: any })
	def.rarity = def.rarity or "common"
	def.stack = def.stack or 1
	def.weight = def.weight or 1
	def.value = def.value or 1
	def.icon = def.icon or ""
	def.tags = def.tags or {}
	table.insert(list, def :: any)
end

local HANDS = { "mainHand", "offHand" }
local RINGS = { "ring1", "ring2" }
local BAGS = { "bag1", "bag2" }

-- ─── Weapons ────────────────────────────────────────────────────────────────

item({
	id = "iron_sword", name = "Iron Sword", category = "weapon", glyph = "⚔", color = rgb(170, 170, 178),
	description = "A plain, honest blade. Balanced for a beginner's arm.",
	weight = 4, value = 40, tags = { "metal", "blade", "melee" },
	equip = { slots = { "mainHand" }, stats = { attackPower = 8 }, durability = 120, affixClass = "weapon" },
	weapon = { kind = "sword", damage = 12, damageType = "momentum", speed = 1.4, reach = 6, stamina = 8 },
	model = { shape = "sword", color = rgb(170, 170, 178), material = M.Metal },
})
item({
	id = "hunting_spear", name = "Hunting Spear", category = "weapon", glyph = "↟", color = rgb(150, 115, 80),
	description = "Ash shaft, iron head. Keeps boar and worse at arm's length.",
	weight = 5, value = 35, tags = { "wood", "metal", "polearm", "melee" },
	equip = { slots = { "mainHand" }, twoHanded = true, stats = { attackPower = 10 }, durability = 100, affixClass = "weapon" },
	weapon = { kind = "spear", damage = 14, damageType = "momentum", speed = 1.0, reach = 9, stamina = 10 },
	model = { shape = "spear", color = rgb(150, 115, 80), material = M.Wood },
})
item({
	id = "bone_dagger", name = "Bone Dagger", category = "weapon", glyph = "†", color = rgb(225, 215, 190),
	description = "Carved from a hornback's shin. Quick and quiet.",
	weight = 1, value = 18, tags = { "bone", "blade", "melee" },
	equip = { slots = HANDS, stats = { attackPower = 4, attackSpeedPct = 0.15 }, durability = 70, affixClass = "weapon" },
	weapon = { kind = "dagger", damage = 6, damageType = "momentum", speed = 2.2, reach = 4, stamina = 4 },
	model = { shape = "dagger", color = rgb(225, 215, 190), material = M.SmoothPlastic },
})
item({
	id = "woodsman_axe", name = "Woodsman's Axe", category = "weapon", glyph = "⚒", color = rgb(130, 95, 60),
	description = "Fells trees and, in a pinch, whatever is coming out of them.",
	weight = 5, value = 30, tags = { "metal", "wood", "axe", "melee", "tool_chop" },
	equip = { slots = { "mainHand" }, stats = { attackPower = 9 }, durability = 110, affixClass = "weapon" },
	weapon = { kind = "axe", damage = 15, damageType = "momentum", speed = 0.9, reach = 6, stamina = 12 },
	model = { shape = "axe", color = rgb(130, 95, 60), material = M.Wood },
	data = { toolTier = 1, harvest = "chop" },
})
item({
	id = "ash_shortbow", name = "Ash Shortbow", category = "weapon", glyph = "➶", color = rgb(160, 120, 75),
	description = "Light enough to draw on the run.",
	weight = 2, value = 38, tags = { "wood", "ranged" },
	equip = { slots = { "mainHand" }, twoHanded = true, stats = { attackPower = 6 }, durability = 90, affixClass = "weapon" },
	weapon = { kind = "bow", damage = 10, damageType = "momentum", speed = 0.8, reach = 90, stamina = 6, ammo = "arrow" },
	model = { shape = "bow", color = rgb(160, 120, 75), material = M.Wood },
})
item({
	id = "light_crossbow", name = "Light Crossbow", category = "weapon", glyph = "⌖", color = rgb(125, 95, 65),
	description = "Slow to wind, but anyone can aim it. Hits hard and flies flat.",
	weight = 5, value = 60, tags = { "wood", "metal", "ranged" },
	equip = { slots = { "mainHand" }, twoHanded = true, stats = { attackPower = 8 }, durability = 110, affixClass = "weapon" },
	weapon = { kind = "crossbow", damage = 18, damageType = "momentum", speed = 0.5, reach = 110, stamina = 4, ammo = "bolt" },
	model = { shape = "crossbow", color = rgb(125, 95, 65), material = M.Wood },
})
item({
	id = "knife_bandolier", name = "Knife Bandolier", category = "weapon", glyph = "⟋", color = rgb(120, 85, 55),
	description = "A strap of sheaths worn across the hand and wrist. Each throw spends one Throwing Knife.",
	weight = 1, value = 25, tags = { "leather", "ranged", "thrown" },
	equip = { slots = { "mainHand" }, stats = { attackSpeedPct = 0.05 }, durability = 90, affixClass = "weapon" },
	weapon = { kind = "thrown", damage = 7, damageType = "momentum", speed = 1.6, reach = 45, stamina = 5, ammo = "thrown_knife" },
	model = { shape = "dagger", color = rgb(190, 190, 198), material = M.Metal },
})

-- ─── Ammunition ─────────────────────────────────────────────────────────────

item({
	id = "wooden_arrow", name = "Wooden Arrow", category = "material", glyph = "➵", color = rgb(170, 135, 90),
	description = "Fletched with goose feathers. A bow spends one per shot.",
	stack = 50, weight = 0.05, value = 1, tags = { "arrow", "ammo", "wood" },
})
item({
	id = "iron_bolt", name = "Iron Bolt", category = "material", glyph = "➝", color = rgb(150, 150, 158),
	description = "A short, heavy quarrel. A crossbow spends one per shot.",
	stack = 40, weight = 0.08, value = 2, tags = { "bolt", "ammo", "metal" },
})
item({
	id = "throwing_knife", name = "Throwing Knife", category = "material", glyph = "⟋", color = rgb(190, 190, 198),
	description = "Balanced for the throw. A Knife Bandolier spends one per throw.",
	stack = 20, weight = 0.25, value = 3, tags = { "thrown_knife", "ammo", "metal", "blade" },
})

-- ─── Magic foci ─────────────────────────────────────────────────────────────

item({
	id = "apprentice_wand", name = "Apprentice's Wand", category = "focus", glyph = "/", color = rgb(190, 160, 110),
	description = "A straight birch twig with a copper cap. Steadies the hand a little, whatever you cast.",
	weight = 0.5, value = 30, tags = { "wood", "focus" },
	equip = { slots = HANDS, stats = { castSpeedPct = 0.04 }, durability = 80, affixClass = "focus" },
	focus = { grade = "major", domains = { any = 0.04 }, stability = 0.1 },
	model = { shape = "wand", color = rgb(190, 160, 110), material = M.Wood },
})
item({
	id = "oak_staff", name = "Oak Staff", category = "focus", glyph = "|", color = rgb(120, 90, 55),
	description = "Heavy heartwood that drinks in earth and growth. Two hands, steady casting.",
	weight = 3, value = 70, tags = { "wood", "focus", "staff" },
	requires = { tier = { earth = 2 } },
	equip = { slots = { "mainHand" }, twoHanded = true, stats = { reservoirMax = 10, stabilityPct = 0.06 }, durability = 140, affixClass = "focus" },
	focus = { grade = "major", domains = { earth = 0.12, life = 0.08 }, stability = 0.2 },
	weapon = { kind = "staff", damage = 8, damageType = "momentum", speed = 1.1, reach = 7, stamina = 9 },
	model = { shape = "staff", color = rgb(120, 90, 55), material = M.Wood },
})
item({
	id = "ember_orb", name = "Ember Orb", category = "focus", glyph = "●", color = rgb(255, 120, 40),
	description = "A sphere of smoked glass with a coal that never goes out.",
	rarity = "uncommon", weight = 1, value = 90, tags = { "glass", "focus", "orb", "fire" },
	requires = { tier = { energy = 2 } },
	equip = {
		slots = { "offHand" }, stats = { castSpeedPct = 0.05 }, resist = { combustion = 0.05 }, durability = 100, affixClass = "focus",
		attune = { requires = { affinity = { energy = 0.5 } }, stats = { power_energy = 0.06 }, text = "Answers a strong Energy affinity" },
	},
	focus = { grade = "major", domains = { energy = 0.12 }, stability = 0.15 },
	model = { shape = "orb", color = rgb(255, 120, 40), material = M.Glass, glow = rgb(255, 140, 60) },
})
item({
	id = "tidecall_tome", name = "Tidecall Tome", category = "focus", glyph = "▤", color = rgb(60, 120, 170),
	description = "Salt-stiff pages of tide tables and drowned hymns. Its margins make room for one more thought.",
	rarity = "rare", weight = 2, value = 160, tags = { "paper", "focus", "tome", "water" },
	requires = { tier = { water = 3 } },
	equip = { slots = { "offHand" }, stats = { modifierSlots = 1, reservoirRegenPct = 0.05 }, durability = 90, affixClass = "focus" },
	focus = { grade = "major", domains = { water = 0.1 }, stability = 0.1 },
	model = { shape = "tome", color = rgb(60, 120, 170), material = M.Fabric },
})
item({
	id = "copper_band", name = "Copper Band", category = "jewelry", glyph = "○", color = rgb(196, 120, 70),
	description = "A minor focus: worn, not held. Takes some of the edge off casting bare-handed.",
	weight = 0.1, value = 25, tags = { "metal", "ring", "focus" },
	equip = { slots = RINGS, stats = { reservoirMax = 5 }, affixClass = "jewelry" },
	focus = { grade = "minor", domains = { any = 0.02 } },
	model = { shape = "none" },
})
item({
	id = "moonstone_amulet", name = "Moonstone Amulet", category = "jewelry", glyph = "◎", color = rgb(200, 210, 235),
	description = "Cool to the touch even in summer. Quiets the mind and the dead alike.",
	rarity = "uncommon", weight = 0.2, value = 80, tags = { "gem", "amulet", "focus" },
	equip = { slots = { "amulet" }, stats = { backlashResistPct = 0.05 }, resist = { mind = 0.05, spirit = 0.05 }, affixClass = "jewelry" },
	focus = { grade = "minor", domains = { mind = 0.05, spirit = 0.05 } },
	model = { shape = "amulet", color = rgb(200, 210, 235), material = M.Glass },
})

-- ─── Armor and clothing ─────────────────────────────────────────────────────

item({
	id = "leather_cap", name = "Leather Cap", category = "armor", glyph = "◠", color = rgb(120, 85, 55),
	description = "Boiled leather, laced at the back.",
	weight = 1, value = 12, tags = { "leather" },
	equip = { slots = { "head" }, stats = { defense = 2, health = 4 }, durability = 60, affixClass = "armor" },
	model = { shape = "cap", color = rgb(120, 85, 55), material = M.Leather },
})
item({
	id = "miner_helm", name = "Miner's Helm", category = "armor", glyph = "◠", color = rgb(110, 110, 115),
	description = "A dented iron helm with a candle spike.",
	weight = 2, value = 28, tags = { "metal", "npc_gear" },
	equip = { slots = { "head" }, stats = { defense = 4 }, resist = { earth = 0.15, seismicity = 0.1 }, durability = 100, affixClass = "armor" },
	model = { shape = "helm", color = rgb(110, 110, 115), material = M.Metal },
})
item({
	id = "padded_robe", name = "Padded Robe", category = "clothing", glyph = "⛨", color = rgb(150, 130, 160),
	description = "Layers of quilted cloth.",
	weight = 3, value = 22, tags = { "cloth", "npc_gear" },
	equip = { slots = { "chest" }, stats = { reservoirRegenPct = 0.03 }, resist = { all = 0.05, momentum = 0.1 }, durability = 80, affixClass = "armor" },
	model = { shape = "robe", color = rgb(150, 130, 160), material = M.Fabric },
})
item({
	id = "chain_mail", name = "Chain Mail", category = "armor", glyph = "⛨", color = rgb(150, 150, 160),
	description = "Turns blows and stones, but draws lightning.",
	weight = 9, value = 90, tags = { "metal", "npc_gear" },
	equip = { slots = { "chest" }, stats = { defense = 10, health = 10 }, resist = { momentum = 0.2, earth = 0.1, charge = -0.2 }, durability = 160, affixClass = "armor" },
	model = { shape = "plate", color = rgb(150, 150, 160), material = M.DiamondPlate },
})
item({
	id = "leather_apron", name = "Leather Apron", category = "clothing", glyph = "⛨", color = rgb(105, 70, 45),
	description = "Scorched smith's leather; shrugs off sparks and heat.",
	weight = 3, value = 20, tags = { "leather", "npc_gear" },
	equip = { slots = { "chest" }, stats = { defense = 3 }, resist = { combustion = 0.2, temperature = 0.15 }, durability = 90, affixClass = "armor" },
	model = { shape = "apron", color = rgb(105, 70, 45), material = M.Leather },
})
item({
	id = "oilskin", name = "Oilskin Coat", category = "clothing", glyph = "◜", color = rgb(90, 95, 70),
	description = "Keeps the sea and the cold out.",
	weight = 3, value = 26, tags = { "cloth", "npc_gear" },
	equip = { slots = { "cloak" }, resist = { water = 0.2, temperature = 0.1 }, durability = 90, affixClass = "armor" },
	model = { shape = "cloak", color = rgb(90, 95, 70), material = M.Fabric },
})
item({
	id = "wool_cloak", name = "Wool Cloak", category = "clothing", glyph = "◜", color = rgb(120, 60, 50),
	description = "Warm, heavy, and good for sleeping under.",
	weight = 2, value = 15, tags = { "cloth" },
	equip = { slots = { "cloak" }, stats = { staminaMax = 5 }, resist = { temperature = 0.1 }, durability = 70, affixClass = "armor" },
	model = { shape = "cloak", color = rgb(120, 60, 50), material = M.Fabric },
})
item({
	id = "wool_trousers", name = "Wool Trousers", category = "clothing", glyph = "∏", color = rgb(95, 90, 80),
	description = "Patched at both knees by someone who cared.",
	weight = 1.5, value = 10, tags = { "cloth" },
	equip = { slots = { "legs" }, stats = { defense = 1, staminaMax = 5 }, durability = 60, affixClass = "armor" },
	model = { shape = "none" },
})
item({
	id = "rubber_gloves", name = "Insulated Gloves", category = "clothing", glyph = "✋", color = rgb(70, 65, 60),
	description = "Thick, dull gloves; current struggles through them.",
	weight = 0.5, value = 18, tags = { "leather", "npc_gear" },
	equip = { slots = { "hands" }, resist = { charge = 0.3 }, durability = 70, affixClass = "armor" },
	model = { shape = "none" },
})
item({
	id = "traveler_boots", name = "Traveler's Boots", category = "clothing", glyph = "▁", color = rgb(110, 80, 55),
	description = "Broken in by someone else's long road.",
	weight = 1.5, value = 14, tags = { "leather" },
	equip = { slots = { "feet" }, stats = { moveSpeedPct = 0.04 }, durability = 80, affixClass = "armor" },
	model = { shape = "none" },
})
item({
	id = "rope_belt", name = "Tool Belt", category = "clothing", glyph = "═", color = rgb(140, 110, 70),
	description = "Loops and hooks for everything you meant to put down.",
	weight = 0.5, value = 12, tags = { "leather" },
	equip = { slots = { "belt" }, stats = { carryWeight = 10 }, durability = 80, affixClass = "armor" },
	model = { shape = "belt", color = rgb(140, 110, 70), material = M.Leather },
})

-- Trinkets and charms (NPC occupation charms included).
item({
	id = "herb_charm", name = "Herb Charm", category = "jewelry", glyph = "✦", color = rgb(110, 150, 80),
	description = "Bitter herbs bound in cloth.",
	weight = 0.1, value = 15, tags = { "herb", "npc_gear" },
	equip = { slots = { "trinket" }, resist = { toxin = 0.25, decay = 0.15 }, affixClass = "jewelry" },
	model = { shape = "charm", color = rgb(110, 150, 80), material = M.Fabric },
})
item({
	id = "spirit_beads", name = "Prayer Beads", category = "jewelry", glyph = "✦", color = rgb(200, 180, 140),
	description = "Worn smooth by a lifetime of prayer.",
	weight = 0.2, value = 20, tags = { "wood", "npc_gear" },
	equip = { slots = { "trinket" }, resist = { spirit = 0.15, malediction = 0.2 }, affixClass = "jewelry" },
	model = { shape = "charm", color = rgb(200, 180, 140), material = M.Wood },
})
item({
	id = "focus_ring", name = "Focus Ring", category = "jewelry", glyph = "○", color = rgb(190, 190, 200),
	description = "A plain band that steadies the thoughts.",
	weight = 0.1, value = 30, tags = { "metal", "ring", "npc_gear", "focus" },
	equip = { slots = RINGS, resist = { mind = 0.25, emotion = 0.15 }, affixClass = "jewelry" },
	focus = { grade = "minor", domains = { mind = 0.05 } },
	model = { shape = "none" },
})

-- ─── Tools ──────────────────────────────────────────────────────────────────

item({
	id = "iron_pickaxe", name = "Iron Pickaxe", category = "tool", glyph = "⚒", color = rgb(140, 140, 150),
	description = "Breaks stone and copper and iron veins. Earth-sensitive hands find the seams faster.",
	weight = 5, value = 35, tags = { "metal", "tool_mine" },
	equip = { slots = { "mainHand" }, durability = 150, affixClass = "tool" },
	model = { shape = "pickaxe", color = rgb(140, 140, 150), material = M.Metal },
	data = { toolTier = 2, harvest = "mine" },
})
item({
	id = "hatchet", name = "Hatchet", category = "tool", glyph = "⚒", color = rgb(150, 110, 70),
	description = "For kindling, branches and the occasional stubborn root.",
	weight = 2, value = 15, tags = { "metal", "tool_chop" },
	equip = { slots = HANDS, durability = 100, affixClass = "tool" },
	model = { shape = "axe", color = rgb(150, 110, 70), material = M.Wood },
	data = { toolTier = 1, harvest = "chop" },
})
item({
	id = "fishing_rod", name = "Fishing Rod", category = "tool", glyph = "⌒", color = rgb(170, 140, 90),
	description = "Cane, line and a hook carved from bone.",
	weight = 1.5, value = 20, tags = { "wood", "tool_fish" },
	equip = { slots = { "mainHand" }, twoHanded = true, durability = 100, affixClass = "tool" },
	model = { shape = "rod", color = rgb(170, 140, 90), material = M.Wood },
	data = { toolTier = 1, harvest = "fish" },
})
item({
	id = "sickle", name = "Sickle", category = "tool", glyph = "☾", color = rgb(160, 160, 165),
	description = "Cuts herbs clean at the stem so they grow back.",
	weight = 1, value = 14, tags = { "metal", "tool_herb" },
	equip = { slots = HANDS, durability = 100, affixClass = "tool" },
	model = { shape = "sickle", color = rgb(160, 160, 165), material = M.Metal },
	data = { toolTier = 1, harvest = "herb" },
})
item({
	id = "lockpick", name = "Lockpick", category = "tool", glyph = "⚷", color = rgb(150, 150, 155),
	description = "Bent wire and patience. Snaps more often than it should.",
	stack = 20, weight = 0.05, value = 4, tags = { "metal", "tool_lock" },
	data = { toolTier = 1 },
})
item({
	id = "torch", name = "Torch", category = "tool", glyph = "♨", color = rgb(255, 170, 70),
	description = "Pitch-soaked rag on a stick. Light in the off hand.",
	weight = 1, value = 3, tags = { "wood", "light" },
	equip = { slots = { "offHand" }, durability = 300 },
	model = { shape = "torch", color = rgb(120, 80, 45), material = M.Wood, glow = rgb(255, 170, 80) },
})

-- ─── Consumables ────────────────────────────────────────────────────────────

item({
	id = "bread_loaf", name = "Loaf of Bread", category = "consumable", glyph = "◒", color = rgb(210, 165, 100),
	description = "Dense and filling. Restores health slowly.",
	stack = 20, weight = 0.4, value = 2, tags = { "food" },
	use = { effects = { { kind = "heal", amount = 18, over = 12 } }, cooldown = 2, group = "food" },
})
item({
	id = "smoked_fish", name = "Smoked Fish", category = "consumable", glyph = "◒", color = rgb(190, 130, 80),
	description = "Salty and long-keeping. Restores health and a little reservoir.",
	stack = 20, weight = 0.3, value = 4, tags = { "food", "fish" },
	use = { effects = { { kind = "heal", amount = 22, over = 10 }, { kind = "reservoir", amount = 10 } } :: { any }, cooldown = 2, group = "food" },
})
item({
	id = "hearty_stew", name = "Hearty Stew", category = "consumable", glyph = "◓", color = rgb(160, 100, 60),
	description = "Root vegetables and something that used to run. Well fed: more health and stamina for a while.",
	stack = 10, weight = 0.8, value = 12, tags = { "food", "meal" },
	use = {
		effects = {
			{ kind = "heal", amount = 30, over = 15 },
			{ kind = "buff", id = "well_fed", name = "Well fed", duration = 600, stats = { health = 15, staminaMax = 15, healthRegen = 0.2 } },
		} :: { any },
		cooldown = 5, group = "food",
	},
})
item({
	id = "healing_draught", name = "Healing Draught", category = "consumable", glyph = "♥", color = rgb(213, 94, 0),
	description = "Bitter red tincture. Closes wounds quickly.",
	stack = 10, weight = 0.3, value = 15, tags = { "potion" },
	use = { effects = { { kind = "heal", amount = 45 } }, cooldown = 20, group = "potion" },
})
item({
	id = "reservoir_tonic", name = "Reservoir Tonic", category = "consumable", glyph = "♦", color = rgb(120, 170, 255),
	description = "Tastes of thunderstorms. Refills part of your reservoir.",
	stack = 10, weight = 0.3, value = 20, tags = { "potion" },
	use = { effects = { { kind = "reservoir", share = 0.3 } }, cooldown = 30, group = "potion" },
})
item({
	id = "ironbark_elixir", name = "Ironbark Elixir", category = "consumable", glyph = "♣", color = rgb(110, 90, 60),
	description = "Your skin goes stiff and grey for a while: blows and stones hurt less, but you move slower.",
	rarity = "uncommon", stack = 5, weight = 0.3, value = 45, tags = { "elixir" },
	use = {
		effects = { { kind = "buff", id = "ironbark", name = "Ironbark", duration = 180, stats = { defense = 15, moveSpeedPct = -0.08 }, resist = { momentum = 0.15, earth = 0.1 } } },
		cooldown = 60, group = "elixir",
	},
})
item({
	id = "antidote", name = "Antidote", category = "consumable", glyph = "✚", color = rgb(0, 158, 115),
	description = "Chalky and foul. Purges poison and rot.",
	stack = 10, weight = 0.2, value = 10, tags = { "potion" },
	use = { effects = { { kind = "cleanse", statuses = { "poison", "rot" } } }, cooldown = 10, group = "potion" },
})
item({
	id = "scroll_ember_dart", name = "Scroll of Ember Dart", category = "consumable", glyph = "✉", color = rgb(255, 140, 40),
	description = "A fire dart written into vellum. Anyone can read it aloud, once; you still pay its reservoir cost.",
	rarity = "uncommon", stack = 10, weight = 0.1, value = 25, tags = { "scroll", "paper" },
	use = {
		effects = { { kind = "spell", recipe = { branch = "pyromancy", property = "combustion", verb = "generate", form = "projectile", power = 3 } } },
		cooldown = 3, group = "scroll", needsAim = true,
	},
})
item({
	id = "repair_kit", name = "Repair Kit", category = "consumable", glyph = "✚", color = rgb(150, 150, 160),
	description = "Rivets, thread and wax. Restores the most worn piece of your equipment.",
	stack = 10, weight = 0.5, value = 18, tags = { "kit" },
	use = { effects = { { kind = "repair", amount = 60 } }, cooldown = 3 },
})

-- ─── Crafting materials ─────────────────────────────────────────────────────

item({ id = "copper_ore", name = "Copper Ore", category = "material", glyph = "▣", color = rgb(196, 120, 70), description = "Green-streaked rock heavy with copper.", stack = 50, weight = 1, value = 2, tags = { "ore", "metal" }, data = { oreTier = 1 } })
item({ id = "iron_ore", name = "Iron Ore", category = "material", glyph = "▣", color = rgb(130, 90, 80), description = "Rust-red and heavy. Smelts into iron.", stack = 50, weight = 1.2, value = 3, tags = { "ore", "metal" }, data = { oreTier = 2 } })
item({ id = "iron_ingot", name = "Iron Ingot", category = "material", glyph = "▬", color = rgb(150, 150, 160), description = "Smelted iron, ready for the anvil.", stack = 50, weight = 1, value = 9, tags = { "ingot", "metal", "metal_ingot" } })
item({ id = "quartz", name = "Quartz", category = "material", glyph = "◆", color = rgb(230, 230, 240), description = "A clear crystal that holds a charge, briefly.", stack = 50, weight = 0.2, value = 8, tags = { "gem" } })
item({ id = "silverleaf", name = "Silverleaf", category = "material", glyph = "❦", color = rgb(170, 200, 170), description = "A pale herb with a mint smell. Healers want it.", stack = 50, weight = 0.05, value = 3, tags = { "herb", "alch_restore" } })
item({ id = "wolf_hide", name = "Wolf Hide", category = "material", glyph = "▦", color = rgb(120, 110, 100), description = "Thick grey fur. Tans into good leather.", stack = 20, weight = 1.5, value = 6, tags = { "hide" } })
item({ id = "ember_essence", name = "Ember Essence", category = "material", glyph = "✺", color = rgb(255, 130, 50), rarity = "uncommon", description = "What's left when a fire spirit forgets itself. Enchanters use it.", stack = 20, weight = 0.1, value = 20, tags = { "essence", "energy" } })

-- Station materials (workbench, loom, hearth, enchanting desk)
item({ id = "wood_plank", name = "Wood Plank", category = "material", glyph = "▬", color = rgb(170, 130, 85), description = "Sawn and seasoned. Workbenches turn these into furniture and tools.", stack = 50, weight = 0.8, value = 2, tags = { "wood", "plank" } })
item({ id = "wool", name = "Raw Wool", category = "material", glyph = "☁", color = rgb(235, 230, 215), description = "Greasy and warm. A loom spins it into cloth.", stack = 50, weight = 0.3, value = 2, tags = { "fiber" } })
item({ id = "linen_cloth", name = "Cloth", category = "material", glyph = "▤", color = rgb(210, 200, 175), description = "A bolt of plain woven cloth.", stack = 50, weight = 0.4, value = 5, tags = { "fiber", "cloth" } })
item({ id = "blank_vellum", name = "Blank Vellum", category = "material", glyph = "▯", color = rgb(235, 225, 195), description = "Scraped hide, ready to take ink and spells.", stack = 30, weight = 0.1, value = 6, tags = { "paper" } })
item({ id = "raw_fish", name = "Raw Fish", category = "material", glyph = "◒", color = rgb(160, 180, 190), description = "Still glistening. Cook it at a hearth.", stack = 20, weight = 0.4, value = 2, tags = { "food_raw", "fish" } })
item({ id = "raw_meat", name = "Raw Meat", category = "material", glyph = "◒", color = rgb(190, 90, 80), description = "Fresh game. Cook it at a hearth.", stack = 20, weight = 0.5, value = 3, tags = { "food_raw", "meat" } })
item({ id = "flour", name = "Sack of Flour", category = "material", glyph = "◍", color = rgb(240, 235, 220), description = "Milled grain. Bakes into bread at a hearth.", stack = 20, weight = 0.6, value = 2, tags = { "food_raw", "grain" } })
item({ id = "root_vegetables", name = "Root Vegetables", category = "material", glyph = "◍", color = rgb(200, 130, 60), description = "Turnips, carrots and something purple.", stack = 20, weight = 0.5, value = 2, tags = { "food_raw", "vegetable" } })

-- ─── Domain reagents ────────────────────────────────────────────────────────

item({ id = "cinder_salt", name = "Cinder Salt", category = "reagent", glyph = "✺", color = rgb(230, 120, 60), description = "Crystals from cooled lava vents. Energy reagent.", stack = 50, weight = 0.1, value = 6, tags = { "reagent", "energy", "alch_heat" }, data = { domain = "energy" } })
item({ id = "geode_dust", name = "Geode Dust", category = "reagent", glyph = "✺", color = rgb(176, 140, 100), description = "Ground from a geode's heart. Earth reagent.", stack = 50, weight = 0.1, value = 6, tags = { "reagent", "earth", "alch_harden" }, data = { domain = "earth" } })
item({ id = "brine_pearl", name = "Brine Pearl", category = "reagent", glyph = "✺", color = rgb(150, 200, 230), description = "A pearl that is always slightly wet. Water reagent.", stack = 50, weight = 0.05, value = 9, tags = { "reagent", "water", "alch_flow" }, data = { domain = "water" } })

-- ─── Quest items and keys ───────────────────────────────────────────────────

item({ id = "sealed_letter", name = "Sealed Letter", category = "quest", glyph = "✉", color = rgb(230, 220, 190), description = "Wax-sealed and addressed in a careful hand. Not yours to open.", weight = 0.05, quest = true, tags = { "paper" } })
item({ id = "skeleton_key", name = "Skeleton Key", category = "key", glyph = "⚿", color = rgb(200, 190, 160), rarity = "rare", description = "Filed down until it fits most simple locks. Owning one is suspicious.", weight = 0.05, value = 80, tags = { "metal" }, data = { opens = "*" } })
item({ id = "rusted_key", name = "Rusted Key", category = "key", glyph = "⚿", color = rgb(150, 100, 70), description = "Old iron, green with damp. It opens something nearby.", weight = 0.05, value = 1, tags = { "metal" }, data = { opens = "old_cellar" } })

-- ─── Books ──────────────────────────────────────────────────────────────────

item({
	id = "primer_of_stone", name = "A Primer of Stone", category = "book", glyph = "▤", color = rgb(150, 120, 90),
	description = "A quarryman's notes on how rock wants to break. Reading it teaches Earth (once).",
	weight = 1, value = 30, tags = { "paper", "book" },
	use = { effects = { { kind = "study", branch = "earth", lore = { "primer_of_stone" } } }, consume = false, cooldown = 2 },
})
item({
	id = "notes_on_flame", name = "Notes on Flame", category = "book", glyph = "▤", color = rgb(200, 110, 60),
	description = "Scorched pages on why fire climbs. Reading them teaches Energy (once).",
	weight = 1, value = 30, tags = { "paper", "book" },
	use = { effects = { { kind = "study", branch = "energy", lore = { "notes_on_flame" } } }, consume = false, cooldown = 2 },
})

-- ─── Furniture, treasure ────────────────────────────────────────────────────

-- Furniture: place it in your house (HousingService; Shared/World/FurnitureModels draws it).
item({ id = "pine_stool", name = "Pine Stool", category = "furniture", glyph = "⌂", color = rgb(190, 150, 100), description = "Three legs, never wobbles. Place it in your house.", weight = 3, value = 6, tags = { "wood", "placeable" }, data = { furniture = "stool" } })
item({ id = "oak_table", name = "Oak Table", category = "furniture", glyph = "⌂", color = rgb(130, 95, 60), description = "Solid enough to dance on, which has been tested.", weight = 8, value = 20, tags = { "wood", "placeable" }, data = { furniture = "table" } })
item({ id = "woven_rug", name = "Woven Rug", category = "furniture", glyph = "▦", color = rgb(150, 70, 60), description = "Warm underfoot and hides the stains.", weight = 2, value = 14, tags = { "cloth", "placeable" }, data = { furniture = "rug" } })
item({ id = "small_bookcase", name = "Small Bookcase", category = "furniture", glyph = "▥", color = rgb(120, 85, 55), description = "Room for every book you mean to read.", weight = 6, value = 18, tags = { "wood", "placeable" }, data = { furniture = "bookcase" } })
item({ id = "potted_fern", name = "Potted Fern", category = "furniture", glyph = "❦", color = rgb(70, 140, 70), description = "Thrives on neglect.", weight = 2, value = 8, tags = { "plant", "placeable" }, data = { furniture = "fern" } })
item({ id = "standing_lantern", name = "Standing Lantern", category = "furniture", glyph = "♨", color = rgb(255, 200, 120), description = "Lights a corner of your home.", weight = 3, value = 25, tags = { "metal", "light", "placeable" }, data = { furniture = "lantern" } })
item({ id = "silver_goblet", name = "Silver Goblet", category = "treasure", glyph = "◈", color = rgb(200, 200, 210), description = "Tarnished, engraved with a crest nobody remembers.", stack = 5, weight = 0.5, value = 60, tags = { "metal", "valuable" } })
item({ id = "old_coin", name = "Old Coin", category = "treasure", glyph = "◈", color = rgb(230, 190, 90), description = "Minted by a kingdom that no longer exists. Collectors pay well.", stack = 99, weight = 0.01, value = 12, tags = { "metal", "valuable" } })

-- ─── Containers (bags) ──────────────────────────────────────────────────────

item({
	id = "small_pouch", name = "Small Pouch", category = "container", glyph = "▢", color = rgb(150, 110, 75),
	description = "Six more slots, tied at the hip.",
	weight = 0.3, value = 10, tags = { "leather", "bag" },
	equip = { slots = BAGS, bagSlots = 6 },
	model = { shape = "none" },
})
item({
	id = "traveler_pack", name = "Traveler's Pack", category = "container", glyph = "▢", color = rgb(120, 95, 70),
	description = "Twelve more slots and straps that spread the load.",
	rarity = "uncommon", weight = 1.5, value = 45, tags = { "leather", "bag" },
	equip = { slots = BAGS, bagSlots = 12, stats = { carryWeight = 15 } },
	model = { shape = "none" },
})

-- ─── Mythic artifact ────────────────────────────────────────────────────────

item({
	id = "still_hour_glass", name = "Hourglass of the Still Hour", category = "artifact", glyph = "⧗", color = rgb(230, 200, 120),
	description = "The sand inside has not fallen since it was made. For those Time has touched, it holds the moment open.",
	rarity = "artifact", weight = 1, value = 5000, tags = { "glass", "focus", "mythic", "time" },
	unique = true, bind = "pickup",
	requires = { awakened = { "time" } },
	equip = {
		slots = { "offHand" }, stats = { castSpeedPct = 0.15, backlashResistPct = 0.15, power_time = 0.25 },
		attune = { requires = { tier = { time = 4 } }, stats = { formTier = 1, modifierSlots = 1 }, text = "Opens wider for a Skilled Time mage" },
	},
	focus = { grade = "major", domains = { time = 0.2, any = 0.05 }, stability = 0.3 },
	model = { shape = "hourglass", color = rgb(230, 200, 120), material = M.Glass, glow = rgb(255, 225, 150) },
})

return list
