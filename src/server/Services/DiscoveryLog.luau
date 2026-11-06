--!strict
--[[
	DiscoveryLog: who invented what.

	Personal discovery: the first time YOU successfully cast a recipe (power >= 2, with a real
	effect). Stored in data.discoveries.recipes; grants Experimentation XP and counts toward
	"discoveries" breakthrough requirements.

	World-first: the first time ANYONE in the world casts it. Claimed atomically in the
	"Discoveries" DataStore (UpdateAsync create-if-absent, key = 64-bit hash of the recipe key),
	so two servers can't both win. Grants a large bonus, a chronicle entry, and an Epiphany
	awakening attempt. Stored in data.discoveries.worldFirsts.

	Novelty: the first effective cast of a new verb + property + form, at ANY power, pays falling
	experimentation XP and a toast (Progression/Experiment). First reactions: the first time you
	trigger each InteractionMatrix reaction pays reactionXp and says what you found. Neither counts
	toward breakthroughs. SuggestSpell answers the Composer's "Try something".

	Signature spell (paradigm shift): a world-first recipe you've named, cast 50+ times, and
	reached Expert in, can be declared your signature (max 3). The creator casts it at
	x1.1 power and x0.9 cost; it counts toward the Transcendent breakthrough.

		recordCast(player, stats, effective)   called by CastService after every resolved cast
		declareSignature(player, recipeKey)    -> ok, reasonOrName
		list(player)                           -> { { key, at, worldFirst } }
]]

local Players = game:GetService("Players")
local Shared = game:GetService("ReplicatedStorage").Shared
local ServerScriptService = game:GetService("ServerScriptService")
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Experiment = require(script.Parent.Parent.Progression.Experiment)
local Seed = require(Shared.Magic.Seed)
local Types = require(Shared.Magic.Types)
local Schemas = require(script.Parent.Parent.Persistence.Schemas)
local Progression = require(script.Parent.Parent.Progression.Progression)
local T = require(script.Parent.Parent.Progression.ProgressionTuning)
local InnateProfile = require(ServerScriptService.Server.Magic.InnateProfile)

local DiscoveryLog = {
	name = "DiscoveryLog",
	dependencies = { "NetService", "DataService", "PlayerDataService", "ProgressionService", "WorldService", "SpellbookService" },
}

local log: any = nil
local flags: any = nil
local store: any = nil
local playerData: any = nil
local progression: any = nil
local world: any = nil
local spellbook: any = nil
local claimedCache: { [string]: boolean } = {} -- hashes known to be claimed already
local suggestCounts: { [Player]: number } = {}
local pendingFirsts: { [Player]: { [string]: any } } = {}
local FIRST_MERGE = 0.25 -- seconds a first waits for others from the same moment

-- DataStore keys are limited to 50 characters; recipe keys can be longer. Two 32-bit FNV hashes.
local function storeKey(recipeKey: string): string
	return string.format("r_%08x%08x", Seed.derive(0, recipeKey, "discovery:a"), Seed.derive(0, recipeKey, "discovery:b"))
end

local function tryWorldFirst(player: Player, stats: Types.SpellStats)
	local key = stats.key
	local hashKey = storeKey(key)
	if claimedCache[hashKey] then
		return
	end
	local userId = player.UserId
	local now = os.time()
	local record, reason = store:update(hashKey, function(r)
		if r.by ~= 0 then
			return nil -- someone got here first
		end
		r.key, r.by, r.t = key, userId, now
		return r
	end)
	claimedCache[hashKey] = true
	if not record or record.by ~= userId or record.key ~= key then
		if reason ~= "CANCELLED" and reason ~= nil then
			log:warn("world_first_claim_failed", { reason = reason })
		end
		return
	end

	local state = playerData:get(player)
	if not state then
		return
	end
	state.data.discoveries.worldFirsts[key] = now
	progression:awardDiscovery(player, stats.recipe.branch, stats.recipe.power, true)
	if flags.get("awakenings_enabled") then
		local result = InnateProfile.applyAwakening(state.innate, "epiphany", { now = now })
		if result.ok and #result.revealed > 0 then
			playerData:refreshCaster(player)
		end
	end
	Net.fire("ProgressionChanged", player, { { kind = "worldFirst", key = key } })
	world:recordEvent("world_first_recipe", { by = userId, branch = stats.recipe.branch, power = stats.recipe.power })
	log:info("world_first", { userId = userId, branch = stats.recipe.branch })
