--!strict
--[[
	Metal: magnetism. Moves loose metal and pulls chunks out of ore.

		redirect   metal around the CASTER is flung toward the aim point (a hail of iron)
		otherwise  metal around the POINT is pulled toward the caster
	"Metal" = an unanchored, server-owned part of a metal material, or tagged "Metal".
	Ore nodes (anchored parts tagged "Ore", attribute OreAmount, default 5) give up one chunk per
	cast: a small part of the node's material and colour, tagged Metal so it can be pulled again,
	that flies to the destination and lasts 60 s. When OreAmount reaches 0 the node is spent.
	Every moved part spends from the parts budget. A backfire draws metal at the caster.
	Damage: magnetism is a harmful property, so whoever the form reaches (the projectile's hit,
	the beam's line, the area) takes 0.6 of an Impact hit, +0.05 per metal part moved (max 1.0).
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")

local Cast = script.Parent.Parent
local T = require(Cast.Parent.Data.CastTuning)
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local Damage = require(Cast.Damage)
local EffectBudget = require(Cast.EffectBudget)
local Impact = require(script.Parent.Impact)
local DamageModel = require(Cast.DamageModel)

-- Share of an Impact hit the working deals, plus a little per part of real metal that flew.
local M = { baseShare = 0.6, perPartShare = 0.05, maxShare = 1.0 }

local METALS: { [Enum.Material]: boolean } = {
	[Enum.Material.Metal] = true,
	[Enum.Material.DiamondPlate] = true,
	[Enum.Material.CorrodedMetal] = true,
	[Enum.Material.Foil] = true,
}
local MAX_PARTS = 20

local Metal = {}

local function isMetal(part: BasePart): boolean
	return METALS[part.Material] == true or CollectionService:HasTag(part, "Metal")
end

local function launch(part: BasePart, to: Vector3, speed: number)
	local offset = to - part.Position
	if offset.Magnitude < 1 then
		return
	end
	part.AssemblyLinearVelocity = offset.Unit * speed + Vector3.new(0, math.min(30, offset.Magnitude * 0.3), 0)
end

local function chunkFrom(ore: BasePart): BasePart?
	local amount = (ore:GetAttribute("OreAmount") :: number?) or 5
	if amount <= 0 or EffectBudget.takeParts(1) < 1 then
		return nil
	end
	ore:SetAttribute("OreAmount", amount - 1)
	local chunk = Instance.new("Part")
	chunk.Name = "OreChunk"
	chunk.Size = Vector3.new(1.2, 1.2, 1.2)
	chunk.Material = ore.Material
	chunk.Color = ore.Color
	chunk.Position = ore.Position + Vector3.new(0, ore.Size.Y / 2 + 1, 0)
	chunk:SetAttribute("Ore", ore.Name)
	CollectionService:AddTag(chunk, "Metal")
	chunk.Parent = workspace
	Debris:AddItem(chunk, 60)
	return chunk
end

function Metal.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	local stats = ctx.stats
	local speed = math.clamp(T.force.perPower * math.max(0, ctx.power) ^ T.force.exponent, 20, 120)
	local fling = stats.recipe.verb == "redirect" and not ctx.backfire
	local from = if fling then ctx.origin else (if ctx.backfire then ctx.origin else ctx.point)
	local to = if fling then ctx.point else ctx.origin + Vector3.new(0, 3, 0)
	local radius = math.clamp(stats.area + 6, 6, 40)

	local params = OverlapParams.new()
	params.MaxParts = MAX_PARTS * 6
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ctx.character }
	local loose: { BasePart } = {}
	local moved = 0
	for _, part in workspace:GetPartBoundsInRadius(from, radius, params) do
		if #loose >= MAX_PARTS then
			break
		end
		if CollectionService:HasTag(part, "Ore") and part.Anchored then
			local chunk = chunkFrom(part)
			if chunk then
				launch(chunk, to, speed)
				moved += 1
			end
		elseif not part.Anchored and isMetal(part) and not Targeting.characterOf(part) and part:GetNetworkOwner() == nil then
			table.insert(loose, part.AssemblyRootPart or part)
		end
	end
	local granted = EffectBudget.takeParts(#loose)
	for i = 1, granted do
		launch(loose[i], to, speed)
		moved += 1
	end

	if ctx.backfire and moved > 0 then
		local own = ctx.character:FindFirstChildOfClass("Humanoid")
		if own then
			Damage.apply(own, Impact.damageFor(ctx.power) * 0.3, ctx.player.UserId, "backfire")
		end
		return { effective = false, hits = 1, harmedSelf = true, note = "Every scrap of iron nearby comes for you." }
	end

	-- Magnetism is harmful: whoever the form reaches is struck by the working itself (the iron in
	-- their blood and gear wrenched), harder when real metal flew with it. Flung parts alone never
	-- hurt anyone: Roblox physics collisions deal no damage.
	local hits = 0
	if stats.harmful and not ctx.backfire then
		local share = math.min(M.maxShare, M.baseShare + M.perPartShare * moved)
		for _, hit in Targeting.select(ctx) do
			if Targeting.canHarm(ctx.player, hit.model) then
				DamageModel.hit(ctx, hit, share, stats.recipe.property)
				hits += 1
			end
		end
	end
	return {
		effective = moved > 0 or hits > 0,
		hits = hits,
		note = if moved == 0 and hits == 0 then "No loose metal answers." else nil,
	}
end

return Metal
