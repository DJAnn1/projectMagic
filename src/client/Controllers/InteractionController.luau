--!strict
--[[
	InteractionController: the windows the world opens (docs/Buildings.md §6). ProximityPrompts
	are server-side; when one opens a container or a station the server pushes a view and this
	controller shows the matching screen. Both screens are `hidden` (no tab): they exist only
	while you're using the thing.

	CONTAINER   (ContainerView)  the container's grid on the left, your inventory on the right.
	            Click / tap / A on a container item takes it; on one of yours puts it in.
	            "Take all", coins. Shift-click takes or puts just one of a stack.
	            A banner says when taking counts as theft (someone else's property).
	            Closing the screen (or walking away: the server closes it) ends the session.
	CRAFTING    (StationView)    the station's recipes: output, every ingredient with what you
	            have (✓ / ✗ and n / needed; tag ingredients count any matching item), station tier
	            and mastery requirements in words; Craft ×1 / ×5. Above the recipes, a Repair card
	            lists your worn items this station mends (Shared/Items/Repair) with the price.

	Text rules: never colour alone (✓ ✗ ! glyphs and words).
]]

local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local ItemTypes = require(Shared.Items.ItemTypes)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local Recipes = require(Shared.Items.Data.Recipes)
local Repair = require(Shared.Items.Repair)
local Registry = require(Shared.Magic.Registry)
local MasteryTiers = require(Shared.Magic.Data.MasteryTiers)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local ItemWidgets = require(UI.ItemWidgets)

type Scope = Kit.Scope
type ItemView = ItemTypes.ItemView

local CELL = 52

local InteractionController = {
	name = "InteractionController",
	dependencies = { "InterfaceController", "MagicStateController", "ItemStateController" },
}

local interface: any = nil
local magic: any = nil
local items: any = nil

local containerView = Kit.value(nil :: any)
local stationView = Kit.value(nil :: any)
local hovered = Kit.value(nil :: ItemView?)
local busy = false

local function notifyFailure(result: any)
	if typeof(result) == "table" and not result.ok then
		magic.events:Fire({ kind = "notify", text = items:reasonText(result.reason) })
	end
end

local function containerAction(op: string, ref: string?, n: number?)
	local view = containerView:get()
	if not view or busy then
		return
	end
	busy = true
	task.spawn(function()
		local ok, result = Net.invoke("ContainerAction", op, view.id, ref, n)
		busy = false
		if ok then
			notifyFailure(result)
		end
	end)
end

local function oneOnly(): number?
	return if UserInputService:IsKeyDown(Enum.KeyCode.LeftShift) or UserInputService:IsKeyDown(Enum.KeyCode.RightShift) then 1 else nil
end

-- ─── Container screen ───────────────────────────────────────────────────────

local function gridOf(parent: Instance, order: number, height: UDim2): Frame
	local scroll = C.scroll({ Size = height, LayoutOrder = order, Parent = parent })
	C.padding(2).Parent = scroll
	local holder: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = scroll,
	})
	C.grid(CELL, CELL, Theme.space.xs).Parent = holder
	return holder
end

local function cellFor(s: Scope, parent: Instance, view: ItemView?, ref: string, order: number, onClick: (() -> ())?)
	local cell = ItemWidgets.cell(view, CELL, { ref = ref })
	cell.LayoutOrder = order
	cell.Parent = parent
	if onClick then
		s:add(cell.Activated:Connect(onClick))
	end
	s:add(cell.MouseEnter:Connect(function()
		hovered:set(view)
	end))
	s:add(cell.MouseLeave:Connect(function()
		if hovered:get() == view then
			hovered:set(nil)
		end
	end))
end

