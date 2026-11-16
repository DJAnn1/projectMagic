--!strict
--[[
	EffectLibrary: what every spell DOES. Pure data, read by Shared/Magic/SpellRoute, so the server
	(CastService) and the Composer's preview pick the same route. A new route also needs its
	player-facing words in Data/RouteSummaries (Tests/SpellOutcome.spec checks).

	Each route names an effect resolver (Magic/Cast/Effects/<effect>) and the params it gets.
	Routes are tried IN ORDER and the first match wins: specific routes (disasters, fields,
	statuses) come before broad ones (force, harm), and `manifest` is the catch-all.

	Match fields (unset = any):
		branches     the recipe's branch, one of its ancestors, or one of its domains is listed
		properties / verbs / forms / categories   the recipe's value is listed
		harmful      the property's `harmful` flag equals this
		strike       the recipe is a non-native domain strike (Shared/Magic/Strike.routed)
		minPower / maxPower   recipe power bounds
	Route flags:
		recordsWorld  the resolver records magic pressure itself (CastService skips noteMagic)
		repeatable    echoes and channel pulses may re-run it (never disasters or zones)
		heavy         counts against the per-server heavy budget when power >= budget.heavyPower
		instant       a click casts it at once (owner, 2026-11-16: "it makes no sense to charge" a blink):
		              no hold to charge, no Quick-tap penalty, cast time Tuning.minCastTime. For moving
		              yourself, escapes and self toggles, where the moment matters more than the power.

	Adding a spell effect: write Effects/<Name>.luau (resolve(ctx, params) -> Outcome), add a
	route here, add an example to Shared/Magic/Data/SpellExamples, and Tests/Cast.spec checks
	that the example routes where you said.
]]

export type Route = {
	id: string,
	effect: string,
	params: { [string]: any }?,
	branches: { string }?,
	properties: { string }?,
	verbs: { string }?,
	forms: { string }?,
	categories: { string }?,
	harmful: boolean?,
	strike: boolean?,
	minPower: number?,
	maxPower: number?,
	recordsWorld: boolean?,
	repeatable: boolean?,
	heavy: boolean?,
	instant: boolean?,
}

local OFFENSIVE = { "generate", "amplify", "reduce", "transfer", "redirect", "release", "transmute" }
local AREA_FORMS = { "zone", "burst", "aura", "ritual" }
local POINT_FORMS = { "touch", "projectile", "beam", "chain" }
local EARTH = { "earth", "mudshaping", "magmacraft" }
-- Stage 1b (Effects/Status targetsByForm): a harmful status reaches everyone in an area form; a
-- helpful one covers you and your allies in an area form or an aura.
local FOE = { zone = "area", burst = "area", ritual = "area", wall = "area", pillar = "area", aura = "area" }
local FRIEND = { zone = "allies", burst = "allies", ritual = "allies", wall = "allies", pillar = "allies", aura = "allies", summon = "allies" }

