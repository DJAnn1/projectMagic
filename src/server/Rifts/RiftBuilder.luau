--!strict
--[[
	RiftBuilder: makes a Rift's parts from its plan (docs/Rifts.md). It only builds; Services/RiftService
	decides what happens to them.

		buildPortal(plan, ground, color) -> (Model, BasePart)    the tear in the world, near a town
		buildInterior(plan, color) -> Interior                   the pocket: a hall, rooms, an arena

	STRUCTURE  Every wall, floor and door is anchored and tagged NoMagicEdit, so fields can't phase or
	           move them and spells can't heat them. A locked door is what stops you skipping a room, so
	           it must hold against everything. Barricade pieces are the exception: they burn, for real.
	BUDGET     About 110 parts for a whole Rift, built only when someone steps in, and all destroyed when
	           it closes. A few PointLights per section. No light in the world reaches a sealed room.
]]

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage").Shared
local R = require(Shared.Rifts.Data.RiftData)

local RiftRules = require(script.Parent.RiftRules)

local rgb = Color3.fromRGB
local M = Enum.Material

local WALL = rgb(38, 32, 52)
local FLOOR = rgb(52, 46, 66)
local THICK = 2

export type RoomParts = {
	section: RiftRules.Section,
	entrance: CFrame, -- where you stand just inside it
	center: Vector3, -- on the floor
	door: BasePart?, -- the way out, until solved
	pieces: { BasePart }, -- barrier: what's left of it
	bridge: { BasePart }, -- chasm: planks, unseen and not solid until earned
	coils: { BasePart }, -- coils: dark until woken
	eyes: { Vector3 }, -- eyes: where they hang
	spots: { Vector3 }, -- where its enemies appear
	farEdge: number?, -- chasm: world X past which you've crossed
}

export type Interior = {
	folder: Folder,
	length: number,
	hall: RoomParts,
	rooms: { RoomParts },
	arena: RoomParts,
	exits: { BasePart }, -- parts carrying a Leave prompt
}

local RiftBuilder = {}

local function block(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): Part
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.CFrame = cframe
	part.Color = color
	part.Material = material
	part.Anchored = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	part.Parent = parent
	return part
end

local function structural(parent: Instance, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material): Part
	local part = block(parent, name, size, cframe, color, material)
	part:SetAttribute("Flammability", 0)
	CollectionService:AddTag(part, "NoMagicEdit")
	return part
end

local function light(parent: BasePart, color: Color3, range: number)
	local point = Instance.new("PointLight")
	point.Color = color
	point.Range = range
	point.Brightness = 1.6
	point.Shadows = false
	point.Parent = parent
end

-- The wall at a section's far end, with a door-sized gap, and (optionally) the door filling it.
local function endWall(parent: Instance, x: number, floorY: number, z: number, withDoor: boolean, accent: Color3): BasePart?
	local w, h = R.width, R.height
	local dw, dh = R.doorWidth, R.doorHeight
	local sideWidth = (w - dw) / 2
	for _, sign in { -1, 1 } do
		structural(parent, "Wall", Vector3.new(THICK, h, sideWidth), CFrame.new(x, floorY + h / 2, z + sign * (dw / 2 + sideWidth / 2)), WALL, M.Slate)
	end
	structural(parent, "Lintel", Vector3.new(THICK, h - dh, dw), CFrame.new(x, floorY + dh + (h - dh) / 2, z), WALL, M.Slate)
	if not withDoor then
		return nil
	end
	local door = structural(parent, "RiftDoor", Vector3.new(1.4, dh, dw), CFrame.new(x, floorY + dh / 2, z), accent, M.Neon)
	door.Transparency = 0.35
	return door
end

