--!strict
--[[
	CraftingService: crafting at stations (docs/Buildings.md §5). The first station is the smithy
	forge; the crafting stage adds the other stations, discovery and experimentation on the same
	recipe format (Shared/Items/Data/Recipes).

	FLOW
		the forge's prompt -> open(player, part) -> StationView { id, station, tier, name } to the
		player -> the Crafting screen lists that station's recipes -> CraftAction(stationId,
		recipeId, count) -> checks -> one atomic InventoryService:transact: inputs removed, outputs
		added; if anything doesn't fit, nothing happens (NO_ROOM).

	CHECKS (every craft)  the station exists, the player is alive and beside it (prompt distance +
	6), the recipe belongs to this station, StationTier >= recipe tier, recipe mastery requirements
	met, every input present (tag inputs: any items carrying the tag, spent in item-id order), a
	0.4 s per-player cooldown. Count 1-10 per request.

	QUALITY (recipes with quality = true): 40 + 6 x metallurgy tier + 8 x (station tier - 1)
	± 6, seeded from the new item's uid, clamped 5-100; the item carries the crafter's display
	name (ItemInstance: "Made by ..."). Crafted gear is Common rarity: quality is its variation.

	XP: recipe.xp through ProgressionService:awardQuest (study XP; only for unlocked branches).
	Topic ItemCrafted { player, recipe, itemId, count }.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local MagicCore = require(Shared.Magic.MagicCore)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local Recipes = require(Shared.Items.Data.Recipes)
local Interactables = require(Shared.World.Interactables)
local ItemTypes = require(Shared.Items.ItemTypes)
local Repair = require(Shared.Items.Repair)

local Server = ServerScriptService.Server
local Inventory = require(Server.Items.Inventory)
local ItemGenerator = require(Server.Items.ItemGenerator)

local REACH_SLACK = 6
local COOLDOWN = 0.4
local MAX_COUNT = 10

local CraftingService = {
	name = "CraftingService",
	dependencies = { "NetService", "InventoryService", "ProgressionService", "PlayerDataService", "WorldService" },
}

local bus: any = nil
local inventory: any = nil
local progression: any = nil
local playerData: any = nil
local worldService: any = nil
local lastCraft: { [Player]: number } = {}

-- ─── Validation (boot) ──────────────────────────────────────────────────────

local stationIds: { [string]: boolean } = {}
for _, def in Interactables do
	if def.station then
		stationIds[def.station.id] = true
	end
end
for _, r in Recipes.list do
	assert(stationIds[r.station], "Recipe " .. r.id .. ": unknown station " .. r.station)
	assert(ItemDatabase.get(r.output.item), "Recipe " .. r.id .. ": unknown output " .. r.output.item)
	for _, input in r.inputs do
		if input.item then
			assert(ItemDatabase.get(input.item), "Recipe " .. r.id .. ": unknown input " .. input.item)
		else
			assert(input.tag and #ItemDatabase.withTag(input.tag) > 0, "Recipe " .. r.id .. ": no item carries tag " .. tostring(input.tag))
		end
	end
end

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function stationOf(part: BasePart): (string?, number)
	local kind = part:GetAttribute("Interactable")
	local def = typeof(kind) == "string" and Interactables[kind] or nil
	local tier = part:GetAttribute("StationTier")
	return if def and def.station then def.station.id else nil, if typeof(tier) == "number" then tier else 1
end

local function stationById(id: string): BasePart?
	for _, part in CollectionService:GetTagged("Interactable") do
		if part:IsA("BasePart") and part:GetAttribute("InteractId") == id then
			return part
		end
	end
	return nil
end

local function inReach(player: Player, part: BasePart): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local kind = part:GetAttribute("Interactable")
	local def = typeof(kind) == "string" and Interactables[kind] or nil
	if not root or not humanoid or humanoid.Health <= 0 or not def or not part:IsDescendantOf(workspace) then
		return false
	end
	return (root.Position - part.Position).Magnitude <= def.distance + REACH_SLACK
end

local function matcher(input: Recipes.Ingredient): (any) -> boolean
	if input.item then
		local id = input.item
		return function(def)
			return def.id == id
		end
	end
	local tag = input.tag :: string
	return function(def)
		return table.find(def.tags, tag) ~= nil
	end
end

local function quality(player: Player, uid: string, stationTier: number): number
	local data = playerData:get(player)
	local tier = if data then MagicCore.masteryTier(data.caster, "metallurgy") else 0
	local rng = Seed.random(worldService:getSeed(), uid, "quality")
	return math.clamp(math.floor(40 + 6 * tier + 8 * (stationTier - 1) + rng:NextInteger(-6, 6)), 5, 100)
end

-- ─── Craft ──────────────────────────────────────────────────────────────────

local function craft(player: Player, stationId: string, recipeId: string, count: number): { ok: boolean, reason: string? }
	local recipe = Recipes.byId[recipeId]
	local part = stationById(stationId)
	if not recipe or not part then
		return { ok = false, reason = "UNKNOWN" }
	end
	if not inReach(player, part) then
		return { ok = false, reason = "TOO_FAR" }
	end
	local station, tier = stationOf(part)
	if station ~= recipe.station then
		return { ok = false, reason = "WRONG_STATION" }
	end
	if tier < recipe.tier then
		return { ok = false, reason = "STATION_TIER" }
	end
	-- Cooking needs the fire lit (Interact/Lamps marks the building Warm).
	if recipe.station == "hearth" then
		local building = part:FindFirstAncestorWhichIsA("Model")
		while building and building:GetAttribute("BuildingType") == nil do
			building = building:FindFirstAncestorWhichIsA("Model")
		end
		if not building or building:GetAttribute("Warm") ~= true then
			return { ok = false, reason = "FIRE_OUT" }
		end
	end
	local data = playerData:get(player)
	local met, why = ItemInstance.meets(recipe.requires :: any, data and data.caster)
	if not met then
		return { ok = false, reason = "REQUIREMENTS: " .. (why or "") }
	end
	local t = os.clock()
	if lastCraft[player] and t - lastCraft[player] < COOLDOWN then
		return { ok = false, reason = "COOLDOWN" }
	end
	lastCraft[player] = t

	local outDef = ItemDatabase.get(recipe.output.item) :: any
	local seed = worldService:getSeed()
	local n = math.clamp(math.floor(count), 1, MAX_COUNT)
	local ok, reason = inventory:transact(player, "craft", string.format("%s x%d @%s", recipe.id, n, stationId), function(inv): (boolean, string?)
		for _ = 1, n do
			for _, input in recipe.inputs do
				if not Inventory.removeMatching(inv, matcher(input), input.n) then
					return false, "MISSING_INGREDIENTS"
				end
			end
			if outDef.stack > 1 then
				local rec = ItemGenerator.roll(outDef.id, ItemGenerator.rng(seed, "craft:" .. recipe.id), { count = recipe.output.n }) :: any
				local added = Inventory.add(inv, rec, inventory:ownerKey(player))
				if added < recipe.output.n then
					return false, "NO_ROOM"
				end
			else
				for _ = 1, recipe.output.n do
					local uid = Inventory.mintUid(inv, inventory:ownerKey(player))
					local rec = ItemGenerator.roll(outDef.id, ItemGenerator.rng(seed, uid), { rarity = "common" }) :: any
					rec.u, rec.t = uid, os.time()
					if recipe.quality then
						rec.q = quality(player, uid, tier)
						rec.c = player.DisplayName
					end
					if Inventory.add(inv, rec, inventory:ownerKey(player)) < 1 then
						return false, "NO_ROOM"
					end
				end
			end
		end
		return true, nil
	end)
	if not ok then
		return { ok = false, reason = reason }
	end
	if recipe.xp then
		progression:awardQuest(player, recipe.xp.branch, recipe.xp.amount * n)
	end
	bus:publish(Topics.ItemCrafted, { player = player, recipe = recipe.id, itemId = outDef.id, count = recipe.output.n * n })
	return { ok = true }
end

-- ─── Repair ─────────────────────────────────────────────────────────────────

--[[
	RepairAction(stationId, ref | "all") at the station Shared/Items/Repair names for each item
	(metal at the forge, wood and leather at the workbench, cloth at the loom). One atomic
	transaction: every coin and material is taken and every item mended, or nothing changes.
	"all" mends everything carried or worn that this station can mend.
]]
local function repair(player: Player, stationId: string, ref: string): { ok: boolean, reason: string?, repaired: number?, coins: number? }
	local t = os.clock()
	if (lastCraft[player] or 0) + COOLDOWN > t then
		return { ok = false, reason = "TOO_FAST" }
	end
	lastCraft[player] = t
	local part = stationById(stationId)
	if not part or not inReach(player, part) then
		return { ok = false, reason = "TOO_FAR" }
	end
	local station = stationOf(part)
	local repaired, coins = 0, 0
	local ok, reason = inventory:transact(player, "repair", stationId .. " " .. ref, function(inv)
		local targets: { ItemTypes.Record } = {}
		local materials: { [string]: number } = {}
		local cost = 0
		local function consider(rec: ItemTypes.Record): string?
			local quote = Repair.quote(rec)
			if not quote then
				return "NOT_DAMAGED"
			elseif quote.station ~= station then
				return "WRONG_STATION"
			end
			table.insert(targets, rec)
			cost += quote.coins
			if quote.material then
				materials[quote.material] = (materials[quote.material] or 0) + quote.materialCount
			end
			return nil
		end
		if ref == "all" then
			for _, entry in Inventory.each(inv) do
				consider(entry.rec)
			end
			if #targets == 0 then
				return false, "NOTHING_TO_REPAIR"
			end
		else
			local rec = Inventory.at(inv, ref)
			if not rec then
				return false, "EMPTY"
			end
			local why = consider(rec)
			if why then
				return false, why
			end
		end
		if inv.currency < cost then
			return false, "NOT_ENOUGH_COINS"
		end
		for tag, n in materials do
			local taken = Inventory.removeMatching(inv, function(def)
				return table.find(def.tags, tag) ~= nil
			end, n)
			if not taken then
				return false, "MISSING_MATERIALS"
			end
		end
		inv.currency -= cost
		for _, rec in targets do
			rec.d = nil -- full durability
		end
		repaired, coins = #targets, cost
		return true, nil
	end)
	if not ok then
		return { ok = false, reason = reason }
	end
	return { ok = true, repaired = repaired, coins = coins }
end

-- ─── API ────────────────────────────────────────────────────────────────────

function CraftingService.open(_self: any, player: Player, part: BasePart): (boolean, string?)
	if not inReach(player, part) then
		return false, "TOO_FAR"
	end
	local station, tier = stationOf(part)
	local id = part:GetAttribute("InteractId")
	if not station or typeof(id) ~= "string" then
		return false, "NOT_A_STATION"
	end
	local kind = part:GetAttribute("Interactable") :: string
	Net.fire("StationView", player, { id = id, station = station, tier = tier, name = Interactables[kind].object })
	return true, nil
end

function CraftingService.init(_self: any, ctx: any)
	bus = ctx.bus
	inventory = ctx.get("InventoryService")
	progression = ctx.get("ProgressionService")
	playerData = ctx.get("PlayerDataService")
	worldService = ctx.get("WorldService")
	Net.handle("CraftAction", craft :: any)
	Net.handle("RepairAction", repair :: any)
end

function CraftingService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		lastCraft[player] = nil
	end)
end

return CraftingService
