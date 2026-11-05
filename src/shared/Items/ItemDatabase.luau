--!strict
--[[
	ItemDatabase: the one place item data is read from (docs/Items.md §2). Shared: the server
	validates and simulates with it, the client draws tooltips with it.

		ItemDatabase.VERSION                 bump when existing items change meaning (saves keep ids)
		ItemDatabase.get(id) -> ItemDef?     follows aliases (renamed ids)
		ItemDatabase.resolve(id) -> string?  the current id for an old or current id
		ItemDatabase.ids                     every item id, sorted
		ItemDatabase.byCategory[cat]         ids per category
		ItemDatabase.withTag(tag) -> { id }  every item carrying a tag ("metal_ingot", "food"...)
		ItemDatabase.affix(id) / .affixes    affix definitions
		ItemDatabase.set(id)                 gear sets
		ItemDatabase.rarity(index|id)        rarity definitions
		ItemDatabase.isStackable(def)        stack > 1 (stackables carry no per-instance state)

	Requiring this module validates every definition: a bad item, affix or set errors at boot
	with its id, before any player touches it (same policy as Magic/Registry).
]]

local Shared = script.Parent.Parent
local Registry = require(Shared.Magic.Registry)
local ItemTypes = require(script.Parent.ItemTypes)
local Data = script.Parent.Data
local Items = require(Data.Items)
local Affixes = require(Data.Affixes)
local Rarities = require(Data.Rarities)
local StatDefs = require(Data.StatDefs)
local ItemRules = require(Data.ItemRules)

type ItemDef = ItemTypes.ItemDef
type AffixDef = ItemTypes.AffixDef

local ItemDatabase = {}

ItemDatabase.VERSION = 1

-- Renamed item ids: old id -> current id. Never remove an entry (old saves still hold it).
ItemDatabase.aliases = {} :: { [string]: string }

local defs: { [string]: ItemDef } = {}
local affixes: { [string]: AffixDef } = {}
local sets: { [string]: ItemTypes.SetDef } = {}
local tagIndex: { [string]: { string } } = {}

ItemDatabase.ids = {} :: { string }
ItemDatabase.byCategory = {} :: { [string]: { string } }
ItemDatabase.affixes = Affixes.list
ItemDatabase.affixIds = {} :: { string }
ItemDatabase.sets = Affixes.sets

-- ─── Validation ─────────────────────────────────────────────────────────────

local AFFIX_CLASSES = { weapon = true, focus = true, armor = true, jewelry = true, tool = true }
local USE_KINDS = { heal = true, reservoir = true, buff = true, study = true, spell = true, repair = true, cleanse = true }
local ID_PATTERN = "^[a-z][a-z0-9_]*$"

local function resistKeyValid(key: string): boolean
	return key == "all" or Registry.domains[key] ~= nil or Registry.properties[key] ~= nil
end

local function checkStats(owner: string, stats: { [string]: any }?)
	for statId in (stats or {}) :: any do
		assert(StatDefs.byId[statId], owner .. ": unknown stat " .. tostring(statId))
	end
end

local function checkResist(owner: string, resist: { [string]: any }?)
	for key in (resist or {}) :: any do
		assert(resistKeyValid(key), owner .. ": unknown resistance key " .. tostring(key))
	end
end

local function checkRequirement(owner: string, req: ItemTypes.Requirement?)
	if not req then
		return
	end
	for key, tier in (req.tier or {}) :: any do
		assert(key == "any" or Registry.branches[key] or Registry.domains[key], owner .. ": unknown tier key " .. key)
		assert(typeof(tier) == "number" and tier >= 0 and tier <= 8, owner .. ": tier must be 0..8")
	end
	for domain, v in (req.affinity or {}) :: any do
		assert(Registry.domains[domain], owner .. ": unknown affinity domain " .. domain)
		assert(typeof(v) == "number" and v >= 0 and v <= 1, owner .. ": affinity must be 0..1")
	end
	for _, domain in (req.awakened or {}) :: { string } do
		assert(Registry.domains[domain], owner .. ": unknown awakened domain " .. domain)
	end
