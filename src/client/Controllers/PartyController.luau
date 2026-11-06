--!strict
--[[
	PartyController: parties from the player's side (docs/Social.md §3).

		layer    your party's health and reservoir bars under the region panel, and invite cards. Bars
		         also say their numbers, so colour is never the only cue.
		screen   Party [P]: requests, your party (Lead / Remove / Leave), the people on this server
		         (Invite / Duel), and every emote as a button (the gamepad and touch way in).
		markers  a ◆ and a name over party members' heads, so you can find each other in a crowd.
		blocks   reads this client's Roblox block list and tells the server (SocialSafetyService).

	The people list only shows Roblox display names, which is what the Roblox player list already
	shows: no mastery, domains, health or location of anyone who isn't in your party.
]]

local Players = game:GetService("Players")
local StarterGui = game:GetService("StarterGui")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Controls = require(Shared.UI.Controls)
local DuelRules = require(Shared.Social.Data.DuelRules)
local Emotes = require(Shared.Social.Data.Emotes)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

local MARKER_RANGE = 300
local MARKER_EVERY = 1 -- seconds between checks that every party member has a marker
local BLOCK_RETRIES = 10 -- the block list isn't readable until Roblox's own scripts have loaded
local BLOCK_RETRY_SECONDS = 3

local PartyController = {
	name = "PartyController",
	dependencies = { "InterfaceController", "MagicStateController", "DuelController", "EmoteController" },
}

local interface: any = nil
local magic: any = nil
local duel: any = nil
local emotes: any = nil
local localPlayer = Players.LocalPlayer

type View = { id: string?, leader: number?, members: { any }, invites: { any } }

local state = Kit.value({ members = {}, invites = {} } :: View)
local vitals = Kit.value({} :: { [number]: any })
local peopleTick = Kit.value(0)

local REFUSALS: { [string]: string } = {
	GONE = "They've left.",
	SELF = "That's you.",
	NOT_ACCEPTING = "They aren't taking invites right now.",
	IN_PARTY = "They're already in a party. (If that's you: leave yours first.)",
	NOT_LEADER = "Only the party leader can do that.",
	FULL = "That party is full.",
	EXPIRED = "That invite has run out.",
	COOLDOWN = "They just said no. Give it a moment.",
	TOO_MANY_INVITES = "You have too many invites open.",
	ALREADY_INVITED = "You've already invited them.",
	NOT_IN_PARTY = "You aren't in a party.",
	NOT_MEMBER = "They aren't in your party.",
	OFF = "Parties are switched off right now.",
}

local function act(op: string, target: number?, success: string?)
	task.spawn(function()
		local ok, result = Net.invoke("PartyAction", op, target)
		if not ok or typeof(result) ~= "table" then
			magic.events:Fire({ kind = "notify", text = "That didn't work. Try again in a moment." })
		elseif not result.ok then
			magic.events:Fire({ kind = "notify", text = REFUSALS[result.reason or ""] or "That didn't work." })
		elseif success then
			magic.events:Fire({ kind = "notify", text = success })
		end
	end)
end

-- ─── Pieces ─────────────────────────────────────────────────────────────────

local function buttonRow(parent: Instance, order: number): Frame
	local row: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, Theme.minTouch),
		LayoutOrder = order,
		Parent = parent,
	})
	C.list("x", Theme.space.s, { VerticalAlignment = Enum.VerticalAlignment.Center }).Parent = row
	return row
end

local function smallButton(parent: Instance, label: string, kind: string, order: number, fn: () -> ())
	local button = C.button(label, fn, { kind = kind }, {
		Size = UDim2.fromOffset(0, Theme.minTouch),
		AutomaticSize = Enum.AutomaticSize.X,
		LayoutOrder = order,
	})
	C.padding(0, Theme.space.m).Parent = button
	button.Parent = parent
end

