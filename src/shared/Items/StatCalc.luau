--!strict
--[[
	StatCalc: derives a character's final stats from ordered layers, with a breakdown line for
	every contribution (docs/Items.md §4). Pure; shared so the UI can explain the numbers.

	CALCULATION ORDER
		1. base       StatDefs.base (a bare character: 100 health, 60 carry...)
		2. profile    innate: reservoir capacity from attunement and traits (Reservoir.maxReservoir)
		3. mastery    +health per best mastery tier (ItemRules.masteryHealthPerTier)
		4. gear       every equipped, unbroken item whose requirements are met: rolled base stats,
		              affixes, focus domain power, and attunements the wearer qualifies for
		5. set        set bonuses by pieces worn (cumulative)
		6. buff       consumables and other timed effects
		   -- all flat and percent values above are SUMMED per stat (additive stacking) --
		7. percent    each *Pct stat with `pctOf` multiplies its target once: health x (1 + healthPct)
		8. load       encumbrance from carried weight / carry capacity (after carry is final)
		9. caps       every final value clamped to StatDefs min/max
	Resistances add up per key through steps 4-6; Cast/Resistances clamps the total per hit.

		StatCalc.gearLayers(equipped, caster) -> (layers, focus)   step 4-5 layers for a loadout
		StatCalc.derive(layers, weight) -> Sheet
]]

local ItemTypes = require(script.Parent.ItemTypes)
local ItemDatabase = require(script.Parent.ItemDatabase)
local ItemInstance = require(script.Parent.ItemInstance)
local StatDefs = require(script.Parent.Data.StatDefs)
local ItemRules = require(script.Parent.Data.ItemRules)

type Layer = ItemTypes.Layer
type Record = ItemTypes.Record
type Sheet = ItemTypes.Sheet

-- What the equipped foci add up to; Server/Items/StatCache applies it per spell.
export type FocusInfo = {
	grade: string, -- best grade worn: "major" | "minor" | "none"
	foci: { { grade: string, domains: { [string]: boolean }, stability: number, label: string } },
}

local StatCalc = {}

-- Pieces worn of each set, from an equipment map.
local function setCounts(equipped: { [string]: Record }): { [string]: number }
	local counts: { [string]: number } = {}
	for _, rec in equipped do
		if not ItemInstance.isBroken(rec) then
			local seen: { [string]: boolean } = {}
			for _, setId in ItemInstance.rolled(rec).sets do
				if not seen[setId] then
					seen[setId] = true
					counts[setId] = (counts[setId] or 0) + 1
				end
			end
		end
	end
	return counts
end

--[[
	Gear and set layers for a loadout. An item contributes only when it isn't broken and its
	requirements are met; gated parts (attunements, attuned affixes) only when those are met too.
	`caster` is the wearer's CasterProfile (nil: nothing with a requirement counts).
]]
function StatCalc.gearLayers(equipped: { [string]: Record }, caster: any?): ({ Layer }, FocusInfo)
	local layers: { Layer } = {}
	local focus: FocusInfo = { grade = "none", foci = {} }

	-- Slot order keeps the breakdown stable.
	for _, slot in ItemRules.equipSlots do
		local rec = equipped[slot.id]
		local def = rec and ItemDatabase.get(rec.i)
		if not rec or not def or ItemInstance.isBroken(rec) or not ItemInstance.meets(def.requires, caster) then
			continue
		end
		local rolled = ItemInstance.rolled(rec)
		local stats = table.clone(rolled.stats)
		local resist = table.clone(rolled.resist)
		for _, g in rolled.gated do
			if ItemInstance.meets(g.requires, caster) then
				for k, v in g.stats do
					stats[k] = (stats[k] or 0) + v
				end
				for k, v in g.resist do
					resist[k] = (resist[k] or 0) + v
				end
			end
		end
		local f = def.focus
		if f then
			local domains: { [string]: boolean } = {}
			for domain, bonus in (f.domains or {}) :: any do
				domains[domain] = true
				local statId = if domain == "any" then "spellPowerPct" else "power_" .. domain
				stats[statId] = (stats[statId] or 0) + bonus
			end
			table.insert(focus.foci, { grade = f.grade, domains = domains, stability = f.stability or 0, label = def.name })
			if f.grade == "major" then
				focus.grade = "major"
			elseif focus.grade == "none" then
				focus.grade = "minor"
			end
		end
		table.insert(layers, { source = "gear", label = ItemInstance.displayName(rec), stats = stats, resist = resist })
	end

	local counts = setCounts(equipped)
	for _, set in ItemDatabase.sets do
		local worn = counts[set.id] or 0
		for _, bonus in set.bonuses do
			if worn >= bonus.pieces then
				table.insert(layers, {
					source = "set",
					label = string.format("%s (%d)", set.name, bonus.pieces),
					stats = bonus.stats,
					resist = bonus.resist,
				})
			end
		end
	end
	return layers, focus
