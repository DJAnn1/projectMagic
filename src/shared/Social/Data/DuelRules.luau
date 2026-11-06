--!strict
--[[
	DuelRules: the ways a duel can be fought, and the limits every duel shares (docs/Social.md §6).
	Shared so the challenge card can describe a rule with the same words the server enforces.

		floorShare         nobody in the duel can fall below this share of MaxHealth (Cast/Damage's
		                   HealthFloor). Every rule has one: no duel can kill.
		endAtDamageShare   the duel ends once one fighter has dealt this share of the other's MaxHealth
		endAtFloor         the duel ends the moment a fighter reaches the floor
		floorYieldSeconds  a fighter who stays at the floor this long yields automatically (otherwise
		                   a fighter at the floor could never lose and the duel would only time out)

	Every floor stays above 5% of MaxHealth on purpose: "Brush with Death" needs health at or below
	5%, so a friendly duel can never be used to farm it.
]]

export type Rule = {
	id: string,
	name: string,
	text: string,
	order: number,
	floorShare: number,
	endAtDamageShare: number?,
	endAtFloor: boolean?,
	floorYieldSeconds: number?,
}

local rules: { [string]: Rule } = {
	first_blood = {
		id = "first_blood", name = "First blood", order = 1,
		text = "The first to land a real wound wins.",
		floorShare = 0.2,
		endAtDamageShare = 0.05,
	},
	no_lethal = {
		id = "no_lethal", name = "No lethal", order = 2,
		text = "Fight until one of you is nearly spent. It ends before anyone is hurt badly.",
		floorShare = 0.15,
		endAtFloor = true,
	},
	yield = {
		id = "yield", name = "To yield", order = 3,
		text = "Fight until someone yields. Nobody can kill you; at your limit you yield after a few seconds.",
		floorShare = 0.08,
		floorYieldSeconds = 8,
	},
}

local ordered: { Rule } = {}
for _, rule in rules do
	table.insert(ordered, rule)
end
table.sort(ordered, function(a, b)
	return a.order < b.order
end)

return table.freeze({
	rules = rules,
	ordered = ordered,
	default = "no_lethal",
	limits = table.freeze({
		challengeSeconds = 30, -- how long a challenge stays open
		challengeCooldown = 15, -- seconds before challenging the same person again after a no
		challengeRange = 60, -- studs: how close you must be to challenge or accept
		recentHitSeconds = 10, -- can't start a duel this soon after being hit (no escaping a fight)
		countdownSeconds = 3,
		fightSeconds = 180,
		ringRadius = 45,
		ringOutSeconds = 3, -- this long outside the ring forfeits
		graceSeconds = 6, -- the two can't hurt each other this long after a duel (late projectiles)
		maxConcurrent = 8, -- duels at once on a server (each draws a ring)
		tickRate = 5, -- ring, clock and floor checks per second
		logCap = 40, -- hits remembered per duel for the recap
		spectatorRange = 150, -- studs: who hears how a duel ended
	}),
})
