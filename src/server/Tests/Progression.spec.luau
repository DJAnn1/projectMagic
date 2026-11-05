--!strict
-- Unit specs for progression: curve, holds and breakthroughs, anti-grind, focus/breadth,
-- unlock rules, specializations, techniques, environment and the v2 -> v3 migration.

local ServerScriptService = game:GetService("ServerScriptService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local Specialization = require(Shared.Magic.Specialization)
local Server = ServerScriptService.Server
local Progression = require(Server.Progression.Progression)
local T = require(Server.Progression.ProgressionTuning)
local Schemas = require(Server.Persistence.Schemas)
local ProfileGenerator = require(Server.Magic.ProfileGenerator)

local NOW = 1_800_000_000

local function freshPlayer(): (any, any)
	local innate = ProfileGenerator.generate(1337, "spec:progression", { forceGiftTier = "Gifted" })
	innate.manifest = { "energy", "earth", "water" }
	innate.domains.energy, innate.domains.earth, innate.domains.water = 0.6, 0.6, 0.6
	innate.growth = "steady"
	for style in innate.learning do
		innate.learning[style] = 1
	end
	for branchId in innate.leanings do
		innate.leanings[branchId] = 1
	end
	local p = Schemas.Player.template().progression
	Progression.ensureRoots(p, innate)
	return p, innate
end

local function setMastery(p: any, branchId: string, mastery: number)
	p.unlocked[branchId] = true
	p.xp[branchId] = Progression.xpForMastery(mastery)
	Progression.recompute(p, branchId)
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("XP curve", function()
		it("inverts cleanly", function()
			for _, m in { 1, 10, 25, 55, 85, 100 } do
				expect(Progression.masteryForXp(Progression.xpForMastery(m))).toBeNear(m, 1e-6)
			end
		end)
		it("matches the documented Grandmaster threshold (~200k XP)", function()
			expect(Progression.xpForMastery(85)).toBeNear(199960, 2000)
		end)
	end)

	describe("Unlocking roots", function()
		it("opens every manifest domain at Sensing", function()
			local p = freshPlayer()
			expect(p.unlocked.energy).toBe(true)
			expect((Progression.getMasteryTier(p, "energy"))).toBe(1)
			expect(p.unlocked.space).toBe(nil)
		end)
	end)

	describe("Experience", function()
		it("trickles 40% of a sub-branch's gain to its parent", function()
			local p, innate = freshPlayer()
			setMastery(p, "thermal", 5)
			local result = Progression.addExperience(p, innate, "thermal", "study", 100, { now = NOW })
			expect(result.gained > 0).toBe(true)
			expect(result.trickle.energy).toBeNear(result.gained * 0.4, 0.01)
		end)
		it("refuses locked branches", function()
			local p, innate = freshPlayer()
			expect(Progression.addExperience(p, innate, "pyromancy", "study", 100, { now = NOW }).reason).toBe("LOCKED")
		end)
		it("gives a fully focused player the maximum focus bonus", function()
			local p, innate = freshPlayer()
			local result = Progression.addExperience(p, innate, "energy", "study", 10, { now = NOW })
			expect(result.factors.focus).toBeNear(1 + T.focus.maxBonus, 1e-6)
		end)
		it("charges a breadth penalty beyond the free lines", function()
			local p = freshPlayer()
			for _, line in { "thermal", "luminous", "kinetic", "geomancy", "hydromancy" } do
				setMastery(p, line, 30)
			end
			expect(Progression.activeLines(p)).toBe(5)
			expect(Progression.breadthMultiplier(p)).toBeNear(1 - 2 * T.breadth.penaltyPerLine, 1e-6)
		end)
		it("enforces daily caps", function()
			local p, innate = freshPlayer()
			local first = Progression.addExperience(p, innate, "energy", "experimentation", 100000, { now = NOW })
			local second = Progression.addExperience(p, innate, "energy", "experimentation", 1000, { now = NOW + 60 })
			expect(first.gained).toBeNear(T.channels.experimentation.dailyCap :: number, 0.01)
			expect(second.gained).toBe(0)
		end)
	end)

	describe("Practice anti-grind", function()
		it("gives nothing while AFK", function()
			local p, innate = freshPlayer()
			local runtime = Progression.newRuntime(NOW - 1000)
			local result = Progression.addExperience(p, innate, "energy", "practice", 10, { now = NOW, runtime = runtime, recipeKey = "a" })
			expect(result.gained).toBe(0)
		end)
		it("decays repeated identical casts", function()
			local p, innate = freshPlayer()
			local runtime = Progression.newRuntime(NOW)
			local last = 1
			local rng = Random.new(1)
			local now = NOW
			for _ = 1, 30 do
				now += 3 + rng:NextNumber() * 4
				runtime.lastActiveAt = now
				local result = Progression.addExperience(p, innate, "energy", "practice", 10, { now = now, runtime = runtime, recipeKey = "same" })
				last = result.factors.repetition
			end
			expect(last < 0.15).toBe(true)
		end)
		it("halves XP for machine-regular timing", function()
			local p, innate = freshPlayer()
			local runtime = Progression.newRuntime(NOW)
			local result: any = nil
			for i = 1, T.practice.metronomeCasts do
				runtime.lastActiveAt = NOW + i * 2
				result = Progression.addExperience(p, innate, "energy", "practice", 10, { now = NOW + i * 2, runtime = runtime, recipeKey = "k" .. i })
			end
			expect(result.factors.metronome).toBe(T.practice.metronomePenalty)
		end)
	end)

	describe("Breakthroughs", function()
		it("holds mastery below Expert until the breakthrough is done, then releases banked XP", function()
			local p = freshPlayer()
			p.xp.energy = Progression.xpForMastery(60)
			Progression.recompute(p, "energy")
			expect(p.mastery.energy).toBeNear(54.99, 1e-6)
			local ok, reason = Progression.tryBreakthrough(p, "energy", NOW)
			expect(ok).toBe(false)
			expect(reason).toBe("REQUIREMENTS_UNMET")
			Progression.record(p, "discovery", "energy", nil, NOW)
			Progression.record(p, "discovery", "energy", nil, NOW)
			Progression.record(p, "feat", "energy", 5, NOW)
			expect((Progression.tryBreakthrough(p, "energy", NOW))).toBe(true)
			expect(p.mastery.energy).toBeNear(60, 0.01)
		end)
		it("uses the Earth-specific Master requirements", function()
			local p = freshPlayer()
			p.breakthroughs.earth = { ["5"] = NOW }
			p.xp.earth = Progression.xpForMastery(72)
			Progression.recompute(p, "earth")
			local tier, list = Progression.breakthroughStatus(p, "earth")
			expect(tier).toBe(6)
			expect(list[1].text).toBe("Study a real fault zone.")
		end)
	end)

	describe("SubBranchRules: Metallurgy", function()
		it("needs Adept Geomancy, affinity, lore and both catalysts", function()
			local p, innate = freshPlayer()
			setMastery(p, "geomancy", 30)
			local ok = Progression.canUnlock(p, innate, "metallurgy")
			expect(ok).toBe(false)
			Progression.record(p, "lore", "tome:iron_and_flame", nil, NOW)
			Progression.record(p, "catalyst", "ore", nil, NOW)
			expect((Progression.canUnlock(p, innate, "metallurgy"))).toBe(false) -- heat still missing
			Progression.record(p, "catalyst", "heat", nil, NOW)
			expect((Progression.unlock(p, innate, "metallurgy", NOW))).toBe(true)
			expect((Progression.getMasteryTier(p, "metallurgy"))).toBe(1)
		end)
	end)

	describe("Specializations", function()
		it("boosts a subtree and weakens the opposing one", function()
			local mods = Specialization.branchMods({ pyre_oath = NOW })
			expect(mods.pyromancy.power).toBeNear(1.2, 1e-6)
			expect(mods.conflagration.power).toBeNear(1.2, 1e-6)
			expect(mods.cryothermy.power).toBeNear(0.8, 1e-6)
			expect(mods.thermal).toBe(nil)
		end)
		it("refuses opposing oaths", function()
			expect(Specialization.conflicts({ pyre_oath = NOW }, "frost_vow")).toBe("OPPOSES_PYRE_OATH")
			expect(Specialization.conflicts({ pyre_oath = NOW }, "forgeheart")).toBe(nil)
		end)
	end)

	describe("Technique ladders", function()
		for id, technique in Registry.techniques do
			it(id .. " is castable at " .. MagicCore.tierDef(technique.tier).name, function()
				local unlocked: { [string]: boolean } = {}
				local node: any = Registry.branches[technique.recipe.branch]
				while node do
					unlocked[node.id] = true
					node = if node.parent then Registry.branches[node.parent] else nil
				end
				local caster = {
					id = "spec",
					affinities = { [technique.domain] = 0.7 },
					awakened = { [technique.domain] = true },
					mastery = { [technique.recipe.branch] = MagicCore.tierDef(technique.tier).minMastery },
					unlocked = unlocked,
				}
				local ok, errors = MagicCore.validateRecipe(technique.recipe, caster :: any)
				local codes = {}
				for _, e in errors do
					table.insert(codes, e.code)
				end
				expect(table.concat(codes, ",")).toBe("")
				expect(ok).toBe(true)
			end)
		end
	end)

	describe("Environment", function()
		local caster = {
			id = "spec",
			affinities = { water = 0.8 },
			awakened = { water = true },
			mastery = { tsunamancy = 90 },
			unlocked = { water = true, hydromancy = true, tidal = true, tsunamancy = true },
		}
		local recipe = Registry.techniques.tsunami.recipe
		it("blocks a tsunami without an ocean", function()
			local stats = MagicCore.computeStats(recipe, caster :: any, { ambientDensity = 3, environment = { waterVolume = 50 } })
			expect(stats and stats.blockedBy).toBe("great_wave")
		end)
		it("allows it, slightly stronger, at sea", function()
			local stats = MagicCore.computeStats(recipe, caster :: any, { ambientDensity = 3, environment = { waterVolume = 5e6 } })
			expect(stats ~= nil and stats.blockedBy == nil and stats.environmentFactor >= 1).toBe(true)
		end)
	end)

	describe("Mastery gates in MagicCore", function()
		it("needs Adept for Transfer", function()
			local caster = { id = "spec", affinities = { energy = 0.5 }, awakened = { energy = true }, mastery = { energy = 30, thermal = 12 } }
			local ok, errors = MagicCore.validateRecipe({ branch = "thermal", property = "temperature", verb = "transfer", form = "touch", power = 2 }, caster :: any)
			expect(ok).toBe(false)
			expect(errors[1].code).toBe("VERB_MASTERY")
		end)
	end)

	describe("Player schema migration v2 -> v3", function()
		it("converts mastery to XP and grandfathers passed breakthroughs", function()
			local migrated = Schemas.Player.migrations[2]({
				profile = { manifest = { "energy" } },
				progression = { mastery = { thermal = 60 } },
			})
			local p = migrated.progression
			expect(p.xp.thermal).toBeNear(Progression.xpForMastery(60), 0.01)
			expect(p.unlocked.thermal).toBe(true)
			expect(p.unlocked.energy).toBe(true)
			expect(p.breakthroughs.thermal["5"]).toBe(0)
			expect(p.breakthroughs.thermal["6"]).toBe(nil)
		end)
	end)
end
