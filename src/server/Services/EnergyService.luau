--!strict
--[[
	EnergyService: runs Cast/EnergyRuntime (Energy's spells, docs/DomainIdeas.md "Energy"). Steps what's
	running every frame (wisps and puppets follow smoothly; ticks keep their own clocks), wraps
	Delivery.interceptor last (after Gravity, Reality and Space) so an Ice Mirror, a Heat Haze or a Repulse
	has the first say on a bolt passing it, and hears who hurt whom (kindled hands, the shadow puppet).

	Flag `energy_arts_enabled`. Admin `energy` (what's running), `energyclear [player]`.
]]

local RunService = game:GetService("RunService")

local Server = script.Parent.Parent
local EnergyRuntime = require(Server.Magic.Cast.EnergyRuntime)
local Delivery = require(Server.Magic.Cast.Delivery)

local EnergyService = {
	name = "EnergyService",
	-- After Space: its interceptor (which wraps Gravity's and Reality's) is in place, so ours wraps it.
	dependencies = { "AdminService", "EffectRunner", "SpaceService" },
}

function EnergyService.init(_self: any, ctx: any)
	EnergyRuntime.start(ctx.log)

	local nextIntercept = Delivery.interceptor
	Delivery.interceptor = function(position: Vector3, velocity: Vector3, flight: Delivery.Flight): (string?, any)
		local action, value = EnergyRuntime.intercept(position, velocity, flight)
		if action then
			return action, value
		end
		if nextIntercept then
			return nextIntercept(position, velocity, flight)
		end
		return nil, nil
	end

	local admin = ctx.get("AdminService")
	admin:Register({
		name = "energy",
		category = "Magic",
		description = "Energy's spells running now: rings, fences, burning ground, wisps, puppets, tethers (seconds left)",
		args = {},
		handler = function(_c: any, _a: any)
			return EnergyRuntime.report()
		end,
	})
	admin:Register({
		name = "energyclear",
		category = "Magic",
		description = "End every running Energy spell (or one player's)",
		args = {
			{ name = "player", type = "player", optional = true },
		},
		handler = function(_c: any, a: any)
			local target: Player? = a.player
			return string.format("ended %d", EnergyRuntime.clear(if target then target.UserId else nil))
		end,
	})
end

function EnergyService.start(_self: any, _ctx: any)
	RunService.Heartbeat:Connect(function(dt: number)
		EnergyRuntime.step(dt)
	end)
end

return EnergyService
