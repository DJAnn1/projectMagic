--!strict
--[[
	MeleeTuning: the spellblade (docs/Combat.md §13). Shared: the server times and resolves swings
	(Services/MeleeService) and the client predicts them (CastClient, the cast bar, the trail).

	SWINGS   Slash1 then Slash2, then round again. Times are seconds at speed 1 (a weapon's speed
	         divides them):
	           duration   the swing (the "slashing" action state)
	           hitFrom/To when the blade can connect (the server sweeps `samples` boxes between)
	           comboFrom  from here until duration + comboGrace, a press continues the combo
	           share      share of the attuned spell's power a hit deals (DamageModel share)
	           reach/width/height  the hit box in front of the chest (studs)
	           knockback  push on a hit (studs/s)
	COST     costBase + costShare x the attuned spell's reservoir cost, per swing
	FINISHER a cast within finisherWindow of a Slash2 that hit gets x finisherPower
	XP       a swing that hits awards practice XP to the attuned branch at xpShare of a cast's
	STATUS   statusChance that a hit carries the domain's touch (statuses), briefly and weakly
	WEAPONS  the main-hand weapon (Items: def.weapon) sets reach (its own, if longer), speed
	         (weapon.speed / speedRef, clamped) and adds its damage + attackPower flat; a focus
	         (staff, orb, wand) adds focusPower instead (the edge is the spell, made sharper).
]]

export type Swing = {
	clip: string,
	duration: number,
	hitFrom: number,
	hitTo: number,
	comboFrom: number,
	share: number,
	reach: number,
	width: number,
	height: number,
	knockback: number,
}

local MeleeTuning = {
	swings = {
		{ clip = "Slash1", duration = 0.5, hitFrom = 0.16, hitTo = 0.28, comboFrom = 0.3, share = 0.45, reach = 6, width = 5, height = 5, knockback = 0 },
		{ clip = "Slash2", duration = 0.55, hitFrom = 0.2, hitTo = 0.34, comboFrom = 0.36, share = 0.6, reach = 6.5, width = 6, height = 5, knockback = 22 },
	} :: { Swing },
	comboGrace = 0.3,
	samples = 3,
	costBase = 1,
	costShare = 0.12,
	finisherWindow = 0.8,
	finisherPower = 1.2,
	xpShare = 0.2,
	statusChance = 0.35,
	-- The domain's touch on a blade hit: a short, weak status (magnitude = per power where it ticks).
	status = {
		energy = { id = "burning", duration = 1.5, magnitudePerPower = 0.6 },
		earth = { id = "slow", duration = 0.8 },
		water = { id = "slow", duration = 1.0 },
		void = { id = "hexed", duration = 1.5, magnitudePerPower = 0.3 },
		time = { id = "time_slow", duration = 0.6 },
		gravity = { id = "slow", duration = 1.0 },
		spirit = { id = "fear", duration = 0.8 },
	} :: { [string]: { id: string, duration: number, magnitudePerPower: number? } },
	weapons = {
		speedRef = 1.2, -- a weapon of this speed swings at speed 1
		minSpeed = 0.75,
		maxSpeed = 1.5,
		focusPower = 1.1,
	},
}

return MeleeTuning
