--!strict
--[[
	CantripService: your awakening gives you spells (docs/EarlyGamePlan.md, plan item 1).

	For every awakened domain whose root branch is unlocked, once (PlayerData.cantrips records it):
	its Strike (an attack: Scorch, Stone Shot...) and a utility spell (Shared/Magic/Cantrips), saved
	in the spellbook with their names and put on the first empty hotbar slots (the first domain's
	land in 1 and 2). Runs when a player's data loads (so existing saves get theirs too) and when an
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
		if awakened and unlocked and not data.cantrips[domainId] then
			local rng = Seed.random(world:getSeed(), "player:" .. player.UserId, "cantrip:" .. domainId)
			local spells = Cantrips.forDomain(domainId, caster, rng)
			local given = 0
			for _, spell in spells do
				if spellbook:grant(player, spell.recipe, spell.name) then
					given += 1
				end
			end
			if given > 0 then
				data.cantrips[domainId] = os.time()
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
