--!strict
--[[
	Lamps: building lamps and fireplaces (docs/Buildings.md §3.3). Lights are made switched off;
	this module lights them.

	AUTOMATIC  at night (WorldClock 19:00 to 06:30) a lamp or fireplace is lit when its building
	           is occupied (an NPC rig or a player standing inside the interior box) and a player
	           is within NEAR studs (nobody sees lights out of everyone's sight). Daytime: off.
	BY HAND    the prompt toggles it; a manual choice holds until the next dusk or dawn.
	CAP        at most CAP PointLights lit at once, server-wide: the ones nearest a player win.
	WARMTH     a building with a lit fireplace gets the attribute Warm = true (the survival stage
	           reads it; cooking at a hearth needs it).

		Lamps.register(part) / unregister(part)
		Lamps.isLit(part) / Lamps.set(part, lit, manualPhase?)
		Lamps.phase(hour, day) -> "night:<day>" | "day:<day>"
		Lamps.wanted(isNight, occupied, near) -> boolean          (pure rule; specs)
		Lamps.tick(hour, day, playerRoots, occupantRoots)        every few seconds
		Lamps.onChanged = fn(part)                                (prompt text)
]]

local CollectionService = game:GetService("CollectionService")

local CAP = 60
local NEAR = 320
local DUSK, DAWN = 19, 6.5

local Lamps = {}

Lamps.CAP = CAP
Lamps.onChanged = nil :: ((BasePart) -> ())?

type Entry = { part: BasePart, kind: string, building: Model? }

local entries: { [BasePart]: Entry } = {}

local LAMP_ON, LAMP_OFF = Color3.fromRGB(255, 214, 150), Color3.fromRGB(120, 110, 90)
local FIRE_ON, FIRE_OFF = Color3.fromRGB(255, 120, 40), Color3.fromRGB(60, 50, 45)

local function buildingOf(part: BasePart): Model?
	local node: Instance? = part.Parent
	while node and node ~= workspace do
		if node:IsA("Model") and CollectionService:HasTag(node, "Building") then
			return node
		end
		node = node.Parent
	end
	return nil
end

local function updateWarmth(building: Model?)
	if not building then
		return
	end
	local warm = false
	for _, entry in entries do
		if entry.building == building and entry.kind == "fireplace" and entry.part:GetAttribute("Lit") == true then
			warm = true
			break
		end
	end
	building:SetAttribute("Warm", warm)
end

function Lamps.register(part: BasePart)
	local kind = part:GetAttribute("Interactable")
	if kind ~= "lamp" and kind ~= "fireplace" then
		return
	end
	entries[part] = { part = part, kind = kind :: string, building = buildingOf(part) }
end

function Lamps.unregister(part: BasePart)
	entries[part] = nil
end

function Lamps.isLit(part: BasePart): boolean
	return part:GetAttribute("Lit") == true
end

function Lamps.phase(hour: number, day: number): string
	if hour >= DUSK then
		return "night:" .. day
	elseif hour < DAWN then
		return "night:" .. (day - 1) -- the night that began yesterday evening
	end
	return "day:" .. day
end

function Lamps.wanted(isNight: boolean, occupied: boolean, near: boolean): boolean
	return isNight and occupied and near
end

-- Lights or douses one lamp. `manualPhase` marks a hand choice that holds for that phase.
function Lamps.set(part: BasePart, lit: boolean, manualPhase: string?)
	local entry = entries[part]
	if not entry then
		return
	end
	if manualPhase then
		part:SetAttribute("ManualPhase", manualPhase)
	end
	if Lamps.isLit(part) == lit then
		return
	end
	part:SetAttribute("Lit", lit)
	local light = part:FindFirstChildOfClass("PointLight")
	if light then
		light.Enabled = lit
	end
	if entry.kind == "lamp" then
		part.Material = if lit then Enum.Material.Neon else Enum.Material.Glass
		part.Color = if lit then LAMP_ON else LAMP_OFF
	else
		part.Material = if lit then Enum.Material.Neon else Enum.Material.Slate
		part.Color = if lit then FIRE_ON else FIRE_OFF
		updateWarmth(entry.building)
	end
	local fn = Lamps.onChanged
	if fn then
		fn(part)
	end
end

local function inside(building: Model, p: Vector3): boolean
	local cf = building:GetAttribute("InteriorCFrame")
	local size = building:GetAttribute("InteriorSize")
	if typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return false
	end
	local l = cf:PointToObjectSpace(p)
	return math.abs(l.X) <= size.X / 2 + 0.5 and math.abs(l.Y) <= size.Y / 2 + 3 and math.abs(l.Z) <= size.Z / 2 + 0.5
end

--[[
	The automatic pass. `players` are player root positions; `occupants` every character that can
	make a home occupied (players and NPC rigs). Manual choices for the current phase are kept;
	everything else follows the rule, nearest-first under the cap.
]]
function Lamps.tick(hour: number, day: number, players: { Vector3 }, occupants: { Vector3 })
	local phase = Lamps.phase(hour, day)
	local isNight = string.sub(phase, 1, 5) == "night"
	local occupiedCache: { [Model]: boolean } = {}
	local candidates: { { part: BasePart, distance: number } } = {}
	local manualLit = 0
	for part, entry in entries do
		if not part.Parent then
			entries[part] = nil
			continue
		end
		if part:GetAttribute("ManualPhase") == phase then
			if Lamps.isLit(part) then
				manualLit += 1
			end
			continue
		end
		local nearest = math.huge
		for _, p in players do
			nearest = math.min(nearest, (p - part.Position).Magnitude)
		end
		local building = entry.building
		local occupied = false
		if building then
			local cached = occupiedCache[building]
			if cached == nil then
				cached = false
				for _, p in occupants do
					if inside(building, p) then
						cached = true
						break
					end
				end
				occupiedCache[building] = cached
			end
			occupied = cached
		end
		if Lamps.wanted(isNight, occupied, nearest <= NEAR) then
			table.insert(candidates, { part = part, distance = nearest })
		elseif Lamps.isLit(part) then
			Lamps.set(part, false)
		end
	end
	table.sort(candidates, function(a, b)
		return a.distance < b.distance
	end)
	local budget = math.max(0, CAP - manualLit)
	for i, c in candidates do
		Lamps.set(c.part, i <= budget)
	end
end

function Lamps.litCount(): number
	local n = 0
	for part in entries do
		if Lamps.isLit(part) then
			n += 1
		end
	end
	return n
end

function Lamps.count(): number
	local n = 0
	for _ in entries do
		n += 1
	end
	return n
end

return Lamps
