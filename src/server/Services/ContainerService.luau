--!strict
--[[
	ContainerService: storage you can open: chests, barrels, crates (docs/Buildings.md §3.2). The
	container interface for the inventory system: a container is an Inventory.Inv with a fixed
	capacity, and every move between it and a player is ONE Inventory.transactMany (both change
	or neither does; a uid can never be in both).

	STATE (per server, created the first time someone opens it)
		contents   seeded from ContainerLoot (world seed + InteractId + restock round)
		restock    after RESTOCK_DAYS game days the round advances and fresh loot fills free slots
		deposits   what each player put in: taking your own things back is never theft
		viewers    players with it open; every change is pushed to all of them
	Settlement containers are regenerated on every server (they're NPC property, not saved).
	In a player's house (HousingService:containerFor) every container opens the owner's personal
	storage instead: an inventory inside the owner's session-locked save, so it can't be
	duplicated across servers; anyone else is refused.

	REMOTES
		ContainerView (server -> client)   the open container: { id, name, owner, theft, capacity,
		                                   coins, items = { ItemView } } or { id, closed = true }
		ContainerAction(op, id, ref?, n?)  op: take | put | takeall | coins | close -> { ok, reason? }
		    take   container "sK" -> your inventory     put   your "sK" -> the container
	Every action re-checks that the player is alive, beside the container (its prompt distance +
	6 studs) and has it open. Taking what you didn't put there from a building you aren't allowed
	to use is theft (Interact/Access): Topics.CrimeCommitted with the item value's severity.

	API (InteractionService, admin): open(player, part) · peek(part) -> Inv · reset(part) · count()
]]

local Players = game:GetService("Players")
local HttpService = game:GetService("HttpService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local ItemTypes = require(Shared.Items.ItemTypes)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local Interactables = require(Shared.World.Interactables)

local Server = ServerScriptService.Server
local Inventory = require(Server.Items.Inventory)
local ItemGenerator = require(Server.Items.ItemGenerator)
local Access = require(Server.Interact.Access)
local ContainerLoot = require(Server.Interact.ContainerLoot)
local WorldClock = require(Server.NPC.WorldClock)

type Record = ItemTypes.Record

type Container = {
	id: string,
	kind: string,
	part: BasePart,
	inv: Inventory.Inv,
	ownerKey: string, -- uid prefix for items minted into this container
	round: number, -- restock round its loot was last rolled for
	rolledDay: number,
	deposits: { [number]: { [string]: number } }, -- userId -> itemId -> count put in
	viewers: { [Player]: boolean },
	personal: boolean?, -- the owner's housing storage (no loot, no restock, no theft)
}

local RESTOCK_DAYS = 3
local REACH_SLACK = 6

local ContainerService = {
	name = "ContainerService",
	dependencies = { "NetService", "InventoryService", "WorldService", "HousingService" },
}

local bus: any = nil
local inventory: any = nil
local worldService: any = nil
local housing: any = nil
local containers: { [string]: Container } = {}
local openBy: { [Player]: string } = {}
local serial = 0
local serverKey = "c" .. Inventory.base36(Seed.derive(0, game.JobId ~= "" and game.JobId or HttpService:GenerateGUID(false), "containers") % 1679616)

-- ─── State ──────────────────────────────────────────────────────────────────

local function defOf(part: BasePart): Interactables.Def?
	local kind = part:GetAttribute("Interactable")
	local def = typeof(kind) == "string" and Interactables[kind] or nil
	return if def and def.container then def else nil
end

-- Fills free slots with this round's seeded loot (never removes anything already there).
local function stock(c: Container, round: number)
	local def = defOf(c.part) :: Interactables.Def
	local seed = worldService:getSeed()
	local items, coins = ContainerLoot.roll(seed, c.id, (def.container :: any).loot, round)
	for i, entry in items do
		local rec = ItemGenerator.roll(entry.id, ItemGenerator.rng(seed, c.id .. ":" .. round, i), { count = entry.n })
		if rec then
			Inventory.add(c.inv, rec, c.ownerKey)
		end
	end
	c.inv.currency = math.min(c.inv.currency + coins, 100000)
	-- Loot isn't "new" to anyone: clear the NEW flag Inventory.add sets.
	for _, rec in c.inv.slots do
		ItemInstance.setFlag(rec, ItemInstance.NEW, false)
	end
	c.round = round
	c.rolledDay = WorldClock.day()
end

local function containerFor(part: BasePart): Container?
	local def = defOf(part)
	local id = part:GetAttribute("InteractId")
	if not def or typeof(id) ~= "string" then
		return nil
	end
	local c = containers[id]
	if c then
		c.part = part -- a rebuilt building keeps its container state
		return c
	end
	serial += 1
	local inv = Inventory.new()
	inv.cap = (def.container :: any).slots
	local created: Container = {
		id = id,
		kind = part:GetAttribute("Interactable") :: string,
		part = part,
		inv = inv,
		ownerKey = serverKey .. Inventory.base36(serial),
		round = 0,
		rolledDay = WorldClock.day(),
		deposits = {},
		viewers = {},
	}
	containers[id] = created
	stock(created, 1)
	return created
end

local function maybeRestock(c: Container)
	if c.personal or next(c.viewers) ~= nil then
		return
	end
	local days = WorldClock.day() - c.rolledDay
	if days >= RESTOCK_DAYS then
		stock(c, c.round + 1)
	end
end

-- ─── Views ──────────────────────────────────────────────────────────────────

local function viewFor(c: Container, player: Player): { [string]: any }
	local building = Access.buildingOf(c.part)
	local def = defOf(c.part) :: Interactables.Def
	local items: { ItemTypes.ItemView } = {}
	for _, entry in Inventory.each(c.inv) do
		table.insert(items, { ref = entry.ref, rec = entry.rec, ok = true })
	end
	local kind, ownerId = Access.ownerOf(building)
	return {
		id = c.id,
		name = if c.personal then "Your storage" else def.object .. (if building then " · " .. Access.describe(building) else ""),
		owner = if kind == "player" then (if ownerId == player.UserId then "yours" else "another adventurer's") elseif kind == "npc" then "a local household's" else nil,
		theft = not c.personal and not Access.permits(player, building),
		capacity = Inventory.capacity(c.inv),
		coins = c.inv.currency,
		items = items,
	}
end

local function push(c: Container)
	for player in c.viewers do
		if player.Parent then
			Net.fire("ContainerView", player, viewFor(c, player))
		else
			c.viewers[player] = nil
		end
	end
end

local function close(player: Player)
	local id = openBy[player]
	openBy[player] = nil
	local c = id and containers[id]
	if c then
		c.viewers[player] = nil
		Net.fire("ContainerView", player, { id = c.id, closed = true })
	end
end

-- ─── Rules ──────────────────────────────────────────────────────────────────

local function inReach(player: Player, part: BasePart): boolean
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local def = defOf(part)
	if not root or not humanoid or humanoid.Health <= 0 or not def or not part:IsDescendantOf(workspace) then
		return false
	end
	return (root.Position - part.Position).Magnitude <= def.distance + REACH_SLACK
end

-- Severity of taking `rec` (count n) from c, after the player's own deposits are used up.
local function theftOf(player: Player, c: Container, itemId: string, n: number, value: number): number
	if c.personal or Access.permits(player, Access.buildingOf(c.part)) then
		return 0
	end
	local mine = c.deposits[player.UserId]
	local own = mine and mine[itemId] or 0
	local stolen = math.max(0, n - own)
	if mine and own > 0 then
		mine[itemId] = math.max(0, own - n)
	end
	if stolen <= 0 then
		return 0
	end
	return Access.theftSeverity(value * stolen / math.max(1, n))
end

local function reportTheft(player: Player, c: Container, severity: number, what: string)
	if severity <= 0 then
		return
	end
	local building = Access.buildingOf(c.part)
	bus:publish(Topics.CrimeCommitted, {
		player = player,
		settlementId = Access.settlementOf(building),
		severity = severity,
		reason = "stealing " .. what .. " from " .. Access.describe(building),
	})
end

-- Moves one stack from the container to the player (all or nothing).
local function takeOne(player: Player, c: Container, ref: string, n: number?): (boolean, string?)
	local rec = Inventory.at(c.inv, ref)
	if not rec then
		return false, "EMPTY"
	end
	local itemId = rec.i
	local moved = 0
	local value = 0
	local ok, reason = inventory:transfer(player, c.inv, "take", string.format("%s %s x%s", c.id, itemId, tostring(n or "all")), function(pInv, cInv)
		local part = Inventory.take(cInv, ref, n)
		if not part then
			return false, "EMPTY"
		end
		moved = ItemInstance.count(part)
		value = ItemInstance.value(part)
		local added = Inventory.add(pInv, part, inventory:ownerKey(player))
		return added == moved, "NO_ROOM"
	end)
	if ok then
		local def = ItemDatabase.get(itemId)
		reportTheft(player, c, theftOf(player, c, itemId, moved, value), if def then def.name else itemId)
	end
	return ok, reason
end

local function onAction(player: Player, op: string, id: string, ref: string?, n: number?): { ok: boolean, reason: string? }
	local c = containers[id]
	if op == "close" then
		close(player)
		return { ok = true }
	end
	if not c or openBy[player] ~= id or not c.viewers[player] then
		return { ok = false, reason = "NOT_OPEN" }
	end
	if not inReach(player, c.part) then
		close(player)
		return { ok = false, reason = "TOO_FAR" }
	end
	local ok, reason = false, nil
	if op == "take" then
		if not ref then
			return { ok = false, reason = "BAD_REF" }
		end
		ok, reason = takeOne(player, c, ref, n)
	elseif op == "takeall" then
		ok = true
		for _, entry in Inventory.each(c.inv) do
			local took, why = takeOne(player, c, entry.ref, nil)
			if not took then
				ok, reason = false, why
				break
			end
		end
	elseif op == "coins" then
		local amount = c.inv.currency
		if amount <= 0 then
			return { ok = false, reason = "EMPTY" }
		end
		ok, reason = inventory:transfer(player, c.inv, "takecoins", string.format("%s %d", c.id, amount), function(pInv: Inventory.Inv, cInv: Inventory.Inv)
			pInv.currency += cInv.currency
			cInv.currency = 0
			return true, nil
		end)
		if ok then
			reportTheft(player, c, theftOf(player, c, "coins", amount, amount), amount .. " coins")
		end
	elseif op == "put" then
		local pInv = inventory:inventoryOf(player)
		local rec = pInv and ref and Inventory.at(pInv, ref)
		local def = rec and ItemDatabase.get(rec.i)
		if not rec or not def or string.sub(ref :: string, 1, 1) ~= "s" then
			return { ok = false, reason = "EMPTY" }
		end
		if def.quest then
			return { ok = false, reason = "QUEST_ITEM" }
		end
		if ItemInstance.hasFlag(rec, ItemInstance.LOCKED) then
			return { ok = false, reason = "LOCKED" }
		end
		local itemId, moved = rec.i, 0
		ok, reason = inventory:transfer(player, c.inv, "put", string.format("%s %s x%s", c.id, itemId, tostring(n or "all")), function(pi, ci)
			local part = Inventory.take(pi, ref :: string, n)
			if not part then
				return false, "EMPTY"
			end
			moved = ItemInstance.count(part)
			local added = Inventory.add(ci, part, c.ownerKey)
			return added == moved, "CONTAINER_FULL"
		end)
		if ok then
			local mine = c.deposits[player.UserId] or {}
			c.deposits[player.UserId] = mine
			mine[itemId] = (mine[itemId] or 0) + moved
			for _, r in c.inv.slots do
				ItemInstance.setFlag(r, ItemInstance.NEW, false)
			end
		end
	else
		return { ok = false, reason = "BAD_OP" }
	end
	push(c)
	return { ok = ok == true, reason = if ok then nil else reason }
end

-- ─── API ────────────────────────────────────────────────────────────────────

-- Opens a container for a player (from its prompt). One container open per player.
function ContainerService.open(_self: any, player: Player, part: BasePart): (boolean, string?)
	if not inReach(player, part) then
		return false, "TOO_FAR"
	end
	local c: Container? = nil
	local backend, value = housing:containerFor(part, player)
	if backend == "denied" then
		return false, value
	elseif backend == "player" then
		-- The owner's personal storage: one container per owner, whichever chest they open.
		local id = "home@" .. player.UserId
		local existing = containers[id]
		if existing then
			existing.inv, existing.part = value, part
		else
			serial += 1
			existing = {
				id = id, kind = part:GetAttribute("Interactable") :: string, part = part, inv = value,
				ownerKey = serverKey .. Inventory.base36(serial), round = 0, rolledDay = math.huge,
				deposits = {}, viewers = {}, personal = true,
			}
			containers[id] = existing
		end
		c = existing
	else
		c = containerFor(part)
	end
	if not c then
		return false, "NOT_A_CONTAINER"
	end
	if openBy[player] and openBy[player] ~= (c :: Container).id then
		close(player)
	end
	local opened = c :: Container
	maybeRestock(opened)
	openBy[player] = opened.id
	opened.viewers[player] = true
	Net.fire("ContainerView", player, viewFor(opened, player))
	return true, nil
end

-- The container's contents (rolled if nobody opened it yet). Admin and the building check.
function ContainerService.peek(_self: any, part: BasePart): Inventory.Inv?
	local c = containerFor(part)
	return c and c.inv
end

-- Forgets a container's state (admin): its next open rolls round 1 again.
function ContainerService.reset(_self: any, part: BasePart): boolean
	local id = part:GetAttribute("InteractId")
	local c = typeof(id) == "string" and containers[id] or nil
	if not c then
		return false
	end
	for player in c.viewers do
		close(player)
	end
	containers[id :: string] = nil
	return true
end

function ContainerService.count(_self: any): number
	local n = 0
	for _ in containers do
		n += 1
	end
	return n
end

function ContainerService.init(_self: any, ctx: any)
	bus = ctx.bus
	inventory = ctx.get("InventoryService")
	worldService = ctx.get("WorldService")
	housing = ctx.get("HousingService")
	Net.handle("ContainerAction", onAction :: any)
end

function ContainerService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		local id = openBy[player]
		openBy[player] = nil
		local c = id and containers[id]
		if c then
			c.viewers[player] = nil
		end
	end)
	-- Walking away closes the window.
	while true do
		task.wait(1)
		for player, id in openBy do
			local c = containers[id]
			if not c or not inReach(player, c.part) then
				close(player)
			end
		end
	end
end

return ContainerService
