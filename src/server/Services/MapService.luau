--!strict
--[[
	MapService: what the map shows you (docs/Map.md). Rules and looks: Shared/World/MapData.

	GRID       One character per cell, built once from the generator when the world is ready.
	UNCOVERING Every 2 s, the ground around each player, further from high up, is saved in their
	           data.discoveries.map. Anything new goes to them straight away.
	SENDING    A client only ever gets cells it has uncovered, and places in that ground. Hidden mythic
	           sites never leave the server, even if you walk across one.

		RequestMap() -> { cols, cell, cells, pois } | nil while the world is generating
		MapReveal    { cells = { i, code, i, code, ... }, pois = { ... } } new ground and places

	Flag: map_enabled. Admin: maprevealall [player], mapreset [player].
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local MapData = require(Shared.World.MapData)

local Server = script.Parent.Parent
local WorldConfig = require(Server.World.WorldConfig)

local TICK = 2

local MapService = {
	name = "MapService",
	dependencies = { "NetService", "AdminService", "PlayerDataService", "WorldStateService" },
}

local log: any = nil
local world: any = nil
local playerData: any = nil
local grid: string? = nil

local function bitsOf(state: any): { [string]: number }
	local discoveries = state.data.discoveries
	local bits = discoveries.map
	if not bits then
		bits = {}
		discoveries.map = bits
	end
	return bits
end

local function buildGrid()
	world:awaitReady()
	local gen = world:gen()
	local parts = table.create(MapData.cols * MapData.cols)
	for index = 0, MapData.cols * MapData.cols - 1 do
		local x, z = MapData.cellCentre(index)
		local sample = gen:sample(x, z)
		parts[index + 1] = MapData.encodeCell(sample.biome, sample.height, WorldConfig.SEA_LEVEL)
		if index % MapData.cols == MapData.cols - 1 then
			task.wait() -- a row a frame: this never holds up the server
		end
	end
	grid = table.concat(parts)
	log:info("map_ready", { cells = #parts })
end

-- What's new for this player after uncovering `fresh`, as MapReveal's payload.
local function sendFresh(player: Player, bits: { [string]: number }, fresh: { number })
	local terrain = grid
	if #fresh == 0 or not terrain then
		return
	end
	local cells = table.create(#fresh * 2)
	local isNew: { [number]: boolean } = {}
	for _, index in fresh do
		table.insert(cells, index)
		table.insert(cells, string.sub(terrain, index + 1, index + 1))
		isNew[index] = true
	end
	local pois = {}
	for _, known in MapData.knownPois(world:placement().pois, bits) do
		if isNew[MapData.cellIndex(known.x, known.z)] then
			table.insert(pois, known)
		end
	end
	Net.fire("MapReveal", player, { cells = cells, pois = pois })
end

local function tick()
	if FeatureFlags.get("map_enabled") ~= true or not grid then
		return
	end
	for _, player in Players:GetPlayers() do
		local state = playerData:get(player)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if state and root and root:IsA("BasePart") then
			local p = root.Position
			local height = p.Y - math.max(world:surfaceHeight(p.X, p.Z), WorldConfig.SEA_LEVEL)
			local bits = bitsOf(state)
			sendFresh(player, bits, MapData.revealAround(bits, p.X, p.Z, MapData.radiusAt(height)))
		end
	end
end

function MapService.init(_self: any, ctx: any)
	log = ctx.log
	world = ctx.get("WorldStateService")
	playerData = ctx.get("PlayerDataService")
	Net.handle("RequestMap", function(player: Player)
		local terrain = grid
		local state = playerData:get(player)
		if not terrain or not state or FeatureFlags.get("map_enabled") ~= true then
			return nil
		end
		local bits = bitsOf(state)
		return {
			cols = MapData.cols,
			cell = MapData.cell,
			cells = MapData.visibleGrid(terrain, bits),
			pois = MapData.knownPois(world:placement().pois, bits),
		}
	end)
	local admin = ctx.get("AdminService")
	admin:Register({
		name = "maprevealall",
		category = "World",
		description = "Uncover the whole map for a player (hidden sites stay hidden; reopen the map to redraw)",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_ctx: any, a: any)
			local state = playerData:get(a.player)
			local terrain = grid
			if not state or not terrain then
				return "not ready"
			end
			local bits = bitsOf(state)
			local fresh: { number } = {}
			for index = 0, #terrain - 1 do
				if MapData.reveal(bits, index) then
					table.insert(fresh, index)
				end
			end
			sendFresh(a.player, bits, fresh)
			return string.format("uncovered %d cells", #fresh)
		end,
	})
	admin:Register({
		name = "mapreset",
		category = "World",
		description = "Forget everything a player has uncovered (they see it on their next join)",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_ctx: any, a: any)
			local state = playerData:get(a.player)
			if not state then
				return "not ready"
			end
			state.data.discoveries.map = {}
			return "forgotten"
		end,
	})
end

function MapService.start(_self: any, _ctx: any)
	task.spawn(buildGrid)
	task.spawn(function()
		while true do
			task.wait(TICK)
			local ok, err = pcall(tick)
			if not ok then
				log:throttled("map_tick", 30, "Error", "map_tick_failed", { err = err })
			end
		end
	end)
end

return MapService
