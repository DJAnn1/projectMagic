--!strict
--[[
	SocialSafetyService: who may reach whom (docs/Social.md §7). Every social feature asks here before
	it shows one player anything from another, so a block or a setting holds everywhere.

		allows(settingId, from, to) -> boolean      may `from` send `to` this? (may yield: friends check)
		emoteVisible(viewer, actor, sameParty) -> boolean   never yields; safe in a loop
		isBlocked(a, b) -> boolean                  either one has blocked the other

	BLOCKS come from the Roblox block list. Only the client can read it (StarterGui
	GetCore("GetBlockedUserIds")), so each client reports its own list through ReportBlocks. A false
	list can only ever hide things from the player who sent it, so trusting it is safe.

	Refusals never say why: "isn't taking invites right now" reads the same for a block, a setting
	or a full party, so nobody can use invites to find out they've been blocked.

	This stage has no free text anywhere: parties, emotes, combos and duels show only Roblox display
	names, which Roblox moderates. Custom text (guild names, house names, books) arrives in later
	stages and must go through TextService first, as spell names do (Services/SpellbookService).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)

local FRIEND_CACHE_SECONDS = 300

local SocialSafetyService = {
	name = "SocialSafetyService",
	dependencies = { "NetService", "PreferencesService" },
}

local prefs: any = nil
local blocked: { [number]: { [number]: boolean } } = {}
local friendCache: { [string]: { value: boolean, expires: number } } = {}

local function pairKey(a: number, b: number): string
	return if a < b then a .. "|" .. b else b .. "|" .. a
end

function SocialSafetyService.isBlocked(_self: any, a: number, b: number): boolean
	local ofA, ofB = blocked[a], blocked[b]
	return (ofA ~= nil and ofA[b] == true) or (ofB ~= nil and ofB[a] == true)
end

local function areFriends(a: Player, b: Player): boolean
	local key = pairKey(a.UserId, b.UserId)
	local cached = friendCache[key]
	if cached and os.clock() < cached.expires then
		return cached.value
	end
	local ok, result = pcall(a.IsFriendsWith, a, b.UserId)
	local value = ok and result == true
	friendCache[key] = { value = value, expires = os.clock() + FRIEND_CACHE_SECONDS }
	return value
end

-- `settingId` is "partyInvites" or "duelChallenges" (Shared/UI/Settings): anyone | friends | nobody.
function SocialSafetyService.allows(self: any, settingId: string, from: Player, to: Player): boolean
	if self:isBlocked(from.UserId, to.UserId) then
		return false
	end
	local mode = prefs:get(to, settingId)
	if mode == "nobody" then
		return false
	elseif mode == "friends" then
		return areFriends(from, to)
	end
	return true
end

function SocialSafetyService.emoteVisible(self: any, viewer: Player, actor: Player, sameParty: boolean): boolean
	if viewer == actor then
		return true
	end
	if self:isBlocked(viewer.UserId, actor.UserId) then
		return false
	end
	local mode = prefs:get(viewer, "emotesFrom")
	if mode == "nobody" then
		return false
	elseif mode == "party" then
		return sameParty
	end
	return true
end

function SocialSafetyService.init(_self: any, ctx: any)
	prefs = ctx.get("PreferencesService")
	Net.on("ReportBlocks", function(player: Player, ids: { number })
		local set: { [number]: boolean } = {}
		for _, id in ids do
			set[id] = true
		end
		blocked[player.UserId] = set
	end)
end

function SocialSafetyService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		blocked[player.UserId] = nil
		local prefix = tostring(player.UserId)
		for key in friendCache do
			if string.find(key, prefix, 1, true) then
				friendCache[key] = nil
			end
		end
	end)
end

return SocialSafetyService