-- One section's shell: floor, ceiling, side walls, lights, and the far wall (the arena's has no gap).
local function shell(parent: Instance, section: RiftRules.Section, accent: Color3, withFloor: boolean, sealedEnd: boolean, withDoor: boolean): BasePart?
	local p = R.pocket
	local length, w, h = section.length, R.width, R.height
	local cx = section.startX + length / 2
	if withFloor then
		structural(parent, "Floor", Vector3.new(length, THICK, w), CFrame.new(cx, p.y - THICK / 2, p.z), FLOOR, M.Slate)
	end
	structural(parent, "Ceiling", Vector3.new(length, THICK, w), CFrame.new(cx, p.y + h + THICK / 2, p.z), WALL, M.Basalt)
	for _, sign in { -1, 1 } do
		structural(parent, "Wall", Vector3.new(length, h, THICK), CFrame.new(cx, p.y + h / 2, p.z + sign * (w / 2 + THICK / 2)), WALL, M.Slate)
		local strip = structural(parent, "Glow", Vector3.new(length, 0.6, 0.4), CFrame.new(cx, p.y + h - 2, p.z + sign * (w / 2 - 0.3)), accent, M.Neon)
		strip.CanCollide = false
		strip.CanQuery = false
		light(strip, accent, 42)
	end
	local endX = section.startX + length
	if sealedEnd then
		structural(parent, "Wall", Vector3.new(THICK, h, w), CFrame.new(endX, p.y + h / 2, p.z), WALL, M.Slate)
		return nil
	end
	return endWall(parent, endX, p.y, p.z, withDoor, accent)
end

local function newRoomParts(section: RiftRules.Section): RoomParts
	local p = R.pocket
	return {
		section = section,
		entrance = CFrame.lookAt(Vector3.new(section.startX + 6, p.y + 4, p.z), Vector3.new(section.startX + 20, p.y + 4, p.z)),
		center = Vector3.new(section.startX + section.length / 2, p.y, p.z),
		door = nil,
		pieces = {},
		bridge = {},
		coils = {},
		eyes = {},
		spots = {},
		farEdge = nil,
	}
end

-- Where enemies appear, as a share of the room's length. They have to be on your side of the obstacle:
-- behind a barricade they'd never reach you, and over the drop they'd just fall in.
local SPOT_ALONG: { [string]: number } = { barrier = 0.3, chasm = 0.14, eyes = 0.7, coils = 0.8 }

local function addSpots(parts: RoomParts, kind: string, count: number)
	local s = parts.section
	for i = 1, count do
		local z = R.pocket.z + (i - (count + 1) / 2) * 8
		table.insert(parts.spots, Vector3.new(s.startX + s.length * SPOT_ALONG[kind], R.pocket.y, z))
	end
end

-- A barricade of real, burnable planks across the room, with a few dry crates to spread the fire.
local function fillBarrier(parent: Instance, parts: RoomParts)
	local s = parts.section
	local x = s.startX + s.length * 0.55
	local columns, rows = R.barrierColumns, R.barrierRows
	local pieceW, pieceH = R.width / columns, R.height / rows
	for row = 1, rows do
		for column = 1, columns do
			local z = R.pocket.z - R.width / 2 + (column - 0.5) * pieceW
			local y = R.pocket.y + (row - 0.5) * pieceH
			local piece = block(parent, "Thornwall", Vector3.new(5, pieceH, pieceW), CFrame.new(x + (column % 2) * 1.2, y, z), rgb(84, 60, 38), M.WoodPlanks)
			-- Set so one burning plank just catches its neighbours: fuel lasts ~6 s, at about 20 °C a second
			-- from a neighbour. The Wildfire twist's boost does the same work in half the time.
			piece:SetAttribute("Flammability", 0.9)
			piece:SetAttribute("Fuel", 12)
			piece:SetAttribute("IgnitionPoint", 120)
			piece:SetAttribute("HeatCapacity", 3)
			table.insert(parts.pieces, piece)
		end
	end
	for _, offset in { Vector2.new(-8, -18), Vector2.new(-5, 16), Vector2.new(-11, 6) } do
		local crate = block(parent, "DryCrate", Vector3.new(4, 4, 4), CFrame.new(x + offset.X, R.pocket.y + 2, R.pocket.z + offset.Y), rgb(120, 92, 56), M.Wood)
		crate:SetAttribute("Flammability", 0.9)
		crate:SetAttribute("IgnitionPoint", 120)
		crate:SetAttribute("HeatCapacity", 6)
		CollectionService:AddTag(crate, "Thermal") -- heat only finds tagged parts
	end
