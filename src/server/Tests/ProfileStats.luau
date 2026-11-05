--!strict
--[[
	ProfileStats: generate N innate profiles and print a statistical summary for tuning.
	Runs automatically in Studio (see init.server.luau). From the command bar:

		require(game.ServerScriptService.Server.Tests.ProfileStats)(5000, 42)

	args: count (default 1000), worldSeed (default 1337), mythicSamples (default 200000)
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Magic = ReplicatedStorage.Shared.Magic
local Types = require(Magic.Types)
local Registry = require(Magic.Registry)
local MagicCore = require(Magic.MagicCore)
local ServerMagic = ServerScriptService.Server.Magic
local ProfileGenerator = require(ServerMagic.ProfileGenerator)
local InnateProfile = require(ServerMagic.InnateProfile)
local ProfileTuning = require(ServerMagic.Data.ProfileTuning)

type InnateProfile = Types.InnateProfile

local T = ProfileTuning

local function pct(n: number, total: number): string
	return string.format("%6.2f%%", if total > 0 then 100 * n / total else 0)
end

local function increment(map: { [string]: number }, key: string, by: number?)
	map[key] = (map[key] or 0) + (by or 1)
end

local function deepEqual(a: any, b: any): boolean
	if typeof(a) ~= typeof(b) then
		return false
	end
	if typeof(a) ~= "table" then
		return a == b
	end
	for k, v in a do
		if not deepEqual(v, b[k]) then
			return false
		end
	end
	for k in b do
		if a[k] == nil then
			return false
		end
	end
	return true
end

return function(count: number?, worldSeed: number?, mythicSamples: number?)
	local n = count or 1000
	local seed = worldSeed or 1337
	local samples = mythicSamples or 200000
	local passed, failed = 0, 0
	local function check(name: string, ok: boolean, detail: string?)
		if ok then
			passed += 1
		else
			failed += 1
			warn("  ✗ " .. name .. (if detail then " -> " .. detail else ""))
		end
	end

	print(string.format("════════ Innate profile statistics: %d people, worldSeed %d ════════", n, seed))

	-- ─── Generate ──────────────────────────────────────────────────────────
	local start = os.clock()
	local profiles: { InnateProfile } = {}
	for i = 1, n do
		profiles[i] = ProfileGenerator.generate(seed, "npc:" .. i)
		if i % 2000 == 0 then
			task.wait()
		end
	end
	local elapsed = os.clock() - start
	print(string.format("generated in %.1f ms (%.1f µs/profile)", elapsed * 1000, elapsed * 1e6 / n))

	-- ─── Tally ─────────────────────────────────────────────────────────────
	local gift: { [string]: number } = {}
	local rarityHidden: { [string]: number } = {}
	local rarityVisible: { [string]: number } = {}
	local manifestCount: { [string]: number } = {}
	local domainManifest: { [string]: number } = {}
	local domainTop: { [string]: number } = {}
	local domainExceptional: { [string]: number } = {}
	local domainSum: { [string]: number } = {}
	local temperamentHas: { [string]: number } = {}
	local temperamentCount: { [string]: number } = {}
	local growth: { [string]: number } = {}
	local latentCount: { [string]: number } = {}
	local latentKinds: { [string]: number } = {}
	local latentDomainTargets: { [string]: number } = {}
	local capacitySum, topSum = 0, 0
	local mythicInSample = 0
	local castable = 0

	for _, p in profiles do
		increment(gift, p.giftTier)
		increment(rarityHidden, InnateProfile.getRarityTier(p, true))
		increment(rarityVisible, InnateProfile.getRarityTier(p, false))
		increment(manifestCount, tostring(#p.manifest))
		for i, d in p.manifest do
			increment(domainManifest, d)
			increment(domainSum, d, p.domains[d])
			if i == 1 then
				increment(domainTop, d)
				topSum += p.domains[d]
			end
			if p.domains[d] >= T.exceptionalThreshold then
				increment(domainExceptional, d)
			end
		end
		for _, t in p.temperaments do
			increment(temperamentHas, t)
		end
		increment(temperamentCount, tostring(#p.temperaments))
		increment(growth, p.growth)
		local hiddenCount = 0
		for _, l in p.latents do
			if l.kind == "Mythic" then
				mythicInSample += 1
			else
				hiddenCount += 1
				increment(latentKinds, l.kind)
				if l.kind == "Domain" then
					increment(latentDomainTargets, l.target)
				end
			end
		end
		increment(latentCount, tostring(hiddenCount))
		capacitySum += InnateProfile.traits(p).capacity

		-- Invariant: everyone can cast at least one spell from day one.
		local caster = InnateProfile.toCasterProfile(p, { mastery = {} })
		local templates = MagicCore.listAvailableRecipes(caster, { limit = 1 })
		if #templates > 0 then
			local t = templates[1]
			if MagicCore.computeStats({ branch = t.branch, property = t.property, verb = t.verb, form = t.form, power = 1 }, caster) then
				castable += 1
			end
		end
	end

	-- ─── Print ─────────────────────────────────────────────────────────────
	local giftTotal = 0
	for _, tier in T.giftTiers do
		giftTotal += tier.weight
	end
	print("Gift tier            observed   expected")
	for _, tier in T.giftTiers do
		print(string.format("  %-16s %s   %s", tier.id, pct(gift[tier.id] or 0, n), pct(tier.weight, giftTotal)))
	end

	print("Primary domains      observed   expected")
	for k = 1, 4 do
		local expected = 0
		for _, tier in T.giftTiers do
			local sum = 0
			for _, w in tier.domainCount do
				sum += w
			end
			expected += (tier.weight / giftTotal) * (tier.domainCount[k] / sum)
		end
		print(string.format("  %d domain(s)      %s   %s", k, pct(manifestCount[tostring(k)] or 0, n), pct(expected, 1)))
	end

	print("Domain        rarity     manifest   top-domain  exceptional  mean(manifest)  hidden-latent")
	for _, d in Registry.domainIds do
		local m = domainManifest[d] or 0
		print(string.format(
			"  %-10s %-9s %s    %s     %5d        %5.3f          %5d",
			d,
			Registry.domains[d].rarity,
			pct(m, n),
			pct(domainTop[d] or 0, n),
			domainExceptional[d] or 0,
			if m > 0 then (domainSum[d] or 0) / m else 0,
			latentDomainTargets[d] or 0
		))
	end
	print(string.format("  mean top affinity %.3f, mean capacity multiplier %.3f", topSum / n, capacitySum / n))

	print("Person rarity        true(hidden)  visible")
	for _, tier in { "Common", "Uncommon", "Rare", "Epic", "Legendary", "Mythic" } do
		print(string.format("  %-16s %s      %s", tier, pct(rarityHidden[tier] or 0, n), pct(rarityVisible[tier] or 0, n)))
	end

	print("Temperaments (share of people)")
	for _, entry in T.temperamentWeights do
		print(string.format("  %-12s %s", entry.id, pct(temperamentHas[entry.id] or 0, n)))
	end
	print(string.format("  count 0/1/2/3: %s %s %s %s",
		pct(temperamentCount["0"] or 0, n), pct(temperamentCount["1"] or 0, n), pct(temperamentCount["2"] or 0, n), pct(temperamentCount["3"] or 0, n)))

	print("Growth curves")
	for _, entry in T.growthWeights do
		print(string.format("  %-12s %s", entry.id, pct(growth[entry.id] or 0, n)))
	end

	print(string.format("Latents (non-mythic) count 0/1/2/3: %s %s %s %s",
		pct(latentCount["0"] or 0, n), pct(latentCount["1"] or 0, n), pct(latentCount["2"] or 0, n), pct(latentCount["3"] or 0, n)))
	for _, entry in T.latentKinds do
		print(string.format("  %-12s %d", entry.id, latentKinds[entry.id] or 0))
	end

	-- ─── Mythic: fast sampler (gift + mythic rolls only) ───────────────────
	local mythicStart = os.clock()
	local mythicCounts: { [string]: number } = {}
	local mythicTotal = 0
	for i = 1, samples do
		local _, mythic = ProfileGenerator.sampleRarity(seed, "sample:" .. i)
		if mythic then
			mythicTotal += 1
			increment(mythicCounts, mythic)
		end
		if i % 20000 == 0 then
			task.wait()
		end
	end
	local expectedOverall = 0
	for _, tier in T.giftTiers do
		expectedOverall += (tier.weight / giftTotal) * T.mythic.baseChance * tier.mythicMult
	end
	print(string.format("Mythic: %d in the %d-person sample; fast sampler %d/%d (1 in %s) in %.0f ms; expected 1 in %.0f",
		mythicInSample, n, mythicTotal, samples,
		if mythicTotal > 0 then string.format("%.0f", samples / mythicTotal) else "∞",
		(os.clock() - mythicStart) * 1000, 1 / expectedOverall))
	for _, entry in T.mythic.domains do
		print(string.format("  %-8s %d", entry.id, mythicCounts[entry.id] or 0))
	end

	-- ─── Checks ────────────────────────────────────────────────────────────
	print("Checks:")
	check("everyone can cast on day one", castable == n, string.format("%d/%d", castable, n))
	check("deterministic", deepEqual(ProfileGenerator.generate(seed, "npc:1"), profiles[1]))
	check("seed matters", not deepEqual(ProfileGenerator.generate(seed + 1, "npc:1"), profiles[1]))
	local restored = InnateProfile.deserialize(InnateProfile.serialize(profiles[1]))
	check("save round-trip", restored ~= nil and deepEqual(restored, profiles[1]))
	check("player floor", ProfileGenerator.generate(seed, "player:1", { kind = "Player" }).giftTier ~= "Faint")

	-- Awakening on a clone is deterministic, respects cooldowns and enforces its trigger.
	local nearDeathFacts = { healthFraction = 0.03, threatRatio = 2, secondsSurvived = 12 }
	local easy = InnateProfile.applyAwakening(InnateProfile.deserialize(InnateProfile.serialize(profiles[1])) :: InnateProfile,
		"nearDeath", { now = 0, facts = { healthFraction = 0.03, threatRatio = 1.0, secondsSurvived = 12 } })
	check("near-death needs a stronger foe", not easy.ok and easy.reason == "TRIGGER_NOT_MET")
	local noFacts = InnateProfile.applyAwakening(InnateProfile.deserialize(InnateProfile.serialize(profiles[1])) :: InnateProfile,
		"nearDeath", { now = 0 })
	check("near-death needs measured facts", not noFacts.ok and noFacts.reason == "TRIGGER_NOT_MET")

	local revealedCount = 0
	for i = 1, math.min(n, 1000) do
		local a = InnateProfile.deserialize(InnateProfile.serialize(profiles[i]))
		if a then
			local r = InnateProfile.applyAwakening(a, "nearDeath", { now = 0, facts = nearDeathFacts })
			revealedCount += #r.revealed
			if i == 1 then
				local again = InnateProfile.applyAwakening(a, "nearDeath", { now = 60, facts = nearDeathFacts })
				check("awakening cooldown", not again.ok and again.reason == "ON_COOLDOWN")
				local b = InnateProfile.deserialize(InnateProfile.serialize(profiles[i]))
				if b then
					InnateProfile.applyAwakening(b, "nearDeath", { now = 0, facts = nearDeathFacts })
					check("awakening deterministic", deepEqual(a.domains, b.domains) and deepEqual(a.temperaments, b.temperaments))
				end
			end
		end
	end
	print(string.format("  'Brush with Death' revealed a latent for %s of people", pct(revealedCount, math.min(n, 1000))))

	-- An authored mythic NPC: hidden until the right event, then castable.
	local seer = ProfileGenerator.generate(seed, "npc:the_seer", { forceGiftTier = "Paragon", forceMythic = "reality" })
	check("forced mythic is Mythic tier", InnateProfile.getRarityTier(seer, true) == "Mythic")
	check("mythic hidden from visible tier", InnateProfile.getRarityTier(seer, false) ~= "Mythic")
	local seerView = InnateProfile.getVisibleProfile(seer, 3)
	local leaked = false
	for _, entry in seerView.domains do
		leaked = leaked or entry.domain == "reality"
	end
	check("mythic not leaked at max knowledge", not leaked and #(seerView.latentHints or {}) == #seer.latents - 1)
	local wrongEvent = InnateProfile.applyAwakening(seer, "starfall", { now = 0 })
	check("wrong mythic event reveals nothing", wrongEvent.ok and #wrongEvent.revealed == 0)
	InnateProfile.applyAwakening(seer, "theSeam", { now = 0 })
	local seerCaster = InnateProfile.toCasterProfile(seer, { mastery = {} })
	check("reality awakened and castable", seerCaster.awakened.reality == true
		and #MagicCore.listAvailableRecipes(seerCaster, { branch = "reality", limit = 1 }) > 0)

	-- What one person knows about themselves at each knowledge level.
	local sample = profiles[1]
	print(string.format("Example %s: gift %s, true tier %s, signature #%s/#%s %s %s (%s, %+d st)",
		sample.entityId, sample.giftTier, InnateProfile.getRarityTier(sample, true),
		sample.signature.primary, sample.signature.accent, sample.signature.motion, sample.signature.particle,
		sample.signature.timbre, sample.signature.pitch))
	for level = 0, 3 do
		local v = InnateProfile.getVisibleProfile(sample, level)
		local parts = {}
		for _, entry in v.domains do
			local detail = {}
			if entry.band then
				table.insert(detail, entry.band)
			end
			if entry.value then
				table.insert(detail, tostring(entry.value))
			end
			table.insert(parts, entry.domain .. (if #detail > 0 then "(" .. table.concat(detail, " ") .. ")" else ""))
		end
		print(string.format("  level %d: %s%s%s%s", level, table.concat(parts, ", "),
			if v.temperaments and #v.temperaments > 0 then " | " .. table.concat(v.temperaments, ",") else "",
			if v.growth then " | growth " .. v.growth .. ", learns by " .. tostring(v.favoredLearning) .. ", " .. tostring(v.capacityBand) .. " reservoir" else "",
			if v.latentHints and #v.latentHints > 0 then " | senses depths: " .. table.concat(v.latentHints, ",") else ""))
	end

	print(string.format("════════ %d passed, %d failed ════════", passed, failed))
end
