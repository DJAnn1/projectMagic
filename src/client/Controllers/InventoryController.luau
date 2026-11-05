--!strict
--[[
	InventoryController: the Inventory screen (I / gamepad D-pad up) and the item quickbar
	(docs/Items.md §7). Data comes only from ItemStateController; every change is an intent the
	server checks (InventoryAction).

	SCREEN (Wide: three columns; Compact: one scrolling column)
		left    paper doll (15 slots), character summary (health, defense, magic, move speed),
		        focus status, carried weight vs capacity, "All stats" (the server's breakdown)
		middle  filter chips, search, Sort, coins and slots, the 4 quickslots, the grid
		        (items that don't match the filter or search are dimmed, not hidden, so slots
		        never jump around under a drag)
		right   the selected item: tooltip, comparison with what's worn, and actions
		        (Equip/Unequip, Use, Split, Move, Quick 1-4, Favourite, Lock, Drop)

	INPUT
		mouse     click selects; drag drops onto any cell (grid, equipment, quickslot); right-click
		          equips, unequips or uses; hovering shows a floating tooltip with comparison
		touch     tap selects; Move then tap the destination; the action buttons do the rest
		gamepad   cells are selectable (A selects); the action buttons do the rest
	QUICKBAR     4 slots: Z X V B on keyboard; on gamepad tap D-pad down to use the selected slot,
	             hold it to select the next; tap on touch. Keys come from Shared/UI/Controls.
	             Scrolls aim like spells (the crosshair or mouse). Gear in a quickslot toggles.

	Leaving the screen clears every NEW mark (one request, not one per hover).
]]

local GuiService = game:GetService("GuiService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Controls = require(Shared.UI.Controls)
local Controls = require(Shared.UI.Controls)
local ItemTypes = require(Shared.Items.ItemTypes)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local ItemRules = require(Shared.Items.Data.ItemRules)
local Repair = require(Shared.Items.Repair)
local StatDefs = require(Shared.Items.Data.StatDefs)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local ItemWidgets = require(UI.ItemWidgets)

type Scope = Kit.Scope
type ItemView = ItemTypes.ItemView

local CELL = 56
local DRAG_START = 6 -- pixels before a press becomes a drag
local LEFT_WIDTH = 270
local RIGHT_WIDTH = 330
local QUICK_KEYS = Controls.keys("quick_items", "keyboard") -- Z X V B (Shared/UI/Controls)
local QUICK_PAD = Controls.key("quick_items", "gamepad") -- D-pad down: tap uses, hold selects the next
local QUICK_HOLD = 0.35 -- seconds before a held D-pad down counts as "next item"

local InventoryController = {
	name = "InventoryController",
	dependencies = { "InterfaceController", "MagicStateController", "ItemStateController", "CastClient", "HousingController" },
}

local interface: any = nil
local magic: any = nil
local items: any = nil
local castClient: any = nil
local housing: any = nil

local selected = Kit.value(nil :: string?)
local moving = Kit.value(nil :: string?)
local filter = Kit.value("all")
local search = Kit.value("")
local showSheet = Kit.value(false)
local hovered = Kit.value(nil :: string?)
local dropArmed = Kit.value(nil :: string?)
local quickSelected = Kit.value(1)
local padPress = 0 -- bumps on every D-pad-down press and release (cancels a stale hold timer)
local padCycled = true -- true = the next release does nothing (it already cycled, or no press was seen)

local dragging: { ref: string, start: Vector2, ghost: ScreenGui? }? = nil

-- ─── Actions ────────────────────────────────────────────────────────────────

local function act(op: string, a: string?, b: string?, n: number?, aim: Vector3?)
	task.spawn(function()
		items:action(op, a, b, n, aim)
	end)
end

local function defOf(view: ItemView?): ItemTypes.ItemDef?
	return if view then ItemDatabase.get(view.rec.i) else nil
end

-- First empty grid slot in the current view (for Split).
local function firstEmpty(): string?
	local view = items.view:get()
	if not view then
		return nil
	end
	local used: { [string]: boolean } = {}
	for _, item in view.items do
		used[item.ref] = true
	end
	for n = 1, view.capacity do
		if not used["s" .. n] then
			return "s" .. n
		end
	end
	return nil
end

local function useRef(ref: string)
	local view = items:find(ref)
	local def = defOf(view)
	local aim: Vector3? = nil
	if def and def.use and def.use.needsAim then
		-- Aim from the world, not the menu: close the screen and use the crosshair / mouse.
		interface:close()
		task.wait()
		aim = castClient:aim()
	end
	act("use", ref, nil, nil, aim)
end

-- Right-click / double purpose: unequip worn items, equip gear, use consumables.
local function defaultAction(ref: string)
	local view = items:find(ref)
	local def = defOf(view)
	if not view or not def then
		return
	end
	if string.sub(ref, 1, 2) == "e:" then
		act("unequip", ref)
	elseif def.equip then
		act("equip", ref)
	elseif def.use then
		useRef(ref)
	end
end

local function useQuick(key: number)
	local view = items:quickRef(tostring(key))
	local def = defOf(view)
	if not view or not def then
		local id = items:quickItemId(tostring(key))
		local d = id and ItemDatabase.get(id)
		magic.events:Fire({ kind = "notify", text = if d then "You have no " .. d.name .. " left." else "Quickslot " .. ItemRules.quickKeys[key] .. " is empty." })
		return
	end
	local aim = if def.use and def.use.needsAim then castClient:aim() else nil
	act("use", "q" .. key, nil, nil, aim)
end

local function onCellActivated(ref: string)
	local source = moving:get()
	if source then
		moving:set(nil)
		if source ~= ref then
			local q = string.match(ref, "^q(%d)$")
			if q then
				act("quick", q, source)
			else
				act("move", source, ref)
			end
		end
		return
	end
	local q = string.match(ref, "^q(%d)$")
	if q then
		-- A quickslot: assign the selected item to it.
		local sel = selected:get()
		if sel and string.sub(sel, 1, 1) == "s" then
			act("quick", q, sel)
		end
		return
	end
	selected:set(if selected:get() == ref then nil else ref)
	dropArmed:set(nil)
end

-- ─── Drag and drop (mouse) ──────────────────────────────────────────────────

local function refUnder(position: Vector2): string?
	local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui") :: PlayerGui
	for _, object in playerGui:GetGuiObjectsAtPosition(position.X, position.Y) do
		local node: Instance? = object
		while node and node ~= playerGui do
			local ref = node:GetAttribute("ItemRef")
			if typeof(ref) == "string" then
				return ref
			end
			node = node.Parent
		end
	end
	return nil
end

local function endDrag(position: Vector2?)
	local d = dragging
	dragging = nil
	if not d then
		return
	end
	if d.ghost then
		d.ghost:Destroy()
		local target = if position then refUnder(position) else nil
		if target and target ~= d.ref then
			local q = string.match(target, "^q(%d)$")
			if q then
				act("quick", q, d.ref)
			else
				act("move", d.ref, target)
			end
		end
	end
end

local function hookCell(scope: Scope, cell: TextButton, ref: string)
	scope:add(cell.Activated:Connect(function()
		if not (dragging and dragging.ghost) then
			onCellActivated(ref)
		end
	end))
	scope:add(cell.InputBegan:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and string.sub(ref, 1, 1) ~= "q" and items:find(ref) then
			dragging = { ref = ref, start = Vector2.new(input.Position.X, input.Position.Y), ghost = nil }
		elseif input.UserInputType == Enum.UserInputType.MouseButton2 then
			local q = string.match(ref, "^q(%d)$")
			if q then
				act("quick", q, nil)
			else
				defaultAction(ref)
			end
		end
	end))
	scope:add(cell.MouseEnter:Connect(function()
		hovered:set(ref)
	end))
	scope:add(cell.MouseLeave:Connect(function()
		if hovered:get() == ref then
			hovered:set(nil)
		end
	end))
end

-- ─── Pieces ─────────────────────────────────────────────────────────────────

local function column(parent: Instance, order: number?, gap: number?): Frame
	local f: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order or 0,
		Parent = parent,
	})
	C.list("y", gap or Theme.space.xs).Parent = f
	return f
