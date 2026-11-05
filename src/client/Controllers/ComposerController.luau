--!strict
--[[
	ComposerController: build a spell from its grammar, see what it will do, save it, slot it.

	Two modes (the composerMode setting; the header toggles it):
		Guided  ready-made cards: techniques you can already cast plus a "first spark" per awakened
		        domain. Pick a power and press Save; it goes straight into a free hotbar slot.
		Full    six steps: Branch > Property > Verb > Form > Modifiers > Power and source.
		        Every option is shown, and unavailable ones say why ("Unlocks at Adept",
		        "Conflicts with Silent"), so the grammar teaches itself.

	Live preview: MagicCore.computeStats on the client's estimated caster (UI/KnownCaster) at the
	player's current location (RegionInfo). Numbers carry "≈": the server recomputes with the real
	profile on every cast and its result is the only one that counts.

	Opening with args { recipe, key? } (from the Grimoire or a hotbar right-click) loads the
	recipe into Full mode for editing.

	Wide:     [ steps rail ] [ options for the current step ] [ preview + name + save + slots ]
	Compact:  [ step chips ]
	          [ options (55%) | brief preview, Details toggle, name + Save + slots (45%) ]
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local GuardRules = require(Shared.Magic.GuardRules)
local Strike = require(Shared.Magic.Strike)
local Types = require(Shared.Magic.Types)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

type Scope = Kit.Scope

type Draft = {
	branch: string?,
	property: string?,
	verb: string?,
	form: string?,
	modifiers: { string },
	power: number,
	costProfile: string,
}

type Option = {
	id: string,
	name: string,
	description: string,
	available: boolean,
	reason: string?,
	selected: boolean,
	domain: string?,
}

local HOTBAR_SLOTS = 8
local RAIL_WIDTH = 190
local PREVIEW_WIDTH = 350

local STEPS = {
	{ id = "branch", title = "Branch" },
	{ id = "property", title = "Property" },
	{ id = "verb", title = "Verb" },
	{ id = "form", title = "Form" },
	{ id = "modifiers", title = "Modifiers" },
	{ id = "power", title = "Power" },
}

-- Validation codes in the player's words; unknown codes show MagicCore's message.
local ERRORS: { [string]: string } = {
	BRANCH_LOCKED = "You haven't learned this branch yet.",
	PROPERTY_NOT_IN_BRANCH = "This branch can't touch that property.",
	VERB_TIER = "This verb needs a deeper branch.",
	VERB_MASTERY = "Your mastery here isn't high enough for this verb yet.",
	VERB_PROPERTY_INCOMPATIBLE = "That verb doesn't work on this property.",
	FORM_TIER = "This form needs a deeper branch.",
	FORM_MASTERY = "Your mastery here isn't high enough for this form yet.",
	FORM_VERB_INCOMPATIBLE = "That form doesn't fit this verb.",
	FORM_PROPERTY_INCOMPATIBLE = "That form can't shape this property.",
	MODIFIER_CONFLICT = "Two of these modifiers fight each other.",
	MODIFIER_TIER = "A modifier needs a deeper branch.",
	MODIFIER_FORM = "A modifier doesn't fit this form.",
	MODIFIER_VERB = "A modifier doesn't fit this verb.",
	TOO_MANY_MODIFIERS = "More modifiers than you can hold together.",
	POWER_OVER_CAP = "More power than you can reach in this branch yet.",
	POWER_OVER_BRANCH_MAX = "More power than this branch can ever hold.",
}

local WARNINGS: { [string]: string } = {
	OVERREACH = "Overreaching: beyond your comfortable power, so less stable.",
	AMBIENT_TOO_THIN = "Too little ambient magic here to draw on.",
	BLOCKED_BY_ENVIRONMENT = "The world here can't support this.",
	REQUIRES_TARGET = "Needs a target that has this property.",
	REQUIRES_SOURCE = "Needs some of this property nearby to work with.",
	REQUIRES_STORED = "Needs a charge you stored earlier.",
}

local FACTS: { [string]: string } = {
	waterVolume = "enough water nearby",
	groundMass = "solid ground beneath",
	seismicStress = "stress built up in the earth",
	fuel = "something to burn",
	stormCharge = "charge in the air",
}

local SAVE_REFUSALS: { [string]: string } = {
	SPELLBOOK_FULL = "Your spellbook is full (100). Forget a spell first.",
	NOT_LOADED = "Still gathering yourself... try again in a moment.",
	RATE_LIMITED = "Easy. Try again in a moment.",
	INVALID_NAME = "That name can't be used.",
	FILTER_UNAVAILABLE = "Names can't be checked right now; saved with its description.",
}

local ComposerController = {
	name = "ComposerController",
	dependencies = { "InterfaceController", "MagicStateController" },
}

local interface: any = nil
local magic: any = nil

local function emptyDraft(): Draft
	return { modifiers = {}, power = 1, costProfile = Registry.Tuning.DEFAULT_COST_PROFILE }
end

-- Survive rebuilds and closing the screen: a half-built spell is never lost.
local draft = Kit.value(emptyDraft())
local step = Kit.value(1)
local status = Kit.value(nil :: { text: string, color: Color3 }?)
local showDetails = Kit.value(false) -- compact: full preview instead of options
local modeOverride: string? = nil -- "advanced" while editing a recipe passed in args
local loadedArgs: any = nil
local spellName = ""
local cardPowers: { [string]: Kit.Value<number> } = {}

-- ─── Draft logic ────────────────────────────────────────────────────────────

local function recipeOf(d: Draft): Types.Recipe?
	if not (d.branch and d.property and d.verb and d.form) then
		return nil
	end
	local mods = table.clone(d.modifiers)
	table.sort(mods)
	return {
		v = Registry.Tuning.RECIPE_VERSION,
		branch = d.branch,
		property = d.property,
		verb = d.verb,
		form = d.form,
		modifiers = mods,
		power = d.power,
		costProfile = d.costProfile,
	}
end

local function templateFor(d: Draft): Types.RecipeTemplate?
	if not (d.branch and d.property and d.verb and d.form) then
		return nil
	end
	for _, t in magic:templatesFor(d.branch) do
		if t.property == d.property and t.verb == d.verb and t.form == d.form then
			return t
		end
	end
	return nil
end

-- Drops every later choice that the earlier ones no longer allow, and clamps power.
local function prune(d: Draft): Draft
	local out = table.clone(d)
	out.modifiers = table.clone(d.modifiers)
	local templates = if out.branch then magic:templatesFor(out.branch) else {}
	local function any(pred: (Types.RecipeTemplate) -> boolean): boolean
		for _, t in templates do
			if pred(t) then
				return true
			end
		end
		return false
	end
	if out.property and not any(function(t)
		return t.property == out.property
	end) then
		out.property = nil
	end
	if not out.property or (out.verb and not any(function(t)
		return t.property == out.property and t.verb == out.verb
	end)) then
		out.verb = nil
	end
	if not out.verb or (out.form and not any(function(t)
		return t.property == out.property and t.verb == out.verb and t.form == out.form
	end)) then
		out.form = nil
	end
	local template = templateFor(out)
	if template then
		local kept: { string } = {}
		for _, m in out.modifiers do
			if table.find(template.modifiers, m) and #kept < template.modifierSlots then
				table.insert(kept, m)
			end
		end
		out.modifiers = kept
		out.power = math.clamp(out.power, 1, math.max(1, template.maxPower))
	else
		out.modifiers = {}
	end
	return out
end

local function update(changes: { [string]: any })
	local d = table.clone(draft:get())
	for key, value in changes do
		(d :: any)[key] = value
	end
	draft:set(prune(d))
	status:set(nil)
end

local function load(recipe: any)
	draft:set(prune({
		branch = recipe.branch,
		property = recipe.property,
		verb = recipe.verb,
		form = recipe.form,
		modifiers = table.clone(recipe.modifiers or {}),
		power = recipe.power or 1,
		costProfile = recipe.costProfile or Registry.Tuning.DEFAULT_COST_PROFILE,
	}))
	step:set(#STEPS)
	status:set(nil)
end

local function tierOf(branchId: string): (number, number)
	local view = magic:branchView(branchId)
	return if view then view.tier else 0, if view then view.mastery else 0
end

-- ─── Options per step ───────────────────────────────────────────────────────

local function branchOptions(d: Draft): { Option }
	local progression = magic.progression:get()
	local options: { Option } = {}
	if not progression then
		return options
	end
	local views: { any } = table.clone(progression.branches)
	table.sort(views, function(a, b)
		local da, db = Registry.branches[a.id], Registry.branches[b.id]
		if da.domains[1] ~= db.domains[1] then
			return da.domains[1] < db.domains[1]
		end
		if da.tier ~= db.tier then
			return da.tier < db.tier
		end
		return da.name < db.name
	end)
	for _, view in views do
		local def = Registry.branches[view.id]
		table.insert(options, {
			id = view.id,
			name = def.name,
			description = view.tierName,
			available = true,
			selected = d.branch == view.id,
			domain = def.domains[1],
		})
	end
	return options
end

local function propertyOptions(d: Draft): { Option }
	local options: { Option } = {}
	local branch = d.branch and Registry.branches[d.branch]
	if not branch then
		return options
	end
	local usable: { [string]: boolean } = {}
	for _, t in magic:templatesFor(branch.id) do
		usable[t.property] = true
	end
	for _, propertyId in branch.properties do
		local p = Registry.properties[propertyId]
		table.insert(options, {
			id = propertyId,
			name = p.name,
			description = p.description,
			available = usable[propertyId] == true,
			reason = if usable[propertyId] then nil else "Nothing you can do with it yet",
			selected = d.property == propertyId,
		})
	end
	return options
end

local function verbOptions(d: Draft): { Option }
	local options: { Option } = {}
	local branch = d.branch and Registry.branches[d.branch]
	local property = d.property and Registry.properties[d.property]
	if not branch or not property then
		return options
	end
	local usable: { [string]: boolean } = {}
	for _, t in magic:templatesFor(branch.id) do
		if t.property == d.property then
			usable[t.verb] = true
		end
	end
	local tier = tierOf(branch.id)
	for _, verbId in Registry.verbIds do
		local verb = Registry.verbs[verbId]
		local reason: string? = nil
		if not usable[verbId] then
			if verb.minTier > branch.tier then
				reason = "Needs a deeper branch"
			elseif Registry.verbMasteryTier[verbId] > tier then
				reason = "Unlocks at " .. MagicCore.tierDef(Registry.verbMasteryTier[verbId]).name
			elseif Registry.verbPropertyEff[verbId][d.property :: string] <= 0 then
				reason = string.format("Can't %s %s", string.lower(verb.name), string.lower(property.name))
			else
				reason = "No form fits this yet"
			end
		end
		table.insert(options, {
			id = verbId,
			name = verb.name,
			description = verb.description,
			available = reason == nil,
			reason = reason,
			selected = d.verb == verbId,
		})
	end
	return options
end

local function formOptions(d: Draft): { Option }
	local options: { Option } = {}
	local branch = d.branch and Registry.branches[d.branch]
	local property = d.property and Registry.properties[d.property]
	if not branch or not property or not d.verb then
		return options
	end
	local usable: { [string]: boolean } = {}
	for _, t in magic:templatesFor(branch.id) do
		if t.property == d.property and t.verb == d.verb then
			usable[t.form] = true
		end
	end
	local tier, mastery = tierOf(branch.id)
	for _, formId in Registry.formIds do
		local form = Registry.forms[formId]
		local reason: string? = nil
		if not usable[formId] then
			if form.minTier > branch.tier then
				reason = "Needs a deeper branch"
			elseif Registry.formMasteryTier[formId] > tier then
				reason = "Unlocks at " .. MagicCore.tierDef(Registry.formMasteryTier[formId]).name
			elseif form.minMastery > mastery then
				reason = string.format("Needs mastery %d here", form.minMastery)
			elseif Registry.formVerbEff[formId][d.verb] <= 0 then
				reason = "Doesn't fit " .. Registry.verbs[d.verb].name
			elseif Registry.formCategoryBlocked[formId][property.category] then
				reason = string.format("Can't shape %s this way", string.lower(property.category))
			else
				reason = "Not available"
			end
		end
		table.insert(options, {
			id = formId,
			name = form.name,
			description = form.description,
			available = reason == nil,
			reason = reason,
			selected = d.form == formId,
		})
	end
	return options
end

local function modifierOptions(d: Draft): ({ Option }, number)
	local options: { Option } = {}
	local template = templateFor(d)
	if not template or not d.branch then
		return options, 0
	end
	local branch = Registry.branches[d.branch]
	for _, modId in Registry.modifierIds do
		local mod = Registry.modifiers[modId]
		local chosen = table.find(d.modifiers, modId) ~= nil
		local reason: string? = nil
		if not table.find(template.modifiers, modId) then
			reason = if mod.minTier > branch.tier then "Needs a deeper branch" else "Doesn't fit this verb or form"
		elseif not chosen then
			for _, other in d.modifiers do
				if Registry.modifierConflicts[modId][other] then
					reason = "Conflicts with " .. Registry.modifiers[other].name
					break
				end
			end
			if not reason and #d.modifiers >= template.modifierSlots then
				reason = string.format("All %d slots used", template.modifierSlots)
			end
		end
		table.insert(options, {
			id = modId,
			name = mod.name,
			description = mod.description,
			available = reason == nil,
			reason = reason,
			selected = chosen,
		})
	end
	return options, template.modifierSlots
end

-- ─── Shared builders ────────────────────────────────────────────────────────

local function optionTile(option: Option, order: number, onChoose: () -> ()): TextButton
	local button = C.button("", if option.available then onChoose else nil, {
		kind = "ghost",
		selected = option.selected,
		disabled = not option.available,
		height = 64,
	}, { LayoutOrder = order, Size = UDim2.new(1, 0, 0, 64) })
	local inner: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = button,
	})
	C.padding(Theme.space.xs, Theme.space.s).Parent = inner
	C.list("x", Theme.space.s, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = inner
	if option.domain then
		C.badge(option.domain, 32).Parent = inner
	end
	local texts: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, if option.domain then -44 else 0, 1, 0),
		Parent = inner,
	})
	C.list("y", 0, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = texts
	C.text((if option.selected then "✓ " else "") .. option.name, "label", {
		TextColor3 = if option.available then Theme.color.ink else Theme.color.inkFaint,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}).Parent = texts
	C.text(option.reason or option.description, "caption", {
		TextColor3 = if option.reason then Theme.color.warn else Theme.color.inkDim,
		TextWrapped = false,
		TextTruncate = Enum.TextTruncate.AtEnd,
	}).Parent = texts
	return button
end

local function statLine(parent: Instance, order: number, label: string, value: string, color: Color3?)
	local line: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, Theme.text("body") + 6),
		LayoutOrder = order,
		Parent = parent,
	})
	C.text(label, "body", { Size = UDim2.fromScale(0.5, 1), AutomaticSize = Enum.AutomaticSize.None, TextColor3 = Theme.color.inkDim, Parent = line })
	C.text(value, "body", {
		Position = UDim2.fromScale(0.5, 0),
		Size = UDim2.fromScale(0.5, 1),
		AutomaticSize = Enum.AutomaticSize.None,
		TextXAlignment = Enum.TextXAlignment.Right,
		FontFace = Theme.font.mono,
		TextColor3 = color or Theme.color.ink,
		Parent = line,
	})
