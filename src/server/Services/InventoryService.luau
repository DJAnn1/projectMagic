--!strict
--[[
	InventoryService: every player's items, equipment and derived stats (docs/Items.md).
	Server-authoritative: clients send intents (InventoryAction) naming places ("s12", "e:head",
	"q2"); every rule is checked here, every change runs as one Inventory.transact (all or
	nothing), is logged, and the owner gets the new view.

	FLOW
		PlayerDataLoaded  normalize the saved inventory (quarantine bad records, resolve aliases),
		                  give the starter kit once, derive stats, dress the character, push
		InventoryAction   move | equip | unequip | use | drop | sort | favorite | lock | quick | seen | mend
		recompute         layers (profile, mastery, gear, sets, buffs) -> StatCalc.derive -> StatCache
		                  -> MaxHealth, WalkSpeed, gear models; ReservoirService/CastService/Resistances
		                  read StatCache themselves
		1 Hz loop         health regeneration, buff expiry; every 10 s a full recompute (mastery moves)
		wear              hits worth >= 5% max health wear one armor piece; casting wears the held
		                  focus (1 point per 7 recipe power); at 0 an item is broken and gives nothing

	PUBLIC API (quests, loot, crafting, trade and admin call these; all atomic)
		give(player, itemId, count?, opts?) -> (added, leftover?, err?)    rolls variants (ItemGenerator)
		giveRecord(player, rec, reason) -> (added, leftover?)
		take(player, itemId, count, reason) -> boolean                      all or nothing
		count(player, itemId) -> number
		currency(player) / addCurrency(player, delta, reason) -> boolean / setCurrency
		clear(player, reason) / repairAll(player) / sheet(player) / inventoryOf(player)
		roll(itemId, sourceId, opts?) -> (Record?, err?)                   seeded, no uid yet
		transact(player, op, detail, fn(inv)) -> (ok, reason, ...)          any atomic change (crafting)
		transfer(player, other, op, detail, fn(inv, other)) -> (ok, reason, ...)
		                                                                    atomic across the player and
		                                                                    another inventory (containers,
		                                                                    later trades): both or neither
		ownerKey(player) -> string                                          uid prefix for minting
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local MagicCore = require(Shared.Magic.MagicCore)
local Reservoir = require(Shared.Magic.Reservoir)
local ItemTypes = require(Shared.Items.ItemTypes)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local StatCalc = require(Shared.Items.StatCalc)
local ItemRules = require(Shared.Items.Data.ItemRules)
local Repair = require(Shared.Items.Repair)

local ItemsFolder = ServerScriptService.Server.Items
local Inventory = require(ItemsFolder.Inventory)
local ItemGenerator = require(ItemsFolder.ItemGenerator)
local StatCache = require(ItemsFolder.StatCache)
local GearVisuals = require(ItemsFolder.GearVisuals)
local ItemUse = require(ItemsFolder.ItemUse)
local AdminCommands = require(ItemsFolder.AdminCommands)
local Resistances = require(ServerScriptService.Server.Magic.Cast.Resistances)

type Record = ItemTypes.Record
type Inv = Inventory.Inv

type PlayerInv = {
	inv: Inv,
	ownerKey: string,
	rev: number,
	pushQueued: boolean,
	cooldowns: { [string]: number }, -- use cooldown key -> server time ready
	log: { string }, -- recent operations (memory only)
	lastCaster: any,
	lastWalk: number?,
	wearIndex: number,
	focusWear: number, -- recipe power cast since the focus last lost a point
}

local ARMOR_SLOTS = { "chest", "head", "legs", "hands", "feet", "cloak" }
local BASE_WALK = 16
local RECOMPUTE_EVERY = 10

local InventoryService = {
	name = "InventoryService",
	dependencies = {
		"NetService",
		"PlayerDataService",
		"WorldService",
		"ReservoirService",
		"ProgressionService",
		"CastService",
		"AdminService",
	},
}

local log: any = nil
local bus: any = nil
local flags: any = nil
local playerData: any = nil
local worldService: any = nil
local reservoirs: any = nil
local progression: any = nil
local castService: any = nil
local states: { [Player]: PlayerInv } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function stateOf(player: Player): PlayerInv?
	return states[player]
end

local function casterOf(player: Player): any?
	local data = playerData:get(player)
	return data and data.caster
end

local function remember(s: PlayerInv, line: string)
	table.insert(s.log, string.format("%.0f %s", os.time(), line))
	while #s.log > ItemRules.inventory.memoryLog do
		table.remove(s.log, 1)
	end
end

-- ─── Views ──────────────────────────────────────────────────────────────────

local function viewOf(player: Player, s: PlayerInv): ItemTypes.InventoryView
	local caster = casterOf(player)
	local items: { ItemTypes.ItemView } = {}
	for _, entry in Inventory.each(s.inv) do
		local def = ItemDatabase.get(entry.rec.i)
		local ok = def ~= nil and ItemInstance.meets(def.requires, caster)
		local att: boolean? = nil
		if def and def.equip then
			local gated = ItemInstance.rolled(entry.rec).gated
			if #gated > 0 then
				att = false
				for _, g in gated do
					att = att or ItemInstance.meets(g.requires, caster)
				end
			end
		end
		table.insert(items, { ref = entry.ref, rec = entry.rec, ok = ok, att = att })
	end
	local cached = StatCache.get(player)
	local sheet = cached and cached.sheet
	return {
		rev = s.rev,
		currency = s.inv.currency,
		rare = s.inv.rare,
		capacity = Inventory.capacity(s.inv),
		weight = Inventory.weight(s.inv),
		carry = if sheet then sheet.carry else 60,
		load = if sheet then sheet.load else "light",
		items = items,
		quick = s.inv.quick,
		stats = if sheet then sheet.final else {},
		resist = if sheet then sheet.resist else {},
		focus = if cached then cached.focus.grade else "none",
		cooldowns = s.cooldowns,
	}
end

-- Coalesces every change in a frame into one push.
local function push(player: Player)
	local s = states[player]
	if not s or s.pushQueued then
		return
	end
	s.pushQueued = true
	task.defer(function()
		s.pushQueued = false
		if states[player] == s and player.Parent then
			s.rev += 1
			Net.fire("InventoryChanged", player, viewOf(player, s))
		end
	end)
end

-- ─── Stats ──────────────────────────────────────────────────────────────────

local function bestTier(caster: any): number
	local best = 0
	for branchId in (caster and caster.mastery or {}) :: { [string]: number } do
		best = math.max(best, MagicCore.masteryTier(caster, branchId))
	end
	return best
end

local function applyToCharacter(player: Player, s: PlayerInv)
	local cached = StatCache.get(player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not cached or not humanoid or humanoid.Health <= 0 then
		return
	end
	local f = cached.sheet.final

	-- Health: keep the current share when the maximum moves.
	local newMax = math.max(1, math.floor(f.health + 0.5))
	if humanoid.MaxHealth ~= newMax then
		local share = humanoid.Health / math.max(1, humanoid.MaxHealth)
		humanoid.MaxHealth = newMax
		humanoid.Health = math.clamp(newMax * share, 1, newMax)
	end

	-- Walk speed: StatusEffects owns WalkSpeed while a slow/haste is active (it multiplies the
	-- saved MagicBaseWalk), so write the base there instead. Only on change, so an admin's
	-- `walkspeed` sticks until gear or load changes.
	local walk = BASE_WALK * (1 + (f.moveSpeedPct or 0))
	if s.lastWalk ~= walk then
		s.lastWalk = walk
		if humanoid:GetAttribute("MagicBaseWalk") ~= nil then
			humanoid:SetAttribute("MagicBaseWalk", walk)
		else
			humanoid.WalkSpeed = walk
		end
	end

	-- Gear models: rebuild only slots whose item changed.
	local shown = GearVisuals.shown(character :: Model)
	for _, slot in ItemRules.equipSlots do
		local rec = s.inv.equip[slot.id]
		local want = if rec then rec.i else nil
		if (shown[slot.id] or nil) ~= want then
			GearVisuals.dress(character :: Model, slot.id, rec)
		end
	end
end

local function recompute(player: Player)
	local s = states[player]
	local data = playerData:get(player)
	if not s or not data then
		return
	end
	local caster = data.caster
	s.lastCaster = caster
	local layers: { ItemTypes.Layer } = {
		{ source = "profile", label = "Your attunement", stats = { reservoirMax = Reservoir.maxReservoir(caster) } },
		{ source = "mastery", label = "Mastery", stats = { health = bestTier(caster) * ItemRules.masteryHealthPerTier } },
	}
	local gear, focus = StatCalc.gearLayers(s.inv.equip, caster)
	for _, layer in gear do
		table.insert(layers, layer)
	end
	for _, buff in StatCache.buffs(player, now()) do
		table.insert(layers, { source = "buff", label = buff.name, stats = buff.stats, resist = buff.resist })
	end
	local sheet = StatCalc.derive(layers, Inventory.weight(s.inv))

	local flat, pct = 0, 0
	for _, line in sheet.lines do
		if line.source == "gear" or line.source == "set" or line.source == "buff" then
			if line.stat == "reservoirMax" then
				flat += line.value
			elseif line.stat == "reservoirMaxPct" then
				pct += line.value
			end
		end
	end
	StatCache.set(player, { sheet = sheet, focus = focus, reservoirFlat = flat, reservoirPct = pct })
	applyToCharacter(player, s)
	push(player)
end

-- ─── Operations ─────────────────────────────────────────────────────────────

local function rulesFor(player: Player): Inventory.Rules
	return {
		canEquip = function(rec: Record, _slot: string): (boolean, string?)
			local def = ItemDatabase.get(rec.i)
			local ok, why = ItemInstance.meets(def and def.requires, casterOf(player))
			return ok, if ok then nil else "REQUIREMENTS: " .. (why or "")
		end,
		onEquip = function(rec: Record)
			local def = ItemDatabase.get(rec.i)
			if def and def.bind == "equip" then
				rec.b = true
			end
			ItemInstance.setFlag(rec, ItemInstance.NEW, false)
		end,
	}
end

-- One logged, atomic change to a player's inventory. fn returns (ok, reason?, ...).
local function change(player: Player, op: string, detail: string, fn: (Inv) -> (boolean, string?, ...any)): (boolean, string?, ...any)
	local s = states[player]
	if not s then
		return false, "NOT_LOADED"
	end
	local results = table.pack(Inventory.transact(s.inv, fn))
	local ok, reason = results[1], results[2]
	remember(s, string.format("%s %s %s", op, detail, if ok then "ok" else tostring(reason)))
	if ok then
		Inventory.audit(s.inv, os.time(), op, detail)
		if flags.get("items_debug_log") then
			log:info("inv_op", { userId = player.UserId, op = op, detail = detail })
		end
		recompute(player)
	elseif reason == "ERROR" or (typeof(reason) == "string" and string.sub(reason, 1, 9) == "INVARIANT") then
		log:error("inv_op_failed", { userId = player.UserId, op = op, detail = detail, reason = reason, err = results[3] })
	end
	return table.unpack(results, 1, results.n)
end

-- The same, atomic across the player's inventory and another one (a container, a trade window).
local function changeWith(player: Player, other: Inv, op: string, detail: string, fn: (Inv, Inv) -> (boolean, string?, ...any)): (boolean, string?, ...any)
	local s = states[player]
	if not s then
		return false, "NOT_LOADED"
	end
	local results = table.pack(Inventory.transactMany({ s.inv, other }, fn :: any))
	local ok, reason = results[1], results[2]
	remember(s, string.format("%s %s %s", op, detail, if ok then "ok" else tostring(reason)))
	if ok then
		Inventory.audit(s.inv, os.time(), op, detail)
		if flags.get("items_debug_log") then
			log:info("inv_op", { userId = player.UserId, op = op, detail = detail })
		end
		recompute(player)
	elseif reason == "ERROR" or (typeof(reason) == "string" and string.sub(reason, 1, 9) == "INVARIANT") then
		log:error("inv_op_failed", { userId = player.UserId, op = op, detail = detail, reason = reason, err = results[3] })
	end
	return table.unpack(results, 1, results.n)
end

local function notify(player: Player, text: string)
	Net.fire("Notify", player, text)
end

local function breakCheck(player: Player, rec: Record)
	if ItemInstance.isBroken(rec) then
		notify(player, ItemInstance.displayName(rec) .. " broke. Repair it to use it again.")
	end
end

-- Wear: one point off an equipped item (outside a transaction: it can only lower a number).
local function wear(player: Player, rec: Record, amount: number)
	local max = ItemInstance.maxDurability(rec)
	if not max or ItemInstance.isBroken(rec) then
		return
	end
	rec.d = math.max(0, (ItemInstance.durability(rec) :: number) - amount)
	if rec.d == 0 then
		breakCheck(player, rec)
		recompute(player)
	else
		push(player)
	end
end

-- Resolves "q1".."q4" to the quickslot's current place; other refs pass through.
local function resolveRef(inv: Inv, ref: string): string?
	local q = string.match(ref, "^q(%d)$")
	if q then
		return Inventory.resolveQuick(inv, q)
	end
	return ref
end

local function useItem(player: Player, ref: string, aim: Vector3?): (boolean, string?)
	local s = states[player]
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not s then
		return false, "NOT_LOADED"
	end
	if not humanoid or humanoid.Health <= 0 then
		return false, "DEAD"
	end
	local place = resolveRef(s.inv, ref)
	local rec = place and Inventory.at(s.inv, place)
	local def = rec and ItemDatabase.get(rec.i)
	if not place or not rec or not def then
		return false, "EMPTY"
	end
	-- Quickslotted gear toggles: equip from the grid, unequip from the body.
	if not def.use then
		if not def.equip then
			return false, "NOT_USABLE"
		end
		if string.sub(place, 1, 2) == "e:" then
			return change(player, "unequip", place, function(inv)
				return Inventory.unequip(inv, string.sub(place, 3))
			end)
		end
		return change(player, "equip", place, function(inv)
			return Inventory.autoEquip(inv, place, rulesFor(player))
		end)
	end
	if string.sub(place, 1, 1) ~= "s" then
		return false, "NOT_USABLE"
	end
	local ok, why = ItemInstance.meets(def.requires, casterOf(player))
	if not ok then
		return false, "REQUIREMENTS: " .. (why or "")
	end
	local t = now()
	local key = def.use.group or def.id
	if (s.cooldowns[key] or 0) > t then
		return false, "COOLDOWN"
	end
	if def.use.needsAim and not aim then
		return false, "NEEDS_AIM"
	end
	local ctx: ItemUse.Context = {
		player = player,
		humanoid = humanoid,
		itemId = def.id,
		inv = s.inv,
		now = t,
		aim = aim,
		reservoirs = reservoirs,
		progression = progression,
		cast = castService,
	}
	local reason = ItemUse.check(ctx, def.use.effects)
	if reason then
		return false, reason
	end

	-- Take the item first (atomic), then apply; refund it if nothing happened. Two fast uses of
	-- a last potion can't both succeed: the second finds the slot empty.
	local consume = def.use.consume ~= false
	local taken: Record? = nil
	if consume then
		local took = change(player, "consume", place .. " " .. def.id, function(inv)
			taken = Inventory.take(inv, place, 1)
			return taken ~= nil, "EMPTY"
		end)
		if not took then
			return false, "EMPTY"
		end
	end
	local applied, failure = ItemUse.apply(ctx, def.use.effects)
	if not applied then
		if taken then
			change(player, "refund", def.id, function(inv)
				local added = Inventory.add(inv, taken :: Record, s.ownerKey)
				return added > 0, "NO_ROOM"
			end)
		end
		return false, failure or "NOTHING_TO_DO"
	end
	s.cooldowns[key] = t + (def.use.cooldown or 0)
	bus:publish(Topics.ItemUsed, { player = player, itemId = def.id })
	recompute(player) -- buffs, repairs
	return true, nil
end

-- ─── Remote ─────────────────────────────────────────────────────────────────

local function protectedFrom(rec: Record?, def: ItemTypes.ItemDef?): string?
	if not rec or not def then
		return "EMPTY"
	end
	if def.quest then
		return "QUEST_ITEM"
	end
	if ItemInstance.hasFlag(rec, ItemInstance.LOCKED) then
		return "LOCKED"
	end
	return nil
end

--[[
	Magic mending (docs/Items.md §11): Earth magic knits a metal, glass or stone item back
	together. Shared/Items/Repair.mendQuote says how much one mend restores (by the Earth root's
	tier, or Metallurgy's + 1) and what it costs in reservoir. The reservoir is checked and paid
	only if the durability change commits. Awards a little study XP to the branch that did it.
]]
local function mendItem(player: Player, s: PlayerInv, ref: string): (boolean, string?)
	local t = now()
	if (s.cooldowns.mend or 0) > t then
		return false, "COOLDOWN"
	end
	local caster = casterOf(player)
	local reservoir = reservoirs:get(player)
	if not caster or not reservoir then
		return false, "NOT_LOADED"
	end
	local M = ItemRules.mend
	local earthTier = MagicCore.masteryTier(caster, M.domainBranch)
	local metalTier = if MagicCore.isBranchUnlocked(caster, M.metallurgy) then MagicCore.masteryTier(caster, M.metallurgy) else 0
	local tier = Repair.mendTier(earthTier, metalTier)
	local rec = Inventory.at(s.inv, ref)
	if not rec then
		return false, "EMPTY"
	end
	local quote = Repair.mendQuote(rec, tier)
	if not quote then
		return false, if tier < M.minTier then "MEND_UNSKILLED" else "CANT_MEND"
	end
	if reservoir.current < quote.reservoir then
		return false, "INSUFFICIENT_RESERVOIR"
	end
	local ok, reason = change(player, "mend", ref, function(inv)
		local target = Inventory.at(inv, ref)
		if not target or target.i ~= (rec :: Record).i then
			return false, "EMPTY"
		end
		local max = ItemInstance.maxDurability(target) :: number
		local after = (ItemInstance.durability(target) :: number) + quote.points
		target.d = if after >= max then nil else after
		return true, nil
	end)
	if not ok then
		return false, reason
	end
	reservoir.current -= quote.reservoir
	reservoirs:push(player)
	s.cooldowns.mend = t + M.cooldown
	progression:awardQuest(player, if metalTier + M.metallurgyBonus >= earthTier and metalTier > 0 then M.metallurgy else M.domainBranch, math.max(1, math.floor(quote.points / 10)))
	return true, nil
end

local function onAction(player: Player, op: string, a: string?, b: string?, n: number?, aim: Vector3?): { ok: boolean, reason: string? }
	if flags.get("items_enabled") == false then
		return { ok = false, reason = "DISABLED" }
	end
	local s = states[player]
	if not s then
		return { ok = false, reason = "NOT_LOADED" }
	end
	local ok, reason
	if op == "move" then
		if not a or not b then
			return { ok = false, reason = "BAD_REF" }
		end
		ok, reason = change(player, "move", string.format("%s>%s x%s", a, b, tostring(n or "all")), function(inv)
			return Inventory.move(inv, a, b, n, rulesFor(player))
		end)
	elseif op == "equip" then
		if not a then
			return { ok = false, reason = "BAD_REF" }
		end
		ok, reason = change(player, "equip", a, function(inv)
			return Inventory.autoEquip(inv, a, rulesFor(player))
		end)
	elseif op == "unequip" then
		local slot = a and string.match(a, "^e:(.+)$")
		if not slot then
			return { ok = false, reason = "BAD_REF" }
		end
		ok, reason = change(player, "unequip", a :: string, function(inv)
			return Inventory.unequip(inv, slot)
		end)
	elseif op == "use" then
		if not a then
			return { ok = false, reason = "BAD_REF" }
		end
		ok, reason = useItem(player, a, aim)
	elseif op == "drop" then
		-- Until world pickups exist (loot stage), dropping destroys the item. The client asks first.
		if not a or string.sub(a, 1, 1) ~= "s" then
			return { ok = false, reason = "BAD_REF" }
		end
		local rec = Inventory.at(s.inv, a)
		local blocked = protectedFrom(rec, rec and ItemDatabase.get(rec.i))
		if blocked then
			return { ok = false, reason = blocked }
		end
		ok, reason = change(player, "drop", string.format("%s %s x%s", a, (rec :: Record).i, tostring(n or "all")), function(inv)
			return Inventory.take(inv, a, n) ~= nil, "EMPTY"
		end)
	elseif op == "sort" then
		ok, reason = change(player, "sort", "", function(inv)
			Inventory.sort(inv)
			return true, nil
		end)
	elseif op == "favorite" or op == "lock" then
		local flag = if op == "favorite" then ItemInstance.FAVORITE else ItemInstance.LOCKED
		if not a then
			return { ok = false, reason = "BAD_REF" }
		end
		ok, reason = change(player, op, a, function(inv)
			local rec = Inventory.at(inv, a)
			if not rec then
				return false, "EMPTY"
			end
			ItemInstance.setFlag(rec, flag, not ItemInstance.hasFlag(rec, flag))
			return true, nil
		end)
	elseif op == "quick" then
		if not a then
			return { ok = false, reason = "BAD_SLOT" }
		end
		ok, reason = change(player, "quick", string.format("%s=%s", a, tostring(b)), function(inv)
			return Inventory.setQuick(inv, a, b)
		end)
	elseif op == "mend" then
		if not a then
			return { ok = false, reason = "BAD_REF" }
		end
		ok, reason = mendItem(player, s, a)
	elseif op == "seen" then
		-- Clears NEW flags without a recompute (cosmetic).
		for _, entry in Inventory.each(s.inv) do
			if a == nil or entry.ref == a then
				ItemInstance.setFlag(entry.rec, ItemInstance.NEW, false)
			end
		end
		push(player)
		ok = true
	else
		ok, reason = false, "BAD_OP"
	end
	return { ok = ok == true, reason = if ok then nil else reason }
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

local function onLoaded(player: Player)
	local data = playerData:get(player)
	if not data or states[player] then
		return
	end
	local inv, report = Inventory.normalize(data.data.inventory)
	data.data.inventory = inv
	if report.quarantined > 0 then
		log:warn("inventory_quarantined", { userId = player.UserId, count = report.quarantined, duplicates = report.duplicates })
	end
	local s: PlayerInv = {
		inv = inv,
		ownerKey = Inventory.ownerKey(player.UserId),
		rev = 0,
		pushQueued = false,
		cooldowns = {},
		log = {},
		lastCaster = nil,
		lastWalk = nil,
		wearIndex = 0,
		focusWear = 0,
	}
	states[player] = s

	if not inv.starter then
		change(player, "starter", "kit", function(i)
			for _, entry in ItemRules.starterKit do
				local rec = ItemGenerator.roll(entry.id, ItemGenerator.rng(0, "starter:" .. entry.id), { count = entry.n, rarity = "common" })
				if rec then
					Inventory.add(i, rec, s.ownerKey)
				end
			end
			i.currency += ItemRules.starterCurrency
			i.starter = true
			return true, nil
		end)
	end
	recompute(player)
end

local function onCharacter(player: Player, character: Model)
	local s = states[player]
	if not s then
		return
	end
	s.lastWalk = nil
	local humanoid = character:WaitForChild("Humanoid", 10)
	if not humanoid or player.Character ~= character then
		return
	end
	-- Gear welds to the hand's grip attachment: wait for the hand (R6 "Right Arm", R15 "RightHand").
	character:WaitForChild(if (humanoid :: Humanoid).RigType == Enum.HumanoidRigType.R6 then "Right Arm" else "RightHand", 5)
	recompute(player)
end

local function onDamaged(payload: any)
	local humanoid: Humanoid? = payload.humanoid
	local character = humanoid and humanoid.Parent
	local player = character and Players:GetPlayerFromCharacter(character)
	local s = player and states[player]
	if not s or not humanoid or payload.amount < ItemRules.durability.armorHitShare * humanoid.MaxHealth then
		return
	end
	-- Rotate through worn armor so wear spreads evenly.
	for _ = 1, #ARMOR_SLOTS do
		s.wearIndex = s.wearIndex % #ARMOR_SLOTS + 1
		local rec = s.inv.equip[ARMOR_SLOTS[s.wearIndex]]
		if rec and ItemInstance.maxDurability(rec) and not ItemInstance.isBroken(rec) then
			wear(player :: Player, rec, 1)
			return
		end
	end
end

local function onSpellCast(payload: any)
	local player = Players:GetPlayerByUserId(payload.casterUserId or 0)
	local s = player and states[player]
	if not s then
		return
	end
	s.focusWear += payload.power or 0
	if s.focusWear < ItemRules.durability.focusPerCastPower then
		return
	end
	s.focusWear -= ItemRules.durability.focusPerCastPower
	for _, slot in { "offHand", "mainHand" } do
		local rec = s.inv.equip[slot]
		local def = rec and ItemDatabase.get(rec.i)
		if rec and def and def.focus and ItemInstance.maxDurability(rec) then
			wear(player :: Player, rec, 1)
			return
		end
	end
end

local function tick(elapsed: number)
	local t = now()
	for player, s in states do
		local _, expired = StatCache.buffs(player, t)
		local data = playerData:get(player)
		if expired or (data and data.caster ~= s.lastCaster) or elapsed % RECOMPUTE_EVERY == 0 then
			recompute(player)
		end
		local cached = StatCache.get(player)
		local regen = cached and cached.sheet.final.healthRegen or 0
		local character = player.Character
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if regen > 0 and humanoid and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + regen)
		end
	end
end

function InventoryService.init(_self: any, ctx: any)
	log, bus, flags = ctx.log, ctx.bus, ctx.flags
	playerData = ctx.get("PlayerDataService")
	worldService = ctx.get("WorldService")
	reservoirs = ctx.get("ReservoirService")
	progression = ctx.get("ProgressionService")
	castService = ctx.get("CastService")

	Resistances.setItemProvider(StatCache.resistFor)

	Net.handle("RequestInventory", function(player: Player)
		local s = states[player]
		return if s then viewOf(player, s) else nil
	end)
	Net.handle("RequestStatSheet", function(player: Player)
		local cached = StatCache.get(player)
		if not cached then
			return nil
		end
		local buffs = {}
		for _, buff in StatCache.buffs(player, now()) do
			table.insert(buffs, { id = buff.id, name = buff.name, expires = buff.expires })
		end
		local lines = cached.sheet.lines
		return {
			final = cached.sheet.final,
			resist = cached.sheet.resist,
			lines = if #lines > 300 then table.move(lines, 1, 300, 1, {}) else lines,
			weight = cached.sheet.weight,
			carry = cached.sheet.carry,
			load = cached.sheet.load,
			focus = cached.focus.grade,
			buffs = buffs,
		}
	end)
	Net.handle("InventoryAction", onAction :: any)

	bus:subscribe(Topics.PlayerDataLoaded, function(payload: any)
		onLoaded(payload.player)
	end)
	bus:subscribe(Topics.PlayerDataReleased, function(payload: any)
		local player = payload.player
		if player then
			states[player] = nil
			StatCache.clear(player)
		end
	end)
	bus:subscribe(Topics.TargetDamaged, onDamaged)
	bus:subscribe(Topics.SpellCast, onSpellCast)

	AdminCommands.register(ctx.get("AdminService"), InventoryService)
end

function InventoryService.start(_self: any, _ctx: any)
	local function watch(player: Player)
		player.CharacterAdded:Connect(function(character)
			onCharacter(player, character)
		end)
	end
	Players.PlayerAdded:Connect(watch)
	for _, player in Players:GetPlayers() do
		watch(player)
		if playerData:get(player) then
			task.spawn(onLoaded, player)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
		StatCache.clear(player)
	end)
	local elapsed = 0
	while true do
		task.wait(1)
		elapsed += 1
		tick(elapsed)
	end
end

-- ─── Public API ─────────────────────────────────────────────────────────────

-- A seeded variant (no uid: it gets one when it enters an inventory).
function InventoryService.roll(_self: any, itemId: string, sourceId: string, opts: ItemGenerator.RollOptions?): (Record?, string?)
	return ItemGenerator.roll(itemId, ItemGenerator.rng(worldService:getSeed(), sourceId), opts)
end

-- Gives `count` of an item: stackables as stacks, others as separately rolled variants (each
-- seeded by the uid it's about to get). Returns (added, leftoverCount, err).
function InventoryService.give(self: any, player: Player, itemId: string, count: number?, opts: ItemGenerator.RollOptions?): (number, number, string?)
	local s = states[player]
	local def = ItemDatabase.get(itemId)
	if not s then
		return 0, count or 1, "NOT_LOADED"
	end
	if not def then
		return 0, count or 1, "unknown item " .. itemId
	end
	local want = math.max(1, math.floor(count or 1))
	local seed = worldService:getSeed()
	local added = 0
	local err: string? = nil
	local ok, reason = change(player, "give", string.format("%s x%d", def.id, want), function(inv)
		if def.stack > 1 then
			local o = table.clone(opts or {})
			o.count = math.min(want, def.stack * Inventory.capacity(inv))
			local rec, rollErr = ItemGenerator.roll(def.id, ItemGenerator.rng(seed, "give"), o)
			if not rec then
				return false, rollErr
			end
			rec.n = if o.count > 1 then o.count else nil
			added = Inventory.add(inv, rec, s.ownerKey)
		else
			for _ = 1, want do
				local uid = Inventory.mintUid(inv, s.ownerKey)
				local rec, rollErr = ItemGenerator.roll(def.id, ItemGenerator.rng(seed, uid), opts)
				if not rec then
					err = rollErr
					break
				end
				rec.u, rec.t = uid, os.time()
				if def.bind == "pickup" then
					rec.b = true
				end
				local n = Inventory.add(inv, rec, s.ownerKey)
				if n == 0 then
					break
				end
				added += n
			end
		end
		return added > 0, err or "NO_ROOM"
	end)
	if not ok then
		return 0, want, reason
	end
	bus:publish(Topics.ItemsGained, { player = player, itemId = def.id, count = added })
	return added, want - added, err
end

-- Adds an existing record (trades, refunds, loot rolled elsewhere). Returns (added, leftover?).
function InventoryService.giveRecord(_self: any, player: Player, rec: Record, reason: string): (number, Record?)
	local s = states[player]
	if not s then
		return 0, rec
	end
	local added: number, leftover: Record? = 0, rec
	change(player, "giveRecord", string.format("%s x%d (%s)", rec.i, ItemInstance.count(rec), reason), function(inv)
		added, leftover = Inventory.add(inv, rec, s.ownerKey)
		return added > 0, "NO_ROOM"
	end)
	if added > 0 then
		bus:publish(Topics.ItemsGained, { player = player, itemId = rec.i, count = added })
	end
	return added, leftover
end

function InventoryService.take(_self: any, player: Player, itemId: string, count: number, reason: string): boolean
	return (change(player, "take", string.format("%s x%d (%s)", itemId, count, reason), function(inv)
		return Inventory.removeItem(inv, itemId, count), "NOT_ENOUGH"
	end))
end

function InventoryService.count(_self: any, player: Player, itemId: string): number
	local s = states[player]
	return if s then Inventory.countOf(s.inv, itemId) else 0
end

function InventoryService.currency(_self: any, player: Player): number
	local s = states[player]
	return if s then s.inv.currency else 0
end

-- Adds (or with a negative delta, spends) coins. Never goes below zero: returns false instead.
function InventoryService.addCurrency(_self: any, player: Player, delta: number, reason: string): boolean
	return (change(player, "currency", string.format("%+d (%s)", delta, reason), function(inv)
		local after = inv.currency + math.floor(delta)
		if after < 0 then
			return false, "NOT_ENOUGH"
		end
		inv.currency = math.min(after, ItemRules.inventory.maxCurrency)
		return true, nil
	end))
end

function InventoryService.setCurrency(_self: any, player: Player, amount: number, rare: number?, reason: string): boolean
	return (change(player, "setcurrency", string.format("%d/%s (%s)", amount, tostring(rare), reason), function(inv)
		inv.currency = math.clamp(math.floor(amount), 0, ItemRules.inventory.maxCurrency)
		if rare then
			inv.rare = math.clamp(math.floor(rare), 0, ItemRules.inventory.maxRare)
		end
		return true, nil
	end))
end

-- Empties the grid (and with `equipment`, the body). Quest items stay unless `everything`.
function InventoryService.clear(_self: any, player: Player, equipment: boolean, reason: string): (boolean, number)
	local removed = 0
	local ok = change(player, "clear", reason, function(inv)
		for key, rec in inv.slots do
			local def = ItemDatabase.get(rec.i)
			if not (def and def.quest) then
				inv.slots[key] = nil
				removed += 1
			end
		end
		if equipment then
			for slot in inv.equip do
				inv.equip[slot] = nil
				removed += 1
			end
		end
		table.clear(inv.quick)
		return true, nil
	end)
	return ok, removed
end

function InventoryService.repairAll(_self: any, player: Player): number
	local repaired = 0
	change(player, "repairall", "", function(inv)
		for _, entry in Inventory.each(inv) do
			if entry.rec.d ~= nil then
				entry.rec.d = nil
				repaired += 1
			end
		end
		return true, nil
	end)
	return repaired
end

-- Mutates one record in place inside a transaction (admin tools: durability, rarity edits).
function InventoryService.edit(_self: any, player: Player, ref: string, label: string, fn: (Record) -> (boolean, string?)): (boolean, string?)
	return change(player, "edit", ref .. " " .. label, function(inv)
		local rec = Inventory.at(inv, ref)
		if not rec then
			return false, "EMPTY"
		end
		return fn(rec)
	end)
end

function InventoryService.sheet(_self: any, player: Player): ItemTypes.Sheet?
	local cached = StatCache.get(player)
	return cached and cached.sheet
end

function InventoryService.inventoryOf(_self: any, player: Player): Inv?
	local s = states[player]
	return s and s.inv
end

function InventoryService.recentLog(_self: any, player: Player): { string }
	local s = states[player]
	return if s then s.log else {}
end

function InventoryService.wear(_self: any, player: Player, slot: string, amount: number): boolean
	local s = states[player]
	local rec = s and s.inv.equip[slot]
	if not rec or not ItemInstance.maxDurability(rec) then
		return false
	end
	wear(player, rec, amount)
	return true
end

function InventoryService.recompute(_self: any, player: Player)
	recompute(player)
end

-- Any atomic, logged change to a player's inventory (recipes, rewards with conditions).
function InventoryService.transact(_self: any, player: Player, op: string, detail: string, fn: (Inv) -> (boolean, string?, ...any)): (boolean, string?, ...any)
	return change(player, op, detail, fn)
end

-- Atomic across the player's inventory and `other` (a container): both change or neither does.
function InventoryService.transfer(_self: any, player: Player, other: Inv, op: string, detail: string, fn: (Inv, Inv) -> (boolean, string?, ...any)): (boolean, string?, ...any)
	return changeWith(player, other, op, detail, fn)
end

function InventoryService.ownerKey(_self: any, player: Player): string
	local s = states[player]
	return if s then s.ownerKey else Inventory.ownerKey(player.UserId)
end

return InventoryService
