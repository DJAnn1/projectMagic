--!strict
--[[
	ThermalSim: a coarse heat model for parts. Not physics, just enough for magic to warm, chill,
	ignite and conduct believably.

	A part takes part when it's tagged "Thermal" (designers tag candles, torches, haystacks,
	cauldrons), or the first time a spell heats it (ensure() tags it). Its state lives in attributes:
		Temperature    °C (ambient = CastTuning.thermal.ambient)
		HeatCapacity   energy per °C (from material and size; a wick is tiny, a boulder huge)
		Flammability   0..1 (0 = never burns)
		IgnitionPoint  °C at which a flammable part catches (FireSim takes over)
	Designers can override any of them per part (a Candle: IgnitionPoint 60, Flammability 1).

	Only ACTIVE parts (more than 2 °C from ambient) are simulated, at most thermal.maxActive per
	tick, so a thousand tagged props cost nothing until someone heats one:
		conduction   to Thermal parts within conductRadius (share of the difference per second)
		cooling      toward ambient
		ignition     above IgnitionPoint with Flammability > 0 -> FireSim.ignitePart
]]

local CollectionService = game:GetService("CollectionService")

local T = require(script.Parent.Parent.Data.CastTuning)
local Targeting = require(script.Parent.Targeting)
local TimeZones = require(script.Parent.TimeZones)

local TH = T.thermal
local TAG = "Thermal"
local MIN_CAPACITY = 0.5
local MIN_TEMPERATURE = -60

type MaterialHeat = { flammability: number, ignition: number, capacity: number }

-- capacity is per cubic stud; the rest are defaults a designer can override with attributes.
local MATERIALS: { [Enum.Material]: MaterialHeat } = {
	[Enum.Material.Wood] = { flammability = 0.7, ignition = 260, capacity = 0.9 },
	[Enum.Material.WoodPlanks] = { flammability = 0.8, ignition = 240, capacity = 0.9 },
	[Enum.Material.Fabric] = { flammability = 0.95, ignition = 180, capacity = 0.5 },
	[Enum.Material.Grass] = { flammability = 0.9, ignition = 200, capacity = 0.5 },
	[Enum.Material.LeafyGrass] = { flammability = 0.9, ignition = 200, capacity = 0.5 },
	[Enum.Material.Plastic] = { flammability = 0.25, ignition = 350, capacity = 1.2 },
	[Enum.Material.SmoothPlastic] = { flammability = 0.25, ignition = 350, capacity = 1.2 },
	[Enum.Material.Metal] = { flammability = 0, ignition = 1500, capacity = 2.5 },
	[Enum.Material.DiamondPlate] = { flammability = 0, ignition = 1500, capacity = 2.5 },
	[Enum.Material.CorrodedMetal] = { flammability = 0, ignition = 1500, capacity = 2.5 },
	[Enum.Material.Ice] = { flammability = 0, ignition = 9999, capacity = 2 },
	[Enum.Material.Glass] = { flammability = 0, ignition = 1400, capacity = 2 },
}
local DEFAULT_MATERIAL: MaterialHeat = { flammability = 0, ignition = 1200, capacity = 2.2 } -- stone, brick, concrete

local ThermalSim = {}

local activeParts: { [BasePart]: boolean } = {}
local onIgnite: ((BasePart, number) -> ())? = nil

-- FireSim registers itself here (avoids a require cycle).
function ThermalSim.setIgniter(fn: (BasePart, number) -> ())
	onIgnite = fn
end

local function eligible(part: Instance): boolean
	return part:IsA("BasePart") and not part:IsA("Terrain") and not Targeting.characterOf(part)
		and not CollectionService:HasTag(part, "NoMagicEdit")
end

-- Tags and initialises a part for the simulation (attributes a designer set are kept).
function ThermalSim.ensure(part: BasePart)
	if not CollectionService:HasTag(part, TAG) then
		CollectionService:AddTag(part, TAG)
	end
	local m = MATERIALS[part.Material] or DEFAULT_MATERIAL
	if part:GetAttribute("Temperature") == nil then
		part:SetAttribute("Temperature", TH.ambient)
	end
	if part:GetAttribute("HeatCapacity") == nil then
		local volume = part.Size.X * part.Size.Y * part.Size.Z
		part:SetAttribute("HeatCapacity", math.max(MIN_CAPACITY, volume * m.capacity))
	end
	if part:GetAttribute("Flammability") == nil then
		part:SetAttribute("Flammability", m.flammability)
	end
	if part:GetAttribute("IgnitionPoint") == nil then
		part:SetAttribute("IgnitionPoint", m.ignition)
	end