end

local function validateItem(def: ItemDef)
	local id = def.id
	local owner = "item " .. tostring(id)
	assert(typeof(id) == "string" and string.match(id, ID_PATTERN) and #id <= 32, owner .. ": bad id")
	assert(defs[id] == nil, owner .. ": duplicate id")
	assert(typeof(def.name) == "string" and def.name ~= "", owner .. ": name required")
	assert(typeof(def.description) == "string", owner .. ": description required")
	assert(ItemRules.categories[def.category], owner .. ": unknown category " .. tostring(def.category))
	assert(Rarities.byId[def.rarity], owner .. ": unknown rarity " .. tostring(def.rarity))
	assert(def.stack >= 1 and def.stack <= ItemRules.inventory.maxStack and def.stack % 1 == 0, owner .. ": bad stack")
	assert(def.weight >= 0 and def.value >= 0, owner .. ": weight and value must be >= 0")
	assert(typeof(def.color) == "Color3", owner .. ": color must be a Color3")
	checkRequirement(owner, def.requires)

	local equip = def.equip
	if equip then
		assert(def.stack == 1, owner .. ": equippable items can't stack")
		assert(#equip.slots > 0, owner .. ": equip needs slots")
		for _, slot in equip.slots do
			assert(ItemRules.slotById[slot], owner .. ": unknown equip slot " .. slot)
		end
		assert(not equip.twoHanded or (#equip.slots == 1 and equip.slots[1] == "mainHand"), owner .. ": two-handed items go in mainHand only")
		assert(equip.affixClass == nil or AFFIX_CLASSES[equip.affixClass], owner .. ": unknown affix class")
		assert(equip.durability == nil or equip.durability > 0, owner .. ": durability must be > 0")
		checkStats(owner, equip.stats)
		checkResist(owner, equip.resist)
		if equip.attune then
			checkRequirement(owner .. " attune", equip.attune.requires)
			checkStats(owner .. " attune", equip.attune.stats)
			checkResist(owner .. " attune", equip.attune.resist)
		end
		local isBag = table.find(equip.slots, "bag1") ~= nil
		assert(isBag == (equip.bagSlots ~= nil), owner .. ": bags (and only bags) need bagSlots")
	end
	if def.focus then
		assert(equip, owner .. ": a focus must be equippable")
		assert(def.focus.grade == "major" or def.focus.grade == "minor", owner .. ": focus grade must be major or minor")
		for domain in (def.focus.domains or {}) :: any do
			assert(domain == "any" or Registry.domains[domain], owner .. ": unknown focus domain " .. domain)
		end
	end
	if def.use then
		assert(#def.use.effects > 0, owner .. ": use needs effects")
		for _, effect in def.use.effects do
			assert(USE_KINDS[effect.kind], owner .. ": unknown use effect " .. tostring(effect.kind))
			if effect.kind == "buff" then
				assert(typeof(effect.id) == "string" and typeof(effect.duration) == "number", owner .. ": buff needs id and duration")
				checkStats(owner .. " buff", effect.stats)
				checkResist(owner .. " buff", effect.resist)
			elseif effect.kind == "study" then
				assert(Registry.branches[effect.branch], owner .. ": study needs a real branch")
			elseif effect.kind == "spell" then
				assert(typeof(effect.recipe) == "table", owner .. ": spell needs a recipe")
			end
		end
	end
	assert(not (def.unique and def.stack > 1), owner .. ": unique items can't stack")
	assert(def.bind == nil or def.bind == "pickup" or def.bind == "equip", owner .. ": bind must be pickup or equip")
end

local function validateAffix(def: AffixDef)
	local owner = "affix " .. tostring(def.id)
	assert(typeof(def.id) == "string" and string.match(def.id, ID_PATTERN), owner .. ": bad id")
	assert(affixes[def.id] == nil, owner .. ": duplicate id")
	assert(def.kind == "prefix" or def.kind == "suffix", owner .. ": kind must be prefix or suffix")
	assert(typeof(def.group) == "string", owner .. ": group required")
	assert(#def.on > 0, owner .. ": `on` needs at least one class")
	for _, class in def.on do
		assert(AFFIX_CLASSES[class], owner .. ": unknown class " .. class)
	end
	assert(def.minRarity >= 2 and def.minRarity <= Rarities.LEGENDARY, owner .. ": minRarity must be 2..5")
	assert(def.weight > 0, owner .. ": weight must be > 0")
	assert(def.stats or def.resist or def.set, owner .. ": an affix must do something")
	for statId, range in (def.stats or {}) :: any do
		assert(StatDefs.byId[statId], owner .. ": unknown stat " .. statId)
		assert(#range == 2 and typeof(range[1]) == "number" and typeof(range[2]) == "number", owner .. ": ranges are { min, max }")
	end
	for key, range in (def.resist or {}) :: any do
		assert(resistKeyValid(key), owner .. ": unknown resistance key " .. key)
		assert(#range == 2, owner .. ": ranges are { min, max }")
	end
	checkRequirement(owner, def.attune)
end

for _, def in Items do
	validateItem(def)
	defs[def.id] = def
	table.insert(ItemDatabase.ids, def.id)
	local list = ItemDatabase.byCategory[def.category] or {}
	ItemDatabase.byCategory[def.category] = list
	table.insert(list, def.id)
	for _, tag in def.tags do
		local tagged = tagIndex[tag] or {}
		tagIndex[tag] = tagged
		table.insert(tagged, def.id)
	end
end
table.sort(ItemDatabase.ids)

for _, def in Affixes.list do
	validateAffix(def)
	affixes[def.id] = def
	table.insert(ItemDatabase.affixIds, def.id)
end
table.sort(ItemDatabase.affixIds)

for _, set in Affixes.sets do
	assert(sets[set.id] == nil, "set " .. set.id .. ": duplicate")
	for _, bonus in set.bonuses do
		checkStats("set " .. set.id, bonus.stats)
		checkResist("set " .. set.id, bonus.resist)
	end
	sets[set.id] = set
end
for _, def in Affixes.list do
	assert(def.set == nil or sets[def.set], "affix " .. def.id .. ": unknown set " .. tostring(def.set))
end

for old, new in ItemDatabase.aliases do
	assert(defs[old] == nil, "alias " .. old .. " shadows a live item")
	assert(defs[new], "alias " .. old .. " points at unknown item " .. new)
end

for _, entry in ItemRules.starterKit do
	assert(defs[entry.id], "starterKit: unknown item " .. entry.id)
end

-- ─── Lookups ────────────────────────────────────────────────────────────────

function ItemDatabase.resolve(id: string): string?
	if defs[id] then
		return id
	end
	local new = ItemDatabase.aliases[id]
	return if new and defs[new] then new else nil
end

function ItemDatabase.get(id: string): ItemDef?
	local resolved = ItemDatabase.resolve(id)
	return if resolved then defs[resolved] else nil
end

function ItemDatabase.withTag(tag: string): { string }
	return tagIndex[tag] or {}
end

function ItemDatabase.affix(id: string): AffixDef?
	return affixes[id]
end

function ItemDatabase.set(id: string): ItemTypes.SetDef?
	return sets[id]
end

function ItemDatabase.rarity(key: number | string): ItemTypes.RarityDef?
	if typeof(key) == "number" then
		return Rarities.list[key]
	end
	return Rarities.byId[key :: string]
end

function ItemDatabase.isStackable(def: ItemDef): boolean
	return def.stack > 1
end

-- Item ids whose name or id contains `text` (admin autocomplete, inventory search).
function ItemDatabase.search(text: string): { string }
	local needle = string.lower(text)
	local out: { string } = {}
	for _, id in ItemDatabase.ids do
		if string.find(id, needle, 1, true) or string.find(string.lower(defs[id].name), needle, 1, true) then
			table.insert(out, id)
		end
	end
	return out
end

return ItemDatabase
