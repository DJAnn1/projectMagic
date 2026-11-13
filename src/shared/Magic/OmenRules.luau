--!strict
--[[
	OmenRules: the pure part of omens (docs/Omens.md). No Instances and no services, so the spec
	can test all of it.

		OmenRules.strength(startsAt, now, lead)   0..1: rises over the lead, holds at 1 for `linger`
		                                          after the start, then nil (the omen is over)
		OmenRules.bearing(fromX, fromZ, toX, toZ) "north", "south-east"...: north is -Z (as POIPlacer
		                                          and the wild-zone rumours)
		OmenRules.visible(source, dx, dz)         can someone this far from the place notice it at all?
		OmenRules.noticeable(source, dx, dz, s)   close and strong enough to write about or talk about
		OmenRules.rumor(signId, fromX, fromZ, toX, toZ)   a townsperson's line about a sign
		OmenRules.signature(list)                 a short string that changes only when what a player
		                                          sees changes enough to resend (strength in tenths)
]]

local Data = require(script.Parent.Data.Omens)

local OmenRules = {}

local BEARINGS = { "east", "north-east", "north", "north-west", "west", "south-west", "south", "south-east" }

function OmenRules.strength(startsAt: number, now: number, lead: number): number?
	if now >= startsAt then
		return if now - startsAt <= Data.linger then 1 else nil
	end
	local left = startsAt - now
	if left > lead then
		return nil
	end
	return math.clamp(1 - left / lead, 0, 1)
end

function OmenRules.bearing(fromX: number, fromZ: number, toX: number, toZ: number): string
	local angle = math.atan2(-(toZ - fromZ), toX - fromX)
	local index = math.floor(((angle + math.pi * 2) % (math.pi * 2)) / (math.pi / 4) + 0.5) % 8
	return BEARINGS[index + 1]
end

function OmenRules.visible(source: Data.Source, dx: number, dz: number): boolean
	return source.seen == math.huge or dx * dx + dz * dz <= source.seen * source.seen
end

function OmenRules.noticeable(source: Data.Source, dx: number, dz: number, strength: number): boolean
	if strength < Data.noticeAt then
		return false
	end
	if source.seen == math.huge then
		return true
	end
	return dx * dx + dz * dz <= Data.noticeRange * Data.noticeRange
end

function OmenRules.rumor(signId: string, fromX: number, fromZ: number, toX: number, toZ: number): string?
	local sign = Data.signs[signId]
	if not sign then
		return nil
	end
	return (string.gsub(sign.rumor, "{dir}", OmenRules.bearing(fromX, fromZ, toX, toZ)))
end

export type Seen = { id: string, source: string, s: number }

function OmenRules.signature(list: { Seen }): string
	local parts: { string } = {}
	for _, o in list do
		table.insert(parts, o.id .. ":" .. math.floor(o.s * 10 + 0.5))
	end
	table.sort(parts)
	return table.concat(parts, "|")
end

return OmenRules
