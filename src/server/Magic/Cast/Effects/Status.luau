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
		selfIfNone      a beneficial status lands on the caster when it reached nobody (Haste)
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

local Status = {}

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

	local targets: { Targeting.Hit }
	if ctx.backfire then
		if not harmful then
			return { effective = false, hits = 0, note = "The working slips away from you." }
		end
		targets = targetsFor(ctx, "self")
	else
		targets = targetsFor(ctx, params.targets or "hit")
		if #targets == 0 and params.selfIfNone and not harmful then
			targets = targetsFor(ctx, "self")
		end
	end

	local magnitude = 0
	if def and def.dot then
		magnitude = Impact.damageFor(ctx.power) * T.status.dotShare
	elseif def and def.absorb then
		magnitude = T.status.wardPerPower * math.max(1, ctx.power) ^ 0.7
	end
	-- A ward also resists all magic while it lasts (Cast/Resistances "ward" source).
	local wardResist = if def and def.absorb then Resistances.wardFor(recipe.power) else nil

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
	end

	if not ctx.backfire then
		if params.extinguishLights then
			affected += extinguishLights(ctx.point, stats.area)
		end
		if params.stopParts then
			affected += stopParts(ctx.point, stats.area, ctx.character)
		end
	end
	return { effective = affected > 0, hits = affected, harmedSelf = ctx.backfire and harmful }
end

return Status
