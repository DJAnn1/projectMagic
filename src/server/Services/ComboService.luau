--!strict
--[[
	ComboService: cooperative magic between two party members (docs/Social.md §4). Data in
	Shared/Social/Data/Combos, matching rules in Social/ComboMatcher.

	HOW IT TRIGGERS  Every resolved spell by a party member is remembered for a few seconds. When a
	                 second member's spell lands close enough and fills the other role, the combo
	                 fires at the midpoint. The two spells have already been paid for and have
	                 already done their own work: the combo is a bonus on top, not a third cost.
	FEEDBACK         Your partner sees a ring where your spell landed if they can finish the combo
	                 (combo_ready, sent only to them). When it fires, everyone nearby sees the eruption
	                 and a banner naming it and the two casters (the combo cue).
	DAMAGE           Through Cast/Damage, so guards, wards, resistance, PvP rules and NPC memory all
	                 apply. Friendly fire can't happen: party members are never harmed (PvpRules).
	                 The combo's source is whoever finished it, for NPC memory and kill credit.
	REWARD           A flat experimentation XP award, once ever per player and combo. Repeats pay no
	                 XP, so two friends can't farm one by casting at a wall.
	DETERMINISM      Damage variance comes from Seed.random(worldSeed, "combo:<id>", "hit", counter).

	Budget: one list of at most 8 recent casts per party, scanned once per resolved spell. A combo
	does one area query (at most `maxTargets` occlusion rays), one cooldown per party and combo, and
	one heavy cue. It creates no parts or terrain on the server.

	Admin: combos, combotest.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local Combos = require(Shared.Social.Data.Combos)

local Server = script.Parent.Parent
local Cast = Server.Magic.Cast
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local Resistances = require(Cast.Resistances)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local C = require(Server.Magic.Data.CombatTuning)
local ComboMatcher = require(Server.Social.ComboMatcher)

local RECENT_CAP = 8
local READY_COOLDOWN = 5 -- seconds between "your partner can finish this" rings for one player
local READY_RANGE = 120 -- studs: a partner further than this won't see the ring

local ComboService = {
	name = "ComboService",
	dependencies = { "NetService", "PlayerDataService", "PartyService", "ProgressionService", "EffectRunner", "WorldService", "AdminService" },
}

local log: any = nil
local bus: any = nil
local flags: any = nil
local playerData: any = nil
local parties: any = nil
local progression: any = nil
local runner: any = nil
local worldService: any = nil

local recent: { [string]: { ComboMatcher.Cast } } = {}
local cooldowns: { [string]: number } = {} -- "<party>|<combo>" -> os.clock() it ends
local readyAt: { [Player]: number } = {}
local counter = 0

local function rootOf(player: Player): BasePart?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

-- The longest window any combo uses: casts older than this can't matter.
local LONGEST_WINDOW = 0
for _, combo in Combos.list do
	LONGEST_WINDOW = math.max(LONGEST_WINDOW, combo.window)
end

-- What one target takes: same steps as DamageModel, from the combo's own numbers.
local function amountFor(combo: Combos.Combo, power: number, distance: number, radius: number, humanoid: Humanoid, model: Model, rng: Random): number
	local D = C.damage
	local falloff = 1 - 0.5 * math.clamp(distance / radius, 0, 1)
	local amount = DamageModel.base(power) * combo.share * falloff
	amount *= 1 - Resistances.total(humanoid, combo.domains, combo.property)
	amount *= 1 + (rng:NextNumber() * 2 - 1) * D.variance
	amount = math.clamp(amount, D.minDamage, D.maxHit)
	if Players:GetPlayerFromCharacter(model) then
		amount = math.min(amount, humanoid.MaxHealth * D.pvpMaxShare)
	end
	return amount
end

local function awardFirst(player: Player, combo: Combos.Combo, branch: string)
	local state = playerData:get(player)
	if not state then
		return
	end
	local found = state.data.combosFound
	if typeof(found) ~= "table" then
		found = {}
		state.data.combosFound = found
	end
	if found[combo.id] then
		return
	end
	found[combo.id] = os.time()
	progression:awardExperiment(player, branch, combo.firstXp)
	Net.fire("Notify", player, "New combo discovered: " .. combo.name)
	log:info("combo_discovered", { userId = player.UserId, combo = combo.id })
end

-- Fires a combo. `a` started it and `b` finished it (they can be the same person only in `combotest`).
local function fire(combo: Combos.Combo, a: ComboMatcher.Cast, b: ComboMatcher.Cast): number
	local center = a.point:Lerp(b.point, 0.5)
	local power = ComboMatcher.powerOf(combo, a, b)
	local radius = ComboMatcher.radiusOf(combo, power)
	local first = Players:GetPlayerByUserId(a.userId)
	local finisher = Players:GetPlayerByUserId(b.userId)

	counter += 1
	local rng = Seed.random(worldService:getSeed(), "combo:" .. combo.id, "hit", counter)
	local exclude: { [Model]: boolean } = {}
	for _, p in { first, finisher } :: { Player } do
		if p.Character then
			exclude[p.Character] = true
		end
	end

	local total, struck = 0, 0
	local eye = center + Vector3.new(0, C.area.lift, 0)
	for _, hit in Targeting.inRadius(center, radius, combo.maxTargets, exclude) do
		local allowed = (not first or Targeting.canHarm(first, hit.model)) and (not finisher or Targeting.canHarm(finisher, hit.model))
		if allowed and not (C.area.occlusion and Targeting.occluded(eye, hit, {})) then
			local amount = amountFor(combo, power, hit.distance, radius, hit.humanoid, hit.model, rng)
			local dealt = Damage.apply(hit.humanoid, amount, b.userId, "combo", {
				domain = combo.domains[1],
				power = power,
				from = center,
				property = combo.property,
				form = "burst",
				branch = b.branch,
			})
			if dealt > 0 then
				total += dealt
				struck += 1
				local status = combo.status
				if status then
					StatusEffects.apply(hit.humanoid, status.id, {
						duration = status.seconds,
						magnitude = DamageModel.base(power) * status.dpsShare,
						source = b.userId,
					})
				end
			end
		end
	end

	runner:cue("combo", { combo = combo.id, a = a.userId, b = b.userId, radius = radius, power = power }, center, true)
	bus:publish(Topics.MagicWitnessed, { position = center, radius = radius, domains = combo.domains, power = math.floor(power), harmful = true, casterUserId = b.userId })
	bus:publish(Topics.ComboTriggered, { combo = combo.id, a = a.userId, b = b.userId, position = center, targets = struck, total = total })
	if first then
		awardFirst(first, combo, a.branch)
	end
	if finisher and finisher ~= first then
		awardFirst(finisher, combo, b.branch)
	end
	log:info("combo_triggered", { combo = combo.id, a = a.userId, b = b.userId, power = power, targets = struck, total = math.floor(total) })
	return struck
end

-- Tells partners who could finish this one where to aim.
local function offerReady(player: Player, cast: ComboMatcher.Cast)
	for _, mate in parties:matesOf(player) do
		local state = playerData:get(mate)
		local root = rootOf(mate)
		if state and root and (root.Position - cast.point).Magnitude <= READY_RANGE and os.clock() >= (readyAt[mate] or 0) then
			for _, combo in Combos.list do
				local role = ComboMatcher.neededRole(combo, cast)
				if role and state.caster.awakened[role.domain] then
					readyAt[mate] = os.clock() + READY_COOLDOWN
					Net.fire("WorldEffect", mate, { kind = "combo_ready", combo = combo.id, position = cast.point, need = role.domain, from = player.UserId })
					break
				end
			end
		end
	end
end

local function onResolved(payload: any)
	if flags.get("combos_enabled") == false then
		return
	end
	local partyId = parties:partyIdOf(payload.casterUserId)
	local player = Players:GetPlayerByUserId(payload.casterUserId)
	if not partyId or not player then
		return
	end
	local t = os.clock()
	local cast: ComboMatcher.Cast = {
		userId = payload.casterUserId,
		domains = payload.domains,
		tags = payload.tags or {},
		verb = payload.verb,
		power = payload.power,
		branch = payload.branch,
		point = payload.point,
		at = t,
		backfired = payload.backfired == true,
	}
	local list = recent[partyId] or {}
	recent[partyId] = list
	for i = #list, 1, -1 do
		if t - list[i].at > LONGEST_WINDOW then
			table.remove(list, i)
		end
	end
	for i, earlier in list do
		for _, combo in Combos.list do
			local key = partyId .. "|" .. combo.id
			if t >= (cooldowns[key] or 0) and ComboMatcher.matches(combo, earlier, cast) then
				cooldowns[key] = t + combo.cooldown
				table.remove(list, i) -- both halves are spent
				fire(combo, earlier, cast)
				return
			end
		end
	end
	table.insert(list, cast)
	while #list > RECENT_CAP do
		table.remove(list, 1)
	end
	offerReady(player, cast)
end

local function registerAdmin(admin: any)
	local ids: { string } = {}
	for _, combo in Combos.list do
		table.insert(ids, combo.id)
	end
	admin:Register({
		name = "combos",
		category = "Social",
		description = "Every combo, and what triggers it",
		handler = function(_ctx: any, _a: any)
			local lines: { string } = {}
			for _, combo in Combos.list do
				local parts: { string } = {}
				for _, role in combo.roles do
					table.insert(parts, role.domain)
				end
				table.insert(lines, string.format("%s: %s, within %.1f s and %d studs, cooldown %d s", combo.id, table.concat(parts, " + "), combo.window, combo.reach, combo.cooldown))
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "combotest",
		category = "Social",
		description = "Fire a combo 15 studs in front of you with no partner and no cost (hurts targets; you're spared)",
		args = {
			{ name = "combo", type = "enum", options = ids },
			{ name = "power", type = "number", min = 1, max = 10, default = 4 },
		},
		handler = function(ctx: any, a: any)
			local player: Player = ctx.player
			local root = rootOf(player)
			local combo = Combos.byId[a.combo]
			if not root or not combo then
				return "no character"
			end
			local point = root.Position + root.CFrame.LookVector * 15
			local function half(role: Combos.Role): ComboMatcher.Cast
				return { userId = player.UserId, domains = { role.domain }, tags = role.tags or {}, verb = "generate", power = a.power, branch = role.domain, point = point, at = os.clock(), backfired = false }
			end
			local struck = fire(combo, half(combo.roles[1]), half(combo.roles[2]))
			return string.format("%s fired, %d target(s) struck", combo.name, struck)
		end,
	})
end

function ComboService.init(_self: any, ctx: any)
	log, bus, flags = ctx.log, ctx.bus, ctx.flags
	playerData = ctx.get("PlayerDataService")
	parties = ctx.get("PartyService")
	progression = ctx.get("ProgressionService")
	runner = ctx.get("EffectRunner")
	worldService = ctx.get("WorldService")
	bus:subscribe(Topics.SpellResolved, onResolved)
	bus:subscribe(Topics.PartyChanged, function(payload: any)
		if payload.partyId then
			recent[payload.partyId] = nil
		end
	end)
	registerAdmin(ctx.get("AdminService"))
end

function ComboService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		readyAt[player] = nil
	end)
end

return ComboService
