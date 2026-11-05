--!strict
--[[
	EffectLibrary: what every spell DOES. Pure data, read by CastService.routeFor.

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
}

local OFFENSIVE = { "generate", "amplify", "reduce", "transfer", "redirect", "release", "transmute" }
local AREA_FORMS = { "zone", "burst", "aura", "ritual" }
local POINT_FORMS = { "touch", "projectile", "beam", "chain" }
local EARTH = { "earth", "mudshaping", "magmacraft" }

local routes: { Route } = {
	-- ─── World-scale disasters ──────────────────────────────────────────────
	{ id = "earthquake", effect = "Earthquake", branches = { "seismic" }, properties = { "seismicity" }, verbs = { "generate", "release" }, minPower = 5, recordsWorld = true, heavy = true },
	{ id = "tsunami", effect = "Tsunami", branches = { "tidal" }, properties = { "flow" }, verbs = { "redirect", "generate" }, forms = { "ritual" }, minPower = 8, recordsWorld = true, heavy = true },

	-- ─── Perception and charges ─────────────────────────────────────────────
	{ id = "sense", effect = "Sense", verbs = { "sense" } },
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
	{ id = "gravity_field", effect = "Field", branches = { "gravity" }, properties = { "weight", "orientation", "buoyancy", "density" }, forms = AREA_FORMS, params = { field = "gravity" }, heavy = true },
	{ id = "reality", effect = "Field", branches = { "reality" }, properties = { "law", "substance", "identity" }, params = { field = "reality", ruleByProperty = { law = "slick", substance = "intangible", identity = "transmute" } }, heavy = true },
	{ id = "fortune", effect = "Status", properties = { "probability" }, verbs = { "amplify", "generate" }, params = { status = "lucky", targets = "allies" } },

	-- ─── Space ──────────────────────────────────────────────────────────────
	{ id = "blink", effect = "Blink", properties = { "position" }, verbs = { "redirect", "transfer" } },
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
	{ id = "light", effect = "Light", properties = { "luminosity" }, verbs = { "generate", "amplify" }, forms = { "touch", "aura" } },
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
	{ id = "metal", effect = "Metal", properties = { "magnetism" } },

	-- ─── General ────────────────────────────────────────────────────────────
	{ id = "restore", effect = "Restore", properties = { "vitality", "growth", "metabolism" }, verbs = { "generate", "amplify", "transfer" }, repeatable = true },
	{ id = "construct", effect = "Construct", forms = { "wall", "pillar" }, harmful = false, verbs = { "generate", "bind", "transmute", "amplify" } },
	{ id = "binding", effect = "Status", verbs = { "bind" }, params = { status = "root", targets = "hit" } },
	{ id = "force", effect = "Force", properties = { "momentum", "pressure", "flow", "orientation" }, verbs = { "generate", "redirect", "amplify", "release", "transfer" }, repeatable = true },
	{ id = "harm", effect = "Impact", harmful = true, verbs = OFFENSIVE, repeatable = true, heavy = true },
	{ id = "manifest", effect = "Manifest", repeatable = true },
}

return table.freeze({ routes = routes })
