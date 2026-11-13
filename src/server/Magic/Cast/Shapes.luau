--!strict
--[[
	Shapes: how a harmful spell PLAYS beyond its main hit (docs/SpellOverhaul.md §2B, stage 3; which
	shape a recipe gets is Shared/Magic/SpellShape over Data/SpellShapes). CastService calls, per
	cast (not per echo or channel pulse):

		Shapes.find(stats, routeId) -> Shape?           nil when off or the spell has none
		Shapes.before(ctx, shape)                       before the main hit: steer the flight (lob,
		                                                homing, skip), or mark the ground and wait
		                                                (erupt, rain) with a warning everyone near sees
		Shapes.after(ctx, shape, record)                after it: echo, split, splash, drain, nova,
		                                                a lingering area or barrier, eruption lift,
		                                                the rain's drops, aura pulses

	Every extra hit goes through DamageModel (wards, guards, resistances, PvP caps: Cast/Damage) and
	then the property's behaviour (Cast/PropertyBehaviour), and only lands on people the caster may
	harm (Targeting.canHarm). Knockback on a player goes to their own client. Clients draw what they
	are told through WorldEffect cues of kind "shape" (Client/Fx/ShapeFx). Lingering areas are
	capped (Data/SpellShapes.caps) and stepped in one Heartbeat.
	Known gap: hits that land after the cast resolved (echo, nova, zones, drops, pulses) aren't
	judged by settlement law (the pinned "crime judgment for delayed hits" item).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local SpellShape = require(Shared.Magic.SpellShape)
local Data = require(Shared.Magic.Data.SpellShapes)

local Cast = script.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local Targeting = require(Cast.Targeting)
local PropertyBehaviour = require(Cast.PropertyBehaviour)

type Ctx = CastTypes.EffectContext
type Shape = { kind: string, [string]: any }

local Shapes = {}

type Zone = {
	ctx: Ctx,
	shape: Shape,
	behaviour: string?,
	point: Vector3,
	radius: number,
	ends: number,
	nextTick: number,
	owner: number,
	id: number,
}
local zones: { Zone } = {}
local zoneId = 0

-- ─── Helpers ────────────────────────────────────────────────────────────────

function Shapes.find(stats: any, routeId: string?): Shape?
	if FeatureFlags.get("spell_shapes_enabled") == false then
		return nil
	end
	return SpellShape.of(stats.recipe, routeId)
end

-- Which behaviour a route's hits carry: the thermal routes know better than the property.
local function behaviourFor(ctx: Ctx, routeId: string?): string?
	if routeId == "thermal" then
		return if ctx.stats.recipe.verb == "reduce" then "cold" else "heat"
	elseif routeId == "ignite" then
		return "combustion"
	end
	return PropertyBehaviour.idFor(ctx.stats.recipe)
end

local function radiusOf(ctx: Ctx): number
	return math.clamp(ctx.stats.area, 3, 40)
end

local function send(ctx: Ctx, fields: { [string]: any }, position: Vector3, heavy: boolean?)
	local stats = ctx.stats
	local payload: { [string]: any } = {
		caster = if ctx.player then ctx.player.UserId else nil,
		domain = stats.domains[1],
		property = stats.recipe.property,
		form = stats.recipe.form,
		power = stats.recipe.power,
		masteryTier = stats.masteryTier,
	}
	for k, v in fields do
		payload[k] = v
	end
	ctx.runtime:cue("shape", payload, position, heavy == true)
end

local function alive(ctx: Ctx): boolean
	return ctx.player ~= nil and ctx.player.Parent ~= nil and ctx.character.Parent ~= nil
end

-- One extra hit on everyone the caster may harm around `center`. Returns how many were struck.
local function hitAround(ctx: Ctx, center: Vector3, radius: number, share: number, behaviour: string?, exclude: { [Model]: boolean }?): number
	local skip = exclude or {}
	skip[ctx.character] = true
	local count = 0
	for _, hit in Targeting.inRadius(center, radius, ctx.stats.maxTargets, skip) do
		if Targeting.canHarm(ctx.player, hit.model) then
			local dealt, result = DamageModel.hit(ctx, hit, share, "shape", { noFalloff = true })
			PropertyBehaviour.apply(ctx, hit, dealt, result, behaviour)
			count += 1
		end
	end
	return count
end

local function lift(hit: Targeting.Hit, speed: number)
	local velocity = Vector3.new(0, speed, 0)
	local player = Players:GetPlayerFromCharacter(hit.model)
	if player then
		Net.fire("WorldEffect", player, { kind = "knockback", velocity = velocity })
	else
		hit.root.AssemblyLinearVelocity += velocity
	end
end

-- A frozen copy for work that happens later (echoes and pulses change the live context).
local function later(ctx: Ctx): Ctx
	local copy = table.clone(ctx)
	copy.delivered = nil
	copy.target = nil
	return copy
end

-- ─── Before the main hit ────────────────────────────────────────────────────

-- Steers the flight, or marks the ground and waits. Rain spots are kept on the context's shape run.
function Shapes.before(ctx: Ctx, shape: Shape): { Vector3 }?
	local kind = shape.kind
	if ctx.backfire then
		return nil
	end
	if kind == "lob" then
		ctx.shapeGravityMult = shape.gravityMult
		ctx.speedMult = (ctx.speedMult or 1) * 0.6
	elseif kind == "homing" then
		ctx.shapeHoming = true
	elseif kind == "skip" then
		ctx.shapeBounces = shape.bounces
	elseif kind == "erupt" then
		local radius = radiusOf(ctx)
		send(ctx, { shape = kind, stage = "warn", spots = { ctx.point }, radius = radius, delay = shape.warn }, ctx.point, true)
		task.wait(shape.warn)
		ctx.target = nil -- it lands where it was marked, not on whoever stepped away
	elseif kind == "rain" then
		local area = radiusOf(ctx)
		local count = math.min(Data.caps.maxDrops, math.floor(shape.drops + ctx.stats.recipe.power * shape.perPower))
		local spots: { Vector3 } = { ctx.point }
		for _ = 2, count do
			local angle = ctx.rng:NextNumber() * math.pi * 2
			local reach = math.sqrt(ctx.rng:NextNumber()) * area * shape.spread
			local at = ctx.point + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)
			local ground = ctx.world and ctx.world.surfaceHeight and ctx.world:surfaceHeight(at.X, at.Z)
			table.insert(spots, if typeof(ground) == "number" then Vector3.new(at.X, ground, at.Z) else at)
		end
		send(ctx, { shape = kind, stage = "warn", spots = spots, radius = shape.radius, delay = shape.warn }, ctx.point, true)
		task.wait(shape.warn)
		ctx.target = nil
		return spots
	elseif kind == "linger" and shape.warn and radiusOf(ctx) >= 10 then
		-- Big zones are marked too (owner, 2026-11-13), briefly.
		send(ctx, { shape = kind, stage = "warn", spots = { ctx.point }, radius = radiusOf(ctx), delay = shape.warn }, ctx.point, true)
		task.wait(shape.warn)
		ctx.target = nil
	end
	return nil
end

-- ─── After the main hit ─────────────────────────────────────────────────────

local function zonesOf(owner: number): number
	local n = 0
	for _, z in zones do
		if z.owner == owner then
			n += 1
		end
	end
	return n
end

local function startZone(ctx: Ctx, shape: Shape, behaviour: string?, point: Vector3)
	local owner = ctx.player.UserId
	if #zones >= Data.caps.zones or zonesOf(owner) >= Data.caps.zonesPerPlayer then
		return
	end
	zoneId += 1
	local radius = if shape.kind == "barrier" then math.clamp(ctx.stats.area, 3, 12) else radiusOf(ctx)
	local seconds = shape.seconds -- an instant spell still leaves its area for the full time
	local zone: Zone = {
		ctx = later(ctx),
		shape = shape,
		behaviour = behaviour,
		point = point,
		radius = radius,
		ends = os.clock() + seconds,
		nextTick = os.clock() + shape.every,
		owner = owner,
		id = zoneId,
	}
	table.insert(zones, zone)
	send(ctx, { shape = shape.kind, stage = "zone", id = zone.id, radius = radius, seconds = seconds, spots = { point } }, point, true)
end

local function tickZone(zone: Zone)
	local ctx = zone.ctx
	if zone.shape.kind == "barrier" then
		-- The property acts on whoever stands in it; no extra damage.
		for _, hit in Targeting.inRadius(zone.point, zone.radius, ctx.stats.maxTargets, { [ctx.character] = true }) do
			if Targeting.canHarm(ctx.player, hit.model) and zone.behaviour then
				PropertyBehaviour.applyControl(ctx, hit, zone.behaviour)
			end
		end
	else
		hitAround(ctx, zone.point, zone.radius, zone.shape.share, zone.behaviour)
	end
end

function Shapes.after(ctx: Ctx, shape: Shape, routeId: string?, record: { Damage.RecordEntry }, spots: { Vector3 }?)
	if ctx.backfire then
		return
	end
	local kind = shape.kind
	local behaviour = behaviourFor(ctx, routeId)
	local point = ctx.point
	local struck: { [Model]: boolean } = {}
	for _, h in (ctx.delivered or {}) :: { Targeting.Hit } do
		struck[h.model] = true
	end

	if kind == "echo" then
		local c = later(ctx)
		local targets = Targeting.select(ctx)
		task.delay(shape.delay, function()
			if not alive(c) then
				return
			end
			for _, hit in targets do
				if hit.model ~= c.character and hit.humanoid.Health > 0 and hit.model.Parent and Targeting.canHarm(c.player, hit.model) then
					local dealt, result = DamageModel.hit(c, hit, shape.share, "shape", { noFalloff = true })
					PropertyBehaviour.apply(c, hit, dealt, result, behaviour)
					send(c, { shape = kind, stage = "hit", spots = { hit.root.Position }, radius = 1.5 }, hit.root.Position)
				end
			end
		end)
	elseif kind == "split" then
		local c = later(ctx)
		local others = Targeting.inRadius(point, shape.radius, shape.count, (function()
			local skip = table.clone(struck)
			skip[ctx.character] = true
			return skip
		end)())
		local to: { Vector3 } = {}
		for _, hit in others do
			if Targeting.canHarm(ctx.player, hit.model) then
				table.insert(to, hit.root.Position)
			end
		end
		if #to > 0 then
			send(ctx, { shape = kind, stage = "split", from = point, spots = to }, point)
			task.delay(0.15, function()
				for _, hit in others do
					if hit.humanoid.Health > 0 and Targeting.canHarm(c.player, hit.model) then
						local dealt, result = DamageModel.hit(c, hit, shape.share, "shape", { noFalloff = true })
						PropertyBehaviour.apply(c, hit, dealt, result, behaviour)
					end
				end
			end)
		end
	elseif kind == "lob" then
		send(ctx, { shape = kind, stage = "hit", spots = { point }, radius = shape.splash }, point)
		hitAround(ctx, point, shape.splash, shape.share, behaviour, struck)
	elseif kind == "drain" then
		local total = 0
		for _, entry in record do
			if not entry.practice then
				total += entry.dealt
			end
		end
		local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
		if total > 0 and humanoid then
			Damage.heal(humanoid, total * shape.back, ctx.player.UserId, { domain = ctx.stats.domains[1] })
			send(ctx, { shape = kind, stage = "drain", from = point, spots = { ctx.origin } }, point)
		end
	elseif kind == "nova" then
		local c = later(ctx)
		local radius = radiusOf(ctx) * shape.scale
		task.delay(shape.delay, function()
			if alive(c) then
				send(c, { shape = kind, stage = "hit", spots = { point }, radius = radius }, point, true)
				hitAround(c, point, radius, shape.share, behaviour)
			end
		end)
	elseif kind == "linger" or kind == "barrier" then
		startZone(ctx, shape, behaviour, point)
	elseif kind == "erupt" then
		send(ctx, { shape = kind, stage = "hit", spots = { point }, radius = radiusOf(ctx) }, point, true)
		for _, hit in Targeting.inRadius(point, radiusOf(ctx), ctx.stats.maxTargets, { [ctx.character] = true }) do
			if Targeting.canHarm(ctx.player, hit.model) then
				lift(hit, shape.lift + ctx.stats.recipe.power * 2)
			end
		end
	elseif kind == "rain" and spots then
		local c = later(ctx)
		for i, spot in spots do
			if i > 1 then -- the first spot is the main hit's own
				task.delay((i - 1) * 0.12, function()
					if alive(c) then
						send(c, { shape = kind, stage = "drop", spots = { spot }, radius = shape.radius }, spot, true)
						hitAround(c, spot, shape.radius, shape.share, behaviour)
					end
				end)
			end
		end
	elseif kind == "pulse" then
		local c = later(ctx)
		local radius = radiusOf(ctx)
		task.spawn(function()
			for _ = 1, shape.count do
				task.wait(shape.every)
				if not alive(c) then
					return
				end
				local root = c.character:FindFirstChild("HumanoidRootPart")
				if not root or not root:IsA("BasePart") then
					return
				end
				send(c, { shape = kind, stage = "hit", spots = { root.Position }, radius = radius }, root.Position)
				hitAround(c, root.Position, radius, shape.share, behaviour)
			end
		end)
	end
end

-- Lingering areas tick here; one Heartbeat for all of them.
local function step()
	if #zones == 0 then
		return
	end
	local now = os.clock()
	for i = #zones, 1, -1 do
		local zone = zones[i]
		if now >= zone.ends or not alive(zone.ctx) then
			table.remove(zones, i)
			zone.ctx.runtime:cue("shape", { shape = zone.shape.kind, stage = "zoneEnd", id = zone.id, caster = zone.owner }, zone.point, false)
		elseif now >= zone.nextTick then
			zone.nextTick += zone.shape.every
			local ok, err = pcall(tickZone, zone)
			if not ok then
				warn("[Shapes] zone tick: " .. tostring(err))
			end
		end
	end
end

function Shapes.zoneCount(): number
	return #zones
end

if RunService:IsServer() then
	RunService.Heartbeat:Connect(step)
end

return Shapes
