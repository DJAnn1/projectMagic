--!strict
--[[
	PropertyBehaviours: what a harmful spell does BESIDES its damage, by property (docs/SpellOverhaul.md
	§2A, stage 1). Before this, every harmful property the routes didn't claim was plain damage
	(Effects/Impact): `spellaudit` counted 7,496 recipes that way. Now each one has its own rule,
	applied by Server/Magic/Cast/PropertyBehaviour after a hit lands (a fully warded or blocked hit
	gets nothing extra). Shared, because the Composer says what each one does (Data/RouteSummaries).

	A behaviour is a list of effects, tried in order:
		status    { id, duration, dotShare?, magnitude?, chance?, onCrit?, minPower? }
		          dotShare: the status's damage over its whole duration as a share of the spell's
		          base hit (DamageModel.base(power)), so damage over time grows with power like hits do
		stack     { id, duration, max, at = { id, duration } }: each hit adds a stack (and applies
		          `id`); at `max` stacks they turn into `at` and clear (chill -> freeze)
		knockback { speed, perPower, up }: away from the caster (players: on their own client)
		echo      { delay, share, minPower? }: the same hit lands again `delay` seconds later
		drain     { what = "reservoir" | "stamina", amount, perPower, back? }: takes from a player
		          (back: the share the caster gets); NPCs are silenced for `silence` seconds instead
		spread    { radius, id, duration, dotShare, minPower }: the status jumps to people beside them
		grow      { id, duration, dotShare, factor }: a damage over time that gets worse every second
	Variants: `byVerb` = { [verb] = behaviour id } picks another behaviour for some verbs (phase:
	amplify scalds instead of chilling). Resolvers that know better pass an id directly (Thermal:
	heat, cold, combustion).

	Budget: a behaviour's extra damage is about a third of a hit (dotShare 0.25 to 0.4, echo 0.5).
	Tuning status: first guesses, not yet played.
]]

export type Effect = { [string]: any }
export type Behaviour = { summary: string, effects: { Effect }, byVerb: { [string]: string }? }

