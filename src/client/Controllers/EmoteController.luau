--!strict
--[[
	EmoteController: the emote wheel, chat commands, and playing other people's emotes
	(docs/Social.md §5). The server decides everything (Services/EmoteService); this only asks and draws.

	WHEEL     Hold T, point at one and let go (letting go near the centre cancels). Clicking or tapping
	          a slice also works; on touch a small Emotes button opens it. Gamepad players use the
	          buttons on the Party screen.
	CHAT      /wave /bow /cheer /laugh /dance /meditate /lightshow /halo (TextChatCommands, created
	          here so they only ever trigger an EmoteIntent; nothing typed is shown to anyone).
	DRAWING   A cue arrives for everyone in range:
	            clip      played only by the owner's client (animations replicate on their own)
	            pose      Fx/EmotePoses, drawn locally by each viewer
	            flourish  Fx/EmoteFx, drawn locally by each viewer
	HIDDEN    `hide` means you don't want to see this person's emotes (a block or Settings › Emotes
	          from others). Poses and flourishes simply aren't drawn. A clip replicates regardless, so
	          while it runs this client keeps stopping that track on that character, locally.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TextChatService = game:GetService("TextChatService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Controls = require(Shared.UI.Controls)
local Emotes = require(Shared.Social.Data.Emotes)

local Client = script.Parent.Parent
local UI = Client:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local EmotePoses = require(Client.Fx.EmotePoses)
local EmoteFx = require(Client.Fx.EmoteFx)

local WHEEL_RADIUS = 150 -- pixels from the centre to each slice
local DEAD_ZONE = 45 -- pixels: letting go this close to the centre cancels
local SLICE_SIZE = Vector2.new(124, 56)
local SUPPRESS_EVERY = 0.25 -- seconds between checks for a hidden emote's replicated clip
local SUPPRESS_MAX = 35 -- seconds: the longest a hidden clip can run

local EmoteController = {
	name = "EmoteController",
	dependencies = { "InterfaceController" },
}

local interface: any = nil
local localPlayer = Players.LocalPlayer

-- What's playing for each person, so an "off" cue can undo it.
type Playing = { stopFx: (() -> ())?, track: AnimationTrack?, suppress: boolean? }
local playing: { [number]: Playing } = {}

-- ─── Asking ─────────────────────────────────────────────────────────────────

function EmoteController.request(_self: any, id: string)
	Net.send("EmoteIntent", id)
end

-- ─── Drawing cues ───────────────────────────────────────────────────────────

local function playOwnClip(def: Emotes.Emote): AnimationTrack?
	local character = localPlayer.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator or not def.clip then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = def.clip
	local track = animator:LoadAnimation(animation)
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = def.loop == true
	track:Play(0.2)
	return track
end

-- Keeps a replicated clip stopped on this client for as long as the emote lasts.
local function suppressClip(player: Player, clip: string, entry: Playing)
	task.spawn(function()
		local elapsed = 0
		while entry.suppress and elapsed < SUPPRESS_MAX do
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
			if animator then
				for _, track in animator:GetPlayingAnimationTracks() do
					if track.Animation and track.Animation.AnimationId == clip then
						track:Stop(0)
					end
				end
			end
			task.wait(SUPPRESS_EVERY)
			elapsed += SUPPRESS_EVERY
		end
	end)
end

local function stopFor(userId: number)
	local entry = playing[userId]
	if not entry then
		return
	end
	playing[userId] = nil
	entry.suppress = false
	if entry.stopFx then
		entry.stopFx()
	end
	if entry.track then
		entry.track:Stop(0.2)
		entry.track:Destroy()
	end
	local player = Players:GetPlayerByUserId(userId)
	if player and player.Character then
		EmotePoses.stop(player.Character)
	end
end

local function onCue(cue: any)
	if typeof(cue) ~= "table" or typeof(cue.u) ~= "number" then
		return
	end
	stopFor(cue.u)
	if not cue.on then
		return
	end
	local def = Emotes.byId[cue.id]
	local player = Players:GetPlayerByUserId(cue.u)
	local character = player and player.Character
	if not def or not player or not character then
		return
	end
	local entry: Playing = {}
	playing[cue.u] = entry
	if cue.hide then
		if def.clip then
			entry.suppress = true
			suppressClip(player, def.clip, entry)
		end
		return
	end
	if def.clip and player == localPlayer then
		entry.track = playOwnClip(def)
	end
	if def.pose then
		EmotePoses.start(character, def.pose)
	end
	if def.flourish then
		entry.stopFx = EmoteFx.play(def.flourish, cue.u, character)
	end
end

-- ─── The wheel ──────────────────────────────────────────────────────────────

local wheel: ScreenGui? = nil
local slices: { TextButton } = {}
local hovered = 0
local hoverConnection: RBXScriptConnection? = nil

local function closeWheel()
	if hoverConnection then
		hoverConnection:Disconnect()
		hoverConnection = nil
	end
	if wheel then
		wheel:Destroy()
		wheel = nil
	end
	table.clear(slices)
	hovered = 0
end

local function paint(index: number)
	for i, slice in slices do
		slice.BackgroundColor3 = if i == index then Theme.color.accent else Theme.color.panel
		slice.TextColor3 = if i == index then Theme.color.bg else Theme.color.ink
	end
end

local function openWheel()
	closeWheel()
	local gui: ScreenGui = Kit.create(nil, "ScreenGui", {
		Name = "EmoteWheel",
		ResetOnSpawn = false,
		IgnoreGuiInset = true,
		DisplayOrder = 8,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
	})
	-- Modal frees the mouse, even in first person or shift-lock, while the wheel is open.
	local backdrop: TextButton = Kit.create(nil, "TextButton", {
		Text = "",
		AutoButtonColor = false,
		Modal = true,
		BackgroundColor3 = Theme.color.backdrop,
		BackgroundTransparency = 0.7,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	backdrop.Activated:Connect(closeWheel)

	local count = #Emotes.list
	for i, def in Emotes.list do
		local angle = (i - 1) / count * 2 * math.pi - math.pi / 2
		local slice = C.button(def.glyph .. "  " .. def.label, function()
			EmoteController:request(def.id)
			closeWheel()
		end, { kind = "ghost" }, {
			AnchorPoint = Vector2.new(0.5, 0.5),
			Position = UDim2.new(0.5, math.cos(angle) * WHEEL_RADIUS, 0.5, math.sin(angle) * WHEEL_RADIUS),
			Size = UDim2.fromOffset(SLICE_SIZE.X, SLICE_SIZE.Y),
			Parent = backdrop,
		})
		table.insert(slices, slice)
	end
	C.text("Emotes", "label", {
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.fromOffset(120, 0),
		TextXAlignment = Enum.TextXAlignment.Center,
		Parent = backdrop,
	})
	gui.Parent = localPlayer:WaitForChild("PlayerGui")
	wheel = gui

	hoverConnection = RunService.RenderStepped:Connect(function()
		if not backdrop.Parent then
			return
		end
		local mouse = UserInputService:GetMouseLocation()
		local center = backdrop.AbsolutePosition + backdrop.AbsoluteSize / 2
		local offset = mouse - center
		local index = 0
		if offset.Magnitude >= DEAD_ZONE then
			local angle = math.atan2(offset.Y, offset.X) + math.pi / 2
			index = math.floor((angle / (2 * math.pi)) * count + 0.5) % count + 1
		end
		if index ~= hovered then
			hovered = index
			paint(index)
		end
	end)
end

local function releaseWheel()
	if not wheel then
		return
	end
	local def = Emotes.list[hovered]
	closeWheel()
	if def then
		EmoteController:request(def.id)
	end
end

-- ─── Chat commands ──────────────────────────────────────────────────────────

local function makeChatCommands()
	if TextChatService.ChatVersion ~= Enum.ChatVersion.TextChatService then
		return
	end
	local folder = Instance.new("Folder")
	folder.Name = "EmoteCommands"
	for _, def in Emotes.list do
		local command = Instance.new("TextChatCommand")
		command.Name = "Emote_" .. def.id
		command.PrimaryAlias = "/" .. def.command
		command.Triggered:Connect(function()
			EmoteController:request(def.id)
		end)
		command.Parent = folder
	end
	folder.Parent = TextChatService
end

-- ─── Touch button ───────────────────────────────────────────────────────────

local function buildLayer(_scope: Kit.Scope, root: Frame)
	if interface.inputMode:get() ~= "Touch" then
		return
	end
	local button = C.button("Emotes", function()
		if wheel then
			closeWheel()
		else
			openWheel()
		end
	end, { kind = "ghost" }, {
		AnchorPoint = Vector2.new(0, 0.5),
		Position = UDim2.new(0, Theme.space.m, 0.62, 0),
		Size = UDim2.fromOffset(84, Theme.minTouch),
	})
	button.Parent = root
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function EmoteController.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	interface:registerLayer({ id = "EmoteButton", build = buildLayer })
end

function EmoteController.start(_self: any, _ctx: any)
	Net.listen("EmoteCue", onCue)
	pcall(makeChatCommands)
	UserInputService.InputBegan:Connect(function(input, processed)
		if not processed and not interface:isInputBlocked() and Controls.matches("emote_wheel", input) then
			openWheel()
		end
	end)
	UserInputService.InputEnded:Connect(function(input)
		if Controls.matches("emote_wheel", input) then
			releaseWheel()
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		stopFor(player.UserId)
	end)
end

return EmoteController
