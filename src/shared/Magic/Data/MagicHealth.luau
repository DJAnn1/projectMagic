--!strict
--[[
	MagicHealth data: your health grows as your magic does (docs/SpellOverhaul.md §2F; owner,
	2026-11-12: "I also want health to increase with skill increasing as your magic gets stronger,
	it ties to your health also"). Read by Shared/Magic/MagicHealth for players (InventoryService,
	the "Your magic" line of the stat breakdown) and NPC rigs (NPC/NPCLOD).

		perTier          +health per mastery tier of your best branch (Sensing 1 .. Transcendent 8)
		breadthPerBranch +health per OTHER branch at breadthMinTier or above
		breadthCap       the most breadth can add
		lifePct          up to this share more health, times your Life affinity (0..1)

	A bare start is 100 (StatDefs). Roughly: Adept ~180, Master ~260, Transcendent with breadth ~330,
	before gear. Damage per hit runs 9 (P1) to 36 (P10) before crits (DamageModel.base).
]]

return {
	perTier = 20,
	breadthPerBranch = 4,
	breadthMinTier = 2, -- Novice
	breadthCap = 60,
	lifePct = 0.10,
}
