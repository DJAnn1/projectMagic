--!strict
--[[
	SpaceService: runs Cast/SpaceRuntime (docs/Space.md, stage 1). Steps gates, seals and strides at 10 Hz,
	wraps Delivery.interceptor after Gravity's and Reality's (so a bolt meets a gate before a bend or an
	edict), and ends a Folding Stride the moment its strider hurts someone.

	Flag `space_powers_enabled`. Admin `space` (what's open), `spaceclear` (close every gate),
	`dislocate [player]` (Space's backfire on someone). Log `space_gate_opened`, `space_gate_closed`.
]]

local RunService = game:GetService("RunService")

local Net = require(game:GetService("ReplicatedStorage").Shared.Net)

local Server = script.Parent.Parent
local SpaceRuntime = require(Server.Magic.Cast.SpaceRuntime)
local Damage = require(Server.Magic.Cast.Damage)
local Inventory = require(Server.Items.Inventory)

local SpaceService = {
	name = "SpaceService",
	-- After Gravity and Reality: their interceptors are in place, so ours wraps them.
	dependencies = { "AdminService", "ContainerService", "EffectRunner", "GravityService", "MapService", "PartyService", "PlayerDataService", "RealityService", "WorldStateService" },
}

local STEP = 0.1

function SpaceService.init(_self: any, ctx: any)
	SpaceRuntime.start(ctx.get("EffectRunner"), ctx.log)
	SpaceRuntime.world = ctx.get("WorldStateService")
	local map = ctx.get("MapService")
	SpaceRuntime.seenHook = function(player: Player, x: number, z: number): boolean
		return map:hasSeen(player, x, z)
	end
	-- Stage 2: party mates come along on a Grandmaster recall; the pocket is your saved data.spacePocket.
	local parties = ctx.get("PartyService")
	local playerData = ctx.get("PlayerDataService")
	local containers = ctx.get("ContainerService")
	SpaceRuntime.matesHook = function(player: Player): { Player }
		return parties:matesOf(player)
	end
	SpaceRuntime.pocketHook = function(player: Player, slots: number, seconds: number): (boolean, string?)
		local state = playerData:get(player)
		if not state then
			return false, "Your pocket won't open yet."
		end
		local pocket = Inventory.normalize(state.data.spacePocket)
		-- It grows with you and never shrinks: what's already in it stays.
		pocket.cap = math.max(pocket.cap or 0, slots)
		state.data.spacePocket = pocket
		local ok = containers:openPocket(player, pocket, seconds)
		return ok, if ok then nil else "Your pocket won't open here."
	end
	-- Your map waypoint: a long gate's far end opens there (docs/Space.md).
	Net.on("MapWaypoint", function(player: Player, point: Vector3?)
		SpaceRuntime.setWaypoint(player, point)
	end)

	-- Hurting someone lets go of the fold.
	Damage.listenAttacked(function(_victim: Humanoid, attacker: Model)
		if typeof(attacker) == "Instance" and attacker:IsA("Model") then
			local humanoid = attacker:FindFirstChildOfClass("Humanoid")
			if humanoid and SpaceRuntime.isStriding(humanoid) then
				SpaceRuntime.endStride(humanoid)
			end
		end
	end)

	local admin = ctx.get("AdminService")
	admin:Register({
		name = "space",
		category = "Magic",
		description = "Space's powers running now: gates (with seconds left), sealed and striding bodies",
		args = {},
		handler = function(_c: any, _a: any)
			return SpaceRuntime.report()
		end,
	})
	admin:Register({
		name = "spaceclear",
		category = "Magic",
		description = "Close every Space gate on the server",
		args = {},
		handler = function(_c: any, _a: any)
			return string.format("closed %d gates", SpaceRuntime.closeGates(nil, nil, nil))
		end,
	})
	admin:Register({
		name = "dislocate",
		category = "Magic",
		description = "Space's backfire on a player: thrown some studs in a random direction, sometimes from above",
		args = {
			{ name = "player", type = "player", default = "me" },
			{ name = "studs", type = "number", min = 4, max = 40, default = 16 },
		},
		handler = function(c: any, a: any)
			local target: Player = a.player or c.player
			local character = target.Character
			if not character then
				return "no character"
			end
			local ok = SpaceRuntime.dislocate(character, a.studs, Random.new())
			return if ok then "dislocated " .. target.Name else "nowhere to land"
		end,
	})
end

function SpaceService.start(_self: any, _ctx: any)
	local acc = 0
	RunService.Heartbeat:Connect(function(dt: number)
		acc += dt
		if acc < STEP then
			return
		end
		local elapsed = acc
		acc = 0
		local ok, err = pcall(SpaceRuntime.step, elapsed)
		if not ok then
			warn("[Space] step failed: " .. tostring(err))
		end
	end)
end

return SpaceService