end

local function fmt(x: number): string
	if x >= 100 then
		return string.format("%d", math.floor(x + 0.5))
	end
	return string.format("%.1f", x)
end

-- Human sentence for a recipe: "Generate Luminosity as a Beam".
local function sentence(recipe: Types.Recipe): string
	local verb, property, form = Registry.verbs[recipe.verb], Registry.properties[recipe.property], Registry.forms[recipe.form]
	return string.format("%s %s as %s", verb and verb.name or "?", property and property.name or "?", form and form.name or "?")
end

local function environmentRule(id: string): Types.EnvironmentRuleDef?
	for _, rule in Registry.environmentRules do
		if rule.id == id then
			return rule
		end
	end
	return nil
end

-- The full preview: stats, warnings, errors. `brief` keeps only the three numbers that matter most.
local function buildStats(parent: Instance, recipe: Types.Recipe?, brief: boolean)
	local order = 0
	local function o(): number
		order += 1
		return order
	end
	if not recipe then
		local d = draft:get()
		local missing = if not d.branch then "a branch" elseif not d.property then "a property" elseif not d.verb then "a verb" else "a form"
		C.text("Choose " .. missing .. " to see what the spell will do.", "body", { LayoutOrder = o(), TextColor3 = Theme.color.inkDim }).Parent = parent
		return
	end

	C.text(sentence(recipe), "heading", { LayoutOrder = o(), TextColor3 = Theme.branchColor(recipe.branch) }).Parent = parent
	if not brief then
		local mods: { string } = {}
		for _, m in recipe.modifiers do
			table.insert(mods, Registry.modifiers[m].name)
		end
		C.text(string.format("%s · power %d%s", Registry.branches[recipe.branch].name, recipe.power, if #mods > 0 then " · " .. table.concat(mods, ", ") else ""), "caption", { LayoutOrder = o() }).Parent = parent
	end

	local stats, errors = magic:preview(recipe)
	if not stats then
		for _, e in errors do
			local line = C.check(false, ERRORS[e.code] or e.message)
			line.LayoutOrder = o()
			line.Parent = parent
		end
		return
	end

	local reservoir = magic.reservoir:get()
	local cost = stats.costBreakdown.reservoir
	local overdraws = reservoir ~= nil and cost > reservoir.current
	statLine(parent, o(), "Cost", "≈ " .. fmt(cost) .. (if overdraws then "  !" else ""), if overdraws then Theme.color.warn else nil)
	statLine(parent, o(), "Power", "≈ " .. fmt(stats.power))
	local backfire = stats.backfireChance
	statLine(parent, o(), "Backfire", string.format("≈ %d%%", math.floor(backfire * 100 + 0.5)), if backfire >= 0.15 then Theme.color.danger elseif backfire >= 0.05 then Theme.color.warn else nil)
	if brief then
		return
	end

	if stats.costBreakdown.ambient > 0 then
		statLine(parent, o(), "  from ambient", "≈ " .. fmt(stats.costBreakdown.ambient))
	end
	if stats.costBreakdown.vitalHp > 0 then
		statLine(parent, o(), "  from your life", "≈ " .. fmt(stats.costBreakdown.vitalHp) .. " HP", Theme.color.danger)
	end
	if reservoir and reservoir.max > 0 then
		local bar = C.bar(nil, cost / reservoir.max, if overdraws then Theme.color.warn else Theme.color.reservoir, 6)
		bar.LayoutOrder = o()
		bar.Parent = parent
		C.text(string.format("of your reservoir (%d now)", reservoir.current), "caption", { LayoutOrder = o() }).Parent = parent
	end
	statLine(parent, o(), "Range", fmt(stats.range) .. " studs")
	if stats.area > 0 then
		statLine(parent, o(), "Area", fmt(stats.area) .. " studs")
	end
	if stats.duration > 0 then
		statLine(parent, o(), "Duration", fmt(stats.duration) .. " s")
	end
	statLine(parent, o(), "Cast time", fmt(stats.castTime) .. " s")
	statLine(parent, o(), "Cooldown", fmt(stats.cooldown) .. " s")
	if stats.maxTargets > 0 then
		statLine(parent, o(), "Targets", tostring(stats.maxTargets))
	end
	-- How guards treat it (Shared/Magic/GuardRules): blockable, pierces, or unblockable.
	statLine(parent, o(), "Guards", GuardRules.label(GuardRules.kindOfRecipe(stats.recipe)))
	-- Your domain's first attack (Shared/Magic/Data/Strikes): its name, and what it adds.
	local _, strike = Strike.find(stats.recipe)
	if strike then
		local extra = if strike.rider then " · " .. strike.rider.word else ""
		statLine(parent, o(), "Strike", "⚔ " .. strike.name .. extra)
	end
	statLine(parent, o(), "Instability", string.format("%d%%", math.floor(stats.instability * 100 + 0.5)))

	if stats.blockedBy then
		local rule = environmentRule(stats.blockedBy)
		local line = C.check(false, "Impossible here" .. (if rule then ": " .. rule.description else "."))
		line.LayoutOrder = o()
		line.TextColor3 = Theme.color.danger
		line.Parent = parent
	end
	for _, warning in stats.warnings do
		local text = WARNINGS[warning]
		if not text and string.sub(warning, 1, 12) == "ENV_UNKNOWN:" then
			local fact = string.sub(warning, 13)
			text = "Depends on the world where you cast it: " .. (FACTS[fact] or fact) .. "."
		end
		C.text("! " .. (text or warning), "caption", { LayoutOrder = o(), TextColor3 = Theme.color.warn }).Parent = parent
	end
	C.text("≈ Estimates from what you know of yourself. Casting reveals the truth.", "caption", { LayoutOrder = o(), TextColor3 = Theme.color.inkFaint }).Parent = parent
end

-- Slot picker: shown once the current recipe is in your spellbook.
local function buildSlots(parent: Instance, key: string)
	local block: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 50,
		Parent = parent,
	})
	C.list("y", Theme.space.xs).Parent = block
	C.text("Place in hotbar", "label", { LayoutOrder = 1 }).Parent = block
	local grid: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = block,
	})
	C.grid(Theme.minTouch + 30, Theme.minTouch, Theme.space.xs).Parent = grid
	local hotbar = magic.hotbar:get()
	for slot = 1, HOTBAR_SLOTS do
		local here = hotbar[slot] == key
		C.button(tostring(slot), function()
			task.spawn(function()
				if magic:setHotbarSlot(slot, key) then
					status:set({ text = "Placed in slot " .. slot .. ".", color = Theme.color.good })
				end
			end)
		end, { kind = if here then "primary" else "ghost", selected = here, sound = "confirm" }, { LayoutOrder = slot }).Parent = grid
	end
