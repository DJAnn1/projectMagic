--!strict
--[[
	MasteryTiers: the nine stages of mastery in a branch, and the XP curve beneath them.

	Mastery (0-100) is what MagicCore uses; it's derived from XP:
		xpForMastery(m) = xpScale * m ^ xpExponent      masteryForXp(xp) = (xp / xpScale) ^ (1 / xpExponent)

	Each tier opens verbs and forms (on top of the branch-depth gates) and raises the power
	ceiling. Tiers marked `breakthrough` can't be entered by XP alone: mastery holds just below
	them until the breakthrough's requirements are completed (see server Progression/Breakthroughs).
	Any unlocked branch counts as at least Sensing.

	Projectile opens at Sensing (2026-11-05, docs/EarlyGamePlan.md item 3): ranged magic is never
	gated behind a task; the Sensing power ceiling (1) is what keeps a first bolt weak.
]]
local Types = require(script.Parent.Parent.Types)

local MasteryTiers = {
	xpScale = 2.3,
	xpExponent = 2.56,

	tiers = {
		{
			index = 0, id = "untouched", name = "Untouched", minMastery = 0, powerCeiling = 0, breakthrough = false,
			verbs = {}, forms = {}, vfxScale = 0,
			unlocks = "Nothing yet. The branch is unknown to you.",
			look = "-",
		},
		{
			index = 1, id = "sensing", name = "Sensing", minMastery = 1, powerCeiling = 1, breakthrough = false,
			verbs = { "sense", "generate" }, forms = { "touch", "aura", "projectile" }, vfxScale = 0.2,
			unlocks = "Feel the branch's property around you; make the tiniest effects (a glow, a nudged pebble) and throw them.",
			look = "A faint flicker in your palette; barely visible.",
		},
		{
			index = 2, id = "novice", name = "Novice", minMastery = 10, powerCeiling = 3, breakthrough = false,
			verbs = { "amplify", "reduce" }, forms = { "burst" }, vfxScale = 0.4,
			unlocks = "Strengthen or weaken what's already there; burst small effects around a point.",
			look = "A steady glow; simple, slightly unstable particles.",
		},
		{
			index = 3, id = "adept", name = "Adept", minMastery = 25, powerCeiling = 5, breakthrough = false,
			verbs = { "transfer", "redirect", "store", "release" }, forms = { "beam", "wall", "pillar", "chain" }, vfxScale = 0.6,
			unlocks = "Move and steer existing energy and matter; shape walls, beams and pillars.",
			look = "Clean shapes; your signature colours become recognisable.",
		},
		{
			index = 4, id = "skilled", name = "Skilled", minMastery = 40, powerCeiling = 6, breakthrough = false,
			verbs = { "transmute", "bind" }, forms = { "zone" }, vfxScale = 0.75,
			unlocks = "Change what things are and bind them; hold areas. Specialization commitments open.",
			look = "Your signature particle style appears; casting has a distinct sound.",
		},
		{
			index = 5, id = "expert", name = "Expert", minMastery = 55, powerCeiling = 7, breakthrough = true,
			verbs = {}, forms = { "summon" }, vfxScale = 0.9,
			unlocks = "Give your magic a body (summons). Noticeably cheaper and steadier casting.",
			look = "Residual sparks linger after casts; your aura is visible to sensitives.",
		},
		{
			index = 6, id = "master", name = "Master", minMastery = 70, powerCeiling = 8, breakthrough = true,
			verbs = {}, forms = { "ritual" }, vfxScale = 1.05,
			unlocks = "Rituals; landscape-scale workings in deep branches. You can mentor others to unlock branches.",
			look = "The environment answers: dust lifts, water ripples, embers drift around you while casting.",
		},
		{
			index = 7, id = "grandmaster", name = "Grandmaster", minMastery = 85, powerCeiling = 10, breakthrough = true,
			verbs = {}, forms = {}, vfxScale = 1.2,
			unlocks = "Power 10 in world-altering branches: region-scale events, with giant costs and cooldowns.",
			look = "Your palette saturates the area; a persistent ambient effect follows you.",
		},
		{
			index = 8, id = "transcendent", name = "Transcendent", minMastery = 100, powerCeiling = 10, breakthrough = true,
			verbs = {}, forms = {}, vfxScale = 1.35,
			unlocks = "No overreach instability: you cast at your ceiling as steadily as at your comfort. Extremely rare.",
			look = "Magic bends toward you; spells take on your signature even when others cast them nearby.",
		},
	} :: { Types.MasteryTierDef },
}

return MasteryTiers
