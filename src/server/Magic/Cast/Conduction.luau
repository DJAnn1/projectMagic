--!strict
--[[
	Conduction: lightning doesn't stop at whoever it hits. After a conducting spell (charge
	property, CombatTuning.conduction.properties) strikes, the current runs on:

	METAL  a flood fill from metal parts (Metal, DiamondPlate, CorrodedMetal, Foil) within metalReach
	       of the strike, across metal parts within metalLinkGap of each other, up to maxMetalParts.
	       Everyone within metalReach of a charged part is shocked: share x falloffPerHop ^ hops.
	       Clients see arcs from the strike along the metal to each victim.
	WATER  if there's water at the strike (or under someone it struck), everyone IN water (swimming,
	       or standing in a water voxel) within waterRadius is shocked: share, falling to
	       waterFalloffMin at the edge. That includes the caster: lightning into the lake you're
	       standing in is a mistake you survive once (it counts as harming yourself).
	Already-struck characters aren't shocked twice. PvP rules apply (Targeting.canHarm), except
	for the caster's own mistake. Damage goes through DamageModel (resistances: insulated gloves!).

	Cost: one radius query + up to 2 x maxMetalParts box queries (charged to EffectBudget) and a
	few 4-stud ReadVoxels per strike.
]]

local Cast = script.Parent
local C = require(Cast.Parent.Data.CombatTuning)
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local DamageModel = require(Cast.DamageModel)
local EffectBudget = require(Cast.EffectBudget)

local K = C.conduction

local METAL: { [Enum.Material]: boolean } = {}
for _, name in K.metalMaterials do
	local ok, material = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	if ok and material then
		METAL[material] = true
	end
end

local Conduction = {}

function Conduction.conducts(property: string): boolean
	return K.properties[property] == true
end

function Conduction.isMetal(part: BasePart): boolean
	return METAL[part.Material] == true
end

-- True when the 4-stud voxel at `position` (or `probe` studs below it) holds water.
function Conduction.waterAt(position: Vector3, probe: number?): boolean
	local depth = probe or 0
	local low = Vector3.new(position.X - 2, position.Y - 2 - depth, position.Z - 2)
	local high = Vector3.new(position.X + 2, position.Y + 2, position.Z + 2)
	local region = Region3.new(low, high):ExpandToGrid(4)
	local ok, materials, occupancies = pcall(function()
		return workspace.Terrain:ReadVoxels(region, 4)
	end)
	if not ok then
		return false
	end
	local size = materials.Size
	for x = 1, size.X do
		for y = 1, size.Y do
			for z = 1, size.Z do
				if materials[x][y][z] == Enum.Material.Water and occupancies[x][y][z] > 0.3 then
					return true
				end
			end
		end
	end
	return false
end

local function inWater(hit: CastTypes.Hit): boolean
	return hit.humanoid:GetState() == Enum.HumanoidStateType.Swimming or Conduction.waterAt(hit.root.Position, 0)
end

local function metalNear(center: Vector3, radius: number): { BasePart }
	local params = OverlapParams.new()
	params.MaxParts = 60
	local out: { BasePart } = {}
	for _, part in workspace:GetPartBoundsInRadius(center, radius, params) do
		if METAL[part.Material] and not Targeting.characterOf(part) then
			table.insert(out, part)
		end
	end
	return out
end

-- Flood fill across touching metal. Returns parts and their hop count from the strike.
function Conduction.metalNetwork(center: Vector3): ({ BasePart }, { [BasePart]: number })
	local hops: { [BasePart]: number } = {}
	local order: { BasePart } = {}
	local queue: { BasePart } = {}
	for _, part in metalNear(center, K.metalReach) do
		hops[part] = 0
		table.insert(order, part)
		table.insert(queue, part)
	end
	local params = OverlapParams.new()
	params.MaxParts = 40
	local head = 1
	while head <= #queue and #order < K.maxMetalParts do
		local part = queue[head]
		head += 1
		if EffectBudget.takeParts(1) < 1 then
			break
		end
		local grow = Vector3.one * (K.metalLinkGap * 2)
		for _, other in workspace:GetPartBoundsInBox(part.CFrame, part.Size + grow, params) do
			if hops[other] == nil and METAL[other.Material] and not Targeting.characterOf(other) then
				hops[other] = hops[part] + 1
				table.insert(order, other)
				table.insert(queue, other)
				if #order >= K.maxMetalParts then
					break
				end
			end
		end
	end
	return order, hops
