--!strict
--[[
	JourneySim: simulates 30 hours of play for three player types through the REAL progression
	code (Progression, MagicCore, Reservoir), and prints where each stands over time.

		require(game.ServerScriptService.Server.Tests.JourneySim)(30)

	Activity model per simulated hour (deliberately simple, tune it as real data arrives):
	- practice: as many casts as the reservoir's regeneration pays for (max 180), cycling through
	  up to 12 recipes in the chosen branch at a comfortable power, every cast effective;
	- study: one book per hour, plus a mentor lesson (two tiers above) every 4 hours;
	- unlocks: knowledge and catalysts for the next branch on the path are found once its
	  parent is ready; breakthrough requirements are completed 2 hours after XP first banks.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local Reservoir = require(Shared.Magic.Reservoir)
local Server = ServerScriptService.Server
local Progression = require(Server.Progression.Progression)
local SubBranchRules = require(Server.Progression.SubBranchRules)
local Breakthroughs = require(Server.Progression.Breakthroughs)
local T = require(Server.Progression.ProgressionTuning)
local Schemas = require(Server.Persistence.Schemas)
local ProfileGenerator = require(Server.Magic.ProfileGenerator)
local InnateProfile = require(Server.Magic.InnateProfile)

type Archetype = {
	name: string,
	manifest: { [string]: number },
	path: { string },
	mode: string, -- "deepest" | "rotate"
	mythic: { hour: number, domain: string, affinity: number, path: { string } }?,
}

local ARCHETYPES: { Archetype } = {
	{
		name = "Fire-focused",
		manifest = { energy = 0.7 },
		path = { "energy", "thermal", "pyromancy", "conflagration" },
		mode = "deepest",
	},
	{
		name = "Generalist",
		manifest = { energy = 0.45, earth = 0.45, water = 0.45, air = 0.45 },
		path = { "energy", "thermal", "luminous", "earth", "geomancy", "water", "hydromancy", "air", "aeromancy", "sonics" },
		mode = "rotate",
	},
	{
		name = "Mythic gravity",
		manifest = { earth = 0.4 },
		path = { "earth", "geomancy" },
		mode = "deepest",
		mythic = { hour = 6, domain = "gravity", affinity = 0.6, path = { "gravity", "weightcraft", "attraction", "orbitcraft", "collapse" } },
	},
}

local SNAPSHOTS = { 1, 3, 5, 10, 15, 20, 25, 30 }

local function grantUnlockConditions(p: any, innate: any, branchId: string, now: number)
	local condition = SubBranchRules.conditionFor(branchId)
	local function grantSet(set: any, isCatalyst: boolean)
		if not set then
			return
		end
		for _, list in { set.anyOf or {}, set.allOf or {} } do
			for _, id in list do
				if not isCatalyst then
					Progression.record(p, "lore", id, nil, now)
				else
					local prefix, rest = string.match(id, "^(%a+):(.+)$")
					if prefix == "exposure" then
						Progression.record(p, "catalyst", rest :: string, nil, now)
					elseif prefix == "insight" then
						Progression.record(p, "insight", rest :: string, nil, now)
					elseif prefix == "awakening" then
						innate.awakenings[rest :: string] = { count = 1, lastAt = now }
					end
				end
			end
		end
	end
	grantSet(condition.lore, false)
	grantSet(condition.catalyst, true)
end

local function grantBreakthrough(p: any, branchId: string, tierIndex: number, now: number)
	local def = Breakthroughs[tierIndex]
	local domain = Registry.branches[branchId].domains[1]
	local r = p.records
	for i, req in def.domains[domain] or def.default do
		if req.type == "insight" then
			Progression.record(p, "insight", req.id or (domain .. ":sim_site_" .. tierIndex .. "_" .. i), nil, now)
			for k = 1, (req.count or 1) do
				Progression.record(p, "insight", domain .. ":sim_site_" .. tierIndex .. "_" .. i .. "_" .. k, nil, now)
			end
		elseif req.type == "teach" then
			r.taught[branchId] = math.max(r.taught[branchId] or 0, req.count or 1)
		elseif req.type == "survive" and req.id then
			Progression.record(p, "survived", req.id, nil, now)
		elseif req.type == "discoveries" then
			r.discoveries[branchId] = math.max(r.discoveries[branchId] or 0, req.count or 1)
		elseif req.type == "feat" then
			Progression.record(p, if req.challenge then "challengeFeat" else "feat", branchId, req.minPower, now)
		elseif req.type == "paradigm" then
			r.paradigms = math.max(r.paradigms or 0, req.count or 1)
		elseif req.type == "mentor" then
			Progression.record(p, "mentor", branchId, req.tier, now)
		end
	end
end

local function simulate(arch: Archetype, hours: number)
	local rng = Random.new(42)
	local innate = ProfileGenerator.generate(1337, "sim:" .. arch.name, { forceGiftTier = "Gifted" })
	innate.manifest = {}
	for d, a in arch.manifest do
		table.insert(innate.manifest, d)
		innate.domains[d] = a
	end
	innate.growth = "steady"
	innate.temperaments = {}
	for style in innate.learning do
		innate.learning[style] = 1
	end
	for branchId in innate.leanings do
		innate.leanings[branchId] = 1
	end

	local p = Schemas.Player.template().progression
	Progression.ensureRoots(p, innate)
	local path = table.clone(arch.path)
	local now = 1_800_000_000
	local runtime = Progression.newRuntime(now)
	local heldSince: { [string]: number } = {}
	local totalGained = 0
	local snapshotIndex = 1

	print(string.format("── %s ──", arch.name))
	for hour = 1, hours do
		local mythic = arch.mythic
		if mythic and hour == mythic.hour then
			table.insert(innate.manifest, mythic.domain)
			innate.domains[mythic.domain] = mythic.affinity
			Progression.ensureRoots(p, innate)
			path = table.clone(mythic.path)
			print(string.format("  hour %d: %s awakens (Starfall); focus shifts", hour, Registry.domains[mythic.domain].name))
		end

		-- Unlock whatever on the path is ready.
		for _, branchId in path do
			if not p.unlocked[branchId] then
				grantUnlockConditions(p, innate, branchId, now)
				Progression.unlock(p, innate, branchId, now)
			end
		end

		-- Pick the branch to practise this hour.
		local open = {}
		for _, branchId in path do
			if p.unlocked[branchId] then
				table.insert(open, branchId)
			end
		end
		local target = if arch.mode == "rotate" then open[(hour - 1) % #open + 1] else open[#open]

		local caster = InnateProfile.toCasterProfile(innate, p)
		local mastery = p.mastery[target] or 0
		local power = math.max(1, math.min(MagicCore.powerCap(caster, target), math.floor(MagicCore.comfortPower(mastery))))
		local recipes = {}
		for _, template in MagicCore.listAvailableRecipes(caster, { branch = target, limit = 60 }) do
			local stats = MagicCore.computeStats({
				branch = template.branch, property = template.property, verb = template.verb, form = template.form,
				power = math.min(power, template.maxPower),
			}, caster)
			if stats and not stats.blockedBy then
				table.insert(recipes, stats)
				if #recipes >= 12 then
					break
				end
			end
		end

		if #recipes > 0 then
			local avgCost = 0
			for _, stats in recipes do
				avgCost += stats.cost
			end
			avgCost /= #recipes
			local state = Reservoir.newState(caster)
			local manaPerHour = Reservoir.regenPerSecond(state, "Normal", 1, 0) * 3600
			local casts = math.clamp(math.floor(manaPerHour / math.max(avgCost, 1)), 1, 180)
			local step = 3600 / casts
			for c = 1, casts do
				now += step * (0.6 + 0.8 * rng:NextNumber())
				runtime.lastActiveAt = now
				local stats = recipes[(c - 1) % #recipes + 1]
				local result = Progression.addExperience(p, innate, target, "practice", Progression.practiceXp(stats.cost), {
					now = now, runtime = runtime, recipeKey = stats.key, power = stats.recipe.power, comfort = stats.comfortPower, effective = true,
				})
				Progression.record(p, "feat", target, stats.recipe.power, now)
				totalGained += result.gained
			end
		else
			now += 3600
		end

		-- Study.
		totalGained += Progression.addExperience(p, innate, target, "study", T.study.book.xp, { now = now }).gained
		if hour % 4 == 0 then
			local tier = Progression.getMasteryTier(p, target)
			totalGained += Progression.addExperience(p, innate, target, "study", T.study.mentor.xp * 2, { now = now }).gained
			Progression.record(p, "mentor", target, tier + 2, now)
		end

		-- Breakthroughs complete 2 hours after XP starts banking behind them.
		for _, branchId in open do
			if Progression.masteryForXp(p.xp[branchId] or 0) > (p.mastery[branchId] or 0) + 0.01 then
				heldSince[branchId] = heldSince[branchId] or hour
				if hour - heldSince[branchId] >= 2 then
					local tierIndex = Progression.breakthroughStatus(p, branchId)
					if tierIndex then
						grantBreakthrough(p, branchId, tierIndex, now)
						if Progression.tryBreakthrough(p, branchId, now) then
							heldSince[branchId] = nil
						end
					end
				end
			else
				heldSince[branchId] = nil
			end
		end

		if hour == SNAPSHOTS[snapshotIndex] then
			snapshotIndex += 1
			local list = {}
			for branchId, m in p.mastery do
				table.insert(list, { id = branchId, m = m })
			end
			table.sort(list, function(a, b)
				return a.m > b.m
			end)
			local parts = {}
			for i = 1, math.min(4, #list) do
				local tier = Progression.getMasteryTier(p, list[i].id)
				table.insert(parts, string.format("%s %s %.1f", Registry.branches[list[i].id].name, MagicCore.tierDef(tier).name, list[i].m))
			end
			print(string.format("  hour %2d | %s | lines %d, breadth x%.2f | %.0f XP/h avg",
				hour, table.concat(parts, ", "), Progression.activeLines(p), Progression.breadthMultiplier(p), totalGained / hour))
		end
	end
end

return function(hours: number?)
	print("════════ Player journey simulation ════════")
	for _, arch in ARCHETYPES do
		simulate(arch, hours or 30)
	end
	print("════════ end of simulation ════════")
end
