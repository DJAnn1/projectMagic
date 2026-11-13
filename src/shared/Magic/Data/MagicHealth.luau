--!strict
--[[
	MagicHealth data: your health grows as your magic does (docs/SpellOverhaul.md §2F; owner,
	2026-11-12: "I also want health to increase with skill increasing as your magic gets stronger,
	it ties to your health also"). Read by Shared/Magic/MagicHealth for players (InventoryService,
	the "Your magic" line of the stat breakdown) and NPC rigs (NPC/NPCLOD).

		byTier           +health for the mastery tier of your best branch (index 0 Untouched ..
		                 8 Transcendent); it climbs faster near the top (owner, 2026-11-13: "max
		                 level should have about 1000 health")
		breadthPerBranch +health per OTHER branch at breadthMinTier or above
		breadthCap       the most breadth can add
		lifePct          up to this share more health, times your Life affinity (0..1)

	A bare start is 100 (StatDefs). Roughly, before gear: Novice ~160, Adept ~210, Master ~380,
	Transcendent ~940, and ~1000 with full breadth (~1100 with Life affinity). Damage per hit runs
	9 (P1) to 36 (P10) before crits (DamageModel.base): see docs/SpellOverhaul.md §5 on fight length.
]]

return {
	byTier = { [0] = 0, 25, 60, 110, 180, 280, 420, 610, 840 },
	breadthPerBranch = 4,
	breadthMinTier = 2, -- Novice
	breadthCap = 60,
	lifePct = 0.10,
}
