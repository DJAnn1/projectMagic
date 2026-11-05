--!strict
--[[
	FireSim: fire that lives on after the spell. Two kinds, both budgeted (EffectBudget):

	PART FIRES   a burning part (ThermalSim ignition, or a fire spell). Burns its Fuel attribute
	             (default: proportional to size and flammability), heats Thermal parts nearby (so
	             fire spreads through a wooden house part by part), sets characters touching it
	             Burning, and ends charred (darkened, Flammability 0).
	GROUND FIRES cells on an 8-stud grid over flammable terrain (grass burns, sand and rock don't).
	             Each tick a cell may spread to a neighbour: chance = fire.spreadChance x terrain
	             flammability x the region's vegetation x a wind factor that strongly prefers
	             downwind. Cells burn out after fire.groundLifetime x flammability; burned regions
	             lose vegetation (WorldStateService, regrows over days) and some cells leave a
	             persistent scorch (grass -> ground) through TerrainDeform's budgeted commit.

	Wind: a slowly turning direction derived from the world seed and the hour (same on every
	server), plus temporary boosts from wind magic (InteractionMatrix "firestorm").
	Water, cold, Dispel and steam call extinguish(position, radius).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Cast = script.Parent
local T = require(Cast.Parent.Data.CastTuning)
local EffectBudget = require(Cast.EffectBudget)
local ThermalSim = require(Cast.ThermalSim)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)

local F = T.fire
local CELL = F.groundCell
local BURN_DPS = 6
local SCORCH_EVERY = 3 -- one persistent scorch op per this many burned-out cells

local FLAMMABLE_TERRAIN: { [Enum.Material]: number } = {
	[Enum.Material.Grass] = 0.8,
	[Enum.Material.LeafyGrass] = 0.95,
	[Enum.Material.Ground] = 0.25,
	[Enum.Material.Mud] = 0.05,
}

type PartFire = { fire: Fire, fuel: number, intensity: number, source: number? }
type GroundFire = { part: BasePart, expires: number, flammability: number, intensity: number, source: number?, x: number, z: number }
type Boost = { position: Vector3, radius: number, mult: number, expires: number }
type Spread = { position: Vector3, intensity: number, source: number? }

local FireSim = {}

local world: any = nil
local worldSeed = 0
local rng = Random.new(0)
local partFires: { [BasePart]: PartFire } = {}
local groundFires: { [string]: GroundFire } = {}
local boosts: { Boost } = {}
local burnedCells = 0
local scorchQueue: { Vector3 } = {}
local scorcher: ((Vector3) -> ())? = nil
local folder: Folder? = nil

local function now(): number
	return workspace:GetServerTimeNow()
end

local function cellKey(x: number, z: number): string
	return math.floor(x / CELL) .. "," .. math.floor(z / CELL)
end

function FireSim.init(worldService: any, seed: number, scorch: (Vector3) -> ())
	world, worldSeed, scorcher = worldService, seed, scorch
	rng = Seed.random(seed, "server", "fire", os.time())
	local f = Instance.new("Folder")
	f.Name = "MagicFires"
	f.Parent = workspace
	folder = f
	ThermalSim.setIgniter(function(part: BasePart, flammability: number)
		FireSim.ignitePart(part, flammability, nil)
	end)
end

-- The prevailing wind: a unit vector that turns slowly over the world hour.
function FireSim.wind(): Vector3
	local hour = math.floor(os.time() / 3600)
	local angle = Seed.random(worldSeed, "world", "wind", hour):NextNumber() * math.pi * 2
	return Vector3.new(math.cos(angle), 0, math.sin(angle))
end

-- Wind magic near a fire makes it spread faster for a while.
function FireSim.boost(position: Vector3, radius: number, mult: number, seconds: number)
	table.insert(boosts, { position = position, radius = radius, mult = mult, expires = now() + seconds })
end

local function boostAt(position: Vector3): number
	local mult = 1
	for _, b in boosts do
		if (b.position - position).Magnitude <= b.radius then
			mult = math.max(mult, b.mult)
		end
	end
	return mult
end

-- ─── Part fires ─────────────────────────────────────────────────────────────

function FireSim.ignitePart(part: BasePart, intensity: number, source: number?): boolean
	if partFires[part] or not part.Parent or Targeting.characterOf(part) then
		return false
	end
	ThermalSim.ensure(part)
	local flammability = (part:GetAttribute("Flammability") :: number?) or 0
	if flammability <= 0 or not EffectBudget.acquire("burningParts") then
		return false
	end
	local volume = part.Size.X * part.Size.Y * part.Size.Z
	local fuel = (part:GetAttribute("Fuel") :: number?) or math.clamp(volume * flammability * 2, 5, 120)
	local fire = Instance.new("Fire")
	fire.Size = math.clamp(math.max(part.Size.X, part.Size.Z) * 1.2, 1, 20)
	fire.Heat = math.clamp(fire.Size, 2, 15)
	fire.Parent = part
	part:SetAttribute("Burning", true)
	partFires[part] = { fire = fire, fuel = fuel, intensity = math.clamp(intensity, 0.2, 2), source = source }
	return true
end

local function endPartFire(part: BasePart, charred: boolean)
	local state = partFires[part]
	if not state then
		return
	end
	partFires[part] = nil
	EffectBudget.release("burningParts")
	state.fire:Destroy()
	if part.Parent then
		part:SetAttribute("Burning", nil)
		if charred then
			part.Color = part.Color:Lerp(Color3.new(0.08, 0.07, 0.06), 0.8)
			part:SetAttribute("Flammability", 0)
		end
	end
end

-- ─── Ground fires ───────────────────────────────────────────────────────────

-- Terrain flammability under a point (0 when nothing burnable), and the surface position.
local function groundAt(x: number, y: number, z: number): (number, Vector3?)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(Vector3.new(x, y + 30, z), Vector3.new(0, -80, 0), params)
	if not hit then
		return 0, nil
	end
	local base = FLAMMABLE_TERRAIN[hit.Material] or 0
	local vegetation = if world then world:vegetationAt(x, z) else 1
	return base * vegetation, hit.Position
end

function FireSim.igniteGround(position: Vector3, intensity: number, source: number?): boolean
	local key = cellKey(position.X, position.Z)
	if groundFires[key] then
		return false
	end
	local cx = (math.floor(position.X / CELL) + 0.5) * CELL
	local cz = (math.floor(position.Z / CELL) + 0.5) * CELL
	local flammability, surface = groundAt(cx, position.Y, cz)
	if flammability < 0.05 or not surface or not EffectBudget.acquire("groundFires") then
		return false
	end
	local anchor = Instance.new("Part")
	anchor.Name = "GroundFire"
	anchor.Anchored = true
	anchor.CanCollide = false
	anchor.CanQuery = false
	anchor.CanTouch = false
	anchor.Transparency = 1
	anchor.Size = Vector3.new(CELL, 1, CELL)
	anchor.Position = surface + Vector3.new(0, 0.5, 0)
	local fire = Instance.new("Fire")
	fire.Size = 4 + 6 * flammability
	fire.Heat = 8
	fire.Parent = anchor
	anchor.Parent = folder or workspace
	groundFires[key] = {
		part = anchor,
		expires = now() + F.groundLifetime * (0.5 + flammability),
		flammability = flammability,
		intensity = intensity,
		source = source,
		x = cx,
		z = cz,
	}
	return true
end

local function endGroundFire(key: string, burnedOut: boolean)
	local cell = groundFires[key]
	if not cell then
		return
	end
	groundFires[key] = nil
	EffectBudget.release("groundFires")
	cell.part:Destroy()
	if burnedOut and world then
		world:setVegetation(cell.x, cell.z, world:vegetationAt(cell.x, cell.z) * 0.85)
		burnedCells += 1
		if burnedCells % SCORCH_EVERY == 0 then
			table.insert(scorchQueue, cell.part.Position)
		end
	end
end

-- ─── Shared ─────────────────────────────────────────────────────────────────

-- Puts out every fire within radius. Returns how many.
function FireSim.extinguish(position: Vector3, radius: number): number
	local count = 0
	for part in partFires do
		if (part.Position - position).Magnitude <= radius then
			endPartFire(part, false)
			count += 1
		end
	end
	for key, cell in groundFires do
		if (cell.part.Position - position).Magnitude <= radius then
			endGroundFire(key, false)
			count += 1
		end
	end
	return count
end

function FireSim.counts(): (number, number)
	local parts, ground = 0, 0
	for _ in partFires do
		parts += 1
	end
	for _ in groundFires do
		ground += 1
	end
	return parts, ground
end

-- Fire burns NPCs and whoever lit it; other players only with pvp_enabled.
local function burnCharacters(position: Vector3, radius: number, intensity: number, source: number?)
	local pvp = FeatureFlags.get("pvp_enabled") == true
	for _, hit in Targeting.inRadius(position, radius, 6) do
		local player = Players:GetPlayerFromCharacter(hit.model)
		if not player or pvp or (source ~= nil and player.UserId == source) then
			StatusEffects.apply(hit.humanoid, "burning", { duration = F.burnStatusSeconds, magnitude = BURN_DPS * intensity, source = source })
		end
	end
end

function FireSim.tick(dt: number)
	local t = now()
	for i = #boosts, 1, -1 do
		if boosts[i].expires <= t then
			table.remove(boosts, i)
		end
	end
	local wind = FireSim.wind()

	-- Part fires: burn fuel, heat neighbours, burn characters. Snapshot first: heating a
	-- neighbour can ignite it, which mustn't add to the table we're walking.
	local burning: { BasePart } = {}
	for part in partFires do
		table.insert(burning, part)
	end
	for _, part in burning do
		local state = partFires[part]
		if not state then
			continue
		end
		if not part.Parent then
			endPartFire(part, false)
			continue
		end
		local flammability = (part:GetAttribute("Flammability") :: number?) or 0.5
		state.fuel -= dt * (1 + flammability) * boostAt(part.Position)
		if state.fuel <= 0 then
			endPartFire(part, true)
			continue
		end
		local reach = math.max(part.Size.X, part.Size.Z) / 2 + 4
		for _, other in ThermalSim.partsNear(part.Position + wind * 2, reach, 4) do
			if other ~= part then
				ThermalSim.addHeat(other, 60 * state.intensity * dt * boostAt(part.Position))
			end
		end
		burnCharacters(part.Position, reach, state.intensity, state.source)
		if rng:NextNumber() < 0.1 * dt * flammability then
			FireSim.igniteGround(part.Position - Vector3.new(0, part.Size.Y / 2, 0), state.intensity, state.source)
		end
	end

	-- Ground fires: spread downwind, burn out.
	local spreads: { Spread } = {}
	for key, cell in groundFires do
		if cell.expires <= t then
			endGroundFire(key, true)
			continue
		end
		local position = cell.part.Position
		burnCharacters(position, CELL * 0.7, cell.intensity, cell.source)
		for _, part in ThermalSim.partsNear(position, CELL, 3) do
			ThermalSim.addHeat(part, 40 * cell.intensity * dt)
		end
		local boost = boostAt(position)
		for _ = 1, 2 do
			local angle = rng:NextNumber() * math.pi * 2
			local dir = Vector3.new(math.cos(angle), 0, math.sin(angle))
			local windFactor = math.max(0.05, 1 + F.windInfluence * 2 * dir:Dot(wind))
			if rng:NextNumber() < F.spreadChance * cell.flammability * windFactor * boost * dt / F.tick then
				table.insert(spreads, { position = position + dir * CELL, intensity = cell.intensity * 0.95, source = cell.source })
			end
		end
	end
	-- Spread after the loop: igniting while iterating groundFires would mutate it mid-walk.
	for _, s in spreads do
		FireSim.igniteGround(s.position, s.intensity, s.source)
	end

	-- Persistent scorch marks, a few at a time, through the terrain budget.
	if #scorchQueue > 0 and scorcher then
		local position = table.remove(scorchQueue, 1) :: Vector3
		task.spawn(scorcher :: (Vector3) -> (), position)
	end
end

return FireSim
