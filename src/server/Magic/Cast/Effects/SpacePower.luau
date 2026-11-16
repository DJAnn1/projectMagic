--!strict
--[[
	SpacePower: Space's own powers (docs/Space.md, stage 1). `params.power` in Data/EffectLibrary picks one;
	Cast/SpaceRuntime keeps gates, seals and strides running after the cast. Numbers: Data/SpaceTuning.

		gate     two linked rifts: one in front of you, one at the aim point (Gatecraft)
		swap     you and the target change places (Translocation, transmute position)
		seal     a box nobody crosses: one target (touch/beam/projectile) or everyone in an area
		stride   space folds under your feet: each step covers far more ground (Folding, reduce, aura)
		cut      a rend along the aim: hurts everyone it crosses, and guards can't turn it

	A backfire is Dislocation: you're thrown somewhere, sometimes somewhere awkward.
	Refusals (no room, nobody there) cost nothing further and say why in a note.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Types = require(Shared.Magic.Types)
local S = require(Shared.Magic.Data.SpaceTuning)

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local SpaceRuntime = require(Cast.SpaceRuntime)
local Targeting = require(Cast.Targeting)

local SINGLE: { [string]: boolean } = { touch = true, beam = true, projectile = true }

local SpacePower = {}

function SpacePower.precheck(params: { [string]: any }, _stats: Types.SpellStats, _player: Player): string?
	if FeatureFlags.get("space_powers_enabled") == false then
		return "WORLD_STRAINED"
	end
	if params.power == "gate" and not SpaceRuntime.canOpenGate() then
		return "WORLD_STRAINED"
	end
	return nil
end

local function tierOf(ctx: CastTypes.EffectContext): number
	return ctx.stats.masteryTier or 0
end

-- Dislocation: Space's backfire, and its risk (BacklashService calls SpaceRuntime.dislocate too).
local function dislocate(ctx: CastTypes.EffectContext): CastTypes.Outcome
	local D = S.dislocation
	local studs = math.min(D.maxStuds, S.byTier(D.studs, 0) + ctx.power * D.perPower)
	SpaceRuntime.dislocate(ctx.character, studs, ctx.rng)
	return { effective = false, hits = 0, harmedSelf = true, note = "Space lets go of you, and puts you down somewhere you didn't choose." }
end

local function swap(ctx: CastTypes.EffectContext): CastTypes.Outcome
	local hit: Targeting.Hit? = if ctx.target then Targeting.characterOf(ctx.target) else Targeting.select(ctx, 1)[1]
	if not hit or hit.model == ctx.character then
		return { effective = false, hits = 0, note = "Nothing there to change places with." }
	end
	-- Another player only where you could hurt them (pvp_enabled, not a party member's choice to make).
	if Players:GetPlayerFromCharacter(hit.model) and not Targeting.canHarm(ctx.player, hit.model) then
		return { effective = false, hits = 0, note = "They won't let space move them." }
	end
	if hit.root.Anchored then
		return { effective = false, hits = 0, note = "They're held too fast to move." }
	end
	local mine, theirs = ctx.root.CFrame, hit.root.CFrame
	if (mine.Position - theirs.Position).Magnitude > S.swap.maxStuds then
		return { effective = false, hits = 0, note = "Too far for space to fold that much." }
	end
	hit.model:PivotTo(mine)
	ctx.character:PivotTo(theirs)
	ctx.runtime:cue("space", { fx = "swap", a = mine.Position, b = theirs.Position, caster = ctx.player.UserId }, mine.Position, false)
	return { effective = true, hits = 1 }
end

local function seal(ctx: CastTypes.EffectContext): CastTypes.Outcome
	local form = ctx.stats.recipe.form
	local targets: { Targeting.Hit } = {}
	if SINGLE[form] then
		local one = if ctx.target then Targeting.characterOf(ctx.target) else Targeting.select(ctx, 1)[1]
		if one then
			table.insert(targets, one)
		end
	else
		for _, hit in Targeting.select(ctx) do
			if #targets >= S.seal.areaMax then
				break
			end
			table.insert(targets, hit)
		end
	end
	local seconds = S.byTier(S.seal.seconds, tierOf(ctx))
	local sealed = 0
	for _, hit in targets do
		-- The caster is never sealed by their own area; other players only where you could hurt them.
		if hit.model ~= ctx.character and Targeting.canHarm(ctx.player, hit.model) then
			local isPlayer = Players:GetPlayerFromCharacter(hit.model) ~= nil
			if SpaceRuntime.seal(hit.humanoid, hit.root, if isPlayer then math.min(seconds, S.seal.pvpSeconds) else seconds, ctx.player.UserId) then
				sealed += 1
			end
		end
	end
	if sealed == 0 then
		return { effective = false, hits = 0, note = "Nobody there to close space around." }
	end
	return { effective = true, hits = sealed }
end

local function stride(ctx: CastTypes.EffectContext): CastTypes.Outcome
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return { effective = false, hits = 0 }
	end
	local tier = tierOf(ctx)
	SpaceRuntime.stride(humanoid, S.byTier(S.stride.seconds, tier), S.byTier(S.stride.walk, tier), ctx.player.UserId)
	ctx.runtime:cue("space", { fx = "stride", caster = ctx.player.UserId, model = ctx.character, seconds = S.byTier(S.stride.seconds, tier) }, ctx.origin, false)
	return { effective = true, hits = 0, note = "Space folds under your feet. It lets go the moment you hurt someone." }
end

local function cut(ctx: CastTypes.EffectContext): CastTypes.Outcome
	local hits = 0
	for _, hit in Targeting.select(ctx) do
		if hits >= S.cut.maxTargets then
			break
		end
		if hit.model ~= ctx.character and Targeting.canHarm(ctx.player, hit.model) then
			local result = DamageModel.compute(ctx, hit, S.cut.share)
			Damage.apply(hit.humanoid, result.amount, ctx.player.UserId, "space_cut", {
				domain = ctx.stats.domains[1],
				crit = result.crit,
				power = ctx.stats.recipe.power,
				from = ctx.origin,
				property = ctx.stats.recipe.property,
				pierce = true, -- a cut in space goes round a raised guard, not through it
				form = ctx.stats.recipe.form,
				attacker = ctx.character,
				branch = ctx.stats.recipe.branch,
			})
			hits += 1
		end
	end
	ctx.runtime:cue("space", { fx = "cut", from = ctx.origin + Vector3.new(0, 1.5, 0), to = ctx.point, caster = ctx.player.UserId }, ctx.point, false)
	return { effective = hits > 0, hits = hits, note = if hits == 0 then "Space parts, and closes on nothing." else nil }
end

function SpacePower.resolve(ctx: CastTypes.EffectContext, params: { [string]: any }): CastTypes.Outcome
	if ctx.backfire then
		return dislocate(ctx)
	end
	local power = params.power
	if power == "gate" then
		local seconds = S.byTier(S.gate.seconds, tierOf(ctx))
		local gate, why = SpaceRuntime.openGate(ctx.player.UserId, ctx.origin, ctx.root.CFrame.LookVector, ctx.point, seconds, { ctx.character })
		if not gate then
			return { effective = false, hits = 0, note = why }
		end
		return { effective = true, hits = 0, note = "Two holes in space, joined. Anything can use them." }
	elseif power == "swap" then
		return swap(ctx)
	elseif power == "seal" then
		return seal(ctx)
	elseif power == "stride" then
		return stride(ctx)
	elseif power == "cut" then
		return cut(ctx)
	end
	return { effective = false, hits = 0 }
end

return SpacePower
