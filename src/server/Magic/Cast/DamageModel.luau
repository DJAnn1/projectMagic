--!strict
--[[
	DamageModel: how much a spell hurts one target. Every resolver that injures a character calls
	DamageModel.hit, so crits, resistances, falloff and caps are the same for every spell.

		DamageModel.base(power) -> number                      the curve alone (no rolls)
		DamageModel.compute(ctx, hit, share, opts?) -> Result  the full formula, no side effects
		DamageModel.hit(ctx, hit, share, kind, opts?) -> (dealt, Result)   compute + Damage.apply

	FORMULA (numbers in Data/CombatTuning.damage; docs/Combat.md §3)
		amount = base(ctx.power)          perPower x power ^ exponent; power already carries
		                                  affinity, mastery, temperament, resonance, environment
		       x share                    the route's share (an ignite is 0.6 fire + a burn)
		       x falloff                  area forms: 1 at the centre .. areaFalloffMin at the rim;
		                                  chains: chainFalloff ^ hop (opts.falloff)
		       x (1 - resistance)         Cast/Resistances: innate (NPC affinities + traits), wards,
		                                  gear and manual Resist_<key> attributes; clamped
		       x variance                 1 ± (variance + variancePerOverreach x overreach), seeded
		       x critMult on a crit       chance = critBase + critPerTier x masteryTier (+reckless)
		then at least minDamage, at most maxHit, and at most pvpMaxShare of a player's MaxHealth.
	Every roll uses ctx.rng (Seed.random(worldSeed, "player:<id>", "cast", counter)), so a cast's
	damage is reproducible from its seed.
]]

local Players = game:GetService("Players")

local Cast = script.Parent
local C = require(Cast.Parent.Data.CombatTuning)
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local Resistances = require(Cast.Resistances)
local StatusEffects = require(Cast.StatusEffects)

local D = C.damage

local AREA_FORMS: { [string]: boolean } = {
	burst = true, aura = true, zone = true, pillar = true, ritual = true, wall = true, summon = true,
}

export type Options = {
	falloff: number?, -- explicit multiplier (chain hops); skips the area falloff
	noCrit: boolean?,
	noFalloff: boolean?,
}

export type Result = {
	amount: number,
	crit: boolean,
	resist: number, -- the resistance that applied (negative = vulnerable)
	falloff: number,
}

local DamageModel = {}

function DamageModel.base(power: number): number
	return D.perPower * math.max(0, power) ^ D.exponent
end

-- The target's resistance to this spell: every source (innate, ward, gear, manual) through
-- Cast/Resistances, clamped. Hybrids average their domains.
function DamageModel.resistance(humanoid: Humanoid, domains: { string }, property: string): number
	return Resistances.total(humanoid, domains, property)
end

function DamageModel.compute(ctx: CastTypes.EffectContext, hit: CastTypes.Hit, share: number, opts: Options?): Result
	local stats = ctx.stats
	local o: Options = opts or {}
	local amount = DamageModel.base(ctx.power) * share
	local casterHumanoid = ctx.character and ctx.character:FindFirstChildOfClass("Humanoid")
	if casterHumanoid then
		amount *= StatusEffects.damageDealtMult(casterHumanoid) -- Anchor Weight
	end

	local falloff = 1
	if o.falloff then
		falloff = o.falloff
	elseif not o.noFalloff and AREA_FORMS[stats.recipe.form] and stats.area > 0 then
		local center = if stats.recipe.form == "aura" then ctx.origin else ctx.point
		local t = math.clamp((hit.root.Position - center).Magnitude / stats.area, 0, 1)
		falloff = 1 - (1 - D.areaFalloffMin) * t ^ D.areaFalloffCurve
	end
	amount *= falloff

	local resist = DamageModel.resistance(hit.humanoid, stats.domains, stats.recipe.property)
	amount *= 1 - resist

	local spread = D.variance + D.variancePerOverreach * stats.overreach
	amount *= 1 + (ctx.rng:NextNumber() * 2 - 1) * spread

	local crit = false
	if not o.noCrit then
		local chance = D.critBase + D.critPerTier * stats.masteryTier + (if stats.flags.reckless then D.critReckless else 0)
			+ StatusEffects.critTakenBonus(hit.humanoid) -- Jinxed
		if ctx.rng:NextNumber() < math.min(D.critMax, chance) then
			crit = true
			amount *= D.critMult
		end
	end

	if share > 0 then
		amount = math.max(D.minDamage, amount)
	end
	amount = math.min(amount, D.maxHit)
	if Players:GetPlayerFromCharacter(hit.model) then
		amount = math.min(amount, hit.humanoid.MaxHealth * D.pvpMaxShare)
	end
	return { amount = amount, crit = crit, resist = resist, falloff = falloff }
end

-- Computes and deals the damage. `kind` is the damage type NPC memory and logs see.
function DamageModel.hit(ctx: CastTypes.EffectContext, hit: CastTypes.Hit, share: number, kind: string, opts: Options?): (number, Result)
	local result = DamageModel.compute(ctx, hit, share, opts)
	-- NPC casters (NPC/NPCCombat) have no Player: their damage has no source UserId.
	local source = if ctx.player then ctx.player.UserId else nil
	local dealt = Damage.apply(hit.humanoid, result.amount, source, kind, {
		domain = ctx.stats.domains[1],
		crit = result.crit,
		power = ctx.stats.recipe.power,
		from = ctx.origin,
		-- For guards (Cast/Guard): unblockable categories, Piercing, parried touch spells.
		property = ctx.stats.recipe.property,
		pierce = ctx.stats.flags.piercing == true,
		form = ctx.stats.recipe.form,
		attacker = ctx.character,
		branch = ctx.stats.recipe.branch,
	})
	return dealt, result
end

return DamageModel
