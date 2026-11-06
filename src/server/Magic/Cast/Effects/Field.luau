--!strict
--[[
	Field: spells that leave a zone behind (Cast/FieldEffects, run by EffectRunner).

		params.field = "time"     reduce -> slow, otherwise haste
		             = "gravity"  weight/density amplify -> heavy, weight reduce or buoyancy -> light,
		                          orientation -> invert
		             = "current"  along the caster's aim (caster -> point)
		             = "reality"  params.ruleByProperty[property]: slick | intangible | transmute
	Placement: aura forms follow the caster; touch makes a small field at the point; everything
	else centres on the point. A backfire centres it on the caster (an inverted field under your
	own feet is its own lesson).
	Crushing: a heavy gravity field cast with a harmful verb (generate, amplify) damages everyone
	inside but the caster once a second (CombatTuning.crush; strongest at the centre). How heavy and
	how hard it crushes both rise with mastery (Data/GravityTuning.field).
	Radius = the spell's area (clamped by FieldEffects); duration = the spell's duration, at least
	5 s, at most field.maxFieldSeconds. Budget refusals come back as a note, not an error.
]]

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Types = require(game:GetService("ReplicatedStorage").Shared.Magic.Types)
local GravityRules = require(game:GetService("ReplicatedStorage").Shared.Magic.GravityRules)
local GravityTuning = require(game:GetService("ReplicatedStorage").Shared.Magic.Data.GravityTuning)
local EffectBudget = require(Cast.EffectBudget)
local FieldEffects = require(Cast.FieldEffects)
local Targeting = require(Cast.Targeting)
local DamageModel = require(Cast.DamageModel)
local C = require(Cast.Parent.Data.CombatTuning)

local REFUSALS: { [string]: string } = {
	active = "You can't hold another working open right now.",
	fields = "Too many workings already bend the world here.",
	mythicFields = "The world won't bend that way again yet. Too much is already bent.",
}

local Field = {}

local function modeFor(kind: string, recipe: any, params: { [string]: any }): string
	if kind == "time" then
		return if recipe.verb == "reduce" then "slow" else "haste"
	elseif kind == "gravity" then
		if recipe.property == "orientation" then
			return "invert"
		elseif recipe.property == "buoyancy" or recipe.verb == "reduce" then
			return "light"
		end
		return "heavy"
	elseif kind == "reality" then
		return (params.ruleByProperty or {})[recipe.property] or "transmute"
	end
	return "flow"
end

-- Refuses before payment when no field slot is free.
function Field.precheck(params: { [string]: any }, _stats: Types.SpellStats, player: Player): string?
	local kind = params.field or "time"
	if not EffectBudget.canAcquireActive(player.UserId) or EffectBudget.available("fields") <= 0 then
		return "WORLD_STRAINED"
	end
	if FieldEffects.isMythic(kind) and EffectBudget.available("mythicFields") <= 0 then
		return "WORLD_STRAINED"
	end
	return nil
end

function Field.resolve(ctx: CastTypes.EffectContext, params: { [string]: any }): CastTypes.Outcome
	local stats = ctx.stats
	local recipe = stats.recipe
	local kind = params.field or "time"
	local mode = modeFor(kind, recipe, params)

	local follow: BasePart? = nil
	local center = ctx.point
	local radius = stats.area
	if recipe.form == "aura" and not ctx.backfire then
		follow = ctx.root
		center = ctx.root.Position
	elseif recipe.form == "touch" then
		radius = math.max(stats.area, 4)
	end
	local flat = Vector3.new(ctx.point.X - ctx.origin.X, 0, ctx.point.Z - ctx.origin.Z)
	local direction = if flat.Magnitude > 0.1 then flat.Unit else ctx.root.CFrame.LookVector

	-- Crushing: heavy gravity cast to harm (weight / density, generate or amplify) damages everyone
	-- inside but the caster, each crush.interval, through DamageModel (resistances, crits, the
	-- PvP cap). Weight is a knockdown kind, so a strong field also knocks people flat.
	local crush: ((any, number) -> ())? = nil
	if kind == "gravity" and mode == "heavy" and stats.harmful and C.crush.verbs[recipe.verb] then
		local share = GravityRules.byTier(GravityTuning.field.crushShare, stats.masteryTier)
		crush = function(hit: any, falloff: number)
			local own = hit.model == ctx.character
			if (own and ctx.backfire) or (not own and Targeting.canHarm(ctx.player, hit.model)) then
				DamageModel.hit(ctx, hit, share, recipe.property, { falloff = falloff, noCrit = own })
			end
		end
	end

	local id, reason = ctx.runtime:startField(kind, mode, center, radius, math.max(stats.duration, 5), {
		follow = follow,
		direction = direction,
		owner = ctx.player.UserId,
		-- Your own heavy / light field leaves you alone (a backfire doesn't).
		spare = if ctx.backfire then nil else ctx.character,
		crush = crush,
		-- Heavier with mastery: a Grandmaster's heavy ground is five times normal gravity.
		gravityMult = if kind == "gravity" then GravityRules.fieldMult(mode, stats.masteryTier) else nil,
	})
	if not id then
		return { effective = false, hits = 0, note = REFUSALS[reason or ""] or "The working won't take hold." }
	end
	return { effective = true, hits = 0, effectId = id, harmedSelf = ctx.backfire }
end

return Field
