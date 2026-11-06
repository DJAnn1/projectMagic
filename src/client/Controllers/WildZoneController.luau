--!strict
--[[
	WildZoneController: a wild zone from the player's side (docs/WildZones.md). The server decides where
	you are (Services/WildZoneService); this shows it.

		card   Top right, while you're inside: the zone's name and its rule, and on the Tilting Moor a
		       countdown to the ground letting go, from the same synced clock the server uses.
		tint   A faint colour over the world while you're inside, so you can feel the border. It's a
		       local ColorCorrectionEffect. Reduce spell effects leaves it off.

	The zone's name and rule are words, so colour is never the only cue. There are no intents to send.
	Budget: one Kit.dynamic, and a 5 Hz label only on the zones with a tide.
]]

local Lighting = game:GetService("Lighting")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local W = require(Shared.World.WildZones)

local Client = script.Parent.Parent
local UI = Client:WaitForChild("UI")
local Kit = require(UI.Kit)
local Theme = require(UI.Theme)
local C = require(UI.Components)

local UPDATE_SECONDS = 0.2
local TINT_SECONDS = 1.5
local NEUTRAL = Color3.new(1, 1, 1)

local WildZoneController = {
	name = "WildZoneController",
	dependencies = { "InterfaceController", "MagicStateController" },
}

local magic: any = nil
local tint: ColorCorrectionEffect? = nil

WildZoneController.zone = Kit.value(nil :: string?)

local function tideText(def: W.Zone): string
	local tide = def.tide
	if not tide then
		return ""
	end
	local phase = workspace:GetServerTimeNow() % tide.every
	if phase < tide.lasts then
		return "The ground has let go!"
	end
	return string.format("The ground lets go in %d", math.ceil(tide.every - phase))
end

local function buildLayer(scope: Kit.Scope, root: Frame)
	local holder: Frame = Kit.create(nil, "Frame", {
		Name = "WildZoneCard",
		BackgroundTransparency = 1,
		AnchorPoint = Vector2.new(1, 0),
		Position = UDim2.new(1, -Theme.space.m, 0, 120),
		Size = UDim2.fromOffset(300, 0),
		AutomaticSize = Enum.AutomaticSize.Y,
		Parent = root,
	})
	C.list("y", Theme.space.xs).Parent = holder

	Kit.dynamic(scope, { WildZoneController.zone }, function(s)
		local id = WildZoneController.zone:get()
		local def = if id then W.zones[id] else nil
		if not def then
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
		C.text("❖ " .. def.name, "heading", { LayoutOrder = 1, Parent = card })
		C.text(def.rule, "caption", { LayoutOrder = 2, Parent = card })
		if def.tide then
			local label = C.text(tideText(def), "label", { LayoutOrder = 3, Parent = card })
			local elapsed = 0
			s:add(RunService.Heartbeat:Connect(function(dt)
				elapsed += dt
				if elapsed >= UPDATE_SECONDS then
					elapsed = 0
					label.Text = tideText(def)
				end
			end))
		end
	end)
end

local function setTint(color: Color3)
	local effect = tint
	if not effect then
		effect = Instance.new("ColorCorrectionEffect")
		effect.Name = "WildZoneTint"
		effect.Parent = Lighting
		tint = effect
	end
	TweenService:Create(effect :: ColorCorrectionEffect, TweenInfo.new(TINT_SECONDS), { TintColor = color }):Play()
end

local function setZone(payload: any)
	if typeof(payload) ~= "table" then
		return
	end
	local id = if typeof(payload.id) == "string" then payload.id else nil
	WildZoneController.zone:set(id)
	local def = if id then W.zones[id] else nil
	local reduced = magic.settings:get().reducedEffects == true
	setTint(if def and not reduced then def.tint else NEUTRAL)
end

function WildZoneController.init(_self: any, ctx: any)
	magic = ctx.get("MagicStateController")
	ctx.get("InterfaceController"):registerLayer({ id = "WildZone", build = buildLayer })
end

function WildZoneController.start(_self: any, _ctx: any)
	Net.listen("WildZoneState", setZone)
end

return WildZoneController
