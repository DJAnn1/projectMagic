--!strict
--[[
	Ultimate: a domain's ultimate (docs/SpellOverhaul.md §10, stage 5; data in
	Shared/Magic/Data/Ultimates). A Ritual at power 8+ in a domain's own magic routes here
	(`ult_<id>` routes in Data/EffectLibrary).

	The cast lands at once; the ultimate then plays its BEATS over the next few seconds: warned
	ground first (everyone near sees the marks, as the bosses' moves), then the strikes, rains,
	eruptions and whirlpools. Every hit goes through DamageModel (wards, guards, resistances, PvP
	caps, kill credit to the caster) and only lands on people the caster may harm
	(Targeting.canHarm); each also carries the spell's property behaviour (Cast/PropertyBehaviour,
	so mastery finishers apply). Knockback on a player goes to their own client. Clients only draw:
	the cues reuse Fx/ShapeFx ("warn", "drop", "hit", "zone", "zoneEnd").

	Refusals before payment: the kill switch (flag `ultimates_enabled`), the caster's cooldown for
	this ultimate (Data cooldown by tier: ULTIMATE_COOLDOWN) and the server's cap on ultimates
	running at once (ULTIMATE_BUSY).
	Known gap: like other delayed hits, an ultimate's beats aren't judged by settlement law.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Net = require(Shared.Net)
local Types = require(Shared.Magic.Types)
local Data = require(Shared.Magic.Data.Ultimates)

local Cast = script.Parent.Parent
local C = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local PropertyBehaviour = require(Cast.PropertyBehaviour)
local FireSim = require(Cast.FireSim)

type Ctx = CastTypes.EffectContext
type Beat = Data.Beat

local Ultimate = {}

local MAX_PER_SPOT = 30
local readyAt: { [string]: number } = {}
local active = 0
local zoneId = 5000000

local function key(userId: number, id: string): string
	return tostring(userId) .. "|" .. id
end

function Ultimate.precheck(params: { [string]: any }, _stats: Types.SpellStats, player: Player): string?
	if FeatureFlags.get("ultimates_enabled") == false then
		return "WORLD_STRAINED"
	elseif active >= Data.maxActive then
		return "ULTIMATE_BUSY"
	elseif player:GetAttribute("CheatNoCooldown") ~= true and os.clock() < (readyAt[key(player.UserId, params.ultimate)] or 0) then
		return "ULTIMATE_COOLDOWN" -- the admin `cheat nocooldown` skips it (Admin/Commands/Spells)
	end
	return nil
end

-- For the admin panel and specs: seconds left on a caster's cooldown, and how many are running.
function Ultimate.cooldownLeft(userId: number, id: string): number
	return math.max(0, (readyAt[key(userId, id)] or 0) - os.clock())
end

function Ultimate.running(): number
	return active
end

function Ultimate.clearCooldowns(userId: number?)
	for k in readyAt do
		if userId == nil or string.sub(k, 1, #tostring(userId) + 1) == tostring(userId) .. "|" then
			readyAt[k] = nil
		end
	end
end

local function alive(c: Ctx): boolean
	return c.player ~= nil and c.player.Parent ~= nil and c.character.Parent ~= nil
end

local function send(c: Ctx, fields: { [string]: any }, position: Vector3)
	local stats = c.stats
	local payload: { [string]: any } = {
		caster = if c.player then c.player.UserId else nil,
		domain = stats.domains[1],
		property = stats.recipe.property,
		form = stats.recipe.form,
		power = stats.recipe.power,
		masteryTier = stats.masteryTier,
	}
	for k, v in fields do
		payload[k] = v
	end
	c.runtime:cue("shape", payload, position, true)
end

local function ground(c: Ctx, at: Vector3): Vector3
	local y = c.world and c.world.surfaceHeight and c.world:surfaceHeight(at.X, at.Z)
	return if typeof(y) == "number" then Vector3.new(at.X, y, at.Z) else at
end

local function spotsFor(c: Ctx, beat: Beat): { Vector3 }
	local center = c.point
	local where = beat.where
	local out: { Vector3 } = {}
	if where == "caster" then
		table.insert(out, ground(c, c.root.Position))
	elseif where == "scatter" then
		for _ = 1, beat.count or 4 do
			local angle = c.rng:NextNumber() * math.pi * 2
			local reach = math.sqrt(c.rng:NextNumber()) * (beat.spread or 20)
			table.insert(out, ground(c, center + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)))
		end
	elseif where == "ring" then
		local count = beat.count or 8
		local spin = c.rng:NextNumber() * math.pi
		for i = 1, count do
			local angle = spin + (i / count) * math.pi * 2
			local d = beat.distance or 10
			table.insert(out, ground(c, center + Vector3.new(math.cos(angle) * d, 0, math.sin(angle) * d)))
		end
	elseif where == "targets" then
		for _, hit in Targeting.inRadius(center, beat.spread or 25, beat.count or 6, { [c.character] = true }) do
			if Targeting.canHarm(c.player, hit.model) then
				table.insert(out, ground(c, hit.root.Position))
			end
		end
	end
	if #out == 0 then
		table.insert(out, ground(c, center)) -- "center", or nobody to hunt: the middle of it
	end
	return out
end

local function shove(hit: CastTypes.Hit, velocity: Vector3)
	if velocity.Magnitude < 0.1 then
		return
	end
	local player = Players:GetPlayerFromCharacter(hit.model)
	if player then
		Net.fire("WorldEffect", player, { kind = "knockback", velocity = velocity })
	else
		hit.root.AssemblyLinearVelocity += velocity
	end
end

-- One strike of a beat: everyone the caster may harm around each spot, each at most once.
local function strike(c: Ctx, beat: Beat, spots: { Vector3 }, ignite: boolean)
	local seen: { [Model]: boolean } = { [c.character] = true }
	local behaviour = PropertyBehaviour.idFor(c.stats.recipe)
	local total = 0
	local source = if c.player then c.player.UserId else nil
	for _, spot in spots do
		if ignite then
			FireSim.igniteGround(spot, 0.8, source, true)
		end
		for _, hit in Targeting.inRadius(spot, beat.radius, MAX_PER_SPOT, seen) do
			seen[hit.model] = true
			if not Targeting.canHarm(c.player, hit.model) then
				continue
			end
			local dealt, result = DamageModel.hit(c, hit, beat.share, "ultimate", { noFalloff = true })
			total += dealt
			PropertyBehaviour.apply(c, hit, dealt, result, behaviour)
			if beat.status and hit.humanoid.Health > 0 then
				StatusEffects.apply(hit.humanoid, beat.status.id, { duration = beat.status.duration, source = source })
			end
			local flat = Vector3.new(hit.root.Position.X - spot.X, 0, hit.root.Position.Z - spot.Z)
			local out = if flat.Magnitude > 0.5 then flat.Unit else Vector3.zero
			local velocity = Vector3.new(0, beat.lift or 0, 0) + out * (beat.push or 0) - out * (beat.pull or 0)
			shove(hit, velocity)
		end
	end
	if beat.heal and total > 0 then
		local own = c.character:FindFirstChildOfClass("Humanoid")
		if own then
			Damage.heal(own, total * beat.heal, source, { domain = c.stats.domains[1] })
		end
	end
end

local function runBeat(c: Ctx, beat: Beat)
	if not alive(c) then
		return
	end
	local spots = spotsFor(c, beat)
	local look = beat.look
	if beat.warn and beat.warn > 0 then
		send(c, { shape = if look == "drop" then "rain" else look, stage = "warn", spots = spots, radius = beat.radius, delay = beat.warn }, spots[1])
		task.wait(beat.warn)
		if not alive(c) then
			return
		end
	end
	local zone = beat.zone
	if zone then
		zoneId += 1
		local id = zoneId
		send(c, { shape = "linger", stage = "zone", id = id, radius = beat.radius, seconds = zone.seconds, spots = { spots[1] } }, spots[1])
		local ends = os.clock() + zone.seconds
		while os.clock() < ends and alive(c) do
			strike(c, beat, spots, false)
			task.wait(zone.every)
		end
		send(c, { shape = "linger", stage = "zoneEnd", id = id }, spots[1])
		return
	end
	if look == "drop" then
		send(c, { shape = "rain", stage = "drop", spots = spots, radius = beat.radius }, spots[1])
		task.wait(0.28) -- the drop's fall (Fx/ShapeFx)
	else
		send(c, { shape = look, stage = "hit", spots = spots, radius = beat.radius }, spots[1])
	end
	strike(c, beat, spots, beat.ignite == true)
end

function Ultimate.resolve(ctx: Ctx, params: { [string]: any }): CastTypes.Outcome
	local u = Data.list[params.ultimate]
	if ctx.backfire then
		local own = Targeting.select(ctx)[1]
		if own then
			DamageModel.hit(ctx, own, C.backfireSelfShare, "backfire", { noCrit = true, noFalloff = true })
		end
		return { effective = false, hits = 1, harmedSelf = true }
	end
	if not u or not ctx.player then
		return { effective = false, hits = 0 }
	end
	local tier = math.clamp(math.floor(math.max(1, ctx.stats.masteryTier or 1)), 1, #Data.cooldown)
	readyAt[key(ctx.player.UserId, params.ultimate)] = os.clock() + Data.cooldown[tier]

	-- A frozen copy: the beats play out after the cast's own context has moved on.
	local c = table.clone(ctx)
	c.delivered = nil
	c.target = nil
	active += 1
	local last = 0
	for _, beat in u.beats do
		local length = beat.at + (beat.warn or 0) + (if beat.zone then beat.zone.seconds else 0.5)
		last = math.max(last, length)
		task.delay(beat.at, function()
			local ok, err = pcall(runBeat, c, beat)
			if not ok then
				warn("[Ultimate] " .. tostring(params.ultimate) .. ": " .. tostring(err))
			end
		end)
	end
	task.delay(last + 0.5, function()
		active = math.max(0, active - 1)
	end)
	return { effective = true, hits = 0, note = u.name .. "." }
end

return Ultimate
