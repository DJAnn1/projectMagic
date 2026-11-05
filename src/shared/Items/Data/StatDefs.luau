--!strict
--[[
	StatDefs: every character stat items, sets, buffs and encumbrance can change
	(docs/Items.md §4). StatCalc derives the final values; this module only describes them.

		format   "flat" (+12), "pct" (+8%), "int" (+1), "rate" (+0.5/s)
		base     the value before any layer (a bare character)
		min/max  clamp on the FINAL value (caps keep stacking sane)
		pctOf    a percentage stat that multiplies another stat in the % pass
		wired    nil when the stat already does something; otherwise the stage that makes it
		         matter (the breakdown shows it, so nobody wonders why +stamina does nothing yet)

	Per-domain spell power is generated: power_<domainId> for every domain in the Registry.
	Resistances are not stats: they're keyed by domain/property/"all" and go to Cast/Resistances.
]]

local Shared = script.Parent.Parent.Parent
local Registry = require(Shared.Magic.Registry)
local ItemTypes = require(script.Parent.Parent.ItemTypes)

type StatDef = ItemTypes.StatDef

local list: { StatDef } = {
	-- Vitals
	{ id = "health", name = "Health", format = "flat", base = 100, min = 1, max = 5000, group = "vitals", description = "Maximum health." },
	{ id = "healthPct", name = "Health", format = "pct", base = 0, min = -0.5, max = 1, pctOf = "health", group = "vitals", description = "Percent more maximum health." },
	{ id = "healthRegen", name = "Health regeneration", format = "rate", base = 0, min = 0, max = 20, group = "vitals", description = "Health per second, on top of natural recovery." },
	{ id = "defense", name = "Defense", format = "flat", base = 0, min = 0, max = 400, group = "vitals", description = "Reduces weapon damage: defense / (defense + 60), at most 60%." },
	{ id = "staminaMax", name = "Stamina", format = "flat", base = 100, min = 10, max = 1000, group = "vitals", description = "Maximum stamina." },
	{ id = "staminaRegenPct", name = "Stamina recovery", format = "pct", base = 0, min = -1, max = 2, group = "vitals", description = "Percent faster stamina recovery." },

	-- Magic
	{ id = "reservoirMax", name = "Reservoir", format = "flat", base = 0, min = 0, max = 100000, group = "magic", description = "Reservoir capacity. Its base comes from your profile and attunement." },
	{ id = "reservoirMaxPct", name = "Reservoir", format = "pct", base = 0, min = -0.5, max = 1, pctOf = "reservoirMax", group = "magic", description = "Percent more reservoir capacity." },
	{ id = "reservoirRegenPct", name = "Reservoir regeneration", format = "pct", base = 0, min = -0.75, max = 1.5, group = "magic", description = "Percent faster reservoir regeneration." },
	{ id = "spellPowerPct", name = "Spell power", format = "pct", base = 0, min = -0.5, max = 1, group = "magic", description = "Percent more power for every spell." },
	{ id = "castSpeedPct", name = "Cast speed", format = "pct", base = 0, min = -0.5, max = 0.5, group = "magic", description = "Percent faster casting (cast time divides by 1 + this)." },
	{ id = "costReductionPct", name = "Reservoir cost", format = "pct", base = 0, min = -0.5, max = 0.4, group = "magic", description = "Percent less reservoir paid per spell." },
	{ id = "stabilityPct", name = "Stability", format = "pct", base = 0, min = 0, max = 0.6, group = "magic", description = "Percent lower backfire chance." },
	{ id = "backlashResistPct", name = "Backlash resistance", format = "pct", base = 0, min = 0, max = 0.6, group = "magic", description = "Overdraw consequences (backlash, burnout, lockouts) are this much weaker and shorter." },
	{ id = "modifierSlots", name = "Modifier slots", format = "int", base = 0, min = 0, max = 2, group = "magic", description = "Extra modifier slots (never beyond what a form can structurally hold)." },
	{ id = "formTier", name = "Form reach", format = "int", base = 0, min = 0, max = 1, group = "magic", description = "Use forms one mastery tier above your own." },

	-- Movement
	{ id = "moveSpeedPct", name = "Move speed", format = "pct", base = 0, min = -0.6, max = 0.3, group = "movement", description = "Percent faster walking." },
	{ id = "carryWeight", name = "Carry capacity", format = "flat", base = 60, min = 10, max = 1000, group = "movement", description = "Weight you can carry before you slow down." },

	-- Combat (weapons stage)
	{ id = "attackPower", name = "Attack power", format = "flat", base = 0, min = 0, max = 500, group = "combat", description = "Added to weapon hits." },
	{ id = "attackSpeedPct", name = "Attack speed", format = "pct", base = 0, min = -0.5, max = 0.6, group = "combat", description = "Percent faster weapon swings." },
	{ id = "critChancePct", name = "Critical chance", format = "pct", base = 0, min = 0, max = 0.5, group = "combat", description = "Chance for a weapon hit to crit." },

	-- Item-local: they change the item that carries them, never the character.
	{ id = "itemWeightPct", name = "Item weight", format = "pct", base = 0, min = -0.9, max = 1, group = "item", description = "This item is lighter." },
	{ id = "durabilityPct", name = "Durability", format = "pct", base = 0, min = 0, max = 2, group = "item", description = "This item lasts longer." },
}

for _, domainId in Registry.domainIds do
	local domain = Registry.domains[domainId]
	table.insert(list, {
		id = "power_" .. domainId,
		name = domain.name .. " power",
		format = "pct",
		base = 0,
		min = 0,
		max = 0.75,
		group = "magic",
		description = "Percent more power for " .. domain.name .. " spells (hybrids average their domains).",
	})
end

local byId: { [string]: StatDef } = {}
for _, def in list do
	assert(byId[def.id] == nil, "StatDefs: duplicate stat " .. def.id)
	byId[def.id] = def
end
for _, def in list do
	assert(def.pctOf == nil or byId[def.pctOf], "StatDefs: " .. def.id .. " multiplies unknown stat " .. tostring(def.pctOf))
end

-- Stats that change the item itself, never the character.
local itemLocal: { [string]: boolean } = { itemWeightPct = true, durabilityPct = true }

-- "+12", "+8%", "+0.5/s" for a tooltip line.
local function format(statId: string, value: number): string
	local def = byId[statId]
	local sign = if value >= 0 then "+" else "−"
	local v = math.abs(value)
	if not def or def.format == "flat" then
		return sign .. (if v >= 10 or v % 1 == 0 then string.format("%d", math.floor(v + 0.5)) else string.format("%.1f", v))
	elseif def.format == "pct" then
		return sign .. (if v * 100 >= 10 then string.format("%d%%", math.floor(v * 100 + 0.5)) else string.format("%.1f%%", v * 100))
	elseif def.format == "int" then
		return sign .. string.format("%d", math.floor(v + 0.5))
	end
	return sign .. string.format("%.1f/s", v)
end

return table.freeze({
	list = list,
	byId = byId,
	itemLocal = itemLocal,
	format = format,
})
