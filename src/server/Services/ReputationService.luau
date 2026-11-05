--!strict
--[[
	ReputationService: how the world regards each player (docs/Quests.md §5). Owns the numbers;
	FactionService decides which deeds move them.

	PlayerData fields (filled into old saves by reconcile):
		factions   { [factionId] = standing -1000..1000 }
		reputation { [settlementId] = standing } (existing: crimes negative, deeds positive)
		infamy     { v, t }   0..100, decays decayPerHour (real hours), lazily from t
		bounties   { [settlementId] = { amount, faction, reason, t } }
		notoriety  { [mythicDomain] = { v, t } }   how visible your mythic magic is (the Quiet Hand)

	API
		standing(player, faction) / rankOf(standing) / addStanding(player, faction, delta, reason)
		    addStanding spreads to allies (+allyShare x relation) and enemies (-enemyShare x |relation|)
		    unless opts.direct; logs rank changes and big moves to the journal
		addSettlement(player, settlementId, delta, reason)
		infamyOf(player) / addInfamy(player, amount, reason)
		crime(player, settlementId, severity, reason)   infamy + Concord standing; a bounty once
		                                     infamy >= bountyAt (Topics.CrimeCommitted calls this)
		bountiesOf(player) / clearBounty(player, settlementId) / addBounty(...)
		notorietyOf(player) / addNotoriety(player, domain, amount)
	Topic: ReputationChanged { player, faction?, settlementId?, delta, standing }.
	Journal tab "factions": every faction you know (secret ones once revealed), rank words,
	infamy, bounties. Exact standings are shown; secret factions' are shown once revealed.

	Admin: faction <faction> <value> [player], infamy <value> [player], bounty <settlement> <amount>
	[player], rep (existing), notoriety <domain> <value> [player], standings [player].
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Topics = require(Shared.Core.Topics)

local Server = script.Parent.Parent
local FactionData = require(Server.Quests.Data.Factions)
local Q = require(Server.Quests.Data.QuestTuning)

local F = FactionData.factions

local ReputationService = {
	name = "ReputationService",
	dependencies = { "PlayerDataService", "JournalService", "AdminService", "WorldStateService" },
}

local bus: any = nil
local log: any = nil
local playerData: any = nil
local journal: any = nil
local world: any = nil

local function dataOf(player: Player): any?
	local state = playerData:get(player)
	if not state then
		return nil
	end
	local d = state.data
	d.factions = d.factions or {}
	d.reputation = d.reputation or {}
	d.infamy = d.infamy or { v = 0, t = os.time() }
	d.bounties = d.bounties or {}
	d.notoriety = d.notoriety or {}
	return d
end

function ReputationService.rankOf(_self: any, standing: number): { id: string, name: string, min: number }
	for _, rank in FactionData.ranks do
		if standing >= rank.min then
			return rank
		end
	end
	return FactionData.ranks[#FactionData.ranks]
end

function ReputationService.standing(_self: any, player: Player, factionId: string): number
	local d = dataOf(player)
	return if d then d.factions[factionId] or 0 else 0
end

local function setStanding(self: any, player: Player, d: any, factionId: string, delta: number, reason: string, quiet: boolean)
	local before = d.factions[factionId] or 0
	local after = math.clamp(before + delta, -FactionData.limit, FactionData.limit)
	if after == before then
		return
	end
	d.factions[factionId] = after
	bus:publish(Topics.ReputationChanged, { player = player, faction = factionId, delta = after - before, standing = after })
	local faction = F[factionId]
	local known = not faction.secret or journal:isRevealed(player, factionId)
	if not quiet and known then
		local r0, r1 = self:rankOf(before), self:rankOf(after)
		if r0.id ~= r1.id then
			journal:log(player, "reputation", string.format("%s now regard you as %s (%s).", faction.name, r1.name, reason))
		elseif math.abs(after - before) >= 20 then
			journal:log(player, "reputation", string.format("%s %s you (%s).", faction.name, if delta > 0 then "think better of" else "think less of", reason))
		end
	end
end

-- Standing with a faction, spread to its allies and enemies (opts.direct = no spread).
function ReputationService.addStanding(self: any, player: Player, factionId: string, delta: number, reason: string, opts: { direct: boolean? }?)
	local d = dataOf(player)
	local faction = F[factionId]
	if not d or not faction or delta == 0 then
		return
	end
	setStanding(self, player, d, factionId, delta, reason, false)
	if opts and opts.direct then
		return
	end
	for otherId, relation in faction.relations do
		if F[otherId] then
			local spread = if relation > 0 then delta * FactionData.allyShare * relation else -delta * FactionData.enemyShare * math.abs(relation)
			if math.abs(spread) >= 1 then
				setStanding(self, player, d, otherId, spread, reason, true)
			end
		end
	end
end

function ReputationService.settlement(_self: any, player: Player, settlementId: string): number
	local d = dataOf(player)
	return if d then d.reputation[settlementId] or 0 else 0
end

function ReputationService.addSettlement(_self: any, player: Player, settlementId: string, delta: number, _reason: string)
	local d = dataOf(player)
	if not d or delta == 0 then
		return
	end
	d.reputation[settlementId] = (d.reputation[settlementId] or 0) + delta
	bus:publish(Topics.ReputationChanged, { player = player, settlementId = settlementId, delta = delta, standing = d.reputation[settlementId] })
end

-- ─── Infamy, crime and bounties ─────────────────────────────────────────────

local function decayed(entry: { v: number, t: number }, perHour: number): number
	local hours = math.max(0, os.time() - entry.t) / 3600
	return math.max(0, entry.v - perHour * hours)
end

function ReputationService.infamyOf(_self: any, player: Player): number
	local d = dataOf(player)
	return if d then decayed(d.infamy, Q.infamy.decayPerHour) else 0
end

function ReputationService.addInfamy(self: any, player: Player, amount: number, reason: string)
	local d = dataOf(player)
	if not d or amount == 0 then
		return
	end
	local v = math.clamp(self:infamyOf(player) + amount, 0, Q.infamy.max)
	d.infamy = { v = v, t = os.time() }
	if amount >= 5 then
		journal:log(player, "crime", string.format("Your name is spoken darkly (%s).", reason))
	end
end

function ReputationService.bountiesOf(_self: any, player: Player): { [string]: { amount: number, faction: string, reason: string, t: number } }
	local d = dataOf(player)
	return if d then d.bounties else {}
end

function ReputationService.addBounty(_self: any, player: Player, settlementId: string, amount: number, factionId: string, reason: string)
	local d = dataOf(player)
	if not d or amount <= 0 then
		return
	end
	local existing = d.bounties[settlementId]
	local total = (if existing then existing.amount else 0) + amount
	d.bounties[settlementId] = { amount = math.floor(total), faction = factionId, reason = reason, t = os.time() }
	local name = settlementId
	for _, s in world:placement().settlements do
		if s.id == settlementId then
			name = s.name
		end
	end
	journal:log(player, "crime", string.format("A bounty of %d is posted for you in %s (%s).", math.floor(total), name, reason))
end

function ReputationService.clearBounty(_self: any, player: Player, settlementId: string): number
	local d = dataOf(player)
	local b = d and d.bounties[settlementId]
	if not d or not b then
		return 0
	end
	d.bounties[settlementId] = nil
	return b.amount
end

--[[
	A crime in a settlement (casting forbidden magic there, assaulting a citizen...). `severity` is
	the settlement reputation already lost. Raises infamy, lowers the Concord's standing, and once
	infamy crosses bountyAt, the Concord posts (or raises) a bounty in that settlement.
]]
function ReputationService.crime(self: any, player: Player, settlementId: string?, severity: number, reason: string)
	if severity <= 0 then
		return
	end
	self:addInfamy(player, severity * Q.infamy.crimeScale, reason)
	self:addStanding(player, "island_concord", -severity, reason, { direct = true })
	local infamy = self:infamyOf(player)
	if settlementId and infamy >= Q.infamy.bountyAt then
		self:addBounty(player, settlementId, severity * Q.infamy.bountyPerInfamy, "island_concord", reason)
	end
	bus:publish(Topics.CrimeRecorded, { player = player, settlementId = settlementId, severity = severity, reason = reason, infamy = infamy })
end

-- ─── Mythic notoriety ───────────────────────────────────────────────────────

function ReputationService.notorietyOf(_self: any, player: Player): { [string]: number }
	local d = dataOf(player)
	local out: { [string]: number } = {}
	if d then
		for domain, entry in d.notoriety do
			out[domain] = decayed(entry, Q.mythicNotoriety.decayPerHour)
		end
	end
	return out
end

function ReputationService.addNotoriety(self: any, player: Player, domain: string, amount: number)
	local d = dataOf(player)
	if not d or amount == 0 then
		return
	end
	local current = self:notorietyOf(player)[domain] or 0
	d.notoriety[domain] = { v = math.clamp(current + amount, 0, 100), t = os.time() }
end

-- ─── Journal tab ────────────────────────────────────────────────────────────

local function factionsView(player: Player, _page: number): any
	local d = dataOf(player)
	if not d then
		return {}
	end
	local list = {}
	for id, faction in F do
		local known = not faction.secret or journal:isRevealed(player, id)
		if known then
			local standing = d.factions[id] or 0
			table.insert(list, {
				id = id,
				name = faction.name,
				kind = faction.kind,
				description = faction.description,
				ideology = faction.ideology,
				standing = math.floor(standing),
				rank = ReputationService:rankOf(standing).name,
				secret = faction.secret == true,
			})
		end
	end
	table.sort(list, function(a, b)
		return a.name < b.name
	end)
	local bounties = {}
	for settlementId, b in d.bounties do
		local name = settlementId
		for _, s in world:placement().settlements do
			if s.id == settlementId then
				name = s.name
			end
		end
		table.insert(bounties, { settlement = name, amount = b.amount, reason = b.reason })
	end
	return { factions = list, infamy = math.floor(ReputationService:infamyOf(player)), bounties = bounties }
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	local factionIds = {}
	for id in F do
		table.insert(factionIds, id)
	end
	table.sort(factionIds)

	admin:Register({
		name = "faction", category = "Quests & factions", description = "Set your standing with a faction (-1000..1000)",
		args = {
			{ name = "faction", type = "enum", options = factionIds },
			{ name = "value", type = "number", min = -1000, max = 1000 },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local current = ReputationService:standing(a.player, a.faction)
			ReputationService:addStanding(a.player, a.faction, a.value - current, "admin", { direct = true })
			journal:reveal(a.player, a.faction)
			return string.format("%s: %s %d (%s)", a.player.Name, a.faction, a.value, ReputationService:rankOf(a.value).name)
		end,
	})
	admin:Register({
		name = "infamy", category = "Quests & factions", description = "Set infamy (0..100)",
		args = { { name = "value", type = "number", min = 0, max = 100 }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local d = dataOf(a.player)
			if not d then
				return "not loaded"
			end
			d.infamy = { v = a.value, t = os.time() }
			return string.format("%s infamy %d", a.player.Name, a.value)
		end,
	})
	admin:Register({
		name = "bounty", category = "Quests & factions", description = "Post (or with 0, clear) a bounty in a settlement",
		args = { { name = "settlement", type = "settlement" }, { name = "amount", type = "integer", min = 0, max = 100000 }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local id = if typeof(a.settlement) == "table" then a.settlement.id else a.settlement
			if a.amount == 0 then
				return "cleared " .. tostring(ReputationService:clearBounty(a.player, id))
			end
			ReputationService:addBounty(a.player, id, a.amount, "island_concord", "admin")
			return "bounty posted"
		end,
	})
	admin:Register({
		name = "notoriety", category = "Quests & factions", description = "Set mythic notoriety for a domain (0..100; the Quiet Hand hunts at " .. Q.mythicNotoriety.huntAt .. ")",
		args = { { name = "domain", type = "enum", options = { "time", "gravity", "reality" } }, { name = "value", type = "number", min = 0, max = 100 }, { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local d = dataOf(a.player)
			if not d then
				return "not loaded"
			end
			d.notoriety[a.domain] = { v = a.value, t = os.time() }
			return string.format("%s %s notoriety %d", a.player.Name, a.domain, a.value)
		end,
	})
	admin:Register({
		name = "standings", category = "Quests & factions", description = "Every faction standing, infamy, bounties and notoriety (secret factions included)",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_, a)
			local d = dataOf(a.player)
			if not d then
				return "not loaded"
			end
			local lines = {}
			for _, id in factionIds do
				local s = d.factions[id] or 0
				table.insert(lines, string.format("%-16s %5d %s%s", id, math.floor(s), ReputationService:rankOf(s).name, if F[id].secret then " (secret)" else ""))
			end
			table.insert(lines, string.format("infamy %.1f", ReputationService:infamyOf(a.player)))
			for settlementId, b in d.bounties do
				table.insert(lines, string.format("bounty %s %d (%s)", settlementId, b.amount, b.reason))
			end
			for domain, v in ReputationService:notorietyOf(a.player) do
				table.insert(lines, string.format("notoriety %s %.1f", domain, v))
			end
			return table.concat(lines, "\n")
		end,
	})
end

function ReputationService.init(_self: any, ctx: any)
	bus, log = ctx.bus, ctx.log
	playerData = ctx.get("PlayerDataService")
	journal = ctx.get("JournalService")
	world = ctx.get("WorldStateService")
	journal:setTab("factions", factionsView)
	registerAdmin(ctx.get("AdminService"))
	-- Crimes judged elsewhere (WorldStateService.judgeCast, FactionService) arrive as a topic.
	bus:subscribe(Topics.CrimeCommitted, function(payload: any)
		local player: Player? = payload.player
		if player and player.Parent then
			ReputationService:crime(player, payload.settlementId, payload.severity, payload.reason)
		end
	end)
end

function ReputationService.start(_self: any, _ctx: any)
	log:debug("reputation_ready", {})
end

return ReputationService
