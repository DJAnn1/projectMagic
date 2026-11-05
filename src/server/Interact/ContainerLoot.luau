--!strict
--[[
	ContainerLoot: what a settlement container holds, seeded (docs/Buildings.md §3.2).
	Same world seed + container id + restock round = the same contents on every server.

	These household tables are the container system's own starting point; the loot stage
	(Server/Loot) replaces them with full weighted, conditional loot tables keyed by the same ids.

		ContainerLoot.roll(worldSeed, containerId, tableId, round) -> ({ { id, n } }, coins)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Seed = require(ReplicatedStorage.Shared.Magic.Seed)
local ItemDatabase = require(ReplicatedStorage.Shared.Items.ItemDatabase)

type Entry = { id: string, w: number, n: { number } }
type Table = { rolls: { number }, coins: { number }?, coinChance: number?, entries: { Entry } }

local TABLES: { [string]: Table } = {
	household = {
		rolls = { 1, 4 },
		coins = { 2, 18 },
		coinChance = 0.55,
		entries = {
			{ id = "bread_loaf", w = 30, n = { 1, 3 } },
			{ id = "smoked_fish", w = 18, n = { 1, 2 } },
			{ id = "silverleaf", w = 12, n = { 1, 4 } },
			{ id = "healing_draught", w = 8, n = { 1, 1 } },
			{ id = "old_coin", w = 8, n = { 1, 3 } },
			{ id = "wool_trousers", w = 6, n = { 1, 1 } },
			{ id = "leather_cap", w = 5, n = { 1, 1 } },
			{ id = "torch", w = 6, n = { 1, 1 } },
			{ id = "lockpick", w = 5, n = { 1, 2 } },
			{ id = "silver_goblet", w = 2, n = { 1, 1 } },
			{ id = "primer_of_stone", w = 1, n = { 1, 1 } },
			{ id = "notes_on_flame", w = 1, n = { 1, 1 } },
		},
	},
	provisions = {
		rolls = { 1, 3 },
		entries = {
			{ id = "bread_loaf", w = 30, n = { 2, 5 } },
			{ id = "smoked_fish", w = 25, n = { 1, 4 } },
			{ id = "hearty_stew", w = 6, n = { 1, 2 } },
			{ id = "silverleaf", w = 12, n = { 2, 6 } },
			{ id = "antidote", w = 5, n = { 1, 1 } },
			{ id = "brine_pearl", w = 3, n = { 1, 1 } },
			{ id = "flour", w = 14, n = { 1, 3 } },
			{ id = "raw_fish", w = 10, n = { 1, 3 } },
			{ id = "raw_meat", w = 8, n = { 1, 2 } },
			{ id = "root_vegetables", w = 12, n = { 1, 4 } },
		},
	},
	clothes = {
		rolls = { 1, 3 },
		entries = {
			{ id = "wool_trousers", w = 20, n = { 1, 1 } },
			{ id = "wool_cloak", w = 14, n = { 1, 1 } },
			{ id = "leather_cap", w = 12, n = { 1, 1 } },
			{ id = "traveler_boots", w = 12, n = { 1, 1 } },
			{ id = "padded_robe", w = 8, n = { 1, 1 } },
			{ id = "rope_belt", w = 8, n = { 1, 1 } },
			{ id = "herb_charm", w = 4, n = { 1, 1 } },
			{ id = "linen_cloth", w = 14, n = { 1, 3 } },
			{ id = "wool", w = 10, n = { 2, 5 } },
		},
	},
	workshop = {
		rolls = { 1, 3 },
		entries = {
			{ id = "iron_ore", w = 25, n = { 2, 6 } },
			{ id = "copper_ore", w = 20, n = { 2, 6 } },
			{ id = "iron_ingot", w = 12, n = { 1, 3 } },
			{ id = "wolf_hide", w = 10, n = { 1, 2 } },
			{ id = "quartz", w = 6, n = { 1, 2 } },
			{ id = "repair_kit", w = 5, n = { 1, 1 } },
			{ id = "lockpick", w = 6, n = { 1, 3 } },
			{ id = "geode_dust", w = 4, n = { 1, 3 } },
			{ id = "wood_plank", w = 22, n = { 2, 6 } },
			{ id = "wool", w = 8, n = { 2, 4 } },
			{ id = "linen_cloth", w = 6, n = { 1, 2 } },
			{ id = "blank_vellum", w = 3, n = { 1, 2 } },
		},
	},
}

for tableId, t in TABLES do
	for _, e in t.entries do
		assert(ItemDatabase.get(e.id), string.format("ContainerLoot.%s: unknown item %s", tableId, e.id))
	end
end

local ContainerLoot = {}

ContainerLoot.tables = TABLES

function ContainerLoot.roll(worldSeed: number, containerId: string, tableId: string, round: number): ({ { id: string, n: number } }, number)
	local t = TABLES[tableId]
	if not t then
		return {}, 0
	end
	local rng = Seed.random(worldSeed, "container:" .. containerId, "loot", round)
	local total = 0
	for _, e in t.entries do
		total += e.w
	end
	local out: { { id: string, n: number } } = {}
	for _ = 1, rng:NextInteger(t.rolls[1], t.rolls[2]) do
		local pick = rng:NextNumber() * total
		for _, e in t.entries do
			pick -= e.w
			if pick <= 0 then
				table.insert(out, { id = e.id, n = rng:NextInteger(e.n[1], e.n[2]) })
				break
			end
		end
	end
	local coins = 0
	if t.coins and rng:NextNumber() < (t.coinChance or 1) then
		coins = rng:NextInteger(t.coins[1], t.coins[2])
	end
	return out, coins
end

return ContainerLoot
