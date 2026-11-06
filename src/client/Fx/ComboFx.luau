--!strict
--[[
	ComboFx: what a combo looks like (docs/Social.md §4). Two cues, from Services/ComboService:

		combo        { combo, a, b, radius, power, position, lod }
		             The eruption, and a banner naming the combo and the two casters. Everyone in
		             range sees the eruption; the banner shows at near and mid LOD.
		combo_ready  { combo, position, need, from }  sent only to a partner who can finish it:
		             a ring where the spell landed, and a line saying what to cast there.

	The banner is words first, not colour alone. Reduce motion drops its slide; Reduce spell effects
	lowers particles through SpellFx.quality and removes the shake (SpellFx.shake checks it).
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Combos = require(Shared.Social.Data.Combos)

local Audio = require(script.Parent.Parent:WaitForChild("Audio").Audio)
local FxLayers = require(script.Parent.FxLayers)
local Recipes = require(script.Parent.FxRecipes)
local SpellFx = require(script.Parent.SpellFx)

local UI = script.Parent.Parent:WaitForChild("UI")
local Theme = require(UI.Theme)

local BANNER_SECONDS = 2.6
local READY_LINE_SECONDS = 2.5
local SHAKE_RANGE = 80

local ComboFx = {}

local gui: ScreenGui? = nil
local bannerToken = 0

local function screen(): ScreenGui
	local existing = gui
	if existing and existing.Parent then
		return existing
	end
	local created = Instance.new("ScreenGui")
	created.Name = "ComboBanner"
	created.ResetOnSpawn = false
	created.DisplayOrder = 7
	created.Parent = Players.LocalPlayer:WaitForChild("PlayerGui")
	gui = created
	return created
end

local function nameOf(userId: any): string
	local player = typeof(userId) == "number" and Players:GetPlayerByUserId(userId) or nil
	return if player then player.DisplayName else "Someone"
end

local function clearBanner(root: ScreenGui)
	local old = root:FindFirstChild("Banner")
	if old then
		old:Destroy()
	end
end

local function makeLabel(parent: Instance, text: string, size: number, color: Color3, order: number)
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Text = text
	label.TextSize = size
	label.TextColor3 = color
	label.FontFace = Theme.font.title
	label.TextStrokeTransparency = 0.3
	label.Size = UDim2.new(1, 0, 0, size + 6)
	label.LayoutOrder = order
	label.Parent = parent
end

-- A title and a line under it, high in the middle of the screen. A newer banner replaces it.
local function showBanner(title: string, line: string, color: Color3, seconds: number, big: boolean)
	local root = screen()
	clearBanner(root)
	bannerToken += 1
	local token = bannerToken

	local holder = Instance.new("Frame")
	holder.Name = "Banner"
	holder.BackgroundTransparency = 1
	holder.AnchorPoint = Vector2.new(0.5, 0)
	holder.Position = UDim2.fromScale(0.5, 0.2)
	holder.Size = UDim2.fromOffset(620, 90)
	local list = Instance.new("UIListLayout")
	list.HorizontalAlignment = Enum.HorizontalAlignment.Center
	list.SortOrder = Enum.SortOrder.LayoutOrder
	list.Parent = holder
	if title ~= "" then
		makeLabel(holder, title, if big then 42 else 28, color, 1)
	end
	makeLabel(holder, line, 18, Theme.color.ink, 2)
	holder.Parent = root

	if not Theme.settings.reducedMotion then
		holder.Position = UDim2.fromScale(0.5, 0.17)
		TweenService:Create(holder, TweenInfo.new(0.2, Enum.EasingStyle.Back, Enum.EasingDirection.Out), { Position = UDim2.fromScale(0.5, 0.2) }):Play()
	end
	task.delay(seconds, function()
		if token == bannerToken and holder.Parent then
			holder:Destroy()
		end
	end)
end

function ComboFx.play(cue: { [string]: any })
	local combo = Combos.byId[cue.combo]
	local position: any = cue.position
	if not combo or typeof(position) ~= "Vector3" then
		return
	end
	local radius = if typeof(cue.radius) == "number" then math.clamp(cue.radius, 4, 40) else 12
	local lodFactor = if cue.lod == 2 then 1 elseif cue.lod == 1 then 0.5 else 0.25
	local count = SpellFx.quality() * lodFactor
	local style: SpellFx.Style = { primary = combo.primary, secondary = combo.secondary, accent = combo.primary, particle = "motes", motion = "swirling" }
	local tier = Recipes.tiers[6]

	local ground, normal = FxLayers.ground(position, 30)
	local at = ground or position
	local up = normal or Vector3.yAxis
	FxLayers.shockwave(at, up, radius, combo.primary, 0.8)
	FxLayers.flash(at + Vector3.new(0, 2, 0), radius * 0.8, combo.primary, 0.3)
	FxLayers.light(at + Vector3.new(0, 3, 0), combo.primary, 8, radius * 2.5, 1.2)
	SpellFx.burstAt(at, radius * 0.6, style, tier, math.floor(120 * count), { lifetime = 1.3, color = combo.primary, sizeMult = 2, speedMult = 2.5 })
	SpellFx.burstAt(at, radius * 0.7, style, tier, math.floor(70 * count), { lifetime = 1.8, color = combo.secondary, sizeMult = 2.5, speedMult = 1.5 })

	Audio.play("combat.knockdown", { position = at })

	local me = Players.LocalPlayer
	local mine = cue.a == me.UserId or cue.b == me.UserId
	if mine then
		Audio.play("sting.first")
	end
	local root = me.Character and me.Character:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") and (root.Position - at).Magnitude <= SHAKE_RANGE then
		SpellFx.shake(1, 0.6)
	end
	if cue.lod ~= 0 then
		showBanner(string.upper(combo.name), string.format("%s + %s", nameOf(cue.a), nameOf(cue.b)), combo.primary, BANNER_SECONDS, mine)
	end
end

function ComboFx.ready(cue: { [string]: any })
	local combo = Combos.byId[cue.combo]
	local position: any = cue.position
	if not combo or typeof(position) ~= "Vector3" then
		return
	end
	local ground, normal = FxLayers.ground(position, 30)
	FxLayers.shockwave(ground or position, normal or Vector3.yAxis, combo.reach * 0.4, combo.primary, 1.6)
	local need = tostring(cue.need)
	local word = string.upper(string.sub(need, 1, 1)) .. string.sub(need, 2)
	showBanner("", string.format("%s's spell is ready: cast %s there for %s!", nameOf(cue.from), word, combo.name), combo.primary, READY_LINE_SECONDS, false)
end

return ComboFx