local function inviteCard(parent: Instance, invite: any, order: number)
	local card = C.panel({
		BackgroundTransparency = Theme.glass,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	C.padding(Theme.space.s).Parent = card
	C.list("y", Theme.space.xs).Parent = card
	C.text(string.format("%s invites you to their party", tostring(invite.name)), "label", { LayoutOrder = 1, Parent = card })
	local row = buttonRow(card, 2)
	smallButton(row, "Accept", "primary", 1, function()
		act("accept", invite.from)
	end)
	smallButton(row, "Decline", "ghost", 2, function()
		act("decline", invite.from)
	end)
end

-- One member's name, bars and numbers, kept live from `vitals`.
local function memberRow(scope: Kit.Scope, parent: Instance, member: any, leader: number?, order: number)
	local row: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	C.list("y", 2).Parent = row
	local crown = if member.u == leader then "★ " else ""
	C.text(crown .. tostring(member.name), "label", { LayoutOrder = 1, Parent = row })

	local function rowOf(): any
		return vitals:get()[member.u]
	end
	local health = Kit.computed(scope, { vitals }, function(): number
		local v = rowOf()
		return if v and v.m > 0 then v.h / v.m else 0
	end)
	local reservoir = Kit.computed(scope, { vitals }, function(): number
		local v = rowOf()
		return if v and v.rm > 0 then v.r / v.rm else 0
	end)
	local healthBar = C.bar(scope, health, Theme.color.danger, 8)
	healthBar.LayoutOrder = 2
	healthBar.Parent = row
	local reservoirBar = C.bar(scope, reservoir, Theme.color.good, 6)
	reservoirBar.LayoutOrder = 3
	reservoirBar.Parent = row

	local numbers = C.text("", "caption", { LayoutOrder = 4, Parent = row })
	local function refresh()
		local v = rowOf()
		if not v then
			numbers.Text = "…"
			return
		end
		local parts = { if v.h <= 0 then "Down" else string.format("Health %d/%d", v.h, v.m), string.format("Reservoir %d/%d", v.r, v.rm) }
		local root = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
		if member.u ~= localPlayer.UserId and root and root:IsA("BasePart") and v.x and v.z then
			table.insert(parts, string.format("%d studs", (Vector3.new(v.x, 0, v.z) - Vector3.new(root.Position.X, 0, root.Position.Z)).Magnitude // 1))
		end
		numbers.Text = table.concat(parts, " · ")
	end
	refresh()
	scope:add(vitals:observe(refresh))
end

-- ─── The HUD layer ──────────────────────────────────────────────────────────

local function buildLayer(scope: Kit.Scope, root: Frame)
	local compact = interface.layout:get() == "Compact"
	local holder: Frame = Kit.create(nil, "Frame", {
		Name = "PartyFrames",
		BackgroundTransparency = 1,
		-- Under the region panel. That panel's height changes a little; this clears its tallest.
		Position = UDim2.fromOffset(Theme.space.m, if compact then 84 else 128),
		Size = UDim2.fromOffset(if compact then 190 else 240, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = root,
	})
	C.list("y", Theme.space.s).Parent = holder

	Kit.dynamic(scope, { state }, function(s)
		local view = state:get()
		local inner: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = holder,
		})
		s:add(inner)
		C.list("y", Theme.space.s).Parent = inner
		for i, invite in view.invites do
			inviteCard(inner, invite, i)
		end
		if #view.members > 0 then
			local panel = C.panel({
				BackgroundTransparency = Theme.glass,
				Size = UDim2.fromScale(1, 0),
				AutomaticSize = Enum.AutomaticSize.Y,
				LayoutOrder = 100,
				Parent = inner,
			})
			C.padding(Theme.space.s).Parent = panel
			C.list("y", Theme.space.s).Parent = panel
			local order = 0
			for _, member in view.members do
				if member.u ~= localPlayer.UserId then
					order += 1
					memberRow(s, panel, member, view.leader, order)
				end
			end
		end
	end)
end

-- ─── The Party screen ───────────────────────────────────────────────────────

local function section(parent: Instance, title: string, order: number, note: string?): Frame
	local box = C.panel({
		BackgroundTransparency = Theme.glass,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = order,
		Parent = parent,
	})
	C.padding(Theme.space.m).Parent = box
	C.list("y", Theme.space.s).Parent = box
	C.text(title, "heading", { LayoutOrder = -2, Parent = box })
	if note then
		C.text(note, "caption", { LayoutOrder = -1, Parent = box })
	end
	return box
end

local function partySection(s: Kit.Scope, parent: Instance, view: View)
	if #view.members == 0 then
		section(parent, "Your party", 2, "You're on your own, and that's fine. Invite someone below to travel together: you can't hurt each other, you see each other's health and reservoir, you can help with each other's quests, and your magic can combine.")
		return
	end
	local box = section(parent, "Your party", 2, "You can't hurt each other. Each of you can advance the others' quests. Spells of the right kinds landing together become a combo.")
	local amLeader = view.leader == localPlayer.UserId
	for i, member in view.members do
		local card: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = i,
			Parent = box,
		})
		C.list("y", Theme.space.xs).Parent = card
		memberRow(s, card, member, view.leader, 1)
		if amLeader and member.u ~= localPlayer.UserId then
			local row = buttonRow(card, 2)
			smallButton(row, "Make leader", "ghost", 1, function()
				act("promote", member.u)
			end)
			smallButton(row, "Remove", "ghost", 2, function()
				act("kick", member.u)
			end)
		end
	end
	local row = buttonRow(box, 50)
	smallButton(row, "Leave party", "danger", 1, function()
		act("leave")
	end)
end

local function ruleSection(s: Kit.Scope, box: Instance)
	C.text("Duel rule", "label", { LayoutOrder = 1, Parent = box })
	Kit.dynamic(s, { duel.rule }, function(inner)
		local holder: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 2,
			Parent = box,
		})
		inner:add(holder)
		C.list("y", Theme.space.xs).Parent = holder
		local row = buttonRow(holder, 1)
		local current = duel.rule:get()
		for i, rule in DuelRules.ordered do
			local button = C.button(rule.name, function()
				duel.rule:set(rule.id)
			end, { kind = "ghost", selected = rule.id == current }, {
				Size = UDim2.fromOffset(0, Theme.minTouch),
				AutomaticSize = Enum.AutomaticSize.X,
				LayoutOrder = i,
			})
			C.padding(0, Theme.space.m).Parent = button
			button.Parent = row
		end
		C.text(DuelRules.rules[current].text, "caption", { LayoutOrder = 2, Parent = holder })
	end)
