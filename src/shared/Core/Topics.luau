--!strict
--[[
	Topics: every SignalBus topic, in one place. Publishing or subscribing to a topic that
	isn't listed here errors, so typos surface immediately instead of silently doing nothing.
	Payload shapes are documented next to each topic.
]]

return table.freeze({
	-- Server
	PlayerDataLoaded = "PlayerDataLoaded", -- { player: Player }
	PlayerDataReleased = "PlayerDataReleased", -- { player: Player?, userId: number, reason: string }
	NetViolation = "NetViolation", -- { player: Player, remote: string, reason: string }
	WorldEventRecorded = "WorldEventRecorded", -- { id: string, kind: string, data: any, origin: string }
	FlagChanged = "FlagChanged", -- { name: string, value: any }
	WorldReady = "WorldReady", -- {} generation index and POIs are available
	ChunkBuilt = "ChunkBuilt", -- { cx: number, cz: number }
	TerrainChanged = "TerrainChanged", -- { cause: string, position: Vector3, radius: number }
	WorldEventStarted = "WorldEventStarted", -- { id: string, type: string, x: number, z: number, radius: number }
	WorldEventEnded = "WorldEventEnded", -- { id: string, type: string }
	MagicWitnessed = "MagicWitnessed", -- { position: Vector3, radius: number, domains: {string}, power: number, harmful: boolean, casterUserId: number } (NPC reactions)
	MagicDamage = "MagicDamage", -- { humanoid: Humanoid, amount: number, kind: string, sourceUserId: number? }
	-- Combat (docs/Combat.md §6)
	SpellCast = "SpellCast", -- { casterUserId, key, route, domain, power, point } a cast was accepted and paid
	SpellHit = "SpellHit", -- { casterUserId, key, route, domain, total, targets: { { name, dealt, crit, killed, kind } } }
	TargetDamaged = "TargetDamaged", -- { humanoid, model, amount, kind, sourceUserId?, crit, domain?, branch?, killed }
	TargetKilled = "TargetKilled", -- { humanoid, model, kind, sourceUserId?, domain? }
	StatusApplied = "StatusApplied", -- { humanoid, model, status, duration, sourceUserId? } a NEW status (not a refresh)
	SpellResolved = "SpellResolved", -- { casterUserId, key, route, point, domains, branch, branchPath, property, verb, form, power, tags, effective, backfired, hits, harmful, forbidden, borrowed }
	MagicReaction = "MagicReaction", -- { result, description, owner: number?, branch: string? } an InteractionMatrix reaction fired; owner triggered it
	-- NPCs, quests and reputation (docs/Quests.md)
	NpcTalked = "NpcTalked", -- { player, npcId, topic }
	QuestOffered = "QuestOffered", -- { player, questId, template }
	QuestStarted = "QuestStarted", -- { player?, questId, template, scope }
	QuestAdvanced = "QuestAdvanced", -- { questId, stage }
	QuestEnded = "QuestEnded", -- { questId, template, outcome, success, status, players: { Player } }
	ReputationChanged = "ReputationChanged", -- { player, faction?, settlementId?, delta, standing }
	CrimeCommitted = "CrimeCommitted", -- { player, settlementId?, severity, reason } (ReputationService records it)
	CrimeRecorded = "CrimeRecorded", -- { player, settlementId?, severity, reason, infamy } after infamy/bounty
	BuildingBuilt = "BuildingBuilt", -- { lotId: string, settlementId: string, kind: string } a settlement building now exists
	-- Items (docs/Items.md)
	ItemsGained = "ItemsGained", -- { player, itemId, count } items entered a player's inventory (give, loot, rewards)
	ItemUsed = "ItemUsed", -- { player, itemId } a consumable, book or scroll was used successfully
	HouseClaimed = "HouseClaimed", -- { player, lotId, price } (Services/HousingService)
	ItemCrafted = "ItemCrafted", -- { player, recipe, itemId, count } (Services/CraftingService)
	-- Social (docs/Social.md)
	PartyChanged = "PartyChanged", -- { partyId } someone joined or left (Services/PartyService)
	ComboTriggered = "ComboTriggered", -- { combo, a, b, position, targets, total } (Services/ComboService)
	DuelEnded = "DuelEnded", -- { id, a, b, winner?, reason, rule } (Services/DuelService)
	TargetHealed = "TargetHealed", -- { humanoid, model, amount, sourceUserId? } magic healed someone (EffectRunner)
	SharedEventEnded = "SharedEventEnded", -- { id, type, result, place, players } (Services/SharedEventService)

	-- Client
	ScreenChanged = "ScreenChanged", -- { screen: string? } full-screen UI opened (id) or closed (nil)
})
