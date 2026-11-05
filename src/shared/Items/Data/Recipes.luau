--!strict
--[[
	Recipes: what crafting stations make (docs/Buildings.md §5). Pure data; CraftingService
	validates it at boot (unknown items, tags or stations fail loudly).

	Six stations: forge (smithies), workbench and loom (barns, large houses), hearth (any lit
	fireplace: cooking needs the fire burning), alchemy table and enchanting desk (magic
	schools). The crafting stage (docs/Items.md, stage 3) adds discovery, experimentation and
	real enchanting (affixes) on top of the same format.

		station   Interactables station id ("forge")
		tier      minimum StationTier of the station part (forgehold smithies are tier 2)
		inputs    { item = id, n } a specific item, or { tag = tag, n } any items with that tag
		          (taken from the fewest kinds first, in id order, so it's predictable)
		output    { item = id, n } (stackables arrive as one stack; others as n separate items)
		requires  optional mastery (Shared/Items ItemTypes.Requirement): tier-gated techniques
		xp        { branch, amount }: study XP when the branch is unlocked (ProgressionService:awardQuest)
		quality   true: the result rolls crafted quality and carries the crafter's name
]]

export type Ingredient = { item: string?, tag: string?, n: number }

export type Recipe = {
	id: string,
	name: string,
	station: string,
	tier: number,
	inputs: { Ingredient },
	output: { item: string, n: number },
	requires: { tier: { [string]: number }? }?,
	xp: { branch: string, amount: number }?,
	quality: boolean?,
}

local list: { Recipe } = {
	-- Smelting
	{ id = "smelt_iron", name = "Smelt iron", station = "forge", tier = 1, inputs = { { item = "iron_ore", n = 2 } }, output = { item = "iron_ingot", n = 1 }, xp = { branch = "metallurgy", amount = 25 } },
	-- Smithing (any metal ingot works)
	{ id = "forge_lockpicks", name = "Bend lockpicks", station = "forge", tier = 1, inputs = { { tag = "metal_ingot", n = 1 } }, output = { item = "lockpick", n = 5 }, xp = { branch = "metallurgy", amount = 20 } },
	{ id = "forge_hatchet", name = "Forge a hatchet", station = "forge", tier = 1, inputs = { { tag = "metal_ingot", n = 2 } }, output = { item = "hatchet", n = 1 }, xp = { branch = "metallurgy", amount = 50 }, quality = true },
	{ id = "forge_sword", name = "Forge an iron sword", station = "forge", tier = 1, inputs = { { tag = "metal_ingot", n = 3 } }, output = { item = "iron_sword", n = 1 }, xp = { branch = "metallurgy", amount = 80 }, quality = true },
	{ id = "forge_pickaxe", name = "Forge a pickaxe", station = "forge", tier = 1, inputs = { { tag = "metal_ingot", n = 3 } }, output = { item = "iron_pickaxe", n = 1 }, xp = { branch = "metallurgy", amount = 80 }, quality = true },
	{ id = "forge_repair_kit", name = "Make a repair kit", station = "forge", tier = 1, inputs = { { tag = "metal_ingot", n = 1 }, { item = "wolf_hide", n = 1 } }, output = { item = "repair_kit", n = 2 }, xp = { branch = "metallurgy", amount = 30 } },
	-- Master forge (tier 2) and a mastery-gated technique
	{ id = "forge_chain_mail", name = "Link chain mail", station = "forge", tier = 2, inputs = { { tag = "metal_ingot", n = 6 } }, output = { item = "chain_mail", n = 1 }, xp = { branch = "metallurgy", amount = 160 }, quality = true },
	{ id = "forge_helm", name = "Raise a miner's helm", station = "forge", tier = 1, inputs = { { tag = "metal_ingot", n = 2 } }, output = { item = "miner_helm", n = 1 },
		requires = { tier = { metallurgy = 2 } }, xp = { branch = "metallurgy", amount = 70 }, quality = true },

	-- Workbench: furniture, tools, vellum
	{ id = "wb_stool", name = "Make a stool", station = "workbench", tier = 1, inputs = { { item = "wood_plank", n = 3 } }, output = { item = "pine_stool", n = 1 } },
	{ id = "wb_table", name = "Make a table", station = "workbench", tier = 1, inputs = { { item = "wood_plank", n = 5 } }, output = { item = "oak_table", n = 1 } },
	{ id = "wb_bookcase", name = "Make a bookcase", station = "workbench", tier = 1, inputs = { { item = "wood_plank", n = 4 } }, output = { item = "small_bookcase", n = 1 } },
	{ id = "wb_torches", name = "Wrap torches", station = "workbench", tier = 1, inputs = { { item = "wood_plank", n = 1 }, { item = "linen_cloth", n = 1 } }, output = { item = "torch", n = 3 } },
	{ id = "wb_rod", name = "Make a fishing rod", station = "workbench", tier = 1, inputs = { { item = "wood_plank", n = 2 }, { item = "linen_cloth", n = 1 } }, output = { item = "fishing_rod", n = 1 }, quality = true },
	{ id = "wb_pouch", name = "Stitch a pouch", station = "workbench", tier = 1, inputs = { { item = "wolf_hide", n = 1 }, { item = "linen_cloth", n = 1 } }, output = { item = "small_pouch", n = 1 } },
	{ id = "wb_vellum", name = "Scrape vellum", station = "workbench", tier = 1, inputs = { { item = "wolf_hide", n = 1 } }, output = { item = "blank_vellum", n = 2 } },

	-- Loom: cloth and clothes
	{ id = "loom_cloth", name = "Weave cloth", station = "loom", tier = 1, inputs = { { item = "wool", n = 2 } }, output = { item = "linen_cloth", n = 1 } },
	{ id = "loom_trousers", name = "Sew trousers", station = "loom", tier = 1, inputs = { { tag = "cloth", n = 2 } }, output = { item = "wool_trousers", n = 1 }, quality = true },
	{ id = "loom_cloak", name = "Sew a cloak", station = "loom", tier = 1, inputs = { { tag = "cloth", n = 3 } }, output = { item = "wool_cloak", n = 1 }, quality = true },
	{ id = "loom_robe", name = "Quilt a robe", station = "loom", tier = 1, inputs = { { tag = "cloth", n = 4 } }, output = { item = "padded_robe", n = 1 }, quality = true },
	{ id = "loom_rug", name = "Weave a rug", station = "loom", tier = 1, inputs = { { tag = "cloth", n = 3 } }, output = { item = "woven_rug", n = 1 } },

	-- Hearth: cooking (the fire must be lit)
	{ id = "cook_bread", name = "Bake bread", station = "hearth", tier = 1, inputs = { { item = "flour", n = 2 } }, output = { item = "bread_loaf", n = 2 } },
	{ id = "cook_fish", name = "Smoke fish", station = "hearth", tier = 1, inputs = { { item = "raw_fish", n = 1 } }, output = { item = "smoked_fish", n = 1 } },
	{ id = "cook_stew", name = "Cook a stew", station = "hearth", tier = 1, inputs = { { tag = "meat", n = 1 }, { tag = "vegetable", n = 2 } }, output = { item = "hearty_stew", n = 1 } },

	-- Alchemy table
	{ id = "alch_healing", name = "Brew a healing draught", station = "alchemy", tier = 1, inputs = { { item = "silverleaf", n = 3 } }, output = { item = "healing_draught", n = 1 }, xp = { branch = "life", amount = 30 } },
	{ id = "alch_antidote", name = "Mix an antidote", station = "alchemy", tier = 1, inputs = { { item = "silverleaf", n = 1 }, { item = "geode_dust", n = 1 } }, output = { item = "antidote", n = 1 }, xp = { branch = "life", amount = 20 } },
	{ id = "alch_tonic", name = "Brew a reservoir tonic", station = "alchemy", tier = 1, inputs = { { item = "brine_pearl", n = 1 }, { item = "quartz", n = 1 } }, output = { item = "reservoir_tonic", n = 1 }, xp = { branch = "water", amount = 30 } },
	{ id = "alch_ironbark", name = "Brew ironbark elixir", station = "alchemy", tier = 1, inputs = { { item = "geode_dust", n = 2 }, { item = "wolf_hide", n = 1 } }, output = { item = "ironbark_elixir", n = 1 },
		requires = { tier = { earth = 2 } }, xp = { branch = "earth", amount = 60 } },

	-- Enchanting desk (affix enchanting arrives with the crafting stage)
	{ id = "ench_ember_scroll", name = "Scribe Ember Dart scrolls", station = "enchanting", tier = 1, inputs = { { item = "blank_vellum", n = 1 }, { item = "ember_essence", n = 1 } }, output = { item = "scroll_ember_dart", n = 2 },
		requires = { tier = { energy = 2 } }, xp = { branch = "energy", amount = 60 } },
	{ id = "ench_focus_ring", name = "Set a focus ring", station = "enchanting", tier = 1, inputs = { { item = "quartz", n = 2 }, { tag = "metal_ingot", n = 1 } }, output = { item = "focus_ring", n = 1 },
		requires = { tier = { any = 2 } }, quality = true },
}

local byId: { [string]: Recipe } = {}
for _, r in list do
	assert(byId[r.id] == nil, "Recipes: duplicate " .. r.id)
	byId[r.id] = r
end

return table.freeze({
	list = list,
	byId = byId,
})