end

local function row(parent: Instance, order: number?): Frame
	local f: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order or 0,
		Parent = parent,
	})
	C.list("x", Theme.space.xs, { Wraps = true, VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = f
	return f
end

local function smallButton(parent: Instance, text: string, kind: string, order: number, onClick: () -> (), width: number?)
	local b = C.button(text, onClick, { kind = kind, height = 36 }, { Size = UDim2.fromOffset(width or 96, 36), LayoutOrder = order })
	b.Parent = parent
	return b
end

local function matches(view: ItemView): boolean
	local def = defOf(view)
	if not def then
		return filter:get() == "all"
	end
	local f = filter:get()
	if f ~= "all" then
		local cat = ItemRules.categories[def.category]
		if not cat or cat.filter ~= f then
			return false
		end
	end
	local text = string.lower(search:get())
	if text ~= "" then
		local name = string.lower(ItemInstance.displayName(view.rec))
		if not string.find(name, text, 1, true) and not string.find(string.lower(def.category), text, 1, true) then
			local tagged = false
			for _, tag in def.tags do
				tagged = tagged or string.find(tag, text, 1, true) ~= nil
			end
			if not tagged then
				return false
			end
		end
	end
	return true
end

local function pct(v: number?): string
	return string.format("%+d%%", math.floor((v or 0) * 100 + 0.5))
end

-- ─── Left column: paper doll and summary ────────────────────────────────────

local function buildEquipment(scope: Scope, parent: Instance)
	local holder = column(parent, 1, Theme.space.s)
	C.text("Equipment", "label", { FontFace = Theme.font.title, LayoutOrder = 0, Parent = holder })
	Kit.dynamic(scope, { items.view, selected, moving }, function(s)
		local grid: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
			Parent = holder,
		})
		s:add(grid)
		local layout = C.grid(CELL + 22, CELL + 16, Theme.space.xs)
		layout.FillDirectionMaxCells = 3
		layout.Parent = grid
		for _, slot in ItemRules.equipSlots do
			local ref = "e:" .. slot.id
			local box: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, LayoutOrder = slot.order, Parent = grid })
			local cell = ItemWidgets.cell(items:find(ref), CELL, { ref = ref, placeholder = slot.glyph, selected = selected:get() == ref or moving:get() == ref })
			cell.AnchorPoint = Vector2.new(0.5, 0)
			cell.Position = UDim2.fromScale(0.5, 0)
			cell.Parent = box
			hookCell(s, cell, ref)
			C.text(slot.name, "caption", {
				TextSize = 11,
				TextXAlignment = Enum.TextXAlignment.Center,
				TextColor3 = Theme.color.inkFaint,
				Position = UDim2.fromOffset(0, CELL + 1),
				Parent = box,
			})
		end
	end)
