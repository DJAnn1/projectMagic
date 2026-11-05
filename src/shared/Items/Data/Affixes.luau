--!strict
--[[
	Affixes: the random prefixes and suffixes item variants roll, and the gear sets
	(docs/Items.md §2.4). Pure data; ItemDatabase validates it at boot.

	An affix rolls one value per stat inside { min, max }, narrowed to the item rarity's band
	(Data/Rarities). Saves keep only the affix id and a roll 0..999, so rebalancing a range here
	re-tunes every existing item at once.

		kind       "prefix" (before the name) | "suffix" ("of ...")
		group      at most one affix per group per item (two domain-power prefixes never stack)
		on         affix classes it rolls on: weapon | focus | armor | jewelry | tool
		minRarity  Rarities index it first appears at (3 = Rare)
		weight     relative odds inside the eligible pool
		stats / resist   { min, max } per stat id (Data/StatDefs) or resistance key
		set        joins a set: wearing enough pieces of it grants the set bonus
		attune     the affix only works for a wearer who meets this (affinity or mastery)

	Int stats (modifierSlots, formTier) always give their max: you can't roll half a slot.
]]

local ItemTypes = require(script.Parent.Parent.ItemTypes)

type AffixDef = ItemTypes.AffixDef

local list: { AffixDef } = {}

local CASTER = { "focus", "jewelry" }
local WEAR = { "armor", "jewelry" }
local ALL_GEAR = { "weapon", "focus", "armor", "jewelry" }

local function affix(def: { [string]: any })
	def.weight = def.weight or 10
	def.minRarity = def.minRarity or 2
	table.insert(list, def :: any)
end

-- ─── Prefixes: domain power ─────────────────────────────────────────────────

affix({ id = "ember_touched", name = "Ember-touched", kind = "prefix", group = "domain", on = { "focus", "weapon", "jewelry" }, stats = { power_energy = { 0.04, 0.12 } } })
affix({ id = "stone_bound", name = "Stone-bound", kind = "prefix", group = "domain", on = { "focus", "weapon", "jewelry" }, stats = { power_earth = { 0.04, 0.12 } } })
affix({ id = "tide_kissed", name = "Tide-kissed", kind = "prefix", group = "domain", on = CASTER, stats = { power_water = { 0.04, 0.12 } } })
affix({ id = "gale_born", name = "Gale-born", kind = "prefix", group = "domain", on = CASTER, stats = { power_air = { 0.04, 0.12 } } })
affix({ id = "verdant", name = "Verdant", kind = "prefix", group = "domain", on = CASTER, stats = { power_life = { 0.04, 0.12 } } })
affix({ id = "lucid", name = "Lucid", kind = "prefix", group = "domain", on = CASTER, stats = { power_mind = { 0.04, 0.12 } } })
affix({ id = "hallowed", name = "Hallowed", kind = "prefix", group = "domain", on = CASTER, stats = { power_spirit = { 0.04, 0.12 } } })
affix({ id = "hollowed", name = "Hollowed", kind = "prefix", group = "domain", on = CASTER, stats = { power_void = { 0.04, 0.12 } } })
affix({ id = "far_reaching", name = "Far-reaching", kind = "prefix", group = "domain", on = CASTER, minRarity = 3, weight = 6, stats = { power_space = { 0.05, 0.12 } } })
affix({ id = "timeworn", name = "Timeworn", kind = "prefix", group = "domain", on = CASTER, minRarity = 4, weight = 2, stats = { power_time = { 0.06, 0.14 } } })
affix({ id = "leaden", name = "Leaden", kind = "prefix", group = "domain", on = CASTER, minRarity = 4, weight = 2, stats = { power_gravity = { 0.06, 0.14 } } })
affix({ id = "unreal", name = "Unreal", kind = "prefix", group = "domain", on = CASTER, minRarity = 5, weight = 1, stats = { power_reality = { 0.08, 0.15 } } })

-- ─── Prefixes: casting ──────────────────────────────────────────────────────

