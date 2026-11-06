--!strict
--[[
	TimeService: runs Cast/TimeRuntime (docs/Time.md): steps it every frame, gives it the cooldowns,
	stamina and dash charges a recall restores, takes the client's TimeIntent, and tells Future Sight
	about casts.

		TimeIntent("recall")        back to your mark
		TimeIntent("release", aim)  marked targets snap back, hanging spells fly

	Flag: time_powers_enabled. Off, new casts are refused before payment; what's running finishes.
	Admin: timestate.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)

local Server = script.Parent.Parent
local TimeRuntime = require(Server.Magic.Cast.TimeRuntime)

local TimeService = {
	name = "TimeService",
	dependencies = { "NetService", "AdminService", "EffectRunner", "CastService", "StaminaService", "MovementService" },
}

function TimeService.init(_self: any, ctx: any)
	local cast = ctx.get("CastService")
	local movement = ctx.get("MovementService")
	TimeRuntime.start(ctx.get("EffectRunner"), ctx.log, {
		cooldownsOf = function(player: Player): { [string]: number }
			return cast:cooldownsOf(player)
		end,
		setCooldowns = function(player: Player, cooldowns: { [string]: number })
			cast:setCooldowns(player, cooldowns)
		end,
		stamina = ctx.get("StaminaService"),
		chargesOf = function(player: Player): number?
			return movement:chargesOf(player)
		end,
		setCharges = function(player: Player, charges: number)
			movement:setCharges(player, charges)
		end,
	})
	Net.on("TimeIntent", function(player: Player, intent: string, aim: Vector3?)
		if intent == "recall" then
			local reason = TimeRuntime.recallSelf(player)
			if reason then
				Net.fire("Notify", player, TimeRuntime.refusalText(reason))
			end
		else
			TimeRuntime.release(player, aim)
		end
	end)
	ctx.bus:subscribe(Topics.SpellCast, function(payload: any)
		TimeRuntime.onSpellCast(payload.casterUserId, payload.point)
	end)
	ctx.get("AdminService"):Register({
		name = "timestate",
		category = "Spells",
		description = "What Time is doing on this server: marks, stops, wounds, loops",
		args = {},
		handler = function()
			return TimeRuntime.report()
		end,
	})
end

function TimeService.start(_self: any, _ctx: any)
	RunService.Heartbeat:Connect(TimeRuntime.step)
	Players.PlayerRemoving:Connect(TimeRuntime.forget)
end

return TimeService
