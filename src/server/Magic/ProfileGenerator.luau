--!strict
--[[
	ProfileGenerator (SERVER ONLY)
	Builds a person's innate magical profile from (worldSeed, entityId, context).

	Determinism
	- Every aspect draws from its OWN seeded stream: Seed.random(worldSeed, entityId, "profile.<aspect>").
	  Retuning temperaments therefore never reshuffles anyone's domains, and so on.
	- All weighted picks iterate ARRAYS or sorted id lists, never dictionary order.
	- Same (worldSeed, entityId, context, GENERATOR_VERSION) gives an identical profile on any server, forever.
	- No pity, no global state: every person is an independent draw.

	SECURITY: never replicate the world seed or this module. With both, a client could compute
	every NPC's hidden latents, including who carries mythic potential.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Magic = ReplicatedStorage.Shared.Magic
local Types = require(Magic.Types)
local Registry = require(Magic.Registry)
local Seed = require(Magic.Seed)
local Temperaments = require(Magic.Data.Temperaments)
local GrowthCurves = require(Magic.Data.GrowthCurves)
local ProfileTuning = require(script.Parent.Data.ProfileTuning)

type InnateProfile = Types.InnateProfile
type Latent = Types.Latent
type GenerateContext = Types.GenerateContext
type Weighted = { id: string, weight: number }

local T = ProfileTuning

local ProfileGenerator = {}

-- ─── Data checks (fail at boot, not mid-game) ───────────────────────────────

do
	local problems: { string } = {}
	for _, entry in T.temperamentWeights do
		if not Temperaments[entry.id] then
			table.insert(problems, "temperamentWeights lists unknown temperament " .. entry.id)
		end
	end
	for id, def in Temperaments do
		for _, other in def.excludes or {} do
			if not Temperaments[other] then
				table.insert(problems, string.format("temperament %s excludes unknown %s", id, other))
			end
		end
	end
	for _, entry in T.growthWeights do
		if not GrowthCurves[entry.id] then
			table.insert(problems, "growthWeights lists unknown curve " .. entry.id)
		end
	end
	for _, entry in T.mythic.domains do
		local def = Registry.domains[entry.id]
		if not def or def.rarity ~= "Mythic" then
			table.insert(problems, "mythic.domains lists non-mythic domain " .. entry.id)
		end
	end
	if #problems > 0 then
		error("[ProfileGenerator] invalid tuning:\n  " .. table.concat(problems, "\n  "), 0)
	end
end

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function round(x: number, places: number): number
	local m = 10 ^ places
	return math.floor(x * m + 0.5) / m
end

local function lerp(a: number, b: number, t: number): number
	return a + (b - a) * t
end

local function pickWeighted(rng: Random, items: { Weighted }): string?
	local total = 0
	for _, item in items do
		total += math.max(0, item.weight)
	end
	if total <= 0 then
		return nil
	end
	local roll = rng:NextNumber() * total
	local last: string? = nil
	for _, item in items do
		if item.weight > 0 then
			last = item.id
			roll -= item.weight
			if roll < 0 then
				return item.id
			end
		end
	end
	return last -- floating-point guard
end

-- Picks an index 1..#weights.
local function pickIndex(rng: Random, weights: { number }): number
	local items: { Weighted } = {}
	for i, w in weights do
		table.insert(items, { id = tostring(i), weight = w })
	end
	return tonumber(pickWeighted(rng, items)) or 1
end

local function removeId(items: { Weighted }, id: string)
	for i, item in items do
		if item.id == id then
			table.remove(items, i)
			return
		end
	end
end

local function temperamentsConflict(a: string, b: string): boolean
	if a == b then
		return true
	end
	local da, db = Temperaments[a], Temperaments[b]
	return (da.excludes ~= nil and table.find(da.excludes, b) ~= nil)
		or (db.excludes ~= nil and table.find(db.excludes, a) ~= nil)
end
ProfileGenerator.temperamentsConflict = temperamentsConflict

local function canAddTemperament(owned: { string }, id: string): boolean
	for _, other in owned do
		if temperamentsConflict(other, id) then
			return false
		end
	end
	return true
end

local tierIndex: { [string]: number } = {}
for i, tier in T.giftTiers do
	tierIndex[tier.id] = i
end

local function stream(worldSeed: number, entityId: string, aspect: string): Random
	return Seed.random(worldSeed, entityId, "profile." .. aspect)
end

-- ─── Rarity rolls (also used directly by the fast debug sampler) ─────────────

-- Returns the gift tier index and potential. Floors and forces never change which random
-- numbers are drawn, only how they are interpreted, so a floor doesn't reshuffle anything else.
function ProfileGenerator.rollGift(worldSeed: number, entityId: string, context: GenerateContext?): (number, number)
	local ctx: GenerateContext = context or {}
	local rng = stream(worldSeed, entityId, "gift")
	local items: { Weighted } = {}
	for _, tier in T.giftTiers do
		table.insert(items, { id = tier.id, weight = tier.weight })
	end
	local index = tierIndex[pickWeighted(rng, items) or "Modest"]
	local u = rng:NextNumber()

	local floorId = ctx.minGiftTier or (if ctx.kind == "Player" then T.playerMinGiftTier else nil)
	if floorId and tierIndex[floorId] and index < tierIndex[floorId] then
		index = tierIndex[floorId]
	end
	if ctx.forceGiftTier and tierIndex[ctx.forceGiftTier] then
		index = tierIndex[ctx.forceGiftTier]
	end
	local tier = T.giftTiers[index]
	return index, lerp(tier.min, tier.max, u)
end

-- Returns the mythic domain carried as a hidden latent (or nil) and its strength.
function ProfileGenerator.rollMythic(worldSeed: number, entityId: string, giftIndex: number, context: GenerateContext?): (string?, number)
	local ctx: GenerateContext = context or {}
	local rng = stream(worldSeed, entityId, "mythic")
	local chance = T.mythic.baseChance * T.giftTiers[giftIndex].mythicMult
	local roll = rng:NextNumber()
	local pick = rng:NextNumber() -- always drawn, so forcing doesn't shift the stream
	local strengthU = rng:NextNumber()

	local domain: string? = nil
	if ctx.forceMythic and Registry.domains[ctx.forceMythic] and Registry.domains[ctx.forceMythic].rarity == "Mythic" then
		domain = ctx.forceMythic
	elseif roll < chance then
		local total = 0
		for _, d in T.mythic.domains do
			total += d.weight
		end
		local r = pick * total
		for _, d in T.mythic.domains do
			r -= d.weight
			if r < 0 then
				domain = d.id
				break
			end
		end
		domain = domain or T.mythic.domains[#T.mythic.domains].id
	end
	local range = T.latentStrength.Mythic
	return domain, round(lerp(range[1], range[2], strengthU), 3)
end

-- Cheap path for statistics: only the gift and mythic rolls.
function ProfileGenerator.sampleRarity(worldSeed: number, entityId: string, context: GenerateContext?): (string, string?)
	local giftIndex = ProfileGenerator.rollGift(worldSeed, entityId, context)
	local mythic = ProfileGenerator.rollMythic(worldSeed, entityId, giftIndex, context)
	return T.giftTiers[giftIndex].id, mythic
end

-- ─── Aspects ────────────────────────────────────────────────────────────────

local function rollDomains(worldSeed: number, entityId: string, giftIndex: number, potential: number, ctx: GenerateContext): ({ [string]: number }, { string })
	local tier = T.giftTiers[giftIndex]
	local rng = stream(worldSeed, entityId, "domains")
	local count = pickIndex(rng, tier.domainCount)

	local bias = ctx.domainBias or {}
	local candidates: { Weighted } = {}
	for _, d in Registry.domainIds do
		local w = T.domainRarityWeight[Registry.domains[d].rarity] * (bias[d] or 1)
		if w > 0 then
			table.insert(candidates, { id = d, weight = w })
		end
	end

	local primaries: { string } = {}
	for _ = 1, count do
		local pick = pickWeighted(rng, candidates)
		if not pick then
			break
		end
		table.insert(primaries, pick)
		removeId(candidates, pick)
	end

	local A = T.affinity
	local arng = stream(worldSeed, entityId, "affinity")
	local domains: { [string]: number } = {}
	for _, d in Registry.domainIds do
		domains[d] = 0
		if Registry.domains[d].rarity ~= "Mythic" then
			domains[d] = round(A.backgroundMax * arng:NextNumber() ^ A.backgroundExponent, 3)
		end
	end
	for rank, d in primaries do
		local jitter = lerp(A.jitterMin, A.jitterMax, arng:NextNumber())
		local value = potential * (A.rankFactor[rank] or A.rankFactor[#A.rankFactor]) * jitter
		domains[d] = round(math.clamp(math.max(value, A.primaryFloor), 0, 1), 3)
	end

	-- Manifest = awake from birth, strongest first (ties by id for determinism).
	local manifest = table.clone(primaries)
	table.sort(manifest, function(a, b)
		if domains[a] ~= domains[b] then
			return domains[a] > domains[b]
		end
		return a < b
	end)
	return domains, manifest
end

local function rollLeanings(worldSeed: number, entityId: string): { [string]: number }
	local rng = stream(worldSeed, entityId, "leanings")
	local L = T.leaning
	local leanings: { [string]: number } = {}
	for _, domainId in Registry.domainIds do
		local children = Registry.branches[domainId].children
		if #children == 0 then
			continue
		end
		local favored = rng:NextInteger(1, #children)
		for i, branchId in children do
			local lean = lerp(L.min, L.max, rng:NextNumber())
			if i == favored then
				lean *= L.favoredMult
			end
			leanings[branchId] = round(lean, 3)
		end
	end
	return leanings
end

local function rollTemperaments(worldSeed: number, entityId: string): { string }
	local rng = stream(worldSeed, entityId, "temperament")
	local count = pickIndex(rng, T.temperamentCount) - 1
	local chosen: { string } = {}
	for _ = 1, count do
		local pool: { Weighted } = {}
		for _, entry in T.temperamentWeights do
			if canAddTemperament(chosen, entry.id) then
				table.insert(pool, entry)
			end
		end
		local pick = pickWeighted(rng, pool)
		if not pick then
			break
		end
		table.insert(chosen, pick)
	end
	return chosen
end

local function rollLearning(worldSeed: number, entityId: string): { [string]: number }
	local rng = stream(worldSeed, entityId, "learning")
	local L = T.learning
	local favored = rng:NextInteger(1, #L.styles)
	local weak = rng:NextInteger(1, #L.styles - 1)
	if weak >= favored then
		weak += 1
	end
	local learning: { [string]: number } = {}
	for i, style in L.styles do
		local u = rng:NextNumber()
		local value = if i == favored
			then lerp(L.favoredMin, L.favoredMax, u)
			elseif i == weak then lerp(L.weakMin, L.weakMax, u)
			else lerp(L.otherMin, L.otherMax, u)
		learning[style] = round(value, 3)
	end
	return learning
end

local function rollLatents(
	worldSeed: number,
	entityId: string,
	domains: { [string]: number },
	manifest: { string },
	temperaments: { string },
	ctx: GenerateContext
): { Latent }
	local rng = stream(worldSeed, entityId, "latents")
	local count = pickIndex(rng, T.latentCount) - 1
	local latents: { Latent } = {}
	local targeted: { [string]: boolean } = {}
	local bias = ctx.domainBias or {}

	local function strength(kind: string): number
		local range = T.latentStrength[kind]
		return round(lerp(range[1], range[2], rng:NextNumber()), 3)
	end

	local function triggers(): { string }
		local pool = table.clone(T.awakeningCategories)
		local out: { string } = {}
		for _ = 1, math.min(T.latentTriggerCount, #pool) do
			table.insert(out, table.remove(pool, rng:NextInteger(1, #pool)) :: string)
		end
		table.sort(out)
		return out
	end

	for i = 1, count do
		local kind = pickWeighted(rng, T.latentKinds) or "Capacity"
		local target = ""

		if kind == "Domain" then
			local pool: { Weighted } = {}
			for _, d in Registry.domainIds do
				local rarity = Registry.domains[d].rarity
				if not table.find(manifest, d) and not targeted[d] then
					local w = T.domainRarityWeight[rarity] * T.latentRarityBoost[rarity] * (bias[d] or 1)
					if w > 0 then
						table.insert(pool, { id = d, weight = w })
					end
				end
			end
			local pick = pickWeighted(rng, pool)
			if pick then
				target = pick
			else
				kind = "Capacity"
			end
		elseif kind == "Amplify" then
			local pool: { Weighted } = {}
			for _, d in manifest do
				if not targeted["amp:" .. d] then
					table.insert(pool, { id = d, weight = 1 })
				end
			end
			local pick = pickWeighted(rng, pool)
			if pick then
				target = pick
			else
				kind = "Capacity"
			end
		elseif kind == "Temperament" then
			local pool: { Weighted } = {}
			for _, entry in T.temperamentWeights do
				if canAddTemperament(temperaments, entry.id) and not targeted["tmp:" .. entry.id] then
					table.insert(pool, entry)
				end
			end
			local pick = pickWeighted(rng, pool)
			if pick then
				target = pick
			else
				kind = "Capacity"
			end
		end

		if kind == "Domain" then
			targeted[target] = true
		elseif kind == "Amplify" then
			targeted["amp:" .. target] = true
		elseif kind == "Temperament" then
			targeted["tmp:" .. target] = true
		end

		table.insert(latents, {
			id = "L" .. i,
			kind = kind,
			target = target,
			strength = strength(kind),
			triggers = triggers(),
			revealed = false,
		})
	end
	return latents
end

local function rollSignature(worldSeed: number, entityId: string, manifest: { string }): Types.Signature
	local rng = stream(worldSeed, entityId, "signature")
	local S = T.signature

	local function vary(c: Color3): Color3
		local h, s, v = c:ToHSV()
		h = (h + (rng:NextNumber() * 2 - 1) * S.hueShift) % 1
		s = math.clamp(s * lerp(0.8, 1.1, rng:NextNumber()), 0, 1)
		v = math.clamp(v * lerp(0.85, 1.05, rng:NextNumber()), 0, 1)
		return Color3.fromHSV(h, s, v)
	end

	local topPalette = Registry.domains[manifest[1]].feel.palette
	local primary = vary(topPalette[1])
	local secondary = if manifest[2]
		then vary(Registry.domains[manifest[2]].feel.palette[1])
		else vary(topPalette[2] or topPalette[1])
	local accent = Color3.fromHSV(rng:NextNumber(), lerp(0.5, 0.9, rng:NextNumber()), lerp(0.8, 1, rng:NextNumber()))

	return {
		primary = primary:ToHex(),
		secondary = secondary:ToHex(),
		accent = accent:ToHex(),
		particle = S.particles[rng:NextInteger(1, #S.particles)],
		motion = S.motions[rng:NextInteger(1, #S.motions)],
		timbre = S.timbres[rng:NextInteger(1, #S.timbres)],
		pitch = math.floor((rng:NextNumber() + rng:NextNumber() - 1) * S.pitchRange + 0.5),
	}
end

-- ─── Public ─────────────────────────────────────────────────────────────────

--[[
	worldSeed : integer, server-secret
	entityId  : stable id, e.g. "player:12345" or "npc:village_03:7"
	context   : optional; must itself be deterministic (stored with the NPC, or derived from
	            its spawn data) or regeneration won't reproduce the same profile.
]]
function ProfileGenerator.generate(worldSeed: number, entityId: string, context: GenerateContext?): InnateProfile
	local ctx: GenerateContext = context or {}

	local giftIndex, potential = ProfileGenerator.rollGift(worldSeed, entityId, ctx)
	local mythicDomain, mythicStrength = ProfileGenerator.rollMythic(worldSeed, entityId, giftIndex, ctx)
	local domains, manifest = rollDomains(worldSeed, entityId, giftIndex, potential, ctx)
	local temperaments = rollTemperaments(worldSeed, entityId)
	local latents = rollLatents(worldSeed, entityId, domains, manifest, temperaments, ctx)
	if mythicDomain then
		table.insert(latents, {
			id = "LM",
			kind = "Mythic",
			target = mythicDomain,
			strength = mythicStrength,
			triggers = { "Mythic" },
			revealed = false,
		})
	end

	local R = T.reservoir
	local rrng = stream(worldSeed, entityId, "reservoir")
	local capacity = (R.capacityBase + R.capacityPerPotential * potential) * (1 + R.capacityJitter * (rrng:NextNumber() * 2 - 1))
	local regen = lerp(R.regenMin, R.regenMax, rrng:NextNumber())

	local growth = pickWeighted(stream(worldSeed, entityId, "growth"), T.growthWeights) or "steady"

	return {
		v = T.PROFILE_VERSION,
		gen = T.GENERATOR_VERSION,
		worldSeed = worldSeed,
		entityId = entityId,
		kind = ctx.kind or "NPC",
		giftTier = T.giftTiers[giftIndex].id,
		potential = round(potential, 3),
		capacity = round(capacity, 3),
		regen = round(regen, 3),
		domains = domains,
		leanings = rollLeanings(worldSeed, entityId),
		manifest = manifest,
		temperaments = temperaments,
		growth = growth,
		breakthrough = false,
		learning = rollLearning(worldSeed, entityId),
		latents = latents,
		signature = rollSignature(worldSeed, entityId, manifest),
		awakenings = {},
		history = {},
	}
end

return ProfileGenerator