end

local function save(recipe: Types.Recipe, name: string?, autoSlot: boolean)
	task.spawn(function()
		local ok, keyOrReason, displayName, refusal = magic:saveSpell(recipe, name)
		if not ok then
			status:set({ text = SAVE_REFUSALS[keyOrReason] or ERRORS[keyOrReason] or ("Couldn't save (" .. keyOrReason .. ")."), color = Theme.color.warn })
			C.sound("deny")
			return
		end
		local text = "Saved: " .. tostring(displayName)
		if refusal then
			text ..= ". " .. (SAVE_REFUSALS[refusal] or "The name wasn't accepted; it keeps its description.")
		end
		if autoSlot then
			local hotbar = magic.hotbar:get()
			for slot = 1, HOTBAR_SLOTS do
				if hotbar[slot] == keyOrReason then
					break
				elseif hotbar[slot] == nil then
					if magic:setHotbarSlot(slot, keyOrReason) then
						text ..= string.format(" In slot %d.", slot)
					end
					break
				end
			end
		end
		status:set({ text = text, color = Theme.color.good })
	end)
end

local function statusLine(scope: Scope, parent: Instance, order: number)
	local label = C.text("", "body", { LayoutOrder = order, Parent = parent })
	local function refresh()
		local s = status:get()
		label.Visible = s ~= nil
		if s then
			label.Text = s.text
			label.TextColor3 = s.color
		end
	end
	scope:add(status:observe(refresh))
	refresh()