end

function StatCalc.loadState(weight: number, carry: number): typeof(ItemRules.encumbrance[1])
	local ratio = weight / math.max(1, carry)
	for _, row in ItemRules.encumbrance do
		if ratio <= row.upTo then
			return row
		end
	end
	return ItemRules.encumbrance[#ItemRules.encumbrance]
end

function StatCalc.derive(layers: { Layer }, weight: number): Sheet
	local sums: { [string]: number } = {}
	local resist: { [string]: number } = {}
	local lines: { ItemTypes.SheetLine } = {}

	-- 1. base
	for _, def in StatDefs.list do
		if not StatDefs.itemLocal[def.id] then
			sums[def.id] = def.base
			if def.base ~= 0 then
				table.insert(lines, { stat = def.id, source = "base", label = "Base", value = def.base })
			end
		end
	end

	-- 2-6. every layer, summed per stat
	for _, layer in layers do
		for statId, v in (layer.stats or {}) :: any do
			if StatDefs.byId[statId] and not StatDefs.itemLocal[statId] and v ~= 0 then
				sums[statId] = (sums[statId] or 0) + v
				table.insert(lines, { stat = statId, source = layer.source, label = layer.label, value = v })
			end
		end
		for key, v in (layer.resist or {}) :: any do
			if v ~= 0 then
				resist[key] = (resist[key] or 0) + v
				table.insert(lines, { stat = "resist:" .. key, source = layer.source, label = layer.label, value = v })
			end
		end
	end

	-- 7. percent: each *Pct with pctOf multiplies its target once
	local final: { [string]: number } = table.clone(sums)
	for _, def in StatDefs.list do
		local target = def.pctOf
		if target and (sums[def.id] or 0) ~= 0 then
			local before = final[target] or 0
			final[target] = before * (1 + sums[def.id])
			table.insert(lines, { stat = target, source = "percent", label = StatDefs.format(def.id, sums[def.id]), value = final[target] - before })
		end
	end

	-- 8. load: encumbrance from the final carry capacity
	local carry = math.clamp(final.carryWeight or 60, StatDefs.byId.carryWeight.min or 1, StatDefs.byId.carryWeight.max or 1000)
	local load = StatCalc.loadState(weight, carry)
	if load.moveSpeedPct ~= 0 then
		final.moveSpeedPct = (final.moveSpeedPct or 0) + load.moveSpeedPct
		table.insert(lines, { stat = "moveSpeedPct", source = "load", label = load.name, value = load.moveSpeedPct })
	end
	if load.staminaRegenPct ~= 0 then
		final.staminaRegenPct = (final.staminaRegenPct or 0) + load.staminaRegenPct
		table.insert(lines, { stat = "staminaRegenPct", source = "load", label = load.name, value = load.staminaRegenPct })
	end

	-- 9. caps
	for _, def in StatDefs.list do
		local v = final[def.id]
		if v ~= nil then
			local clamped = math.clamp(v, def.min or -math.huge, def.max or math.huge)
			if clamped ~= v then
				table.insert(lines, { stat = def.id, source = "cap", label = "Limit", value = clamped - v })
				final[def.id] = clamped
			end
		end
	end

	return { final = final, resist = resist, lines = lines, weight = weight, carry = carry, load = load.id }
end

return StatCalc
