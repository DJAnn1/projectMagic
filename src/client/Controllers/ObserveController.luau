--!strict
--[[
	ObserveController: reading what someone is doing by looking at them (docs/Activities.md §5).

	Rest the mouse on a person (or the middle of the screen on touch and gamepad) within LOOK_RANGE for
	DWELL seconds and a small label appears over them. The words come from the server (NpcObserve):
	how much you can read depends on whether you know them, how sharp your Mind magic is, and how long
	you've been watching. A stranger glanced at is "Someone working at an anvil"; watched a while, or
	known, it's "Marta · Smith: Hammering out a plowshare, with great care · on shift".

	The Reading people setting (Shared/UI/Settings npcObserve): Off · Minimal · Standard · Detailed.
	Text size follows the Text size setting; the text is plain words (no colour-only cues, no icons), so
	screen readers and colour-blind players read the same thing.

	Budget: a ray every 0.1 s while the setting is on; one request when a new person is looked at and one
	every REFRESH seconds while you keep looking (the server rate-limits it too).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)

local Client = script.Parent.Parent
local UI = Client:WaitForChild("UI")
local Theme = require(UI.Theme)

local LOOK_RANGE = 40
local DWELL = 0.35
local REFRESH = 2
local LOSE_AFTER = 0.6
local SCAN_EVERY = 0.1

local ObserveController = {
	name = "ObserveController",
	dependencies = {},
}

local player = Players.LocalPlayer
local gui: BillboardGui? = nil
local title: TextLabel? = nil
local line: TextLabel? = nil

local looking: Model? = nil
local lastSeen = 0
local shownFor: Model? = nil
local nextAsk = 0
local asking = false
local scanAt = 0

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function build(): BillboardGui
	if gui then
		return gui
	end
	local g = Instance.new("BillboardGui")
	g.Name = "ObserveLabel"
	g.Size = UDim2.fromOffset(320, 70)
	g.StudsOffset = Vector3.new(0, 3.4, 0)
	g.AlwaysOnTop = true
	g.LightInfluence = 0
	g.MaxDistance = LOOK_RANGE + 10
	g.Enabled = false
	local panel = Instance.new("Frame")
	panel.Name = "Panel"
	panel.AnchorPoint = Vector2.new(0.5, 1)
	panel.Position = UDim2.fromScale(0.5, 1)
	panel.Size = UDim2.fromScale(0, 0)
	panel.AutomaticSize = Enum.AutomaticSize.XY
	panel.BackgroundColor3 = Theme.color.panel
	panel.BackgroundTransparency = 0.18
	panel.Parent = g
	local corner = Instance.new("UICorner")
	corner.CornerRadius = UDim.new(0, Theme.radius.m)
	corner.Parent = panel
	local stroke = Instance.new("UIStroke")
	stroke.Color = Theme.color.line
	stroke.Transparency = 0.4
	stroke.Parent = panel
	local pad = Instance.new("UIPadding")
	pad.PaddingLeft = UDim.new(0, Theme.space.m)
	pad.PaddingRight = UDim.new(0, Theme.space.m)
	pad.PaddingTop = UDim.new(0, Theme.space.xs + 2)
	pad.PaddingBottom = UDim.new(0, Theme.space.xs + 2)
	pad.Parent = panel
	local layout = Instance.new("UIListLayout")
	layout.SortOrder = Enum.SortOrder.LayoutOrder
	layout.HorizontalAlignment = Enum.HorizontalAlignment.Center
	layout.Padding = UDim.new(0, 2)
	layout.Parent = panel
	local function label(name: string, order: number, font: Font, color: Color3): TextLabel
		local t = Instance.new("TextLabel")
		t.Name = name
		t.LayoutOrder = order
		t.BackgroundTransparency = 1
		t.AutomaticSize = Enum.AutomaticSize.XY
		t.Size = UDim2.fromOffset(0, 0)
		t.FontFace = font
		t.TextColor3 = color
		t.TextWrapped = false
		t.Text = ""
		t.Parent = panel
		local limit = Instance.new("UISizeConstraint")
		limit.MaxSize = Vector2.new(300, math.huge)
		limit.Parent = t
		return t
	end
	title = label("Title", 1, Theme.font.bold, Theme.color.ink)
	line = label("Line", 2, Theme.font.body, Theme.color.inkDim)
	g.Parent = player:WaitForChild("PlayerGui")
	gui = g
	return g
end

local function hide()
	if gui then
		gui.Enabled = false
		gui.Adornee = nil
	end
	shownFor = nil
end

local function show(model: Model, t: string, l: string)
	local g = build()
	local head = model:FindFirstChild("Head")
	if not head or not head:IsA("BasePart") then
		hide()
		return
	end
	local tl, ll = title :: TextLabel, line :: TextLabel
	tl.TextSize = Theme.text("label")
	ll.TextSize = Theme.text("body")
	-- Wrap the line once it's long; the panel grows to fit (scaled with the text size).
	ll.TextWrapped = #l > 46
	ll.Size = if #l > 46 then UDim2.fromOffset(290, 0) else UDim2.fromOffset(0, 0)
	ll.AutomaticSize = if #l > 46 then Enum.AutomaticSize.Y else Enum.AutomaticSize.XY
	tl.Text = t
	ll.Text = l
	g.Size = UDim2.fromOffset(320, math.floor(70 * Theme.settings.textScale))
	g.Adornee = head
	g.Enabled = true
	shownFor = model
end

-- The NPC under the pointer (mouse) or at the middle of the screen (touch, gamepad).
local function lookedAt(): Model?
	local camera = workspace.CurrentCamera
	local folder = workspace:FindFirstChild("NPCs")
	if not camera or not folder then
		return nil
	end
	local point = if UserInputService.MouseEnabled and not UserInputService.TouchEnabled
		then UserInputService:GetMouseLocation()
		else camera.ViewportSize / 2
	local ray = camera:ViewportPointToRay(point.X, point.Y)
	local ignore: { Instance } = {}
	if player.Character then
		table.insert(ignore, player.Character)
	end
	rayParams.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(ray.Origin, ray.Direction * (LOOK_RANGE + 30), rayParams)
	if not hit then
		return nil
	end
	local node: Instance? = hit.Instance
	while node and node.Parent ~= folder do
		node = node.Parent
	end
	if not node or not node:IsA("Model") or typeof(node:GetAttribute("NpcId")) ~= "string" then
		return nil
	end
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	local theirs = node:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or not theirs or not theirs:IsA("BasePart") then
		return nil
	end
	if (theirs.Position - root.Position).Magnitude > LOOK_RANGE then
		return nil
	end
	return node
end

local function ask(model: Model)
	if asking then
		return
	end
	local npcId = model:GetAttribute("NpcId")
	if typeof(npcId) ~= "string" then
		return
	end
	asking = true
	local detail = Theme.settings.npcObserve
	task.spawn(function()
		local ok, result = Net.invoke("NpcObserve", npcId, detail)
		asking = false
		-- Still looking at the same person, and the setting still on?
		if looking ~= model or Theme.settings.npcObserve == "Off" then
			return
		end
		if ok and typeof(result) == "table" and typeof(result.title) == "string" and typeof(result.line) == "string" then
			show(model, result.title, result.line)
		else
			hide()
		end
	end)
end

local function step()
	local now = os.clock()
	if now < scanAt then
		return
	end
	scanAt = now + SCAN_EVERY
	if Theme.settings.npcObserve == "Off" then
		looking = nil
		hide()
		return
	end
	local target = lookedAt()
	if target then
		lastSeen = now
		if target ~= looking then
			looking = target
			nextAsk = now + DWELL
			if shownFor and shownFor ~= target then
				hide()
			end
		end
		if now >= nextAsk then
			nextAsk = now + REFRESH
			ask(target)
		end
	elseif looking and now - lastSeen > LOSE_AFTER then
		looking = nil
		hide()
	end
	if shownFor and not shownFor.Parent then
		hide()
	end
end

function ObserveController.init(_self: any, _ctx: any) end

function ObserveController.start(_self: any, _ctx: any)
	RunService.Heartbeat:Connect(step)
end

return ObserveController
