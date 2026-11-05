--!strict
--[[
	StatCache: every player's derived item stats, readable by any server module without a
	Bootstrap dependency (like Cast/Resistances). InventoryService writes it; casting, the
	reservoir and resistances read it (docs/Items.md §4-5).

		StatCache.set(player, entry) / get(player) / clear(player)
		StatCache.applyToCast(player, stats)                  CastService, after computeStats
		StatCache.applyToConsequences(player, list, reservoir, now)   after Reservoir.trySpend
		StatCache.modifierSlots(player) / formTier(player)     CastService, before validation
		StatCache.reservoir(player, baseMax, baseRegen) -> (max, regenMult)   ReservoirService
		StatCache.resistFor(humanoid) -> map?                  the "items" source in Resistances
		StatCache.focusPenalty(foci, domains, power) -> FocusEffect   (pure; specs and tooltips)

	THE FOCUS TRADEOFF (ItemRules.focus). Spells below power 6 never need a focus. From power 6 up,
	casting without a matching focus costs +6% reservoir and adds +2% backfire chance per power step
	(P10 bare-handed: +30% cost, +10% backfire). A held (major) focus that matches the spell's
	domain removes the penalty and adds its stability; a minor focus (ring, amulet) or a held focus
	of another domain halves it. Low-level play is never gated; high power is where gear matters.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local ItemTypes = require(Shared.Items.ItemTypes)
local StatCalc = require(Shared.Items.StatCalc)
local ItemRules = require(Shared.Items.Data.ItemRules)

export type Buff = {
	id: string,
	name: string,
	expires: number, -- server time
	stats: { [string]: number }?,
	resist: { [string]: number }?,
}

export type Entry = {
	sheet: ItemTypes.Sheet,
	focus: StatCalc.FocusInfo,
	reservoirFlat: number, -- gear and buff flat reservoir (the profile base is live in ReservoirService)
	reservoirPct: number,
}

export type FocusEffect = {
	match: string, -- "major" | "partial" | "none"
	share: number, -- share of the bare-handed penalty that applies (0..1)
	costMult: number, -- multiplier on reservoir cost from the penalty
	backfireAdd: number, -- absolute backfire chance added by the penalty
	instabilityAdd: number,
	stability: number, -- the matching focus's own stability (0..1 lower backfire)
}

local StatCache = {}

local entries: { [Player]: Entry } = {}
local buffs: { [Player]: { [string]: Buff } } = {}

function StatCache.set(player: Player, entry: Entry)
	entries[player] = entry
end

function StatCache.get(player: Player): Entry?
	return entries[player]
end

function StatCache.clear(player: Player)
	entries[player] = nil
	buffs[player] = nil
end

local function final(player: Player, stat: string): number
	local entry = entries[player]
	return entry and entry.sheet.final[stat] or 0
end

-- ─── Buffs (consumables) ────────────────────────────────────────────────────

-- Adds or refreshes a timed buff (same id: the later expiry and the new values win).
function StatCache.addBuff(player: Player, buff: Buff)
	local list = buffs[player] or {}
	buffs[player] = list
	local existing = list[buff.id]
	if existing then
		buff.expires = math.max(existing.expires, buff.expires)
	end
	list[buff.id] = buff
end

-- Active buffs; expired ones are dropped. Returns true in the second result if any expired.
function StatCache.buffs(player: Player, now: number): ({ Buff }, boolean)
	local list = buffs[player]
	local out: { Buff } = {}
	local expired = false
	if list then
		for id, buff in list do
			if buff.expires <= now then
				list[id] = nil
				expired = true
			else
				table.insert(out, buff)
			end
		end
	end
	table.sort(out, function(a, b)
		return a.id < b.id
	end)
	return out, expired
end

-- ─── Casting ────────────────────────────────────────────────────────────────

function StatCache.focusPenalty(foci: { { grade: string, domains: { [string]: boolean }, stability: number } }, domains: { string }, power: number): FocusEffect
	local F = ItemRules.focus
	local match = "none"
	local stability = 0
	for _, focus in foci do
		local matches = focus.domains.any == true
		for _, d in domains do
			matches = matches or focus.domains[d] == true
		end
		if matches and focus.grade == "major" then
			match = "major"
			stability = math.max(stability, focus.stability)
		elseif match == "none" and (matches or focus.grade == "major") then
			match = "partial" -- a minor focus, or a held focus of another domain
		end
		if matches and focus.grade == "minor" then
			stability = math.max(stability, focus.stability)
		end
	end
	local share = if match == "major" then 0 elseif match == "partial" then F.partialShare else 1
	local steps = math.max(0, power - F.penaltyFromPower + 1)
	return {
		match = match,
		share = share,
		costMult = 1 + F.costPerPower * steps * share,
		backfireAdd = F.backfirePerPower * steps * share,
		instabilityAdd = F.instabilityPerPower * steps * share,
		stability = stability,
	}
end

-- Gear on the spell's numbers: power, cast time, cost, stability, and the focus tradeoff.
-- Mutates `stats` (a fresh table from MagicCore.computeStats).
function StatCache.applyToCast(player: Player, stats: any)
	local entry = entries[player]
	local domains: { string } = stats.domains
	local f: { [string]: number } = if entry then entry.sheet.final else {}

	local domainPower = 0
	for _, d in domains do
		domainPower += f["power_" .. d] or 0
	end
	domainPower /= math.max(1, #domains)
	stats.power *= math.max(0.1, 1 + (f.spellPowerPct or 0) + domainPower)
	stats.castTime /= math.max(0.5, 1 + (f.castSpeedPct or 0))

	local foci: { any } = if entry then entry.focus.foci else {}
	local focus = StatCache.focusPenalty(foci, domains, stats.recipe.power)
	local costMult = (1 - (f.costReductionPct or 0)) * focus.costMult
	stats.cost *= costMult
	stats.costBreakdown.reservoir *= costMult
	stats.backfireChance = math.clamp(
		stats.backfireChance * (1 - (f.stabilityPct or 0)) * (1 - focus.stability) + focus.backfireAdd,
		0,
		1
	)
	stats.instability += focus.instabilityAdd
	stats.focusMatch = focus.match -- read by the cast log; not part of SpellStats' contract
end

-- Backlash resistance: overdraw consequences this cast produced become weaker and shorter. The
-- burnout/lockout timers trySpend already set are pulled in to match (older, longer ones stay).
function StatCache.applyToConsequences(player: Player, consequences: { any }, reservoir: any, now: number)
	local pct = math.clamp(final(player, "backlashResistPct"), 0, 0.6)
	if pct <= 0 then
		return
	end
	for _, c in consequences do
		local original = c.duration
		c.amount *= 1 - pct
		c.duration *= 1 - pct
		if c.kind == "Burnout" and math.abs(reservoir.burnoutUntil - (now + original)) < 1e-3 then
			reservoir.burnoutUntil = now + c.duration
		elseif c.kind == "Lockout" and c.domain and math.abs((reservoir.lockouts[c.domain] or 0) - (now + original)) < 1e-3 then
			reservoir.lockouts[c.domain] = now + c.duration
		end
	end
end

function StatCache.modifierSlots(player: Player): number
	return math.floor(final(player, "modifierSlots"))
end

function StatCache.formTier(player: Player): number
	return math.floor(final(player, "formTier"))
end

-- ─── Reservoir ──────────────────────────────────────────────────────────────

-- The live maximum and regen multiplier with gear: (profile max + flat) x (1 + pct).
function StatCache.reservoir(player: Player, baseMax: number, baseRegen: number): (number, number)
	local entry = entries[player]
	if not entry then
		return baseMax, baseRegen
	end
	local max = (baseMax + entry.reservoirFlat) * math.max(0.5, 1 + entry.reservoirPct)
	local regen = baseRegen * math.max(0.25, 1 + (entry.sheet.final.reservoirRegenPct or 0))
	return max, regen
end

-- ─── Resistances ────────────────────────────────────────────────────────────

-- The "items" resistance source: equipped gear, sets and buffs, for players only.
function StatCache.resistFor(humanoid: Humanoid): { [string]: number }?
	local character = humanoid.Parent
	local player = character and Players:GetPlayerFromCharacter(character)
	local entry = player and entries[player]
	if not entry or next(entry.sheet.resist) == nil then
		return nil
	end
	return entry.sheet.resist
end

return StatCache
