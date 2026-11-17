--!strict
--[[
	Weight: how hits and casts feel in the body (docs/Smoothness.md, stage 6). Data only; read by
	Client/Fx/CombatFeedback (hit-stop), Client/Fx/Flinch, Client/Fx/SpellFx (the step) and
	Controllers/CastClient (the input buffer). The cancel window lives with the action states
	(Data/CombatAnimations `cancelLast`, read by Magic/ActionRules.allowsAt on both sides).

	Nothing here turns the camera (owner, 2026-11-17: spells must not move your view).

	HITSTOP   your own spell landing freezes your own animation for a moment: `base` seconds plus
	          `perShare` x the share of the target's health it took, at most `max`
	FLINCH    a player hit by a spell tilts away from where it came from (their root joint, on every
	          client), up to `degrees` at `fullShare` of their health; back over `seconds`. NPCs
	          flinch on the server already (Cast/HitReactions).
	STEP      your own spells of these forms carry you a little forward as they land
	BUFFER    a cast pressed this close to the end of the one before is kept and fired the moment
	          you're free, instead of being refused
]]

local Weight = {}

Weight.hitStop = table.freeze({
	base = 0.035,
	perShare = 0.15,
	max = 0.09,
})

Weight.flinch = table.freeze({
	degrees = 14,
	fullShare = 0.25,
	minShare = 0.02, -- smaller hits don't flinch
	seconds = 0.3,
	rise = 0.06, -- seconds to the full tilt
})

Weight.step = table.freeze({
	enabled = true,
	forms = { touch = true } :: { [string]: boolean },
	speed = 16, -- studs/s
	seconds = 0.12, -- about 2 studs
})

Weight.buffer = table.freeze({
	seconds = 0.3,
})

return Weight
