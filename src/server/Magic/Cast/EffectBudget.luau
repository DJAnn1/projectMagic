--!strict
--[[
	EffectBudget: the server's hard limits on magic, so 60 players can't melt it.

		heavy slots      at most budget.maxHeavyActive large effects at once (quakes, waves, P8+ harm)
		parts bucket     every effect that touches parts spends tokens (budget.partsPerSecond,
		                 refilled continuously). When it runs dry, effects touch fewer parts
		                 (graceful degradation) instead of failing outright.
		terrain bucket   same for terrain writes (budget.terrainOpsPerSecond)
		counters         active durational effects (server and per player), fields, mythic
		                 fields, lights, burning parts, ground fires
		LOD              listeners(point, heavy) splits nearby players into near / mid / far tiers
		metrics          counters for the admin `budget` command and logs

	Everything is module-level state: there is one budget per server.
]]

local Players = game:GetService("Players")

local T = require(script.Parent.Parent.Data.CastTuning)

local B = T.budget

local EffectBudget = {}

type Bucket = { tokens: number, capacity: number, rate: number, last: number }

local function bucket(capacity: number, rate: number): Bucket
	return { tokens = capacity, capacity = capacity, rate = rate, last = os.clock() }
end

local function refill(b: Bucket)
	local now = os.clock()
	b.tokens = math.min(b.capacity, b.tokens + (now - b.last) * b.rate)
	b.last = now
end

local partsBucket = bucket(B.partsBurst, B.partsPerSecond)
local terrainBucket = bucket(B.terrainOpsBurst, B.terrainOpsPerSecond)

local counts: { [string]: number } = {
	heavy = 0,
	active = 0,
	fields = 0,
	mythicFields = 0,
	lights = 0,
	burningParts = 0,
	groundFires = 0,
}
local perPlayer: { [number]: number } = {}

local LIMITS: { [string]: number } = {
	heavy = B.maxHeavyActive,
	active = B.maxActiveEffects,
	fields = B.maxFields,
	mythicFields = B.maxMythicFields,
	lights = B.maxLights,
	burningParts = B.maxBurningParts,
	groundFires = B.maxGroundFires,
}

-- Metrics since boot (and per minute, reset by EffectRunner).
EffectBudget.metrics = {
	partsGranted = 0,
	partsDenied = 0,
	terrainGranted = 0,
	terrainDenied = 0,
	refusals = {} :: { [string]: number },
}

-- ─── Counted slots ──────────────────────────────────────────────────────────

-- Takes one slot of `kind` if one is free. Returns false (and counts a refusal) when full.
function EffectBudget.acquire(kind: string): boolean
	if counts[kind] >= LIMITS[kind] then
		EffectBudget.metrics.refusals[kind] = (EffectBudget.metrics.refusals[kind] or 0) + 1
		return false
	end
	counts[kind] += 1
	return true
end

function EffectBudget.release(kind: string)
	counts[kind] = math.max(0, counts[kind] - 1)
end

function EffectBudget.available(kind: string): number
	return LIMITS[kind] - counts[kind]
end

-- A durational effect owned by a player: server cap and per-player cap together.
function EffectBudget.acquireActive(userId: number?): boolean
	if userId and (perPlayer[userId] or 0) >= B.maxActivePerPlayer then
		EffectBudget.metrics.refusals.perPlayer = (EffectBudget.metrics.refusals.perPlayer or 0) + 1
		return false
	end
	if not EffectBudget.acquire("active") then
		return false
	end
	if userId then
		perPlayer[userId] = (perPlayer[userId] or 0) + 1
	end
	return true
end

-- Would acquireActive succeed? (No side effects: used before a caster pays.)
function EffectBudget.canAcquireActive(userId: number?): boolean
	return counts.active < LIMITS.active and (userId == nil or (perPlayer[userId] or 0) < B.maxActivePerPlayer)
end

function EffectBudget.releaseActive(userId: number?)
	EffectBudget.release("active")
	if userId and perPlayer[userId] then
		perPlayer[userId] = math.max(0, perPlayer[userId] - 1)
	end
end

-- ─── Token buckets ──────────────────────────────────────────────────────────

-- Asks for `wanted` part-touches; returns how many are granted (0..wanted).
function EffectBudget.takeParts(wanted: number): number
	refill(partsBucket)
	local granted = math.clamp(math.floor(partsBucket.tokens), 0, wanted)
	partsBucket.tokens -= granted
	EffectBudget.metrics.partsGranted += granted
	EffectBudget.metrics.partsDenied += wanted - granted
	return granted
end

function EffectBudget.takeTerrainOps(wanted: number): number
	refill(terrainBucket)
	local granted = math.clamp(math.floor(terrainBucket.tokens), 0, wanted)
	terrainBucket.tokens -= granted
	EffectBudget.metrics.terrainGranted += granted
	EffectBudget.metrics.terrainDenied += wanted - granted
	return granted
end

-- ─── LOD ────────────────────────────────────────────────────────────────────

export type Listeners = { near: { Player }, mid: { Player }, far: { Player } }

-- Players by distance tier from `point`. Far listeners only hear about heavy effects.
function EffectBudget.listeners(point: Vector3, heavy: boolean): Listeners
	local out: Listeners = { near = {}, mid = {}, far = {} }
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			local d = (root.Position - point).Magnitude
			if d <= T.lod.near then
				table.insert(out.near, player)
			elseif d <= T.lod.mid then
				table.insert(out.mid, player)
			elseif heavy and d <= T.lod.far then
				table.insert(out.far, player)
			end
		end
	end
	return out
end

-- ─── Reporting ──────────────────────────────────────────────────────────────

function EffectBudget.report(): string
	refill(partsBucket)
	refill(terrainBucket)
	local m = EffectBudget.metrics
	local refusals = {}
	for kind, n in m.refusals do
		table.insert(refusals, kind .. " " .. n)
	end
	table.sort(refusals)
	return string.format(
		"heavy %d/%d · active %d/%d · fields %d/%d (mythic %d/%d) · lights %d/%d · burning %d/%d · ground fires %d/%d\nparts bucket %.0f/%d (granted %d, denied %d) · terrain bucket %.0f/%d (granted %d, denied %d)\nrefusals: %s",
		counts.heavy, LIMITS.heavy, counts.active, LIMITS.active, counts.fields, LIMITS.fields, counts.mythicFields, LIMITS.mythicFields,
		counts.lights, LIMITS.lights, counts.burningParts, LIMITS.burningParts, counts.groundFires, LIMITS.groundFires,
		partsBucket.tokens, partsBucket.capacity, m.partsGranted, m.partsDenied,
		terrainBucket.tokens, terrainBucket.capacity, m.terrainGranted, m.terrainDenied,
		if #refusals > 0 then table.concat(refusals, ", ") else "none"
	)
end

function EffectBudget.counts(): { [string]: number }
	return table.clone(counts)
end

Players.PlayerRemoving:Connect(function(player)
	perPlayer[player.UserId] = nil
end)

return EffectBudget
