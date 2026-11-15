--!strict
--[[
	SenseService: the living side of Sense sight (docs/SenseSight.md).

	1. TRACKS. Every `tracks.sampleEvery` seconds it notes where every player, NPC rig and creature
	   is (Shared/Magic/SenseRules TrackStore): a mover that has gone `minStep` studs on the ground
	   since its last print leaves a new one. Prints fade from the store after `keepSeconds`. Only
	   bodies that exist in the workspace leave prints, so far-off NPCs simulated without a rig
	   don't (nobody could read their tracks there anyway).
	2. DELIVERY. Cast/SenseSight gathers what a Sense spell shows; this service sends it to the
	   caster alone (remote SenseReveal) and, the first time a player sees each kind with something
	   in it, writes a first-person Journal line (save `data.sight.noted`, once per kind, ever).
	   No toast, no card: the world shows it and the Journal remembers it.

	Admin: `sensesight <kind> [power] [player]` shows a kind around a player as if they'd cast it;
	`sensetracks [player]` counts the prints held and near them; `sensenotes [player] [clear]`.
	Log: `sense_noticed` { userId, kind, shown } (the first time per kind).

	Cost: one pass over players, rigs in workspace.NPCs and models in workspace.Creatures per sample
	(one table write per mover that moved), a prune every 10 s.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Net = require(Shared.Net)
local Data = require(Shared.Magic.Data.SenseSight)
local SenseRules = require(Shared.Magic.SenseRules)
local SenseSight = require(ServerScriptService.Server.Magic.Cast.SenseSight)

local SenseService = {
	name = "SenseService",
	dependencies = { "AdminService", "JournalService", "PlayerDataService", "WorldStateService" },
}

local PRUNE_EVERY = 10

local log: any = nil
local journal: any = nil
local playerData: any = nil
local world: any = nil
local tracks = SenseRules.newTracks()

-- Creatures have no stable id attribute everywhere: give each model one for its life.
local creatureKeys: { [Model]: string } = setmetatable({}, { __mode = "k" }) :: any
local creatureCount = 0

local function recordOf(player: Player): { noted: { [string]: number } }?
	local state = playerData:get(player)
	if not state then
		return nil
	end
	local data = state.data
	data.sight = data.sight or { noted = {} }
	data.sight.noted = data.sight.noted or {}
	return data.sight
end

-- ─── Tracks ─────────────────────────────────────────────────────────────────

local function grounded(model: Model, root: BasePart): boolean
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return true -- a creature body without a Humanoid walks on its feet
	end
	if root.Anchored then
		return true -- a far rig, moved by the NPC system: it walked there
	end
	return humanoid.FloorMaterial ~= Enum.Material.Air and humanoid.FloorMaterial ~= Enum.Material.Water
end

local function stepModel(key: string, model: Model, kind: string, now: number)
	local root = model:FindFirstChild("HumanoidRootPart") or model.PrimaryPart
	if not root or not root:IsA("BasePart") then
		return
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	if humanoid and humanoid.Health <= 0 then
		return
	end
	-- The print sits on the ground under the body: hip height plus half the root.
	local drop = if humanoid then humanoid.HipHeight + root.Size.Y / 2 else root.Size.Y / 2
	tracks:step(key, root.Position - Vector3.new(0, drop, 0), now, kind, grounded(model, root))
end

local function sample()
	local now = workspace:GetServerTimeNow()
	for _, player in Players:GetPlayers() do
		local character = player.Character
		if character then
			stepModel("p" .. player.UserId, character, "person", now)
		end
	end
	local npcs = workspace:FindFirstChild("NPCs")
	if npcs then
		for _, model in npcs:GetChildren() do
			if model:IsA("Model") then
				local id = model:GetAttribute("NpcId")
				stepModel("n" .. tostring(id or model.Name), model, "person", now)
			end
		end
	end
	local creatures = workspace:FindFirstChild("Creatures")
	if creatures then
		for _, model in creatures:GetChildren() do
			if model:IsA("Model") then
				local key = creatureKeys[model]
				if not key then
					creatureCount += 1
					key = "c" .. creatureCount
					creatureKeys[model] = key
				end
				stepModel(key, model, "beast", now)
			end
		end
	end
end

-- ─── Delivery ───────────────────────────────────────────────────────────────

local function send(player: Player, payload: { [string]: any })
	Net.fire("SenseReveal", player, payload)
end

local function revealed(player: Player, kind: string, shown: number)
	if shown <= 0 then
		return -- nothing showed: nothing to write about yet
	end
	local def = Data.kinds[kind]
	local record = recordOf(player)
	if not def or not record or record.noted[kind] then
		return
	end
	record.noted[kind] = os.time()
	journal:log(player, "sight", def.journal, { sight = kind, quiet = true })
	log:info("sense_noticed", { userId = player.UserId, kind = kind, shown = shown })
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "sensesight",
		category = "Magic",
		description = "Show a player one kind of Sense sight around them, as if they'd cast it (heat, metal, ley, tracks)",
		args = {
			{ name = "kind", type = "enum", options = Data.order },
			{ name = "power", type = "number", default = 4 },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_ctx: any, a: any)
			local character = a.player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if not character or not root then
				return "they have no body right now"
			end
			local shown, line = SenseSight.revealAt(a.player, character, root.Position, a.kind, a.power, nil, world)
			return string.format("%s: %d shown, radius %.0f, %.0f s. \"%s\"", a.kind, shown, SenseRules.radiusFor(a.power, nil), SenseRules.durationFor(a.power), line)
		end,
	})
	admin:Register({
		name = "sensetracks",
		category = "Magic",
		description = "Count the footprints Sense sight remembers: all of them, and those within 60 studs of a player (not their own)",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_ctx: any, a: any)
			local character = a.player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			local near = if root then #tracks:query(root.Position, 60, workspace:GetServerTimeNow(), "p" .. a.player.UserId, 10000) else 0
			return string.format("%d prints held, %d within 60 studs (last %d s)", tracks:count(), near, Data.tracks.keepSeconds)
		end,
	})
	admin:Register({
		name = "sensenotes",
		category = "Magic",
		description = "List the Sense sight Journal lines a player has already written (once per kind), or clear them so they can be written again",
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
				table.clear(record.noted)
				return "cleared"
			end
			local ids = {}
			for id in record.noted do
				table.insert(ids, id)
			end
			table.sort(ids)
			return if #ids == 0 then "none yet" else table.concat(ids, ", ")
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function SenseService.init(_self: any, ctx: any)
	log = ctx.log
	journal = ctx.get("JournalService")
	playerData = ctx.get("PlayerDataService")
	world = ctx.get("WorldStateService")
	SenseSight.setTracks(tracks)
	SenseSight.setHooks({ send = send, revealed = revealed })
	registerAdmin(ctx.get("AdminService"))
end

function SenseService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		tracks:forget("p" .. player.UserId)
	end)
	task.spawn(function()
		local sincePrune = 0
		while true do
			task.wait(Data.tracks.sampleEvery)
			if FeatureFlags.get("sense_sight_enabled") == true then
				local ok, err = pcall(sample)
				if not ok then
					log:warn("sense_sample_failed", { err = tostring(err) })
				end
			end
			sincePrune += Data.tracks.sampleEvery
			if sincePrune >= PRUNE_EVERY then
				sincePrune = 0
				tracks:prune(workspace:GetServerTimeNow())
			end
		end
	end)
end

return SenseService