end

-- The drop: two stretches of floor, a pit between them, and planks that appear as you earn them.
local function fillChasm(parent: Instance, parts: RoomParts, accent: Color3)
	local s = parts.section
	local p = R.pocket
	local w = R.width
	local gapStart, gapEnd = s.startX + R.chasmStart, s.startX + R.chasmEnd
	structural(parent, "Floor", Vector3.new(R.chasmStart, THICK, w), CFrame.new(s.startX + R.chasmStart / 2, p.y - THICK / 2, p.z), FLOOR, M.Slate)
	local farLength = s.length - R.chasmEnd
	structural(parent, "Floor", Vector3.new(farLength, THICK, w), CFrame.new(gapEnd + farLength / 2, p.y - THICK / 2, p.z), FLOOR, M.Slate)
	-- The pit's box: its floor and four walls, so nothing falls out of the world by accident.
	local gap = gapEnd - gapStart
	local depth = R.chasmDepth
	local mid = (gapStart + gapEnd) / 2
	structural(parent, "PitFloor", Vector3.new(gap, THICK, w), CFrame.new(mid, p.y - depth - THICK / 2, p.z), rgb(14, 10, 22), M.Basalt)
	for _, sign in { -1, 1 } do
		structural(parent, "PitWall", Vector3.new(gap, depth, THICK), CFrame.new(mid, p.y - depth / 2, p.z + sign * (w / 2 + THICK / 2)), WALL, M.Slate)
	end
	structural(parent, "PitWall", Vector3.new(THICK, depth, w), CFrame.new(gapStart - THICK / 2, p.y - depth / 2, p.z), WALL, M.Slate)
	structural(parent, "PitWall", Vector3.new(THICK, depth, w), CFrame.new(gapEnd + THICK / 2, p.y - depth / 2, p.z), WALL, M.Slate)
	local glow = structural(parent, "PitGlow", Vector3.new(gap, 0.4, w), CFrame.new(mid, p.y - depth + 0.4, p.z), accent, M.Neon)
	glow.CanCollide = false
	glow.CanQuery = false
	glow.Transparency = 0.5

	local n = R.bridgeSegments
	local plank = gap / n
	for i = 1, n do
		local segment = structural(parent, "RiftBridge", Vector3.new(plank + 0.2, 1, 12), CFrame.new(gapStart + (i - 0.5) * plank, p.y - 0.5, p.z), accent, M.Glass)
		segment.Transparency = 1
		segment.CanCollide = false
		segment.CanQuery = false
		table.insert(parts.bridge, segment)
	end
	parts.farEdge = gapEnd
	parts.center = Vector3.new(mid, p.y, p.z)
end

local function fillEyes(parts: RoomParts)
	local s = parts.section
	for i = 1, 3 do
		local z = R.pocket.z + (i - 2) * 18
		table.insert(parts.eyes, Vector3.new(s.startX + s.length * 0.68, R.pocket.y + 10, z))
	end
end

local function fillCoils(parent: Instance, parts: RoomParts)
	local s = parts.section
	for i = 1, 3 do
		local z = R.pocket.z + (i - 2) * 18
		local at = Vector3.new(s.startX + s.length * 0.6, R.pocket.y, z)
		structural(parent, "CoilBase", Vector3.new(6, 2, 6), CFrame.new(at + Vector3.new(0, 1, 0)), rgb(70, 60, 50), M.Metal)
		local coil = structural(parent, "Coil", Vector3.new(3, 12, 3), CFrame.new(at + Vector3.new(0, 8, 0)), rgb(60, 50, 44), M.CorrodedMetal)
		table.insert(parts.coils, coil)
	end
end

