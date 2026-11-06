--!strict
--[[
	QuestDirector: turns the living world into quests, paces them per player, runs them, and
	writes their consequences back into the world (docs/Quests.md).

	LOOPS
		scan      every scanSeconds (a Scheduler job): SituationDetector.scanWorld -> `situations`
		          (merged by id; vanished world situations age out). Crisis situations whose
		          template is `shared` become SHARED quests at once: everyone nearby can help.
		director  per player every directorSeconds (staggered): tension decay, expiry, escalation,
		          complications, then maybe one new OFFER (see SCORING) and autoStart quests
		poll      every pollSeconds: position objectives (reach, collect, escort, witness, unseen),
		          state predicates, leashes and wards on quest NPCs
		hourly    on each new game hour (WorldClock): NPCs may solve open quests (npcSolve)
	EVENTS
		SpellResolved  cast / demonstrate objectives (with creative recognition, Quests/Objectives)
		NpcTalked      talk / deliver / pay objectives; the "quest" topic accepts an NPC's offer
		TargetDamaged  subdue objectives (a duelling NPC yields at its share), protected NPCs
		Humanoid.Died  a stage's failOnDeath (lost duels)

	SCORING an offer (QuestTuning):
		weight x focus x novelty x pacing x power x distance (x 0 when requirements or cooldown fail)
		focus     focusFloor + focusBoost x (your recent XP share in the template's domains),
		          never 0, so a metal mage sees mostly forge work, but not only
		novelty   noveltyBase ^ (times you did this template among your last 10) x
		          noveltyTypeBase ^ (recent quests of the same type)
		pacing    the template's intensity against the phase's wanted intensity: calm (tension
		          < 0.25) wants quiet quests, rising wants more, peak wants set pieces
		power     1 inside the template's tier band, falling off outside it
	The pick is a seeded weighted draw: Seed.random(worldSeed, "player:<id>", "director", n).

	PERSISTENCE: personal quests live in PlayerData.quests (active, offers, finished, history,
	recent, tension, followUps) and travel with the player across servers. Shared quests are this
	server's (like world events): they end when the server does, and contributors are rewarded
	when they complete.
	Admin: quests, questgen, questcomplete, questfail, queststage, questsituation, situations.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local Registry = require(Shared.Magic.Registry)

local Server = script.Parent.Parent
local Scheduler = require(Server.Core.Scheduler)
local WorldClock = require(Server.NPC.WorldClock)
local NPCCombat = require(Server.NPC.NPCCombat)
local InnateProfile = require(Server.Magic.InnateProfile)
local Progression = require(Server.Progression.Progression)
local QuestTypes = require(Server.Quests.QuestTypes)
local QuestTemplates = require(Server.Quests.Data.QuestTemplates)
local Q = require(Server.Quests.Data.QuestTuning)
local SituationDetector = require(Server.Quests.SituationDetector)
local QuestFactory = require(Server.Quests.QuestFactory)
local NPCMagicLife = require(Server.NPC.NPCMagicLife)
local Objectives = require(Server.Quests.Objectives)

type QuestState = QuestTypes.QuestState
type Template = QuestTypes.Template
type Situation = QuestTypes.Situation

local T = QuestTemplates.byId
local MYTHIC_AWAKENING: { [string]: string } = { time = "meetingYourself", gravity = "theLongFall", reality = "witnessParadox" }
local FINISHED_CAP = 30
local MAX_SHARED = 6

local QuestDirector = {
	name = "QuestDirector",
	dependencies = {
		"NetService", "PlayerDataService", "WorldStateService", "WorldService", "EventDirector", "NPCService",
		"ProgressionService", "ReputationService", "FactionService", "JournalService", "AdminService",
		"InventoryService", "PartyService", "PartyLootService",
	},
}

local log: any = nil
local bus: any = nil
local flags: any = nil
local playerData: any = nil
local world: any = nil
local worldService: any = nil
local events: any = nil
local npcs: any = nil
local progression: any = nil
local inventory: any = nil -- InventoryService
local reputation: any = nil
local factions: any = nil
local journal: any = nil
local parties: any = nil -- PartyService
local partyLoot: any = nil -- PartyLootService
local worldSeed = 0

local situations: { [string]: Situation } = {}
local shared: { [string]: QuestState } = {}
local directorCount: { [Player]: number } = {}
local noticeTime: { [string]: number } = {} -- quest id -> seconds noticed
local spawned: { [string]: { any } } = {} -- quest id -> NPCs made for it
local sharedEnded: { [string]: number } = {} -- shared quest id -> os.time() it ended (re-offer cooldown)

-- ─── Small helpers ──────────────────────────────────────────────────────────

local function enabled(): boolean
	return flags.get("quests_enabled") ~= false
end

local function rootOf(player: Player): BasePart?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function questsOf(player: Player): any?
	local state = playerData:get(player)
	if not state then
		return nil
	end
	local q = state.data.quests
	if typeof(q) ~= "table" then
		q = {}
		state.data.quests = q
	end
	q.active = q.active or {}
	q.offers = q.offers or {}
	q.finished = q.finished or {}
	q.history = q.history or {}
	q.recent = q.recent or {}
	q.tension = q.tension or { v = 0, t = os.time() }
	q.followUps = q.followUps or {}
	return q
end

local function tensionOf(q: any): number
	local minutes = math.max(0, os.time() - q.tension.t) / 60
	return math.clamp(q.tension.v - Q.tension.decayPerMinute * minutes, 0, 1)
end

local function addTension(player: Player, amount: number)
	local q = questsOf(player)
	if q then
		q.tension = { v = math.clamp(tensionOf(q) + amount, 0, 1), t = os.time() }
	end
end

local function phaseOf(tension: number): any
	for _, phase in Q.phases do
		if tension <= phase.max then
			return phase
		end
	end
	return Q.phases[#Q.phases]
end

local function stageOf(template: Template, id: string): QuestTypes.Stage?
	for _, stage in template.stages do
		if stage.id == id then
			return stage
		end
	end
	return nil
end

local function npcOf(quest: QuestState, slot: string?): any?
	return slot and npcs:get(quest.slots[slot])
end

local function settlementName(id: string?): string
	for _, s in world:placement().settlements do
		if s.id == id then
			return s.name
		end
	end
	return "somewhere"
end

-- Everyone a quest concerns: its owner, or (shared) anyone within reach of it.
local function playersOf(quest: QuestState): { Player }
	if quest.owner then
		local p = Players:GetPlayerByUserId(quest.owner)
		return if p then { p } else {}
	end
	local out = {}
	local s = situations[quest.situation]
	for _, p in Players:GetPlayers() do
		local root = rootOf(p)
		if root and s and (Vector3.new(s.x, root.Position.Y, s.z) - root.Position).Magnitude <= Q.offerRadius then
			table.insert(out, p)
		end
	end
	return out
end

--[[
	Can a party member help with this personal quest? Not a first-hour quest (a veteran friend doing
	your tutorial teaches you nothing), and not one that starts by itself because someone is hunting
	you. Everything else: your party can advance it (docs/Social.md §3).
]]
local function sharesWithParty(quest: QuestState): boolean
	local template = T[quest.template]
	return template ~= nil and template.scope ~= "shared" and not template.beginner and not template.autoStart
end

-- Every active quest a player can make progress on: their own, their party's, and shared ones near them.
local function activeFor(player: Player): { QuestState }
	local out: { QuestState } = {}
	local q = questsOf(player)
	if q then
		for _, quest in q.active do
			table.insert(out, quest)
		end
	end
	for _, mate in parties:matesOf(player) do
		local theirs = questsOf(mate)
		for _, quest in (if theirs then theirs.active else {}) :: { [string]: QuestState } do
			if sharesWithParty(quest) then
				table.insert(out, quest)
			end
		end
	end
	local root = rootOf(player)
	for _, quest in shared do
		local s = situations[quest.situation]
		if root and s and (Vector3.new(s.x, root.Position.Y, s.z) - root.Position).Magnitude <= Q.offerRadius then
			table.insert(out, quest)
		end
	end
	return out
end

-- ─── Requirements ───────────────────────────────────────────────────────────

local function bestTier(state: any): number
	local best = 0
	for branchId in state.data.progression.unlocked do
		local tier = Progression.getMasteryTier(state.data.progression, branchId) -- (tier, def): keep only the tier
		best = math.max(best, tier)
	end
	return best
end

local function meets(player: Player, state: any, req: QuestTypes.Requirement?): boolean
	if not req then
		return true
	end
	if req.domains then
		local any = false
		for _, d in req.domains do
			if (state.innate and state.innate.awakened and state.innate.awakened[d]) or state.data.progression.unlocked[d] then
				any = true
			end
		end
		if not any then
			return false
		end
	end
	if req.minTier and bestTier(state) < req.minTier then
		return false
	end
	if req.maxTier and bestTier(state) > req.maxTier then
		return false
	end
	for _, loreId in (req.lore or {}) :: { string } do
		if not state.data.progression.lore[loreId] then
			return false
		end
	end
	if req.currency and (state.data.inventory.currency or 0) < req.currency then
		return false
	end
	for factionId, min in (req.reputation or {}) :: { [string]: number } do
		if reputation:standing(player, factionId) < min then
			return false
		end
	end
	return true
end

-- ─── World consequences ─────────────────────────────────────────────────────

local function situationPosition(quest: QuestState): Vector3?
	local s = situations[quest.situation]
	return if s then Vector3.new(s.x, 0, s.z) else nil
end

--[[
	Applies an outcome's `world` table. Every key is optional:
		relief (domain)   ends the situation's event through EventDirector relief
		endEvent          stops the situation's event
		startEvent        starts that event at the situation
		prosperity, ore   the settlement's prosperity delta (ore folds into prosperity)
		stress            tectonic stress at the situation (+ adds, - releases)
		density           a day of ambient density boost at the settlement
		relation          relation drift between the quest's two settlements
		npcMastery        { npc = slot, branch = slot|id, delta } raise an NPC's mastery
		awakenNpc         slot: an NPC awakens (their hidden latents, if any)
		revealFaction     id: the owner learns of a secret faction
		clearBounty       the owner's bounty in the quest's settlement is lifted
		notoriety         the owner's mythic notoriety (quest domain slot "mythic") +/-
]]
local function applyWorld(quest: QuestState, spec: { [string]: any }, owner: Player?)
	local s = situations[quest.situation]
	local settlementId = quest.slots.town or (s and s.settlementId)
	local eventId = s and s.facts.eventId
	if (spec.relief or spec.endEvent) and eventId then
		pcall(events.stopEvent, events, eventId, "quest")
	end
	if spec.startEvent and s then
		pcall(events.startEvent, events, spec.startEvent, s.x, s.z)
	end
	local prosperity = (spec.prosperity or 0) + (spec.ore or 0) * 5
	if prosperity ~= 0 and settlementId then
		world:addSettlementDelta("prosperity", settlementId, prosperity)
	end
	if spec.stress and s then
		if spec.stress > 0 then
			world:addStress(s.x, s.z, spec.stress)
		else
			world:releaseStress(s.x, s.z, -spec.stress)
		end
	end
	if spec.density and settlementId and s then
		world:addModifier({
			id = "quest:" .. quest.id, x = s.x, z = s.z, radius = 500, density = 1 + spec.density,
			expiresAt = os.time() + 86400,
		})
	end
	if spec.relation and quest.slots.town and quest.slots.other then
		local a, b = quest.slots.town, quest.slots.other
		world:addSettlementDelta("relations", if a < b then a .. "|" .. b else b .. "|" .. a, spec.relation)
	end
	local nm = spec.npcMastery
	if nm then
		local npc = npcOf(quest, nm.npc)
		local branch = quest.slots[nm.branch] or nm.branch
		if npc and typeof(branch) == "string" and Registry.branches[branch] then
			npcs:setMastery(npc, branch, (npc.magic.mastery[branch] or 0) + nm.delta)
		end
	end
	if spec.awakenNpc then
		local npc = npcOf(quest, spec.awakenNpc)
		if npc then
			npcs:awaken(npc, "a teacher's patience")
		end
	end
	if owner then
		if spec.revealFaction then
			local data = require(Server.Quests.Data.Factions).factions[spec.revealFaction]
			journal:reveal(owner, spec.revealFaction, data and data.name)
		end
		if spec.clearBounty and settlementId then
			reputation:clearBounty(owner, settlementId)
		end
		if spec.notoriety and typeof(quest.slots.mythic) == "string" then
			reputation:addNotoriety(owner, quest.slots.mythic, spec.notoriety)
		end
	end
end

-- ─── Rewards ────────────────────────────────────────────────────────────────

local function bestBranchIn(state: any, domain: string): string?
	local p = state.data.progression
	local best, bestXp = nil, -1
	for branchId in p.unlocked do
		local def = Registry.branches[branchId]
		if def and (domain == "any" or table.find(def.domains, domain)) then
			local xp = p.xp[branchId] or 0
			if xp > bestXp then
				best, bestXp = branchId, xp
			end
		end
	end
	return best
end

local function giveRewards(player: Player, quest: QuestState, rewards: QuestTypes.Rewards, share: number)
	local state = playerData:get(player)
	if not state then
		return
	end
	-- Knowledge and XP
	local lore: { string } = {}
	for _, id in (rewards.lore or {}) :: { string } do
		table.insert(lore, QuestFactory.fill(quest, id))
	end
	local branch: string? = nil
	local amount = 0
	if rewards.xp then
		amount = rewards.xp.amount * share
		local b = QuestFactory.fill(quest, rewards.xp.branch)
		local domain = string.match(b, "^best:(.+)$")
		branch = if domain then bestBranchIn(state, domain) else (quest.slots[b] or b)
	end
	if #lore > 0 or (branch and amount > 0) then
		progression:awardQuest(player, branch, amount, lore)
	end
	-- Currency (never below zero), through the inventory so it's logged and the owner sees it
	if rewards.currency then
		local delta = math.floor(rewards.currency * (if rewards.currency > 0 then share else 1))
		inventory:addCurrency(player, math.max(delta, -inventory:currency(player)), "quest " .. quest.template)
	end
	-- Reputation
	for key, delta in (rewards.reputation or {}) :: { [string]: number } do
		if key == "settlement" then
			local s = situations[quest.situation]
			local id = quest.slots.town or (s and s.settlementId)
			if id then
				reputation:addSettlement(player, id, delta * share, "quest")
			end
		else
			reputation:addStanding(player, key, delta * share, T[quest.template].title)
		end
	end
	if rewards.infamy then
		reputation:addInfamy(player, rewards.infamy, T[quest.template].title)
	end
	-- A lesson: mentor-channel study XP in your best branch (its own cooldown per mentor and branch).
	if rewards.study then
		local npc = npcOf(quest, rewards.study.npc)
		local best = bestBranchIn(state, "any")
		if npc and best then
			local mentorTier = 1
			if npc.magic then
				local _, _, tier = NPCMagicLife.best(npc)
				mentorTier = tier
			end
			progression:awardStudy(player, best, rewards.study.kind, npc.id, { mentorTier = mentorTier })
		end
	end
	if rewards.bounty then
		local id = quest.slots.town
		if id then
			reputation:addBounty(player, id, rewards.bounty.amount, rewards.bounty.faction, T[quest.template].title)
		end
	end
	-- Awakening roll: seeded per quest, so it can't be rerolled by abandoning and retrying.
	if rewards.awakening and flags.get("awakenings_enabled") ~= false then
		local domain = QuestFactory.fill(quest, rewards.awakening.domain)
		local event = MYTHIC_AWAKENING[domain]
		if event and Seed.random(worldSeed, quest.id, "awakening"):NextNumber() < rewards.awakening.chance then
			local result = InnateProfile.applyAwakening(state.innate, event, { now = os.time() })
			if result.ok then
				progression:syncInnate(player)
				playerData:refreshCaster(player)
				if #result.revealed > 0 then
					journal:log(player, "discovery", "Something old in you stirs.", { questId = quest.id })
				end
			end
		end
	end
end

-- ─── Leashes, wards and spawns ──────────────────────────────────────────────

local function release(quest: QuestState)
	local template = T[quest.template]
	for slot in (template.holds or {}) :: { [string]: string } do
		local npc = npcOf(quest, slot)
		if npc and npc.leash then
			npcs:setLeash(npc, nil)
		end
	end
	for _, slot in (template.protect or {}) :: { string } do
		local npc = npcOf(quest, slot)
		if npc then
			if npc.leash then
				npcs:setLeash(npc, nil)
			end
			if npc.rig then
				npc.rig.humanoid:SetAttribute("QuestWard", nil)
			end
		end
	end
	for name in quest.slots do
		local npc = npcs:get(quest.slots[name])
		if npc and npc.rig and npc.rig.humanoid:GetAttribute("QuestSanction") == quest.owner then
			npc.rig.humanoid:SetAttribute("QuestSanction", nil)
		end
		if npc and npc.leash and npc.leash.userId == quest.owner then
			npcs:setLeash(npc, nil)
		end
	end
	for _, npc in (spawned[quest.id] or {}) :: { any } do
		NPCCombat.disengage(npc)
		pcall(npcs.remove, npcs, npc)
	end
	spawned[quest.id] = nil
	noticeTime[quest.id] = nil
end

local function spawnFor(quest: QuestState, player: Player?)
	local template = T[quest.template]
	if not template.spawns then
		return
	end
	local root = player and rootOf(player)
	local list = {}
	for slot, spec in template.spawns do
		local at = if root then root.Position + Vector3.new(18, 0, 10) else (situationPosition(quest) or Vector3.zero)
		local npc = npcs:spawn(at, { occupation = spec.occupation or "hunter", faction = spec.faction, mastery = { energy = 45, earth = 30 } })
		if npc then
			quest.slots[slot] = npc.id
			quest.names[slot] = npc.name
			table.insert(list, npc)
		end
	end
	spawned[quest.id] = list
end

-- ─── Lifecycle of a quest ───────────────────────────────────────────────────

local finish: (QuestState, string, string?) -> ()

local function enterStage(quest: QuestState, stageId: string)
	local template = T[quest.template]
	local stage = stageOf(template, stageId)
	if not stage then
		return
	end
	quest.stage = stageId
	quest.progress = {}
	quest.stageDeadline = if stage.hours then WorldClock.now() + stage.hours / 24 else nil
	bus:publish(Topics.QuestAdvanced, { questId = quest.id, stage = stageId })
	for _, player in playersOf(quest) do
		journal:log(player, "quest", QuestFactory.text(quest, stage.text), { questId = quest.id })
	end
	-- The party follows along too (their journal, not a toast per step of someone else's story).
	if quest.owner and sharesWithParty(quest) then
		for _, mate in parties:matesOfUser(quest.owner) do
			journal:log(mate, "quest", QuestFactory.text(quest, stage.text), { questId = quest.id })
		end
	end
end

local function start(quest: QuestState, player: Player?)
	local template = T[quest.template]
	quest.status = "active"
	-- Your newest quest is tracked (its pin gets the arrow) unless you're already tracking one.
	local q = player and quest.owner and questsOf(player)
	if q then
		local tracking = false
		for _, other in q.active do
			tracking = tracking or (other ~= quest and other.tracked == true)
		end
		quest.tracked = not tracking
	end
	quest.startedAt = os.time()
	quest.deadline = WorldClock.now() + template.expireHours / 24
	spawnFor(quest, player)
	-- Holds: the NPC is where the story says it is.
	for slot, posSlot in (template.holds or {}) :: { [string]: string } do
		local npc = npcOf(quest, slot)
		local at = QuestFactory.position(quest, posSlot)
		if npc and at then
			npcs:setLeash(npc, { kind = "hold", position = at })
		end
	end
	enterStage(quest, template.stages[1].id)
	bus:publish(Topics.QuestStarted, { player = player, questId = quest.id, template = template.id, scope = template.scope })
	log:info("quest_started", { quest = quest.id, userId = if player then player.UserId else nil })
end

-- Moves to the next stage or finishes, when an option is complete.
local function checkOptions(quest: QuestState)
	if quest.status ~= "active" then
		return
	end
	local template = T[quest.template]
	local stage = stageOf(template, quest.stage)
	if not stage then
		return
	end
	for _, option in stage.options do
		if Objectives.optionDone(option, quest.progress) then
			if option.outcome then
				finish(quest, option.outcome, nil)
			elseif option.next then
				enterStage(quest, option.next)
			end
			return
		end
	end
end

local function addProgress(quest: QuestState, optionId: string, spec: QuestTypes.ObjectiveSpec, gain: number, contributor: Player?, creative: boolean)
	if gain <= 0 then
		return
	end
	local key = Objectives.key(optionId, spec.id)
	local required = Objectives.required(spec)
	local before = quest.progress[key] or 0
	quest.progress[key] = math.min(required, before + gain)
	if creative and not table.find(quest.creative, key) then
		table.insert(quest.creative, key)
		if contributor then
			journal:log(contributor, "quest", "A creative solution: the world took your magic in a way nobody planned.", { questId = quest.id })
		end
	end
	if contributor and quest.contributors then
		local id = tostring(contributor.UserId)
		quest.contributors[id] = (quest.contributors[id] or 0) + gain
	end
	if contributor and quest.owner and contributor.UserId ~= quest.owner then
		local helpers = quest.helpers or {}
		helpers[tostring(contributor.UserId)] = true
		quest.helpers = helpers
	end
	if quest.progress[key] >= required and before < required and contributor then
		journal:log(contributor, "quest", "Done: " .. QuestFactory.text(quest, spec.text), { questId = quest.id })
	end
	checkOptions(quest)
end

-- This quest's item drop. `salt` separates one person's roll from another's; the quest id means
-- abandoning and retrying rolls the same thing. `chanceMult` scales every chance.
local function rollQuestLoot(quest: QuestState, template: Template, salt: number, chanceMult: number): { { item: string, n: number } }
	local out: { { item: string, n: number } } = {}
	local tableFor = Q.loot[template.type]
	if tableFor == nil then
		tableFor = Q.loot.default
	end
	if not tableFor then
		return out
	end
	local rng = Seed.random(worldSeed, quest.id, "quest_loot", math.abs(salt))
	for _, entry in tableFor :: { any } do
		local roll, amount = rng:NextNumber(), rng:NextInteger(entry.min, entry.max)
		if roll < entry.chance * chanceMult then
			table.insert(out, { item = entry.item, n = amount })
		end
	end
	return out
end

local function giveLoot(player: Player, items: { { item: string, n: number } }, source: string)
	for _, entry in items do
		inventory:give(player, entry.item, entry.n)
	end
	if #items > 0 then
		log:info("quest_loot", { userId = player.UserId, items = #items, source = source })
	end
end

--[[
	The owner's party when their quest succeeds. A member counts if they advanced it or were near the
	owner at the end (a healer never ticks an objective, and still helped). They get a share of the
	good parts only: XP in their OWN best branch, coins, standing gained and item drops (by the
	party's loot mode). Never fines, infamy, bounties, lore, lessons, awakenings, follow-ups or the
	quest's own NPC bond: those belong to the person whose story it is. Being in a party when a quest
	fails costs you nothing. Returns the members who counted.
]]
local function rewardHelpers(quest: QuestState, template: Template, outcome: any, outcomeId: string, text: string): { Player }
	local owner = quest.owner
	local counted: { Player } = {}
	if not owner or not sharesWithParty(quest) then
		return counted
	end
	local ownerPlayer = Players:GetPlayerByUserId(owner)
	local ownerRoot = ownerPlayer and rootOf(ownerPlayer)
	local rewards = outcome.rewards
	for _, mate in parties:matesOfUser(owner) do
		local root = rootOf(mate)
		local near = ownerRoot ~= nil and root ~= nil and (ownerRoot.Position - root.Position).Magnitude <= Q.party.assistRadius
		local helped = quest.helpers ~= nil and quest.helpers[tostring(mate.UserId)] == true
		if helped or near then
			if rewards then
				local gains: { [string]: number } = {}
				for key, delta in (rewards.reputation or {}) :: { [string]: number } do
					if delta > 0 then
						gains[key] = delta
					end
				end
				giveRewards(mate, quest, {
					xp = if rewards.xp then { branch = "best:any", amount = rewards.xp.amount } else nil,
					currency = if rewards.currency and rewards.currency > 0 then rewards.currency else nil,
					reputation = gains,
				} :: any, Q.party.helperShare)
			end
			factions:deed(mate, "quest_helped", situationPosition(quest), { magnitude = 0.25 })
			journal:log(mate, "outcome", text, { questId = quest.id })
			local q = questsOf(mate)
			if q then
				table.insert(q.finished, {
					id = quest.id, template = template.id, title = QuestFactory.text(quest, template.title),
					outcome = outcomeId, text = text, success = true, t = os.time(), creative = #quest.creative > 0, helped = true,
				})
				while #q.finished > FINISHED_CAP do
					table.remove(q.finished, 1)
				end
			end
			table.insert(counted, mate)
			log:info("quest_helped", { quest = quest.id, userId = mate.UserId })
		end
	end
	return counted
end

-- Item drops for a personal quest that succeeded: the owner's roll, shared by the party's loot mode.
local function dropPersonalLoot(quest: QuestState, template: Template, helpers: { Player })
	local owner = quest.owner
	local ownerPlayer = owner and Players:GetPlayerByUserId(owner)
	if not owner then
		return
	end
	local source = "quest " .. quest.template
	if #helpers > 0 and partyLoot:modeOf(owner) ~= "free_for_all" then
		local members: { Player } = table.clone(helpers)
		if ownerPlayer then
			table.insert(members, 1, ownerPlayer)
		end
		-- One roll for the group, a little richer for having helped each other.
		local items = rollQuestLoot(quest, template, 0, 1 + Q.party.helperShare * #helpers)
		partyLoot:pool(owner, members, items, 0, source)
		return
	end
	if ownerPlayer then
		giveLoot(ownerPlayer, rollQuestLoot(quest, template, 0, 1), source)
	end
	for _, helper in helpers do
		giveLoot(helper, rollQuestLoot(quest, template, helper.UserId, Q.party.helperShare), source)
	end
end

finish = function(quest: QuestState, outcomeId: string, reason: string?)
	if quest.status ~= "active" and quest.status ~= "offered" then
		return
	end
	local template = T[quest.template]
	local outcome = template.outcomes[outcomeId] or template.outcomes[template.failOutcome]
	quest.outcome = outcomeId
	quest.status = if outcome.success then "completed" elseif reason == "npc" then "solved_by_others" elseif reason == "expired" then "expired" else "failed"
	local text = QuestFactory.text(quest, outcome.text)

	-- Who is rewarded: the owner, or shared contributors above contributionMin of the top one.
	local recipients: { { player: Player, share: number } } = {}
	if quest.owner then
		local p = Players:GetPlayerByUserId(quest.owner)
		if p then
			table.insert(recipients, { player = p, share = 1 })
		end
	elseif quest.contributors then
		local top = 0
		for _, v in quest.contributors do
			top = math.max(top, v)
		end
		for id, v in quest.contributors do
			local p = Players:GetPlayerByUserId(tonumber(id) or 0)
			if p and top > 0 and v >= top * Q.contributionMin then
				table.insert(recipients, { player = p, share = math.clamp(v / top, 0.4, 1) })
			end
		end
		-- A party in a crisis together shares in it: a healer never ticks the objective.
		local listed: { [Player]: boolean } = {}
		for _, r in recipients do
			listed[r.player] = true
		end
		for _, r in table.clone(recipients) do
			local root = rootOf(r.player)
			for _, mate in parties:matesOf(r.player) do
				local mateRoot = rootOf(mate)
				if not listed[mate] and root and mateRoot and (root.Position - mateRoot.Position).Magnitude <= Q.party.assistRadius then
					listed[mate] = true
					table.insert(recipients, { player = mate, share = r.share * Q.party.helperShare })
				end
			end
		end
	end

	local byOthers = (quest.status :: string) == "solved_by_others"
	if outcome.world and not byOthers then
		applyWorld(quest, outcome.world, if quest.owner then Players:GetPlayerByUserId(quest.owner) else nil)
	elseif outcome.world and outcome.world.prosperity and outcome.world.prosperity < 0 then
		applyWorld(quest, outcome.world, nil) -- bad endings land even when nobody played
	end

	local giver = npcOf(quest, template.giver)
	for _, r in recipients do
		if outcome.rewards then
			giveRewards(r.player, quest, outcome.rewards, r.share)
			if giver and outcome.rewards.relationship then
				npcs:questBond(giver, r.player, outcome.rewards.relationship * r.share, outcome.memory)
			end
		end
		if outcome.success then
			factions:deed(r.player, "quest_helped", situationPosition(quest), { magnitude = 0.5 })
		end
		journal:log(r.player, "outcome", text, { questId = quest.id })
		addTension(r.player, if outcome.success then Q.tension.questCompleted else Q.tension.questFailed)
		-- History (novelty), finished list (journal), follow-ups.
		local q = questsOf(r.player)
		if q then
			local h = q.history[template.id] or { n = 0, last = 0 }
			h.n += 1
			h.last = os.time()
			q.history[template.id] = h
			table.insert(q.recent, template.id)
			while #q.recent > 10 do
				table.remove(q.recent, 1)
			end
			q.active[quest.id] = nil
			table.insert(q.finished, {
				id = quest.id, template = template.id, title = QuestFactory.text(quest, template.title),
				outcome = outcomeId, text = text, success = outcome.success, t = os.time(), creative = #quest.creative > 0,
			})
			while #q.finished > FINISHED_CAP do
				table.remove(q.finished, 1)
			end
			if outcome.followUp and T[outcome.followUp] then
				table.insert(q.followUps, { template = outcome.followUp, situation = quest.situation, slots = quest.slots })
			end
		end
	end
	if outcome.success and (quest.status :: string) == "completed" then
		if quest.owner then
			dropPersonalLoot(quest, template, rewardHelpers(quest, template, outcome, outcomeId, text))
		else
			for _, r in recipients do
				giveLoot(r.player, rollQuestLoot(quest, template, r.player.UserId, r.share), "quest " .. quest.template)
			end
		end
	end
	-- An owner who was offline (or a shared quest nobody finished) still clears the record.
	if quest.owner then
		local p = Players:GetPlayerByUserId(quest.owner)
		local q = p and questsOf(p)
		if q then
			q.active[quest.id] = nil
			q.offers[quest.id] = nil
		end
	else
		shared[quest.id] = nil
		sharedEnded[quest.id] = os.time()
	end
	release(quest)
	local players = {}
	for _, r in recipients do
		table.insert(players, r.player)
	end
	bus:publish(Topics.QuestEnded, { questId = quest.id, template = template.id, outcome = outcomeId, success = outcome.success, status = quest.status, players = players })
	log:info("quest_ended", { quest = quest.id, outcome = outcomeId, status = quest.status, recipients = #recipients })
end

-- ─── Offers ─────────────────────────────────────────────────────────────────

local function focusShare(state: any, domains: { string }): number
	if #domains == 0 then
		return 0.5
	end
	local focus = state.data.progression.focus or {}
	local total, hit = 0, 0
	for domain, entry in focus do
		local v = if typeof(entry) == "table" then entry.v or 0 else entry
		total += v
		if table.find(domains, domain) then
			hit += v
		end
	end
	return if total > 0 then hit / total else 0
end

local function score(player: Player, state: any, q: any, template: Template, situation: Situation, position: Vector3, tension: number): number
	if not table.find(template.situations, situation.kind) then
		return 0
	end
	if situation.forUserId and situation.forUserId ~= player.UserId then
		return 0
	end
	if not meets(player, state, template.requires) then
		return 0
	end
	local h = q.history[template.id]
	if h and os.time() - h.last < template.cooldownHours * 3600 then
		return 0
	end
	-- Focus: more of what you practise, never only that.
	local focus = Q.focusFloor + Q.focusBoost * focusShare(state, template.domains)
	-- Novelty: fewer repeats of the same template and type.
	local sameTemplate, sameType = 0, 0
	for _, id in q.recent do
		if id == template.id then
			sameTemplate += 1
		end
		if T[id] and T[id].type == template.type then
			sameType += 1
		end
	end
	local novelty = Q.noveltyBase ^ sameTemplate * Q.noveltyTypeBase ^ sameType
	-- Pacing: the intensity this phase wants.
	local want = phaseOf(tension).wantIntensity
	local pacing = 1 / (1 + (math.abs(template.intensity - want) / Q.pacingWidth) ^ 2)
	-- Power: inside the tier band.
	local tier = bestTier(state)
	local lo, hi = template.difficulty[1], template.difficulty[2]
	local power = if tier < lo then 0.5 ^ (lo - tier) elseif tier > hi then 0.6 ^ (tier - hi) else 1
	-- Distance (personal situations are about you: no falloff).
	local d = (Vector3.new(situation.x, 0, situation.z) - Vector3.new(position.X, 0, position.Z)).Magnitude
	local distance = if situation.forUserId then 1 else math.clamp(1 - d / Q.offerRadius, 0, 1)
	return template.weight * focus * novelty * pacing * power * distance * (0.5 + situation.severity)
end

local function offer(player: Player, quest: QuestState)
	local q = questsOf(player)
	if not q then
		return
	end
	local template = T[quest.template]
	if template.autoStart then
		q.active[quest.id] = quest
		start(quest, player)
		journal:log(player, "quest", QuestFactory.text(quest, template.summary), { questId = quest.id })
		return
	end
	q.offers[quest.id] = quest
	local giver = npcOf(quest, template.giver)
	local text = QuestFactory.text(quest, template.summary)
	journal:log(player, "rumor", if giver then text .. " (talk to " .. giver.name .. ")" else text, { questId = quest.id })
	bus:publish(Topics.QuestOffered, { player = player, questId = quest.id, template = template.id })
	log:info("quest_offered", { userId = player.UserId, quest = quest.id })
end

local function tryOffer(player: Player, state: any, q: any, position: Vector3)
	local count = 0
	for _ in q.offers do
		count += 1
	end
	local activeCount = 0
	for _ in q.active do
		activeCount += 1
	end
	-- Beginner quests come one at a time: a new player is never handed a pile of chores.
	local beginnerOpen = false
	for _, list in { q.offers, q.active } do
		for _, quest in list do
			if T[quest.template] and T[quest.template].beginner then
				beginnerOpen = true
			end
		end
	end
	-- Full: only a beginner quest may still come in, or three road escorts would lock a new player
	-- out of them for good (seen in play, 2026-11-05).
	local full = count >= Q.maxOffers or activeCount >= Q.maxActive
	if full and (beginnerOpen or activeCount >= Q.maxActive) then
		return
	end
	local tension = tensionOf(q)
	local candidates: { { template: Template, situation: Situation, score: number } } = {}
	local pool: { Situation } = {}
	for _, s in situations do
		table.insert(pool, s)
	end
	for _, s in SituationDetector.scanPlayer({ world = world, events = events, npcs = npcs, reputation = reputation }, player, state, position) do
		situations[s.id] = situations[s.id] or s
		table.insert(pool, s)
	end
	-- Follow-ups from earlier endings ride on their old situation.
	for i = #q.followUps, 1, -1 do
		local f = q.followUps[i]
		local s = situations[f.situation]
		if s then
			table.insert(candidates, { template = T[f.template], situation = s, score = 2 })
		end
		table.remove(q.followUps, i)
	end
	for _, s in pool do
		for _, template in QuestTemplates.list do
			if template.scope == "personal" and not (beginnerOpen and template.beginner) then
				local id = template.id .. "|" .. s.id .. "|" .. player.UserId
				if not q.active[id] and not q.offers[id] then
					local sc = score(player, state, q, template, s, position, tension)
					if sc > 0.02 then
						table.insert(candidates, { template = template, situation = s, score = sc })
					end
				end
			end
		end
	end
	-- A beginner quest wins whenever one fits. Otherwise the many NPC situations outnumber the few
	-- beginner ones, and a new player's first offers are all errands for strangers.
	local beginnerCandidates: { { template: Template, situation: Situation, score: number } } = {}
	for _, c in candidates do
		if c.template.beginner then
			table.insert(beginnerCandidates, c)
		end
	end
	if #beginnerCandidates > 0 then
		candidates = beginnerCandidates
	elseif full then
		return
	end
	if #candidates == 0 then
		return
	end
	directorCount[player] = (directorCount[player] or 0) + 1
	local rng = Seed.random(worldSeed, "player:" .. player.UserId, "director", directorCount[player] + os.time() // 3600)
	if rng:NextNumber() > Q.offerChance then
		return
	end
	-- A pick can fail to build (no mentor in town, the yard not built yet): try another, and say so.
	for _ = 1, 4 do
		local total = 0
		for _, c in candidates do
			total += c.score
		end
		local roll = rng:NextNumber() * total
		local chosen = #candidates
		for i, c in candidates do
			roll -= c.score
			if roll <= 0 then
				chosen = i
				break
			end
		end
		local c = candidates[chosen]
		local quest = QuestFactory.build(c.template, c.situation, { world = world, npcs = npcs, worldSeed = worldSeed, userId = player.UserId, position = position })
		if quest then
			offer(player, quest)
			return
		end
		log:info("quest_build_failed", { template = c.template.id, situation = c.situation.id })
		table.remove(candidates, chosen)
		if #candidates == 0 then
			return
		end
	end
end

-- ─── Director tick (per player) ─────────────────────────────────────────────

local function complications(player: Player, quest: QuestState, tension: number)
	local template = T[quest.template]
	for _, c in (template.complications or {}) :: { QuestTypes.Complication } do
		if not table.find(quest.firedComplications, c.id) and (not c.afterStage or c.afterStage == quest.stage) then
			local scale = Q.complicationScale[phaseOf(tension).id] or 1
			if Seed.random(worldSeed, quest.id, "complication:" .. c.id, directorCount[player] or 0):NextNumber() < c.chance * scale then
				table.insert(quest.firedComplications, c.id)
				journal:log(player, "quest", QuestFactory.text(quest, c.text), { questId = quest.id })
				local effect = c.effect
				if effect.spawnHostiles then
					local anchor = npcOf(quest, effect.near)
					local root = rootOf(player)
					local at = if anchor then anchor.position elseif root then root.Position else nil
					if at then
						spawned[quest.id] = spawned[quest.id] or {}
						for i = 1, effect.spawnHostiles do
							local npc = npcs:spawn(at + Vector3.new(14 + i * 4, 0, 12), { occupation = "hunter", faction = effect.faction, mastery = { energy = 40 } })
							if npc then
								table.insert(spawned[quest.id], npc)
								task.delay(2, function()
									if npc.rig then
										npc.rig.humanoid:SetAttribute("QuestSanction", player.UserId)
									end
									NPCCombat.challenge(npc, "u:" .. player.UserId)
								end)
							end
						end
					end
				end
				if effect.startEvent then
					local s = situations[quest.situation]
					if s then
						pcall(events.startEvent, events, effect.startEvent, s.x, s.z)
					end
				end
			end
		end
	end
end

local function directorTick(player: Player)
	local state = playerData:get(player)
	local q = questsOf(player)
	local root = rootOf(player)
	if not state or not q or not root then
		return
	end
	local now = WorldClock.now()
	local tension = tensionOf(q)
	if #events:activeAt(root.Position.X, root.Position.Z) > 0 then
		addTension(player, Q.tension.crisisNearby)
	end

	-- Offers expire.
	for id, quest in q.offers do
		if os.time() - quest.offeredAt > Q.offerHours * 3600 then
			q.offers[id] = nil
		end
	end
	-- Active quests: deadlines, escalation, complications, NPC targets that no longer exist.
	for _, quest in q.active do
		local template = T[quest.template]
		if not template then
			q.active[quest.id] = nil
			continue
		end
		if quest.deadline and now > quest.deadline then
			finish(quest, template.failOutcome, "expired")
			continue
		end
		if quest.stageDeadline and now > quest.stageDeadline then
			finish(quest, template.failOutcome, "expired")
			continue
		end
		local esc = template.escalation
		if esc and not table.find(quest.firedComplications, "escalation") and quest.startedAt then
			local hours = (os.time() - quest.startedAt) / WorldClock.secondsPerHour()
			if hours >= esc.afterHours then
				table.insert(quest.firedComplications, "escalation")
				journal:log(player, "quest", QuestFactory.text(quest, esc.text), { questId = quest.id })
				if esc.event then
					local s = situations[quest.situation]
					if s then
						pcall(events.startEvent, events, esc.event, s.x, s.z)
					end
				end
				if esc.outcome then
					finish(quest, esc.outcome, "expired")
					continue
				end
			end
		end
		complications(player, quest, tension)
	end
	tryOffer(player, state, q, root.Position)
end

-- ─── Shared quests (crises) ─────────────────────────────────────────────────

local function spawnShared()
	local count = 0
	for _ in shared do
		count += 1
	end
	for _, s in situations do
		if count >= MAX_SHARED then
			return
		end
		for _, template in QuestTemplates.list do
			if template.scope == "shared" and table.find(template.situations, s.kind) then
				local id = template.id .. "|" .. s.id .. "|shared"
				-- A crisis that just ended (solved, failed, or the locals got there) isn't offered
				-- again straight away, even if the condition is still true: cooldownHours of game time.
				local ended = sharedEnded[id]
				local cooling = ended ~= nil and os.time() - ended < template.cooldownHours * WorldClock.secondsPerHour()
				if not shared[id] and not cooling and #Players:GetPlayers() > 0 then
					local quest = QuestFactory.build(template, s, { world = world, npcs = npcs, worldSeed = worldSeed })
					if quest then
						shared[id] = quest
						count += 1
						start(quest, nil)
						for _, p in playersOf(quest) do
							journal:log(p, "rumor", QuestFactory.text(quest, template.summary), { questId = quest.id })
						end
					end
				end
			end
		end
	end
end

local function sharedTick()
	local now = WorldClock.now()
	for _, quest in shared do
		local template = T[quest.template]
		if quest.deadline and now > quest.deadline then
			finish(quest, template.failOutcome, "expired")
		elseif not situations[quest.situation] then
			-- The crisis is over on its own (the event ended, the stress released).
			finish(quest, if template.npcSolve then template.npcSolve.outcome else template.failOutcome, "npc")
		end
	end
end

-- ─── Events ─────────────────────────────────────────────────────────────────

-- A cast match with its {slot} placeholders filled ("{branch_parent}", "{property}", "{domain}").
local function fillMatch(quest: QuestState, match: QuestTypes.CastMatch?): QuestTypes.CastMatch?
	if not match then
		return nil
	end
	local m: any = table.clone(match)
	for _, field in { "domains", "properties", "verbs", "forms", "routes", "branches" } do
		local list = (match :: any)[field]
		if list then
			local out: { string } = {}
			for _, v in list do
				table.insert(out, QuestFactory.fill(quest, v))
			end
			m[field] = out
		end
	end
	return m
end

local function onSpellResolved(payload: any)
	local player = Players:GetPlayerByUserId(payload.casterUserId)
	if not player or not enabled() then
		return
	end
	local cast: Objectives.Cast = payload
	for _, quest in activeFor(player) do
		local template = T[quest.template]
		local stage = stageOf(template, quest.stage)
		if quest.status == "active" and stage then
			for _, option in stage.options do
				for _, spec in Objectives.open(option, quest.progress) do
					if spec.kind == "cast" or spec.kind == "demonstrate" then
						local at = QuestFactory.position(quest, spec.at)
						local targetNpc = npcOf(quest, spec.target)
						local center = at or (if targetNpc then targetNpc.position else nil)
						local inRange = center ~= nil and (cast.point - center).Magnitude <= (spec.radius or 40)
						if inRange then
							if spec.kind == "demonstrate" then
								-- Lessons: the student's branch, spaced out in game hours.
								local branch = quest.slots[spec.branch or ""]
								local key = Objectives.key(option.id, spec.id) .. "@"
								local last = quest.progress[key] or -math.huge
								local matches = spec.match == nil or Objectives.castMatches(fillMatch(quest, spec.match), cast)
								if branch and matches and table.find(cast.branchPath, branch) and WorldClock.now() - last >= (spec.spacingHours or 0) / 24 then
									quest.progress[key] = WorldClock.now()
									addProgress(quest, option.id, spec, 1, player, false)
								end
							else
								local probe = table.clone(spec)
								probe.match = fillMatch(quest, spec.match)
								local gain, creative = Objectives.castGain(probe, cast)
								addProgress(quest, option.id, spec, gain, player, creative)
							end
						end
					end
				end
			end
		end
	end
end

local function onTalked(payload: any)
	local player: Player = payload.player
	if not enabled() or not player then
		return
	end
	local state = playerData:get(player)
	for _, quest in activeFor(player) do
		local template = T[quest.template]
		local stage = stageOf(template, quest.stage)
		if quest.status == "active" and stage then
			for _, option in stage.options do
				for _, spec in Objectives.open(option, quest.progress) do
					if quest.slots[spec.target or ""] == payload.npcId then
						if spec.kind == "talk" then
							local gives = spec.args and spec.args.gives
							if gives then
								quest.carried[gives] = true
							end
							addProgress(quest, option.id, spec, 1, player, false)
						elseif spec.kind == "deliver" and quest.carried[spec.item or ""] then
							quest.carried[spec.item or ""] = nil
							local gives = spec.args and spec.args.gives
							if gives then
								quest.carried[gives] = true
							end
							addProgress(quest, option.id, spec, 1, player, false)
						elseif spec.kind == "pay" and state and (not quest.owner or quest.owner == player.UserId) then
							-- Only your own quest can spend your coins: chatting to someone a
							-- party member owes money must never empty your purse.
							local amount = spec.amount or (spec.args and quest.slots[spec.args.amountSlot or ""]) or 0
							if inventory:addCurrency(player, -amount, "quest pay " .. quest.template) then
								addProgress(quest, option.id, spec, 1, player, false)
							else
								journal:log(player, "quest", string.format("You need %d to pay.", amount), { questId = quest.id })
							end
						end
					end
				end
			end
		end
	end
end

local function onDamaged(payload: any)
	local npcId = payload.npcId
	if not npcId or not enabled() then
		return
	end
	local humanoid: Humanoid = payload.humanoid
	local share = humanoid.Health / math.max(1, humanoid.MaxHealth)
	local function visit(quest: QuestState)
		local template = T[quest.template]
		-- Protected NPCs: a knockout ends the quest badly.
		if payload.killed then
			for _, slot in (template.protect or {}) :: { string } do
				if quest.slots[slot] == npcId then
					finish(quest, template.protectOutcome or template.failOutcome, nil)
					return
				end
			end
		end
		local stage = stageOf(template, quest.stage)
		if quest.status ~= "active" or not stage then
			return
		end
		for _, option in stage.options do
			for _, spec in Objectives.open(option, quest.progress) do
				if spec.kind == "subdue" and quest.slots[spec.target or ""] == npcId then
					local owner = quest.owner
					local source = payload.sourceUserId
					local byOwner = not owner or source == owner or (source ~= nil and sharesWithParty(quest) and parties:sameParty(source, owner))
					if byOwner and (payload.killed or share <= (spec.share or Q.duelYieldShare)) then
						local npc = npcs:get(npcId)
						if npc then
							NPCCombat.disengage(npc) -- they yield
						end
						addProgress(quest, option.id, spec, 1, Players:GetPlayerByUserId(payload.sourceUserId or 0), false)
					end
				end
			end
		end
	end
	for _, player in Players:GetPlayers() do
		local q = questsOf(player)
		for _, quest in (if q then q.active else {}) :: { [string]: QuestState } do
			visit(quest)
		end
	end
	for _, quest in shared do
		visit(quest)
	end
end

-- ─── Poll (positions, predicates, wards) ────────────────────────────────────

local function awakeNear(position: Vector3, radius: number): boolean
	for _, npc in npcs:all() do
		if npc.rig and npc.tier == 0 and not npc.knockedOut and npc.action ~= "sleep" and (npc.position - position).Magnitude <= radius then
			return true
		end
	end
	return false
end

local function pollQuest(player: Player, quest: QuestState, root: BasePart, dt: number)
	local template = T[quest.template]
	local stage = stageOf(template, quest.stage)
	if quest.status ~= "active" or not stage then
		return
	end
	-- Wards and sanctions on the NPCs this quest is about (rigs come and go with LOD).
	for _, slot in (template.protect or {}) :: { string } do
		local npc = npcOf(quest, slot)
		if npc and npc.rig and quest.owner then
			npc.rig.humanoid:SetAttribute("QuestWard", quest.owner)
		end
	end
	local hour = WorldClock.hourOf(WorldClock.now())
	local s = situations[quest.situation]
	local eventActive = s ~= nil and s.facts.eventId ~= nil and #events:activeAt(s.x, s.z) > 0
	for _, option in stage.options do
		for _, spec in Objectives.open(option, quest.progress) do
			local at = QuestFactory.position(quest, spec.at)
			local near = at ~= nil and (root.Position - at).Magnitude <= (spec.radius or 20)
			if spec.kind == "reach" and near then
				addProgress(quest, option.id, spec, dt, player, false)
			elseif spec.kind == "collect" and near then
				if spec.unseen then
					local veiled = (player.Character and player.Character:FindFirstChildOfClass("Humanoid") and (player.Character:FindFirstChildOfClass("Humanoid") :: Humanoid):GetAttribute("Status_veiled")) ~= nil
					local night = Objectives.predicates.night({ hour = hour, eventActive = eventActive })
					local radius = Q.noticeRadius * (if veiled then 0.25 elseif night then 0.5 else 1)
					if awakeNear(root.Position, radius) then
						noticeTime[quest.id] = (noticeTime[quest.id] or 0) + dt
						if noticeTime[quest.id] >= Q.noticeSeconds and spec.onNoticed then
							finish(quest, spec.onNoticed, nil)
							return
						end
					else
						noticeTime[quest.id] = math.max(0, (noticeTime[quest.id] or 0) - dt)
					end
				end
				local before = quest.progress[Objectives.key(option.id, spec.id)] or 0
				addProgress(quest, option.id, spec, dt, player, false)
				if before + dt >= Objectives.required(spec) and spec.item then
					quest.carried[spec.item] = true
				end
			elseif spec.kind == "escort" then
				local npc = npcOf(quest, spec.target)
				if npc and quest.owner then
					-- Only the owner picks them up: they follow the owner, wherever a helper stands.
					if not npc.leash and player.UserId == quest.owner and (npc.position - root.Position).Magnitude <= 15 then
						npcs:setLeash(npc, { kind = "follow", userId = quest.owner })
						if npc.rig then
							npc.rig.humanoid:SetAttribute("QuestWard", quest.owner)
						end
					end
					if at and (npc.position - at).Magnitude <= (spec.radius or 30) then
						npcs:setLeash(npc, nil)
						addProgress(quest, option.id, spec, 1, player, false)
					end
				end
			elseif spec.kind == "subdue" then
				-- Duels: once you're close, they fight you (and hits on them aren't crimes).
				local npc = npcOf(quest, spec.target)
				if npc and npc.rig and npc.tier == 0 and quest.owner and (npc.position - root.Position).Magnitude <= 40 then
					if npc.rig.humanoid:GetAttribute("QuestSanction") ~= quest.owner then
						npc.rig.humanoid:SetAttribute("QuestSanction", quest.owner)
					end
					if not NPCCombat.engaged(npc) then
						NPCCombat.challenge(npc, "u:" .. player.UserId) -- whoever came close: the owner or a helper
					end
				end
			elseif spec.kind == "witness" and near then
				local want = QuestFactory.fill(quest, spec.event or "")
				for _, e in events:activeAt(root.Position.X, root.Position.Z) do
					if e.type == want then
						addProgress(quest, option.id, spec, 1, player, false)
					end
				end
			elseif spec.kind == "state" then
				local predicate = Objectives.predicates[spec.predicate or ""]
				if predicate and predicate({ hour = hour, eventActive = eventActive }) then
					addProgress(quest, option.id, spec, 1, player, false)
				end
			elseif spec.kind == "wait" then
				local key = Objectives.key(option.id, spec.id) .. "@start"
				quest.progress[key] = quest.progress[key] or WorldClock.now()
				if WorldClock.now() - quest.progress[key] >= (spec.hours or 1) / 24 then
					addProgress(quest, option.id, spec, 1, player, false)
				end
			end
			if quest.status ~= "active" then
				return
			end
		end
	end
end

local function poll(dt: number)
	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		if root then
			for _, quest in activeFor(player) do
				local ok, err = pcall(pollQuest, player, quest, root, dt)
				if not ok then
					log:throttled("quest_poll:" .. quest.template, 60, "Warn", "quest_poll_failed", { quest = quest.id, err = err })
				end
			end
		end
	end
end

-- ─── Hourly: NPCs solve what players don't ──────────────────────────────────

local function hourly(hourIndex: number)
	local function roll(quest: QuestState)
		local template = T[quest.template]
		local solve = template.npcSolve
		-- Grace: locals don't beat players to it in the first quarter of the quest's time.
		local hours = if quest.startedAt then (os.time() - quest.startedAt) / WorldClock.secondsPerHour() else 0
		if hours < template.expireHours * 0.25 then
			return
		end
		if solve and quest.status == "active" and Seed.random(worldSeed, quest.id, "npcsolve", hourIndex):NextNumber() < solve.chancePerHour then
			finish(quest, solve.outcome, "npc")
		end
	end
	for _, quest in shared do
		roll(quest)
	end
	for _, player in Players:GetPlayers() do
		local q = questsOf(player)
		for _, quest in (if q then q.active else {}) :: { [string]: QuestState } do
			roll(quest)
		end
	end
end

-- ─── Journal: quests tab, actions, the "quest" talk topic ───────────────────

-- Whether a player sees an option: its requirements, and every NPC / place it names exists
-- (an option needing someone the town doesn't have, an optional slot, isn't a way through).
-- Anything already progressed stays visible: you found that way yourself.
local function optionVisible(player: Player, state: any, quest: QuestState, option: QuestTypes.Option): boolean
	for _, spec in option.objectives do
		if (quest.progress[Objectives.key(option.id, spec.id)] or 0) > 0 then
			return true
		end
	end
	if not state or not meets(player, state, option.requires) then
		return false
	end
	for _, spec in option.objectives do
		if (spec.target and quest.slots[spec.target] == nil) or (spec.at and quest.slots[spec.at] == nil) then
			return false
		end
	end
	return true
end

local function viewOf(player: Player, quest: QuestState): any
	local template = T[quest.template]
	local state = playerData:get(player)
	local stage = stageOf(template, quest.stage)
	local options = {}
	if stage then
		for _, option in stage.options do
			local objectives = {}
			for _, spec in option.objectives do
				if not spec.hidden or Objectives.done(spec, option.id, quest.progress) then
					local at = QuestFactory.position(quest, spec.at)
					local npc = npcOf(quest, spec.target)
					table.insert(objectives, {
						text = QuestFactory.text(quest, spec.text),
						progress = math.floor((quest.progress[Objectives.key(option.id, spec.id)] or 0) * 10) / 10,
						required = Objectives.required(spec),
						done = Objectives.done(spec, option.id, quest.progress),
						pin = at or (if npc then npc.position else nil),
					})
				end
			end
			if optionVisible(player, state, quest, option) then
				table.insert(options, { id = option.id, label = QuestFactory.text(quest, option.label), approach = option.approach, objectives = objectives })
			end
		end
	end
	local giver = npcOf(quest, template.giver)
	return {
		id = quest.id,
		title = QuestFactory.text(quest, template.title),
		summary = QuestFactory.text(quest, template.summary),
		stage = if stage then QuestFactory.text(quest, stage.text) else "",
		type = template.type,
		scope = template.scope,
		status = quest.status,
		giver = if giver then giver.name else nil,
		hoursLeft = if quest.deadline then math.max(0, (quest.deadline - WorldClock.now()) * 24) else template.expireHours,
		options = options,
		creative = #quest.creative,
		tracked = quest.tracked == true,
	}
end

--[[
	Map pins (client Controllers/QuestPinsController): where the open objectives of your quests are.
	Only objectives you could act on NOW (an ordered option shows its next step only), only options
	you can see, never hidden ones. People are pinned where they are, so pins move with NPCs.
	Pushed (QuestPins, owner only) when they change, checked every pinSeconds.
		{ { q = questId, title, text, p = Vector3, tracked, shared, person } }   at most MAX_PINS
]]
local MAX_PINS = 10
local PIN_SECONDS = 2
local lastPins: { [Player]: string } = {}

local function pinsFor(player: Player): { any }
	local pins = {}
	local seen: { [string]: boolean } = {}
	local state = playerData:get(player)
	for _, quest in activeFor(player) do
		local template = T[quest.template]
		local stage = stageOf(template, quest.stage)
		if quest.status == "active" and stage then
			local title = QuestFactory.text(quest, template.title)
			for _, option in stage.options do
				if optionVisible(player, state, quest, option) then
					for _, spec in Objectives.open(option, quest.progress) do
						if not spec.hidden then
							local at = QuestFactory.position(quest, spec.at)
							local npc = if at then nil else npcOf(quest, spec.target)
							local p: Vector3? = at or (if npc and not npc.knockedOut then npc.position + Vector3.new(0, 3, 0) else nil)
							if p then
								-- One pin per place: two options naming the same NPC share it.
								local key = quest.id .. "@" .. math.floor(p.X / 4) .. "," .. math.floor(p.Z / 4)
								if not seen[key] and #pins < MAX_PINS then
									seen[key] = true
									table.insert(pins, {
										q = quest.id,
										title = title,
										text = QuestFactory.text(quest, spec.text),
										p = p,
										tracked = quest.tracked == true,
										shared = quest.scope == "shared" or quest.owner ~= player.UserId,
										person = npc ~= nil,
									})
								end
							end
						end
					end
				end
			end
		end
	end
	-- Tracked first, so the client's arrow (and the cap) favour them.
	table.sort(pins, function(a, b)
		return a.tracked and not b.tracked
	end)
	return pins
end

local function pushPins(player: Player, force: boolean?)
	local pins = pinsFor(player)
	local parts = {}
	for _, pin in pins do
		table.insert(parts, string.format("%s|%s|%d|%d|%d|%s", pin.q, pin.text, pin.p.X // 2, pin.p.Y // 2, pin.p.Z // 2, tostring(pin.tracked)))
	end
	local signature = table.concat(parts, ";")
	if force or lastPins[player] ~= signature then
		lastPins[player] = signature
		Net.fire("QuestPins", player, pins)
	end
end

local function questsTab(player: Player, _page: number): any
	local q = questsOf(player)
	if not q then
		return {}
	end
	local offers, active, nearby = {}, {}, {}
	for _, quest in q.offers do
		table.insert(offers, viewOf(player, quest))
	end
	for _, quest in q.active do
		table.insert(active, viewOf(player, quest))
	end
	local party = {}
	for _, quest in activeFor(player) do
		if quest.scope == "shared" then
			table.insert(nearby, viewOf(player, quest))
		elseif quest.owner and quest.owner ~= player.UserId then
			local view = viewOf(player, quest)
			local owner = Players:GetPlayerByUserId(quest.owner)
			view.helping = if owner then owner.DisplayName else "your party"
			table.insert(party, view)
		end
	end
	local finished = {}
	for i = #q.finished, 1, -1 do
		table.insert(finished, q.finished[i])
	end
	return { offers = offers, active = active, party = party, shared = nearby, finished = finished }
end

local function onActionInner(player: Player, questId: string, action: string): any
	local q = questsOf(player)
	if not q or not enabled() then
		return { ok = false }
	end
	if action == "accept" then
		local quest = q.offers[questId]
		local activeCount = 0
		for _ in q.active do
			activeCount += 1
		end
		if not quest or activeCount >= Q.maxActive then
			return { ok = false, reason = if quest then "too_many" else "gone" }
		end
		q.offers[questId] = nil
		q.active[questId] = quest
		start(quest, player)
		return { ok = true }
	elseif action == "decline" then
		q.offers[questId] = nil
		return { ok = true }
	elseif action == "abandon" then
		local quest = q.active[questId]
		if not quest or T[quest.template].autoStart then
			return { ok = false }
		end
		finish(quest, T[quest.template].failOutcome, "abandoned")
		return { ok = true }
	elseif action == "track" then
		for id, quest in q.active do
			quest.tracked = id == questId
		end
		return { ok = true }
	end
	return { ok = false }
end

-- Every journal action re-sends the pins at once (accepting, tracking or abandoning moves them).
local function onAction(player: Player, questId: string, action: string): any
	local result = onActionInner(player, questId, action)
	pcall(pushPins, player, true)
	return result
end

-- NPCService's talk hook: answers the "quest" topic and says when to show it.
local function talkHook(player: Player, npc: any, topic: string): (string?, boolean)
	local q = questsOf(player)
	if not q then
		return nil, false
	end
	-- An offer this NPC gives.
	for id, quest in q.offers do
		local template = T[quest.template]
		if template.giver and quest.slots[template.giver] == npc.id then
			if topic == "quest" then
				onAction(player, id, "accept")
				return QuestFactory.text(quest, template.summary) .. " " .. QuestFactory.text(quest, template.stages[1].text), true
			end
			return nil, true
		end
	end
	-- A step of an active quest that needs them.
	for _, quest in q.active do
		local template = T[quest.template]
		local stage = stageOf(template, quest.stage)
		if stage then
			for _, option in stage.options do
				for _, spec in Objectives.open(option, quest.progress) do
					if quest.slots[spec.target or ""] == npc.id and (spec.kind == "talk" or spec.kind == "deliver" or spec.kind == "pay") then
						if topic == "quest" then
							return QuestFactory.text(quest, stage.text), true
						end
						return nil, true
					end
				end
			end
		end
	end
	return nil, false
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function findQuest(player: Player, id: string): QuestState?
	local q = questsOf(player)
	if q then
		for questId, quest in q.active do
			if questId == id or string.find(questId, id, 1, true) then
				return quest
			end
		end
		for questId, quest in q.offers do
			if questId == id or string.find(questId, id, 1, true) then
				return quest
			end
		end
	end
	for questId, quest in shared do
		if questId == id or string.find(questId, id, 1, true) then
			return quest
		end
	end
	return nil
end

local function registerAdmin(admin: any)
	local ids = {}
	for _, t in QuestTemplates.list do
		table.insert(ids, t.id)
	end
	table.sort(ids)
	admin:Register({
		name = "quests", category = "Quests & factions", description = "A player's offers, active quests, nearby shared quests and tension",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local q = questsOf(a.player)
			if not q then
				return "not loaded"
			end
			local lines = { string.format("tension %.2f (%s)", tensionOf(q), phaseOf(tensionOf(q)).id) }
			for id in q.offers do
				table.insert(lines, "offer  " .. id)
			end
			for id, quest in q.active do
				table.insert(lines, string.format("active %s  stage %s", id, quest.stage))
			end
			for id, quest in shared do
				table.insert(lines, string.format("shared %s  stage %s", id, quest.stage))
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "situations", category = "Quests & factions", description = "Every situation this server has detected",
		args = {},
		handler = function()
			local lines = {}
			for id, s in situations do
				table.insert(lines, string.format("%s  sev %.2f  %s", id, s.severity, s.source))
			end
			table.sort(lines)
			return if #lines > 0 then table.concat(lines, "\n") else "none"
		end,
	})
	admin:Register({
		name = "questgen", category = "Quests & factions", description = "Offer a template now from a matching situation (closest first)",
		args = { { name = "template", type = "enum", options = ids } :: any, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local template = T[a.template]
			local root = rootOf(a.player)
			local state = playerData:get(a.player)
			if not root or not state then
				return "no character"
			end
			local pool: { Situation } = {}
			for _, s in situations do
				table.insert(pool, s)
			end
			for _, s in SituationDetector.scanPlayer({ world = world, events = events, npcs = npcs, reputation = reputation }, a.player, state, root.Position) do
				situations[s.id] = situations[s.id] or s
				table.insert(pool, s)
			end
			table.sort(pool, function(x, y)
				return (x.x - root.Position.X) ^ 2 + (x.z - root.Position.Z) ^ 2 < (y.x - root.Position.X) ^ 2 + (y.z - root.Position.Z) ^ 2
			end)
			for _, s in pool do
				if table.find(template.situations, s.kind) and (not s.forUserId or s.forUserId == a.player.UserId) then
					local quest, err = QuestFactory.build(template, s, { world = world, npcs = npcs, worldSeed = worldSeed, userId = if template.scope == "personal" then a.player.UserId else nil, position = root.Position })
					if quest then
						if template.scope == "shared" then
							shared[quest.id] = quest
							start(quest, nil)
						else
							offer(a.player, quest)
						end
						return "made " .. quest.id
					end
					log:debug("questgen_skip", { situation = s.id, err = err })
				end
			end
			return "no matching situation (kinds: " .. table.concat(template.situations, ", ") .. "); see `situations`"
		end,
	})
	admin:Register({
		name = "questcomplete", category = "Quests & factions", description = "Finish a quest with an outcome (default: its first success)",
		args = { { name = "quest", type = "string" }, { name = "outcome", type = "string", optional = true }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local quest = findQuest(a.player, a.quest)
			if not quest then
				return "no such quest"
			end
			local template = T[quest.template]
			local outcome = a.outcome
			if not outcome then
				for id, o in template.outcomes do
					if o.success then
						outcome = id
						break
					end
				end
			end
			if quest.status == "offered" then
				local q = questsOf(a.player)
				if q then
					q.offers[quest.id] = nil
					q.active[quest.id] = quest
				end
				start(quest, a.player)
			end
			finish(quest, outcome or template.failOutcome, nil)
			return "finished with " .. tostring(outcome)
		end,
	})
	admin:Register({
		name = "questreset", category = "Quests & factions", description = "Forget a quest entirely (no outcome) and its template's history, so it can be offered again",
		args = { { name = "quest", type = "string" }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local quest = findQuest(a.player, a.quest)
			local q = questsOf(a.player)
			if not quest or not q then
				return "no such quest"
			end
			release(quest)
			q.active[quest.id], q.offers[quest.id] = nil, nil
			q.history[quest.template] = nil
			shared[quest.id] = nil
			return "reset " .. quest.id
		end,
	})
	admin:Register({
		name = "hunters", category = "Quests & factions", description = "Send the Quiet Hand after a player (raises mythic notoriety past huntAt)",
		args = { { name = "domain", type = "enum", options = { "time", "gravity", "reality" }, default = "time" } :: any, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local current = reputation:notorietyOf(a.player)[a.domain] or 0
			reputation:addNotoriety(a.player, a.domain, math.max(0, Q.mythicNotoriety.huntAt + 5 - current))
			local q = questsOf(a.player)
			local state = playerData:get(a.player)
			local root = rootOf(a.player)
			if not q or not state or not root then
				return "no character"
			end
			q.history["hunted_by_hand"] = nil
			-- Start it now (the director would too, but only on a lucky check).
			for _, s in SituationDetector.scanPlayer({ world = world, events = events, npcs = npcs, reputation = reputation }, a.player, state, root.Position) do
				if s.kind == "mythic_notoriety" and s.facts.domain == a.domain then
					situations[s.id] = situations[s.id] or s
					local quest, err = QuestFactory.build(T.hunted_by_hand, s, { world = world, npcs = npcs, worldSeed = worldSeed, userId = a.player.UserId, position = root.Position })
					if not quest then
						return "couldn't build the hunt: " .. tostring(err)
					end
					if q.active[quest.id] then
						return "already hunted: " .. quest.id
					end
					offer(a.player, quest)
					return "the Quiet Hand is here: " .. quest.id
				end
			end
			return "notoriety raised, but no hunt situation was found"
		end,
	})
	admin:Register({
		name = "questfail", category = "Quests & factions", description = "Fail a quest",
		args = { { name = "quest", type = "string" }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local quest = findQuest(a.player, a.quest)
			if not quest then
				return "no such quest"
			end
			finish(quest, T[quest.template].failOutcome, nil)
			return "failed"
		end,
	})
	admin:Register({
		name = "queststage", category = "Quests & factions", description = "Jump a quest to a stage (by id)",
		args = { { name = "quest", type = "string" }, { name = "stage", type = "string" }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local quest = findQuest(a.player, a.quest)
			if not quest or not stageOf(T[quest.template], a.stage) then
				return "no such quest or stage"
			end
			enterStage(quest, a.stage)
			return "now at " .. a.stage
		end,
	})
	admin:Register({
		name = "questsituation", category = "Quests & factions", description = "The situation behind a quest, with its facts",
		args = { { name = "quest", type = "string" }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local quest = findQuest(a.player, a.quest)
			local s = quest and situations[quest.situation]
			if not s then
				return "no such quest, or its situation is gone"
			end
			local lines = { string.format("%s (%s) at %.0f, %.0f  severity %.2f", s.id, s.source, s.x, s.z, s.severity) }
			for k, v in s.facts do
				table.insert(lines, "  " .. k .. " = " .. tostring(v))
			end
			if s.settlementId then
				table.insert(lines, "  in " .. settlementName(s.settlementId))
			end
			return table.concat(lines, "\n")
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function scan()
	Scheduler.spawn("quest situations", function()
		local found = SituationDetector.scanWorld({ world = world, events = events, npcs = npcs, reputation = reputation }, Scheduler.checkpoint)
		local seen: { [string]: boolean } = {}
		local t = os.time()
		for _, s in found do
			seen[s.id] = true
			local existing = situations[s.id]
			if existing then
				existing.severity, existing.facts, existing.expiresAt = s.severity, s.facts, s.expiresAt
			else
				situations[s.id] = s
			end
			situations[s.id].lastSeen = t
		end
		-- World situations that are no longer true end. NPC situations are scanned round-robin, so
		-- they end only after a whole NPC cycle without being seen; personal ones expire on their own.
		local npcCycle = Q.scanSeconds * (math.ceil(#npcs:all() / Q.npcScanPerPass) + 2)
		for id, s in situations do
			local stale = if s.forUserId then false
				elseif s.source == "npc" then t - (s.lastSeen or s.detectedAt) > npcCycle
				else not seen[id]
			if stale or t > s.expiresAt then
				situations[id] = nil
			end
		end
		-- Over the cap: drop the least recently seen, never one that is true right now.
		local spare = {}
		local count = 0
		for id, s in situations do
			count += 1
			if not seen[id] then
				table.insert(spare, { id = id, t = s.lastSeen or s.detectedAt })
			end
		end
		if count > Q.maxSituations then
			table.sort(spare, function(a, b)
				return a.t < b.t
			end)
			for i = 1, math.min(#spare, count - Q.maxSituations) do
				situations[spare[i].id] = nil
			end
		end
		spawnShared()
		sharedTick()
	end)

end

function QuestDirector.init(_self: any, ctx: any)
	log, bus, flags = ctx.log, ctx.bus, ctx.flags
	playerData = ctx.get("PlayerDataService")
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	events = ctx.get("EventDirector")
	npcs = ctx.get("NPCService")
	progression = ctx.get("ProgressionService")
	inventory = ctx.get("InventoryService")
	reputation = ctx.get("ReputationService")
	factions = ctx.get("FactionService")
	journal = ctx.get("JournalService")
	parties = ctx.get("PartyService")
	partyLoot = ctx.get("PartyLootService")

	journal:setTab("quests", questsTab)
	Net.handle("QuestAction", onAction)
	npcs:setTalkHook(talkHook)
	bus:subscribe(Topics.SpellResolved, onSpellResolved)
	bus:subscribe(Topics.NpcTalked, onTalked)
	bus:subscribe(Topics.TargetDamaged, onDamaged)
	registerAdmin(ctx.get("AdminService"))
end

function QuestDirector.start(_self: any, _ctx: any)
	worldSeed = worldService:getSeed()
	world:awaitReady()

	-- Duels and hunts: dying during a failOnDeath stage ends it.
	local function watch(player: Player)
		player.CharacterAdded:Connect(function(character)
			local humanoid = character:WaitForChild("Humanoid", 10)
			if humanoid and humanoid:IsA("Humanoid") then
				humanoid.Died:Connect(function()
					local q = questsOf(player)
					for _, quest in (if q then q.active else {}) :: { [string]: QuestState } do
						local stage = stageOf(T[quest.template], quest.stage)
						if stage and stage.failOnDeath then
							finish(quest, stage.failOnDeath, nil)
						end
					end
				end)
			end
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, p in Players:GetPlayers() do
		watch(p)
	end
	Players.PlayerRemoving:Connect(function(player)
		directorCount[player] = nil
		lastPins[player] = nil
		local q = questsOf(player)
		for _, quest in (if q then q.active else {}) :: { [string]: QuestState } do
			release(quest) -- leashes and spawns don't outlive the session (the quest itself is saved)
		end
	end)

	task.spawn(function()
		while true do
			if enabled() then
				scan()
			end
			task.wait(Q.scanSeconds)
		end
	end)
	-- Map pins: re-checked every PIN_SECONDS (people move); only changes are sent.
	task.spawn(function()
		while true do
			task.wait(PIN_SECONDS)
			if enabled() then
				for _, player in Players:GetPlayers() do
					local ok, err = pcall(pushPins, player)
					if not ok then
						log:throttled("quest_pins", 60, "Warn", "pins_failed", { err = err })
					end
				end
			end
		end
	end)
	-- Director: one player per slice, so a full server spreads its decisions evenly.
	task.spawn(function()
		local index = 0
		while true do
			local list = Players:GetPlayers()
			local slice = Q.directorSeconds / math.max(1, #list)
			task.wait(math.max(0.5, slice))
			if enabled() and #list > 0 then
				index = index % #list + 1
				local player = list[index]
				local ok, err = pcall(directorTick, player)
				if not ok then
					log:throttled("quest_director", 60, "Warn", "director_failed", { err = err })
				end
			end
		end
	end)
	task.spawn(function()
		local last = os.clock()
		local lastHour = math.floor(WorldClock.now() * 24)
		while true do
			task.wait(Q.pollSeconds)
			local t = os.clock()
			if enabled() then
				poll(t - last)
				local hourIndex = math.floor(WorldClock.now() * 24)
				if hourIndex ~= lastHour then
					lastHour = hourIndex
					pcall(hourly, hourIndex)
				end
			end
			last = t
		end
	end)
end

return QuestDirector
