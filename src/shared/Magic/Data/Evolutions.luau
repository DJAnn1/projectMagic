--!strict
--[[
	Evolutions: spells grow with mastery, like a boss changing phase, and harmful verbs each have a
	flavour (docs/SpellOverhaul.md §2D and §9, stage 4). Read by Shared/Magic/Evolution (the rules,
	and the Composer's words), Server/Magic/Cast/Shapes (shape growth) and
	Server/Magic/Cast/PropertyBehaviour (Master and Grandmaster, verb flavours).

	Tiers are mastery in the spell's branch: 5 Expert, 6 Master, 7 Grandmaster, 8 Transcendent.
		Expert        the shape grows once (`shapeGrowth`: added to the shape's own numbers)
		Master        a behaviour's "strong enough" effects (minPower) work at any power, and its
		              statuses last `master.durationMult` longer
		Grandmaster   a finisher: a hit on someone already carrying `needs` sets it off
		Transcendent  the shape grows a second time; finishers hit `transcendent.finisherMult` harder

	Finisher fields
		needs    a status the target must already carry (checked before this hit's own effects)
		share    an extra hit, as a share of the spell's base hit
		clear    true: `needs` is used up
		status   { id, duration }: applied to the target
		spread   { radius, share }: the extra hit also lands on up to 4 others around them
		heal     a share of the extra hit's damage that heals the caster
		words    what the Composer says
	A target can be finished once every `finisherGap` seconds (rains and pulses don't chain them).

	Verb flavours (only the plain-damage `harm` route: elsewhere the verb already picks what a
	spell does): `share` multiplies the main hit; then at most one of
		status { id, duration }   pull { speed }   heal (share of the damage)   splash { radius, share }
	Tuning status: first pass, 2026-11-13, not yet played.
]]

export type Finisher = {
	needs: string,
	share: number?,
	clear: boolean?,
	status: { id: string, duration: number }?,
	spread: { radius: number, share: number }?,
	heal: number?,
	words: string,
}

export type Flavour = {
	share: number?,
	status: { id: string, duration: number }?,
	pull: { speed: number }?,
	heal: number?,
	splash: { radius: number, share: number }?,
	words: string,
}

local finishers: { [string]: Finisher } = {
	cold = { needs = "frozen", share = 0.9, clear = true, words = "a hit on someone frozen shatters the ice for a heavy blow" },
	phase = { needs = "frozen", share = 0.9, clear = true, words = "a hit on someone frozen shatters the ice for a heavy blow" },
	heat = { needs = "burning", share = 0.35, spread = { radius = 7, share = 0.25 }, words = "a hit on someone burning flares up and scorches those beside them" },
	temperature = { needs = "burning", share = 0.35, spread = { radius = 7, share = 0.25 }, words = "a hit on someone burning flares up and scorches those beside them" },
	combustion = { needs = "burning", share = 0.45, spread = { radius = 8, share = 0.3 }, words = "a hit on someone burning explodes, scorching those beside them" },
	charge = { needs = "dazed", share = 0.3, spread = { radius = 12, share = 0.35 }, words = "a hit on someone dazed arcs on to others nearby" },
	luminosity = { needs = "blind", share = 0.55, words = "a hit on someone blinded sears them for a heavy blow" },
	radiation = { needs = "irradiated", share = 0.3, spread = { radius = 8, share = 0.25 }, words = "a hit on someone sick with it bursts, sickening those nearby" },
	sound = { needs = "dazed", share = 0.4, status = { id = "knockdown", duration = 1.2 }, words = "a hit on someone dazed knocks them flat" },
	resonance = { needs = "crumbling", share = 0.6, clear = true, words = "a hit on someone crumbling shatters them" },
	momentum = { needs = "knockdown", share = 0.6, words = "a hit on someone already down crushes them" },
	weight = { needs = "knockdown", share = 0.7, words = "a hit on someone already down crushes them" },
	orientation = { needs = "dazed", share = 0.3, status = { id = "knockdown", duration = 1.4 }, words = "a hit on someone dizzy throws them to the ground" },
	pressure = { needs = "slow", share = 0.45, words = "a hit on someone slowed crushes the air out of them" },
	flow = { needs = "slow", share = 0.35, status = { id = "knockdown", duration = 1 }, words = "a hit on someone sodden sweeps them off their feet" },
	breath = { needs = "suffocating", share = 0.3, status = { id = "knockdown", duration = 1.2 }, words = "a hit on someone choking drops them" },
	cohesion = { needs = "crumbling", share = 0.7, clear = true, words = "a hit on someone crumbling shatters them" },
	vitality = { needs = "sapped", share = 0.45, heal = 0.6, words = "a hit on someone sapped drinks their life: you heal" },
	metabolism = { needs = "sapped", share = 0.45, heal = 0.6, words = "a hit on someone sapped drinks their life: you heal" },
	soul = { needs = "soulmarked", share = 0.55, status = { id = "soulmarked", duration = 6 }, words = "a hit on a marked soul tears at it and marks it again" },
	essence = { needs = "silence", share = 0.55, words = "a hit on someone who can't cast burns what magic is left in them" },
	unlife = { needs = "withering", share = 0.6, spread = { radius = 7, share = 0.2 }, words = "a hit on someone withering makes the rot bloom onto others nearby" },
	age = { needs = "aged", share = 0.65, status = { id = "jinxed", duration = 4 }, words = "a hit on someone aged turns them brittle as dust" },
}

local verbs: { [string]: Flavour } = {
	generate = { words = "Generate: a plain, steady blow." },
	amplify = { share = 1.2, words = "Amplify: it hits a fifth harder." },
	reduce = { share = 0.9, status = { id = "slow", duration = 2.5 }, words = "Reduce: a little softer, but it slows them." },
	transfer = { heal = 0.2, words = "Transfer: a fifth of the damage heals you." },
	redirect = { pull = { speed = 34 }, words = "Redirect: it drags them toward you." },
	release = { share = 0.95, splash = { radius = 6, share = 0.3 }, words = "Release: it bursts onto others beside them." },
	transmute = { status = { id = "jinxed", duration = 4 }, words = "Transmute: it unsettles their luck: crits find them easily for a while." },
	bind = { share = 0.85, status = { id = "root", duration = 1.2 }, words = "Bind: softer, but it roots them in place for a moment." },
}

return table.freeze({
	tiers = table.freeze({ expert = 5, master = 6, grandmaster = 7, transcendent = 8 }),
	shapeGrowth = table.freeze({
		echo = { share = 0.15 },
		split = { count = 2, share = 0.05 },
		lob = { splash = 3, share = 0.1 },
		skip = { bounces = 1 },
		drain = { back = 0.1 },
		nova = { scale = 0.4, share = 0.1 },
		linger = { seconds = 2 },
		barrier = { seconds = 3 },
		erupt = { lift = 12 },
		rain = { drops = 2 },
		pulse = { count = 1 },
	} :: { [string]: { [string]: number } }),
	shapeWords = table.freeze({
		echo = "the echo hits harder",
		split = "two more shards fly",
		lob = "a wider splash",
		skip = "one more skip",
		drain = "you drink more of it",
		nova = "a wider, harder second ring",
		linger = "the area lasts 2 s longer",
		barrier = "it stands 3 s longer",
		erupt = "it throws them higher",
		rain = "two more drops fall",
		pulse = "one more ring",
	} :: { [string]: string }),
	master = table.freeze({ durationMult = 1.25 }),
	transcendent = table.freeze({ finisherMult = 1.5 }),
	finisherGap = 1.0,
	finishers = finishers,
	verbs = verbs,
	-- Only these routes take a verb's flavour (plain damage: the verb is otherwise meaningless).
	flavourRoutes = table.freeze({ harm = true }),
})
