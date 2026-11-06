--!strict
--[[
	DuelController: a duel from the player's side (docs/Social.md §6). The server decides everything
	(Services/DuelService); `view` is the last DuelState it sent.

		card      an always-on layer (and a section of the Party screen) that shows, by phase:
		          incoming   who challenged you, the rule in words, Accept / Decline, time left
		          outgoing   who you're waiting for, Cancel
		          countdown  a big 3-2-1 in the middle of the screen
		          fight      opponent, rule, clock, Yield, and a warning when you're out of the ring
		          ended      the recap: who won and why, both fighters' numbers, the biggest hit
		ring      every DuelRing tagged part in range is drawn locally as a glowing circle on the ground
		          with the fighters' names over the middle, so bystanders can see what's going on and
		          keep out. Parts only stream to players nearby, so far-off rings cost nothing.
		/yield    typed in chat, for when the mouse is busy.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local DuelRules = require(Shared.Social.Data.DuelRules)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

local RECAP_SECONDS = 25
local RING_SEGMENTS = 48
local RING_LABEL_RANGE = 220
local CLOCK_HZ = 5

local DuelController = {
	name = "DuelController",
	dependencies = { "InterfaceController", "MagicStateController" },
}

local interface: any = nil
local magic: any = nil
local localPlayer = Players.LocalPlayer

DuelController.view = Kit.value({ phase = "none" } :: { [string]: any })
DuelController.rule = Kit.value(DuelRules.default) -- the rule the Party screen would challenge with

local REFUSALS: { [string]: string } = {
	GONE = "They've left.",
	SELF = "You can't duel yourself.",
	NOT_NOW = "Neither of you can duel right now.",
	TOO_FAR = "You're too far apart. Get closer first.",
	IN_DUEL = "One of you is already in a duel.",
	IN_COMBAT = "Someone was hit in the last few seconds. Wait until the fighting stops.",
	PENDING = "You already have a challenge open.",
	NOT_ACCEPTING = "They aren't taking challenges right now.",
	COOLDOWN = "They just said no. Give it a moment.",
	FULL = "Too many duels are running here. Try again soon.",
	EXPIRED = "That challenge has run out.",
	NOT_FIGHTING = "There's nothing to yield yet.",
	OFF = "Duels are switched off right now.",
}

local ENDINGS: { [string]: string } = {
	first_blood = "First blood decided it.",
	floor = "One fighter was nearly spent.",
	floor_yield = "One fighter stayed at their limit and yielded.",
	yielded = "One fighter yielded.",
	ring = "A fighter left the ring.",
	down = "A fighter went down.",
	left = "A fighter left the server.",
	time = "Time ran out.",
	interrupted = "Something else got involved, so the duel was called off.",
}

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

function DuelController.act(_self: any, op: string, target: number?, rule: string?)
	task.spawn(function()
		local ok, result = Net.invoke("DuelAction", op, target, rule)
		if ok and typeof(result) == "table" and not result.ok and result.reason then
			magic.events:Fire({ kind = "notify", text = REFUSALS[result.reason] or "That didn't work." })
		end
	end)
end

function DuelController.challenge(self: any, target: number)
	self:act("challenge", target, DuelController.rule:get())
end

-- ─── The card ───────────────────────────────────────────────────────────────

local function actionRow(parent: Instance, order: number, buttons: { { label: string, kind: string, fn: () -> () } })
	local row: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.new(1, 0, 0, Theme.minTouch),
		LayoutOrder = order,
		Parent = parent,
	})
	C.list("x", Theme.space.s).Parent = row
	local width = 1 / #buttons
	for i, b in buttons do
		local button = C.button(b.label, b.fn, { kind = b.kind }, {
			Size = UDim2.new(width, -Theme.space.s, 1, 0),
			LayoutOrder = i,
		})
		button.Parent = row
	end
end

