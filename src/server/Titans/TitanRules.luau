--!strict
--[[
	TitanRules: the decisions behind Titans, with no Instances, so Tests/Titans.spec can check them
	(docs/Titans.md). Services/TitanService does the running.

		slotOf(now) / plan(worldSeed, slot, towns) -> Plan   the same on every server
		lengthOf(points) / pointAt(points, walked) -> (x, z, dirX, dirZ, arrived)
		forcedRoute(x, z, angle, worldSize) -> points        an admin's Titan, starting in front of them
		fallSpot(x, z, towns) -> (x, z)                      never in a town
		addFall(falls, record, max) -> inserted              first server wins, oldest out
		scrub(falls, userId) -> changed                      erasure: takes a name off the bones
		payout / rollItems / rollGear
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)
local T = require(Shared.Titans.Data.Titans)

export type Town = { id: string, name: string, x: number, z: number, radius: number }
export type Point = { x: number, z: number }
export type Plan = {
	slot: number,
	id: string, -- also the claim key and the fall's key
	kind: string,
	points: { Point },
	towns: { string }, -- the names it's heading for, in order
	length: number,
}
export type Fall = {
	id: string,
	kind: string,
	x: number,
	z: number,
	t: number,
	by: string, -- the top fighter's name
	u: number, -- their UserId, so a name can be taken off on request
	n: number, -- how many others helped
}

local TitanRules = {}

-- ─── The road ───────────────────────────────────────────────────────────────

function TitanRules.slotOf(now: number): number
	return math.floor(now / T.slotSeconds)
end

function TitanRules.lengthOf(points: { Point }): number
	local total = 0
	for i = 2, #points do
		total += math.sqrt((points[i].x - points[i - 1].x) ^ 2 + (points[i].z - points[i - 1].z) ^ 2)
	end
	return total
end

-- Where it is after walking this far, which way it faces, and whether it's reached the end.
function TitanRules.pointAt(points: { Point }, walked: number): (number, number, number, number, boolean)
	local left = math.max(0, walked)
	for i = 2, #points do
		local a, b = points[i - 1], points[i]
		local dx, dz = b.x - a.x, b.z - a.z
		local length = math.sqrt(dx * dx + dz * dz)
		if length > 0 then
			if left <= length then
				local share = left / length
				return a.x + dx * share, a.z + dz * share, dx / length, dz / length, false
			end
			left -= length
		end
	end
	local last, before = points[#points], points[math.max(1, #points - 1)]
	local dx, dz = last.x - before.x, last.z - before.z
	local length = math.max(math.sqrt(dx * dx + dz * dz), 1e-3)
	return last.x, last.z, dx / length, dz / length, true
end

--[[
	From one coast to the other, through towns close to the line. `towns` must be in a stable order. The
	towns are passed in the order it would meet them, so it never doubles back.
]]
function TitanRules.plan(worldSeed: number, slot: number, towns: { Town }, worldSize: number): Plan
	assert(#towns > 0, "TitanRules.plan: no towns")
	local rng = Seed.random(worldSeed, "titan", "schedule", slot)
	local kind = T.ids[rng:NextInteger(1, #T.ids)]
	local angle = rng:NextNumber() * 2 * math.pi
	local dirX, dirZ = math.cos(angle), math.sin(angle)
	local reach = worldSize / 2 * T.routeReach

	local nearLine = table.clone(towns)
	local function offLine(town: Town): number
		return math.abs(town.x * dirZ - town.z * dirX)
	end
	table.sort(nearLine, function(a, b)
		local da, db = offLine(a), offLine(b)
		if da ~= db then
			return da < db
		end
		return a.id < b.id
	end)
	local choices: { Town } = {}
	for i = 1, math.min(T.routeChoices, #nearLine) do
		choices[i] = nearLine[i]
	end
	local chosen: { Town } = {}
	for _ = 1, math.min(T.routeTowns, #choices) do
		table.insert(chosen, table.remove(choices, rng:NextInteger(1, #choices)) :: Town)
	end
	table.sort(chosen, function(a, b)
		return a.x * dirX + a.z * dirZ < b.x * dirX + b.z * dirZ
	end)

	local points: { Point } = { { x = -dirX * reach, z = -dirZ * reach } }
	local names: { string } = {}
	for _, town in chosen do
		table.insert(points, { x = town.x, z = town.z })
		table.insert(names, town.name)
	end
	table.insert(points, { x = dirX * reach, z = dirZ * reach })
	return { slot = slot, id = "titan_" .. slot, kind = kind, points = points, towns = names, length = TitanRules.lengthOf(points) }
end

-- An admin's Titan: starts at a point and walks away across the world, for testing near you.
function TitanRules.forcedRoute(x: number, z: number, angle: number, worldSize: number): { Point }
	local reach = worldSize * 0.5
	local tx = math.clamp(x + math.cos(angle) * reach, -worldSize / 2, worldSize / 2)
	local tz = math.clamp(z + math.sin(angle) * reach, -worldSize / 2, worldSize / 2)
	return { { x = x, z = z }, { x = tx, z = tz } }
end

-- ─── Where it falls ─────────────────────────────────────────────────────────

-- Never in a town: a permanent carcass and crater couldn't be mended under streets and houses.
function TitanRules.fallSpot(x: number, z: number, towns: { Town }): (number, number)
	for _, town in towns do
		local dx, dz = x - town.x, z - town.z
		local distance = math.sqrt(dx * dx + dz * dz)
		local clear = town.radius + T.landmarkOffset
		if distance < clear then
			if distance < 1 then
				dx, dz, distance = 1, 0, 1 -- dead centre: any way out will do
			end
			return town.x + dx / distance * clear, town.z + dz / distance * clear
		end
	end
	return x, z
end

-- The first server to report a Titan's death wins; the rest keep the bones already there.
function TitanRules.addFall(falls: { Fall }, record: Fall, max: number): boolean
	for _, fall in falls do
		if fall.id == record.id then
			return false
		end
	end
	table.insert(falls, record)
	table.sort(falls, function(a, b)
		if a.t ~= b.t then
			return a.t < b.t
		end
		return a.id < b.id
	end)
	while #falls > max do
		table.remove(falls, 1)
	end
	return true
end

-- Someone asked to be erased: the bones stay, the name goes.
function TitanRules.scrub(falls: { Fall }, userId: number): boolean
	local changed = false
	for _, fall in falls do
		if fall.u == userId then
			fall.u = 0
			fall.by = "someone"
			changed = true
		end
	end
	return changed
end

-- "Name", "Name and 1 other", "Name and 3 others".
function TitanRules.credit(fall: Fall): string
	if fall.n <= 0 then
		return fall.by
	end
	return string.format("%s and %d other%s", fall.by, fall.n, if fall.n == 1 then "" else "s")
end

-- ─── Rewards ────────────────────────────────────────────────────────────────

function TitanRules.payout(tier: string, won: boolean): (number, number)
	local reward = T.rewards[tier]
	local share = if won then 1 else T.failedShare
	return math.floor(reward.xp * share), math.floor(reward.coins * share)
end

function TitanRules.rollItems(tier: string, won: boolean, rng: Random): { { item: string, n: number } }
	local out: { { item: string, n: number } } = {}
	if not won then
		return out
	end
	for _, entry in T.rewards[tier].items do
		if rng:NextNumber() < entry.chance then
			table.insert(out, { item = entry.item, n = rng:NextInteger(entry.min, entry.max) })
		end
	end
	return out
end

-- One piece of gear for gold and silver on a win.
function TitanRules.rollGear(tier: string, won: boolean, rng: Random): (string?, string?)
	local rarity = T.gearRarity[tier]
	if not won or not rarity then
		return nil, nil
	end
	local item = T.gear[rng:NextInteger(1, #T.gear)]
	if tier == "gold" and rng:NextNumber() < T.legendaryChance then
		rarity = "legendary"
	end
	return item, rarity
end

return TitanRules