function RiftBuilder.buildInterior(plan: RiftRules.Plan, accent: Color3): Interior
	local folder = Instance.new("Folder")
	folder.Name = "Rift_" .. plan.id
	local sections = RiftRules.layout(plan.rooms)

	-- The way in: one solid wall behind the hall.
	local p = R.pocket
	structural(folder, "Wall", Vector3.new(THICK, R.height, R.width), CFrame.new(p.x, p.y + R.height / 2, p.z), WALL, M.Slate)

	local hall: RoomParts? = nil
	local arena: RoomParts? = nil
	local rooms: { RoomParts } = {}
	local exits: { BasePart } = {}
	for _, section in sections do
		local parts = newRoomParts(section)
		if section.kind == "hall" then
			shell(folder, section, accent, true, false, false) -- an open gap: only rooms have locked doors
			local gateway = structural(folder, "LeaveGate", Vector3.new(1, 12, 8), CFrame.new(section.startX + 1.5, p.y + 6, p.z), accent, M.Neon)
			gateway.CanCollide = false
			table.insert(exits, gateway)
			parts.entrance = CFrame.lookAt(Vector3.new(section.startX + 12, p.y + 4, p.z), Vector3.new(section.startX + 24, p.y + 4, p.z))
			hall = parts
		elseif section.kind == "arena" then
			shell(folder, section, accent, true, true, false)
			local gate = structural(folder, "LeaveGate", Vector3.new(1, 12, 8), CFrame.new(section.startX + section.length - 2, p.y + 6, p.z), accent, M.Neon)
			gate.CanCollide = false
			table.insert(exits, gate)
			parts.spots = { Vector3.new(section.startX + section.length * 0.6, p.y, p.z) }
			arena = parts
		else
			local def = R.rooms[section.roomId :: string]
			parts.door = shell(folder, section, accent, def.kind ~= "chasm", false, true)
			if def.kind == "barrier" then
				fillBarrier(folder, parts)
			elseif def.kind == "chasm" then
				fillChasm(folder, parts, accent)
			elseif def.kind == "eyes" then
				fillEyes(parts)
			else
				fillCoils(folder, parts)
			end
			addSpots(parts, def.kind, 6)
			table.insert(rooms, parts)
		end
	end
	folder.Parent = workspace
	return {
		folder = folder,
		length = RiftRules.totalLength(#plan.rooms),
		hall = hall :: RoomParts,
		rooms = rooms,
		arena = arena :: RoomParts,
		exits = exits,
	}
end

-- A standing tear with the prompt on it. CanCollide off: you walk into it.
function RiftBuilder.buildPortal(plan: RiftRules.Plan, ground: Vector3, color: Color3): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "RiftPortal_" .. plan.id
	local core = Instance.new("Part")
	core.Name = "Tear"
	core.Shape = Enum.PartType.Ball
	core.Size = Vector3.new(16, 16, 16)
	core.CFrame = CFrame.new(ground + Vector3.new(0, 11, 0))
	core.Color = color
	core.Material = M.Neon
	core.Transparency = 0.25
	core.Anchored = true
	core.CanCollide = false
	core.CanTouch = false
	core.CastShadow = false
	core:SetAttribute("Flammability", 0)
	CollectionService:AddTag(core, "NoMagicEdit")
	core.Parent = model
	model.PrimaryPart = core

	local emitter = Instance.new("ParticleEmitter")
	emitter.Color = ColorSequence.new(color)
	emitter.Rate = 18
	emitter.Lifetime = NumberRange.new(0.8, 1.6)
	emitter.Speed = NumberRange.new(2, 6)
	emitter.SpreadAngle = Vector2.new(180, 180)
	emitter.Size = NumberSequence.new(0.8, 0)
	emitter.LightEmission = 0.9
	emitter.Parent = core
	light(core, color, 50)

	local base = Instance.new("Part")
	base.Name = "Scorch"
	base.Size = Vector3.new(26, 0.4, 26)
	base.CFrame = CFrame.new(ground + Vector3.new(0, 0.25, 0))
	base.Color = rgb(20, 14, 28)
	base.Material = M.Basalt
	base.Anchored = true
	base.CanCollide = false
	base.CanTouch = false
	base.CastShadow = false
	base:SetAttribute("Flammability", 0)
	CollectionService:AddTag(base, "NoMagicEdit")
	base.Parent = model

	model.Parent = workspace
	return model, core
end

return RiftBuilder
