--!strict
--[[
	TestMageService: Studio-only console shortcuts for trying magic at any level of power.

		testmage <tier 1-8> [domain ...|all]
		    Makes you a mage of that mastery tier (1 Sensing, 2 Novice, 3 Adept, 4 Skilled,
		    5 Expert, 6 Master, 7 Grandmaster, 8 Transcendent) in every branch of the listed
		    domains (default: all twelve). Awakens those domains (affinity at least 0.7), unlocks
		    their branches and hybrids, sets XP to just inside the tier, grants the breakthroughs
		    up to it, and refills the reservoir at its new size. Running it again with a LOWER tier
		    lowers you back down.
		testspells [maxPower] [domain]
		    Learns every example spell (Shared/Magic/Data/SpellExamples) up to maxPower (default 10)
		    that your current mastery can cast, optionally only one domain's, and puts up to 8 of
		    them on hotbar keys 1-8 in increasing power (the 8 strongest when more qualify).

	Both refuse outside Studio: they rewrite progression and the innate profile, and a live save
	would keep that. In Studio the mock DataStore forgets it when the session ends.
]]

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local Reservoir = require(Shared.Magic.Reservoir)
local MasteryTiers = require(Shared.Magic.Data.MasteryTiers)
local SpellExamples = require(Shared.Magic.Data.SpellExamples)
local Progression = require(script.Parent.Parent.Progression.Progression)

local HOTBAR_KEYS = 8
local TEST_AFFINITY = 0.7

local TestMageService = {
	name = "TestMageService",
	dependencies = { "NetService", "PlayerDataService", "ReservoirService", "AdminService" },
}

local playerData: any = nil
local reservoirs: any = nil

local function parseDomains(args: { string }, from: number): ({ string }?, string?)
	if not args[from] or args[from] == "all" then
		return table.clone(Registry.domainIds), nil
	end
	local list: { string } = {}
	for i = from, #args do
		local id = string.lower(args[i])
		if not Registry.domains[id] then
			return nil, "unknown domain '" .. id .. "' (domains: " .. table.concat(Registry.domainIds, ", ") .. ")"
		end
		table.insert(list, id)
	end
	return list, nil
end

-- Client: refresh progression, profile and spellbook views.
local function notifyClient(player: Player)
	local events: { { [string]: string } } = { { kind = "fact", fact = "test", id = "testmage" }, { kind = "spellbook" } }
	Net.fire("ProgressionChanged", player, events)
end

local function becomeMage(player: Player, tier: number, domains: { string }): string
	local state = playerData:get(player)
	if not state then
		return "your data isn't loaded yet"
	end
	local p = state.data.progression
	local innate = state.innate
	local def = MasteryTiers.tiers[tier + 1]
	local target = if tier >= 8 then 100 else math.min(100, def.minMastery + 2)
	local xp = Progression.xpForMastery(target)

	local inSet: { [string]: boolean } = {}
	for _, d in domains do
		inSet[d] = true
		if not table.find(innate.manifest, d) then
			table.insert(innate.manifest, d)
		end
		innate.domains[d] = math.max(innate.domains[d] or 0, TEST_AFFINITY)
	end

	local count = 0
	for _, id in Registry.branchIds do
		local branch = Registry.branches[id]
		local all = true
		for _, d in branch.domains do
			all = all and inSet[d] == true
		end
		if all then
			p.unlocked[id] = true
			p.xp[id] = xp
			local done = {}
			for _, t in MasteryTiers.tiers do
				if t.breakthrough and t.index <= tier then
					done[tostring(t.index)] = 0
				end
			end
			p.breakthroughs[id] = done
			p.mastery[id] = math.floor(math.min(Progression.masteryForXp(xp), (Progression.masteryCap(p, id))) * 100) / 100
			count += 1
		end
	end

	playerData:refreshCaster(player)
	local reservoir = reservoirs:get(player)
	if reservoir then
		Reservoir.refreshMax(reservoir, state.caster)
		reservoir.current, reservoir.strain, reservoir.burnoutUntil = reservoir.max, 0, 0
		table.clear(reservoir.lockouts)
		reservoirs:push(player)
	end
	notifyClient(player)
	return string.format(
		"You are now %s (mastery %d) in %d branches of %s. Tier power ceiling: %d (each branch's own max still applies). Reservoir %d.",
		def.name, target, count, table.concat(domains, ", "), def.powerCeiling, if reservoir then math.floor(reservoir.max) else 0
	)
