--!strict
--[[
	SituationDetector: finds the quest-worthy conditions in the simulation (docs/Quests.md §1).
	It never invents trouble: every situation is read off state that already exists.

	WORLD SCAN (scanWorld, every QuestTuning.scanSeconds, inside a Scheduler job)
		tunnel_collapse   a mine with high tectonic stress or exhausted ore, and a miner nearby
		drought/ley_shift a drought event over a settlement, or the settlement's ambient density low
		tremors           tectonic stress under a settlement above stressThreshold
		flood             a tempest over a coastal settlement
		wildfire / plague those world events over a settlement
		dispute           two settlements whose relation has soured below hostileRelation
	NPC SCAN (round-robin, npcScanPerPass per pass, so 300 NPCs cost the same as 60)
		forbidden_experiment  a young mage with the forbidden_dabble secret or the forbidden ambition
		npc_goal_commission   goal "commission" / "savings"
		npc_goal_journey      goal "journey" / "reconcile", ambition "see_world" / "lost_sibling"
		proud_rival           pride > 0.7 and a real mage (tier >= 2)
		debt_trouble          secret "debt" or "thief"
		rogue_mage            a rogue (NPCMagicLife)
	PLAYER SCAN (scanPlayer, by the Director per player; forUserId set)
		wants_teacher     an NPC nearby studies a branch you're 2+ tiers ahead in
		lore_gap          a sub-branch whose ONLY unmet unlock condition is its treatise
		mythic_trail      you hold a hint toward a mythic domain but not its fragment
		wanted            you have a bounty somewhere (ReputationService)
		mythic_notoriety  your mythic notoriety crossed huntAt (the Quiet Hand)

	Ids are deterministic ("<kind>:<subject>"), so a condition that persists is the same situation
	on every scan, and nothing is offered twice for it. Nothing here reads a player's hidden latents.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)

local Server = script.Parent.Parent
local SubBranchRules = require(Server.Progression.SubBranchRules)
local Settlements = require(Server.World.Settlements)
local Progression = require(Server.Progression.Progression)
local NPCMagicLife = require(Server.NPC.NPCMagicLife)
local QuestTypes = require(script.Parent.QuestTypes)
local Q = require(script.Parent.Data.QuestTuning)

type Situation = QuestTypes.Situation

export type Deps = {
	world: any, -- WorldStateService
	events: any, -- EventDirector
	npcs: any, -- NPCService
	reputation: any, -- ReputationService
}

local SituationDetector = {}

local npcCursor = 0

local function situation(kind: string, subject: string, x: number, z: number, severity: number, facts: { [string]: any }, source: string): Situation
	local t = os.time()
	return {
		id = kind .. ":" .. subject,
		kind = kind,
		x = x,
		z = z,
		settlementId = facts.settlementId,
		severity = math.clamp(severity, 0, 1),
		facts = facts,
		source = source,
		forUserId = nil,
		detectedAt = t,
		expiresAt = t + Q.situationHours * 3600,
	}
end

local function nearestSettlement(world: any, x: number, z: number, maxDistance: number, except: string?): any?
	local best, bestD = nil, maxDistance * maxDistance
	for _, s in world:placement().settlements do
		local d = (s.x - x) ^ 2 + (s.z - z) ^ 2
		if d < bestD and s.id ~= except then
			best, bestD = s, d
		end
	end
	return best
end

-- An NPC of one of `occupations` living in a settlement (lowest id: deterministic).
local function npcOf(npcs: any, settlementId: string, occupations: { string }): any?
	local best = nil
	for _, town in npcs:towns() do
		if town.id == settlementId then
			for _, npc in town.npcs do
				if not npc.knockedOut and table.find(occupations, npc.occupation) and (not best or npc.id < best.id) then
					best = npc
				end
			end
		end
	end
	return best
end

-- Settlements whose relation with `s` is friendliest (for deliveries and journeys).
local function friendliestOther(world: any, s: any): any?
	local best, bestValue = nil, -math.huge
	for _, other in world:placement().settlements do
		if other.id ~= s.id then
			local value = (s.relations[other.id] or 0) - math.sqrt((other.x - s.x) ^ 2 + (other.z - s.z) ^ 2) / 4000
			if value > bestValue then
				best, bestValue = other, value
			end
		end
	end
	return best
end

-- ─── World ──────────────────────────────────────────────────────────────────

local EVENT_KINDS: { [string]: string } = { drought = "drought", wildfire = "wildfire", plague = "plague" }

local function scanSettlements(deps: Deps, out: { Situation })
	local world, events = deps.world, deps.events
	for _, s in world:placement().settlements do
		-- World events over the settlement.
		for _, e in events:activeAt(s.x, s.z) do
			local kind = EVENT_KINDS[e.type]
			if kind then
				table.insert(out, situation(kind, e.id .. ":" .. s.id, e.x, e.z, 0.6, {
					settlementId = s.id, eventId = e.id, causeText = if kind == "drought" then " in the drought" else "",
				}, "event"))
			elseif e.type == "tempest" and Settlements.cultures[s.culture].coastal then
				table.insert(out, situation("flood", e.id .. ":" .. s.id, s.x, s.z, 0.8, { settlementId = s.id, eventId = e.id }, "event"))
			end
		end
		-- A ley shift: magic has drained out of the place.
		local density = world:densityAt(s.x, s.z)
		if density < Q.lowDensity then
			table.insert(out, situation("ley_shift", s.id, s.x, s.z, 1 - density, {
				settlementId = s.id, causeText = " since the ley line shifted",
			}, "world"))
		end
		-- Tremors: stress under the town.
		local stress = world:stressAt(s.x, s.z)
		if stress > Q.stressThreshold then
			table.insert(out, situation("tremors", s.id, s.x, s.z, stress, { settlementId = s.id }, "world"))
		end
		-- Disputes (each pair once: lower id first).
		for otherId, relation in s.relations do
			if s.id < otherId and relation < Q.hostileRelation then
				table.insert(out, situation("dispute", s.id .. "|" .. otherId, s.x, s.z, -relation, { settlementId = s.id, otherSettlementId = otherId }, "world"))
			end
		end
	end
end

local function scanMines(deps: Deps, out: { Situation })
	local world, npcs = deps.world, deps.npcs
	for _, poi in world:placement().pois do
		if poi.type == "mine" then
			local stress = world:stressAt(poi.x, poi.z)
			if stress > Q.stressThreshold * 0.85 then
				local s = nearestSettlement(world, poi.x, poi.z, Q.mineStressRadius * 4)
				local miner = s and npcOf(npcs, s.id, { "miner", "smith" })
				if s and miner then
					table.insert(out, situation("tunnel_collapse", poi.id, poi.x, poi.z, stress, {
						settlementId = s.id, poiId = poi.id, npcId = miner.id,
					}, "world"))
				end
			end
		end
	end
end

-- ─── NPCs ───────────────────────────────────────────────────────────────────

local function npcSituations(deps: Deps, npc: any, out: { Situation })
	if npc.knockedOut or not npc.magic then
		return
	end
	local world = deps.world
	local x, z = npc.position.X, npc.position.Z
	local s = nil
	for _, settlement in world:placement().settlements do
		if settlement.id == npc.settlementId then
			s = settlement
		end
	end
	if not s then
		return
	end
	local base = { npcId = npc.id, settlementId = s.id }
	local function with(extra: { [string]: any }): { [string]: any }
		local f = table.clone(base)
		for k, v in extra do
			f[k] = v
		end
		return f
	end
	local magic = npc.magic
	local _, _, tier = NPCMagicLife.best(npc)
	local secret = npc.secret and npc.secret.id
	local ambition = npc.ambition and npc.ambition.id
	local goal = npc.goal and npc.goal.id

	if (secret == "forbidden_dabble" or ambition == "forbidden") and npc.age >= 14 and npc.age <= 35 and tier >= 1 then
		table.insert(out, situation("forbidden_experiment", npc.id, x, z, 0.7, base, "npc"))
	end
	if goal == "commission" or goal == "savings" then
		local other = friendliestOther(world, s)
		if other then
			table.insert(out, situation("npc_goal_commission", npc.id, x, z, 0.2, with({ otherSettlementId = other.id }), "npc"))
		end
	end
	if goal == "journey" or goal == "reconcile" or ambition == "see_world" or ambition == "lost_sibling" then
		local other = friendliestOther(world, s)
		if other and npc.ageBand ~= "child" then
			local text = if goal == "reconcile" then "make peace with family in " .. other.name else "see " .. other.name
			table.insert(out, situation("npc_goal_journey", npc.id, x, z, 0.4, with({ otherSettlementId = other.id, goalText = text }), "npc"))
		end
	end
	if (npc.traits.pride or 0) > 0.7 and tier >= 2 and npc.ageBand ~= "child" then
		table.insert(out, situation("proud_rival", npc.id, x, z, 0.5, with({ tier = tier }), "npc"))
	end
	if secret == "debt" or secret == "thief" then
		table.insert(out, situation("debt_trouble", npc.id, x, z, 0.5, base, "npc"))
	end
	if magic.rogue then
		table.insert(out, situation("rogue_mage", npc.id, x, z, 0.6, base, "npc"))
	end
end

--[[
	One world pass. `checkpoint` (Scheduler.checkpoint) is called between expensive parts so a pass
	never holds a frame. Returns every situation currently true (the Director merges by id).
]]
function SituationDetector.scanWorld(deps: Deps, checkpoint: (() -> ())?): { Situation }
	local out: { Situation } = {}
	scanSettlements(deps, out)
	if checkpoint then
		checkpoint()
	end
	scanMines(deps, out)
	if checkpoint then
		checkpoint()
	end
	local all = deps.npcs:all()
	local n = #all
	if n > 0 then
		for _ = 1, math.min(n, Q.npcScanPerPass) do
			npcCursor = npcCursor % n + 1
			npcSituations(deps, all[npcCursor], out)
		end
	end
	return out
end

-- ─── Players ────────────────────────────────────────────────────────────────

local MYTHICS = { "time", "gravity", "reality" }

local function personal(kind: string, subject: string, userId: number, x: number, z: number, severity: number, facts: { [string]: any }): Situation
	local s = situation(kind, subject .. ":u" .. userId, x, z, severity, facts, "player")
	s.forUserId = userId
	return s
end

--[[
	Situations that exist because of who this player is. `state` is their PlayerData state;
	`position` their character's position.
]]
function SituationDetector.scanPlayer(deps: Deps, player: Player, state: any, position: Vector3): { Situation }
	local out: { Situation } = {}
	local userId = player.UserId
	local p = state.data.progression
	local x, z = position.X, position.Z

	-- Lore gaps: a sub-branch whose only missing condition is its written knowledge.
	for branchId in p.unlocked do
		for _, child in Registry.branchIds do
			local def = Registry.branches[child]
			if def.parent == branchId and not p.unlocked[child] and Registry.domains[def.domains[1]].rarity ~= "Mythic" then
				local ok, checks = SubBranchRules.evaluate(p, state.innate, child)
				if not ok then
					local onlyLore = true
					local loreMissing = false
					for _, check in checks do
						if not check.met then
							if check.kind == "lore" then
								loreMissing = true
							else
								onlyLore = false
							end
						end
					end
					if onlyLore and loreMissing then
						table.insert(out, personal("lore_gap", child, userId, x, z, 0.3, { branch = child, branch_parent = branchId }))
					end
				end
			end
		end
	end

	-- Mythic trails: a hint held, the fragment not.
	for _, domain in MYTHICS do
		local hinted = false
		for loreId in p.lore do
			if string.sub(loreId, 1, #("hint:" .. domain .. ":")) == "hint:" .. domain .. ":" then
				hinted = true
				break
			end
		end
		local root = Registry.branches[domain]
		local hasFragment = false
		for _, child in Registry.branchIds do
			if Registry.branches[child].parent == (root and root.id) and p.lore["fragment:" .. child] then
				hasFragment = true
			end
		end
		if hinted and not hasFragment then
			table.insert(out, personal("mythic_trail", domain, userId, x, z, 0.4, { domain = domain }))
		end
	end

	-- Students: an NPC nearby working at a branch you're far ahead in.
	local npcs = deps.npcs
	local bestTier: { [string]: number } = {}
	for branchId in p.unlocked do
		bestTier[branchId] = Progression.getMasteryTier(p, branchId)
	end
	for _, record in npcs:all() do
		local magic = record.magic
		if magic and not record.knockedOut and (record.position - position).Magnitude <= 120 then
			local focus = magic.focus or next(magic.unlocked)
			if focus and bestTier[focus] and bestTier[focus] >= 3 and bestTier[focus] >= NPCMagicLife.tierOf(record, focus) + 2 then
				table.insert(out, personal("wants_teacher", record.id, userId, x, z, 0.2, { npcId = record.id, settlementId = record.settlementId, branch = focus }))
				break -- one student at a time
			end
		end
	end

	-- Reputation: bounties and the Quiet Hand.
	local rep = deps.reputation
	for settlementId, bounty in rep:bountiesOf(player) do
		local s = nil
		for _, settlement in deps.world:placement().settlements do
			if settlement.id == settlementId then
				s = settlement
			end
		end
		if s then
			table.insert(out, personal("wanted", settlementId, userId, s.x, s.z, 0.5, { settlementId = settlementId, bounty = bounty.amount }))
		end
	end
	local notoriety = rep:notorietyOf(player)
	for domain, value in notoriety do
		if value >= Q.mythicNotoriety.huntAt then
			table.insert(out, personal("mythic_notoriety", domain, userId, x, z, math.clamp(value / 100, 0, 1), { domain = domain }))
		end
	end
	return out
end

SituationDetector.MYTHICS = MYTHICS

-- Every kind a template may name (Tests/Quest.spec checks templates against it).
SituationDetector.KINDS = {
	"tunnel_collapse", "drought", "ley_shift", "tremors", "flood", "wildfire", "plague", "dispute",
	"forbidden_experiment", "npc_goal_commission", "npc_goal_journey", "proud_rival", "debt_trouble", "rogue_mage",
	"wants_teacher", "lore_gap", "mythic_trail", "wanted", "mythic_notoriety",
}

return SituationDetector
