--!strict
--[[
	GrimoireController: the living book of everything you know about magic.

	Wide:     [ domains ribbon ] [ branch tree ] [ page: details of the selection ]
	Compact:  one column at a time (domains -> tree -> page) with a back button.

	What the book shows grows with you. Every node has one of these states:
		known     unlocked: name, tier, progress, what you can shape there, your spells, techniques
		ready     a candidate whose requirements are all met: the Unlock button is live
		hint      a candidate: its name and the requirements, ✓ met / ✗ unmet
		rumor     a locked branch beyond a candidate: "???" and a whisper naming the parent
		hidden    anything deeper: not drawn at all, so the tree never becomes a wall of ???

	Domains: awakened (yours), stirring (you sense it: the visible profile lists it but it hasn't
	awakened), sealed (an ordinary domain others use), and one "Torn pages" entry that stands for
	every unawakened mythic domain without naming any or saying how many there are.

	Everything is derived from data the server already sends (progression view, visible profile,
	spellbook) plus the shared Registry. Unlocks and breakthroughs are requests; the server decides.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Controls = require(Shared.UI.Controls)
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local MasteryTiers = require(Shared.Magic.Data.MasteryTiers)
local Types = require(Shared.Magic.Types)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local KnownCaster = require(UI.KnownCaster)

type Scope = Kit.Scope
type BranchDef = Types.BranchDef

local TORN = "__torn" -- the single entry standing for all unawakened mythic domains
local DOMAIN_COLUMN = 230
local TREE_SHARE = 0.4 -- of the width left after the domain column

local GrimoireController = {
	name = "GrimoireController",
	dependencies = { "InterfaceController", "MagicStateController" },
}

local interface: any = nil
local magic: any = nil

-- Survives rebuilds and closing the book.
local selectedDomain = Kit.value(nil :: string?)
local selectedBranch = Kit.value(nil :: string?)
local compactPage = Kit.value("domains") -- "domains" | "tree" | "page"
local message = Kit.value(nil :: string?) -- result of the last unlock / breakthrough request

-- ─── Knowledge model ────────────────────────────────────────────────────────

type Book = {
	progression: KnownCaster.ProgressionView,
	known: { [string]: KnownCaster.BranchView },
	candidates: { [string]: KnownCaster.CandidateView },
	awakened: { [string]: boolean },
	stirring: { [string]: string }, -- domainId -> band (or "" when the band is unknown)
}

local function readBook(): Book?
	local progression = magic.progression:get()
	if not progression then
		return nil
	end
	local book: Book = { progression = progression, known = {}, candidates = {}, awakened = {}, stirring = {} }
	for _, view in progression.branches do
		book.known[view.id] = view
		local def = Registry.branches[view.id]
		if def and def.isRoot then
			book.awakened[def.domains[1]] = true
		end
	end
	for _, candidate in progression.candidates do
		book.candidates[candidate.id] = candidate
	end
	local profile = magic.profile:get()
	if profile then
		for _, visible in profile.domains do
			if not book.awakened[visible.domain] then
				book.stirring[visible.domain] = visible.band or ""
			end
		end
	end
	return book
end

local function nodeState(book: Book, branchId: string): string
	if book.known[branchId] then
		return "known"
	end
	local candidate = book.candidates[branchId]
	if candidate then
		return if candidate.ready then "ready" else "hint"
	end
	local branch = Registry.branches[branchId]
	if branch and branch.parent and book.candidates[branch.parent] then
		return "rumor"
	end
	return "hidden"
end

local function domainState(book: Book, domainId: string): string
	if book.awakened[domainId] then
		return "awakened"
	elseif book.stirring[domainId] then
		return "stirring"
	elseif Registry.domains[domainId].rarity == "Mythic" then
		return "torn"
	end
	return "sealed"
end

-- Verbs, forms and modifiers usable in a branch at a tier (the same gates as MagicCore).
local function shapesAt(branch: BranchDef, tier: number, mastery: number): ({ string }, { string }, { string })
	local verbs, forms, mods = {}, {}, {}
	for _, verbId in Registry.verbIds do
		local verb = Registry.verbs[verbId]
		if verb.minTier <= branch.tier and Registry.verbMasteryTier[verbId] <= tier then
			for _, propertyId in branch.properties do
				if Registry.verbPropertyEff[verbId][propertyId] > 0 then
					table.insert(verbs, verb.name)
					break
				end
			end
		end
	end
	for _, formId in Registry.formIds do
		local form = Registry.forms[formId]
		if form.minTier <= branch.tier and Registry.formMasteryTier[formId] <= tier and form.minMastery <= mastery then
			table.insert(forms, form.name)
		end
	end
	for _, modId in Registry.modifierIds do
		if Registry.modifiers[modId].minTier <= branch.tier then
			table.insert(mods, Registry.modifiers[modId].name)
		end
	end
	return verbs, forms, mods
end

-- What the NEXT tier adds, filtered by this branch's depth gates.
local function nextTierShapes(branch: BranchDef, tier: number): (Types.MasteryTierDef?, { string })
	local nextDef = Registry.masteryTiers.tiers[tier + 2]
	if not nextDef then
		return nil, {}
	end
	local names: { string } = {}
	for _, verbId in nextDef.verbs do
		if Registry.verbs[verbId].minTier <= branch.tier then
			table.insert(names, Registry.verbs[verbId].name)
		end
	end
	for _, formId in nextDef.forms do
		if Registry.forms[formId].minTier <= branch.tier then
			table.insert(names, Registry.forms[formId].name)
		end
	end
	return nextDef, names
end

-- ─── Small builders ─────────────────────────────────────────────────────────

local function column(parent: Instance, props: { [string]: any }?): ScrollingFrame
	local scroll = C.scroll(props)
	C.list("y", Theme.space.s).Parent = scroll
	C.padding(Theme.space.xs).Parent = scroll
	scroll.Parent = parent
	return scroll
end

local function section(parent: Instance, order: number, title: string): Frame
	local frame: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	C.list("y", Theme.space.xs).Parent = frame
	C.text(title, "heading", { LayoutOrder = 0, TextColor3 = Theme.color.accent }).Parent = frame
	return frame
end

local function row(parent: Instance, order: number): Frame
	local frame: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	C.list("x", Theme.space.s, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = frame
	return frame
end

local function joined(list: { string }): string
	return if #list > 0 then table.concat(list, ", ") else "nothing yet"
end

-- A list entry: badge on the left, title + subtitle on the right. Returns the button.
local function entry(parent: Instance, order: number, badgeDomain: string?, dim: boolean, title: string, subtitle: string, selected: boolean, indent: number, onActivate: () -> ()): TextButton
	local button = C.button("", onActivate, { kind = "ghost", selected = selected, height = 52 }, {
		LayoutOrder = order,
		Size = UDim2.new(1, -indent, 0, 52),
		Parent = parent,
	})
	-- Indentation via a wrapper keeps the list layout simple.
	if indent > 0 then
		local wrapper: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.new(1, 0, 0, 52),
			LayoutOrder = order,
			Parent = parent,
		})
		button.Position = UDim2.fromOffset(indent, 0)
		button.Parent = wrapper
	end
	local inner: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 1),
		Parent = button,
	})
	C.padding(Theme.space.xs, Theme.space.s).Parent = inner
	C.list("x", Theme.space.s, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = inner
	if badgeDomain then
		local badge = C.badge(badgeDomain, 32, dim)
		badge.LayoutOrder = 1
		badge.Parent = inner
	end
	local texts: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, -44, 1, 0),
		LayoutOrder = 2,
		Parent = inner,
	})
	C.list("y", 0, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = texts
	C.text(title, "label", { TextColor3 = if dim then Theme.color.inkFaint else Theme.color.ink, TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd }).Parent = texts
	C.text(subtitle, "caption", { TextWrapped = false, TextTruncate = Enum.TextTruncate.AtEnd }).Parent = texts
	return button
end

-- ─── Columns ────────────────────────────────────────────────────────────────

local function buildDomains(book: Book, parent: Instance, compact: boolean)
	local list = column(parent, {
		Size = if compact then UDim2.fromScale(1, 1) else UDim2.new(0, DOMAIN_COLUMN, 1, 0),
	})
	local ordered = table.clone(Registry.domainIds)
	local rank: { [string]: number } = { awakened = 1, stirring = 2, sealed = 3, torn = 4 }
	table.sort(ordered, function(a, b)
		local ra, rb = rank[domainState(book, a)], rank[domainState(book, b)]
		if ra ~= rb then
			return ra < rb
		end
		return a < b
	end)

	local tornShown = false
	for index, domainId in ordered do
		local state = domainState(book, domainId)
		local def = Registry.domains[domainId]
		local function choose(id: string)
			selectedDomain:set(id)
			selectedBranch:set(nil)
			message:set(nil)
			compactPage:set(if id == TORN then "page" else "tree")
		end
		if state == "torn" then
			if not tornShown then
				tornShown = true
				entry(list, index, nil, true, "Torn pages", "They will not stay written", selectedDomain:get() == TORN, 0, function()
					choose(TORN)
				end)
			end
		else
			local subtitle = if state == "awakened"
				then (book.known[domainId] and book.known[domainId].tierName or "Awakened")
				elseif state == "stirring" then "A faint stirring"
				else "Not awakened in you"
			entry(list, index, domainId, state ~= "awakened", def.name, subtitle, selectedDomain:get() == domainId, 0, function()
				choose(domainId)
			end)
		end
	end
end

local function buildTree(book: Book, domainId: string, parent: Instance, compact: boolean)
	local list = column(parent, {
		Size = if compact then UDim2.fromScale(1, 1) else UDim2.new(TREE_SHARE, -DOMAIN_COLUMN * TREE_SHARE, 1, 0),
	})
	local order = 0
	local function nextOrder(): number
		order += 1
		return order
	end

	if compact then
		C.button("‹ Domains", function()
			compactPage:set("domains")
		end, { kind = "ghost" }, { LayoutOrder = nextOrder(), Parent = list })
	end

	local def = Registry.domains[domainId]
	entry(list, nextOrder(), domainId, not book.awakened[domainId], def.name, "Overview", selectedBranch:get() == nil, 0, function()
		selectedBranch:set(nil)
		compactPage:set("page")
	end)

	if not book.awakened[domainId] then
		return
	end

	local function visit(branchId: string, depth: number)
		local state = nodeState(book, branchId)
		if state == "hidden" then
			return
		end
		local branch = Registry.branches[branchId]
		local view = book.known[branchId]
		local title = if state == "rumor" then "???" else branch.name
		local subtitle = if state == "known" and view then (if view.held then view.tierName .. "  ! held" else view.tierName)
			elseif state == "ready" then "✓ Ready to learn"
			elseif state == "hint" then "Not yet within reach"
			else "A whisper"
		local button = entry(list, nextOrder(), branch.domains[1], state ~= "known" and state ~= "ready", title, subtitle, selectedBranch:get() == branchId, math.min(depth, 4) * 16, function()
			selectedBranch:set(branchId)
			message:set(nil)
			compactPage:set("page")
		end)
		if state == "ready" then
			local stroke = button:FindFirstChildOfClass("UIStroke")
			if stroke then
				stroke.Color = Theme.color.good
			end
		end
		if state == "rumor" then
			return -- nothing beneath a rumor is drawn
		end
		for _, childId in branch.children do
			visit(childId, depth + 1)
		end
	end

	-- The root is the domain itself (shown as Overview); start with its children.
	for _, childId in Registry.branches[domainId].children do
		visit(childId, 0)
	end

	-- Confluences (hybrids): only where you could ever reach them.
	local hybrids = (Registry.hybridsByDomain[domainId] or {}) :: { string }
	local headerShown = false
	for _, hybridId in hybrids do
		local state = nodeState(book, hybridId)
		if state ~= "hidden" then
			if not headerShown then
				headerShown = true
				C.text("Confluences", "heading", { LayoutOrder = nextOrder(), TextColor3 = Theme.color.accent }).Parent = list
			end
			visit(hybridId, 0)
		end
	end
	if not headerShown and #hybrids > 0 then
		C.text("Confluences", "heading", { LayoutOrder = nextOrder(), TextColor3 = Theme.color.accent }).Parent = list
		C.text("This art meets others somewhere. Wake another domain to find where.", "caption", { LayoutOrder = nextOrder() }).Parent = list
	end
end

-- ─── Pages ──────────────────────────────────────────────────────────────────

local function backButton(page: Instance, compact: boolean)
	if compact then
		C.button("‹ Back", function()
			compactPage:set(if selectedDomain:get() == TORN then "domains" else "tree")
		end, { kind = "ghost" }, { LayoutOrder = -1, Parent = page })
	end
end

local function messageLine(scope: Scope, page: Instance)
	local label = C.text("", "body", { LayoutOrder = 100, TextColor3 = Theme.color.warn, Parent = page })
	local function update()
		local text = message:get()
		label.Visible = text ~= nil
		label.Text = text or ""
	end
	scope:add(message:observe(update))
	update()
end

local function domainPage(book: Book, domainId: string, page: Instance)
	if domainId == TORN then
		C.text("Torn pages", "title", { LayoutOrder = 2 }).Parent = page
		C.text("A few pages refuse to hold ink. Scholars argue about what was written there, and the few who claim to know are not believed.", "body", { LayoutOrder = 3 }).Parent = page
		C.text("Rumours gather in strange places. Listen for them.", "caption", { LayoutOrder = 4 }).Parent = page
		return
	end
	local def = Registry.domains[domainId]
	local state = domainState(book, domainId)
	local head = row(page, 2)
	C.badge(domainId, 56, state ~= "awakened").Parent = head
	C.text(def.name, "title", { Size = UDim2.new(1, -72, 0, 0), TextColor3 = Theme.domainColor(domainId) }).Parent = head
	C.text(string.format("%s domain", def.rarity), "caption", { LayoutOrder = 3 }).Parent = page
	C.text(def.concept, "body", { LayoutOrder = 4 }).Parent = page

	if state == "awakened" then
		local profile = magic.profile:get()
		local band: string? = nil
		if profile then
			for _, visible in profile.domains do
				if visible.domain == domainId then
					band = if visible.value then string.format("%s (%.2f)", visible.band or "", visible.value) else visible.band
				end
			end
		end
		local yours = section(page, 5, "In you")
		C.text(if band then "Your affinity feels " .. band .. "." else "You can't yet tell how strong it runs in you.", "body", { LayoutOrder = 1 }).Parent = yours
		local risk = section(page, 6, "If you overdraw: " .. def.risk.name)
		C.text(def.risk.description, "body", { LayoutOrder = 1 }).Parent = risk
		local names = function(ids: { string }): string
			local out = {}
			for _, id in ids do
				table.insert(out, Registry.domains[id].name)
			end
			return joined(out)
		end
		local relations = section(page, 7, "Kinship")
		C.text("Flows with: " .. names(def.synergies), "body", { LayoutOrder = 1 }).Parent = relations
		C.text("Resists: " .. names(def.oppositions), "body", { LayoutOrder = 2 }).Parent = relations
	elseif state == "stirring" then
		local band = book.stirring[domainId]
		C.text(if band ~= "" then string.format("You feel a %s stirring of it. Something may yet wake it.", string.lower(band)) else "You feel a faint stirring of it. Something may yet wake it.", "body", { LayoutOrder = 5, TextColor3 = Theme.color.good }).Parent = page
	else
		C.text("Not awakened in you. Others carry it; you may learn from watching them.", "body", { LayoutOrder = 5, TextColor3 = Theme.color.inkDim }).Parent = page
	end
end

local function knownPage(scope: Scope, book: Book, branch: BranchDef, view: KnownCaster.BranchView, page: Instance)
	local head = row(page, 2)
	for _, d in branch.domains do
		C.badge(d, 40).Parent = head
	end
	C.text(branch.name, "title", { Size = UDim2.new(1, -56 * #branch.domains, 0, 0), TextColor3 = Theme.branchColor(branch.id) }).Parent = head
	C.text(branch.description, "body", { LayoutOrder = 3 }).Parent = page

	-- Mastery
	local mastery = section(page, 4, string.format("%s  ·  tier %d of 8", view.tierName, view.tier))
	local nextDef = Registry.masteryTiers.tiers[view.tier + 2]
	if view.xpForNext and nextDef then
		local start = MasteryTiers.xpScale * MagicCore.tierDef(view.tier).minMastery ^ MasteryTiers.xpExponent
		local bar = C.bar(nil, (view.xp - start) / math.max(1, view.xpForNext - start), Theme.branchColor(branch.id), 10)
		bar.LayoutOrder = 1
		bar.Parent = mastery
		C.text(string.format("%d / %d toward %s", view.xp, view.xpForNext, nextDef.name), "caption", { LayoutOrder = 2 }).Parent = mastery
	end
	C.text(MagicCore.tierDef(view.tier).unlocks, "caption", { LayoutOrder = 3 }).Parent = mastery

	-- Breakthrough
	local breakthrough = view.breakthrough
	if breakthrough then
		local target = MagicCore.tierDef(breakthrough.tier)
		local block = section(page, 5, "Breakthrough to " .. target.name)
		if view.held then
			C.text("! Your growth is held at the threshold until this is done.", "body", { LayoutOrder = 1, TextColor3 = Theme.color.warn }).Parent = block
		end
		local allMet = true
		for index, requirement in breakthrough.requirements do
			allMet = allMet and requirement.met
			local check = C.check(requirement.met, requirement.text)
			check.LayoutOrder = 1 + index
			check.Parent = block
		end
		C.button("Attempt breakthrough", function()
			task.spawn(function()
				local ok, reason = magic:attemptBreakthrough(branch.id)
				message:set(if ok then nil elseif reason == "NOT_ENOUGH_XP" then "You need more experience first." elseif reason == "REQUIREMENTS_UNMET" then "Not every requirement is met yet." else "Nothing happens.")
			end)
		end, { kind = "primary", disabled = not (allMet and view.held), sound = "confirm" }, { LayoutOrder = 99, Parent = block })
	end

	-- What you can shape here
	local verbs, forms, mods = shapesAt(branch, view.tier, view.mastery)
	local shapes = section(page, 6, "What you can shape")
	local properties: { string } = {}
	for _, id in branch.properties do
		table.insert(properties, Registry.properties[id].name)
	end
	C.text("Properties: " .. joined(properties), "body", { LayoutOrder = 1 }).Parent = shapes
	C.text("Verbs: " .. joined(verbs), "body", { LayoutOrder = 2 }).Parent = shapes
	C.text("Forms: " .. joined(forms), "body", { LayoutOrder = 3 }).Parent = shapes
	C.text("Modifiers: " .. joined(mods), "body", { LayoutOrder = 4 }).Parent = shapes
	local upcoming, upcomingNames = nextTierShapes(branch, view.tier)
	if upcoming and #upcomingNames > 0 then
		C.text(string.format("At %s: %s", upcoming.name, joined(upcomingNames)), "caption", { LayoutOrder = 5 }).Parent = shapes
	end

	-- Your spells from this branch
	local spells = section(page, 7, "Your spells")
	local count = 0
	for _, spell in magic.spellbook:get() do
		if spell.recipe.branch == branch.id then
			count += 1
			local line = row(spells, count)
			C.text(spell.name, "body", { Size = UDim2.new(1, -150, 0, 0) }).Parent = line
			C.button("Edit", function()
				interface:open("Composer", { recipe = spell.recipe, key = spell.key })
			end, { kind = "ghost" }, { Size = UDim2.fromOffset(120, Theme.minTouch) }).Parent = line
		end
	end
	if count == 0 then
		C.text("None yet. Compose one.", "caption", { LayoutOrder = 1 }).Parent = spells
	end

	-- Techniques: the ones within reach, then one veiled goal.
	local techniques: { Types.TechniqueDef } = {}
	for _, technique in Registry.techniques do
		if technique.recipe.branch == branch.id then
			table.insert(techniques, technique)
		end
	end
	table.sort(techniques, function(a, b)
		if a.tier ~= b.tier then
			return a.tier < b.tier
		end
		return a.name < b.name
	end)
	if #techniques > 0 then
		local block = section(page, 8, "Techniques")
		local veiled = false
		for index, technique in techniques do
			if technique.tier <= view.tier then
				local line = row(block, index)
				C.text(string.format("%s: %s", technique.name, technique.description), "body", { Size = UDim2.new(1, -150, 0, 0) }).Parent = line
				C.button("Try", function()
					interface:open("Composer", { recipe = table.clone(technique.recipe) })
				end, { kind = "ghost" }, { Size = UDim2.fromOffset(120, Theme.minTouch) }).Parent = line
			elseif not veiled then
				veiled = true
				C.text(string.format("???  (within reach at %s)", MagicCore.tierDef(technique.tier).name), "caption", { LayoutOrder = index }).Parent = block
			end
		end
	end

	-- Deeper branches
	if #branch.children > 0 then
		local block = section(page, 9, "Deeper paths")
		for index, childId in branch.children do
			local state = nodeState(book, childId)
			if state ~= "hidden" then
				local child = Registry.branches[childId]
				C.text(string.format("%s  ·  %s", if state == "rumor" then "???" else child.name, if state == "known" then "learned" elseif state == "ready" then "✓ ready" else "not yet"), "body", { LayoutOrder = index }).Parent = block
			end
		end
	end
	messageLine(scope, page)
end

local function lockedPage(scope: Scope, book: Book, branch: BranchDef, state: string, page: Instance)
	if state == "rumor" then
		local parentName = if branch.parent then Registry.branches[branch.parent].name else "this art"
		C.text("???", "title", { LayoutOrder = 2 }).Parent = page
		C.text(string.format("Whispers speak of something beyond %s. Learn %s first, and the page may fill in.", parentName, parentName), "body", { LayoutOrder = 3 }).Parent = page
		return
	end
	local candidate = book.candidates[branch.id]
	local head = row(page, 2)
	for _, d in branch.domains do
		C.badge(d, 40, state ~= "ready").Parent = head
	end
	C.text(branch.name, "title", { Size = UDim2.new(1, -56 * #branch.domains, 0, 0) }).Parent = head
	C.text(branch.description, "body", { LayoutOrder = 3 }).Parent = page
	local block = section(page, 4, "To learn it")
	for index, check in (if candidate then candidate.checks else {}) :: { { kind: string, met: boolean, text: string } } do
		local line = C.check(check.met, check.text)
		line.LayoutOrder = index
		line.Parent = block
	end
	C.button(if state == "ready" then "Learn this branch" else "Not yet", function()
		task.spawn(function()
			local ok = magic:unlockBranch(branch.id)
			message:set(if ok then nil else "Not yet. Something is still missing.")
		end)
	end, { kind = "primary", disabled = state ~= "ready", sound = "confirm" }, { LayoutOrder = 99, Parent = block })
	messageLine(scope, page)
end

local function buildPage(scope: Scope, book: Book, parent: Instance, compact: boolean)
	local page = column(parent, {
		Size = if compact then UDim2.fromScale(1, 1) else UDim2.new(1 - TREE_SHARE, -DOMAIN_COLUMN * (1 - TREE_SHARE) - Theme.space.l, 1, 0),
	})
	local layout = page:FindFirstChildOfClass("UIListLayout") :: UIListLayout
	layout.Padding = UDim.new(0, Theme.space.m)
	backButton(page, compact)

	local domainId = selectedDomain:get()
	local branchId = selectedBranch:get()
	if not domainId then
		C.text("Choose a domain.", "body", { LayoutOrder = 2 }).Parent = page
		return
	end
	local branch = branchId and Registry.branches[branchId]
	if not branch then
		domainPage(book, domainId, page)
		return
	end
	local state = nodeState(book, branch.id)
	local view = book.known[branch.id]
	if state == "known" and view then
		knownPage(scope, book, branch, view, page)
	else
		lockedPage(scope, book, branch, state, page)
	end
end

-- ─── Screen ─────────────────────────────────────────────────────────────────

local function build(scope: Scope, container: Frame, _args: any?)
	local compact = interface.layout:get() == "Compact"
	Kit.dynamic(scope, { magic.progression, magic.profile, magic.spellbook, selectedDomain, selectedBranch, compactPage }, function(s)
		local book = readBook()
		local body: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 1),
			Parent = container,
		})
		s:add(body)
		if not book then
			C.text("The pages are still settling...", "body", { Parent = body })
			return
		end
		-- Default selection: your strongest awakened domain.
		if not selectedDomain:get() then
			local first = book.progression.branches[1]
			for _, view in book.progression.branches do
				local def = Registry.branches[view.id]
				if def and def.isRoot then
					first = view
					break
				end
			end
			if first then
				selectedDomain:set(Registry.branches[first.id].domains[1])
				return -- the set() re-renders
			end
		end

		if compact then
			local pageId = compactPage:get()
			if pageId == "domains" then
				buildDomains(book, body, true)
			elseif pageId == "tree" and selectedDomain:get() and selectedDomain:get() ~= TORN then
				buildTree(book, selectedDomain:get() :: string, body, true)
			else
				buildPage(s, book, body, true)
			end
			return
		end

		C.list("x", Theme.space.l).Parent = body
		buildDomains(book, body, false)
		local domainId = selectedDomain:get()
		if domainId and domainId ~= TORN then
			buildTree(book, domainId, body, false)
		end
		buildPage(s, book, body, false)
	end)
end

function GrimoireController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	interface:registerScreen({
		id = "Grimoire",
		title = "Grimoire",
		order = 1,
		key = Controls.key("open_grimoire", "keyboard"), -- Shared/UI/Controls
		gamepadKey = Controls.key("open_grimoire", "gamepad"),
		build = build,
	})
end

return GrimoireController