local function buildContainer(scope: Scope, container: Frame, _args: any?)
	local compact = interface.layout:get() == "Compact"
	local root: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 1), Parent = container })
	C.list("y", Theme.space.s).Parent = root

	Kit.dynamic(scope, { containerView }, function(s)
		local view = containerView:get()
		local header: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = root })
		s:add(header)
		C.list("y", 2).Parent = header
		if not view then
			C.text("Nothing open.", "body", { TextColor3 = Theme.color.inkDim, Parent = header })
			return
		end
		C.text(view.name, "label", { FontFace = Theme.font.title, LayoutOrder = 1, Parent = header })
		if view.theft then
			C.text(string.format("! This belongs to %s. Taking anything you didn't put here is theft.", view.owner or "someone else"), "caption", {
				TextColor3 = Theme.color.warn, LayoutOrder = 2, Parent = header,
			})
		elseif view.owner then
			C.text("Owner: " .. view.owner, "caption", { TextColor3 = Theme.color.inkDim, LayoutOrder = 2, Parent = header })
		end
		C.text("Click to move a stack across; Shift-click moves just one.", "caption", { TextColor3 = Theme.color.inkFaint, LayoutOrder = 3, Parent = header })
	end)

	local columns: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 1, -110),
		LayoutOrder = 2,
		Parent = root,
	})
	C.list(if compact then "y" else "x", Theme.space.l).Parent = columns
	local columnSize = if compact then UDim2.new(1, 0, 0.5, -Theme.space.l) else UDim2.new(0.5, -Theme.space.l / 2, 1, 0)

	-- The container.
	local left: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = columnSize, LayoutOrder = 1, Parent = columns })
	C.list("y", Theme.space.xs).Parent = left
	Kit.dynamic(scope, { containerView }, function(s)
		local view = containerView:get()
		if not view then
			return
		end
		local bar: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 1, Parent = left })
		s:add(bar)
		C.list("x", Theme.space.s, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = bar
		local takeAll = C.button("Take all", function()
			containerAction("takeall")
		end, { kind = "primary", height = 36, disabled = #view.items == 0 }, { Size = UDim2.fromOffset(110, 36), LayoutOrder = 1 })
		takeAll.Parent = bar
		if view.coins > 0 then
			local coins = C.button(string.format("◈ Take %d coins", view.coins), function()
				containerAction("coins")
			end, { kind = "secondary", height = 36 }, { Size = UDim2.fromOffset(150, 36), LayoutOrder = 2 })
			coins.Parent = bar
		end
		local grid = gridOf(left, 2, UDim2.new(1, 0, 1, -44))
		s:add(grid.Parent)
		local byRef: { [string]: ItemView } = {}
		for _, item in view.items do
			byRef[item.ref] = item
		end
		for n = 1, view.capacity do
			local ref = "s" .. n
			local item = byRef[ref]
			cellFor(s, grid, item, "c" .. ref, n, if item then function()
				containerAction("take", ref, oneOnly())
			end else nil)
		end
	end)

	-- Your inventory.
	local right: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = columnSize, LayoutOrder = 2, Parent = columns })
	C.list("y", Theme.space.xs).Parent = right
	C.text("Your bags", "label", { LayoutOrder = 1, Size = UDim2.new(1, 0, 0, 36), Parent = right })
	Kit.dynamic(scope, { items.view }, function(s)
		local inv = items.view:get()
		if not inv then
			return
		end
		local grid = gridOf(right, 2, UDim2.new(1, 0, 1, -44))
		s:add(grid.Parent)
		local byRef: { [string]: ItemView } = {}
		for _, item in inv.items do
			byRef[item.ref] = item
		end
		for n = 1, inv.capacity do
			local ref = "s" .. n
			local item = byRef[ref]
			cellFor(s, grid, item, "p" .. ref, n, if item then function()
				containerAction("put", ref, oneOnly())
			end else nil)
		end
	end)

	-- What the mouse is over.
	Kit.dynamic(scope, { hovered }, function(s)
		local view = hovered:get()
		if not view or interface.inputMode:get() ~= "Keyboard" then
			return
		end
		local panel = C.panel({ Size = UDim2.new(1, 0, 0, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 3, Parent = root })
		s:add(panel)
		C.padding(Theme.space.s).Parent = panel
		C.list("y", 2).Parent = panel
		ItemWidgets.tooltip(panel, view, nil)
	end)
end

-- ─── Crafting screen ────────────────────────────────────────────────────────

local function tierName(index: number): string
	local def = MasteryTiers.tiers[index + 1]
	return if def then def.name else "tier " .. index
end

-- How many of an ingredient you carry (grid only, like the server).
local function have(inv: any, input: Recipes.Ingredient): number
	local total = 0
	for _, item in (inv and inv.items or {}) :: { ItemView } do
		if string.sub(item.ref, 1, 1) == "s" then
			local def = ItemDatabase.get(item.rec.i)
			if def and ((input.item and def.id == input.item) or (input.tag and table.find(def.tags, input.tag))) then
				total += ItemInstance.count(item.rec)
			end
		end
	end
	return total
end

local function ingredientName(input: Recipes.Ingredient): string
	if input.item then
		local def = ItemDatabase.get(input.item)
		return if def then def.name else input.item
	end
	return "any " .. (string.gsub(input.tag :: string, "_", " "))
end

local function craft(stationId: string, recipeId: string, count: number)
	if busy then
		return
	end
	busy = true
	task.spawn(function()
		local ok, result = Net.invoke("CraftAction", stationId, recipeId, count)
		busy = false
		if ok then
			notifyFailure(result)
		end
	end)
end

local function repair(stationId: string, ref: string)
	if busy then
		return
	end
	busy = true
	task.spawn(function()
		local ok, result = Net.invoke("RepairAction", stationId, ref)
		busy = false
		if ok then
			notifyFailure(result)
			if typeof(result) == "table" and result.ok then
				magic.events:Fire({ kind = "notify", text = string.format("Repaired %d item(s) for %d coins.", result.repaired or 0, result.coins or 0) })
			end
		end
	end)
end

-- The Repair card: worn things this station can mend (Shared/Items/Repair), each with its price.
local function buildRepairs(_s: Scope, body: Frame, station: any, inv: any)
	local rows: { { view: ItemView, quote: Repair.Quote } } = {}
	local totalCoins = 0
	for _, view in (inv and inv.items or {}) :: { ItemView } do
		local quote = Repair.quote(view.rec)
		if quote and quote.station == station.station then
			table.insert(rows, { view = view, quote = quote })
			totalCoins += quote.coins
		end
	end
	if #rows == 0 then
		return
	end
	local card = C.panel({ Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = body })
	C.padding(Theme.space.s).Parent = card
	C.list("y", 2).Parent = card
	C.text("⚒ Repair", "label", { LayoutOrder = 0, Parent = card })
	local coins = if inv then inv.currency else 0
	for i, row in rows do
		local quote = row.quote
		local line: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = i, Parent = card })
		C.list("x", Theme.space.s, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = line
		local material = if quote.material then { tag = quote.material, n = quote.materialCount } :: any else nil
		local hasMaterial = material == nil or have(inv, material) >= quote.materialCount
		local affordable = coins >= quote.coins and hasMaterial
		local cost = string.format("%s %d coins%s", if coins >= quote.coins then "✓" else "✗", quote.coins,
			if material then string.format(", %s %d %s", if hasMaterial then "✓" else "✗", quote.materialCount, ingredientName(material)) else "")
		local max = ItemInstance.maxDurability(row.view.rec) or 0
		C.text(string.format("%s (%d / %d) · %s", ItemInstance.displayName(row.view.rec), max - quote.points, max, cost), "caption", {
			Size = UDim2.new(1, -110, 0, 0), TextColor3 = if affordable then Theme.color.ink else Theme.color.inkDim, LayoutOrder = 1, Parent = line,
		})
		local ref = row.view.ref
		local button = C.button("Repair", function()
			repair(station.id, ref)
		end, { kind = "secondary", height = 30, disabled = not affordable }, { Size = UDim2.fromOffset(96, 30), LayoutOrder = 2 })
		button.Parent = line
	end
	if #rows > 1 then
		local all = C.button(string.format("Repair all (%d coins)", totalCoins), function()
			repair(station.id, "all")
		end, { kind = "primary", height = 32, disabled = coins < totalCoins }, { Size = UDim2.fromOffset(200, 32), LayoutOrder = #rows + 1 })
		all.Parent = card
	end
end

local function buildCrafting(scope: Scope, container: Frame, _args: any?)
	local scroll = C.scroll({ Parent = container })
	Kit.dynamic(scope, { stationView, items.view }, function(s)
		local station = stationView:get()
		local inv = items.view:get()
		local body: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, Parent = scroll })
		s:add(body)
		C.list("y", Theme.space.m).Parent = body
		if not station then
			C.text("Use a crafting station to work here.", "body", { TextColor3 = Theme.color.inkDim, Parent = body })
			return
		end
		C.text(string.format("%s%s", station.name, if station.tier >= 2 then " · master (tier 2)" else ""), "label", { FontFace = Theme.font.title, LayoutOrder = 0, Parent = body })
		buildRepairs(s, body, station, inv)
		local order = 1
		for _, recipe in Recipes.list do
			if recipe.station ~= station.station then
				continue
			end
			order += 1
			local card = C.panel({ Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = order, Parent = body })
			C.padding(Theme.space.s).Parent = card
			C.list("y", 2).Parent = card
			local outDef = ItemDatabase.get(recipe.output.item)
			local row: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 1, Parent = card })
			C.list("x", Theme.space.s, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = row
			local preview = ItemWidgets.cell({ ref = "craft", rec = { i = recipe.output.item, n = if recipe.output.n > 1 then recipe.output.n else nil, u = "preview" }, ok = true }, 44, {})
			preview.LayoutOrder = 1
			preview.Parent = row
			s:add(preview.MouseEnter:Connect(function()
				hovered:set({ ref = "craft", rec = { i = recipe.output.item, u = "preview" }, ok = true })
			end))
			C.text(string.format("%s → %s%s", recipe.name, if outDef then outDef.name else recipe.output.item, if recipe.output.n > 1 then " ×" .. recipe.output.n else ""), "label", {
				Size = UDim2.new(1, -60, 0, 0), LayoutOrder = 2, Parent = row,
			})

			local ready = true
			for i, input in recipe.inputs do
				local n = have(inv, input)
				local met = n >= input.n
				ready = ready and met
				C.text(string.format("%s %d / %d %s", if met then "✓" else "✗", math.min(n, 999), input.n, ingredientName(input)), "caption", {
					TextColor3 = if met then Theme.color.good else Theme.color.inkDim, LayoutOrder = 10 + i, Parent = card,
				})
			end
			if recipe.tier > station.tier then
				ready = false
				C.text("✗ Needs a master forge (tier " .. recipe.tier .. ")", "caption", { TextColor3 = Theme.color.danger, LayoutOrder = 30, Parent = card })
			end
			for branch, tier in (recipe.requires and recipe.requires.tier or {}) :: { [string]: number } do
				local b = Registry.branches[branch]
				C.text(string.format("! Needs %s in %s", tierName(tier), if b then b.name else branch), "caption", { TextColor3 = Theme.color.warn, LayoutOrder = 31, Parent = card })
			end
			if recipe.quality then
				C.text("Quality depends on your Metallurgy and the forge; it will carry your name.", "caption", { TextColor3 = Theme.color.inkFaint, LayoutOrder = 32, Parent = card })
			end
			local buttons: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, 36), LayoutOrder = 40, Parent = card })
			C.list("x", Theme.space.s).Parent = buttons
			local one = C.button("Craft", function()
				craft(station.id, recipe.id, 1)
			end, { kind = "primary", height = 34, disabled = not ready }, { Size = UDim2.fromOffset(100, 34), LayoutOrder = 1 })
			one.Parent = buttons
			local five = C.button("×5", function()
				craft(station.id, recipe.id, 5)
			end, { kind = "secondary", height = 34, disabled = not ready }, { Size = UDim2.fromOffset(60, 34), LayoutOrder = 2 })
			five.Parent = buttons
		end
	end)
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function InteractionController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	items = ctx.get("ItemStateController")
	interface:registerScreen({ id = "Container", title = "Container", order = 90, hidden = true, build = buildContainer })
	interface:registerScreen({ id = "Crafting", title = "Crafting", order = 91, hidden = true, build = buildCrafting })
