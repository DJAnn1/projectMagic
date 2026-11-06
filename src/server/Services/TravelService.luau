--!strict
--[[
	TravelService: Domain Travel, on the server's side (docs/Travel.md). Numbers: Shared/Magic/Data/TravelTuning.
	Decisions: Shared/Magic/TravelRules. Players own their characters' physics, so the client does the
	moving (Controllers/TravelClient) and this grants it, drains it and checks it, as Flight does.

	GRANT    TravelIntent(true) sets TravelStyle (a domain id) and TravelSpeed on the character, which every
	         client reads. The domain is your readied spell's, or else your best.
	DRAIN    A share of your reservoir per second, less with skill. Empty ends it.
	CHECK    Four times a second: speed and height against what it allowed. Three in a row ends it and
	         logs travel_violation.
	KNOCKED  A hit worth knockShare of your health, a knockdown, being held or frozen, being silenced,
	         or taking flight all end it. After a knock, a short wait before you can set off again.

	Flag: travel_enabled. Admin: travel [on | off] [player], travelstate.
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local Registry = require(Shared.Magic.Registry)
local T = require(Shared.Magic.Data.TravelTuning)
local Rules = require(Shared.Magic.TravelRules)

local Server = script.Parent.Parent
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local WorldConfig = require(Server.World.WorldConfig)
local Progression = require(Server.Progression.Progression)

local TravelService = {
	name = "TravelService",
	dependencies = { "NetService", "AdminService", "PlayerDataService", "ReservoirService", "WorldStateService" },
}

type Riding = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	domain: string,
	tier: number,
	check: number,
	lastPosition: Vector3,
	strikes: number,
}

local log: any = nil
local playerData: any = nil
local reservoirs: any = nil
local world: any = nil

local riding: { [Player]: Riding } = {}
local readyAt: { [Player]: number } = {}

local function clearAttributes(model: Model)
	model:SetAttribute("TravelStyle", nil)
	model:SetAttribute("TravelSpeed", nil)
end

local function stop(player: Player, text: string?, knocked: boolean?)
	local ride = riding[player]
	if not ride then
		return
	end
	riding[player] = nil
	if ride.model.Parent then
		clearAttributes(ride.model)
	end
	if knocked then
		readyAt[player] = os.clock() + T.knockCooldown
	end
	if text and player.Parent then
		Net.fire("Notify", player, text)
	end
end

-- Every domain you know, at your best tier in it.
local function knownDomains(player: Player): { Rules.Known }
	local state = playerData:get(player)
	if not state then
		return {}
	end
	local p = state.data.progression
	local byDomain: { [string]: Rules.Known } = {}
	for branchId in p.unlocked do
		local branch = Registry.branches[branchId]
		if branch then
			local domain = branch.domains[1]
			local tier = (Progression.getMasteryTier(p, branchId))
			local xp = p.xp[branchId] or 0
			local entry = byDomain[domain]
			if not entry then
				byDomain[domain] = { domain = domain, tier = tier, xp = xp }
			else
				entry.tier = math.max(entry.tier, tier)
				entry.xp += xp
			end
		end
	end
	local out: { Rules.Known } = {}
	for _, entry in byDomain do
		table.insert(out, entry)
	end
	return out
end

local function begin(player: Player): string?
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return "You can't set off right now."
	end
	if riding[player] or character:GetAttribute("GravityFlight") or character:GetAttribute("GravityHeld") then
		return nil
	end
	if StatusEffects.blocksCasting(humanoid) or humanoid:GetAttribute("Status_knockdown") ~= nil then
		return "You can't set off right now."
	end
	if os.clock() < (readyAt[player] or 0) then
		return "You're still catching your breath."
	end
	local reservoir = reservoirs:get(player)
	if reservoir and not Rules.canSetOff(reservoir.current, reservoir.max, reservoir.infinite == true) then
		return "Your reservoir is too low to travel."
	end
	local readied = character:GetAttribute("AttunedDomain")
	local domain, tier = Rules.pick(knownDomains(player), if typeof(readied) == "string" then readied else nil)
	riding[player] = {
		model = character,
		humanoid = humanoid,
		root = root,
		domain = domain,
		tier = tier,
		check = 0,
		lastPosition = root.Position,
		strikes = 0,
	}
	character:SetAttribute("TravelSpeed", Rules.speed(domain, tier))
	character:SetAttribute("TravelStyle", domain) -- last: clients read the other when this changes
	return nil
end

local function step(dt: number)
	for player, ride in table.clone(riding) do
		ride.check += dt
		if ride.check < T.checkSeconds then
			continue
		end
		local elapsed = ride.check
		ride.check = 0
		local model, humanoid = ride.model, ride.humanoid
		if not player.Parent or player.Character ~= model or humanoid.Health <= 0 or not ride.root.Parent then
			stop(player)
			continue
		end
		if model:GetAttribute("GravityFlight") then
			stop(player) -- you took to the air: that's a better ride
			continue
		end
		if model:GetAttribute("GravityHeld") or StatusEffects.has(humanoid, "knockdown") or StatusEffects.blocksCasting(humanoid) then
			stop(player, "You've been knocked out of your stride.", true)
			continue
		end
		local reservoir = reservoirs:get(player)
		if reservoir and not reservoir.infinite then
			reservoir.current = math.max(0, reservoir.current - Rules.drainPerSecond(reservoir.max, ride.tier) * elapsed)
			reservoirs:push(player)
			if reservoir.current <= 0 then
				stop(player, "Your reservoir is empty.", true)
				continue
			end
		end
		local position = ride.root.Position
		local speed = (position - ride.lastPosition).Magnitude / math.max(elapsed, 1e-3)
		ride.lastPosition = position
		local height = position.Y - math.max(world:surfaceHeight(position.X, position.Z), WorldConfig.SEA_LEVEL)
		if Rules.violation(ride.domain, ride.tier, speed, height) then
			ride.strikes += 1
			if ride.strikes >= T.strikesToEnd then
				log:warn("travel_violation", { userId = player.UserId, speed = math.floor(speed), height = math.floor(height), domain = ride.domain, tier = ride.tier })
				stop(player, "You lost your stride.")
			end
		else
			ride.strikes = 0
		end
	end
end

local function onDamaged(payload: any)
	local model = payload.model
	local victim = if model then Players:GetPlayerFromCharacter(model) else nil
	if victim and riding[victim] and Rules.knockedOff(payload.amount, payload.humanoid.MaxHealth) then
		stop(victim, "That knocked you out of your stride.", true)
	end
end

function TravelService.init(_self: any, ctx: any)
	log = ctx.log
	playerData = ctx.get("PlayerDataService")
	reservoirs = ctx.get("ReservoirService")
	world = ctx.get("WorldStateService")
	Net.on("TravelIntent", function(player: Player, on: boolean)
		if not on then
			stop(player)
		elseif FeatureFlags.get("travel_enabled") == true then
			local refusal = begin(player)
			if refusal then
				Net.fire("Notify", player, refusal)
			end
		end
	end)
	ctx.bus:subscribe(Topics.TargetDamaged, onDamaged)
	local admin = ctx.get("AdminService")
	admin:Register({
		name = "travel",
		category = "Movement",
		description = "Start or stop a player's Domain Travel",
		args = {
			{ name = "on", type = "boolean", default = true },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_ctx: any, a: any)
			if not a.on then
				stop(a.player)
				return "stopped"
			end
			readyAt[a.player] = nil
			local refusal = begin(a.player)
			if refusal then
				return refusal
			end
			local ride = riding[a.player]
			return if ride then string.format("%s, tier %d, %.0f studs/s", T.styles[ride.domain].name, ride.tier, Rules.speed(ride.domain, ride.tier)) else "not riding"
		end,
	})
	admin:Register({
		name = "travelstate",
		category = "Movement",
		description = "Who's using Domain Travel on this server",
		args = {},
		handler = function()
			local lines = {}
			for player, ride in riding do
				table.insert(lines, string.format("%s: %s, tier %d", player.Name, T.styles[ride.domain].name, ride.tier))
			end
			return if #lines > 0 then table.concat(lines, "\n") else "nobody"
		end,
	})
end

function TravelService.start(_self: any, _ctx: any)
	RunService.Heartbeat:Connect(function(dt)
		local ok, err = pcall(step, dt)
		if not ok then
			log:throttled("travel_step", 30, "Error", "travel_step_failed", { err = err })
		end
	end)
	Players.PlayerRemoving:Connect(function(player)
		riding[player] = nil
		readyAt[player] = nil
	end)
end

return TravelService