end

local function buildSummary(scope: Scope, parent: Instance)
	local holder = column(parent, 2)
	Kit.dynamic(scope, { items.view, magic.reservoir }, function(s)
		local view = items.view:get()
		if not view then
			return
		end
		local box = column(holder, 0, 2)
		s:add(box)
		local f = view.stats
		local reservoir = magic.reservoir:get()
		local lines = {
			string.format("Health %d   Defense %d", math.floor((f.health or 100) + 0.5), math.floor((f.defense or 0) + 0.5)),
			string.format("Reservoir %s   Regen %s", if reservoir then tostring(reservoir.max) else "?", pct(f.reservoirRegenPct)),
			string.format("Spell power %s   Cast speed %s", pct(f.spellPowerPct), pct(f.castSpeedPct)),
			string.format("Cost %s   Stability %s", pct(-(f.costReductionPct or 0)), pct(f.stabilityPct)),
			string.format("Move speed %s", pct(f.moveSpeedPct)),
		}
		for i, text in lines do
			C.text(text, "caption", { LayoutOrder = i, Parent = box })
		end
		local focusText = if view.focus == "major" then "✓ Holding a focus: no penalty for matching spells at power 6+"
			elseif view.focus == "minor" then "! Worn focus only: half the penalty at power 6+"
			else "! No focus: spells of power 6+ cost more and are less stable"
		C.text(focusText, "caption", { LayoutOrder = 10, TextColor3 = if view.focus == "major" then Theme.color.good else Theme.color.warn, Parent = box })
		local load = view.weight / math.max(1, view.carry)
		local loadRow
		for _, r in ItemRules.encumbrance do
			if r.id == view.load then
				loadRow = r
			end
		end
		C.text(string.format("Carrying %.1f / %.0f · %s", view.weight, view.carry, if loadRow then loadRow.name else view.load), "caption", {
			LayoutOrder = 11,
			TextColor3 = if view.load == "light" then Theme.color.inkDim else Theme.color.warn,
			Parent = box,
		})
		local bar = C.bar(nil, math.min(1, load), if load > 1 then Theme.color.danger elseif load > 0.75 then Theme.color.warn else Theme.color.good, 6)
		bar.LayoutOrder = 12
		bar.Parent = box
	end)
	smallButton(holder, "All stats", "ghost", 3, function()
		showSheet:set(not showSheet:get())
		items.sheetWanted = showSheet:get()
		if showSheet:get() then
			items:fetchSheet()
		end
	end, 120)
end

-- ─── Middle column: toolbar, quickslots, grid ───────────────────────────────