affix({ id = "potent", name = "Potent", kind = "prefix", group = "power", on = CASTER, stats = { spellPowerPct = { 0.03, 0.08 } } })
affix({ id = "thrifty", name = "Thrifty", kind = "prefix", group = "cost", on = CASTER, stats = { costReductionPct = { 0.03, 0.1 } } })
affix({ id = "quickened", name = "Quickened", kind = "prefix", group = "speed", on = CASTER, stats = { castSpeedPct = { 0.04, 0.12 } } })
affix({ id = "steady", name = "Steady", kind = "prefix", group = "stability", on = CASTER, stats = { stabilityPct = { 0.05, 0.15 } } })
affix({ id = "brimming", name = "Brimming", kind = "prefix", group = "reservoir", on = { "focus", "jewelry", "armor" }, stats = { reservoirMax = { 5, 25 } } })
affix({ id = "wellspring", name = "Wellspring", kind = "prefix", group = "regen", on = { "focus", "jewelry", "armor" }, stats = { reservoirRegenPct = { 0.04, 0.12 } } })
affix({ id = "kindred_flame", name = "Kindred-flame", kind = "prefix", group = "domain", on = CASTER, minRarity = 3, weight = 5, stats = { power_energy = { 0.1, 0.2 } }, attune = { affinity = { energy = 0.5 } }, text = "Only for those with a strong Energy affinity" })
affix({ id = "deep_bound", name = "Deep-bound", kind = "prefix", group = "cost", on = CASTER, minRarity = 3, weight = 5, stats = { costReductionPct = { 0.08, 0.15 } }, attune = { affinity = { water = 0.5 } }, text = "Only for those with a strong Water affinity" })
affix({ id = "sunforged", name = "Sunforged", kind = "prefix", group = "power", on = { "focus", "weapon" }, minRarity = 5, weight = 2, stats = { power_energy = { 0.1, 0.18 }, spellPowerPct = { 0.04, 0.08 } }, resist = { combustion = { 0.08, 0.15 } } })

-- ─── Prefixes: armor and weapons ────────────────────────────────────────────

affix({ id = "warded", name = "Warded", kind = "prefix", group = "ward", on = WEAR, resist = { all = { 0.02, 0.06 } } })
affix({ id = "sturdy", name = "Sturdy", kind = "prefix", group = "health", on = WEAR, stats = { health = { 5, 20 } } })
affix({ id = "reinforced", name = "Reinforced", kind = "prefix", group = "defense", on = { "armor" }, stats = { defense = { 2, 8 } } })
affix({ id = "featherlight", name = "Featherlight", kind = "prefix", group = "weight", on = { "armor", "weapon", "tool" }, stats = { itemWeightPct = { -0.2, -0.5 } } })
affix({ id = "fleet", name = "Fleet", kind = "prefix", group = "move", on = { "armor" }, stats = { moveSpeedPct = { 0.02, 0.06 } } })
affix({ id = "keen", name = "Keen", kind = "prefix", group = "attack", on = { "weapon" }, stats = { attackPower = { 2, 8 } } })
affix({ id = "swift", name = "Swift", kind = "prefix", group = "aspeed", on = { "weapon" }, stats = { attackSpeedPct = { 0.03, 0.1 } } })
affix({ id = "vicious", name = "Vicious", kind = "prefix", group = "crit", on = { "weapon" }, stats = { critChancePct = { 0.02, 0.06 } } })
affix({ id = "insulated", name = "Insulated", kind = "prefix", group = "element", on = WEAR, resist = { charge = { 0.05, 0.15 } } })
affix({ id = "fireproof", name = "Fireproof", kind = "prefix", group = "element", on = WEAR, resist = { combustion = { 0.05, 0.15 } } })
affix({ id = "frost_lined", name = "Frost-lined", kind = "prefix", group = "element", on = WEAR, resist = { temperature = { 0.05, 0.15 } } })
affix({ id = "grounded", name = "Grounded", kind = "prefix", group = "element", on = WEAR, resist = { seismicity = { 0.05, 0.15 }, earth = { 0.02, 0.06 } } })
affix({ id = "enduring", name = "Enduring", kind = "prefix", group = "durability", on = { "armor", "weapon", "tool", "focus" }, stats = { durabilityPct = { 0.2, 0.5 } } })
affix({ id = "packmules", name = "Packmule's", kind = "prefix", group = "carry", on = { "armor" }, stats = { carryWeight = { 5, 15 } } })
affix({ id = "vigorous", name = "Vigorous", kind = "prefix", group = "stamina", on = WEAR, stats = { staminaMax = { 5, 20 } } })
affix({ id = "mending", name = "Mending", kind = "prefix", group = "hregen", on = WEAR, minRarity = 3, stats = { healthRegen = { 0.2, 0.8 } } })
affix({ id = "masterwork", name = "Masterwork", kind = "prefix", group = "durability", on = { "tool" }, stats = { durabilityPct = { 0.5, 1.0 } } })

