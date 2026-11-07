--!strict
--[[
	TitanController: a Titan from the player's side (docs/Titans.md). The server decides everything
	(Services/TitanService); `view` is the last state it sent.

		panel    In the right-hand column (UI/SideCards): what it is, where it's heading, its health, its
		         weak points and your part. The recap shows your tier and rewards.
		marker   ✹ over it with the distance, while it's walking and you're not beside it. It moves with
		         TitanPos, once a second.
		warnings Fx/EventFx draws the telegraphs the server cues.

	Setting: World event alerts. Off hides the panel and marker until you're close to it.
	There are no intents to send. Words carry everything: tiers, results and the stumble.
	Budget: one 5 Hz loop, only while there's a Titan.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local T = require(Shared.Titans.Data.Titans)
local ItemDatabase = require(Shared.Items.ItemDatabase)

local Client = script.Parent.Parent
local UI = Client:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local SideCards = require(UI.SideCards)
local EventFx = require(Client:WaitForChild("Fx"):WaitForChild("EventFx"))

local UPDATE_SECONDS = 0.2
local MARKER_HEIGHT = 90

local TitanController = {
	name = "TitanController",
	dependencies = { "InterfaceController", "MagicStateController" },
}

local magic: any = nil
local localPlayer = Players.LocalPlayer

TitanController.view = Kit.value({ phase = "none" } :: { [string]: any })
TitanController.score = Kit.value({ points = 0, inZone = false } :: { [string]: any })

local close = Kit.value(false)
local dismissedRecap: string? = nil
local dismissTick = Kit.value(0)

local markerHolder: Attachment? = nil
local markerGui: BillboardGui? = nil
local markerLabel: TextLabel? = nil

local RESULTS: { [string]: string } = {
	won = "✓ It fell",
	failed = "✗ It walked into the sea",
	passed = "It crossed the island, and nobody met it",
	cancelled = "Called off",
}

local function alertsOn(): boolean
	return magic.settings:get().eventAlerts ~= false
end

local function rootPosition(): Vector3?
	local root = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

local function distanceTo(view: { [string]: any }): number?
	local here = rootPosition()
	if not here or typeof(view.x) ~= "number" or typeof(view.z) ~= "number" then
		return nil
	end
	return Vector3.new(here.X - view.x, 0, here.Z - view.z).Magnitude
end

local function distanceText(d: number): string
	return if d >= 1000 then string.format("%.1fk studs", d / 1000) else string.format("%d studs", math.floor(d))
end

-- ─── The panel ──────────────────────────────────────────────────────────────

local function statusText(view: { [string]: any }): string
	local d = distanceTo(view)
	local away = if d then ", " .. distanceText(d) .. " away" else ""
	if view.phase == "warning" then
		local s = math.max(0, math.ceil((view.warnEnds or 0) - workspace:GetServerTimeNow()))
		return string.format("Comes ashore in %d:%02d%s", s // 60, s % 60, away)
	end
	if view.stumbling then
		return "It has stumbled, and stopped!" .. away
	end
	return string.format("%d%% of the way across%s", view.walkedShare or 0, away)
end

local function scoreText(): string
	local score = TitanController.score:get()
	if (score.points or 0) <= 0 and not score.inZone then
		return ""
	end
	local tier = if score.tier then T.tierNames[score.tier] else "No reward yet"
	return string.format("Your part: %d points · %s", score.points or 0, tier)
end

local function renderWalking(s: Kit.Scope, card: Instance, view: { [string]: any })
	C.text("✹ " .. tostring(view.name), "heading", { LayoutOrder = 1, Parent = card })
	C.text(tostring(view.text), "caption", { LayoutOrder = 2, Parent = card })
	local towns = view.towns
	if typeof(towns) == "table" and #towns > 0 then
		C.text("Heading through " .. table.concat(towns, ", then "), "label", { LayoutOrder = 3, Parent = card })
	end
	local status = C.text(statusText(view), "label", { LayoutOrder = 4, Parent = card })
	if view.phase == "walking" then
		local bar = C.bar(nil, math.clamp((view.health or 100) / 100, 0, 1), Theme.color.warn, 8)
		bar.LayoutOrder = 5
		bar.Parent = card
		C.text(string.format("Weak points left: %d of %d. Break them to stop it.", view.weakLeft or 0, view.weakTotal or 3), "caption", { LayoutOrder = 6, Parent = card })
	end
	local score = C.text(scoreText(), "body", { LayoutOrder = 7, Parent = card })
	s:add(TitanController.score:observe(function()
		score.Text = scoreText()
	end))
	local elapsed = 0
	s:add(RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= UPDATE_SECONDS then
			elapsed = 0
			status.Text = statusText(view)
		end
	end))
end

local function rewardLine(mine: { [string]: any }): string
	local parts = { string.format("%d XP", mine.xp or 0), string.format("%d coins", mine.coins or 0) }
	for _, entry in (mine.items or {}) :: { any } do
		local def = ItemDatabase.get(entry.item)
		local name = if def then def.name else tostring(entry.item)
		if entry.rarity then
			local rarity = tostring(entry.rarity)
			name = string.upper(string.sub(rarity, 1, 1)) .. string.sub(rarity, 2) .. " " .. name
		end
		table.insert(parts, string.format("%s x%d", name, entry.n))
	end
	return table.concat(parts, ", ")
end

local function renderRecap(card: Instance, view: { [string]: any })
	C.text(string.format("%s: %s", tostring(view.name), RESULTS[view.result or ""] or "Over"), "heading", { LayoutOrder = 1, Parent = card })
	local mine = view.mine
	if typeof(mine) == "table" then
		if mine.reason == "already" then
			C.text("You've already been rewarded for this Titan on another server.", "body", { LayoutOrder = 2, Parent = card })
		elseif mine.reason == "too_little" then
			C.text(string.format("You earned %d points: not enough for a reward.", mine.points or 0), "body", { LayoutOrder = 2, Parent = card })
		else
			C.text(string.format("%s, with %d points", T.tierNames[mine.tier] or "?", mine.points or 0), "label", { LayoutOrder = 2, Parent = card })
			C.text(rewardLine(mine), "body", { LayoutOrder = 3, Parent = card })
			if mine.noRoom then
				C.text("Your bags were full, so something was left behind.", "body", { LayoutOrder = 4, Parent = card })
			end
		end
	end
	local button = C.button("Close", function()
		dismissedRecap = view.id
		dismissTick:set(dismissTick:get() + 1)
	end, { kind = "ghost" }, { Size = UDim2.new(1, 0, 0, Theme.minTouch), LayoutOrder = 5 })
	button.Parent = card
end

local function buildLayer(scope: Kit.Scope, root: Frame)
	local holder = SideCards.holder(scope, root, 2, "TitanPanel")

	Kit.dynamic(scope, { TitanController.view, magic.settings, close, dismissTick }, function(s)
		local view = TitanController.view:get()
		local phase = view.phase
		if phase == nil or phase == "none" then
			return
		end
		if phase == "ended" then
			local tookPart = typeof(view.mine) == "table"
			if view.id == dismissedRecap or (not tookPart and (view.result ~= "won" or not alertsOn())) then
				return
			end
		elseif not alertsOn() and not close:get() then
			return
		end
		local card = C.panel({
			BackgroundTransparency = SideCards.background,
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
			renderWalking(s, card, view)
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
	if (view.phase ~= "warning" and view.phase ~= "walking") or typeof(view.x) ~= "number" or typeof(view.z) ~= "number" then
		return
	end
	local holder = Instance.new("Attachment")
	holder.Name = "TitanMarker"
	holder.Parent = workspace.Terrain

	local gui = Instance.new("BillboardGui")
	gui.Name = "TitanMarker"
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
	glyph.TextColor3 = Theme.color.warn
	glyph.TextStrokeTransparency = 0.3
	glyph.Text = "✹"
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
	local view = TitanController.view:get()
	if view.phase ~= "warning" and view.phase ~= "walking" then
		if close:get() then
			close:set(false)
		end
		return
	end
	local d = distanceTo(view)
	local isClose = d ~= nil and d <= T.activeRadius
	if isClose ~= close:get() then
		close:set(isClose)
	end
	local gui, label, holder = markerGui, markerLabel, markerHolder
	local here = rootPosition()
	if gui and label and holder and here and d then
		gui.Enabled = alertsOn() and d > T.zoneRadius
		holder.WorldPosition = Vector3.new(view.x, here.Y + MARKER_HEIGHT, view.z)
		label.Text = string.format("%s\n%s", tostring(view.name), distanceText(d))
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function setView(view: any)
	if typeof(view) ~= "table" then
		return
	end
	local previous = TitanController.view:get()
	TitanController.view:set(view)
	if view.id ~= previous.id or view.phase ~= previous.phase then
		rebuildMarker(view)
	end
	if view.id ~= previous.id then
		TitanController.score:set({ points = 0, inZone = false })
	end
	if view.phase ~= previous.phase and alertsOn() then
		if view.phase == "warning" then
			C.sound("confirm")
			magic.events:Fire({ kind = "notify", text = string.format("%s is wading ashore.", tostring(view.name)) })
		elseif view.phase == "walking" and previous.phase == "warning" then
			magic.events:Fire({ kind = "notify", text = string.format("%s is walking.", tostring(view.name)) })
		end
	end
	if view.phase == "ended" and previous.phase ~= "ended" and typeof(view.mine) == "table" and view.mine.xp then
		C.sound("questDone")
	end
end

function TitanController.init(_self: any, ctx: any)
	magic = ctx.get("MagicStateController")
	ctx.get("InterfaceController"):registerLayer({ id = "Titan", build = buildLayer })
end

function TitanController.start(_self: any, _ctx: any)
	Net.listen("TitanState", setView)
	Net.listen("TitanPos", function(pos: any)
		-- Changed in place: MapController reads it when it draws, and the panel needn't rebuild each second.
		local view = TitanController.view:get()
		if typeof(pos) == "table" and typeof(pos.x) == "number" and typeof(pos.z) == "number" then
			view.x, view.z = pos.x, pos.z
		end
	end)
	Net.listen("TitanScore", function(score: any)
		if typeof(score) == "table" then
			TitanController.score:set(score)
		end
	end)
	Net.listen("TitanCue", function(cue: any)
		if typeof(cue) ~= "table" then
			return
		end
		if cue.kind == "telegraph" then
			EventFx.telegraph(cue)
		elseif cue.kind == "impact" then
			EventFx.impact(cue, magic.settings:get().reducedEffects == true)
		end
	end)
	task.spawn(function()
		local ok, view = Net.invoke("RequestTitan")
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

return TitanController
