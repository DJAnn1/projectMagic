--!strict
--[[
	HousingService: players owning houses (docs/Buildings.md §8).

	WHICH HOUSES   any house no NPC household lives in (SettlementService:npcOwnerOf == nil). A
	               "deed" sign by its door says it's for sale and what it costs.
	BUYING         the sign's prompt (pressed twice: the first press quotes the price). Coins are
	               paid first, then the claim is written to the world store ("housing",
	               world-scoped) with an UpdateAsync that cancels if anyone already holds that
	               house, or if this player already owns one; a lost race refunds at once. The
	               world store is the one truth across servers; every server re-reads it every
	               90 s and applies claims to its built houses (OwnerUserId, OwnerName).
	               Prices: small 400, medium 900, large 1800 coins.
	GIVING UP      your own sign, pressed twice: half the price back. Your chest and furniture
	               must be empty first (nothing is ever destroyed by giving a house up).
	DOOR           the owner unlocks their door with their key (InteractionService asks Access).
	STORAGE        every chest and wardrobe in your house opens your personal storage: a 24-slot
	               inventory in YOUR session-locked save (data.housing.chest), so it can't be
	               duplicated across servers. Others can't open it.
	FURNITURE      furniture items (ItemDef.data.furniture) are placed from the inventory:
	               PlaceDecor(ref, x, z, r) with lot-local x/z (snapped to 0.5) and r in 15-degree
	               steps. Checks: you own the house, you're inside it, it's furniture, the spot is
	               inside the rooms, and the house budget (30 pieces, 120 parts, 3 lanterns). The
	               item moves out of your inventory into data.housing.decor (its whole record, so
	               picking it up gives back exactly the same item). Placed pieces get a "Pick up"
	               prompt (owner only). Pieces are built while their owner is on the server.
	HousingState   (server -> owner) what the client needs to place: lot frame, interior box,
	               floor height, budget use; {} when you own nothing.

	Admin (category World): house info|claim|release [player] (claim is free; release with
	force empties storage and furniture into nothing: testing only).
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local FurnitureModels = require(Shared.World.FurnitureModels)

local Server = ServerScriptService.Server
local Schemas = require(Server.Persistence.Schemas)
local Inventory = require(Server.Items.Inventory)

local PRICES: { [string]: number } = { house_small = 400, house_medium = 900, house_large = 1800 }
local MAX_DECOR = 30
local MAX_PARTS = 120
local MAX_LANTERNS = 3
local CHEST_SLOTS = 24
local CONFIRM_SECONDS = 6
local REFRESH_SECONDS = 90

local HousingService = {
	name = "HousingService",
	dependencies = { "NetService", "DataService", "PlayerDataService", "InventoryService", "WorldService", "SettlementService", "AdminService" },
}

local log: any = nil
local bus: any = nil
local flags: any = nil
local playerData: any = nil
local inventory: any = nil
local worldService: any = nil
local settlements: any = nil
local store: any = nil

local claims: { [string]: { u: number, t: number, n: string } } = {}
local pending: { [Player]: { lot: string, action: string, expires: number } } = {}

local function notify(player: Player, text: string)
	Net.fire("Notify", player, text)
end

local function storeKey(): string
	return worldService:scopedKey("housing")
end

local function housingOf(player: Player): any?
	local state = playerData:get(player)
	return state and state.data.housing
end

local function confirmed(player: Player, lot: string, action: string, warning: string): boolean
	local p = pending[player]
	local t = os.clock()
	if p and p.lot == lot and p.action == action and t <= p.expires then
		pending[player] = nil
		return true
	end
	pending[player] = { lot = lot, action = action, expires = t + CONFIRM_SECONDS }
	notify(player, warning)
	return false
end

-- ─── Geometry ───────────────────────────────────────────────────────────────

local function floorTop(model: Model): number?
	local cf = model:GetAttribute("InteriorCFrame")
	local size = model:GetAttribute("InteriorSize")
	if typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return nil
	end
	return cf.Position.Y - size.Y / 2 - 0.1
end

-- World pose of a decor entry (lot-local x/z on the floor, r in 15-degree steps).
local function decorPose(model: Model, x: number, z: number, r: number): CFrame?
	local lot = model:GetAttribute("LotCFrame")
	local y = floorTop(model)
	if typeof(lot) ~= "CFrame" or not y then
		return nil
	end
	local flat = lot * CFrame.new(x, 0, z) * CFrame.Angles(0, math.rad(r * 15), 0)
	return CFrame.new(flat.Position.X, y, flat.Position.Z) * flat.Rotation
end

-- Whether a footprint centred at `pose` stays inside the rooms (with its own half-size margin).
function HousingService.fits(model: Model, pose: CFrame, footprint: Vector3): boolean
	local cf = model:GetAttribute("InteriorCFrame")
	local size = model:GetAttribute("InteriorSize")
	if typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return false
	end
	local l = cf:PointToObjectSpace(pose.Position)
	local margin = math.max(footprint.X, footprint.Z) / 2
	return math.abs(l.X) <= size.X / 2 - margin and math.abs(l.Z) <= size.Z / 2 - margin and footprint.Y <= size.Y
end

local function inside(model: Model, p: Vector3): boolean
	local cf = model:GetAttribute("InteriorCFrame")
	local size = model:GetAttribute("InteriorSize")
	if typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return false
	end
	local l = cf:PointToObjectSpace(p)
	return math.abs(l.X) <= size.X / 2 + 0.5 and math.abs(l.Y) <= size.Y / 2 + 3 and math.abs(l.Z) <= size.Z / 2 + 0.5
end

-- ─── Budget ─────────────────────────────────────────────────────────────────

local function shapeOf(rec: any): string?
	local def = ItemDatabase.get(rec.i)
	local shape = def and def.data and def.data.furniture
	return if typeof(shape) == "string" and FurnitureModels.has(shape) then shape else nil
end

local function usage(decor: { any }): (number, number)
	local parts, lanterns = 0, 0
	for _, d in decor do
		local shape = shapeOf(d.rec)
		if shape then
			local info = FurnitureModels.info(shape)
			parts += info.parts
			if info.light then
				lanterns += 1
			end
		end
	end
	return parts, lanterns
end

-- ─── State to the owner ─────────────────────────────────────────────────────

local function pushState(player: Player)
	local h = housingOf(player)
	if not h or h.lot == "" then
		Net.fire("HousingState", player, {})
		return
	end
	local model = settlements:modelOf(h.lot)
	local parts = usage(h.decor)
	Net.fire("HousingState", player, {
		lot = h.lot,
		name = h.name,
		built = model ~= nil,
		lotCFrame = model and model:GetAttribute("LotCFrame"),
		interiorCFrame = model and model:GetAttribute("InteriorCFrame"),
		interiorSize = model and model:GetAttribute("InteriorSize"),
		floorY = model and floorTop(model),
		decor = #h.decor,
		decorMax = MAX_DECOR,
		parts = parts,
		partsMax = MAX_PARTS,
	})
end

-- ─── Signs and claims on built houses ───────────────────────────────────────

local function signOf(model: Model): BasePart?
	local sign = model:FindFirstChild("DeedSign")
	return if sign and sign:IsA("BasePart") then sign else nil
end

local function ensureSign(model: Model, lotId: string, text: string, action: string)
	local sign = signOf(model)
	if not sign then
		local entrance: Attachment? = nil
		for _, d in model:GetDescendants() do
			if d:IsA("Attachment") and CollectionService:HasTag(d, "BuildingEntrance") then
				entrance = d
				break
			end
		end
		local lot = model:GetAttribute("LotCFrame")
		if not entrance or typeof(lot) ~= "CFrame" then
			return
		end
		local at = CFrame.new(entrance.WorldPosition) * lot.Rotation * CFrame.new(3.5, -1.2, 0)
		local post = Instance.new("Part")
		post.Name = "DeedSign"
		post.Anchored = true
		post.CanTouch = false
		post.Size = Vector3.new(2.4, 1.6, 0.25)
		post.CFrame = at
		post.Material = Enum.Material.WoodPlanks
		post.Color = Color3.fromRGB(170, 130, 85)
		post:SetAttribute("Interactable", "deed")
		post:SetAttribute("InteractId", lotId .. ":deed1")
		post:SetAttribute("LotId", lotId)
		CollectionService:AddTag(post, "Interactable")
		post.Parent = model
		sign = post
	end
	local s = sign :: BasePart
	s:SetAttribute("SignText", text)
	s:SetAttribute("SignAction", action)
	local prompt = s:FindFirstChildOfClass("ProximityPrompt")
	if prompt then
		prompt.ObjectText, prompt.ActionText = text, action
	end
end

local function buildDecor(player: Player)
	local h = housingOf(player)
	if not h or h.lot == "" then
		return
	end
	local model = settlements:modelOf(h.lot)
	if not model then
		return
	end
	local name = "Decor_" .. player.UserId
	local old = model:FindFirstChild(name)
	if old then
		old:Destroy()
	end
	local folder = Instance.new("Model")
	folder.Name = name
	for i, d in h.decor do
		local shape = shapeOf(d.rec)
		local pose = decorPose(model, d.x, d.z, d.r)
		local def = ItemDatabase.get(d.rec.i)
		if shape and pose and def then
			local piece = FurnitureModels.build(shape, def.color)
			piece:PivotTo(pose)
			local primary = piece.PrimaryPart :: BasePart
			primary:SetAttribute("Interactable", "decor")
			primary:SetAttribute("InteractId", string.format("%s:decor%d_%d", h.lot, player.UserId, i))
			primary:SetAttribute("DecorIndex", i)
			primary:SetAttribute("DecorOwner", player.UserId)
			CollectionService:AddTag(primary, "Interactable")
			piece.Parent = folder
		end
	end
	folder.Parent = model
end

local function removeDecor(player: Player)
	local h = housingOf(player)
	local model = h and h.lot ~= "" and settlements:modelOf(h.lot)
	local folder = model and model:FindFirstChild("Decor_" .. player.UserId)
	if folder then
		folder:Destroy()
	end
end

-- Applies the claim state of one built house: owner attributes and the sign.
local function applyHouse(model: Model)
	if not CollectionService:HasTag(model, "House") then
		return
	end
	local lotId = model:GetAttribute("LotId")
	if typeof(lotId) ~= "string" then
		return
	end
	local claim = claims[lotId]
	if claim then
		model:SetAttribute("OwnerUserId", claim.u)
		model:SetAttribute("OwnerName", claim.n)
		ensureSign(model, lotId, "Home of " .. claim.n, "Owner")
		local owner = Players:GetPlayerByUserId(claim.u)
		if owner and not model:FindFirstChild("Decor_" .. claim.u) then
			buildDecor(owner)
		end
		return
	end
	model:SetAttribute("OwnerUserId", nil)
	model:SetAttribute("OwnerName", nil)
	if settlements:npcOwnerOf(lotId) or flags.get("housing_enabled") == false then
		local sign = signOf(model)
		if sign then
			sign:Destroy()
		end
		return
	end
	local price = PRICES[model:GetAttribute("BuildingType") :: string] or 900
	ensureSign(model, lotId, string.format("For sale · %d coins", price), "Buy")
end

local function applyAll()
	for _, model in CollectionService:GetTagged("House") do
		if model:IsA("Model") and model:IsDescendantOf(workspace) then
			applyHouse(model)
		end
	end
end

local function refreshClaims()
	local data = store:read(storeKey())
	if typeof(data) == "table" and typeof(data.claims) == "table" then
		claims = data.claims
		applyAll()
	end
end

-- ─── Buy / give up ──────────────────────────────────────────────────────────

local function freshChest(): any
	local chest: any = Inventory.new()
	chest.cap = CHEST_SLOTS
	return chest
end

local function claim(player: Player, model: Model, price: number): (boolean, string)
	local h = housingOf(player)
	local lotId = model:GetAttribute("LotId") :: string
	if not h then
		return false, "Your data is still loading."
	end
	if h.lot ~= "" then
		return false, "You already own a house."
	end
	if price > 0 and not inventory:addCurrency(player, -price, "buy house " .. lotId) then
		return false, string.format("You need %d coins.", price)
	end
	local userId, name = player.UserId, player.DisplayName
	local result, reason = store:update(storeKey(), function(data: any): any
		local existing = data.claims[lotId]
		if existing and existing.u ~= userId then
			return nil
		end
		for _, c in data.claims do
			if c.u == userId then
				return nil
			end
		end
		data.claims[lotId] = { u = userId, t = os.time(), n = name }
		return data
	end)
	if not result or (result.claims[lotId] and result.claims[lotId].u ~= userId) or not result.claims[lotId] then
		if price > 0 then
			inventory:addCurrency(player, price, "refund house " .. lotId)
		end
		if result then
			claims = result.claims
			applyAll()
		end
		log:info("house_claim_refused", { userId = userId, lot = lotId, reason = reason })
		return false, "Someone else has a claim on this house."
	end
	claims = result.claims
	h.lot = lotId
	h.settlement = (model:GetAttribute("SettlementId") :: string?) or ""
	h.name = model.Name
	h.since = os.time()
	h.decor = {}
	h.chest = freshChest()
	playerData:saveNow(player)
	applyHouse(model)
	pushState(player)
	bus:publish(Topics.HouseClaimed, { player = player, lotId = lotId, price = price })
	log:info("house_claimed", { userId = userId, lot = lotId, price = price })
	return true, "The house is yours. Your door opens to you, and every chest inside is your own storage."
end

local function chestEmpty(chest: any): boolean
	return next(chest.slots or {}) == nil and (chest.currency or 0) == 0
end

local function release(player: Player, force: boolean): (boolean, string)
	local h = housingOf(player)
	if not h or h.lot == "" then
		return false, "You don't own a house."
	end
	if not force and (#h.decor > 0 or not chestEmpty(h.chest)) then
		return false, "Pick up your furniture and empty your storage first."
	end
	local lotId, userId = h.lot, player.UserId
	local result = store:update(storeKey(), function(data: any): any
		local existing = data.claims[lotId]
		if not existing or existing.u ~= userId then
			return nil
		end
		data.claims[lotId] = nil
		return data
	end)
	removeDecor(player)
	local model = settlements:modelOf(lotId)
	local refund = math.floor((PRICES[model and model:GetAttribute("BuildingType") :: string or ""] or 0) / 2)
	h.lot, h.settlement, h.name, h.since, h.decor, h.chest = "", "", "", 0, {}, freshChest()
	if result then
		claims = result.claims
	else
		claims[lotId] = nil
	end
	if refund > 0 and not force then
		inventory:addCurrency(player, refund, "sold house " .. lotId)
	end
	playerData:saveNow(player)
	if model then
		applyHouse(model)
	end
	pushState(player)
	return true, if force then "House released." else string.format("You gave up the house and got %d coins back.", refund)
end

-- ─── Interactions (called by InteractionService) ────────────────────────────

function HousingService.deed(_self: any, player: Player, part: BasePart)
	if flags.get("housing_enabled") == false then
		return
	end
	local lotId = part:GetAttribute("LotId")
	local model = typeof(lotId) == "string" and settlements:modelOf(lotId) or nil
	if not model then
		return
	end
	local c = claims[lotId :: string]
	if c and c.u == player.UserId then
		if confirmed(player, lotId :: string, "release", "Give up your house? You get half the price back. Use the sign again to confirm.") then
			local _, message = release(player, false)
			notify(player, message)
		end
		return
	elseif c then
		notify(player, "This is " .. c.n .. "'s house.")
		return
	end
	if settlements:npcOwnerOf(lotId) then
		notify(player, "Someone lives here.")
		return
	end
	local price = PRICES[model:GetAttribute("BuildingType") :: string] or 900
	if confirmed(player, lotId :: string, "buy", string.format("Buy this house for %d coins? Use the sign again to confirm.", price)) then
		local _, message = claim(player, model, price)
		notify(player, message)
	end
end

function HousingService.pickUp(_self: any, player: Player, part: BasePart)
	local owner = part:GetAttribute("DecorOwner")
	local index = part:GetAttribute("DecorIndex")
	if owner ~= player.UserId or typeof(index) ~= "number" then
		notify(player, "That's not yours to move.")
		return
	end
	local h = housingOf(player)
	local entry = h and h.decor[index]
	if not h or not entry then
		return
	end
	local added = inventory:giveRecord(player, table.clone(entry.rec), "furniture picked up")
	if added < ItemInstance.count(entry.rec) then
		notify(player, "No room in your bags.")
		return
	end
	table.remove(h.decor, index)
	buildDecor(player)
	pushState(player)
end

-- Container backend for owned houses (ContainerService asks this before using settlement loot).
-- Returns ("player", inv) for the owner, ("denied", text) for anyone else, nil for unowned buildings.
function HousingService.containerFor(_self: any, part: BasePart, player: Player): (string?, any)
	local node: Instance? = part.Parent
	while node and not (node:IsA("Model") and CollectionService:HasTag(node, "Building")) do
		node = node.Parent
	end
	local model = node :: Model?
	local ownerId = model and model:GetAttribute("OwnerUserId")
	if typeof(ownerId) ~= "number" then
		return nil, nil
	end
	if ownerId ~= player.UserId then
		return "denied", "That belongs to " .. tostring(model and model:GetAttribute("OwnerName") or "someone") .. "."
	end
	local h = housingOf(player)
	if not h or h.lot ~= (model :: Model):GetAttribute("LotId") then
		return "denied", "That isn't yours any more."
	end
	local chest = Inventory.normalize(h.chest)
	chest.cap = CHEST_SLOTS
	h.chest = chest
	return "player", chest
end

-- ─── Placement (remote) ─────────────────────────────────────────────────────

local function place(player: Player, ref: string, x: number, z: number, r: number): { ok: boolean, reason: string? }
	if flags.get("housing_enabled") == false then
		return { ok = false, reason = "DISABLED" }
	end
	local h = housingOf(player)
	if not h or h.lot == "" then
		return { ok = false, reason = "NO_HOUSE" }
	end
	local model = settlements:modelOf(h.lot)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	if not model or not root or not inside(model, root.Position) then
		return { ok = false, reason = "NOT_HOME" }
	end
	local inv = inventory:inventoryOf(player)
	local rec = inv and Inventory.at(inv, ref)
	if not rec or string.sub(ref, 1, 1) ~= "s" then
		return { ok = false, reason = "EMPTY" }
	end
	local shape = shapeOf(rec)
	if not shape then
		return { ok = false, reason = "NOT_FURNITURE" }
	end
	if ItemInstance.hasFlag(rec, ItemInstance.LOCKED) then
		return { ok = false, reason = "LOCKED" }
	end
	if #h.decor >= MAX_DECOR then
		return { ok = false, reason = "DECOR_FULL" }
	end
	local info = FurnitureModels.info(shape)
	local parts, lanterns = usage(h.decor)
	if parts + info.parts > MAX_PARTS or (info.light and lanterns >= MAX_LANTERNS) then
		return { ok = false, reason = "DECOR_FULL" }
	end
	local sx, sz = math.floor(x * 2 + 0.5) / 2, math.floor(z * 2 + 0.5) / 2
	local sr = math.floor(r) % 24
	local pose = decorPose(model, sx, sz, sr)
	if not pose or not HousingService.fits(model, pose, info.footprint) then
		return { ok = false, reason = "OUTSIDE" }
	end
	local itemId = rec.i
	local taken: any = nil
	local ok, reason = inventory:transact(player, "decor_place", string.format("%s %s @%.1f,%.1f r%d", h.lot, itemId, sx, sz, sr), function(i)
		taken = Inventory.take(i, ref, 1)
		return taken ~= nil and taken.i == itemId, "EMPTY"
	end)
	if not ok then
		return { ok = false, reason = reason }
	end
	ItemInstance.setFlag(taken, ItemInstance.NEW, false)
	table.insert(h.decor, { rec = taken, x = sx, z = sz, r = sr })
	buildDecor(player)
	pushState(player)
	return { ok = true }
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "house", category = "World", description = "Housing: info, claim the nearest vacant house free (testing), or release yours (force empties storage)",
		args = {
			{ name = "action", type = "enum", options = { "info", "claim", "release", "forcerelease" } },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_, a)
			local player: Player = a.player
			local h = housingOf(player)
			if not h then
				return "not loaded"
			end
			if a.action == "info" then
				local counted = 0
				for _ in claims do
					counted += 1
				end
				if h.lot == "" then
					return string.format("%s owns no house. %d houses claimed in this world.", player.Name, counted)
				end
				local parts, lanterns = usage(h.decor)
				local chest = Inventory.normalize(h.chest)
				local items = 0
				for _ in chest.slots do
					items += 1
				end
				return string.format("%s owns %s (%s) since %s: %d/%d furniture, %d/%d parts, %d lanterns, %d stacks in storage. Built here: %s",
					player.Name, h.name, h.lot, os.date("%d %b", h.since), #h.decor, MAX_DECOR, parts, MAX_PARTS, lanterns, items, tostring(settlements:modelOf(h.lot) ~= nil))
			elseif a.action == "claim" then
				local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart") :: BasePart?
				if not root then
					return "no character"
				end
				local best, bestD = nil, math.huge
				for _, model in CollectionService:GetTagged("House") do
					local lotId = model:GetAttribute("LotId")
					if model:IsA("Model") and model.PrimaryPart and typeof(lotId) == "string" and not claims[lotId] and not settlements:npcOwnerOf(lotId) then
						local d = (model.PrimaryPart.Position - root.Position).Magnitude
						if d < bestD then
							best, bestD = model, d
						end
					end
				end
				if not best then
					return "no vacant, built house on this server (walk into a town first)"
				end
				local _, message = claim(player, best, 0)
				return best.Name .. ": " .. message
			end
			local _, message = release(player, a.action == "forcerelease")
			return message
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function HousingService.init(_self: any, ctx: any)
	log, bus, flags = ctx.log, ctx.bus, ctx.flags
	playerData = ctx.get("PlayerDataService")
	inventory = ctx.get("InventoryService")
	worldService = ctx.get("WorldService")
	settlements = ctx.get("SettlementService")
	store = ctx.get("DataService"):openStore(Schemas.Housing)
	Net.handle("PlaceDecor", place :: any)
	bus:subscribe(Topics.BuildingBuilt, function(payload: any)
		local model = settlements:modelOf(payload.lotId)
		if model then
			applyHouse(model)
			local c = claims[payload.lotId]
			local owner = c and Players:GetPlayerByUserId(c.u)
			if owner then
				pushState(owner)
			end
		end
	end)
	bus:subscribe(Topics.PlayerDataLoaded, function(payload: any)
		local player = payload.player
		buildDecor(player)
		pushState(player)
	end)
	bus:subscribe(Topics.PlayerDataReleased, function(payload: any)
		local player = payload.player
		if player then
			pending[player] = nil
			for _, model in CollectionService:GetTagged("House") do
				local folder = model:FindFirstChild("Decor_" .. payload.userId)
				if folder then
					folder:Destroy()
				end
			end
		end
	end)
	registerAdmin(ctx.get("AdminService"))
end

function HousingService.start(_self: any, _ctx: any)
	worldService:getSeed() -- the world record (and its generation, for the scoped key) is loaded
	local ok, err = pcall(refreshClaims)
	if not ok then
		log:warn("housing_claims_read_failed", { err = tostring(err) })
	end
	while true do
		task.wait(REFRESH_SECONDS)
		pcall(refreshClaims)
	end
end

return HousingService
