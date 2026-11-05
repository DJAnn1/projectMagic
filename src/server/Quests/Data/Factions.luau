--!strict
--[[
	Factions: the organisations above settlements. Pure data; Services/FactionService runs it
	(docs/Quests.md §5). Settlement reputation (PlayerData.reputation) still exists and is
	separate: a town can like you while its guild doesn't.

	kind        guild | academy | government | cult | league | hunters | order | secret
	secret      hidden from players until revealed (by a quest, a member, or being hunted);
	            their standing still moves in the dark
	members     which NPCs belong (deterministic from occupation / culture / secret / ambition /
	            traits; FactionService.memberOf), and a share of matching NPCs that actually join
	territory   cultures whose settlements this faction watches (deeds there count as seen)
	esteem      domain -> how the faction feels about magic of that domain cast where it sees
	            (>0 admires, <0 condemns); scaled by recipe power
	deeds       deed id -> standing change (FactionService.DEEDS lists every deed)
	relations   faction id -> -1..1. Standing you gain with a faction moves its allies by
	            +allyShare x relation and its enemies by -enemyShare x |relation|
	bounties    issues bounties for crimes in its territory (the Concord) or on Mythic users
	            (the Quiet Hand)
	Ids are permanent (renames go through Data/Aliases).
]]

export type Faction = {
	name: string,
	kind: string,
	description: string,
	ideology: string, -- one line, shown once discovered
	secret: boolean?,
	members: {
		occupations: { string }?,
		cultures: { string }?, -- members must live in one of these (unset = anywhere)
		secrets: { string }?, -- NPC secret ids that make someone a member
		ambitions: { string }?,
		share: number, -- of matching NPCs who join (seeded per NPC)
	},
	territory: { string }, -- culture ids
	esteem: { [string]: number },
	deeds: { [string]: number },
	relations: { [string]: number },
	bounties: string?, -- "crimes" | "mythic"
}