end

-- ─── Full mode ──────────────────────────────────────────────────────────────

local function stepValue(d: Draft, id: string): string?
	if id == "branch" then
		return d.branch and Registry.branches[d.branch].name
	elseif id == "property" then
		return d.property and Registry.properties[d.property].name
	elseif id == "verb" then
		return d.verb and Registry.verbs[d.verb].name
	elseif id == "form" then
		return d.form and Registry.forms[d.form].name
	elseif id == "modifiers" then
		return if #d.modifiers > 0 then tostring(#d.modifiers) .. " chosen" else (if d.form then "none" else nil)
	end
	return if d.form then string.format("P%d · %s", d.power, Registry.Tuning.CostProfiles[d.costProfile].name) else nil
end

-- Steps are reachable once everything before them is chosen.
local function reachable(d: Draft, index: number): boolean
	local needs = { true, d.branch ~= nil, d.property ~= nil, d.verb ~= nil, d.form ~= nil, d.form ~= nil }
	return needs[index] == true
end

local function buildRail(scope: Scope, parent: Instance, compact: boolean)
	Kit.dynamic(scope, { draft, step }, function(s)
		local holder: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Parent = parent,
		})
		s:add(holder)
		local d = draft:get()
		if compact then
			local scroll = C.scroll({
				Parent = holder,
				ScrollingDirection = Enum.ScrollingDirection.X,
				AutomaticCanvasSize = Enum.AutomaticSize.X,
			})
			C.list("x", Theme.space.xs).Parent = scroll
			for index, def in STEPS do
				local value = stepValue(d, def.id)
				local button = C.button(if value then value else string.format("%d. %s", index, def.title), function()
					step:set(index)
					showDetails:set(false)
				end, { kind = "ghost", selected = step:get() == index, disabled = not reachable(d, index) }, {
					Size = UDim2.fromOffset(0, Theme.minTouch),
					AutomaticSize = Enum.AutomaticSize.X,
					LayoutOrder = index,
				})
				C.padding(0, Theme.space.m).Parent = button
				button.Parent = scroll
			end
			return
		end
		C.list("y", Theme.space.s).Parent = holder
		for index, def in STEPS do
			local value = stepValue(d, def.id)
			local button = C.button(string.format("%d. %s\n%s", index, def.title, value or "-"), function()
				step:set(index)
			end, { kind = "ghost", selected = step:get() == index, disabled = not reachable(d, index), height = 56 }, {
				LayoutOrder = index,
				Size = UDim2.new(1, 0, 0, 56),
				TextXAlignment = Enum.TextXAlignment.Left,
			})
			C.padding(Theme.space.xs, Theme.space.m).Parent = button
			button.Parent = holder
		end
	end)
