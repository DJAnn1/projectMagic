--!strict
--[[
	InnateProfile (SERVER ONLY)
	Queries and mutations over a generated innate profile.

		getRarityTier(profile, includeHidden?)       -> "Common" .. "Mythic"
		getVisibleProfile(profile, knowledgeLevel)   -> VisibleProfile (safe to send to a client)
		applyAwakening(profile, eventId, context)    -> AwakeningResult (mutates profile)
		toCasterProfile(profile, progression)        -> CasterProfile for MagicCore / Reservoir
		traits(profile) / branchAffinity(profile, id) / growthMultiplier(profile, mastery)
		serialize(profile) / deserialize(data)       -> versioned save data
		signatureColors(profile)                     -> Color3s for VFX

	Never send the raw profile to a client: it contains hidden latents. Send getVisibleProfile.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Magic = ReplicatedStorage.Shared.Magic
local Types = require(Magic.Types)
local Registry = require(Magic.Registry)
local Seed = require(Magic.Seed)
local Specialization = require(Magic.Specialization)
local Temperaments = require(Magic.Data.Temperaments)
local GrowthCurves = require(Magic.Data.GrowthCurves)
local ProfileTuning = require(script.Parent.Data.ProfileTuning)
local AwakeningEvents = require(script.Parent.Data.AwakeningEvents)
local ProfileGenerator = require(script.Parent.ProfileGenerator)

type InnateProfile = Types.InnateProfile
type Latent = Types.Latent
type CasterProfile = Types.CasterProfile
type CasterTraits = Types.CasterTraits
type VisibleProfile = Types.VisibleProfile
type AwakeningResult = Types.AwakeningResult
type AwakeningContext = Types.AwakeningContext

local T = ProfileTuning

local InnateProfile = {}

InnateProfile.KNOWLEDGE = table.freeze({
	Untrained = 0, -- knows which domains they have, nothing more
	Aware = 1, -- feels relative strength and temperament
	Studied = 2, -- measured values, leanings, growth, learning style
	Introspective = 3, -- exact numbers and a sense of untapped depths
})

-- ─── Event data checks ──────────────────────────────────────────────────────

do
	local problems: { string } = {}
	local categories: { [string]: boolean } = { Mythic = true }
	for _, c in T.awakeningCategories do
		categories[c] = true
	end
	for id, def in AwakeningEvents do
		if not categories[def.category] then
			table.insert(problems, string.format("event %s has unknown category %s", id, def.category))
		end
		for _, d in (def.domains or {}) :: { string } do
			if not Registry.domains[d] then
				table.insert(problems, string.format("event %s lists unknown domain %s", id, d))
			end
		end
		if def.mythic and (not Registry.domains[def.mythic] or Registry.domains[def.mythic].rarity ~= "Mythic") then
			table.insert(problems, string.format("event %s mythic target %s is not a mythic domain", id, def.mythic))
		end
		if (def.category == "Mythic") ~= (def.mythic ~= nil) then
			table.insert(problems, string.format("event %s: Mythic category and mythic field must go together", id))
		end
		if def.risk and def.risk.temperament and not Temperaments[def.risk.temperament] then
			table.insert(problems, string.format("event %s risk temperament %s unknown", id, def.risk.temperament))
		end
		for fact, bound in (def.requires or {}) :: { [string]: { min: number?, max: number? } } do
			if bound.min == nil and bound.max == nil then
				table.insert(problems, string.format("event %s requirement %s has no bounds", id, fact))
			end
		end
	end
	if #problems > 0 then
		error("[InnateProfile] invalid awakening events:\n  " .. table.concat(problems, "\n  "), 0)
	end
end

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function round(x: number, places: number): number
	local m = 10 ^ places
	return math.floor(x * m + 0.5) / m
end

local function roundTo(x: number, step: number): number
	return round(math.floor(x / step + 0.5) * step, 2)
end

local function deepClone<V>(value: V): V
	if typeof(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value :: any do
		out[k] = deepClone(v)
	end
	return out :: any
end

local function bandFor(value: number): string?
	for _, band in T.bands do
		if value >= band.min then
			return band.name
		end
	end
	return nil
end

local function sortManifest(profile: InnateProfile)
	table.sort(profile.manifest, function(a, b)
		local va, vb = profile.domains[a] or 0, profile.domains[b] or 0
		if va ~= vb then
			return va > vb
		end
		return a < b
	end)
end

local function addManifest(profile: InnateProfile, domainId: string)
	if not table.find(profile.manifest, domainId) then
		table.insert(profile.manifest, domainId)
	end
	sortManifest(profile)
end

-- Adds a temperament. A conflicting existing temperament is REPLACED (a transformation).
local function addTemperament(profile: InnateProfile, id: string, changes: { string })
	if table.find(profile.temperaments, id) then
		return
	end
	for i = #profile.temperaments, 1, -1 do
		local other = profile.temperaments[i]
		if ProfileGenerator.temperamentsConflict(other, id) then
			table.remove(profile.temperaments, i)
			table.insert(changes, "temperament_lost:" .. other)
		end
	end
	table.insert(profile.temperaments, id)
	table.insert(changes, "temperament_gained:" .. id)
end

local function applyLatent(profile: InnateProfile, latent: Latent, changes: { string })
	latent.revealed = true
	if latent.kind == "Domain" or latent.kind == "Mythic" then
		local before = profile.domains[latent.target] or 0
		profile.domains[latent.target] = round(math.max(before, latent.strength), 3)
		addManifest(profile, latent.target)
		table.insert(changes, "domain_awakened:" .. latent.target)
	elseif latent.kind == "Amplify" then
		local before = profile.domains[latent.target] or 0
		profile.domains[latent.target] = round(math.min(1, before + latent.strength), 3)
		sortManifest(profile)
		table.insert(changes, "domain_amplified:" .. latent.target)
	elseif latent.kind == "Capacity" then
		profile.capacity = round(profile.capacity + latent.strength, 3)
		table.insert(changes, "capacity_increased")
	elseif latent.kind == "Temperament" then
		addTemperament(profile, latent.target, changes)
	end
end

-- Reveals one hidden latent now, as its awakening would (admin tools). Returns what changed.
function InnateProfile.revealLatent(profile: InnateProfile, latentId: string): { string }
	local changes: { string } = {}
	for _, latent in profile.latents do
		if latent.id == latentId and not latent.revealed then
			applyLatent(profile, latent, changes)
		end
	end
	return changes
end

-- ─── Derived values ─────────────────────────────────────────────────────────

-- Innate affinity for a branch line: its domain's affinity times the tier-1 ancestor's leaning.
function InnateProfile.branchAffinity(profile: InnateProfile, branchId: string): number
	local branch = Registry.branches[branchId]
	if not branch then
		return 0
	end
	local node = branch
	while node.tier > 1 do
		local parentId = node.parent
		if not parentId then
			break
		end
		node = Registry.branches[parentId]
	end
	local domainAffinity = profile.domains[branch.domains[1]] or 0
	if node.isRoot or node.isHybrid then
		return domainAffinity
	end
	return math.clamp(domainAffinity * (profile.leanings[node.id] or 1), 0, 1)
end

-- Temperaments x innate reservoir, folded into one trait table.
function InnateProfile.traits(profile: InnateProfile): CasterTraits
	local t: CasterTraits = table.clone(Registry.Tuning.neutralTraits)
	for _, id in profile.temperaments do
		local def = Temperaments[id]
		if not def then
			continue
		end
		local e = def.effects
		t.power *= e.power or 1
		t.cost *= e.cost or 1
		t.instability *= e.instability or 1
		t.castTime *= e.castTime or 1
		t.capacity *= e.capacity or 1
		t.regen *= e.regen or 1
		t.overdrawRisk *= e.overdrawRisk or 1
		t.vitalCost *= e.vitalCost or 1
		t.detectability *= e.detectability or 1
		t.ambientShareBonus += e.ambientShareBonus or 0
		t.allyPower += e.allyPower or 0
	end
	t.capacity *= profile.capacity
	t.regen *= profile.regen
	return t
end

--[[
	Builds the CasterProfile MagicCore and Reservoir consume.
	progression = the separately saved, earned state: mastery per branch, plus (when managed by
	the Progression system) the unlock set, specialization commitments and signature spells.
]]
function InnateProfile.toCasterProfile(
	profile: InnateProfile,
	progression: {
		mastery: { [string]: number },
		attunement: number?,
		unlocked: { [string]: boolean }?,
		commitments: { [string]: number }?,
		signatures: { [string]: number }?,
	}
): CasterProfile
	local awakened: { [string]: boolean } = {}
	for _, d in profile.manifest do
		awakened[d] = true
	end
	local branchAffinities: { [string]: number } = {}
	for _, d in profile.manifest do
		for _, branchId in Registry.branches[d].children do
			branchAffinities[branchId] = InnateProfile.branchAffinity(profile, branchId)
		end
	end
	return {
		id = profile.entityId,
		attunement = progression.attunement,
		affinities = table.clone(profile.domains),
		awakened = awakened,
		mastery = progression.mastery,
		branchAffinities = branchAffinities,
		traits = InnateProfile.traits(profile),
		unlocked = progression.unlocked,
		branchMods = Specialization.branchMods(progression.commitments),
		signatures = progression.signatures,
	}
end

-- Mastery gain multiplier for this person at the given mastery (0..100).
function InnateProfile.growthMultiplier(profile: InnateProfile, mastery: number): number
	local curve = GrowthCurves[profile.growth] or GrowthCurves.steady
	local points = if profile.breakthrough and curve.afterBreakthrough then curve.afterBreakthrough else curve.points
	local m = math.clamp(mastery, 0, 100)
	if m <= points[1][1] then
		return points[1][2]
	end
	for i = 2, #points do
		local a, b = points[i - 1], points[i]
		if m <= b[1] then
			local t = (m - a[1]) / math.max(1e-6, b[1] - a[1])
			return a[2] + (b[2] - a[2]) * t
		end
	end
	return points[#points][2]
end

function InnateProfile.signatureColors(profile: InnateProfile): { primary: Color3, secondary: Color3, accent: Color3 }
	local s = profile.signature
	return {
		primary = Color3.fromHex(s.primary),
		secondary = Color3.fromHex(s.secondary),
		accent = Color3.fromHex(s.accent),
	}
end

-- ─── Rarity ─────────────────────────────────────────────────────────────────

--[[
	The person's rarity tier. includeHidden (default true) projects unrevealed latents, i.e.
	what they COULD become. Use includeHidden=false for anything a player or NPC can perceive.
]]
function InnateProfile.getRarityTier(profile: InnateProfile, includeHidden: boolean?): string
	local hidden = includeHidden ~= false
	local domains = table.clone(profile.domains)
	local manifest: { [string]: boolean } = {}
	for _, d in profile.manifest do
		manifest[d] = true
	end

	if hidden then
		for _, latent in profile.latents do
			if latent.revealed then
				continue
			end
			if latent.kind == "Mythic" then
				return "Mythic"
			elseif latent.kind == "Domain" then
				domains[latent.target] = math.max(domains[latent.target] or 0, latent.strength)
				manifest[latent.target] = true
			elseif latent.kind == "Amplify" then
				domains[latent.target] = math.min(1, (domains[latent.target] or 0) + latent.strength)
			end
		end
	end

	local R = T.rarity
	local meaningful, exceptional = 0, 0
	local hasUnusual, hasRareNotable, hasRareStrong = false, false, false
	local top = 0
	for d in manifest do
		local rarity = Registry.domains[d].rarity
		local value = domains[d] or 0
		if rarity == "Mythic" then
			return "Mythic"
		end
		meaningful += 1
		top = math.max(top, value)
		if value >= T.exceptionalThreshold then
			exceptional += 1
		end
		if rarity == "Rare" or rarity == "Uncommon" then
			hasUnusual = hasUnusual or value >= R.uncommonDomainAffinity
		end
		if rarity == "Rare" then
			hasRareNotable = hasRareNotable or value >= R.rareRareDomainAffinity
			hasRareStrong = hasRareStrong or value >= R.epicRareDomainAffinity
		end
	end

	local gift = if hidden then profile.giftTier else nil
	local giftShows = gift == "Gifted" and top >= R.rareGiftedTopAffinity
	if gift == "Paragon" or exceptional >= R.legendaryExceptionalCount then
		return "Legendary"
	elseif gift == "Prodigy" or exceptional >= 1 or hasRareStrong then
		return "Epic"
	elseif giftShows or hasRareNotable or meaningful >= R.rareMeaningfulCount then
		return "Rare"
	elseif hasUnusual or meaningful >= R.uncommonMeaningfulCount then
		return "Uncommon"
	end
	return "Common"
end

-- ─── Visibility ─────────────────────────────────────────────────────────────

--[[
	What someone with `knowledgeLevel` perceives about this profile. Used both for
	self-knowledge (a player's own sheet) and for observers (an NPC scholar reading you).
	Unrevealed latents are never described; mythic latents are never even hinted at.
]]
function InnateProfile.getVisibleProfile(profile: InnateProfile, knowledgeLevel: number): VisibleProfile
	local level = math.clamp(math.floor(knowledgeLevel), 0, 3)
	local step = if level >= 3 then 0.01 else 0.05

	local visible: VisibleProfile = {
		entityId = profile.entityId,
		knowledgeLevel = level,
		domains = {},
		signature = table.clone(profile.signature),
	}

	for _, d in profile.manifest do
		local value = profile.domains[d] or 0
		table.insert(visible.domains, {
			domain = d,
			band = if level >= 1 then bandFor(value) else nil,
			value = if level >= 2 then roundTo(value, step) else nil,
		})
	end

	if level >= 2 then
		-- Unawakened domains: faint stirrings at Studied, everything non-mythic at Introspective.
		for _, d in Registry.domainIds do
			local value = profile.domains[d] or 0
			if table.find(profile.manifest, d) or Registry.domains[d].rarity == "Mythic" then
				continue
			end
			if value >= 0.1 or (level >= 3 and value > 0) then
				table.insert(visible.domains, {
					domain = d,
					band = bandFor(value),
					value = if level >= 3 then roundTo(value, step) else nil,
				})
			end
		end

		local leanings: { [string]: number } = {}
		for _, d in profile.manifest do
			for _, branchId in Registry.branches[d].children do
				leanings[branchId] = roundTo(InnateProfile.branchAffinity(profile, branchId), step)
			end
		end
		visible.leanings = leanings
		visible.growth = profile.growth

		local favored: string? = nil
		local best = -math.huge
		for _, style in T.learning.styles do
			local v = profile.learning[style] or 1
			if v > best then
				favored, best = style, v
			end
		end
		visible.favoredLearning = favored

		local capacity = InnateProfile.traits(profile).capacity
		for _, band in T.capacityBands do
			if capacity >= band.min then
				visible.capacityBand = band.name
				break
			end
		end
		visible.rarityTier = InnateProfile.getRarityTier(profile, false)
	end

	if level >= 1 then
		visible.temperaments = table.clone(profile.temperaments)
	end

	if level >= 3 then
		local traits = InnateProfile.traits(profile)
		visible.capacity = round(traits.capacity, 2)
		visible.regen = round(traits.regen, 2)
		visible.learning = table.clone(profile.learning)
		local hints: { string } = {}
		for _, latent in profile.latents do
			if not latent.revealed and latent.kind ~= "Mythic" then
				table.insert(hints, latent.triggers[1])
			end
		end
		visible.latentHints = hints
	end

	return visible
end

-- ─── Awakening ──────────────────────────────────────────────────────────────

--[[
	Applies an awakening event the CALLER has already verified happened (server-side).
	Deterministic: randomness comes from Seed(worldSeed, entityId, "awakening:<id>", occurrence).
	Mutates the profile; persist it afterwards and rebuild the CasterProfile / Reservoir max.
]]
function InnateProfile.applyAwakening(profile: InnateProfile, eventId: string, context: AwakeningContext): AwakeningResult
	local result: AwakeningResult = { ok = false, revealed = {}, changes = {} }
	local def = AwakeningEvents[eventId]
	if not def then
		result.reason = "UNKNOWN_EVENT"
		return result
	end
	if typeof(context.now) ~= "number" or context.now ~= context.now then
		result.reason = "BAD_CONTEXT"
		return result
	end

	if def.requires then
		local facts = context.facts or {}
		for fact, bound in def.requires do
			local value = facts[fact]
			if typeof(value) ~= "number" or value ~= value
				or (bound.min ~= nil and value < bound.min)
				or (bound.max ~= nil and value > bound.max)
			then
				result.reason = "TRIGGER_NOT_MET"
				return result
			end
		end
	end

	local record = profile.awakenings[eventId] or { count = 0, lastAt = -math.huge }
	if def.once and record.count > 0 then
		result.reason = "ALREADY_EXPERIENCED"
		return result
	end
	if record.count > 0 and context.now - record.lastAt < def.cooldownHours * 3600 then
		result.reason = "ON_COOLDOWN"
		return result
	end

	local rng = Seed.random(profile.worldSeed, profile.entityId, "awakening:" .. eventId, record.count + 1)

	local eventDomains: { string }? = def.domains
	if def.domainFromContext then
		eventDomains = if context.domain and Registry.domains[context.domain] then { context.domain } else {}
	end

	-- Which hidden latents can this moment reach?
	local eligible: { Latent } = {}
	for _, latent in profile.latents do
		if latent.revealed then
			continue
		end
		if def.mythic then
			if latent.kind == "Mythic" and latent.target == def.mythic then
				table.insert(eligible, latent)
			end
		elseif latent.kind ~= "Mythic"
			and table.find(def.reveals, latent.kind)
			and table.find(latent.triggers, def.category)
		then
			local domainBound = latent.kind == "Domain" or latent.kind == "Amplify"
			if not domainBound or eventDomains == nil or table.find(eventDomains, latent.target) then
				table.insert(eligible, latent)
			end
		end
	end
	table.sort(eligible, function(a, b)
		if a.strength ~= b.strength then
			return a.strength > b.strength
		end
		return a.id < b.id
	end)

	for i = 1, math.min(def.maxReveals, #eligible) do
		applyLatent(profile, eligible[i], result.changes)
		table.insert(result.revealed, table.clone(eligible[i]))
	end

	-- Nothing hidden to find: a small, diminishing nudge to a related awakened domain.
	if #result.revealed == 0 and def.minorGain > 0 then
		local best: string? = nil
		local bestValue = -1
		for _, d in profile.manifest do
			if eventDomains == nil or table.find(eventDomains, d) then
				local v = profile.domains[d] or 0
				if v > bestValue then
					best, bestValue = d, v
				end
			end
		end
		if best then
			local gain = def.minorGain * 0.5 ^ record.count
			profile.domains[best] = round(math.min(1, bestValue + gain), 3)
			sortManifest(profile)
			table.insert(result.changes, "domain_nudged:" .. best)
		end
	end

	if profile.growth == "breakthrough" and not profile.breakthrough then
		if #result.revealed > 0 or def.category == "Danger" or def.category == "Emotion" or def.category == "Mentor" then
			profile.breakthrough = true
			table.insert(result.changes, "breakthrough")
		end
	end

	if def.risk and rng:NextNumber() < def.risk.chance then
		result.risk = def.risk.description
		if def.risk.temperament then
			addTemperament(profile, def.risk.temperament, result.changes)
		end
		if def.risk.capacityLoss then
			profile.capacity = round(math.max(0.3, profile.capacity - def.risk.capacityLoss), 3)
			table.insert(result.changes, "capacity_scarred")
		end
	end

	profile.awakenings[eventId] = { count = record.count + 1, lastAt = context.now }
	table.insert(profile.history, { e = eventId, t = context.now })
	while #profile.history > T.historyCap do
		table.remove(profile.history, 1)
	end

	result.ok = true
	return result
end

-- ─── Persistence ────────────────────────────────────────────────────────────

-- MIGRATIONS[n] upgrades a version-n save to n+1. Never edit a shipped entry; append.
local MIGRATIONS: { [number]: (any) -> any } = {}

function InnateProfile.serialize(profile: InnateProfile): any
	local data = deepClone(profile)
	data.v = T.PROFILE_VERSION
	return data
end

--[[
	Returns (profile, nil) or (nil, reason). On failure the caller may regenerate from
	(worldSeed, entityId), but earned awakenings would be lost, so log loudly.
]]
function InnateProfile.deserialize(data: any): (InnateProfile?, string?)
	if typeof(data) ~= "table" or typeof(data.v) ~= "number" then
		return nil, "not a profile"
	end
	if data.v > T.PROFILE_VERSION then
		return nil, "saved by a newer server version"
	end
	local working = deepClone(data)
	while working.v < T.PROFILE_VERSION do
		local migrate = MIGRATIONS[working.v]
		if not migrate then
			return nil, "no migration from v" .. tostring(working.v)
		end
		working = migrate(working)
		working.v += 1
	end
	for _, field in { "entityId", "giftTier", "growth" } do
		if typeof(working[field]) ~= "string" then
			return nil, "missing " .. field
		end
	end
	for _, field in { "domains", "leanings", "manifest", "temperaments", "learning", "latents", "signature", "awakenings", "history" } do
		if typeof(working[field]) ~= "table" then
			return nil, "missing " .. field
		end
	end
	-- Resolve renamed ids so old saves survive content changes (see Data/Aliases).
	local domains: { [string]: number } = {}
	for id, value in working.domains do
		domains[Registry.resolveAlias("domains", id)] = value
	end
	for _, d in Registry.domainIds do
		domains[d] = domains[d] or 0 -- domains added after this save start at 0
	end
	working.domains = domains
	for i, d in working.manifest do
		working.manifest[i] = Registry.resolveAlias("domains", d)
	end
	return working :: InnateProfile, nil
end

return InnateProfile
