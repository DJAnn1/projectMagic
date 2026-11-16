--!strict
--[[
	DownedTuning: the numbers behind losing (docs/LivingHistory.md §7, Living History stage 3).
	Read by Downed/DownedRules and Services/DownedService. Server-only.

	DOWN
		downSeconds      lying there before a carrier comes or the captor drags you off
		wakeSeconds      lying there before you come round where you fell (no one came)
		maxDown          the `downed` status's cap: nobody stays down longer than this
		graceSeconds     after getting up, creatures, Wildborn and NPC fighters leave you be this long
		fadeSeconds      the screen's fade to black before you're moved (the client's tween is the same)
		wakeHealth       share of max health you come round with, by outcome
	CARRY
		carryReach       a free townsperson within this many studs of where you fell may carry you
		carryMinAffinity ... unless they dislike you more than this (RelationshipGraph affinity)
		healerOccupations who in a town counts as its healer, in order
		thankBond        what thanking your carrier (talking to them) adds to their regard for you
		thankWindow      seconds after the carry that a talk still counts as thanks
	CAPTURE
		deepFrom         studs from the nearest town: only this deep in the wilds can a Wildborn drag you off
		captureChance    when everything allows it, how often it does
		captureGap       seconds: no capture within this long of the last one
		holdRadius       the captor leaves you alone inside this many studs of its home
		holdSeconds      how long it watches you before it wanders off
		wanderSeconds    how long it stays away once it has
		escapeRadius     past this many studs from its home, you've got away
	PURSE
		purseMin         coins you need on you before a purse drops
		purseShare       { min, max } share of your coins that drop
		purseLife        seconds a purse lies there before it's gone (nobody found it, you didn't come back)
		findAfter        { min, max } seconds before a passer-by in town may notice it
		findRadius       studs: who's close enough to notice it
		returnAt         an honest-enough finder gives it back (DownedRules.returns)
		keptKeep         seconds someone in town may still let slip who kept it
]]

return {
	downSeconds = 5,
	wakeSeconds = 20,
	maxDown = 40,
	graceSeconds = 8,
	fadeSeconds = 1.4,
	wakeHealth = { carry = 0.4, wake = 0.25, capture = 0.35 },

	carryReach = 60,
	carryMinAffinity = -0.25,
	healerOccupations = { "healer", "herbalist" },
	thankBond = 0.08,
	thankWindow = 3600,

	deepFrom = 260,
	captureChance = 0.75,
	captureGap = 900,
	holdRadius = 22,
	holdSeconds = 90,
	wanderSeconds = 60,
	escapeRadius = 70,

	purseMin = 5,
	purseShare = { 0.2, 0.4 },
	purseLife = 1200,
	findAfter = { 30, 120 },
	findRadius = 40,
	returnAt = 0.58,
	keptKeep = 3600,
}