end

local function learnExamples(player: Player, maxPower: number, domain: string?): string
	local state = playerData:get(player)
	if not state then
		return "your data isn't loaded yet"
	end
	local candidates = {}
	for _, e in SpellExamples do
		if e.recipe.power <= maxPower and (not domain or e.domain == domain) then
			table.insert(candidates, e)
		end
	end
	table.sort(candidates, function(a, b)
		if a.recipe.power ~= b.recipe.power then
			return a.recipe.power < b.recipe.power
		end
		if a.domain ~= b.domain then
			return a.domain < b.domain
		end
		return a.name < b.name
	end)

	local book = state.data.spellbook
	local learned: { { key: string, example: SpellExamples.Example } } = {}
	local skipped: { string } = {}
	for _, e in candidates do
		local ok, errors, normalized = MagicCore.validateRecipe(e.recipe, state.caster)
		if ok and normalized then
			local key = MagicCore.recipeKey(normalized)
			if not book[key] then
				book[key] = { recipe = normalized, name = e.name, favorite = false, casts = 0, addedAt = os.time() }
			end
			table.insert(learned, { key = key, example = e })
		else
			table.insert(skipped, string.format("%s (%s)", e.name, errors[1] and errors[1].code or "?"))
		end
	end

	-- Hotbar 1-8: increasing power; the strongest 8 when more qualify.
	local hotbar = state.data.hotbar
	for slot = 1, HOTBAR_KEYS do
		hotbar[tostring(slot)] = nil
	end
	local first = math.max(1, #learned - HOTBAR_KEYS + 1)
	local lines = { string.format("Learned %d spell(s). Hotbar:", #learned) }
	for i = first, #learned do
		local slot = i - first + 1
		local entry = learned[i]
		hotbar[tostring(slot)] = entry.key
		table.insert(lines, string.format("  [%d] %s  (%s, P%d) -> %s", slot, entry.example.name, entry.example.domain, entry.example.recipe.power, entry.example.effect))
	end
	if #learned > HOTBAR_KEYS then
		table.insert(lines, string.format("  ...and %d more in your spellbook (Composer / Grimoire, or filter by domain).", #learned - HOTBAR_KEYS))
	end
	if #skipped > 0 then
		table.insert(lines, "Not castable yet (raise testmage): " .. table.concat(skipped, ", "))
	end
	notifyClient(player)
	return table.concat(lines, "\n")
end

function TestMageService.init(_self: any, ctx: any)
	playerData = ctx.get("PlayerDataService")
	reservoirs = ctx.get("ReservoirService")
	local admin = ctx.get("AdminService")

	admin:Register({
		name = "testmage", category = "Magic", studioOnly = true,
		description = "(Studio) Become a mage of a mastery tier in every branch of some domains",
		args = {
			{ name = "tier", type = "integer", min = 1, max = 8, default = 6, slider = true, hint = "1 Sensing .. 8 Transcendent" },
			{ name = "domains", type = "text", default = "all", hint = "domain ids separated by spaces, or all" },
		},
		handler = function(ctx, a)
			local domains, err = parseDomains(string.split(a.domains, " "), 1)
			if not domains then
				return err or "bad domains"
			end
			return becomeMage(ctx.player, a.tier, domains)
		end,
	})

	admin:Register({
		name = "testspells", category = "Spells", studioOnly = true,
		description = "(Studio) Learn every example spell you can cast and fill hotbar 1-8",
		args = {
			{ name = "maxPower", type = "integer", min = 1, max = 10, default = 10, slider = true },
			{ name = "domain", type = "domain", optional = true },
		},
		handler = function(ctx, a)
			return learnExamples(ctx.player, a.maxPower, a.domain)
		end,
	})
end

return TestMageService
