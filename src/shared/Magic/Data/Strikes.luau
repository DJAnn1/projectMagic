--!strict
--[[
	Strikes: every domain's first attack. Key = domain id; every domain must have one (Registry).

	The guarantee (docs/Combat.md §14, Tests/EarlyGame.spec): a caster at Sensing can build a
	damaging spell from their domain's ROOT branch with `generate` + `touch`, and at Novice a
	ranged one with `generate` + `projectile`.

	property : a property of the domain's ROOT branch (Registry checks)
	verbs    : the verbs that make this a strike (generate: the only attacking verb at Sensing)
	forms    : default touch, projectile, beam, chain (minus forms that block the category)
	native   : an existing EffectLibrary route already makes this attack (Thermal, Impact...).
	           The `strike` route skips native strikes; the data still names them for the UI.
	share    : non-native only: damage as a share of the base hit (DamageModel.base). Exotic
	           domains trade raw damage for their rider, never more than the energy baseline.
	rider    : non-native only: the small extra each hit carries (Cast/Effects/Strike)
		status    StatusEffects id applied on hit
		duration  seconds
		chance    0..1, rolled on the cast's seeded rng (default 1)
		dotShare  for a damage-over-time status: total extra damage over the duration, as a
		          share of the base hit
		strip     remove this many beneficial statuses
		shove     sideways shove, studs/s
		word      what the Composer shows ("slows", "dazes" ...)

	Parity at equal power (base = 9·power^0.6; Thermal heat is 0.8, Impact is 1.0):
		energy  0.80 + burn at P3   water 0.80 + burn at P3   air 1.00   gravity 1.00   spirit 1.00
		earth   1.00 + 30% slow     life  0.90 + 50% slow      mind 0.80 + daze (unblockable)
		void    0.85 + strip one    space 0.90 + shove         time 0.55 + 0.40 rot DoT (unblockable)
		reality 0.85 + jinx (crits more likely on the target)
]]
local Types = require(script.Parent.Parent.Types)

local Strikes: { [string]: Types.StrikeDef } = {
	-- Native: the root already attacks through an existing route.
	energy = {
		name = "Scorch", property = "temperature", verbs = { "generate" }, native = "thermal",
		flavour = "A flare of raw heat from your hand.",
	},
	water = {
		name = "Scald", property = "temperature", verbs = { "generate" }, native = "thermal",
		flavour = "A spray of near-boiling water.",
	},
	air = {
		name = "Thunderclap", property = "sound", verbs = { "generate" }, native = "harm",
		flavour = "A crack of compressed sound that hits like a fist.",
	},
	gravity = {
		name = "Press", property = "weight", verbs = { "generate" }, native = "harm",
		flavour = "A sudden, crushing heaviness on one body.",
	},
	spirit = {
		name = "Soul Prick", property = "essence", verbs = { "generate" }, native = "harm",
		flavour = "A needle of spirit straight into the self.",
	},

	-- Strike route: these roots have no harmful property of their own.
	earth = {
		name = "Stone Shot", property = "hardness", verbs = { "generate" }, share = 1.0,
		rider = { status = "slow", duration = 1, chance = 0.3, word = "may stagger" },
		flavour = "A fist-sized stone, hardened in the air and hurled.",
	},
	life = {
		name = "Thornlash", property = "growth", verbs = { "generate" }, share = 0.9,
		rider = { status = "slow", duration = 1.5, chance = 0.5, word = "may snare" },
		flavour = "Growth forced too fast: a lash of thorns.",
	},
	mind = {
		name = "Psychic Spike", property = "perception", verbs = { "generate" }, share = 0.8,
		rider = { status = "dazed", duration = 2, word = "dazes (shaky casting)" },
		flavour = "Too much sensation at once, driven behind the eyes.",
	},
	void = {
		name = "Unmake", property = "aether", verbs = { "generate" }, share = 0.85,
		rider = { strip = 1, word = "strips a blessing" },
		flavour = "A hollow pulse that eats whatever magic it meets.",
	},
	space = {
		name = "Shear", property = "distance", verbs = { "generate" }, share = 0.9,
		rider = { shove = 40, word = "shoves aside" },
		flavour = "A sliver of space opens through the target, and closes.",
	},
	time = {
		name = "Hasten Decay", property = "tempo", verbs = { "generate" }, share = 0.55,
		rider = { status = "rot", duration = 3, dotShare = 0.4, word = "ages (rot)" },
		flavour = "A pulse of runaway time: years pass in one spot of flesh.",
	},
	reality = {
		name = "Misfortune", property = "probability", verbs = { "generate" }, share = 0.85,
		rider = { status = "jinxed", duration = 4, word = "jinxes (crits likelier)" },
		flavour = "The odds turn against them, and so does the blow.",
	},
}

return table.freeze(Strikes)
