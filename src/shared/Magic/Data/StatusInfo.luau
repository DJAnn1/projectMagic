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
	knockdown = { name = "Knocked down", harmful = true, description = "You're on the ground." },
	dazed = { name = "Dazed", harmful = true, description = "Your head is ringing: slower, and your spells backfire more." },
	jinxed = { name = "Jinxed", harmful = true, description = "Luck has turned on you: hits on you crit more often." },
	gravity_held = { name = "Held", harmful = true, description = "Gravity has you: you can't move, cast or fight until it lets go." },
	gravity_heavy = { name = "Anchor Weight", harmful = false, description = "Slower, but you resist damage, shrug off pushes and your spells hit harder." },
	gravity_light = { name = "Featherweight", harmful = false, description = "Faster, and you jump enormous distances." },
	foreseeing = { name = "Future Sight", harmful = false, description = "You see where spells are aimed, and some hits miss you." },
	surging = { name = "Surging", harmful = false, description = "You hit harder, resist damage, move faster and cast for less. Press K to end it with a blast." },
}

return table.freeze(StatusInfo)
