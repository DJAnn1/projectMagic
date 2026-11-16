--!strict
--[[
	HistoryService: things with a past (docs/LivingHistory.md §6, Living History stage 2a). Rules:
	Chronicle/HistoryRules. Names and lines: Chronicle/Data/DeedNames. Legends: Services/ChronicleService.

	ITEMS      When a deed on this server becomes a legend (Topics.LegendMade), the unique item in the
	           top doer's main hand (else off hand) gets a past: `h` (the legend), `hn` (an epithet
	           seeded from the legend: "Ashwalker's Bane"), `hl` (one line: "Struck down The Ashwalker
	           out north of Glenhold."). No player names on it, so it can change hands safely; it keeps
	           its past wherever it goes. A quiet Journal line. Someone who knows the legend (a
	           `legend_of` memory of it, or living in its town) may recognise it when you walk by.
	PLACES     A legend in the wilds names its spot ("Ashwalker's Fall"): a map place (POI type
	           named_place) for whoever has uncovered that ground, and people telling the story say
	           "at Ashwalker's Fall". One per placeSpacing studs, the biggest legend wins. Computed from
	           the legends every server shares, so every server names the same places.
	MONUMENTS  Each town's biggest legend gets a carved stone near its centre. Legends from before this
	           server are standing at boot; a new top legend is raised by the town's own people
	           (TownRepairService.raise: scaffolding, a worker with a hammer, piece by piece), and the
	           old stone goes. Clicking it reads the one line cut into it.

	Flag history_enabled. Admin: history, epithet, monumentnow.
	Log: item_got_past, item_recognised, place_named, place_unnamed, monument_placed, monument_read.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local OmenRules = require(Shared.Magic.OmenRules)
local ItemDatabase = require(Shared.Items.ItemDatabase)

local Server = script.Parent.Parent
local Rules = require(Server.Chronicle.HistoryRules)
local Names = require(Server.Chronicle.Data.DeedNames)
local Inventory = require(Server.Items.Inventory)
local PromptRouter = require(Server.Interact.PromptRouter)
local Util = require(Server.Admin.Util)

local T = Rules.Tuning
local REFRESH = 60 -- seconds between looks at the legends (new ones from other servers arrive every 10 min)
local HANDS = { "e:mainHand", "e:offHand" }

local HistoryService = {
	name = "HistoryService",
	dependencies = {
		"AdminService",
		"AmbientLifeService",
		"ChronicleService",
		"InventoryService",
		"JournalService",
		"NPCService",
		"TownRepairService",
		"WorldService",
		"WorldStateService",
	},
}

type Place = { id: string, name: string, x: number, z: number, poi: string }
type Monument = { legend: string, model: Model, line: string }

local log: any = nil
local chronicle: any = nil
local inventory: any = nil
local journal: any = nil
local npcs: any = nil
local ambient: any = nil
local repair: any = nil
local world: any = nil
local worldService: any = nil

local places: { [string]: Place } = {} -- legend id -> its named place
local monuments: { [string]: Monument } = {} -- town id -> its stone
local recognised: { [string]: { [string]: boolean } } = {} -- npc id -> item uid -> said so (or decided not to)
local folder: Folder? = nil
local booted = false
local counts = { items = 0, recognised = 0, read = 0 }

local function enabled(): boolean
	return FeatureFlags.get("history_enabled") == true
end

local function rollFor(id: string, what: string): number
	return Seed.random(worldService:getSeed(), "history", id, what):NextNumber()
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function townById(id: string?): any?
	if not id then
		return nil
	end
	for _, town in npcs:towns() do
		if town.id == id then
			return town
		end
	end
	return nil
end

local function townName(town: any?): string
	return if town and town.settlement and town.settlement.name then tostring(town.settlement.name) else "a town"
end

-- Where a legend happened, in words, as seen from `town` (or the nearest town if nil).
local function whereOf(entry: any, from: any?): string
	local town = from or townById(entry.town)
	if not town then
		local best, bestD = nil, math.huge
		for _, t in npcs:towns() do
			local d = (t.x - entry.x) ^ 2 + (t.z - entry.z) ^ 2
			if d < bestD then
				best, bestD = t, d
			end
		end
		town = best
	end
	if not town then
		return "out in the wilds"
	end
	local d = math.sqrt((town.x - entry.x) ^ 2 + (town.z - entry.z) ^ 2)
	if d <= town.radius * 1.3 then
		return if from then "here" else "in " .. townName(town)
	end
	local place = places[entry.id]
	local dir = OmenRules.bearing(town.x, town.z, entry.x, entry.z)
	if place then
		return string.format("at %s, out %s of %s", place.name, dir, townName(town))
	end
	return string.format("out %s of %s", dir, townName(town))
end

-- In the wilds: no town's reach covers it.
local function isWild(entry: any): boolean
	for _, town in npcs:towns() do
		if (town.x - entry.x) ^ 2 + (town.z - entry.z) ^ 2 <= (town.radius * 1.3) ^ 2 then
			return false
		end
	end
	return true
end

local function legendById(id: string): any?
	for _, entry in chronicle:legends() do
		if entry.id == id then
			return entry
		end
	end
	return nil
end

-- ─── Items ──────────────────────────────────────────────────────────────────

-- Gives the item in `player`'s hands a past from `entry`. Returns the epithet, or nil and why not.
local function givePast(player: Player, entry: any): (string?, string?)
	local inv = inventory:inventoryOf(player)
	if not inv then
		return nil, "no inventory"
	end
	for _, ref in HANDS do
		local rec = Inventory.at(inv, ref)
		if rec and rec.u and not rec.h then
			local epithet = Rules.epithet(entry, rollFor(entry.id, "epithet"))
			local line = Rules.historyLine(entry, whereOf(entry, nil))
			local ok, err = inventory:edit(player, ref, "past " .. entry.id, function(r: any)
				r.h, r.hn, r.hl = string.sub(entry.id, 1, 64), string.sub(epithet, 1, 64), string.sub(line, 1, 160)
				return true, nil
			end)
			if not ok then
				return nil, tostring(err)
			end
			counts.items += 1
			local def = ItemDatabase.get(rec.i)
			local base = if def then string.lower(def.name) else "it"
			journal:log(player, "legend", string.format("People have started calling my %s %s.", base, epithet), { quiet = true })
			log:info("item_got_past", { userId = player.UserId, item = rec.i, legend = entry.id, epithet = epithet })
			return epithet, nil
		elseif rec and rec.h then
			return nil, "the item in your hands already has a past"
		end
	end
	return nil, "no unique item in your hands"
end

local function onLegend(payload: any)
	local entry = payload and payload.entry
	if not enabled() or typeof(entry) ~= "table" or not entry.by then
		return
	end
	local player = Players:GetPlayerByUserId(entry.by[1])
	if player then
		givePast(player, entry)
	end
end

-- Whether `npc` knows the legend `entry`: it happened in their town, or they remember it.
local function knows(npc: any, entry: any): boolean
	if entry.town and npc.settlementId == entry.town then
		return true
	end
	local note = entry.kind .. "|" .. (entry.what or "")
	for _, m in (npc.memories or {}) :: { any } do
		if m.kind == "legend_of" and m.note == note then
			return true
		end
	end
	return false
end

local function greetHook(npc: any, player: Player, close: boolean, _clock: number): any?
	if not enabled() or not close then
		return nil
	end
	local inv = inventory:inventoryOf(player)
	if not inv then
		return nil
	end
	for _, ref in HANDS do
		local rec = Inventory.at(inv, ref)
		if rec and rec.h and rec.u then
			local seen = recognised[npc.id] or {}
			recognised[npc.id] = seen
			if seen[rec.u] then
				return nil
			end
			local entry = legendById(rec.h)
			if not entry or not knows(npc, entry) then
				return nil
			end
			seen[rec.u] = true -- they've made up their mind about this one
			if rollFor(npc.id, rec.u) >= T.recogniseChance then
				return nil
			end
			return {
				categories = { "item_known" },
				lines = Names.lines,
				vars = { epithet = rec.hn or "that", what = entry.what or Rules.root(entry) },
				said = function(text: string)
					counts.recognised += 1
					log:info("item_recognised", { npc = npc.id, userId = player.UserId, legend = entry.id, text = text })
				end,
			}
		end
	end
	return nil
end

-- ─── Places ─────────────────────────────────────────────────────────────────

local function refreshPlaces(legends: { any })
	local wild: { any } = {}
	for _, entry in legends do
		if isWild(entry) then
			table.insert(wild, entry)
		end
	end
	local keep: { [string]: boolean } = {}
	for _, entry in Rules.places(wild, T.placeSpacing) do
		keep[entry.id] = true
		if not places[entry.id] then
			local name = Rules.placeName(entry, rollFor(entry.id, "place"))
			local poi = "named_place_" .. entry.id
			world:addPOI({
				id = poi,
				type = "named_place",
				name = name,
				x = entry.x,
				z = entry.z,
				biome = "",
				radius = 40,
				hidden = false,
				grants = {},
				settlement = nil,
				hints = {},
			})
			places[entry.id] = { id = entry.id, name = name, x = entry.x, z = entry.z, poi = poi }
			log:info("place_named", { legend = entry.id, name = name, x = math.floor(entry.x), z = math.floor(entry.z) })
		end
	end
	for id, place in places do
		if not keep[id] then
			world:removePOI(place.poi)
			places[id] = nil
			log:info("place_unnamed", { legend = id, name = place.name })
		end
	end
end

-- ─── Monuments ──────────────────────────────────────────────────────────────

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Include
groundParams.FilterDescendantsInstances = { workspace.Terrain }

local function clearAt(spot: Vector3): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local skip: { Instance } = { workspace.Terrain }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(skip, player.Character)
		end
	end
	params.FilterDescendantsInstances = skip
	for _, part in workspace:GetPartBoundsInBox(CFrame.new(spot + Vector3.new(0, 4.5, 0)), Vector3.new(8, 8, 6), params) do
		if part.Anchored then
			return false
		end
	end
	return true
end

-- A free spot near the town's centre, the same on every server unless something's in the way.
local function spotFor(town: any): CFrame?
	local start = rollFor(town.id, "monument") * 2 * math.pi
	for ring = T.monumentRing[1], T.monumentRing[2], 7 do
		for i = 0, 11 do
			local angle = start + i * math.pi / 6
			local x, z = town.x + math.cos(angle) * ring, town.z + math.sin(angle) * ring
			local top = world:surfaceHeight(x, z) + 60
			local hit = workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, -160, 0), groundParams)
			if hit and hit.Material ~= Enum.Material.Water and clearAt(hit.Position) then
				-- It faces the town centre.
				return CFrame.lookAt(hit.Position, Vector3.new(town.x, hit.Position.Y, town.z))
			end
		end
	end
	return nil
