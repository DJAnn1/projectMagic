--!strict
--[[
	Conjuring: Reality's Conjuration Summon spells raise whatever was wished for (docs/Reality.md
	"Conjured beings"; owner, 2026-11-13: "reality should be able to summon every kind of elemental
	and more ... as if you're a genie"). Called by Effects/RealityPower (power "summon").

		Conjuring.summon(ctx) -> (count, note?)     raise the spell's beings; count is how many rise

	WHAT RISES: the recipe's `wish` (Shared/Magic/Wishes):
		a being id     that elemental, or one of Reality's own (a colossus, a seraph, a leviathan...)
		"self"         a double of you
		"aim" / none   read the world where the spell lands: a body there (a creature, a Wildborn,
		               a townsperson, a player, an elemental) gives a double of it; else the material
		               it lands on (lava a magma golem, water a tide spirit, metal an iron golem...),
		               a burning part fire, open sky a gale spirit (at night, a shadow wight)
	HOW (the verb, Wishes.plan): generate a host beside you, bind guardians holding the spot,
	transmute one colossus that grows with power.

	Every body is an elemental (Cast/Elementals): the same fight, budget (`maxAlive` on the server),
	damage path and endings. Doubles are capped at RealityTuning.summon.copyMaxParts parts.
]]

local Players = game:GetService("Players")
local Lighting = game:GetService("Lighting")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local Wishes = require(Shared.Magic.Wishes)
local WishData = require(Shared.Magic.Data.Wishes)
local R = require(Shared.Magic.Data.RealityTuning)

local Cast = script.Parent
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local Elementals = require(Cast.Elementals)

type Ctx = CastTypes.EffectContext

local Conjuring = {}

local function domainOf(id: string): string?
	local branch: any = Registry.branches[id]
	return if branch and branch.domains then branch.domains[1] else nil
end

local function exclude(ctx: Ctx): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local list: { Instance } = { ctx.character }
	local folder = workspace:FindFirstChild("Elementals")
	if folder then
		table.insert(list, folder)
	end
	params.FilterDescendantsInstances = list
	return params
end

-- A body where the spell landed: what it was aimed at, else the nearest one within a few studs.
local function bodyAt(ctx: Ctx): Model?
	local target = ctx.target
	if target and target ~= ctx.character and target:FindFirstChildOfClass("Humanoid") then
		return target
	end
	local near = Targeting.inRadius(ctx.point, 6, 1, { [ctx.character] = true })[1]
	return if near then near.model else nil
end

local function partCount(model: Model): number
	local n = 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			n += 1
		end
	end
	return n
end

-- What "aim" raises from the ground (or the sky) at the landing point.
local function beingAt(ctx: Ctx): string
	local hit = workspace:Raycast(ctx.point + Vector3.new(0, 3, 0), Vector3.new(0, -10, 0), exclude(ctx))
	if not hit then
		local clock = Lighting.ClockTime
		return if clock < 6 or clock > 18.5 then WishData.night else WishData.sky
	end
	local instance = hit.Instance
	if instance:GetAttribute("Burning") or instance:FindFirstChildOfClass("Fire") then
		return WishData.fire
	end
	return Wishes.fromMaterial(hit.Material.Name)
end

local function copyIdentity(model: Model): (string, string)
	local player = Players:GetPlayerFromCharacter(model)
	local who: string
	if player then
		who = player.DisplayName
	else
		local named = model:GetAttribute("Elemental")
		who = if typeof(named) == "string" then named else model.Name
	end
	-- People and Wildborn fight with magic; creatures and elementals with their bodies.
	local style = if model:GetAttribute("Creature") ~= nil or model:GetAttribute("ElementalOwner") ~= nil then "strike" else "bolt"
	return "a double of " .. who, style
end

-- Where each body rises: a ring around the landing point, each on the ground, facing the caster.
local function spots(ctx: Ctx, count: number, scale: number): { CFrame }
	local out: { CFrame } = {}
	local params = exclude(ctx)
	local ring = if count > 1 then R.summon.spread * math.max(1, scale) * (0.6 + count * 0.15) else 0
	for i = 1, count do
		local angle = (i / count) * math.pi * 2
		local around = ctx.point + Vector3.new(math.sin(angle) * ring, 0, math.cos(angle) * ring)
		local hit = workspace:Raycast(around + Vector3.new(0, 10, 0), Vector3.new(0, -50, 0), params)
		local ground = if hit then hit.Position else around
		local at = ground + Vector3.new(0, 3 * scale, 0)
		local facing = Vector3.new(ground.X - ctx.origin.X, 0, ground.Z - ctx.origin.Z)
		table.insert(out, if facing.Magnitude > 0.1 then CFrame.lookAt(at, at + facing) else CFrame.new(at))
	end
	return out
end

function Conjuring.summon(ctx: Ctx): (number, string?)
	local recipe: any = ctx.stats.recipe
	local plan = Wishes.plan(recipe.verb, recipe.power, ctx.stats.masteryTier or 0)
	local wish: string = recipe.wish or "aim"
	if not Wishes.isValid("being", wish) then
		wish = "aim"
	end

	local opts: Elementals.SummonOpts = {
		scale = plan.scale,
		healthMult = plan.health,
		shareMult = plan.blow,
		seconds = plan.seconds,
		limit = plan.limit,
	}
	local note: string? = nil
	if wish == "self" then
		opts.copyOf = ctx.character
		opts.copyName = "a double of " .. (if ctx.player then ctx.player.DisplayName else "you")
		opts.copyStyle = "bolt"
	else
		local beingId = wish
		if wish == "aim" then
			local body = bodyAt(ctx)
			if body and partCount(body) <= R.summon.copyMaxParts then
				opts.copyOf = body
				opts.copyName, opts.copyStyle = copyIdentity(body)
			else
				if body then
					note = "That's too vast to copy; the ground answers instead."
				end
				beingId = beingAt(ctx)
			end
		end
		if not opts.copyOf then
			local def, domain = Wishes.being(beingId)
			if not def then
				def, domain = Wishes.being(WishData.fallback)
			end
			opts.def = def
			opts.domain = domain or domainOf(beingId) or "reality"
		end
	end

	local places = spots(ctx, plan.count, plan.scale * ((opts.def and opts.def.scale) or 1))
	if plan.mode == "guard" then
		opts.guardAt = places[1].Position
	end
	-- Building a rig can yield, so the cast's result isn't held up by it.
	for _, place in places do
		local each = table.clone(opts)
		each.at = place
		if plan.mode == "guard" then
			each.guardAt = place.Position
		end
		task.spawn(function()
			local ok, err = pcall(Elementals.summon, ctx, nil, each)
			if not ok then
				warn("[Conjuring] summon: " .. tostring(err))
			end
		end)
	end
	return #places, note
end

return Conjuring