end

local function buildPowerStep(parent: Instance, d: Draft)
	local template = templateFor(d)
	if not template then
		return
	end
	local region = magic.region:get()
	C.text("Power", "heading", { LayoutOrder = 1 }).Parent = parent
	C.text(string.format("Comfortable up to %d. Up to %d is within reach, but overreaching is less stable.", math.floor(template.comfortPower), template.maxPower), "caption", { LayoutOrder = 2 }).Parent = parent
	local row: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 3,
		Parent = parent,
	})
	C.list("x", Theme.space.xs, { Wraps = true }).Parent = row
	for p = Registry.Tuning.MIN_POWER, Registry.Tuning.MAX_POWER do
		local reachableP = p <= template.maxPower
		local comfortable = p <= math.floor(template.comfortPower)
		local button = C.button(tostring(p), function()
			update({ power = p })
		end, {
			kind = "ghost",
			selected = d.power == p,
			disabled = not reachableP,
		}, { Size = UDim2.fromOffset(Theme.minTouch, Theme.minTouch), LayoutOrder = p })
		if reachableP and not comfortable then
			button.TextColor3 = Theme.color.warn -- overreach: colour AND the caption above
		end
		button.Parent = row
	end

	C.text("Paid from", "heading", { LayoutOrder = 4 }).Parent = parent
	local order = 5
	local ids: { string } = {}
	for id in Registry.Tuning.CostProfiles do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local profile = Registry.Tuning.CostProfiles[id]
		local thin = profile.minDensity > 0 and region ~= nil and region.density < profile.minDensity
		optionTile({
			id = id,
			name = profile.name,
			description = profile.description,
			available = not thin,
			reason = if thin then "Too little ambient magic here" else nil,
			selected = d.costProfile == id,
		}, order, function()
			update({ costProfile = id })
		end).Parent = parent
		order += 1
	end
