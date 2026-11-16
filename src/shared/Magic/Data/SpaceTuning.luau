--!strict
--[[
	SpaceTuning: the numbers behind Space's powers (docs/Space.md, stage 1). Server-side code reads these;
	the client only needs the looks. A `{ base, perTier, max }` grows with the caster's mastery tier (0..8):
	SpaceTuning.byTier(t, tier) = min(max, base + perTier x tier).

	GATE   two linked rifts: one in front of the caster, one at the aim point. Anything that walks or flies
	       into one comes out of the other (people, NPCs, creatures, bolts and arrows).
	SWAP   the caster and the target change places.
	SEAL   a box nobody crosses: the sealed one can't move, cast or be hurt; bolts stop at its wall.
	STRIDE space folds under your feet: you cover more ground with each step, until you hurt someone.
	CUT    a rend in space along the aim: hurts, and guards can't turn it.
	DISLOCATION  Space's backfire and its risk: thrown somewhere, sometimes somewhere awkward.
]]

local SpaceTuning = {}

export type Curve = { base: number, perTier: number, max: number }

function SpaceTuning.byTier(curve: Curve, tier: number): number
	return math.min(curve.max, curve.base + curve.perTier * math.max(0, tier))
end

SpaceTuning.gate = {
	seconds = { base = 20, perTier = 5, max = 60 } :: Curve,
	radius = 2.8, -- studs: a body's root this close to a gate's centre goes through
	exitOffset = 4, -- studs out of the other gate along its face
	perCaster = 2, -- open pairs at once; a third closes the oldest
	maxServer = 24,
	bodyGap = 1.2, -- seconds before the same body can go through again (no ping-pong)
	flightGap = 0.4,
	frontOffset = 5, -- studs ahead of the caster for the near gate
	--[[
		Long gates (owner, 2026-11-16: "at a high enough skill level you should be able to gate anywhere around
		the map"). With a map waypoint set, the far end opens there instead of at the aim point, if it's within
		this many studs for your tier (index = tier + 1) and on ground you've uncovered on your map.
		Expert: across a region; Master: half the island; Grandmaster and up: anywhere.
	]]
	waypointReach = { 0, 0, 0, 0, 700, 1600, 8000, 8000, 8000 },
	farWait = 12, -- seconds a far end may take to open (its ground being built) before the gate gives up
}

function SpaceTuning.waypointReach(tier: number): number
	local list = SpaceTuning.gate.waypointReach
	return list[math.clamp(math.floor(tier) + 1, 1, #list)]
end

SpaceTuning.swap = {
	maxStuds = 140, -- never further than this, whatever the range said
}

SpaceTuning.seal = {
	seconds = { base = 3, perTier = 0.4, max = 6 } :: Curve,
	pvpSeconds = 2.5, -- a player sealed by another player: never longer
	radius = 4, -- the box's half size around a body
	areaRadius = { base = 10, perTier = 1.5, max = 20 } :: Curve, -- zone/burst/ritual: everyone in here
	areaMax = 8,
}

SpaceTuning.stride = {
	seconds = { base = 12, perTier = 3, max = 36 } :: Curve,
	walk = { base = 1.9, perTier = 0.18, max = 3.4 } :: Curve, -- WalkSpeed multiplier
}

SpaceTuning.cut = {
	share = 1.35, -- of a normal hit: it costs, it should bite
	length = { base = 40, perTier = 6, max = 90 } :: Curve,
	width = 3,
	maxTargets = 6,
}

SpaceTuning.dislocation = {
	studs = { base = 10, perTier = 0, max = 10 } :: Curve, -- plus power x 2.5
	perPower = 2.5,
	maxStuds = 34,
	upChance = 0.25, -- sometimes dropped from above whatever is there instead (a roof, a ledge)
	dropFrom = 14,
}

-- ─── Stage 2 ─────────────────────────────────────────────────────────────

--[[
	ANCHOR and RECALL (Blinking, position): bind leaves an anchor where you stand (one each, kept for the
	session); release takes you back to it from as far as your tier reaches (index = tier + 1). From
	Grandmaster, party mates within partyRadius come with you.
]]
SpaceTuning.anchor = {
	reach = { 250, 300, 400, 600, 1000, 1800, 8000, 8000, 8000 },
	partyRadius = 14,
	partyFromTier = 6,
	wait = 10, -- seconds a far recall may wait for the ground there to be built
}

function SpaceTuning.anchorReach(tier: number): number
	local list = SpaceTuning.anchor.reach
	return list[math.clamp(math.floor(tier) + 1, 1, #list)]
end

--[[
	STRETCH (Folding, amplify, an area form): space lengthens around a point. Everyone inside but the caster
	crawls (status space_stretched), and anyone else's bolts crossing it slow to boltMult, once each.
]]
SpaceTuning.stretch = {
	seconds = { base = 8, perTier = 1, max = 16 } :: Curve,
	radius = { base = 10, perTier = 1.5, max = 22 } :: Curve,
	boltMult = 0.45,
	perCaster = 2,
	maxServer = 16,
}

--[[
	POCKET (Pocketcraft, volume): a pocket of space only you can reach into. Its contents are saved with you;
	the spell opens it wherever you are, for a while. Its size grows with your tier (it never shrinks: what's
	in it stays, only adding is refused past the size).
]]
SpaceTuning.pocket = {
	slots = { base = 6, perTier = 2, max = 22 } :: Curve,
	seconds = { base = 30, perTier = 10, max = 120 } :: Curve,
}

--[[
	CLAIRSENTIENCE: Sense sight's "space" kind (Data/SenseSight): every body, door and container in reach,
	through walls. Space reaches further than the other kinds: radius x reachMult, up to maxRadius.
]]
SpaceTuning.clairsentience = {
	reachMult = 2.2,
	maxRadius = 200,
}

SpaceTuning.looks = {
	rim = Color3.fromRGB(150, 160, 255),
	deep = Color3.fromRGB(20, 18, 60),
	star = Color3.fromRGB(230, 230, 255),
}

return SpaceTuning
