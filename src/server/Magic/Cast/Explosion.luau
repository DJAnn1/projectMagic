--!strict
--[[
	Explosion: strong area harm throws the world around. Numbers in CombatTuning.explosion.

	WHEN   a harmful spell of a blasting category (Thermal, Kinetic, Energetic) and form (burst,
	       zone, pillar, ritual, and projectiles where they land) at recipe power >= minPower.
	WHAT   within radius (area x radiusMult; projectiles projectileRadius + 0.6 x power):
	         loose parts    unanchored, server-owned, no bigger than maxPartSize: an outward
	                        impulse, impulse x (1 - distance / radius), capped at maxSpeed
	         breakables     ANCHORED parts of models tagged Decor / Breakable / Rubble, at recipe
	                        power >= breakPower: their welds break, they come loose, fly, and are
	                        cleaned up after debrisSeconds (tagged "BlastDebris")
	       Characters are never moved here (the damage and HitReactions knock them down).
	BUDGET at most maxParts per blast, each charged to EffectBudget.takeParts; structures
	       (tag "Structure") are WorldStateService.damageStructures' business and never touched.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

local Cast = script.Parent
local C = require(Cast.Parent.Data.CombatTuning)
local Types = require(game:GetService("ReplicatedStorage").Shared.Magic.Types)
local Targeting = require(Cast.Targeting)
local EffectBudget = require(Cast.EffectBudget)

local X = C.explosion

local Explosion = {}

function Explosion.applies(stats: Types.SpellStats): boolean
	return stats.harmful
		and X.categories[stats.category] == true
		and X.forms[stats.recipe.form] == true
		and stats.recipe.power >= X.minPower
end

function Explosion.radiusFor(stats: Types.SpellStats): number
	if stats.recipe.form == "projectile" then
		return X.projectileRadius + 0.6 * stats.recipe.power
	end
	return math.max(4, stats.area * X.radiusMult)
end

local function taggedAncestor(part: BasePart): Model?
	local model = part:FindFirstAncestorOfClass("Model")
	while model do
		if CollectionService:HasTag(model, "Structure") then
			return nil -- buildings collapse through damageStructures, never piecemeal
		end
		for _, tag in X.breakTags do
			if CollectionService:HasTag(model, tag) then
				return model
			end
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

local function serverOwned(part: BasePart): boolean
	local ok, owner = pcall(part.GetNetworkOwner, part)
	return ok and owner == nil
end

-- Breaks a part's welds and unanchors it; it is cleaned up after debrisSeconds.
local function breakLoose(part: BasePart)
	for _, child in part:GetChildren() do
		if child:IsA("WeldConstraint") or child:IsA("Weld") or child:IsA("Motor6D") then
			child:Destroy()
		end
	end
	part.Anchored = false
	CollectionService:AddTag(part, "BlastDebris")
	Debris:AddItem(part, X.debrisSeconds)
end

--[[
	Blasts loose (and, with enough power, breakable) parts away from `center`. `exclude` (the
	caster) is ignored. Returns how many parts moved.
]]
function Explosion.blast(center: Vector3, radius: number, recipePower: number, exclude: Model?): number
	local params = OverlapParams.new()
	params.MaxParts = X.maxParts * 3
	if exclude then
		params.FilterType = Enum.RaycastFilterType.Exclude
		params.FilterDescendantsInstances = { exclude }
	end
	local canBreak = recipePower >= X.breakPower
	local moving: { BasePart } = {}
	local loosen: { [BasePart]: boolean } = {}
	for _, part in workspace:GetPartBoundsInRadius(center, radius, params) do
		if #moving >= X.maxParts then
			break
		end
		if part:IsA("Terrain") or Targeting.characterOf(part) then
			continue
		end
		local s = part.Size
		if math.max(s.X, s.Y, s.Z) > X.maxPartSize then
			continue
		end
		if part.Anchored then
			if canBreak and taggedAncestor(part) then
				loosen[part] = true
				table.insert(moving, part)
			end
		elseif serverOwned(part) then
			table.insert(moving, part)
		end
	end
	local granted = EffectBudget.takeParts(#moving)
	for i = 1, granted do
		local part = moving[i]
		if loosen[part] then
			breakLoose(part)
		end
		local offset = part.Position - center
		local distance = offset.Magnitude
		local direction = (if distance > 0.1 then offset.Unit else Vector3.yAxis) + Vector3.new(0, 0.35, 0)
		local speed = math.min(X.maxSpeed, X.impulse * math.clamp(1 - distance / radius, 0.15, 1) * (0.7 + recipePower * 0.06))
		part.AssemblyLinearVelocity = direction.Unit * speed
		part.AssemblyAngularVelocity = Vector3.new(math.random() - 0.5, math.random() - 0.5, math.random() - 0.5) * 12
	end
	return granted
end

return Explosion
