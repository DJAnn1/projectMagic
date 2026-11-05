--!strict
--[[
	GuardService: players raising and lowering their guard (docs/Combat.md §12). The rules live in
	Cast/Guard and Shared/Magic/GuardRules; this is the player-facing side.

	GuardIntent("raise" | "lower")   reliable event, rate 6 burst / 4 per s
		raise   either a spell attuned in equip mode (a ward with its domain's look), or no spell
		        readied and a blocking weapon in the main hand (WeaponRules.canBlock: swords,
		        axes, spears, staves; a "steel" guard). Then: alive, the body free to block
		        (Cast/ActionState), the guard not broken or spent. The parry window opens on the
		        server's clock when this arrives, plus up to latencyAllowanceMax of the player's
		        own ping. Refusals come back as CastResult { stage = "refused", reason }.
		lower   always allowed.
	PRICE      what a ward turns away is also paid from the reservoir (reservoirPerPoint); a weapon
	           guard pays stamina instead (WeaponTuning.stamina.staminaPerBlockPoint). Either one
	           running dry breaks the guard.
	METER      the guard meter attribute is refreshed at 10 Hz while anyone's meter is refilling.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local GuardRules = require(Shared.Magic.GuardRules)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local WeaponRules = require(Shared.Items.WeaponRules)

local Guard = require(script.Parent.Parent.Magic.Cast.Guard)

local T = GuardRules.tuning
local METER_HZ = 10
local STEEL = "steel" -- the "Guarding" look of a weapon block (GuardFxController)

local GuardService = {
	name = "GuardService",
	dependencies = { "NetService", "AttunementService", "ReservoirService", "InventoryService", "StaminaService" },
}

local log: any = nil
local attunement: any = nil
local reservoirs: any = nil
local inventory: any = nil
local stamina: any = nil

local function refuse(player: Player, reason: string)
	Net.fire("CastResult", player, { ok = false, stage = "refused", reason = reason })
end

-- A main-hand weapon that can turn a blow (not broken).
local function weaponCanBlock(player: Player): boolean
	local inv = inventory:inventoryOf(player)
	local rec = inv and inv.equip and inv.equip.mainHand
	return rec ~= nil and not ItemInstance.isBroken(rec) and WeaponRules.canBlock(ItemDatabase.get(rec.i))
end

local function onIntent(player: Player, kind: string)
	local character = player.Character
	if not character then
		return
	end
	if kind == "lower" then
		Guard.lower(character)
		return
	end
	local look: string
	if attunement:equipMode(player) and attunement:attunedKey(player) then
		local domain = character:GetAttribute("AttunedDomain")
		look = if typeof(domain) == "string" then domain else "energy"
	elseif not attunement:attunedKey(player) and weaponCanBlock(player) then
		look = STEEL
	else
		refuse(player, "NOT_ATTUNED")
		return
	end
	local ok, reason = Guard.raise(character, look, {
		latency = Guard.latencyOf(character),
	})
	if not ok then
		refuse(player, reason or "BUSY")
	end
end

-- A player's guard turns damage away at a price: a ward pays reservoir, a weapon pays stamina.
-- Running dry breaks it.
local function onAbsorb(model: Model, absorbed: number)
	local player = Players:GetPlayerFromCharacter(model)
	if player and model:GetAttribute("Guarding") == STEEL then
		local left = stamina:drain(player, absorbed * WeaponRules.data.stamina.staminaPerBlockPoint)
		if left <= 0 and Guard.isGuarding(model) then
			Guard.breakGuard(model)
			log:debug("guard_broken", { userId = player.UserId, why = "stamina" })
		end
		return
	end
	local reservoir = player and reservoirs:get(player)
	if not player or not reservoir then
		return
	end
	reservoir.current = math.max(0, reservoir.current - absorbed * T.reservoirPerPoint)
	reservoirs:push(player)
	if reservoir.current <= 0 and Guard.isGuarding(model) then
		Guard.breakGuard(model)
		log:debug("guard_broken", { userId = player.UserId, why = "reservoir" })
	end
end

function GuardService.init(_self: any, ctx: any)
	log = ctx.log
	attunement = ctx.get("AttunementService")
	reservoirs = ctx.get("ReservoirService")
	inventory = ctx.get("InventoryService")
	stamina = ctx.get("StaminaService")
	Net.on("GuardIntent", onIntent :: any)
	Guard.onAbsorb = onAbsorb
	Guard.onParry = function(model: Model)
		local player = Players:GetPlayerFromCharacter(model)
		log:debug("parried", { who = if player then player.UserId else model.Name })
	end
end

function GuardService.start(_self: any, _ctx: any)
	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		elapsed += dt
		if elapsed >= 1 / METER_HZ then
			elapsed = 0
			Guard.tickMeters()
		end
	end)
end

return GuardService