local Factions: { [string]: Faction } = {
	smiths_guild = {
		name = "Smiths' Guild", kind = "guild",
		description = "The chartered smiths, miners and builders of the forge-cities.",
		ideology = "Metal is law; a contract is sacred; idle hands are theft.",
		members = { occupations = { "smith", "miner", "builder" }, share = 0.85 },
		territory = { "forgehold", "emberclan" },
		esteem = { earth = 0.6, energy = 0.3, void = -0.8 },
		deeds = { quest_helped = 40, commission_done = 60, theft = -120, assault_member = -80, knockout_member = -200, forbidden_magic = -30, relief = 20 },
		relations = { wayfarer_league = 0.3, island_concord = 0.4, scholars_league = 0.1, hollow_choir = -0.6 },
	},
	scholars_league = {
		name = "Scholars' League", kind = "academy",
		description = "The academies' fellowship of scholars, archivists and examiners.",
		ideology = "Knowledge is owed to everyone; a mind is not a field to be ploughed.",
		members = { occupations = { "scholar" }, share = 0.9 },
		territory = { "loreseat" },
		esteem = { mind = -0.2, space = 0.3, time = 0.4 },
		deeds = { quest_helped = 30, lore_shared = 60, discovery = 15, mind_on_people = -60, forbidden_magic = -50, theft = -60, knockout_member = -150, assault_member = -60 },
		relations = { island_concord = 0.3, hollow_choir = -0.8, seam_keepers = 0.2, smiths_guild = 0.1 },
	},
	tide_temple = {
		name = "Tide Temple", kind = "cult",
		description = "Priests of the sea, keepers of wells, rites and drowned shrines.",
		ideology = "The water remembers; what you take from it you owe back.",
		members = { occupations = { "tidepriest", "fisher" }, share = 0.7 },
		territory = { "tidecall", "frostfolk" },
		esteem = { water = 0.7, spirit = 0.4, energy = -0.3 },
		deeds = { quest_helped = 40, relief = 50, assault_member = -80, knockout_member = -180, forbidden_magic = -40 },
		relations = { verdant_circle = 0.4, island_concord = 0.2, hollow_choir = -0.5 },
	},
	verdant_circle = {
		name = "Verdant Circle", kind = "order",
		description = "Herbalists, healers and farmers who tend the island's living things.",
		ideology = "Grow what you can; burn nothing you cannot replant.",
		members = { occupations = { "herbalist", "healer", "farmer" }, share = 0.6 },
		territory = { "verdant" },
		esteem = { life = 0.8, water = 0.3, energy = -0.2 },
		deeds = { quest_helped = 40, relief = 60, healed_people = 25, burned_land = -60, assault_member = -80, knockout_member = -180 },
		relations = { tide_temple = 0.4, skywardens = 0.2, hollow_choir = -0.4 },
	},
	skywardens = {
		name = "Skywardens", kind = "order",
		description = "Weathercallers who read and steer the island's winds and storms.",
		ideology = "The sky is shared; whoever bends it answers to everyone under it.",
		members = { occupations = { "weathercaller" }, share = 0.9 },
		territory = { "skywarden" },
		esteem = { air = 0.8, energy = 0.2 },
		deeds = { quest_helped = 40, relief = 50, assault_member = -80, knockout_member = -180 },
		relations = { verdant_circle = 0.2, island_concord = 0.3 },
	},
	wayfarer_league = {
		name = "Wayfarer League", kind = "league",
		description = "Merchants, innkeepers and caravaneers who keep goods moving between towns.",
		ideology = "Roads open, prices fair, debts paid.",
		members = { occupations = { "merchant", "innkeeper" }, share = 0.8 },
		territory = { "wayfarer" },
		esteem = {},
		deeds = { quest_helped = 30, delivery_done = 50, theft = -150, assault_member = -80, knockout_member = -180, diplomacy = 40 },
		relations = { smiths_guild = 0.3, island_concord = 0.4, hunters_lodge = 0.2 },
	},
	hunters_lodge = {
		name = "Hunters' Lodge", kind = "hunters",
		description = "Trackers and hunters who take contracts on beasts, rogues and runaways.",
		ideology = "Every trail ends somewhere; we get paid when it does.",
		members = { occupations = { "hunter" }, share = 0.8 },
		territory = {},
		esteem = { air = 0.2, life = 0.2 },
		deeds = { quest_helped = 30, bounty_claimed = 80, assault_member = -60, knockout_member = -150 },
		relations = { island_concord = 0.5, wayfarer_league = 0.2 },
	},
	island_concord = {
		name = "Island Concord", kind = "government",
		description = "The compact of settlement councils and their watch. Keeps the peace, issues bounties.",
		ideology = "Every town its own law, and every law kept.",
		members = { occupations = { "guard" }, share = 1 },
		territory = { "forgehold", "emberclan", "tidecall", "frostfolk", "verdant", "skywarden", "loreseat", "wayfarer" },
		esteem = { void = -0.3 },
		deeds = { quest_helped = 25, relief = 30, crime = -40, assault_member = -120, knockout_member = -300, knockout_citizen = -60, bounty_paid = 120, diplomacy = 60, theft = -100 },
		relations = { smiths_guild = 0.4, scholars_league = 0.3, wayfarer_league = 0.4, hunters_lodge = 0.5, hollow_choir = -0.7 },
		bounties = "crimes",
	},
	hollow_choir = {
		name = "Hollow Choir", kind = "cult", secret = true,
		description = "Void-devotees who meet in cellars and ruins to listen to the silence between things.",
		ideology = "Everything is borrowed from the nothing, and the nothing will collect.",
		members = { secrets = { "forbidden_dabble" }, ambitions = { "forbidden" }, share = 0.5 },
		territory = {},
		esteem = { void = 0.8, spirit = -0.2 },
		deeds = { quest_helped = 30, forbidden_magic = 30, assault_member = -60, knockout_member = -120 },
		relations = { scholars_league = -0.8, island_concord = -0.7, smiths_guild = -0.6, tide_temple = -0.5 },
	},
	quiet_hand = {
		name = "The Quiet Hand", kind = "secret", secret = true,
		description = "A society that watches for Time, Gravity and Reality and makes sure they stay rare.",
		ideology = "Some doors must stay shut, whoever is knocking.",
		members = { occupations = { "guard", "hunter", "scholar" }, share = 0.06 },
		territory = {},
		esteem = { time = -1, gravity = -1, reality = -1 },
		deeds = { mythic_cast = -60, mythic_awakened = -200, hunter_spared = 40, knockout_member = -100 },
		relations = { seam_keepers = -0.9, island_concord = 0.1 },
		bounties = "mythic",
	},
	seam_keepers = {
		name = "Seam Keepers", kind = "secret", secret = true,
		description = "Old, patient people who keep the breadcrumbs to the rarest magic from being swept away.",
		ideology = "Nothing true is ever lost; it waits for someone who listens.",
		members = { occupations = { "retired", "scholar", "tidepriest" }, share = 0.08 },
		territory = {},
		esteem = { time = 0.6, gravity = 0.6, reality = 0.6, spirit = 0.2 },
		deeds = { quest_helped = 40, lore_shared = 60, mythic_awakened = 120, knockout_member = -120 },
		relations = { quiet_hand = -0.9, scholars_league = 0.2 },
	},
}

-- Standing bands (-1000..1000). The first whose `min` the standing reaches wins.
local ranks = {
	{ min = 600, id = "revered", name = "Revered" },
	{ min = 300, id = "honored", name = "Honored" },
	{ min = 100, id = "friendly", name = "Friendly" },
	{ min = -99, id = "neutral", name = "Neutral" },
	{ min = -299, id = "unfriendly", name = "Unfriendly" },
	{ min = -599, id = "hostile", name = "Hostile" },
	{ min = -1000, id = "hated", name = "Hated" },
}

return table.freeze({
	factions = Factions,
	ranks = ranks,
	allyShare = 0.5,
	enemyShare = 0.3,
	limit = 1000,
})
