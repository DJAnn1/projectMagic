--!strict
--[[
	StationTypes: the places in buildings where activities are done (docs/Activities.md §2). Shared:
	the server finds them and gives them use points (Life/StationRegistry); clients draw what a station
	looks like while it's in use (Fx/StationFx).

	A STATION TYPE
		label        what it's called in reports and tooltips
		names        parts with these names are this station
		interactables  parts whose Interactable attribute is one of these are this station
		seatTag      Attachments with this CollectionService tag are this station (one slot each)
		slots        how many people can use one at once (each gets its own use point)
		reach        how far out from the part's side the person stands (studs)
		body         where the body is drawn: "self" (on the station itself: a bed, a bench seat),
		             "chairs" (the nearest ChairSeat parts, one per slot), nil (standing at the use point)
		face         "station" (face the part) | "table" (face the nearest table, else the room)
		fx           the client look while in use (Fx/StationFx)
		passive      no use point: it lights up when a linked station in the same building is used
		linked       a passive station type in the same building that comes on with this one
]]

export type StationType = {
	label: string,
	names: { string }?,
	interactables: { string }?,
	seatTag: string?,
	slots: number,
	reach: number,
	body: string?,
	face: string,
	fx: string,
	passive: boolean?,
	linked: string?,
}

local types: { [string]: StationType } = {
	anvil = { label = "Anvil", names = { "Anvil" }, slots = 1, reach = 1.4, face = "station", fx = "anvil", linked = "forge" },
	forge = { label = "Forge", interactables = { "forge" }, slots = 0, reach = 0, face = "station", fx = "forge", passive = true },
	hearth = { label = "Hearth", interactables = { "hearth" }, slots = 1, reach = 1.5, face = "station", fx = "hearth" },
	desk = { label = "Desk", interactables = { "enchanting_desk", "alchemy_table" }, slots = 1, reach = 1.3, face = "station", fx = "desk" },
	bed = { label = "Bed", interactables = { "bed" }, slots = 1, reach = 1.2, body = "self", face = "station", fx = "bed" },
	altar = { label = "Altar", interactables = { "ward_stone" }, slots = 2, reach = 1.6, face = "station", fx = "altar" },
	seat = { label = "Tavern seat", seatTag = "NPCSeat", slots = 1, reach = 1.4, body = "self", face = "table", fx = "seat" },
	table = { label = "Table", names = { "TableTop" }, slots = 2, reach = 1.3, body = "chairs", face = "station", fx = "table" },
}

local StationTypes = {}

StationTypes.types = types

-- Attribute names on a station part (and on use-point Attachments), shared by server and client.
StationTypes.ATTR = table.freeze({
	kind = "StationKind", -- station type id
	id = "StationId", -- "<lotId>:<kind><n>", stable for the same lot
	active = "StationActive", -- someone is using it (any LOD tier, so it shows from afar)
	user = "StationUser", -- npc id of the first user (empty when idle)
	work = "StationWork", -- "<activityIndex>|<start>|<duration>|<item>": what's being made, for progress
	body = "BodyCFrame", -- on a use point: where the body is drawn (sit, lie)
	slot = "StationSlot", -- on a use point: its slot number
})

StationTypes.TAG = "ActivityStation" -- every station part
StationTypes.POINT_TAG = "StationUsePoint" -- every use-point Attachment

function StationTypes.encodeWork(index: number, start: number, duration: number, item: number): string
	return string.format("%d|%.1f|%.1f|%d", index, start, duration, item)
end

function StationTypes.decodeWork(raw: any): (number?, number, number, number)
	if typeof(raw) ~= "string" or raw == "" then
		return nil, 0, 0, 1
	end
	local f = string.split(raw, "|")
	return tonumber(f[1]), tonumber(f[2]) or 0, tonumber(f[3]) or 1, tonumber(f[4]) or 1
end

return StationTypes
