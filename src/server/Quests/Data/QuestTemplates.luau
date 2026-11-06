--!strict
--[[
	QuestTemplates: every kind of story a situation can become. Pure data (schema in
	Quests/QuestTypes; docs/Quests.md §2-3). Read by QuestDirector and QuestFactory.

	Conventions
		Slots    "giver", "town", "site"... resolved by QuestFactory from the situation's facts or a
		         picker; text uses {slot}. Positions are slots too.
		Options  every stage offers several ways through; `requires` only hides an option from the
		         list (anyone who does it anyway still gets it, which is how hidden creative paths work).
		Casts    `match` = the expected solutions; `needs` = interaction tags (InteractionMatrix) that
		         also solve it. A cast that meets `needs` without matching `match` is recorded as
		         creative (journal + a bonus).
		Rewards  xp.branch may be a slot, a branch id, or "best:<domain>" (your best branch there).
		         reputation keys: faction ids, or "settlement" (the quest's town).
		World    applied by QuestDirector.applyWorld: relief, prosperity, stress, relation, endEvent,
		         startEvent, npcMastery, awakenNpc, revealFaction, clearBounty, notoriety.

	Adding a template: add an entry here, give it a situation kind SituationDetector produces, and
	Tests/Quest.spec checks its slots, stages, outcomes and option targets are consistent.
]]

local QuestTypes = require(script.Parent.Parent.QuestTypes)

type Template = QuestTypes.Template
type ObjectiveSpec = QuestTypes.ObjectiveSpec

-- Small builders keep the data readable.
local function o(kind: string, id: string, text: string, fields: { [string]: any }?): ObjectiveSpec
	local spec: any = fields and table.clone(fields) or {}
	spec.kind, spec.id, spec.text = kind, id, text
	return spec
end

local EARTH_SHAPING = { "contour", "cohesion", "hardness", "density" }
local CONSTRUCT = { forms = { "wall", "pillar" }, harmful = false }

local templates: { Template } = {
	-- ─── 1. Earth: the tunnel collapse ──────────────────────────────────────
	{
		id = "ore_tunnel_collapse", type = "crisis",
		title = "The Shut Seam", summary = "A tunnel collapse at {mine_name} has trapped {town_name}'s ore shipment.",
		giver = "giver", scope = "personal", situations = { "tunnel_collapse" },
		weight = 1, domains = { "earth" }, intensity = 0.4, difficulty = { 1, 6 },
		slots = {
			giver = { kind = "npc", from = "npcId" },
			mine = { kind = "position", from = "poiId" },
			town = { kind = "settlement", from = "settlementId" },
			builder = { kind = "npc", pick = "colleague:builder", optional = true },
		},
		stages = {
			{ id = "hear", text = "{giver} needs someone who can move stone.", options = {
				{ id = "listen", label = "Hear them out", approach = "talk", objectives = { o("talk", "ask", "Talk to {giver}", { target = "giver" }) }, next = "clear" },
			} },
			{ id = "clear", text = "The seam at {mine_name} is choked with rubble.", hours = 36, options = {
				{ id = "dig", label = "Shape the rock aside", approach = "magic", requires = { domains = { "earth" } },
					objectives = { o("cast", "dig", "Reshape the rubble at the seam", { at = "mine", radius = 45, amount = 14, match = { properties = EARTH_SHAPING, verbs = { "reduce", "transmute", "redirect" } }, needs = { "stone", "force" } }) },
					outcome = "cleared" },
				{ id = "shore", label = "Shore it up with stone", approach = "magic", requires = { domains = { "earth" } },
					objectives = { o("cast", "brace", "Raise two supports in the tunnel", { at = "mine", radius = 45, count = 2, match = CONSTRUCT }) },
					outcome = "shored" },
				{ id = "crew", label = "Hire a building crew", approach = "trade",
					objectives = {
						o("talk", "find", "Find {builder} in {town_name}", { target = "builder" }),
						o("pay", "hire", "Pay {builder} 40", { target = "builder", amount = 40 }),
						o("wait", "dig", "Give the crew two hours", { hours = 2 }),
					}, ordered = true, outcome = "crew" },
				{ id = "blast", label = "Blast it open (risky)", approach = "force",
					objectives = { o("cast", "blast", "Blow the rubble apart", { at = "mine", radius = 45, count = 1, match = { harmful = true, minPower = 5 } }) },
					outcome = "caved" },
			} },
		},
		outcomes = {
			cleared = { text = "The seam breathes again. Carts are rolling by nightfall.", success = true, memory = "helped_me",
				rewards = { xp = { branch = "best:earth", amount = 400 }, currency = 60, relationship = 0.15, reputation = { smiths_guild = 60, settlement = 15 } }, world = { ore = 0.15, prosperity = 2 } },
			shored = { text = "Your pillars hold the roof while the miners clear the rest.", success = true, memory = "helped_me",
				rewards = { xp = { branch = "best:earth", amount = 350 }, currency = 50, relationship = 0.12, reputation = { smiths_guild = 50, settlement = 10 } }, world = { ore = 0.1, prosperity = 1.5 } },
			crew = { text = "The crew grumbles, digs, and gets it done.", success = true,
				rewards = { relationship = 0.08, reputation = { smiths_guild = 30, wayfarer_league = 10 } }, world = { ore = 0.1, prosperity = 1 } },
			caved = { text = "The blast brings down half the hill. The seam is gone for a season.", success = false, memory = "harmed_town",
				rewards = { relationship = -0.2, reputation = { smiths_guild = -40, settlement = -10 } }, world = { stress = 0.2, ore = -0.3, prosperity = -2 } },
			locals = { text = "The miners dug their own way out, eventually.", success = false },
			lapsed = { text = "Nobody cleared the seam. The forges of {town_name} run cold for a while.", success = false, world = { prosperity = -1.5 } },
		},
		failOutcome = "lapsed", expireHours = 48,
		escalation = { afterHours = 30, text = "With the seam shut, {town_name}'s forges are going cold.", outcome = "lapsed" },
		npcSolve = { chancePerHour = 0.03, outcome = "locals" },
		cooldownHours = 24,
	},

	-- ─── 2. Water/Life: the failing reservoir ───────────────────────────────
	{
		id = "failing_reservoir", type = "crisis",
		title = "Low Water", summary = "{town_name}'s reservoir is drying out{cause}.",
		giver = "farmer", scope = "shared", situations = { "drought", "ley_shift" },
		weight = 1.2, domains = { "water", "life", "space" }, intensity = 0.5, difficulty = { 0, 8 },
		slots = {
			town = { kind = "settlement", from = "settlementId" },
			well = { kind = "position", pick = "settlementCenter" },
			farmer = { kind = "npc", pick = "colleague:farmer", optional = true },
			priest = { kind = "npc", pick = "colleague:tidepriest", optional = true },
			cause = { kind = "text", from = "causeText" },
		},
		stages = {
			{ id = "save", text = "The wells of {town_name} are failing.", options = {
				{ id = "call", label = "Call water into the reservoir", approach = "magic", requires = { domains = { "water" } },
					objectives = { o("cast", "fill", "Fill the reservoir (water magic at the wells)", { at = "well", radius = 70, amount = 25, match = { domains = { "water" }, verbs = { "generate", "amplify", "redirect" } }, needs = { "water" } }) },
					outcome = "refilled" },
				{ id = "ley", label = "Mend the ley line", approach = "magic", requires = { domains = { "space", "spirit", "void" } },
					objectives = { o("cast", "mend", "Pour arcane power back into the ground", { at = "well", radius = 90, amount = 18, match = { properties = { "aether", "presence", "distance" }, verbs = { "amplify", "redirect", "transfer" } } }) },
					outcome = "ley_mended" },
				{ id = "rite", label = "Bring {priest} to lead the water rite", approach = "talk",
					objectives = { o("talk", "ask", "Ask {priest} for the rite", { target = "priest" }), o("escort", "walk", "Walk {priest} to the wells", { target = "priest", at = "well", radius = 20 }) },
					ordered = true, outcome = "rite" },
				{ id = "hardy", label = "Make the fields need less", approach = "magic", requires = { domains = { "life" } },
					objectives = { o("cast", "tend", "Strengthen the crops around {town_name}", { at = "well", radius = 120, count = 4, match = { domains = { "life" }, properties = { "growth", "vitality" } } }) },
					outcome = "drought_hardy" },
			} },
		},
		outcomes = {
			refilled = { text = "Water rises in the wells. Someone starts singing.", success = true,
				rewards = { xp = { branch = "best:water", amount = 350 }, reputation = { settlement = 30, tide_temple = 40, verdant_circle = 20 } }, world = { relief = "water", prosperity = 2 } },
			ley_mended = { text = "The ground hums again; the springs follow the magic home.", success = true,
				rewards = { xp = { branch = "best:space", amount = 400 }, reputation = { settlement = 30, scholars_league = 30 } }, world = { relief = "water", density = 0.3, prosperity = 2 } },
			rite = { text = "The old rite works, slowly. The priest won't stop telling the story.", success = true,
				rewards = { relationship = 0.2, reputation = { settlement = 20, tide_temple = 60 } }, world = { relief = "water", prosperity = 1 } },
			drought_hardy = { text = "The crops will survive the dry months, even if the wells don't fill.", success = true,
				rewards = { xp = { branch = "best:life", amount = 300 }, reputation = { settlement = 20, verdant_circle = 50 } }, world = { prosperity = 1 } },
			locals = { text = "The town's own water-callers brought the wells back.", success = false },
			dried = { text = "{town_name} rations water, and the fields brown.", success = false, world = { prosperity = -2 } },
		},
		failOutcome = "dried", expireHours = 24,
		escalation = { afterHours = 12, event = "wildfire", text = "The dry fields around {town_name} have caught fire." },
		npcSolve = { chancePerHour = 0.04, outcome = "locals" },
		cooldownHours = 12,
	},

	-- ─── 3. Void: the missing apprentice ────────────────────────────────────
	{
		id = "missing_apprentice", type = "rescue",
		title = "The Quiet Student", summary = "{apprentice} hasn't been seen since they started studying something they shouldn't.",
		giver = "master", scope = "personal", situations = { "forbidden_experiment" },
		weight = 0.9, domains = { "void", "mind", "spirit" }, intensity = 0.7, difficulty = { 2, 8 },
		slots = {
			master = { kind = "npc", pick = "worriedOne" },
			apprentice = { kind = "npc", from = "npcId" },
			study = { kind = "position", pick = "npcHome:apprentice" },
			ruin = { kind = "position", pick = "nearPoi:dungeon,ruined_library" },
			town = { kind = "settlement", from = "settlementId" },
		},
		stages = {
			{ id = "trail", text = "{master} is frightened for {apprentice}.", options = {
				{ id = "ask", label = "Ask around and search their room", approach = "talk",
					objectives = { o("talk", "ask", "Talk to {master}", { target = "master" }), o("reach", "room", "Search {apprentice}'s room", { at = "study", radius = 10, seconds = 5 }) },
					next = "ruin" },
				{ id = "sense", label = "Read the traces they left", approach = "magic",
					objectives = { o("cast", "trace", "Sense what was worked here", { at = "study", radius = 20, count = 1, match = { verbs = { "sense" } } }) },
					next = "ruin" },
			} },
			{ id = "ruin", text = "The trail leads to {ruin_name}. Something there is too quiet.", hours = 24, options = {
				{ id = "unmake", label = "Unmake what they summoned", approach = "magic", requires = { domains = { "void", "spirit" } },
					objectives = { o("reach", "go", "Go to {ruin_name}", { at = "ruin", radius = 40 }), o("cast", "dispel", "Unweave the working", { at = "ruin", radius = 40, amount = 10, match = { properties = { "aether" }, verbs = { "reduce", "bind", "transmute" } }, needs = { "null", "light" } }) },
					ordered = true, outcome = "rescued" },
				{ id = "talk", label = "Talk them down", approach = "talk",
					objectives = { o("reach", "go", "Go to {ruin_name}", { at = "ruin", radius = 40 }), o("talk", "plead", "Talk to {apprentice}", { target = "apprentice" }) },
					ordered = true, outcome = "talked_down" },
				{ id = "drag", label = "Subdue them and carry them home", approach = "force",
					objectives = { o("subdue", "subdue", "Subdue {apprentice} without killing them", { target = "apprentice", share = 0.3 }) },
					outcome = "dragged_home" },
				{ id = "join", label = "Listen to the silence with them", approach = "creative", requires = { domains = { "void" } },
					objectives = { o("reach", "go", "Go to {ruin_name}", { at = "ruin", radius = 40 }), o("cast", "listen", "Work Void magic beside them", { at = "ruin", radius = 40, count = 2, match = { domains = { "void" } } }) },
					ordered = true, outcome = "joined" },
			} },
		},
		outcomes = {
			rescued = { text = "The working comes apart. {apprentice} sleeps for a day, then asks for you.", success = true, memory = "saved_me",
				rewards = { xp = { branch = "best:void", amount = 500 }, relationship = 0.25, reputation = { scholars_league = 40, settlement = 20 } } },
			talked_down = { text = "{apprentice} walks home beside you, ashamed and alive.", success = true, memory = "saved_me",
				rewards = { relationship = 0.3, reputation = { settlement = 25, scholars_league = 20 } } },
			dragged_home = { text = "{apprentice} is home. They won't look at you.", success = true,
				rewards = { relationship = 0.05, reputation = { settlement = 10, island_concord = 15 } } },
			joined = { text = "In the quiet, someone else is listening too. A choir, you think.", success = true,
				rewards = { xp = { branch = "best:void", amount = 600 }, lore = { "primer:void" }, reputation = { hollow_choir = 120, scholars_league = -60 } }, world = { revealFaction = "hollow_choir" }, followUp = "rogue_bounty" },
			lost = { text = "Whatever {apprentice} opened in {ruin_name} closed again, with them inside it for a while. They came back changed.", success = false,
				world = { npcMastery = { npc = "apprentice", branch = "void", delta = 15 } } },
		},
		holds = { apprentice = "ruin" }, -- they are AT the ruin until it ends
		failOutcome = "lost", expireHours = 36,
		escalation = { afterHours = 24, event = "magic_storm", text = "Raw magic is boiling out of {ruin_name}." },
		cooldownHours = 72,
	},

	-- ─── 4. Delivery: the commission ────────────────────────────────────────
	{
		id = "commission_delivery", type = "delivery",
		title = "Supplies for a Commission", summary = "{giver} can't finish their commission without goods from {other_name}.",
		giver = "giver", scope = "personal", situations = { "npc_goal_commission" },
		weight = 1, domains = { "earth", "energy" }, intensity = 0.15, difficulty = { 0, 4 },
		slots = {
			giver = { kind = "npc", from = "npcId" },
			other = { kind = "settlement", from = "otherSettlementId" },
			supplier = { kind = "npc", pick = "colleagueIn:other:merchant,smith,innkeeper" },
			town = { kind = "settlement", from = "settlementId" },
		},
		stages = {
			{ id = "fetch", text = "{giver} needs a crate from {supplier} in {other_name}.", options = {
				{ id = "fetch", label = "Fetch the crate", approach = "talk",
					objectives = { o("talk", "collect", "Collect the crate from {supplier}", { target = "supplier", args = { gives = "crate" } }), o("deliver", "deliver", "Bring the crate to {giver}", { target = "giver", item = "crate" }) },
					ordered = true, outcome = "delivered" },
				{ id = "haggle", label = "Use your League standing", approach = "trade", requires = { reputation = { wayfarer_league = 100 } },
					objectives = { o("talk", "collect", "Collect the crate from {supplier} (they owe the League)", { target = "supplier", args = { gives = "crate" } }), o("deliver", "deliver", "Bring the crate to {giver}", { target = "giver", item = "crate" }) },
					ordered = true, outcome = "delivered_cheap" },
				{ id = "forge", label = "Make the material yourself", approach = "creative", requires = { domains = { "earth" } },
					objectives = { o("cast", "make", "Shape the material at {giver}'s workplace", { target = "giver", radius = 25, count = 2, match = { properties = { "hardness", "purity", "magnetism", "density" }, verbs = { "transmute", "amplify", "generate" } }, needs = { "metal" } }) },
					outcome = "crafted" },
			} },
		},
		outcomes = {
			delivered = { text = "{giver} gets to work at once.", success = true, memory = "helped_me",
				rewards = { currency = 40, relationship = 0.12, reputation = { wayfarer_league = 30, smiths_guild = 15 } } },
			delivered_cheap = { text = "{supplier} grumbles, but the League's word holds.", success = true, memory = "helped_me",
				rewards = { currency = 60, relationship = 0.12, reputation = { wayfarer_league = 15 } } },
			crafted = { text = "{giver} turns the metal over, astonished: better than the shipment.", success = true, memory = "impressed_me",
				rewards = { xp = { branch = "best:earth", amount = 350 }, currency = 40, relationship = 0.2, reputation = { smiths_guild = 50 } } },
			late = { text = "{giver} missed the commission.", success = false, rewards = { relationship = -0.05 } },
		},
		failOutcome = "late", expireHours = 48, cooldownHours = 6,
	},

	-- ─── 5. Escort: the journey ─────────────────────────────────────────────
	{
		id = "escort_journey", type = "escort",
		title = "The Road to {other_name}", summary = "{giver} wants to {goal_text}, but won't travel the road alone.",
		giver = "giver", scope = "personal", situations = { "npc_goal_journey" },
		weight = 0.9, domains = { "air", "space" }, intensity = 0.45, difficulty = { 1, 6 },
		slots = {
			giver = { kind = "npc", from = "npcId" },
			other = { kind = "settlement", from = "otherSettlementId" },
			gate = { kind = "position", pick = "settlementCenter:other" },
			merchant = { kind = "npc", pick = "colleague:merchant", optional = true },
			goal_text = { kind = "text", from = "goalText" },
		},
		stages = {
			{ id = "go", text = "{giver} is packed and nervous.", options = {
				{ id = "walk", label = "Escort them yourself", approach = "force",
					objectives = { o("escort", "walk", "Escort {giver} to {other_name}", { target = "giver", at = "gate", radius = 40 }) }, outcome = "arrived" },
				{ id = "caravan", label = "Buy them a place with a caravan", approach = "trade",
					objectives = { o("pay", "fare", "Pay {merchant} 30 for the fare", { target = "merchant", amount = 30 }) }, outcome = "caravan" },
			} },
		},
		outcomes = {
			arrived = { text = "{giver} made it to {other_name}. They'll talk about the road for years.", success = true, memory = "protected_me",
				rewards = { relationship = 0.25, currency = 30, reputation = { wayfarer_league = 20, settlement = 10 } } },
			caravan = { text = "{giver} rides off with the caravan, waving.", success = true, rewards = { relationship = 0.1, reputation = { wayfarer_league = 15 } } },
			harmed = { text = "{giver} was hurt on the road, on your watch.", success = false, memory = "failed_me", rewards = { relationship = -0.25, reputation = { settlement = -10 } } },
			gave_up = { text = "{giver} unpacked again.", success = false },
		},
		failOutcome = "gave_up", expireHours = 24,
		protect = { "giver" }, protectOutcome = "harmed",
		complications = {
			{ id = "ambush", text = "Two rogues step out of the trees.", afterStage = "go", chance = 0.35, effect = { spawnHostiles = 2, near = "giver" } },
		},
		cooldownHours = 24,
	},

	-- ─── 6. Duel: the proud rival ───────────────────────────────────────────
	{
		id = "duel_challenge", type = "duel",
		title = "A Matter of Pride", summary = "{rival} has heard about you, and doesn't believe it.",
		giver = "rival", scope = "personal", situations = { "proud_rival" },
		weight = 0.8, domains = {}, intensity = 0.6, difficulty = { 1, 8 }, requires = { minTier = 2 }, -- never a duel at Sensing
		slots = { rival = { kind = "npc", from = "npcId" }, town = { kind = "settlement", from = "settlementId" } },
		stages = {
			{ id = "challenge", text = "{rival} stands in your way.", options = {
				{ id = "accept", label = "Accept the challenge", approach = "talk", objectives = { o("talk", "accept", "Tell {rival} you accept", { target = "rival" }) }, next = "duel" },
				{ id = "decline", label = "Walk away", approach = "wait", objectives = { o("wait", "leave", "Let it go", { hours = 2 }) }, outcome = "declined" },
			} },
			{ id = "duel", text = "Fight {rival} until one of you yields. Nobody dies today.", hours = 6, failOnDeath = "lost", options = {
				{ id = "fight", label = "Win the duel", approach = "force", objectives = { o("subdue", "win", "Make {rival} yield", { target = "rival", share = 0.3 }) }, outcome = "won" },
				{ id = "trick", label = "Win by misdirection", approach = "creative", requires = { domains = { "mind" } },
					objectives = { o("cast", "trick", "Cloud {rival}'s senses", { target = "rival", radius = 25, count = 1, match = { properties = { "illusion", "emotion", "perception" } } }), o("subdue", "win", "Make {rival} yield", { target = "rival", share = 0.3 }) },
					ordered = true, outcome = "won_dirty" },
			} },
		},
		outcomes = {
			won = { text = "{rival} yields, breathing hard, and laughs. \"Again, someday.\"", success = true, memory = "beat_me_fairly",
				rewards = { xp = { branch = "best:any", amount = 300 }, relationship = 0.15, reputation = { settlement = 15 } } },
			won_dirty = { text = "{rival} yields, but knows exactly what you did.", success = true, memory = "cheated_me",
				rewards = { xp = { branch = "best:mind", amount = 300 }, relationship = -0.15, reputation = { settlement = -5 } } },
			lost = { text = "{rival} helps you up. \"Not today.\"", success = false, memory = "beat_me", rewards = { relationship = 0.05 } },
			declined = { text = "{rival} tells everyone you were scared.", success = false, rewards = { relationship = -0.05, reputation = { settlement = -3 } } },
		},
		failOutcome = "declined", expireHours = 12, cooldownHours = 48,
	},

	-- ─── 7. Teaching: the apprenticeship arc ────────────────────────────────
	{
		id = "apprenticeship", type = "teaching",
		title = "A Student of {branch_name}", summary = "{student} wants to learn {branch_name}, and you know it better than anyone near.",
		giver = "student", scope = "personal", situations = { "wants_teacher" },
		weight = 0.8, domains = {}, intensity = 0.1, difficulty = { 3, 8 }, requires = { minTier = 3 },
		slots = { student = { kind = "npc", from = "npcId" }, branch = { kind = "branch", from = "branch" }, town = { kind = "settlement", from = "settlementId" } },
		stages = {
			{ id = "lessons", text = "Teach {student} {branch_name}: show them, over several days.", options = {
				{ id = "teach", label = "Give three lessons", approach = "magic",
					objectives = { o("demonstrate", "lessons", "Demonstrate {branch_name} near {student}", { target = "student", branch = "branch", count = 3, spacingHours = 4, radius = 20 }) },
					next = "test" },
			} },
			{ id = "test", text = "{student} is ready to try it alone.", options = {
				{ id = "watch", label = "Watch their first working", approach = "talk",
					objectives = { o("wait", "practise", "Let them practise", { hours = 2 }), o("talk", "test", "Watch {student} try", { target = "student" }) },
					ordered = true, outcome = "taught" },
				{ id = "alone", label = "Let them find it alone", approach = "wait",
					objectives = { o("wait", "alone", "Give {student} a day to struggle", { hours = 24 }) }, outcome = "self_taught" },
			} },
		},
		outcomes = {
			taught = { text = "{student}'s first working holds. They look at you like you hung the moon.", success = true, memory = "taught_me",
				rewards = { xp = { branch = "branch", amount = 600 }, relationship = 0.35, reputation = { settlement = 20, scholars_league = 20 } },
				world = { npcMastery = { npc = "student", branch = "branch", delta = 12 }, awakenNpc = "student" } },
			self_taught = { text = "{student} gets there on their own, and is prouder for it. They still credit you.", success = true, memory = "taught_me",
				rewards = { xp = { branch = "branch", amount = 300 }, relationship = 0.2 }, world = { npcMastery = { npc = "student", branch = "branch", delta = 8 } } },
			drifted = { text = "{student} found another teacher.", success = false, rewards = { relationship = -0.05 } },
		},
		failOutcome = "drifted", expireHours = 120, cooldownHours = 72,
	},

	-- ─── 8. Research: the lost technique ────────────────────────────────────
	{
		id = "lost_technique", type = "research",
		title = "The Missing Treatise", summary = "Nobody alive teaches {branch_name}. Somewhere, someone wrote it down.",
		giver = "scholar", scope = "personal", situations = { "lore_gap" },
		weight = 1.1, domains = {}, intensity = 0.25, difficulty = { 2, 8 },
		slots = {
			branch = { kind = "branch", from = "branch" },
			scholar = { kind = "npc", pick = "anywhere:scholar" },
			library = { kind = "position", pick = "nearPoi:ruined_library,academy" },
		},
		stages = {
			{ id = "search", text = "Find the treatise on {branch_name}.", options = {
				{ id = "archive", label = "Search the ruined archive", approach = "magic",
					objectives = { o("reach", "go", "Search {library_name}", { at = "library", radius = 35, seconds = 30 }), o("cast", "read", "Sense the right shelf", { at = "library", radius = 35, count = 1, match = { verbs = { "sense" } } }) },
					ordered = true, outcome = "found" },
				{ id = "trade", label = "Buy a copy from {scholar}", approach = "trade",
					objectives = { o("talk", "ask", "Ask {scholar}", { target = "scholar" }), o("pay", "buy", "Pay {scholar} 80", { target = "scholar", amount = 80 }) }, ordered = true, outcome = "bought" },
				{ id = "derive", label = "Work it out yourself", approach = "creative",
					objectives = { o("cast", "experiment", "Experiment with {branch_name}'s parent art at {library_name}", { at = "library", radius = 35, count = 6, match = { branches = { "{branch_parent}" } } }) },
					outcome = "derived" },
			} },
		},
		outcomes = {
			found = { text = "Under rot and rubble, the treatise. Half of it is still legible.", success = true,
				rewards = { lore = { "treatise:{branch}" }, xp = { branch = "best:any", amount = 200 }, reputation = { scholars_league = 30 } } },
			bought = { text = "{scholar} copies it out for you, muttering about the price of ink.", success = true,
				rewards = { lore = { "treatise:{branch}" }, reputation = { scholars_league = 20 } } },
			derived = { text = "You work out from first principles what the treatise would have said.", success = true,
				rewards = { lore = { "treatise:{branch}" }, xp = { branch = "{branch_parent}", amount = 600 }, reputation = { scholars_league = 60 } } },
			cold = { text = "The trail went cold.", success = false },
		},
		failOutcome = "cold", expireHours = 96, cooldownHours = 24,
	},

	-- ─── 9. Earth crisis: the tremors ───────────────────────────────────────
	{
		id = "calm_tremors", type = "crisis",
		title = "The Ground Is Restless", summary = "Pressure is building under {town_name}. The next quake could level it.",
		scope = "shared", situations = { "tremors" },
		weight = 1, domains = { "earth", "gravity" }, intensity = 0.65, difficulty = { 2, 8 },
		slots = { town = { kind = "settlement", from = "settlementId" }, fault = { kind = "position", from = "here" }, centre = { kind = "position", pick = "settlementCenter" }, official = { kind = "npc", pick = "colleague:guard", optional = true } },
		stages = {
			{ id = "calm", text = "Ease the strain beneath {town_name}, or get people ready.", options = {
				{ id = "release", label = "Bleed the stress out gently", approach = "magic", requires = { domains = { "earth" } },
					objectives = { o("cast", "ease", "Gentle seismic magic at the fault (power 4 or less)", { at = "fault", radius = 90, amount = 12, match = { properties = { "seismicity" }, verbs = { "reduce" }, maxPower = 4 } }) },
					outcome = "eased" },
				{ id = "brace", label = "Brace the town", approach = "magic", requires = { domains = { "earth" } },
					objectives = { o("cast", "brace", "Raise three supports in {town_name}", { at = "centre", radius = 140, count = 3, match = CONSTRUCT }) }, outcome = "braced" },
				{ id = "evacuate", label = "Warn the town", approach = "talk",
					objectives = { o("talk", "warn", "Warn {official}", { target = "official" }), o("wait", "clear", "Help clear the streets", { hours = 1 }) }, ordered = true, outcome = "evacuated" },
				{ id = "trigger", label = "Set it off now, on your terms", approach = "force",
					objectives = { o("cast", "trigger", "Strong seismic magic at the fault", { at = "fault", radius = 90, count = 1, match = { properties = { "seismicity" }, minPower = 6 } }) }, outcome = "triggered" },
			} },
		},
		outcomes = {
			eased = { text = "The ground settles with a long sigh. Dogs stop barking.", success = true,
				rewards = { xp = { branch = "best:earth", amount = 450 }, reputation = { settlement = 30, island_concord = 30, smiths_guild = 20 } }, world = { stress = -0.4 } },
			braced = { text = "When the shake comes, your stone holds the old houses up.", success = true,
				rewards = { xp = { branch = "best:earth", amount = 350 }, reputation = { settlement = 25, island_concord = 20 } }, world = { stress = -0.15 } },
			evacuated = { text = "The streets are empty when the ground moves. Nobody is hurt.", success = true, rewards = { reputation = { settlement = 20, island_concord = 30 } } },
			triggered = { text = "The quake comes early and smaller. It still cracks walls, and people know who did it.", success = false,
				rewards = { reputation = { settlement = -20 }, infamy = 5 }, world = { stress = -0.6, prosperity = -1 } },
			settled = { text = "The strain eased on its own.", success = false },
			shook = { text = "The quake came, and {town_name} took the worst of it.", success = false, world = { prosperity = -2, stress = 0.2 } },
		},
		failOutcome = "shook", expireHours = 30,
		escalation = { afterHours = 20, text = "Small quakes are rattling {town_name}.", outcome = "shook" },
		npcSolve = { chancePerHour = 0.02, outcome = "settled" },
		cooldownHours = 24,
	},

	-- ─── 10. Water crisis: the flood ────────────────────────────────────────
	{
		id = "stop_flood", type = "crisis",
		title = "Rising Water", summary = "The sea is coming into {town_name}.",
		scope = "shared", situations = { "flood" },
		weight = 1, domains = { "water", "earth", "air" }, intensity = 0.8, difficulty = { 2, 8 },
		slots = { town = { kind = "settlement", from = "settlementId" }, shore = { kind = "position", from = "here" }, priest = { kind = "npc", pick = "colleague:tidepriest", optional = true } },
		stages = {
			{ id = "hold", text = "Hold the water back from {town_name}.", options = {
				{ id = "wall", label = "Raise a sea wall", approach = "magic", requires = { domains = { "earth" } },
					objectives = { o("cast", "wall", "Raise three walls along the shore", { at = "shore", radius = 160, count = 3, match = { forms = { "wall" } }, needs = { "stone" } }) }, outcome = "walled" },
				{ id = "freeze", label = "Freeze the surge", approach = "magic", requires = { domains = { "water" } },
					objectives = { o("cast", "freeze", "Freeze the incoming water", { at = "shore", radius = 160, amount = 20, match = { properties = { "phase", "temperature" }, verbs = { "reduce" } }, needs = { "ice", "cold" } }) }, outcome = "frozen" },
				{ id = "turn", label = "Turn the tide", approach = "magic", requires = { domains = { "water", "air" } },
					objectives = { o("cast", "turn", "Redirect the flow back to sea", { at = "shore", radius = 160, amount = 22, match = { properties = { "flow", "pressure" }, verbs = { "redirect", "reduce" } }, needs = { "dry", "wind" } }) }, outcome = "turned" },
			} },
		},
		outcomes = {
			walled = { text = "The water hits your wall and breaks.", success = true, rewards = { xp = { branch = "best:earth", amount = 450 }, reputation = { settlement = 40, tide_temple = 20, island_concord = 30 } } },
			frozen = { text = "The surge freezes in a jagged wave, glittering over the rooftops.", success = true, rewards = { xp = { branch = "best:water", amount = 450 }, reputation = { settlement = 40, tide_temple = 40 } } },
			turned = { text = "The water turns, sullen, and goes back to the sea.", success = true, rewards = { xp = { branch = "best:water", amount = 450 }, reputation = { settlement = 40, tide_temple = 50 } } },
			receded = { text = "The water went back down on its own, leaving mud everywhere.", success = false },
			flooded = { text = "{town_name}'s lower streets are under water.", success = false, world = { prosperity = -2 } },
		},
		failOutcome = "flooded", expireHours = 15,
		npcSolve = { chancePerHour = 0.05, outcome = "receded" },
		cooldownHours = 12,
	},

	-- ─── 11. Diplomacy: the dispute ─────────────────────────────────────────
	{
		id = "settlement_dispute", type = "diplomacy",
		title = "Bad Blood", summary = "{town_name} and {other_name} are a few insults from open trouble.",
		giver = "envoyA", scope = "personal", situations = { "dispute" },
		weight = 0.8, domains = { "mind" }, intensity = 0.35, difficulty = { 0, 8 },
		slots = {
			town = { kind = "settlement", from = "settlementId" },
			other = { kind = "settlement", from = "otherSettlementId" },
			envoyA = { kind = "npc", pick = "colleague:guard" },
			envoyB = { kind = "npc", pick = "colleagueIn:other:guard" },
		},
		stages = {
			{ id = "hear", text = "{envoyA} wants someone neutral to carry words.", options = {
				{ id = "listen", label = "Hear {town_name}'s side", approach = "talk", objectives = { o("talk", "hear", "Talk to {envoyA}", { target = "envoyA", args = { gives = "terms" } }) }, next = "broker" },
			} },
			{ id = "broker", text = "Carry {town_name}'s words to {envoyB} in {other_name}.", hours = 48, options = {
				{ id = "broker", label = "Broker a peace", approach = "talk",
					objectives = { o("deliver", "terms", "Give {envoyB} the terms", { target = "envoyB", item = "terms", args = { gives = "reply" } }), o("deliver", "reply", "Bring the reply to {envoyA}", { target = "envoyA", item = "reply" }) },
					ordered = true, outcome = "peace" },
				{ id = "soothe", label = "Soften their tempers with magic", approach = "creative", requires = { domains = { "mind" } },
					objectives = { o("cast", "calm", "Calm {envoyB}", { target = "envoyB", radius = 20, count = 1, match = { properties = { "emotion" }, verbs = { "reduce" } } }), o("deliver", "terms", "Give {envoyB} the terms", { target = "envoyB", item = "terms" }) },
					ordered = true, outcome = "peace_magic" },
				{ id = "side", label = "Deliver an ultimatum instead", approach = "force",
					objectives = { o("deliver", "ultimatum", "Give {envoyB} {town_name}'s ultimatum", { target = "envoyB", item = "terms" }) }, outcome = "ultimatum" },
			} },
		},
		outcomes = {
			peace = { text = "Two towns that hated each other now merely dislike each other. That's diplomacy.", success = true,
				rewards = { reputation = { island_concord = 60, wayfarer_league = 40, settlement = 25 } }, world = { relation = 0.25 } },
			peace_magic = { text = "Peace, of a kind. {envoyB} doesn't quite remember agreeing.", success = true,
				rewards = { reputation = { island_concord = 30, scholars_league = -40, settlement = 15 } }, world = { relation = 0.2 } },
			ultimatum = { text = "{other_name} took the ultimatum badly.", success = true,
				rewards = { reputation = { settlement = 40, island_concord = -20 } }, world = { relation = -0.25 } },
			stalled = { text = "The words were never carried. The grudge grew.", success = false, world = { relation = -0.1 } },
		},
		failOutcome = "stalled", expireHours = 72, cooldownHours = 48,
	},

	-- ─── 12. Heist: the ledger ──────────────────────────────────────────────
	{
		id = "guild_heist", type = "heist",
		title = "The Other Ledger", summary = "{client} needs a ledger from {mark}'s workshop, and nobody can know.",
		giver = "client", scope = "personal", situations = { "debt_trouble" },
		weight = 0.6, domains = { "mind", "void" }, intensity = 0.55, difficulty = { 1, 8 },
		slots = {
			client = { kind = "npc", from = "npcId" },
			mark = { kind = "npc", pick = "colleague:smith,merchant" },
			vault = { kind = "position", pick = "npcWork:mark" },
			official = { kind = "npc", pick = "colleague:guard", optional = true },
			town = { kind = "settlement", from = "settlementId" },
		},
		stages = {
			{ id = "pitch", text = "{client} pulls you aside.", options = {
				{ id = "hear", label = "Hear the job", approach = "talk", objectives = { o("talk", "hear", "Talk to {client}", { target = "client" }) }, next = "job" },
			} },
			{ id = "job", text = "Get the ledger from {mark}'s workshop.", hours = 24, options = {
				{ id = "sneak", label = "Slip in unseen", approach = "stealth",
					objectives = { o("collect", "ledger", "Take the ledger unseen", { at = "vault", radius = 6, seconds = 4, item = "ledger", unseen = true, onNoticed = "caught" }), o("deliver", "hand", "Give the ledger to {client}", { target = "client", item = "ledger" }) },
					ordered = true, outcome = "clean" },
				{ id = "con", label = "Talk your way in", approach = "talk",
					objectives = { o("talk", "chat", "Distract {mark}", { target = "mark" }), o("pay", "bribe", "Grease {mark}'s palm (50)", { target = "mark", amount = 50 }), o("collect", "ledger", "Take the ledger", { at = "vault", radius = 6, seconds = 2, item = "ledger" }), o("deliver", "hand", "Give the ledger to {client}", { target = "client", item = "ledger" }) },
					ordered = true, outcome = "conned" },
				{ id = "report", label = "Report {client} to the watch", approach = "talk",
					objectives = { o("talk", "report", "Tell {official} everything", { target = "official" }) }, outcome = "betrayed" },
			} },
		},
		outcomes = {
			clean = { text = "{client} takes the ledger with shaking hands. Nobody saw a thing.", success = true, memory = "owes_me",
				rewards = { currency = 120, relationship = 0.3, infamy = 3 } },
			conned = { text = "{mark} never knew. Probably.", success = true, rewards = { currency = 70, relationship = 0.2 } },
			caught = { text = "A shout. Torches. The watch wants a word with you.", success = false, memory = "used_me",
				rewards = { reputation = { smiths_guild = -120, settlement = -25 }, infamy = 20, bounty = { faction = "island_concord", amount = 150 } } },
			betrayed = { text = "The watch arrests {client}. {mark} sends a thank-you basket.", success = true, memory = "betrayed_me",
				rewards = { currency = 40, relationship = -0.5, reputation = { island_concord = 60, smiths_guild = 40 } } },
			cold_feet = { text = "{client} found someone else.", success = false },
		},
		failOutcome = "cold_feet", expireHours = 36, cooldownHours = 72,
	},

	-- ─── 13. Mythic: the breadcrumbs ────────────────────────────────────────
	{
		id = "mythic_breadcrumbs", type = "mythic",
		title = "Something Older", summary = "{keeper} speaks of {mythic_name} as if it were a person who left.",
		giver = "keeper", scope = "personal", situations = { "mythic_trail" },
		weight = 0.5, domains = { "time", "gravity", "reality", "spirit" }, intensity = 0.3, difficulty = { 0, 8 },
		slots = {
			mythic = { kind = "domain", from = "domain" },
			keeper = { kind = "npc", pick = "elder:{mythic}" },
			tower = { kind = "position", pick = "nearPoi:hermit_tower" },
			shrine = { kind = "position", pick = "nearPoi:ruined_library,quiet_place,sunken_shrine" },
			fragment = { kind = "branch", pick = "mythicSubBranch:{mythic}" },
		},
		stages = {
			{ id = "whisper", text = "Old {keeper} has something to tell you, if you sit.", options = {
				{ id = "sit", label = "Sit and listen", approach = "talk", objectives = { o("talk", "listen", "Listen to {keeper}", { target = "keeper" }) }, next = "tower" },
			} },
			{ id = "tower", text = "{keeper} says the first mark is at {tower_name}.", options = {
				{ id = "climb", label = "Find the mark", approach = "wait", objectives = { o("reach", "mark", "Spend a minute at {tower_name}", { at = "tower", radius = 40, seconds = 60 }) }, next = "moment" },
			} },
			{ id = "moment", text = "The last mark only shows at the right moment.", options = {
				{ id = "witness", label = "Be there when the world opens", approach = "wait",
					objectives = { o("witness", "moment", "Be at {shrine_name} during the right sky", { at = "shrine", radius = 120, event = "{mythic_moment}" }) }, outcome = "fragment" },
				{ id = "night", label = "Keep a long night vigil", approach = "wait",
					objectives = { o("state", "night", "Wait for full night", { predicate = "night" }), o("reach", "vigil", "Hold a vigil at {shrine_name}", { at = "shrine", radius = 40, seconds = 180 }) },
					ordered = true, outcome = "fragment_slow" },
			} },
		},
		outcomes = {
			fragment = { text = "For a heartbeat you see it whole. You'll spend years remembering it.", success = true,
				rewards = { lore = { "fragment:{fragment}", "hint:{mythic}:quest" }, awakening = { domain = "{mythic}", chance = 0.2 }, reputation = { seam_keepers = 80 } },
				world = { revealFaction = "seam_keepers", notoriety = 10 } },
			fragment_slow = { text = "Near dawn, something answers. Faintly.", success = true,
				rewards = { lore = { "fragment:{fragment}", "hint:{mythic}:quest" }, awakening = { domain = "{mythic}", chance = 0.08 }, reputation = { seam_keepers = 60 } },
				world = { revealFaction = "seam_keepers" } },
			faded = { text = "The trail fades. It'll come back, someday, for someone.", success = false },
		},
		failOutcome = "faded", expireHours = 240,
		complications = { { id = "watchers", text = "Someone has been following you since the tower.", afterStage = "moment", chance = 0.25, effect = { spawnHostiles = 1, faction = "quiet_hand", near = "player" } } },
		cooldownHours = 168,
	},

	-- ─── 14. Hunt: the rogue ────────────────────────────────────────────────
	{
		id = "rogue_bounty", type = "hunt",
		title = "Contract: {rogue}", summary = "The Lodge has a contract on {rogue}, a mage gone wrong.",
		giver = "lodge", scope = "personal", situations = { "rogue_mage" },
		weight = 0.8, domains = { "air", "life" }, intensity = 0.6, difficulty = { 2, 8 },
		slots = { rogue = { kind = "npc", from = "npcId" }, lodge = { kind = "npc", pick = "colleague:hunter,guard" }, town = { kind = "settlement", from = "settlementId" } },
		stages = {
			{ id = "contract", text = "{lodge} has the contract.", options = {
				{ id = "take", label = "Take the contract", approach = "talk", objectives = { o("talk", "take", "Talk to {lodge}", { target = "lodge" }) }, next = "confront" },
			} },
			{ id = "confront", text = "Find {rogue}. How it ends is up to you.", hours = 48, options = {
				{ id = "bring", label = "Bring them in", approach = "force", objectives = { o("subdue", "subdue", "Subdue {rogue}", { target = "rogue", share = 0.3 }) }, outcome = "brought_in" },
				{ id = "persuade", label = "Persuade them to surrender", approach = "talk", requires = { reputation = { hunters_lodge = 0 } },
					objectives = { o("talk", "talk", "Talk to {rogue}", { target = "rogue" }), o("talk", "report", "Tell {lodge} they'll come quietly", { target = "lodge" }) }, ordered = true, outcome = "surrendered" },
				{ id = "warn", label = "Warn them to run", approach = "talk", objectives = { o("talk", "warn", "Warn {rogue}", { target = "rogue" }) }, outcome = "warned" },
			} },
		},
		outcomes = {
			brought_in = { text = "{rogue} is in the Lodge's cells. The contract pays.", success = true, rewards = { currency = 100, reputation = { hunters_lodge = 80, island_concord = 30 } } },
			surrendered = { text = "{rogue} walks in on their own. The Lodge is impressed.", success = true, memory = "spared_me", rewards = { currency = 80, reputation = { hunters_lodge = 60, island_concord = 20 } } },
			warned = { text = "{rogue} is gone by morning. The Lodge suspects you.", success = false, memory = "spared_me", rewards = { reputation = { hunters_lodge = -60, hollow_choir = 40 } } },
			escaped = { text = "{rogue} slipped away.", success = false, rewards = { reputation = { hunters_lodge = -10 } } },
		},
		failOutcome = "escaped", expireHours = 72, cooldownHours = 48,
	},

	-- ─── 15. Fire crisis ────────────────────────────────────────────────────
	{
		id = "wildfire_response", type = "crisis",
		title = "Firefront", summary = "A wildfire is racing toward {town_name}.",
		scope = "shared", situations = { "wildfire" },
		weight = 1.2, domains = { "water", "earth", "air" }, intensity = 0.85, difficulty = { 1, 8 },
		slots = { town = { kind = "settlement", from = "settlementId" }, fire = { kind = "position", from = "here" } },
		stages = {
			{ id = "fight", text = "Stop the fire before it reaches {town_name}.", options = {
				{ id = "douse", label = "Douse it", approach = "magic", requires = { domains = { "water" } },
					objectives = { o("cast", "douse", "Water on the fire", { at = "fire", radius = 200, amount = 22, match = { domains = { "water" } }, needs = { "water", "cold", "ice" } }) }, outcome = "doused" },
				{ id = "break", label = "Cut a firebreak", approach = "magic", requires = { domains = { "earth" } },
					objectives = { o("cast", "break", "Raise walls or turn the earth in the fire's path", { at = "fire", radius = 200, count = 3, match = { domains = { "earth" }, properties = EARTH_SHAPING }, needs = { "stone" } }) }, outcome = "firebreak" },
				{ id = "wind", label = "Turn the wind (risky)", approach = "magic", requires = { domains = { "air" } },
					objectives = { o("cast", "wind", "Push the wind back over the burned ground", { at = "fire", radius = 200, amount = 18, match = { domains = { "air" }, verbs = { "redirect" } } }) }, outcome = "turned" },
				{ id = "out", label = "Hold until it's out", approach = "wait", objectives = { o("state", "out", "The fire is out", { predicate = "eventEnded" }) }, outcome = "burned_out" },
			} },
		},
		outcomes = {
			doused = { text = "Steam where flames were. The woods will grow back.", success = true, rewards = { xp = { branch = "best:water", amount = 400 }, reputation = { settlement = 35, verdant_circle = 50, skywardens = 20 } }, world = { endEvent = true } },
			firebreak = { text = "The fire reaches your break and starves.", success = true, rewards = { xp = { branch = "best:earth", amount = 400 }, reputation = { settlement = 35, verdant_circle = 30 } }, world = { endEvent = true } },
			turned = { text = "The fire turns back into its own ashes.", success = true, rewards = { xp = { branch = "best:air", amount = 400 }, reputation = { settlement = 30, skywardens = 50 } }, world = { endEvent = true } },
			burned_out = { text = "The fire burned out. The forest didn't.", success = false },
			razed = { text = "The fire reached {town_name}'s edges.", success = false, world = { prosperity = -2 } },
		},
		failOutcome = "razed", expireHours = 20,
		cooldownHours = 6,
	},

	-- ─── 16. Life crisis: the plague ────────────────────────────────────────
	{
		id = "plague_relief", type = "crisis",
		title = "The Coughing Sickness", summary = "Sickness is spreading through {town_name}.",
		scope = "shared", situations = { "plague" },
		weight = 1, domains = { "life", "water", "spirit" }, intensity = 0.55, difficulty = { 1, 8 },
		slots = { town = { kind = "settlement", from = "settlementId" }, clinic = { kind = "position", pick = "settlementCenter" }, herbalist = { kind = "npc", pick = "colleague:herbalist,healer", optional = true }, grove = { kind = "position", pick = "nearPoi:hollow_grove,shrine_life" } },
		stages = {
			{ id = "treat", text = "Help {town_name} through the sickness.", options = {
				{ id = "heal", label = "Heal the sick", approach = "magic", requires = { domains = { "life" } },
					objectives = { o("cast", "heal", "Heal people in {town_name}", { at = "clinic", radius = 150, count = 5, match = { routes = { "restore", "cleanse" } }, needs = { "life" } }) }, outcome = "cured" },
				{ id = "purify", label = "Purify the water", approach = "magic", requires = { domains = { "water", "earth" } },
					objectives = { o("cast", "purify", "Cleanse the town's water", { at = "clinic", radius = 150, amount = 12, match = { properties = { "purity", "toxin" }, verbs = { "reduce", "transmute", "amplify" } } }) }, outcome = "purified" },
				{ id = "remedy", label = "Fetch the remedy", approach = "talk",
					objectives = { o("talk", "ask", "Ask {herbalist} what's needed", { target = "herbalist" }), o("collect", "herb", "Gather the herb at {grove_name}", { at = "grove", radius = 40, seconds = 10, item = "herb" }), o("deliver", "bring", "Bring it to {herbalist}", { target = "herbalist", item = "herb" }) },
					ordered = true, outcome = "remedy" },
			} },
		},
		outcomes = {
			cured = { text = "The coughing fades street by street.", success = true, rewards = { xp = { branch = "best:life", amount = 450 }, reputation = { settlement = 40, verdant_circle = 50 } }, world = { endEvent = true } },
			purified = { text = "It was the water all along. Clean water, and the sickness starves.", success = true, rewards = { xp = { branch = "best:water", amount = 400 }, reputation = { settlement = 35, tide_temple = 30 } }, world = { endEvent = true } },
			remedy = { text = "The remedy works, slowly and bitterly.", success = true, rewards = { relationship = 0.2, reputation = { settlement = 30, verdant_circle = 40 } }, world = { endEvent = true } },
			passed = { text = "The sickness ran its course.", success = false },
			ravaged = { text = "{town_name} buried more people than anyone will talk about.", success = false, world = { prosperity = -3 } },
		},
		failOutcome = "ravaged", expireHours = 30,
		npcSolve = { chancePerHour = 0.04, outcome = "passed" },
		cooldownHours = 12,
	},

	-- ─── 17. Atonement: the bounty ──────────────────────────────────────────
	{
		id = "atonement", type = "atonement",
		title = "Settling Accounts", summary = "There's a bounty on you in {town_name}.",
		giver = "official", scope = "personal", situations = { "wanted" },
		weight = 1.5, domains = {}, intensity = 0.3, difficulty = { 0, 8 },
		slots = { town = { kind = "settlement", from = "settlementId" }, official = { kind = "npc", pick = "colleague:guard" }, fine = { kind = "number", from = "bounty" } },
		stages = {
			{ id = "settle", text = "The watch of {town_name} wants you to answer for what you did.", options = {
				{ id = "pay", label = "Pay the fine ({fine})", approach = "trade",
					objectives = { o("talk", "surrender", "Present yourself to {official}", { target = "official" }), o("pay", "pay", "Pay {fine}", { target = "official", args = { amountSlot = "fine" } }) }, ordered = true, outcome = "paid" },
				{ id = "serve", label = "Work it off", approach = "magic",
					objectives = { o("cast", "help", "Help around {town_name} (healing, building, mending)", { at = "town", radius = 200, count = 6, match = { harmful = false } }), o("talk", "report", "Report to {official}", { target = "official" }) }, ordered = true, outcome = "served" },
			} },
		},
		outcomes = {
			paid = { text = "{official} takes the coin and strikes your name from the board.", success = true, rewards = { reputation = { island_concord = 40, settlement = 10 } }, world = { clearBounty = true } },
			served = { text = "After a week of mending fences, {town_name} decides you're tolerable.", success = true, rewards = { reputation = { island_concord = 60, settlement = 25 } }, world = { clearBounty = true } },
			fled = { text = "You didn't answer. The bounty stands, and grows.", success = false, rewards = { infamy = 5 } },
		},
		failOutcome = "fled", expireHours = 48, cooldownHours = 2,
	},

	-- ─── 18. Hunted: the Quiet Hand ─────────────────────────────────────────
	{
		id = "hunted_by_hand", type = "hunted",
		title = "Quiet Footsteps", summary = "People who don't want {mythic_name} in the world have found you.",
		scope = "personal", situations = { "mythic_notoriety" }, autoStart = true,
		weight = 2, domains = { "time", "gravity", "reality" }, intensity = 0.9, difficulty = { 0, 8 },
		slots = { mythic = { kind = "domain", from = "domain" }, refuge = { kind = "position", pick = "nearPoi:shrine_spirit,sunken_shrine,academy" } },
		spawns = { hunter = { faction = "quiet_hand", near = "player", fight = true } },
		stages = {
			{ id = "hunted", text = "A stranger has been following you. They aren't hiding it any more.", hours = 4, options = {
				{ id = "fight", label = "Fight", approach = "force", objectives = { o("subdue", "beat", "Defeat the hunter", { target = "hunter", share = 0.3 }) }, outcome = "repelled" },
				{ id = "flee", label = "Reach sanctuary", approach = "stealth", objectives = { o("reach", "refuge", "Get to {refuge_name}", { at = "refuge", radius = 40 }) }, outcome = "escaped" },
				{ id = "parley", label = "Talk to them", approach = "talk", objectives = { o("talk", "parley", "Talk to the hunter", { target = "hunter" }) }, outcome = "parley" },
			} },
		},
		outcomes = {
			repelled = { text = "The hunter yields and melts away. There will be others.", success = true, rewards = { reputation = { quiet_hand = -40 } }, world = { revealFaction = "quiet_hand", notoriety = -10 } },
			escaped = { text = "They won't follow you in here. For now.", success = true, world = { notoriety = -15 } },
			parley = { text = "\"Keep it small,\" the hunter says, \"and we'll keep our distance.\"", success = true,
				rewards = { reputation = { quiet_hand = 60 } }, world = { revealFaction = "quiet_hand", notoriety = -25 } },
			caught = { text = "They caught up with you. You wake up somewhere else, poorer and warned.", success = false, rewards = { currency = -50 }, world = { notoriety = -10 } },
		},
		failOutcome = "caught", expireHours = 6, cooldownHours = 24,
	},

	-- ─── First hour (docs/EarlyGamePlan.md item 4) ──────────────────────────
	-- Small personal goals around your nearest town, only while your best branch is below Adept
	-- (requires.maxTier = 2) and one at a time (`beginner`). Each has a way through for any domain.

	-- B1. The practice yard: hit the straw dummies (PracticeTarget: never a crime).
	{
		id = "first_practice", type = "training", beginner = true,
		title = "Practice Yard", summary = "The straw dummies in {town_name}'s practice yard are there to be hit. Nobody minds.",
		scope = "personal", situations = { "beginner" },
		weight = 1.6, domains = {}, intensity = 0.1, difficulty = { 1, 2 }, requires = { maxTier = 2 },
		slots = { town = { kind = "settlement", from = "settlementId" }, yard = { kind = "position", pick = "tagged:PracticeYard" } },
		stages = {
			{ id = "practise", text = "Land five spells on the dummies in {yard_name}.", options = {
				{ id = "spells", label = "Hit the dummies with magic", approach = "magic",
					objectives = { o("cast", "hits", "Hit the training dummies with harmful magic", { at = "yard", radius = 16, count = 5, match = { harmful = true } }) },
					outcome = "practised" },
				{ id = "watch", label = "Watch the regulars train", approach = "wait",
					objectives = { o("reach", "watch", "Watch from {yard_name}", { at = "yard", radius = 16, seconds = 60 }) },
					outcome = "watched" },
			} },
		},
		outcomes = {
			practised = { text = "Five clean hits. The straw is scorched and your aim a little steadier.", success = true,
				rewards = { xp = { branch = "best:any", amount = 150 } } },
			watched = { text = "You pick up a few habits just by watching.", success = true, rewards = { xp = { branch = "best:any", amount = 40 } } },
			drifted = { text = "The dummies will still be there.", success = false },
		},
		failOutcome = "drifted", expireHours = 24, cooldownHours = 12,
	},

	-- B2. Light the lamps at dusk: heat or light near the plaza, or help carry the oil.
	{
		id = "light_the_lamps", type = "chore", beginner = true,
		title = "Lamps at Dusk", summary = "Dusk in {town_name}, and the plaza lamps are still dark.",
		scope = "personal", situations = { "beginner_dusk" },
		weight = 1.2, domains = { "energy" }, intensity = 0.1, difficulty = { 1, 2 }, requires = { maxTier = 2 },
		slots = { town = { kind = "settlement", from = "settlementId" }, centre = { kind = "position", pick = "settlementCenter" } },
		stages = {
			{ id = "light", text = "Light the lamps around the plaza of {town_name}.", options = {
				{ id = "magic", label = "Light them with magic", approach = "magic",
					objectives = { o("cast", "light", "Cast light or heat near the plaza lamps", { at = "centre", radius = 50, count = 3, anyEffect = true,
						match = { properties = { "luminosity", "temperature", "combustion" } }, needs = { "light", "fire", "heat", "lightning" } }) },
					outcome = "lit" },
				{ id = "help", label = "Help carry the oil", approach = "talk",
					objectives = { o("reach", "plaza", "Go to the plaza of {town_name}", { at = "centre", radius = 40, seconds = 20 }), o("wait", "carry", "Carry oil round the lamps", { hours = 1 }) },
					ordered = true, outcome = "helped" },
			} },
		},
		outcomes = {
			lit = { text = "One by one the plaza lamps catch. Someone claps.", success = true,
				rewards = { xp = { branch = "best:any", amount = 120 }, reputation = { settlement = 5 } } },
			helped = { text = "Oil-stained hands, and a plaza full of light.", success = true,
				rewards = { xp = { branch = "best:any", amount = 40 }, reputation = { settlement = 5 } } },
			dark = { text = "Someone else lit them in the end.", success = false },
		},
		failOutcome = "dark", expireHours = 6, cooldownHours = 20,
	},

	-- B3. "Show me your magic": a villager asks to see one property of your domain.
	{
		id = "show_me_magic", type = "chore", beginner = true,
		title = "Show Me", summary = "{curious} has heard you have {domain_name} magic and wants to see it.",
		giver = "curious", scope = "personal", situations = { "beginner" },
		weight = 1.2, domains = {}, intensity = 0.05, difficulty = { 1, 2 }, requires = { maxTier = 2 },
		slots = {
			town = { kind = "settlement", from = "settlementId" },
			domain = { kind = "domain", from = "domain" },
			root = { kind = "branch", from = "domain" },
			property = { kind = "text", pick = "domainProperty:{domain}" },
			curious = { kind = "npc", pick = "colleague:child,merchant,innkeeper,farmer,fisher,builder,herbalist" },
		},
		stages = {
			{ id = "ask", text = "{curious} wants to see some {domain_name} magic.", options = {
				{ id = "talk", label = "Talk to {curious}", approach = "talk", objectives = { o("talk", "ask", "Talk to {curious}", { target = "curious" }) }, next = "show" },
			} },
			{ id = "show", text = "{curious} asks to see {property_name}. Cast it near them, not at them.", options = {
				{ id = "exact", label = "Show them {property_name}", approach = "magic",
					objectives = { o("cast", "show", "Cast {property_name} magic near {curious}", { target = "curious", radius = 18, count = 2, anyEffect = true, match = { properties = { "{property}" } } }) },
					outcome = "amazed" },
				{ id = "any", label = "Show them something else", approach = "creative",
					objectives = { o("cast", "other", "Cast any {domain_name} spell near {curious}", { target = "curious", radius = 18, count = 3, anyEffect = true, match = { branches = { "{root}" } } }) },
					outcome = "pleased" },
			} },
		},
		outcomes = {
			amazed = { text = "{curious} stares, then laughs out loud. \"Again!\"", success = true,
				rewards = { xp = { branch = "best:any", amount = 120 }, relationship = 0.15, reputation = { settlement = 5 } } },
			pleased = { text = "Not what {curious} asked for, but they're delighted anyway.", success = true,
				rewards = { xp = { branch = "best:any", amount = 60 }, relationship = 0.1 } },
			shrug = { text = "{curious} wandered off.", success = false },
		},
		failOutcome = "shrug", expireHours = 12, cooldownHours = 16,
	},

	-- B4. The lost pet: sense for it, or ask around; then go and get it.
	{
		id = "lost_pet", type = "rescue", beginner = true,
		title = "The Lost {pet_name}", summary = "{owner}'s {pet_name} got out, somewhere outside {town_name}.",
		giver = "owner", scope = "personal", situations = { "beginner" },
		weight = 1, domains = {}, intensity = 0.15, difficulty = { 1, 2 }, requires = { maxTier = 2 },
		slots = {
			town = { kind = "settlement", from = "settlementId" },
			owner = { kind = "npc", pick = "colleague:farmer,fisher,merchant,innkeeper,builder,smith,herbalist,hunter,retired" },
			pet = { kind = "text", pick = "oneOf:goat,dog,cat,hen,lamb" },
			spot = { kind = "position", pick = "aroundTown:45:110" },
		},
		stages = {
			{ id = "find", text = "Find {owner}'s {pet_name} somewhere outside {town_name}.", options = {
				{ id = "sense", label = "Sense for it", approach = "magic",
					objectives = { o("cast", "sense", "Sense near where it was last seen", { at = "spot", radius = 70, count = 1, anyEffect = true, match = { verbs = { "sense" } } }),
						o("reach", "fetch", "Go and fetch it", { at = "spot", radius = 10, seconds = 3 }) },
					ordered = true, outcome = "found" },
				{ id = "ask", label = "Ask around", approach = "talk",
					objectives = { o("talk", "ask", "Ask {owner} where it ran", { target = "owner" }), o("reach", "fetch", "Go and fetch it", { at = "spot", radius = 10, seconds = 3 }) },
					ordered = true, outcome = "found_asked" },
			} },
		},
		outcomes = {
			found = { text = "The {pet_name} was right where your senses said. {owner} is overjoyed.", success = true,
				rewards = { xp = { branch = "best:any", amount = 150 }, relationship = 0.25, reputation = { settlement = 5 }, currency = 10 } },
			found_asked = { text = "A muddy {pet_name}, safely home. {owner} can't thank you enough.", success = true,
				rewards = { xp = { branch = "best:any", amount = 60 }, relationship = 0.25, reputation = { settlement = 5 }, currency = 10 } },
			wandered = { text = "The {pet_name} found its own way home.", success = false },
		},
		failOutcome = "wandered", expireHours = 24, cooldownHours = 24,
	},

	-- B5. A lesson from the town's mentor (QuestFactory "mentor"): mentor-channel study XP and a
	-- hint naming your domain's next technique (SituationDetector.techniqueHint).
	{
		id = "mentor_lesson", type = "teaching", beginner = true,
		title = "A Lesson", summary = "{mentor} teaches anyone in {town_name} who is willing to listen.",
		giver = "mentor", scope = "personal", situations = { "beginner" },
		weight = 1.4, domains = {}, intensity = 0.05, difficulty = { 1, 2 }, requires = { maxTier = 2 },
		slots = { town = { kind = "settlement", from = "settlementId" }, mentor = { kind = "npc", pick = "mentor" } },
		stages = {
			{ id = "seek", text = "Find {mentor} and ask for a lesson.", options = {
				{ id = "ask", label = "Ask {mentor} for a lesson", approach = "talk", objectives = { o("talk", "ask", "Talk to {mentor}", { target = "mentor" }) }, next = "lesson" },
			} },
			{ id = "lesson", text = "{mentor} watches you work. \"Again. Slower.\"", options = {
				{ id = "practise", label = "Cast for {mentor}", approach = "magic",
					objectives = { o("cast", "cast", "Cast any spell near {mentor}", { target = "mentor", radius = 20, count = 2, anyEffect = true }) },
					outcome = "taught" },
				{ id = "listen", label = "Just listen", approach = "wait",
					objectives = { o("wait", "listen", "Listen to {mentor} for an hour", { hours = 1 }) }, outcome = "listened" },
			} },
		},
		outcomes = {
			taught = { text = "{mentor} nods. \"Better. {hint}\"", success = true, memory = "taught_me",
				-- A fixed gift, not mentor-channel study: `study.mentor.xp` (650 x tier gap) reached Novice
				-- by itself at about 3 minutes (docs/EarlyGamePlan.md §10). About a quarter of the way now.
				rewards = { xp = { branch = "best:any", amount = 200 }, relationship = 0.2 } },
			listened = { text = "{mentor} talks for an hour. One line sticks: \"{hint}\"", success = true,
				rewards = { xp = { branch = "best:any", amount = 60 }, relationship = 0.1 } },
			missed = { text = "{mentor} had other students today.", success = false },
		},
		failOutcome = "missed", expireHours = 24, cooldownHours = 20,
	},

	-- B6. Spar the training master: a duel for Novices only (never at Sensing).
	{
		id = "spar_master", type = "duel", beginner = true,
		title = "Sparring", summary = "{master} drills {town_name}'s guard and will spar with a promising Novice.",
		giver = "master", scope = "personal", situations = { "beginner" },
		weight = 1, domains = {}, intensity = 0.3, difficulty = { 2, 2 }, requires = { minTier = 2, maxTier = 2 },
		slots = { town = { kind = "settlement", from = "settlementId" }, master = { kind = "npc", pick = "colleague:guard" } },
		stages = {
			{ id = "ask", text = "Ask {master} for a bout.", options = {
				{ id = "ask", label = "Ask for a bout", approach = "talk", objectives = { o("talk", "ask", "Talk to {master}", { target = "master" }) }, next = "spar" },
			} },
			{ id = "spar", text = "Spar with {master}. They'll call it at half strength.", hours = 3, failOnDeath = "beaten", options = {
				{ id = "win", label = "Win the bout", approach = "force", objectives = { o("subdue", "win", "Bring {master} to half strength", { target = "master", share = 0.5 }) }, outcome = "won" },
				{ id = "learn", label = "Land three hits and learn", approach = "magic",
					objectives = { o("cast", "hits", "Land three harmful spells on {master}", { target = "master", radius = 30, count = 3, match = { harmful = true } }) }, outcome = "learned" },
			} },
		},
		outcomes = {
			won = { text = "{master} lowers their guard and grins. \"You'll do.\"", success = true, memory = "beat_me_fairly",
				rewards = { xp = { branch = "best:any", amount = 250 }, relationship = 0.2, reputation = { settlement = 10 } } },
			learned = { text = "{master} calls it. \"Good. Now do that when it counts.\"", success = true,
				rewards = { xp = { branch = "best:any", amount = 120 }, relationship = 0.15 } },
			beaten = { text = "{master} offers you a hand up. \"Better than most.\"", success = false,
				rewards = { xp = { branch = "best:any", amount = 40 }, relationship = 0.1 } },
			declined = { text = "{master} shrugs. The offer stands.", success = false },
		},
		failOutcome = "declined", expireHours = 12, cooldownHours = 24,
	},
}

local byId: { [string]: Template } = {}
for _, t in templates do
	assert(byId[t.id] == nil, "QuestTemplates: duplicate id " .. t.id)
	byId[t.id] = t
end

return table.freeze({ list = templates, byId = byId })
