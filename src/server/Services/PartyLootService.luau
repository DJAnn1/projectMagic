--!strict
--[[
	PartyLootService: shares a drop across a party (docs/Social.md §3). CreatureService and QuestDirector
	call it; the rules are in Shared/Social/Data/PartyRewards and Social/LootRules.

		nearby(userId, position, radius?) -> { Player }   that player's party near a place, including them
		modeOf(userId) -> string                          the party's loot mode (free_for_all with no party)
		pool(userId, members, items, coins, source)       hands out one group drop by the party's mode

		PartyLoot(mode) -> { ok, reason? }                leader only
		LootRoll (to the members)   { id, item, n, expires } a roll opened, or { id, closed, winner, item }
		LootRollChoice(id, need | greed | pass)

	WHAT HAPPENS TO A ROLL  It's held in memory until everyone answers or rollSeconds pass. If the
	server closes first the drop is lost, the same as an unlooted corpse: nothing was yet in anyone's
	inventory, so nothing can be duplicated. If the winner has no room, the next person in the party
	who answered gets it.

	Admin: lootmode, lootroll.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Seed = require(Shared.Magic.Seed)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local PartyRewards = require(Shared.Social.Data.PartyRewards)

local LootRules = require(script.Parent.Parent.Social.LootRules)

type Roll = {
	id: string,
	item: string,
	n: number,
	members: { number },
	choices: { [number]: string },
	expires: number,
	source: string,
	partyId: string,
}

local PartyLootService = {
	name = "PartyLootService",
	dependencies = { "NetService", "PartyService", "InventoryService", "WorldService", "AdminService" },
}

local log: any = nil
local parties: any = nil
local inventory: any = nil
local worldService: any = nil

local modes: { [string]: string } = {} -- partyId -> mode
local turns: { [string]: number } = {} -- partyId -> whose turn next (round robin)
local rolls: { [string]: Roll } = {}
local rollCounter = 0

local function rootOf(player: Player): BasePart?
	local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function nameOf(item: string): string
	local def = ItemDatabase.get(item)
	return if def then def.name else item
end

function PartyLootService.modeOf(_self: any, userId: number): string
	local id = parties:partyIdOf(userId)
	return (id and modes[id]) or PartyRewards.default
end

function PartyLootService.nearby(_self: any, userId: number, position: Vector3, radius: number?): { Player }
	local out: { Player } = {}
	local reach = radius or PartyRewards.assistRadius
	local me = Players:GetPlayerByUserId(userId)
	if me then
		table.insert(out, me)
	end
	for _, mate in parties:matesOfUser(userId) do
		local root = rootOf(mate)
		if root and (root.Position - position).Magnitude <= reach then
			table.insert(out, mate)
		end
	end
	return out
end

-- Gives to the first person in `order` with room. Returns who got it.
local function giveToFirst(order: { Player }, item: string, n: number, source: string): Player?
	for _, player in order do
		if player.Parent then
			local added = inventory:give(player, item, n)
			if added > 0 then
				log:info("party_loot", { userId = player.UserId, item = item, n = added, source = source })
				return player
			end
		end
	end
	log:info("party_loot_no_room", { item = item, n = n, source = source })
	return nil
end

-- The members starting from the next turn, and advances the turn.
local function rotation(partyId: string, members: { Player }): { Player }
	local start = (turns[partyId] or 0) % #members + 1
	turns[partyId] = start
	local order: { Player } = {}
	for i = 0, #members - 1 do
		table.insert(order, members[(start - 1 + i) % #members + 1])
	end
	return order
end

local function closeRoll(roll: Roll)
	if not rolls[roll.id] then
		return
	end
	rolls[roll.id] = nil
	local entries: { LootRules.RollEntry } = {}
	for _, userId in roll.members do
		table.insert(entries, { userId = userId, choice = roll.choices[userId] })
	end
	rollCounter += 1
	local rng = Seed.random(worldService:getSeed(), "party:" .. roll.partyId, "need_greed", rollCounter)

	-- The winner first, then anyone else who wanted it, in case the winner's bags are full.
	local order: { Player } = {}
	local winnerId = LootRules.decideRoll(entries, rng)
	while winnerId do
		local player = Players:GetPlayerByUserId(winnerId)
		if player then
			table.insert(order, player)
		end
		local remaining: { LootRules.RollEntry } = {}
		for _, entry in entries do
			if entry.userId ~= winnerId then
				table.insert(remaining, entry)
			end
		end
		entries = remaining
		winnerId = LootRules.decideRoll(entries, rng)
	end
	local got = giveToFirst(order, roll.item, roll.n, roll.source)
	local text = if got
		then string.format("%s won %s.", got.DisplayName, nameOf(roll.item))
		else string.format("Nobody took %s.", nameOf(roll.item))
	for _, userId in roll.members do
		local player = Players:GetPlayerByUserId(userId)
		if player then
			Net.fire("LootRoll", player, { id = roll.id, closed = true })
			Net.fire("Notify", player, text)
		end
	end
end

local function openRoll(partyId: string, members: { Player }, item: string, n: number, source: string)
	rollCounter += 1
	local roll: Roll = {
		id = "roll" .. rollCounter,
		item = item,
		n = n,
		members = {},
		choices = {},
		expires = workspace:GetServerTimeNow() + PartyRewards.rollSeconds,
		source = source,
		partyId = partyId,
	}
	for _, player in members do
		table.insert(roll.members, player.UserId)
		Net.fire("LootRoll", player, { id = roll.id, item = item, n = n, expires = roll.expires })
	end
	rolls[roll.id] = roll
	task.delay(PartyRewards.rollSeconds, closeRoll, roll)
end

--[[
	One group drop, by the party's mode. `items` is { { item, n } }. Free for all isn't handled here:
	callers roll each member's loot separately for that mode.
]]
function PartyLootService.pool(self: any, userId: number, members: { Player }, items: { { item: string, n: number } }, coins: number, source: string)
	if #members == 0 then
		return
	end
	local partyId = parties:partyIdOf(userId) or ("solo:" .. userId)
	local mode = self:modeOf(userId)
	for _, entry in items do
		local def = ItemDatabase.get(entry.item)
		if mode == "need_greed" and def and def.stack <= 1 and #members > 1 then
			openRoll(partyId, members, entry.item, entry.n, source)
		else
			giveToFirst(rotation(partyId, members), entry.item, entry.n, source)
		end
	end
	if coins > 0 then
		for i, amount in LootRules.splitCoins(coins, #members) do
			if amount > 0 and members[i].Parent then
				inventory:addCurrency(members[i], amount, source)
			end
		end
	end
end

local function onSetMode(player: Player, mode: string): { [string]: any }
	local partyId = parties:partyIdOf(player.UserId)
	if not partyId then
		return { ok = false, reason = "NOT_IN_PARTY" }
	end
	if parties:leaderOf(player.UserId) ~= player.UserId then
		return { ok = false, reason = "NOT_LEADER" }
	end
	if not PartyRewards.modes[mode] then
		return { ok = false }
	end
	modes[partyId] = mode
	parties:setLootMode(partyId, mode)
	for _, mate in parties:matesOf(player) do
		Net.fire("Notify", mate, "Party loot is now: " .. PartyRewards.modes[mode].name .. ".")
	end
	return { ok = true }
end

function PartyLootService.init(_self: any, ctx: any)
	log = ctx.log
	parties = ctx.get("PartyService")
	inventory = ctx.get("InventoryService")
	worldService = ctx.get("WorldService")
	Net.handle("PartyLoot", onSetMode)
	Net.on("LootRollChoice", function(player: Player, id: string, choice: string)
		local roll = rolls[id]
		if not roll or not table.find(roll.members, player.UserId) or roll.choices[player.UserId] then
			return
		end
		roll.choices[player.UserId] = choice
		for _, userId in roll.members do
			if not roll.choices[userId] and Players:GetPlayerByUserId(userId) then
				return
			end
		end
		closeRoll(roll)
	end)
	local modeIds: { string } = {}
	for _, mode in PartyRewards.ordered do
		table.insert(modeIds, mode.id)
	end
	local admin = ctx.get("AdminService")
	admin:Register({
		name = "lootmode",
		category = "Social",
		description = "Set a player's party loot mode (skips the leader check)",
		args = {
			{ name = "mode", type = "enum", options = modeIds },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_ctx: any, a: any)
			local partyId = parties:partyIdOf(a.player.UserId)
			if not partyId then
				return a.player.Name .. " isn't in a party"
			end
			modes[partyId] = a.mode
			parties:setLootMode(partyId, a.mode)
			return "Loot mode: " .. a.mode
		end,
	})
	admin:Register({
		name = "lootroll",
		category = "Social",
		description = "Open a need-or-greed roll for an item in your party (testing)",
		args = { { name = "item", type = "string" } },
		handler = function(ctx: any, a: any)
			if not ItemDatabase.get(a.item) then
				return "No item called " .. a.item
			end
			local members = { ctx.player }
			for _, mate in parties:matesOf(ctx.player) do
				table.insert(members, mate)
			end
			openRoll(parties:partyIdOf(ctx.player.UserId) or "admin", members, a.item, 1, "admin")
			return "Roll open"
		end,
	})
end

return PartyLootService
