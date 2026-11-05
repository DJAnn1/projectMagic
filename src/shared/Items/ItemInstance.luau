--!strict
--[[
	ItemInstance: the instance model (docs/Items.md §2.5). A definition is static and shared; an
	instance (Record) stores only what differs from it, in short keys, so a full inventory stays a
	few kilobytes in the player's save.

		i  item id            n  count (nil = 1)        u  unique id (stack-1 items only)
		r  rarity index       a  affix id -> roll 0..999 d  durability (nil = full)
		q  quality 0..100     c  crafter name           cn custom name (filtered)
		b  bound              f  flag bits              ch charges          t  minted (unix)

	Affix VALUES are never saved: they're re-derived from the roll, the affix's range and the
	rarity band, so retuning Data/Affixes retunes every existing item.

	Pure and shared: the server derives stats with it, the client draws tooltips with it.

		ItemInstance.def(rec) / .rarity(rec)
		ItemInstance.rolled(rec) -> Rolled         base + affix stats, resistances, sets, gated parts
		ItemInstance.displayName(rec) -> string    "Ember-touched Oak Staff of Resonance"
		ItemInstance.weight(rec) / .value(rec) / .maxDurability(rec) / .durability(rec) / .isBroken(rec)
		ItemInstance.canStack(a, b) / .validate(rec) / .meets(requirement, caster)
		ItemInstance.hasFlag / .setFlag            FAVORITE, LOCKED, NEW
]]

local Shared = script.Parent.Parent
local MagicCore = require(Shared.Magic.MagicCore)
local MasteryTiers = require(Shared.Magic.Data.MasteryTiers)
local Registry = require(Shared.Magic.Registry)
local ItemTypes = require(script.Parent.ItemTypes)
local ItemDatabase = require(script.Parent.ItemDatabase)
local StatDefs = require(script.Parent.Data.StatDefs)

type Record = ItemTypes.Record
type ItemDef = ItemTypes.ItemDef

export type Gated = {
	requires: ItemTypes.Requirement,
	stats: { [string]: number },
	resist: { [string]: number },
	text: string,
}

export type Rolled = {
	stats: { [string]: number }, -- character stats this item gives (active when worn, not broken)
	resist: { [string]: number },
	itemLocal: { [string]: number }, -- itemWeightPct, durabilityPct
	sets: { string },
	gated: { Gated }, -- only for a wearer who meets `requires`
	affixes: { { id: string, name: string, kind: string, stats: { [string]: number }, resist: { [string]: number }, text: string? } },
}

local ItemInstance = {}

ItemInstance.FAVORITE = 1
ItemInstance.LOCKED = 2
ItemInstance.NEW = 4

ItemInstance.ROLL_MAX = 999

-- ─── Basics ─────────────────────────────────────────────────────────────────

function ItemInstance.def(rec: Record): ItemDef?
	return ItemDatabase.get(rec.i)
end

function ItemInstance.count(rec: Record): number
	return rec.n or 1
end

function ItemInstance.rarityIndex(rec: Record): number
	if rec.r then
		return rec.r
	end
	local def = ItemDatabase.get(rec.i)
	local r = def and ItemDatabase.rarity(def.rarity)
	return if r then r.index else 1
end

function ItemInstance.rarity(rec: Record): ItemTypes.RarityDef
	return ItemDatabase.rarity(ItemInstance.rarityIndex(rec)) or (ItemDatabase.rarity(1) :: ItemTypes.RarityDef)
end

function ItemInstance.hasFlag(rec: Record, flag: number): boolean
	return bit32.band(rec.f or 0, flag) ~= 0
end

function ItemInstance.setFlag(rec: Record, flag: number, on: boolean)
	local f = rec.f or 0
	f = if on then bit32.bor(f, flag) else bit32.band(f, bit32.bnot(flag))
	rec.f = if f == 0 then nil else f
end

-- Crafted quality: 50 is standard (x1.0); 0 is x0.85, 100 is x1.15.
function ItemInstance.qualityMult(rec: Record): number
	return 0.85 + 0.3 * math.clamp(rec.q or 50, 0, 100) / 100
