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
	workReach = 14, -- close enough to work
	walkSeconds = 35, -- gives up walking after this, and works from wherever it got to
	stepOff = 5, -- stands this far back from the part
	workSeconds = 5, -- one part repaired this often, by someone there
	offscreenSeconds = 25, -- and this often with nobody working on it where anyone can see
	shoutRadius = 45,
	-- Living things recover by themselves, slowly. Nobody hammers a tree (seen in play, 2026-11-07).
	livingSeconds = 150, -- one part this often
	livingNames = { "tree", "hedge", "bush", "orchard", "garden", "plant", "flower", "grass" } :: { string },
	-- Repaired parts stay a little paler: a patched building looks patched.
	freshColor = Color3.fromRGB(190, 155, 110),
	freshShare = 0.18,
}

-- Who comes to fix things: lower is first, and anyone not listed isn't asked unless nobody else is free.
Repair.trades = { builder = 1, smith = 2, farmer = 3, hunter = 3, merchant = 3, innkeeper = 3 } :: { [string]: number }
Repair.anyoneElse = 5
Repair.neverAsked = { child = true, retired = true, guard = true } :: { [string]: boolean }

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
}

return table.freeze(Repair)
