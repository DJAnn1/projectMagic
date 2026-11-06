--!strict
--[[
	SurgeService: fighting fills a meter, and when it's full you transform (docs/Moments.md).
	Numbers: Shared/Magic/Data/SurgeTuning. Decisions: Shared/Magic/SurgeRules.

	METER     Damage you deal and take fills it. Practice dummies and hurting yourself don't count, and no
	          single hit gives more than maxPerHit. It fades after a while with no fighting.
	SURGE     K with a full meter: the "surging" status (harder hits, resist all, faster), cheaper spells,
	          some health and reservoir back. The domain is the one you've fought with most lately, and
	          the character attributes SurgeDomain and SurgeUntil let every client draw it.
	FINISHER  K again ends it with a blast and that domain's rider. Letting it run out gives no blast.
	Being frozen stops the clock. Dying ends it and empties the meter.

	Remote: SurgeIntent. Player attribute SurgeMeter (0..1). Flag: surge_enabled. Admin: surge fill | end.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local MagicCore = require(Shared.Magic.MagicCore)
local S = require(Shared.Magic.Data.SurgeTuning)
local Rules = require(Shared.Magic.SurgeRules)

local Server = script.Parent.Parent
local Cast = Server.Magic.Cast
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local C = require(Server.Magic.Data.CombatTuning)
local Progression = require(Server.Progression.Progression)

local TICK = 0.25
local TIER_EVERY = 5 -- seconds between working out someone's best tier
local FALLBACK_DOMAIN = "energy"

local SurgeService = {
	name = "SurgeService",
	dependencies = { "NetService", "AdminService", "EffectRunner", "PlayerDataService", "ReservoirService" },
}

type State = {
	meter: number,
	lastFight: number,
	tier: number,
	nextTier: number,
	tally: { [string]: number },
	surging: boolean,
	expires: number,
	domain: string,
	model: Model?,
}

local log: any = nil
local runner: any = nil
local playerData: any = nil
local reservoirs: any = nil
local states: { [Player]: State } = {}

local function stateOf(player: Player): State
	local s = states[player]
	if not s then
		s = { meter = 0, lastFight = 0, tier = 1, nextTier = 0, tally = {}, surging = false, expires = 0, domain = FALLBACK_DOMAIN, model = nil }
		states[player] = s
	end
	return s
end

local function bestTier(player: Player): number
	local state = playerData:get(player)
	if not state then
		return 1
	end
	local p = state.data.progression
	local best = 1
	for branchId in p.unlocked do
		local tier = (Progression.getMasteryTier(p, branchId))
		best = math.max(best, tier)
	end
	return best
end

local function publish(player: Player, s: State)
	-- Whole steps of 2%: no replication for nothing. Rounded down, so "ready" means really full.
	local rounded = math.floor(s.meter * 50) / 50
	if player:GetAttribute("SurgeMeter") ~= rounded then
		player:SetAttribute("SurgeMeter", rounded)
	end
end

local function bodyOf(player: Player): (Model?, Humanoid?, BasePart?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil, nil, nil
	end
	return character, humanoid, root
end

-- ─── The transformation ─────────────────────────────────────────────────────

local function endSurge(player: Player, s: State)
	s.surging = false
	local model = s.model
	s.model = nil
	if model and model.Parent then
		model:SetAttribute("SurgeDomain", nil)
		model:SetAttribute("SurgeUntil", nil)
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if humanoid then
			StatusEffects.remove(humanoid, "surging")
		end
	end
	local reservoir = reservoirs:get(player)
	if reservoir then
		reservoir.costMult = nil
	end
end

local function startSurge(player: Player, s: State, force: boolean?)
	local model, humanoid, root = bodyOf(player)
	if not model or not humanoid or not root or s.surging or (not force and not Rules.ready(s.meter)) then
		return
	end
	local tier = bestTier(player)
	s.tier = tier
	s.meter = 0
	s.surging = true
	s.model = model
	s.domain = Rules.favourite(s.tally, FALLBACK_DOMAIN)
	table.clear(s.tally)
	local seconds = Rules.byTier(S.seconds, tier)
	s.expires = workspace:GetServerTimeNow() + seconds
	StatusEffects.apply(humanoid, "surging", {
		duration = seconds,
		source = player.UserId,
		magnitude = Rules.byTier(S.damage, tier),
		resist = { all = Rules.byTier(S.resist, tier) },
	})
	Damage.heal(humanoid, humanoid.MaxHealth * S.healShare, player.UserId, { domain = s.domain })
	local reservoir = reservoirs:get(player)
	if reservoir then
		reservoir.costMult = Rules.byTier(S.costMult, tier)
		reservoir.current = math.min(reservoir.max, reservoir.current + reservoir.max * S.reservoirShare)
		reservoirs:push(player)
	end
	model:SetAttribute("SurgeUntil", s.expires)
	model:SetAttribute("SurgeDomain", s.domain) -- last: clients read the other when this changes
	publish(player, s)
	runner:cue("surge", { fx = "start", domain = s.domain, caster = player.UserId }, root.Position, true)
	log:info("surge_started", { userId = player.UserId, domain = s.domain, tier = tier })
end

local function launch(hit: any, velocity: Vector3)
	local victim = Players:GetPlayerFromCharacter(hit.model)
	if victim then
		Net.fire("WorldEffect", victim, { kind = "knockback", velocity = velocity })
	elseif not hit.root.Anchored then
		hit.root.AssemblyLinearVelocity += velocity
	end
end

local function finisher(player: Player, s: State)
	local model, _, root = bodyOf(player)
	local domain, tier = s.domain, s.tier
	endSurge(player, s)
	if not model or not root or not player.Parent then
		return
	end
	local def = Rules.finisherFor(domain)
	local radius = Rules.byTier(S.finisherRadius, tier)
	local center = root.Position
	local fullHit = DamageModel.base(MagicCore.tierDef(tier).powerCeiling)
	runner:cue("surge", { fx = "finisher", domain = domain, radius = radius, name = def.name, caster = player.UserId }, center, true)
	local struck = 0
	for _, hit in Targeting.inRadius(center, radius, S.maxTargets, { [model] = true }) do
		if Targeting.canHarm(player, hit.model) then
			local amount = Rules.finisherAmount(fullHit, tier, (hit.root.Position - center).Magnitude, radius)
			amount *= 1 - DamageModel.resistance(hit.humanoid, { domain }, "momentum")
			if Players:GetPlayerFromCharacter(hit.model) then
				amount = math.min(amount, hit.humanoid.MaxHealth * C.damage.pvpMaxShare)
			end
			Damage.apply(hit.humanoid, math.max(1, amount), player.UserId, "surge_finisher", {
				domain = domain,
				power = MagicCore.tierDef(tier).powerCeiling,
				from = center,
				form = "burst",
				property = "momentum",
			})
			if hit.humanoid.Health > 0 then
				if def.status then
					StatusEffects.apply(hit.humanoid, def.status, {
						duration = def.seconds or 3,
						magnitude = if def.dotShare then fullHit * def.dotShare else nil,
						source = player.UserId,
					})
				end
				if def.launch then
					local away = hit.root.Position - center
					local direction = if away.Magnitude > 0.5 then away.Unit else Vector3.new(0, 1, 0)
					launch(hit, (direction + Vector3.new(0, 0.6, 0)).Unit * def.launch)
				end
			end
			struck += 1
		end
	end
	log:info("surge_finisher", { userId = player.UserId, domain = domain, name = def.name, struck = struck })
end

-- ─── Filling the meter ──────────────────────────────────────────────────────

local function onDamaged(payload: any)
	local amount = payload.amount
	local source: number? = payload.sourceUserId
	local model = payload.model
	local victim = if model then Players:GetPlayerFromCharacter(model) else nil
	if source and source ~= (if victim then victim.UserId else nil) and not (model and model:GetAttribute("PracticeTarget")) then
		local attacker = Players:GetPlayerByUserId(source)
		if attacker then
			local s = stateOf(attacker)
			if not s.surging then
				s.meter = Rules.addMeter(s.meter, Rules.gainFromDealing(amount, s.tier))
				if payload.domain then
					s.tally[payload.domain] = (s.tally[payload.domain] or 0) + amount
				end
				publish(attacker, s)
			end
			s.lastFight = os.clock()
		end
	end
	if victim and source ~= victim.UserId and payload.kind ~= "backfire" then
		local s = stateOf(victim)
		if not s.surging then
			s.meter = Rules.addMeter(s.meter, Rules.gainFromTaking(amount, payload.humanoid.MaxHealth))
			publish(victim, s)
		end
		s.lastFight = os.clock()
	end
end

local function tick()
	local t = workspace:GetServerTimeNow()
	local clock = os.clock()
	for _, player in Players:GetPlayers() do
		local s = stateOf(player)
		if clock >= s.nextTier then
			s.nextTier = clock + TIER_EVERY
			s.tier = bestTier(player)
		end
		if s.surging then
			local model = s.model
			local humanoid = model and model:FindFirstChildOfClass("Humanoid")
			if not model or player.Character ~= model or not humanoid or humanoid.Health <= 0 then
				endSurge(player, s)
				s.meter = 0
				publish(player, s)
			elseif model:GetAttribute("TimeFrozen") then
				s.expires += TICK -- stopped time doesn't use it up
				model:SetAttribute("SurgeUntil", s.expires)
			elseif t >= s.expires then
				endSurge(player, s)
			end
		else
			s.meter = Rules.fade(s.meter, clock - s.lastFight, TICK)
			publish(player, s)
		end
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function SurgeService.init(_self: any, ctx: any)
	log = ctx.log
	runner = ctx.get("EffectRunner")
	playerData = ctx.get("PlayerDataService")
	reservoirs = ctx.get("ReservoirService")
	Net.on("SurgeIntent", function(player: Player)
		if FeatureFlags.get("surge_enabled") ~= true then
			return
		end
		-- Held or frozen: you can't transform, or blast, your way out.
		if player.Character and player.Character:GetAttribute("GravityHeld") then
			return
		end
		local s = stateOf(player)
		if s.surging then
			finisher(player, s)
		else
			startSurge(player, s)
		end
	end)
	ctx.bus:subscribe(Topics.TargetDamaged, onDamaged)
	ctx.get("AdminService"):Register({
		name = "surge",
		category = "Spells",
		description = "Fill your Surge meter, start a Surge now, or end it",
		args = {
			{ name = "action", type = "enum", options = { "fill", "start", "end" } },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_ctx: any, a: any)
			local s = stateOf(a.player)
			if a.action == "fill" then
				s.meter = 1
				s.lastFight = os.clock()
				publish(a.player, s)
				return "meter full"
			elseif a.action == "start" then
				startSurge(a.player, s, true)
				return if s.surging then "surging: " .. s.domain else "couldn't start"
			end
			endSurge(a.player, s)
			return "ended"
		end,
	})
end

function SurgeService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(TICK)
			-- One failure mustn't stop this loop: every Surge would then last forever.
			local ok, err = pcall(tick)
			if not ok then
				log:throttled("surge_tick", 30, "Error", "surge_tick_failed", { err = err })
			end
		end
	end)
end

return SurgeService
