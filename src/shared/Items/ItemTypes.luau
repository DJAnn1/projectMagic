--!strict
--[[
	ItemTypes: every shape the item system passes around (docs/Items.md §2).

	ItemDef     static definition (Shared/Items/Data/Items). Never saved; looked up by id.
	Record      one item instance as SAVED: short keys, only what differs from the definition.
	ItemView    a Record as sent to its owner: the record plus a location ref and two flags the
	            client can't compute (requirements met, attunement active).
	Sheet       a character's derived stats with a line-by-line breakdown (Shared/Items/StatCalc).
]]

-- ─── Definitions ────────────────────────────────────────────────────────────

-- Who may equip (or attune) an item. Tier keys are a branch id or a domain id (a domain's root
-- branch); "any" means the caster's best tier anywhere. Affinity keys are domain ids (0..1).
export type Requirement = {
	tier: { [string]: number }?,
	affinity: { [string]: number }?,
	awakened: { string }?,
}

-- An effect that only switches on for a wearer who meets `requires` (affinity- or mastery-gated).
export type Attunement = {
	requires: Requirement,
	stats: { [string]: number }?,
	resist: { [string]: number }?,
	text: string, -- shown in the tooltip, e.g. "Answers a strong Fire affinity"
}

export type FocusDef = {
	grade: string, -- "major" (held: wand, staff, orb, tome) | "minor" (worn: ring, amulet)
	domains: { [string]: number }?, -- domain -> spell power bonus (0.1 = +10%); "any" matches all
	stability: number?, -- 0..1 lower backfire chance for spells this focus matches
}

