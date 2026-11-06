--!strict
--[[
	MagicCore
	Pure, deterministic functions over the spell grammar: no Instances, no randomness, no
	yields. The same module runs on the server (authoritative) and on the client (UI previews).

	SECURITY: the server must re-run validateRecipe/computeStats on every cast intent, using
	its OWN copy of the caster profile. Never accept stats, costs or profiles from a client.
	Use only the normalized recipe returned by validateRecipe; discard the raw client table.

	Public API
		normalizeRecipe(raw)                       -> Recipe?, {ValidationError}
		validateRecipe(raw, caster?)               -> boolean, {ValidationError}, Recipe?
		computeStats(raw, caster, context?)        -> SpellStats?, {ValidationError}
		listAvailableRecipes(caster, filter?)      -> {RecipeTemplate}
		isBranchUnlocked(caster, branchId)         -> boolean
		comfortPower(mastery) / powerCap(caster, branchId) / modifierSlots(mastery, formId)
		recipeKey(recipe) / describe(recipe)
]]

local Types = require(script.Parent.Types)
local Registry = require(script.Parent.Registry)
local Strike = require(script.Parent.Strike)

local Tuning = Registry.Tuning

type Recipe = Types.Recipe
type CasterProfile = Types.CasterProfile
type CastContext = Types.CastContext
type ValidationError = Types.ValidationError
type SpellStats = Types.SpellStats
type RecipeTemplate = Types.RecipeTemplate
type TemplateFilter = Types.TemplateFilter
type BranchDef = Types.BranchDef

local MagicCore = {}

-- Recipe schema migrations: MIGRATIONS[n] upgrades a version-n recipe table to version n+1.
-- Never edit a shipped entry. Append a new one and bump Tuning.RECIPE_VERSION.
local MIGRATIONS: { [number]: (any) -> any } = {}

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function addError(errors: { ValidationError }, code: string, message: string)
	table.insert(errors, { code = code, message = message })
end

local function isId(value: any): boolean
	return typeof(value) == "string" and #value > 0 and #value <= Tuning.MAX_ID_LENGTH
end

-- True for a dense array with only integer keys and at most maxLen entries.
local function isArray(value: any, maxLen: number): boolean
	if typeof(value) ~= "table" then
		return false
	end
	local count = 0
	for key in value do
		if typeof(key) ~= "number" then
			return false
		end
		count += 1
		if count > maxLen then
			return false
		end
	end
	for i = 1, count do
		if value[i] == nil then
			return false
		end
	end
	return true
end

local function round(x: number, places: number): number
	local m = 10 ^ places
	return math.floor(x * m + 0.5) / m
end

local function masteryOf(caster: CasterProfile, branchId: string): number
	local value = caster.mastery[branchId]
	if typeof(value) ~= "number" or value ~= value then
		return 0
	end
	return math.clamp(value, 0, 100)
end