local function buildToolbar(scope: Scope, parent: Instance)
	local bar = row(parent, 1)
	Kit.dynamic(scope, { filter }, function(s)
		local chips = row(bar, 1)
		chips.Size = UDim2.fromOffset(0, 0)
		chips.AutomaticSize = Enum.AutomaticSize.XY
		s:add(chips)
		for i, f in ItemRules.filters do
			local b = C.button(f.name, function()
				filter:set(f.id)
			end, { kind = "ghost", selected = filter:get() == f.id, height = 32 }, { Size = UDim2.fromOffset(0, 32), AutomaticSize = Enum.AutomaticSize.X, LayoutOrder = i })
			C.padding(0, Theme.space.s).Parent = b
			b.Parent = chips
		end
	end)
	-- The search box lives outside any dynamic region so it keeps focus while results change.
	local box: TextBox = Kit.create(nil, "TextBox", {
		PlaceholderText = "Search",
		Text = search:get(),
		ClearTextOnFocus = false,
		BackgroundColor3 = Theme.color.bg,
		TextColor3 = Theme.color.ink,
		PlaceholderColor3 = Theme.color.inkFaint,
		FontFace = Theme.font.body,
		TextSize = Theme.text("body"),
		TextXAlignment = Enum.TextXAlignment.Left,
		Size = UDim2.fromOffset(150, 32),
		LayoutOrder = 2,
		Parent = bar,
	})
	C.corner(Theme.radius.s).Parent = box
	C.stroke().Parent = box
	C.padding(0, Theme.space.s).Parent = box
	scope:add(box:GetPropertyChangedSignal("Text"):Connect(function()
		search:set(box.Text)
	end))
	smallButton(bar, "Sort", "secondary", 3, function()
		act("sort")
	end, 70)
end

local function buildQuickRow(scope: Scope, parent: Instance)
	local holder = column(parent, 3, 2)
	C.text("Quickslots: drag an item here, or select it and tap a slot. Right-click clears.", "caption", { TextColor3 = Theme.color.inkFaint, LayoutOrder = 0, Parent = holder })
	Kit.dynamic(scope, { items.view, moving }, function(s)
		local r = row(holder, 1)
		s:add(r)
		for k = 1, ItemRules.inventory.quickSlots do
			local view, total = items:quickRef(tostring(k))
			local shown = view
			if not shown then
				local id = items:quickItemId(tostring(k))
				if id then
					shown = { ref = "q" .. k, rec = { i = id }, ok = true }
				end
			end
			local cell = ItemWidgets.cell(shown, 48, {
				ref = "q" .. k,
				hint = ItemRules.quickKeys[k],
				dim = view == nil and shown ~= nil,
				count = if (defOf(shown) and (defOf(shown) :: ItemTypes.ItemDef).stack > 1) then total else nil,
				placeholder = "+",
			})
			cell.LayoutOrder = k
			cell.Parent = r
			hookCell(s, cell, "q" .. k)
		end
	end)
end

local function buildGrid(scope: Scope, parent: Instance, height: UDim2?)
	local scroll = C.scroll({ LayoutOrder = 5, Size = height or UDim2.new(1, 0, 1, -170), Parent = parent })
	C.padding(2).Parent = scroll
	Kit.dynamic(scope, { items.view, filter, search, selected, moving }, function(s)
		local view = items.view:get()
		local holder: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = scroll,
		})
		s:add(holder)
		if not view then
			C.text("Unpacking...", "body", { TextColor3 = Theme.color.inkDim, Parent = holder })
			return
		end
		C.grid(CELL, CELL, Theme.space.xs).Parent = holder
		local byRef: { [string]: ItemView } = {}
		local highest = view.capacity
		for _, item in view.items do
			byRef[item.ref] = item
			local n = tonumber(string.match(item.ref, "^s(%d+)$"))
			if n then
				highest = math.max(highest, n)
			end
		end
		for n = 1, highest do
			local ref = "s" .. n
			local item = byRef[ref]
			local cell = ItemWidgets.cell(item, CELL, {
				ref = ref,
				selected = selected:get() == ref or moving:get() == ref,
				dim = item ~= nil and not matches(item),
			})
			cell.LayoutOrder = n
			if n > view.capacity then
				cell.BackgroundColor3 = Theme.color.bg -- overflow: move it out
			end
			cell.Parent = holder
			hookCell(s, cell, ref)
		end
	end)
end

-- ─── Right column: details, actions, stat sheet ─────────────────────────────

