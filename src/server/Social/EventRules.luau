--!strict
--[[
	EventRules: the decisions behind shared events, with no Instances, so Tests/SharedEvents.spec can
	check every case (docs/Social.md "Shared events"). Services/SharedEventService does the running.

		slotOf(now) / timeline(slot, typeId) / phaseAt(timeline, now) / canJoin(timeline, now)
		plan(worldSeed, slot, towns, isDry) -> Plan     the same on every server
		healthFor(base, players) / raise(max, health, target) -> (max, health)
		newScore() / noteAction / addDamage / addHeal / tickScore
		tierFor(score, top) -> tier?
		payout(tier, won) -> (xp, coins) / rollItems(tier, won, rng) -> { { item, n } }
		claimed / claim / pruneClaims                    the once-per-event record in the save
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)
local S = require(Shared.Social.Data.SharedEvents)

export type Timeline = { startsAt: number, warnEnds: number, endsAt: number, duration: number }
export type Town = { id: string, name: string, x: number, z: number }
export type Plan = { slot: number, typeId: string, townId: string, townName: string, x: number, z: number, variant: number }

export type Score = {
	points: number,
	damage: number,
	healing: number,
	seconds: number, -- seconds spent in the zone during the fight
	lastAct: number, -- clock time of your last action; -inf = never
	healSecond: number, -- which whole second the heal cap is counting
	healUsed: number,
}

local EventRules = {}

-- ─── Schedule ───────────────────────────────────────────────────────────────

function EventRules.slotOf(now: number): number
	return math.floor(now / S.slotSeconds)
end

function EventRules.timeline(slot: number, typeId: string): Timeline
	local startsAt = slot * S.slotSeconds
	local duration = S.types[typeId].duration
	local warnEnds = startsAt + S.warnSeconds
	return { startsAt = startsAt, warnEnds = warnEnds, endsAt = warnEnds + duration, duration = duration }
end

function EventRules.phaseAt(timeline: Timeline, now: number): string
	if now < timeline.warnEnds then
		return "warning"
	end
	return if now < timeline.endsAt then "fight" else "over"
end

-- May a server that has only just noticed this event run it? (It booted part-way through.)
function EventRules.canJoin(timeline: Timeline, now: number): boolean
	if now < timeline.warnEnds then
		return true
	end
	return (timeline.endsAt - now) / timeline.duration >= S.joinShare
end

--[[
	What this slot's event is, and where. `towns` must be in a stable order and `isDry` must read the
	world generator, not built terrain, or two servers could choose different places.
]]
function EventRules.plan(worldSeed: number, slot: number, towns: { Town }, isDry: (number, number) -> boolean): Plan
	assert(#towns > 0, "EventRules.plan: no towns")
	local rng = Seed.random(worldSeed, "shared_event", "schedule", slot)
	local typeId = S.ids[rng:NextInteger(1, #S.ids)]
	local town = towns[rng:NextInteger(1, #towns)]
	local variant = rng:NextInteger(1, 1000)
	local x, z = town.x, town.z
	if S.types[typeId].outsideTown then
		for _ = 1, S.placeTries do
			local angle = rng:NextNumber() * 2 * math.pi
			local distance = S.placeOffset.min + rng:NextNumber() * (S.placeOffset.max - S.placeOffset.min)
			local px, pz = town.x + math.cos(angle) * distance, town.z + math.sin(angle) * distance
			if isDry(px, pz) then
				x, z = px, pz
				break
			end
		end
	end
	return { slot = slot, typeId = typeId, townId = town.id, townName = town.name, x = x, z = z, variant = variant }
end

-- ─── Scaling ────────────────────────────────────────────────────────────────

function EventRules.healthFor(base: number, players: number): number
	return base * (1 + S.perExtraPlayer * (math.max(1, players) - 1))
end

-- Scaling only ever goes up, and adds the difference, so damage already dealt still counts.
function EventRules.raise(maxHealth: number, health: number, target: number): (number, number)
	if target <= maxHealth then
		return maxHealth, health
	end
	return target, health + (target - maxHealth)
end

-- ─── Contribution ───────────────────────────────────────────────────────────

function EventRules.newScore(): Score
	return { points = 0, damage = 0, healing = 0, seconds = 0, lastAct = -math.huge, healSecond = -1, healUsed = 0 }
end

function EventRules.noteAction(score: Score, now: number)
	score.lastAct = now
end

function EventRules.addDamage(score: Score, amount: number, now: number)
	if amount > 0 then
		score.damage += amount
		score.points += amount
		score.lastAct = now
	end
end

-- Returns the points it counted. Healing above the per-second cap still heals but doesn't score.
function EventRules.addHeal(score: Score, amount: number, now: number): number
	if amount <= 0 then
		return 0
	end
	local second = math.floor(now)
	if score.healSecond ~= second then
		score.healSecond, score.healUsed = second, 0
	end
	local counted = math.min(amount, S.contribution.healCapPerSecond - score.healUsed)
	score.lastAct = now
	if counted <= 0 then
		return 0
	end
	score.healUsed += counted
	score.healing += counted
	score.points += counted
	return counted
end

-- One second passing. Standing in the zone earns only if you acted recently.
function EventRules.tickScore(score: Score, inZone: boolean, now: number)
	if inZone then
		score.seconds += 1
		if now - score.lastAct <= S.contribution.activeSeconds then
			score.points += S.contribution.presencePerSecond
		end
	end
end

function EventRules.tierFor(score: Score, top: number): string?
	local c = S.contribution
	if score.seconds < c.minSeconds or score.points < c.minPoints then
		return nil
	end
	if score.points >= top * c.gold then
		return "gold"
	end
	return if score.points >= top * c.silver then "silver" else "bronze"
end

-- ─── Rewards ────────────────────────────────────────────────────────────────

function EventRules.payout(tier: string, won: boolean): (number, number)
	local reward = S.rewards[tier]
	local share = if won then 1 else S.failedShare
	return math.floor(reward.xp * share), math.floor(reward.coins * share)
end

-- A failed event pays no items.
function EventRules.rollItems(tier: string, won: boolean, rng: Random): { { item: string, n: number } }
	local out: { { item: string, n: number } } = {}
	if not won then
		return out
	end
	for _, entry in S.rewards[tier].items do
		if rng:NextNumber() < entry.chance then
			table.insert(out, { item = entry.item, n = rng:NextInteger(entry.min, entry.max) })
		end
	end
	return out
end

-- Your first gold finish in a won event guarantees a relic, so most players get the moment at least once.
function EventRules.firstRelic(tier: string, won: boolean, alreadyGiven: boolean, rng: Random): string?
	if tier ~= "gold" or not won or alreadyGiven then
		return nil
	end
	return S.relics[rng:NextInteger(1, #S.relics)]
end

-- ─── Claims: data.sharedEvents.claimed, in the session-locked save ──────────

function EventRules.claimed(claims: { [string]: number }, key: string): boolean
	return claims[key] ~= nil
end

function EventRules.claim(claims: { [string]: number }, key: string, now: number)
	claims[key] = now
end

-- Old claims can go once their event can't run again. Keeps a save from growing forever.
function EventRules.pruneClaims(claims: { [string]: number }, now: number)
	local keep = S.slotSeconds * 3
	for key, at in claims do
		if now - at > keep then
			claims[key] = nil
		end
	end
end

return EventRules