end

function InteractionController.start(_self: any, _ctx: any)
	Net.listen("ContainerView", function(view)
		if typeof(view) ~= "table" or typeof(view.id) ~= "string" then
			return
		end
		if view.closed then
			local current = containerView:get()
			if current and current.id == view.id then
				containerView:set(nil)
				if interface.openScreen:get() == "Container" then
					interface:close()
				end
			end
			return
		end
		containerView:set(view, true)
		if interface.openScreen:get() ~= "Container" then
			interface:open("Container")
		end
	end)
	-- The world can ask for a screen (a notice board opens the Journal). Only known, safe screens.
	local openable: { [string]: boolean } = { Journal = true }
	Net.listen("OpenScreen", function(request)
		if typeof(request) == "table" and openable[request.id] then
			interface:open(request.id)
		end
	end)
	Net.listen("StationView", function(view)
		if typeof(view) ~= "table" or typeof(view.id) ~= "string" then
			return
		end
		stationView:set(view, true)
		interface:open("Crafting")
	end)
	-- Closing the window ends the container session on the server.
	interface.openScreen:observe(function(id)
		hovered:set(nil)
		if id ~= "Container" then
			local view = containerView:get()
			if view then
				containerView:set(nil)
				task.spawn(Net.invoke, "ContainerAction", "close", view.id)
			end
		end
	end)
end

return InteractionController
