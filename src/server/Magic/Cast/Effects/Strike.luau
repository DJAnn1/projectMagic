--!strict
--[[
	Strike: a domain's first attack (Shared/Magic/Data/Strikes) for the domains whose root branch
	has no harmful property of its own: Stone Shot, Thornlash, Psychic Spike, Unmake, Shear,
	Hasten Decay, Misfortune. Routed by EffectLibrary's `strike` route (Shared/Magic/Strike.routed).

	Per target: DamageModel.hit at the strike's `share` (so crits, resistances, wards, guards and
	PvP caps all apply), then the rider:
		status    StatusEffects.apply (dot statuses carry dotShare of the base hit over the duration)
		strip     StatusEffects.stripBeneficial
		shove     a sideways push (left or right, seeded)
	Riders have diminishing returns: once a rider lands on a target, the same domain's rider can't
	land on it again for RIDER_LOCKOUT x its duration (min 1.5 s), so a fast caster can't keep
	someone slowed or dazed forever. The damage still lands.

	Strikes are point forms only (touch, projectile, beam, chain), so they never damage
	structures, blast loose parts or conduct.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Types = require(Shared.Magic.Types)
local Strike = require(Shared.Magic.Strike)
local Cast = script.Parent.Parent
local T = require(Cast.Parent.Data.CastTuning)
local C = require(Cast.Parent.Data.CombatTuning)
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local DamageModel = require(Cast.DamageModel)
local StatusEffects = require(Cast.StatusEffects)

local RIDER_LOCKOUT = 2 -- x the rider's duration
local MIN_LOCKOUT = 1.5 -- seconds, for riders without a duration (strip, shove)

local StrikeEffect = {}

-- lockouts[humanoid][domainId] = server time the rider may land again. Weak keys: dead
-- humanoids drop out on their own.
local lockouts: { [Humanoid]: { [string]: number } } = setmetatable({}, { __mode = "k" }) :: any

local function riderReady(humanoid: Humanoid, domainId: string, now: number): boolean
	local byDomain = lockouts[humanoid]
	return not byDomain or (byDomain[domainId] or 0) <= now
end

local function lockRider(humanoid: Humanoid, domainId: string, now: number, duration: number?)
	local byDomain = lockouts[humanoid] or {}
	byDomain[domainId] = now + math.max(MIN_LOCKOUT, (duration or 0) * RIDER_LOCKOUT)
	lockouts[humanoid] = byDomain
end

local function shove(hit: CastTypes.Hit, velocity: Vector3)
	local player = Players:GetPlayerFromCharacter(hit.model)
	if player then
		-- Players own their character's physics: their client applies it (as Force does).
		Net.fire("WorldEffect", player, { kind = "knockback", velocity = velocity })
	else
		hit.root.AssemblyLinearVelocity += velocity
	end
end

-- Returns true if the rider landed.
local function applyRider(ctx: CastTypes.EffectContext, hit: CastTypes.Hit, domainId: string, rider: Types.StrikeRider): boolean
	-- Always roll, even at chance 1, so the cast's seeded stream doesn't depend on the rider.
	local roll = ctx.rng:NextNumber()
	local sideRoll = ctx.rng:NextNumber()
	if roll >= (rider.chance or 1) or hit.humanoid.Health <= 0 then
		return false
	end
	local now = workspace:GetServerTimeNow()
	if not riderReady(hit.humanoid, domainId, now) then
		return false
	end

	local landed = false
	if rider.status then
		local duration = rider.duration or 1
		local magnitude = if rider.dotShare then DamageModel.base(ctx.power) * rider.dotShare / duration else nil
		landed = StatusEffects.apply(hit.humanoid, rider.status, { duration = duration, magnitude = magnitude, source = ctx.player.UserId })
	end
	if rider.strip then
		landed = StatusEffects.stripBeneficial(hit.humanoid, rider.strip) > 0 or landed
	end
	if rider.shove then
		local aim = hit.root.Position - ctx.origin
		aim = Vector3.new(aim.X, 0, aim.Z)
		local forward = if aim.Magnitude > 0.1 then aim.Unit else ctx.root.CFrame.LookVector
		local side = Vector3.new(-forward.Z, 0, forward.X) * (if sideRoll < 0.5 then -1 else 1)
		shove(hit, (side + Vector3.new(0, 0.2, 0)).Unit * rider.shove)
		landed = true
	end
	if landed then
		lockRider(hit.humanoid, domainId, now, rider.duration)
	end
	return landed
end

function StrikeEffect.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	local stats = ctx.stats
	local domainId, def = Strike.routed(stats.recipe)
	if not (domainId and def) then
		-- Only reachable if the route table and Strike disagree; never deal damage by accident.
		return { effective = false, hits = 0, note = "The working finds no edge." }
	end

	if ctx.backfire then
		local own = Targeting.select(ctx)[1]
		if own then
			DamageModel.hit(ctx, own, T.backfireSelfShare, "backfire", { noCrit = true, noFalloff = true })
		end
		return { effective = false, hits = 1, harmedSelf = true }
	end

	local share = def.share or 1
	local dealt = 0
	for index, hit in Targeting.select(ctx) do
		if Targeting.canHarm(ctx.player, hit.model) then
			local falloff = if stats.recipe.form == "chain" then C.damage.chainFalloff ^ (index - 1) else nil
			DamageModel.hit(ctx, hit, share, stats.recipe.property, { falloff = falloff })
			if def.rider then
				applyRider(ctx, hit, domainId, def.rider)
			end
			dealt += 1
		end
	end
	return { effective = dealt > 0, hits = dealt }
end

return StrikeEffect
