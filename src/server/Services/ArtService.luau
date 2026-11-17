--!strict
--[[
	ArtService: runs Cast/ArtRuntime (the domains' own spells, docs/DomainIdeas.md: Energy, Earth). Steps
	what's running every frame (wisps and puppets follow smoothly; ticks keep their own clocks), wraps
	Delivery.interceptor last (after Gravity, Reality and Space) so an Ice Mirror, a Heat Haze or a Repulse
	has the first say on a bolt passing it, and hears who hurt whom (kindled hands, the shadow puppet).

	Flags `energy_arts_enabled`, `earth_arts_enabled` (read by the resolvers). Admin `arts` (alias `energy`:
	what's running), `artsclear [player]` (alias `energyclear`).
]]

local RunService = game:GetService("RunService")

local Server = script.Parent.Parent
local ArtRuntime = require(Server.Magic.Cast.ArtRuntime)
local Delivery = require(Server.Magic.Cast.Delivery)
local Damage = require(Server.Magic.Cast.Damage)
local WildbornMoves = require(Server.Wildborn.WildbornMoves)

local ArtService = {
	name = "ArtService",
	-- After Space: its interceptor (which wraps Gravity's and Reality's) is in place, so ours wraps it.
	-- After Time and Reality too: Damage.interceptor is theirs first, and ours wraps it (Antimagic Shell).
	dependencies = { "AdminService", "EffectRunner", "SpaceService", "TimeService", "RealityService" },
}

function ArtService.init(_self: any, ctx: any)
	ArtRuntime.start(ctx.log)

	local nextIntercept = Delivery.interceptor
	Delivery.interceptor = function(position: Vector3, velocity: Vector3, flight: Delivery.Flight): (string?, any)
		local action, value = ArtRuntime.intercept(position, velocity, flight)
		if action then
			return action, value
		end
		if nextIntercept then
			return nextIntercept(position, velocity, flight)
		end
		return nil, nil
	end

	-- Wildborn bolts and boulders fly in their own simulation: they ask the same swallowers.
	WildbornMoves.swallower = function(position: Vector3, ownerModel: Model?): boolean
		return ArtRuntime.swallows(position, ownerModel, nil)
	end
	-- ...and the deflectors (Ice Mirror, Heat Haze, Repulse, Windwall) turn them as they turn spell bolts.
	WildbornMoves.deflector = function(position: Vector3, velocity: Vector3, flight: any): (string?, any, number?)
		return ArtRuntime.deflects(position, velocity, flight)
	end

	-- Void's Antimagic Shell: every magic hit (anything with a domain; not weapons, not overdraw) is
	-- softened while it lasts, whoever cast it.
	local nextDamage = Damage.interceptor
	Damage.interceptor = function(humanoid: Humanoid, amount: number, source: number?, kind: string, info: Damage.Info?): number
		local untilAt = humanoid:GetAttribute("AntimagicUntil")
		if typeof(untilAt) == "number" and untilAt > workspace:GetServerTimeNow() and info and info.domain and kind ~= "weapon" and kind ~= "internal" then
			local resist = humanoid:GetAttribute("AntimagicResist")
			amount *= 1 - math.clamp(if typeof(resist) == "number" then resist else 0.3, 0, 0.8)
		end
		if nextDamage then
			return nextDamage(humanoid, amount, source, kind, info)
		end
		return amount
	end

	local admin = ctx.get("AdminService")
	admin:Register({
		name = "arts",
		aliases = { "energy" },
		category = "Magic",
		description = "The domains' lasting spells running now: rings, fences, burning ground, wisps, puppets, tethers, spike walls (seconds left)",
		args = {},
		handler = function(_c: any, _a: any)
			return ArtRuntime.report()
		end,
	})
	admin:Register({
		name = "artsclear",
		aliases = { "energyclear" },
		category = "Magic",
		description = "End every running lasting spell of the domains (or one player's)",
		args = {
			{ name = "player", type = "player", optional = true },
		},
		handler = function(_c: any, a: any)
			local target: Player? = a.player
			return string.format("ended %d", ArtRuntime.clear(if target then target.UserId else nil))
		end,
	})
end

function ArtService.start(_self: any, _ctx: any)
	RunService.Heartbeat:Connect(function(dt: number)
		ArtRuntime.step(dt)
	end)
end

return ArtService
