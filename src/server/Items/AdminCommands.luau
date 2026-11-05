--!strict
--[[
	Item admin commands (Admin Panel category "Items"; docs/AdminPanel.md). InventoryService calls
	register() at init. Every change goes through InventoryService's atomic, logged operations.

	give <player> <item> [count] [rarity] [affixes]   rarity: roll | common..legendary | artifact;
	                                                  affixes: comma list (e.g. ember_touched,of_haste)
	kit <player> <kit>             starter bundles: caster, fighter, tools, consumables, materials, all
	inv [player]                   what a player carries (grid, equipment, coins)
	iteminfo <item>                a definition: category, rarity, stack, weight, value, stats, use
	clearinv <player> [equipment]  empties the grid (and the body with equipment=on); quest items stay
	setcoins <player> <amount> [rare]
	coins <player> <delta>         add or spend coins (never below zero)
	repairall [player]             full durability on everything
	wear <player> <slot> <amount>  damage an equipped item's durability (test breaking)
	itemstats [player]             the derived stat sheet with every contribution, in order
	itemroll <item> [n] [luck]     roll n variants: rarity shares, affix frequency, stat ranges
	invlog [player]                the last operations on a player's inventory (memory log)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local StatDefs = require(Shared.Items.Data.StatDefs)
local Rarities = require(Shared.Items.Data.Rarities)
local ItemRules = require(Shared.Items.Data.ItemRules)
local Inventory = require(script.Parent.Inventory)
local ItemGenerator = require(script.Parent.ItemGenerator)

local KITS: { [string]: { { string | number } } } = {
	caster = { { "apprentice_wand", 1 }, { "oak_staff", 1 }, { "ember_orb", 1 }, { "tidecall_tome", 1 }, { "copper_band", 1 }, { "moonstone_amulet", 1 }, { "padded_robe", 1 }, { "reservoir_tonic", 5 } },
	fighter = { { "iron_sword", 1 }, { "hunting_spear", 1 }, { "bone_dagger", 1 }, { "ash_shortbow", 1 }, { "wooden_arrow", 50 }, { "light_crossbow", 1 }, { "iron_bolt", 40 }, { "knife_bandolier", 1 }, { "throwing_knife", 20 }, { "chain_mail", 1 }, { "leather_cap", 1 }, { "healing_draught", 5 } },
	tools = { { "iron_pickaxe", 1 }, { "hatchet", 1 }, { "fishing_rod", 1 }, { "sickle", 1 }, { "lockpick", 10 }, { "torch", 1 }, { "repair_kit", 3 } },
	consumables = { { "bread_loaf", 10 }, { "smoked_fish", 10 }, { "hearty_stew", 3 }, { "healing_draught", 5 }, { "reservoir_tonic", 5 }, { "ironbark_elixir", 2 }, { "antidote", 3 }, { "scroll_ember_dart", 3 }, { "repair_kit", 3 } },
	materials = { { "copper_ore", 20 }, { "iron_ore", 20 }, { "iron_ingot", 10 }, { "quartz", 5 }, { "silverleaf", 10 }, { "wolf_hide", 4 }, { "ember_essence", 3 }, { "cinder_salt", 5 }, { "geode_dust", 5 }, { "brine_pearl", 5 } },
}

local function sortedKeys(t: { [string]: any }): { string }
	local out = {}
	for k in t do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

local function line(rec: any): string
	local rarity = ItemInstance.rarity(rec)
	local count = ItemInstance.count(rec)
	local extra = {}
	local max = ItemInstance.maxDurability(rec)
	if max then
		table.insert(extra, string.format("dur %d/%d", ItemInstance.durability(rec) :: number, max))
	end
	if rec.u then
		table.insert(extra, rec.u)
	end
	return string.format("%s%s [%s]%s", ItemInstance.displayName(rec), if count > 1 then " x" .. count else "", rarity.name,
		if #extra > 0 then "  (" .. table.concat(extra, ", ") .. ")" else "")
end

local AdminCommands = {}

function AdminCommands.register(admin: any, service: any)
	admin:RegisterType("item", {
		parse = function(raw: string)
			local id = ItemDatabase.resolve(string.lower(raw))
			if id then
				return id, nil
			end
			return admin.matchOption(raw, ItemDatabase.ids)
		end,
		options = function()
			return ItemDatabase.ids
		end,
	})
	local rarityOptions = { "roll" }
	for _, r in Rarities.list do
		table.insert(rarityOptions, r.id)
	end

	admin:Register({
		name = "give", aliases = { "giveitem" }, category = "Items",
		description = "Give items. Rarity: roll (default) or a fixed rarity; affixes: comma list of affix ids",
		args = {
			{ name = "player", type = "player", default = "me" },
			{ name = "item", type = "item" },
			{ name = "count", type = "integer", min = 1, max = 999, default = 1 },
			{ name = "rarity", type = "enum", options = rarityOptions, default = "roll" },
			{ name = "affixes", type = "text", optional = true, hint = "e.g. ember_touched,of_haste" },
		},
		handler = function(_, a)
			local affixes: { string }? = nil
			if a.affixes and a.affixes ~= "" then
				affixes = {}
				for id in string.gmatch(a.affixes, "[^,%s]+") do
					table.insert(affixes :: { string }, string.lower(id))
				end
			end
			local opts = { rarity = if a.rarity == "roll" then nil else a.rarity, affixes = affixes }
			local added, left, err = service:give(a.player, a.item, a.count, opts)
			if added == 0 then
				return "nothing given: " .. tostring(err)
			end
			return string.format("gave %s x%d to %s%s", a.item, added, a.player.Name, if left > 0 then string.format(" (%d didn't fit: %s)", left, tostring(err)) else "")
		end,
	})

	admin:Register({
		name = "kit", category = "Items", description = "Give a bundle of items: caster, fighter, tools, consumables, materials, or all (one of every item)",
		args = {
			{ name = "player", type = "player", default = "me" },
			{ name = "kit", type = "enum", options = { "caster", "fighter", "tools", "consumables", "materials", "all" } },
		},
		handler = function(_, a)
			local list: { any } = {}
			if a.kit == "all" then
				for _, id in ItemDatabase.ids do
					local entry: { string | number } = { id, 1 }
					table.insert(list, entry)
				end
			else
				list = KITS[a.kit]
			end
			local given, missed = 0, {}
			for _, entry in list do
				local added = service:give(a.player, entry[1] :: string, entry[2] :: number)
				if added > 0 then
					given += 1
				else
					table.insert(missed, entry[1] :: string)
				end
			end
			return string.format("%s kit: %d entries given%s", a.kit, given,
				if #missed > 0 then string.format("; no room for %d (%s)", #missed, table.concat(missed, ", ", 1, math.min(#missed, 6))) else "")
		end,
	})

	admin:Register({
		name = "inv", aliases = { "inventory" }, category = "Items", description = "What a player carries: coins, weight, grid and equipment",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local inv = service:inventoryOf(a.player)
			if not inv then
				return "inventory not loaded"
			end
			local out = { string.format("%s: %d coins, %d rare, %d/%d slots used, weight %.1f",
				a.player.Name, inv.currency, inv.rare, Inventory.capacity(inv) - Inventory.freeCount(inv), Inventory.capacity(inv), Inventory.weight(inv)) }
			for _, entry in Inventory.each(inv) do
				table.insert(out, string.format("  %-10s %s", entry.ref, line(entry.rec)))
			end
			if inv.quarantine and #inv.quarantine > 0 then
				table.insert(out, string.format("  ! %d quarantined record(s)", #inv.quarantine))
			end
			return table.concat(out, "\n")
		end,
	})

	admin:Register({
		name = "iteminfo", category = "Items", description = "An item definition: category, rarity, stack, weight, value, stats, use",
		args = { { name = "item", type = "item" } },
		handler = function(_, a)
			local def = ItemDatabase.get(a.item)
			if not def then
				return "unknown item"
			end
			local out = {
				string.format("%s (%s): %s, %s", def.name, def.id, ItemRules.categories[def.category].name, def.rarity),
				string.format("stack %d, weight %.2f, value %d, tags %s", def.stack, def.weight, def.value, table.concat(def.tags, " ")),
				def.description,
			}
			if def.equip then
				local stats = {}
				for _, id in sortedKeys(def.equip.stats or {}) do
					table.insert(stats, StatDefs.byId[id].name .. " " .. StatDefs.format(id, (def.equip.stats :: any)[id]))
				end
				for _, key in sortedKeys(def.equip.resist or {}) do
					table.insert(stats, string.format("resist %s %+.0f%%", key, (def.equip.resist :: any)[key] * 100))
				end
				table.insert(out, string.format("equip %s%s, durability %s, affixes %s: %s", table.concat(def.equip.slots, "/"),
					if def.equip.twoHanded then " (two-handed)" else "", tostring(def.equip.durability or "-"),
					tostring(def.equip.affixClass or "none"), table.concat(stats, ", ")))
			end
			if def.focus then
				table.insert(out, string.format("focus %s: %s, stability %.0f%%", def.focus.grade,
					table.concat(sortedKeys(def.focus.domains or {}), "/"), (def.focus.stability or 0) * 100))
			end
			if def.use then
				local kinds = {}
				for _, e in def.use.effects do
					table.insert(kinds, e.kind)
				end
				table.insert(out, string.format("use: %s (cooldown %ss%s)", table.concat(kinds, " + "), tostring(def.use.cooldown or 0),
					if def.use.consume == false then ", not consumed" else ""))
			end
			return table.concat(out, "\n")
		end,
	})

	admin:Register({
		name = "clearinv", category = "Items", description = "Empty a player's grid (equipment too with equipment=on). Quest items stay",
		args = { { name = "player", type = "player", default = "me" }, { name = "equipment", type = "boolean", default = false } },
		handler = function(ctx, a)
			local ok, removed = service:clear(a.player, a.equipment, "admin " .. ctx.player.UserId)
			return if ok then string.format("removed %d item(s) from %s", removed, a.player.Name) else "failed"
		end,
	})

	admin:Register({
		name = "setcoins", category = "Items", description = "Set a player's coins (and optionally rare currency)",
		args = {
			{ name = "player", type = "player", default = "me" },
			{ name = "amount", type = "integer", min = 0, max = ItemRules.inventory.maxCurrency },
			{ name = "rare", type = "integer", min = 0, max = ItemRules.inventory.maxRare, optional = true },
		},
		handler = function(ctx, a)
			local ok = service:setCurrency(a.player, a.amount, a.rare, "admin " .. ctx.player.UserId)
			return if ok then string.format("%s now has %d coins", a.player.Name, service:currency(a.player)) else "failed"
		end,
	})

	admin:Register({
		name = "coins", category = "Items", description = "Add (or with a negative number, spend) coins",
		args = { { name = "player", type = "player", default = "me" }, { name = "delta", type = "integer", min = -1e9, max = 1e9 } },
		handler = function(ctx, a)
			local ok = service:addCurrency(a.player, a.delta, "admin " .. ctx.player.UserId)
			return string.format("%s: %s, now %d coins", a.player.Name, if ok then "done" else "not enough coins", service:currency(a.player))
		end,
	})

	admin:Register({
		name = "repairall", category = "Items", description = "Full durability on every item a player carries",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			return string.format("repaired %d item(s)", service:repairAll(a.player))
		end,
	})

	local slotIds = {}
	for _, slot in ItemRules.equipSlots do
		table.insert(slotIds, slot.id)
	end
	admin:Register({
		name = "wear", category = "Items", description = "Take durability off an equipped item (test breaking and repair)",
		args = {
			{ name = "player", type = "player", default = "me" },
			{ name = "slot", type = "enum", options = slotIds },
			{ name = "amount", type = "integer", min = 1, max = 100000, default = 10 },
		},
		handler = function(_, a)
			if not service:wear(a.player, a.slot, a.amount) then
				return "nothing that wears in " .. a.slot
			end
			local rec = service:inventoryOf(a.player).equip[a.slot]
			return line(rec)
		end,
	})

	admin:Register({
		name = "itemstats", category = "Items", description = "The derived stat sheet: every contribution in calculation order, then the totals",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local sheet = service:sheet(a.player)
			if not sheet then
				return "not loaded"
			end
			local out = { string.format("load %s: weight %.1f / carry %.0f", sheet.load, sheet.weight, sheet.carry) }
			for _, l in sheet.lines do
				local name = if string.sub(l.stat, 1, 7) == "resist:" then l.stat else (StatDefs.byId[l.stat] and StatDefs.byId[l.stat].name or l.stat)
				local value = if string.sub(l.stat, 1, 7) == "resist:" then string.format("%+.1f%%", l.value * 100) else StatDefs.format(l.stat, l.value)
				table.insert(out, string.format("  %-8s %-24s %-26s %s", l.source, name, l.label, value))
			end
			table.insert(out, "totals:")
			for _, def in StatDefs.list do
				local v = sheet.final[def.id]
				if v and v ~= def.base and not StatDefs.itemLocal[def.id] then
					table.insert(out, string.format("  %-24s %s%s", def.name, StatDefs.format(def.id, v), if def.wired then "  (matters once: " .. def.wired .. ")" else ""))
				end
			end
			for _, key in sortedKeys(sheet.resist) do
				table.insert(out, string.format("  resist %-17s %+.1f%%", key, sheet.resist[key] * 100))
			end
			return table.concat(out, "\n")
		end,
	})

	admin:Register({
		name = "itemroll", category = "Items", description = "Roll an item n times: rarity shares, affix frequency and stat ranges (balance check)",
		args = {
			{ name = "item", type = "item" },
			{ name = "n", type = "integer", min = 1, max = 20000, default = 1000 },
			{ name = "luck", type = "number", min = 0, max = 5, default = 0 },
		},
		handler = function(_, a)
			local rarityCount: { number } = {}
			local affixCount: { [string]: number } = {}
			local ranges: { [string]: { number } } = {}
			local started = os.clock()
			for i = 1, a.n do
				local rec = ItemGenerator.roll(a.item, ItemGenerator.rng(1337, "itemroll", i), { luck = a.luck })
				if rec then
					local r = ItemInstance.rarityIndex(rec)
					rarityCount[r] = (rarityCount[r] or 0) + 1
					for id in (rec.a or {}) :: any do
						affixCount[id] = (affixCount[id] or 0) + 1
					end
					for stat, v in ItemInstance.rolled(rec).stats do
						local range = ranges[stat] or { math.huge, -math.huge }
						ranges[stat] = range
						range[1], range[2] = math.min(range[1], v), math.max(range[2], v)
					end
				end
			end
			local out = { string.format("%s x%d (luck %.1f) in %.0f ms", a.item, a.n, a.luck, (os.clock() - started) * 1000) }
			for i, r in Rarities.list do
				if rarityCount[i] then
					table.insert(out, string.format("  %-10s %5.1f%%", r.name, rarityCount[i] / a.n * 100))
				end
			end
			local affixIds = sortedKeys(affixCount)
			table.sort(affixIds, function(x, y)
				return affixCount[x] > affixCount[y]
			end)
			local top = {}
			for i = 1, math.min(12, #affixIds) do
				table.insert(top, string.format("%s %.1f%%", affixIds[i], affixCount[affixIds[i]] / a.n * 100))
			end
			table.insert(out, "  affixes: " .. (if #top > 0 then table.concat(top, ", ") else "none (not affixable)"))
			for _, stat in sortedKeys(ranges) do
				local range = ranges[stat]
				table.insert(out, string.format("  %-22s %s .. %s", stat, StatDefs.format(stat, range[1]), StatDefs.format(stat, range[2])))
			end
			return table.concat(out, "\n")
		end,
	})

	admin:Register({
		name = "invlog", category = "Items", description = "The last inventory operations for a player (server memory, newest last)",
		args = { { name = "player", type = "player", default = "me" }, { name = "count", type = "integer", min = 1, max = 200, default = 25 } },
		handler = function(_, a)
			local entries = service:recentLog(a.player)
			if #entries == 0 then
				return "no operations yet"
			end
			return table.concat(entries, "\n", math.max(1, #entries - a.count + 1), #entries)
		end,
	})
end

return AdminCommands
