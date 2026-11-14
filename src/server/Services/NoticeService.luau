--!strict
--[[
	NoticeService: people notice what you do with magic (docs/Noticing.md, idea #38 "People noticed
	that"). No interface: everything is said aloud by someone who was there, in a chat bubble.

	SEEN    On Topics.MagicWitnessed from a player's cast, the townspeople within Noticing.Tuning
	        .seeRadius of the caster or of where it landed are witnesses. The likeliest to speak up
	        (outgoing, young, close) may say one thing a moment later, about what the spell did:
	        it backfired, hurt someone, landed near them, moved the ground, did nothing, was huge,
	        hit a practice dummy... or by its domain, the witness's job, fears and temperament
	        (NPC/Noticing picks the categories, NPC/Data/NoticedLines holds the lines, Ambient
	        LifeService fills them). They stop and look at you while they say it.

	HEARD   A big spell (Noticing.big) is heard in every town within hearReach. Later, someone there
	        who wasn't a witness may ask you about it instead of greeting you, with the direction
	        it came from (AmbientLifeService's greeting hook). At most heardAskers people per spell.

	LIMITS  one speaker per cast; one comment per player per playerGap (bigPlayerGap if big); the
	        same person to the same player once per npcGap; the same spell again within repeatGap
	        isn't news unless big. Everything said comes from our own data (no player text).

	Cost: one pass over the town NPCs near the cast per player cast (only T0 bodies count: you can
	only see someone who's drawn). Heard lists: at most heardPerTown entries per town, in memory.

	Flag noticing_enabled. Admin: noticing, noticetest. Log: npc_noticed, npc_asked_about_magic.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local Registry = require(Shared.Magic.Registry)
local Seed = require(Shared.Magic.Seed)
local SpellOutcome = require(Shared.Magic.SpellOutcome)
local OmenRules = require(Shared.Magic.OmenRules)

local Server = ServerScriptService.Server
local Noticing = require(Server.NPC.Noticing)
local Lines = require(Server.NPC.Data.NoticedLines)
local NPCMagicLife = require(Server.NPC.NPCMagicLife)

local T = Noticing.Tuning

local NoticeService = {
	name = "NoticeService",
	dependencies = { "AdminService", "AmbientLifeService", "NPCService", "WorldService" },
}

type Heard = {
	userId: number,
	at: Vector3,
	seen: Noticing.Seen,
	clock: number,
	witnesses: { [any]: boolean }, -- npc ids who saw it: they don't ask, they were there
	asked: { [any]: boolean },
	askers: number,
}

local log: any = nil
local npcs: any = nil
local ambient: any = nil
local worldService: any = nil

local lastSaid: { [Player]: number } = {} -- player -> when someone last commented on their magic
local seenKeys: { [Player]: { [string]: number } } = {} -- player -> recipe key -> when last noticed
local heard: { [string]: { Heard } } = {} -- town id -> big spells heard there
local counter = 0
local counts = { seen = 0, asked = 0, heard = 0 }

local function enabled(): boolean
	return FeatureFlags.get("noticing_enabled") == true and FeatureFlags.get("ambient_life_enabled") == true
end

local function rngFor(userId: number): Random
	counter += 1
	return Seed.random(worldService:getSeed(), "player:" .. userId, "noticed", counter)
end

local function rootOf(player: Player): Vector3?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

local function isMythic(domains: { string }): boolean
	for _, id in domains do
		local def = Registry.domains[id]
		if def and def.rarity == "Mythic" then
			return true
		end
	end
	return false
end

local function kindOf(recipe: any): string?
	if typeof(recipe) ~= "table" then
		return nil
	end
	local ok, outcome = pcall(SpellOutcome.of, recipe)
	return if ok and outcome then outcome.kind else nil
end

-- Someone who could look up and say something right now.
local function free(npc: any): boolean
	return npc.rig ~= nil
		and not npc.knockedOut
		and not npc.combat
		and not npc.talk
		and not npc.leash
		and npc.action ~= "sleep"
		and npc.action ~= "shelter"
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

-- ─── Heard from afar ────────────────────────────────────────────────────────

local function hear(player: Player, at: Vector3, seen: Noticing.Seen, witnesses: { [any]: boolean }, clock: number)
	for _, town in npcs:towns() do
		if (town.x - at.X) ^ 2 + (town.z - at.Z) ^ 2 <= T.hearReach * T.hearReach then
			local list = heard[town.id]
			if not list then
				list = {}
				heard[town.id] = list
			end
			table.insert(list, { userId = player.UserId, at = at, seen = seen, clock = clock, witnesses = witnesses, asked = {}, askers = 0 })
			while #list > T.heardPerTown do
				table.remove(list, 1)
			end
			counts.heard += 1
		end
	end
end

-- AmbientLifeService asks before greeting: does this person want to ask about something they heard?
local function greetHook(npc: any, player: Player, close: boolean, clock: number): any?
	if not enabled() or not close then
		return nil
	end
	local list = heard[npc.settlementId]
	if not list then
		return nil
	end
	for i = #list, 1, -1 do
		local entry = list[i]
		if clock - entry.clock > T.heardKeep then
			table.remove(list, i)
		elseif entry.userId == player.UserId and entry.askers < T.heardAskers and not entry.asked[npc.id] and not entry.witnesses[npc.id] then
			entry.asked[npc.id] = true -- asked or not, they've made up their mind about this one
			if rngFor(player.UserId):NextNumber() < T.askChance then
				return {
					categories = Noticing.heardCategories(entry.seen),
					lines = Lines,
					vars = { direction = OmenRules.bearing(npc.position.X, npc.position.Z, entry.at.X, entry.at.Z) },
					said = function(text: string)
						entry.askers += 1
						counts.asked += 1
						log:info("npc_asked_about_magic", { npc = npc.id, player = player.UserId, text = text })
					end,
				}
			end
		end
	end
	return nil
end

-- ─── Seen ───────────────────────────────────────────────────────────────────

local function say(npc: any, player: Player, text: string, category: string, toward: Vector3, power: number)
	ambient:markGreeted(npc, player)
	ambient:face(npc, toward, T.facing)
	npcs:speak(npc, text, T.speakRadius)
	counts.seen += 1
	log:throttled("npc_noticed", 2, "Info", "npc_noticed", { npc = npc.id, player = player.UserId, category = category, power = power, text = text })
end

local function onWitnessed(payload: any)
	if not enabled() or typeof(payload) ~= "table" or typeof(payload.position) ~= "Vector3" then
		return
	end
	local player = Players:GetPlayerByUserId(payload.casterUserId or 0)
	if not player then
		return -- NPC magic and anything without a caster isn't "you"
	end
	local landed: Vector3 = payload.position
	local casterAt = rootOf(player) or landed
	local clock = os.clock()
	local domains = if typeof(payload.domains) == "table" then payload.domains else {}
	local seen = Noticing.read(payload, isMythic(domains), nil)
	local big = Noticing.big(seen)

	-- Who saw it: drawn, awake, free people near you or near where it landed.
	local witnesses: { [any]: boolean } = {}
	local candidates: { { npc: any, distance: number, toLanding: number } } = {}
	for _, town in npcs:towns() do
		local reach = town.radius * 1.7 + T.seeRadius
		if (town.x - casterAt.X) ^ 2 + (town.z - casterAt.Z) ^ 2 <= reach * reach or (town.x - landed.X) ^ 2 + (town.z - landed.Z) ^ 2 <= reach * reach then
			for _, npc in town.npcs do
				if npc.rig and not npc.knockedOut and npc.action ~= "sleep" then
					local toLanding = flat(npc.position, landed)
					local distance = math.min(flat(npc.position, casterAt), toLanding)
					if distance <= T.seeRadius then
						witnesses[npc.id] = true
						if free(npc) then
							table.insert(candidates, { npc = npc, distance = distance, toLanding = toLanding })
						end
					end
				end
			end
		end
	end

	if big then
		hear(player, landed, seen, witnesses, clock)
	end
	if #candidates == 0 then
		return
	end
	local gap = if big then T.bigPlayerGap else T.playerGap
	if clock - (lastSaid[player] or -math.huge) < gap then
		return
	end
	local keys = seenKeys[player]
	if not keys then
		keys = {}
		seenKeys[player] = keys
	end
	if not Noticing.fresh(keys, seen.key, clock, big) then
		return
	end

	-- The one most likely to speak up, who hasn't spoken to this player lately.
	local rng = rngFor(player.UserId)
	local best, bestScore = nil, -math.huge
	for _, c in candidates do
		local npc = c.npc
		local noticed = npc.noticedAt and npc.noticedAt[player.UserId]
		if not noticed or clock - noticed >= T.npcGap then
			local score = Noticing.score(npc.traits.extraversion or 0.5, npc.ageBand == "child", c.distance, rng:NextNumber())
			if score > bestScore then
				best, bestScore = c, score
			end
		end
	end
	if not best then
		return
	end
	local npc = best.npc
	if rng:NextNumber() > Noticing.chance(seen, npc.traits.extraversion or 0.5, npc.ageBand == "child") then
		return
	end

	-- Only now work out what kind of spell it was (it reruns the route finder).
	seen.kind = kindOf(payload.recipe)
	local _, _, tier = NPCMagicLife.best(npc)
	local categories = Noticing.categories(seen, {
		scared = seen.harmful and best.toLanding <= T.scareRadius,
		outclassed = Noticing.outclassed(seen.power, tier),
	})
	local text, category = ambient:lineFor(npc, player, categories, Lines)
	if not text or not category then
		return
	end
	lastSaid[player] = clock
	if seen.key then
		keys[seen.key] = clock
	end
	npc.noticedAt = npc.noticedAt or {}
	npc.noticedAt[player.UserId] = clock
	local delay = T.reactDelay[1] + rng:NextNumber() * (T.reactDelay[2] - T.reactDelay[1])
	task.delay(delay, function()
		if player.Parent and free(npc) then
			say(npc, player, text :: string, category :: string, rootOf(player) or casterAt, seen.power)
		end
	end)
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "noticing",
		category = "NPCs",
		description = "People noticing your magic: comments and questions so far, the big spells each town heard (and who asked), or clear every cooldown so the next cast can be noticed",
		args = { { name = "clear", type = "string", default = "" } },
		handler = function(ctx: any, a: any)
			if a.clear == "clear" then
				lastSaid[ctx.player] = nil
				seenKeys[ctx.player] = nil
				for _, town in npcs:towns() do
					for _, npc in town.npcs do
						if npc.noticedAt then
							npc.noticedAt[ctx.player.UserId] = nil
						end
					end
				end
				for _, list in heard do
					for _, entry in list do
						if entry.userId == ctx.player.UserId then
							table.clear(entry.asked)
							entry.askers = 0
						end
					end
				end
				return "cleared: your next cast can be noticed, and every town may ask about what it heard again"
			end
			local lines = {
				string.format("on=%s · seen comments %d · questions asked %d · times heard %d", tostring(enabled()), counts.seen, counts.asked, counts.heard),
			}
			local clock = os.clock()
			for townId, list in heard do
				for _, entry in list do
					table.insert(
						lines,
						string.format(
							"%s heard %s (power %d%s) %ds ago from user %d; asked by %d",
							townId,
							table.concat(entry.seen.domains, "+"),
							entry.seen.power,
							if entry.seen.changedLand then ", land" else "",
							math.floor(clock - entry.clock),
							entry.userId,
							entry.askers
						)
					)
				end
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "noticetest",
		category = "NPCs",
		description = "Print the categories a cast would be noticed under (kind of event: any, dummy, scared, hurt, killed, backfire, land, big, dud, mythic, weak), and the line the nearest person would say",
		args = {
			{ name = "what", type = "string", default = "any" },
			{ name = "domain", type = "string", default = "energy" },
		},
		handler = function(ctx: any, a: any)
			local what = a.what
			local payload = {
				domains = { a.domain },
				power = if what == "big" or what == "land" then 7 elseif what == "weak" then 1 else 3,
				harmful = what == "scared" or what == "hurt" or what == "killed",
				effective = what ~= "dud",
				backfire = what == "backfire",
				practice = what == "dummy",
				hurt = what == "hurt" or what == "killed",
				killed = what == "killed",
				changedLand = what == "land",
			}
			local seen = Noticing.read(payload, isMythic(payload.domains) or what == "mythic", if what == "dud" then "none" else nil)
			local categories = Noticing.categories(seen, { scared = what == "scared", outclassed = what == "weak" })
			local at = rootOf(ctx.player)
			local nearest, nd = nil, math.huge
			if at then
				for _, town in npcs:towns() do
					for _, npc in town.npcs do
						if npc.rig and flat(npc.position, at) < nd then
							nearest, nd = npc, flat(npc.position, at)
						end
					end
				end
			end
			local out = "categories: " .. table.concat(categories, ", ")
			if nearest then
				local text, category = ambient:lineFor(nearest, ctx.player, categories, Lines)
				out ..= string.format("\n%s (%s) would say [%s]: %s", tostring(nearest.name), tostring(nearest.id), tostring(category), tostring(text))
				if text then
					npcs:speak(nearest, text, T.speakRadius)
				end
			end
			return out
		end,
	})
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

function NoticeService.init(_self: any, ctx: any)
	log = ctx.log
	npcs = ctx.get("NPCService")
	ambient = ctx.get("AmbientLifeService")
	worldService = ctx.get("WorldService")
	registerAdmin(ctx.get("AdminService"))
	ambient:setGreetHook(greetHook)
	ctx.bus:subscribe(Topics.MagicWitnessed, onWitnessed)
	Players.PlayerRemoving:Connect(function(player)
		lastSaid[player] = nil
		seenKeys[player] = nil
	end)
end

function NoticeService.start(_self: any, _ctx: any) end

return NoticeService