end

local function peopleSection(s: Kit.Scope, parent: Instance, view: View)
	local box = section(parent, "People here", 3)
	ruleSection(s, box)
	local mine: { [number]: boolean } = {}
	for _, member in view.members do
		mine[member.u] = true
	end
	local myRoot = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
	local list: { { player: Player, distance: number } } = {}
	for _, player in Players:GetPlayers() do
		if player ~= localPlayer then
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			local distance = if myRoot and myRoot:IsA("BasePart") and root and root:IsA("BasePart") then (myRoot.Position - root.Position).Magnitude else math.huge
			table.insert(list, { player = player, distance = distance })
		end
	end
	table.sort(list, function(a, b)
		if a.distance ~= b.distance then
			return a.distance < b.distance
		end
		return a.player.UserId < b.player.UserId
	end)
	if #list == 0 then
		C.text("Nobody else is on this server right now.", "caption", { LayoutOrder = 3, Parent = box })
	end
	for i, entry in list do
		local player = entry.player
		local row = buttonRow(box, 3 + i)
		C.text(string.format("%s (@%s)", player.DisplayName, player.Name), "body", {
			Size = UDim2.fromOffset(280, 0),
			LayoutOrder = 1,
			Parent = row,
		})
		if not mine[player.UserId] then
			smallButton(row, "Invite", "secondary", 2, function()
				act("invite", player.UserId, "Invite sent to " .. player.DisplayName .. ".")
			end)
		end
		smallButton(row, "Duel", "ghost", 3, function()
			duel:challenge(player.UserId)
		end)
	end
end

local function emoteSection(parent: Instance)
	local box = section(parent, "Emotes", 4, string.format("Hold %s for the wheel, or type a command in chat.", Controls.display("T")))
	local grid: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 1,
		Parent = box,
	})
	C.list("x", Theme.space.s, { Wraps = true }).Parent = grid
	for i, def in Emotes.list do
		smallButton(grid, string.format("%s  (/%s)", def.label, def.command), "ghost", i, function()
			emotes:request(def.id)
			interface:close()
		end)
	end
end

