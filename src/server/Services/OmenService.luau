--!strict
--[[
	OmenService: strange signs before big events (docs/Omens.md; data in Shared/Magic/Data/Omens,
	pure rules in Shared/Magic/OmenRules).

	Every `tick` seconds it finds what is coming:
		the next Titan            TitanService:upcoming   (source titan_<kind>, at its landing point)
		the next shared event     SharedEventService:upcoming (shared_<type>, at its town)
		the next Rift             RiftService:upcoming    (rift, at its town)
		rolled world events       EventDirector:pending   (world_<type>; the director holds them back
		                          for the omen's lead before starting them)
	An omen exists from `lead` seconds before its event to `linger` seconds after it begins, and its
	strength grows from 0 to 1 over the lead (OmenRules.strength). Nothing names the event.

	TELLING, world-over-game, no card or toast:
		SIGHT     each player is sent only the omens they could see from where they stand (remote
		          Omens, when what they see changes); Controllers/OmenController draws the signs.
		JOURNAL   the first time you notice a sign (close enough, strong enough), a first-person line
		          (once per sign, ever: data.omens.signs). If you noticed or heard of an omen and its
		          event then arrives while you're on the server, a second line ties them together
		          (once per source, ever: data.omens.after).
		PEOPLE    asking a townsperson within rumorRange for news while an omen is strong gets them
		          talking about the sign and its direction (NPCService rumour hook, ahead of others).

	Admin: `omens` lists what's coming and how strong; `omen <source> [lead]` raises a test omen at
	you; `omennotes [player] [clear]`. Log: `omen_noticed`, `omen_arrived` (with how many had seen it).
	Cost: three schedule checks (cached plans), a pass over pending events, and per player a distance
	check per omen, every 2 s.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Net = require(Shared.Net)
local Data = require(Shared.Magic.Data.Omens)
local OmenRules = require(Shared.Magic.OmenRules)
local WorldConfig = require(ServerScriptService.Server.World.WorldConfig)

local OmenService = {
	name = "OmenService",
	dependencies = {
		"AdminService", "EventDirector", "JournalService", "NPCService", "PlayerDataService",
		"RiftService", "SharedEventService", "TitanService", "WorldStateService",
	},
}

type Omen = { id: string, source: string, x: number, y: number, z: number, startsAt: number, test: boolean? }

local log: any = nil
local journal: any = nil
local playerData: any = nil
local world: any = nil
local director: any = nil
local titans: any = nil
local sharedEvents: any = nil
local rifts: any = nil

local omens: { [string]: Omen } = {}
local witnessed: { [string]: { [number]: boolean } } = {} -- omen id -> userIds who noticed or heard of it
local arrived: { [string]: boolean } = {}
local lastSent: { [Player]: string } = {}
local testCount = 0

local MAX_LEAD = 0
for _, source in Data.sources do
	MAX_LEAD = math.max(MAX_LEAD, source.lead)
end

local function enabled(): boolean
	return FeatureFlags.get("omens_enabled") == true
end

local function recordOf(player: Player): { signs: { [string]: number }, after: { [string]: number } }?
	local state = playerData:get(player)
	if not state then
		return nil
	end
	local data = state.data
	data.omens = data.omens or { signs = {}, after = {} }
	data.omens.signs = data.omens.signs or {}
	data.omens.after = data.omens.after or {}
	return data.omens
end

local function groundY(x: number, z: number): number
	return math.max(world:surfaceHeight(x, z), WorldConfig.SEA_LEVEL)
end

-- ─── Finding what's coming ──────────────────────────────────────────────────

local function add(id: string, source: string, x: number, z: number, startsAt: number)
	if omens[id] or not Data.sources[source] then
		return
	end
	omens[id] = { id = id, source = source, x = x, y = groundY(x, z), z = z, startsAt = startsAt }
end

local function discover()
	local titan = titans:upcoming(MAX_LEAD)
	if titan then
		add("titan:" .. titan.id, "titan_" .. titan.kind, titan.x, titan.z, titan.startsAt)
	end
	local shared = sharedEvents:upcoming(MAX_LEAD)
	if shared then
		add("shared:" .. shared.id, "shared_" .. shared.typeId, shared.x, shared.z, shared.startsAt)
	end
	local rift = rifts:upcoming(MAX_LEAD)
	if rift then
		add("rift:" .. rift.id, "rift", rift.x, rift.z, rift.startsAt)
	end
	for _, p in director:pending() do
		add("world:" .. p.id, "world_" .. p.type, p.x, p.z, p.startsAt)
	end
end

-- ─── Telling ────────────────────────────────────────────────────────────────

local function notice(player: Player, omen: Omen)
	local who = witnessed[omen.id]
	if not who then
		who = {}
		witnessed[omen.id] = who
	end
	who[player.UserId] = true
	local record = recordOf(player)
	if not record then
		return
	end
	for _, signId in Data.sources[omen.source].signs do
		if not record.signs[signId] then
			record.signs[signId] = os.time()
			journal:log(player, "omen", Data.signs[signId].journal, { sign = signId, quiet = true })
			log:info("omen_noticed", { userId = player.UserId, sign = signId, source = omen.source })
		end
	end
end

local function arrive(omen: Omen)
	arrived[omen.id] = true
	local source = Data.sources[omen.source]
	local count = 0
	for userId in witnessed[omen.id] or {} do
		local player = Players:GetPlayerByUserId(userId)
		local record = player and recordOf(player)
		if player and record and not record.after[omen.source] then
			record.after[omen.source] = os.time()
			journal:log(player, "omen", source.after, { omen = omen.source, quiet = true })
		end
		count += 1
	end
	log:info("omen_arrived", { id = omen.id, source = omen.source, witnesses = count })
end

local function rootOf(player: Player): BasePart?
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function update()
	local now = os.time()
	if enabled() then
		discover()
	else
		table.clear(omens)
	end

	-- Strength now; gone when it's over; arrival once.
	local strengths: { [string]: number } = {}
	for id, omen in omens do
		local s = OmenRules.strength(omen.startsAt, now, Data.sources[omen.source].lead)
		if not s then
			omens[id] = nil
			witnessed[id] = nil
			arrived[id] = nil
		else
			strengths[id] = s
			if now >= omen.startsAt and not arrived[id] then
				arrive(omen)
			end
		end
	end

	-- What each player sees from where they stand.
	for _, player in Players:GetPlayers() do
		local root = rootOf(player)
		local list: { OmenRules.Seen } = {}
		local payload: { { [string]: any } } = {}
		if root then
			for id, omen in omens do
				local source = Data.sources[omen.source]
				local dx, dz = omen.x - root.Position.X, omen.z - root.Position.Z
				local s = strengths[id]
				if s and OmenRules.visible(source, dx, dz) then
					table.insert(list, { id = id, source = omen.source, s = s })
					table.insert(payload, { id = id, source = omen.source, x = omen.x, y = omen.y, z = omen.z, s = s })
					if OmenRules.noticeable(source, dx, dz, s) and not (witnessed[id] and witnessed[id][player.UserId]) then
						notice(player, omen)
					end
				end
			end
		end
		local signature = OmenRules.signature(list)
		if lastSent[player] ~= signature then
			lastSent[player] = signature
			Net.fire("Omens", player, { list = payload })
		end
	end
end

-- A townsperson near a strong omen talks about it (one sign of it, chosen by who they are).
local function rumor(player: Player, npc: any): string?
	if not enabled() then
		return nil
	end
	local at: Vector3? = npc and npc.position
	if typeof(at) ~= "Vector3" then
		return nil
	end
	local now = os.time()
	local best: Omen?, bestS = nil, Data.noticeAt
	for _, omen in omens do
		local s = OmenRules.strength(omen.startsAt, now, Data.sources[omen.source].lead)
		local dx, dz = omen.x - at.X, omen.z - at.Z
		if s and s >= bestS and now < omen.startsAt and dx * dx + dz * dz <= Data.rumorRange * Data.rumorRange then
			best, bestS = omen, s
		end
	end
	if not best then
		return nil
	end
	local signs = Data.sources[best.source].signs
	local pick = (#tostring(npc.id) % #signs) + 1
	local who = witnessed[best.id]
	if not who then
		who = {}
		witnessed[best.id] = who
	end
	who[player.UserId] = true -- you heard of it: its arrival will mean something to you
	return OmenRules.rumor(signs[pick], at.X, at.Z, best.x, best.z)
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	local sourceIds: { string } = {}
	for id in Data.sources do
		table.insert(sourceIds, id)
	end
	table.sort(sourceIds)

	admin:Register({
		name = "omens",
		category = "World",
		description = "List the omens showing now: what they come before, where, how strong, and how long until it begins",
		handler = function()
			local now = os.time()
			local lines = {}
			for id, omen in omens do
				local s = OmenRules.strength(omen.startsAt, now, Data.sources[omen.source].lead) or 0
				table.insert(lines, string.format("%s  %s at (%.0f, %.0f)  strength %.2f  %s", id, omen.source, omen.x, omen.z, s,
					if now < omen.startsAt then string.format("in %d s", omen.startsAt - now) else "begun"))
			end
			table.sort(lines)
			return if #lines > 0 then table.concat(lines, "\n") else "(no omens: nothing big is coming soon)"
		end,
	})
	admin:Register({
		name = "omen",
		category = "World",
		description = "Raise a test omen at your feet, as if its event began in `lead` seconds (the event itself won't come)",
		args = {
			{ name = "source", type = "enum", options = sourceIds },
			{ name = "lead", type = "number", default = 60 },
		},
		handler = function(ctx: any, a: any)
			local root = rootOf(ctx.player)
			if not root then
				return "you have no body right now"
			end
			testCount += 1
			local id = "test:" .. testCount
			local source = Data.sources[a.source]
			-- Start partway into its lead so it shows at once and peaks after `lead` seconds.
			local startsAt = os.time() + math.max(5, math.floor(a.lead))
			omens[id] = { id = id, source = a.source, x = root.Position.X + 30, y = groundY(root.Position.X + 30, root.Position.Z), z = root.Position.Z, startsAt = startsAt, test = true }
			return string.format("%s: %s, peaks in %d s (its real lead is %d s)", id, a.source, startsAt - os.time(), source.lead)
		end,
	})
	admin:Register({
		name = "omennotes",
		category = "World",
		description = "List the omen Journal lines a player has written (signs seen, events tied to them), or clear them",
		args = {
			{ name = "player", type = "player", default = "me" },
			{ name = "clear", type = "string", default = "" },
		},
		handler = function(_ctx: any, a: any)
			local record = recordOf(a.player)
			if not record then
				return "no data for them yet"
			end
			if a.clear == "clear" then
				table.clear(record.signs)
				table.clear(record.after)
				return "cleared"
			end
			local signs, after = {}, {}
			for id in record.signs do
				table.insert(signs, id)
			end
			for id in record.after do
				table.insert(after, id)
			end
			table.sort(signs)
			table.sort(after)
			return string.format("signs: %s\nafter: %s", if #signs > 0 then table.concat(signs, ", ") else "none",
				if #after > 0 then table.concat(after, ", ") else "none")
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function OmenService.init(_self: any, ctx: any)
	log = ctx.log
	journal = ctx.get("JournalService")
	playerData = ctx.get("PlayerDataService")
	world = ctx.get("WorldStateService")
	director = ctx.get("EventDirector")
	titans = ctx.get("TitanService")
	sharedEvents = ctx.get("SharedEventService")
	rifts = ctx.get("RiftService")
	ctx.get("NPCService"):setRumorHook(rumor, true)
	registerAdmin(ctx.get("AdminService"))
end

function OmenService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		lastSent[player] = nil
	end)
	task.spawn(function()
		while true do
			task.wait(Data.tick)
			local ok, err = pcall(update)
			if not ok then
				log:warn("omen_update_failed", { err = tostring(err) })
			end
		end
	end)
end

return OmenService
