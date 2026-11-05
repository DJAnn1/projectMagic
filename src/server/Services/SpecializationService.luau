--!strict
--[[
	SpecializationService: commits players to (and releases them from) Specialization oaths.
	The rules for what an oath does live in Shared/Magic/Data/Specializations; the effects are
	applied by MagicCore (power/cost) and Progression (XP) through CasterProfile.branchMods.

		commit(player, id)   -> ok, reason?
		renounce(player, id) -> ok, reason?

	Limits: minimum mastery in the oath's branch; 1/2/3 oaths at Skilled/Master/Grandmaster
	(your best branch); no opposing oaths; a 30-day cooldown after renouncing.
	Renouncing needs the "rite:unbinding" lore (consumed) and costs 35% of the oath branch's XP.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Registry = require(Shared.Magic.Registry)
local Specialization = require(Shared.Magic.Specialization)
local ProgressionFolder = script.Parent.Parent.Progression
local Progression = require(ProgressionFolder.Progression)
local T = require(ProgressionFolder.ProgressionTuning)

local SpecializationService = {
	name = "SpecializationService",
	dependencies = { "NetService", "PlayerDataService" },
}

local log: any = nil
local playerData: any = nil

local function bestTier(p: any): number
	local best = 0
	for branchId in p.unlocked do
		best = math.max(best, (Progression.getMasteryTier(p, branchId)))
	end
	return best
end

function SpecializationService.allowedCommitments(_self: any, p: any): number
	return T.specialization.commitmentsByTier[bestTier(p)] or 0
end

function SpecializationService.commit(self: any, player: Player, id: string): (boolean, string?)
	local state = playerData:get(player)
	local def = Registry.specializations[id]
	if not state or not def then
		return false, "INVALID"
	end
	local p = state.data.progression
	local now = os.time()
	if (p.mastery[def.branch] or 0) < def.minMastery then
		return false, "NOT_ENOUGH_MASTERY"
	end
	local count = 0
	for _ in p.commitments do
		count += 1
	end
	if count >= self:allowedCommitments(p) then
		return false, "NO_FREE_COMMITMENT"
	end
	if p.renouncedAt > 0 and now - p.renouncedAt < T.specialization.renounceCooldownSeconds then
		return false, "RECENTLY_RENOUNCED"
	end
	local conflict = Specialization.conflicts(p.commitments, id)
	if conflict then
		return false, conflict
	end

	p.commitments[id] = now
	playerData:refreshCaster(player)
	Net.fire("ProgressionChanged", player, { { kind = "commitment", id = id } })
	log:info("committed", { userId = player.UserId, id = id })
	return true, nil
end

function SpecializationService.renounce(_self: any, player: Player, id: string): (boolean, string?)
	local state = playerData:get(player)
	local def = Registry.specializations[id]
	if not state or not def then
		return false, "INVALID"
	end
	local p = state.data.progression
	if not p.commitments[id] then
		return false, "NOT_COMMITTED"
	end
	local lore = T.specialization.renounceLore
	if not p.lore[lore] then
		return false, "NEEDS_RITE_OF_UNBINDING"
	end

	p.lore[lore] = nil -- the rite is consumed
	Progression.removeExperience(p, def.branch, T.specialization.renounceXpLoss)
	p.commitments[id] = nil
	p.renouncedAt = os.time()
	playerData:refreshCaster(player)
	Net.fire("ProgressionChanged", player, { { kind = "renounced", id = id } })
	log:info("renounced", { userId = player.UserId, id = id })
	return true, nil
end

function SpecializationService.init(_self: any, ctx: any)
	log = ctx.log
	playerData = ctx.get("PlayerDataService")
	Net.handle("CommitSpecialization", function(player: Player, id: string)
		return SpecializationService:commit(player, id)
	end)
	Net.handle("RenounceSpecialization", function(player: Player, id: string)
		return SpecializationService:renounce(player, id)
	end)
end

return SpecializationService
