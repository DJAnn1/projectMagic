--!strict
--[[
	WeaponTuning: how item weapons fight (docs/Items.md §10). Shared: the server times and resolves
	attacks (Services/WeaponService), the client predicts them (Controllers/WeaponClient).

	A weapon's own numbers (damage, speed, reach, stamina, ammo) live on its item (Data/Items,
	def.weapon); this file says how each KIND uses them.

	MELEE KINDS (sword, axe, spear, dagger, staff)
		swings    the combo, in order, then round again. Times are seconds at speed 1; a weapon's
		          speed / speedRef (x attack speed) divides them, clamped to minSpeed..maxSpeed.
		            clip       the animation (Data/CombatAnimations); `wants` names the bespoke
		                       clip this swing should get one day (see `animations` below)
		            duration, hitFrom, hitTo, comboFrom   as the spellblade (Data/MeleeTuning)
		            share      share of the weapon's hit this swing deals
		            width/height  the hit box (studs); its depth is the weapon's reach
		            knockback  push on a hit (studs/s)
		            stamina    x the weapon's stamina cost
		critBonus  added to the base crit chance (daggers find gaps)
	RANGED KINDS (bow, crossbow, thrown)
		draw       bow: hold to draw. Below drawMin the shot is refused; the hit's share grows
		           from minShare at drawMin to 1 at drawFull; held past holdMax, stamina drains
		           holdDrainPerSecond and the shot weakens back toward minShare.
		reload     crossbow/thrown: seconds after a shot before the next (the weapon's speed
		           caps it too). A crossbow always hits at full share.
		speed      flight speed (studs/s); gravity (studs/s²); radius (the projectile's hit sphere)
	HITS
		amount     (weapon.damage + attackPower) x share, x critMult on a crit, x (1 - resistance
		           to the damage type), x (1 - defense reduction), then the PvP cap
		defense    reduction = defense / (defense + defenseK), at most maxDefenseReduction
		crit       critBase (+ the kind's critBonus), seeded per attack
		wear       the weapon loses 1 durability per `wearEvery` hits; a broken weapon can't attack
	STAMINA (Services/StaminaService)
		max/regen  from the stat sheet (staminaMax, staminaRegenPct; encumbrance lowers regen)
		regen      regenPerSecond after regenDelay seconds without spending
		blocking   a weapon guard pays staminaPerBlockPoint per point of damage it turns away; at
		           0 stamina the guard breaks
]]

export type Swing = {
	clip: string,
	wants: string?,
	duration: number,
	hitFrom: number,
	hitTo: number,
	comboFrom: number,
	share: number,
	width: number,
	height: number,
	knockback: number,
	stamina: number,
}

export type MeleeKind = {
	swings: { Swing },
	critBonus: number,
	canBlock: boolean,
}

export type RangedKind = {
	draw: { drawMin: number, drawFull: number, holdMax: number, minShare: number, holdDrainPerSecond: number }?,
	reload: number,
	speed: number,
	gravity: number,
	radius: number,
	projectile: string, -- the client's look (Fx/WeaponFx): arrow | bolt | knife
}

local WeaponTuning = {
	speedRef = 1.2, -- a weapon of this speed swings at speed 1
	minSpeed = 0.7,
	maxSpeed = 1.6,
	comboGrace = 0.3,
	samples = 3, -- hit-box sweeps per swing

	melee = {
		sword = {
			swings = {
				{ clip = "Slash1", duration = 0.5, hitFrom = 0.16, hitTo = 0.28, comboFrom = 0.3, share = 0.9, width = 5, height = 5, knockback = 0, stamina = 1 },
				{ clip = "Slash2", duration = 0.55, hitFrom = 0.2, hitTo = 0.34, comboFrom = 0.36, share = 1.1, width = 6, height = 5, knockback = 18, stamina = 1.2 },
			},
			critBonus = 0,
			canBlock = true,
		},
		axe = {
			swings = {
				{ clip = "Slash1", wants = "AxeChop", duration = 0.62, hitFrom = 0.24, hitTo = 0.36, comboFrom = 0.4, share = 1.0, width = 5, height = 6, knockback = 6, stamina = 1 },
				{ clip = "Slash2", wants = "AxeOverhead", duration = 0.75, hitFrom = 0.32, hitTo = 0.46, comboFrom = 0.5, share = 1.35, width = 4, height = 7, knockback = 26, stamina = 1.4 },
			},
			critBonus = 0,
			canBlock = true,
		},
		spear = {
			swings = {
				{ clip = "Slash1", wants = "SpearThrust", duration = 0.55, hitFrom = 0.2, hitTo = 0.3, comboFrom = 0.34, share = 1.0, width = 2.5, height = 4, knockback = 8, stamina = 1 },
				{ clip = "Slash2", wants = "SpearSweep", duration = 0.65, hitFrom = 0.24, hitTo = 0.4, comboFrom = 0.44, share = 0.85, width = 8, height = 4, knockback = 20, stamina = 1.2 },
			},
			critBonus = 0.02,
			canBlock = true,
		},
		dagger = {
			swings = {
				{ clip = "Slash1", wants = "DaggerJab", duration = 0.36, hitFrom = 0.1, hitTo = 0.2, comboFrom = 0.2, share = 0.9, width = 3.5, height = 4, knockback = 0, stamina = 1 },
				{ clip = "Slash2", wants = "DaggerSlash", duration = 0.4, hitFrom = 0.12, hitTo = 0.24, comboFrom = 0.24, share = 1.0, width = 4, height = 4, knockback = 0, stamina = 1 },
			},
			critBonus = 0.08,
			canBlock = false, -- too short to turn a blow
		},
		staff = {
			swings = {
				{ clip = "Slash1", wants = "StaffSwing", duration = 0.55, hitFrom = 0.18, hitTo = 0.32, comboFrom = 0.34, share = 0.9, width = 6, height = 5, knockback = 12, stamina = 1 },
				{ clip = "Slash2", wants = "StaffSweep", duration = 0.6, hitFrom = 0.22, hitTo = 0.38, comboFrom = 0.4, share = 1.0, width = 7, height = 4, knockback = 22, stamina = 1.1 },
			},
			critBonus = 0,
			canBlock = true,
		},
	} :: { [string]: MeleeKind },

	ranged = {
		bow = {
			draw = { drawMin = 0.25, drawFull = 1.0, holdMax = 3.0, minShare = 0.35, holdDrainPerSecond = 8 },
			reload = 0.2,
			speed = 160,
			gravity = 40,
			radius = 0.35,
			projectile = "arrow",
		},
		crossbow = {
			draw = nil,
			reload = 1.6,
			speed = 220,
			gravity = 20,
			radius = 0.35,
			projectile = "bolt",
		},
		thrown = {
			draw = nil,
			reload = 0.45,
			speed = 110,
			gravity = 55,
			radius = 0.4,
			projectile = "knife",
		},
	} :: { [string]: RangedKind },

	hits = {
		critBase = 0.05,
		critMult = 1.5,
		defenseK = 60,
		maxDefenseReduction = 0.6,
		minDamage = 1,
		wearEvery = 4,
	},

	stamina = {
		regenPerSecond = 20,
		regenDelay = 0.9,
		staminaPerBlockPoint = 0.6,
	},

	--[[
		Animations a full weapon set needs (R6, owned by the place's owner). Until they exist, each
		swing plays its `clip` (Slash1/Slash2) and shots use the CastSpell wind-up:
			AxeChop, AxeOverhead          heavy, weight on the front foot
			SpearThrust, SpearSweep       two-handed thrust, wide low sweep
			DaggerJab, DaggerSlash        quick, close
			StaffSwing, StaffSweep        two-handed, wide
			BowDraw (loop, hold at full draw), BowRelease
			CrossbowFire, CrossbowReload
			Throw                         overarm knife throw
		Add each to Data/CombatAnimations.animations with its id, then set the swing's `clip`.
	]]
	animations = {
		"AxeChop", "AxeOverhead", "SpearThrust", "SpearSweep", "DaggerJab", "DaggerSlash",
		"StaffSwing", "StaffSweep", "BowDraw", "BowRelease", "CrossbowFire", "CrossbowReload", "Throw",
	},
}

return WeaponTuning