end

-- ─── Rolled stats ───────────────────────────────────────────────────────────

-- One affix stat: the roll (0..999) lands inside the rarity's band of the affix's range.
function ItemInstance.affixValue(statId: string, range: { number }, roll: number, rarityIndex: number): number
	local def = StatDefs.byId[statId]
	if def and def.format == "int" then
		return range[2]
	end
	local rarity = ItemDatabase.rarity(rarityIndex) or ItemDatabase.rarity(1)
	local band = (rarity :: ItemTypes.RarityDef).band
	local t = band[1] + (band[2] - band[1]) * math.clamp(roll, 0, ItemInstance.ROLL_MAX) / ItemInstance.ROLL_MAX
	return range[1] + (range[2] - range[1]) * t
end

local function addInto(target: { [string]: number }, source: { [string]: number }?, mult: number)
	for key, v in (source or {}) :: any do
		target[key] = (target[key] or 0) + v * mult
	end
end

-- Affix ids in a stable order: prefixes first, then suffixes, each alphabetical.
local function orderedAffixes(rec: Record): { string }
	local ids: { string } = {}
	for id in (rec.a or {}) :: any do
		if ItemDatabase.affix(id) then
			table.insert(ids, id)
		end
	end
	table.sort(ids, function(x, y)
		local ax, ay = ItemDatabase.affix(x) :: ItemTypes.AffixDef, ItemDatabase.affix(y) :: ItemTypes.AffixDef
		if ax.kind ~= ay.kind then
			return ax.kind == "prefix"
		end
		return x < y
	end)
	return ids
end
ItemInstance.orderedAffixes = orderedAffixes

function ItemInstance.rolled(rec: Record): Rolled
	local out: Rolled = { stats = {}, resist = {}, itemLocal = {}, sets = {}, gated = {}, affixes = {} }
	local def = ItemDatabase.get(rec.i)
	local equip = def and def.equip
	if not def or not equip then
		return out
	end
	local rarityIndex = ItemInstance.rarityIndex(rec)
	local rarity = ItemInstance.rarity(rec)
	local mult = rarity.baseMult * ItemInstance.qualityMult(rec)

	-- Base stats scale with rarity and quality; int stats (slots, form reach) never scale.
	for statId, v in (equip.stats or {}) :: any do
		local sd = StatDefs.byId[statId]
		local value = if sd and sd.format == "int" then v else v * mult
		if StatDefs.itemLocal[statId] then
			out.itemLocal[statId] = (out.itemLocal[statId] or 0) + value
		else
			out.stats[statId] = (out.stats[statId] or 0) + value
		end
	end
	addInto(out.resist, equip.resist, mult)
	if equip.attune then
		local g: Gated = { requires = equip.attune.requires, stats = {}, resist = {}, text = equip.attune.text }
		addInto(g.stats, equip.attune.stats, 1)
		addInto(g.resist, equip.attune.resist, 1)
		table.insert(out.gated, g)
	end

	for _, affixId in orderedAffixes(rec) do
		local affix = ItemDatabase.affix(affixId) :: ItemTypes.AffixDef
		local roll = (rec.a :: { [string]: number })[affixId]
		local stats: { [string]: number } = {}
		local resist: { [string]: number } = {}
		for statId, range in (affix.stats or {}) :: any do
			stats[statId] = ItemInstance.affixValue(statId, range, roll, rarityIndex)
		end
		for key, range in (affix.resist or {}) :: any do
			resist[key] = ItemInstance.affixValue("", range, roll, rarityIndex)
		end
		table.insert(out.affixes, { id = affixId, name = affix.name, kind = affix.kind, stats = stats, resist = resist, text = affix.text })
		if affix.set then
			table.insert(out.sets, affix.set)
		end
		if affix.attune then
			local g: Gated = { requires = affix.attune, stats = stats, resist = resist, text = affix.text or affix.name }
			table.insert(out.gated, g)
		else
			for statId, v in stats do
				if StatDefs.itemLocal[statId] then
					out.itemLocal[statId] = (out.itemLocal[statId] or 0) + v
				else
					out.stats[statId] = (out.stats[statId] or 0) + v
				end
			end
			addInto(out.resist, resist, 1)
		end
	end
	return out
