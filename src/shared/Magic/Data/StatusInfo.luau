--!strict
--[[
	StatusInfo: how each status looks to a player (the HUD status bar, tooltips). Pure data,
	shared. What a status DOES lives server-side in Cast/StatusEffects (DEFS, same ids);
	Tests/Combat.spec checks every server status has an entry here.

	The HUD never relies on colour alone: harmful statuses carry ▼ and a warm colour, helpful ones
	▲ and a cool one, plus the name and the seconds left.
]]

export type Info = {
	name: string,
	harmful: boolean,
	description: string,
}

local StatusInfo: { [string]: Info } = {
	slow = { name = "Slowed", harmful = true, description = "You move at about half speed." },
	haste = { name = "Hastened", harmful = false, description = "You move faster." },
	root = { name = "Rooted", harmful = true, description = "You can't walk or jump." },
	stasis = { name = "Stasis", harmful = true, description = "Held still in time." },
	ward = { name = "Warded", harmful = false, description = "A ward soaks up damage and resists all magic." },
	evading = { name = "Evading", harmful = false, description = "Mid-dash: you take less damage for a moment." },
	hexed = { name = "Hexed", harmful = true, description = "You take more damage, and the curse gnaws at you." },
	poison = { name = "Poisoned", harmful = true, description = "Losing health over time." },
	rot = { name = "Rotting", harmful = true, description = "Losing health and slowed." },
	burning = { name = "Burning", harmful = true, description = "On fire: losing health over time." },
	silence = { name = "Silenced", harmful = true, description = "You can't cast." },
	fear = { name = "Afraid", harmful = true, description = "Your nerve is shaken." },
	charm = { name = "Charmed", harmful = true, description = "Your will isn't entirely your own." },
	calm = { name = "Calm", harmful = false, description = "Soothed." },
	blind = { name = "Blinded", harmful = true, description = "You can barely see." },
	veiled = { name = "Veiled", harmful = false, description = "Hard to see." },
	lucky = { name = "Lucky", harmful = false, description = "Your spells backfire less often." },
	time_slow = { name = "Slowed time", harmful = true, description = "Time around you crawls." },
	time_haste = { name = "Quickened time", harmful = false, description = "Time around you races." },
	zone_crawl = { name = "Crawling time", harmful = false, description = "Time crawls in this place, for everything in it." },
	knockdown = { name = "Knocked down", harmful = true, description = "You're on the ground." },
	dazed = { name = "Dazed", harmful = true, description = "Your head is ringing: slower, and your spells backfire more." },
	jinxed = { name = "Jinxed", harmful = true, description = "Luck has turned on you: hits on you crit more often." },
	chilled = { name = "Chilled", harmful = true, description = "Cold to the bone: slower. Two more chills and you freeze." },
	frozen = { name = "Frozen", harmful = true, description = "Frozen solid: you can't move or cast." },
	downed = { name = "Down", harmful = false, description = "You're down. You can't move or cast until you come round." },
	struggling = { name = "Struggling", harmful = false, description = "Your spell is locked against another. Click to pour more in, jump to let go." },
	suffocating = { name = "Suffocating", harmful = true, description = "You can't get your breath: slower, losing health and stamina." },
	irradiated = { name = "Irradiated", harmful = true, description = "A sickness in you that keeps hurting." },
	crumbling = { name = "Crumbling", harmful = true, description = "What holds you together is loose: you take more from every hit." },
	soulmarked = { name = "Soul-marked", harmful = true, description = "Your soul is marked: you take more from every hit." },
	withering = { name = "Withering", harmful = true, description = "A rot that gets worse every second." },
	aged = { name = "Aged", harmful = true, description = "Years laid on you: slower, and your magic hits softer." },
	sapped = { name = "Sapped", harmful = true, description = "Your life is draining away: slower and losing health." },
	gravity_held = { name = "Held", harmful = true, description = "Gravity has you: you can't move, cast or fight until it lets go." },
	gravity_heavy = { name = "Anchor Weight", harmful = false, description = "Slower, but you resist damage, shrug off pushes and your spells hit harder." },
	gravity_light = { name = "Featherweight", harmful = false, description = "Faster, and you jump enormous distances." },
	foreseeing = { name = "Future Sight", harmful = false, description = "You see where spells are aimed, and some hits miss you." },
	space_sealed = { name = "Sealed", harmful = true, description = "Space is closed around you: you can't move or cast, and nothing can reach you." },
	space_stride = { name = "Folding Stride", harmful = false, description = "Space folds under your feet: every step covers far more ground. Hurting someone ends it." },
	-- Reality (Cast/RealityRuntime, docs/Reality.md); harmful must match StatusEffects' defs (Combat.spec).
	reality_favored = { name = "Favored", harmful = false, description = "Luck is with you: your hits crit more, some blows graze off you, and you backfire less." },
	reality_doomed = { name = "Doomed", harmful = true, description = "Luck has left you: hits on you crit more, your blows sometimes miss, and you backfire more." },
	reality_sealed = { name = "Fate-sealed", harmful = true, description = "Your fate is fixed: the next hits from whoever sealed it are certain to crit." },
	reality_fated = { name = "Twist of Fate", harmful = false, description = "A direct blow on you is cancelled, and part of it lands on whoever dealt it." },
	reality_undying = { name = "Undying", harmful = false, description = "Nothing can take you below 1 health." },
	reality_frayed = { name = "Frayed", harmful = true, description = "You're coming apart at the edges: you take more damage." },
	reality_polymorphed = { name = "Polymorphed", harmful = true, description = "You're a small creature for now: no casting, attacks or dashes, and slower." },
	surging = { name = "Surging", harmful = false, description = "You hit harder, resist damage, move faster and cast for less. Press K to end it with a blast." },
}

return table.freeze(StatusInfo)
