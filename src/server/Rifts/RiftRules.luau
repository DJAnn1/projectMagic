--!strict
--[[
	RiftRules: the decisions behind Rifts, with no Instances, so Tests/Rifts.spec can check every case
	(docs/Rifts.md). Services/RiftService does the running; Rifts/RiftBuilder makes the parts.

		slotOf(now) / window(slot) / runEnds(slot, startedAt)
		plan(worldSeed, slot, towns, isDry) -> Plan      the same on every server
		layout(roomIds) -> { Section }                   where each room sits in the pocket
		inPocket(position, length)
		classify(room, cast, twist) -> (approach?, gain) what one cast is worth to a room
		solvedCleverly(cleverGain, bruteGain)
		payout(tier, won, cleverRooms) -> (xp, coins)
		rollItems(tier, won, rng) / bossRarity(tier, cleverRooms, rng) / rollBossLoot(tier, won, cleverRooms, rng)

	Claims and contribution scores reuse Social/EventRules: the same once-only record, the same tiers.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)
local R = require(Shared.Rifts.Data.RiftData)

export type Town = { id: string, name: string, x: number, z: number }
export type Window = { startsAt: number, closesAt: number, lastEnd: number }
export type Plan = {
	slot: number,
	id: string, -- also the claim key
	twist: string,
	rooms: { string },
	boss: string,
	bossWeakness: string,
	bossWeakness2: string, -- the Twins' other one: never the same as the first
	townName: string,
	x: number,
	z: number,
}
export type Section = {
	kind: string, -- "hall" | "room" | "arena"
	roomId: string?,
	startX: number, -- world X of the wall it starts at
	length: number,
}
export type Cast = {
	tags: { string },
	route: string?,
	power: number,
	backfired: boolean?,
}

-- A boss can be weak to any of these. Mythic domains are left out: almost nobody has them.
local WEAKNESSES = { "energy", "water", "air", "earth", "life", "mind", "spirit", "void", "space" }

local RiftRules = {}

-- ─── Schedule ───────────────────────────────────────────────────────────────

function RiftRules.slotOf(now: number): number
	return math.floor(now / R.slotSeconds)
end

function RiftRules.window(slot: number): Window
	local startsAt = slot * R.slotSeconds
	return { startsAt = startsAt, closesAt = startsAt + R.openSeconds, lastEnd = startsAt + R.slotSeconds - R.closeMargin }
end

-- How long a run's clock is under this twist.
function RiftRules.runLength(twist: R.Twist?): number
	return math.floor(R.runSeconds * (if twist then twist.clockShare or 1 else 1))
end

-- When a run that began at `startedAt` must end: the full clock, unless the next Rift is due first.
function RiftRules.runEnds(slot: number, startedAt: number, twist: R.Twist?): number
	return math.min(startedAt + RiftRules.runLength(twist), RiftRules.window(slot).lastEnd)
end

--[[
	This slot's Rift. `towns` must be in a stable order and `isDry` must read the world generator, not
	built terrain, or two servers could choose different places.
]]
function RiftRules.plan(worldSeed: number, slot: number, towns: { Town }, isDry: (number, number) -> boolean): Plan
	assert(#towns > 0, "RiftRules.plan: no towns")
	local rng = Seed.random(worldSeed, "rift", "schedule", slot)
	local twist = R.twistIds[rng:NextInteger(1, #R.twistIds)]
	-- A seeded shuffle: the first few rooms of it are this Rift's.
	local pool = table.clone(R.roomIds)
	for i = #pool, 2, -1 do
		local j = rng:NextInteger(1, i)
		pool[i], pool[j] = pool[j], pool[i]
	end
	local rooms: { string } = {}
	for i = 1, math.min(R.roomCount, #pool) do
		rooms[i] = pool[i]
	end
	local weakIndex = rng:NextInteger(1, #WEAKNESSES)
	local weakness = WEAKNESSES[weakIndex]
	local weakness2 = WEAKNESSES[(weakIndex + rng:NextInteger(0, #WEAKNESSES - 2)) % #WEAKNESSES + 1]
	local boss = R.bossIds[rng:NextInteger(1, #R.bossIds)]
	local town = towns[rng:NextInteger(1, #towns)]
	local x, z = town.x, town.z
	for _ = 1, R.placeTries do
		local angle = rng:NextNumber() * 2 * math.pi
		local distance = R.placeOffset.min + rng:NextNumber() * (R.placeOffset.max - R.placeOffset.min)
		local px, pz = town.x + math.cos(angle) * distance, town.z + math.sin(angle) * distance
		if isDry(px, pz) then
			x, z = px, pz
			break
		end
	end
	return {
		slot = slot,
		id = "rift_" .. slot,
		twist = twist,
		rooms = rooms,
		boss = boss,
		bossWeakness = weakness,
		bossWeakness2 = weakness2,
		townName = town.name,
		x = x,
		z = z,
	}
end

-- ─── The pocket ─────────────────────────────────────────────────────────────

-- The hall, each room in order, then the arena, wall to wall along +X.
function RiftRules.layout(roomIds: { string }): { Section }
	local sections: { Section } = {}
	local x = R.pocket.x
	local function add(kind: string, roomId: string?, length: number)
		table.insert(sections, { kind = kind, roomId = roomId, startX = x, length = length })
		x += length
	end
	add("hall", nil, R.hallLength)
	for _, id in roomIds do
		add("room", id, R.roomLength)
	end
	add("arena", nil, R.arenaLength)
	return sections
end

function RiftRules.totalLength(roomCount: number): number
	return R.hallLength + roomCount * R.roomLength + R.arenaLength
end

function RiftRules.inPocket(position: Vector3, length: number): boolean
	local p = R.pocket
	return position.X >= p.x - 10
		and position.X <= p.x + length + 10
		and math.abs(position.Z - p.z) <= R.width / 2 + 10
		and position.Y >= p.y - R.chasmDepth - 60
		and position.Y <= p.y + R.height + 20
end

-- ─── Solving ────────────────────────────────────────────────────────────────

-- Flat on purpose: a strong spell helps a little, but what solves a room quickly is the right answer.
local function powerFactor(power: number): number
	return math.clamp(0.7 + 0.1 * power, 0.8, 1.2)
end

-- What the same answer is worth the (uses + 1)th time in one room.
function RiftRules.repeatFactor(uses: number): number
	return math.max(R.repeatFloor, R.repeatShare ^ math.max(0, uses))
end

-- How much tougher enemies are, for the strongest spell cast inside. 1 at power 3 or below.
function RiftRules.powerHealth(power: number): number
	return math.clamp(1 + R.powerHealthPerLevel * (power - 3), 1, R.powerHealthCap)
end

function RiftRules.powerDamage(power: number): number
	return math.clamp(1 + R.powerDamagePerLevel * (power - 3), 1, R.powerDamageCap)
end

--[[
	What one cast is worth to a room's progress (0..1 of the room). Returns the clever approach it
	matched, if any.

	A plain domain strike (your first innate attacks) is never clever, whatever its tags: it's the same
	attack you'd use on anything. It still counts as brute force, so a new player is never locked out.
]]
function RiftRules.classify(room: R.Room, cast: Cast, twist: R.Twist?): (R.Approach?, number)
	if cast.backfired then
		return nil, 0
	end
	local factor = powerFactor(cast.power)
	if cast.route ~= "strike" then
		for _, approach in room.approaches do
			for _, tag in cast.tags do
				if table.find(approach.tags, tag) then
					local gain = R.cleverGain * factor * (if twist then twist.cleverGain or 1 else 1)
					if approach.burns and twist and twist.burnGain then
						gain *= twist.burnGain
					end
					return approach, gain
				end
			end
		end
	end
	return nil, R.bruteGain * factor * (if twist then twist.bruteGain or 1 else 1)
end

-- A room counts as solved cleverly if at least half of the work on it was.
function RiftRules.solvedCleverly(cleverGain: number, bruteGain: number): boolean
	return cleverGain > 0 and cleverGain >= bruteGain
end

-- ─── Rewards ────────────────────────────────────────────────────────────────

function RiftRules.payout(tier: string, won: boolean, cleverRooms: number, twist: R.Twist?): (number, number)
	local reward = R.rewards[tier]
	local share = (if won then 1 else R.failedShare) * (if twist then twist.rewardShare or 1 else 1)
	local bonus = 1 + R.cleverXp * math.max(0, cleverRooms)
	return math.floor(reward.xp * share * bonus), math.floor(reward.coins * share)
end

-- What finding an answer counts as: the same room solved the same way is one answer, ever.
function RiftRules.answerKey(roomId: string, approach: R.Approach): string
	return approach.key or (roomId .. ":" .. approach.id)
end

-- How many ordinary answers exist in all. Reactions are a bonus on top, so the panel doesn't count them.
function RiftRules.answerCount(): number
	local total = 0
	for _, room in R.rooms do
		total += #room.approaches
	end
	return total
end

-- How many of those you've found, from data.rifts.found.
function RiftRules.answersFound(found: { [string]: number }): number
	local count = 0
	for key in found do
		if string.sub(key, 1, 9) ~= "reaction:" then
			count += 1
		end
	end
	return count
end

-- A reaction, worded as an answer: it's worth more than a cast, and has its own place in the journal.
function RiftRules.reactionApproach(result: string, description: string): R.Approach
	return {
		id = result,
		label = (string.gsub(description, "%.$", "")),
		tags = {},
		key = "reaction:" .. result,
	}
end

-- A run that ran out of time pays no items.
function RiftRules.rollItems(tier: string, won: boolean, rng: Random): { { item: string, n: number } }
	local out: { { item: string, n: number } } = {}
	if not won then
		return out
	end
	for _, entry in R.rewards[tier].items do
		if rng:NextNumber() < entry.chance then
			table.insert(out, { item = entry.item, n = rng:NextInteger(entry.min, entry.max) })
		end
	end
	return out
end

-- The rarity of the boss's gift: solving rooms cleverly is what raises it.
function RiftRules.bossRarity(tier: string, cleverRooms: number, rng: Random): string
	local b = R.bossRarity
	if tier == "gold" and cleverRooms >= b.legendaryAt and rng:NextNumber() < b.legendaryChance then
		return "legendary"
	end
	if cleverRooms >= b.epicAt then
		return b.silverCap
	end
	return b.base
end

-- One piece of gear for gold and silver on a win, or nil.
function RiftRules.rollBossLoot(tier: string, won: boolean, cleverRooms: number, rng: Random): (string?, string?)
	if not won or (tier ~= "gold" and tier ~= "silver") then
		return nil, nil
	end
	local item = R.bossLoot[rng:NextInteger(1, #R.bossLoot)]
	return item, RiftRules.bossRarity(tier, cleverRooms, rng)
end

return RiftRules
