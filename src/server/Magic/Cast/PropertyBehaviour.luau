--!strict
--[[
	PropertyBehaviour: what a harmful spell does besides its damage (docs/SpellOverhaul.md §2A,
	stage 1; the behaviours are data in Shared/Magic/Data/PropertyBehaviours).

		PropertyBehaviour.apply(ctx, hit, dealt, result, id?)   after a hit has landed
			Effects/Impact calls it for every target it damaged (id = the recipe's property, or its
			byVerb variant); Effects/Thermal calls it with "heat", "cold" or "combustion".
			Nothing happens when the hit dealt nothing (warded, parried, immune): the extras ride on
			a real hit.
		PropertyBehaviour.idFor(recipe)   which behaviour a recipe gets (property, then byVerb)
		PropertyBehaviour.setStamina(service)   StaminaService registers itself (breath drains it)

	Every status goes through Cast/StatusEffects and every extra damage through DamageModel or a
	status's damage over time (Cast/Damage), so wards, resistances, cleanses and PvP rules apply.
	Knockback on a player goes to their own client (WorldEffect "knockback"), as Effects/Force.
	Chill stacks live here (StatusEffects has no stacks): per humanoid, a count and when it lapses.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Behaviours = require(Shared.Magic.Data.PropertyBehaviours)

local Cast = script.Parent
local CastTypes = require(Cast.CastTypes)
local DamageModel = require(Cast.DamageModel)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)

local PropertyBehaviour = {}

type Stack = { count: number, expires: number }
local stacks: { [Humanoid]: { [string]: Stack } } = setmetatable({}, { __mode = "k" }) :: any
local stamina: any = nil

function PropertyBehaviour.setStamina(service: any)
	stamina = service
end

function PropertyBehaviour.idFor(recipe: { property: string, verb: string }): string?
	local behaviour = Behaviours[recipe.property]
	if not behaviour then
		return nil
	end
	local variant = behaviour.byVerb and behaviour.byVerb[recipe.verb]
	return if variant and Behaviours[variant] then variant else recipe.property
end

local function sourceOf(ctx: CastTypes.EffectContext): number?
	return if ctx.player then ctx.player.UserId else nil
end

-- A status's damage per second from its share of the spell's base hit.
local function dps(effect: { [string]: any }, power: number): number?
	if not effect.dotShare then
		return effect.magnitude
	end
	return DamageModel.base(power) * effect.dotShare / math.max(0.5, effect.duration)
end

local function knock(ctx: CastTypes.EffectContext, hit: CastTypes.Hit, effect: { [string]: any })
	local away = Vector3.new(hit.root.Position.X - ctx.origin.X, 0, hit.root.Position.Z - ctx.origin.Z)
	local dir = if away.Magnitude > 0.1 then away.Unit else ctx.root.CFrame.LookVector
	local speed = (effect.speed or 30) + (effect.perPower or 0) * ctx.power
	local velocity = dir * speed + Vector3.new(0, speed * (effect.up or 0.3), 0)
	local player = Players:GetPlayerFromCharacter(hit.model)
	if player then
		Net.fire("WorldEffect", player, { kind = "knockback", velocity = velocity })
	else
		hit.root.AssemblyLinearVelocity += velocity
	end
end

local function addStack(hit: CastTypes.Hit, effect: { [string]: any }, source: number?)
	local mine = stacks[hit.humanoid]
	if not mine then
		mine = {}
		stacks[hit.humanoid] = mine
	end
	local now = os.clock()
	local s = mine[effect.id]
	if not s or now > s.expires then
		s = { count = 0, expires = 0 }
		mine[effect.id] = s
	end
	s.count += 1
	s.expires = now + effect.duration
	if s.count >= effect.max and effect.at then
		mine[effect.id] = nil
		StatusEffects.remove(hit.humanoid, effect.id)
		StatusEffects.apply(hit.humanoid, effect.at.id, { duration = effect.at.duration, source = source })
	else
		StatusEffects.apply(hit.humanoid, effect.id, { duration = effect.duration, source = source })
	end
end

local function drain(ctx: CastTypes.EffectContext, hit: CastTypes.Hit, effect: { [string]: any })
	local amount = (effect.amount or 0) + (effect.perPower or 0) * ctx.power
	local victim = Players:GetPlayerFromCharacter(hit.model)
	if effect.what == "stamina" then
		if victim and stamina then
			pcall(function()
				stamina:drain(victim, amount)
			end)
		end
		return
	end
	-- Reservoir: a mage's magic burns; anyone else can't cast for a moment.
	local reservoirs = ctx.services and ctx.services.reservoirs
	local theirs = victim and reservoirs and reservoirs:get(victim)
	if victim and theirs then
		local taken = math.clamp(amount, 0, math.max(0, theirs.current))
		theirs.current -= taken
		reservoirs:push(victim)
		local mine = ctx.player and reservoirs:get(ctx.player)
		if mine and effect.back and taken > 0 then
			mine.current = math.min(mine.max, mine.current + taken * effect.back)
			reservoirs:push(ctx.player)
		end
	elseif effect.silence then
		StatusEffects.apply(hit.humanoid, "silence", { duration = effect.silence, source = sourceOf(ctx) })
	end
end

local function grow(hit: CastTypes.Hit, effect: { [string]: any }, start: number, source: number?)
	local humanoid = hit.humanoid
	StatusEffects.apply(humanoid, effect.id, { duration = effect.duration, magnitude = start, source = source })
	for second = 1, math.floor(effect.duration) - 1 do
		task.delay(second, function()
			if humanoid.Parent and humanoid.Health > 0 and StatusEffects.has(humanoid, effect.id) then
				-- apply keeps the strongest magnitude and the longest expiry: only the damage grows.
				StatusEffects.apply(humanoid, effect.id, { duration = 0.1, magnitude = start * effect.factor ^ second, source = source })
			end
		end)
	end
end

local function run(ctx: CastTypes.EffectContext, hit: CastTypes.Hit, effect: { [string]: any }, crit: boolean)
	local power = ctx.power
	if effect.minPower and power < effect.minPower then
		return
	end
	if effect.onCrit and not crit then
		return
	end
	if effect.chance and ctx.rng:NextNumber() >= effect.chance then
		return
	end
	local source = sourceOf(ctx)
	local kind = effect.kind
	if kind == "status" then
		StatusEffects.apply(hit.humanoid, effect.id, { duration = effect.duration, magnitude = dps(effect, power), source = source })
	elseif kind == "stack" then
		addStack(hit, effect, source)
	elseif kind == "knockback" then
		knock(ctx, hit, effect)
	elseif kind == "echo" then
		task.delay(effect.delay, function()
			if hit.humanoid.Parent and hit.humanoid.Health > 0 then
				DamageModel.hit(ctx, hit, effect.share, "echo", { noCrit = true })
			end
		end)
	elseif kind == "drain" then
		drain(ctx, hit, effect)
	elseif kind == "spread" then
		for _, other in Targeting.inRadius(hit.root.Position, effect.radius, 4, { [hit.model] = true, [ctx.character] = true }) do
			if ctx.player == nil or Targeting.canHarm(ctx.player, other.model) then
				StatusEffects.apply(other.humanoid, effect.id, { duration = effect.duration, magnitude = dps(effect, power), source = source })
			end
		end
	elseif kind == "grow" then
		grow(hit, effect, dps(effect, power) or 0, source)
	end
end

-- After a hit that dealt `dealt`: the behaviour's extras.
function PropertyBehaviour.apply(ctx: CastTypes.EffectContext, hit: CastTypes.Hit, dealt: number, result: DamageModel.Result?, id: string?)
	if dealt <= 0 or hit.humanoid.Health <= 0 then
		return
	end
	local behaviourId = id or PropertyBehaviour.idFor(ctx.stats.recipe)
	local behaviour = behaviourId and Behaviours[behaviourId]
	if not behaviour then
		return
	end
	local crit = result ~= nil and result.crit == true
	for _, effect in behaviour.effects do
		local ok, err = pcall(run, ctx, hit, effect, crit)
		if not ok then
			warn("[PropertyBehaviour] " .. tostring(behaviourId) .. " " .. tostring(effect.kind) .. ": " .. tostring(err))
		end
	end
end

return PropertyBehaviour
