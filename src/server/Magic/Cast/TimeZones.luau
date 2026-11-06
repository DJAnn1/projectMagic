--!strict
--[[
	TimeZones: where time has stopped right now (docs/Time.md, Timestop). Anything with a clock asks here
	and pauses: fire, heat, fields, gravity powers, event attacks. It has no dependencies, so any of
	them can require it without a cycle.

		add(center, radius, ownerUserId) -> zone
		remove(zone)
		stopped(position, exemptUserId?) -> boolean   exemptUserId: the caster's own body keeps moving

	Cost: a distance check per zone. Almost always there are none, and it returns at once.
]]

export type Zone = { center: Vector3, radius: number, owner: number? }

local TimeZones = {}

local zones: { Zone } = {}

function TimeZones.add(center: Vector3, radius: number, owner: number?): Zone
	local zone: Zone = { center = center, radius = radius, owner = owner }
	table.insert(zones, zone)
	return zone
end

function TimeZones.remove(zone: Zone)
	local index = table.find(zones, zone)
	if index then
		table.remove(zones, index)
	end
end

function TimeZones.stopped(position: Vector3, exemptUserId: number?): boolean
	for _, zone in zones do
		if (exemptUserId == nil or zone.owner ~= exemptUserId) and (position - zone.center).Magnitude <= zone.radius then
			return true
		end
	end
	return false
end

return TimeZones
