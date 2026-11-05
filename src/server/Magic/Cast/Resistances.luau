--!strict
--[[
	Resistances: how much less (or more) magic hurts one character. Cast/DamageModel asks
	Resistances.total for every hit; everything that can make someone tougher writes here.

	SOURCES (summed per key, then clamped to CombatTuning.damage maxResist / maxVulnerability)
		innate   a provider callback (NPCService registers one): an NPC's affinities resist their
		         own domains, and their traits shift mind / time / curse keys (CombatTuning.resistances)
		ward     active statuses that carry a `resist` table (StatusEffects.apply opts.resist):
		         every Ward resists all magic, scaled by the ward's power
		gear     Humanoid attributes "Gear_<slot>" = item id (Data/Gear), set by setGear (NPCs)
		items    a provider callback (InventoryService registers Items/StatCache.resistFor): a
		         player's equipped items, set bonuses and item buffs
		manual   Humanoid attributes "Resist_<key>" (admin `resist`, tests, scripted encounters)

	KEYS: a domain id, a property id, or "all". For a spell, the applied value is
		avg(domain keys over a hybrid's domains) + property key + all
	from every source together.

		Resistances.total(humanoid, domains, property) -> number   (clamped)
		Resistances.breakdown(humanoid) -> { { source, key, value } }   (admin / inspector)
		Resistances.setGear(humanoid, slot, itemId?)                    (nil unequips)
		Resistances.setInnateProvider(fn(humanoid) -> { [key]: number }?)
		Resistances.setItemProvider(fn(humanoid) -> { [key]: number }?)
]]

local Cast = script.Parent
local C = require(Cast.Parent.Data.CombatTuning)
local Gear = require(Cast.Parent.Data.Gear)
local StatusEffects = require(Cast.StatusEffects)

export type Map = { [string]: number }
export type Line = { source: string, key: string, value: number }

local Resistances = {}

local innateProvider: ((Humanoid) -> Map?)? = nil
local itemProvider: ((Humanoid) -> Map?)? = nil

function Resistances.setInnateProvider(fn: (Humanoid) -> Map?)
	innateProvider = fn
end

function Resistances.setItemProvider(fn: (Humanoid) -> Map?)
	itemProvider = fn
end

local function gearMap(humanoid: Humanoid): Map?
	local out: Map? = nil
	for _, slot in Gear.slots do
		local id = humanoid:GetAttribute("Gear_" .. slot)
		local item = if typeof(id) == "string" then Gear.items[id] else nil
		if item then
			local m: Map = out or {}
			for key, v in item.resist do
				m[key] = (m[key] or 0) + v
			end
			out = m
		end
	end
	return out
end

local function manualMap(humanoid: Humanoid): Map?
	local out: Map? = nil
	for name, v in humanoid:GetAttributes() do
		if typeof(v) == "number" and string.sub(name, 1, 7) == "Resist_" then
			local m: Map = out or {}
			m[string.sub(name, 8)] = v
			out = m
		end
	end
	return out
end

-- Every source's map for this character, by source name.
local function sources(humanoid: Humanoid): { [string]: Map }
	local out: { [string]: Map } = {}
	local provider = innateProvider
	if provider then
		local ok, m = pcall(provider, humanoid)
		if ok and m then
			out.innate = m
		end
	end
	local ward = StatusEffects.resistOf(humanoid)
	if ward then
		out.ward = ward
	end
	local gear = gearMap(humanoid)
	if gear then
		out.gear = gear
	end
	local items = itemProvider
	if items then
		local ok, m = pcall(items, humanoid)
		if ok and m then
			out.items = m
		end
	end
	local manual = manualMap(humanoid)
	if manual then
		out.manual = manual
	end
	return out
end

function Resistances.total(humanoid: Humanoid, domains: { string }, property: string): number
	local total = 0
	for _, m in sources(humanoid) do
		local domainSum = 0
		for _, d in domains do
			domainSum += m[d] or 0
		end
		total += domainSum / math.max(1, #domains) + (m[property] or 0) + (m.all or 0)
	end
	return math.clamp(total, -C.damage.maxVulnerability, C.damage.maxResist)
end

function Resistances.breakdown(humanoid: Humanoid): { Line }
	local lines: { Line } = {}
	for source, m in sources(humanoid) do
		for key, value in m do
			if value ~= 0 then
				table.insert(lines, { source = source, key = key, value = value })
			end
		end
	end
	table.sort(lines, function(a, b)
		if a.source ~= b.source then
			return a.source < b.source
		end
		return a.key < b.key
	end)
	return lines
end

-- Equips (or with nil, unequips) an item in a slot. Returns false for an unknown item or a slot
-- the item doesn't fit.
function Resistances.setGear(humanoid: Humanoid, slot: string, itemId: string?): boolean
	if not table.find(Gear.slots, slot) then
		return false
	end
	if itemId == nil then
		humanoid:SetAttribute("Gear_" .. slot, nil)
		return true
	end
	local item = Gear.items[itemId]
	if not item or item.slot ~= slot then
		return false
	end
	humanoid:SetAttribute("Gear_" .. slot, itemId)
	return true
end

--[[
	An NPC's innate resistances from its caster affinities and traits (CombatTuning.resistances).
	Pure: NPCService caches the result per NPC.
]]
function Resistances.innateFor(affinities: { [string]: number }, traits: { [string]: number }): Map
	local R = C.resistances
	local m: Map = {}
	for domain, a in affinities do
		if a > R.affinityFrom then
			m[domain] = math.min(R.affinityMax, (a - R.affinityFrom) * R.affinityScale)
		end
	end
	for trait, keys in R.traits do
		local centred = (traits[trait] or 0.5) - 0.5
		if centred ~= 0 then
			for key, weight in keys do
				m[key] = (m[key] or 0) + centred * weight
			end
		end
	end
	return m
end

-- The `resist` table a Ward of this recipe power carries.
function Resistances.wardFor(recipePower: number): Map
	local R = C.resistances
	return { all = math.min(R.wardMax, R.wardBase + R.wardPerPower * recipePower) }
end

return Resistances
