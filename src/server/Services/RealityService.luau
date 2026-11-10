--!strict
--[[
	RealityService: runs Cast/RealityRuntime (docs/Reality.md): installs its hooks after Time's and
	Gravity's (so they chain, not replace), steps it every frame, and puts every unmade part back and
	every polymorph away on shutdown.

	No keys and no remote: every Reality power is an ordinary cast.
	Flag: reality_powers_enabled. Off, new casts are refused before payment; what's running finishes.
	Admin: realitystate.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Server = script.Parent.Parent
local RealityRuntime = require(Server.Magic.Cast.RealityRuntime)

local RealityService = {
	name = "RealityService",
	-- TimeService and GravityService set the damage and projectile hooks this one wraps.
	dependencies = { "AdminService", "EffectRunner", "TimeService", "GravityService" },
}

function RealityService.init(_self: any, ctx: any)
	RealityRuntime.start(ctx.get("EffectRunner"), ctx.log)
	ctx.get("AdminService"):Register({
		name = "realitystate",
		category = "Spells",
		description = "What Reality is doing on this server: luck, edicts, unmade parts, conjured shapes, polymorphs",
		args = {},
		handler = function()
			return RealityRuntime.report()
		end,
	})
end

function RealityService.start(_self: any, _ctx: any)
	RunService.Heartbeat:Connect(RealityRuntime.step)
	Players.PlayerRemoving:Connect(RealityRuntime.forget)
	game:BindToClose(RealityRuntime.restoreAll)
end

return RealityService
