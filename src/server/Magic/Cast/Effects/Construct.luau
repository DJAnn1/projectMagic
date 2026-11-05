--!strict
--[[
	Construct: walls and pillars of non-harmful matter (stone, ice, wards). Temporary parts, not
	terrain edits: they'd otherwise pile up in every server's saved deltas. Lifetime is the
	spell's duration (clamped); the caster's construct cap applies.

	A wall faces the caster and is as wide as twice the spell's area; a pillar is a square column.
	Height = construct.heightBase + heightPerPower * power level. It won't form on top of a
	character (that would fling them), and a backfire crumbles it before it forms.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local Cast = script.Parent.Parent
local T = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)
local Constructs = require(Cast.Constructs)
local Targeting = require(Cast.Targeting)

local MATERIALS: { [string]: Enum.Material } = {
	earth = Enum.Material.Slate,
	water = Enum.Material.Ice,
	energy = Enum.Material.Neon,
	life = Enum.Material.LeafyGrass,
	air = Enum.Material.ForceField,
	spirit = Enum.Material.ForceField,
	void = Enum.Material.Glass,
	space = Enum.Material.Glass,
}

local Construct = {}

-- Ground height under a point (terrain or parts, never characters).
local function groundAt(point: Vector3, ignore: { Instance }): number
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local result = workspace:Raycast(point + Vector3.new(0, 40, 0), Vector3.new(0, -120, 0), params)
	return if result then result.Position.Y else point.Y
end

function Construct.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	if ctx.backfire then
		return { effective = false, hits = 0, note = "The shape crumbles before it can form." }
	end
	local stats = ctx.stats
	local domainId = stats.domains[1]
	local height = T.construct.heightBase + T.construct.heightPerPower * stats.recipe.power
	local isWall = stats.recipe.form == "wall"
	local width = math.clamp(stats.area * 2, 4, 60)
	local size = if isWall
		then Vector3.new(width, height, T.construct.thickness)
		else Vector3.new(math.clamp(stats.area, 3, 16), height, math.clamp(stats.area, 3, 16))

	local base = groundAt(ctx.point, { ctx.character })
	local center = Vector3.new(ctx.point.X, base + height / 2, ctx.point.Z)
	local facing = Vector3.new(ctx.origin.X, center.Y, ctx.origin.Z)
	local cframe = if (facing - center).Magnitude > 0.1 then CFrame.lookAt(center, facing) else CFrame.new(center)

	local params = OverlapParams.new()
	params.MaxParts = 200
	for _, part in workspace:GetPartBoundsInBox(cframe, size, params) do
		if Targeting.characterOf(part) then
			return { effective = false, hits = 0, note = "Something stands in the way." }
		end
	end

	local part = Instance.new("Part")
	part.Name = if isWall then "MagicWall" else "MagicPillar"
	part.Anchored = true
	part.Size = size
	part.CFrame = cframe
	part.Material = MATERIALS[domainId] or Enum.Material.SmoothPlastic
	part.Color = Registry.domains[domainId].feel.palette[1]
	part.Transparency = if part.Material == Enum.Material.ForceField or part.Material == Enum.Material.Glass then 0.4 else 0
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = workspace
	Constructs.track(ctx.player, part, math.clamp(stats.duration, T.construct.minLifetime, T.construct.maxLifetime))
	return { effective = true, hits = 0 }
end

return Construct
