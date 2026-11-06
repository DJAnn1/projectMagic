--!strict
--[[
	DuelModel: one duel as pure data: the score, the rule, and when it's over (docs/Social.md §6).
	No Players, remotes or instances, so every ending can be specced (Tests/Social.spec).
	Services/DuelService feeds it real hits and body checks and carries out the result.

		noteHit(duel, attacker?, victim, amount, health, maxHealth, info, now) -> Outcome?
		tick(duel, dt, now, bodies) -> Outcome?   bodies[userId] = { alive, share, distance }
		recap(duel, outcome, now) -> Recap        what both fighters see afterwards

	An Outcome has a winner (nil = no winner) and a reason:
		first_blood, floor, floor_yield, yielded, ring, down, left, time   someone won or it was even
		interrupted   something other than the two fighters brought one of them to the floor
]]

local DuelRules = require(game:GetService("ReplicatedStorage").Shared.Social.Data.DuelRules)

local L = DuelRules.limits

export type Fighter = { dealt: number, hits: number, crits: number, biggest: number }
export type LogEntry = { t: number, by: number, to: number, amount: number, kind: string, domain: string?, crit: boolean }

export type Duel = {
	id: string,
	a: number,
	b: number,
	rule: DuelRules.Rule,
	center: Vector3,
	radius: number,
	phase: string, -- "countdown" | "fight" | "ended"
	createdAt: number,
	fightAt: number,
	endsAt: number,
	fighters: { [number]: Fighter },
	log: { LogEntry },
	outside: { [number]: number }, -- seconds spent outside the ring, per fighter
	floorSince: { [number]: number }, -- when a fighter reached the floor
}

export type Outcome = { winner: number?, reason: string }
export type Body = { alive: boolean, share: number, distance: number }

export type Recap = {
	winner: number?,
	reason: string,
	seconds: number,
	fighters: { { userId: number, dealt: number, hits: number, crits: number, biggest: number } },
	biggest: { by: number, amount: number, kind: string, domain: string?, crit: boolean }?,
	hits: number,
}

local DuelModel = {}

local AT_FLOOR_SLACK = 0.01 -- health points: Damage clamps to the floor exactly, floats round

function DuelModel.new(id: string, a: number, b: number, ruleId: string, center: Vector3, now: number): Duel
	local rule = DuelRules.rules[ruleId] or DuelRules.rules[DuelRules.default]
	local fightAt = now + L.countdownSeconds
	return {
		id = id,
		a = a,
		b = b,
		rule = rule,
		center = center,
		radius = L.ringRadius,
		phase = "countdown",
		createdAt = now,
		fightAt = fightAt,
		endsAt = fightAt + L.fightSeconds,
		fighters = {
			[a] = { dealt = 0, hits = 0, crits = 0, biggest = 0 },
			[b] = { dealt = 0, hits = 0, crits = 0, biggest = 0 },
		},
		log = {},
		outside = { [a] = 0, [b] = 0 },
		floorSince = {},
	}
end

function DuelModel.opponent(duel: Duel, userId: number): number
	return if userId == duel.a then duel.b else duel.a
end

function DuelModel.floorOf(duel: Duel, maxHealth: number): number
	return maxHealth * duel.rule.floorShare
end

-- `attacker` nil is the world or an NPC. A hit by the other fighter counts toward the rule; any
-- other hit only matters if it brings someone to the floor, because then the duel can't go on fairly.
function DuelModel.noteHit(duel: Duel, attacker: number?, victim: number, amount: number, health: number, maxHealth: number, info: { kind: string, domain: string?, crit: boolean }, now: number): Outcome?
	if duel.phase == "ended" then
		return nil
	end
	local rule = duel.rule
	local atFloor = health <= DuelModel.floorOf(duel, maxHealth) + AT_FLOOR_SLACK
	local other = DuelModel.opponent(duel, victim)

	if duel.phase ~= "fight" then
		return if atFloor then { winner = nil, reason = "interrupted" } else nil
	end

	if attacker == other then
		local stats = duel.fighters[other]
		stats.dealt += amount
		stats.hits += 1
		stats.crits += if info.crit then 1 else 0
		stats.biggest = math.max(stats.biggest, amount)
		if #duel.log < L.logCap then
			table.insert(duel.log, { t = now - duel.fightAt, by = other, to = victim, amount = amount, kind = info.kind, domain = info.domain, crit = info.crit })
		end
		if rule.endAtDamageShare and stats.dealt >= maxHealth * rule.endAtDamageShare then
			return { winner = other, reason = "first_blood" }
		end
	end

	if atFloor then
		if attacker ~= other and attacker ~= victim then
			return { winner = nil, reason = "interrupted" }
		end
		if rule.endAtFloor then
			return { winner = other, reason = "floor" }
		end
		duel.floorSince[victim] = duel.floorSince[victim] or now
	end
	return nil
end

function DuelModel.tick(duel: Duel, dt: number, now: number, bodies: { [number]: Body }): Outcome?
	if duel.phase ~= "fight" then
		return nil
	end
	local a, b = bodies[duel.a], bodies[duel.b]
	if not a or not a.alive then
		return { winner = if b and b.alive then duel.b else nil, reason = "down" }
	end
	if not b or not b.alive then
		return { winner = duel.a, reason = "down" }
	end

	-- At the floor too long: a yield. Healing back above it starts the clock over.
	local wait = duel.rule.floorYieldSeconds
	for _, id in { duel.a, duel.b } do
		local since = duel.floorSince[id]
		if since then
			if bodies[id].share > duel.rule.floorShare + 0.001 then
				duel.floorSince[id] = nil
			elseif wait and now - since >= wait then
				return { winner = DuelModel.opponent(duel, id), reason = "floor_yield" }
			end
		end
	end

	-- The ring: step back inside and the count resets.
	for _, id in { duel.a, duel.b } do
		duel.outside[id] = if bodies[id].distance > duel.radius then duel.outside[id] + dt else 0
	end
	local aOut, bOut = duel.outside[duel.a] >= L.ringOutSeconds, duel.outside[duel.b] >= L.ringOutSeconds
	if aOut and bOut then
		return { winner = nil, reason = "ring" }
	elseif aOut then
		return { winner = duel.b, reason = "ring" }
	elseif bOut then
		return { winner = duel.a, reason = "ring" }
	end

	if now >= duel.endsAt then
		local gap = a.share - b.share
		if math.abs(gap) < 0.02 then
			return { winner = nil, reason = "time" }
		end
		return { winner = if gap > 0 then duel.a else duel.b, reason = "time" }
	end
	return nil
end

function DuelModel.recap(duel: Duel, outcome: Outcome, now: number): Recap
	local fighters = {}
	for _, id in { duel.a, duel.b } do
		local f = duel.fighters[id]
		table.insert(fighters, {
			userId = id,
			dealt = math.floor(f.dealt + 0.5),
			hits = f.hits,
			crits = f.crits,
			biggest = math.floor(f.biggest + 0.5),
		})
	end
	local biggest: LogEntry? = nil
	for _, entry in duel.log do
		if not biggest or entry.amount > biggest.amount then
			biggest = entry
		end
	end
	return {
		winner = outcome.winner,
		reason = outcome.reason,
		seconds = math.max(0, math.floor(now - duel.fightAt)),
		fighters = fighters,
		biggest = if biggest then { by = biggest.by, amount = math.floor(biggest.amount + 0.5), kind = biggest.kind, domain = biggest.domain, crit = biggest.crit } else nil,
		hits = duel.fighters[duel.a].hits + duel.fighters[duel.b].hits,
	}
end

return DuelModel
