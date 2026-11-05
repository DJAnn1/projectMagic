--!strict
--[[
	EffectRunner: everything magic leaves running after the cast.

	Owns and ticks (Heartbeat-driven, fixed rates, one loop for the whole server):
		durational effects   fields (FieldEffects) at field.tick (10 Hz); each registered effect
		                     holds a budget slot (EffectBudget) released when it ends
		statuses             StatusEffects at 4 Hz (expiry, damage over time, NPC animation speed)
		heat and fire        ThermalSim and FireSim at fire.tick (2 Hz)
		presences            elemental traces for InteractionMatrix; checked when added, expired 1 Hz
	Provides:
		startField(kind, mode, center, radius, opts) -> effectId?   budgeted zone
		addPresence(tags, position, radius, power, owner?, effectId?)  -> triggers reactions
		dispelArea(position, radius, owner?) -> count   ends effects, fires, statuses, magic constructs
		stop(effectId)
		cue(kind, payload, position, heavy)   WorldEffect fan-out with LOD (near/mid/far)
		env()   the dependency bundle InteractionMatrix handlers use
	Hooks Damage.onDamage / onHeal and StatusEffects.onApplied: Topics.MagicDamage (NPC brains:
	who hurt me), TargetDamaged, TargetKilled, StatusApplied, and the "hit" / "heal" / "statusTag"
	cues every client near the target gets (damage numbers, hit markers, hit-stop; docs/Combat.md §7).
	Damage over time is summed per target and shown once every feedback.dotFlush seconds.

	Admin: `effects` (what's running), `budget` (EffectBudget report), `clearfx [radius]`.
	On shutdown every field is stopped, so no server ever saves or leaves edited parts behind.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)

local Server = script.Parent.Parent
local Cast = Server.Magic.Cast
local T = require(Server.Magic.Data.CastTuning)
local C = require(Server.Magic.Data.CombatTuning)
local EffectBudget = require(Cast.EffectBudget)
local StatusEffects = require(Cast.StatusEffects)
local Damage = require(Cast.Damage)
local ThermalSim = require(Cast.ThermalSim)
local FireSim = require(Cast.FireSim)
local FieldEffects = require(Cast.FieldEffects)
local InteractionMatrix = require(Cast.InteractionMatrix)
local Targeting = require(Cast.Targeting)
local HitReactions = require(Cast.HitReactions)
local TerrainDeform = require(Server.World.TerrainDeform)

type Active = {
	id: number,
	kind: string,
	owner: number?,
	field: FieldEffects.Field?,
	expires: number,
	slots: { string }, -- EffectBudget slots held (released on stop)
	position: Vector3,
	radius: number,
}

local EffectRunner = {
	name = "EffectRunner",
	dependencies = { "NetService", "WorldStateService", "WorldService", "AdminService" },
}

local log: any = nil
local bus: any = nil
local world: any = nil
local effects: { [number]: Active } = {}
local presences: { InteractionMatrix.Presence } = {}
local reactionCooldowns: { [string]: number } = {}
local nextId = 0
local metrics = { reactions = 0, fieldSteps = 0, touched = 0 }

local function now(): number
	return workspace:GetServerTimeNow()
end

local function newId(): number
	nextId += 1
	return nextId
end

-- ─── Cues ───────────────────────────────────────────────────────────────────

-- Sends a cosmetic cue to players by distance tier: near gets lod 2, mid lod 1, far lod 0.
function EffectRunner.cue(_self: any, kind: string, payload: { [string]: any }, position: Vector3, heavy: boolean)
	local listeners = EffectBudget.listeners(position, heavy)
	for lod, group in { [2] = listeners.near, [1] = listeners.mid, [0] = listeners.far } :: { [number]: { Player } } do
		if #group > 0 then
			local message = table.clone(payload)
			message.kind = kind
			message.position = message.position or position
			message.lod = lod
			Net.fireList("WorldEffect", group, message)
		end
	end
end

-- ─── Combat feedback (docs/Combat.md §7) ────────────────────────────────────

-- Damage-over-time waiting to be shown as one number (flushed every feedback.dotFlush seconds).
local pendingDot: { [Humanoid]: { amount: number, source: number?, kind: string } } = {}

-- Just above the head, where numbers and status words appear.
local function headPosition(humanoid: Humanoid): Vector3?
	local model = humanoid.Parent
	if not model then
		return nil
	end
	local head = model:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position + Vector3.new(0, 1.2, 0)
	end
	local root = model:FindFirstChild("HumanoidRootPart")
	if root and root:IsA("BasePart") then
		return root.Position + Vector3.new(0, 3, 0)
	end
	return nil
end

local function victimOf(humanoid: Humanoid): number?
	local player = Players:GetPlayerFromCharacter(humanoid.Parent)
	return if player then player.UserId else nil
end

-- One "hit" cue to everyone near the target: the number, the caster's hit marker, the victim's
-- hurt flash, and hit-stop for heavy hits. Compact: no instances, only the head position.
local function hitCue(humanoid: Humanoid, amount: number, source: number?, kind: string, info: Damage.Info, dot: boolean)
	local position = headPosition(humanoid)
	if not position then
		return
	end
	local maxHealth = math.max(1, humanoid.MaxHealth)
	EffectRunner:cue("hit", {
		amount = math.max(1, math.floor(amount + 0.5)),
		crit = info.crit == true,
		killed = info.killed == true,
		domain = info.domain,
		kind = kind,
		dot = dot,
		caster = source,
		victim = victimOf(humanoid),
		heavy = amount >= maxHealth * C.feedback.heavyShare,
		share = math.clamp(amount / maxHealth, 0, 1),
	}, position, false)
end

local function flushDots()
	for humanoid, pending in pendingDot do
		pendingDot[humanoid] = nil
		if humanoid.Parent and pending.amount >= 0.5 then
			hitCue(humanoid, pending.amount, pending.source, pending.kind, { domain = nil }, true)
		end
	end
end

-- ─── Effects ────────────────────────────────────────────────────────────────

local function stopEffect(id: number)
	local effect = effects[id]
	if not effect then
		return
	end
	effects[id] = nil
	if effect.field then
		FieldEffects.stop(effect.field)
		EffectRunner:cue("field_end", { id = id }, effect.position, false)
	end
	for _, slot in effect.slots do
		if slot == "active" then
			EffectBudget.releaseActive(effect.owner)
		else
			EffectBudget.release(slot)
		end
	end
	for i = #presences, 1, -1 do
		if presences[i].effectId == id then
			table.remove(presences, i)
		end
	end
end

function EffectRunner.stop(_self: any, id: number)
	stopEffect(id)
end

--[[
	Starts a budgeted zone. Returns the effect id, or (nil, reason) when the budget refuses:
	"active" (server or per-player cap), "fields", "mythicFields".
]]
function EffectRunner.startField(
	_self: any,
	kind: string,
	mode: string,
	center: Vector3,
	radius: number,
	seconds: number,
	opts: FieldEffects.FieldOptions
): (number?, string?)
	local slots: { string } = {}
	local function rollback()
		for _, slot in slots do
			if slot == "active" then
				EffectBudget.releaseActive(opts.owner)
			else
				EffectBudget.release(slot)
			end
		end
	end
	if not EffectBudget.acquireActive(opts.owner) then
		return nil, "active"
	end
	table.insert(slots, "active")
	if not EffectBudget.acquire("fields") then
		rollback()
		return nil, "fields"
	end
	table.insert(slots, "fields")
	if FieldEffects.isMythic(kind) then
		if not EffectBudget.acquire("mythicFields") then
			rollback()
			return nil, "mythicFields"
		end
		table.insert(slots, "mythicFields")
	end
	local field = FieldEffects.new(kind, mode, center, radius, opts)
	local id = newId()
	local duration = math.clamp(seconds, 2, T.field.maxFieldSeconds)
	effects[id] = {
		id = id,
		kind = kind,
		owner = opts.owner,
		field = field,
		expires = now() + duration,
		slots = slots,
		position = center,
		radius = field.radius,
	}
	EffectRunner:cue("field", {
		id = id,
		field = kind,
		mode = mode,
		radius = field.radius,
		height = field.height,
		duration = duration,
		followUserId = opts.follow and opts.owner or nil,
		direction = opts.direction,
	}, center, true)
	return id, nil
end

-- ─── Presences and reactions ────────────────────────────────────────────────

local env: InteractionMatrix.Env

function EffectRunner.env(_self: any): InteractionMatrix.Env
	return env
end

function EffectRunner.addPresence(_self: any, tags: { string }, position: Vector3, radius: number, power: number, owner: number?, effectId: number?)
	local presence: InteractionMatrix.Presence = {
		id = newId(),
		tags = tags,
		position = position,
		radius = math.max(radius, 4),
		power = power,
		owner = owner,
		expires = if effectId and effects[effectId] then effects[effectId].expires else now() + T.presenceSeconds,
		effectId = effectId,
	}
	local fired = 0
	local t = now()
	for _, other in presences do
		if fired >= 3 then
			break
		end
		if other.expires > t and (other.position - position).Magnitude <= presence.radius + other.radius then
			for _, reaction in InteractionMatrix.match(presence, other) do
				local cell = math.floor(position.X / 16) .. "," .. math.floor(position.Z / 16)
				local key = reaction.result .. "@" .. cell
				if (reactionCooldowns[key] or 0) <= t then
					reactionCooldowns[key] = t + T.reactionCooldown
					local ok, err = pcall(InteractionMatrix.react, env, reaction, presence, other)
					if not ok then
						log:error("reaction_failed", { result = reaction.result, err = err })
					else
						fired += 1
						metrics.reactions += 1
						log:debug("reaction", { result = reaction.result })
						EffectRunner:cue("reaction", { result = reaction.result, radius = math.min(presence.radius, other.radius) }, (presence.position + other.position) / 2, false)
					end
				end
			end
		end
	end
	table.insert(presences, presence)
end

-- ─── Dispel ─────────────────────────────────────────────────────────────────

-- Ends magic in an area: fields, fires, statuses on characters, magic constructs. `owner`'s own
-- effects are spared (you don't dispel your own ward by unravelling an enemy's field).
function EffectRunner.dispelArea(_self: any, position: Vector3, radius: number, owner: number?): number
	local count = 0
	for id, effect in effects do
		if effect.owner ~= owner and (effect.position - position).Magnitude <= radius + effect.radius then
			stopEffect(id)
			count += 1
		end
	end
	count += FireSim.extinguish(position, radius)
	for _, hit in Targeting.inRadius(position, radius, 30) do
		count += StatusEffects.dispel(hit.humanoid)
	end
	for _, construct in CollectionService:GetTagged("MagicConstruct") do
		if construct:IsA("BasePart") and construct:GetAttribute("OwnerUserId") ~= owner and (construct.Position - position).Magnitude <= radius then
			construct:Destroy()
			count += 1
		end
	end
	count += TerrainDeform.meltAt(position, radius)
	return count
end

-- ─── Tick ───────────────────────────────────────────────────────────────────

local function tickFields(dt: number)
	local t = now()
	for id, effect in effects do
		if effect.expires <= t then
			stopEffect(id)
		elseif effect.field then
			local ok, result = pcall(FieldEffects.step, effect.field, dt)
			if ok then
				metrics.fieldSteps += 1
				metrics.touched += result
				effect.position = effect.field.center
			else
				log:error("field_step_failed", { kind = effect.kind, err = result })
				stopEffect(id)
			end
		end
	end
end

local function tickPresences()
	local t = now()
	for i = #presences, 1, -1 do
		if presences[i].expires <= t then
			table.remove(presences, i)
		end
	end
	for key, untilTime in reactionCooldowns do
		if untilTime <= t then
			reactionCooldowns[key] = nil
		end
	end
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "effects", category = "Spells", description = "Running fields, fires, statuses, presences and reactions",
		handler = function()
		local t = now()
		local lines = {}
		for id, effect in effects do
			table.insert(lines, string.format("#%d %s/%s r%.0f %.0fs owner %s", id, effect.kind, effect.field and effect.field.mode or "-", effect.radius, effect.expires - t, tostring(effect.owner)))
		end
		table.sort(lines)
		local parts, ground = FireSim.counts()
		table.insert(lines, string.format(
			"fires: %d parts, %d ground · heat-active parts %d · statuses %d · presences %d · reactions %d · field steps %d (touched %d)",
			parts, ground, ThermalSim.activeCount(), StatusEffects.count(), #presences, metrics.reactions, metrics.fieldSteps, metrics.touched
		))
		return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "budget", category = "Spells", description = "Per-server magic budget: slots, token buckets, refusals",
		handler = function()
			return EffectBudget.report()
		end,
	})
	admin:Register({
		name = "clearfx", category = "Spells", description = "End all magic around you (or everywhere when no radius)",
		args = { { name = "radius", type = "number", min = 1, max = 5000, optional = true } },
		handler = function(ctx, a)
		local radius: number? = a.radius
		local player = ctx.player
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if radius and root then
			return "cleared " .. EffectRunner:dispelArea(root.Position, radius, nil)
		end
		local n = 0
		for id in effects do
			stopEffect(id)
			n += 1
		end
		return string.format("stopped %d effects, %d fires", n, FireSim.extinguish(Vector3.zero, math.huge))
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function EffectRunner.init(_self: any, ctx: any)
	log, bus = ctx.log, ctx.bus
	world = ctx.get("WorldStateService")
	local worldService = ctx.get("WorldService")
	registerAdmin(ctx.get("AdminService"))

	env = {
		fire = FireSim,
		thermal = ThermalSim,
		status = StatusEffects,
		damage = Damage,
		terrain = TerrainDeform,
		world = world,
		targets = function(position: Vector3, radius: number): { any }
			return Targeting.inRadius(position, radius, 24)
		end,
		cue = function(kind: string, payload: { [string]: any }, position: Vector3, heavy: boolean)
			EffectRunner:cue(kind, payload, position, heavy)
		end,
		stopEffect = stopEffect,
		dispelArea = function(position: Vector3, radius: number, owner: number?): number
			return EffectRunner:dispelArea(position, radius, owner)
		end,
	}

	Damage.onDamage = function(humanoid: Humanoid, amount: number, kind: string, source: number?, info: Damage.Info)
		bus:publish(Topics.MagicDamage, { humanoid = humanoid, amount = amount, kind = kind, sourceUserId = source })
		local model = humanoid.Parent
		local npcId = if model then model:GetAttribute("NpcId") else nil
		bus:publish(Topics.TargetDamaged, {
			humanoid = humanoid,
			model = model,
			npcId = npcId,
			amount = amount,
			kind = kind,
			sourceUserId = source,
			crit = info.crit == true,
			domain = info.domain,
			branch = info.branch,
			killed = info.killed == true,
		})
		if info.killed then
			bus:publish(Topics.TargetKilled, { humanoid = humanoid, model = model, npcId = npcId, kind = kind, sourceUserId = source, domain = info.domain })
		end
		local def = StatusEffects.defs[kind]
		HitReactions.react(humanoid, amount, kind, info, def ~= nil and def.dot == true)
		if def and def.dot and not info.killed then
			-- Damage over time: summed and shown as one number every dotFlush seconds.
			local pending = pendingDot[humanoid]
			if pending then
				pending.amount += amount
			else
				pendingDot[humanoid] = { amount = amount, source = source, kind = kind }
			end
		else
			hitCue(humanoid, amount, source, kind, info, def ~= nil and def.dot == true)
		end
	end
	Damage.onHeal = function(humanoid: Humanoid, amount: number, source: number?, info: Damage.Info)
		local position = headPosition(humanoid)
		if position then
			EffectRunner:cue("heal", { amount = math.max(1, math.floor(amount + 0.5)), domain = info.domain, caster = source, victim = victimOf(humanoid) }, position, false)
		end
	end
	StatusEffects.onApplied = function(humanoid: Humanoid, id: string, duration: number, source: number?)
		local def = StatusEffects.defs[id]
		bus:publish(Topics.StatusApplied, { humanoid = humanoid, model = humanoid.Parent, status = id, duration = duration, sourceUserId = source })
		local position = headPosition(humanoid)
		if def and position then
			EffectRunner:cue("statusTag", { status = id, name = def.name, harmful = def.harmful == true, caster = source }, position, false)
		end
	end

	-- FireSim needs the world seed (wind) and a way to leave persistent scorch marks.
	task.defer(function()
		FireSim.init(world, worldService:getSeed(), function(position: Vector3)
			TerrainDeform.commit(world, "scorch", TerrainDeform.scorchOps(world, position))
		end)
	end)
end

function EffectRunner.start(_self: any, _ctx: any)
	local fieldAcc, statusAcc, fireAcc, presenceAcc, dotAcc = 0, 0, 0, 0, 0
	RunService.Heartbeat:Connect(function(dt)
		fieldAcc += dt
		statusAcc += dt
		fireAcc += dt
		presenceAcc += dt
		dotAcc += dt
		if dotAcc >= C.feedback.dotFlush then
			dotAcc = 0
			flushDots()
		end
		if fieldAcc >= T.field.tick then
			tickFields(fieldAcc)
			fieldAcc = 0
		end
		if statusAcc >= 0.25 then
			StatusEffects.tick(statusAcc, Damage.apply)
			statusAcc = 0
		end
		if fireAcc >= T.fire.tick then
			local elapsed = fireAcc
			fireAcc = 0
			local ok, err = pcall(function()
				ThermalSim.tick(elapsed)
				FireSim.tick(elapsed)
			end)
			if not ok then
				log:throttled("fire_tick", 30, "Error", "fire_tick_failed", { err = err })
			end
		end
		if presenceAcc >= 1 then
			tickPresences()
			presenceAcc = 0
		end
	end)

	Players.PlayerRemoving:Connect(function(player)
		-- A leaving player's zones end with them; fires they lit burn on (the world remembers).
		for id, effect in effects do
			if effect.owner == player.UserId then
				stopEffect(id)
			end
		end
	end)
	game:BindToClose(function()
		for id in effects do
			stopEffect(id)
		end
	end)
end

return EffectRunner