end

-- The first effective cast of this verb + property + form, at any power (Progression/Experiment).
-- Returns true when it was new.
local function noteNovelty(player: Player, state: any, stats: Types.SpellStats): boolean
	local d = state.data.discoveries
	d.novelty = d.novelty or {}
	local combo = Experiment.comboKey(stats.recipe)
	local found = d.noveltyCount or 0
	if d.novelty[combo] or found >= T.experimentation.noveltyCap then
		return false
	end
	d.novelty[combo] = 1
	d.noveltyCount = found + 1
	progression:awardExperiment(player, stats.recipe.branch, Experiment.noveltyXp(found))
	return true
end

--[[
	First-time flourishes (docs/EarlyGamePlan.md §9): the first blow you ever land, and the first
	effective cast of each verb and form, once per save. A spell's first hit and first cast arrive
	moments apart, so they wait FIRST_MERGE seconds and go out as one event: one toast, one stinger.
	Saved lazily in discoveries.firsts, filled from the old save on first use (Experiment.firstsFromSave).
	At most one entry per verb and form plus "damage", so it stays tiny.
]]
local function firstsOf(state: any): { [string]: number }
	local d = state.data.discoveries
	if not d.firsts then
		d.firsts = Experiment.firstsFromSave(d)
	end
	return d.firsts
end

local function queueFirst(player: Player, field: string, value: any)
	local pending = pendingFirsts[player]
	if pending then
		pending[field] = value
		return
	end
	pendingFirsts[player] = { kind = "first", [field] = value }
	task.delay(FIRST_MERGE, function()
		local event = pendingFirsts[player]
		pendingFirsts[player] = nil
		if event and player.Parent then
			Net.fire("ProgressionChanged", player, { event })
		end
	end)
end

-- Returns true when this cast opened a verb or form you'd never used.
local function noteFirstCast(player: Player, state: any, stats: Types.SpellStats): boolean
	local firsts = firstsOf(state)
	local now = os.time()
	local recipe = stats.recipe
	local any = false
	if not firsts["verb:" .. recipe.verb] then
		firsts["verb:" .. recipe.verb] = now
		queueFirst(player, "verb", recipe.verb)
		any = true
	end
	if not firsts["form:" .. recipe.form] then
		firsts["form:" .. recipe.form] = now
		queueFirst(player, "form", recipe.form)
		any = true
	end
	return any
end

-- Any damage you deal to anything but yourself: spells, blades, bows, burns, dummies, creatures.
local function onTargetDamaged(payload: any)
	local source = payload.sourceUserId
	local player = if source then Players:GetPlayerByUserId(source) else nil
	if not player or payload.model == player.Character then
		return
	end
	local state = playerData:get(player)
	if not state then
		return
	end
	local firsts = firstsOf(state)
	if not firsts.damage then
		firsts.damage = os.time()
		queueFirst(player, "damage", true)
		log:info("first_damage", { userId = source })
	end
end

function DiscoveryLog.recordCast(_self: any, player: Player, stats: Types.SpellStats, effective: boolean)
	if not effective then
		return
	end
	local state = playerData:get(player)
	if not state then
		return
	end
	local novel = noteNovelty(player, state, stats)
	-- A first says it better than the smaller toasts, so they stay quiet for this cast. Their XP stands.
	local first = noteFirstCast(player, state, stats)
	local recipes = state.data.discoveries.recipes
	if stats.recipe.power < T.experimentation.minPowerForCredit or recipes[stats.key] then
		-- Not a discovery. A new idea still gets its toast (a discovery would have said it instead).
		if novel and not first then
			Net.fire("ProgressionChanged", player, { { kind = "novelty", key = stats.key } })
		end
		return
	end
	recipes[stats.key] = os.time()
	progression:awardDiscovery(player, stats.recipe.branch, stats.recipe.power, false)
	if not first then
		Net.fire("ProgressionChanged", player, { { kind = "discovery", key = stats.key } })
	end
	task.spawn(tryWorldFirst, player, stats)
end