end

local function buildOptions(scope: Scope, parent: Instance)
	Kit.dynamic(scope, { draft, step, magic.known, magic.region }, function(s)
		local scroll = C.scroll({ Parent = parent })
		s:add(scroll)
		C.list("y", Theme.space.s).Parent = scroll
		C.padding(Theme.space.xs).Parent = scroll

		local d = draft:get()
		local index = step:get()
		local def = STEPS[index]
		if def.id == "power" then
			buildPowerStep(scroll, d)
			return
		end

		local options: { Option }
		local hint = ""
		if def.id == "branch" then
			options = branchOptions(d)
			hint = "Which part of your magic?"
		elseif def.id == "property" then
			options = propertyOptions(d)
			hint = "What will the spell affect?"
		elseif def.id == "verb" then
			options = verbOptions(d)
			hint = "What will you do to it?"
		elseif def.id == "form" then
			options = formOptions(d)
			hint = "What shape does it take?"
		else
			local slots
			options, slots = modifierOptions(d)
			hint = string.format("Optional refinements. You can hold %d.", slots)
		end
		C.text(hint, "heading", { LayoutOrder = 0 }).Parent = scroll

		for order, option in options do
			optionTile(option, order, function()
				if def.id == "modifiers" then
					local mods = table.clone(d.modifiers)
					local at = table.find(mods, option.id)
					if at then
						table.remove(mods, at)
					else
						table.insert(mods, option.id)
					end
					update({ modifiers = mods })
				else
					update({ [def.id] = option.id })
					step:set(math.min(index + 1, #STEPS))
				end
			end).Parent = scroll
		end
		if #options == 0 then
			C.text("Nothing to choose here yet.", "body", { LayoutOrder = 1, TextColor3 = Theme.color.inkDim }).Parent = scroll
		end
	end)
end

-- Name box + Save + slot picker + status. Built once: re-rendering would steal the text box's focus.
local function buildSaveArea(scope: Scope, parent: Instance)
	local area: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 100,
		Parent = parent,
	})
	C.list("y", Theme.space.s).Parent = area

	local box: TextBox = Kit.create(nil, "TextBox", {
		LayoutOrder = 1,
		Size = UDim2.new(1, 0, 0, Theme.minTouch),
		BackgroundColor3 = Theme.color.panel,
		TextColor3 = Theme.color.ink,
		PlaceholderText = "Name it (optional)",
		PlaceholderColor3 = Theme.color.inkFaint,
		Text = spellName,
		ClearTextOnFocus = false,
		FontFace = Theme.font.body,
		TextSize = Theme.text("body"),
		TextXAlignment = Enum.TextXAlignment.Left,
		Parent = area,
	})
	C.corner().Parent = box
	C.stroke().Parent = box
	C.padding(0, Theme.space.s).Parent = box
	box:GetPropertyChangedSignal("Text"):Connect(function()
		if utf8.len(box.Text) and (utf8.len(box.Text) :: number) > 32 then
			box.Text = string.sub(box.Text, 1, (utf8.offset(box.Text, 33) or 33) - 1)
		end
		spellName = box.Text
	end)

	local dynamicHolder: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 2,
		Parent = area,
	})
	Kit.dynamic(scope, { draft, magic.known, magic.spellbook, magic.hotbar }, function(s)
		local holder: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = dynamicHolder,
		})
		s:add(holder)
		C.list("y", Theme.space.s).Parent = holder
		local recipe = recipeOf(draft:get())
		local stats = recipe and magic:preview(recipe)
		C.button("Save to spellbook", function()
			if recipe then
				local name = string.match(spellName, "^%s*(.-)%s*$") or ""
				save(recipe, if name ~= "" then name else nil, false) -- Full mode shows the slot picker instead
			end
		end, { kind = "primary", disabled = stats == nil, sound = "confirm" }, { LayoutOrder = 1, Parent = holder })

		if recipe then
			local normalized = MagicCore.normalizeRecipe(recipe)
			local key = normalized and MagicCore.recipeKey(normalized)
			if key and magic:spell(key) then
				buildSlots(holder, key)
			end
		end
	end)
	statusLine(scope, area, 3)