local B: { [string]: Behaviour } = {
	-- ─── Fire and frost (also used by Effects/Thermal) ──────────────────────
	combustion = {
		summary = "Sets them burning. Strong enough, the fire jumps to whoever stands beside them.",
		effects = {
			{ kind = "status", id = "burning", duration = 3, dotShare = 0.35 },
			{ kind = "spread", radius = 7, id = "burning", duration = 2, dotShare = 0.2, minPower = 6 },
		},
	},
	heat = {
		summary = "Scalds them: they keep burning for a moment.",
		effects = { { kind = "status", id = "burning", duration = 2, dotShare = 0.25 } },
	},
	cold = {
		summary = "Chills them, slowing them more with every hit. Three chills freeze them solid.",
		-- 4 s between chills (was 3: charged casts couldn't chain three in time, 2026-11-13).
		-- Freeze 2 s (was 1.4; owner, 2026-11-13: "only half a second at most"), x1.25 from Master.
		effects = { { kind = "stack", id = "chilled", duration = 4, max = 3, at = { id = "frozen", duration = 2 } } },
	},
	temperature = {
		summary = "Heat that lingers: they keep burning for a moment.",
		effects = { { kind = "status", id = "burning", duration = 2, dotShare = 0.25 } },
	},
	phase = {
		summary = "Turns the water in them to ice: chills that build into a freeze. Amplified, it boils instead.",
		effects = { { kind = "stack", id = "chilled", duration = 4, max = 3, at = { id = "frozen", duration = 1.8 } } },
		byVerb = { amplify = "heat", generate = "heat" },
	},

	-- ─── Energy ──────────────────────────────────────────────────────────────
	charge = {
		summary = "Lightning: it runs through metal and water, and often leaves them dazed.",
		effects = {
			{ kind = "status", id = "dazed", duration = 1.2, chance = 0.35 },
			{ kind = "status", id = "knockdown", duration = 1, onCrit = true, minPower = 6 },
		},
	},
	luminosity = {
		summary = "Searing light: a crit blinds them. Strong enough, it leaves them reeling.",
		effects = {
			{ kind = "status", id = "blind", duration = 2, onCrit = true },
			{ kind = "status", id = "blind", duration = 1.2, chance = 0.2 },
			{ kind = "status", id = "dazed", duration = 1.5, minPower = 6, chance = 0.4 },
		},
	},
	radiation = {
		summary = "A sickness that lingers long after the hit.",
		effects = { { kind = "status", id = "irradiated", duration = 6, dotShare = 0.4 } },
	},

	-- ─── Kinetic ─────────────────────────────────────────────────────────────
	sound = {
		summary = "A shockwave: throws them back and leaves them deafened, unable to cast for a moment.",
		effects = {
			{ kind = "knockback", speed = 30, perPower = 4, up = 0.35 },
			{ kind = "status", id = "silence", duration = 0.6 },
			{ kind = "status", id = "dazed", duration = 1.2, minPower = 5 },
		},
	},
	resonance = {
		summary = "Sets them ringing: a moment later they shatter for a second hit.",
		effects = { { kind = "echo", delay = 1.2, share = 0.5 }, { kind = "echo", delay = 1.2, share = 0.3, minPower = 6 } },
	},
	momentum = {
		summary = "Hits like a falling wall: they're thrown back hard.",
		effects = { { kind = "knockback", speed = 38, perPower = 5, up = 0.3 } },
	},
	weight = {
		summary = "Crushing weight: it can knock them flat, and a crit always does.",
		effects = {
			{ kind = "status", id = "knockdown", duration = 1.2, chance = 0.25 },
			{ kind = "status", id = "knockdown", duration = 1.4, onCrit = true },
			{ kind = "status", id = "slow", duration = 2 },
		},
	},
	orientation = {
		summary = "Twists which way is down for them: they stagger, dizzy.",
		effects = { { kind = "status", id = "dazed", duration = 2 }, { kind = "knockback", speed = 18, perPower = 2, up = 0.6 } },
	},

	-- ─── Fluid ───────────────────────────────────────────────────────────────
	pressure = {
		summary = "A blast of pressure that throws them back.",
		effects = { { kind = "knockback", speed = 32, perPower = 4, up = 0.25 } },
	},
	flow = {
		summary = "A rush of water: shoves them and leaves them sodden and slow.",
		effects = { { kind = "knockback", speed = 24, perPower = 3, up = 0.15 }, { kind = "status", id = "slow", duration = 1.8 } },
	},
	breath = {
		summary = "Takes the air from them: they choke, slow down and tire.",
		effects = {
			{ kind = "status", id = "suffocating", duration = 3, dotShare = 0.25 },
			{ kind = "drain", what = "stamina", amount = 15, perPower = 3 },
		},
	},

	-- ─── Material ────────────────────────────────────────────────────────────
	cohesion = {
		summary = "Loosens what holds them together: they crumble, and every hit hurts more for a while.",
		effects = { { kind = "status", id = "crumbling", duration = 5 } },
	},

	-- ─── Vital ───────────────────────────────────────────────────────────────
	vitality = {
		summary = "Saps their life: they weaken, slow and keep losing health.",
		effects = { { kind = "status", id = "sapped", duration = 4, dotShare = 0.3 } },
	},
	metabolism = {
		summary = "Upsets their body: sapped, slow and sick for a while.",
		effects = { { kind = "status", id = "sapped", duration = 4, dotShare = 0.3 } },
	},

	-- ─── Spiritual ───────────────────────────────────────────────────────────
	soul = {
		summary = "Marks their soul: they take more from every hit for a while.",
		effects = { { kind = "status", id = "soulmarked", duration = 6 } },
	},
	essence = {
		summary = "Burns their magic: a mage loses reservoir (half of it comes to you); others can't cast for a moment.",
		effects = { { kind = "drain", what = "reservoir", amount = 3, perPower = 2, back = 0.5, silence = 1.5 } },
	},
	unlife = {
		summary = "Withering: a rot that gets worse every second it's left.",
		effects = { { kind = "grow", id = "withering", duration = 4, dotShare = 0.3, factor = 1.35 } },
	},

	-- ─── Temporal ────────────────────────────────────────────────────────────
	age = {
		summary = "Ages them: slower and weaker. Strong enough, they turn brittle and crits find them easily.",
		effects = {
			{ kind = "status", id = "aged", duration = 5, magnitude = -0.15 },
			{ kind = "status", id = "jinxed", duration = 4, minPower = 7 },
		},
	},
}

return B