local function buildActions(parent: Instance, view: ItemView)
	local def = defOf(view)
	if not def then
		return
	end
	local ref = view.ref
	local worn = string.sub(ref, 1, 2) == "e:"
	local r = row(parent, 100)
	local o = 0
	local function next(): number
		o += 1
		return o
	end
	if worn then
		smallButton(r, "Unequip", "primary", next(), function()
			act("unequip", ref)
		end)
	elseif def.equip then
		smallButton(r, "Equip", "primary", next(), function()
			act("equip", ref)
		end)
	end
	if def.use and not worn then
		smallButton(r, if def.category == "book" then "Read" else "Use", "primary", next(), function()
			useRef(ref)
		end)
	end
	if not worn and def.data and def.data.furniture then
		-- Furniture goes into your house (HousingController's placement mode).
		local canPlace = housing:canPlace()
		local b = smallButton(r, "Place", if canPlace then "primary" else "ghost", next(), function()
			housing:startPlacement(ref)
		end)
		if not canPlace then
			b.Text = "Place (at home)"
			b.Size = UDim2.fromOffset(130, 36)
		end
	end
	if not worn and ItemInstance.count(view.rec) > 1 then
		smallButton(r, "Split", "secondary", next(), function()
			local target = firstEmpty()
			if target then
				act("move", ref, target, math.floor(ItemInstance.count(view.rec) / 2))
			else
				magic.events:Fire({ kind = "notify", text = items:reasonText("NO_ROOM") })
			end
		end, 70)
	end
	-- Earth magic mends worn metal, stone and glass (Shared/Items/Repair; the server re-checks).
	local earth = magic:branchView(ItemRules.mend.domainBranch)
	local metal = magic:branchView(ItemRules.mend.metallurgy)
	local mend = Repair.mendQuote(view.rec, Repair.mendTier(if earth then earth.tier else 0, if metal then metal.tier else 0))
	if mend then
		smallButton(r, string.format("✦ Mend (+%d, %d res.)", mend.points, math.ceil(mend.reservoir)), "secondary", next(), function()
			act("mend", ref)
		end, 170)
	end
	smallButton(r, if moving:get() == ref then "Cancel move" else "Move", "secondary", next(), function()
		moving:set(if moving:get() == ref then nil else ref)
	end)
	if not worn and (def.use or def.equip) then
		for k = 1, ItemRules.inventory.quickSlots do
			smallButton(r, "Q" .. ItemRules.quickKeys[k], "ghost", next(), function()
				act("quick", tostring(k), ref)
			end, 48)
		end
	end
	local fav = ItemInstance.hasFlag(view.rec, ItemInstance.FAVORITE)
	smallButton(r, if fav then "♥ Unfavourite" else "♥ Favourite", "ghost", next(), function()
		act("favorite", ref)
	end, 130)
	local locked = ItemInstance.hasFlag(view.rec, ItemInstance.LOCKED)
	smallButton(r, if locked then "Unlock" else "🔒 Lock", "ghost", next(), function()
		act("lock", ref)
	end)
	if not worn and not def.quest and not locked then
		local armed = dropArmed:get() == ref
		smallButton(r, if armed then "Destroy: sure?" else "Drop", "danger", next(), function()
			if dropArmed:get() == ref then
				dropArmed:set(nil)
				selected:set(nil)
				act("drop", ref)
			else
				dropArmed:set(ref)
			end
		end, 130)
	end
	if not worn and not def.quest and not locked then
		C.text("Dropped items are destroyed until world drops arrive.", "caption", { TextColor3 = Theme.color.inkFaint, LayoutOrder = 101, Parent = parent })
	end
end

local function buildSheet(parent: Instance)
	local sheet = items.sheet:get()
	if not sheet then
		C.text("Adding it all up...", "body", { TextColor3 = Theme.color.inkDim, Parent = parent })
		return
	end
	local o = 1
	local function add(text: string, color: Color3?, role: string?)
		C.text(text, role or "caption", { TextColor3 = color or Theme.color.ink, LayoutOrder = o, Parent = parent })
		o += 1
	end
	add("All stats", nil, "label")
	add("Order: base, profile, mastery, gear, sets, buffs (added up), then percentages, then load, then limits.", Theme.color.inkDim)
	for _, group in { "vitals", "magic", "movement", "combat" } do
		add(string.upper(string.sub(group, 1, 1)) .. string.sub(group, 2), Theme.color.accent, "label")
		for _, def in StatDefs.list do
			if def.group == group then
				local total = sheet.final[def.id]
				local contributions = {}
				for _, line in sheet.lines do
					if line.stat == def.id then
						table.insert(contributions, string.format("%s %s", line.label, StatDefs.format(def.id, line.value)))
					end
				end
				if total and (total ~= def.base or #contributions > 1) then
					add(string.format("%s %s%s", def.name, StatDefs.format(def.id, total), if def.wired then "  (once " .. def.wired .. " exist)" else ""))
					if #contributions > 0 then
						add("   " .. table.concat(contributions, " · "), Theme.color.inkDim)
					end
				end
			end
		end
	end
	local keys = {}
	for key in sheet.resist do
		table.insert(keys, key)
	end
	table.sort(keys)
	if #keys > 0 then
		add("Resistances (from items)", Theme.color.accent, "label")
		for _, key in keys do
			add(string.format("%+.0f%% vs %s", sheet.resist[key] * 100, ItemWidgets.resistName(key)))
		end
	end
	if sheet.buffs and #sheet.buffs > 0 then
		add("Active effects", Theme.color.accent, "label")
		local t = workspace:GetServerTimeNow()
		for _, buff in sheet.buffs do
			add(string.format("%s: %d s left", buff.name, math.max(0, math.floor(buff.expires - t))))
		end
	end
end

local function buildDetails(scope: Scope, parent: Instance)
	local scroll = C.scroll({ Parent = parent })
	C.padding(Theme.space.xs).Parent = scroll
	Kit.dynamic(scope, { items.view, items.sheet, selected, showSheet, dropArmed, moving }, function(s)
		local body = column(scroll, 0)
		s:add(body)
		if showSheet:get() then
			buildSheet(body)
			return
		end
		local ref = selected:get()
		local view = ref and items:find(ref)
		if not view then
			C.text(if interface.inputMode:get() == "Keyboard"
				then "Select an item to see it here. Drag to move or equip; right-click to use, equip or unequip."
				else "Tap an item to see it here, then use the buttons. Move, then tap where it should go.",
				"body", { TextColor3 = Theme.color.inkDim, Parent = body })
			return
		end
		if moving:get() then
			C.text("Moving: pick where it should go.", "label", { TextColor3 = Theme.color.accent, LayoutOrder = 0, Parent = body })
		end
		local card = C.panel({ Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = body })
		C.padding(Theme.space.s).Parent = card
		C.list("y", 2).Parent = card
		ItemWidgets.tooltip(card, view, ItemWidgets.compareTarget(view, function(r)
			return items:find(r)
		end))
		buildActions(body, view)
	end)
end

-- ─── Floating tooltip (mouse hover) ─────────────────────────────────────────

local function buildHoverTooltip(scope: Scope)
	local gui: ScreenGui = Kit.create(nil, "ScreenGui", {
		Name = "ItemTooltip",
		DisplayOrder = 30,
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		Parent = Players.LocalPlayer:WaitForChild("PlayerGui"),
	})
	scope:add(gui)
	local panel: Frame? = nil
	Kit.dynamic(scope, { hovered, items.view }, function(s)
		panel = nil
		local ref = hovered:get()
		local view = ref and (if string.sub(ref, 1, 1) == "q" then items:quickRef(string.sub(ref, 2)) else items:find(ref))
		if not view or interface.inputMode:get() ~= "Keyboard" then
			return
		end
		local p = C.panel({ Size = UDim2.fromOffset(300, 0), AutomaticSize = Enum.AutomaticSize.Y, BackgroundTransparency = Theme.glass, ZIndex = 10, Parent = gui })
		s:add(p)
		C.padding(Theme.space.s).Parent = p
		C.list("y", 2).Parent = p
		ItemWidgets.tooltip(p, view, ItemWidgets.compareTarget(view, function(r)
			return items:find(r)
		end))
		panel = p
	end)
	scope:add(RunService.RenderStepped:Connect(function()
		local p = panel
		if not p then
			return
		end
		if dragging and dragging.ghost then
			p.Visible = false
			return
		end
		p.Visible = true
		local mouse = UserInputService:GetMouseLocation()
		local viewport = workspace.CurrentCamera.ViewportSize
		local size = p.AbsoluteSize
		local x = if mouse.X + 20 + size.X > viewport.X then mouse.X - 20 - size.X else mouse.X + 20
		local y = math.clamp(mouse.Y + 12, 0, math.max(0, viewport.Y - size.Y))
		p.Position = UDim2.fromOffset(x, y)
	end))
end

-- ─── Screen ─────────────────────────────────────────────────────────────────

local function build(scope: Scope, container: Frame, _args: any?)
	local compact = interface.layout:get() == "Compact"
	moving:set(nil)
	dropArmed:set(nil)
	if items.sheetWanted then
		items:fetchSheet()
	end

	-- Mouse drag: a press on a filled cell becomes a drag once it moves DRAG_START pixels.
	scope:add(UserInputService.InputChanged:Connect(function(input)
		local d = dragging
		if not d or input.UserInputType ~= Enum.UserInputType.MouseMovement then
			return
		end
		local position = Vector2.new(input.Position.X, input.Position.Y)
		if not d.ghost and (position - d.start).Magnitude >= DRAG_START then
			local gui: ScreenGui = Kit.create(nil, "ScreenGui", { Name = "ItemDrag", DisplayOrder = 40, IgnoreGuiInset = true, ResetOnSpawn = false })
			local ghost = ItemWidgets.cell(items:find(d.ref), CELL, {})
			ghost.Active = false
			ghost.BackgroundTransparency = 0.3
			ghost.AnchorPoint = Vector2.new(0.5, 0.5)
			ghost.Parent = gui
			gui.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
			d.ghost = gui
		end
		if d.ghost then
			local mouse = UserInputService:GetMouseLocation()
			local ghost = d.ghost:FindFirstChildWhichIsA("GuiObject")
			if ghost then
				ghost.Position = UDim2.fromOffset(mouse.X, mouse.Y)
			end
		end
	end))
	scope:add(UserInputService.InputEnded:Connect(function(input)
		if input.UserInputType == Enum.UserInputType.MouseButton1 and dragging then
			endDrag(Vector2.new(input.Position.X, input.Position.Y))
		end
	end))
	scope:add(function()
		endDrag(nil)
		hovered:set(nil)
	end)
	buildHoverTooltip(scope)

	if compact then
		local scroll = C.scroll({ Parent = container })
		local body = column(scroll, 0, Theme.space.m)
		local top = column(body, 1, Theme.space.s)
		buildToolbar(scope, top)
		Kit.dynamic(scope, { items.view }, function(s)
			local view = items.view:get()
			if view then
				s:add(C.text(string.format("◈ %d coins · %d slots", view.currency, view.capacity), "caption", { LayoutOrder = 2, Parent = top }))
			end
		end)
		buildQuickRow(scope, top)
		local gridBox = column(body, 2)
		buildGrid(scope, gridBox, UDim2.new(1, 0, 0, CELL * 4 + Theme.space.xs * 4))
		local details: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 360), LayoutOrder = 3, Parent = body })
		buildDetails(scope, details)
		local left = column(body, 4, Theme.space.s)
		buildEquipment(scope, left)
		buildSummary(scope, left)
		return
	end

	local gap = Theme.space.l
	local left: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.new(0, LEFT_WIDTH, 1, 0), Parent = container })
	local leftScroll = C.scroll({ Parent = left })
	local leftBody = column(leftScroll, 0, Theme.space.m)
	buildEquipment(scope, leftBody)
	buildSummary(scope, leftBody)

	local middle: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Position = UDim2.fromOffset(LEFT_WIDTH + gap, 0),
		Size = UDim2.new(1, -(LEFT_WIDTH + RIGHT_WIDTH + gap * 2), 1, 0),
		Parent = container,
	})
	C.list("y", Theme.space.s).Parent = middle
	buildToolbar(scope, middle)
	Kit.dynamic(scope, { items.view }, function(s)
		local view = items.view:get()
		if view then
			local used = 0
			for _, item in view.items do
				if string.sub(item.ref, 1, 1) == "s" then
					used += 1
				end
			end
			s:add(C.text(string.format("◈ %d coins%s · %d / %d slots", view.currency, if view.rare > 0 then string.format(" · ✦ %d", view.rare) else "", used, view.capacity),
				"caption", { LayoutOrder = 2, Parent = middle }))
		end
	end)
	buildQuickRow(scope, middle)
	buildGrid(scope, middle)

	local right: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.fromScale(1, 0),
		Size = UDim2.new(0, RIGHT_WIDTH, 1, 0),
		Parent = container,
	})
	buildDetails(scope, right)