local function affinityFor(caster: CasterProfile, branch: BranchDef): number
	-- Hybrids use the geometric mean: one weak domain drags the whole hybrid down.
	local product = 1
	for _, d in branch.domains do
		local a = caster.affinities[d]
		product *= if typeof(a) == "number" and a == a then math.clamp(a, 0, 1) else 0
	end
	local domainAffinity = product ^ (1 / #branch.domains)

	-- An innate leaning toward this line of study (the tier-1 ancestor) pulls affinity toward it.
	local leanings = caster.branchAffinities
	if leanings and not branch.isHybrid and not branch.isRoot then
		local node = branch
		while node.tier > 1 do
			local parentId = node.parent
			if not parentId then
				break
			end
			node = Registry.branches[parentId]
		end
		local lean = leanings[node.id]
		if typeof(lean) == "number" and lean == lean then
			return domainAffinity + (math.clamp(lean, 0, 1) - domainAffinity) * Tuning.affinity.branchBlend
		end
	end
	return domainAffinity
end

local function modifierParam(modId: string, key: string, default: number): number
	local params = Registry.modifiers[modId].params
	local value = params and params[key]
	return if value ~= nil then value else default
end

local function modifierAllowed(modId: string, verbId: string, formId: string, tier: number): boolean
	local mod = Registry.modifiers[modId]
	if mod.minTier > tier then
		return false
	end
	local forms = Registry.modifierForms[modId]
	if forms and not forms[formId] then
		return false
	end
	local verbs = Registry.modifierVerbs[modId]
	if verbs and not verbs[verbId] then
		return false
	end
	return true
end

-- ─── Progression queries ────────────────────────────────────────────────────

function MagicCore.isBranchUnlocked(caster: CasterProfile, branchId: string): boolean
	local branch = Registry.branches[branchId]
	if not branch then
		return false
	end
	for _, d in branch.domains do
		if not caster.awakened[d] then
			return false
		end
	end
	-- Progression-managed casters: the explicit unlock set is authoritative.
	if caster.unlocked then
		return caster.unlocked[branchId] == true
	end
	-- Legacy rule (tests, previews): parent mastery thresholds.
	local parentId = branch.parent
	if parentId then
		if not MagicCore.isBranchUnlocked(caster, parentId) then
			return false
		end
		local needed = Tuning.unlockMastery[math.min(branch.tier, 4)] or 0
		if masteryOf(caster, parentId) < needed then
			return false
		end
	end
	for _, pre in branch.prerequisites do
		if masteryOf(caster, pre.branch) < pre.mastery then
			return false
		end
	end
	return true
end

-- The power level a caster can hold steady with no overreach penalty.
function MagicCore.comfortPower(mastery: number): number
	local m01 = math.clamp(mastery / 100, 0, 1)
	return Tuning.MIN_POWER + (Tuning.MAX_POWER - Tuning.MIN_POWER) * m01 ^ Tuning.mastery.comfortCurve
end

-- Mastery tier index (0 Untouched .. 8 Transcendent) for a mastery value.
function MagicCore.tierForMastery(mastery: number): number
	local tiers = Registry.masteryTiers.tiers
	for i = #tiers, 1, -1 do
		if mastery >= tiers[i].minMastery then
			return tiers[i].index
		end
	end
	return 0
end

function MagicCore.tierDef(index: number): Types.MasteryTierDef
	return Registry.masteryTiers.tiers[math.clamp(index, 0, #Registry.masteryTiers.tiers - 1) + 1]
end

-- The caster's mastery tier in a branch. Any unlocked branch counts as at least Sensing.
function MagicCore.masteryTier(caster: CasterProfile, branchId: string): number
	local tier = MagicCore.tierForMastery(masteryOf(caster, branchId))
	if tier < 1 and MagicCore.isBranchUnlocked(caster, branchId) then
		tier = 1
	end
	return tier
end

--[[
	Highest power level the caster may attempt from this branch: the lowest of
	the branch's maximum, the mastery tier's ceiling, and comfort + overreach allowance.
]]
function MagicCore.powerCap(caster: CasterProfile, branchId: string): number
	local branch = Registry.branches[branchId]
	if not branch then
		return 0
	end
	local comfort = MagicCore.comfortPower(masteryOf(caster, branchId))
	local ceiling = MagicCore.tierDef(MagicCore.masteryTier(caster, branchId)).powerCeiling
	return math.min(branch.maxPower, ceiling, math.floor(comfort) + Tuning.overreach.maxLevels)
end

function MagicCore.modifierSlots(mastery: number, formId: string): number
	local s = Tuning.modifierSlots
	local base = math.min(s.max, s.base + math.floor(math.clamp(mastery, 0, 100) / s.perMastery))
	local form = Registry.forms[formId]
	return base + (if form then form.modifierSlotsBonus else 0)
end

-- ─── Recipe normalization & validation ──────────────────────────────────────

-- The cost multiplier for a domain's innate attacks (Data/Strikes `innateCost`). Only the exact
-- Strike and its thrown form, at power 1 with no modifiers; a hand-built copy is the same spell, so
-- it gets the same price. Everything else in the domain returns 1.
local function innateCostFactor(recipe: Recipe, domainCost: number, costWeight: number): number
	local strike = Registry.strikes[recipe.branch]
	if
		not strike
		or not strike.innateCost
		or recipe.power ~= 1
		or #recipe.modifiers > 0
		or recipe.property ~= strike.property
		or not table.find(strike.verbs, recipe.verb)
		or (recipe.form ~= "touch" and recipe.form ~= "projectile")
	then
		return 1
	end
	return math.min(1, strike.innateCost / (domainCost * costWeight))
end

function MagicCore.recipeKey(recipe: Recipe): string
	return string.format(
		"%d|%s|%s|%s|%s|%d|%s|%s",
		recipe.v,
		recipe.branch,
		recipe.property,
		recipe.verb,
		recipe.form,
		recipe.power,
		recipe.costProfile,
		table.concat(recipe.modifiers, ",")
	)
end

--[[
	Shape-checks an untrusted table, runs schema migrations, resolves aliases, and returns a
	fresh canonical Recipe (sorted modifiers, defaulted cost profile). Does not check grammar.
]]
function MagicCore.normalizeRecipe(raw: any): (Recipe?, { ValidationError })
	local errors: { ValidationError } = {}
	if typeof(raw) ~= "table" then
		addError(errors, "BAD_TYPE", "recipe must be a table")
		return nil, errors
	end

	local version = raw.v
	if version == nil then
		version = 1
	end
	if typeof(version) ~= "number" or version % 1 ~= 0 or version < 1 or version > Tuning.RECIPE_VERSION then
		addError(errors, "BAD_VERSION", "unsupported recipe version " .. tostring(version))
		return nil, errors
	end

	local working = table.clone(raw)
	while version < Tuning.RECIPE_VERSION do
		working = MIGRATIONS[version](working)
		version += 1
	end

	for _, field in { "branch", "property", "verb", "form" } do
		if not isId(working[field]) then
			addError(errors, "BAD_TYPE", string.format("'%s' must be an id string", field))
		end
	end

	local power = working.power
	if typeof(power) ~= "number" or power ~= power or power % 1 ~= 0 or power < Tuning.MIN_POWER or power > Tuning.MAX_POWER then
		addError(errors, "BAD_POWER", string.format("power must be an integer %d-%d", Tuning.MIN_POWER, Tuning.MAX_POWER))
	end

	local mods = working.modifiers
	if mods == nil then
		mods = {}
	end
	if not isArray(mods, Tuning.MAX_MODIFIERS) then
		addError(errors, "BAD_TYPE", string.format("modifiers must be an array of at most %d ids", Tuning.MAX_MODIFIERS))
	else
		for _, m in mods do
			if not isId(m) then
				addError(errors, "BAD_TYPE", "modifier entries must be id strings")
				break
			end
		end
	end

	local costProfile = working.costProfile
	if costProfile == nil then
		costProfile = Tuning.DEFAULT_COST_PROFILE
	elseif not isId(costProfile) then
		addError(errors, "BAD_TYPE", "costProfile must be an id string")
	end

	if #errors > 0 then
		return nil, errors
	end

	local cleanMods: { string } = {}
	local seen: { [string]: boolean } = {}
	for _, m in mods do
		local id = Registry.resolveAlias("modifiers", m)
		if seen[id] then
			addError(errors, "DUPLICATE_MODIFIER", "modifier '" .. id .. "' listed twice")
		else
			seen[id] = true
			table.insert(cleanMods, id)
		end
	end
	table.sort(cleanMods)
	if #errors > 0 then
		return nil, errors
	end

	local recipe: Recipe = {
		v = Tuning.RECIPE_VERSION,
		branch = Registry.resolveAlias("branches", working.branch),
		property = Registry.resolveAlias("properties", working.property),
		verb = Registry.resolveAlias("verbs", working.verb),
		form = Registry.resolveAlias("forms", working.form),
		modifiers = cleanMods,
		power = power,
		costProfile = Registry.resolveAlias("costProfiles", costProfile),
	}
	return recipe, errors
end

--[[
	Grammar validation, plus caster gating when a profile is supplied.
	Collects every error rather than stopping at the first, so UIs can show all problems.
	Returns the normalized recipe only when valid.
]]
function MagicCore.validateRecipe(raw: any, caster: CasterProfile?): (boolean, { ValidationError }, Recipe?)
	local recipe, errors = MagicCore.normalizeRecipe(raw)
	if not recipe then
		return false, errors, nil
	end

	local branch = Registry.branches[recipe.branch]
	local property = Registry.properties[recipe.property]
	local verb = Registry.verbs[recipe.verb]
	local form = Registry.forms[recipe.form]
	if not branch then
		addError(errors, "UNKNOWN_BRANCH", "unknown branch '" .. recipe.branch .. "'")
	end
	if not property then
		addError(errors, "UNKNOWN_PROPERTY", "unknown property '" .. recipe.property .. "'")
	end
	if not verb then
		addError(errors, "UNKNOWN_VERB", "unknown verb '" .. recipe.verb .. "'")
	end
	if not form then
		addError(errors, "UNKNOWN_FORM", "unknown form '" .. recipe.form .. "'")
	end
	if not Tuning.CostProfiles[recipe.costProfile] then
		addError(errors, "UNKNOWN_COST_PROFILE", "unknown cost profile '" .. recipe.costProfile .. "'")
	end
	for _, m in recipe.modifiers do
		if not Registry.modifiers[m] then
			addError(errors, "UNKNOWN_MODIFIER", "unknown modifier '" .. m .. "'")
		end
	end
	if #errors > 0 then
		return false, errors, nil
	end

	-- Grammar ---------------------------------------------------------------
	if not branch.propertySet[recipe.property] then
		addError(errors, "PROPERTY_NOT_IN_BRANCH", string.format("%s cannot affect %s", branch.name, property.name))
	end
	if Registry.verbPropertyEff[recipe.verb][recipe.property] <= 0 then
		addError(errors, "VERB_PROPERTY_INCOMPATIBLE", string.format("cannot %s %s (%s)", verb.name, property.name, property.category))
	end
	if Registry.formVerbEff[recipe.form][recipe.verb] <= 0 then
		addError(errors, "FORM_VERB_INCOMPATIBLE", string.format("%s cannot be delivered as %s", verb.name, form.name))
	end
	if Registry.formCategoryBlocked[recipe.form][property.category] then
		addError(errors, "FORM_PROPERTY_INCOMPATIBLE", string.format("%s cannot carry %s magic", form.name, property.category))
	end
	if verb.minTier > branch.tier then
		addError(errors, "VERB_TIER", string.format("%s needs a tier %d branch", verb.name, verb.minTier))
	end
	if form.minTier > branch.tier then
		addError(errors, "FORM_TIER", string.format("%s needs a tier %d branch", form.name, form.minTier))
	end
	if recipe.power > branch.maxPower then
		addError(errors, "POWER_OVER_BRANCH_MAX", string.format("%s tops out at power %d", branch.name, branch.maxPower))
	end

	for i, modId in recipe.modifiers do
		local mod = Registry.modifiers[modId]
		if mod.minTier > branch.tier then
			addError(errors, "MODIFIER_TIER", string.format("%s needs a tier %d branch", mod.name, mod.minTier))
		end
		local forms = Registry.modifierForms[modId]
		if forms and not forms[recipe.form] then
			addError(errors, "MODIFIER_FORM", string.format("%s cannot apply to %s", mod.name, form.name))
		end
		local verbs = Registry.modifierVerbs[modId]
		if verbs and not verbs[recipe.verb] then
			addError(errors, "MODIFIER_VERB", string.format("%s cannot apply to %s", mod.name, verb.name))
		end
		for j = i + 1, #recipe.modifiers do
			local other = recipe.modifiers[j]
			if Registry.modifierConflicts[modId][other] then
				addError(errors, "MODIFIER_CONFLICT", string.format("%s conflicts with %s", mod.name, Registry.modifiers[other].name))
			end
		end
	end

	local structuralSlots = Tuning.modifierSlots.max + form.modifierSlotsBonus
	if #recipe.modifiers > structuralSlots then
		addError(errors, "TOO_MANY_MODIFIERS", string.format("%s holds at most %d modifiers", form.name, structuralSlots))
	end

	-- Caster gating -----------------------------------------------------------
	if caster then
		if not MagicCore.isBranchUnlocked(caster, recipe.branch) then
			addError(errors, "BRANCH_LOCKED", branch.name .. " is not unlocked")
		end
		local mastery = masteryOf(caster, recipe.branch)
		-- Form reach (a focus): forms are judged as if mastery were bonusFormTier tiers higher.
		local formReach = caster.bonusFormTier or 0
		local formMastery = if formReach > 0
			then math.max(mastery, MagicCore.tierDef(MagicCore.tierForMastery(mastery) + formReach).minMastery)
			else mastery
		if formMastery < form.minMastery then
			addError(errors, "FORM_MASTERY", string.format("%s needs %d mastery in %s", form.name, form.minMastery, branch.name))
		end
		local tier = MagicCore.masteryTier(caster, recipe.branch)
		local verbTier = Registry.verbMasteryTier[recipe.verb]
		if verbTier > tier then
			addError(errors, "VERB_MASTERY", string.format("%s needs %s in %s", verb.name, MagicCore.tierDef(verbTier).name, branch.name))
		end
		local formTier = Registry.formMasteryTier[recipe.form]
		if formTier > tier + (caster.bonusFormTier or 0) then
			addError(errors, "FORM_MASTERY", string.format("%s needs %s in %s", form.name, MagicCore.tierDef(formTier).name, branch.name))
		end
		local slots = math.min(structuralSlots, MagicCore.modifierSlots(mastery, recipe.form) + (caster.bonusModifierSlots or 0))
		if #recipe.modifiers > slots and #recipe.modifiers <= structuralSlots then
			addError(errors, "TOO_MANY_MODIFIERS", string.format("current mastery allows %d modifiers", slots))
		end
		local cap = MagicCore.powerCap(caster, recipe.branch)
		if recipe.power > cap then
			addError(errors, "POWER_OVER_CAP", string.format("current mastery allows power %d at most", cap))
		end
	end

	local ok = #errors == 0
	return ok, errors, if ok then recipe else nil
end

-- ─── Environment ────────────────────────────────────────────────────────────

-- True if the branch, one of its ancestors, or one of its domains is listed.
local function branchMatches(branch: BranchDef, ids: { string }): boolean
	local node: BranchDef? = branch
	while node do
		if table.find(ids, node.id) then
			return true
		end
		local parentId = node.parent
		node = if parentId then Registry.branches[parentId] else nil
	end
	for _, d in branch.domains do
		if table.find(ids, d) then
			return true
		end
	end
	return false
end

-- Applies EnvironmentRules (see Data/EnvironmentRules). Returns (powerFactor, blockedByRuleId?).
local function environmentFactor(recipe: Recipe, branch: BranchDef, ctx: CastContext, warnings: { string }): (number, string?)
	local factor = 1
	local bonus = 1 -- the best surplus bonus; never stacked across rules
	local blocked: string? = nil
	for _, rule in Registry.environmentRules do
		if recipe.power < rule.minPower then
			continue
		end
		if rule.properties and not table.find(rule.properties, recipe.property) then
			continue
		end
		if rule.verbs and not table.find(rule.verbs, recipe.verb) then
			continue
		end
		if not branchMatches(branch, rule.branches) then
			continue
		end
		local value = ctx.environment and ctx.environment[rule.fact]
		if typeof(value) ~= "number" or value ~= value then
			local warning = "ENV_UNKNOWN:" .. rule.fact
			if not table.find(warnings, warning) then
				table.insert(warnings, warning)
			end
			continue
		end
		local required = rule.base * rule.growth ^ (recipe.power - rule.minPower)
		local ratio = value / required
		if ratio < rule.hardFraction then
			blocked = blocked or rule.id
		elseif ratio < 1 then
			factor *= ratio ^ 0.5
		else
			bonus = math.max(bonus, math.min(Tuning.environment.maxBonus, 1 + Tuning.environment.surplusBonus * (ratio - 1)))
		end
	end
	return factor * bonus, blocked
end

-- ─── Stats ──────────────────────────────────────────────────────────────────

--[[
	Computes every number the cast pipeline needs. Pure: same (recipe, caster, context) always
	yields the same stats. See docs/MagicSystem.md §5 for the model.
]]
function MagicCore.computeStats(raw: any, caster: CasterProfile, context: CastContext?): (SpellStats?, { ValidationError })
	local ok, errors, recipe = MagicCore.validateRecipe(raw, caster)
	if not ok or not recipe then
		return nil, errors
	end

	local ctx: CastContext = context or {}
	local branch = Registry.branches[recipe.branch]
	local property = Registry.properties[recipe.property]
	local verb = Registry.verbs[recipe.verb]
	local form = Registry.forms[recipe.form]
	local profile = Tuning.CostProfiles[recipe.costProfile]
	local M = Tuning.mastery
	local A = Tuning.affinity
	local P = recipe.power
	local traits = caster.traits or Tuning.neutralTraits
	local warnings: { string } = {}

	local mastery = masteryOf(caster, recipe.branch)
	local m01 = mastery / 100
	local affinity = affinityFor(caster, branch)
	local verbEff = Registry.verbPropertyEff[recipe.verb][recipe.property]
	local formEff = Registry.formVerbEff[recipe.form][recipe.verb]

	-- Modifier aggregate
	local mPower, mCost, mRange, mArea, mDuration, mCast, mCooldown, mInstability = 1, 1, 1, 1, 1, 1, 1, 0
	local flags: { [string]: boolean } = {}
	for _, modId in recipe.modifiers do
		local mod = Registry.modifiers[modId]
		mPower *= mod.powerMult
		mCost *= mod.costMult
		mRange *= mod.rangeMult
		mArea *= mod.areaMult
		mDuration *= mod.durationMult
		mCast *= mod.castTimeMult
		mCooldown *= mod.cooldownMult
		mInstability += mod.instability
		flags[modId] = true
	end

	-- Domain factors (hybrids average their domains)
	local domainCost, domainVolatility, biasSum = 0, 0, 0
	local bias = ctx.ambientBias or {}
	for _, d in branch.domains do
		local def = Registry.domains[d]
		domainCost += def.costMult
		domainVolatility += def.volatility
		biasSum += bias[d] or 1
	end
	local n = #branch.domains
	domainCost /= n
	domainVolatility /= n

	-- Ambient density
	local baseDensity = ctx.ambientDensity or Tuning.Ambient.default
	if typeof(baseDensity) ~= "number" or baseDensity ~= baseDensity then
		baseDensity = Tuning.Ambient.default
	end
	local density = math.clamp(baseDensity * (biasSum / n), Tuning.Ambient.min, Tuning.Ambient.max)
	local scarcity = 1 + Tuning.Ambient.scarcityCostMult * math.max(0, 1 - density)

	-- Power
	local magnitude = Tuning.magnitudeGrowth ^ (P - 1)
	local affinityPower = A.powerMin + A.powerSpan * affinity
	local masteryPower = 1 + M.powerBonus * m01
	-- Domain resonance of the place (ambientBias): aligned magic is stronger, opposed magic suppressed.
	local R = Tuning.resonance
	local resonance = math.clamp((biasSum / n) ^ R.powerExponent, R.min, R.max)
	local power = magnitude
		* verb.powerMult
		* form.powerMult
		* mPower
		* verbEff
		* formEff
		* affinityPower
		* masteryPower
		* profile.powerMult
		* traits.power
		* resonance

	-- Cost
	local affinityCost = A.costMax - A.costSpan * affinity
	local masteryCost = 1 - M.costDiscount * m01 ^ M.costCurve
	local awkwardness = (1 / (verbEff * formEff)) ^ Tuning.awkwardCostExponent
	local cost = Tuning.costBase
		* Tuning.costGrowth ^ (P - 1)
		* verb.costMult
		* form.costMult
		* mCost
		* property.costWeight
		* awkwardness
		* affinityCost
		* masteryCost
		* domainCost
		* scarcity
		* traits.cost
		* innateCostFactor(recipe, domainCost, property.costWeight)

	-- Specialization commitments, the creator's signature bonus, and environmental conditions.
	local key = MagicCore.recipeKey(recipe)
	local branchMod = caster.branchMods and caster.branchMods[recipe.branch]
	local isSignature = caster.signatures ~= nil and caster.signatures[key] ~= nil
	local envFactor, blockedBy = environmentFactor(recipe, branch, ctx, warnings)
	power *= (if branchMod then branchMod.power else 1)
		* (if isSignature then Tuning.signature.power else 1)
		* envFactor
	cost *= (if branchMod then branchMod.cost else 1) * (if isSignature then Tuning.signature.cost else 1)
	if blockedBy then
		table.insert(warnings, "BLOCKED_BY_ENVIRONMENT")
	end

	-- Channeled spells bill a fraction upfront plus upkeep per second.
	local channelCostPerSecond, maxChannelTime = 0, 0
	if flags.channeled then
		channelCostPerSecond = cost * modifierParam("channeled", "costPerSecondFraction", 0.25)
		maxChannelTime = modifierParam("channeled", "maxChannel", 6)
		cost *= modifierParam("channeled", "upfrontFraction", 0.4)
	end

	-- Cost split across sources
	local ambientShare = 0
	if profile.ambientShareMax > 0 then
		if density >= profile.minDensity then
			ambientShare = math.min(profile.ambientShareMax, profile.ambientSharePerDensity * density)
			ambientShare = math.min(Tuning.maxAmbientShare, ambientShare + traits.ambientShareBonus)
		else
			table.insert(warnings, "AMBIENT_TOO_THIN")
		end
	end
	local vitalMana = cost * profile.vitalShare
	local ambientMana = (cost - vitalMana) * ambientShare
	local reservoirMana = cost - vitalMana - ambientMana

	-- Shape
	local range = form.baseRange * (1 + Tuning.rangePerLevel * (P - 1)) * (1 + M.rangeBonus * m01) * mRange
	local area = form.baseArea * magnitude ^ Tuning.areaExponent * mArea * envFactor ^ 0.5
	local duration = form.baseDuration * (1 + Tuning.durationPerLevel * (P - 1)) * verb.durationMult * mDuration
	local castTime = math.max(
		Tuning.minCastTime,
		form.castTime
			* verb.castTimeMult
			* (1 + Tuning.castTimePerLevel * (P - 1))
			* (1 - M.castTimeReduction * m01)
			* mCast
			* profile.castTimeMult
			* traits.castTime
	)
	local cooldown = math.max(Tuning.minCooldown, form.cooldown * (1 + Tuning.cooldownPerLevel * (P - 1)) * mCooldown)
	local maxTargets = if form.maxTargets > 0
		then form.maxTargets + math.floor(form.extraTargetsPerPower * (P - 1))
		else Tuning.maxAreaTargets

	-- Instability
	local comfort = MagicCore.comfortPower(mastery)
	local masteryTier = MagicCore.masteryTier(caster, recipe.branch)
	local transcendent = masteryTier >= #Registry.masteryTiers.tiers - 1
	local overreach = if transcendent then 0 else math.max(0, P - comfort)
	if overreach > 0 then
		table.insert(warnings, "OVERREACH")
	end
	local baseInstability = math.max(0, verb.instability + form.instability + mInstability + property.volatility)
	local instability = baseInstability
		* (Tuning.instability.powerBase + Tuning.instability.powerScale * P)
		* (1 - M.instabilityReduction * m01)
		* domainVolatility
		* profile.instabilityMult
		* traits.instability
		+ overreach * Tuning.overreach.instabilityPerLevel
	instability = math.clamp(instability, 0, 1)

	if verb.requirement ~= "None" then
		table.insert(warnings, "REQUIRES_" .. string.upper(verb.requirement))
	end

	local echoes = if flags.echoing then modifierParam("echoing", "echoes", 2) else 0

	local stats: SpellStats = {
		key = key,
		recipe = recipe,
		domains = table.clone(branch.domains),
		tier = branch.tier,
		category = property.category,
		requirement = verb.requirement,
		-- A domain's strike (Data/Strikes) is an attack even on a property that can't injure by
		-- itself (Stone Shot, Psychic Spike): safe zones, crimes and NPC witnesses treat it so.
		harmful = property.harmful or Strike.find(recipe) ~= nil,
		magnitude = round(magnitude, 3),
		power = round(power, 3),
		cost = round(cost, 2),
		costBreakdown = {
			reservoir = round(reservoirMana, 2),
			ambient = round(ambientMana, 2),
			vitalHp = round(vitalMana * profile.hpPerMana * traits.vitalCost, 2),
		},
		range = round(range, 2),
		area = round(area, 2),
		duration = round(duration, 2),
		castTime = round(castTime, 2),
		cooldown = round(cooldown, 2),
		maxTargets = maxTargets,
		instability = round(instability, 4),
		backfireChance = round(instability * instability, 4),
		comfortPower = round(comfort, 2),
		overreach = round(overreach, 2),
		flags = flags,
		channelCostPerSecond = round(channelCostPerSecond, 2),
		maxChannelTime = maxChannelTime,
		echoes = echoes,
		echoPower = if echoes > 0 then round(power * modifierParam("echoing", "echoPowerFraction", 0.5), 3) else 0,
		delay = if flags.delayed then modifierParam("delayed", "delay", 2) else 0,
		masteryTier = masteryTier,
		resonance = round(resonance, 3),
		environmentFactor = round(envFactor, 3),
		blockedBy = blockedBy,
		warnings = warnings,
	}
	return stats, errors
end

-- ─── Discovery ──────────────────────────────────────────────────────────────

--[[
	Every (branch, property, verb, form) combination the caster can currently build, with the
	power ceiling and the modifiers that fit. Modifier subsets and power levels are NOT
	expanded (that would be combinatorial); the UI picks from `modifiers` up to `modifierSlots`.

	Cost is O(unlockedBranches * properties * verbs * forms): a few thousand for a strong
	caster. Call on demand (spellbook open) or cache per profile revision, not per frame.
]]
function MagicCore.listAvailableRecipes(caster: CasterProfile, filter: TemplateFilter?): { RecipeTemplate }
	local f: TemplateFilter = filter or {}
	local limit = f.limit or math.huge
	local results: { RecipeTemplate } = {}

	for _, branchId in Registry.branchIds do
		if f.branch and f.branch ~= branchId then
			continue
		end
		if not MagicCore.isBranchUnlocked(caster, branchId) then
			continue
		end
		local branch = Registry.branches[branchId]
		local mastery = masteryOf(caster, branchId)
		local tier = MagicCore.masteryTier(caster, branchId)
		local cap = MagicCore.powerCap(caster, branchId)
		local comfort = round(MagicCore.comfortPower(mastery), 2)

		for _, propertyId in branch.properties do
			if f.property and f.property ~= propertyId then
				continue
			end
			local category = Registry.properties[propertyId].category

			for _, verbId in Registry.verbIds do
				if f.verb and f.verb ~= verbId then
					continue
				end
				if Registry.verbs[verbId].minTier > branch.tier or Registry.verbPropertyEff[verbId][propertyId] <= 0 then
					continue
				end
				if Registry.verbMasteryTier[verbId] > tier then
					continue
				end

				for _, formId in Registry.formIds do
					if f.form and f.form ~= formId then
						continue
					end
					local form = Registry.forms[formId]
					if form.minTier > branch.tier or mastery < form.minMastery or Registry.formMasteryTier[formId] > tier then
						continue
					end
					if Registry.formVerbEff[formId][verbId] <= 0 or Registry.formCategoryBlocked[formId][category] then
						continue
					end

					local mods: { string } = {}
					for _, modId in Registry.modifierIds do
						if modifierAllowed(modId, verbId, formId, branch.tier) then
							table.insert(mods, modId)
						end
					end

					table.insert(results, {
						branch = branchId,
						property = propertyId,
						verb = verbId,
						form = formId,
						maxPower = cap,
						comfortPower = comfort,
						modifierSlots = MagicCore.modifierSlots(mastery, formId),
						modifiers = mods,
					})
					if #results >= limit then
						return results
					end
				end
			end
		end
	end
	return results
end

-- Human-readable one-liner, for logs and debug UI.
function MagicCore.describe(recipe: Recipe): string
	local branch = Registry.branches[recipe.branch]
	local property = Registry.properties[recipe.property]
	local verb = Registry.verbs[recipe.verb]
	local form = Registry.forms[recipe.form]
	-- Tolerates raw, unnormalized recipes (missing modifiers), since this is called on invalid input.
	local modifiers = if typeof(recipe.modifiers) == "table" then recipe.modifiers else {}
	local mods = if #modifiers > 0 then " +" .. table.concat(modifiers, "+") else ""
	return string.format(
		"%s %s as %s [%s] P%s%s",
		if verb then verb.name else recipe.verb,
		if property then property.name else recipe.property,
		if form then form.name else recipe.form,
		if branch then branch.name else recipe.branch,
		tostring(recipe.power),
		mods
	)
end

return MagicCore
