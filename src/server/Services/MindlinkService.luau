--!strict
--[[
	MindlinkService: the Mindlink hybrid (Space + Mind; docs/Space.md "Mindlink"). Owner, 2026-11-16: it
	reaches "party members anywhere, plus any NPC you've talked to before, who answers as if you were there".

	CAST      SpacePower "mindlink" -> SpaceRuntime.mindlink -> offer(player, target):
	          aimed straight at someone you can reach: the link opens to them at once;
	          otherwise the caster is sent the minds they can reach (remote `Mindlink` t = "open") for
	          `pickSeconds`: their party (anywhere, unless either blocked the other) and every NPC who holds
	          a relationship with them (NPCService:knownTo), strongest bond first, at most `maxPeople`.
	NPC       MindlinkIntent("npc", id): NPCService:linkTalk opens a link; the client opens the ordinary
	          dialogue panel, and NPCService.onTalk answers without distance or a body nearby, without
	          stopping the NPC, and without teaching. Asleep or knocked out: no answer.
	PLAYER    MindlinkIntent("player", userId, thought): one of SpaceTuning.mindlink.thoughts (no free text,
	          so nothing to filter), heard by that party member with where it came from in words.

	Server-authoritative: an intent only works on someone the server offered in that cast's window.
	Admin `mindlink [player]` (who they could reach). Log `mindlink_cast`, `mindlink_npc`, `mindlink_thought`.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local S = require(Shared.Magic.Data.SpaceTuning)

local Server = script.Parent.Parent
local SpaceRuntime = require(Server.Magic.Cast.SpaceRuntime)

local M = S.mindlink

local MindlinkService = {
	name = "MindlinkService",
	dependencies = { "AdminService", "NetService", "NPCService", "PartyService", "SocialSafetyService" },
}

type Offer = { untilAt: number, npcs: { [string]: boolean }, players: { [number]: boolean } }

local log: any = nil
local npcs: any = nil
local parties: any = nil
local safety: any = nil
local offers: { [Player]: Offer } = {}
local lastThought: { [Player]: number } = {}

local THOUGHTS: { [string]: string } = {}
for _, t in M.thoughts do
	THOUGHTS[t.id] = t.text
end

local COMPASS = { "east", "north-east", "north", "north-west", "west", "south-west", "south", "south-east" }

-- "far to the north-east", "close by": where `from` is, seen from `to`. Roblox: -Z is north.
local function whereWords(from: Vector3, to: Vector3): string
	local d = Vector3.new(from.X - to.X, 0, from.Z - to.Z)
	local distance = d.Magnitude
	if distance < 60 then
		return "close by"
	end
	local angle = math.atan2(-d.Z, d.X)
	local index = (math.floor((angle / (math.pi / 4)) + 0.5) % 8) + 1
	local how = if distance < 300 then "not far" elseif distance < 1200 then "away" else "far"
	return how .. " to the " .. COMPASS[index]
end

local function positionOf(player: Player): Vector3?
	local character = player.Character
	return if character then character:GetPivot().Position else nil
end

-- Party mates anyone could link to: not you, not blocked either way.
local function reachableMates(player: Player): { Player }
	local found = {}
	for _, mate in parties:matesOf(player) do
		if mate ~= player and mate.Parent == Players and not safety:isBlocked(player.UserId, mate.UserId) and not safety:isBlocked(mate.UserId, player.UserId) then
			table.insert(found, mate)
		end
	end
	return found
end

local function asleep(npc: any): boolean
	return npc.action == "sleep"
end

-- Opens the dialogue link to one NPC (it must be in the current offer, or `force`).
local function linkNpc(player: Player, npcId: string, force: boolean?): (boolean, string?)
	local offer = offers[player]
	if not force and (not offer or offer.untilAt < os.clock() or not offer.npcs[npcId]) then
		return false, "NOT_OFFERED"
	end
	local npc = npcs:get(npcId)
	if not npc or npc.knockedOut then
		return false, "GONE"
	elseif asleep(npc) then
		return false, "ASLEEP"
	end
	npcs:linkTalk(player, npcId)
	offers[player] = nil
	log:info("mindlink_npc", { userId = player.UserId, npc = npcId })
	return true, nil
end

-- The cast. (effective, note)
function MindlinkService.offer(_self: any, player: Player, target: Model?): (boolean, string?)
	local here = positionOf(player)
	if not here then
		return false, nil
	end
	-- Aimed at someone you know: straight to them.
	if target then
		local npcId = target:GetAttribute("NpcId")
		if npcId ~= nil then
			for _, row in npcs:knownTo(player) do
				if row.npc.id == tostring(npcId) then
					local ok = linkNpc(player, row.npc.id, true)
					if ok then
						Net.fire("Mindlink", player, { t = "talk", npcId = row.npc.id })
						return true, nil
					end
					break
				end
			end
		end
	end
	local offer: Offer = { untilAt = os.clock() + M.pickSeconds, npcs = {}, players = {} }
	local people = {}
	for _, mate in reachableMates(player) do
		local at = positionOf(mate)
		offer.players[mate.UserId] = true
		table.insert(people, { kind = "player", id = tostring(mate.UserId), name = mate.DisplayName, where = if at then whereWords(at, here) else "somewhere" })
	end
	local count = 0
	for _, row in npcs:knownTo(player) do
		if count >= M.maxPeople then
			break
		end
		local npc = row.npc
		count += 1
		offer.npcs[npc.id] = true
		table.insert(people, {
			kind = "npc",
			id = npc.id,
			name = npc.name,
			role = npc.occupationName,
			where = whereWords(npc.position, here),
			asleep = asleep(npc) or nil,
		})
	end
	log:info("mindlink_cast", { userId = player.UserId, mates = #reachableMates(player), npcs = count })
	if #people == 0 then
		return false, "Your mind reaches out, and finds nobody it knows. Talk to people first."
	end
	offers[player] = offer
	Net.fire("Mindlink", player, { t = "open", seconds = M.pickSeconds, people = people, thoughts = M.thoughts })
	return true, nil
end

local function onIntent(player: Player, kind: string, id: string, thought: string?): any
	if kind == "npc" then
		local ok, why = linkNpc(player, id)
		return { ok = ok, reason = why }
	end
	local offer = offers[player]
	local userId = tonumber(id)
	if not offer or offer.untilAt < os.clock() or not userId or not offer.players[userId] then
		return { ok = false, reason = "NOT_OFFERED" }
	end
	local text = thought and THOUGHTS[thought]
	if not text then
		return { ok = false, reason = "NO_THOUGHT" }
	end
	if os.clock() - (lastThought[player] or -math.huge) < M.thoughtGap then
		return { ok = false, reason = "TOO_SOON" }
	end
	local mate = Players:GetPlayerByUserId(userId)
	-- Checked again now: the party or the blocks may have changed since the cast.
	if not mate or not table.find(reachableMates(player), mate) then
		return { ok = false, reason = "GONE" }
	end
	lastThought[player] = os.clock()
	local from, to = positionOf(player), positionOf(mate)
	Net.fire("Mindlink", mate, { t = "thought", from = player.DisplayName, text = text, where = if from and to then whereWords(from, to) else "somewhere" })
	log:info("mindlink_thought", { from = player.UserId, to = userId, thought = thought })
	return { ok = true }
end

function MindlinkService.init(self: any, ctx: any)
	log = ctx.log
	npcs = ctx.get("NPCService")
	parties = ctx.get("PartyService")
	safety = ctx.get("SocialSafetyService")
	SpaceRuntime.mindlinkHook = function(player: Player, target: Model?): (boolean, string?)
		return self:offer(player, target)
	end
	Net.handle("MindlinkIntent", onIntent)
	Players.PlayerRemoving:Connect(function(player)
		offers[player] = nil
		lastThought[player] = nil
	end)

	ctx.get("AdminService"):Register({
		name = "mindlink",
		category = "Magic",
		description = "Who a player's Mindlink would reach now: party mates and the people they've talked to",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(c: any, a: any)
			local target: Player = a.player or c.player
			local here = positionOf(target) or Vector3.zero
			local lines = { string.format("%s: %d party mate(s)", target.Name, #reachableMates(target)) }
			for i, row in npcs:knownTo(target) do
				if i > M.maxPeople then
					table.insert(lines, "...")
					break
				end
				table.insert(lines, string.format("%s (%s) %s, bond %.2f%s", row.npc.name, tostring(row.npc.occupationName), whereWords(row.npc.position, here), row.bond, if asleep(row.npc) then ", asleep" else ""))
			end
			return table.concat(lines, "\n")
		end,
	})
end

function MindlinkService.start(_self: any, _ctx: any) end

return MindlinkService
