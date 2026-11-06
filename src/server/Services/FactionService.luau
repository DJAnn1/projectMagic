--!strict
--[[
	FactionService: which NPCs belong to which faction, and which of a player's deeds each faction
	notices (docs/Quests.md §5). ReputationService holds the numbers.

	MEMBERSHIP  deterministic: an NPC matching a faction's member rule (occupation / secret /
	            ambition, plus its territory when listed for members) joins with probability
	            `share`, rolled from Seed.random(worldSeed, npcId, "faction:<id>"). Quest-spawned
	            NPCs can carry npc.factionOverride (the Quiet Hand's hunters).
	SEEN        a deed counts for a faction when it happens in a settlement of its territory, or a
	            living member stands within witnessRadius, or the deed is always known (quest
	            outcomes, mythic awakenings: word travels).
	DEEDS       from topics:
	              SpellResolved  esteem (domain likes and dislikes, scaled by power, rate-limited),
	                             forbidden_magic, mind_on_people (Mind magic that hit people),
	                             healed_people, burned_land, mythic_cast (+ mythic notoriety)
	              TargetDamaged  assault_member (once a minute per NPC), knockout_member,
	                             knockout_citizen (the Concord) + a crime (CrimeCommitted)
	            and from QuestDirector (quest_helped, delivery_done, relief, diplomacy...).
	            Duels and quest hostiles are exempt (Humanoid attribute QuestSanction = userId).
	ENFORCEMENT every 5 s: a player with a bounty and infamy >= guardsEngageAt who stands in that
	            settlement is engaged by the guards near them (NPCCombat).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)

local Server = script.Parent.Parent
local FactionData = require(Server.Quests.Data.Factions)
local Q = require(Server.Quests.Data.QuestTuning)
local NPCCombat = require(Server.NPC.NPCCombat)
local PvpRules = require(Server.Magic.Cast.PvpRules)

local F = FactionData.factions

local ESTEEM_SCALE = 0.6 -- standing per point of recipe power x esteem
local ESTEEM_WINDOW = 600 -- seconds
local ESTEEM_CAP = 30 -- max |standing| from esteem per faction per window
local MIND_PROPERTIES = { emotion = true, memory = true, thought = true, will = true, illusion = true, perception = true }

local FactionService = {
	name = "FactionService",
	dependencies = { "PlayerDataService", "ReputationService", "JournalService", "NPCService", "WorldStateService", "WorldService", "AdminService" },
}

local log: any = nil
local bus: any = nil
local reputation: any = nil
local journal: any = nil
local npcs: any = nil
local world: any = nil
local worldSeed = 0

local members: { [string]: { any } } = {} -- faction -> NPC records (rebuilt each minute)
local membersBuiltAt = -math.huge
local esteemBucket: { [Player]: { [string]: { sum: number, since: number } } } = {}
local assaultSeen: { [string]: number } = {} -- "<userId>|<npcId>" -> os.clock()

-- ─── Membership ─────────────────────────────────────────────────────────────

local function matches(rule: any, npc: any): boolean
	if rule.occupations and table.find(rule.occupations, npc.occupation) then
		return true
	end
	if rule.secrets and npc.secret and table.find(rule.secrets, npc.secret.id) then
		return true
	end
	if rule.ambitions and npc.ambition and table.find(rule.ambitions, npc.ambition.id) then
		return true
	end
	return false
end

function FactionService.factionsOf(_self: any, npc: any): { string }
	local cached = npc.factions
	if cached then
		return cached
	end
	local out: { string } = {}
	if npc.factionOverride then
		table.insert(out, npc.factionOverride)
	end
	for id, faction in F do
		if id ~= npc.factionOverride and matches(faction.members, npc) then
			if Seed.random(worldSeed, tostring(npc.id), "faction:" .. id):NextNumber() < faction.members.share then
				table.insert(out, id)
			end
		end
	end
	table.sort(out)
	npc.factions = out
	return out
end

local function rebuildMembers()
	table.clear(members)
	for _, npc in npcs:all() do
		for _, id in FactionService:factionsOf(npc) do
			members[id] = members[id] or {}
			table.insert(members[id], npc)
		end
	end
	membersBuiltAt = os.clock()
end

function FactionService.membersOf(_self: any, factionId: string): { any }
	if os.clock() - membersBuiltAt > 60 then
		rebuildMembers()
	end
	return members[factionId] or {}
end

-- ─── Seeing ─────────────────────────────────────────────────────────────────

local function cultureAt(position: Vector3): (string?, string?)
	local s = world:settlementAt(position.X, position.Z)
	if s then
		return s.culture, s.id
	end
	return nil, nil
end

function FactionService.sees(self: any, factionId: string, position: Vector3?): boolean
	if not position then
		return false
	end
	local faction = F[factionId]
	local culture = cultureAt(position)
	if culture and table.find(faction.territory, culture) then
		return true
	end
	local r2 = Q.witnessRadius * Q.witnessRadius
	for _, npc in self:membersOf(factionId) do
		if not npc.knockedOut then
			local d = npc.position - position
			if d.X * d.X + d.Z * d.Z <= r2 then
				return true
			end
		end
	end
	return false
end

--[[
	A deed by a player. Every faction with an opinion on `deed` that sees it (or `opts.always`)
	moves the player's standing by deeds[deed] x (opts.magnitude or 1).
]]
function FactionService.deed(self: any, player: Player, deed: string, position: Vector3?, opts: { magnitude: number?, always: boolean?, only: string? }?)
	local o = opts or {}
	for id, faction in F do
		local delta = faction.deeds[deed]
		if delta and (not o.only or o.only == id) and (o.always or self:sees(id, position)) then
			reputation:addStanding(player, id, delta * (o.magnitude or 1), (string.gsub(deed, "_", " "))) -- parens: gsub also returns a count
		end
	end
end

-- ─── Magic seen ─────────────────────────────────────────────────────────────

local function anyoneNear(position: Vector3, caster: Player): boolean
	local r2 = Q.witnessRadius * Q.witnessRadius
	for _, other in Players:GetPlayers() do
		local root = other ~= caster and other.Character and other.Character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and (root.Position - position).Magnitude <= Q.witnessRadius then
			return true
		end
	end
	for _, npc in npcs:all() do
		local d = npc.position - position
		if not npc.knockedOut and d.X * d.X + d.Z * d.Z <= r2 then
			return true
		end
	end
	return false
end

local function onSpellResolved(payload: any)
	local player = Players:GetPlayerByUserId(payload.casterUserId)
	if not player then
		return
	end
	local point: Vector3 = payload.point
	local power: number = payload.power

	-- Esteem: what each faction thinks of the domain, rate-limited so it can't be farmed.
	if payload.effective and power >= 2 then
		local buckets = esteemBucket[player] or {}
		esteemBucket[player] = buckets
		local t = os.clock()
		for id, faction in F do
			local e = 0
			for _, d in payload.domains do
				e += faction.esteem[d] or 0
			end
			e /= math.max(1, #payload.domains)
			if e ~= 0 and FactionService:sees(id, point) then
				local b = buckets[id]
				if not b or t - b.since > ESTEEM_WINDOW then
					b = { sum = 0, since = t }
					buckets[id] = b
				end
				local delta = e * power * ESTEEM_SCALE
				local room = ESTEEM_CAP - math.abs(b.sum)
				if room > 0 then
					delta = math.clamp(delta, -room, room)
					b.sum += delta
					reputation:addStanding(player, id, delta, "your " .. payload.domains[1] .. " magic", { direct = true })
				end
			end
		end
	end

	if payload.forbidden then
		FactionService:deed(player, "forbidden_magic", point)
	end
	if table.find(payload.domains, "mind") and payload.hits > 0 and (payload.harmful or MIND_PROPERTIES[payload.property]) then
		FactionService:deed(player, "mind_on_people", point)
	end
	if payload.route == "restore" and payload.hits > 0 then
		FactionService:deed(player, "healed_people", point)
	end
	if payload.route == "ignite" and payload.effective then
		FactionService:deed(player, "burned_land", point)
	end
	for _, domain in payload.domains do
		if domain == "time" or domain == "gravity" or domain == "reality" then
			if anyoneNear(point, player) then
				reputation:addNotoriety(player, domain, Q.mythicNotoriety.perCast)
				FactionService:deed(player, "mythic_cast", point, { always = true, only = "quiet_hand", magnitude = 0.1 })
			end
		end
	end
end

-- ─── Harm to NPCs ───────────────────────────────────────────────────────────

local function onTargetDamaged(payload: any)
	local source = payload.sourceUserId
	local npcId = payload.npcId
	if not source or not npcId then
		return
	end
	local player = Players:GetPlayerByUserId(source)
	local npc = npcs:get(npcId)
	if not player or not npc then
		return
	end
	local humanoid: Humanoid? = payload.humanoid
	local sanction = humanoid and humanoid:GetAttribute("QuestSanction")
	if sanction == source or (typeof(sanction) == "number" and PvpRules.sameParty(sanction, source)) then
		return -- a duel, or someone who came to kill you (you or a party member's quest)
	end
	local position = npc.position
	local factions = FactionService:factionsOf(npc)
	if payload.killed then
		for _, id in factions do
			FactionService:deed(player, "knockout_member", position, { always = true, only = id })
		end
		FactionService:deed(player, "knockout_citizen", position, { only = "island_concord" })
		bus:publish(Topics.CrimeCommitted, { player = player, settlementId = npc.settlementId, severity = 15, reason = "knocking out " .. npc.name })
	else
		local key = source .. "|" .. tostring(npcId)
		local t = os.clock()
		if not assaultSeen[key] or t - assaultSeen[key] > 60 then
			assaultSeen[key] = t
			for _, id in factions do
				FactionService:deed(player, "assault_member", position, { always = true, only = id })
			end
			bus:publish(Topics.CrimeCommitted, { player = player, settlementId = npc.settlementId, severity = 3, reason = "attacking " .. npc.name })
		end
	end
end

-- ─── Enforcement ────────────────────────────────────────────────────────────

local function enforce()
	for _, player in Players:GetPlayers() do
		local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and reputation:infamyOf(player) >= Q.infamy.guardsEngageAt then
			local s = world:settlementAt(root.Position.X, root.Position.Z)
			if s and reputation:bountiesOf(player)[s.id] then
				for _, npc in FactionService:membersOf("island_concord") do
					if npc.settlementId == s.id and npc.rig and npc.tier == 0 and (npc.position - root.Position).Magnitude < 45 then
						NPCCombat.onWitness(npc, "u:" .. player.UserId)
					end
				end
			end
		end
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function FactionService.init(_self: any, ctx: any)
	log, bus = ctx.log, ctx.bus
	reputation = ctx.get("ReputationService")
	journal = ctx.get("JournalService")
	npcs = ctx.get("NPCService")
	world = ctx.get("WorldStateService")
	local worldService = ctx.get("WorldService")
	bus:subscribe(Topics.SpellResolved, onSpellResolved)
	bus:subscribe(Topics.TargetDamaged, onTargetDamaged)
	task.defer(function()
		worldSeed = worldService:getSeed()
	end)

	ctx.get("AdminService"):Register({
		name = "npcfactions", category = "Quests & factions", description = "Which factions an NPC belongs to (secret ones included)",
		args = { { name = "npc", type = "npc", default = "nearest" } },
		handler = function(_, a)
			local list = FactionService:factionsOf(a.npc)
			return a.npc.name .. ": " .. (if #list > 0 then table.concat(list, ", ") else "none")
		end,
	})
	ctx.get("AdminService"):Register({
		name = "reveal", category = "Quests & factions", description = "Reveal a secret faction to a player's journal",
		args = { { name = "faction", type = "enum", options = { "hollow_choir", "quiet_hand", "seam_keepers" } }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			journal:reveal(a.player, a.faction, F[a.faction].name)
			return "revealed " .. a.faction
		end,
	})
end

function FactionService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		esteemBucket[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(5)
			local ok, err = pcall(enforce)
			if not ok then
				log:throttled("faction_enforce", 60, "Warn", "enforce_failed", { err = err })
			end
		end
	end)
end

return FactionService