export type WeaponDef = {
	kind: string, -- "sword" | "axe" | "spear" | "dagger" | "staff" | "bow" | "crossbow" | "thrown"
	damage: number, -- base hit (Combat stage: through DamageModel with the weapon's damage type)
	damageType: string, -- a resistance key: "momentum" (blunt/cut), "combustion", ...
	speed: number, -- swings per second (ranged: shots per second at most)
	reach: number, -- studs (ranged: the furthest an aim point may be)
	stamina: number, -- stamina per swing or shot
	-- Ranged only (Shared/Items/WeaponRules): the item tag a shot uses up ("arrow", "bolt",
	-- "thrown_knife"); one item carrying it is taken from the grid per shot.
	ammo: string?,
}

export type EquipDef = {
	slots: { string }, -- EquipSlots ids this item may occupy (rings list both ring slots)
	twoHanded: boolean?, -- main hand only; the off hand must stay empty
	stats: { [string]: number }?, -- base stats, scaled by rarity and quality
	resist: { [string]: number }?, -- base resistances, scaled the same way
	durability: number?, -- max durability (nil = never wears)
	affixClass: string?, -- which affix pool can roll on it (nil = no random affixes)
	attune: Attunement?,
	bagSlots: number?, -- containers: extra inventory slots while equipped in a bag slot
}

export type UseEffect = {
	kind: string, -- ItemUse handler: heal | reservoir | buff | study | spell | repair | cleanse
	[string]: any,
}

export type UseDef = {
	effects: { UseEffect },
	consume: boolean?, -- default true
	cooldown: number?, -- seconds, per item id
	group: string?, -- shared cooldown group (e.g. all potions)
	needsAim: boolean?, -- spell scrolls: the client sends its aim point
}

export type ModelDef = {
	shape: string, -- GearVisuals builder id
	color: Color3?,
	material: Enum.Material?,
	glow: Color3?, -- PointLight colour (torches, artifacts)
}

export type ItemDef = {
	id: string,
	name: string,
	description: string,
	category: string, -- ItemRules.categories id
	rarity: string, -- base rarity (Rarities id); random variants roll their own
	stack: number, -- max stack size; 1 = unique instance (gets a uid)
	weight: number, -- per unit
	value: number, -- base coin value per unit (Common, quality 50)
	icon: string, -- rbxassetid; "" = the generated glyph icon
	glyph: string, -- 1-2 characters drawn on the generated icon
	color: Color3, -- icon tint and default model colour
	tags: { string },
	requires: Requirement?,
	equip: EquipDef?,
	focus: FocusDef?,
	weapon: WeaponDef?,
	use: UseDef?,
	model: ModelDef?,
	unique: boolean?, -- at most one per player (artifacts)
	quest: boolean?, -- can't be dropped or sold; removed by its quest
	bind: string?, -- "pickup" | "equip": becomes bound (untradeable) then
	data: { [string]: any }?, -- category-specific extras (ore tier, herb potency, key id...)
}

export type AffixDef = {
	id: string,
	name: string, -- "Ember-touched" (prefix) or "of Resonance" (suffix)
	kind: string, -- "prefix" | "suffix"
	group: string, -- one affix per group per item
	on: { string }, -- affix classes it can roll on
	minRarity: number, -- Rarities index
	weight: number,
	stats: { [string]: { number } }?, -- stat -> { min, max }
	resist: { [string]: { number } }?,
	set: string?, -- Sets id (set bonus while enough pieces are worn)
	attune: Requirement?, -- the affix only works for a wearer who meets this
	text: string?, -- extra tooltip text
}

export type SetDef = {
	id: string,
	name: string,
	bonuses: { { pieces: number, stats: { [string]: number }?, resist: { [string]: number }? } },
}

export type RarityDef = {
	id: string,
	index: number,
	name: string,
	glyph: string,
	color: Color3,
	affixes: number, -- random affixes rolled
	band: { number }, -- { lo, hi }: the slice of every affix's range this rarity rolls in
	baseMult: number, -- multiplier on the definition's base stats
	valueMult: number,
	weight: number, -- default drop weight (loot stage adjusts by luck/danger)
}

export type StatDef = {
	id: string,
	name: string,
	format: string, -- "flat" | "pct" | "int" | "rate"
	base: number, -- value before any layer
	min: number?,
	max: number?,
	pctOf: string?, -- a *Pct stat that multiplies another stat
	group: string, -- sheet section: "vitals" | "magic" | "movement" | "combat"
	wired: string?, -- when not live yet: which stage makes it matter (shown in the breakdown)
	description: string,
}

-- ─── Instances ──────────────────────────────────────────────────────────────

-- Saved keys are short on purpose: a full inventory is ~80 records in every player save.
export type Record = {
	i: string, -- item id
	n: number?, -- count (nil = 1)
	u: string?, -- unique id (uniques only: stack 1). Minted once, never reused.
	r: number?, -- rarity index (nil = the definition's rarity)
	a: { [string]: number }?, -- affix id -> roll 0..999 (value re-derived from the tables)
	d: number?, -- current durability (nil = full)
	q: number?, -- crafted quality 0..100 (nil = 50, standard)
	c: string?, -- crafter's display name (signature)
	cn: string?, -- custom name, already text-filtered (crafting stage)
	b: boolean?, -- bound to its owner (untradeable)
	f: number?, -- flag bits: 1 favourite, 2 locked, 4 new (unseen)
	ch: number?, -- charges (imbued items)
	t: number?, -- unix time minted (uniques)
}

export type ItemView = {
	ref: string, -- "s12" grid slot, "e:head" equipment
	rec: Record,
	ok: boolean, -- requirements met (equip allowed / effects active)
	att: boolean?, -- attunement active (only for items with one)
}

export type InventoryView = {
	rev: number,
	currency: number,
	rare: number,
	capacity: number,
	weight: number,
	carry: number,
	load: string, -- ItemRules.encumbrance state id
	items: { ItemView }, -- grid and equipment together
	quick: { [string]: string }, -- "1".."4" -> "i:<itemId>" | "u:<uid>"
	stats: { [string]: number }, -- final stats (the sheet's totals)
	resist: { [string]: number },
	focus: string, -- "major" | "minor" | "none"
	cooldowns: { [string]: number }, -- use cooldown key -> server time ready
}

-- ─── Stats ──────────────────────────────────────────────────────────────────

export type Layer = {
	source: string, -- "base" | "profile" | "mastery" | "gear" | "set" | "buff" | "load"
	label: string, -- what the player reads: "Oak Staff", "Forgeborn (2)", "Well fed"
	stats: { [string]: number }?,
	resist: { [string]: number }?,
}

export type SheetLine = { stat: string, source: string, label: string, value: number }

export type Sheet = {
	final: { [string]: number },
	resist: { [string]: number },
	lines: { SheetLine },
	weight: number,
	carry: number,
	load: string,
}

return {}