end

-- ─── Quickbar (HUD layer) ───────────────────────────────────────────────────

local function buildQuickbar(scope: Scope, root: Frame)
	local compact = interface.layout:get() == "Compact"
	local bar: Frame = Kit.create(nil, "Frame", {
		Name = "Quickbar",
		BackgroundTransparency = 1,
		AutomaticSize = Enum.AutomaticSize.XY,
		Size = UDim2.fromOffset(0, 0),
		AnchorPoint = if compact then Vector2.new(0, 0.5) else Vector2.new(1, 1),
		Position = if compact then UDim2.new(0, Theme.space.s, 0.45, 0) else UDim2.new(1, -Theme.space.m, 1, -Theme.space.m),
		Parent = root,
	})
	local function syncVisible()
		root.Visible = not (compact and interface.openScreen:get() ~= nil)
	end
	scope:add(interface.openScreen:observe(syncVisible))
	syncVisible()

	local cooldownLabels: { [number]: TextLabel } = {}
	Kit.dynamic(scope, { items.view, quickSelected, interface.inputMode }, function(s)
		table.clear(cooldownLabels)
		local holder: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, AutomaticSize = Enum.AutomaticSize.XY, Size = UDim2.fromOffset(0, 0), Parent = bar })
		s:add(holder)
		C.list(if compact then "y" else "x", Theme.space.xs).Parent = holder
		local gamepad = interface.inputMode:get() == "Gamepad"
		for k = 1, ItemRules.inventory.quickSlots do
			local view, total = items:quickRef(tostring(k))
			local shown = view
			if not shown then
				local id = items:quickItemId(tostring(k))
				if id then
					shown = { ref = "q" .. k, rec = { i = id }, ok = true }
				end
			end
			local size = if compact then Theme.minTouch + 4 else 50
			local cell = ItemWidgets.cell(shown, size, {
				ref = "q" .. k,
				hint = if interface.inputMode:get() == "Keyboard" then ItemRules.quickKeys[k] else "",
				dim = view == nil and shown ~= nil,
				count = if (defOf(shown) and (defOf(shown) :: ItemTypes.ItemDef).stack > 1) then total else nil,
				selected = gamepad and quickSelected:get() == k,
			})
			cell.LayoutOrder = k
			cell.BackgroundTransparency = 0.25
			cell.Parent = holder
			s:add(cell.Activated:Connect(function()
				useQuick(k)
			end))
			local cooldown: TextLabel = Kit.create(nil, "TextLabel", {
				BackgroundColor3 = Theme.color.backdrop,
				BackgroundTransparency = 0.45,
				Text = "",
				TextColor3 = Theme.color.ink,
				FontFace = Theme.font.mono,
				TextSize = 16,
				Size = UDim2.fromScale(1, 1),
				Visible = false,
				ZIndex = 5,
				Parent = cell,
			})
			C.corner(Theme.radius.s).Parent = cooldown
			cooldownLabels[k] = cooldown
		end
		if gamepad then
			local hint = C.keyHint("L1 / L2")
			if hint then
				hint.LayoutOrder = 99
				hint.Parent = holder
			end
		end
	end)

	-- Cooldown overlays, 10 times a second.
	local elapsed = 0
	scope:add(RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed < 0.1 then
			return
		end
		elapsed = 0
		local view = items.view:get()
		local t = workspace:GetServerTimeNow()
		for k, label in cooldownLabels do
			local item = items:quickRef(tostring(k))
			local def = defOf(item)
			local key = def and def.use and (def.use.group or def.id)
			local ready = key and view and view.cooldowns[key]
			local left = if ready then ready - t else 0
			label.Visible = left > 0
			label.Text = if left > 0 then tostring(math.ceil(left)) else ""
		end
	end))
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function InventoryController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	items = ctx.get("ItemStateController")
	castClient = ctx.get("CastClient")
	housing = ctx.get("HousingController")
	interface:registerScreen({
		id = "Inventory",
		title = "Inventory",
		order = 4,
		key = Controls.key("open_inventory", "keyboard"), -- Shared/UI/Controls
		gamepadKey = Controls.key("open_inventory", "gamepad"),
		build = build,
	})
	interface:registerLayer({ id = "Quickbar", build = buildQuickbar })