end

local function part(model: Model, name: string, size: Vector3, cf: CFrame, material: Enum.Material, color: Color3): BasePart
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Anchored = true
	p.Material = material
	p.Color = color
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p.Parent = model
	return p
end

local function buildStone(town: any, entry: any, at: CFrame, line: string): Model
	local model = Instance.new("Model")
	model.Name = "Monument_" .. town.id
	model:SetAttribute("Monument", entry.id)
	model:SetAttribute("SettlementId", town.id)
	local stone = Color3.fromRGB(118, 116, 110)
	local dark = Color3.fromRGB(88, 86, 82)
	part(model, "Plinth", Vector3.new(6, 1, 4), at * CFrame.new(0, 0.3, 0), Enum.Material.Cobblestone, dark)
	part(model, "Step", Vector3.new(4.4, 0.8, 2.8), at * CFrame.new(0, 1.2, 0), Enum.Material.Slate, stone)
	local face = part(model, "Stone", Vector3.new(3, 6.5, 1.1), at * CFrame.new(0, 4.85, 0) * CFrame.Angles(0, 0, math.rad(rollFor(entry.id, "lean") * 4 - 2)), Enum.Material.Slate, stone)
	part(model, "Cap", Vector3.new(3.4, 0.5, 1.4), at * CFrame.new(0, 8.3, 0), Enum.Material.Slate, dark)
	model.PrimaryPart = face
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Read"
	prompt.ObjectText = "Carved stone"
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Parent = face
	model.Parent = folder
	PromptRouter.connect(prompt, function(player: Player)
		counts.read += 1
		log:info("monument_read", { userId = player.UserId, town = town.id, legend = entry.id })
		return true, nil, line
	end)
	return model