end

-- ─── Derived properties ─────────────────────────────────────────────────────

function ItemInstance.maxDurability(rec: Record): number?
	local def = ItemDatabase.get(rec.i)
	local base = def and def.equip and def.equip.durability
	if not base then
		return nil
	end
	local bonus = 0
	local rarityIndex = ItemInstance.rarityIndex(rec)
	for affixId, roll in (rec.a or {}) :: any do
		local affix = ItemDatabase.affix(affixId)
		local range = affix and affix.stats and affix.stats.durabilityPct
		if range then
			bonus += ItemInstance.affixValue("durabilityPct", range, roll, rarityIndex)
		end
	end
	return math.floor(base * (1 + bonus) * ItemInstance.qualityMult(rec) + 0.5)
end

function ItemInstance.durability(rec: Record): number?
	local max = ItemInstance.maxDurability(rec)
	if not max then
		return nil
	end
	return math.clamp(rec.d or max, 0, max)
end

function ItemInstance.isBroken(rec: Record): boolean
	return rec.d ~= nil and rec.d <= 0 and ItemInstance.maxDurability(rec) ~= nil
end

function ItemInstance.weight(rec: Record): number
	local def = ItemDatabase.get(rec.i)
	if not def then
		return 0
	end
	local pct = 0
	if rec.a then
		local rarityIndex = ItemInstance.rarityIndex(rec)
		for affixId, roll in rec.a do
			local affix = ItemDatabase.affix(affixId)
			local range = affix and affix.stats and affix.stats.itemWeightPct
			if range then
				pct += ItemInstance.affixValue("itemWeightPct", range, roll, rarityIndex)
			end
		end
	end
	return def.weight * ItemInstance.count(rec) * math.max(0.1, 1 + pct)
end

-- Base coin value of the whole stack (the economy stage adds regional prices on top).
function ItemInstance.value(rec: Record): number
	local def = ItemDatabase.get(rec.i)
	if not def then
		return 0
	end
	local v = def.value * ItemInstance.rarity(rec).valueMult * ItemInstance.qualityMult(rec)
	if ItemInstance.isBroken(rec) then
		v *= 0.25
	end
	return math.floor(v * ItemInstance.count(rec) + 0.5)
end

function ItemInstance.displayName(rec: Record): string
	if rec.cn and rec.cn ~= "" then
		return rec.cn
	end
	local def = ItemDatabase.get(rec.i)
	if not def then
		return "Unknown item (" .. tostring(rec.i) .. ")"
	end
	local prefix, suffix = nil, nil
	for _, affixId in orderedAffixes(rec) do
		local affix = ItemDatabase.affix(affixId) :: ItemTypes.AffixDef
		if affix.kind == "prefix" and not prefix then
			prefix = affix.name
		elseif affix.kind == "suffix" and not suffix then
			suffix = affix.name
		end
	end
	local name = def.name
	if prefix then
		name = prefix .. " " .. name
	end
	if suffix then
		name = name .. " " .. suffix
	end
	return name
end

-- Two records can merge into one stack: same item, stackable, and no per-instance state.
function ItemInstance.canStack(a: Record, b: Record): boolean
	if a.i ~= b.i then
		return false
	end
	local def = ItemDatabase.get(a.i)
	if not def or def.stack <= 1 then
		return false
	end
	return a.u == nil and b.u == nil and a.a == nil and b.a == nil and a.d == nil and b.d == nil
		and a.q == b.q and a.b == b.b and a.ch == nil and b.ch == nil
end

-- ─── Validation (loads and saves) ───────────────────────────────────────────

