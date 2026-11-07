--!strict
--[[
	StationRegistry: every station in every built building, with places to stand (docs/Activities.md §2).

	Buildings are generated without knowing about activities, so stations are found after a building is
	built (Topics.BuildingBuilt) from what's already there (Shared/Life/Data/StationTypes): parts by name
	("Anvil", "TableTop"), parts by Interactable kind ("hearth", "bed", ...), and NPCSeat attachments.

	USE POINTS. For each slot, an Attachment tagged StationUsePoint on the station part, at root height
	(3 studs over the floor), facing the work. It's chosen from the four sides of the station:
		on the floor   a ray down from it lands on a building floor within 0.8 studs of the station's own
		               floor, inside the building's interior box
		clear          a body-sized box there touches no collidable part (the station itself excluded)
		nearest the room's middle first, so people stand inside the room, not against a wall
	A station with fewer valid points than slots keeps what it found; one with none is INVALID: logged
	once (activity_station_invalid) and listed by the stationcheck admin command. Reachability by the
	pathfinder isn't checked here (it costs a path per point); the door fallback in NPCService still puts
	people on the point when the walk fails.

	BODY. Sitting and lying are drawn by the client where the body should be (StationTypes.body): the use
	point carries a BodyCFrame attribute (the bed's mattress, the chair, the bench), so the server's
	Humanoid never has to stand inside furniture.

		StationRegistry.scanLot(lotId, model, settlementId)
		StationRegistry.forget(lotId)
		StationRegistry.inLot(lotId, kind?) -> { Station }
		StationRegistry.inTown(settlementId, kind) -> { Station }
		StationRegistry.byId(id) -> Station?
		StationRegistry.claim(station, npcId) -> slot? · release(station, npcId)
		StationRegistry.usable(station) -> boolean     (still standing, not collapsed)
		StationRegistry.invalid() -> { Station }        StationRegistry.counts() -> { [kind]: number }
]]

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage").Shared
local StationTypes = require(Shared.Life.Data.StationTypes)

local A = StationTypes.ATTR
local ROOT_HEIGHT = 3 -- an R6 root's centre over the floor it stands on
-- What has to be clear where someone stands: an R6 Humanoid only collides with its torso and head (legs
-- and arms don't), so from 2 studs over the floor up. Benches, stools, chair seats and mattresses are lower.
local BODY_BOX = Vector3.new(1.8, 2.5, 1.1)
local BODY_BOX_CENTRE = 0.3 -- over the root (root 3 over the floor: the box spans 2.05 to 4.55)
local FLOOR_TOLERANCE = 0.8

export type Point = { stand: CFrame, body: CFrame?, attachment: Attachment }

export type Station = {
	id: string,
	kind: string,
	lotId: string,
	settlementId: string,
	part: BasePart,
	points: { Point },
	users: { [number]: string }, -- slot -> npc id
	invalid: string?, -- why it has no use point
}

local StationRegistry = {}

local byLot: { [string]: { Station } } = {}
local byIdMap: { [string]: Station } = {}
local byTown: { [string]: { [string]: { Station } } } = {}
local log: any = nil

function StationRegistry.setLog(logger: any)
	log = logger
end

local overlap = OverlapParams.new()
overlap.FilterType = Enum.RaycastFilterType.Exclude
overlap.RespectCanCollide = true

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Exclude

local function excluded(): { Instance }
	local list: { Instance } = {}
	local npcs = workspace:FindFirstChild("NPCs")
	if npcs then
		table.insert(list, npcs)
	end
	for _, player in game:GetService("Players"):GetPlayers() do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	return list
end

-- The building's interior box (BuildingGenerator's InteriorCFrame/InteriorSize), if it has one.
local function interiorOf(model: Model): (CFrame?, Vector3?)
	local cf = model:GetAttribute("InteriorCFrame")
	local size = model:GetAttribute("InteriorSize")
	if typeof(cf) == "CFrame" and typeof(size) == "Vector3" then
		return cf, size
	end
	return nil, nil
end

local function inside(point: Vector3, cf: CFrame?, size: Vector3?): boolean
	if not cf or not size then
		return true -- open structures (the shrine's platform) have no box: anywhere on the floor will do
	end
	local p = cf:PointToObjectSpace(point)
	return math.abs(p.X) <= size.X / 2 + 0.5 and math.abs(p.Z) <= size.Z / 2 + 0.5
end

-- Floor under a spot: the surface Y, or nil when there's nothing solid within reach.
local function floorAt(position: Vector3, ignore: { Instance }): number?
	rayParams.FilterDescendantsInstances = ignore
	local hit = workspace:Raycast(position + Vector3.new(0, 2, 0), Vector3.new(0, -8, 0), rayParams)
	return if hit then hit.Position.Y else nil
end

local function clear(stand: Vector3, station: BasePart, ignore: { Instance }): boolean
	local list = table.clone(ignore)
	table.insert(list, station)
	overlap.FilterDescendantsInstances = list
	local centre = stand + Vector3.new(0, BODY_BOX_CENTRE, 0)
	local hits = workspace:GetPartBoundsInBox(CFrame.new(centre), BODY_BOX, overlap)
	for _, part in hits do
		if part.CanCollide and part.Transparency < 1 then
			return false
		end
	end
	return true
end

-- The nearest table-ish part to face (seats), or nil.
local function nearestTable(model: Model, from: Vector3): BasePart?
	local best, bestD = nil :: BasePart?, 7
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and (d.Name == "TableTop" or d.Name == "Table" or d.Name == "Bar") then
			local dist = (d.Position - from).Magnitude
			if dist < bestD then
				best, bestD = d, dist
			end
		end
	end
	return best
end

local function chairsNear(model: Model, table_: BasePart): { BasePart }
	local out: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and (d.Name == "ChairSeat" or d.Name == "Stool") and (d.Position - table_.Position).Magnitude < 4.5 then
			table.insert(out, d)
		end
	end
	table.sort(out, function(a, b)
		return a.Position.X + a.Position.Z * 0.001 < b.Position.X + b.Position.Z * 0.001
	end)
	return out
end

-- The four sides of a part (in its own axes), each a candidate stand point at `reach` past its face.
local function sides(part: BasePart, reach: number): { Vector3 }
	local cf, size = part.CFrame, part.Size
	return {
		cf:PointToWorldSpace(Vector3.new(0, 0, -(size.Z / 2 + reach))),
		cf:PointToWorldSpace(Vector3.new(0, 0, size.Z / 2 + reach)),
		cf:PointToWorldSpace(Vector3.new(-(size.X / 2 + reach), 0, 0)),
		cf:PointToWorldSpace(Vector3.new(size.X / 2 + reach, 0, 0)),
	}
end

local function lookFlat(from: Vector3, toward: Vector3): CFrame
	local flat = Vector3.new(toward.X, from.Y, toward.Z)
	if (flat - from).Magnitude < 0.05 then
		return CFrame.new(from)
	end
	return CFrame.lookAt(from, flat)
end

--[[
	Candidate stand points for a station part, best first, validated. Each side's floor is measured
	where the person would stand: it must be at or below the station's underside (a bed's seat sits on
	the mattress, a table top on its leg) and no more than 3.5 studs below it (not the street outside, not
	the storey below).
]]
local function standPoints(model: Model, part: BasePart, def: StationTypes.StationType, ignore: { Instance }): { Vector3 }
	local icf, isize = interiorOf(model)
	local middle = if icf then icf.Position else model:GetPivot().Position
	local candidates = sides(part, def.reach)
	table.sort(candidates, function(a, b)
		return (a - middle).Magnitude < (b - middle).Magnitude
	end)
	local bottom = part.Position.Y - part.Size.Y / 2
	local top = part.Position.Y + part.Size.Y / 2
	local out: { Vector3 } = {}
	for _, c in candidates do
		local y = floorAt(Vector3.new(c.X, top, c.Z), ignore)
		if y and y <= bottom + FLOOR_TOLERANCE and y >= bottom - 3.5 and inside(c, icf, isize) then
			local stand = Vector3.new(c.X, y + ROOT_HEIGHT, c.Z)
			if clear(stand, part, ignore) then
				table.insert(out, stand)
			end
		end
	end
	return out
end

local function addPoint(station: Station, slot: number, stand: CFrame, body: CFrame?)
	local attachment = Instance.new("Attachment")
	attachment.Name = "UsePoint" .. slot
	attachment.Parent = station.part
	attachment.WorldCFrame = stand
	attachment:SetAttribute(A.slot, slot)
	attachment:SetAttribute(A.id, station.id)
	if body then
		attachment:SetAttribute(A.body, body)
	end
	CollectionService:AddTag(attachment, StationTypes.POINT_TAG)
	table.insert(station.points, { stand = stand, body = body, attachment = attachment })
end

local function register(station: Station)
	byIdMap[station.id] = station
	byLot[station.lotId] = byLot[station.lotId] or {}
	table.insert(byLot[station.lotId], station)
	local town = byTown[station.settlementId] or {}
	byTown[station.settlementId] = town
	town[station.kind] = town[station.kind] or {}
	table.insert(town[station.kind], station)
	local part = station.part
	part:SetAttribute(A.kind, station.kind)
	part:SetAttribute(A.id, station.id)
	part:SetAttribute(A.active, false)
	part:SetAttribute(A.user, "")
	part:SetAttribute(A.work, "")
	CollectionService:AddTag(part, StationTypes.TAG)
	if station.invalid and log then
		log:debug("activity_station_invalid", { station = station.id, kind = station.kind, why = station.invalid })
	end
end

local function newStation(kind: string, lotId: string, settlementId: string, part: BasePart, n: number): Station
	return { id = string.format("%s:%s%d", lotId, kind, n), kind = kind, lotId = lotId, settlementId = settlementId, part = part, points = {}, users = {}, invalid = nil }
end

-- Finds the stations in one built building and gives them use points. Safe to call again (a rebuild).
function StationRegistry.scanLot(lotId: string, model: Model, settlementId: string)
	StationRegistry.forget(lotId)
	local ignore = excluded()
	local counts: { [string]: number } = {}
	local found: { { kind: string, part: BasePart, seat: Attachment?, noSeat: boolean? } } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			local interactable = d:GetAttribute("Interactable")
			for kind, def in StationTypes.types do
				local byName = def.names and table.find(def.names, d.Name) ~= nil
				local byKind = def.interactables and typeof(interactable) == "string" and table.find(def.interactables, interactable) ~= nil
				if byName or byKind then
					table.insert(found, { kind = kind, part = d })
				end
			end
		elseif d:IsA("Attachment") then
			for kind, def in StationTypes.types do
				local buildingOk = def.buildings == nil or table.find(def.buildings, model:GetAttribute("BuildingType")) ~= nil
				if def.seatTag and buildingOk and CollectionService:HasTag(d, def.seatTag) then
					-- Seat anchors hang off the foundation; the station is the bench or stool under them.
					rayParams.FilterDescendantsInstances = ignore
					local hit = workspace:Raycast(d.WorldPosition + Vector3.new(0, 0.5, 0), Vector3.new(0, -3, 0), rayParams)
					local under = hit and hit.Instance
					if under and under:IsA("BasePart") and under:IsDescendantOf(model) and not CollectionService:HasTag(under, "BuildingFloor") then
						table.insert(found, { kind = kind, part = under, seat = d })
					else
						table.insert(found, { kind = kind, part = d.Parent :: BasePart, seat = d, noSeat = true })
					end
				end
			end
		end
	end
	-- Build order is deterministic, so ids are stable for the same lot.
	table.sort(found, function(a, b)
		if a.kind ~= b.kind then
			return a.kind < b.kind
		end
		local pa = if a.seat then a.seat.WorldPosition else a.part.Position
		local pb = if b.seat then b.seat.WorldPosition else b.part.Position
		if pa.X ~= pb.X then
			return pa.X < pb.X
		end
		return pa.Z < pb.Z
	end)
	for _, f in found do
		local def = StationTypes.types[f.kind]
		local n = (counts[f.kind] or 0) + 1
		counts[f.kind] = n
		local station = newStation(f.kind, lotId, settlementId, f.part, n)
		if def.passive then
			register(station)
			continue
		end
		if f.noSeat then
			-- Not given a part of its own (its attributes would land on the foundation): logged, not registered.
			if log then
				log:debug("activity_station_invalid", { station = station.id, kind = station.kind, why = "no bench or stool under the seat anchor" })
			end
			continue
		end
		local seat = f.seat
		if seat then
			-- One slot: stand beside the bench, sit on the seat facing the table.
			local seatAt = seat.WorldPosition
			local withBench = table.clone(ignore)
			table.insert(withBench, f.part)
			local floorY = floorAt(seatAt, withBench) or (seatAt.Y - 2)
			local seatTop = f.part.Position.Y + f.part.Size.Y / 2
			-- A stand-in the size of a person's footprint on the floor under the seat, so the sides are
			-- measured from the seat itself rather than the whole bench.
			local probe = Instance.new("Part")
			probe.Size = Vector3.new(0.4, 0.4, 0.4)
			probe.CFrame = CFrame.new(seatAt.X, floorY + 0.2, seatAt.Z) * f.part.CFrame.Rotation
			local stands = standPoints(model, probe, def, ignore)
			probe:Destroy()
			local tablePart = nearestTable(model, seatAt)
			local faceAt = if tablePart then tablePart.Position else (interiorOf(model) or model:GetPivot()).Position
			if #stands > 0 then
				local bodyAt = lookFlat(Vector3.new(seatAt.X, seatTop + 1.5, seatAt.Z), faceAt)
				addPoint(station, 1, lookFlat(stands[1], seatAt), bodyAt)
			else
				station.invalid = "no clear floor beside the seat"
			end
			register(station)
			continue
		end
		local stands = standPoints(model, f.part, def, ignore)
		local bodies: { CFrame? } = {}
		if def.body == "self" then
			-- A bed: lying along its length, on the mattress (the seat sits on top of it).
			-- The bed seat sits just over the mattress: a body lying on its back is half a stud thick.
			local top = f.part.Position + Vector3.new(0, 0.3, 0)
			bodies[1] = CFrame.new(top) * f.part.CFrame.Rotation
		elseif def.body == "chairs" then
			for i, chair in chairsNear(model, f.part) do
				bodies[i] = lookFlat(chair.Position + Vector3.new(0, chair.Size.Y / 2 + 1.5, 0), f.part.Position)
			end
		end
		local slots = math.min(def.slots, #stands)
		if def.body == "chairs" then
			slots = math.min(slots, #bodies)
		end
		local taken: { [Vector3]: boolean } = {}
		for slot = 1, slots do
			local stand = stands[slot]
			local body = bodies[slot]
			if def.body == "chairs" and body then
				-- Stand at whichever free valid point is nearest this chair.
				local best, bestD = nil :: Vector3?, math.huge
				for _, s in stands do
					local d = (s - body.Position).Magnitude
					if d < bestD and not taken[s] then
						best, bestD = s, d
					end
				end
				if not best then
					break
				end
				stand = best
			end
			taken[stand] = true
			addPoint(station, slot, lookFlat(stand, f.part.Position), body)
		end
		if #station.points == 0 then
			station.invalid = if #stands == 0 then "no clear floor on any side" else "no chair beside it"
		end
		register(station)
	end
end

function StationRegistry.forget(lotId: string)
	local list = byLot[lotId]
	if not list then
		return
	end
	for _, station in list do
		byIdMap[station.id] = nil
		local town = byTown[station.settlementId]
		local same = town and town[station.kind]
		if same then
			local i = table.find(same, station)
			if i then
				table.remove(same, i)
			end
		end
		for _, point in station.points do
			point.attachment:Destroy()
		end
	end
	byLot[lotId] = nil
end

function StationRegistry.inLot(lotId: string, kind: string?): { Station }
	local out: { Station } = {}
	for _, station in (byLot[lotId] or {}) :: { Station } do
		if kind == nil or station.kind == kind then
			table.insert(out, station)
		end
	end
	return out
end

function StationRegistry.inTown(settlementId: string, kind: string): { Station }
	local town = byTown[settlementId]
	return (town and town[kind]) or {}
end

function StationRegistry.byId(id: string): Station?
	return byIdMap[id]
end

-- Still standing: in the world and anchored (a collapse unanchors a building's parts).
function StationRegistry.usable(station: Station): boolean
	local part = station.part
	return part.Parent ~= nil and part.Anchored and #station.points > 0 and station.invalid == nil
end

-- A free slot for this person (theirs already if they hold one), or nil when it's full.
function StationRegistry.claim(station: Station, npcId: string): number?
	for slot, user in station.users do
		if user == npcId then
			return slot
		end
	end
	for slot = 1, #station.points do
		if station.users[slot] == nil then
			station.users[slot] = npcId
			return slot
		end
	end
	return nil
end

function StationRegistry.release(station: Station, npcId: string)
	for slot, user in station.users do
		if user == npcId then
			station.users[slot] = nil
		end
	end
end

function StationRegistry.firstUser(station: Station): string?
	for slot = 1, #station.points do
		local user = station.users[slot]
		if user then
			return user
		end
	end
	return nil
end

function StationRegistry.invalid(): { Station }
	local out: { Station } = {}
	for _, station in byIdMap do
		if station.invalid then
			table.insert(out, station)
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out
end

function StationRegistry.counts(): ({ [string]: number }, { [string]: number })
	local total: { [string]: number } = {}
	local bad: { [string]: number } = {}
	for _, station in byIdMap do
		total[station.kind] = (total[station.kind] or 0) + 1
		if station.invalid then
			bad[station.kind] = (bad[station.kind] or 0) + 1
		end
	end
	return total, bad
end

return StationRegistry