-- ─── Suffixes: domain ───────────────────────────────────────────────────────

affix({ id = "of_resonance", name = "of Resonance", kind = "suffix", group = "s_power", on = CASTER, stats = { spellPowerPct = { 0.02, 0.06 }, reservoirRegenPct = { 0.02, 0.06 } } })
affix({ id = "of_the_ember", name = "of the Ember", kind = "suffix", group = "s_domain", on = ALL_GEAR, stats = { power_energy = { 0.03, 0.08 } }, resist = { combustion = { 0.03, 0.08 } } })
affix({ id = "of_the_deep", name = "of the Deep", kind = "suffix", group = "s_domain", on = ALL_GEAR, stats = { power_water = { 0.03, 0.08 } }, resist = { water = { 0.03, 0.08 } } })
affix({ id = "of_the_mountain", name = "of the Mountain", kind = "suffix", group = "s_domain", on = ALL_GEAR, stats = { power_earth = { 0.03, 0.08 }, health = { 4, 12 } } })
affix({ id = "of_the_wind", name = "of the Wind", kind = "suffix", group = "s_domain", on = ALL_GEAR, stats = { power_air = { 0.03, 0.08 }, moveSpeedPct = { 0.01, 0.03 } } })
affix({ id = "of_bloom", name = "of Bloom", kind = "suffix", group = "s_domain", on = ALL_GEAR, stats = { power_life = { 0.03, 0.08 }, healthRegen = { 0.1, 0.4 } } })
affix({ id = "of_clarity", name = "of Clarity", kind = "suffix", group = "s_domain", on = CASTER, stats = { power_mind = { 0.03, 0.08 }, stabilityPct = { 0.02, 0.06 } } })
affix({ id = "of_the_vigil", name = "of the Vigil", kind = "suffix", group = "s_domain", on = ALL_GEAR, stats = { power_spirit = { 0.03, 0.08 } }, resist = { malediction = { 0.05, 0.12 } } })
affix({ id = "of_the_hollow_star", name = "of the Hollow Star", kind = "suffix", group = "s_domain", on = CASTER, minRarity = 3, stats = { power_void = { 0.04, 0.1 } } })

-- ─── Suffixes: casting ──────────────────────────────────────────────────────

affix({ id = "of_haste", name = "of Haste", kind = "suffix", group = "s_speed", on = CASTER, stats = { castSpeedPct = { 0.03, 0.08 } } })
affix({ id = "of_thrift", name = "of Thrift", kind = "suffix", group = "s_cost", on = CASTER, stats = { costReductionPct = { 0.02, 0.07 } } })
affix({ id = "of_the_wellspring", name = "of the Wellspring", kind = "suffix", group = "s_reservoir", on = { "focus", "jewelry", "armor" }, stats = { reservoirMaxPct = { 0.03, 0.1 } } })
affix({ id = "of_calm", name = "of Calm", kind = "suffix", group = "s_backlash", on = { "focus", "jewelry", "armor" }, stats = { backlashResistPct = { 0.05, 0.15 } } })
affix({ id = "of_steadiness", name = "of Steadiness", kind = "suffix", group = "s_stability", on = CASTER, stats = { stabilityPct = { 0.03, 0.1 } } })
affix({ id = "of_the_scholar", name = "of the Scholar", kind = "suffix", group = "s_slots", on = { "focus" }, minRarity = 4, weight = 3, stats = { modifierSlots = { 1, 1 } }, text = "One more modifier slot" })
affix({ id = "of_ascension", name = "of Ascension", kind = "suffix", group = "s_slots", on = { "focus" }, minRarity = 5, weight = 1, stats = { formTier = { 1, 1 } }, text = "Forms one tier above your mastery" })
affix({ id = "of_the_adept", name = "of the Adept", kind = "suffix", group = "s_power", on = CASTER, minRarity = 3, weight = 5, stats = { spellPowerPct = { 0.06, 0.12 } }, attune = { tier = { any = 4 } }, text = "Only for a Skilled mage or better" })
affix({ id = "of_the_unbroken", name = "of the Unbroken", kind = "suffix", group = "s_backlash", on = { "focus", "armor" }, minRarity = 5, weight = 2, stats = { backlashResistPct = { 0.1, 0.2 }, stabilityPct = { 0.05, 0.1 }, health = { 10, 25 } } })

