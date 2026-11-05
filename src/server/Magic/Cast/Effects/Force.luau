--!strict
--[[
	Force: momentum, weight, pressure and flow magic that moves things.

	Direction by verb (or params.mode = "pull": everything toward the point, e.g. Space's Fold):
		transfer          pull toward the caster
		redirect          along the caster's aim (caster -> point)
		everything else   away from the point (away from the caster for line forms)
	Speed = force.perPower * power ^ force.exponent, capped at force.maxSpeed.

	Player characters are owned by their clients, so the server can't move them directly: their
	client receives a WorldEffect { kind = "knockback", velocity } (WorldEffectController applies
	it). Ignoring it only denies the player a push against themselves. NPCs and loose
	server-owned parts are moved here. Harmful properties also deal force.harmShare of Impact damage.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Registry = require(Shared.Magic.Registry)
local Cast = script.Parent.Parent
local T = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local Impact = require(script.Parent.Impact)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local EffectBudget = require(Cast.EffectBudget)

local MAX_LOOSE_PARTS = 30
local LINE_FORMS: { [string]: boolean } = { projectile = true, beam = true, chain = true, touch = true }

local Force = {}

local function push(model: Model, root: BasePart, velocity: Vector3)
	local player = Players:GetPlayerFromCharacter(model)
	if player then
		Net.fire("WorldEffect", player, { kind = "knockback", velocity = velocity })
	else
		root.AssemblyLinearVelocity += velocity
	end
end

function Force.resolve(ctx: CastTypes.EffectContext, params: { [string]: any }): CastTypes.Outcome
	local stats = ctx.stats
	local verb = stats.recipe.verb
	local speed = math.min(T.force.maxSpeed, T.force.perPower * math.max(0, ctx.power) ^ T.force.exponent)
	local harmful = Registry.properties[stats.recipe.property].harmful
	local damage = if harmful then Impact.damageFor(ctx.power) * T.force.harmShare else 0
	local aim = Vector3.new(ctx.point.X - ctx.origin.X, 0, ctx.point.Z - ctx.origin.Z)
	local aimDir = if aim.Magnitude > 0.1 then aim.Unit else ctx.root.CFrame.LookVector

	local function directionFor(position: Vector3): Vector3
		if params.mode == "pull" then
			local toward = ctx.point - position
			return if toward.Magnitude > 0.1 then toward.Unit else aimDir
		elseif verb == "transfer" then
			local toward = ctx.origin - position
			return if toward.Magnitude > 0.1 then toward.Unit else -aimDir
		elseif verb == "redirect" or LINE_FORMS[stats.recipe.form] then
			return aimDir
		end
		local away = position - ctx.point
		away = Vector3.new(away.X, 0, away.Z)
		return if away.Magnitude > 0.1 then away.Unit else aimDir
	end

	if ctx.backfire then
		local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
		push(ctx.character, ctx.root, (-aimDir + Vector3.new(0, 0.4, 0)).Unit * speed)
		if humanoid and damage > 0 then
			Damage.apply(humanoid, damage * T.backfireSelfShare, ctx.player.UserId, "backfire")
		end
		return { effective = false, hits = 1, harmedSelf = damage > 0 }
	end

	local moved = 0
	for _, hit in Targeting.select(ctx) do
		local friendly = not Targeting.canHarm(ctx.player, hit.model)
		if friendly and damage > 0 then
			continue -- a harmful push is an attack; PvP rules apply
		end
		push(hit.model, hit.root, (directionFor(hit.root.Position) + Vector3.new(0, 0.25, 0)).Unit * speed)
		if damage > 0 then
			DamageModel.hit(ctx, hit, T.force.harmShare, stats.recipe.property)
		end
		moved += 1
	end

	-- Loose, unanchored, server-owned parts in the area move too (crates, rubble).
	local overlap = OverlapParams.new()
	overlap.MaxParts = MAX_LOOSE_PARTS * 4
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = { ctx.character }
	local radius = if LINE_FORMS[stats.recipe.form] then math.max(4, stats.area * 0.5) else stats.area
	local candidates: { BasePart } = {}
	for _, part in workspace:GetPartBoundsInRadius(ctx.point, radius, overlap) do
		if #candidates >= MAX_LOOSE_PARTS then
			break
		end
		if not part.Anchored and not Targeting.characterOf(part) and part:GetNetworkOwner() == nil then
			table.insert(candidates, part)
		end
	end
	local loose = EffectBudget.takeParts(#candidates)
	for i = 1, loose do
		local part = candidates[i]
		part:ApplyImpulse(directionFor(part.Position) * speed * part.AssemblyMass)
	end
	return { effective = moved > 0 or loose > 0, hits = moved }
end

return Force