end

local function buildPreview(scope: Scope, parent: Instance, compact: boolean)
	Kit.dynamic(scope, { draft, magic.known, magic.region, showDetails }, function(s)
		local holder: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
			Parent = parent,
		})
		s:add(holder)
		C.list("y", Theme.space.xs).Parent = holder
		local brief = compact and not showDetails:get()
		buildStats(holder, recipeOf(draft:get()), brief)
		if compact then
			C.button(if showDetails:get() then "Hide details" else "Details", function()
				showDetails:set(not showDetails:get())
			end, { kind = "ghost" }, { LayoutOrder = 99, Parent = holder })
		end
	end)
	buildSaveArea(scope, parent)
end

local function buildFull(scope: Scope, body: Frame, compact: boolean)
	if compact then
		local railHeight = Theme.minTouch + Theme.space.s
		local rail: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, railHeight),
			Parent = body,
		})
		buildRail(scope, rail, true)
		-- Options and the preview share the remaining height; Details swaps the options for the full preview.
		local middle: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Position = UDim2.fromOffset(0, railHeight),
			Size = UDim2.new(0.55, -Theme.space.s, 1, -railHeight),
			Parent = body,
		})
		buildOptions(scope, middle)
		local side = C.scroll({
			Position = UDim2.new(0.55, 0, 0, railHeight),
			Size = UDim2.new(0.45, 0, 1, -railHeight),
			Parent = body,
		})
		C.list("y", Theme.space.s).Parent = side
		buildPreview(scope, side, true)
		return
	end

	local rail: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(0, RAIL_WIDTH, 1, 0),
		Parent = body,
	})
	buildRail(scope, rail, false)
	local middle: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(RAIL_WIDTH + Theme.space.l, 0),
		Size = UDim2.new(1, -(RAIL_WIDTH + PREVIEW_WIDTH + 2 * Theme.space.l), 1, 0),
		Parent = body,
	})
	buildOptions(scope, middle)
	local side = C.panel({
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, PREVIEW_WIDTH, 1, 0),
		Parent = body,
	})
	local sideScroll = C.scroll({ Parent = side })
	C.padding(Theme.space.m).Parent = sideScroll
	C.list("y", Theme.space.s).Parent = sideScroll
	buildPreview(scope, sideScroll, false)
end

-- ─── Guided mode ────────────────────────────────────────────────────────────

type Card = { id: string, name: string, description: string, recipe: any, domain: string }

-- Techniques you can cast now, plus a first spark for any awakened domain without one.
local function guidedCards(): ({ Card }, { string })
	local known = magic.known:get()
	local cards: { Card } = {}
	local later: { string } = {}
	if not known then
		return cards, later
	end
	local covered: { [string]: boolean } = {}
	local ids: { string } = {}
	for id in Registry.techniques do
		table.insert(ids, id)
	end
	table.sort(ids, function(a, b)
		local ta, tb = Registry.techniques[a], Registry.techniques[b]
		if ta.domain ~= tb.domain then
			return ta.domain < tb.domain
		end
		if ta.tier ~= tb.tier then
			return ta.tier < tb.tier
		end
		return a < b
	end)
	local laterByDomain: { [string]: boolean } = {}
	for _, id in ids do
		local technique = Registry.techniques[id]
		if not known.caster.awakened[technique.domain] then
			continue
		end
		local ok = MagicCore.validateRecipe(technique.recipe, known.caster)
		if ok then
			covered[technique.domain] = true
			table.insert(cards, { id = id, name = technique.name, description = technique.description, recipe = technique.recipe, domain = technique.domain })
		elseif not laterByDomain[technique.domain] then
			laterByDomain[technique.domain] = true
			table.insert(later, string.format("%s (%s, at %s)", technique.name, Registry.domains[technique.domain].name, MagicCore.tierDef(technique.tier).name))
		end
	end
	for _, domainId in Registry.domainIds do
		if known.caster.awakened[domainId] and not covered[domainId] then
			local template = magic:templatesFor(domainId)[1]
			if template then
				local recipe = { branch = template.branch, property = template.property, verb = template.verb, form = template.form, power = 1 }
				table.insert(cards, 1, {
					id = "spark_" .. domainId,
					name = "First spark: " .. Registry.domains[domainId].name,
					description = sentence(recipe :: any) .. ". The smallest thing you can do. Try it and see.",
					recipe = recipe,
					domain = domainId,
				})
			end
		end
	end
	return cards, later
end

