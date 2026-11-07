--!strict
--[[
	ActivityLibrary: every visible thing an NPC can be doing, as data (docs/Activities.md).
	Shared: the server picks and replicates an activity's id; every client renders it from this table.

	AN ACTIVITY
		group        family for reports and the town overview ("craft", "home", "faith", "magic", ...)
		name         the short label ("Blacksmithing")
		actions      the NPCBrain actions it serves (Data/NeedsActions)
		occupations  only these jobs (nil = anyone the action allows)
		domain       practice only: the NPC's strongest domain must be this one
		weight       among several fits for the same person, how often this one is chosen (default 1)
		station      a StationTypes kind the NPC goes to and uses; nil = performed at a spot
		spot         station-less: "route" (wherever the schedule sends them), "door" (a house's front
		             step), "yard" (beside a house), "patrol" (a guard's round)
		props        { right = HeldProps id?, left = HeldProps id? }, out from Preparing to Finishing
		carry        props stay out while Travelling too (a guard's spear, a fisher's rod)
		pose         ActivityPoses family (the procedural fallback and the silhouette)
		clip         ActivityPoses.slots key: an animation that replaces the pose when it has an id
		strikeAt     with a clip: the fraction of it where the tool lands (sparks, chips)
		setPiece     a client-built object at the work spot that shows progress (SetPieces)
		vfx          client effect ids played on the NPC (ActivityRenderer)
		sound        an AudioLibrary role (none chosen yet for activities: see docs/Activities.md)
		minutes      { min, max } game minutes for one piece of work; progress loops after it
		interrupt    what happens when someone talks to them: "hold" (stop, keep the tool in hand),
		             "setDown" (put the tool away), "stay" (they don't stop: sleeping, praying)
		tell         what reads at a distance: the silhouette and rhythm the player learns
		seen         what a stranger can tell at a glance ("Someone working at an anvil")
		doing        what someone who knows them reads: {item} is replaced by one of `items`
		items        what the work makes (seeded per piece of work)
		learn        what watching it closely teaches (Observe, docs/Activities.md §5)
]]

export type Activity = {
	id: string,
	index: number,
	group: string,
	name: string,
	actions: { string },
	occupations: { string }?,
	domain: string?,
	weight: number?,
	station: string?,
	spot: string?,
	props: { right: string?, left: string? },
	carry: boolean?,
	pose: string,
	clip: string?,
	strikeAt: number?,
	setPiece: string?,
	vfx: { string },
	sound: string?,
	minutes: { number },
	interrupt: string,
	tell: string,
	seen: string,
	doing: string,
	items: { string }?,
	learn: string,
}

local list: { Activity } = {
	{
		id = "forging", index = 0, group = "craft", name = "Blacksmithing",
		actions = { "work" }, occupations = { "smith" },
		station = "anvil", props = { right = "hammer", left = "tongs" },
		pose = "hammer", clip = "hammer", strikeAt = 0.45, setPiece = nil, vfx = {},
		minutes = { 50, 110 }, interrupt = "hold",
		tell = "A steady overhead hammer rhythm at an anvil; sparks on every strike, the forge glowing behind.",
		seen = "Someone working at an anvil",
		doing = "Hammering out {item}",
		items = { "a plowshare", "a set of horseshoes", "a door hinge", "a sword blade", "a bucket of nails", "a pot hook", "a sickle blade" },
		learn = "Smiths hammer while the metal still glows, and quench it in the trough when the shape is right.",
	},
	{
		id = "baking", index = 0, group = "craft", name = "Baking",
		actions = { "work" }, occupations = { "innkeeper" },
		station = "hearth", props = { right = "peel" },
		pose = "stir", vfx = { "flour" },
		minutes = { 40, 80 }, interrupt = "setDown",
		tell = "Bent at a lit hearth, arm working in slow circles; smoke rises from the chimney.",
		seen = "Someone busy at a hearth",
		doing = "Baking {item}",
		items = { "a batch of loaves", "oat cakes", "a meat pie", "honey bread", "a pot of stew" },
		learn = "The hearth has to be lit before anything cooks; the smoke over the roof tells the street.",
	},
	{
		id = "farming", index = 0, group = "land", name = "Farming",
		actions = { "work" }, occupations = { "farmer" },
		spot = "route", props = { right = "hoe" }, carry = true,
		pose = "dig", clip = "dig", strikeAt = 0.55, setPiece = "furrows", vfx = { "dirt" },
		minutes = { 60, 120 }, interrupt = "hold",
		tell = "A long-handled hoe rising and falling, working along the ground; furrows lengthen behind.",
		seen = "Someone hoeing the ground",
		doing = "Turning {item}",
		items = { "a row for barley", "the bean patch", "ground for turnips", "the onion bed" },
		learn = "Farmers turn the soil in rows; the furrows they leave say how far the day's work has gone.",
	},
	{
		id = "sweeping", index = 0, group = "home", name = "Sweeping",
		actions = { "help" }, weight = 1,
		spot = "door", props = { right = "broom" },
		pose = "sweep", setPiece = "swept", vfx = { "dust" },
		minutes = { 15, 35 }, interrupt = "hold",
		tell = "Wide side-to-side sweeps with a broom in front of a door; dust drifts up.",
		seen = "Someone sweeping a doorstep",
		doing = "Sweeping {item}",
		items = { "a neighbour's doorstep", "the step", "the lane by the door" },
		learn = "Neighbours keep each other's steps clean; who sweeps whose door says who looks out for whom.",
	},
	{
		id = "chopping", index = 0, group = "home", name = "Chopping wood",
		actions = { "help" }, weight = 1,
		spot = "yard", props = { right = "axe" },
		pose = "chop", setPiece = "logpile", vfx = { "chips" },
		minutes = { 25, 50 }, interrupt = "setDown",
		tell = "A two-handed axe swung high and brought down on a block; the woodpile grows beside it.",
		seen = "Someone splitting wood",
		doing = "Splitting {item}",
		items = { "firewood for a neighbour", "kindling", "logs for the winter pile" },
		learn = "A growing woodpile beside a house means someone's been helping there.",
	},
	{
		id = "reading", index = 0, group = "learning", name = "Studying",
		actions = { "study" },
		station = "desk", props = { right = "quill" },
		pose = "read", vfx = {},
		minutes = { 40, 90 }, interrupt = "hold",
		tell = "Hunched over a desk, head down, a candle lit beside an open book.",
		seen = "Someone reading at a desk",
		doing = "Studying {item}",
		items = { "a treatise on their domain", "old casting notes", "a borrowed grimoire", "a lesson's exercises" },
		learn = "Mages read before they practise; what's on the desk hints at what they're working toward.",
	},
	{
		id = "sleeping", index = 0, group = "home", name = "Sleeping",
		actions = { "sleep" },
		station = "bed", props = {},
		pose = "sleep", setPiece = "blanket", vfx = {},
		minutes = { 240, 480 }, interrupt = "stay",
		tell = "Lying still under a blanket, breathing slowly.",
		seen = "Someone asleep",
		doing = "Asleep",
		items = nil,
		learn = "People sleep in their own beds; an empty bed at night means someone's out, or gone.",
	},
	{
		id = "eating_tavern", index = 0, group = "social", name = "Eating at the tavern",
		actions = { "eat" },
		station = "seat", props = { right = "mug", left = "bread" },
		pose = "eat", vfx = {},
		minutes = { 30, 60 }, interrupt = "hold",
		tell = "Sitting at a tavern bench, lifting a mug and bread in turns.",
		seen = "Someone eating at the tavern",
		doing = "Eating {item}",
		items = { "a bowl of stew", "bread and cheese", "the house pie", "a plate of fish" },
		learn = "Sociable people eat at the tavern; quieter ones eat at home.",
	},
	{
		id = "eating_home", index = 0, group = "home", name = "Eating at home",
		actions = { "eat" },
		station = "table", props = { right = "spoon", left = "bowl" },
		pose = "eat", vfx = {},
		minutes = { 20, 45 }, interrupt = "hold",
		tell = "Sitting at their own table, spoon going from bowl to mouth.",
		seen = "Someone eating at a table",
		doing = "Eating {item}",
		items = { "porridge", "soup", "bread and dripping", "leftover stew" },
		learn = "Households eat at their own tables at mealtimes.",
	},
	{
		id = "patrolling", index = 0, group = "duty", name = "Patrolling",
		actions = { "work" }, occupations = { "guard" },
		spot = "patrol", props = { right = "spear" }, carry = true,
		pose = "patrol", vfx = {},
		minutes = { 60, 120 }, interrupt = "hold",
		tell = "Walking a slow round with a spear upright, stopping to look about.",
		seen = "A guard on patrol",
		doing = "Walking {item}",
		items = { "the evening round", "the plaza and the gates", "the market rounds" },
		learn = "Guards walk the same round each watch; where they stop is where they expect trouble.",
	},
	{
		id = "fishing", index = 0, group = "land", name = "Fishing",
		actions = { "work" }, occupations = { "fisher" },
		spot = "route", props = { right = "rod" }, carry = true,
		pose = "fish", setPiece = "fishing", vfx = {},
		minutes = { 60, 150 }, interrupt = "hold",
		tell = "Standing at the water with a long rod out, a line down to a bobber; now and then a splash.",
		seen = "Someone fishing",
		doing = "Fishing for {item}",
		items = { "mackerel", "the evening catch", "eels", "whatever's biting" },
		learn = "A full basket beside a fisher means the fish are biting here.",
	},
	{
		id = "praying", index = 0, group = "faith", name = "Praying",
		actions = { "worship" },
		station = "altar", props = {},
		pose = "pray", vfx = { "prayer" },
		minutes = { 30, 60 }, interrupt = "stay",
		tell = "Kneeling still before an altar, head bowed, a faint light about their hands.",
		seen = "Someone kneeling in prayer",
		doing = "Praying {item}",
		items = { "for a good harvest", "for someone far away", "in thanks", "for calm" },
		learn = "Frightened people pray more; a crowded shrine means a worried town.",
	},
	{
		id = "practice_energy", index = 0, group = "magic", name = "Practising Energy magic",
		actions = { "practice" }, domain = "energy",
		spot = "route", props = {},
		pose = "cast_hold", setPiece = "practice_energy", vfx = {},
		minutes = { 30, 60 }, interrupt = "setDown",
		tell = "Palms cupped in front of them around a small flame; masters juggle rings of fire.",
		seen = "Someone holding a small flame",
		doing = "Practising {item}",
		items = { "keeping a flame steady", "shaping fire", "heat without a flame" },
		learn = "Watch the flame: a novice's gutters and jumps, a master's holds a shape.",
	},
	{
		id = "practice_earth", index = 0, group = "magic", name = "Practising Earth magic",
		actions = { "practice" }, domain = "earth",
		spot = "route", props = {},
		pose = "cast_shape", setPiece = "practice_earth", vfx = {},
		minutes = { 30, 60 }, interrupt = "setDown",
		tell = "Crouched over a pebble, hands shaping; small stone figures stand up around it.",
		seen = "Someone shaping pebbles",
		doing = "Practising {item}",
		items = { "shaping stone figures", "raising pebbles", "reading the ground" },
		learn = "The more figures they raise at once, the further along they are.",
	},
	{
		id = "practice_water", index = 0, group = "magic", name = "Practising Water magic",
		actions = { "practice" }, domain = "water",
		spot = "route", props = {},
		pose = "cast_pour", setPiece = "practice_water", vfx = {},
		minutes = { 30, 60 }, interrupt = "setDown",
		tell = "Two bowls on the ground and water arcing between them through the air.",
		seen = "Someone moving water between bowls",
		doing = "Practising {item}",
		items = { "moving water between bowls", "holding water in the air", "a steady stream" },
		learn = "Count the splashes: a novice spills, a master's water never touches the ground.",
	},
}

local ActivityLibrary = {}

ActivityLibrary.list = list
ActivityLibrary.byId = {} :: { [string]: Activity }
ActivityLibrary.byIndex = {} :: { [number]: Activity }

for i, def in list do
	def.index = i
	ActivityLibrary.byId[def.id] = def
	ActivityLibrary.byIndex[i] = def
end

-- Why someone is doing it: a reason id (ActivityRules) -> the words.
ActivityLibrary.reasons = table.freeze({
	shift = "on shift",
	overtime = "working late for extra coin",
	hungry = "hungry",
	mealtime = "mealtime",
	tired = "worn out",
	bedtime = "bedtime",
	lesson = "studying for a lesson",
	curious = "reading out of curiosity",
	practice = "keeping their hand in",
	ambition = "pushing to get better",
	prayers = "at prayers",
	frightened = "frightened, and praying",
	helping = "helping a neighbour",
	watch = "on watch",
	told = "asked to",
}) :: { [string]: string }

-- How far along, in words (the Detailed tooltip).
function ActivityLibrary.progressWord(progress: number): string
	if progress < 0.15 then
		return "just started"
	elseif progress < 0.45 then
		return "under way"
	elseif progress < 0.8 then
		return "well along"
	end
	return "nearly done"
end

-- The activity's sentence with its item filled in.
function ActivityLibrary.doingText(def: Activity, item: number): string
	local items = def.items
	local word = if items and #items > 0 then items[(item - 1) % #items + 1] else ""
	return (string.gsub(def.doing, "{item}", word))
end

return ActivityLibrary
