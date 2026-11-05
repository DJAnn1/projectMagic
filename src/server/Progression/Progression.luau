--!strict
--[[
	Progression: pure rules for earning mastery. No services, no yields, `now` is passed in,
	so everything here is unit-testable and deterministic.

	State lives in the player's save (data.progression); see Persistence/Schemas Player v3.
	XP is the source of truth; mastery is always recomputed from XP and breakthrough caps.

		Progression.addExperience(p, innate, branchId, channel, baseAmount, ctx) -> GainResult
		Progression.getMasteryTier(p, branchId)        -> tierIndex, tierDef
		Progression.canUnlock(p, innate, branchId)     -> ok, checks
		Progression.unlock(p, innate, branchId, now)   -> ok, checks
		Progression.breakthroughStatus(p, branchId)    -> tierIndex?, requirements
		Progression.tryBreakthrough(p, branchId, now)  -> ok, reason?
		Progression.record(p, kind, id, value, now)    -- facts used by breakthroughs and unlocks
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Magic = ReplicatedStorage.Shared.Magic
local Types = require(Magic.Types)
local Registry = require(Magic.Registry)
local MagicCore = require(Magic.MagicCore)
local Specialization = require(Magic.Specialization)
local InnateProfile = require(ServerScriptService.Server.Magic.InnateProfile)
local T = require(script.Parent.ProgressionTuning)
local Breakthroughs = require(script.Parent.Breakthroughs)
local SubBranchRules = require(script.Parent.SubBranchRules)

type Innate = Types.InnateProfile

-- In-memory per-player state for anti-grind checks. Never saved.
export type Runtime = {
	recent: { [string]: { n: number, t: number } }, -- recipeKey -> decayed repeat count
	castTimes: { number },
	lastActiveAt: number,
}

export type GainContext = {
	now: number,
	runtime: Runtime?,
	recipeKey: string?,
	power: number?,
	comfort: number?,
	effective: boolean?,
}

export type GainResult = {
	branch: string,
	gained: number,
	masteryBefore: number,
	masteryAfter: number,
	tierBefore: number,
	tierAfter: number,
	held: boolean, -- XP is banking behind an unmet breakthrough
	trickle: { [string]: number },
	factors: { [string]: number },
	reason: string?,
}

export type RequirementStatus = {
	text: string,
	met: boolean,
}

local Progression = {}

local Tiers = Registry.masteryTiers

-- ─── Curve ──────────────────────────────────────────────────────────────────

function Progression.xpForMastery(mastery: number): number
	return Tiers.xpScale * math.clamp(mastery, 0, 100) ^ Tiers.xpExponent
end

function Progression.masteryForXp(xp: number): number
	if xp <= 0 then
		return 0
	end
	return math.min(100, (xp / Tiers.xpScale) ^ (1 / Tiers.xpExponent))
end

-- XP earned by one practice cast, before multipliers: effort-weighted by its reservoir cost.
function Progression.practiceXp(reservoirCost: number): number
	return T.practice.base * math.max(0, reservoirCost) ^ T.practice.costExponent
end

function Progression.newRuntime(now: number): Runtime
	return { recent = {}, castTimes = {}, lastActiveAt = now }
end

local function round2(x: number): number
	return math.floor(x * 100 + 0.5) / 100
end

-- ─── Mastery & caps ─────────────────────────────────────────────────────────

local function hasBreakthrough(p: any, branchId: string, index: number): boolean
	local done = p.breakthroughs[branchId]
	return done ~= nil and done[tostring(index)] ~= nil
end

--[[
	(highest mastery reachable now, most XP that can be banked).
	Mastery holds just below the first breakthrough tier not yet completed. XP keeps banking up
	to the NEXT tier's threshold, so completing the breakthrough releases it all at once.
]]
function Progression.masteryCap(p: any, branchId: string): (number, number)
	for _, tier in Tiers.tiers do
		if tier.breakthrough and not hasBreakthrough(p, branchId, tier.index) then
			local nextTier = Tiers.tiers[tier.index + 2]
			local bank = if nextTier then Progression.xpForMastery(nextTier.minMastery) else Progression.xpForMastery(100)
			return tier.minMastery - 0.01, bank
		end
	end
	return 100, Progression.xpForMastery(100)
end

local function recompute(p: any, branchId: string)
	local cap = Progression.masteryCap(p, branchId)
	p.mastery[branchId] = round2(math.min(Progression.masteryForXp(p.xp[branchId] or 0), cap))
end
Progression.recompute = recompute

function Progression.getMasteryTier(p: any, branchId: string): (number, Types.MasteryTierDef)
	local tier = MagicCore.tierForMastery(p.mastery[branchId] or 0)
	if tier < 1 and p.unlocked[branchId] then
		tier = 1
	end
	return tier, MagicCore.tierDef(tier)
end

-- Adds XP directly (no multipliers), respecting the bank cap. Returns the amount actually added.
local function addRaw(p: any, branchId: string, amount: number): number
	if not p.unlocked[branchId] or amount <= 0 then
		return 0
	end
	local _, bank = Progression.masteryCap(p, branchId)
	local current = p.xp[branchId] or 0
	local added = math.max(0, math.min(amount, bank - current))
	p.xp[branchId] = current + added
	recompute(p, branchId)
	return added
end

-- Removes a fraction of XP from a branch and its whole subtree (used by renouncing an oath).
function Progression.removeExperience(p: any, branchId: string, fraction: number)
	for _, id in Specialization.subtree(branchId) do
		if p.xp[id] then
			p.xp[id] *= (1 - math.clamp(fraction, 0, 1))
			recompute(p, id)
		end
	end
end

-- ─── Focus & breadth ────────────────────────────────────────────────────────

local function decayed(entry: { v: number, t: number }?, now: number): number
	if not entry then
		return 0
	end
	return entry.v * 0.5 ^ (math.max(0, now - entry.t) / T.focus.halfLifeSeconds)
end

-- This domain's share (0..1) of the player's recent XP.
function Progression.focusShare(p: any, domainId: string, now: number): number
	local total, mine = 0, 0
	for d, entry in p.focus do
		local v = decayed(entry, now)
		total += v
		if d == domainId then
			mine = v
		end
	end
	return if total > 0 then mine / total else 1
end

-- The tier-1 line a branch belongs to (a hybrid's root counts as its own line). Nil for roots.
local function lineOf(branchId: string): string?
	local node = Registry.branches[branchId]
	if not node or node.isRoot then
		return nil
	end
	while node.tier > 1 do
		local parentId = node.parent
		if not parentId then
			break
		end
		node = Registry.branches[parentId]
	end
	return node.id
end

-- Distinct lines with at least Adept mastery somewhere in them.
function Progression.activeLines(p: any): number
	local lines: { [string]: boolean } = {}
	for branchId, mastery in p.mastery do
		if mastery >= T.breadth.lineThresholdMastery then
			local line = lineOf(branchId)
			if line then
				lines[line] = true
			end
		end
	end
	local count = 0
	for _ in lines do
		count += 1
	end
	return count
end

function Progression.breadthMultiplier(p: any): number
	local B = T.breadth
	return math.max(B.floor, 1 - B.penaltyPerLine * math.max(0, Progression.activeLines(p) - B.freeLines))
end

-- ─── Caps ───────────────────────────────────────────────────────────────────

local function rollDaily(p: any, now: number)
	local day = math.floor(now / 86400)
	if p.daily.day ~= day then
		p.daily.day = day
		p.daily.channels = {}
	end
	local hour = math.floor(now / 3600)
	if p.hourly.hour ~= hour then
		p.hourly.hour = hour
		p.hourly.practice = {}
	end
end

-- ─── Practice anti-grind ────────────────────────────────────────────────────

local function practiceFactors(p: any, branchId: string, ctx: GainContext, factors: { [string]: number })
	local P = T.practice
	local runtime = ctx.runtime
	local now = ctx.now

	-- AFK: no movement or aim change recently.
	if runtime and now - runtime.lastActiveAt > P.idleSeconds then
		factors.idle = 0
		return
	end

	-- Repeating the same recipe teaches less and less (decays back over ~10 minutes).
	if runtime and ctx.recipeKey then
		local entry = runtime.recent[ctx.recipeKey]
		local repeats = if entry then entry.n * 0.5 ^ ((now - entry.t) / P.repeatHalfLife) else 0
		factors.repetition = math.max(P.spamFloor, math.exp(-repeats / P.repeatScale))
		runtime.recent[ctx.recipeKey] = { n = repeats + 1, t = now }
	end

	-- Casting far below your comfort teaches little.
	if ctx.power and ctx.comfort then
		factors.relevance = math.clamp(ctx.power / math.max(1, ctx.comfort - 1), P.relevanceFloor, 1)
	end

	if ctx.effective == false then
		factors.effect = P.ineffective
	end

	-- Machine-regular cast timing (macros).
	if runtime then
		table.insert(runtime.castTimes, now)
		while #runtime.castTimes > P.metronomeCasts do
			table.remove(runtime.castTimes, 1)
		end
		local n = #runtime.castTimes
		if n == P.metronomeCasts then
			local intervals = {}
			for i = 2, n do
				table.insert(intervals, runtime.castTimes[i] - runtime.castTimes[i - 1])
			end
			local mean = 0
			for _, d in intervals do
				mean += d
			end
			mean /= #intervals
			local variance = 0
			for _, d in intervals do
				variance += (d - mean) ^ 2
			end
			local cv = if mean > 0 then math.sqrt(variance / #intervals) / mean else 0
			if cv < P.metronomeVariation then
				factors.metronome = P.metronomePenalty
			end
		end
	end

	-- Hourly soft cap per branch.
	if (p.hourly.practice[branchId] or 0) >= P.hourlySoftCap then
		factors.hourlyCap = P.hourlyOverflow
	end
end

-- ─── Experience ─────────────────────────────────────────────────────────────

--[[
	Awards XP for one learning event. `baseAmount` is the channel's raw amount (see
	ProgressionTuning); this applies learning style, growth curve, focus, breadth,
	specialization, anti-grind factors and daily caps, then trickles a share to ancestor
	branches (and to a hybrid's prerequisite branches).
]]
function Progression.addExperience(p: any, innate: Innate, branchId: string, channel: string, baseAmount: number, ctx: GainContext): GainResult
	local masteryBefore = p.mastery[branchId] or 0
	local tierBefore = Progression.getMasteryTier(p, branchId)
	local result: GainResult = {
		branch = branchId,
		gained = 0,
		masteryBefore = masteryBefore,
		masteryAfter = masteryBefore,
		tierBefore = tierBefore,
		tierAfter = tierBefore,
		held = false,
		trickle = {},
		factors = {},
	}
	local def = (T.channels :: any)[channel]
	local branch = Registry.branches[branchId]
	if not def then
		result.reason = "UNKNOWN_CHANNEL"
		return result
	elseif not branch or not p.unlocked[branchId] then
		result.reason = "LOCKED"
		return result
	elseif typeof(baseAmount) ~= "number" or baseAmount ~= baseAmount or baseAmount <= 0 then
		result.reason = "NO_XP"
		return result
	end
	rollDaily(p, ctx.now)

	local factors = result.factors
	local domainId = branch.domains[1]
	factors.channel = def.weight
	factors.style = if def.style then innate.learning[def.style] or 1 else 1
	factors.growth = InnateProfile.growthMultiplier(innate, masteryBefore)
	factors.focus = 1 + T.focus.maxBonus * Progression.focusShare(p, domainId, ctx.now) ^ 2
	factors.breadth = Progression.breadthMultiplier(p)
	local mod = Specialization.branchMods(p.commitments)[branchId]
	factors.specialization = if mod then mod.xp else 1
	if channel == "practice" or channel == "challenge" then
		practiceFactors(p, branchId, ctx, factors)
	end

	local amount = baseAmount
	for _, f in factors do
		amount *= f
	end
	if def.dailyCap then
		amount = math.min(amount, math.max(0, def.dailyCap - (p.daily.channels[channel] or 0)))
	end

	local gained = addRaw(p, branchId, amount)
	result.gained = gained
	if def.dailyCap then
		p.daily.channels[channel] = (p.daily.channels[channel] or 0) + gained
	end
	if channel == "practice" or channel == "challenge" then
		p.hourly.practice[branchId] = (p.hourly.practice[branchId] or 0) + gained
	end
	local focusEntry = p.focus[domainId]
	p.focus[domainId] = { v = decayed(focusEntry, ctx.now) + gained, t = ctx.now }

	-- Lineage: parents learn from their children; a hybrid's root feeds its prerequisites.
	local share = gained
	local node = branch
	while share > 0.01 do
		local parentId = node.parent
		if parentId then
			share *= T.lineage.trickle
			result.trickle[parentId] = addRaw(p, parentId, share)
			node = Registry.branches[parentId]
		else
			if node.isHybrid then
				for _, pre in node.prerequisites do
					result.trickle[pre.branch] = addRaw(p, pre.branch, share * T.lineage.hybridTrickle)
				end
			end
			break
		end
	end

	result.masteryAfter = p.mastery[branchId] or 0
	result.tierAfter = Progression.getMasteryTier(p, branchId)
	result.held = Progression.masteryForXp(p.xp[branchId] or 0) > result.masteryAfter + 0.01
	return result
end

-- ─── Unlocking ──────────────────────────────────────────────────────────────

function Progression.canUnlock(p: any, innate: Innate, branchId: string): (boolean, { SubBranchRules.Check })
	return SubBranchRules.evaluate(p, innate, branchId)
end

-- Unlocks and seeds the branch at Sensing. Returns (ok, checks).
function Progression.unlock(p: any, innate: Innate, branchId: string, _now: number): (boolean, { SubBranchRules.Check })
	if p.unlocked[branchId] then
		return true, {}
	end
	local ok, checks = Progression.canUnlock(p, innate, branchId)
	if not ok then
		return false, checks
	end
	p.unlocked[branchId] = true
	p.xp[branchId] = math.max(p.xp[branchId] or 0, Progression.xpForMastery(1))
	recompute(p, branchId)
	return true, checks
end

-- Every manifest domain's root is unlocked from birth. Returns the newly unlocked roots.
function Progression.ensureRoots(p: any, innate: Innate): { string }
	local added = {}
	for _, d in innate.manifest do
		if not p.unlocked[d] then
			p.unlocked[d] = true
			p.xp[d] = math.max(p.xp[d] or 0, Progression.xpForMastery(1))
			recompute(p, d)
			table.insert(added, d)
		end
	end
	return added
end

-- ─── Records (facts for breakthroughs and unlocks) ──────────────────────────

--[[
	kind: "insight" | "catalyst" | "survived" | "lore"   (id = what; stored with time)
	      "taught" | "discovery"                         (id = branchId; counts up)
	      "feat" | "challengeFeat"                       (id = branchId; value = power; keeps the max)
	      "mentor"                                       (id = branchId; value = mentor tier; keeps the max)
	      "paradigm"                                     (counts up)
]]
function Progression.record(p: any, kind: string, id: string, value: number?, now: number)
	local r = p.records
	if kind == "insight" then
		r.insights[id] = r.insights[id] or now
	elseif kind == "catalyst" then
		r.catalysts[id] = r.catalysts[id] or now
	elseif kind == "survived" then
		r.survived[id] = r.survived[id] or now
	elseif kind == "lore" then
		p.lore[id] = p.lore[id] or now
	elseif kind == "taught" then
		r.taught[id] = (r.taught[id] or 0) + 1
	elseif kind == "discovery" then
		r.discoveries[id] = (r.discoveries[id] or 0) + 1
	elseif kind == "feat" then
		r.feats[id] = math.max(r.feats[id] or 0, value or 0)
	elseif kind == "challengeFeat" then
		r.challengeFeats[id] = math.max(r.challengeFeats[id] or 0, value or 0)
		r.feats[id] = math.max(r.feats[id] or 0, value or 0)
	elseif kind == "mentor" then
		r.mentors[id] = math.max(r.mentors[id] or 0, value or 0)
	elseif kind == "paradigm" then
		r.paradigms = (r.paradigms or 0) + 1
	else
		error("Progression.record: unknown kind " .. kind)
	end
end

-- ─── Breakthroughs ──────────────────────────────────────────────────────────

local function requirementsFor(branchId: string, tierIndex: number): { Breakthroughs.Requirement }
	local def = Breakthroughs[tierIndex]
	if not def then
		return {}
	end
	return def.domains[Registry.branches[branchId].domains[1]] or def.default
end

local function requirementMet(p: any, branchId: string, req: Breakthroughs.Requirement): boolean
	local r = p.records
	local domain = Registry.branches[branchId].domains[1]
	if req.type == "insight" then
		if req.id then
			return r.insights[req.id] ~= nil
		end
		local count = 0
		for insightId in r.insights do
			if string.sub(insightId, 1, #domain + 1) == domain .. ":" then
				count += 1
			end
		end
		return count >= (req.count or 1)
	elseif req.type == "teach" then
		return (r.taught[branchId] or 0) >= (req.count or 1)
	elseif req.type == "survive" then
		return req.id ~= nil and r.survived[req.id] ~= nil
	elseif req.type == "discoveries" then
		return (r.discoveries[branchId] or 0) >= (req.count or 1)
	elseif req.type == "feat" then
		local best = if req.challenge then r.challengeFeats[branchId] else r.feats[branchId]
		return (best or 0) >= (req.minPower or 0)
	elseif req.type == "paradigm" then
		return (r.paradigms or 0) >= (req.count or 1)
	elseif req.type == "mentor" then
		return (r.mentors[branchId] or 0) >= (req.tier or 0)
	end
	return false
end

-- The next breakthrough this branch needs, with each requirement's status. Nil when none remain.
function Progression.breakthroughStatus(p: any, branchId: string): (number?, { RequirementStatus })
	for _, tier in Tiers.tiers do
		if tier.breakthrough and not hasBreakthrough(p, branchId, tier.index) then
			local list: { RequirementStatus } = {}
			for _, req in requirementsFor(branchId, tier.index) do
				table.insert(list, { text = req.text, met = requirementMet(p, branchId, req) })
			end
			return tier.index, list
		end
	end
	return nil, {}
end

--[[
	Completes the next breakthrough if the XP is banked AND every requirement is met.
	Returns (true, nil) or (false, "NONE_LEFT" | "NOT_ENOUGH_XP" | "REQUIREMENTS_UNMET").
]]
function Progression.tryBreakthrough(p: any, branchId: string, now: number): (boolean, string?)
	local index, list = Progression.breakthroughStatus(p, branchId)
	if not index then
		return false, "NONE_LEFT"
	end
	if Progression.masteryForXp(p.xp[branchId] or 0) < MagicCore.tierDef(index).minMastery then
		return false, "NOT_ENOUGH_XP"
	end
	for _, req in list do
		if not req.met then
			return false, "REQUIREMENTS_UNMET"
		end
	end
	p.breakthroughs[branchId] = p.breakthroughs[branchId] or {}
	p.breakthroughs[branchId][tostring(index)] = now
	recompute(p, branchId)
	return true, nil
end

return Progression