local function buildCard(scope: Scope, parent: Instance, card: Card, order: number)
	local power = cardPowers[card.id]
	if not power then
		power = Kit.value(card.recipe.power or 1)
		cardPowers[card.id] = power
	end
	local frame = C.panel({
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	C.padding(Theme.space.m).Parent = frame
	C.list("y", Theme.space.s).Parent = frame
	local head: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 1,
		Parent = frame,
	})
	C.list("x", Theme.space.s, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = head
	C.badge(card.domain, 36).Parent = head
	C.text(card.name, "heading", { Size = UDim2.new(1, -48, 0, 0), TextColor3 = Theme.domainColor(card.domain) }).Parent = head
	C.text(card.description, "body", { LayoutOrder = 2 }).Parent = frame

	local live: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 3,
		Parent = frame,
	})
	Kit.dynamic(scope, { power, magic.known, magic.region }, function(s)
		local holder: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = live,
		})
		s:add(holder)
		C.list("y", Theme.space.s).Parent = holder
		local recipe = table.clone(card.recipe)
		local template = nil
		for _, t in magic:templatesFor(recipe.branch) do
			if t.property == recipe.property and t.verb == recipe.verb and t.form == recipe.form then
				template = t
				break
			end
		end
		local cap = if template then template.maxPower else recipe.power
		recipe.power = math.clamp(power:get(), 1, math.max(1, cap))

		local row: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
			Parent = holder,
		})
		C.list("x", Theme.space.xs, { Wraps = true, VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = row
		C.text("Power", "label", { Size = UDim2.fromOffset(60, 0), TextWrapped = false }).Parent = row
		for p = 1, cap do
			C.button(tostring(p), function()
				power:set(p)
			end, { kind = "ghost", selected = recipe.power == p }, { Size = UDim2.fromOffset(Theme.minTouch, Theme.minTouch), LayoutOrder = p }).Parent = row
		end

		local stats = magic:preview(recipe)
		local summary = if stats
			then string.format("≈ cost %s · range %s · cooldown %ss · backfire %d%%", fmt(stats.costBreakdown.reservoir), fmt(stats.range), fmt(stats.cooldown), math.floor(stats.backfireChance * 100 + 0.5))
			else "Not castable right now."
		C.text(summary, "caption", { LayoutOrder = 2 }).Parent = holder

		local buttons: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 3,
			Parent = holder,
		})
		C.list("x", Theme.space.s, { Wraps = true }).Parent = buttons
		C.button("Save to hotbar", function()
			save(recipe, nil, true)
		end, { kind = "primary", disabled = stats == nil, sound = "confirm" }, { Size = UDim2.fromOffset(180, Theme.minTouch) }).Parent = buttons
		C.button("Customize", function()
			interface:open("Composer", { recipe = recipe })
		end, { kind = "ghost" }, { Size = UDim2.fromOffset(140, Theme.minTouch) }).Parent = buttons
	end)
end

local function buildGuided(scope: Scope, body: Frame)
	local scroll = C.scroll({ Parent = body })
	C.list("y", Theme.space.m).Parent = scroll
	C.padding(Theme.space.xs).Parent = scroll
	statusLine(scope, scroll, 0)
	Kit.dynamic(scope, { magic.known }, function(s)
		local holder: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
			Parent = scroll,
		})
		s:add(holder)
		local compact = interface.layout:get() == "Compact"
		-- Cards vary in height, so a wrapping list (not a UIGridLayout with fixed cells) lays them out.
		C.list("x", Theme.space.m, { Wraps = true }).Parent = holder

		local cards, later = guidedCards()
		if #cards == 0 then
			C.text("Your magic is still settling. Give it a moment.", "body").Parent = holder
			return
		end
		for order, card in cards do
			local cell: Frame = Kit.create(nil, "Frame", {
				BackgroundTransparency = 1,
				Size = UDim2.fromOffset(if compact then 330 else 360, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = order,
				Parent = holder,
			})
			buildCard(s, cell, card, order)
		end
		if #later > 0 then
			C.text("Within reach later: " .. table.concat(later, "; "), "caption", { LayoutOrder = 999, Size = UDim2.fromScale(1, 0) }).Parent = holder
		end
	end)
end

-- ─── Screen ─────────────────────────────────────────────────────────────────

local function build(scope: Scope, container: Frame, args: any?)
	local compact = interface.layout:get() == "Compact"
	-- Any args (a recipe to edit, or {} from Start over) mean Full mode for this opening.
	if args and args ~= loadedArgs then
		loadedArgs = args
		modeOverride = "advanced"
		if args.recipe then
			load(args.recipe)
		end
		if args.key then
			local spell = magic:spell(args.key)
			spellName = if spell and spell.custom then spell.name else ""
		end
	elseif not args then
		loadedArgs = nil
		modeOverride = nil
	end
	local mode = modeOverride or magic.settings:get().composerMode or "simple"

	-- Mode toggle
	local top: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, Theme.minTouch),
		Parent = container,
	})
	C.list("x", Theme.space.s, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = top
	for index, entry in { { "simple", "Guided" }, { "advanced", "Full" } } do
		local id, label = entry[1], entry[2]
		C.button(label, function()
			modeOverride = nil
			task.spawn(magic.setSetting, magic, "composerMode", id)
		end, { kind = "ghost", selected = mode == id }, { Size = UDim2.fromOffset(110, Theme.minTouch), LayoutOrder = index }).Parent = top
	end
	if mode == "advanced" then
		C.button("Start over", function()
			draft:set(emptyDraft())
			step:set(1)
			spellName = ""
			status:set(nil)
			interface:open("Composer", {})
		end, { kind = "ghost" }, { Size = UDim2.fromOffset(130, Theme.minTouch), LayoutOrder = 3 }).Parent = top
	end

	local body: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(0, Theme.minTouch + Theme.space.s),
		Size = UDim2.new(1, 0, 1, -(Theme.minTouch + Theme.space.s)),
		Parent = container,
	})
	if mode == "advanced" then
		buildFull(scope, body, compact)
	else
		buildGuided(scope, body)
	end
end

function ComposerController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	interface:registerScreen({
		id = "Composer",
		title = "Spell Composer",
		order = 2,
		key = Enum.KeyCode.C,
		gamepadKey = Enum.KeyCode.ButtonX,
		build = build,
	})
end

return ComposerController