local function clock(seconds: number): string
	local s = math.max(0, math.ceil(seconds))
	return string.format("%d:%02d", s // 60, s % 60)
end

local function fighterLine(name: string, f: any): string
	return string.format("%s: %d damage in %d hit%s%s, biggest %d", name, f.dealt, f.hits, if f.hits == 1 then "" else "s", if f.crits > 0 then string.format(" (%d crit%s)", f.crits, if f.crits == 1 then "" else "s") else "", f.biggest)
end

local function renderRecap(parent: Instance, view: { [string]: any })
	local recap = view.recap
	local headline = if view.result == "won" then "You won the duel" elseif view.result == "lost" then "You lost the duel" else "A draw"
	C.text(headline, "heading", { LayoutOrder = 1, Parent = parent })
	C.text(string.format("Against %s, %s. %s", tostring(view.name), clock(recap.seconds), ENDINGS[view.reason] or ""), "caption", { LayoutOrder = 2, Parent = parent })
	for i, f in recap.fighters do
		local who = if f.userId == localPlayer.UserId then "You" else tostring(view.name)
		C.text(fighterLine(who, f), "body", { LayoutOrder = 2 + i, Parent = parent })
	end
	local biggest = recap.biggest
	if biggest then
		local who = if biggest.by == localPlayer.UserId then "yours" else tostring(view.name) .. "'s"
		C.text(string.format("Biggest hit: %d, %s%s (%s)", biggest.amount, who, if biggest.crit then ", a crit" else "", tostring(biggest.kind)), "caption", { LayoutOrder = 6, Parent = parent })
	end
	actionRow(parent, 7, { { label = "Close", kind = "ghost", fn = function()
		DuelController.view:set({ phase = "none" })
	end } })
end

-- Builds the card for the current phase into `parent`. Used by the layer and the Party screen.
function DuelController.renderCard(_self: any, scope: Kit.Scope, parent: Instance, order: number)
	Kit.dynamic(scope, { DuelController.view }, function(s)
		local view = DuelController.view:get()
		local phase = view.phase
		if phase == "none" or phase == nil or phase == "countdown" then
			return
		end
		local rule = DuelRules.rules[view.rule or ""]
		local card = C.panel({
			BackgroundTransparency = Theme.glass,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = order,
			Parent = parent,
		})
		s:add(card)
		C.padding(Theme.space.m).Parent = card
		C.list("y", Theme.space.xs).Parent = card

		if phase == "incoming" then
			C.text(tostring(view.name) .. " challenges you to a duel", "heading", { LayoutOrder = 1, Parent = card })
			if rule then
				C.text(rule.name .. ": " .. rule.text, "body", { LayoutOrder = 2, Parent = card })
			end
			C.text("Nobody can die in a duel, and you get your health back afterwards.", "caption", { LayoutOrder = 3, Parent = card })
			local left = C.text("", "caption", { LayoutOrder = 4, Parent = card })
			s:add(RunService.Heartbeat:Connect(function()
				left.Text = "Time to answer: " .. clock((view.expires or 0) - serverNow())
			end))
			actionRow(card, 5, {
				{ label = "Accept", kind = "primary", fn = function()
					DuelController:act("accept")
				end },
				{ label = "Decline", kind = "ghost", fn = function()
					DuelController:act("decline")
				end },
			})
		elseif phase == "outgoing" then
			C.text("Waiting for " .. tostring(view.name), "heading", { LayoutOrder = 1, Parent = card })
			if rule then
				C.text(rule.name .. ": " .. rule.text, "caption", { LayoutOrder = 2, Parent = card })
			end
			actionRow(card, 3, { { label = "Cancel", kind = "ghost", fn = function()
				DuelController:act("cancel")
			end } })
		elseif phase == "fight" then
			C.text(string.format("Duel: %s · %s", tostring(view.name), if rule then rule.name else "?"), "label", { LayoutOrder = 1, Parent = card })
			local status = C.text("", "caption", { LayoutOrder = 2, Parent = card })
			local elapsed = 0
			s:add(RunService.Heartbeat:Connect(function(dt)
				elapsed += dt
				if elapsed < 1 / CLOCK_HZ then
					return
				end
				elapsed = 0
				local text = clock((view.endsAt or 0) - serverNow()) .. " left"
				local root = localPlayer.Character and localPlayer.Character:FindFirstChild("HumanoidRootPart")
				local center: any = view.center
				if root and root:IsA("BasePart") and typeof(center) == "Vector3" and typeof(view.radius) == "number" then
					local away = Vector3.new(root.Position.X - center.X, 0, root.Position.Z - center.Z).Magnitude
					if away > view.radius then
						text = "! Back inside the ring or you forfeit!"
						status.TextColor3 = Theme.color.warn
					else
						status.TextColor3 = Theme.color.inkDim
					end
				end
				status.Text = text
			end))
			actionRow(card, 3, { { label = "Yield", kind = "ghost", fn = function()
				DuelController:act("yield")
			end } })
		elseif phase == "ended" and view.recap then
			renderRecap(card, view)
		end
	end)
end

local function buildLayer(scope: Kit.Scope, root: Frame)
	local compact = interface.layout:get() == "Compact"
	local holder: Frame = Kit.create(nil, "Frame", {
		Name = "DuelCard",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0),
		Position = UDim2.new(0.5, 0, 0, Theme.space.m),
		Size = UDim2.fromOffset(if compact then 300 else 380, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = root,
	})
	C.list("y", Theme.space.xs).Parent = holder
	DuelController:renderCard(scope, holder, 1)

	-- The countdown, big and in the middle.
	Kit.dynamic(scope, { DuelController.view }, function(s)
		local view = DuelController.view:get()
		if view.phase ~= "countdown" then
			return
		end
		local number: TextLabel = C.text("", "display", {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.fromScale(0.5, 0.35),
			Size = UDim2.fromOffset(600, 0),
			TextXAlignment = Enum.TextXAlignment.Center,
			TextStrokeTransparency = 0.4,
			Parent = root,
		})
		s:add(number)
		s:add(RunService.Heartbeat:Connect(function()
			local left = (view.fightAt or 0) - serverNow()
			number.Text = if left > 0 then string.format("%s\n%d", tostring(view.name), math.ceil(left)) else "Fight!"
		end))
	end)
end

-- ─── The ring ───────────────────────────────────────────────────────────────

local ringFolders: { [Instance]: Folder } = {}

local function drawRing(anchor: Instance)
	if not anchor:IsA("BasePart") or ringFolders[anchor] then
		return
	end
	local radius = anchor:GetAttribute("Radius")
	if typeof(radius) ~= "number" then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "DuelRingFx"
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	local center = anchor.Position
	local length = 2 * math.pi * radius / RING_SEGMENTS + 0.4
	for i = 1, RING_SEGMENTS do
		local angle = i / RING_SEGMENTS * 2 * math.pi
		local at = center + Vector3.new(math.cos(angle) * radius, 0, math.sin(angle) * radius)
		local hit = workspace:Raycast(at + Vector3.new(0, 60, 0), Vector3.new(0, -160, 0), params)
		local y = if hit then hit.Position.Y + 0.15 else center.Y - 3
		local part = Instance.new("Part")
		part.Name = "Segment"
		part.Anchored = true
		part.CanCollide = false
		part.CanQuery = false
		part.CanTouch = false
		part.CastShadow = false
		part.Material = Enum.Material.Neon
		part.Color = Theme.color.accent
		part.Size = Vector3.new(length, 0.25, 0.5)
		part.CFrame = CFrame.new(at.X, y, at.Z) * CFrame.Angles(0, -angle - math.pi / 2, 0)
		part.Parent = folder
	end

	local gui = Instance.new("BillboardGui")
	gui.Name = "DuelLabel"
	gui.Size = UDim2.fromOffset(280, 54)
	gui.StudsOffset = Vector3.new(0, 10, 0)
	gui.MaxDistance = RING_LABEL_RANGE
	gui.AlwaysOnTop = false
	gui.Adornee = anchor
	local rule = DuelRules.rules[tostring(anchor:GetAttribute("Rule"))]
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.FontFace = Theme.font.bold
	label.TextSize = 18
	label.TextColor3 = Theme.color.ink
	label.TextStrokeTransparency = 0.3
	label.TextWrapped = true
	label.Text = string.format("Duel: %s vs %s\n%s", tostring(anchor:GetAttribute("A")), tostring(anchor:GetAttribute("B")), if rule then rule.name else "")
	label.Parent = gui
	gui.Parent = folder

	folder.Parent = workspace
	ringFolders[anchor] = folder
end

local function eraseRing(anchor: Instance)
	local folder = ringFolders[anchor]
	if folder then
		folder:Destroy()
		ringFolders[anchor] = nil
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local recapToken = 0

function DuelController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	magic = ctx.get("MagicStateController")
	interface:registerLayer({ id = "Duel", build = buildLayer })
end

function DuelController.start(_self: any, _ctx: any)
	Net.listen("DuelState", function(view: any)
		if typeof(view) ~= "table" then
			return
		end
		DuelController.view:set(view)
		recapToken += 1
		if view.phase == "incoming" then
			C.sound("confirm")
		elseif view.phase == "ended" then
			C.sound(if view.result == "won" then "questDone" else "close")
			local token = recapToken
			task.delay(RECAP_SECONDS, function()
				if token == recapToken then
					DuelController.view:set({ phase = "none" })
				end
			end)
		end
	end)

	CollectionService:GetInstanceAddedSignal("DuelRing"):Connect(drawRing)
	CollectionService:GetInstanceRemovedSignal("DuelRing"):Connect(eraseRing)
	for _, anchor in CollectionService:GetTagged("DuelRing") do
		drawRing(anchor)
	end

	pcall(function()
		if TextChatService.ChatVersion == Enum.ChatVersion.TextChatService then
			local command = Instance.new("TextChatCommand")
			command.Name = "DuelYield"
			command.PrimaryAlias = "/yield"
			command.Triggered:Connect(function()
				DuelController:act("yield")
			end)
			command.Parent = TextChatService
		end
	end)
end

return DuelController
