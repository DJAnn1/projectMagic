--!strict
--[[
	LightningRods: metal draws lightning (docs/LightningRods.md; numbers in Data/LightningRods).

	CastService.strike asks LightningRods.bend after a projectile's flight (or straight away for area
	forms) and before the resolver runs. If metal near the landing point outpulls the spot the spell
	was aimed at, the landing moves there:
		- to a metal PART (a lamp post, an anvil, a metal construct): the spell resolves at its top,
		  with no direct target. Conduction then runs the current along the metal into anyone touching
		  it, so a rod grounds a bolt meant for you, and standing against the rod is a bad idea.
		- to a PERSON wearing metal (a guard's chain mail): the spell lands on them instead.
	Nothing is announced. Clients see the bolt jump (a "chain" cue from the old point to the new),
	and CastService passes the bend on through SpellResolved for the Journal (LightningRodService).

	Pure helpers (the spec uses them): radiusFor, partPull, weightPull, score.
	Provider: setMetalProvider(fn(model) -> weight) lets InventoryService-backed code report a
	player's worn metal; NPC gear (Gear_<slot> attributes) is read here directly.

	Cost: one GetPartBoundsInRadius (maxQueryParts) per conducting strike of a listed form.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Cast = script.Parent
local C = require(Cast.Parent.Data.CombatTuning)
local R = require(Cast.Parent.Data.LightningRods)
local Gear = require(Cast.Parent.Data.Gear)
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local ItemDatabase = require(ReplicatedStorage.Shared.Items.ItemDatabase)

local METAL: { [Enum.Material]: boolean } = {}
for _, name in C.conduction.metalMaterials do
	local ok, material = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	if ok and material then
		METAL[material] = true
	end
end

export type Bend = {
	kind: string, -- "metal" | "person"
	from: Vector3,
	to: Vector3,
	part: BasePart?,
	hit: CastTypes.Hit?,
}

local LightningRods = {}

local metalProvider: ((Model) -> number)? = nil

-- Players' worn metal (registered by LightningRodService from their equipped items).
function LightningRods.setMetalProvider(fn: (Model) -> number)
	metalProvider = fn
end

-- ─── Pure ───────────────────────────────────────────────────────────────────

function LightningRods.radiusFor(power: number, stormCharge: number?): number
	local r = (R.radiusBase + R.radiusPerPower * (math.max(1, power) - 1)) * (1 + R.stormRadius * math.clamp(stormCharge or 0, 0, 1))
	return math.min(r, R.radiusMax)
end

-- A metal part's pull from its height and size (0 = too small to matter).
function LightningRods.partPull(size: Vector3): number
	if size.X * size.Y * size.Z < R.minPartVolume then
		return 0
	end
	return math.clamp(size.Y / R.partHeightPerPull, R.partPullMin, R.partPullMax)
end

-- A person's pull from the metal they wear (0 below minWeight).
function LightningRods.weightPull(weight: number): number
	if weight < R.minWeight then
		return 0
	end
	return math.min(weight / R.weightPerPull, R.personPullMax)
end

function LightningRods.score(pull: number, distance: number, radius: number): number
	if pull <= 0 or distance >= radius then
		return 0
	end
	return pull * (1 - distance / radius) ^ R.falloffPower
end

-- ─── World reads ────────────────────────────────────────────────────────────

-- Is this part made of a conducting metal (CombatTuning conduction.metalMaterials)? Also used by
-- Sense sight (Cast/SenseSight).
function LightningRods.isMetal(part: BasePart): boolean
	return METAL[part.Material] == true
end

-- The summed weight of metal-tagged items worn by a character (NPC gear attributes, the
-- player provider, and a manual "MetalCarried" attribute for tests and admins).
function LightningRods.metalWeight(model: Model): number
	local weight = 0
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid then
		for _, slot in Gear.slots do
			local id = humanoid:GetAttribute("Gear_" .. slot)
			local def = if typeof(id) == "string" then ItemDatabase.get(id) else nil
			if def and table.find(def.tags or {}, "metal") then
				weight += def.weight or 0
			end
		end
	end
	local provider = metalProvider
	if provider then
		local ok, w = pcall(provider, model)
		if ok and typeof(w) == "number" then
			weight += w
		end
	end
	local manual = model:GetAttribute("MetalCarried")
	if typeof(manual) == "number" then
		weight += manual
	end
	return weight
end

--[[
	Where a conducting spell really lands. Returns nil when it goes where it was aimed.
	`direct` is true when a projectile already struck someone (never bent).
]]
function LightningRods.bend(ctx: CastTypes.EffectContext, direct: boolean): Bend?
	local stats = ctx.stats
	if direct or ctx.backfire or not R.forms[stats.recipe.form] then
		return nil
	end
	if not C.conduction.properties[stats.recipe.property] then
		return nil
	end
	local env = ctx.context and ctx.context.environment
	local radius = LightningRods.radiusFor(stats.recipe.power, env and env.stormCharge)
	local point = ctx.point

	-- What the bolt was aimed at holds it with `stay`, plus that person's own metal.
	local aimed = if ctx.target then Targeting.characterOf(ctx.target) else nil
	local best = R.stay + (if aimed then LightningRods.weightPull(LightningRods.metalWeight(aimed.model)) else 0)
	local winner: Bend? = nil

	local params = OverlapParams.new()
	params.MaxParts = R.maxQueryParts
	local seen: { [Model]: boolean } = { [ctx.character] = true }
	if aimed then
		seen[aimed.model] = true
	end
	for _, part in workspace:GetPartBoundsInRadius(point, radius, params) do
		local hit = Targeting.characterOf(part)
		if hit then
			if seen[hit.model] then
				continue
			end
			seen[hit.model] = true
			if hit.humanoid.Health <= 0 then
				continue
			end
			local pull = LightningRods.weightPull(LightningRods.metalWeight(hit.model))
			local s = LightningRods.score(pull, (hit.root.Position - point).Magnitude, radius)
			if s > best then
				best = s
				winner = { kind = "person", from = point, to = hit.root.Position, hit = hit }
			end
		elseif METAL[part.Material] and part.CanQuery then
			local top = part.Position + Vector3.new(0, part.Size.Y / 2, 0)
			local s = LightningRods.score(LightningRods.partPull(part.Size), (top - point).Magnitude, radius)
			if s > best then
				best = s
				winner = { kind = "metal", from = point, to = top, part = part }
			end
		end
	end
	if winner and (winner.to - point).Magnitude < R.minBend then
		return nil
	end
	return winner
end

return LightningRods
