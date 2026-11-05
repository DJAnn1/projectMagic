--!strict
--[[
	ItemWidgets: item cells and tooltips, shared by every item window (inventory now; containers,
	crafting, trade and shops later), so items look the same everywhere (docs/Items.md §7).

		ItemWidgets.cell(view?, size, opts?) -> TextButton
		    rarity border + glyph, the item's icon (or generated glyph icon), count, durability bar,
		    NEW / favourite / locked / unusable marks. opts: { ref, selected, placeholder, hint, dim }
		    The button carries an "ItemRef" attribute (drag-and-drop finds drop targets by it).
		ItemWidgets.tooltip(parent, view, compare?) -> ()
		    every line a player needs: name in rarity colour + rarity word, requirements (✓/✗),
		    stats, affixes, attunement, set, focus, weapon, use, durability, weight, value, maker,
		    description; with `compare` (the item worn in the same slot) a ▲/▼ difference block
		ItemWidgets.rarityColor(rec) / ItemWidgets.resistName(key) / ItemWidgets.useText(def)

	Colour is never the only cue: rarity has a glyph and its word; better/worse is ▲/▼; met/unmet
	is ✓/✗.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local MasteryTiers = require(Shared.Magic.Data.MasteryTiers)
local ItemTypes = require(Shared.Items.ItemTypes)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local StatDefs = require(Shared.Items.Data.StatDefs)
local ItemRules = require(Shared.Items.Data.ItemRules)

local Kit = require(script.Parent.Kit)
local Theme = require(script.Parent.Theme)
local C = require(script.Parent.Components)

type ItemView = ItemTypes.ItemView
type Record = ItemTypes.Record

local ItemWidgets = {}

function ItemWidgets.rarityColor(rec: Record): Color3
	local rarity = ItemInstance.rarity(rec)
	return if Theme.settings.palette == "highContrast" then Theme.color.ink else rarity.color
end

function ItemWidgets.resistName(key: string): string
	if key == "all" then
		return "all magic"
	end
	local domain = Registry.domains[key]
	if domain then
		return domain.name
	end
	local property = Registry.properties[key]
	return if property and property.name then property.name else key
end

local function tierName(index: number): string
	local def = MasteryTiers.tiers[index + 1]
	return if def then def.name else ("tier " .. index)
end

local function requirementText(req: ItemTypes.Requirement): string
	local parts: { string } = {}
	for key, tier in (req.tier or {}) :: any do
		local where = if key == "any" then "any branch" else (Registry.branches[key] and Registry.branches[key].name or key)
		table.insert(parts, string.format("%s in %s", tierName(tier), where))
	end
	for domain in (req.affinity or {}) :: any do
		local d = Registry.domains[domain]
		table.insert(parts, string.format("a strong %s affinity", d and d.name or domain))
	end
	for _, domain in (req.awakened or {}) :: { string } do
		local d = Registry.domains[domain]
		table.insert(parts, string.format("%s awakened", d and d.name or domain))
	end
	table.sort(parts)
	return table.concat(parts, ", ")
end

local function statLine(statId: string, value: number): string
	local def = StatDefs.byId[statId]
	return string.format("%s %s", StatDefs.format(statId, value), if def then def.name else statId)
end

local function resistLine(key: string, value: number): string
	return string.format("%s%.0f%% vs %s", if value >= 0 then "+" else "−", math.abs(value) * 100, ItemWidgets.resistName(key))
end

local function sortedKeys(t: { [string]: any }): { string }
	local out = {}
	for k in t do
		table.insert(out, k)
	end
	table.sort(out)
	return out
end

local function minutes(seconds: number): string
	return if seconds >= 120 then string.format("%d min", math.floor(seconds / 60 + 0.5)) else string.format("%d s", seconds)
end

-- One sentence per use effect.
function ItemWidgets.useText(def: ItemTypes.ItemDef): { string }
	local out: { string } = {}
	for _, e in (def.use and def.use.effects or {}) :: { any } do
		if e.kind == "heal" then
			table.insert(out, string.format("Restores %d health%s", e.amount, if e.over then " over " .. minutes(e.over) else ""))
		elseif e.kind == "reservoir" then
			table.insert(out, if e.share then string.format("Restores %d%% of your reservoir", math.floor(e.share * 100 + 0.5)) else string.format("Restores %d reservoir", e.amount))
		elseif e.kind == "buff" then
			local bits = {}
			for _, id in sortedKeys(e.stats or {}) do
				table.insert(bits, statLine(id, e.stats[id]))
			end
			for _, key in sortedKeys(e.resist or {}) do
				table.insert(bits, resistLine(key, e.resist[key]))
			end
			table.insert(out, string.format("%s for %s: %s", e.name or e.id, minutes(e.duration), table.concat(bits, ", ")))
		elseif e.kind == "study" then
			local b = Registry.branches[e.branch]
			table.insert(out, string.format("Read to study %s (once)", b and b.name or e.branch))
		elseif e.kind == "spell" then
			local ok, text = pcall(MagicCore.describe, e.recipe)
			table.insert(out, "Casts: " .. (if ok then text else "a stored spell") .. " (you pay its reservoir)")
		elseif e.kind == "repair" then
			table.insert(out, string.format("Repairs your most worn gear by %d", e.amount))
		elseif e.kind == "cleanse" then
			table.insert(out, "Cures " .. table.concat(e.statuses, ", "))
		end
	end
	return out
end

-- ─── Cell ───────────────────────────────────────────────────────────────────

export type CellOptions = {
	ref: string?,
	selected: boolean?,
	placeholder: string?, -- glyph for an empty equipment slot
	hint: string?, -- key hint (quickbar)
	dim: boolean?,
	count: number?, -- override the count shown (quickbar totals)
}

function ItemWidgets.cell(view: ItemView?, size: number, opts: CellOptions?): TextButton
	local o: CellOptions = opts or {}
	local rec = view and view.rec
	local def = rec and ItemDatabase.get(rec.i)
	local rarityColor = if rec then ItemWidgets.rarityColor(rec) else Theme.color.line
	local button: TextButton = Kit.create(nil, "TextButton", {
		Name = o.ref or "Cell",
		Text = "",
		AutoButtonColor = false,
		BackgroundColor3 = if o.selected then Theme.color.panelRaised else Theme.color.panel,
		BorderSizePixel = 0,
		Size = UDim2.fromOffset(size, size),
		Selectable = true,
	})
	if o.ref then
		button:SetAttribute("ItemRef", o.ref)
	end
	C.corner(Theme.radius.s).Parent = button
	local rarityIndex = if rec then ItemInstance.rarityIndex(rec) else 1
	C.stroke(if o.selected then Theme.color.accent else rarityColor, if o.selected then 2 else (if rarityIndex >= 3 then 2 else 1)).Parent = button

	if not rec then
		if o.placeholder then
			Kit.create(nil, "TextLabel", {
				BackgroundTransparency = 1,
				Text = o.placeholder,
				TextColor3 = Theme.color.inkFaint,
				FontFace = Theme.font.body,
				TextScaled = true,
				Size = UDim2.fromScale(0.5, 0.5),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Parent = button,
			})
		end
	else
		local tint = if def then def.color else Theme.color.inkDim
		local faded = o.dim or (view and not view.ok) or ItemInstance.isBroken(rec)
		if def and def.icon ~= "" then
			Kit.create(nil, "ImageLabel", {
				BackgroundTransparency = 1,
				Image = def.icon,
				ImageTransparency = if faded then 0.3 else 0,
				Size = UDim2.fromScale(0.72, 0.72),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Parent = button,
			})
		else
			-- Generated icon: the item's glyph in its colour on a soft disc.
			local disc: Frame = Kit.create(nil, "Frame", {
				BackgroundColor3 = tint,
				BackgroundTransparency = 0.82,
				Size = UDim2.fromScale(0.7, 0.7),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Parent = button,
			})
			C.corner(size).Parent = disc
			Kit.create(nil, "TextLabel", {
				BackgroundTransparency = 1,
				Text = if def then def.glyph else "?",
				TextColor3 = tint,
				TextTransparency = if faded then 0.3 else 0,
				FontFace = Theme.font.bold,
				TextScaled = true,
				Size = UDim2.fromScale(0.5, 0.5),
				AnchorPoint = Vector2.new(0.5, 0.5),
				Position = UDim2.fromScale(0.5, 0.5),
				Parent = button,
			})
		end
		-- Rarity glyph (top left): shape, not just colour.
		if rarityIndex > 1 then
			Kit.create(nil, "TextLabel", {
				BackgroundTransparency = 1,
				Text = ItemInstance.rarity(rec).glyph,
				TextColor3 = rarityColor,
				FontFace = Theme.font.bold,
				TextSize = 12,
				Size = UDim2.fromOffset(14, 14),
				Position = UDim2.fromOffset(2, 1),
				Parent = button,
			})
		end
		-- Count (bottom right).
		local count = o.count or ItemInstance.count(rec)
		if count > 1 or o.count ~= nil then
			Kit.create(nil, "TextLabel", {
				BackgroundTransparency = 1,
				Text = tostring(count),
				TextColor3 = if count == 0 then Theme.color.inkFaint else Theme.color.ink,
				FontFace = Theme.font.mono,
				TextSize = 13,
				TextXAlignment = Enum.TextXAlignment.Right,
				TextStrokeTransparency = 0.4,
				AnchorPoint = Vector2.new(1, 1),
				Position = UDim2.new(1, -3, 1, -1),
				Size = UDim2.fromOffset(size - 6, 14),
				Parent = button,
			})
		end
		-- Marks (top right): NEW, favourite, locked, unusable, broken.
		local marks: { string } = {}
		if ItemInstance.hasFlag(rec, ItemInstance.NEW) then
			table.insert(marks, "NEW")
		end
		if ItemInstance.hasFlag(rec, ItemInstance.FAVORITE) then
			table.insert(marks, "♥")
		end
		if ItemInstance.hasFlag(rec, ItemInstance.LOCKED) then
			table.insert(marks, "🔒")
		end
		if view and not view.ok then
			table.insert(marks, "✗")
		end
		if ItemInstance.isBroken(rec) then
			table.insert(marks, "broken")
		end
		if #marks > 0 then
			Kit.create(nil, "TextLabel", {
				BackgroundTransparency = 1,
				Text = table.concat(marks, " "),
				TextColor3 = if view and not view.ok or ItemInstance.isBroken(rec) then Theme.color.danger else Theme.color.accent,
				FontFace = Theme.font.bold,
				TextSize = 10,
				TextXAlignment = Enum.TextXAlignment.Right,
				AnchorPoint = Vector2.new(1, 0),
				Position = UDim2.new(1, -2, 0, 1),
				Size = UDim2.fromOffset(size - 16, 12),
				Parent = button,
			})
		end
		-- Durability bar (bottom) once worn.
		local max = ItemInstance.maxDurability(rec)
		local dur = ItemInstance.durability(rec)
		if max and dur and dur < max then
			local share = dur / max
			local track: Frame = Kit.create(nil, "Frame", {
				BackgroundColor3 = Theme.color.bg,
				BorderSizePixel = 0,
				AnchorPoint = Vector2.new(0.5, 1),
				Position = UDim2.new(0.5, 0, 1, -2),
				Size = UDim2.new(1, -8, 0, 3),
				Parent = button,
			})
			Kit.create(nil, "Frame", {
				BackgroundColor3 = if share < 0.25 then Theme.color.danger elseif share < 0.5 then Theme.color.warn else Theme.color.good,
				BorderSizePixel = 0,
				Size = UDim2.fromScale(share, 1),
				Parent = track,
			})
		end
	end
	if o.hint and o.hint ~= "" then
		Kit.create(nil, "TextLabel", {
			BackgroundTransparency = 1,
			Text = o.hint,
			TextColor3 = Theme.color.inkDim,
			FontFace = Theme.font.bold,
			TextSize = 11,
			Position = UDim2.new(0, 3, 1, -14),
			Size = UDim2.fromOffset(14, 12),
			TextXAlignment = Enum.TextXAlignment.Left,
			Parent = button,
		})
	end
	return button
end

-- ─── Tooltip ────────────────────────────────────────────────────────────────

local function add(parent: Instance, order: number, text: string, role: string?, color: Color3?): number
	C.text(text, role or "caption", {
		TextColor3 = color or Theme.color.ink,
		LayoutOrder = order,
		Parent = parent,
	})
	return order + 1
end

-- The character stats a record gives right now (gated parts only when the view says they're on).
local function activeStats(view: ItemView): ({ [string]: number }, { [string]: number })
	local rolled = ItemInstance.rolled(view.rec)
	local stats = table.clone(rolled.stats)
	local resist = table.clone(rolled.resist)
	if view.att then
		for _, g in rolled.gated do
			for k, v in g.stats do
				stats[k] = (stats[k] or 0) + v
			end
			for k, v in g.resist do
				resist[k] = (resist[k] or 0) + v
			end
		end
	end
	local def = ItemDatabase.get(view.rec.i)
	for domain, bonus in (def and def.focus and def.focus.domains or {}) :: { [string]: number } do
		local statId = if domain == "any" then "spellPowerPct" else "power_" .. domain
		stats[statId] = (stats[statId] or 0) + bonus
	end
	if ItemInstance.isBroken(view.rec) or not view.ok then
		return {}, {}
	end
	return stats, resist
end

function ItemWidgets.tooltip(parent: Instance, view: ItemView, compare: ItemView?)
	local rec = view.rec
	local def = ItemDatabase.get(rec.i)
	local o = 1
	if not def then
		add(parent, o, "Unknown item (" .. rec.i .. ")", "label", Theme.color.danger)
		add(parent, o + 1, "This item no longer exists. It's kept safe in case it comes back.", "caption", Theme.color.inkDim)
		return
	end
	local rarity = ItemInstance.rarity(rec)
	local category = ItemRules.categories[def.category]
	o = add(parent, o, ItemInstance.displayName(rec) .. (if ItemInstance.count(rec) > 1 then "  ×" .. ItemInstance.count(rec) else ""), "label", ItemWidgets.rarityColor(rec))
	local subtitle = string.format("%s %s · %s", rarity.glyph, rarity.name, category and category.name or def.category)
	if def.equip then
		local slots: { string } = {}
		for _, slot in def.equip.slots do
			local name = ItemRules.slotById[slot].name
			if not table.find(slots, name) then
				table.insert(slots, name)
			end
		end
		subtitle ..= " · " .. table.concat(slots, " or ") .. (if def.equip.twoHanded then " (both hands)" else "")
	end
	o = add(parent, o, subtitle, "caption", Theme.color.inkDim)

	if def.requires then
		o = add(parent, o, string.format("%s Requires %s", if view.ok then "✓" else "✗", requirementText(def.requires)), "caption",
			if view.ok then Theme.color.good else Theme.color.danger)
	end

	-- Base stats and resistances.
	local rolled = ItemInstance.rolled(rec)
	local base = def.equip and def.equip.stats or {}
	local mult = rarity.baseMult * ItemInstance.qualityMult(rec)
	for _, id in sortedKeys(base) do
		if not StatDefs.itemLocal[id] then
			local sd = StatDefs.byId[id]
			o = add(parent, o, statLine(id, if sd and sd.format == "int" then base[id] else base[id] * mult))
		end
	end
	for _, key in sortedKeys(def.equip and def.equip.resist or {}) do
		o = add(parent, o, resistLine(key, ((def.equip :: any).resist)[key] * mult))
	end

	-- Affixes, by name.
	for _, affix in rolled.affixes do
		local bits: { string } = {}
		for _, id in sortedKeys(affix.stats) do
			table.insert(bits, statLine(id, affix.stats[id]))
		end
		for _, key in sortedKeys(affix.resist) do
			table.insert(bits, resistLine(key, affix.resist[key]))
		end
		local adef = ItemDatabase.affix(affix.id)
		local gated = adef and adef.attune
		local prefix = if gated then (if view.att then "✓ " else "✗ ") else "• "
		o = add(parent, o, string.format("%s%s: %s%s", prefix, affix.name, table.concat(bits, ", "), if affix.text and gated then " (" .. affix.text .. ")" else ""),
			"caption", if gated and not view.att then Theme.color.inkFaint else Theme.color.accent)
		if adef and adef.set then
			local set = ItemDatabase.set(adef.set)
			if set then
				local bonusBits = {}
				for _, bonus in set.bonuses do
					local parts = {}
					for _, id in sortedKeys(bonus.stats or {}) do
						table.insert(parts, statLine(id, (bonus.stats :: any)[id]))
					end
					for _, key in sortedKeys(bonus.resist or {}) do
						table.insert(parts, resistLine(key, (bonus.resist :: any)[key]))
					end
					table.insert(bonusBits, string.format("(%d) %s", bonus.pieces, table.concat(parts, ", ")))
				end
				o = add(parent, o, string.format("   Set: %s. %s", set.name, table.concat(bonusBits, "; ")), "caption", Theme.color.inkDim)
			end
		end
	end
	local attune = def.equip and def.equip.attune
	if attune then
		local bits = {}
		for _, id in sortedKeys(attune.stats or {}) do
			table.insert(bits, statLine(id, (attune.stats :: any)[id]))
		end
		o = add(parent, o, string.format("%s %s: %s", if view.att then "✓" else "✗", attune.text, table.concat(bits, ", ")), "caption",
			if view.att then Theme.color.accent else Theme.color.inkFaint)
	end

	-- Focus.
	if def.focus then
		local parts = {}
		for _, d in sortedKeys(def.focus.domains or {}) do
			local name = if d == "any" then "every spell" else (Registry.domains[d] and Registry.domains[d].name or d)
			table.insert(parts, string.format("%s +%d%%", name, math.floor(((def.focus.domains :: any)[d]) * 100 + 0.5)))
		end
		o = add(parent, o, string.format("Focus (%s): %s%s", if def.focus.grade == "major" then "held" else "worn",
			table.concat(parts, ", "), if (def.focus.stability or 0) > 0 then string.format(", %d%% steadier", math.floor((def.focus.stability :: number) * 100 + 0.5)) else ""), "caption", Theme.color.accent)
		o = add(parent, o, if def.focus.grade == "major"
			then "Casting power 6+ through a matching held focus has no bare-handed penalty."
			else "A worn focus halves the bare-handed penalty at power 6+.", "caption", Theme.color.inkDim)
	end

	-- Weapon.
	if def.weapon then
		local w = def.weapon
		o = add(parent, o, string.format("%s: %d %s damage, %.1f per second, reach %d (melee and ranged arrive with combat)",
			string.upper(string.sub(w.kind, 1, 1)) .. string.sub(w.kind, 2), w.damage, ItemWidgets.resistName(w.damageType), w.speed, w.reach), "caption", Theme.color.inkDim)
	end

	-- Use.
	if def.use then
		for _, line in ItemWidgets.useText(def) do
			o = add(parent, o, "Use: " .. line, "caption", Theme.color.good)
		end
		if (def.use.cooldown or 0) > 0 then
			o = add(parent, o, string.format("Cooldown %s%s", minutes(def.use.cooldown :: number), if def.use.group then " (shared with every " .. def.use.group .. ")" else ""), "caption", Theme.color.inkDim)
		end
	end
	if def.equip and def.equip.bagSlots then
		o = add(parent, o, string.format("+%d inventory slots while worn in a bag slot", def.equip.bagSlots), "caption", Theme.color.good)
	end

	-- Condition and facts.
	local max = ItemInstance.maxDurability(rec)
	if max then
		local dur = ItemInstance.durability(rec) :: number
		o = add(parent, o, if dur <= 0 then "✗ Broken: gives nothing until repaired" else string.format("Durability %d / %d", math.floor(dur), max), "caption",
			if dur <= 0 then Theme.color.danger elseif dur < max * 0.25 then Theme.color.warn else Theme.color.inkDim)
	end
	local facts = { string.format("Weight %.1f", ItemInstance.weight(rec)), string.format("Value %d", ItemInstance.value(rec)) }
	if def.stack > 1 then
		table.insert(facts, "stacks to " .. def.stack)
	end
	o = add(parent, o, table.concat(facts, " · "), "caption", Theme.color.inkDim)
	if rec.c then
		o = add(parent, o, "Made by " .. rec.c .. (if rec.q then string.format(" (quality %d)", rec.q) else ""), "caption", Theme.color.inkDim)
	end
	if rec.b then
		o = add(parent, o, "Bound to you: can't be traded", "caption", Theme.color.inkDim)
	end
	if def.quest then
		o = add(parent, o, "§ Quest item", "caption", Theme.color.accent)
	end
	o = add(parent, o, def.description, "caption", Theme.color.inkDim)

	-- Comparison with the item worn in the same slot.
	if compare and compare.rec ~= rec then
		local mine, minesResist = activeStats(view)
		local theirs, theirsResist = activeStats(compare)
		local lines: { { text: string, color: Color3 } } = {}
		local keys: { [string]: boolean } = {}
		for k in mine do
			keys[k] = true
		end
		for k in theirs do
			keys[k] = true
		end
		for _, id in sortedKeys(keys) do
			local delta = (mine[id] or 0) - (theirs[id] or 0)
			if math.abs(delta) > 1e-4 then
				table.insert(lines, { text = (if delta > 0 then "▲ " else "▼ ") .. statLine(id, delta), color = if delta > 0 then Theme.color.good else Theme.color.danger })
			end
		end
		local rkeys: { [string]: boolean } = {}
		for k in minesResist do
			rkeys[k] = true
		end
		for k in theirsResist do
			rkeys[k] = true
		end
		for _, key in sortedKeys(rkeys) do
			local delta = (minesResist[key] or 0) - (theirsResist[key] or 0)
			if math.abs(delta) > 1e-4 then
				table.insert(lines, { text = (if delta > 0 then "▲ " else "▼ ") .. resistLine(key, delta), color = if delta > 0 then Theme.color.good else Theme.color.danger })
			end
		end
		o = add(parent, o, "Compared with " .. ItemInstance.displayName(compare.rec) .. ":", "caption", Theme.color.ink)
		if #lines == 0 then
			o = add(parent, o, "  no difference in stats", "caption", Theme.color.inkDim)
		end
		for _, l in lines do
			o = add(parent, o, "  " .. l.text, "caption", l.color)
		end
	end
end

-- The item worn where `view`'s item would go (the slot it would replace), for comparisons.
function ItemWidgets.compareTarget(view: ItemView, find: (string) -> ItemView?): ItemView?
	local def = ItemDatabase.get(view.rec.i)
	if not def or not def.equip or string.sub(view.ref, 1, 2) == "e:" then
		return nil
	end
	for _, slot in def.equip.slots do
		local worn = find("e:" .. slot)
		if worn then
			return worn
		end
	end
	return nil
end

return ItemWidgets
