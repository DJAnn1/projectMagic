--!strict
--[[
	ChronicleService: the world remembers its big moments, and people tell them
	(docs/LivingHistory.md §4, stage 1 of Living History).

	DEEDS IN   Topics.DeedDone from the services where things happen (Titan falls, Wildborn bosses,
	           ferals loose and ended, shared events won, crises put right, world events relieved),
	           plus SpellResolved (ultimates, earthquakes and tsunamis at power 8+) and
	           WorldEventRecorded from this server (NPC awakenings, world-first recipes).
	SCORED     Chronicle/ChronicleRules: under keepAt it stays in NPC memory only; keepAt and up
	           goes into this server's chronicle (in memory, capped); memoryAt and up, everyone in
	           that town remembers who did it (memory `legend_of`, gossip carries it on); legendAt
	           and up becomes a legend in the World record for every server (one write per
	           legendWriteGap from this server, the doer's name and UserId with it so it can be taken
	           off: DataService.eraseUser, admin legendforget).
	TOLD       never on a screen:
	             evening talk     after dusk, two free townspeople near a player, one tells the other
	             news             asking anyone for rumours (NPCService rumour hook, after the others)
	             greetings        someone who remembers your deed may bring it up (AmbientLife hook)
	             your Journal     a quiet first-person line when your deed becomes a legend
	           Legends from other servers are read at boot and every 10 minutes; the town where one
	           happened knows it (a secondhand memory, once per NPC and doer).

	Flag chronicle_enabled. Admin: chronicle, legends, chronicleadd, chroniclenow, legendforget.
	Log: chronicle_added, legend_written, chronicle_overheard, chronicle_told, chronicle_greeted.
	Every line is our own data plus names Roblox already shows; never player-typed text.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local OmenRules = require(Shared.Magic.OmenRules)
local Ultimates = require(Shared.Magic.Data.Ultimates)

local Server = ServerScriptService.Server
local Rules = require(Server.Chronicle.ChronicleRules)
local Kinds = require(Server.Chronicle.Data.ChronicleKinds)
local Lines = require(Server.Chronicle.Data.ChronicleLines)
local MemoryService = require(Server.NPC.MemoryService)
local WorldClock = require(Server.NPC.WorldClock)

local T = Rules.Tuning
local LEGEND_REFRESH = 600 -- seconds between reads of other servers' legends

local ChronicleService = {
	name = "ChronicleService",
	dependencies = { "AdminService", "AmbientLifeService", "JournalService", "NPCService", "WorldService", "WorldStateService" },
}

local log: any = nil
local npcs: any = nil
local ambient: any = nil
local journal: any = nil
local worldService: any = nil
local world: any = nil

local entries: { Rules.Entry } = {}
local repeats: { [string]: { number } } = {}
local pendingLegends: { Rules.Entry } = {}
local heardBy: { [Player]: { [string]: boolean } } = {} -- overheard or told: not brought up again
local toldBy: { [Player]: { [string]: boolean } } = {} -- asked about: not told again
local playerLast: { [Player]: number } = {}
local townLast: { [string]: number } = {}
local counter = 0
local counts = { added = 0, legends = 0, overheard = 0, told = 0, greeted = 0 }

local function enabled(): boolean
	return FeatureFlags.get("chronicle_enabled") == true
end

local function rngFor(salt: string): Random
	counter += 1
	return Seed.random(worldService:getSeed(), "chronicle", salt, counter)
end

local function rootOf(player: Player): Vector3?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function free(npc: any): boolean
	return npc.rig ~= nil
		and not npc.knockedOut
		and not npc.combat
		and not npc.talk
		and not npc.leash
		and npc.action ~= "sleep"
		and npc.action ~= "shelter"
end

local function towns(): { any }
	local ok, list = pcall(npcs.towns, npcs)
	return if ok and typeof(list) == "table" then list else {}
end

local function townById(id: string?): any?
	if not id then
		return nil
	end
	for _, town in towns() do
		if town.id == id then
			return town
		end
	end
	return nil
end

local function townList(): { Rules.Town }
	local out: { Rules.Town } = {}
	for _, town in towns() do
		table.insert(out, { id = town.id, x = town.x, z = town.z, radius = town.radius })
	end
	return out
end

local function shortId(): string
	local job = game.JobId
	return if job ~= "" then string.sub(job, 1, 8) else "studio"
end

-- ─── Lines ──────────────────────────────────────────────────────────────────

-- {who} {what} {where} {dir} for an entry, told by someone in `town` standing at `from`.
local function varsFor(entry: Rules.Entry, town: any?, from: Vector3): { [string]: string }
	local dir = OmenRules.bearing(from.X, from.Z, entry.x, entry.z)
	local where = "out " .. dir
	if town and entry.town == town.id and entry.inTown then
		where = "here"
	elseif entry.town and (not town or entry.town ~= town.id) then
		local other = townById(entry.town)
		if other and other.settlement and other.settlement.name then
			where = "up by " .. tostring(other.settlement.name)
		end
	end
	local vars: { [string]: string } = { dir = dir, where = where, what = entry.what or "it" }
	if entry.names and entry.names[1] then
		vars.who = entry.names[1]
	end
	return vars
end

-- The first-person Journal line for a doer whose deed became a legend (no speaker needed).
local function journalLine(entry: Rules.Entry): string
	local _, _, _, _, category = Rules.categories(entry)
	for _, line in Lines do
		if line.cat == category then
			return (string.gsub(line.text, "{what}", entry.what or "it"))
		end
	end
	return "People have started telling a story about something I did."
end

-- ─── Remembering ────────────────────────────────────────────────────────────

-- Everyone in the deed's town remembers who did it: firsthand close by, secondhand further off.
local function rememberInTown(entry: Rules.Entry)
	local def = Kinds[entry.kind]
	local town = townById(entry.town)
	if not def or not def.named or not town or not entry.by then
		return
	end
	local at = Vector3.new(entry.x, 0, entry.z)
	local note = entry.kind .. "|" .. (entry.what or "")
	for i, userId in entry.by do
		if i > 4 then
			break
		end
		local share = if i == 1 then 1 else 0.6
		for _, npc in town.npcs do
			if not npc.knockedOut and typeof(npc.position) == "Vector3" then
				local close = flat(npc.position, at) <= 150
				npcs:remember(npc, "legend_of", "u:" .. userId, entry.score * share * (if close then 0.8 else 0.5), {
					valence = def.valence,
					note = note,
					secondhand = not close,
				})
			end
		end
	end
end

-- A legend from before this server: the town it happened in knows, once per person and doer.
local function rememberOld(entry: Rules.Entry)
	local def = Kinds[entry.kind]
	local town = townById(entry.town)
	local userId = entry.by and entry.by[1]
	if not def or not def.named or not town or not userId then
		return
	end
	local subject = "u:" .. userId
	for _, npc in town.npcs do
		local known = false
		for _, m in (npc.memories or {}) :: { any } do
			if m.kind == "legend_of" and m.subject == subject then
				known = true
				break
			end
		end
		if not known then
			npcs:remember(npc, "legend_of", subject, entry.score * 0.4, {
				valence = def.valence,
				note = entry.kind .. "|" .. (entry.what or ""),
				secondhand = true,
			})
		end
	end
end

-- ─── Recording ──────────────────────────────────────────────────────────────

local function record(deed: any): Rules.Entry?
	if not enabled() or typeof(deed) ~= "table" then
		return nil
	end
	local kind = deed.kind
	local def = typeof(kind) == "string" and Kinds[kind] or nil
	local x, z = tonumber(deed.x), tonumber(deed.z)
	if not def or not x or not z or x ~= x or z ~= z or math.abs(x) > 1e6 or math.abs(z) > 1e6 then
		return nil
	end
	local by: { number }? = nil
	if typeof(deed.by) == "table" then
		local list: { number } = {}
		for _, id in deed.by do
			if typeof(id) == "number" and not table.find(list, id) then
				table.insert(list, id)
			end
		end
		by = if #list > 0 then list else nil
	end
	local townId, inTown = Rules.townFor(townList(), x, z)
	local actor = if by then "u:" .. by[1] else "world"
	local key = Rules.repeatKey(kind, actor, townId or Rules.cellOf(x, z))
	local now = os.time()
	local seen = repeats[key] or {}
	for i = #seen, 1, -1 do
		if now - seen[i] > T.repeatWindow then
			table.remove(seen, i)
		end
	end
	local score = Rules.score(kind, { first = deed.first == true, power = tonumber(deed.power), inTown = inTown }, #seen)
	table.insert(seen, now)
	repeats[key] = seen
	if score < T.keepAt then
		log:debug("chronicle_skipped", { kind = kind, score = score, repeats = #seen - 1 })
		return nil
	end
	local names: { string }? = nil
	if by then
		local list: { string } = {}
		for _, id in by do
			local p = Players:GetPlayerByUserId(id)
			table.insert(list, if p then p.DisplayName else "someone")
		end
		names = list
	end
	counter += 1
	local entry: Rules.Entry = {
		id = string.format("%s_%d_%d", shortId(), now, counter),
		kind = kind,
		t = now,
		x = x,
		z = z,
		town = townId,
		inTown = inTown,
		by = by,
		names = names,
		what = if typeof(deed.what) == "string" then deed.what else nil,
		score = score,
	}
	Rules.add(entries, entry, T.serverCap)
	counts.added += 1
	log:info("chronicle_added", { id = entry.id, kind = kind, score = math.floor(score * 100) / 100, town = townId, by = if by then by[1] else nil })
	if score >= T.memoryAt then
		rememberInTown(entry)
	end
	if Rules.isLegend(score) then
		entry.legend = true
		table.insert(pendingLegends, entry)
	end
	return entry
end

local function writeLegend(entry: Rules.Entry)
	local ok, added = pcall(worldService.recordLegend, worldService, Rules.legendOf(entry))
	if not ok then
		log:warn("legend_write_failed", { id = entry.id, error = tostring(added) })
		table.insert(pendingLegends, 1, entry) -- try again next time
		return
	end
	counts.legends += 1
	log:info("legend_written", { id = entry.id, kind = entry.kind, by = if entry.by then entry.by[1] else nil, added = added })
	for _, userId in (entry.by or {}) :: { number } do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			journal:log(player, "legend", journalLine(entry), { quiet = true })
		end
	end
end

-- Other servers' legends, as entries people here can tell.
local function absorbLegends(list: { any })
	local have: { [string]: boolean } = {}
	for _, e in entries do
		have[e.id] = true
	end
	for _, legend in list do
		if typeof(legend) == "table" and typeof(legend.id) == "string" and not have[legend.id] and Kinds[legend.k] then
			local entry = Rules.entryOf(legend)
			Rules.add(entries, entry, T.serverCap)
			rememberOld(entry)
		end
	end
end

-- ─── Evening talk ───────────────────────────────────────────────────────────

local function townAt(at: Vector3): any?
	for _, town in towns() do
		local reach = town.radius * 1.3
		if (town.x - at.X) ^ 2 + (town.z - at.Z) ^ 2 <= reach * reach then
			return town
		end
	end
	return nil
end

local function heardOf(player: Player): { [string]: boolean }
	local heard = heardBy[player]
	if not heard then
		heard = {}
		heardBy[player] = heard
	end
	return heard
end

-- `a` tells `b` about something `listener` hasn't heard. Returns why not, or nil when it started.
local function converse(listener: Player, town: any, a: any, b: any): string?
	local entry = Rules.choose(entries, town.x, town.z, heardOf(listener), rngFor(tostring(listener.UserId)):NextNumber(), town.id)
	if not entry then
		return "nothing in the chronicle near here you haven't heard"
	end
	if (b.traits.extraversion or 0.5) > (a.traits.extraversion or 0.5) then
		a, b = b, a
	end
	local say, reply = Rules.categories(entry)
	local opener = ambient:lineFor(a, nil, { say }, Lines, varsFor(entry, town, a.position))
	local answer = ambient:lineFor(b, nil, { reply, "reply_any" }, Lines, varsFor(entry, town, b.position))
	if not opener or not answer then
		return "no line fits " .. entry.kind
	end
	townLast[town.id] = os.clock()
	local mid = (a.position + b.position) / 2
	for _, player in Players:GetPlayers() do
		local at = rootOf(player)
		if at and flat(at, mid) <= T.hearRadius + T.pairRadius then
			heardOf(player)[entry.id] = true
			playerLast[player] = os.clock()
		end
	end
	ambient:face(a, b.position, T.facing)
	ambient:face(b, a.position, T.facing)
	npcs:speak(a, opener, T.speakRadius)
	local rng = rngFor("reply")
	task.delay(T.replyDelay[1] + rng:NextNumber() * (T.replyDelay[2] - T.replyDelay[1]), function()
		if free(b) then
			npcs:speak(b, answer, T.speakRadius)
		end
	end)
	counts.overheard += 1
	log:info("chronicle_overheard", { town = town.id, entry = entry.id, kind = entry.kind, a = a.id, b = b.id, text = opener })
	return nil
end

local function pairNear(town: any, at: Vector3, radius: number): (any?, any?)
	local near: { any } = {}
	for _, npc in town.npcs do
		if free(npc) and flat(npc.position, at) <= radius then
			table.insert(near, npc)
		end
	end
	table.sort(near, function(x, y)
		return flat(x.position, at) < flat(y.position, at)
	end)
	for i = 1, #near do
		for j = i + 1, #near do
			if flat(near[i].position, near[j].position) <= T.pairRadius then
				return near[i], near[j]
			end
		end
	end
	return nil, nil
end

local function tick()
	if not enabled() or FeatureFlags.get("ambient_life_enabled") ~= true or #entries == 0 then
		return
	end
	local hour = (WorldClock.now() % 1) * 24
	if not Rules.evening(hour) then
		return
	end
	local clock = os.clock()
	for _, player in Players:GetPlayers() do
		local at = rootOf(player)
		if at and clock - (playerLast[player] or -math.huge) >= T.talkPlayerGap then
			local town = townAt(at)
			if town and clock - (townLast[town.id] or -math.huge) >= T.talkTownGap then
				local a, b = pairNear(town, at, T.hearRadius)
				if a and b then
					converse(player, town, a, b)
				end
			end
		end
	end
end

-- ─── Asked for news ─────────────────────────────────────────────────────────

local function rumorHook(player: Player, npc: any): string?
	if not enabled() or typeof(npc) ~= "table" or typeof(npc.position) ~= "Vector3" then
		return nil
	end
	local town = townById(npc.settlementId)
	if not town then
		return nil
	end
	local told = toldBy[player] or {}
	toldBy[player] = told
	local entry = Rules.choose(entries, town.x, town.z, told, rngFor("told" .. player.UserId):NextNumber(), town.id)
	if not entry then
		return nil
	end
	local _, _, category = Rules.categories(entry)
	local text = ambient:lineFor(npc, player, { category }, Lines, varsFor(entry, town, npc.position))
	if not text then
		return nil
	end
	told[entry.id] = true
	heardOf(player)[entry.id] = true
	counts.told += 1
	journal:log(player, "rumor", string.format("I asked %s for news. \"%s\"", tostring(npc.name), text), { quiet = true })
	log:info("chronicle_told", { userId = player.UserId, npc = npc.id, entry = entry.id })
	return text
end

-- ─── Greetings ──────────────────────────────────────────────────────────────

local function greetHook(npc: any, player: Player, close: boolean, _clock: number): any?
	if not enabled() or not close then
		return nil
	end
	local subject = "u:" .. player.UserId
	local now = WorldClock.now()
	local best: any = nil
	for _, m in MemoryService.top(npc, 6, now, subject) do
		if m.kind == "legend_of" and typeof(m.note) == "string" then
			best = m
			break
		end
	end
	if not best then
		return nil
	end
	npc.chronicleGreeted = npc.chronicleGreeted or {}
	local key = player.UserId .. "|" .. best.note
	if npc.chronicleGreeted[key] then
		return nil
	end
	npc.chronicleGreeted[key] = true -- asked or not, they've made up their mind about this one
	if rngFor("greet" .. npc.id):NextNumber() >= T.greetChance then
		return nil
	end
	local kind, what = string.match(best.note, "^([^|]+)|(.*)$")
	if not kind or not Kinds[kind] then
		return nil
	end
	return {
		categories = { "greet_" .. kind },
		lines = Lines,
		vars = { what = if what ~= "" then what else "it" },
		said = function(text: string)
			counts.greeted += 1
			log:info("chronicle_greeted", { npc = npc.id, player = player.UserId, kind = kind, text = text })
		end,
	}
end

-- ─── Other sources ──────────────────────────────────────────────────────────

local function onSpell(p: any)
	if not p.effective or (p.power or 0) < 8 or typeof(p.point) ~= "Vector3" then
		return
	end
	local route = tostring(p.route)
	local kind, what = nil, nil
	if string.sub(route, 1, 4) == "ult_" then
		local u = Ultimates.list[string.sub(route, 5)]
		kind, what = "great_spell", if u then u.name else nil
	elseif route == "earthquake" then
		kind = "quake"
	elseif route == "tsunami" then
		kind = "tsunami"
	end
	if kind then
		record({ kind = kind, x = p.point.X, z = p.point.Z, by = { p.casterUserId }, what = what, power = p.power })
	end
end

local function onWorldEvent(event: any)
	if typeof(event) ~= "table" or event.origin ~= game.JobId or typeof(event.data) ~= "table" then
		return
	end
	if event.kind == "npc_awakened" then
		local npc = npcs:get(event.data.npc)
		if npc and typeof(npc.position) == "Vector3" then
			record({ kind = "npc_awakened", x = npc.position.X, z = npc.position.Z, what = npc.name })
		end
	elseif event.kind == "world_first_recipe" then
		local player = Players:GetPlayerByUserId(event.data.by)
		local at = player and rootOf(player)
		if at then
			record({ kind = "world_first", x = at.X, z = at.Z, by = { event.data.by }, first = true })
		end
	end
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function describe(e: Rules.Entry): string
	return string.format(
		"%s%s %.2f · %s · %s · %s%s",
		if e.legend then "★ " else "",
		e.kind,
		e.score,
		e.what or "-",
		if e.names then table.concat(e.names, ", ") else "nobody named",
		e.town or "the wilds",
		if e.old then " · from before this server" else ""
	)
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "chronicle",
		category = "NPCs",
		description = "This server's chronicle, biggest first (★ = a legend), with counts",
		args = { { name = "count", type = "integer", min = 1, max = 60, default = 15 } },
		handler = function(_ctx: any, a: any)
			local list = table.clone(entries)
			table.sort(list, function(x, y)
				return x.score > y.score
			end)
			local lines = {
				string.format(
					"on=%s · %d entries · added %d · legends written %d (%d waiting) · overheard %d · told %d · greeted %d",
					tostring(enabled()), #entries, counts.added, counts.legends, #pendingLegends, counts.overheard, counts.told, counts.greeted
				),
			}
			for i, e in list do
				if i > a.count then
					break
				end
				table.insert(lines, describe(e))
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "legends",
		category = "NPCs",
		description = "The world's legends as every server sees them (reads the World record again)",
		args = {},
		handler = function(_ctx: any, _a: any)
			local list = worldService:fetchLegends()
			absorbLegends(list)
			local lines = { string.format("%d legends (at most %d kept)", #list, T.legendCap) }
			for _, l in list do
				table.insert(lines, string.format("%s %.2f · %s · %s · %s", tostring(l.k), l.s or 0, tostring(l.w or "-"), tostring(l.by or "nobody named"), tostring(l.town or "the wilds")))
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "chronicleadd",
		category = "NPCs",
		description = "Record a deed by you where you stand, as if it happened (counts as a repeat like any other)",
		args = {
			{ name = "kind", type = "string", default = "boss_slain", hint = "titan_fell boss_slain feral_ended great_spell quake ..." },
			{ name = "first", type = "string", default = "no", hint = "yes = a first" },
		},
		handler = function(ctx: any, a: any)
			local at = rootOf(ctx.player)
			if not at then
				return "no character"
			end
			if not Kinds[a.kind] then
				local names = {}
				for k in Kinds do
					table.insert(names, k)
				end
				table.sort(names)
				return "unknown kind; one of: " .. table.concat(names, ", ")
			end
			local entry = record({ kind = a.kind, x = at.X, z = at.Z, by = { ctx.player.UserId }, what = "the thing in the test", first = a.first == "yes" })
			return if entry then describe(entry) else "scored under keepAt (repeats halve it): only NPC memory"
		end,
	})
	admin:Register({
		name = "chroniclenow",
		category = "NPCs",
		description = "Have the nearest two free people (within 30 studs) tell each other something from the chronicle now, at any hour",
		args = {},
		handler = function(ctx: any, _a: any)
			local at = rootOf(ctx.player)
			local town = at and townAt(at)
			if not at or not town then
				return "stand in a town first"
			end
			local a, b = pairNear(town, at, 30)
			if not a or not b then
				local near: { any } = {}
				for _, npc in town.npcs do
					if free(npc) and flat(npc.position, at) <= 30 then
						table.insert(near, npc)
					end
				end
				table.sort(near, function(x, y)
					return flat(x.position, at) < flat(y.position, at)
				end)
				a, b = near[1], near[2]
			end
			if not a or not b then
				return "need two free people within 30 studs"
			end
			local why = converse(ctx.player, town, a, b)
			return why or string.format("%s is telling %s", tostring(a.name), tostring(b.name))
		end,
	})
	admin:Register({
		name = "legendforget",
		category = "NPCs",
		description = "Take a player's name off every legend (data erasure; the deeds stay, credited to nobody)",
		args = { { name = "userId", type = "integer", min = 1, max = 1e12 } },
		handler = function(_ctx: any, a: any)
			local n = worldService:forgetLegends(a.userId)
			for _, e in entries do
				if e.by and e.by[1] == a.userId then
					e.by, e.names = nil, nil
				end
			end
			return string.format("took the name off %d legends", n)
		end,
	})
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

function ChronicleService.init(_self: any, ctx: any)
	log = ctx.log
	npcs = ctx.get("NPCService")
	ambient = ctx.get("AmbientLifeService")
	journal = ctx.get("JournalService")
	worldService = ctx.get("WorldService")
	world = ctx.get("WorldStateService")
	registerAdmin(ctx.get("AdminService"))
	npcs:setRumorHook(rumorHook) -- after the others: what's loose or overheard nearby comes first
	ambient:setGreetHook(greetHook)
	ctx.bus:subscribe(Topics.DeedDone, record)
	ctx.bus:subscribe(Topics.SpellResolved, onSpell)
	ctx.bus:subscribe(Topics.WorldEventRecorded, onWorldEvent)
	Players.PlayerRemoving:Connect(function(player)
		heardBy[player] = nil
		toldBy[player] = nil
		playerLast[player] = nil
	end)
end

function ChronicleService.start(_self: any, _ctx: any)
	task.spawn(function()
		world:awaitReady()
		while not npcs:isReady() do
			task.wait(2)
		end
		local ok, err = pcall(function()
			absorbLegends(worldService:legends())
		end)
		if not ok then
			log:warn("legends_read_failed", { error = tostring(err) })
		end
		log:info("chronicle_ready", { legends = #entries })
		local nextRefresh = os.clock() + LEGEND_REFRESH
		local nextWrite = 0
		while true do
			task.wait(T.talkTick)
			local okTick, errTick = pcall(tick)
			if not okTick then
				log:warn("chronicle_tick_failed", { error = tostring(errTick) })
			end
			if #pendingLegends > 0 and os.clock() >= nextWrite then
				nextWrite = os.clock() + T.legendWriteGap
				task.spawn(writeLegend, table.remove(pendingLegends, 1) :: Rules.Entry)
			end
			if os.clock() >= nextRefresh then
				nextRefresh = os.clock() + LEGEND_REFRESH
				task.spawn(function()
					local okRead, list = pcall(worldService.fetchLegends, worldService)
					if okRead then
						absorbLegends(list)
					end
				end)
			end
		end
	end)
end

return ChronicleService
