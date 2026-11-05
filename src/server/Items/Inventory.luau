--!strict
--[[
	Inventory: the pure inventory model (docs/Items.md §3). No Instances, no remotes, no yields,
	so every rule is unit-tested (Tests/Items.spec) and InventoryService stays thin.

	DATA (lives in the player save as data.inventory; see Persistence/Schemas v4)
		slots     "1".."72" -> Record   (string keys: DataStores can't hold sparse arrays)
		equip     slot id -> Record     (ItemRules.equipSlots)
		quick     "1".."4" -> "i:<itemId>" (any stack of it) | "u:<uid>" (that item)
		currency, rare, nextUid, audit, starter, quarantine

	REFS name a place: "s12" = grid slot 12, "e:head" = an equipment slot.

	TRANSACTIONS: Inventory.transact(inv, fn) snapshots the inventory, runs fn, then checks every
	invariant. If fn errors, returns false, or leaves the inventory invalid, the snapshot is
	restored: an operation either happens completely or not at all. Invariants (Inventory.check):
	counts within stack caps, uniques carry a uid, no uid twice, each item in a slot it fits,
	nothing new placed beyond capacity, a two-handed main hand means an empty off hand.

	Overflow: if capacity shrinks under items (a bag definition changed), those items stay in
	their slots and can be moved out, never into.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ItemTypes = require(Shared.Items.ItemTypes)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local ItemRules = require(Shared.Items.Data.ItemRules)

type Record = ItemTypes.Record

export type Inv = {
	currency: number,
	rare: number,
	slots: { [string]: Record },
	equip: { [string]: Record },
	quick: { [string]: string },
	nextUid: number,
	audit: { { t: number, op: string, d: string } },
	starter: boolean?,
	quarantine: { any }?,
	cap: number?, -- fixed capacity (containers); players' capacity comes from bags
}

-- Callbacks the service supplies (requirements need the caster; binding marks the record).
export type Rules = {
	canEquip: ((rec: Record, slot: string) -> (boolean, string?))?,
	onEquip: ((rec: Record) -> ())?,
}

local R = ItemRules.inventory

local Inventory = {}

-- ─── Construction and loading ───────────────────────────────────────────────

function Inventory.new(): Inv
	return { currency = 0, rare = 0, slots = {}, equip = {}, quick = {}, nextUid = 0, audit = {} }
end

-- Base-36, for short uids.
local DIGITS = "0123456789abcdefghijklmnopqrstuvwxyz"
local function base36(n: number): string
	n = math.floor(math.abs(n))
	if n == 0 then
		return "0"
	end
	local out = ""
	while n > 0 do
		local d = n % 36
		out = string.sub(DIGITS, d + 1, d + 1) .. out
		n = (n - d) / 36
	end
	return out
end
Inventory.base36 = base36

-- "<owner>.<counter>": the owner key keeps uids unique across players (they travel by trade).
function Inventory.mintUid(inv: Inv, ownerKey: string): string
	inv.nextUid += 1
	return ownerKey .. "." .. base36(inv.nextUid)
end

-- The uid prefix for a player (test players have negative ids).
function Inventory.ownerKey(userId: number): string
	return (if userId < 0 then "n" else "") .. base36(userId)
end

local function isTwoHandedRecord(rec: Record?): boolean
	local def = rec and ItemDatabase.get(rec.i)
	return def ~= nil and def.equip ~= nil and def.equip.twoHanded == true
end

export type LoadReport = { quarantined: number, duplicates: number, upgraded: boolean }

--[[
	Turns a saved inventory (any shape this game ever saved) into a valid Inv, in place.
	Malformed records and duplicate uids move to inv.quarantine (kept for support, never lost);
	renamed ids are resolved through ItemDatabase.aliases.
]]
function Inventory.normalize(raw: any): (Inv, LoadReport)
	local report: LoadReport = { quarantined = 0, duplicates = 0, upgraded = false }
	local inv: any = if typeof(raw) == "table" then raw else {}
	inv.currency = if typeof(inv.currency) == "number" and inv.currency == inv.currency then math.clamp(math.floor(inv.currency), 0, R.maxCurrency) else 0
	inv.rare = if typeof(inv.rare) == "number" and inv.rare == inv.rare then math.clamp(math.floor(inv.rare), 0, R.maxRare) else 0
	inv.slots = if typeof(inv.slots) == "table" then inv.slots else {}
	inv.equip = if typeof(inv.equip) == "table" then inv.equip else {}
	inv.quick = if typeof(inv.quick) == "table" then inv.quick else {}
	inv.nextUid = if typeof(inv.nextUid) == "number" then math.max(0, math.floor(inv.nextUid)) else 0
	inv.audit = if typeof(inv.audit) == "table" then inv.audit else {}
	-- The v3 placeholder `items` list was never written to; fold it in if anything is there.
	if typeof(inv.items) == "table" then
		local legacy = inv.items
		inv.items = nil
		report.upgraded = true
		for _, rec in legacy do
			local n = 1
			while inv.slots[tostring(n)] do
				n += 1
			end
			inv.slots[tostring(n)] = rec
		end
	end

	local seen: { [string]: boolean } = {}
	local function quarantine(rec: any, why: string)
		inv.quarantine = inv.quarantine or {}
		table.insert(inv.quarantine, { rec = rec, why = why })
		report.quarantined += 1
	end
	local function clean(container: { [string]: any }, keyValid: (string) -> boolean)
		for key, rec in container do
			local ok, why = ItemInstance.validate(rec)
			if not keyValid(key) then
				ok, why = false, "bad place " .. tostring(key)
			end
			if ok then
				local current = ItemDatabase.resolve(rec.i)
				if current and current ~= rec.i then
					rec.i = current
				end
				if rec.u then
					if seen[rec.u] then
						ok, why = false, "duplicate uid " .. rec.u
						report.duplicates += 1
					end
					seen[rec.u] = true
				end
			end
			if not ok then
				container[key] = nil
				quarantine(rec, why or "invalid")
			end
		end
	end
	clean(inv.slots, function(key)
		local n = tonumber(key)
		return n ~= nil and n % 1 == 0 and n >= 1 and n <= R.maxSlots
	end)
	clean(inv.equip, function(key)
		return ItemRules.slotById[key] ~= nil
	end)
	-- Equipment that no longer fits its slot (a definition changed) goes back to the grid.
	for slot, rec in inv.equip do
		local def = ItemDatabase.get(rec.i)
		local fits = def ~= nil and def.equip ~= nil and table.find(def.equip.slots, slot) ~= nil
		local blocked = slot == "offHand" and inv.equip.mainHand ~= nil and isTwoHandedRecord(inv.equip.mainHand)
		if not fits or blocked then
			inv.equip[slot] = nil
			local n = 1
			while inv.slots[tostring(n)] and n <= R.maxSlots do
				n += 1
			end
			if n <= R.maxSlots then
				inv.slots[tostring(n)] = rec
			else
				quarantine(rec, "no room to unequip " .. slot)
			end
		end
	end
	for k, v in inv.quick do
		local n = tonumber(k)
		if not n or n < 1 or n > R.quickSlots or typeof(v) ~= "string" then
			inv.quick[k] = nil
		end
	end
	return inv :: Inv, report
end

-- ─── Places ─────────────────────────────────────────────────────────────────

function Inventory.capacity(inv: Inv): number
	if inv.cap then
		return inv.cap
	end
	local cap = R.baseSlots
	for _, slot in { "bag1", "bag2" } do
		local rec = inv.equip[slot]
		local def = rec and ItemDatabase.get(rec.i)
		if def and def.equip and def.equip.bagSlots then
			cap += def.equip.bagSlots
		end
	end
	return math.min(cap, R.maxSlots)
end

export type Place = { kind: string, key: string } -- kind "s" (grid) | "e" (equipment)

function Inventory.parse(ref: string): Place?
	if string.sub(ref, 1, 2) == "e:" then
		local slot = string.sub(ref, 3)
		return if ItemRules.slotById[slot] then { kind = "e", key = slot } else nil
	end
	local n = tonumber(string.match(ref, "^s(%d+)$"))
	if n and n >= 1 and n <= R.maxSlots then
		return { kind = "s", key = tostring(n) }
	end
	return nil
end

function Inventory.at(inv: Inv, ref: string): Record?
	local p = Inventory.parse(ref)
	if not p then
		return nil
	end
	return if p.kind == "s" then inv.slots[p.key] else inv.equip[p.key]
end

local function put(inv: Inv, p: Place, rec: Record?)
	-- (any: assigning nil clears the place)
	if p.kind == "s" then
		(inv.slots :: any)[p.key] = rec
	else
		(inv.equip :: any)[p.key] = rec
	end
end

local function get(inv: Inv, p: Place): Record?
	return if p.kind == "s" then inv.slots[p.key] else inv.equip[p.key]
end

function Inventory.findFree(inv: Inv, capacity: number?): number?
	local cap = capacity or Inventory.capacity(inv)
	for n = 1, cap do
		if inv.slots[tostring(n)] == nil then
			return n
		end
	end
	return nil
end

function Inventory.freeCount(inv: Inv): number
	local free = 0
	for n = 1, Inventory.capacity(inv) do
		if inv.slots[tostring(n)] == nil then
			free += 1
		end
	end
	return free
end

-- Every record with its ref: grid first (slot order), then equipment (paper-doll order).
function Inventory.each(inv: Inv): { { ref: string, rec: Record } }
	local out = {}
	local keys: { number } = {}
	for key in inv.slots do
		table.insert(keys, tonumber(key) :: number)
	end
	table.sort(keys)
	for _, n in keys do
		table.insert(out, { ref = "s" .. n, rec = inv.slots[tostring(n)] })
	end
	for _, slot in ItemRules.equipSlots do
		local rec = inv.equip[slot.id]
		if rec then
			table.insert(out, { ref = "e:" .. slot.id, rec = rec })
		end
	end
	return out
end

function Inventory.findUid(inv: Inv, uid: string): string?
	for _, entry in Inventory.each(inv) do
		if entry.rec.u == uid then
			return entry.ref
		end
	end
	return nil
end

-- ─── Counting and weight ────────────────────────────────────────────────────

-- How many of an item are in the grid (equipped items don't count: you can't craft with your boots on).
function Inventory.countOf(inv: Inv, itemId: string): number
	local total = 0
	for _, rec in inv.slots do
		if rec.i == itemId then
			total += ItemInstance.count(rec)
		end
	end
	return total
end

function Inventory.weight(inv: Inv): number
	local total = 0
	for _, rec in inv.slots do
		total += ItemInstance.weight(rec)
	end
	for _, rec in inv.equip do
		total += ItemInstance.weight(rec)
	end
	return math.floor(total * 100 + 0.5) / 100
end

local function ownsUnique(inv: Inv, itemId: string): boolean
	for _, entry in Inventory.each(inv) do
		if entry.rec.i == itemId then
			return true
		end
	end
	return false
end

-- ─── Adding and removing ────────────────────────────────────────────────────

--[[
	Adds a record. Stackables top up existing stacks first, then take empty slots; uniques need a
	free slot (and get a uid minted with `ownerKey` if they have none). Returns the count added
	and the leftover record (nil when everything fit). Marks new arrivals NEW.
]]
function Inventory.add(inv: Inv, rec: Record, ownerKey: string): (number, Record?)
	local def = ItemDatabase.get(rec.i)
	if not def then
		return 0, rec
	end
	local cap = Inventory.capacity(inv)
	if def.stack <= 1 then
		if def.unique and ownsUnique(inv, def.id) then
			return 0, rec
		end
		local free = Inventory.findFree(inv, cap)
		if not free then
			return 0, rec
		end
		if not rec.u then
			rec.u = Inventory.mintUid(inv, ownerKey)
		end
		ItemInstance.setFlag(rec, ItemInstance.NEW, true)
		inv.slots[tostring(free)] = rec
		return 1, nil
	end

	local remaining = ItemInstance.count(rec)
	local added = 0
	-- Top up existing stacks, in slot order.
	for n = 1, cap do
		local existing = inv.slots[tostring(n)]
		if remaining <= 0 then
			break
		end
		if existing and ItemInstance.canStack(existing, rec) then
			local room = def.stack - ItemInstance.count(existing)
			local moved = math.min(room, remaining)
			if moved > 0 then
				local total = ItemInstance.count(existing) + moved
				existing.n = if total > 1 then total else nil
				remaining -= moved
				added += moved
			end
		end
	end
	-- Then empty slots.
	while remaining > 0 do
		local free = Inventory.findFree(inv, cap)
		if not free then
			break
		end
		local moved = math.min(def.stack, remaining)
		local stack: Record = table.clone(rec)
		stack.n = if moved > 1 then moved else nil
		ItemInstance.setFlag(stack, ItemInstance.NEW, true)
		inv.slots[tostring(free)] = stack
		remaining -= moved
		added += moved
	end
	if remaining > 0 then
		local leftover: Record = table.clone(rec)
		leftover.n = if remaining > 1 then remaining else nil
		return added, leftover
	end
	return added, nil
end

-- Whether `rec` would fit completely, without changing anything.
function Inventory.fits(inv: Inv, rec: Record): boolean
	local def = ItemDatabase.get(rec.i)
	if not def then
		return false
	end
	if def.stack <= 1 then
		return Inventory.findFree(inv) ~= nil and not (def.unique and ownsUnique(inv, def.id))
	end
	local remaining = ItemInstance.count(rec)
	local cap = Inventory.capacity(inv)
	for n = 1, cap do
		local existing = inv.slots[tostring(n)]
		if not existing then
			remaining -= def.stack
		elseif ItemInstance.canStack(existing, rec) then
			remaining -= def.stack - ItemInstance.count(existing)
		end
		if remaining <= 0 then
			return true
		end
	end
	return remaining <= 0
end

-- Removes `count` of an item from the grid: all or nothing. Takes from the LAST stacks first, so
-- the stack you keep at the front stays put. Locked stacks are spent last.
function Inventory.removeItem(inv: Inv, itemId: string, count: number): boolean
	if Inventory.countOf(inv, itemId) < count then
		return false
	end
	local keys: { number } = {}
	for key, rec in inv.slots do
		if rec.i == itemId then
			table.insert(keys, tonumber(key) :: number)
		end
	end
	table.sort(keys, function(a, b)
		local la = ItemInstance.hasFlag(inv.slots[tostring(a)], ItemInstance.LOCKED)
		local lb = ItemInstance.hasFlag(inv.slots[tostring(b)], ItemInstance.LOCKED)
		if la ~= lb then
			return lb
		end
		return a > b
	end)
	local remaining = count
	for _, n in keys do
		local key = tostring(n)
		local rec = inv.slots[key]
		local have = ItemInstance.count(rec)
		local used = math.min(have, remaining)
		if used >= have then
			inv.slots[key] = nil
		else
			local left = have - used
			rec.n = if left > 1 then left else nil
		end
		remaining -= used
		if remaining <= 0 then
			break
		end
	end
	return true
end

-- Removes `count` items matching `predicate(def)` from the grid, all or nothing. Kinds are spent
-- in item-id order (predictable for recipes), each kind's last stacks first.
function Inventory.removeMatching(inv: Inv, predicate: (ItemTypes.ItemDef) -> boolean, count: number): boolean
	local have: { [string]: number } = {}
	local total = 0
	for _, rec in inv.slots do
		local def = ItemDatabase.get(rec.i)
		if def and predicate(def) then
			have[rec.i] = (have[rec.i] or 0) + ItemInstance.count(rec)
			total += ItemInstance.count(rec)
		end
	end
	if total < count then
		return false
	end
	local ids: { string } = {}
	for id in have do
		table.insert(ids, id)
	end
	table.sort(ids)
	local remaining = count
	for _, id in ids do
		local used = math.min(have[id], remaining)
		Inventory.removeItem(inv, id, used)
		remaining -= used
		if remaining <= 0 then
			break
		end
	end
	return true
end

function Inventory.countMatching(inv: Inv, predicate: (ItemTypes.ItemDef) -> boolean): number
	local total = 0
	for _, rec in inv.slots do
		local def = ItemDatabase.get(rec.i)
		if def and predicate(def) then
			total += ItemInstance.count(rec)
		end
	end
	return total
end

-- Takes `n` (default all) from a place and returns it as its own record.
function Inventory.take(inv: Inv, ref: string, n: number?): Record?
	local p = Inventory.parse(ref)
	local rec = p and get(inv, p :: Place)
	if not p or not rec then
		return nil
	end
	local have = ItemInstance.count(rec)
	local want = math.clamp(math.floor(n or have), 1, have)
	if want >= have then
		put(inv, p, nil)
		return rec
	end
	local part: Record = table.clone(rec)
	part.n = if want > 1 then want else nil
	local left = have - want
	rec.n = if left > 1 then left else nil
	return part
end

-- ─── Equipment rules ────────────────────────────────────────────────────────

local function fitsSlot(rec: Record, slot: string): (boolean, string?)
	local def = ItemDatabase.get(rec.i)
	if not def or not def.equip then
		return false, "NOT_EQUIPPABLE"
	end
	if not table.find(def.equip.slots, slot) then
		return false, "WRONG_SLOT"
	end
	return true, nil
end

local isTwoHanded = isTwoHandedRecord

-- Capacity if the bag slots held these records instead.
local function capacityWith(inv: Inv, slot: string, rec: Record?): number
	local equip = inv.equip :: any
	local saved = equip[slot]
	equip[slot] = rec
	local cap = Inventory.capacity(inv)
	equip[slot] = saved
	return cap
end

local function highestUsed(inv: Inv): number
	local high = 0
	for key in inv.slots do
		high = math.max(high, tonumber(key) :: number)
	end
	return high
end

-- Checks an equip of `rec` into `slot` (rules + bag capacity); doesn't change anything.
local function checkEquip(inv: Inv, rec: Record, slot: string, rules: Rules?): (boolean, string?)
	local ok, why = fitsSlot(rec, slot)
	if not ok then
		return false, why
	end
	if rules and rules.canEquip then
		ok, why = rules.canEquip(rec, slot)
		if not ok then
			return false, why or "REQUIREMENTS"
		end
	end
	if slot == "offHand" and isTwoHanded(inv.equip.mainHand) then
		return false, "TWO_HANDED"
	end
	return true, nil
end

-- ─── Moving ─────────────────────────────────────────────────────────────────

local function stackInto(target: Record, source: Record): number
	local def = ItemDatabase.get(target.i) :: ItemTypes.ItemDef
	local room = def.stack - ItemInstance.count(target)
	local moved = math.min(room, ItemInstance.count(source))
	if moved > 0 then
		local total = ItemInstance.count(target) + moved
		target.n = if total > 1 then total else nil
		local left = ItemInstance.count(source) - moved
		source.n = if left > 1 then left else nil
		if left <= 0 then
			source.n = 0 -- marker: fully moved (caller clears the place)
		end
	end
	return moved
end

-- Equips `rec` (taken from grid place `from`) into `slot`; whatever was there goes back to `from`.
local function equipFrom(inv: Inv, from: Place, slot: string, rules: Rules?): (boolean, string?)
	local rec = get(inv, from) :: Record
	local ok, why = checkEquip(inv, rec, slot, rules)
	if not ok then
		return false, why
	end
	local current = inv.equip[slot]
	-- Bags: the capacity after the swap must still hold every item.
	if slot == "bag1" or slot == "bag2" then
		local cap = capacityWith(inv, slot, rec)
		if highestUsed(inv) > cap then
			return false, "BAG_NOT_EMPTY"
		end
	end
	inv.equip[slot] = rec
	put(inv, from, current)
	-- A two-handed weapon pushes the off hand into the grid.
	if slot == "mainHand" and isTwoHanded(rec) and inv.equip.offHand then
		local free = Inventory.findFree(inv)
		if not free then
			return false, "NO_ROOM"
		end
		inv.slots[tostring(free)] = inv.equip.offHand;
		(inv.equip :: any).offHand = nil
	end
	if rules and rules.onEquip then
		rules.onEquip(rec)
	end
	return true, nil
end

--[[
	Moves between two places. `n` splits a stack (grid to empty grid slot only).
		grid -> empty grid      move (or split n)
		grid -> same stackable  merge (leftover stays)
		grid -> other grid      swap
		grid -> equipment       equip (the old item swaps back)
		equipment -> grid       unequip (into an empty slot, or swap with an item that fits)
		equipment -> equipment  swap (rings, hands) when both fit
]]
function Inventory.move(inv: Inv, fromRef: string, toRef: string, n: number?, rules: Rules?): (boolean, string?)
	local from, to = Inventory.parse(fromRef), Inventory.parse(toRef)
	if not from or not to then
		return false, "BAD_REF"
	end
	local src = get(inv, from)
	if not src then
		return false, "EMPTY"
	end
	if from.kind == to.kind and from.key == to.key then
		return true, nil
	end
	local dst = get(inv, to)
	local cap = Inventory.capacity(inv)

	if to.kind == "s" and (tonumber(to.key) :: number) > cap and dst == nil then
		return false, "NO_SLOT"
	end

	if from.kind == "s" and to.kind == "s" then
		local count = ItemInstance.count(src)
		if n and n < count then
			if dst == nil then
				put(inv, to, Inventory.take(inv, fromRef, n))
				return true, nil
			elseif ItemInstance.canStack(dst, src) then
				local part = Inventory.take(inv, fromRef, n) :: Record
				stackInto(dst, part)
				if (part.n or 1) > 0 then
					-- Didn't all fit: put the rest back on the source stack.
					local back = get(inv, from)
					if back then
						back.n = ItemInstance.count(back) + ItemInstance.count(part)
					else
						put(inv, from, part)
					end
				end
				return true, nil
			end
			return false, "SPLIT_TARGET"
		end
		if dst and ItemInstance.canStack(dst, src) then
			stackInto(dst, src)
			if src.n == 0 then
				put(inv, from, nil)
			end
			return true, nil
		end
		put(inv, to, src)
		put(inv, from, dst)
		return true, nil
	end

	if from.kind == "s" and to.kind == "e" then
		return equipFrom(inv, from, to.key, rules)
	end

	if from.kind == "e" and to.kind == "s" then
		-- Unequipping a bag shrinks the grid: everything must still fit, target included.
		local newCap = cap
		if from.key == "bag1" or from.key == "bag2" then
			newCap = capacityWith(inv, from.key, nil)
			if highestUsed(inv) > newCap or (tonumber(to.key) :: number) > newCap then
				return false, "BAG_NOT_EMPTY"
			end
		end
		if dst == nil then
			put(inv, to, src)
			inv.equip[from.key] = nil
			return true, nil
		end
		-- Swap: the grid item must fit the equipment slot.
		inv.equip[from.key] = nil
		local ok, why = checkEquip(inv, dst, from.key, rules)
		if not ok then
			inv.equip[from.key] = src
			return false, why
		end
		inv.equip[from.key] = dst
		put(inv, to, src)
		if rules and rules.onEquip then
			rules.onEquip(dst)
		end
		return true, nil
	end

	-- Equipment to equipment.
	local okA, whyA = fitsSlot(src, to.key)
	if not okA then
		return false, whyA
	end
	if dst then
		local okB, whyB = fitsSlot(dst, from.key)
		if not okB then
			return false, whyB
		end
	end
	inv.equip[to.key], inv.equip[from.key] = src, dst
	if isTwoHanded(inv.equip.mainHand) and inv.equip.offHand then
		inv.equip[to.key], inv.equip[from.key] = dst, src
		return false, "TWO_HANDED"
	end
	return true, nil
end

-- Equips the item at a grid ref into its best slot: the first empty allowed slot, else the first.
function Inventory.autoEquip(inv: Inv, fromRef: string, rules: Rules?): (boolean, string?)
	local rec = Inventory.at(inv, fromRef)
	local def = rec and ItemDatabase.get(rec.i)
	if not rec or not def or not def.equip then
		return false, "NOT_EQUIPPABLE"
	end
	local target = def.equip.slots[1]
	for _, slot in def.equip.slots do
		if inv.equip[slot] == nil then
			target = slot
			break
		end
	end
	return Inventory.move(inv, fromRef, "e:" .. target, nil, rules)
end

-- Unequips into the first free grid slot (that still exists after a bag comes off).
function Inventory.unequip(inv: Inv, slot: string): (boolean, string?)
	if not inv.equip[slot] then
		return false, "EMPTY"
	end
	local cap = if slot == "bag1" or slot == "bag2" then capacityWith(inv, slot, nil) else Inventory.capacity(inv)
	local free = Inventory.findFree(inv, cap)
	if not free then
		return false, "NO_ROOM"
	end
	return Inventory.move(inv, "e:" .. slot, "s" .. free, nil, nil)
end

-- ─── Sorting ────────────────────────────────────────────────────────────────

local CATEGORY_ORDER: { [string]: number } = {}
for i, id in {
	"artifact", "focus", "weapon", "armor", "clothing", "jewelry", "container", "tool", "consumable",
	"book", "reagent", "material", "treasure", "key", "quest", "furniture",
} do
	CATEGORY_ORDER[id] = i
end

-- Merges stacks and compacts the grid: favourites first, then category, rarity (high first),
-- name. Locked items keep their slots; everything else flows around them.
function Inventory.sort(inv: Inv)
	local movable: { Record } = {}
	local locked: { [string]: boolean } = {}
	for key, rec in inv.slots do
		if ItemInstance.hasFlag(rec, ItemInstance.LOCKED) then
			locked[key] = true
		else
			table.insert(movable, rec)
			inv.slots[key] = nil
		end
	end
	-- Merge stackables.
	local merged: { Record } = {}
	for _, rec in movable do
		local into: Record? = nil
		for _, m in merged do
			local def = ItemDatabase.get(m.i)
			if def and ItemInstance.canStack(m, rec) and ItemInstance.count(m) < def.stack then
				into = m
				break
			end
		end
		if into then
			stackInto(into, rec)
			if rec.n ~= 0 then
				table.insert(merged, rec)
			end
		else
			table.insert(merged, rec)
		end
	end
	table.sort(merged, function(a, b)
		local fa, fb = ItemInstance.hasFlag(a, ItemInstance.FAVORITE), ItemInstance.hasFlag(b, ItemInstance.FAVORITE)
		if fa ~= fb then
			return fa
		end
		local da, db = ItemDatabase.get(a.i), ItemDatabase.get(b.i)
		local ca = if da then CATEGORY_ORDER[da.category] or 99 else 100
		local cb = if db then CATEGORY_ORDER[db.category] or 99 else 100
		if ca ~= cb then
			return ca < cb
		end
		local ra, rb = ItemInstance.rarityIndex(a), ItemInstance.rarityIndex(b)
		if ra ~= rb then
			return ra > rb
		end
		local na, nb = ItemInstance.displayName(a), ItemInstance.displayName(b)
		if na ~= nb then
			return na < nb
		end
		return ItemInstance.count(a) > ItemInstance.count(b)
	end)
	local n = 1
	for _, rec in merged do
		while locked[tostring(n)] do
			n += 1
		end
		-- Overflow items (beyond capacity) keep counting past it rather than vanishing.
		inv.slots[tostring(n)] = rec
		n += 1
	end
end

-- ─── Quickslots ─────────────────────────────────────────────────────────────

-- Binds a quickslot to the item at `ref` (stackables by item id, uniques by uid), or clears it.
function Inventory.setQuick(inv: Inv, key: string, ref: string?): (boolean, string?)
	local n = tonumber(key)
	if not n or n < 1 or n > R.quickSlots or n % 1 ~= 0 then
		return false, "BAD_SLOT"
	end
	if ref == nil then
		inv.quick[key] = nil
		return true, nil
	end
	local rec = Inventory.at(inv, ref)
	local def = rec and ItemDatabase.get(rec.i)
	if not rec or not def then
		return false, "EMPTY"
	end
	if not def.use and not def.equip then
		return false, "NOT_USABLE"
	end
	inv.quick[key] = if def.stack > 1 or rec.u == nil then "i:" .. def.id else "u:" .. (rec.u :: string)
	return true, nil
end

-- The place a quickslot points at right now (first stack of the item, or the unique wherever it is).
function Inventory.resolveQuick(inv: Inv, key: string): string?
	local bind = inv.quick[key]
	if not bind then
		return nil
	end
	local kind, value = string.sub(bind, 1, 1), string.sub(bind, 3)
	if kind == "u" then
		return Inventory.findUid(inv, value)
	end
	local best: number? = nil
	for slotKey, rec in inv.slots do
		local n = tonumber(slotKey) :: number
		if rec.i == value and (best == nil or n < best) then
			best = n
		end
	end
	return if best then "s" .. best else nil
end

-- ─── Invariants and transactions ────────────────────────────────────────────

function Inventory.check(inv: Inv): (boolean, string?)
	local uids: { [string]: boolean } = {}
	local function each(rec: Record, where: string): string?
		local ok, why = ItemInstance.validate(rec)
		if not ok then
			return where .. ": " .. (why or "invalid")
		end
		local def = ItemDatabase.get(rec.i)
		if def and ItemInstance.count(rec) > def.stack then
			return where .. ": over stack cap"
		end
		if rec.u then
			if uids[rec.u] then
				return where .. ": duplicate uid " .. rec.u
			end
			uids[rec.u] = true
		end
		return nil
	end
	for key, rec in inv.slots do
		local err = each(rec, "s" .. key)
		if err then
			return false, err
		end
	end
	for slot, rec in inv.equip do
		local err = each(rec, "e:" .. slot)
		if err then
			return false, err
		end
		local ok = fitsSlot(rec, slot)
		if not ok then
			return false, "e:" .. slot .. ": doesn't fit"
		end
	end
	if isTwoHanded(inv.equip.mainHand) and inv.equip.offHand then
		return false, "two-handed main hand with an off hand"
	end
	if inv.currency < 0 or inv.currency ~= inv.currency or inv.currency > R.maxCurrency then
		return false, "bad currency"
	end
	if inv.rare < 0 or inv.rare ~= inv.rare or inv.rare > R.maxRare then
		return false, "bad rare currency"
	end
	return true, nil
end

local function deepCopy(value: any): any
	if typeof(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = deepCopy(v)
	end
	return out
end

-- Grid keys over capacity that hold items now but didn't before: something was placed there.
local function newOverflow(inv: Inv, before: { [string]: Record }): boolean
	local cap = Inventory.capacity(inv)
	for key, rec in inv.slots do
		if (tonumber(key) :: number) > cap and before[key] ~= rec then
			return true
		end
	end
	return false
end

type Snapshot = { currency: number, rare: number, slots: any, equip: any, quick: any, nextUid: number, live: { [string]: Record } }

local function snapshotOf(inv: Inv): Snapshot
	return {
		currency = inv.currency,
		rare = inv.rare,
		slots = deepCopy(inv.slots),
		equip = deepCopy(inv.equip),
		quick = deepCopy(inv.quick),
		nextUid = inv.nextUid,
		live = table.clone(inv.slots),
	}
end

local function restore(inv: Inv, snap: Snapshot)
	inv.currency, inv.rare, inv.nextUid = snap.currency, snap.rare, snap.nextUid
	local swaps: { { any } } = { { inv.slots, snap.slots }, { inv.equip, snap.equip }, { inv.quick, snap.quick } }
	for _, pair in swaps do
		local target: any, source: any = pair[1], pair[2]
		table.clear(target)
		for k, v in source do
			target[k] = v
		end
	end
end

--[[
	Runs fn(...invs) as ONE atomic operation over several inventories (a player and a container,
	two traders). fn returns (ok, reason?, ...results). On an error, a false return, or a broken
	invariant in ANY of them, every inventory is restored exactly. Returns (ok, reason, ...).
]]
function Inventory.transactMany(invs: { Inv }, fn: (...Inv) -> (boolean, string?, ...any)): (boolean, string?, ...any)
	local snaps: { Snapshot } = {}
	for i, inv in invs do
		snaps[i] = snapshotOf(inv)
	end
	-- results: pcall ok, fn ok (or the error), fn reason, fn results...
	local results = table.pack(pcall(fn, table.unpack(invs)))
	local ran, fnOk = results[1], results[2]
	local reason: string? = nil
	if not ran then
		reason = "ERROR"
	elseif not fnOk then
		reason = results[3] or "REFUSED"
	else
		for i, inv in invs do
			local valid, err = Inventory.check(inv)
			if not valid then
				reason = "INVARIANT: " .. tostring(err)
				break
			elseif newOverflow(inv, snaps[i].live) then
				reason = "NO_SLOT"
				break
			end
		end
		-- No uid may exist in two of them at once (a transfer that copied instead of moved).
		if not reason and #invs > 1 then
			local seen: { [string]: boolean } = {}
			for _, inv in invs do
				for _, entry in Inventory.each(inv) do
					local uid = entry.rec.u
					if uid then
						if seen[uid] then
							reason = "INVARIANT: uid in two inventories " .. uid
							break
						end
						seen[uid] = true
					end
				end
			end
		end
	end
	if reason then
		for i, inv in invs do
			restore(inv, snaps[i])
		end
		return false, reason, if not ran then fnOk else nil
	end
	return true, nil, table.unpack(results, 4, results.n)
end

-- Runs fn(inv) as one atomic operation (see transactMany).
function Inventory.transact(inv: Inv, fn: (Inv) -> (boolean, string?, ...any)): (boolean, string?, ...any)
	return Inventory.transactMany({ inv }, fn :: any)
end

-- Appends to the saved audit trail (newest last, capped).
function Inventory.audit(inv: Inv, t: number, op: string, detail: string)
	table.insert(inv.audit, { t = t, op = op, d = string.sub(detail, 1, 120) })
	while #inv.audit > R.auditKept do
		table.remove(inv.audit, 1)
	end
end

return Inventory
