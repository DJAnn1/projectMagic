--!strict
--[[
	TravelTuning: Domain Travel, the fast way everyone gets around (docs/Travel.md). Every domain has its
	own style. Lists are indexed by your mastery tier in that domain, 1 (Sensing) to 8 (Transcendent).

	STYLE FIELDS
		name        what it's called
		speedMult   x the tier's speed
		hover       studs above the ground when you're not climbing
		lift        how far above that Space can take you: small is a hop over a fence, large is real gliding
		water       can it cross water? (Earth and Life can't: they stop at the shore)
		board       what you ride, if anything: { size, material, transparency? }, in the domain's colour
		motes       particles per second streaming off you

	For scale: walking is 16 studs/s, and Flight runs 16 to 110. Travel is meant to beat walking from the
	first minute without replacing Flight. TUNING STATUS: first guesses, not yet played.
]]

local M = Enum.Material

export type Style = {
	name: string,
	speedMult: number,
	hover: number,
	lift: number,
	water: boolean,
	board: { size: Vector3, material: Enum.Material, transparency: number? }?,
	motes: number,
}

local styles: { [string]: Style } = {
	energy = { name = "Flame Jet", speedMult = 1.1, hover = 2, lift = 14, water = true, motes = 40 },
	earth = { name = "Stone Surf", speedMult = 1, hover = 1, lift = 6, water = false, motes = 12, board = { size = Vector3.new(3.5, 0.6, 6), material = M.Slate } },
	water = { name = "Wave Ride", speedMult = 1.05, hover = 1, lift = 6, water = true, motes = 30, board = { size = Vector3.new(4, 0.5, 6.5), material = M.Glass, transparency = 0.35 } },
	air = { name = "Wind Glide", speedMult = 1, hover = 4, lift = 40, water = true, motes = 24 },
	life = { name = "Root Run", speedMult = 0.95, hover = 0.5, lift = 8, water = false, motes = 16, board = { size = Vector3.new(3, 0.5, 5), material = M.Grass } },
	spirit = { name = "Ghost Drift", speedMult = 1, hover = 3, lift = 12, water = true, motes = 22 },
	mind = { name = "Thought Step", speedMult = 1, hover = 2, lift = 10, water = true, motes = 14 },
	void = { name = "Shadow Slide", speedMult = 1.15, hover = 0.5, lift = 4, water = true, motes = 26, board = { size = Vector3.new(5, 0.2, 7), material = M.SmoothPlastic, transparency = 0.25 } },
	space = { name = "Fold Step", speedMult = 1.2, hover = 2, lift = 10, water = true, motes = 18 },
	time = { name = "Quickstep", speedMult = 1.2, hover = 1, lift = 6, water = true, motes = 20 },
	gravity = { name = "Sideways Fall", speedMult = 1.15, hover = 3, lift = 30, water = true, motes = 16 },
	reality = { name = "Slipstream", speedMult = 1.1, hover = 2, lift = 10, water = true, motes = 22 },
}

return table.freeze({
	styles = styles,
	fallbackDomain = "energy",

	speed = { 28, 34, 40, 48, 56, 66, 78, 92 }, -- studs/s
	drainShare = { 0.03, 0.025, 0.02, 0.016, 0.012, 0.009, 0.006, 0.003 }, -- of max reservoir per second
	minReservoir = 0.05, -- you need this share to set off

	-- What knocks you off.
	knockShare = 0.15, -- one hit worth this share of your max health
	knockCooldown = 2, -- seconds before you can set off again

	-- What the server allows (Players own their physics, so it checks rather than moves).
	checkSeconds = 0.25,
	speedSlack = 1.5, -- x speed, plus speedMargin: knockback and dashes fit in here
	speedMargin = 30,
	heightMargin = 45, -- studs past hover + lift: roofs and cliffs fit in here
	strikesToEnd = 3,
})