end

-- Puts up (or replaces) `town`'s stone for `entry`. Standing at once at boot; raised by the town after.
local function placeMonument(town: any, entry: any, raise: boolean): string
	local old = monuments[town.id]
	local spot: CFrame? = nil
	if old then
		-- The same place as the stone it replaces: its plinth's base.
		local base = old.model:FindFirstChild("Plinth")
		if base and base:IsA("BasePart") then
			spot = base.CFrame * CFrame.new(0, -0.3, 0)
		end
		monuments[town.id] = nil
		old.model:Destroy()
	end
	spot = spot or spotFor(town)
	if not spot then
		return "no clear ground near the centre"
	end
	local line = Rules.monumentLine(entry, whereOf(entry, town))
	local model = buildStone(town, entry, spot, line)
	monuments[town.id] = { legend = entry.id, model = model, line = line }
	local raised = raise and repair:raise(model, town.id)
	log:info("monument_placed", { town = town.id, legend = entry.id, raised = raised == true })
	return if raised then "the town is raising it" else "standing"
end

local function refreshMonuments(legends: { any }, raise: boolean)
	local byTown: { [string]: { any } } = {}
	for _, entry in legends do
		if entry.town then
			byTown[entry.town] = byTown[entry.town] or {}
			table.insert(byTown[entry.town], entry)
		end
	end
	for townId, list in byTown do
		local town = townById(townId)
		local top = Rules.top(list)
		local current = monuments[townId]
		if town and top and (not current or current.legend ~= top.id) then
			placeMonument(town, top, raise)
		end
	end