-- ─── Suffixes: armor, weapons, tools ────────────────────────────────────────

affix({ id = "of_warding", name = "of Warding", kind = "suffix", group = "s_ward", on = WEAR, resist = { all = { 0.02, 0.05 } } })
affix({ id = "of_the_bulwark", name = "of the Bulwark", kind = "suffix", group = "s_defense", on = { "armor" }, stats = { defense = { 2, 6 }, health = { 3, 10 } } })
affix({ id = "of_the_fox", name = "of the Fox", kind = "suffix", group = "s_move", on = { "armor", "jewelry" }, stats = { moveSpeedPct = { 0.02, 0.05 }, staminaRegenPct = { 0.05, 0.15 } } })
affix({ id = "of_the_ox", name = "of the Ox", kind = "suffix", group = "s_carry", on = { "armor", "tool" }, stats = { carryWeight = { 5, 20 }, staminaMax = { 5, 10 } } })
affix({ id = "of_the_viper", name = "of the Viper", kind = "suffix", group = "s_attack", on = { "weapon" }, stats = { critChancePct = { 0.02, 0.05 }, attackSpeedPct = { 0.02, 0.05 } } })
affix({ id = "of_slaying", name = "of Slaying", kind = "suffix", group = "s_attack", on = { "weapon" }, stats = { attackPower = { 3, 10 } } })
affix({ id = "of_the_tidewarden", name = "of the Tidewarden", kind = "suffix", group = "s_set", on = WEAR, minRarity = 3, weight = 4, set = "tidewarden", resist = { water = { 0.04, 0.08 } } })
affix({ id = "of_the_forgeborn", name = "of the Forgeborn", kind = "suffix", group = "s_set", on = WEAR, minRarity = 3, weight = 4, set = "forgeborn", resist = { combustion = { 0.04, 0.08 } } })
affix({ id = "of_the_still_wind", name = "of the Still Wind", kind = "suffix", group = "s_set", on = WEAR, minRarity = 3, weight = 4, set = "still_wind", stats = { moveSpeedPct = { 0.01, 0.03 } } })

-- ─── Sets ───────────────────────────────────────────────────────────────────
-- Bonuses are cumulative: wearing 3 pieces grants the 2-piece AND the 3-piece bonus.

local sets: { ItemTypes.SetDef } = {
	{
		id = "tidewarden",
		name = "Tidewarden",
		bonuses = {
			{ pieces = 2, resist = { water = 0.1 } },
			{ pieces = 3, stats = { power_water = 0.1, reservoirRegenPct = 0.1 } },
		},
	},
	{
		id = "forgeborn",
		name = "Forgeborn",
		bonuses = {
			{ pieces = 2, stats = { health = 10 }, resist = { combustion = 0.1 } },
			{ pieces = 3, stats = { power_energy = 0.1, defense = 6 } },
		},
	},
	{
		id = "still_wind",
		name = "Still Wind",
		bonuses = {
			{ pieces = 2, stats = { moveSpeedPct = 0.05 } },
			{ pieces = 3, stats = { castSpeedPct = 0.08, power_air = 0.1 } },
		},
	},
}

return {
	list = list,
	sets = sets,
}
