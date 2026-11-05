--!strict
--[[
	CantripService: your awakening gives you spells (docs/EarlyGamePlan.md, plan item 1).

	For every awakened domain whose root branch is unlocked, once per spell kind: its Strike (an
	attack: Scorch, Stone Shot...), a utility spell and the thrown Strike (Ember Dart...)
	(Shared/Magic/Cantrips), saved in the spellbook with their names and put on the first empty
	hotbar slots (the first domain's land in 1-3).

	PlayerData.cantrips records what was given: "<domain>:<kind>" -> unix. A plain "<domain>" key
	(saves from before the bolt existed) means its strike and utility were given; those players get
	only the bolt, on their next load. Runs when a player's data loads (so existing saves get theirs too) and when an
	awakening opens a new domain (ProgressionService's awaken hook). Then SpellbookChanged tells the
	client to refetch.

	Server-authoritative: the recipes are validated against the player's real caster profile;
	anything they can't cast yet is skipped (and tried again on the next load). Seeded:
	Seed.random(worldSeed, "player:<id>", "cantrip:<domain>").
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local Registry = require(Shared.Magic.Registry)
local Cantrips = require(Shared.Magic.Cantrips)

local CantripService = {
	name = "CantripService",
	dependencies = { "NetService", "PlayerDataService", "ProgressionService", "SpellbookService", "WorldService" },
}

local log: any = nil
local playerData: any = nil
local spellbook: any = nil
local world: any = nil

-- Grants the cantrips of every unlocked, awakened domain that hasn't had them. Returns how many
-- spells were granted.
local function grant(player: Player): number
	local state = playerData:get(player)
	if not state then
		return 0
	end
	local data = state.data
	data.cantrips = data.cantrips or {}
	local caster = state.caster
	local granted = 0
	for _, domainId in Registry.domainIds do
		local awakened = caster.awakened and caster.awakened[domainId]
		local unlocked = data.progression.unlocked[domainId]
		if awakened and unlocked and not data.cantrips[domainId .. ":bolt"] then
			local legacy = data.cantrips[domainId] ~= nil -- strike + utility already given (older save)
			local rng = Seed.random(world:getSeed(), "player:" .. player.UserId, "cantrip:" .. domainId)
			local spells = Cantrips.forDomain(domainId, caster, rng)
			local given = 0
			for _, spell in spells do
				local mark = domainId .. ":" .. spell.kind
				local done = data.cantrips[mark] ~= nil or (legacy and spell.kind ~= "bolt")
				if not done and spellbook:grant(player, spell.recipe, spell.name) then
					data.cantrips[mark] = os.time()
					given += 1
				end
			end
			if given > 0 then
				granted += given
				log:info("cantrips_granted", { userId = player.UserId, domain = domainId, spells = given })
			end
		end
	end
	if granted > 0 then
		Net.fire("SpellbookChanged", player)
	end
	return granted
end

function CantripService.init(_self: any, ctx: any)
	log = ctx.log
	playerData = ctx.get("PlayerDataService")
	spellbook = ctx.get("SpellbookService")
	world = ctx.get("WorldService")
	ctx.get("ProgressionService"):setAwakenHook(function(player: Player, _domains: { string })
		-- The profile and caster have just been refreshed with the new domain.
		grant(player)
	end)
	ctx.bus:subscribe(Topics.PlayerDataLoaded, function(payload: any)
		task.defer(grant, payload.player) -- after ProgressionService has unlocked the roots
	end)
end

function CantripService.start(_self: any, _ctx: any) end

-- For admins and specs: grant now (returns the count).
function CantripService.grant(_self: any, player: Player): number
	return grant(player)
end

return CantripService
