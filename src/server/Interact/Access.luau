--!strict
--[[
	Access: who may do what in a building (docs/Buildings.md §4). Pure rules over the building
	Model's attributes, so doors, containers, beds and later housing all ask the same questions.

	BUILDING ATTRIBUTES (set by BuildingGenerator / SettlementService / housing)
		Access        "public" (anyone, anything) | "private" (only the owner) | "guild" (members)
		OwnerNPCId    the NPC household head living there ("" = none yet)
		OwnerUserId   a player owner (player housing; absent for NPC buildings)
		GuildId       for "guild" access (factions later)
		SettlementId  where a crime here is reported

	CRIMES (Topics.CrimeCommitted { player, settlementId, severity, reason }; ReputationService
	turns them into infamy, Concord standing and bounties)
		theft        taking items you didn't put there from a container you aren't allowed to use:
		             1 + value / 25, capped at 10 per take
		lockpicking  forcing a lock (picks or metal magic) on a building you aren't allowed into: 2
]]

local CollectionService = game:GetService("CollectionService")

local Access = {}

Access.LOCKPICK_SEVERITY = 2
Access.MAX_THEFT_SEVERITY = 10

-- The building Model an interactable part belongs to (nil for things out in the world).
function Access.buildingOf(instance: Instance): Model?
	local node: Instance? = instance.Parent
	while node and node ~= workspace do
		if node:IsA("Model") and CollectionService:HasTag(node, "Building") then
			return node
		end
		node = node.Parent
	end
	return nil
end

-- "npc", id | "player", userId | nil
function Access.ownerOf(building: Model?): (string?, any)
	if not building then
		return nil, nil
	end
	local userId = building:GetAttribute("OwnerUserId")
	if typeof(userId) == "number" then
		return "player", userId
	end
	local npcId = building:GetAttribute("OwnerNPCId")
	if typeof(npcId) == "string" and npcId ~= "" then
		return "npc", npcId
	end
	return nil, nil
end

-- May this player use the building's private things (containers, locks) without it being a crime?
function Access.permits(player: Player, building: Model?): boolean
	if not building then
		return true -- wilderness containers belong to nobody (loot stage)
	end
	local kind, id = Access.ownerOf(building)
	if kind == "player" then
		return id == player.UserId
	end
	local access = building:GetAttribute("Access")
	if access == "guild" then
		local guild = building:GetAttribute("GuildId")
		return typeof(guild) == "string" and player:GetAttribute("GuildId") == guild
	end
	return access ~= "private"
end

function Access.theftSeverity(value: number): number
	return math.clamp(1 + math.floor(value / 25), 1, Access.MAX_THEFT_SEVERITY)
end

function Access.settlementOf(building: Model?): string?
	local id = building and building:GetAttribute("SettlementId")
	return if typeof(id) == "string" then id else nil
end

-- What the owner is called in a sentence ("someone's home", "the smithy").
function Access.describe(building: Model?): string
	if not building then
		return "the wild"
	end
	local display = building:GetAttribute("DisplayName")
	if typeof(display) == "string" then
		return display
	end
	return building.Name
end

return Access
