--!strict
--[[
	Activities: what an NPC visibly does once it reaches where its schedule sent it
	(docs/LivingWorld.md §2). Pure data; NPC/DailyLife runs it.

	CLIPS are the replaceable animation slots. To replace one, change its id here and nothing else: a
	hammering animation goes in `hammer`, and every smith and builder picks it up. An animation must
	be owned by whoever owns the place (or shared with it), or it won't load: NPCLOD warns once.

	PROPS are small parts welded to an arm (the right, unless clipHand says otherwise), each one a list
	of { size, offset, color, material }.

	AN ACTIVITY
		clip        a slot from Clips
		looped      hold the clip while there; otherwise it plays once every `every` seconds
		every       { min, max } seconds between one-shot plays
		prop        a key of Props, carried for the whole activity
		roam        pick a new spot this many studs from where it arrived...
		roamEvery   { min, max } ...this often
		patrol      "guard" (the work post, the plaza, the town's entrances) or "lamps" (the lamp posts)
		pause       seconds to stand at each patrol stop
		spark       a tiny cosmetic spell from the NPC's real magic, if it has any, at power 1
		jump        hops now and then while roaming (children)

	LOOKUP: byOccupation[occupation][action], then byAction[action], else nothing (a plain idle).
]]

local rgb = Color3.fromRGB
local M = Enum.Material

export type PropPart = { size: Vector3, offset: Vector3, color: Color3, material: Enum.Material }

export type Activity = {
	clip: string?,
	looped: boolean?,
	every: { number }?,
	prop: string?,
	roam: number?,
	roamEvery: { number }?,
	patrol: string?,
	pause: number?,
	spark: boolean?,
	jump: boolean?,
}

local WOOD = rgb(120, 85, 55)
local IRON = rgb(90, 90, 96)

local Props: { [string]: { PropPart } } = {
	hammer = {
		{ size = Vector3.new(0.2, 0.2, 1.6), offset = Vector3.new(0, -1, -0.7), color = WOOD, material = M.Wood },
		{ size = Vector3.new(0.5, 0.4, 0.4), offset = Vector3.new(0, -1, -1.5), color = IRON, material = M.Metal },
	},
	hoe = {
		{ size = Vector3.new(0.2, 0.2, 4), offset = Vector3.new(0, -1, -1), color = WOOD, material = M.Wood },
		{ size = Vector3.new(0.6, 0.5, 0.15), offset = Vector3.new(0, -1.3, -3), color = IRON, material = M.Metal },
	},
	pickaxe = {
		{ size = Vector3.new(0.2, 0.2, 2.6), offset = Vector3.new(0, -1, -1), color = WOOD, material = M.Wood },
		{ size = Vector3.new(1.6, 0.25, 0.25), offset = Vector3.new(0, -1, -2.2), color = IRON, material = M.Metal },
	},
	spear = {
		{ size = Vector3.new(0.2, 6, 0.2), offset = Vector3.new(0, 0.6, -0.5), color = WOOD, material = M.Wood },
		{ size = Vector3.new(0.3, 0.8, 0.15), offset = Vector3.new(0, 3.9, -0.5), color = IRON, material = M.Metal },
	},
	lantern = {
		{ size = Vector3.new(0.15, 1.6, 0.15), offset = Vector3.new(0, -1.4, -0.6), color = IRON, material = M.Metal },
		{ size = Vector3.new(0.5, 0.6, 0.5), offset = Vector3.new(0, -2.4, -0.6), color = rgb(255, 214, 150), material = M.Neon },
	},
	mug = { { size = Vector3.new(0.45, 0.55, 0.45), offset = Vector3.new(0, -1, -0.5), color = rgb(150, 110, 70), material = M.Wood } },
	book = { { size = Vector3.new(0.8, 0.15, 1), offset = Vector3.new(0, -1, -0.7), color = rgb(120, 50, 45), material = M.SmoothPlastic } },
	basket = { { size = Vector3.new(1, 0.7, 1), offset = Vector3.new(0, -1.4, -0.3), color = rgb(170, 130, 80), material = M.SmoothPlastic } },
	rod = { { size = Vector3.new(0.12, 0.12, 5), offset = Vector3.new(0, -0.6, -2.4), color = WOOD, material = M.Wood } },
}

local Activities = {}

Activities.Props = Props

-- R6 only: the project's rigs are R6 (CombatAnimations.rigType).
Activities.Clips = table.freeze({
	-- The owner's own clips (2026-11-05).
	hammer = "rbxassetid://83054299922044",
	dig = "rbxassetid://102462779862982",
	hold = "rbxassetid://115233860888201",
	point = "rbxassetid://75385791730022",
	sit = "rbxassetid://123240149331173",
	-- Slots waiting for a clip. Empty is fine: NPCAnimator turns the head and bobs it instead.
	talk = "", -- 3-4 s loop: standing, gesturing with one hand while speaking
	listen = "", -- 3-4 s loop: standing, shifting weight, a small nod
	-- Still Roblox's defaults.
	wave = "rbxassetid://128777973",
	cheer = "rbxassetid://129423030",
	laugh = "rbxassetid://129423131",
	dance = "rbxassetid://182435998",
}) :: { [string]: string }

Activities.byOccupation = {
	smith = { work = { clip = "hammer", every = { 1.8, 3 }, prop = "hammer", spark = true } },
	builder = { work = { clip = "hammer", every = { 2, 4 }, prop = "hammer", roam = 10, roamEvery = { 14, 28 } } },
	miner = { work = { clip = "dig", every = { 2, 3.5 }, prop = "pickaxe" } },
	farmer = { work = { clip = "dig", every = { 2.5, 4.5 }, prop = "hoe", roam = 12, roamEvery = { 12, 24 } } },
	fisher = { work = { clip = "hold", looped = true, prop = "rod" } },
	lamplighter = { work = { prop = "lantern", patrol = "lamps", pause = 4, clip = "wave", every = { 3, 5 }, spark = true } },
	guard = { work = { prop = "spear", patrol = "guard", pause = 7 } },
	merchant = { work = { clip = "point", every = { 8, 16 } } },
	herbalist = { work = { clip = "hold", looped = true, prop = "basket", roam = 6, roamEvery = { 16, 30 } } },
	healer = { work = { clip = "hold", looped = true, prop = "basket" } },
	innkeeper = { work = { clip = "hold", looped = true, prop = "mug", roam = 7, roamEvery = { 10, 20 } } },
	scholar = { work = { clip = "hold", looped = true, prop = "book" } },
	hunter = { work = { clip = "hold", looped = true, prop = "spear" } },
	child = {
		play = { clip = "cheer", every = { 8, 16 }, roam = 14, roamEvery = { 4, 9 }, spark = true, jump = true },
		attend = { clip = "sit", looped = true },
		socialize = { clip = "laugh", every = { 7, 14 }, roam = 8, roamEvery = { 6, 12 }, jump = true },
	},
} :: { [string]: { [string]: Activity } }

Activities.byAction = {
	socialize = { clip = "laugh", every = { 12, 26 }, prop = "mug" },
	eat = { clip = "sit", looped = true },
	worship = { clip = "hold", looped = true },
	study = { clip = "hold", looped = true, prop = "book" },
	practice = { clip = "hold", every = { 4, 8 }, spark = true },
	teach = { clip = "point", every = { 6, 12 } },
	trade = { clip = "point", every = { 9, 18 }, roam = 8, roamEvery = { 14, 28 } },
	help = { clip = "hold", every = { 5, 9 }, roam = 6, roamEvery = { 16, 28 } },
	hobby = { clip = "hold", looped = true },
} :: { [string]: Activity }

-- A leisure or work district -> the real building kind that serves it (plus NPCSeat for the tavern).
-- A town without that building keeps the old abstract spot.
Activities.districtBuildings = table.freeze({
	tavern = "tavern",
	temple = "shrine",
	school = "magic_school",
	library = "magic_school",
	clinic = "shrine",
	forge = "smithy",
	guardpost = "watchtower",
	farm = "barn",
	market = "market_stall",
}) :: { [string]: string }

-- Clips that get into a pose and stay there: where an activity says `looped`, these play once and
-- freeze on their last frame instead of starting over.
Activities.holdAtEnd = table.freeze({ sit = true, hold = true }) :: { [string]: boolean }

-- Which hand a clip works with, where it isn't the right: the prop goes there for that activity.
Activities.clipHand = table.freeze({ hold = "left" }) :: { [string]: string }

function Activities.lookup(occupation: string, action: string): Activity?
	local own = Activities.byOccupation[occupation]
	return (own and own[action]) or Activities.byAction[action]
end

return Activities
