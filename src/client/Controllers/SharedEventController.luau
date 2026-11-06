--!strict
--[[
	SharedEventController: a server-wide event from the player's side (docs/Social.md "Shared events").
	The server decides everything (Services/SharedEventService); `view` is the last state it sent.

		panel    top centre: the event, where it is, the countdown or time left, progress and your score.
		         Hidden during a duel (the duel card sits there). The recap shows your tier and rewards.
		marker   ✦ over the event's place with the distance, until you're inside its zone.
		warnings Fx/EventFx draws the telegraphs the server cues.

	Setting: World event alerts. Off hides the panel and marker until you walk into the zone, so nobody
	playing alone has to look at a countdown for something on the far side of the map.
	Colour is never the only cue: tiers read as words, results as words and glyphs.
	Budget: one 5 Hz loop, only while an event is up.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local S = require(Shared.Social.Data.SharedEvents)
local ItemDatabase = require(Shared.Items.ItemDatabase)

local Client = script.Parent.Parent
local UI = Client:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local EventFx = require(Client:WaitForChild("Fx"):WaitForChild("EventFx"))

local UPDATE_SECONDS = 0.2
local MARKER_HEIGHT = 40

local SharedEventController = {
	name = "SharedEventController",
	dependencies = { "InterfaceController", "MagicStateController", "DuelController" },
}

local magic: any = nil
local duel: any = nil
local localPlayer = Players.LocalPlayer

SharedEventController.view = Kit.value({ phase = "none" } :: { [string]: any })
SharedEventController.score = Kit.value({ points = 0, seconds = 0, inZone = false } :: { [string]: any })

local inZone = Kit.value(false)
local dismissedRecap: string? = nil
local dismissTick = Kit.value(0)

local markerHolder: Attachment? = nil
local markerGui: BillboardGui? = nil
local markerLabel: TextLabel? = nil

local RESULTS: { [string]: string } = {
	won = "✓ Victory",
	failed = "✗ It got away",
	passed = "Nobody came, and it passed",
	cancelled = "Called off",
}

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

local function clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function distanceText(d: number): string
	return if d >= 1000 then string.format("%.1fk studs", d / 1000) else string.format("%d studs", math.floor(d))
end

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

-- ─── The panel ──────────────────────────────────────────────────────────────

local function statusText(view: { [string]: any }): string
	local d = distanceTo(view)
	local away = if d and d > (view.radius or 0) then ", " .. distanceText(d) .. " away" else ""
	if view.phase == "warning" then
		return string.format("Begins in %s%s", clock((view.warnEnds or 0) - serverNow()), away)
	end
	return string.format("%s left%s", clock((view.endsAt or 0) - serverNow()), away)
end

local function scoreText(): string
	local score = SharedEventController.score:get()
	if (score.points or 0) <= 0 and not score.inZone then
		return ""
	end
	local tier = if score.tier then S.tierNames[score.tier] else "No reward yet"
	return string.format("Your part: %d points · %s", score.points or 0, tier)
end

local function renderFight(s: Kit.Scope, card: Instance, view: { [string]: any })
	C.text("✦ " .. tostring(view.name), "heading", { LayoutOrder = 1, Parent = card })
	local where = if view.place == "here" then "Here" else "Near " .. tostring(view.place)
	C.text(where .. ". " .. tostring(view.text), "caption", { LayoutOrder = 2, Parent = card })
	local status = C.text(statusText(view), "label", { LayoutOrder = 3, Parent = card })

	if view.phase == "fight" and view.started then
		local goal = math.max(1, view.goal or 1)
		local bar = C.bar(nil, math.clamp((view.progress or 0) / goal, 0, 1), Theme.color.accent, 8)
		bar.LayoutOrder = 4
		bar.Parent = card
		local line = tostring(view.goalText)
		line ..= if view.type == "elemental" then string.format(": %d%%", view.progress or 0) else string.format(": %d of %d", view.progress or 0, goal)
		if view.detail then
			line ..= " · " .. tostring(view.detail)
		end
		C.text(line, "caption", { LayoutOrder = 5, Parent = card })
	elseif view.phase == "fight" then
		C.text("It appears when someone gets close.", "caption", { LayoutOrder = 4, Parent = card })
	end

	local score = C.text(scoreText(), "body", { LayoutOrder = 6, Parent = card })
	s:add(SharedEventController.score:observe(function()
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
		table.insert(parts, string.format("%s x%d", if def then def.name else entry.item, entry.n))
	end
	return table.concat(parts, ", ")
end

local function renderRecap(card: Instance, view: { [string]: any })
	C.text(string.format("%s: %s", tostring(view.name), RESULTS[view.result or ""] or "Over"), "heading", { LayoutOrder = 1, Parent = card })
	local mine = view.mine
	if typeof(mine) == "table" then
		if mine.reason == "already" then
			C.text("You've already been rewarded for this event on another server.", "body", { LayoutOrder = 2, Parent = card })
		elseif mine.reason == "too_little" then
			C.text(string.format("You earned %d points: not enough for a reward. Stay in the zone and join the fight.", mine.points or 0), "body", { LayoutOrder = 2, Parent = card })
		else
			C.text(string.format("%s, with %d points", S.tierNames[mine.tier] or "?", mine.points or 0), "label", { LayoutOrder = 2, Parent = card })
			C.text(rewardLine(mine), "body", { LayoutOrder = 3, Parent = card })
			if view.result == "failed" then
				C.text("A failed event pays part of the reward, and no items.", "caption", { LayoutOrder = 4, Parent = card })
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
		Name = "SharedEventPanel",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, Theme.space.m),
		Size = UDim2.fromOffset(340, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = root,
	})
	C.list("y", Theme.space.xs).Parent = holder

	Kit.dynamic(scope, { SharedEventController.view, duel.view, magic.settings, inZone, dismissTick }, function(s)
		local view = SharedEventController.view:get()
		local phase = view.phase
		if phase == nil or phase == "none" then
			return
		end
		-- The duel card sits in this spot.
		local duelPhase = duel.view:get().phase
		if duelPhase == "fight" or duelPhase == "countdown" or duelPhase == "incoming" then
			return
		end
		if phase == "ended" then
			-- Took part: always a recap. Didn't: only news of a win, and only with alerts on.
			local tookPart = typeof(view.mine) == "table"
			if view.id == dismissedRecap or (not tookPart and (view.result ~= "won" or not alertsOn())) then
				return
			end
		elseif not alertsOn() and not inZone:get() then
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
			renderFight(s, card, view)
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
	if view.phase ~= "warning" and view.phase ~= "fight" then
		return
	end
	if typeof(view.x) ~= "number" or typeof(view.z) ~= "number" then
		return
	end
	local here = rootPosition()
	local y = (if here then here.Y else 0) + MARKER_HEIGHT
	local holder = Instance.new("Attachment")
	holder.Name = "SharedEventMarker"
	holder.WorldPosition = Vector3.new(view.x, y, view.z)
	holder.Parent = workspace.Terrain

	local gui = Instance.new("BillboardGui")
	gui.Name = "SharedEventMarker"
	gui.Adornee = holder
	gui.AlwaysOnTop = true
	gui.LightInfluence = 0
	gui.ResetOnSpawn = false -- straight under PlayerGui: survives respawns
	gui.Size = UDim2.fromOffset(220, 66)
	gui.Parent = localPlayer:WaitForChild("PlayerGui")

	local glyph = Instance.new("TextLabel")
	glyph.BackgroundTransparency = 1
	glyph.Size = UDim2.new(1, 0, 0, 28)
	glyph.Font = Enum.Font.GothamBlack
	glyph.TextScaled = true
	glyph.TextColor3 = Theme.color.warn
	glyph.TextStrokeTransparency = 0.3
	glyph.Text = "✦"
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

-- Five times a second while an event is up: are you in the zone, and the marker's distance.
local function update()
	local view = SharedEventController.view:get()
	if view.phase ~= "warning" and view.phase ~= "fight" then
		if inZone:get() then
			inZone:set(false)
		end
		return
	end
	local d = distanceTo(view)
	local inside = d ~= nil and d <= (view.radius or 0)
	if inside ~= inZone:get() then
		inZone:set(inside)
	end
	local gui, label = markerGui, markerLabel
	if gui and label then
		gui.Enabled = alertsOn() and not inside
		if d then
			label.Text = string.format("%s\n%s", tostring(view.name), distanceText(d))
		end
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function setView(view: any)
	if typeof(view) ~= "table" then
		return
	end
	local previous = SharedEventController.view:get()
	SharedEventController.view:set(view)
	if view.id ~= previous.id or view.phase ~= previous.phase then
		rebuildMarker(view)
	end
	if view.id ~= previous.id then
		SharedEventController.score:set({ points = 0, seconds = 0, inZone = false })
	end
	-- Worth a word only when something begins or you've earned something.
	if view.phase ~= previous.phase and alertsOn() then
		if view.phase == "warning" then
			C.sound("confirm")
			magic.events:Fire({ kind = "notify", text = string.format("%s is coming, near %s.", tostring(view.name), tostring(view.place)) })
		elseif view.phase == "fight" and previous.phase == "warning" then
			magic.events:Fire({ kind = "notify", text = tostring(view.name) .. " has begun." })
		end
	end
	if view.phase == "ended" and previous.phase ~= "ended" and typeof(view.mine) == "table" and view.mine.xp then
		C.sound("questDone")
	end
end

function SharedEventController.init(_self: any, ctx: any)
	magic = ctx.get("MagicStateController")
	duel = ctx.get("DuelController")
	ctx.get("InterfaceController"):registerLayer({ id = "SharedEvent", build = buildLayer })
end

function SharedEventController.start(_self: any, _ctx: any)
	Net.listen("SharedEventState", setView)
	Net.listen("SharedEventScore", function(score: any)
		if typeof(score) == "table" then
			SharedEventController.score:set(score)
		end
	end)
	Net.listen("SharedEventCue", function(cue: any)
		if typeof(cue) ~= "table" then
			return
		end
		if cue.kind == "telegraph" then
			EventFx.telegraph(cue)
		elseif cue.kind == "comet" then
			EventFx.comet(cue)
		elseif cue.kind == "impact" then
			EventFx.impact(cue, magic.settings:get().reducedEffects == true)
		end
	end)
	-- Someone joining during an event asks what's going on.
	task.spawn(function()
		local ok, view = Net.invoke("RequestSharedEvent")
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

return SharedEventController
