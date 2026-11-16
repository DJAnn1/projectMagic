--!strict
--[[
	NpcFightService: NPCs fighting each other, for reasons inside the world (docs/NpcFights.md).
	The fighting itself is NPC/NPCCombat (the same bolts, guards and courage as against a player,
	aimed at "n:<npcId>" subjects); this service decides when people come to blows and how it ends.

	BRAWL   In a town a player can see (NPCs at T0), in the evening, two free adults standing close
	        who can't stand each other (FightRules.grudge: rivalry, dislike, clashing tempers) may
	        come to blows: a seeded roll per pair and game hour. Words first (they stop and face
	        each other), then spells held to a low power. Nobody drops below `floor` of their health
	        (the HealthFloor attribute, as a duel). It ends when one is beaten, a guard walks over and
	        breaks it up, one runs, or they've had enough. After: their rivalry deepens, the loser
	        and winner say something, bystanders remember it and talk about it. A brawl isn't the
	        guards' business until one walks over: NPCService doesn't send witnesses at brawlers.
	RAID    Services/AgendaService calls raid() when a feuding town's raid comes due with a player
	        near. Real fighters of the raiding town (guards and hunters first, then the bravest;
	        only ones out of sight, so nobody vanishes in front of a player) come in at the edge
	        facing their own town and walk for a building. A guard or hunter of the town who sees
	        one turns on them; a raider meeting a defender who's fighting answers. A raider reaching
	        the building sets it alight and they all go home ("burned"); all of them beaten or run
	        ("driven_off"); too long ("driven_off", they give up). They walk home after; anyone
	        knocked out wakes at home (NPCService).

	Flag npc_fights_enabled (also lets Wildborn fight NPCs, Services/WildbornService).
	Admin: fights, brawlnow [npc], npcvsnpc <a> <b>.
	Log: npc_brawl_started, npc_brawl_ended, npc_raid_started, npc_raid_ended.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Seed = require(Shared.Magic.Seed)

local Server = ServerScriptService.Server
local FightRules = require(Server.Fights.FightRules)
local Data = require(Server.Fights.Data.Fights)
local WorldClock = require(Server.NPC.WorldClock)
local NPCCombat = require(Server.NPC.NPCCombat)
local RelationshipGraph = require(Server.NPC.RelationshipGraph)
local Navigation = require(Server.NPC.NavigationService)
local FireSim = require(Server.Magic.Cast.FireSim)

local B = Data.tuning.brawl
local R = Data.tuning.raid
local SPEAK_RADIUS = 70

local NpcFightService = {
	name = "NpcFightService",
	dependencies = { "AdminService", "AmbientLifeService", "NPCService", "WorldService" },
}

type Brawl = {
	id: number,
	town: any,
	a: any, -- the one who started it
	b: any,
	phase: string, -- "words" | "fight"
	started: number, -- os.clock()
	fightAt: number,
	guard: any?,
	watched: boolean,
}

type Raid = {
	id: string,
	town: any,
	other: any,
	raiders: { any },
	target: BasePart?,
	from: Vector3,
	started: number,
	burned: boolean,
	greeted: { [any]: boolean },
	onDone: (string) -> (),
}

local log: any = nil
local npcs: any = nil
local ambient: any = nil
local worldService: any = nil
local brawls: { Brawl } = {}
local raids: { [string]: Raid } = {}
local brawlCount = 0
local nextLook: { [string]: number } = {} -- town id -> os.clock() of its next brawl look
local pairUntil: { [string]: number } = {} -- pair key -> game time it may happen again
local npcUntil: { [string]: number } = {} -- npc id -> game time

local function enabled(): boolean
	return FeatureFlags.get("npc_fights_enabled") == true
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function pairKey(a: any, b: any): string
	return if a.id < b.id then a.id .. "|" .. b.id else b.id .. "|" .. a.id
end

local function townName(town: any): string
	return if town and town.settlement and town.settlement.name then tostring(town.settlement.name) else "that town"
end

-- One line over someone's head, from this service's lines.
local function line(npc: any, category: string, vars: { [string]: string }?)
	if not npc.rig or npc.knockedOut then
		return
	end
	local text = ambient:lineFor(npc, nil, { category }, Data.lines, vars or {})
	if text then
		npcs:speak(npc, text, SPEAK_RADIUS)
	end
end

local function healthShare(npc: any): number
	local rig = npc.rig
	if not rig then
		return 1
	end
	return rig.humanoid.Health / math.max(1, rig.humanoid.MaxHealth)
end

local function setFloor(npc: any, on: boolean)
	local rig = npc.rig
	if not rig then
		return
	end
	rig.humanoid:SetAttribute("HealthFloor", if on then rig.humanoid.MaxHealth * B.floor else nil)
end

local function inBrawl(npc: any): boolean
	for _, b in brawls do
		if b.a == npc or b.b == npc or b.guard == npc then
			return true
		end
	end
	return false
end

-- ─── Brawls ─────────────────────────────────────────────────────────────────

local function startBrawl(town: any, a: any, b: any, forced: boolean)
	-- The shorter temper starts it.
	if (b.traits.agreeableness or 0.5) < (a.traits.agreeableness or 0.5) then
		a, b = b, a
	end
	brawlCount += 1
	local brawl: Brawl = { id = brawlCount, town = town, a = a, b = b, phase = "words", started = os.clock(), fightAt = os.clock() + B.words, watched = false }
	table.insert(brawls, brawl)
	for _, npc in { a, b } do
		npcs:setLeash(npc, { kind = "hold", position = npc.position })
	end
	line(a, "brawl_words_a", { name = b.name })
	task.delay(1.6, function()
		if table.find(brawls, brawl) then
			line(b, "brawl_words_b", { name = a.name })
		end
	end)
	log:info("npc_brawl_started", {
		town = town.id,
		a = a.id,
		b = b.id,
		forced = forced,
		grudge = math.floor(FightRules.grudge(a, b, RelationshipGraph.peek(a.id, b.id), RelationshipGraph.peek(b.id, a.id)) * 100) / 100,
	})
end

local function endBrawl(brawl: Brawl, how: string)
	local i = table.find(brawls, brawl)
	if i then
		table.remove(brawls, i)
	end
	local a, b = brawl.a, brawl.b
	for _, npc in { a, b } do
		setFloor(npc, false)
		if NPCCombat.reason(npc) == "brawl" then
			NPCCombat.disengage(npc)
		end
		if npc.leash then
			npcs:setLeash(npc, nil)
		end
	end
	if brawl.guard then
		npcs:setLeash(brawl.guard, nil)
	end
	local now = WorldClock.now()
	pairUntil[pairKey(a, b)] = now + B.pairCooldown
	npcUntil[a.id] = now + B.npcCooldown
	npcUntil[b.id] = now + B.npcCooldown
	if brawl.phase == "fight" then
		-- It happened: it isn't forgotten.
		RelationshipGraph.adjust(a.id, b.id, -0.1, -0.08, 0.15)
		RelationshipGraph.adjust(b.id, a.id, -0.1, -0.08, 0.15)
		local winner, loser = nil, nil
		if how == "a_won" then
			winner, loser = a, b
		elseif how == "b_won" then
			winner, loser = b, a
		end
		if winner and loser then
			npcs:remember(winner, "duel_won", loser.id, 0.5)
			npcs:remember(loser, "duel_lost", winner.id, 0.7)
			line(loser, "brawl_lost", { name = winner.name })
			task.delay(1.4, function()
				line(winner, "brawl_won", { name = loser.name })
			end)
		end
		npcs:remember(a, "brawled_with", b.id, 0.6)
		npcs:remember(b, "brawled_with", a.id, 0.6)
		if how == "broken" and brawl.guard then
			line(brawl.guard, "brawl_broken")
			npcs:remember(a, "broke_up_fight", brawl.guard.id, 0.3)
			npcs:remember(b, "broke_up_fight", brawl.guard.id, 0.3)
		end
		local mid = (a.position + b.position) / 2
		for _, other in brawl.town.npcs do
			if other ~= a and other ~= b and not other.knockedOut and flat(other.position, mid) <= B.watchReach then
				npcs:remember(other, "saw_brawl", a.id, 0.5, { note = b.id })
			end
		end
	end
	log:info("npc_brawl_ended", { a = a.id, b = b.id, how = how, phase = brawl.phase, seconds = math.floor(os.clock() - brawl.started) })
end

local function gone(npc: any): boolean
	return npc.knockedOut or not npc.rig or npc.tier ~= 0
end

local function findGuard(brawl: Brawl, mid: Vector3): any?
	local best, bestD = nil, B.guardReach
	for _, npc in brawl.town.npcs do
		if npc.occupation == "guard" and npc ~= brawl.a and npc ~= brawl.b and npc.rig and not npc.knockedOut
			and npc.combat == nil and npc.leash == nil and not inBrawl(npc)
		then
			local d = flat(npc.position, mid)
			if d < bestD then
				best, bestD = npc, d
			end
		end
	end
	return best
end

local function stepBrawl(brawl: Brawl)
	local a, b = brawl.a, brawl.b
	local clock = os.clock()
	if gone(a) or gone(b) then
		endBrawl(brawl, "gone")
		return
	end
	if brawl.phase == "words" then
		local toward = b.position - a.position
		local dir = Vector3.new(toward.X, 0, toward.Z)
		if dir.Magnitude > 0.1 then
			Navigation.FaceNow(a, dir.Unit)
			Navigation.FaceNow(b, -dir.Unit)
		end
		if clock < brawl.fightAt then
			return
		end
		brawl.phase = "fight"
		for _, pair in { { a, b }, { b, a } } do
			local me, them = pair[1], pair[2]
			npcs:setLeash(me, nil)
			setFloor(me, true)
			NPCCombat.challenge(me, "n:" .. them.id, { maxPower = B.maxPower, reason = "brawl" })
		end
		brawl.fightAt = clock
		return
	end
	local mid = (a.position + b.position) / 2
	if not brawl.watched then
		brawl.watched = true
		for _, other in brawl.town.npcs do
			if other ~= a and other ~= b and other.rig and not other.knockedOut and other.combat == nil and flat(other.position, mid) <= B.watchReach then
				line(other, "brawl_watch")
				break
			end
		end
	end
	if not brawl.guard then
		brawl.guard = findGuard(brawl, mid)
	end
	local guard = brawl.guard
	local guardDistance: number? = nil
	if guard then
		if guard.knockedOut or not guard.rig or guard.combat ~= nil then
			brawl.guard = nil
		else
			npcs:setLeash(guard, { kind = "hold", position = mid })
			guardDistance = flat(guard.position, mid)
		end
	end
	local how = FightRules.brawlOver({
		elapsed = clock - brawl.fightAt,
		lasts = B.lasts,
		shareA = healthShare(a),
		shareB = healthShare(b),
		floor = B.floor,
		apart = flat(a.position, b.position),
		apartLimit = B.apart,
		guardDistance = guardDistance,
		breakAt = B.breakAt,
		goneA = gone(a),
		goneB = gone(b),
	})
	if how then
		endBrawl(brawl, how)
	end
end

-- The worst-tempered pair standing close in one town, if they come to blows this hour.
local function lookForBrawl(town: any, force: boolean): boolean
	local now = WorldClock.now()
	local free: { any } = {}
	for _, npc in town.npcs do
		if npc.tier == 0 and npc.rig and FightRules.canBrawl(npc) and not inBrawl(npc) and not npc.raid
			and (force or (npcUntil[npc.id] or -math.huge) <= now)
		then
			table.insert(free, npc)
		end
	end
	local best, bestA, bestB = -1, nil, nil
	for i = 1, #free do
		local a = free[i]
		for j = i + 1, #free do
			local b = free[j]
			if flat(a.position, b.position) <= B.meet and (force or (pairUntil[pairKey(a, b)] or -math.huge) <= now) then
				local g = FightRules.grudge(a, b, RelationshipGraph.peek(a.id, b.id), RelationshipGraph.peek(b.id, a.id))
				if g > best then
					best, bestA, bestB = g, a, b
				end
			end
		end
	end
	if not bestA or not bestB then
		return false
	end
	if not force then
		if best < B.grudgeAt then
			return false
		end
		local roll = Seed.random(worldService:getSeed(), "brawl:" .. pairKey(bestA, bestB), "hour", math.floor(now * 24)):NextNumber()
		if roll >= B.chance then
			return false
		end
	end
	startBrawl(town, bestA, bestB, force)
	return true
end

local function lookForBrawls()
	if not FightRules.inHours(WorldClock.hour(), B.hours) then
		return
	end
	local clock = os.clock()
	for _, town in npcs:towns() do
		if clock >= (nextLook[town.id] or 0) then
			nextLook[town.id] = clock + B.checkEvery
			local seen = false
			for _, npc in town.npcs do
				if npc.tier == 0 then
					seen = true
					break
				end
			end
			local busy = false
			for _, b in brawls do
				busy = busy or b.town == town
			end
			if seen and not busy then
				lookForBrawl(town, false)
			end
		end
	end
end

-- ─── Raids ──────────────────────────────────────────────────────────────────

local function raidAlive(raid: Raid): { any }
	local out: { any } = {}
	for _, npc in raid.raiders do
		if npc.raid == raid.id and not npc.knockedOut then
			table.insert(out, npc)
		end
	end
	return out
end

local function release(npc: any)
	npc.raid = nil
	if NPCCombat.engaged(npc) then
		NPCCombat.disengage(npc)
	end
	npcs:setLeash(npc, nil) -- the brain sends them home
end

local function endRaid(raid: Raid, outcome: string)
	raids[raid.id] = nil
	local left = 0
	for _, npc in raid.raiders do
		if npc.raid == raid.id then
			if not npc.knockedOut then
				left += 1
			end
			release(npc)
		end
	end
	if outcome == "driven_off" then
		for _, npc in raid.town.npcs do
			if (npc.occupation == "guard" or npc.occupation == "hunter") and npc.rig and not npc.knockedOut then
				line(npc, "raid_beaten", { other = townName(raid.other) })
				break
			end
		end
	end
	for _, npc in raid.town.npcs do
		if not npc.knockedOut and flat(npc.position, raid.from) <= R.defend * 2 then
			for _, raider in raid.raiders do
				npcs:remember(npc, "raided_us", raider.id, 0.6, { note = raid.other.id })
			end
		end
	end
	log:info("npc_raid_ended", { id = raid.id, town = raid.town.id, other = raid.other.id, outcome = outcome, left = left, seconds = math.floor(os.clock() - raid.started) })
	local ok, err = pcall(raid.onDone, outcome)
	if not ok then
		log:warn("npc_raid_done_failed", { id = raid.id, err = tostring(err) })
	end
end

local function stepRaid(raid: Raid)
	local alive = raidAlive(raid)
	-- Courage broke: they're done and head home.
	for i = #alive, 1, -1 do
		local npc = alive[i]
		if NPCCombat.engaged(npc) and not NPCCombat.fighting(npc) then
			line(npc, "raid_flee")
			release(npc)
			table.remove(alive, i)
		end
	end
	if #alive == 0 then
		endRaid(raid, if raid.burned then "burned" else "driven_off")
		return
	end
	if os.clock() - raid.started >= R.lasts then
		line(alive[1], "raid_flee")
		endRaid(raid, if raid.burned then "burned" else "driven_off")
		return
	end
	local target = raid.target
	for _, npc in alive do
		if npc.rig and not raid.greeted[npc] then
			raid.greeted[npc] = true
			log:info("npc_raid_arrived", { id = raid.id, npc = npc.id })
			line(npc, "raid_arrive", { town = townName(raid.town), other = townName(raid.other) })
		end
		local subject = "n:" .. npc.id
		-- The town's fighters who see one turn on them.
		for _, def in raid.town.npcs do
			if (def.occupation == "guard" or def.occupation == "hunter") and def.rig and not def.knockedOut
				and not NPCCombat.engaged(def) and flat(def.position, npc.position) <= R.defend
			then
				NPCCombat.onWitness(def, subject)
			end
		end
		if npc.rig and not NPCCombat.engaged(npc) then
			-- A defender is coming at them: they answer.
			local foe, foeD = nil, R.answer
			for _, def in raid.town.npcs do
				if def.rig and not def.knockedOut and NPCCombat.fighting(def) then
					local d = flat(def.position, npc.position)
					if d < foeD then
						foe, foeD = def, d
					end
				end
			end
			if foe then
				NPCCombat.challenge(npc, "n:" .. foe.id, { reason = "raid" })
			elseif not (target and target.Parent) then
				-- Nothing to burn on this side: into the town, to find someone to fight.
				local centre = Vector3.new(raid.town.x, npc.position.Y, raid.town.z)
				local d = flat(npc.position, centre)
				if d > 12 then
					local dir = Vector3.new(centre.X - npc.position.X, 0, centre.Z - npc.position.Z).Unit
					npcs:setLeash(npc, { kind = "hold", position = if d <= R.walkStep then centre else npc.position + dir * R.walkStep })
				end
			elseif target and target.Parent then
				-- Nobody in the way: on toward the building.
				local d = flat(npc.position, target.Position)
				if d <= R.reach and not raid.burned then
					raid.burned = true
					FireSim.ignitePart(target, 0.8)
					line(npc, "raid_fire")
					log:info("npc_raid_fire", { id = raid.id, npc = npc.id, part = target:GetFullName() })
					task.delay(4, function()
						if raids[raid.id] == raid then
							endRaid(raid, "burned")
						end
					end)
					return
				end
				local dir = Vector3.new(target.Position.X - npc.position.X, 0, target.Position.Z - npc.position.Z)
				local stepTo = if d <= R.walkStep then target.Position else npc.position + dir.Unit * R.walkStep
				npcs:setLeash(npc, { kind = "hold", position = stepTo })
			end
		end
	end
end

--[[
	A raid on `town` by `other`'s fighters, played out live. `from` is where they come in, `target`
	the building part they mean to set alight. onDone(outcome) gets "burned" or "driven_off".
	false when nobody could come (no free fighter out of sight).
]]
function NpcFightService.raid(_self: any, opts: { id: string, town: any, other: any, from: Vector3, target: BasePart?, onDone: (string) -> () }): boolean
	if not enabled() or raids[opts.id] then
		return false
	end
	local candidates: { FightRules.Candidate } = {}
	local byId: { [string]: any } = {}
	for _, npc in opts.other.npcs do
		if (npc.tier or 2) == 2 and FightRules.canBrawl(npc) and not npc.raid and NPCCombat.attackRecipe(npc) then
			table.insert(candidates, { id = npc.id, fighter = npc.occupation == "guard" or npc.occupation == "hunter", courage = NPCCombat.courage(npc, 1) })
			byId[npc.id] = npc
		end
	end
	if #candidates == 0 then
		return false
	end
	local ranked = FightRules.rankRaiders(candidates)
	local count = math.min(#ranked, FightRules.raidCount(Seed.random(worldService:getSeed(), "raid:" .. opts.id, "count"):NextNumber(), R.count))
	local toward = Vector3.new(opts.from.X - opts.town.x, 0, opts.from.Z - opts.town.z)
	local side = if toward.Magnitude > 0.1 then Vector3.new(-toward.Unit.Z, 0, toward.Unit.X) else Vector3.new(1, 0, 0)
	local raid: Raid = {
		id = opts.id,
		town = opts.town,
		other = opts.other,
		raiders = {},
		target = opts.target,
		from = opts.from,
		started = os.clock(),
		burned = false,
		greeted = {},
		onDone = opts.onDone,
	}
	for i = 1, count do
		local npc = byId[ranked[i].id]
		npc.raid = opts.id
		local spot = opts.from + side * ((i - (count + 1) / 2) * R.spread)
		npcs:setLeash(npc, { kind = "hold", position = spot }) -- out of sight: they're simply there
		table.insert(raid.raiders, npc)
	end
	raids[opts.id] = raid
	local ids = {}
	for _, npc in raid.raiders do
		table.insert(ids, npc.id)
	end
	log:info("npc_raid_started", { id = opts.id, town = opts.town.id, other = opts.other.id, raiders = table.concat(ids, ","), target = if opts.target then opts.target.Name else "none" })
	return true
end

function NpcFightService.raidRunning(_self: any, id: string): boolean
	return raids[id] ~= nil
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function townOf(npc: any): any?
	for _, town in npcs:towns() do
		if town.id == npc.settlementId then
			return town
		end
	end
	return nil
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "fights", category = "NPCs", description = "NPC brawls and raids running now (docs/NpcFights.md)",
		args = {},
		handler = function()
			local lines = { string.format("npc_fights_enabled=%s · brawl hours %d-%d", tostring(enabled()), B.hours[1], B.hours[2] % 24) }
			for _, b in brawls do
				table.insert(lines, string.format("brawl #%d %s: %s vs %s (%s)%s", b.id, b.town.id, b.a.name, b.b.name, b.phase, if b.guard then " · guard " .. b.guard.name .. " coming" else ""))
			end
			for id, r in raids do
				table.insert(lines, string.format("raid %s on %s by %s: %d of %d left%s", id, townName(r.town), townName(r.other), #raidAlive(r), #r.raiders, if r.burned then " · burned" else ""))
			end
			if #lines == 1 then
				table.insert(lines, "nothing running")
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "brawlnow", category = "NPCs", description = "Start a brawl near an NPC now: it and the free adult nearby it can least stand (skips the hour and the roll)",
		args = { { name = "npc", type = "npc", default = "nearest", hint = "id, name, nearest or @selected" } },
		handler = function(_, a)
			local npc = a.npc
			local town = townOf(npc)
			if not town then
				return "no town for " .. npc.name
			end
			if npc.tier ~= 0 or not npc.rig then
				return npc.name .. " must be close (T0)"
			end
			if not FightRules.canBrawl(npc) then
				return npc.name .. " can't brawl now (a child, retired, asleep, sheltering, busy or in a fight)"
			end
			local best, bestG = nil, -1
			for _, other in town.npcs do
				if other ~= npc and other.tier == 0 and other.rig and FightRules.canBrawl(other) and not inBrawl(other)
					and flat(other.position, npc.position) <= B.meet * 2
				then
					local g = FightRules.grudge(npc, other, RelationshipGraph.peek(npc.id, other.id), RelationshipGraph.peek(other.id, npc.id))
					if g > bestG then
						best, bestG = other, g
					end
				end
			end
			if not best then
				return "nobody free within " .. B.meet * 2 .. " studs of " .. npc.name
			end
			startBrawl(town, npc, best, true)
			return string.format("%s and %s (grudge %.2f) come to blows", npc.name, best.name, bestG)
		end,
	})
	admin:Register({
		name = "npcvsnpc", category = "NPCs", description = "Two NPCs fight for real (no floor: it can knock one out). Both must be close (T0)",
		args = {
			{ name = "a", type = "npc", hint = "id, name, nearest or @selected" },
			{ name = "b", type = "npc", hint = "id, name or @selected" },
		},
		handler = function(_, args)
			local a, b = args.a, args.b
			if a == b then
				return "pick two different NPCs"
			end
			if not a.rig or a.tier ~= 0 or not b.rig or b.tier ~= 0 then
				return "both must be close (T0)"
			end
			NPCCombat.challenge(a, "n:" .. b.id, { reason = "admin" })
			NPCCombat.challenge(b, "n:" .. a.id, { reason = "admin" })
			return string.format("%s and %s fight", a.name, b.name)
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function NpcFightService.init(_self: any, ctx: any)
	log = ctx.log
	npcs = ctx.get("NPCService")
	ambient = ctx.get("AmbientLifeService")
	worldService = ctx.get("WorldService")
	registerAdmin(ctx.get("AdminService"))
end

function NpcFightService.start(_self: any, _ctx: any)
	task.spawn(function()
		while true do
			task.wait(1)
			if npcs:isReady() then
				if enabled() then
					local ok, err = pcall(lookForBrawls)
					if not ok then
						log:warn("npc_brawl_look_failed", { err = tostring(err) })
					end
				end
				for i = #brawls, 1, -1 do
					local brawl = brawls[i]
					local ok, err = pcall(stepBrawl, brawl)
					if not ok then
						log:warn("npc_brawl_step_failed", { err = tostring(err) })
						pcall(endBrawl, brawl, "error")
					end
				end
				for _, raid in raids do
					local ok, err = pcall(stepRaid, raid)
					if not ok then
						log:warn("npc_raid_step_failed", { id = raid.id, err = tostring(err) })
						pcall(endRaid, raid, "driven_off")
					end
				end
			end
		end
	end)
end

return NpcFightService