end

local function refresh()
	if not enabled() then
		return
	end
	local legends = chronicle:legends()
	refreshPlaces(legends)
	refreshMonuments(legends, booted)
	booted = true
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "history",
		category = "World",
		description = "Things with a past: named places, each town's monument, and the items in your hands",
		args = {},
		handler = function(ctx: any, _a: any)
			local lines = { "" }
			local n = 0
			for _, place in places do
				n += 1
				table.insert(lines, string.format("place %s at (%d, %d)", place.name, math.floor(place.x), math.floor(place.z)))
			end
			lines[1] = string.format("on=%s · places %d · items given a past %d · recognised %d · stones read %d", tostring(enabled()), n, counts.items, counts.recognised, counts.read)
			for townId, m in monuments do
				local p = m.model:GetPivot().Position
				table.insert(lines, string.format("stone in %s (%d, %d): %s", townName(townById(townId)), math.floor(p.X), math.floor(p.Z), m.line))
			end
			local inv = inventory:inventoryOf(ctx.player)
			for _, ref in HANDS do
				local rec = inv and Inventory.at(inv, ref)
				if rec then
					table.insert(lines, string.format("%s: %s%s", ref, rec.i, if rec.hn then " · " .. rec.hn .. " · " .. (rec.hl or "") else " (no past)"))
				end
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "epithet",
		category = "World",
		description = "Give the unique item in your hands a past from the newest legend this server knows (make one with chronicleadd boss_slain yes)",
		args = {},
		handler = function(ctx: any, _a: any)
			local newest: any = nil
			for _, entry in chronicle:legends() do
				if not newest or entry.t > newest.t then
					newest = entry
				end
			end
			if not newest then
				return "no legends yet: chronicleadd boss_slain yes first"
			end
			local epithet, why = givePast(ctx.player, newest)
			return if epithet then string.format("it's %s now (%s)", epithet, newest.id) else tostring(why)
		end,
	})
	admin:Register({
		name = "monumentnow",
		category = "World",
		description = "The nearest town raises its stone again right now, as for a new legend (needs a legend in that town)",
		args = {},
		handler = function(ctx: any, _a: any)
			local root = Util.rootOf(ctx.player)
			if not root then
				return "no character"
			end
			local best, bestD = nil, math.huge
			for _, town in npcs:towns() do
				local d = flat(root.Position, Vector3.new(town.x, 0, town.z))
				if d < bestD then
					best, bestD = town, d
				end
			end
			if not best then
				return "no towns"
			end
			local list: { any } = {}
			for _, entry in chronicle:legends() do
				if entry.town == best.id then
					table.insert(list, entry)
				end
			end
			local top = Rules.top(list)
			if not top then
				return "no legend in " .. townName(best) .. ": stand there and chronicleadd boss_slain yes"
			end
			return townName(best) .. ": " .. placeMonument(best, top, true)
		end,
	})
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

function HistoryService.init(_self: any, ctx: any)
	log = ctx.log
	chronicle = ctx.get("ChronicleService")
	inventory = ctx.get("InventoryService")
	journal = ctx.get("JournalService")
	npcs = ctx.get("NPCService")
	ambient = ctx.get("AmbientLifeService")
	repair = ctx.get("TownRepairService")
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	registerAdmin(ctx.get("AdminService"))
	ambient:setGreetHook(greetHook)
	chronicle:setPlaceNamer(function(entry: any): string?
		local place = places[entry.id]
		return if place then place.name else nil
	end)
	ctx.bus:subscribe(Topics.LegendMade, function(payload: any)
		local ok, err = pcall(onLegend, payload)
		if not ok then
			log:warn("history_legend_failed", { err = tostring(err) })
		end
		task.delay(2, function()
			pcall(refresh)
		end)
	end)
end

function HistoryService.start(_self: any, _ctx: any)
	local parent = Instance.new("Folder")
	parent.Name = "Monuments"
	parent.Parent = workspace
	folder = parent
	task.spawn(function()
		world:awaitReady()
		while not npcs:isReady() do
			task.wait(2)
		end
		task.wait(30) -- the chronicle reads other servers' legends first
		while true do
			local ok, err = pcall(refresh)
			if not ok then
				log:warn("history_refresh_failed", { err = tostring(err) })
			end
			task.wait(REFRESH)
		end
	end)
end

return HistoryService
