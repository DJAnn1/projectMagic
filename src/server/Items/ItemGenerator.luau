--!strict
--[[
	ItemGenerator: seeded item variants (docs/Items.md §2.4). Pure: same inputs, same item.

		ItemGenerator.rng(worldSeed, sourceId, salt?) -> Random
		    Seed.random(worldSeed, "item:" .. sourceId, "itemgen", salt). sourceId names what made
		    the item: a uid, "chest:<id>", "npc:<id>"... so any roll can be reproduced.
		ItemGenerator.rollRarity(rng, opts?) -> index           weighted, shifted by luck
		ItemGenerator.roll(itemId, rng, opts?) -> (Record?, err?)
		    A Record WITHOUT a uid (Inventory mints it when the item enters an inventory).
		    opts.rarity      force a rarity (index or id); otherwise rolled (affixable items only)
		    opts.affixes     force these affix ids (each still has to fit the item); the rest roll
		    opts.luck        0..1+, shifts the rarity roll toward higher tiers
		    opts.count       stack size for stackables (clamped to the stack cap)
		    opts.quality     crafted quality 0..100

	Affix picking: candidates must fit the item's affix class, have minRarity <= the item's
	rarity, and not share a group with an affix already chosen. At most 2 prefixes and 2
	suffixes (names show the first of each). If the pool runs dry, the item rolls fewer affixes.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Seed = require(Shared.Magic.Seed)
local ItemTypes = require(Shared.Items.ItemTypes)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local Rarities = require(Shared.Items.Data.Rarities)

type Record = ItemTypes.Record

export type RollOptions = {
	rarity: (number | string)?,
	affixes: { string }?,
	luck: number?,
	count: number?,
	quality: number?,
}

local MAX_PER_KIND = 2

local ItemGenerator = {}

function ItemGenerator.rng(worldSeed: number, sourceId: string, salt: number?): Random
	return Seed.random(worldSeed, "item:" .. sourceId, "itemgen", salt)
end

-- Luck multiplies each rarity's weight by (1 + luck) ^ (index - 1): luck 1 doubles Uncommon,
-- quadruples Rare, x16 Legendary. Artifacts never roll (weight 0).
function ItemGenerator.rollRarity(rng: Random, opts: { luck: number?, maxIndex: number? }?): number
	local luck = math.max(0, opts and opts.luck or 0)
	local maxIndex = opts and opts.maxIndex or Rarities.LEGENDARY
	local total = 0
	local weights: { number } = {}
	for i, r in Rarities.list do
		local w = if i <= maxIndex then r.weight * (1 + luck) ^ (i - 1) else 0
		weights[i] = w
		total += w
	end
	local pick = rng:NextNumber() * total
	for i, w in weights do
		pick -= w
		if pick <= 0 and w > 0 then
			return i
		end
	end
	return 1
end

local function fits(affix: ItemTypes.AffixDef, class: string, rarity: number): boolean
	return affix.minRarity <= rarity and table.find(affix.on, class) ~= nil
end

local function resolveRarity(value: (number | string)?): number?
	if value == nil then
		return nil
	end
	local r = ItemDatabase.rarity(value :: any)
	return r and r.index
end

-- Chooses `count` affixes for an item class and rarity; `forced` ones first.
local function pickAffixes(rng: Random, class: string, rarity: number, count: number, forced: { string }?): ({ [string]: number }?, string?)
	local chosen: { [string]: number } = {}
	local groups: { [string]: boolean } = {}
	local kinds: { [string]: number } = { prefix = 0, suffix = 0 }
	local n = 0

	local function take(affix: ItemTypes.AffixDef)
		chosen[affix.id] = rng:NextInteger(0, ItemInstance.ROLL_MAX)
		groups[affix.group] = true
		kinds[affix.kind] += 1
		n += 1
	end

	for _, id in (forced or {}) :: any do
		local affix = ItemDatabase.affix(id)
		if not affix then
			return nil, "unknown affix " .. id
		end
		if not table.find(affix.on, class) then
			return nil, string.format("%s can't roll on %s items", id, class)
		end
		if groups[affix.group] then
			return nil, string.format("%s shares a group with another chosen affix", id)
		end
		take(affix)
	end

	while n < count do
		local pool: { ItemTypes.AffixDef } = {}
		local total = 0
		for _, affix in ItemDatabase.affixes do
			if not chosen[affix.id] and not groups[affix.group] and kinds[affix.kind] < MAX_PER_KIND and fits(affix, class, rarity) then
				table.insert(pool, affix)
				total += affix.weight
			end
		end
		if #pool == 0 then
			break
		end
		local pick = rng:NextNumber() * total
		local picked = pool[#pool]
		for _, affix in pool do
			pick -= affix.weight
			if pick <= 0 then
				picked = affix
				break
			end
		end
		take(picked)
	end
	return if n > 0 then chosen else nil, nil
end

function ItemGenerator.roll(itemId: string, rng: Random, opts: RollOptions?): (Record?, string?)
	local o: RollOptions = opts or {}
	local def = ItemDatabase.get(itemId)
	if not def then
		return nil, "unknown item " .. tostring(itemId)
	end
	local rec: Record = { i = def.id }

	if def.stack > 1 then
		local count = math.clamp(math.floor(o.count or 1), 1, def.stack)
		rec.n = if count > 1 then count else nil
		return rec, nil
	end

	local class = def.equip and def.equip.affixClass
	local baseRarity = (ItemDatabase.rarity(def.rarity) :: ItemTypes.RarityDef).index
	local rarity = resolveRarity(o.rarity)
	if o.rarity ~= nil and not rarity then
		return nil, "unknown rarity " .. tostring(o.rarity)
	end
	if def.rarity == "artifact" then
		rarity = Rarities.ARTIFACT -- authored uniques never vary
	elseif not class then
		rarity = baseRarity -- nothing to roll on: keep the authored rarity
	elseif rarity == nil then
		rarity = math.max(baseRarity, ItemGenerator.rollRarity(rng, { luck = o.luck }))
	end
	local r = rarity :: number
	if r == Rarities.ARTIFACT and def.rarity ~= "artifact" then
		return nil, "only authored artifacts can be Artifact rarity"
	end
	if r ~= baseRarity then
		rec.r = r
	end

	if class then
		local count = (ItemDatabase.rarity(r) :: ItemTypes.RarityDef).affixes
		count = math.max(count, if o.affixes then #o.affixes else 0)
		if count > 0 then
			local affixes, err = pickAffixes(rng, class, r, count, o.affixes)
			if err then
				return nil, err
			end
			rec.a = affixes
		end
	elseif o.affixes and #o.affixes > 0 then
		return nil, def.name .. " can't carry affixes"
	end

	if o.quality then
		rec.q = math.clamp(math.floor(o.quality), 0, 100)
	end
	return rec, nil
end

return ItemGenerator
