--!strict
--[[
	Registry
	Loads every data module once, flattens the branch tree, builds lookup indexes and
	validates cross-references. Authoring mistakes (typo'd property id, short matrix row,
	dangling prerequisite) fail loudly at require-time instead of at cast-time.
	Everything exposed is deep-frozen so runtime code can't mutate definitions.
]]

local Types = require(script.Parent.Types)
local Data = script.Parent.Data
local Domains = require(Data.Domains)
local Branches = require(Data.Branches)
local Properties = require(Data.Properties)
local Verbs = require(Data.Verbs)
local Forms = require(Data.Forms)
local Modifiers = require(Data.Modifiers)
local Compatibility = require(Data.Compatibility)
local Tuning = require(Data.Tuning)
local Aliases = require(Data.Aliases)
local MasteryTiers = require(Data.MasteryTiers)
local Specializations = require(Data.Specializations)
local EnvironmentRules = require(Data.EnvironmentRules)
local Techniques = require(Data.Techniques)
local Strikes = require(Data.Strikes)

type BranchDef = Types.BranchDef
type BranchNode = Types.BranchNode

local problems: { string } = {}
local function problem(fmt: string, ...: any)
	table.insert(problems, string.format(fmt, ...))
end

local function sortedKeys(t: { [string]: any }): { string }
	local keys: { string } = {}
	for key in t do
		table.insert(keys, key)
	end
	table.sort(keys)
	return keys
end

