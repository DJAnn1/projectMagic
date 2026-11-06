--!strict
--[[
	StaminaService: every player's stamina (docs/Items.md §10). Server-owned; clients only read it.

	POOL     max = the stat sheet's staminaMax (InventoryService); a new body starts full.
	REGEN    after regenDelay seconds without spending, regenPerSecond x (1 + staminaRegenPct).
	         Encumbrance already lowers staminaRegenPct in the sheet (StatCalc step 8), so a heavy
	         pack recovers slower; at -100% it doesn't recover at all.
	SPENDERS weapon swings and shots (WeaponService), weapon blocks (GuardService), a bow held past
	         its full draw (WeaponService). The survival and movement stage adds sprinting,
	         climbing and swimming on the same API.
	REPLICATION  Player attributes "Stamina" and "StaminaMax" (whole numbers, written only when
	         they change, at most 10 times a second). The HUD reads them.

	API
		get(player) -> (current, max)
		spend(player, amount) -> boolean     all or nothing (an attack you can't afford is refused)
		drain(player, amount) -> number      takes what's there (blocks, holding a draw); returns
		                                     what's left
		set(player, value)                   admin / tests
		setInfinite(player, on)              admin: never runs out
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local WeaponRules = require(Shared.Items.WeaponRules)

local T = WeaponRules.data.stamina
local TICK = 0.1
local DEFAULT_MAX = 100

local StaminaService = {
	name = "StaminaService",
	dependencies = { "InventoryService", "AdminService" },
}

type State = { current: number, lastSpend: number, infinite: boolean }

local inventory: any = nil
local states: { [Player]: State } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function maxOf(player: Player): number
	local sheet = inventory:sheet(player)
	local max = sheet and sheet.final.staminaMax
	return if typeof(max) == "number" and max > 0 then max else DEFAULT_MAX
end

local function regenOf(player: Player): number
	local sheet = inventory:sheet(player)
	local pct = sheet and sheet.final.staminaRegenPct or 0
	return T.regenPerSecond * math.max(0, 1 + pct)
end

local function stateOf(player: Player): State
	local s = states[player]
	if not s then
		s = { current = maxOf(player), lastSpend = 0, infinite = false }
		states[player] = s
	end
	return s
end

local function publish(player: Player, s: State, max: number)
	local current = math.floor(s.current + 0.5)
	local whole = math.floor(max + 0.5)
	if player:GetAttribute("Stamina") ~= current then
		player:SetAttribute("Stamina", current)
	end
	if player:GetAttribute("StaminaMax") ~= whole then
		player:SetAttribute("StaminaMax", whole)
	end
end

local function step(dt: number)
	local t = now()
	for player, s in states do
		if player.Character and player.Character:GetAttribute("TimeFrozen") then
			continue -- frozen in a Timestop: it doesn't refill either
		end
		local max = maxOf(player)
		if s.infinite then
			s.current = max
		elseif s.current > max then
			s.current = max -- gear came off
		elseif s.current < max and t - s.lastSpend >= T.regenDelay then
			s.current = math.min(max, s.current + regenOf(player) * dt)
		end
		publish(player, s, max)
	end
end

-- ─── API ────────────────────────────────────────────────────────────────────

function StaminaService.get(_self: any, player: Player): (number, number)
	local s = stateOf(player)
	return s.current, maxOf(player)
end

function StaminaService.spend(_self: any, player: Player, amount: number): boolean
	local s = stateOf(player)
	if s.infinite or amount <= 0 then
		return true
	end
	if s.current < amount then
		return false
	end
	s.current -= amount
	s.lastSpend = now()
	publish(player, s, maxOf(player))
	return true
end

function StaminaService.drain(_self: any, player: Player, amount: number): number
	local s = stateOf(player)
	if s.infinite or amount <= 0 then
		return s.current
	end
	s.current = math.max(0, s.current - amount)
	s.lastSpend = now()
	publish(player, s, maxOf(player))
	return s.current
end

function StaminaService.set(_self: any, player: Player, value: number)
	local s = stateOf(player)
	s.current = math.clamp(value, 0, maxOf(player))
	publish(player, s, maxOf(player))
end

function StaminaService.setInfinite(_self: any, player: Player, on: boolean)
	stateOf(player).infinite = on
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "stamina", category = "Items", description = "Show a player's stamina, or set it",
		args = {
			{ name = "player", type = "player", default = "me" },
			{ name = "value", type = "number", min = 0, max = 1000, optional = true },
		},
		handler = function(_, a)
			if a.value then
				StaminaService:set(a.player, a.value)
			end
			local current, max = StaminaService:get(a.player)
			return string.format("%s: stamina %d / %d%s", a.player.Name, current, max, if stateOf(a.player).infinite then " (infinite)" else "")
		end,
	})
	admin:Register({
		name = "infstamina", category = "Items", description = "Infinite stamina on or off (weapon testing)",
		args = { { name = "player", type = "player", default = "me" }, { name = "on", type = "boolean", default = true } },
		handler = function(_, a)
			StaminaService:setInfinite(a.player, a.on)
			return string.format("%s: infinite stamina %s", a.player.Name, if a.on then "on" else "off")
		end,
	})
end

function StaminaService.init(_self: any, ctx: any)
	inventory = ctx.get("InventoryService")
	registerAdmin(ctx.get("AdminService"))
end

function StaminaService.start(_self: any, _ctx: any)
	local function track(player: Player)
		player.CharacterAdded:Connect(function()
			local s = stateOf(player)
			s.current = maxOf(player) -- a new body starts rested
			s.lastSpend = 0
		end)
		stateOf(player)
	end
	for _, player in Players:GetPlayers() do
		track(player)
	end
	Players.PlayerAdded:Connect(track)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)

	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= TICK then
			step(elapsed)
			elapsed = 0
		end
	end)
end

return StaminaService