end

function ThermalSim.temperature(part: BasePart): number
	return (part:GetAttribute("Temperature") :: number?) or TH.ambient
end

local function checkIgnition(part: BasePart, temperature: number)
	local flammability = (part:GetAttribute("Flammability") :: number?) or 0
	local ignition = (part:GetAttribute("IgnitionPoint") :: number?) or math.huge
	if flammability > 0 and temperature >= ignition and not part:GetAttribute("Burning") and onIgnite then
		(onIgnite :: (BasePart, number) -> ())(part, flammability)
	end
end

-- Adds (or with a negative value removes) heat energy. Returns the new temperature.
function ThermalSim.addHeat(part: BasePart, energy: number): number
	ThermalSim.ensure(part)
	local capacity = part:GetAttribute("HeatCapacity") :: number
	local temperature = math.max(MIN_TEMPERATURE, ThermalSim.temperature(part) + energy / capacity)
	part:SetAttribute("Temperature", temperature)
	activeParts[part] = true
	checkIgnition(part, temperature)
	return temperature
end

-- Heat-capable parts near a point, nearest first.
function ThermalSim.partsNear(point: Vector3, radius: number, max: number): { BasePart }
	local params = OverlapParams.new()
	params.MaxParts = max * 4
	local found: { BasePart } = {}
	for _, part in workspace:GetPartBoundsInRadius(point, radius, params) do
		if eligible(part) then
			table.insert(found, part)
		end
	end
	table.sort(found, function(a, b)
		return (a.Position - point).Magnitude < (b.Position - point).Magnitude
	end)
	while #found > max do
		table.remove(found)
	end
	return found
end

function ThermalSim.activeCount(): number
	local n = 0
	for _ in activeParts do
		n += 1
	end
	return n
end

function ThermalSim.tick(dt: number)
	local processed = 0
	local params = OverlapParams.new()
	params.MaxParts = 24
	-- Snapshot: conduction (addHeat) activates neighbours, which mustn't join this pass mid-walk.
	local snapshot: { BasePart } = {}
	for part in activeParts do
		table.insert(snapshot, part)
	end
	for _, part in snapshot do
		if not part.Parent then
			activeParts[part] = nil
			continue
		end
		if TimeZones.stopped(part.Position) then
			continue -- a Timestop: its heat stays exactly as it is
		end
		processed += 1
		if processed > TH.maxActive then
			-- Over budget: the excess snaps back to ambient instead of being simulated.
			part:SetAttribute("Temperature", TH.ambient)
			activeParts[part] = nil
			continue
		end
		local temperature = ThermalSim.temperature(part)
		local capacity = (part:GetAttribute("HeatCapacity") :: number?) or MIN_CAPACITY

		-- Conduction to nearby Thermal parts (both sides move toward each other).
		local exchanged = 0
		for _, other in workspace:GetPartBoundsInRadius(part.Position, TH.conductRadius, params) do
			if other ~= part and exchanged < 6 and CollectionService:HasTag(other, TAG) then
				exchanged += 1
				local otherTemperature = ThermalSim.temperature(other)
				local otherCapacity = (other:GetAttribute("HeatCapacity") :: number?) or MIN_CAPACITY
				local energy = TH.conduction * (temperature - otherTemperature) * dt * math.min(capacity, otherCapacity)
				if math.abs(energy) > 0.01 then
					temperature -= energy / capacity
					ThermalSim.addHeat(other, energy)
				end
			end
		end

		-- Cooling toward ambient.
		temperature += (TH.ambient - temperature) * math.min(1, TH.cooling * dt)
		part:SetAttribute("Temperature", temperature)
		checkIgnition(part, temperature)
		if math.abs(temperature - TH.ambient) < 2 then
			part:SetAttribute("Temperature", TH.ambient)
			activeParts[part] = nil
		end
	end
end

return ThermalSim