end

function InventoryController.start(_self: any, _ctx: any)
	-- Leaving the screen clears NEW marks once.
	local last: string? = nil
	interface.openScreen:observe(function(id)
		if last == "Inventory" and id ~= "Inventory" then
			local view = items.view:get()
			local anyNew = false
			for _, item in (view and view.items or {}) :: { ItemView } do
				anyNew = anyNew or ItemInstance.hasFlag(item.rec, ItemInstance.NEW)
			end
			if anyNew then
				act("seen")
			end
			selected:set(nil)
			showSheet:set(false)
			items.sheetWanted = false
		end
		last = id
	end)

	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or interface:isInputBlocked() then
			return
		end
		local k = table.find(QUICK_KEYS, input.KeyCode)
		if k then
			useQuick(k)
		elseif QUICK_PAD and input.KeyCode == QUICK_PAD then
			-- Gamepad. (It used to be L1 to cycle and L2 to use, which clashed with guard and
			-- "ready a spell": readying a spell also drank the selected potion.)
			padPress += 1
			local press = padPress
			padCycled = false
			task.delay(QUICK_HOLD, function()
				if press == padPress and UserInputService:IsGamepadButtonDown(input.UserInputType, QUICK_PAD) then
					padCycled = true
					quickSelected:set(quickSelected:get() % ItemRules.inventory.quickSlots + 1)
				end
			end)
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if QUICK_PAD and input.KeyCode == QUICK_PAD then
			padPress += 1 -- a release before QUICK_HOLD cancels the pending "next item"
			if not padCycled and not interface:isInputBlocked() then
				useQuick(quickSelected:get())
			end
			padCycled = true -- one release, one action
		end
	end)

	-- Gamepad: keep a cell selected when the screen opens.
	interface.openScreen:observe(function(id)
		if id == "Inventory" and interface.inputMode:get() == "Gamepad" then
			task.defer(function()
				pcall(function()
					local playerGui = Players.LocalPlayer:WaitForChild("PlayerGui")
					for _, d in playerGui:GetDescendants() do
						if d:IsA("GuiButton") and d:GetAttribute("ItemRef") == "s1" then
							GuiService.SelectedObject = d
							return
						end
					end
				end)
			end)
		end
	end)
end

return InventoryController