local routes: { Route } = {
	-- ─── World-scale disasters ──────────────────────────────────────────────
	{ id = "earthquake", effect = "Earthquake", branches = { "seismic" }, properties = { "seismicity" }, verbs = { "generate", "release" }, minPower = 5, recordsWorld = true, heavy = true },
	{ id = "tsunami", effect = "Tsunami", branches = { "tidal" }, properties = { "flow" }, verbs = { "redirect", "generate" }, forms = { "ritual" }, minPower = 8, recordsWorld = true, heavy = true },

	-- ─── Time's powers (Effects/TimePower, docs/Time.md) ────────────────────
	-- Before `store`, which would swallow Self Timeline, and `time_field`. Each is narrow: its own branch.
	{ id = "self_timeline", effect = "TimePower", branches = { "rewind" }, properties = { "sequence" }, verbs = { "store" }, forms = { "aura" }, params = { power = "self_timeline" }, instant = true },
	{ id = "target_timeline", effect = "TimePower", branches = { "rewind" }, properties = { "sequence" }, verbs = { "bind" }, forms = { "touch", "beam" }, params = { power = "target_timeline" } },
	{ id = "time_loop", effect = "TimePower", branches = { "rewind" }, properties = { "sequence" }, verbs = { "redirect" }, forms = { "touch", "beam" }, params = { power = "loop" } },
	{ id = "stored_moment", effect = "TimePower", branches = { "rewind" }, properties = { "sequence" }, verbs = { "bind" }, forms = { "aura" }, params = { power = "stored" }, instant = true },
	{ id = "borrowed_wound", effect = "TimePower", branches = { "causality" }, properties = { "sequence" }, verbs = { "amplify", "reduce" }, forms = { "touch", "beam", "aura" }, params = { power = "wound" } },
	{ id = "future_sight", effect = "TimePower", branches = { "precognition" }, properties = { "foresight" }, verbs = { "amplify" }, forms = { "aura", "touch" }, params = { power = "sight" }, instant = true },
	{ id = "timestop", effect = "TimePower", branches = { "stasis" }, properties = { "tempo" }, verbs = { "reduce", "bind" }, forms = { "zone", "burst", "aura", "ritual" }, minPower = 7, params = { power = "timestop" }, heavy = true },

	-- ─── Reality's powers (Effects/RealityPower, docs/Reality.md) ───────────
	-- Before `stasis` (persistence), `fortune` and the old `reality` field, which would swallow them.
	-- Each is narrow: its own branch. Verbs and forms the grammar allows for these properties only.
	{ id = "worldlaw", effect = "RealityPower", branches = { "worldlaw" }, properties = { "law" }, verbs = { "reduce", "amplify", "bind", "transmute" }, forms = { "ritual" }, minPower = 9, params = { power = "edict", worldlaw = true }, heavy = true },
	{ id = "edict", effect = "RealityPower", branches = { "edict" }, properties = { "law" }, verbs = { "reduce", "amplify", "bind", "transmute" }, forms = { "zone", "burst", "aura", "ritual" }, params = { power = "edict" } },
	{ id = "favor", effect = "RealityPower", branches = { "fortune" }, properties = { "probability" }, verbs = { "amplify" }, forms = { "aura" }, params = { power = "favor" } },
	{ id = "doom", effect = "RealityPower", branches = { "fatebending" }, properties = { "probability" }, verbs = { "reduce" }, forms = POINT_FORMS, params = { power = "doom" } },
	{ id = "certainty", effect = "RealityPower", branches = { "fatebending" }, properties = { "probability" }, verbs = { "bind" }, forms = { "touch", "beam" }, params = { power = "certainty" } },
	{ id = "twist_of_fate", effect = "RealityPower", branches = { "fatebending" }, properties = { "probability" }, verbs = { "transmute" }, forms = { "aura" }, params = { power = "twist" } },
	-- Conjured beings (docs/Reality.md): the recipe's `wish` picks what rises; the verb how (host, guard, colossus).
	{ id = "conjure_being", effect = "RealityPower", branches = { "conjuration" }, properties = { "substance" }, verbs = { "generate", "bind", "transmute" }, forms = { "summon" }, params = { power = "summon" }, heavy = true },
	-- World wishes (docs/Reality.md): the ground becomes what you wish (saved), or things appear for a while.
	{ id = "remake_land", effect = "RealityPower", branches = { "conjuration" }, properties = { "substance" }, verbs = { "transmute" }, forms = { "zone", "burst", "ritual" }, params = { power = "remake" }, heavy = true },
	{ id = "conjure_things", effect = "RealityPower", branches = { "conjuration" }, properties = { "substance" }, verbs = { "amplify" }, forms = { "zone", "burst", "ritual" }, params = { power = "things" }, heavy = true },
	{ id = "cage", effect = "RealityPower", branches = { "conjuration" }, properties = { "substance" }, verbs = { "bind" }, forms = POINT_FORMS, params = { power = "cage" } },
	{ id = "conjure", effect = "RealityPower", branches = { "conjuration" }, properties = { "substance" }, verbs = { "generate" }, forms = { "touch", "beam", "wall", "pillar", "zone", "burst", "ritual" }, params = { power = "conjure" } },
	{ id = "unmake", effect = "RealityPower", branches = { "unmaking" }, properties = { "substance" }, verbs = { "reduce" }, params = { power = "unmake" } },
	{ id = "undying", effect = "RealityPower", branches = { "substantiation" }, properties = { "persistence" }, verbs = { "bind" }, forms = { "aura" }, params = { power = "undying" }, instant = true },
	{ id = "fray", effect = "RealityPower", branches = { "substantiation" }, properties = { "persistence" }, verbs = { "reduce" }, forms = { "touch", "projectile", "beam" }, params = { power = "fray" } },
	{ id = "polymorph", effect = "RealityPower", branches = { "polymorphy" }, properties = { "identity" }, verbs = { "transmute" }, forms = POINT_FORMS, params = { power = "polymorph" } },
	{ id = "exchange", effect = "RealityPower", branches = { "lawcraft" }, properties = { "identity" }, verbs = { "transfer" }, forms = { "touch", "beam", "chain" }, params = { power = "exchange" } },

	-- ─── Perception and charges ─────────────────────────────────────────────
	{ id = "sense", effect = "Sense", verbs = { "sense" }, instant = true },
	{ id = "store", effect = "Store", verbs = { "store" } },

	-- ─── Domain strikes: every domain's first attack (Shared/Magic/Data/Strikes) ─────
	-- Early on purpose: a strike is narrow (one property, its verbs, point forms), and it must
	-- win over fortune (probability) and restore (growth) for those point forms.
	{ id = "strike", effect = "Strike", strike = true, repeatable = true },

	-- ─── Void: unmaking magic itself ────────────────────────────────────────
	{ id = "dispel", effect = "Dispel", properties = { "aether" }, verbs = { "reduce", "transmute", "bind" } },
	{ id = "silence", effect = "Status", properties = { "sound" }, verbs = { "reduce" }, params = { status = "silence", targets = "area" } },
	{ id = "darken", effect = "Status", properties = { "luminosity" }, verbs = { "reduce" }, params = { status = "blind", targets = "area", extinguishLights = true } },
	{ id = "still", effect = "Status", properties = { "momentum" }, verbs = { "reduce" }, params = { status = "slow", targets = "area", stopParts = true } },

	-- ─── Mythic: Time, Gravity, Reality (zones are budgeted; see FieldEffects) ─
	{ id = "time_field", effect = "Field", properties = { "tempo" }, verbs = { "reduce", "amplify" }, forms = AREA_FORMS, params = { field = "time" }, heavy = true },
	{ id = "tempo", effect = "Status", properties = { "tempo" }, verbs = { "reduce", "amplify" }, params = { statusByVerb = { amplify = "haste", reduce = "slow" }, targets = "hit", selfIfNone = true } },
	{ id = "stasis", effect = "Status", properties = { "persistence" }, verbs = { "bind", "reduce" }, params = { status = "stasis", targets = "hit" } },
	-- Gravity's powers (Effects/GravityPower, docs/Gravity.md). Before gravity_field and the broad
	-- force and harm routes, and each is narrow: its own branch, so nothing else moves.
	{ id = "singularity", effect = "GravityPower", branches = { "collapse" }, properties = { "weight", "cohesion" }, verbs = { "generate", "amplify" }, forms = { "zone", "burst", "ritual" }, minPower = 7, params = { power = "singularity" }, heavy = true },
	{ id = "orbit_shield", effect = "GravityPower", branches = { "orbitcraft" }, properties = { "weight", "cohesion" }, verbs = { "generate", "amplify", "bind" }, forms = { "aura" }, params = { power = "orbit" }, instant = true },
	{ id = "gravity_well", effect = "GravityPower", branches = { "attraction" }, properties = { "weight", "cohesion" }, verbs = { "generate", "amplify" }, forms = { "zone", "burst", "ritual" }, params = { power = "well" }, heavy = true },
	{ id = "flight", effect = "GravityPower", branches = { "levitation" }, properties = { "buoyancy" }, verbs = { "generate", "amplify" }, forms = { "aura" }, params = { power = "flight" }, instant = true },
	{ id = "mass_shift", effect = "GravityPower", branches = { "weightcraft" }, properties = { "density" }, verbs = { "amplify", "reduce" }, forms = { "aura", "touch" }, params = { power = "mass" }, instant = true },
	{ id = "crushing_grip", effect = "GravityPower", branches = { "crushing" }, properties = { "weight" }, verbs = { "generate", "amplify", "bind" }, forms = { "touch", "beam" }, params = { power = "grip" } },
	{ id = "bend_path", effect = "GravityPower", branches = { "vectoring" }, properties = { "momentum", "orientation" }, verbs = { "redirect", "transmute" }, forms = { "aura" }, params = { power = "bend" }, instant = true },
	{ id = "lift_slam", effect = "GravityPower", branches = { "vectoring" }, properties = { "momentum", "orientation" }, verbs = { "redirect", "transfer" }, forms = { "touch", "beam" }, params = { power = "lift" } },
	{ id = "gravity_field", effect = "Field", branches = { "gravity" }, properties = { "weight", "orientation", "buoyancy", "density" }, forms = AREA_FORMS, params = { field = "gravity" }, heavy = true },
	{ id = "reality", effect = "Field", branches = { "reality" }, properties = { "law", "substance", "identity" }, params = { field = "reality", ruleByProperty = { law = "slick", substance = "intangible", identity = "transmute" } }, heavy = true },
	{ id = "fortune", effect = "Status", properties = { "probability" }, verbs = { "amplify", "generate" }, params = { status = "lucky", targets = "allies" } },

	-- ─── Space ──────────────────────────────────────────────────────────────
	-- Space's powers (Effects/SpacePower, docs/Space.md stage 1). Each narrow: its own branch, so the old
	-- blink, fold and push/pull routes keep everything else.
	-- Stage 2 first where branches nest: Pocketcraft sits under Folding, so the pocket goes before the stride.
	-- Stage 3: the Worldgate before the ordinary gate (Worldgates sits under Gatecraft), the hideaway before
	-- the pocket (both Pocketcraft).
	-- Mindlink (the Space + Mind hybrid, stage 3): reach a mind anywhere (Services/MindlinkService).
	{ id = "space_mindlink", effect = "SpacePower", branches = { "mindlink" }, properties = { "thought", "distance" }, verbs = { "transfer", "generate", "amplify", "redirect" }, params = { power = "mindlink" }, instant = true },
	{ id = "space_worldgate", effect = "SpacePower", branches = { "worldgates" }, properties = { "boundary", "position" }, verbs = { "amplify", "transfer" }, forms = { "ritual", "zone", "wall" }, minPower = 9, params = { power = "worldgate" }, heavy = true },
	{ id = "space_hideaway", effect = "SpacePower", branches = { "pocketcraft" }, properties = { "volume" }, verbs = { "bind", "reduce" }, params = { power = "hideaway" }, instant = true },
	{ id = "space_pocket", effect = "SpacePower", branches = { "pocketcraft" }, properties = { "volume" }, verbs = { "amplify", "store", "transfer" }, forms = { "aura", "touch" }, params = { power = "pocket" }, instant = true },
	{ id = "space_anchor", effect = "SpacePower", branches = { "blinking" }, properties = { "position" }, verbs = { "bind" }, params = { power = "anchor" }, instant = true },
	{ id = "space_recall", effect = "SpacePower", branches = { "blinking" }, properties = { "position" }, verbs = { "release" }, forms = { "aura", "burst", "zone", "ritual" }, params = { power = "recall" }, instant = true },
	{ id = "space_stretch", effect = "SpacePower", branches = { "folding" }, properties = { "distance", "volume" }, verbs = { "amplify" }, forms = { "zone", "burst", "wall", "ritual" }, params = { power = "stretch" } },
	{ id = "space_gate", effect = "SpacePower", branches = { "gatecraft" }, properties = { "boundary", "position" }, verbs = { "generate", "amplify", "transfer" }, forms = { "zone", "wall", "ritual" }, params = { power = "gate" } },
	{ id = "space_seal", effect = "SpacePower", branches = { "containment" }, properties = { "boundary", "volume" }, verbs = { "bind", "generate", "amplify" }, params = { power = "seal" } },
	{ id = "space_swap", effect = "SpacePower", branches = { "translocation" }, properties = { "position" }, verbs = { "transmute" }, forms = { "touch", "beam", "projectile" }, params = { power = "swap" }, instant = true },
	{ id = "space_stride", effect = "SpacePower", branches = { "folding" }, properties = { "distance", "volume" }, verbs = { "reduce", "amplify" }, forms = { "aura" }, params = { power = "stride" }, instant = true },
	{ id = "space_cut", effect = "SpacePower", branches = { "space" }, properties = { "distance", "position", "volume", "boundary" }, verbs = { "release", "transmute" }, forms = { "beam", "touch", "wall" }, params = { power = "cut" } },
	{ id = "blink", effect = "Blink", properties = { "position" }, verbs = { "redirect", "transfer" }, instant = true },
	{ id = "fold", effect = "Force", properties = { "volume" }, verbs = { "reduce" }, params = { mode = "pull" }, repeatable = true },

	-- ─── Spirit, Life and Mind: statuses ────────────────────────────────────
	{ id = "ward", effect = "Status", properties = { "warding" }, verbs = { "generate", "amplify" }, params = { status = "ward", targets = "allies" } },
	{ id = "cleanse", effect = "Status", properties = { "toxin", "decay", "malediction" }, verbs = { "reduce" }, params = { cleanse = { "poison", "rot", "hexed", "burning" }, targets = "allies" } },
	{ id = "afflict", effect = "Status", properties = { "toxin", "decay", "malediction" }, verbs = OFFENSIVE, params = { statusByProperty = { toxin = "poison", decay = "rot", malediction = "hexed" }, targets = "hit", impact = 0.3 }, repeatable = true },
	{ id = "fear", effect = "Status", branches = { "dread" }, properties = { "emotion" }, params = { status = "fear", targets = "hit" } },
	{ id = "charm", effect = "Status", branches = { "charm" }, properties = { "emotion" }, params = { status = "charm", targets = "hit" } },
	{ id = "illusion_blind", effect = "Status", properties = { "illusion" }, verbs = { "generate", "amplify" }, params = { status = "blind", targets = "hit" } },
	{ id = "veil", effect = "Status", properties = { "illusion" }, verbs = { "reduce" }, params = { status = "veiled", targets = "self" } },
	{ id = "soothe", effect = "Status", properties = { "instinct", "emotion" }, verbs = { "reduce" }, params = { status = "calm", targets = "hit" } },
	{ id = "siphon", effect = "Siphon", properties = { "essence", "vitality" }, verbs = { "transfer" }, forms = POINT_FORMS },

	-- ─── Energy ─────────────────────────────────────────────────────────────
	{ id = "light", effect = "Light", properties = { "luminosity" }, verbs = { "generate", "amplify" }, forms = { "touch", "aura" }, instant = true },
	{ id = "ignite", effect = "Thermal", properties = { "combustion" }, verbs = { "generate", "amplify", "release", "redirect" }, params = { mode = "ignite" }, repeatable = true, heavy = true },
	{ id = "heat_transfer", effect = "Thermal", properties = { "temperature" }, verbs = { "transfer" }, params = { mode = "transfer" } },

	-- ─── Water ──────────────────────────────────────────────────────────────
	{ id = "freeze", effect = "Terrain", branches = { "water" }, properties = { "phase", "temperature" }, verbs = { "reduce" }, params = { op = "freeze" } },
	{ id = "thermal", effect = "Thermal", properties = { "temperature" }, verbs = { "generate", "amplify", "reduce", "release" }, params = { mode = "byVerb" }, repeatable = true },
	{ id = "pour", effect = "Terrain", branches = { "water" }, properties = { "humidity", "flow" }, verbs = { "generate" }, params = { op = "pour" } },
	{ id = "current", effect = "Field", properties = { "flow" }, verbs = { "redirect", "transfer" }, forms = { "zone", "aura", "wall" }, params = { field = "current" } },
	{ id = "wave", effect = "Wave", branches = { "water" }, properties = { "flow", "pressure" }, verbs = { "redirect", "release", "generate" }, forms = { "burst", "projectile", "beam" }, minPower = 4, heavy = true },

	-- ─── Earth ──────────────────────────────────────────────────────────────
	{ id = "tremor", effect = "Terrain", properties = { "seismicity" }, params = { op = "tremor" } },
	{ id = "landslide", effect = "Terrain", branches = EARTH, properties = { "contour", "cohesion" }, verbs = { "reduce", "redirect" }, minPower = 4, params = { op = "landslide" }, heavy = true },
	{ id = "stoneshape", effect = "Terrain", branches = EARTH, properties = { "contour", "hardness", "density", "cohesion" }, verbs = { "generate", "amplify", "bind", "transmute" }, forms = { "wall", "pillar", "burst", "zone" }, params = { op = "stone" } },
	-- Contour + generate only, so the Guided cards Pebble Nudge and Shape Stone really do something
	-- at a touch, while Amplify-Hardness-as-Touch stays honestly dead (the Composer's own example).
	{ id = "stonetouch", effect = "Terrain", branches = EARTH, properties = { "contour" }, verbs = { "generate" }, forms = { "touch" }, params = { op = "stone" } },
	{ id = "metal", effect = "Metal", properties = { "magnetism" } },

	-- ─── Stage 1b: the properties that did nothing (docs/SpellOverhaul.md §11) ──
	-- Before the general routes, so a bind here wins over the catch-all root. Status's targetsByForm:
	-- FOE sends a harmful status at whoever the form reaches (or everyone in an area form), FRIEND
	-- puts a helpful one on you and your allies for area forms and on whoever you touch or aim at
	-- (yourself if nobody) for point forms.
	{ id = "veil_presence", effect = "Status", properties = { "presence" }, verbs = { "reduce", "transmute" }, params = { status = "veiled", targets = "self", targetsByForm = FRIEND } },
	{ id = "expose", effect = "Status", properties = { "presence" }, verbs = { "generate", "amplify" }, params = { status = "jinxed", targetsByForm = FOE } },
	{ id = "weigh_down", effect = "Status", properties = { "density", "viscosity" }, verbs = { "generate", "amplify" }, forms = POINT_FORMS, params = { status = "slow" } },
	{ id = "anchor_weight", effect = "Status", properties = { "density" }, verbs = { "generate", "amplify" }, params = { status = "gravity_heavy", targets = "allies", magnitude = { base = 0.06, perPower = 0.015 } } },
	{ id = "featherweight", effect = "Status", properties = { "density", "buoyancy" }, verbs = { "reduce", "generate", "amplify" }, params = { statusByVerb = { reduce = "gravity_light", generate = "gravity_light", amplify = "gravity_light" }, selfIfNone = true, targetsByForm = FRIEND } },
	{ id = "mist", effect = "Status", properties = { "humidity" }, verbs = { "generate", "amplify" }, params = { status = "veiled", targets = "allies" } },
	{ id = "dry_air", effect = "Status", properties = { "humidity" }, verbs = { "reduce" }, params = { cleanse = { "burning" }, targets = "allies", extinguish = true } },
	{ id = "keen_senses", effect = "Status", properties = { "perception" }, verbs = { "generate", "amplify" }, params = { status = "evading", selfIfNone = true, targetsByForm = FRIEND, resist = { base = 0.08, perPower = 0.02 } } },
	{ id = "dull_senses", effect = "Status", properties = { "perception" }, verbs = { "reduce", "transmute" }, params = { statusByVerb = { reduce = "blind", transmute = "dazed" }, targetsByForm = FOE } },
	{ id = "unward", effect = "Dispel", properties = { "warding" }, verbs = { "reduce", "transmute" } },
	{ id = "ward_more", effect = "Status", properties = { "warding" }, verbs = { "bind", "transfer", "redirect", "release" }, params = { status = "ward", targets = "allies" } },
	{ id = "stunt", effect = "Status", properties = { "growth" }, verbs = { "reduce", "transmute" }, params = { statusByVerb = { reduce = "slow", transmute = "rot" }, targetsByForm = FOE } },
	{ id = "bloom", effect = "Restore", properties = { "growth" }, verbs = { "release", "redirect" }, repeatable = true },
	{ id = "stone_skin", effect = "Status", properties = { "hardness" }, verbs = { "generate", "amplify", "bind", "transmute" }, params = { status = "ward", selfIfNone = true, targetsByForm = FRIEND } },
	{ id = "brittle", effect = "Status", properties = { "hardness", "purity" }, verbs = { "reduce" }, params = { status = "crumbling", targetsByForm = FOE } },
	{ id = "thicken", effect = "Status", properties = { "viscosity" }, verbs = { "generate", "amplify" }, params = { status = "slow", targets = "area" } },
	{ id = "slick", effect = "Status", properties = { "viscosity" }, verbs = { "reduce" }, params = { status = "haste", selfIfNone = true, targetsByForm = FRIEND } },
	{ id = "sink", effect = "Status", properties = { "buoyancy" }, verbs = { "reduce" }, params = { status = "slow", targetsByForm = FOE } },
	{ id = "distance_pull", effect = "Force", properties = { "distance" }, verbs = { "reduce" }, params = { mode = "pull" }, repeatable = true },
	{ id = "distance_push", effect = "Force", properties = { "distance" }, verbs = { "generate", "amplify", "release", "redirect", "transfer" }, repeatable = true },
	{ id = "courage", effect = "Status", properties = { "emotion" }, verbs = { "amplify" }, params = { status = "haste", selfIfNone = true, targetsByForm = FRIEND } },
	{ id = "dread", effect = "Status", properties = { "emotion" }, verbs = { "generate", "release" }, params = { status = "fear", targetsByForm = FOE } },
	{ id = "sway", effect = "Status", properties = { "emotion" }, verbs = { "transmute", "transfer", "redirect" }, params = { status = "charm", targetsByForm = FOE } },
	{ id = "becalm", effect = "Status", properties = { "emotion" }, verbs = { "bind" }, params = { status = "calm", targetsByForm = FOE } },
	{ id = "wellspring", effect = "Status", properties = { "aether" }, verbs = { "generate", "amplify", "transfer", "release" }, params = { reservoir = 0.08, targets = "allies" } },
	{ id = "raise_stone", effect = "Terrain", properties = { "contour" }, verbs = { "generate", "amplify", "transmute", "bind" }, forms = { "projectile", "beam", "chain", "touch" }, params = { op = "stone" } },
	{ id = "purify", effect = "Status", properties = { "purity" }, verbs = { "generate", "amplify", "transmute" }, params = { cleanse = { "poison", "rot", "hexed", "sapped", "irradiated", "withering", "burning" }, targets = "allies" } },

	-- ─── General ────────────────────────────────────────────────────────────
	{ id = "restore", effect = "Restore", properties = { "vitality", "growth", "metabolism" }, verbs = { "generate", "amplify", "transfer" }, repeatable = true },
	{ id = "construct", effect = "Construct", forms = { "wall", "pillar" }, harmful = false, verbs = { "generate", "bind", "transmute", "amplify" } },
	{ id = "binding", effect = "Status", verbs = { "bind" }, params = { status = "root", targets = "hit" } },
	{ id = "force", effect = "Force", properties = { "momentum", "pressure", "flow", "orientation" }, verbs = { "generate", "redirect", "amplify", "release", "transfer" }, repeatable = true },
	{ id = "harm", effect = "Impact", harmful = true, verbs = OFFENSIVE, repeatable = true, heavy = true },
	{ id = "manifest", effect = "Manifest", repeatable = true },
}

-- Stage 1c fallbacks (Data/PropertyFallbacks, docs/SpellOverhaul.md §12): what a non-harmful
-- property does with every verb nothing more specific claims. Just before the general routes
-- (restore, construct, binding, force, harm, manifest), after everything else.
do
	local Fallbacks = require(script.Parent.PropertyFallbacks)
	local at = #routes
	for i, route in routes do
		if route.id == "restore" then
			at = i
			break
		end
	end
	local ids: { string } = {}
	for id in Fallbacks.list do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, property in ids do
		local byVerb: { [string]: string } = {}
		local onByVerb: { [string]: string } = {}
		for verb, entry in Fallbacks.list[property] do
			byVerb[verb] = entry.status
			if entry.on then
				onByVerb[verb] = entry.on
			end
		end
		table.insert(routes, at, {
			id = "fallback_" .. property,
			effect = "Status",
			properties = { property },
			verbs = Fallbacks.verbs,
			params = { statusByVerb = byVerb, onByVerb = onByVerb, foe = FOE, friend = FRIEND },
		})
		at += 1
	end
end

-- Domain ultimates (Data/Ultimates, docs/SpellOverhaul.md §10, stage 5): a Ritual at power 8+ in
-- a domain's own magic. Placed after Time, Gravity and Reality's powers (which keep theirs, as do
-- the earthquake and the tsunami) and before everything else that would take a ritual.
do
	local Ultimates = require(script.Parent.Ultimates)
	local at = #routes
	for i, route in routes do
		if route.id == "sense" then
			at = i
			break
		end
	end
	local ids: { string } = {}
	for id in Ultimates.list do
		table.insert(ids, id)
	end
	table.sort(ids)
	for _, id in ids do
		local u = Ultimates.list[id]
		table.insert(routes, at, {
			id = "ult_" .. id,
			effect = "Ultimate",
			branches = { u.domain },
			properties = u.properties,
			verbs = Ultimates.verbs,
			forms = { "ritual" },
			minPower = Ultimates.minPower,
			params = { ultimate = id },
			heavy = true,
		})
		at += 1
	end
end

return table.freeze({ routes = routes })