-- The first time you trigger each InteractionMatrix reaction. Only whoever cast the spell that set
-- it off. There are few results and each pays once, so this can't be farmed.
local function onReaction(payload: any)
	local player = if payload.owner then Players:GetPlayerByUserId(payload.owner) else nil
	local state = player and playerData:get(player)
	if not player or not state then
		return
	end
	local d = state.data.discoveries
	d.reactions = d.reactions or {}
	if d.reactions[payload.result] then
		return
	end
	d.reactions[payload.result] = os.time()
	if payload.branch then
		progression:awardExperiment(player, payload.branch, T.experimentation.reactionXp)
	end
	Net.fire("ProgressionChanged", player, { { kind = "reaction", result = payload.result, text = payload.description } })
	log:info("reaction_discovered", { userId = player.UserId, result = payload.result })
end

-- Guided's "Try something". Seeded per player, with a per-session counter so asking again moves on.
local function suggest(player: Player): { [string]: any }?
	local state = playerData:get(player)
	if not state then
		return nil
	end
	local n = (suggestCounts[player] or 0) + 1
	suggestCounts[player] = n
	local rng = Seed.random(world:getSeed(), "player:" .. player.UserId, "suggest", n)
	return Experiment.suggest(state.caster, state.data.discoveries.novelty or {}, rng)
end

function DiscoveryLog.declareSignature(_self: any, player: Player, recipeKey: string): (boolean, string?)
	local state = playerData:get(player)
	if not state then
		return false, "NOT_LOADED"
	end
	local S = T.signature
	local data = state.data
	local p = data.progression
	local entry = data.spellbook[recipeKey]
	if not data.discoveries.worldFirsts[recipeKey] then
		return false, "NOT_YOUR_INVENTION"
	elseif not entry then
		return false, "NOT_IN_SPELLBOOK"
	elseif entry.name == "" then
		return false, "NAME_IT_FIRST"
	elseif entry.casts < S.minCasts then
		return false, "NEEDS_MORE_PRACTICE"
	elseif p.signatures[recipeKey] then
		return false, "ALREADY_SIGNATURE"
	end
	local count = 0
	for _ in p.signatures do
		count += 1
	end
	if count >= S.maxSignatures then
		return false, "TOO_MANY_SIGNATURES"
	end
	if (Progression.getMasteryTier(p, entry.recipe.branch)) < S.minTier then
		return false, "NEEDS_EXPERT"
	end

	local now = os.time()
	p.signatures[recipeKey] = now
	entry.signature = true
	Progression.record(p, "paradigm", recipeKey, nil, now)
	playerData:refreshCaster(player)
	local name = spellbook:displayName(player, recipeKey) or "?"
	Net.fire("ProgressionChanged", player, { { kind = "signature", key = recipeKey, name = name } })
	world:recordEvent("signature_declared", { by = player.UserId, branch = entry.recipe.branch })
	return true, name
end

function DiscoveryLog.list(_self: any, player: Player): { { key: string, at: number, worldFirst: boolean } }
	local state = playerData:get(player)
	if not state then
		return {}
	end
	local out = {}
	local worldFirsts = state.data.discoveries.worldFirsts
	for key, at in state.data.discoveries.recipes do
		table.insert(out, { key = key, at = at, worldFirst = worldFirsts[key] ~= nil })
	end
	table.sort(out, function(a, b)
		return a.at < b.at
	end)
	return out
end

function DiscoveryLog.init(_self: any, ctx: any)
	log, flags = ctx.log, ctx.flags
	store = ctx.get("DataService"):openStore(Schemas.Discovery)
	playerData = ctx.get("PlayerDataService")
	progression = ctx.get("ProgressionService")
	world = ctx.get("WorldService")
	spellbook = ctx.get("SpellbookService")
	Net.handle("DeclareSignature", function(player: Player, recipeKey: string)
		return DiscoveryLog:declareSignature(player, recipeKey)
	end)
	Net.handle("SuggestSpell", suggest)
	ctx.bus:subscribe(Topics.MagicReaction, onReaction)
	ctx.bus:subscribe(Topics.TargetDamaged, onTargetDamaged)
	Players.PlayerRemoving:Connect(function(player)
		suggestCounts[player] = nil
	end)
end

return DiscoveryLog
