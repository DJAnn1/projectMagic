--!strict
--[[
	RiftController: a Rift from the player's side (docs/Rifts.md). The server decides everything
	(Services/RiftService); `view` is the last state it sent.

		panel    Top right, while you're inside or for the recap: the twist, the clock, the room you're in,
		         a nudge, and how far along it is. The boss replaces the room at the end.
		marker   ✦ over the portal with the distance, while it's open and you're outside.
		warnings Fx/EventFx draws the telegraphs the server cues.

	Setting: World event alerts. Off hides the marker and the news, not the panel inside a Rift.
	There are no intents to send: entering and leaving are server-side prompts.
	Colour is never the only cue: tiers and results are words, and the marker is a glyph.
	Budget: one 5 Hz loop.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local R = require(Shared.Rifts.Data.RiftData)
local ItemDatabase = require(Shared.Items.ItemDatabase)

local Client = script.Parent.Parent
local UI = Client:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local EventFx = require(Client:WaitForChild("Fx"):WaitForChild("EventFx"))

local UPDATE_SECONDS = 0.2
local MARKER_HEIGHT = 34
local POCKET_MARGIN = 12

local RiftController = {
	name = "RiftController",
	dependencies = { "InterfaceController", "MagicStateController" },
}

local magic: any = nil
local localPlayer = Players.LocalPlayer

RiftController.view = Kit.value({ phase = "none" } :: { [string]: any })
RiftController.score = Kit.value({ points = 0, inside = false } :: { [string]: any })

local inside = Kit.value(false)
local dismissedRecap: string? = nil
local dismissTick = Kit.value(0)

local markerHolder: Attachment? = nil
local markerGui: BillboardGui? = nil
local markerLabel: TextLabel? = nil

local RESULTS: { [string]: string } = {
	won = "✓ The Rift is closed",
	failed = "✗ Out of time",
	faded = "It faded with nobody inside",
	cancelled = "Called off",
}

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function alertsOn(): boolean
	return magic.settings:get().eventAlerts ~= false
end

local function rootPosition(): Vector3?
	local root = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

local function title(word: string?): string
	local text = tostring(word)
	return string.upper(string.sub(text, 1, 1)) .. string.sub(text, 2)
end

-- ─── The panel ──────────────────────────────────────────────────────────────

local function clockText(view: { [string]: any }): string
	return string.format("%s left · Rooms cleared %d of %d", clock((view.endsAt or 0) - serverNow()), math.min((view.roomIndex or 1) - 1, view.roomCount or 0), view.roomCount or 0)
end

local function scoreText(): string
	local score = RiftController.score:get()
	local tier = if score.tier then R.tierNames[score.tier] else "No reward yet"
	return string.format("Your part: %d points · %s", score.points or 0, tier)
end

local function renderRun(s: Kit.Scope, card: Instance, view: { [string]: any })
	C.text(string.format("✦ %s Rift", tostring(view.twistName)), "heading", { LayoutOrder = 1, Parent = card })
	C.text(tostring(view.twistText), "caption", { LayoutOrder = 2, Parent = card })
	local status = C.text(clockText(view), "label", { LayoutOrder = 3, Parent = card })
	if view.roomName then
		C.text(tostring(view.roomName), "label", { LayoutOrder = 4, Parent = card })
		C.text(tostring(view.roomText), "body", { LayoutOrder = 5, Parent = card })
		C.text(tostring(view.roomHint), "caption", { LayoutOrder = 6, Parent = card })
		local bar = C.bar(nil, math.clamp((view.progress or 0) / 100, 0, 1), Theme.color.accent, 8)
		bar.LayoutOrder = 7
		bar.Parent = card
	elseif view.bossHealth then
		C.text(tostring(view.bossName) .. (if view.bossShield then " · shielded" else ""), "label", { LayoutOrder = 4, Parent = card })
		C.text(tostring(view.bossText), "body", { LayoutOrder = 5, Parent = card })
		local bar = C.bar(nil, math.clamp((view.bossHealth or 0) / 100, 0, 1), Theme.color.warn, 8)
		bar.LayoutOrder = 7
		bar.Parent = card
	end
	if (view.cleverRooms or 0) > 0 then
		C.text(string.format("Solved cleverly: %d", view.cleverRooms), "caption", { LayoutOrder = 8, Parent = card })
	end
	local score = C.text(scoreText(), "body", { LayoutOrder = 9, Parent = card })
	s:add(RiftController.score:observe(function()
		score.Text = scoreText()
	end))
	local elapsed = 0
	s:add(RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= UPDATE_SECONDS then
			elapsed = 0
			status.Text = clockText(view)
		end
	end))
end

local function rewardLine(mine: { [string]: any }): string
	local parts = { string.format("%d XP", mine.xp or 0), string.format("%d coins", mine.coins or 0) }
	for _, entry in (mine.items or {}) :: { any } do
		local def = ItemDatabase.get(entry.item)
		local name = if def then def.name else tostring(entry.item)
		if entry.rarity then
			name = title(entry.rarity) .. " " .. name
		end
		table.insert(parts, string.format("%s x%d", name, entry.n))
	end
	return table.concat(parts, ", ")
end

local function renderRecap(card: Instance, view: { [string]: any })
	C.text(string.format("%s Rift: %s", tostring(view.twistName), RESULTS[view.result or ""] or "Over"), "heading", { LayoutOrder = 1, Parent = card })
	local mine = view.mine
	if typeof(mine) == "table" then
		if mine.reason == "already" then
			C.text("You've already been rewarded for this Rift on another server.", "body", { LayoutOrder = 2, Parent = card })
		elseif mine.reason == "too_little" then
			C.text(string.format("You earned %d points: not enough for a reward.", mine.points or 0), "body", { LayoutOrder = 2, Parent = card })
		else
			C.text(string.format("%s, with %d points. Rooms solved cleverly: %d", R.tierNames[mine.tier] or "?", mine.points or 0, view.cleverRooms or 0), "label", { LayoutOrder = 2, Parent = card })
			C.text(rewardLine(mine), "body", { LayoutOrder = 3, Parent = card })
			if typeof(mine.answers) == "number" then
				local fresh = if (mine.answersNew or 0) > 0 then string.format("%d new this time. ", mine.answersNew) else ""
				C.text(string.format("%sAnswers found: %d of %d", fresh, mine.answers, mine.answersTotal or 0), "caption", { LayoutOrder = 4, Parent = card })
			end
			if mine.noRoom then
				C.text("Your bags were full, so something was left behind.", "body", { LayoutOrder = 4, Parent = card })
			end
			if view.result == "failed" then
				C.text("A Rift you don't finish pays part of the reward, and no items.", "caption", { LayoutOrder = 4, Parent = card })
			end
		end
	end
	local close = C.button("Close", function()
		dismissedRecap = view.id
		dismissTick:set(dismissTick:get() + 1)
	end, { kind = "ghost" }, { Size = UDim2.new(1, 0, 0, Theme.minTouch), LayoutOrder = 5 })
	close.Parent = card
end

local function buildLayer(scope: Kit.Scope, root: Frame)
	local holder: Frame = Kit.create(nil, "Frame", {
		Name = "RiftPanel",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Theme.space.m, 0, 120),
		Size = UDim2.fromOffset(320, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = root,
	})
	C.list("y", Theme.space.xs).Parent = holder

	Kit.dynamic(scope, { RiftController.view, inside, dismissTick }, function(s)
		local view = RiftController.view:get()
		local phase = view.phase
		if phase == "ended" then
			-- Only people who took part see a recap.
			if typeof(view.mine) ~= "table" or view.id == dismissedRecap then
				return
			end
		elseif phase ~= "running" or not inside:get() then
			return
		end
		local card = C.panel({
			BackgroundTransparency = Theme.glass,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 1,
			Parent = holder,
		})
		s:add(card)
		C.padding(Theme.space.m).Parent = card
		C.list("y", Theme.space.xs).Parent = card
		if phase == "ended" then
			renderRecap(card, view)
		else
			renderRun(s, card, view)
		end
	end)
end

-- ─── The marker ─────────────────────────────────────────────────────────────

local function clearMarker()
	if markerGui then
		markerGui:Destroy()
	end
	if markerHolder then
		markerHolder:Destroy()
	end
	markerGui, markerHolder, markerLabel = nil, nil, nil
end

local function rebuildMarker(view: { [string]: any })
	clearMarker()
	if (view.phase ~= "open" and view.phase ~= "running") or typeof(view.x) ~= "number" or typeof(view.z) ~= "number" then
		return
	end
	local here = rootPosition()
	local holder = Instance.new("Attachment")
	holder.Name = "RiftMarker"
	holder.WorldPosition = Vector3.new(view.x, (if here then here.Y else 0) + MARKER_HEIGHT, view.z)
	holder.Parent = workspace.Terrain

	local gui = Instance.new("BillboardGui")
	gui.Name = "RiftMarker"
	gui.Adornee = holder
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false
	gui.Size = UDim2.fromOffset(220, 66)
	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	local glyph = Instance.new("TextLabel")
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.new(1, 0, 0, 28)
	glyph.Font = Enum.Font.GothamBlack
	glyph.TextScaled = true
	glyph.TextColor3 = Theme.color.accent
	glyph.TextStrokeTransparency = 0.3
	glyph.Text = "✧"
	glyph.Parent = gui

	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Position = UDim2.fromOffset(0, 28)
	label.Size = UDim2.new(1, 0, 0, 38)
	label.Font = Enum.Font.GothamMedium
	label.TextSize = 14
	label.TextWrapped = true
	label.TextYAlignment = Enum.TextYAlignment.Top
	label.TextColor3 = Color3.new(1, 1, 1)
	label.TextStrokeTransparency = 0.35
	label.Parent = gui

	markerHolder, markerGui, markerLabel = holder, gui, label
end

local function update()
	local view = RiftController.view:get()
	local here = rootPosition()
	local isInside = false
	if here and (view.phase == "running" or view.phase == "ended") and typeof(view.pocketLength) == "number" then
		local p = R.pocket
		isInside = here.X >= p.x - POCKET_MARGIN and here.X <= p.x + view.pocketLength + POCKET_MARGIN and math.abs(here.Z - p.z) <= R.width
	end
	if isInside ~= inside:get() then
		inside:set(isInside)
	end
	local gui, label = markerGui, markerLabel
	if gui and label and here and typeof(view.x) == "number" and typeof(view.z) == "number" then
		gui.Enabled = alertsOn() and not isInside
		local d = Vector3.new(here.X - view.x, 0, here.Z - view.z).Magnitude
		label.Text = string.format("%s Rift\n%d studs", tostring(view.twistName), math.floor(d))
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function setView(view: any)
	if typeof(view) ~= "table" then
		return
	end
	local previous = RiftController.view:get()
	RiftController.view:set(view)
	if view.id ~= previous.id or view.phase ~= previous.phase then
		rebuildMarker(view)
	end
	if view.id ~= previous.id then
		RiftController.score:set({ points = 0, inside = false })
	end
	if view.phase == "open" and previous.phase ~= "open" and alertsOn() then
		C.sound("confirm")
		magic.events:Fire({ kind = "notify", text = string.format("A Rift has opened near %s.", tostring(view.place)) })
	end
	if view.phase == "ended" and previous.phase ~= "ended" and typeof(view.mine) == "table" and view.mine.xp then
		C.sound("questDone")
	end
end

function RiftController.init(_self: any, ctx: any)
	magic = ctx.get("MagicStateController")
	ctx.get("InterfaceController"):registerLayer({ id = "Rift", build = buildLayer })
end

function RiftController.start(_self: any, _ctx: any)
	Net.listen("RiftState", setView)
	Net.listen("RiftScore", function(score: any)
		if typeof(score) == "table" then
			RiftController.score:set(score)
		end
	end)
	Net.listen("RiftCue", function(cue: any)
		if typeof(cue) ~= "table" then
			return
		end
		if cue.kind == "telegraph" then
			EventFx.telegraph(cue)
		elseif cue.kind == "impact" then
			EventFx.impact(cue, magic.settings:get().reducedEffects == true)
		elseif cue.kind == "solved" then
			C.sound(if cue.clever then "questDone" else "confirm")
		end
	end)
	task.spawn(function()
		local ok, view = Net.invoke("RequestRift")
		if ok then
			setView(view)
		end
	end)
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= UPDATE_SECONDS then
			elapsed = 0
			update()
		end
	end)
end

return RiftController
