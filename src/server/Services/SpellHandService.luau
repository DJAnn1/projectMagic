--!strict
--[[
	SpellHandService: publishes each player's spell hand, their own style in how their magic looks
	(docs/SpellHand.md). Rules: Shared/Magic/SpellHand. Drawing: Client/Fx/Conjure, SpellFx.

	SEEDED    Seed.random(worldSeed, "player:<id>", "hand"), leaning on the profile's temperaments,
	          so it's the same on every server and nobody can reroll it. There's no menu: it's who
	          you are. The world seed never leaves the server; only the result is published.
	MATURES   The hand carries your best mastery tier, so it grows more elaborate as you do.
	          Checked when your data loads and at most every TIER_CHECK seconds after you cast.
	PUBLISHED Player attribute "SpellHand" (SpellHand.encode). Like "MagicSignature", it's how
	          magic looks, not a secret. No save field: everything is regenerated from the seed.

	Admin: spellhand [player] (show it), spellhandtier <tier> [player] (preview a tier until rejoin).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local SpellHand = require(Shared.Magic.SpellHand)

local Server = script.Parent.Parent
local Progression = require(Server.Progression.Progression)

local ATTRIBUTE = "SpellHand"
local TIER_CHECK = 20

local SpellHandService = {
	name = "SpellHandService",
	dependencies = { "AdminService", "PlayerDataService", "WorldService" },
}

local log: any = nil
local playerData: any = nil
local worldService: any = nil

local hands: { [Player]: SpellHand.Hand } = {}
local previews: { [Player]: number } = {}
local lastCheck: { [Player]: number } = {}

local function bestTier(state: any): number
	local p = state.data.progression
	local best = 0
	for branchId in (p and p.unlocked or {}) :: { [string]: any } do
		local tier = (Progression.getMasteryTier(p, branchId))
		best = math.max(best, tier)
	end
	return best
end

local function publish(player: Player)
	local hand = hands[player]
	if hand then
		local preview = previews[player]
		local shown = if preview then SpellHand.withTier(hand, preview) else hand
		player:SetAttribute(ATTRIBUTE, SpellHand.encode(shown))
	end
end

local function build(player: Player)
	local state = playerData:get(player)
	if not state then
		return
	end
	local profile = state.data.profile
	local temperaments = if profile and typeof(profile.temperaments) == "table" then profile.temperaments else {}
	local rng = Seed.random(worldService:getSeed(), "player:" .. player.UserId, "hand")
	hands[player] = SpellHand.generate(rng, temperaments, bestTier(state))
	publish(player)
	log:debug("spell_hand", { userId = player.UserId, hand = SpellHand.encode(hands[player]) })
end

-- After a cast, at most every TIER_CHECK seconds: has the hand matured?
local function onSpell(payload: any)
	local player = Players:GetPlayerByUserId(payload.casterUserId)
	local hand = player and hands[player]
	if not player or not hand then
		return
	end
	local now = os.clock()
	if now - (lastCheck[player] or -math.huge) < TIER_CHECK then
		return
	end
	lastCheck[player] = now
	local state = playerData:get(player)
	local tier = if state then bestTier(state) else hand.tier
	if tier ~= hand.tier then
		hands[player] = SpellHand.withTier(hand, tier)
		publish(player)
		log:info("spell_hand_matured", { userId = player.UserId, tier = tier })
	end
end

local function describe(player: Player): string
	local hand = SpellHand.decode(player:GetAttribute(ATTRIBUTE) :: string?)
	if not hand then
		return player.Name .. " has no hand yet"
	end
	local d = SpellHand.detail(hand.tier)
	return string.format(
		"%s: rune %s, shape %s, spins %s at %.2f turns/s, voice x%.2f, tier %d%s (motes %d, second ring %s, crown %s)",
		player.Name, SpellHand.data.runes[hand.rune], SpellHand.shapeName(hand),
		if hand.spin > 0 then "sunwise" else "widdershins", hand.speed, hand.pitch, hand.tier,
		if previews[player] then " [preview]" else "", d.motes, tostring(d.secondRing), tostring(d.crown)
	)
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "spellhand",
		category = "Spells",
		description = "A player's spell hand: rune, conjure shape, spin, voice, and how elaborate their tier makes it",
		args = { { name = "player", type = "player", default = "me" } },
		handler = function(_ctx: any, a: any)
			return describe(a.player)
		end,
	})
	admin:Register({
		name = "spellhandtier",
		category = "Spells",
		description = "Preview a player's hand at another mastery tier (0-8; -1 ends the preview). Until they rejoin; nothing is saved",
		args = {
			{ name = "tier", type = "number", min = -1, max = 8 },
			{ name = "player", type = "player", default = "me" },
		},
		handler = function(_ctx: any, a: any)
			local tier = math.floor(tonumber(a.tier) or -1)
			previews[a.player] = if tier >= 0 then tier else nil
			if not hands[a.player] then
				build(a.player)
			end
			publish(a.player)
			return describe(a.player)
		end,
	})
end

function SpellHandService.init(_self: any, ctx: any)
	log = ctx.log
	playerData = ctx.get("PlayerDataService")
	worldService = ctx.get("WorldService")
	ctx.bus:subscribe(Topics.PlayerDataLoaded, function(payload: any)
		build(payload.player)
	end)
	ctx.bus:subscribe(Topics.SpellResolved, onSpell)
	registerAdmin(ctx.get("AdminService"))
end

function SpellHandService.start(_self: any, _ctx: any)
	for _, player in Players:GetPlayers() do
		if not hands[player] then
			build(player)
		end
	end
	Players.PlayerRemoving:Connect(function(player)
		hands[player] = nil
		previews[player] = nil
		lastCheck[player] = nil
	end)
end

return SpellHandService
