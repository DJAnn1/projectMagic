--!strict
--[[
	PartyService: live parties of 2-5 players on this server (docs/Social.md §3). The rules are in
	Social/PartyModel; this file connects them to players, remotes and PvpRules.

		PartyAction(op, userId?) -> { ok, reason? }   invite | accept | decline | leave | kick | promote
		PartyState (to you, on change)   { id?, leader?, members = { { u, name, user } }, invites = { { from, name, user, expires } } }
		PartyVitals (to your party, 2 Hz, only on change)  { { u, h, m, r, rm, x, z } }  health, reservoir, position

	Public (QuestDirector, ComboService, EmoteService)
		partyIdOf(userId) -> string?
		matesOf(player) -> { Player }     online members, not including `player`
		matesOfUser(userId) -> { Player }
		sameParty(a, b) -> boolean

	Parties live and die with the server: nothing here is saved, and a player who leaves the server
	leaves their party. Reservoir values go to party members only, and only while they're in the party.

	Budget: one loop at 2 Hz. Each party costs one signature string, and one small unreliable send per
	member only when a value moved. A full server with 12 parties of 5 sends at most 120 messages/s,
	and far fewer in practice, because positions are rounded to 16 studs and health only moves in fights.

	Admin: parties, testparty, partyleave.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)

local Server = script.Parent.Parent
local PartyModel = require(Server.Social.PartyModel)
local PvpRules = require(Server.Magic.Cast.PvpRules)

local VITALS_HZ = 2
local EXPIRE_EVERY = 5 -- seconds between invite expiry sweeps

local PartyService = {
	name = "PartyService",
	dependencies = { "NetService", "PlayerDataService", "ReservoirService", "SocialSafetyService", "AdminService" },
}

local log: any = nil
local bus: any = nil
local flags: any = nil
local reservoirs: any = nil
local safety: any = nil
local book = PartyModel.new()
local vitalSignature: { [string]: string } = {}
local lootModes: { [string]: string } = {} -- partyId -> mode, shown to members (PartyLootService owns the choice)

local function now(): number
	return workspace:GetServerTimeNow()
end

local function playerOf(userId: number): Player?
	return Players:GetPlayerByUserId(userId)
end

local function nameOf(userId: number): (string, string)
	local player = playerOf(userId)
	if player then
		return player.DisplayName, player.Name
	end
	return "Someone", "?"
end

local function notify(userId: number, text: string)
	local player = playerOf(userId)
	if player then
		Net.fire("Notify", player, text)
	end
end

-- ─── Views ──────────────────────────────────────────────────────────────────

local function push(userId: number)
	local player = playerOf(userId)
	if not player then
		return
	end
	local view: { [string]: any } = { members = {}, invites = {} }
	local party = PartyModel.partyOf(book, userId)
	if party then
		view.id = party.id
		view.leader = party.leader
		view.lootMode = lootModes[party.id]
		for _, id in party.members do
			local display, user = nameOf(id)
			table.insert(view.members, { u = id, name = display, user = user })
		end
	end
	for from, invite in (book.invites[userId] or {}) :: { [number]: PartyModel.Invite } do
		local display, user = nameOf(from)
		table.insert(view.invites, { from = from, name = display, user = user, expires = invite.expires })
	end
	Net.fire("PartyState", player, view)
end

local function pushParty(party: PartyModel.Party)
	for _, id in party.members do
		push(id)
	end
end

local function changed(partyId: string?)
	bus:publish(Topics.PartyChanged, { partyId = partyId })
end

-- ─── Actions ────────────────────────────────────────────────────────────────

local function joinPvp(party: PartyModel.Party)
	for _, id in party.members do
		PvpRules.setParty(id, party.id)
	end
end

-- Takes someone out and tidies everyone affected, however they left.
local function removeMember(userId: number)
	local party, disbanded, orphan = PartyModel.leave(book, userId)
	if not party then
		return
	end
	PvpRules.setParty(userId, nil)
	push(userId)
	if orphan then
		PvpRules.setParty(orphan, nil)
		push(orphan)
	end
	if not disbanded then
		pushParty(party)
	end
	if disbanded then
		vitalSignature[party.id] = nil
		lootModes[party.id] = nil
	end
	changed(party.id)
end

local function doInvite(player: Player, targetId: number?): { [string]: any }
	local target = targetId and playerOf(targetId)
	if not target then
		return { ok = false, reason = "GONE" }
	end
	-- A block or a setting reads the same as anything else: "not taking invites".
	if not safety:allows("partyInvites", player, target) then
		return { ok = false, reason = "NOT_ACCEPTING" }
	end
	local ok, reason = PartyModel.invite(book, player.UserId, target.UserId, now())
	if not ok then
		return { ok = false, reason = reason }
	end
	push(target.UserId)
	log:info("party_invite", { from = player.UserId, to = target.UserId })
	return { ok = true }
end

local function doAccept(player: Player, fromId: number?): { [string]: any }
	if not fromId then
		return { ok = false, reason = "EXPIRED" }
	end
	if not playerOf(fromId) then
		PartyModel.decline(book, player.UserId, fromId, now())
		push(player.UserId)
		return { ok = false, reason = "GONE" }
	end
	local ok, reason, party = PartyModel.accept(book, player.UserId, fromId, now())
	if not ok or not party then
		push(player.UserId)
		return { ok = false, reason = reason }
	end
	joinPvp(party)
	pushParty(party)
	for _, id in party.members do
		if id ~= player.UserId then
			notify(id, player.DisplayName .. " joined your party.")
		end
	end
	changed(party.id)
	log:info("party_joined", { party = party.id, userId = player.UserId, size = #party.members })
	return { ok = true }
end

local function onAction(player: Player, op: string, target: number?): { [string]: any }
	if flags.get("party_enabled") == false then
		return { ok = false, reason = "OFF" }
	end
	if op == "invite" then
		return doInvite(player, target)
	elseif op == "accept" then
		return doAccept(player, target)
	elseif op == "decline" then
		if target then
			PartyModel.decline(book, player.UserId, target, now())
			push(player.UserId)
		end
		return { ok = true }
	elseif op == "leave" then
		if not PartyModel.partyOf(book, player.UserId) then
			return { ok = false, reason = "NOT_IN_PARTY" }
		end
		removeMember(player.UserId)
		return { ok = true }
	elseif op == "kick" then
		-- The model checks leadership on a copy of the rules, so a removal goes through one path.
		local party = PartyModel.partyOf(book, player.UserId)
		if not party then
			return { ok = false, reason = "NOT_IN_PARTY" }
		end
		if party.leader ~= player.UserId then
			return { ok = false, reason = "NOT_LEADER" }
		end
		if not target or target == player.UserId or not table.find(party.members, target) then
			return { ok = false, reason = "NOT_MEMBER" }
		end
		removeMember(target)
		notify(target, "You were removed from the party.")
		return { ok = true }
	elseif op == "promote" then
		if not target then
			return { ok = false, reason = "NOT_MEMBER" }
		end
		local ok, reason = PartyModel.promote(book, player.UserId, target)
		if not ok then
			return { ok = false, reason = reason }
		end
		local party = PartyModel.partyOf(book, player.UserId)
		if party then
			pushParty(party)
		end
		return { ok = true }
	end
	return { ok = false }
end

-- ─── Vitals ─────────────────────────────────────────────────────────────────

local function sendVitals()
	for id, party in book.parties do
		local rows = {}
		local parts: { string } = {}
		local online: { Player } = {}
		for _, userId in party.members do
			local player = playerOf(userId)
			if player then
				table.insert(online, player)
				local character = player.Character
				local humanoid = character and character:FindFirstChildOfClass("Humanoid")
				local root = character and character:FindFirstChild("HumanoidRootPart")
				local state = reservoirs:get(player)
				local position = if root and root:IsA("BasePart") then root.Position else nil
				local row = {
					u = userId,
					h = if humanoid then math.ceil(humanoid.Health) else 0,
					m = if humanoid then math.ceil(humanoid.MaxHealth) else 0,
					r = if state then math.floor(state.current) else 0,
					rm = if state then math.floor(state.max) else 0,
					x = if position then math.floor(position.X / 16) * 16 else nil,
					z = if position then math.floor(position.Z / 16) * 16 else nil,
				}
				table.insert(rows, row)
				table.insert(parts, string.format("%d,%d,%d,%d,%d,%s,%s", userId, row.h, row.m, row.r, row.rm, tostring(row.x), tostring(row.z)))
			end
		end
		local signature = table.concat(parts, ";")
		if vitalSignature[id] ~= signature then
			vitalSignature[id] = signature
			Net.fireList("PartyVitals", online, rows)
		end
	end
end

-- ─── Public ─────────────────────────────────────────────────────────────────

function PartyService.partyIdOf(_self: any, userId: number): string?
	return book.byUser[userId]
end

function PartyService.matesOfUser(_self: any, userId: number): { Player }
	local out: { Player } = {}
	local party = PartyModel.partyOf(book, userId)
	if party then
		for _, id in party.members do
			local player = if id ~= userId then playerOf(id) else nil
			if player then
				table.insert(out, player)
			end
		end
	end
	return out
end

function PartyService.matesOf(self: any, player: Player): { Player }
	return self:matesOfUser(player.UserId)
end

function PartyService.sameParty(_self: any, a: number, b: number): boolean
	return PvpRules.sameParty(a, b)
end

function PartyService.leaderOf(_self: any, userId: number): number?
	local party = PartyModel.partyOf(book, userId)
	return party and party.leader
end

function PartyService.setLootMode(_self: any, partyId: string, mode: string)
	lootModes[partyId] = mode
	local party = book.parties[partyId]
	if party then
		pushParty(party)
	end
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "parties",
		category = "Social",
		description = "Every party on this server and every open invite",
		handler = function(_ctx: any, _a: any)
			local lines: { string } = {}
			for id, party in book.parties do
				local names: { string } = {}
				for _, member in party.members do
					table.insert(names, (nameOf(member)) .. (if member == party.leader then " (leader)" else ""))
				end
				table.insert(lines, id .. ": " .. table.concat(names, ", "))
			end
			local invites = 0
			for _, incoming in book.invites do
				for _ in incoming do
					invites += 1
				end
			end
			table.insert(lines, string.format("%d open invite(s)", invites))
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "testparty",
		category = "Social",
		description = "Put up to 5 players on this server in one party (skips invites). In Studio, use Test > Clients and Servers with 2+ players",
		handler = function(ctx: any, _a: any)
			local leader: Player = ctx.player
			removeMember(leader.UserId)
			local joined = 0
			for _, other in Players:GetPlayers() do
				if other ~= leader and joined < PartyModel.MAX_MEMBERS - 1 then
					removeMember(other.UserId)
					local t = now()
					book.declined[leader.UserId .. "|" .. other.UserId] = nil
					if PartyModel.invite(book, leader.UserId, other.UserId, t) then
						local ok, _, party = PartyModel.accept(book, other.UserId, leader.UserId, t)
						if ok and party then
							joinPvp(party)
							pushParty(party)
							changed(party.id)
							joined += 1
						end
					end
				end
			end
			return if joined > 0 then string.format("Party formed with %d other player(s)", joined) else "Nobody else is here. In Studio: Test > Clients and Servers, 2 players"
		end,
	})
	admin:Register({
		name = "partyleave",
		category = "Social",
		description = "Take a player out of their party",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_ctx: any, a: any)
			local target: Player = a.player
			removeMember(target.UserId)
			return target.Name .. " is not in a party now"
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function PartyService.init(_self: any, ctx: any)
	log, bus, flags = ctx.log, ctx.bus, ctx.flags
	reservoirs = ctx.get("ReservoirService")
	safety = ctx.get("SocialSafetyService")
	Net.handle("PartyAction", onAction)
	registerAdmin(ctx.get("AdminService"))
end

function PartyService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		local userId = player.UserId
		local party = PartyModel.partyOf(book, userId)
		for _, id in PartyModel.forgetInvites(book, userId) do
			push(id)
		end
		removeMember(userId)
		if party then
			for _, id in party.members do
				notify(id, player.DisplayName .. " left the party.")
			end
		end
	end)
	-- A client that loaded after an invite arrived asks by loading: send everyone their state once.
	Players.PlayerAdded:Connect(function(player)
		push(player.UserId)
	end)
	local sinceExpire = 0
	while true do
		task.wait(1 / VITALS_HZ)
		sendVitals()
		sinceExpire += 1 / VITALS_HZ
		if sinceExpire >= EXPIRE_EVERY then
			sinceExpire = 0
			for _, id in PartyModel.expire(book, now()) do
				push(id)
			end
		end
	end
end

return PartyService
