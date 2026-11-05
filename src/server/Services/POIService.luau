--!strict
--[[
	POIService: makes places matter. Every 2 s it checks each player against nearby points of
	interest (and active events) and, after the required dwell time, grants:

		catalysts   mines (ore), vents (heat), caverns (geode), wildfires, volcanic unrest
		insights    fault zones, vents, the ocean trench, caverns, a tempest's eye (breakthroughs)
		lore        academies (primers), libraries and hermits (treatises), shrines (primers),
		            plus lore HINTS toward the hidden mythic sites
		awakenings  location awakening events (Singing Caverns, Hollow Grove, Sunken Shrine,
		            The Quiet Place, Eye of the Storm) through InnateProfile.applyAwakening
		mythic      hidden sites; only reachable with enough lore hints AND the right moment
		            (an eclipse at the Stopped Clock; a starfall at the crater)

	Dwell times shrink where magic is dense (density 2 = half the time).
	Visible POIs are sent to clients as map markers; hidden ones never leave the server.
]]

local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Registry = require(Shared.Magic.Registry)
local Seed = require(Shared.Magic.Seed)
local Server = ServerScriptService.Server
local InnateProfile = require(Server.Magic.InnateProfile)
local Settlements = require(Server.World.Settlements)

local TICK = 2

-- Seconds of presence needed for each awakening site (before the density speed-up).
local AWAKENING_DWELL: { [string]: number } = {
	singingCaverns = 300,
	hollowGrove = 180,
	sunkenShrine = 10,
	quietPlace = 600,
	stormEye = 20,
	stoppedClock = 10,
	starfall = 5,
	theSeam = 10,
}

-- Lore hints a player needs before a mythic site will even respond.
local HINTS_NEEDED: { [string]: number } = { time = 2, gravity = 2, reality = 3 }
-- The world moment a mythic site needs (an active EventDirector event), if any.
local MYTHIC_MOMENT: { [string]: string } = { time = "eclipse", gravity = "starfall" }

local POIService = {
	name = "POIService",
	dependencies = { "NetService", "WorldStateService", "PlayerDataService", "ProgressionService", "EventDirector" },
}

local log: any = nil
local flags: any = nil
local world: any = nil
local playerData: any = nil
local progression: any = nil
local events: any = nil
local dwell: { [Player]: { [string]: number } } = {}
local currentSettlement: { [Player]: string } = {}

local function notify(player: Player, text: string)
	Net.fire("Notify", player, text)
end