local function toSet(list: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, v in list do
		set[v] = true
	end
	return set
end

-- ─── Categories & properties ────────────────────────────────────────────────

local categorySet = toSet(Compatibility.categories)

for id, prop in Properties do
	if not categorySet[prop.category] then
		problem("property '%s' has unknown category '%s'", id, prop.category)
	end
end

-- ─── Domains ────────────────────────────────────────────────────────────────

local raritySet = toSet(Tuning.rarities)

for id, domain in Domains do
	if not raritySet[domain.rarity] then
		problem("domain '%s' has unknown rarity '%s'", id, domain.rarity)
	end
	for _, p in domain.properties do
		if not Properties[p] then
			problem("domain '%s' lists unknown property '%s'", id, p)
		end
	end
	for _, other in domain.synergies do
		if not Domains[other] then
			problem("domain '%s' synergy '%s' is not a domain", id, other)
		end
	end
	for _, other in domain.oppositions do
		if not Domains[other] then
			problem("domain '%s' opposition '%s' is not a domain", id, other)
		end
	end
	if not Branches.roots[id] then
		problem("domain '%s' has no root branch", id)
	end
end

-- ─── Branch tree ────────────────────────────────────────────────────────────

local branches: { [string]: BranchDef } = {}

local function domainPropertySet(domainIds: { string }): { [string]: boolean }
	local set: { [string]: boolean } = {}
	for _, d in domainIds do
		local def = Domains[d]
		if def then
			for _, p in def.properties do
				set[p] = true
			end
		end
	end
	return set
end

local function addBranch(
	node: BranchNode,
	tier: number,
	domains: { string },
	parent: BranchDef?,
	isHybrid: boolean,
	allowed: { [string]: boolean }
)
	if branches[node.id] then
		problem("duplicate branch id '%s'", node.id)
		return
	end
	if parent ~= nil and Domains[node.id] then
		problem("branch '%s' reuses a domain id", node.id)
	end

	-- Inherit the parent's properties, then append our own (order kept for deterministic listings).
	local list: { string } = {}
	local set: { [string]: boolean } = {}
	if parent then
		for _, p in parent.properties do
			set[p] = true
			table.insert(list, p)
		end
	end
	local own = node.properties or {}
	for _, p in own do
		if not allowed[p] then
			problem("branch '%s' grants property '%s' outside its domain(s)", node.id, p)
		elseif not set[p] then
			set[p] = true
			table.insert(list, p)
		end
	end

	local maxPower = node.maxPower or Tuning.tierMaxPower[math.min(tier, 4)]
	if maxPower < Tuning.MIN_POWER or maxPower > Tuning.MAX_POWER then
		problem("branch '%s' maxPower %d out of range", node.id, maxPower)
	end

	local def: BranchDef = {
		id = node.id,
		name = node.name,
		description = node.description,
		tier = tier,
		domains = domains,
		parent = if parent then parent.id else nil,
		children = {},
		ownProperties = own,
		properties = list,
		propertySet = set,
		prerequisites = node.prerequisites or {},
		maxPower = maxPower,
		isRoot = parent == nil and not isHybrid,
		isHybrid = isHybrid,
		tags = node.tags or {},
	}
	branches[node.id] = def
	if parent then
		table.insert(parent.children, node.id)
	end

	for _, child in node.children or {} do
		addBranch(child, tier + 1, domains, def, isHybrid, allowed)
	end
end

for _, domainId in sortedKeys(Branches.roots) do
	local root = Branches.roots[domainId]
	if not Domains[domainId] then
		problem("root branch '%s' has no matching domain", domainId)
		continue
	end
	if root.id ~= domainId then
		problem("root branch id '%s' must equal its domain id '%s'", root.id, domainId)
	end
	addBranch(root, 0, { domainId }, nil, false, domainPropertySet({ domainId }))
end

local hybridsByDomain: { [string]: { string } } = {}
for id in Domains do
	hybridsByDomain[id] = {}
end

for _, hybrid in Branches.hybrids do
	if #hybrid.domains < 2 then
		problem("hybrid '%s' must span at least two domains", hybrid.id)
	end
	for _, d in hybrid.domains do
		if not Domains[d] then
			problem("hybrid '%s' references unknown domain '%s'", hybrid.id, d)
		else
			table.insert(hybridsByDomain[d], hybrid.id)
		end
	end
	if #hybrid.prerequisites == 0 then
		problem("hybrid '%s' must declare prerequisites", hybrid.id)
	end
	addBranch(hybrid, Tuning.hybridTier, hybrid.domains, nil, true, domainPropertySet(hybrid.domains))
end

for id, branch in branches do
	for _, pre in branch.prerequisites do
		if not branches[pre.branch] then
			problem("branch '%s' prerequisite '%s' does not exist", id, pre.branch)
		end
		if pre.mastery < 0 or pre.mastery > 100 then
			problem("branch '%s' prerequisite mastery %s out of range", id, tostring(pre.mastery))
		end
	end
end

-- Soft check: a domain property nobody can learn is probably an authoring oversight.
for domainId, domain in Domains do
	local granted: { [string]: boolean } = {}
	for _, branch in branches do
		if branch.domains[1] == domainId and not branch.isHybrid then
			for _, p in branch.ownProperties do
				granted[p] = true
			end
		end
	end
	for _, p in domain.properties do
		if not granted[p] then
			warn(string.format("[Magic.Registry] domain '%s' property '%s' is not granted by any branch", domainId, p))
		end
	end
end

-- ─── Verbs, forms, matrices ─────────────────────────────────────────────────

local verbColumnSet = toSet(Compatibility.verbColumns)
for id in Verbs do
	if not verbColumnSet[id] then
		problem("verb '%s' missing from Compatibility.verbColumns", id)
	end
	local row = Compatibility.verbCategory[id]
	if not row then
		problem("verb '%s' has no Compatibility.verbCategory row", id)
	elseif #row ~= #Compatibility.categories then
		problem("verbCategory row '%s' has %d columns, expected %d", id, #row, #Compatibility.categories)
	end
end
for _, id in Compatibility.verbColumns do
	if not Verbs[id] then
		problem("Compatibility.verbColumns lists unknown verb '%s'", id)
	end
end

local verbCategoryEff: { [string]: { [string]: number } } = {}
for verbId, row in Compatibility.verbCategory do
	if not Verbs[verbId] then
		problem("verbCategory row for unknown verb '%s'", verbId)
	end
	local map: { [string]: number } = {}
	for i, category in Compatibility.categories do
		map[category] = row[i] or 0
	end
	verbCategoryEff[verbId] = map
end

-- Verb x Property: the category grid, then Compatibility.propertyVerb's exceptions on top.
-- Every validity and efficiency check goes through this one table.
local verbPropertyEff: { [string]: { [string]: number } } = {}
for verbId, byCategory in verbCategoryEff do
	local map: { [string]: number } = {}
	for propertyId, prop in Properties do
		map[propertyId] = byCategory[prop.category] or 0
	end
	verbPropertyEff[verbId] = map
end
for propertyId, overrides in Compatibility.propertyVerb do
	if not Properties[propertyId] then
		problem("Compatibility.propertyVerb lists unknown property '%s'", propertyId)
		continue
	end
	for verbId, eff in overrides do
		if not verbPropertyEff[verbId] then
			problem("Compatibility.propertyVerb '%s' lists unknown verb '%s'", propertyId, verbId)
		else
			verbPropertyEff[verbId][propertyId] = eff
		end
	end
end

local formVerbEff: { [string]: { [string]: number } } = {}
local formCategoryBlocked: { [string]: { [string]: boolean } } = {}
for formId in Forms do
	local row = Compatibility.formVerb[formId]
	if not row then
		problem("form '%s' has no Compatibility.formVerb row", formId)
		row = {}
	elseif #row ~= #Compatibility.verbColumns then
		problem("formVerb row '%s' has %d columns, expected %d", formId, #row, #Compatibility.verbColumns)
	end
	local map: { [string]: number } = {}
	for i, verbId in Compatibility.verbColumns do
		map[verbId] = row[i] or 0
	end
	formVerbEff[formId] = map

	local blocked = Compatibility.formCategoryBlocked[formId] or {}
	for _, c in blocked do
		if not categorySet[c] then
			problem("formCategoryBlocked '%s' lists unknown category '%s'", formId, c)
		end
	end
	formCategoryBlocked[formId] = toSet(blocked)
end
for formId in Compatibility.formVerb do
	if not Forms[formId] then
		problem("formVerb row for unknown form '%s'", formId)
	end
end

-- ─── Modifiers ──────────────────────────────────────────────────────────────

local modifierConflicts: { [string]: { [string]: boolean } } = {}
local modifierForms: { [string]: { [string]: boolean } } = {} -- absent = any form
local modifierVerbs: { [string]: { [string]: boolean } } = {} -- absent = any verb
for id in Modifiers do
	modifierConflicts[id] = {}
end
for id, mod in Modifiers do
	for _, other in mod.excludes or {} do
		if not Modifiers[other] then
			problem("modifier '%s' excludes unknown modifier '%s'", id, other)
		else
			modifierConflicts[id][other] = true
			modifierConflicts[other][id] = true
		end
	end
	if mod.forms then
		for _, f in mod.forms do
			if not Forms[f] then
				problem("modifier '%s' lists unknown form '%s'", id, f)
			end
		end
		modifierForms[id] = toSet(mod.forms)
	end
	if mod.verbs then
		for _, v in mod.verbs do
			if not Verbs[v] then
				problem("modifier '%s' lists unknown verb '%s'", id, v)
			end
		end
		modifierVerbs[id] = toSet(mod.verbs)
	end
end

-- ─── Aliases ────────────────────────────────────────────────────────────────

local aliasTargets: { [string]: { [string]: any } } = {
	domains = Domains,
	branches = branches,
	properties = Properties,
	verbs = Verbs,
	forms = Forms,
	modifiers = Modifiers,
	costProfiles = Tuning.CostProfiles,
}
for kind, map in Aliases :: { [string]: { [string]: string } } do
	local targets = aliasTargets[kind]
	if not targets then
		problem("Aliases has unknown kind '%s'", kind)
		continue
	end
	for old, new in map do
		if targets[old] then
			problem("alias '%s.%s' shadows a live id", kind, old)
		end
		-- follow chains to make sure they terminate on a real id
		local current, hops = new, 0
		while (Aliases :: any)[kind][current] and hops < 8 do
			current = (Aliases :: any)[kind][current]
			hops += 1
		end
		if not targets[current] then
			problem("alias '%s.%s' -> '%s' does not resolve to a live id", kind, old, new)
		end
	end
end

-- ─── Mastery tiers ──────────────────────────────────────────────────────────

local verbMasteryTier: { [string]: number } = {}
local formMasteryTier: { [string]: number } = {}
for i, tier in MasteryTiers.tiers do
	if tier.index ~= i - 1 then
		problem("mastery tier %s has index %d, expected %d", tier.id, tier.index, i - 1)
	end
	local previous = MasteryTiers.tiers[i - 1]
	if previous and tier.minMastery <= previous.minMastery then
		problem("mastery tier %s must have a higher minMastery than %s", tier.id, previous.id)
	end
	for _, v in tier.verbs do
		if not Verbs[v] then
			problem("mastery tier %s lists unknown verb %s", tier.id, v)
		elseif verbMasteryTier[v] then
			problem("verb %s is unlocked by two mastery tiers", v)
		end
		verbMasteryTier[v] = tier.index
	end
	for _, f in tier.forms do
		if not Forms[f] then
			problem("mastery tier %s lists unknown form %s", tier.id, f)
		elseif formMasteryTier[f] then
			problem("form %s is unlocked by two mastery tiers", f)
		end
		formMasteryTier[f] = tier.index
	end
end
for id in Verbs do
	if verbMasteryTier[id] == nil then
		problem("verb %s is not unlocked by any mastery tier", id)
	end
end
for id in Forms do
	if formMasteryTier[id] == nil then
		problem("form %s is not unlocked by any mastery tier", id)
	end
end

-- ─── Specializations, environment rules, techniques ─────────────────────────

for id, spec in Specializations do
	if not branches[spec.branch] then
		problem("specialization %s boosts unknown branch %s", id, spec.branch)
	end
	for _, w in spec.weakens do
		if not branches[w] then
			problem("specialization %s weakens unknown branch %s", id, w)
		end
	end
end

for _, rule in EnvironmentRules do
	for _, b in rule.branches do
		if not branches[b] then
			problem("environment rule %s lists unknown branch %s", rule.id, b)
		end
	end
	for _, p in (rule.properties or {}) :: { string } do
		if not Properties[p] then
			problem("environment rule %s lists unknown property %s", rule.id, p)
		end
	end
	for _, v in (rule.verbs or {}) :: { string } do
		if not Verbs[v] then
			problem("environment rule %s lists unknown verb %s", rule.id, v)
		end
	end
end

for id, technique in Techniques do
	local r = technique.recipe
	if not (branches[r.branch] and Properties[r.property] and Verbs[r.verb] and Forms[r.form]) then
		problem("technique %s references an unknown branch/property/verb/form", id)
	end
	if not Domains[technique.domain] then
		problem("technique %s has unknown domain %s", id, technique.domain)
	end
end

-- Strikes: every domain has one, built from its root branch (the early-game guarantee).
for _, domainId in sortedKeys(Domains) do
	local strike = Strikes[domainId]
	local root = branches[domainId]
	if not strike then
		problem("domain '%s' has no strike (Data/Strikes)", domainId)
		continue
	end
	if root and not root.propertySet[strike.property] then
		problem("strike '%s' uses '%s', which the %s root branch doesn't grant", strike.name, strike.property, domainId)
	end
	for _, v in strike.verbs do
		if not Verbs[v] then
			problem("strike '%s' lists unknown verb '%s'", strike.name, v)
		end
	end
	for _, f in (strike.forms or {}) :: { string } do
		if not Forms[f] then
			problem("strike '%s' lists unknown form '%s'", strike.name, f)
		end
	end
	if not strike.native and not (strike.share and strike.share > 0 and strike.share <= 1) then
		problem("strike '%s' needs a share in (0, 1] (or a native route)", strike.name)
	end
end
for id in Strikes do
	if not Domains[id] then
		problem("strike for unknown domain '%s'", id)
	end
end

if #problems > 0 then
	error("[Magic.Registry] invalid magic data:\n  " .. table.concat(problems, "\n  "), 0)
end

-- ─── Public surface ─────────────────────────────────────────────────────────

local function deepFreeze(t: any)
	if typeof(t) ~= "table" or table.isfrozen(t) then
		return
	end
	for _, v in t do
		deepFreeze(v)
	end
	table.freeze(t)
end

local Registry = {
	Tuning = Tuning,
	categories = Compatibility.categories,

	domains = Domains,
	branches = branches,
	properties = Properties,
	verbs = Verbs,
	forms = Forms,
	modifiers = Modifiers,

	-- Sorted id lists for deterministic iteration.
	domainIds = sortedKeys(Domains),
	branchIds = sortedKeys(branches),
	propertyIds = sortedKeys(Properties),
	verbIds = sortedKeys(Verbs),
	formIds = sortedKeys(Forms),
	modifierIds = sortedKeys(Modifiers),

	hybridsByDomain = hybridsByDomain,
	verbCategoryEff = verbCategoryEff,
	verbPropertyEff = verbPropertyEff, -- use this for validity: it includes per-property exceptions
	formVerbEff = formVerbEff,
	formCategoryBlocked = formCategoryBlocked,
	modifierConflicts = modifierConflicts,
	modifierForms = modifierForms,
	modifierVerbs = modifierVerbs,

	masteryTiers = MasteryTiers,
	verbMasteryTier = verbMasteryTier,
	formMasteryTier = formMasteryTier,
	specializations = Specializations,
	environmentRules = EnvironmentRules,
	techniques = Techniques,
	strikes = Strikes,
}

-- Resolve a possibly-renamed id (from an old save) to its current id.
function Registry.resolveAlias(kind: string, id: string): string
	local map = (Aliases :: any)[kind] :: { [string]: string }?
	if not map then
		return id
	end
	local current, hops = id, 0
	while map[current] and hops < 8 do
		current = map[current]
		hops += 1
	end
	return current
end

deepFreeze(Registry)

return Registry
