--!strict
--[[
	Status: every spell whose effect is a condition (Ward, Hex, Fear, Charm, Silence, Haste,
	Stasis, Entangle, Veil...). Which status, and on whom, comes from the route's params
	(Data/EffectLibrary):

		status | statusByVerb | statusByProperty   which StatusEffects id to apply
		cleanse = { ids }                          remove these instead (Purge)
		targets = "hit" | "area" | "allies" | "self"
		    hit     whoever the form reaches (Targeting.select)
		    area    every character within the area except the caster
		    allies  the caster and other PLAYERS in the area (never NPCs: no factions yet)
		    self    the caster
		targetsByForm   { [form] = mode }: overrides `targets` per form (a bolt hits whoever it
		                reaches, an aura works on you and your allies: stage 1b)
		foe / friend    { [form] = mode } chosen by the status itself (stage 1c fallbacks): a
		                harmful one uses `foe`, a helpful one `friend` (and lands on the caster
		                when it reached nobody); unlisted forms reach whoever the form reaches
		selfIfNone      a beneficial status lands on the caster when it reached nobody (Haste)
		reservoir       refills each player reached by this share of their reservoir (+1% per
		                power level): Aether (stage 1b)
		extinguish      fires in the area go out (dry air: Humidity, stage 1b)
		resist          { base, perPower }: resists all damage by this much while it lasts
		                (Keen Senses' Evading, stage 1b)
		magnitude       { base, perPower }: the status's magnitude (Anchor Weight's extra damage)
		impact          share of Impact damage dealt on application (Blighted Bolt, Hex)
		extinguishLights  magic lights in the area go out (Eclipse)
		stopParts       loose server-owned parts in the area stop dead (Stillness)

	Duration = status.minDuration + status.durationPerLevel x power level (clamped).
	Harmful statuses respect PvP (Targeting.canHarm). A backfire turns a harmful status on the
	caster; a beneficial one simply fails.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Cast = script.Parent.Parent
local T = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local StatusEffects = require(Cast.StatusEffects)
local EffectBudget = require(Cast.EffectBudget)
local Impact = require(script.Parent.Impact)
local DamageModel = require(Cast.DamageModel)
local Resistances = require(Cast.Resistances)
local FireSim = require(Cast.FireSim)

local Status = {}

-- Hard control from the stage 1b and 1c routes (targetsByForm, foe/friend) is short whatever the
-- power: 3 s + 1.2 s a level would hold someone in stasis for 15 s at power 10.
local CONTROL_CAPS: { [string]: number } = {
	stasis = 2.5,
	root = 3,
	knockdown = 1.5,
	silence = 3,
	charm = 4,
	fear = 4,
	calm = 4,
	blind = 3,
	dazed = 4,
	chilled = 4,
}

local function statusFor(params: { [string]: any }, recipe: any): string?
	if params.status then
		return params.status
	end
	if params.statusByVerb then
		return params.statusByVerb[recipe.verb]
	end
	if params.statusByProperty then
		return params.statusByProperty[recipe.property]
	end
	return nil
end

local function targetsFor(ctx: CastTypes.EffectContext, mode: string): { Targeting.Hit }
	local own = ctx.character:FindFirstChildOfClass("Humanoid")
	local ownHit: Targeting.Hit? = if own then { model = ctx.character, humanoid = own, root = ctx.root, distance = 0 } else nil
	if mode == "self" then
		return if ownHit then { ownHit } else {}
	elseif mode == "allies" then
		local list: { Targeting.Hit } = if ownHit then { ownHit } else {}
		for _, hit in Targeting.inRadius(ctx.point, math.max(ctx.stats.area, 6), ctx.stats.maxTargets, { [ctx.character] = true }) do
			if Players:GetPlayerFromCharacter(hit.model) then
				table.insert(list, hit)
			end
		end
		return list
	elseif mode == "area" then
		return Targeting.inRadius(ctx.point, ctx.stats.area, ctx.stats.maxTargets, { [ctx.character] = true })
	end
	return Targeting.select(ctx)
end

local function extinguishLights(point: Vector3, radius: number): number
	local count = 0
	for _, construct in CollectionService:GetTagged("MagicConstruct") do
		if construct:IsA("BasePart") and construct:FindFirstChildOfClass("PointLight") and (construct.Position - point).Magnitude <= radius then
			construct:Destroy()
			count += 1
		end
	end
	return count
end

local function stopParts(point: Vector3, radius: number, exclude: Model): number
	local params = OverlapParams.new()
	params.MaxParts = 80
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { exclude }
	local roots: { BasePart } = {}
	local seen: { [BasePart]: boolean } = {}
	for _, part in workspace:GetPartBoundsInRadius(point, radius, params) do
		local root = if part.Anchored or Targeting.characterOf(part) then nil else part.AssemblyRootPart
		if root and not seen[root] and root:GetNetworkOwner() == nil then
			seen[root] = true
			table.insert(roots, root)
		end
	end
	local granted = EffectBudget.takeParts(#roots)
	for i = 1, granted do
		roots[i].AssemblyLinearVelocity = Vector3.zero
		roots[i].AssemblyAngularVelocity = Vector3.zero
	end
	return granted
end

function Status.resolve(ctx: CastTypes.EffectContext, params: { [string]: any }): CastTypes.Outcome
	local stats = ctx.stats
	local recipe = stats.recipe
	local statusId = statusFor(params, recipe)
	local def = if statusId then StatusEffects.defs[statusId] else nil
	local harmful = def ~= nil and def.harmful == true
	local duration = math.clamp(T.status.minDuration + T.status.durationPerLevel * recipe.power, T.status.minDuration, T.status.maxDuration)
	if statusId and CONTROL_CAPS[statusId] and (params.targetsByForm or params.foe or params.friend) then
		duration = math.min(duration, CONTROL_CAPS[statusId])
	end

	local targets: { Targeting.Hit }
	if ctx.backfire then
		if not harmful then
			return { effective = false, hits = 0, note = "The working slips away from you." }
		end
		targets = targetsFor(ctx, "self")
	else
		local mode = (params.targetsByForm and params.targetsByForm[recipe.form]) or params.targets or "hit"
		if params.foe or params.friend then
			local byForm = if harmful then params.foe else params.friend
			mode = (byForm and byForm[recipe.form]) or "hit"
		end
		targets = targetsFor(ctx, mode)
		if #targets == 0 and (params.selfIfNone or params.friend) and not harmful then
			targets = targetsFor(ctx, "self")
		end
	end

	local magnitude = 0
	if def and def.dot then
		magnitude = Impact.damageFor(ctx.power) * T.status.dotShare
	elseif def and def.absorb then
		magnitude = T.status.wardPerPower * math.max(1, ctx.power) ^ 0.7
	end
	if params.magnitude then
		magnitude = params.magnitude.base + params.magnitude.perPower * recipe.power
	end
	-- A ward also resists all magic while it lasts (Cast/Resistances "ward" source).
	local wardResist = if def and def.absorb then Resistances.wardFor(recipe.power) else nil
	if params.resist then
		wardResist = { all = math.min(0.5, params.resist.base + params.resist.perPower * recipe.power) }
	end

	local affected = 0
	for _, hit in targets do
		if harmful and not ctx.backfire and not Targeting.canHarm(ctx.player, hit.model) then
			continue
		end
		if not harmful and not Targeting.canHelp(ctx.player, hit.model) then
			continue -- no outside help in a duel
		end
		if params.cleanse then
			affected += StatusEffects.cleanse(hit.humanoid, params.cleanse)
		elseif statusId and StatusEffects.apply(hit.humanoid, statusId, { duration = duration, magnitude = magnitude, source = ctx.player.UserId, resist = wardResist }) then
			affected += 1
		end
		if params.impact and harmful then
			DamageModel.hit(ctx, hit, params.impact, recipe.property)
		end
		if params.reservoir and not ctx.backfire then
			local player = Players:GetPlayerFromCharacter(hit.model)
			local reservoirs = ctx.services and ctx.services.reservoirs
			local reservoir = player and reservoirs and reservoirs:get(player)
			if player and reservoir and reservoir.current < reservoir.max then
				reservoir.current = math.min(reservoir.max, reservoir.current + reservoir.max * (params.reservoir + 0.01 * recipe.power))
				reservoirs:push(player)
				affected += 1
			end
		end
	end

	if not ctx.backfire then
		if params.extinguishLights then
			affected += extinguishLights(ctx.point, stats.area)
		end
		if params.stopParts then
			affected += stopParts(ctx.point, stats.area, ctx.character)
		end
		if params.extinguish then
			affected += FireSim.extinguish(ctx.point, math.max(stats.area, 8))
		end
	end
	return { effective = affected > 0, hits = affected, harmedSelf = ctx.backfire and harmful }
end

return Status