local function buildScreen(scope: Kit.Scope, container: Frame, _args: any?)
	local scroll = C.scroll({ Parent = container })
	Kit.dynamic(scope, { state, peopleTick }, function(s)
		local view = state:get()
		local body: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = scroll,
		})
		s:add(body)
		C.list("y", Theme.space.l).Parent = body
		C.padding(Theme.space.xs).Parent = body

		-- Requests first: this is also where you answer one with the mouse locked to the camera.
		local requests: Frame = Kit.create(nil, "Frame", {
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
			Parent = body,
		})
		C.list("y", Theme.space.s).Parent = requests
		for i, invite in view.invites do
			inviteCard(requests, invite, i)
		end
		duel:renderCard(s, requests, 50)

		partySection(s, body, view)
		peopleSection(s, body, view)
		emoteSection(body)
		section(body, "Who can reach you", 5, "Settings has Party invites, Duel challenges and Emotes from others. People you've blocked on Roblox can't invite or challenge you, and you won't see their emotes.")
	end)
end

-- ─── Markers over party members ─────────────────────────────────────────────

local markers: { [number]: BillboardGui } = {}

local function refreshMarkers()
	local view = state:get()
	local wanted: { [number]: any } = {}
	for _, member in view.members do
		if member.u ~= localPlayer.UserId then
			wanted[member.u] = member
		end
	end
	for userId, gui in markers do
		if not wanted[userId] or not gui.Parent then
			gui:Destroy()
			markers[userId] = nil
		end
	end
	for userId, member in wanted do
		local player = Players:GetPlayerByUserId(userId)
		local head = player and player.Character and player.Character:FindFirstChild("Head")
		local existing = markers[userId]
		if head and head:IsA("BasePart") and (not existing or existing.Parent ~= head) then
			if existing then
				existing:Destroy()
			end
			local gui = Instance.new("BillboardGui")
			gui.Name = "PartyMarker"
			gui.Size = UDim2.fromOffset(200, 24)
			gui.StudsOffset = Vector3.new(0, 3, 0)
			gui.MaxDistance = MARKER_RANGE
			gui.AlwaysOnTop = true
			local label = Instance.new("TextLabel")
			label.BackgroundTransparency = 1
			label.Size = UDim2.fromScale(1, 1)
			label.FontFace = Theme.font.bold
			label.TextSize = 16
			label.TextColor3 = Theme.color.good
			label.TextStrokeTransparency = 0.3
			label.Text = "◆ " .. tostring(member.name)
			label.Parent = gui
			gui.Parent = head
			markers[userId] = gui
		end
	end
end

-- ─── Block list ─────────────────────────────────────────────────────────────

local function reportBlocks(): boolean
	local ok, ids = pcall(function()
		return StarterGui:GetCore("GetBlockedUserIds")
	end)
	if ok and typeof(ids) == "table" then
		Net.send("ReportBlocks", ids)
		return true
	end
	return false
end

local function watchBlocks()
	for _ = 1, BLOCK_RETRIES do
		if reportBlocks() then
			break
		end
		task.wait(BLOCK_RETRY_SECONDS)
	end
	for _, name in { "PlayerBlockedEvent", "PlayerUnblockedEvent" } do
		local ok, event = pcall(function()
			return StarterGui:GetCore(name)
		end)
		if ok and typeof(event) == "Instance" and event:IsA("BindableEvent") then
			event.Event:Connect(reportBlocks)
		end
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function PartyController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	duel = ctx.get("DuelController")
	emotes = ctx.get("EmoteController")
	interface:registerLayer({ id = "Party", build = buildLayer })
	interface:registerScreen({
		id = "Party",
		title = "Party",
		order = 50,
		key = Controls.key("open_party", "keyboard"),
		build = buildScreen,
	})
end

function PartyController.start(_self: any, _ctx: any)
	Net.listen("PartyState", function(view: any)
		if typeof(view) == "table" then
			state:set({ id = view.id, leader = view.leader, members = view.members or {}, invites = view.invites or {} })
			refreshMarkers()
		end
	end)
	Net.listen("PartyVitals", function(rows: any)
		if typeof(rows) ~= "table" then
			return
		end
		local byUser: { [number]: any } = {}
		for _, row in rows do
			byUser[row.u] = row
		end
		vitals:set(byUser)
	end)
	local function people()
		peopleTick:set(peopleTick:get() + 1)
	end
	Players.PlayerAdded:Connect(people)
	Players.PlayerRemoving:Connect(people)
	task.spawn(watchBlocks)
	while true do
		task.wait(MARKER_EVERY)
		refreshMarkers()
	end
end

return PartyController
