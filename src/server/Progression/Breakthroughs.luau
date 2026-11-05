--!strict
--[[
	Breakthroughs: what you must DO, beyond earning XP, to enter Expert, Master, Grandmaster
	and Transcendent in a branch. Until they're met, mastery holds just below the tier.

	Requirement types (checked against progression.records):
		insight      { id? | count }   studied an environmental insight site ("<domain>:<site>")
		teach        { count }         students you brought to Novice in this branch
		survive      { id }            survived a specific self-caused event ("<domain>:<event>")
		discoveries  { count }         recipes in this branch you were first to cast (personally)
		feat         { minPower, challenge? }  cast at this power in the branch (under real danger if challenge)
		paradigm     { count }         signature spells you have declared
		mentor       { tier }          studied this branch under a mentor of at least this tier

	`default` applies to every domain; a domain entry REPLACES it for that domain.
]]

export type Requirement = {
	type: string,
	id: string?,
	count: number?,
	minPower: number?,
	challenge: boolean?,
	tier: number?,
	text: string,
}

export type BreakthroughDef = {
	default: { Requirement },
	domains: { [string]: { Requirement } },
}

local Breakthroughs: { [number]: BreakthroughDef } = {
	-- ─── 5: Expert ──────────────────────────────────────────────────────────
	[5] = {
		default = {
			{ type = "discoveries", count = 2, text = "Invent 2 recipes in this branch (be the first you know of to cast them)." },
			{ type = "feat", minPower = 5, text = "Cast a power 5 spell in this branch." },
		},
		domains = {},
	},

	-- ─── 6: Master ──────────────────────────────────────────────────────────
	[6] = {
		default = {
			{ type = "insight", count = 1, text = "Study an insight site of this domain." },
			{ type = "teach", count = 1, text = "Bring a student to Novice in this branch." },
			{ type = "feat", minPower = 6, challenge = true, text = "Cast a power 6 spell in this branch under real danger." },
		},
		domains = {
			earth = {
				{ type = "insight", id = "earth:fault_zone", text = "Study a real fault zone." },
				{ type = "teach", count = 1, text = "Bring a student to Novice in this branch." },
				{ type = "survive", id = "earth:self_collapse", text = "Survive a collapse you caused yourself." },
			},
			water = {
				{ type = "insight", id = "water:ocean_trench", text = "Study the deep ocean trench." },
				{ type = "teach", count = 1, text = "Bring a student to Novice in this branch." },
				{ type = "survive", id = "water:drowning", text = "Survive being pulled under by your own current." },
			},
			energy = {
				{ type = "insight", id = "energy:volcanic_vent", text = "Study a volcanic vent." },
				{ type = "teach", count = 1, text = "Bring a student to Novice in this branch." },
				{ type = "survive", id = "energy:self_burn", text = "Survive being caught in your own fire." },
			},
		},
	},

	-- ─── 7: Grandmaster ─────────────────────────────────────────────────────
	[7] = {
		default = {
			{ type = "insight", count = 2, text = "Study 2 insight sites of this domain." },
			{ type = "discoveries", count = 5, text = "Invent 5 recipes in this branch." },
			{ type = "teach", count = 3, text = "Bring 3 students to Novice in this branch." },
			{ type = "feat", minPower = 8, challenge = true, text = "Cast a power 8 spell in this branch under real danger." },
		},
		domains = {},
	},

	-- ─── 8: Transcendent ────────────────────────────────────────────────────
	[8] = {
		default = {
			{ type = "paradigm", count = 1, text = "Declare a signature spell (a paradigm shift of your own)." },
			{ type = "feat", minPower = 10, challenge = true, text = "Cast a power 10 working in this branch under real danger." },
			{ type = "teach", count = 5, text = "Bring 5 students to Novice in this branch." },
			{ type = "mentor", tier = 7, text = "Have studied this branch under a Grandmaster." },
		},
		domains = {},
	},
}

return Breakthroughs