local KNOWN_KEYS = { i = true, n = true, u = true, r = true, a = true, d = true, q = true, c = true, cn = true, b = true, f = true, ch = true, t = true }

local function isInt(v: any, lo: number, hi: number): boolean
	return typeof(v) == "number" and v == v and v % 1 == 0 and v >= lo and v <= hi
end

-- Structural check of a saved record. Unknown item ids pass (they're kept, shown as unknown,
-- and recovered if the id comes back or gets an alias); malformed fields fail.
function ItemInstance.validate(rec: any): (boolean, string?)
	if typeof(rec) ~= "table" then
		return false, "not a table"
	end
	for key in rec do
		if not KNOWN_KEYS[key] then
			return false, "unknown key " .. tostring(key)
		end
	end
	if typeof(rec.i) ~= "string" or #rec.i == 0 or #rec.i > 48 then
		return false, "bad item id"
	end
	local def = ItemDatabase.get(rec.i)
	local maxStack = if def then def.stack else 999
	if rec.n ~= nil and not isInt(rec.n, 2, maxStack) then
		return false, "bad count"
	end
	if def and def.stack == 1 and typeof(rec.u) ~= "string" then
		return false, "unique item without uid"
	end
	if rec.u ~= nil and (typeof(rec.u) ~= "string" or #rec.u > 32) then
		return false, "bad uid"
	end
	if rec.r ~= nil and not isInt(rec.r, 1, 6) then
		return false, "bad rarity"
	end
	if rec.a ~= nil then
		if typeof(rec.a) ~= "table" then
			return false, "bad affixes"
		end
		local count = 0
		for id, roll in rec.a do
			count += 1
			if typeof(id) ~= "string" or not isInt(roll, 0, ItemInstance.ROLL_MAX) or count > 8 then
				return false, "bad affix " .. tostring(id)
			end
		end
	end
	if rec.d ~= nil and not isInt(rec.d, 0, 100000) then
		return false, "bad durability"
	end
	if rec.q ~= nil and not isInt(rec.q, 0, 100) then
		return false, "bad quality"
	end
	if rec.f ~= nil and not isInt(rec.f, 0, 255) then
		return false, "bad flags"
	end
	if rec.ch ~= nil and not isInt(rec.ch, 0, 1000) then
		return false, "bad charges"
	end
	for _, key in { "c", "cn" } do
		local v = rec[key]
		if v ~= nil and (typeof(v) ~= "string" or #v > 64) then
			return false, "bad " .. key
		end
	end
	return true, nil
end

-- ─── Requirements ───────────────────────────────────────────────────────────

-- Whether a caster meets a requirement; the second result is the first unmet part, in words.
function ItemInstance.meets(req: ItemTypes.Requirement?, caster: any?): (boolean, string?)
	if not req then
		return true, nil
	end
	if not caster then
		return false, "unknown caster"
	end
	for key, tier in (req.tier or {}) :: any do
		local have = 0
		if key == "any" then
			for branchId in (caster.mastery or {}) :: any do
				if Registry.branches[branchId] then
					have = math.max(have, MagicCore.masteryTier(caster, branchId))
				end
			end
		elseif Registry.branches[key] then
			have = MagicCore.masteryTier(caster, key)
		end
		if have < tier then
			local tierDef = MasteryTiers.tiers[tier + 1]
			local where = if key == "any" then "any branch" else (Registry.branches[key] and Registry.branches[key].name or key)
			return false, string.format("needs %s in %s", tierDef and tierDef.name or ("tier " .. tier), where)
		end
	end
	for domain, need in (req.affinity or {}) :: any do
		if (caster.affinities and caster.affinities[domain] or 0) < need then
			local d = Registry.domains[domain]
			return false, string.format("needs a strong %s affinity", d and d.name or domain)
		end
	end
	for _, domain in (req.awakened or {}) :: { string } do
		if not (caster.awakened and caster.awakened[domain]) then
			local d = Registry.domains[domain]
			return false, string.format("needs %s awakened", d and d.name or domain)
		end
	end
	return true, nil
end

return ItemInstance
