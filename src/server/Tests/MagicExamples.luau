--!strict
--[[
	MagicExamples
	Unit-test style walkthrough of the spell grammar. Runs automatically in Studio only
	(see init.server.luau). Every spell below is built from the grammar; none is hand-authored.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Magic = ReplicatedStorage:WaitForChild("Shared"):WaitForChild("Magic")
local Types = require(Magic.Types)
local MagicCore = require(Magic.MagicCore)
local Reservoir = require(Magic.Reservoir)
local Seed = require(Magic.Seed)

type CasterProfile = Types.CasterProfile
type SpellStats = Types.SpellStats
type CastContext = Types.CastContext

local WORLD_SEED = 1337

local passed, failed = 0, 0

local function check(name: string, condition: boolean, detail: string?)
	if condition then
		passed += 1
	else
		failed += 1
		warn(string.format("  ✗ %s%s", name, if detail then " -> " .. detail else ""))
	end
end

local function errorCodes(errors: { Types.ValidationError }): string
	local codes = {}
	for _, e in errors do
		table.insert(codes, e.code .. " (" .. e.message .. ")")
	end
	return table.concat(codes, "; ")
end

local function formatStats(s: SpellStats): string
	return string.format(
		"power=%.2f cost=%.1f [res %.1f | amb %.1f | hp %.1f] range=%.1f area=%.1f dur=%.1fs cast=%.2fs cd=%.1fs instab=%.3f backfire=%.3f%s",
		s.power,
		s.cost,
		s.costBreakdown.reservoir,
		s.costBreakdown.ambient,
		s.costBreakdown.vitalHp,
		s.range,
		s.area,
		s.duration,
		s.castTime,
		s.cooldown,
		s.instability,
		s.backfireChance,
		if #s.warnings > 0 then " warn=" .. table.concat(s.warnings, ",") else ""
	)
end

local function expectSpell(label: string, recipe: any, caster: CasterProfile, context: CastContext?): SpellStats?
	local stats, errors = MagicCore.computeStats(recipe, caster, context)
	if stats then
		print(string.format("  ✓ %-16s %s\n      %s", label, MagicCore.describe(stats.recipe), formatStats(stats)))
		check(label, true)
	else
		check(label, false, errorCodes(errors))
	end
	return stats
end

local function expectError(label: string, recipe: any, caster: CasterProfile?, code: string)
	local ok, errors = MagicCore.validateRecipe(recipe, caster)
	local found = false
	for _, e in errors do
		if e.code == code then
			found = true
		end
	end
	check(label, not ok and found, string.format("expected %s, got %s", code, if ok then "valid" else errorCodes(errors)))
	if not ok and found then
		print(string.format("  ✓ %-28s rejected with %s", label, code))
	end
end

local function cloneProfile(p: CasterProfile): CasterProfile
	return {
		id = p.id,
		attunement = p.attunement,
		affinities = table.clone(p.affinities),
		awakened = table.clone(p.awakened),
		mastery = table.clone(p.mastery),
	}
end

-- ─── Test casters ───────────────────────────────────────────────────────────

local novice: CasterProfile = {
	id = "npc_novice",
	affinities = { energy = 0.3 },
	awakened = { energy = true },
	mastery = { energy = 5 },
}

local journeyman: CasterProfile = {
	id = "player_journeyman",
	affinities = { energy = 0.7, earth = 0.6, water = 0.5, air = 0.4, life = 0.55 },
	awakened = { energy = true, earth = true, water = true, air = true, life = true },
	mastery = {
		energy = 40, thermal = 45, electric = 50,
		earth = 50, geomancy = 55, metallurgy = 40, seismic = 35,
		water = 40, hydromancy = 50, tidal = 45,
		air = 35, aeromancy = 45,
		life = 30, restoration = 40,
		stormcalling = 30,
	},
}

local archmage: CasterProfile = {
	id = "npc_archmage",
	attunement = 95,
	affinities = { earth = 0.9 },
	awakened = { earth = true },
	mastery = { earth = 90, geomancy = 60, seismic = 80, faultwork = 85, cataclysm = 90 },
}

return function()
	print("──────── Magic grammar examples ────────")

	-- ─── 1-9: spells built from the grammar ─────────────────────────────────
	print("Spells:")

	-- 1. Candle-light: the smallest thing magic does. Raw Energy, power 1, by a novice.
	expectSpell("candle-light", {
		branch = "energy", property = "temperature", verb = "generate", form = "touch", power = 1,
	}, novice)

	-- 2. Heat transfer: pull warmth out of a forge-hot ingot into a freezing companion.
	expectSpell("heat transfer", {
		branch = "calefaction", property = "temperature", verb = "transfer", form = "touch", power = 3,
	}, (function()
		local p = cloneProfile(journeyman)
		p.mastery.calefaction = 30
		return p
	end)())

	-- 3. Stone wall: raise the terrain contour as a Wall.
	local wall4 = expectSpell("stone wall", {
		branch = "geomancy", property = "contour", verb = "generate", form = "wall", power = 4,
	}, journeyman)

	-- 4. Iron-skin: Amplify your own hardness by touch; Lingering keeps it up.
	expectSpell("iron-skin", {
		branch = "metallurgy", property = "hardness", verb = "amplify", form = "touch", power = 4,
		modifiers = { "lingering" },
	}, journeyman)

	-- 5. Small tremor: Generate seismicity as a Burst around the caster.
	expectSpell("small tremor", {
		branch = "seismic", property = "seismicity", verb = "generate", form = "burst", power = 3,
	}, journeyman)

	-- 6. Wave surge: Redirect existing water (requirement=Source) as a moving Wall. Reckless = big & wild.
	expectSpell("wave surge", {
		branch = "tidal", property = "flow", verb = "redirect", form = "wall", power = 5,
		modifiers = { "reckless" },
	}, journeyman)

	-- 7. Healing touch: Amplify vitality, Efficient for a cheap, steady heal.
	expectSpell("healing touch", {
		branch = "restoration", property = "vitality", verb = "amplify", form = "touch", power = 3,
		modifiers = { "efficient" },
	}, journeyman)

	-- 8. Hybrid: chain lightning from Stormcalling (Energy.Electromancy + Air.Aeromancy).
	--    Power 5 is above this caster's comfort (~4.65), so it carries an OVERREACH warning.
	expectSpell("chain lightning", {
		branch = "stormcalling", property = "charge", verb = "generate", form = "chain", power = 5,
		modifiers = { "piercing" },
	}, journeyman)

	-- 9. World-altering: an archmage's earthquake. Ritual + Cataclysm + Ambient draw at a ley nexus.
	local quake = expectSpell("earthquake", {
		branch = "cataclysm", property = "seismicity", verb = "generate", form = "ritual", power = 10,
		modifiers = { "efficient" }, costProfile = "ambient",
	}, archmage, { ambientDensity = 3 })

	-- ─── Rejections ────────────────────────────────────────────────────────
	print("Rejections:")
	expectError("novice can't raise walls", {
		branch = "geomancy", property = "contour", verb = "generate", form = "wall", power = 1,
	}, novice, "BRANCH_LOCKED")
	expectError("journeyman ritual quake", {
		branch = "seismic", property = "seismicity", verb = "generate", form = "ritual", power = 10,
	}, journeyman, "FORM_TIER")
	expectError("sense as projectile", {
		branch = "energy", property = "luminosity", verb = "sense", form = "projectile", power = 1,
	}, nil, "FORM_VERB_INCOMPATIBLE")
	-- Generate can't make Spatial magic; `distance` (Shear, Space's strike) is the one exception
	-- (Compatibility.propertyVerb), so check a property without one.
	expectError("generate position", {
		branch = "translocation", property = "position", verb = "generate", form = "touch", power = 1,
	}, nil, "VERB_PROPERTY_INCOMPATIBLE")
	expectError("efficient + reckless", {
		branch = "energy", property = "temperature", verb = "generate", form = "touch", power = 1,
		modifiers = { "efficient", "reckless" },
	}, nil, "MODIFIER_CONFLICT")
	expectError("homing wall", {
		branch = "geomancy", property = "contour", verb = "generate", form = "wall", power = 1,
		modifiers = { "homing" },
	}, nil, "MODIFIER_FORM")
	expectError("heat from geomancy", {
		branch = "geomancy", property = "temperature", verb = "generate", form = "touch", power = 1,
	}, nil, "PROPERTY_NOT_IN_BRANCH")
	expectError("mythic not awakened", {
		branch = "chronokinesis", property = "tempo", verb = "reduce", form = "touch", power = 1,
	}, journeyman, "BRANCH_LOCKED")
	expectError("lightning over cap", {
		branch = "stormcalling", property = "charge", verb = "generate", form = "chain", power = 7,
	}, journeyman, "POWER_OVER_CAP")
	expectError("exploit: string power", {
		branch = "energy", property = "temperature", verb = "generate", form = "touch", power = "9000",
	}, nil, "BAD_POWER")
	expectError("exploit: NaN power", {
		branch = "energy", property = "temperature", verb = "generate", form = "touch", power = 0 / 0,
	}, nil, "BAD_POWER")
	expectError("exploit: hash modifiers", {
		branch = "energy", property = "temperature", verb = "generate", form = "touch", power = 1,
		modifiers = { efficient = true },
	}, nil, "BAD_TYPE")
	expectError("exploit: duplicate mods", {
		branch = "energy", property = "temperature", verb = "generate", form = "touch", power = 1,
		modifiers = { "efficient", "efficient" },
	}, nil, "DUPLICATE_MODIFIER")
	expectError("exploit: not a table", "fireball", nil, "BAD_TYPE")

	-- ─── Model properties ──────────────────────────────────────────────────
	print("Model properties:")
	local wallRecipe = { branch = "geomancy", property = "contour", verb = "generate", form = "wall", power = 3 }
	local wall3 = MagicCore.computeStats(wallRecipe, journeyman)
	local wall3b = MagicCore.computeStats(wallRecipe, journeyman)
	check("deterministic", wall3 ~= nil and wall3b ~= nil and wall3.key == wall3b.key and wall3.cost == wall3b.cost and wall3.power == wall3b.power)
	check("power raises cost", wall3 ~= nil and wall4 ~= nil and wall4.cost > wall3.cost and wall4.power > wall3.power)

	local master = cloneProfile(journeyman)
	master.mastery.geomancy = 90
	local wallMaster = MagicCore.computeStats(wallRecipe, master)
	check("mastery lowers cost", wall3 ~= nil and wallMaster ~= nil and wallMaster.cost < wall3.cost and wallMaster.instability < wall3.instability)

	local orderA = MagicCore.computeStats({ branch = "metallurgy", property = "hardness", verb = "amplify", form = "touch", power = 2, modifiers = { "lingering", "efficient" } }, journeyman)
	local orderB = MagicCore.computeStats({ branch = "metallurgy", property = "hardness", verb = "amplify", form = "touch", power = 2, modifiers = { "efficient", "lingering" } }, journeyman)
	check("modifier order canonical", orderA ~= nil and orderB ~= nil and orderA.key == orderB.key)

	local thin = MagicCore.computeStats(wallRecipe, journeyman, { ambientDensity = 0.2 })
	check("dead zones cost more", thin ~= nil and wall3 ~= nil and thin.cost > wall3.cost)

	-- Every template the discovery API offers must actually validate.
	local templates = MagicCore.listAvailableRecipes(journeyman)
	local invalid = 0
	for _, t in templates do
		local ok = MagicCore.validateRecipe({ branch = t.branch, property = t.property, verb = t.verb, form = t.form, power = 1 }, journeyman)
		if not ok then
			invalid += 1
		end
	end
	check("templates all valid", #templates > 0 and invalid == 0, string.format("%d/%d invalid", invalid, #templates))
	print(string.format("  journeyman can build %d base templates; novice can build %d", #templates, #MagicCore.listAvailableRecipes(novice)))

	-- ─── Reservoir & overdraw ──────────────────────────────────────────────
	print("Reservoir:")
	local state = Reservoir.newState(journeyman)
	print(string.format("  journeyman reservoir %.0f, regen %.2f/s normal, %.2f/s resting at a nexus", state.max, Reservoir.regenPerSecond(state, "Normal", 1, 0), Reservoir.regenPerSecond(state, "Resting", 3, 0)))
	local lightning = MagicCore.computeStats({ branch = "stormcalling", property = "charge", verb = "generate", form = "chain", power = 5, modifiers = { "piercing" } }, journeyman)
	if lightning then
		local now = 0
		for cast = 1, 20 do
			local rng = Seed.random(WORLD_SEED, journeyman.id, "overdraw", cast)
			local result = Reservoir.trySpend(state, lightning, now, rng)
			if not result.ok then
				print(string.format("  cast %d refused: %s (reservoir %.1f)", cast, tostring(result.reason), state.current))
				check("overdraw eventually refused", result.reason == "INSUFFICIENT_RESERVOIR" or result.reason == "BURNED_OUT")
				break
			end
			local kinds = {}
			for _, c in result.consequences do
				table.insert(kinds, string.format("%s[%s %.1f/%.0fs]", c.kind, c.riskId, c.amount, c.duration))
			end
			print(string.format("  cast %d ok: reservoir %.1f%s", cast, state.current, if #kinds > 0 then "  -> " .. table.concat(kinds, " ") else ""))
			now += lightning.cooldown
		end
	end

	if quake then
		local archState = Reservoir.newState(archmage)
		local result = Reservoir.trySpend(archState, quake, 0, Seed.random(WORLD_SEED, archmage.id, "overdraw", 1))
		print(string.format("  archmage reservoir %.0f; earthquake needs %.0f from reservoir (+%.0f ambient): %s, now %.1f",
			archState.max, quake.costBreakdown.reservoir, quake.costBreakdown.ambient, if result.ok then "cast" else tostring(result.reason), archState.current))
		check("archmage can quake at a nexus", result.ok)
	end

	-- Seeds are stable across runs and servers.
	check("seed stable", Seed.derive(WORLD_SEED, "npc_42", "affinity") == Seed.derive(WORLD_SEED, "npc_42", "affinity"))
	check("seed varies", Seed.derive(WORLD_SEED, "npc_42", "affinity") ~= Seed.derive(WORLD_SEED, "npc_43", "affinity"))

	print(string.format("──────── %d passed, %d failed ────────", passed, failed))
end
