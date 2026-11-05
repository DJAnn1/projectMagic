--!strict
--[[
	JournalController: the Journal screen (J) — docs/UI.md §4.7, docs/Quests.md §6.

	Tabs (each fetched from the server with RequestJournal(tab, page) when opened or changed):
		Quests    offers (Accept / Decline), active quests (Track / Abandon), crises nearby that
		          anyone can help with, and finished stories. Each quest shows its current stage
		          and every way through it you can see: the approach in words, each objective with
		          ✓ / ○ and its progress.
		Log       everything that happened to you, newest first, 20 per page
		Factions  every faction you know of (secret ones once revealed): rank in words, standing,
		          ideology; your infamy and bounties
	JournalChanged pushes become HUD toasts (MagicStateController "notify" events) and refresh the
	open tab. Accepting can also happen by talking to the quest giver ("About the trouble").
	Never colour alone: status is ✓ / ○ / ★ glyphs and words.
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

type Scope = Kit.Scope

local APPROACH: { [string]: string } = {
	talk = "Talk", force = "Force", magic = "Magic", stealth = "Stealth",
	creative = "Creative", wait = "Patience", trade = "Trade",
}
local KIND_GLYPH: { [string]: string } = {
	quest = "§", outcome = "★", reputation = "⚑", rumor = "…", crime = "!", faction = "⚑", discovery = "✦",
}

local JournalController = {
	name = "JournalController",
	dependencies = { "InterfaceController", "MagicStateController" },
}

local interface: any = nil
local magic: any = nil

local tab = Kit.value("quests")
local page = Kit.value(1)
local data = Kit.value(nil :: any)
local busy = false

local function refresh()
	if busy then
		return
	end
	busy = true
	task.spawn(function()
		local ok, result = Net.invoke("RequestJournal", tab:get(), page:get())
		busy = false
		if ok and typeof(result) == "table" and result.ok then
			data:set(result.data)
		end
	end)
end

local function act(questId: string, action: string)
	task.spawn(function()
		local ok, result = Net.invoke("QuestAction", questId, action)
		if ok and typeof(result) == "table" and not result.ok and result.reason == "too_many" then
			magic.events:Fire({ kind = "notify", text = "You're already carrying as many quests as you can." })
		end
		refresh()
	end)
end

-- ─── Pieces ─────────────────────────────────────────────────────────────────

local function column(parent: Instance, order: number?): Frame
	local f: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order or 0,
		Parent = parent,
	})
	C.list("y", Theme.space.xs).Parent = f
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
	C.list("x", Theme.space.s, { Wraps = true }).Parent = f
	return f
end

local function smallButton(parent: Instance, text: string, kind: string, onClick: () -> ())
	local b = C.button(text, onClick, { kind = kind, height = 36 }, { Size = UDim2.fromOffset(120, 36) })
	b.Parent = parent
end

