--!strict
--[[
	Repair: the numbers and words for how places recover (docs/TownRepair.md). Every number is a first guess.

	Nothing here is saved. A town repairs itself on the server it burned on, and a restart puts it back as new.
]]

local Repair = {}

Repair.tuning = {
	tickSeconds = 1,

	-- Burned ground: bare at first, then it grows back a patch at a time.
	scarSize = 8, -- studs across, split into quarters that regrow separately
	scarDepth = 8,
	healMin = 600, -- seconds until the first quarter can regrow...
	healSpread = 600, -- ...and each one comes up to this much later
	maxScars = 150, -- past this, new fires leave no mark
	healsPerTick = 4,
	scorchable = { Grass = true, LeafyGrass = true } :: { [string]: boolean }, -- what burns bare and regrows

	-- Charred buildings
	maxParts = 400, -- charred parts tracked per server
	workReach = 6, -- close enough to work
	walkSeconds = 35, -- gives up walking after this, and works from wherever it got to
	stepOff = 4, -- stands this far outside the building, so they can't be built in
	moveEvery = 6, -- on a rebuild, they move round to another side after this many pieces
	keepOutEvery = 5, -- seconds between sending people out of a building going back up
	workSeconds = 5, -- one part repaired this often, by someone there
	offscreenSeconds = 25, -- and this often with nobody working on it where anyone can see
	shoutRadius = 45,
	-- Living things recover by themselves, slowly. Nobody hammers a tree (seen in play, 2026-11-07).
	livingSeconds = 150, -- one part this often
	livingNames = { "tree", "hedge", "bush", "orchard", "garden", "plant", "flower", "grass" } :: { string },
	-- Collapsed buildings: the same pieces, put back from the ground up. It's meant to take a while.
	rebuildDelay = 120, -- seconds for the rubble to settle, before anyone starts
	rebuildSeconds = 8, -- one piece this often, with someone working on it
	rebuildOffscreenSeconds = 40, -- and this often with nobody around
	pieceSeconds = 0.6, -- how long a piece takes to settle into place
	riseFrom = 2, -- it comes up from this far below where it goes, not across town
	maxResidentLines = 3, -- how many of the people affected say something about it
	wholeIntegrity = 100,
	-- Damaged but still standing: it slowly regains its strength, or it'd be one tremor from coming down forever.
	mendEvery = 30, -- seconds between checks
	mendAmount = 1, -- integrity per check
	-- Repaired parts stay a little paler: a patched building looks patched.
	freshColor = Color3.fromRGB(190, 155, 110),
	freshShare = 0.18,
}

-- Who comes to fix things: lower is first, and anyone not listed isn't asked unless nobody else is free.
Repair.trades = { builder = 1, smith = 2, farmer = 3, hunter = 3, merchant = 3, innkeeper = 3 } :: { [string]: number }
Repair.anyoneElse = 5
Repair.neverAsked = { child = true, retired = true, guard = true } :: { [string]: boolean }

-- Poles and planks round a building going back up. Only so many at once: a quake can flatten a town.
Repair.scaffold = {
	margin = 2.5, -- outside the building
	poleWidth = 0.5,
	plankThick = 0.25,
	plankWide = 1.2,
	levelEvery = 7, -- studs between platforms
	maxLevels = 3,
	midPoleOver = 14, -- a side longer than this gets a pole in the middle
	groundBelow = 3, -- poles start this far under the floor, to meet uneven ground
	maxAlive = 6,
	poleColor = Color3.fromRGB(120, 88, 58),
	plankColor = Color3.fromRGB(155, 118, 78),
}

Repair.lines = {
	start = {
		"Right. Let's see how bad it is.",
		"I'll get that seen to.",
		"Burned right through, look at that.",
	},
	finish = {
		"That'll hold.",
		"Good as it's going to get.",
		"There. Nobody'll fall through that now.",
	},
	-- %s is the friend they're going to. Only in the lines that have one.
	homeLostFriend = {
		"My house! I'll have to go to %s's.",
		"That was my home. %s will take me in, I hope.",
	},
	homeLost = {
		"My house! Where am I supposed to sleep?",
		"That was my home. All of it.",
		"Gone. I suppose it's the tavern for me.",
	},
	workLost = {
		"That's my work gone, then.",
		"I was only in there this morning.",
	},
	homeBack = {
		"It's standing! I can go home.",
		"I never thought I'd be so glad to see that door.",
	},
	rebuildStart = {
		"It'll take a while, but it's coming back up.",
		"Right. From the ground up, then.",
		"Most of it's still here. It's only got to go back where it was.",
	},
	rebuildFinish = {
		"There. Standing again.",
		"That's the last of it.",
		"You'd hardly know, would you?",
	},
}

return table.freeze(Repair)
