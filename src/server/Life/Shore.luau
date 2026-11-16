--!strict
--[[
	Shore: where a town's fishers can stand with water in front of them (docs/Hunting.md). Pure: it only
	asks a height function, so Tests/Hunting.spec runs it on a made-up coast.

	find(place, height, sea) -> { Spot }
		Walks rings outward from the town's centre (every RING studs, ANGLES around) and keeps dry, low ground
		(sea + 0.5 .. sea + 5) with open water REACH studs off in one of eight directions. Stops at the first
		ring that gave MIN_SPOTS (the nearest shore), or at the town's radius + MAX_OUT. Each spot remembers the
		water it faces, so the fisher looks at it and the bobber lands on it. Empty = no shore within reach:
		that town's fishers mend nets instead of fishing on grass.
	pick(spots, seed) -> Spot?   a fisher's own spot, by seed (a household doesn't all crowd one rock)
]]

local Shore = {}

export type Spot = { at: Vector3, water: Vector3 }
export type Place = { x: number, z: number, radius: number }

local RING = 12
local ANGLES = 48
local REACH = 7
local MIN_SPOTS = 6
local MAX_OUT = 260
local LOW, HIGH = 0.5, 5

local DIRS = (function()
	local out: { Vector2 } = {}
	for i = 0, 7 do
		local a = i / 8 * 2 * math.pi
		table.insert(out, Vector2.new(math.cos(a), math.sin(a)))
	end
	return out
end)()

function Shore.find(place: Place, height: (number, number) -> number, sea: number): { Spot }
	local out: { Spot } = {}
	local limit = math.max(place.radius, 40) + MAX_OUT
	local r = RING
	while r <= limit do
		for i = 0, ANGLES - 1 do
			local a = i / ANGLES * 2 * math.pi
			local x, z = place.x + math.cos(a) * r, place.z + math.sin(a) * r
			local h = height(x, z)
			if h >= sea + LOW and h <= sea + HIGH then
				for _, d in DIRS do
					local wx, wz = x + d.X * REACH, z + d.Y * REACH
					if height(wx, wz) < sea - 0.5 then
						table.insert(out, { at = Vector3.new(x, h, z), water = Vector3.new(wx, sea, wz) })
						break
					end
				end
			end
		end
		if #out >= MIN_SPOTS then
			break
		end
		r += RING
	end
	return out
end

function Shore.pick(spots: { Spot }, seed: number): Spot?
	if #spots == 0 then
		return nil
	end
	return spots[seed % #spots + 1]
end

return Shore
