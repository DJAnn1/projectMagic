--!strict
--[[
	MomentsClient: Surge and borrowed power, from the player's side (docs/Moments.md). The server decides
	everything; this reads Player and character attributes and sends intents.

	SURGE     A bar over the hotbar: SurgeMeter from the server. K transforms when it's full, and K again
	          is the finisher. Every player who's surging gets an aura (Fx/SurgeFx), from the character
	          attribute SurgeDomain. The bar reads in words as well as length: colour is never the only cue.
	BORROWED  While a relic lasts (BorrowedPower, BorrowedUntil), a panel lists its three powers, on 9, 0
	          and -, with what each does and the time left. Buttons work for touch and gamepad too.

	Budget: one 5 Hz loop for the labels. Aura work happens only when an attribute changes.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local Controls = require(Shared.UI.Controls)
local BorrowedPowers = require(Shared.Magic.Data.BorrowedPowers)
local Rules = require(Shared.Magic.SurgeRules)

local Client = script.Parent.Parent
local UI = Client:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)
local SurgeFx = require(Client:WaitForChild("Fx"):WaitForChild("SurgeFx"))

local UPDATE_SECONDS = 0.2
local AIM_RANGE = 1000
local KEYS = { "borrowed_1", "borrowed_2", "borrowed_3" }

local MomentsClient = {
	name = "MomentsClient",
	dependencies = { "InterfaceController" },
}

local interface: any = nil
local localPlayer = Players.LocalPlayer

local meter = Kit.value(0)
local surgeLine = Kit.value("")
local showSurge = Kit.value(false)
local relicId = Kit.value("")
local relicLine = Kit.value("")

local function serverNow(): number
	return workspace:GetServerTimeNow()
end

-- Where you're looking, and whoever's there.
local function aimAt(): (Vector3?, Model?)
	local camera = workspace.CurrentCamera
	if not camera then
		return nil, nil
	end
	local ray
	if UserInputService.MouseEnabled then
		local mouse = UserInputService:GetMouseLocation()
		ray = camera:ViewportPointToRay(mouse.X, mouse.Y)
	else
		ray = camera:ViewportPointToRay(camera.ViewportSize.X / 2, camera.ViewportSize.Y / 2)
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = if localPlayer.Character then { localPlayer.Character } else {}
	local hit = workspace:Raycast(ray.Origin, ray.Direction * AIM_RANGE, params)
	if not hit then
		return ray.Origin + ray.Direction * AIM_RANGE, nil
	end
	local model = hit.Instance:FindFirstAncestorOfClass("Model")
	return hit.Position, if model and model:FindFirstChildOfClass("Humanoid") then model else nil
end

local function useBorrowed(index: number)
	if relicId:get() == "" then
		return
	end
	local aim, target = aimAt()
	if aim then
		Net.send("BorrowedCast", index, aim, target)
	end
end

local function surge()
	Net.send("SurgeIntent")
end

-- ─── Keeping the labels current ─────────────────────────────────────────────

local function update()
	local t = serverNow()
	local value = localPlayer:GetAttribute("SurgeMeter")
	local filled = if typeof(value) == "number" then value else 0
	meter:set(filled)

	local character = localPlayer.Character
	local domain = character and character:GetAttribute("SurgeDomain")
	if typeof(domain) == "string" then
		local untilTime = character and character:GetAttribute("SurgeUntil")
		local left = if typeof(untilTime) == "number" then math.max(0, math.ceil(untilTime - t)) else 0
		surgeLine:set(string.format("✦ SURGING: %d s · K: %s", left, Rules.finisherFor(domain).name))
		showSurge:set(true)
	elseif filled >= 1 then
		surgeLine:set("✦ Surge ready · press K")
		showSurge:set(true)
	elseif filled > 0 then
		surgeLine:set(string.format("Surge %d%%", math.floor(filled * 100)))
		showSurge:set(true)
	else
		showSurge:set(false)
	end

	local id = localPlayer:GetAttribute("BorrowedPower")
	relicId:set(if typeof(id) == "string" then id else "")
	local untilBorrowed = localPlayer:GetAttribute("BorrowedUntil")
	relicLine:set(if typeof(untilBorrowed) == "number" then string.format("%d s left", math.max(0, math.ceil(untilBorrowed - t))) else "")
end

-- ─── The interface ──────────────────────────────────────────────────────────

local function buildLayer(scope: Kit.Scope, root: Frame)
	Kit.dynamic(scope, { showSurge }, function(s)
		if not showSurge:get() then
			return
		end
		local holder: Frame = Kit.create(nil, "Frame", {
			Name = "SurgeBar",
			BackgroundTransparency = 1,
			AnchorPoint = Vector2.new(0.5, 1),
			Position = UDim2.new(0.5, 0, 1, -(Theme.minTouch * 3.6)),
			Size = UDim2.fromOffset(240, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = root,
		})
		s:add(holder)
		C.list("y", 2).Parent = holder
		local label = C.text(surgeLine:get(), "caption", {
			TextXAlignment = Enum.TextXAlignment.Center,
			TextStrokeTransparency = 0.4,
			LayoutOrder = 1,
			Parent = holder,
		})
		s:add(surgeLine:observe(function(text: string)
			label.Text = text
		end))
		local bar = C.bar(s, meter, Theme.color.accent, 6)
		bar.LayoutOrder = 2
		bar.Parent = holder
		if UserInputService.TouchEnabled or UserInputService.GamepadEnabled then
			C.button("✦ Surge", surge, { kind = "primary" }, { Size = UDim2.new(1, 0, 0, Theme.minTouch), LayoutOrder = 3 }).Parent = holder
		end
	end)

	Kit.dynamic(scope, { relicId }, function(s)
		local relic = BorrowedPowers.relics[relicId:get()]
		if not relic then
			return
		end
		local panel = C.panel({
			Name = "BorrowedPanel",
			BackgroundTransparency = Theme.glass,
			AnchorPoint = Vector2.new(1, 0.5),
			Position = UDim2.new(1, -Theme.space.m, 0.5, 0),
			Size = UDim2.fromOffset(300, 0),
			AutomaticSize = Enum.AutomaticSize.Y,
			Parent = root,
		})
		s:add(panel)
		C.padding(Theme.space.m).Parent = panel
		C.list("y", Theme.space.xs).Parent = panel
		C.text(relic.name, "heading", { LayoutOrder = 1, Parent = panel })
		local left = C.text(relicLine:get(), "caption", { LayoutOrder = 2, Parent = panel })
		s:add(relicLine:observe(function(text: string)
			left.Text = text
		end))
		for i, ability in relic.abilities do
			local name = Controls.byId[KEYS[i]]
			local key = if name and name.keyboard then Controls.display(name.keyboard[1]) else tostring(i)
			C.button(string.format("%s %s  [%s]", ability.glyph, ability.name, key), function()
				useBorrowed(i)
			end, { kind = "primary" }, { Size = UDim2.new(1, 0, 0, Theme.minTouch), LayoutOrder = 10 + i * 2 }).Parent = panel
			C.text(ability.text, "caption", { LayoutOrder = 11 + i * 2, Parent = panel })
		end
	end)
end

-- ─── Everyone's aura ────────────────────────────────────────────────────────

local function watchCharacter(character: Model)
	local function changed()
		local domain = character:GetAttribute("SurgeDomain")
		if typeof(domain) == "string" then
			SurgeFx.aura(character, domain)
		else
			SurgeFx.clearAura(character)
		end
	end
	character:GetAttributeChangedSignal("SurgeDomain"):Connect(changed)
	character.Destroying:Connect(function()
		SurgeFx.clearAura(character)
	end)
	changed()
end

local function watchPlayer(player: Player)
	player.CharacterAdded:Connect(watchCharacter)
	if player.Character then
		watchCharacter(player.Character)
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function MomentsClient.init(_self: any, ctx: any)
	interface = ctx.get("InterfaceController")
	interface:registerLayer({ id = "Moments", build = buildLayer })
end

function MomentsClient.start(_self: any, _ctx: any)
	UserInputService.InputBegan:Connect(function(input, processed)
		if processed or interface:isInputBlocked() then
			return
		end
		if Controls.matches("surge", input) then
			surge()
		else
			for i, id in KEYS do
				if Controls.matches(id, input) then
					useBorrowed(i)
				end
			end
		end
	end)
	Players.PlayerAdded:Connect(watchPlayer)
	for _, player in Players:GetPlayers() do
		watchPlayer(player)
	end
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= UPDATE_SECONDS then
			elapsed = 0
			update()
		end
	end)
end

return MomentsClient
