--!strict
--[[
	Terrain: earth and water magic that reshapes the ground (World/TerrainDeform).

		params.op = "stone"      magic stone (temporary, sinks back): wall facing the caster,
		                         pillar, or a ring of spikes for burst/zone
		          = "landslide"  the slope at the point slides downhill (PERSISTENT carve + deposit);
		                         characters in the path are hit and shoved
		          = "pour"       a pool of water from the air (temporary; refused where water is)
		          = "freeze"     the water surface turns to ice (temporary); swimmers caught are
		                         rooted, others slowed; fires go out, parts chill
		          = "tremor"     a local shudder: shake cue, light structure damage, NPCs and
		                         loose parts knocked about. No terrain change: tremors are common,
		                         and only quakes (route `earthquake`) scar the world.
	Backfires: stone crumbles; a landslide starts under the caster; ice closes around the caster.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Cast = script.Parent.Parent
local World = Cast.Parent.Parent.World
local T = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local Damage = require(Cast.Damage)
local StatusEffects = require(Cast.StatusEffects)
local ThermalSim = require(Cast.ThermalSim)
local FireSim = require(Cast.FireSim)
local EffectBudget = require(Cast.EffectBudget)
local TerrainDeform = require(World.TerrainDeform)
local Impact = require(script.Parent.Impact)
local DamageModel = require(Cast.DamageModel)

local Terrain = {}

local function shove(hit: Targeting.Hit, velocity: Vector3)
	local player = Players:GetPlayerFromCharacter(hit.model)
	if player then
		Net.fire("WorldEffect", player, { kind = "knockback", velocity = velocity })
	else
		hit.root.AssemblyLinearVelocity += velocity
	end
end

local function blocked(cframe: CFrame, size: Vector3): boolean
	local params = OverlapParams.new()
	params.MaxParts = 200
	for _, part in workspace:GetPartBoundsInBox(cframe, size, params) do
		if Targeting.characterOf(part) then
			return true
		end
	end
	return false
end

local function stone(ctx: CastTypes.EffectContext): CastTypes.Outcome
	if ctx.backfire then
		return { effective = false, hits = 0, note = "The stone crumbles before it can rise." }
	end
	local stats = ctx.stats
	local height = T.construct.heightBase + T.construct.heightPerPower * stats.recipe.power
	local lifetime = math.clamp(stats.duration * 2, 10, 120)
	local base = TerrainDeform.surfaceAt(ctx.world, ctx.point.X, ctx.point.Z)
	local form = stats.recipe.form

	local pieces: { { cf: CFrame, size: Vector3 } } = {}
	if form == "wall" then
		local center = Vector3.new(ctx.point.X, base + height / 2 - 1, ctx.point.Z)
		local facing = Vector3.new(ctx.origin.X, center.Y, ctx.origin.Z)
		local cf = if (facing - center).Magnitude > 0.1 then CFrame.lookAt(center, facing) else CFrame.new(center)
		table.insert(pieces, { cf = cf, size = Vector3.new(math.clamp(stats.area * 2, 6, 60), height, 3) })
	elseif form == "pillar" then
		local side = math.clamp(stats.area, 4, 16)
		table.insert(pieces, { cf = CFrame.new(ctx.point.X, base + height / 2 - 1, ctx.point.Z), size = Vector3.new(side, height, side) })
	else
		-- Burst / zone: a ring of spikes around the point.
		local ring = math.clamp(stats.area * 0.6, 4, 30)
		for i = 0, 5 do
			local angle = i * math.pi / 3
			local p = ctx.point + Vector3.new(math.cos(angle), 0, math.sin(angle)) * ring
			local y = TerrainDeform.surfaceAt(ctx.world, p.X, p.Z)
			table.insert(pieces, { cf = CFrame.new(p.X, y + height * 0.35, p.Z), size = Vector3.new(3, height * 0.8, 3) })
		end
	end

	local raised = 0
	for _, piece in pieces do
		if blocked(piece.cf, piece.size) then
			continue
		end
		if TerrainDeform.raiseStone(piece.cf, piece.size, lifetime) then
			raised += 1
		end
	end
	if raised == 0 then
		return { effective = false, hits = 0, note = "Something stands in the way." }
	end
	return { effective = true, hits = 0 }
end

local function landslide(ctx: CastTypes.EffectContext): CastTypes.Outcome
	local stats = ctx.stats
	local center = if ctx.backfire then ctx.origin else ctx.point
	local ops, downhill = TerrainDeform.landslide(ctx.world, center, stats.area, ctx.rng)
	if not ops or typeof(downhill) ~= "Vector3" then
		return { effective = false, hits = 0, note = "The ground here is too flat to slide." }
	end
	TerrainDeform.commit(ctx.world, "landslide", ops)
	local path = center + downhill * stats.area
	local amount = Impact.damageFor(ctx.power) * 0.5
	local hits = 0
	for _, hit in Targeting.inRadius(path, math.max(stats.area, 8), stats.maxTargets) do
		local own = hit.model == ctx.character
		if own or Targeting.canHarm(ctx.player, hit.model) then
			if own then
				Damage.apply(hit.humanoid, amount, ctx.player.UserId, "landslide")
			else
				DamageModel.hit(ctx, hit, 0.5, "landslide", { noFalloff = true })
			end
			shove(hit, downhill * 40 + Vector3.new(0, 10, 0))
			hits += 1
		end
	end
	ctx.world:damageStructures(path, stats.area, amount, "landslide")
	return { effective = #ops > 0, hits = hits, harmedSelf = ctx.backfire }
end

local function pour(ctx: CastTypes.EffectContext): CastTypes.Outcome
	if ctx.backfire then
		-- Drenched: at least the fire on you goes out.
		local own = ctx.character:FindFirstChildOfClass("Humanoid")
		if own then
			StatusEffects.remove(own, "burning")
			StatusEffects.apply(own, "slow", { duration = 3 })
		end
		return { effective = false, hits = 0, note = "The water crashes down on you instead." }
	end
	local radius = math.clamp(1.5 + ctx.stats.recipe.power * 0.6, 2, 8)
	local position = ctx.point + Vector3.new(0, radius, 0)
	FireSim.extinguish(ctx.point, radius * 2)
	if not TerrainDeform.pour(ctx.world, position, radius, math.clamp(ctx.stats.duration * 3, 15, 60)) then
		return { effective = false, hits = 0, note = "There's already water here, or the world won't hold more." }
	end
	return { effective = true, hits = 0 }
end

local function freeze(ctx: CastTypes.EffectContext): CastTypes.Outcome
	local stats = ctx.stats
	local own = ctx.character:FindFirstChildOfClass("Humanoid")
	if ctx.backfire then
		if own then
			StatusEffects.apply(own, "root", { duration = 3 })
		end
		return { effective = false, hits = 0, harmedSelf = true, note = "The ice closes around your own feet." }
	end
	local radius = math.clamp(stats.area, 4, 30)
	local froze = TerrainDeform.freeze(ctx.world, ctx.point, radius, math.clamp(stats.duration * 2, 10, 60))
	local affected = FireSim.extinguish(ctx.point, radius)
	for _, part in ThermalSim.partsNear(ctx.point, radius, 6) do
		ThermalSim.addHeat(part, -T.thermal.heatPerPower * ctx.power)
		affected += 1
	end
	for _, hit in Targeting.inRadius(ctx.point, radius, stats.maxTargets, { [ctx.character] = true }) do
		if Targeting.canHarm(ctx.player, hit.model) then
			local caught = hit.humanoid:GetState() == Enum.HumanoidStateType.Swimming and froze
			StatusEffects.apply(hit.humanoid, if caught then "root" else "slow", { duration = 4, source = ctx.player.UserId })
			affected += 1
		end
	end
	return { effective = froze or affected > 0, hits = affected }
end

local function tremor(ctx: CastTypes.EffectContext, runtime: any): CastTypes.Outcome
	local stats = ctx.stats
	local center = if ctx.backfire then ctx.origin else ctx.point
	local radius = math.clamp(stats.area * 2, 12, 80)
	runtime:cue("tremor", { radius = radius, magnitude = stats.recipe.power * 0.4 }, center, false)
	local hits = 0
	for _, hit in Targeting.inRadius(center, radius, stats.maxTargets) do
		local own = hit.model == ctx.character
		if (own and ctx.backfire) or (not own and Targeting.canHarm(ctx.player, hit.model)) then
			StatusEffects.apply(hit.humanoid, "slow", { duration = 2, source = ctx.player.UserId })
			if not Players:GetPlayerFromCharacter(hit.model) then
				hit.humanoid:ChangeState(Enum.HumanoidStateType.FallingDown)
			end
			hits += 1
		end
	end
	ctx.world:damageStructures(center, radius, stats.recipe.power * 2, "tremor")
	-- Rattle loose things.
	local params = OverlapParams.new()
	params.MaxParts = 60
	local roots: { BasePart } = {}
	for _, part in workspace:GetPartBoundsInRadius(center, radius, params) do
		if not part.Anchored and not Targeting.characterOf(part) and part:GetNetworkOwner() == nil then
			table.insert(roots, part)
		end
	end
	for i = 1, EffectBudget.takeParts(#roots) do
		roots[i]:ApplyImpulse(Vector3.new(ctx.rng:NextNumber(-1, 1), 1.5, ctx.rng:NextNumber(-1, 1)) * roots[i].AssemblyMass * 8)
	end
	return { effective = ctx.onSurface or hits > 0, hits = hits, harmedSelf = ctx.backfire and hits > 0 }
end

function Terrain.resolve(ctx: CastTypes.EffectContext, params: { [string]: any }): CastTypes.Outcome
	local op = params.op
	if op == "stone" then
		return stone(ctx)
	elseif op == "landslide" then
		return landslide(ctx)
	elseif op == "pour" then
		return pour(ctx)
	elseif op == "freeze" then
		return freeze(ctx)
	elseif op == "tremor" then
		return tremor(ctx, ctx.runtime)
	end
	return { effective = false, hits = 0 }
end

return Terrain