local function hintCount(state: any, mythic: string): number
	local prefix = "hint:" .. mythic .. ":"
	local count = 0
	for loreId in state.data.progression.lore do
		if string.sub(loreId, 1, #prefix) == prefix then
			count += 1
		end
	end
	return count
end

local function awaken(player: Player, state: any, eventId: string)
	if not flags.get("awakenings_enabled") then
		return
	end
	local result = InnateProfile.applyAwakening(state.innate, eventId, { now = os.time() })
	if not result.ok then
		return
	end
	progression:syncInnate(player)
	playerData:refreshCaster(player)
	if #result.revealed > 0 then
		notify(player, "Something inside you answers this place.")
		log:info("awakened", { userId = player.UserId, event = eventId, revealed = #result.revealed })
	end
end

-- Knowledge a visit teaches: the next steps on paths the player is already walking.
local function grantLore(player: Player, state: any, poi: any)
	local kind = poi.grants.lore
	if not kind then
		return
	end
	local p = state.data.progression
	local granted = {}
	local function teachChildren(prefix: string, depth: number, domain: string?, limit: number)
		for branchId in p.unlocked do
			local branch = Registry.branches[branchId]
			if not domain or branch.domains[1] == domain then
				for _, childId in branch.children do
					local child = Registry.branches[childId]
					local loreId = prefix .. childId
					if #granted < limit and child.tier == depth and not p.lore[loreId] then
						p.lore[loreId] = os.time()
						table.insert(granted, child.name)
					end
				end
			end
		end
	end
	if kind == "academy" then
		teachChildren("primer:", 2, nil, 2)
	elseif kind == "library" then
		teachChildren("treatise:", 3, nil, 2)
	elseif kind == "hermit" then
		teachChildren("treatise:", 3, nil, 1)
		local roll = Seed.random(0, player.UserId .. ":" .. poi.id, "hermit"):NextNumber()
		if roll < 0.1 and not p.lore["rite:unbinding"] then
			p.lore["rite:unbinding"] = os.time()
			table.insert(granted, "the Rite of Unbinding")
		end
	elseif string.sub(kind, 1, 7) == "shrine:" then
		teachChildren("primer:", 2, string.sub(kind, 8), 1)
	end
	for _, hintId in poi.hints do
		if not p.lore[hintId] then
			p.lore[hintId] = os.time()
			local text = world:placement().hintText[hintId]
			if text then
				notify(player, text)
			end
		end
	end
	if #granted > 0 then
		notify(player, "You learned about: " .. table.concat(granted, ", "))
	end
end

-- Records a catalyst once (recordFact also rebuilds the caster and notifies, so don't repeat it).
local function grantCatalyst(player: Player, state: any, id: string)
	if state.data.progression.records.catalysts[id] == nil then
		progression:recordFact(player, "catalyst", id)
	end
end

local function visitPOI(player: Player, state: any, poi: any, seconds: number, density: number)
	local grants = poi.grants
	local first = state.data.discoveries.locations[poi.id] == nil
	if first then
		state.data.discoveries.locations[poi.id] = os.time()
		if not poi.hidden then
			grantLore(player, state, poi)
		end
	end
	if grants.catalyst and seconds >= 10 then
		grantCatalyst(player, state, grants.catalyst)
	end
	if grants.insight and seconds >= 30 then
		progression:studyInsight(player, grants.insight)
	end
	local eventId = grants.awakening
	if eventId then
		local needed = (AWAKENING_DWELL[eventId] or 60) / math.max(0.5, density)
		if poi.type == "quiet_place" and density > 0.2 then
			return -- the quiet only exists where magic truly fails
		end
		local mythic = grants.mythic
		if mythic then
			if hintCount(state, mythic) < (HINTS_NEEDED[mythic] or 2) then
				return
			end
			local moment = MYTHIC_MOMENT[mythic]
			if moment and not events:isActive(moment) then
				return
			end
		end
		if seconds >= needed then
			awaken(player, state, eventId)
		end
	end
end

-- Events grant things to people inside them (wildfire/heat catalysts, the tempest's eye).
local function visitEvents(player: Player, position: Vector3)
	local state = playerData:get(player)
	if not state then
		return
	end
	local EventDefs = require(Server.World.EventDefs)
	for _, e in events:activeAt(position.X, position.Z) do
		local grants = EventDefs[e.type].grants
		if grants then
			if grants.catalyst then
				grantCatalyst(player, state, grants.catalyst)
			end
			local nearCentre = (e.x - position.X) ^ 2 + (e.z - position.Z) ^ 2 <= 80 * 80
			if grants.insight and nearCentre then
				progression:studyInsight(player, grants.insight)
			end
			if grants.awakening and nearCentre then
				awaken(player, state, grants.awakening)
			end
		end
	end
end

local function tick()
	local placement = world:placement()
	for _, player in Players:GetPlayers() do
		local state = playerData:get(player)
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		if not state or not root then
			continue
		end
		local p = root.Position
		local timers = dwell[player] or {}
		dwell[player] = timers
		local density = world:densityAt(p.X, p.Z)
		local present: { [string]: boolean } = {}
		for _, poi in placement.pois do
			local d2 = (poi.x - p.X) ^ 2 + (poi.z - p.Z) ^ 2
			if d2 <= poi.radius * poi.radius then
				present[poi.id] = true
				timers[poi.id] = (timers[poi.id] or 0) + TICK
				visitPOI(player, state, poi, timers[poi.id], density)
			end
		end
		for id in timers do
			if not present[id] then
				timers[id] = nil -- dwell must be continuous
			end
		end
		visitEvents(player, p)

		-- Settlement arrival notice: culture and its laws on magic.
		local settlement = world:settlementAt(p.X, p.Z)
		local settlementId = if settlement then settlement.id else ""
		if settlementId ~= (currentSettlement[player] or "") then
			currentSettlement[player] = settlementId
			if settlement then
				local culture = Settlements.cultures[settlement.culture]
				notify(player, string.format("%s - a %s %s. Casting in town: %s.", settlement.name, settlement.size, culture.name, culture.laws.castingInTown))
			end
		end
	end
end

local function sendMarkers(player: Player)
	local markers = {}
	for _, poi in world:placement().pois do
		if not poi.hidden then
			table.insert(markers, {
				id = poi.id,
				type = poi.type,
				x = math.floor(poi.x),
				z = math.floor(poi.z),
				name = if poi.settlement then poi.settlement.name else nil,
			})
		end
	end
	Net.fire("PoiMarkers", player, markers)
end

function POIService.init(_self: any, ctx: any)
	log, flags = ctx.log, ctx.flags
	world = ctx.get("WorldStateService")
	playerData = ctx.get("PlayerDataService")
	progression = ctx.get("ProgressionService")
	events = ctx.get("EventDirector")
	ctx.bus:subscribe(Topics.PlayerDataLoaded, function(payload)
		world:awaitReady()
		sendMarkers(payload.player)
	end)
end

function POIService.start(_self: any, _ctx: any)
	world:awaitReady()
	Players.PlayerRemoving:Connect(function(player)
		dwell[player] = nil
		currentSettlement[player] = nil
	end)
	while true do
		task.wait(TICK)
		local ok, err = pcall(tick)
		if not ok then
			log:throttled("tick", 30, "Error", "tick_failed", { err = err })
		end
	end
end

return POIService