local function questCard(parent: Instance, quest: any, section: string, order: number)
	local card = C.panel({
		BackgroundTransparency = Theme.glass,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	C.padding(Theme.space.m).Parent = card
	C.list("y", Theme.space.xs).Parent = card

	local title = quest.title .. (if quest.scope == "shared" then "  · anyone can help" else "")
	C.text(title, "label", { FontFace = Theme.font.bold, LayoutOrder = 1, Parent = card })
	C.text(quest.summary, "body", { TextColor3 = Theme.color.inkDim, LayoutOrder = 2, Parent = card })
	if section ~= "offers" then
		C.text("» " .. quest.stage, "body", { LayoutOrder = 3, Parent = card })
	end
	local meta = {}
	if quest.giver then
		table.insert(meta, "from " .. quest.giver)
	end
	if quest.hoursLeft then
		table.insert(meta, string.format("about %d hours left", math.floor(quest.hoursLeft)))
	end
	if quest.creative and quest.creative > 0 then
		table.insert(meta, "✦ solved creatively")
	end
	if quest.tracked then
		table.insert(meta, "◆ tracked")
	end
	if #meta > 0 then
		C.text(table.concat(meta, " · "), "caption", { TextColor3 = Theme.color.inkFaint, LayoutOrder = 4, Parent = card })
	end

	-- Ways through this stage.
	local ways = column(card, 5)
	for i, option in quest.options do
		local box = column(ways, i)
		C.text(string.format("%s  [%s]", option.label, APPROACH[option.approach] or option.approach), "label", { TextColor3 = Theme.color.accent, LayoutOrder = 0, Parent = box })
		for j, obj in option.objectives do
			local mark = if obj.done then "✓" else "○"
			local progress = if not obj.done and obj.required > 1 then string.format("  (%s / %s)", tostring(obj.progress), tostring(obj.required)) else ""
			C.text(string.format("   %s %s%s", mark, obj.text, progress), "caption", {
				TextColor3 = if obj.done then Theme.color.good else Theme.color.ink,
				LayoutOrder = j,
				Parent = box,
			})
		end
	end

	local buttons = row(card, 6)
	if section == "offers" then
		smallButton(buttons, "Accept", "primary", function()
			act(quest.id, "accept")
		end)
		smallButton(buttons, "Decline", "ghost", function()
			act(quest.id, "decline")
		end)
	elseif section == "active" then
		smallButton(buttons, if quest.tracked then "Tracked" else "Track", "secondary", function()
			act(quest.id, "track")
		end)
		if quest.type ~= "hunted" then
			smallButton(buttons, "Abandon", "ghost", function()
				act(quest.id, "abandon")
			end)
		end
	end
end

local function section(parent: Instance, title: string, order: number): Frame
	local box = column(parent, order)
	C.text(title, "label", { FontFace = Theme.font.title, LayoutOrder = 0, Parent = box })
	return box
end

-- ─── Tabs ───────────────────────────────────────────────────────────────────

local function buildQuests(parent: Instance, d: any)
	local any = false
	local function list(title: string, items: { any }?, kind: string, order: number)
		if items and #items > 0 then
			any = true
			local box = section(parent, title, order)
			for i, quest in items do
				questCard(box, quest, kind, i)
			end
		end
	end
	list("Asked of you", d.offers, "offers", 1)
	list("Under way", d.active, "active", 2)
	list("Trouble nearby", d.shared, "shared", 3)
	if d.finished and #d.finished > 0 then
		any = true
		local box = section(parent, "Finished", 4)
		for i, f in d.finished do
			C.text(string.format("%s %s — %s", if f.success then "★" else "·", f.title, f.text), "caption", {
				TextColor3 = if f.success then Theme.color.ink else Theme.color.inkDim,
				LayoutOrder = i,
				Parent = box,
			})
		end
	end
	if not any then
		C.text("Nothing yet. The world will come to you: talk to people, go where things are happening.", "body", { TextColor3 = Theme.color.inkDim, Parent = parent })
	end
end

local function buildLog(parent: Instance, d: any)
	for i, e in (d.entries or {}) :: { any } do
		local when = os.date("%d %b %H:%M", e.t)
		C.text(string.format("%s  %s  %s", KIND_GLYPH[e.kind] or "·", tostring(when), e.text), "caption", { LayoutOrder = i, Parent = parent })
	end
	local nav = row(parent, 1000)
	if (d.page or 1) > 1 then
		smallButton(nav, "Newer", "ghost", function()
			page:set(page:get() - 1)
			refresh()
		end)
	end
	if (d.page or 1) < (d.pages or 1) then
		smallButton(nav, "Older", "ghost", function()
			page:set(page:get() + 1)
			refresh()
		end)
	end
end

local function buildFactions(parent: Instance, d: any)
	C.text(string.format("Infamy: %d / 100", d.infamy or 0), "label", { LayoutOrder = 0, Parent = parent })
	for i, b in (d.bounties or {}) :: { any } do
		C.text(string.format("! Bounty in %s: %d (%s)", b.settlement, b.amount, b.reason), "caption", { TextColor3 = Theme.color.danger, LayoutOrder = i, Parent = parent })
	end
	for i, f in (d.factions or {}) :: { any } do
		local card = C.panel({ BackgroundTransparency = Theme.glass, Size = UDim2.fromScale(1, 0), AutomaticSize = Enum.AutomaticSize.Y, LayoutOrder = 100 + i, Parent = parent })
		C.padding(Theme.space.s).Parent = card
		C.list("y", 2).Parent = card
		C.text(string.format("%s%s — %s (%d)", f.name, if f.secret then " ◈" else "", f.rank, f.standing), "label", { LayoutOrder = 1, Parent = card })
		C.text(f.ideology, "caption", { TextColor3 = Theme.color.inkDim, LayoutOrder = 2, Parent = card })
	end
end

local function build(scope: Scope, container: Frame, _args: any?)
	refresh()
	local tabs = row(container, 0)
	tabs.Size = UDim2.new(1, 0, 0, 44)
	Kit.dynamic(scope, { tab }, function(s)
		local holder = row(tabs, 0)
		s:add(holder)
		for i, id in { "quests", "log", "factions" } do
			local label = ({ quests = "Quests", log = "Log", factions = "Factions" })[id]
			local b = C.button(label, function()
				if tab:get() ~= id then
					tab:set(id)
					page:set(1)
					data:set(nil)
					refresh()
				end
			end, { kind = "secondary", selected = tab:get() == id, height = 40 }, { Size = UDim2.fromOffset(130, 40), LayoutOrder = i })
			b.Parent = holder
		end
	end)

	local scroll = C.scroll({
		Position = UDim2.fromOffset(0, 52),
		Size = UDim2.new(1, 0, 1, -52),
		Parent = container,
	})
	Kit.dynamic(scope, { data, tab }, function(s)
		local body = column(scroll, 0)
		s:add(body)
		local d = data:get()
		if not d then
			C.text("Turning pages...", "body", { TextColor3 = Theme.color.inkDim, Parent = body })
			return
		end
		local t = tab:get()
		if t == "quests" then
			buildQuests(body, d)
		elseif t == "log" then
			buildLog(body, d)
		else
			buildFactions(body, d)
		end
	end)
end

function JournalController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	interface:registerScreen({
		id = "Journal",
		title = "Journal",
		order = 3,
		key = Enum.KeyCode.J,
		build = build,
	})
end

function JournalController.start(_self: any, _ctx: any)
	Net.listen("JournalChanged", function(entry)
		if typeof(entry) ~= "table" or typeof(entry.text) ~= "string" then
			return
		end
		magic.events:Fire({ kind = "notify", text = entry.text })
		if interface.openScreen:get() == "Journal" then
			refresh()
		end
	end)
end

return JournalController