end

export type Shock = { hit: CastTypes.Hit, share: number, via: Vector3? }

--[[
	Who the current reaches beyond `struck`, and how hard (pure apart from spatial queries; the
	spec and the admin `conduct` preview use it). `caster` may appear (water only).
]]
function Conduction.reach(point: Vector3, struck: { CastTypes.Hit }, power: number, caster: Model): { Shock }
	local done: { [Model]: boolean } = {}
	for _, h in struck do
		done[h.model] = true
	end
	local shocks: { Shock } = {}

	-- Metal
	local parts, hops = Conduction.metalNetwork(point)
	if #parts > 0 then
		local params = OverlapParams.new()
		params.MaxParts = 40
		local reach = Vector3.one * (K.metalReach * 2)
		for _, part in parts do
			for _, p in workspace:GetPartBoundsInBox(part.CFrame, part.Size + reach, params) do
				local hit = Targeting.characterOf(p)
				if hit and not done[hit.model] and hit.model ~= caster then
					done[hit.model] = true
					table.insert(shocks, { hit = hit, share = K.share * K.falloffPerHop ^ hops[part], via = part.Position })
				end
			end
		end
	end

	-- Water: from the strike point, and from under anyone the bolt struck directly.
	local sources: { Vector3 } = {}
	if Conduction.waterAt(point, K.waterProbe) then
		table.insert(sources, point)
	end
	for _, h in struck do
		if #sources >= 3 then
			break
		end
		if inWater(h) then
			table.insert(sources, h.root.Position)
		end
	end
	if #sources > 0 then
		local radius = K.waterRadiusBase + K.waterRadiusPerPower * (power - 1)
		for _, source in sources do
			for _, hit in Targeting.inRadius(source, radius, 24, done) do
				if inWater(hit) then
					done[hit.model] = true
					local t = math.clamp(hit.distance / radius, 0, 1)
					local share = K.share * (1 - (1 - K.waterFalloffMin) * t)
					table.insert(shocks, { hit = hit, share = share, via = nil })
				end
			end
		end
	end
	return shocks
end

--[[
	Runs the current after a strike: shocks everyone it reaches and cues the visuals.
	Returns (shocked count, harmed the caster).
]]
function Conduction.spread(ctx: CastTypes.EffectContext, struck: { CastTypes.Hit }): (number, boolean)
	local stats = ctx.stats
	local shocks = Conduction.reach(ctx.point, struck, stats.recipe.power, ctx.character)
	local count, harmedSelf = 0, false
	local arcs: { Vector3 } = {}
	local wet = false
	for _, shock in shocks do
		local own = shock.hit.model == ctx.character
		if own or Targeting.canHarm(ctx.player, shock.hit.model) then
			DamageModel.hit(ctx, shock.hit, shock.share * (if own then 0.5 else 1), "conduction", { falloff = 1, noCrit = own })
			count += 1
			harmedSelf = harmedSelf or own
			if shock.via then
				-- strike -> metal -> victim, one arc each
				table.insert(arcs, ctx.point)
				table.insert(arcs, shock.via)
				table.insert(arcs, shock.hit.root.Position)
			else
				wet = true
			end
		end
	end
	local runtime = ctx.runtime
	if runtime then
		for i = 1, #arcs, 3 do
			runtime:cue("spell", {
				stage = "chain",
				caster = ctx.player.UserId,
				domain = stats.domains[1],
				property = "charge", -- conduction is always electric: clients draw lightning
				power = stats.recipe.power,
				masteryTier = stats.masteryTier,
				points = { arcs[i], arcs[i + 1], arcs[i + 2] },
			}, arcs[i + 1], false)
		end
		if wet then
			runtime:cue("conduction", { radius = K.waterRadiusBase + K.waterRadiusPerPower * (stats.recipe.power - 1) }, ctx.point, false)
		end
	end
	return count, harmedSelf
end

return Conduction
