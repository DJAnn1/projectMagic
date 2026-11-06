--!strict
--[[
	TimeTuning: how the Time powers scale with skill (docs/Time.md). The owner's brief (2026-11-06):
	Time is supposed to be overpowered, so the top of every table is meant to feel that way.

	Lists are indexed by mastery tier in the spell's branch:
	      1 Sensing  2 Novice  3 Adept  4 Skilled  5 Expert  6 Master  7 Grandmaster  8 Transcendent

	TUNING STATUS  First guesses. None has been played.
]]

return table.freeze({
	selfTimeline = {
		window = { 6, 8, 10, 14, 18, 22, 30, 45 }, -- seconds the mark lasts
		cooldown = { 60, 50, 45, 40, 30, 20, 12, 6 }, -- seconds between recalls: this is all that stops an endless full-reservoir loop
	},

	lastMoment = {
		minTier = 7, -- Grandmaster: a killing blow triggers your mark instead
		cooldown = { 300, 300, 300, 300, 300, 300, 180, 90 }, -- seconds between saves
	},

	targetTimeline = {
		window = { 6, 8, 10, 14, 18, 22, 30, 45 },
		marks = { 1, 1, 1, 2, 2, 3, 4, 6 }, -- people marked at once
		stun = { 0.5, 0.6, 0.8, 1, 1.2, 1.5, 2, 3 }, -- seconds frozen where they land
		share = 0.3, -- of a full hit, when they're snapped back
	},

	stored = {
		seconds = { 4, 5, 6, 8, 10, 12, 15, 20 }, -- how long it stays up, and how long spells can hang
		capacity = { 2, 2, 3, 3, 4, 5, 6, 8 }, -- projectiles held at once
		hangAfter = 0.2, -- seconds a projectile flies before it hangs
	},

	timestop = {
		seconds = { 0.5, 0.5, 0.75, 1, 1.5, 2, 3, 5 },
		cooldown = { 120, 120, 110, 100, 90, 75, 60, 40 }, -- per caster
		radiusMin = 20,
		radiusMax = 90,
		scanEvery = 0.25, -- seconds between freezing whoever walked in
		maxTargets = 60,
		maxParts = 150, -- loose objects frozen, per stop
	},

	wound = {
		seconds = { 3, 3, 4, 4, 5, 5, 6, 8 }, -- how long hits are held back
		targetMult = { 1.1, 1.15, 1.2, 1.3, 1.4, 1.6, 1.8, 2.2 }, -- on an enemy: they take this much of it, all at once
		selfMult = { 0.9, 0.85, 0.8, 0.7, 0.6, 0.5, 0.4, 0.25 }, -- on yourself: you pay this much of it later
	},

	foresight = {
		seconds = { 8, 10, 12, 15, 20, 25, 30, 40 },
		dodge = { 0, 0, 0.05, 0.1, 0.15, 0.2, 0.3, 0.4 }, -- chance to simply not be where the hit lands
		seeRadius = 200, -- studs: you see the aim of spells cast this near
	},

	loop = {
		loops = { 2, 2, 3, 3, 4, 5, 6, 8 },
		interval = 2, -- seconds between snaps back to where they stood
		stun = 0.25,
		share = 0.2, -- of a full hit, each time
	},
})
