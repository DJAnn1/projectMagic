--!strict
--[[
	ChronicleKinds: the deeds the world remembers (docs/LivingHistory.md §4, stage 1).

	A KIND: {
		base     0..1 how much it matters on its own. Repeats score less (ChronicleRules.score).
		valence  -1..1 how the town feels about whoever did it (feeds the `legend_of` memory)
		group    feat | disaster | wonder | loss  (which reply lines fit)
		named    true = the deed is credited to the players in it (greetings, Journal, a name in legends)
	}
	Scores at or above ChronicleRules.Tuning.legendAt become legends shared by every server.
	A first (first=true in the deed) adds firstBonus; power 8+ adds powerBonus per point over 7.
]]

export type Kind = {
	base: number,
	valence: number,
	group: string,
	named: boolean,
}

local Kinds: { [string]: Kind } = {
	-- Fights the whole island hears about.
	titan_fell = { base = 0.92, valence = 0.9, group = "feat", named = true },
	boss_slain = { base = 0.55, valence = 0.7, group = "feat", named = true },
	shared_event_won = { base = 0.55, valence = 0.6, group = "feat", named = true },
	-- Loose spells (Services/FeralService).
	feral_ended = { base = 0.4, valence = 0.5, group = "feat", named = true },
	feral_escaped = { base = 0.4, valence = -0.5, group = "disaster", named = true },
	-- The town's own troubles.
	crisis_resolved = { base = 0.5, valence = 0.7, group = "feat", named = true },
	event_relieved = { base = 0.5, valence = 0.7, group = "feat", named = true },
	-- Magic people talk about for days.
	great_spell = { base = 0.45, valence = 0.1, group = "wonder", named = true },
	quake = { base = 0.55, valence = -0.4, group = "disaster", named = true },
	tsunami = { base = 0.65, valence = -0.5, group = "disaster", named = true },
	npc_awakened = { base = 0.5, valence = 0.3, group = "wonder", named = false },
	world_first = { base = 0.35, valence = 0.2, group = "wonder", named = true },
	-- Services/AgendaService (Living History stage 4): what towns live through.
	siege_broken = { base = 0.6, valence = 0.85, group = "feat", named = true },
	town_fell = { base = 0.7, valence = 0, group = "loss", named = false },
	town_retaken = { base = 0.7, valence = 0.9, group = "feat", named = true },
}

return table.freeze(Kinds)
