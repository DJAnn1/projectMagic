--!strict
--[[
	UtilityScore: the pure scoring function at the heart of NPCBrain. No Instances, no yields, no
	globals: it runs identically on the main thread and inside ParallelPool Actors
	(serverstorage/Workers/NpcScoringWorker requires this same module).

	For each available action a:

	    needs(a)  = Σ_n  W_n · U(level_n) · gain(a, n)
	    U(level)  = (1 - level)²,  doubled when level < 0.15 (critical)
	    utility   = needs(a) · fit(a, block) · personality(a) · quirk(a) · momentum(a) + jitter(a)

	W_n           need weights from personality (NPCBrain.compile)
	fit           schedule fit of the action for the current hour's block (Data/NeedsActions)
	personality   1 + Σ_t aff(a, t) · (trait_t - 0.5) · 2, clamped 0.25..2.5
	quirk         product of quirk actionMult for a
	momentum      1.25 for the action already in progress (no dithering)
	jitter        ±3%, a deterministic hash of (npc seed, game hour, action): ties break
	              differently per person and per hour, identically on every server
	Hard rules (before scoring): shelter only under threat; a critical safety level makes
	shelter's needs term dominate everything (fleeing beats finishing work).
]]

export type Compiled = {
	seed: number,
	weights: { [string]: number }, -- need -> W_n
	gains: { [string]: { [string]: number } }, -- action -> need -> gain/hour
	fits: { [string]: { [string]: number } }, -- action -> block -> fit
	personality: { [string]: number }, -- action -> multiplier
	quirk: { [string]: number }, -- action -> multiplier
	available: { string }, -- action ids this NPC can do (sorted)
}

export type Breakdown = {
	action: string,
	needs: number,
	fit: number,
	personality: number,
	quirk: number,
	momentum: number,
	total: number,
}

local UtilityScore = {}

local CRITICAL = 0.15

-- 32-bit integer hash -> 0..1 (deterministic, no Random object, safe in parallel).
-- FNV-1a with the prime multiply split (as Shared/Magic/Seed) so values stay exact below 2^53.
local function hash01(a: number, b: number, s: string): number
	local h = 2166136261
	local function mix(byte: number)
		h = bit32.bxor(h, byte)
		h = (bit32.lshift(h, 24) + h * 403) % 4294967296
	end
	for _, n in { a % 4294967296, b % 4294967296 } do
		for _ = 1, 4 do
			mix(n % 256)
			n = n // 256
		end
	end
	for i = 1, #s do
		mix(string.byte(s, i))
	end
	return (h % 100000) / 100000
end

function UtilityScore.urgency(level: number): number
	local u = (1 - math.clamp(level, 0, 1)) ^ 2
	return if level < CRITICAL then u * 2 else u
end

-- Scores every available action. Returns the best id and the full breakdown (best first).
function UtilityScore.score(c: Compiled, needs: { [string]: number }, block: string, current: string?, hourIndex: number, threat: boolean): (string, { Breakdown })
	local rows: { Breakdown } = {}
	for _, action in c.available do
		if action == "shelter" and not threat then
			continue
		end
		local needsTerm = 0
		for need, gain in c.gains[action] do
			needsTerm += (c.weights[need] or 1) * UtilityScore.urgency(needs[need] or 1) * gain
		end
		local fit = (c.fits[action] or {})[block] or 1
		local personality = c.personality[action] or 1
		local quirk = c.quirk[action] or 1
		local momentum = if action == current then 1.25 else 1
		local jitter = (hash01(c.seed, hourIndex, action) - 0.5) * 0.06 * math.max(needsTerm, 0.05)
		local total = needsTerm * fit * personality * quirk * momentum + jitter
		table.insert(rows, {
			action = action,
			needs = needsTerm,
			fit = fit,
			personality = personality,
			quirk = quirk,
			momentum = momentum,
			total = total,
		})
	end
	table.sort(rows, function(a, b)
		return a.total > b.total
	end)
	return if rows[1] then rows[1].action else "idle", rows
end

-- Batch form for ParallelPool jobs: { { id, compiled, needs, block, current, hour, threat } } -> { [id] = action }
function UtilityScore.batch(jobs: { any }): { [string]: string }
	local out: { [string]: string } = {}
	for _, job in jobs do
		local best = UtilityScore.score(job.compiled, job.needs, job.block, job.current, job.hour, job.threat)
		out[job.id] = best
	end
	return out
end

return UtilityScore
