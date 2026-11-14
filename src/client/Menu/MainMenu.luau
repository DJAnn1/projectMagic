--!strict
--[[
	MainMenu: the title screen and file select, shown before the rest of the client boots
	(src/client/init.client.luau; server side in Services/SaveFileService, docs/SaveFiles.md).

		MainMenu.run()   yields until a save file is loaded (the server sets the Player attribute
		                 "SaveFile"), then hands the camera back and removes itself

	THE SCREEN: the camera drifts slowly round the island's spawn town (no character exists yet),
	under the title and a Play button. Play opens three file cards:
		a played file   its best branch and mastery, spells known, time played, last played;
		                Continue, and Reset (a second step asks you to type RESET)
		an empty file   "a new character": its innate magic is its own, found by playing; Begin
	Text is never the only cue for state: an empty card says so in words, and Reset is set apart.
	Everything here is client-side drawing; the server decides what a file holds and loads it.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local Net = require(Shared.Net)
local Registry = require(Shared.Magic.Registry)

local UI = script.Parent.Parent:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

local MainMenu = {}

-- The game's name (owner, 2026-11-13).
local TITLE = "Project Magic"
local SUBTITLE = "An island where everyone's magic is their own."
local FILES = 3

local REASONS: { [string]: string } = {
	BUSY = "One moment...",
	ALREADY_PLAYING = "That file is already open.",
	IN_GAME = "Return to the main menu before resetting a file.",
	CONFIRM = "Type RESET to confirm.",
	DATASTORE_ERROR = "Your saves couldn't be reached. Try again in a moment.",
	LOCKED = "That file is still open on another server. Try again in a minute.",
}

local function ago(unix: number): string
	if unix <= 0 then
		return "never"
	end
	local s = math.max(0, os.time() - unix)
	if s < 3600 then
		return string.format("%d min ago", math.max(1, math.floor(s / 60)))
	elseif s < 86400 then
		return string.format("%d h ago", math.floor(s / 3600))
	end
	return string.format("%d days ago", math.floor(s / 86400))
end

local function duration(seconds: number): string
	local h = math.floor(seconds / 3600)
	local m = math.floor((seconds % 3600) / 60)
	return if h > 0 then string.format("%d h %d min", h, m) else string.format("%d min", m)
end

local function branchName(id: string): string
	local branch: any = Registry.branches[id]
	return if branch then branch.name else id
end

-- ─── Camera: a slow drift round the spawn town ──────────────────────────────

local function orbit(): () -> ()
	local camera = workspace.CurrentCamera
	camera.CameraType = Enum.CameraType.Scriptable
	local started = os.clock()
	local connection = RunService.RenderStepped:Connect(function()
		local spawn = workspace:FindFirstChild("WorldSpawn")
		local center = if spawn and spawn:IsA("BasePart") then spawn.Position else Vector3.new(0, 60, 0)
		local angle = (os.clock() - started) * 0.035
		local eye = center + Vector3.new(math.cos(angle) * 150, 85, math.sin(angle) * 150)
		camera.CFrame = CFrame.lookAt(eye, center + Vector3.new(0, 10, 0))
	end)
	return function()
		connection:Disconnect()
		camera.CameraType = Enum.CameraType.Custom
	end
end

-- ─── The screen ─────────────────────────────────────────────────────────────

function MainMenu.run()
	local player = Players.LocalPlayer
	if player:GetAttribute("SaveFile") ~= nil then
		return -- already in a file (a client script restart)
	end

	local gui: ScreenGui = Kit.create(nil, "ScreenGui", {
		Name = "MainMenu",
		IgnoreGuiInset = true,
		ResetOnSpawn = false,
		DisplayOrder = 100,
		ZIndexBehavior = Enum.ZIndexBehavior.Sibling,
		Parent = player:WaitForChild("PlayerGui"),
	})
	local stopOrbit = orbit()
	-- A soft vignette so the text reads over a bright sky.
	Kit.create(nil, "Frame", {
		BackgroundColor3 = Theme.color.backdrop,
		BackgroundTransparency = 0.45,
		BorderSizePixel = 0,
		Size = UDim2.fromScale(1, 1),
		Parent = gui,
	})
	local column: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(0.5, 0.5),
		Position = UDim2.fromScale(0.5, 0.5),
		Size = UDim2.new(1, -32, 0, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = gui,
	})
	C.sizeLimit(760, 2000).Parent = column
	C.list("y", Theme.space.l, { HorizontalAlignment = Enum.HorizontalAlignment.Center }).Parent = column

	local body: Frame = Kit.create(nil, "Frame", {
		BackgroundTransparency = 1,
		Size = UDim2.fromScale(1, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		LayoutOrder = 3,
		Parent = column,
	})
	C.text(TITLE, "display", { TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 1, TextSize = 56 }).Parent = column
	C.text(SUBTITLE, "body", { TextXAlignment = Enum.TextXAlignment.Center, TextColor3 = Theme.color.inkDim, LayoutOrder = 2 }).Parent = column
	local status = C.text("", "caption", { TextXAlignment = Enum.TextXAlignment.Center, LayoutOrder = 4 })
	status.Parent = column

	local function clear()
		for _, child in body:GetChildren() do
			child:Destroy()
		end
	end

	local showFiles: () -> ()

	local function showTitle()
		clear()
		C.list("y", Theme.space.s, { HorizontalAlignment = Enum.HorizontalAlignment.Center }).Parent = body
		C.button("Play", showFiles, { kind = "primary" }, { Size = UDim2.fromOffset(220, Theme.minTouch + 8) }).Parent = body
	end

	local function choose(slot: number)
		status.Text = "Waking..."
		local ok, success, reason = Net.invoke("FileChoose", slot)
		if not ok or not success then
			status.Text = REASONS[tostring(reason)] or "That file couldn't be opened. Try again."
		end
		-- On success the server sets "SaveFile" and the wait below ends the menu.
	end

	local function askReset(slot: number, card: Frame)
		for _, child in card:GetChildren() do
			if child:IsA("GuiObject") and child.Name == "Actions" then
				child:Destroy()
			end
		end
		local confirm: Frame = Kit.create(nil, "Frame", {
			Name = "Actions",
			BackgroundTransparency = 1,
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			LayoutOrder = 10,
			Parent = card,
		})
		C.list("y", Theme.space.xs).Parent = confirm
		C.text(string.format("Reset File %d? Its progress, spells, items and house are lost for good. Its innate magic stays the same. Type RESET to confirm.", slot), "caption", { LayoutOrder = 1, TextColor3 = Theme.color.warn }).Parent = confirm
		local box: TextBox = Kit.create(nil, "TextBox", {
			Text = "",
			PlaceholderText = "RESET",
			ClearTextOnFocus = false,
			FontFace = Theme.font.body,
			TextSize = Theme.text("body"),
			TextColor3 = Theme.color.ink,
			PlaceholderColor3 = Theme.color.inkFaint,
			BackgroundColor3 = Theme.color.panelRaised,
			Size = UDim2.new(1, 0, 0, Theme.minTouch),
			LayoutOrder = 2,
			Parent = confirm,
		})
		C.corner().Parent = box
		local row: Frame = Kit.create(nil, "Frame", { BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, Theme.minTouch), LayoutOrder = 3, Parent = confirm })
		C.list("x", Theme.space.s).Parent = row
		C.button("Reset this file", function()
			status.Text = "Resetting..."
			local ok, success, reason = Net.invoke("FileReset", slot, box.Text)
			if ok and success then
				status.Text = string.format("File %d is empty again.", slot)
				showFiles()
			else
				status.Text = REASONS[tostring(reason)] or "The reset didn't go through. Nothing was changed."
			end
		end, { kind = "danger" }, { Size = UDim2.fromOffset(170, Theme.minTouch), LayoutOrder = 1 }).Parent = row
		C.button("Cancel", showFiles, { kind = "ghost" }, { Size = UDim2.fromOffset(110, Theme.minTouch), LayoutOrder = 2 }).Parent = row
	end

	local function card(slot: number, summary: any, isLast: boolean, order: number)
		local frame = C.panel({
			Size = UDim2.fromScale(1, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			BackgroundColor3 = if isLast then Theme.color.panelRaised else Theme.color.panel,
			LayoutOrder = order,
			Parent = body,
		})
		C.padding(Theme.space.m).Parent = frame
		C.list("y", Theme.space.xs).Parent = frame
		C.text(string.format("File %d%s", slot, if isLast then " · last played" else ""), "heading", { LayoutOrder = 1 }).Parent = frame
		local actions: Frame = Kit.create(nil, "Frame", { Name = "Actions", BackgroundTransparency = 1, Size = UDim2.new(1, 0, 0, Theme.minTouch), LayoutOrder = 10, Parent = frame })
		C.list("x", Theme.space.s).Parent = actions
		if summary then
			local best = if summary.best and summary.best ~= "" then string.format("%s, mastery %d", branchName(summary.best), summary.bestMastery or 0) else "No mastery yet"
			C.text(best, "body", { LayoutOrder = 2 }).Parent = frame
			C.text(string.format("%d spells known · %s played · last played %s", summary.spells or 0, duration(summary.playtime or 0), ago(summary.lastPlayed or 0)), "caption", { LayoutOrder = 3 }).Parent = frame
			C.button("Continue", function()
				choose(slot)
			end, { kind = "primary" }, { Size = UDim2.fromOffset(150, Theme.minTouch), LayoutOrder = 1 }).Parent = actions
			C.button("Reset…", function()
				askReset(slot, frame)
			end, { kind = "ghost" }, { Size = UDim2.fromOffset(110, Theme.minTouch), LayoutOrder = 2 }).Parent = actions
		else
			C.text("Empty: a new character. Their innate magic is their own, found by playing.", "caption", { LayoutOrder = 2 }).Parent = frame
			C.button("Begin", function()
				choose(slot)
			end, { kind = "primary" }, { Size = UDim2.fromOffset(150, Theme.minTouch), LayoutOrder = 1 }).Parent = actions
		end
	end

	showFiles = function()
		clear()
		C.list("y", Theme.space.s).Parent = body
		status.Text = "Reading your files..."
		local ok, result = Net.invoke("FileList")
		if not ok or typeof(result) ~= "table" or not result.ok then
			status.Text = "Your files couldn't be read. Try again in a moment."
			C.button("Try again", showFiles, { kind = "ghost" }, { Size = UDim2.fromOffset(160, Theme.minTouch) }).Parent = body
			return
		end
		status.Text = ""
		for slot = 1, FILES do
			local summary = result.files and result.files[slot]
			card(slot, if summary then summary else nil, result.last == slot, slot)
		end
		C.button("Back", showTitle, { kind = "ghost" }, { Size = UDim2.fromOffset(110, Theme.minTouch), LayoutOrder = 99 }).Parent = body
	end

	showTitle()

	-- The server sets "SaveFile" once the chosen file is loaded.
	while player:GetAttribute("SaveFile") == nil do
		player:GetAttributeChangedSignal("SaveFile"):Wait()
	end
	stopOrbit()
	gui:Destroy()
end

return MainMenu
