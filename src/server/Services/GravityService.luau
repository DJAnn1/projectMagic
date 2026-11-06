--!strict
--[[
	GravityService: runs Cast/GravityRuntime (docs/Gravity.md): steps it every frame, takes the
	client's FlightIntent, and gives admins a way to see it.

	Flag: gravity_powers_enabled. Off, new casts of these powers are refused before payment, and running
	ones finish on their own. Plain gravity fields aren't affected.
	Admin: gravitystate, flightend [player].
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)

local Server = script.Parent.Parent
local GravityRuntime = require(Server.Magic.Cast.GravityRuntime)

local GravityService = {
	name = "GravityService",
	dependencies = { "NetService", "AdminService", "EffectRunner", "WorldStateService" },
}

function GravityService.init(_self: any, ctx: any)
	GravityRuntime.start(ctx.get("EffectRunner"), ctx.get("WorldStateService"), ctx.log)
	Net.on("FlightIntent", function(player: Player, intent: string)
		GravityRuntime.flightIntent(player, intent)
	end)
	local admin = ctx.get("AdminService")
	admin:Register({
		name = "gravitystate",
		category = "Spells",
		description = "What gravity is doing on this server: holds, grips, wells, shields, flyers",
		args = {},
		handler = function()
			return GravityRuntime.report()
		end,
	})
	admin:Register({
		name = "flightend",
		category = "Spells",
		description = "Bring a flying player down",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_ctx: any, a: any)
			if not GravityRuntime.isFlying(a.player) then
				return a.player.Name .. " isn't flying"
			end
			GravityRuntime.flightIntent(a.player, "land")
			return a.player.Name .. " has landed"
		end,
	})
end

function GravityService.start(_self: any, _ctx: any)
	RunService.Heartbeat:Connect(GravityRuntime.step)
	Players.PlayerRemoving:Connect(function(player)
		GravityRuntime.flightIntent(player, "land")
	end)
end

return GravityService
