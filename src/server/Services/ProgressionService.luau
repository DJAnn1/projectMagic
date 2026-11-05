--!strict
--[[
	ProgressionService: the only place experience is awarded. Every channel is triggered by
	something the SERVER observed; no remote carries XP, mastery or "I did X" claims.

	Called by other systems:
		awardPractice(player, stats, { effective, challenge })   CastService, after a cast resolves
		awardStudy(player, branchId, sourceKind, sourceId, opts)  books, lectures, NPC/player mentors
		awardObservation(observer, casterKey, branchId, casterTier, power)  someone better cast nearby
		studyInsight(player, insightId, branchId?)               reached an insight site (one-time)
		awardDiscovery(player, branchId, power, worldFirst)      DiscoveryLog
		recordFact(player, kind, id, value?)                     catalysts, survivals, lore, feats...

	Remotes: RequestProgression, UnlockBranch, AttemptBreakthrough.
	Admin commands (test tools): xp, prog, grant, unlockbranch, breakthrough.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Registry = require(Shared.Magic.Registry)
local MagicCore = require(Shared.Magic.MagicCore)
local Types = require(Shared.Magic.Types)
local ProgressionFolder = script.Parent.Parent.Progression
local Progression = require(ProgressionFolder.Progression)
local SubBranchRules = require(ProgressionFolder.SubBranchRules)
local T = require(ProgressionFolder.ProgressionTuning)

local AIM_ACTIVE_DEGREES = 10
local MOVE_ACTIVE_STUDS = 4
local ACTIVITY_SAMPLE_SECONDS = 5

local ProgressionService = {
	name = "ProgressionService",
	dependencies = { "NetService", "PlayerDataService", "AdminService" },
}

local log: any = nil
local playerData: any = nil
local runtimes: { [Player]: Progression.Runtime } = {}
local lastAim: { [Player]: Vector3 } = {}
local lastPosition: { [Player]: Vector3 } = {}
local observeCooldowns: { [Player]: { [string]: number } } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function stateOf(player: Player): any
	return playerData:get(player)
end

local function runtimeOf(player: Player): Progression.Runtime
	local runtime = runtimes[player]
	if not runtime then
		runtime = Progression.newRuntime(now())
		runtimes[player] = runtime
	end
	return runtime
end

-- Rebuilds the caster and tells the client what changed.
local function afterChange(player: Player, events: { any })
	playerData:refreshCaster(player)
	if #events > 0 then
		Net.fire("ProgressionChanged", player, events)
	end
end

local function eventsFor(result: Progression.GainResult): { any }
	local events = {}
	if result.tierAfter > result.tierBefore then
		table.insert(events, { kind = "tier", branch = result.branch, tier = result.tierAfter, name = MagicCore.tierDef(result.tierAfter).name })
	end
	if result.held then
		table.insert(events, { kind = "held", branch = result.branch })
	end
	return events
end

local function gain(player: Player, branchId: string, channel: string, base: number, ctx: Progression.GainContext): Progression.GainResult?
	local state = stateOf(player)
	if not state then
		return nil
	end
	local result = Progression.addExperience(state.data.progression, state.innate, branchId, channel, base, ctx)
	if result.gained > 0 then
		afterChange(player, eventsFor(result))
	end
	return result
end

-- ─── Channels ───────────────────────────────────────────────────────────────

function ProgressionService.awardPractice(_self: any, player: Player, stats: Types.SpellStats, outcome: { effective: boolean, challenge: boolean? }): Progression.GainResult?
	local state = stateOf(player)
	if not state then
		return nil
	end
	local branchId = stats.recipe.branch
	local t = now()
	if outcome.effective then
		Progression.record(state.data.progression, if outcome.challenge then "challengeFeat" else "feat", branchId, stats.recipe.power, t)
	end
	return gain(player, branchId, if outcome.challenge then "challenge" else "practice", Progression.practiceXp(stats.cost), {
		now = t,
		runtime = runtimeOf(player),
		recipeKey = stats.key,
		power = stats.recipe.power,
		comfort = stats.comfortPower,
		effective = outcome.effective,
	})
end

--[[
	sourceKind: "scroll" | "book" | "lecture" | "mentor" (see ProgressionTuning.study)
	opts.mentorTier / opts.mentor: for mentors (an NPC passes only the tier; a player passes themselves)
	opts.lore: knowledge items this source teaches (e.g. "primer:metallurgy")
	Returns (result, nil) or (nil, reason).
]]
function ProgressionService.awardStudy(
	_self: any,
	player: Player,
	branchId: string,
	sourceKind: string,
	sourceId: string,
	opts: { mentorTier: number?, mentor: Player?, lore: { string }? }?
): (Progression.GainResult?, string?)
	local state = stateOf(player)
	local source = (T.study :: any)[sourceKind]
	if not state or not source then
		return nil, "INVALID"
	end
	local p = state.data.progression
	local o = opts or {}
	local t = now()
	local key = sourceKind .. ":" .. sourceId .. ":" .. branchId
	local last = p.studied[key]
	if last then
		if not source.cooldownHours then
			return nil, "ALREADY_STUDIED"
		elseif t - last < source.cooldownHours * 3600 then
			return nil, "ON_COOLDOWN"
		end
	end

	local base = source.xp
	local myTier = Progression.getMasteryTier(p, branchId)
	if sourceKind == "mentor" then
		local mentorTier = o.mentorTier or 0
		if mentorTier < myTier + T.study.minTierGap then
			return nil, "MENTOR_NOT_AHEAD"
		end
		base *= mentorTier - myTier
	end

	-- Knowledge is learned even when the branch itself is still locked (that's how you unlock it).
	for _, loreId in (o.lore or {}) :: { string } do
		Progression.record(p, "lore", loreId, nil, t)
	end
	p.studied[key] = t
	if not p.unlocked[branchId] then
		afterChange(player, { { kind = "lore", branch = branchId } })
		return nil, "LORE_ONLY"
	end

	local result = gain(player, branchId, "study", base, { now = t })
	if result and sourceKind == "mentor" then
		Progression.record(p, "mentor", branchId, o.mentorTier, t)
		local mentor = o.mentor
		if mentor and mentor ~= player then
			ProgressionService:awardTeaching(mentor, branchId, result)
		end
	end
	return result, nil
end

-- The teacher gets a share of what their student learned from them.
function ProgressionService.awardTeaching(_self: any, teacher: Player, branchId: string, studentResult: Progression.GainResult)
	local state = stateOf(teacher)
	if not state then
		return
	end
	local p = state.data.progression
	local teacherTier = Progression.getMasteryTier(p, branchId)
	if teacherTier < T.teaching.minTeacherTier or teacherTier < studentResult.tierAfter + T.teaching.minTierGap then
		return
	end
	local t = now()
	if studentResult.tierBefore < 2 and studentResult.tierAfter >= 2 then
		Progression.record(p, "taught", branchId, nil, t)
	end
	gain(teacher, branchId, "teaching", studentResult.gained * T.teaching.share, { now = t })
end

-- casterKey identifies the caster (UserId or NPC id) for the per-caster cooldown.
function ProgressionService.awardObservation(_self: any, observer: Player, casterKey: string, branchId: string, casterTier: number, power: number)
	local state = stateOf(observer)
	if not state or not state.data.progression.unlocked[branchId] then
		return
	end
	local p = state.data.progression
	local gap = casterTier - Progression.getMasteryTier(p, branchId)
	if gap <= 0 then
		return
	end
	local t = now()
	local cooldowns = observeCooldowns[observer] or {}
	observeCooldowns[observer] = cooldowns
	if cooldowns[casterKey] and t - cooldowns[casterKey] < T.observation.sameCasterCooldown then
		return
	end
	cooldowns[casterKey] = t
	gain(observer, branchId, "observation", T.observation.perTierGap * gap * power, { now = t, runtime = runtimeOf(observer) })
end

-- One-time study of an environmental insight site ("<domain>:<site>").
function ProgressionService.studyInsight(_self: any, player: Player, insightId: string, branchId: string?)
	local state = stateOf(player)
	if not state then
		return
	end
	local p = state.data.progression
	if p.records.insights[insightId] then
		return
	end
	local t = now()
	Progression.record(p, "insight", insightId, nil, t)
	local domain = string.match(insightId, "^(%a+):")
	local target = branchId or domain
	if target and p.unlocked[target] then
		gain(player, target, "observation", T.observation.insightSite, { now = t })
	end
	afterChange(player, { { kind = "insight", id = insightId } })
end

function ProgressionService.awardDiscovery(_self: any, player: Player, branchId: string, power: number, worldFirst: boolean)
	local state = stateOf(player)
	if not state then
		return
	end
	local E = T.experimentation
	local t = now()
	if not worldFirst then
		Progression.record(state.data.progression, "discovery", branchId, nil, t)
	end
	local base = if worldFirst then E.worldFirst else E.personalFirstBase + E.personalFirstPerPower * power
	gain(player, branchId, "experimentation", base, { now = t })
end

-- Called with the domains an awakening just opened (CantripService registers it: it depends on
-- us, so we can't require it).
local awakenHook: ((Player, { string }) -> ())? = nil

function ProgressionService.setAwakenHook(_self: any, hook: (Player, { string }) -> ())
	awakenHook = hook
end

-- Call after the innate profile changes (an awakening revealed a domain): unlocks its root.
function ProgressionService.syncInnate(_self: any, player: Player)
	local state = stateOf(player)
	if state then
		local added = Progression.ensureRoots(state.data.progression, state.innate)
		local events = {}
		for _, domainId in added do
			table.insert(events, { kind = "unlock", branch = domainId })
		end
		afterChange(player, events)
		if #added > 0 and awakenHook then
			task.spawn(awakenHook, player, added)
		end
	end
end

--[[
	A quest's reward (QuestDirector): `lore` items are learned (knowledge counts even for locked
	branches: that's how a treatise opens a sub-branch), and `amount` XP goes to `branchId` through
	the study channel (so daily caps and focus apply). Returns the gain, if any.
]]
function ProgressionService.awardQuest(_self: any, player: Player, branchId: string?, amount: number, lore: { string }?): Progression.GainResult?
	local state = stateOf(player)
	if not state then
		return nil
	end
	local p = state.data.progression
	local t = now()
	local events = {}
	for _, loreId in (lore or {}) :: { string } do
		if not p.lore[loreId] then
			Progression.record(p, "lore", loreId, nil, t)
			table.insert(events, { kind = "lore", lore = loreId })
		end
	end
	if #events > 0 then
		afterChange(player, events)
	end
	if branchId and amount > 0 and p.unlocked[branchId] then
		return gain(player, branchId, "study", amount, { now = t })
	end
	return nil
end

--[[
	A creature kill (CreatureService), through the challenge channel so the practice anti-grind
	applies: AFK earns nothing, the same creature type repeats out like the same recipe does
	("creature:<type>" as the recipe key), and a creature far below your power ceiling teaches little
	(`level` against MagicCore.powerCap). `amount` already carries the per-hour kill factor.
]]
function ProgressionService.awardCreatureKill(_self: any, player: Player, branchId: string, amount: number, creatureType: string, level: number): Progression.GainResult?
	local state = stateOf(player)
	if not state then
		return nil
	end
	return gain(player, branchId, "challenge", amount, {
		now = now(),
		runtime = runtimeOf(player),
		recipeKey = "creature:" .. creatureType,
		power = level,
		comfort = MagicCore.powerCap(state.caster, branchId),
		effective = true,
	})
end

function ProgressionService.recordFact(_self: any, player: Player, kind: string, id: string, value: number?)
	local state = stateOf(player)
	if state then
		Progression.record(state.data.progression, kind, id, value, now())
		afterChange(player, { { kind = "fact", fact = kind, id = id } })
	end
end

-- ─── Views ──────────────────────────────────────────────────────────────────

-- What the client may know about its own progression (no XP formulas, no other players).
local function viewFor(player: Player): any
	local state = stateOf(player)
	if not state then
		return nil
	end
	local p = state.data.progression
	local t = now()
	local branches = {}
	for branchId in p.unlocked do
		local tier, def = Progression.getMasteryTier(p, branchId)
		local nextDef = Registry.masteryTiers.tiers[tier + 2]
		local breakthroughTier, requirements = Progression.breakthroughStatus(p, branchId)
		table.insert(branches, {
			id = branchId,
			name = Registry.branches[branchId].name,
			mastery = p.mastery[branchId] or 0,
			xp = math.floor(p.xp[branchId] or 0),
			xpForNext = if nextDef then math.ceil(Progression.xpForMastery(nextDef.minMastery)) else nil,
			tier = tier,
			tierName = def.name,
			held = Progression.masteryForXp(p.xp[branchId] or 0) > (p.mastery[branchId] or 0) + 0.01,
			breakthrough = if breakthroughTier then { tier = breakthroughTier, requirements = requirements } else nil,
		})
	end
	table.sort(branches, function(a, b)
		return a.mastery > b.mastery
	end)

	-- Candidates: locked branches whose parent is unlocked, and hybrids whose domains are awake.
	local candidates = {}
	for _, branchId in Registry.branchIds do
		local branch = Registry.branches[branchId]
		if p.unlocked[branchId] or branch.isRoot then
			continue
		end
		local parentOpen = if branch.parent then p.unlocked[branch.parent] == true else true
		if parentOpen then
			local ok, checks = SubBranchRules.evaluate(p, state.innate, branchId)
			if branch.parent or checks[1] == nil or checks[1].met then
				table.insert(candidates, { id = branchId, name = branch.name, ready = ok, checks = checks })
			end
		end
	end

	local focus = {}
	for domainId in p.focus do
		focus[domainId] = math.floor(Progression.focusShare(p, domainId, t) * 100 + 0.5) / 100
	end

	return {
		branches = branches,
		candidates = candidates,
		commitments = p.commitments,
		focus = focus,
		activeLines = Progression.activeLines(p),
		breadthMultiplier = Progression.breadthMultiplier(p),
	}
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function onDataLoaded(payload: any)
	local player: Player = payload.player
	local state = stateOf(player)
	if not state then
		return
	end
	local p = state.data.progression
	Progression.ensureRoots(p, state.innate)
	for branchId in p.xp do
		Progression.recompute(p, branchId) -- applies curve or breakthrough changes from new releases
	end
	runtimeOf(player)
	playerData:refreshCaster(player)
end

local function registerAdminCommands(admin: any)
	admin:Register({
		name = "xp", category = "Magic", description = "Award XP through the normal multipliers (focus, breadth, anti-grind)",
		args = {
			{ name = "branch", type = "branch" },
			{ name = "amount", type = "number", min = 1, max = 1000000 },
			{ name = "channel", type = "enum", options = { "practice", "study", "observation", "teaching", "discovery", "insight" }, default = "study" },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local player: Player = a.player
			local result = gain(player, a.branch, a.channel, a.amount, { now = now(), runtime = runtimeOf(player) })
			if not result then
				return "player not loaded"
			end
			local parts = {}
			for name, value in result.factors do
				table.insert(parts, string.format("%s=%.2f", name, value))
			end
			table.sort(parts)
			return string.format("%s +%.1f XP (%s) mastery %.2f -> %.2f%s%s", a.branch, result.gained, table.concat(parts, " "),
				result.masteryBefore, result.masteryAfter, if result.held then " [held: breakthrough needed]" else "",
				if result.reason then " reason=" .. result.reason else "")
		end,
	})

	admin:Register({
		name = "prog", category = "Magic", description = "Progression summary",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local view = viewFor(a.player)
			if not view then
				return "player not loaded"
			end
			local lines = { string.format("active lines %d, breadth x%.2f", view.activeLines, view.breadthMultiplier) }
			for _, b in view.branches do
				local bt = ""
				if b.breakthrough then
					local met = 0
					for _, r in b.breakthrough.requirements do
						met += if r.met then 1 else 0
					end
					bt = string.format(" | next breakthrough: %s (%d/%d met)", MagicCore.tierDef(b.breakthrough.tier).name, met, #b.breakthrough.requirements)
				end
				table.insert(lines, string.format("%s: %s %.2f (%d xp)%s%s", b.name, b.tierName, b.mastery, b.xp, if b.held then " HELD" else "", bt))
			end
			for _, c in view.candidates do
				if c.ready then
					table.insert(lines, "can unlock: " .. c.name)
				end
			end
			return table.concat(lines, "\n")
		end,
	})

	admin:Register({
		name = "grant", category = "Magic", description = "Record a progression fact (lore, catalyst, insight, survived...)",
		args = {
			{ name = "kind", type = "enum", options = { "lore", "catalyst", "insight", "survived", "feat", "location" } },
			{ name = "id", type = "string" },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			if a.kind == "insight" then
				ProgressionService:studyInsight(a.player, a.id)
			else
				ProgressionService:recordFact(a.player, a.kind, a.id)
			end
			return "recorded " .. a.kind .. " " .. a.id
		end,
	})

	admin:Register({
		name = "unlockbranch", category = "Magic", description = "Try to unlock a branch by the normal rules (shows unmet conditions)",
		args = { { name = "branch", type = "branch" }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local player: Player = a.player
			local state = stateOf(player)
			if not state then
				return "player not loaded"
			end
			local ok, checks = Progression.unlock(state.data.progression, state.innate, a.branch, now())
			if ok then
				afterChange(player, { { kind = "unlock", branch = a.branch } })
				return "unlocked " .. a.branch
			end
			local lines = { "locked:" }
			for _, c in checks do
				table.insert(lines, (if c.met then "  [x] " else "  [ ] ") .. c.text)
			end
			return table.concat(lines, "\n")
		end,
	})

	admin:Register({
		name = "breakthrough", category = "Magic", description = "Attempt the next breakthrough by the normal rules",
		args = { { name = "branch", type = "branch" }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local player: Player = a.player
			local state = stateOf(player)
			if not state then
				return "player not loaded"
			end
			local ok, reason = Progression.tryBreakthrough(state.data.progression, a.branch, now())
			if ok then
				afterChange(player, { { kind = "breakthrough", branch = a.branch } })
				return "breakthrough complete"
			end
			return "failed: " .. tostring(reason)
		end,
	})
end

-- Admin tools (Server/Admin/Commands/Magic) notify the client the same way normal play does.
function ProgressionService.notify(_self: any, player: Player, events: { any })
	afterChange(player, events)
end

function ProgressionService.init(_self: any, ctx: any)
	log = ctx.log
	playerData = ctx.get("PlayerDataService")
	registerAdminCommands(ctx.get("AdminService"))

	Net.handle("RequestProgression", function(player: Player)
		return viewFor(player)
	end)

	Net.handle("UnlockBranch", function(player: Player, branchId: string)
		local state = stateOf(player)
		if not state or not Registry.branches[branchId] then
			return false, "INVALID"
		end
		local ok, checks = Progression.unlock(state.data.progression, state.innate, branchId, now())
		if ok then
			afterChange(player, { { kind = "unlock", branch = branchId } })
			log:info("branch_unlocked", { userId = player.UserId, branch = branchId })
		end
		return ok, checks
	end)

	Net.handle("AttemptBreakthrough", function(player: Player, branchId: string)
		local state = stateOf(player)
		if not state or not Registry.branches[branchId] then
			return false, "INVALID"
		end
		local ok, reason = Progression.tryBreakthrough(state.data.progression, branchId, now())
		if ok then
			afterChange(player, { { kind = "breakthrough", branch = branchId } })
			log:info("breakthrough", { userId = player.UserId, branch = branchId })
		end
		return ok, reason
	end)

	-- Aim changes count as activity (AFK detection).
	Net.on("AimUpdate", function(player: Player, aim: Vector3)
		local previous = lastAim[player]
		lastAim[player] = aim
		if previous and previous.Magnitude > 0 and aim.Magnitude > 0 then
			local cos = math.clamp(previous.Unit:Dot(aim.Unit), -1, 1)
			if math.deg(math.acos(cos)) >= AIM_ACTIVE_DEGREES then
				runtimeOf(player).lastActiveAt = now()
			end
		end
	end)

	ctx.bus:subscribe(Topics.PlayerDataLoaded, onDataLoaded)
end

function ProgressionService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		runtimes[player] = nil
		lastAim[player] = nil
		lastPosition[player] = nil
		observeCooldowns[player] = nil
	end)

	-- Movement counts as activity.
	while true do
		task.wait(ACTIVITY_SAMPLE_SECONDS)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				local previous = lastPosition[player]
				lastPosition[player] = root.Position
				if previous and (root.Position - previous).Magnitude >= MOVE_ACTIVE_STUDS then
					runtimeOf(player).lastActiveAt = now()
				end
			end
		end
	end
end

return ProgressionService
