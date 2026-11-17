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
	-- Air's Echo Pulse (Effects/AirArt): before the general Sense, which would take any sense verb.
	{ id = "air_echo_pulse", effect = "AirArt", branches = { "echolocation" }, properties = { "sound" }, verbs = { "sense" }, forms = { "burst", "aura" }, params = { move = "echo_pulse" }, instant = true },
	{ id = "sense", effect = "Sense", verbs = { "sense" }, instant = true },
	{ id = "store", effect = "Store", verbs = { "store" } },

	-- ─── Domain strikes: every domain's first attack (Shared/Magic/Data/Strikes) ─────
	-- Early on purpose: a strike is narrow (one property, its verbs, point forms), and it must
	-- win over fortune (probability) and restore (growth) for those point forms.
	{ id = "strike", effect = "Strike", strike = true, repeatable = true },

	-- ─── Energy's spells (Effects/EnergyArt, Data/EnergyTuning, docs/DomainIdeas.md) ─────
	-- After the strikes (the cantrips stay theirs) and before the broad light, ignite, thermal, darken,
	-- still, binding, force and harm routes. Each is narrow: its own branch, property, verbs and forms.
	-- `flight` tunes the projectile (Cast/Delivery) and `look` gives the bolt its own body (Client/Fx/EnergyFx).
	-- Fire
	{ id = "energy_ember_swarm", effect = "EnergyArt", branches = { "pyromancy" }, properties = { "combustion" }, verbs = { "generate" }, forms = { "burst" }, params = { move = "ember_swarm" }, heavy = true },
	{ id = "energy_fire_whip", effect = "EnergyArt", branches = { "pyromancy" }, properties = { "combustion" }, verbs = { "generate" }, forms = { "touch" }, minPower = 2, params = { move = "fire_whip" } },
	{ id = "energy_flame_serpent", effect = "EnergyArt", branches = { "conflagration" }, properties = { "combustion" }, verbs = { "redirect" }, forms = { "projectile" }, params = { move = "flame_serpent", look = "serpent", flight = { speed = 0.8, homing = true } } },
	{ id = "energy_ring_of_fire", effect = "EnergyArt", branches = { "pyromancy" }, properties = { "combustion" }, verbs = { "generate", "amplify" }, forms = { "wall" }, params = { move = "ring_of_fire" } },
	{ id = "energy_smother", effect = "EnergyArt", branches = { "thermal" }, properties = { "combustion" }, verbs = { "reduce" }, forms = { "touch", "projectile", "burst", "aura", "zone" }, params = { move = "smother" } },
	{ id = "energy_kindle", effect = "EnergyArt", branches = { "pyromancy" }, properties = { "combustion" }, verbs = { "amplify" }, forms = { "touch", "aura" }, params = { move = "kindle" } },
	-- Frost
	{ id = "energy_ice_spike_line", effect = "EnergyArt", branches = { "cryothermy" }, properties = { "temperature" }, verbs = { "reduce" }, forms = { "pillar" }, params = { move = "ice_spike_line" } },
	{ id = "energy_frost_lance", effect = "EnergyArt", branches = { "cryothermy" }, properties = { "temperature" }, verbs = { "reduce" }, forms = { "projectile" }, minPower = 3, params = { move = "frost_lance", look = "lance" } },
	{ id = "energy_hoarfrost", effect = "EnergyArt", branches = { "cryothermy" }, properties = { "temperature" }, verbs = { "reduce" }, forms = { "zone" }, params = { move = "hoarfrost" } },
	{ id = "energy_ice_mirror", effect = "EnergyArt", branches = { "cryothermy" }, properties = { "temperature" }, verbs = { "transmute", "bind" }, forms = { "wall" }, params = { move = "ice_mirror" } },
	{ id = "energy_flurry", effect = "EnergyArt", branches = { "cryothermy" }, properties = { "temperature" }, verbs = { "reduce" }, forms = { "aura" }, params = { move = "flurry" } },
	-- Heat
	{ id = "energy_heat_haze", effect = "EnergyArt", branches = { "calefaction" }, properties = { "temperature" }, verbs = { "amplify" }, forms = { "aura" }, params = { move = "heat_haze" }, instant = true },
	{ id = "energy_boil", effect = "EnergyArt", branches = { "calefaction" }, properties = { "temperature" }, verbs = { "amplify" }, forms = { "touch", "projectile" }, params = { move = "boil" } },
	{ id = "energy_searing_ground", effect = "EnergyArt", branches = { "calefaction" }, properties = { "temperature" }, verbs = { "generate", "amplify" }, forms = { "zone" }, params = { move = "searing_ground" } },
	-- Light
	{ id = "energy_prism_bolt", effect = "EnergyArt", branches = { "photomancy" }, properties = { "luminosity" }, verbs = { "generate" }, forms = { "projectile" }, params = { move = "prism_bolt", look = "prism" } },
	{ id = "energy_sunspot", effect = "EnergyArt", branches = { "photomancy" }, properties = { "luminosity" }, verbs = { "generate", "amplify" }, forms = { "zone" }, params = { move = "sunspot" } },
	{ id = "energy_wisps", effect = "EnergyArt", branches = { "photomancy" }, properties = { "luminosity" }, verbs = { "bind" }, forms = { "summon" }, params = { move = "wisps" } },
	{ id = "energy_flash", effect = "EnergyArt", branches = { "photomancy" }, properties = { "luminosity" }, verbs = { "release" }, forms = { "burst", "aura" }, params = { move = "flash" }, instant = true },
	{ id = "energy_glowing_poison", effect = "EnergyArt", branches = { "irradiance" }, properties = { "radiation" }, verbs = { "generate", "amplify" }, forms = { "touch", "projectile", "beam" }, params = { move = "glowing_poison" } },
	-- Shadow
	{ id = "energy_shadow_grasp", effect = "EnergyArt", branches = { "umbramancy" }, properties = { "shadow" }, verbs = { "generate", "bind" }, forms = { "touch", "beam", "projectile" }, params = { move = "shadow_grasp" } },
	{ id = "energy_shade_cloak", effect = "EnergyArt", branches = { "umbramancy" }, properties = { "shadow" }, verbs = { "amplify" }, forms = { "aura" }, params = { move = "shade_cloak" }, instant = true },
	{ id = "energy_shadow_puppet", effect = "EnergyArt", branches = { "umbramancy" }, properties = { "shadow" }, verbs = { "generate", "transmute" }, forms = { "summon" }, params = { move = "shadow_puppet" } },
	-- Kinetic
	{ id = "energy_stomp", effect = "EnergyArt", branches = { "kinetic" }, properties = { "momentum" }, verbs = { "release" }, forms = { "burst" }, params = { move = "stomp" } },
	{ id = "energy_ricochet", effect = "EnergyArt", branches = { "impetus" }, properties = { "momentum" }, verbs = { "generate" }, forms = { "projectile" }, params = { move = "ricochet", look = "ricochet" } },
	{ id = "energy_repulse", effect = "EnergyArt", branches = { "deflection" }, properties = { "momentum" }, verbs = { "redirect" }, forms = { "aura" }, params = { move = "repulse" }, instant = true },
	{ id = "energy_inertia_lock", effect = "EnergyArt", branches = { "inertia" }, properties = { "momentum" }, verbs = { "bind" }, forms = { "touch", "beam" }, params = { move = "inertia_lock" } },
	{ id = "energy_launch", effect = "EnergyArt", branches = { "impetus" }, properties = { "momentum" }, verbs = { "amplify" }, forms = { "touch", "aura" }, params = { move = "launch" }, instant = true },
	-- Lightning
	{ id = "energy_ball_lightning", effect = "EnergyArt", branches = { "arcweaving" }, properties = { "charge" }, verbs = { "generate" }, forms = { "projectile" }, params = { move = "ball_lightning", look = "ball", flight = { speed = 0.3 } } },
	{ id = "energy_static_field", effect = "EnergyArt", branches = { "electric" }, properties = { "charge" }, verbs = { "generate" }, forms = { "zone" }, params = { move = "static_field" } },
	{ id = "energy_arc_tether", effect = "EnergyArt", branches = { "electric" }, properties = { "charge" }, verbs = { "bind" }, forms = { "chain" }, params = { move = "arc_tether" } },
	{ id = "energy_galvanise", effect = "EnergyArt", branches = { "galvanism" }, properties = { "charge" }, verbs = { "amplify" }, forms = { "touch", "aura" }, params = { move = "galvanise" } },
	{ id = "energy_arc_fence", effect = "EnergyArt", branches = { "arcweaving" }, properties = { "charge" }, verbs = { "generate" }, forms = { "wall" }, params = { move = "arc_fence" } },

	-- ─── Earth's spells (Effects/EarthArt, Data/EarthTuning, docs/DomainIdeas.md) ─────
	-- Same place and rule as Energy's: each narrow, in a sub-branch, so the root and Geomancy keep Raise
	-- Stone, Pebble Rise, Slip and Stone Skin, Seismic keeps Tremor and the quakes, Ferromancy Iron Pull.
	-- Stone
	{ id = "earth_stone_fist", effect = "EarthArt", branches = { "lithomancy" }, properties = { "contour" }, verbs = { "generate" }, forms = { "projectile" }, params = { move = "stone_fist", look = "fist", flight = { speed = 0.75, gravity = 1.6 } } },
	{ id = "earth_gravel_burst", effect = "EarthArt", branches = { "lithomancy" }, properties = { "cohesion" }, verbs = { "reduce" }, forms = { "burst" }, params = { move = "gravel_burst" } },
	{ id = "earth_spike_trail", effect = "EarthArt", branches = { "lithomancy" }, properties = { "contour" }, verbs = { "generate" }, forms = { "pillar" }, params = { move = "spike_trail" } },
	{ id = "earth_stone_step", effect = "EarthArt", branches = { "lithomancy" }, properties = { "contour" }, verbs = { "amplify" }, forms = { "pillar" }, params = { move = "stone_step" }, instant = true },
	{ id = "earth_stone_grip", effect = "EarthArt", branches = { "lithomancy" }, properties = { "cohesion" }, verbs = { "bind" }, forms = { "touch", "beam" }, params = { move = "stone_grip" } },
	{ id = "earth_ramp", effect = "EarthArt", branches = { "architectonics" }, properties = { "contour" }, verbs = { "transmute" }, forms = { "wall" }, params = { move = "ramp" } },
	{ id = "earth_boulder", effect = "EarthArt", branches = { "lithomancy" }, properties = { "density" }, verbs = { "generate" }, forms = { "projectile" }, params = { move = "boulder", look = "boulder", flight = { speed = 0.85, gravity = 1.4 } } },
	-- Metal
	{ id = "earth_iron_storm", effect = "EarthArt", branches = { "ferromancy" }, properties = { "magnetism" }, verbs = { "generate" }, forms = { "zone" }, params = { move = "iron_storm" } },
	{ id = "earth_blade_rain", effect = "EarthArt", branches = { "metallurgy" }, properties = { "magnetism" }, verbs = { "generate" }, forms = { "ritual" }, maxPower = 7, params = { move = "blade_rain" } },
	{ id = "earth_quicksilver_lash", effect = "EarthArt", branches = { "alloycraft" }, properties = { "purity" }, verbs = { "transmute" }, forms = { "touch" }, params = { move = "quicksilver_lash" } },
	-- Crystal
	{ id = "earth_crystal_spires", effect = "EarthArt", branches = { "crystallurgy" }, properties = { "resonance" }, verbs = { "generate" }, forms = { "pillar" }, params = { move = "crystal_spires" } },
	{ id = "earth_singing_shard", effect = "EarthArt", branches = { "crystallurgy" }, properties = { "resonance" }, verbs = { "generate" }, forms = { "projectile" }, params = { move = "singing_shard", look = "shard" } },
	{ id = "earth_crystal_prison", effect = "EarthArt", branches = { "crystallurgy" }, properties = { "resonance" }, verbs = { "bind" }, forms = { "touch", "beam" }, params = { move = "crystal_prison" } },
	{ id = "earth_geode_shell", effect = "EarthArt", branches = { "focuscraft" }, properties = { "purity" }, verbs = { "amplify" }, forms = { "aura" }, params = { move = "geode_shell" }, instant = true },
	-- Seismic
	{ id = "earth_fissure", effect = "EarthArt", branches = { "faultwork" }, properties = { "seismicity" }, verbs = { "redirect" }, forms = { "beam" }, params = { move = "fissure" } },
	{ id = "earth_ground_ripple", effect = "EarthArt", branches = { "seismic" }, properties = { "seismicity" }, verbs = { "amplify" }, forms = { "burst" }, params = { move = "ground_ripple" } },
	-- Sand
	{ id = "earth_sand_blast", effect = "EarthArt", branches = { "sandshaping" }, properties = { "cohesion" }, verbs = { "redirect" }, forms = { "beam" }, params = { move = "sand_blast" } },
	{ id = "earth_dust_cloud", effect = "EarthArt", branches = { "sandshaping" }, properties = { "cohesion" }, verbs = { "generate" }, forms = { "zone" }, params = { move = "dust_cloud" } },
	{ id = "earth_quicksand", effect = "EarthArt", branches = { "sandshaping" }, properties = { "cohesion" }, verbs = { "reduce" }, forms = { "zone" }, params = { move = "quicksand" } },
	{ id = "earth_dust_devil", effect = "EarthArt", branches = { "dunecalling" }, properties = { "cohesion" }, verbs = { "bind" }, forms = { "summon" }, params = { move = "dust_devil" } },
	{ id = "earth_sand_shroud", effect = "EarthArt", branches = { "sandshaping" }, properties = { "cohesion" }, verbs = { "amplify" }, forms = { "aura" }, params = { move = "sand_shroud" }, instant = true },

	-- ─── Water's spells (Effects/WaterArt, Data/WaterTuning, docs/DomainIdeas.md) ─────
	-- Sub-branches only: the root keeps Pour and the cantrip's Scald, Glaciation's reduce zone stays Freeze,
	-- Tidal keeps Undertow (redirect zone) and Breaker (redirect burst), Tsunamancy the tsunami.
	{ id = "water_water_whip", effect = "WaterArt", branches = { "hydromancy" }, properties = { "flow" }, verbs = { "generate" }, forms = { "touch" }, minPower = 2, params = { move = "water_whip" } },
	{ id = "water_pressure_jet", effect = "WaterArt", branches = { "hydrostatics" }, properties = { "pressure" }, verbs = { "generate" }, forms = { "beam" }, params = { move = "pressure_jet" } },
	{ id = "water_bubble", effect = "WaterArt", branches = { "hydrostatics" }, properties = { "pressure" }, verbs = { "bind" }, forms = { "touch", "beam" }, params = { move = "bubble" } },
	{ id = "water_geyser", effect = "WaterArt", branches = { "hydromancy" }, properties = { "pressure" }, verbs = { "release" }, forms = { "pillar" }, params = { move = "geyser" } },
	{ id = "water_mire", effect = "WaterArt", branches = { "hydromancy" }, properties = { "viscosity" }, verbs = { "amplify" }, forms = { "zone" }, params = { move = "mire" } },
	{ id = "water_wave_surge", effect = "WaterArt", branches = { "tidal" }, properties = { "flow" }, verbs = { "generate" }, forms = { "wall" }, params = { move = "wave_surge" } },
	{ id = "water_whirlpool", effect = "WaterArt", branches = { "tidal" }, properties = { "flow" }, verbs = { "transmute" }, forms = { "zone" }, params = { move = "whirlpool" } },
	{ id = "water_riptide", effect = "WaterArt", branches = { "tidal" }, properties = { "flow" }, verbs = { "redirect" }, forms = { "beam" }, params = { move = "riptide" } },
	{ id = "water_ice_slide", effect = "WaterArt", branches = { "glaciation" }, properties = { "phase" }, verbs = { "transmute" }, forms = { "beam" }, params = { move = "ice_slide" } },
	{ id = "water_permafrost", effect = "WaterArt", branches = { "permafrost" }, properties = { "phase" }, verbs = { "bind" }, forms = { "zone" }, params = { move = "permafrost" } },
	{ id = "water_icicle_rain", effect = "WaterArt", branches = { "glaciation" }, properties = { "phase" }, verbs = { "transmute" }, forms = { "ritual" }, maxPower = 7, params = { move = "icicle_rain" } },
	{ id = "water_ice_dome", effect = "WaterArt", branches = { "glaciation" }, properties = { "phase" }, verbs = { "generate" }, forms = { "wall" }, params = { move = "ice_dome" } },
	{ id = "water_scald", effect = "WaterArt", branches = { "vapor" }, properties = { "phase" }, verbs = { "release" }, forms = { "burst" }, params = { move = "scald" } },
	{ id = "water_fog_bank", effect = "WaterArt", branches = { "fogweaving" }, properties = { "phase" }, verbs = { "generate" }, forms = { "zone" }, params = { move = "fog_bank" } },
	{ id = "water_cloud_step", effect = "WaterArt", branches = { "vapor" }, properties = { "phase" }, verbs = { "amplify" }, forms = { "pillar" }, params = { move = "cloud_step" }, instant = true },
	{ id = "water_cleansing_rain", effect = "WaterArt", branches = { "purification" }, properties = { "purity" }, verbs = { "generate" }, forms = { "zone" }, params = { move = "cleansing_rain" } },
	{ id = "water_water_shield", effect = "WaterArt", branches = { "purification" }, properties = { "purity" }, verbs = { "amplify" }, forms = { "aura" }, params = { move = "water_shield" }, instant = true },
	{ id = "water_fountain", effect = "WaterArt", branches = { "wellspring" }, properties = { "humidity" }, verbs = { "generate" }, forms = { "pillar" }, params = { move = "fountain" } },

	-- ─── Air's spells (Effects/AirArt, Data/AirTuning, docs/DomainIdeas.md) ─────
	-- Sub-branches only: the root keeps Gust and the cantrips, Thunderclap's amplify burst stays plain harm,
	-- Vacuity's reduce stays the choke, Weathercraft's charge bolt stays lightning. (Echo Pulse sits before
	-- `sense`, further up.)
	{ id = "air_wind_blade", effect = "AirArt", branches = { "windshaping" }, properties = { "flow" }, verbs = { "generate" }, forms = { "projectile" }, params = { move = "wind_blade", look = "windblade", flight = { speed = 1.4 } } },
	{ id = "air_gale", effect = "AirArt", branches = { "windshaping" }, properties = { "pressure" }, verbs = { "release" }, forms = { "beam" }, params = { move = "gale" } },
	{ id = "air_twister", effect = "AirArt", branches = { "tempest" }, properties = { "flow" }, verbs = { "bind" }, forms = { "summon" }, params = { move = "twister" } },
	{ id = "air_updraft", effect = "AirArt", branches = { "aeromancy" }, properties = { "buoyancy" }, verbs = { "generate" }, forms = { "pillar" }, params = { move = "updraft" } },
	{ id = "air_airless", effect = "AirArt", branches = { "vacuity" }, properties = { "breath" }, verbs = { "bind" }, forms = { "touch", "beam" }, params = { move = "airless" } },
	{ id = "air_pressure_bomb", effect = "AirArt", branches = { "windshaping" }, properties = { "pressure" }, verbs = { "transmute" }, forms = { "burst" }, params = { move = "pressure_bomb" } },
	{ id = "air_tailwind", effect = "AirArt", branches = { "windshaping" }, properties = { "flow" }, verbs = { "amplify" }, forms = { "aura" }, params = { move = "tailwind" }, instant = true },
	{ id = "air_windwall", effect = "AirArt", branches = { "windshaping" }, properties = { "flow" }, verbs = { "generate" }, forms = { "wall" }, params = { move = "windwall" } },
	{ id = "air_sonic_ring", effect = "AirArt", branches = { "sonics" }, properties = { "sound" }, verbs = { "release" }, forms = { "beam" }, params = { move = "sonic_ring" } },
	{ id = "air_shatter", effect = "AirArt", branches = { "sonics" }, properties = { "sound" }, verbs = { "release" }, forms = { "touch" }, params = { move = "shatter" } },
	{ id = "air_thunder_boom", effect = "AirArt", branches = { "thunderclap" }, properties = { "sound" }, verbs = { "release" }, forms = { "burst" }, params = { move = "thunder_boom" } },
	{ id = "air_raincloud", effect = "AirArt", branches = { "rainmaking" }, properties = { "humidity" }, verbs = { "generate" }, forms = { "touch", "projectile" }, params = { move = "raincloud" } },
	{ id = "air_call_lightning", effect = "AirArt", branches = { "stormbrewing" }, properties = { "charge" }, verbs = { "release" }, forms = { "pillar" }, params = { move = "call_lightning" } },
	{ id = "air_hail", effect = "AirArt", branches = { "stormbrewing" }, properties = { "temperature" }, verbs = { "reduce" }, forms = { "ritual" }, maxPower = 7, params = { move = "hail" } },

	-- ─── Life's spells (Effects/LifeArt, Data/LifeTuning, docs/DomainIdeas.md) ─────
	-- Sub-branches only: the root and Restoration keep healing and Thornlash (the strike), Purgation's
	-- cleanse, Beastspeech's calm, Blight's poison bolt and Arborism's grove stay as they were.
	{ id = "life_healing_grove", effect = "LifeArt", branches = { "mending" }, properties = { "vitality" }, verbs = { "generate" }, forms = { "zone" }, params = { move = "healing_grove" } },
	{ id = "life_lifeline", effect = "LifeArt", branches = { "mending" }, properties = { "vitality" }, verbs = { "transfer" }, forms = { "beam", "touch" }, params = { move = "lifeline" } },
	{ id = "life_petal_ward", effect = "LifeArt", branches = { "mending" }, properties = { "vitality" }, verbs = { "bind" }, forms = { "aura" }, params = { move = "petal_ward" }, instant = true },
	{ id = "life_second_wind", effect = "LifeArt", branches = { "restoration" }, properties = { "metabolism" }, verbs = { "amplify" }, forms = { "aura" }, params = { move = "second_wind" }, instant = true },
	{ id = "life_raise_them", effect = "LifeArt", branches = { "resurgence" }, properties = { "vitality" }, verbs = { "amplify" }, forms = { "touch", "beam" }, params = { move = "raise_them" } },
	{ id = "life_vine_lash", effect = "LifeArt", branches = { "flora" }, properties = { "growth" }, verbs = { "redirect" }, forms = { "beam" }, params = { move = "vine_lash" } },
	{ id = "life_root_snare", effect = "LifeArt", branches = { "flora" }, properties = { "growth" }, verbs = { "bind" }, forms = { "touch", "beam" }, params = { move = "root_snare" } },
	{ id = "life_thorn_burst", effect = "LifeArt", branches = { "flora" }, properties = { "growth" }, verbs = { "transmute" }, forms = { "burst" }, params = { move = "thorn_burst" } },
	{ id = "life_bramble_wall", effect = "LifeArt", branches = { "flora" }, properties = { "growth" }, verbs = { "generate" }, forms = { "wall" }, params = { move = "bramble_wall" } },
	{ id = "life_sapling", effect = "LifeArt", branches = { "arborism" }, properties = { "growth" }, verbs = { "generate" }, forms = { "pillar" }, params = { move = "sapling" } },
	{ id = "life_spore_cloud", effect = "LifeArt", branches = { "mycology" }, properties = { "decay" }, verbs = { "generate" }, forms = { "zone" }, params = { move = "spore_cloud" } },
	{ id = "life_fairy_ring", effect = "LifeArt", branches = { "mycology" }, properties = { "decay" }, verbs = { "amplify" }, forms = { "burst" }, params = { move = "fairy_ring" } },
	{ id = "life_swarm", effect = "LifeArt", branches = { "fauna" }, properties = { "instinct" }, verbs = { "generate" }, forms = { "projectile" }, params = { move = "swarm" } },
	{ id = "life_flock", effect = "LifeArt", branches = { "fauna" }, properties = { "instinct" }, verbs = { "release" }, forms = { "burst", "aura" }, params = { move = "flock" }, instant = true },
	{ id = "life_beast_claws", effect = "LifeArt", branches = { "wildshape" }, properties = { "metabolism" }, verbs = { "amplify" }, forms = { "aura" }, params = { move = "beast_claws" }, instant = true },
	{ id = "life_rot", effect = "LifeArt", branches = { "blight" }, properties = { "decay" }, verbs = { "transmute" }, forms = { "touch", "projectile" }, params = { move = "rot" } },
	{ id = "life_withering_field", effect = "LifeArt", branches = { "withering" }, properties = { "decay" }, verbs = { "generate" }, forms = { "zone" }, params = { move = "withering_field" } },
	{ id = "life_plague_flies", effect = "LifeArt", branches = { "pestilence" }, properties = { "toxin" }, verbs = { "generate" }, forms = { "projectile" }, params = { move = "plague_flies" } },
	{ id = "life_corpse_bloom", effect = "LifeArt", branches = { "blight" }, properties = { "toxin" }, verbs = { "generate" }, forms = { "pillar" }, params = { move = "corpse_bloom" } },

	-- ─── Void's spells (Effects/VoidArt, Data/VoidTuning, docs/DomainIdeas.md) ─────
	-- Sub-branches only, ahead of the old Void routes just below: Negation's burst stays Dispel, Silence's
	-- zone stays Silence, Eclipse's zone stays darkness, Stillness stays Still, Siphoning's transfer stays
	-- Siphon, and the root keeps Unmake (the strike).
	{ id = "void_null_bolt", effect = "VoidArt", branches = { "negation" }, properties = { "aether" }, verbs = { "reduce" }, forms = { "projectile" }, params = { move = "null_bolt" } },
	{ id = "void_unravel", effect = "VoidArt", branches = { "dispelling" }, properties = { "aether" }, verbs = { "transmute" }, forms = { "beam" }, params = { move = "unravel" } },
	{ id = "void_antimagic_shell", effect = "VoidArt", branches = { "antimagic" }, properties = { "aether" }, verbs = { "bind" }, forms = { "aura" }, params = { move = "antimagic_shell" }, instant = true },
	{ id = "void_null_ground", effect = "VoidArt", branches = { "antimagic" }, properties = { "aether" }, verbs = { "reduce" }, forms = { "zone" }, params = { move = "null_ground" } },
	{ id = "void_black_sun", effect = "VoidArt", branches = { "eclipse" }, properties = { "luminosity" }, verbs = { "reduce" }, forms = { "pillar" }, params = { move = "black_sun" } },
	{ id = "void_hush", effect = "VoidArt", branches = { "silence" }, properties = { "sound" }, verbs = { "reduce" }, forms = { "projectile", "touch" }, params = { move = "hush" } },
	{ id = "void_ground_out", effect = "VoidArt", branches = { "dampening" }, properties = { "charge" }, verbs = { "reduce" }, forms = { "zone" }, params = { move = "ground_out" } },
	{ id = "void_sponge", effect = "VoidArt", branches = { "absorption" }, properties = { "essence" }, verbs = { "bind" }, forms = { "aura" }, params = { move = "sponge" }, instant = true },
	{ id = "void_hungry_mouth", effect = "VoidArt", branches = { "absorption" }, properties = { "essence" }, verbs = { "redirect" }, forms = { "zone" }, params = { move = "hungry_mouth" } },
	{ id = "void_shadow_step", effect = "VoidArt", branches = { "obscurance" }, properties = { "presence" }, verbs = { "redirect" }, forms = { "touch", "beam", "projectile" }, params = { move = "shadow_step" }, instant = true },
	{ id = "void_rift_mote", effect = "VoidArt", branches = { "obscurance" }, properties = { "presence" }, verbs = { "reduce" }, forms = { "projectile" }, params = { move = "rift_mote" } },
	{ id = "void_black_flame", effect = "VoidArt", branches = { "nullsign" }, properties = { "presence" }, verbs = { "transmute" }, forms = { "touch", "projectile" }, params = { move = "black_flame" } },
	{ id = "void_unseen", effect = "VoidArt", branches = { "nullsign" }, properties = { "presence" }, verbs = { "reduce" }, forms = { "aura" }, params = { move = "unseen" }, instant = true },

	-- ─── Spirit's spells (Effects/SpiritArt, Data/SpiritTuning, docs/DomainIdeas.md) ─────
	-- Narrow: Warding's aura stays the Ward, Hexcraft's bolt stays the hex, Soulbinding's soul bind and
	-- Necrourgy's burst stay as they were, and the root keeps Soul Prick (the strike) and Sense.
	{ id = "spirit_glyph_shield", effect = "SpiritArt", branches = { "warding" }, properties = { "warding" }, verbs = { "generate" }, forms = { "wall" }, params = { move = "glyph_shield" } },
	{ id = "spirit_sigil_trap", effect = "SpiritArt", branches = { "sanctum" }, properties = { "warding" }, verbs = { "bind" }, forms = { "zone" }, params = { move = "sigil_trap" } },
	{ id = "spirit_hallowed_ground", effect = "SpiritArt", branches = { "hallowing" }, properties = { "warding" }, verbs = { "amplify" }, forms = { "zone" }, params = { move = "hallowed_ground" } },
	{ id = "spirit_mirror_ward", effect = "SpiritArt", branches = { "counterwarding" }, properties = { "warding" }, verbs = { "redirect" }, forms = { "aura" }, params = { move = "mirror_ward" }, instant = true },
	{ id = "spirit_doom_mark", effect = "SpiritArt", branches = { "hexcraft" }, properties = { "malediction" }, verbs = { "amplify" }, forms = { "touch", "beam", "projectile" }, params = { move = "doom_mark" } },
	{ id = "spirit_ill_luck", effect = "SpiritArt", branches = { "greatercurses" }, properties = { "malediction" }, verbs = { "generate" }, forms = { "aura" }, params = { move = "ill_luck" }, instant = true },
	{ id = "spirit_thorn_curse", effect = "SpiritArt", branches = { "greatercurses" }, properties = { "malediction" }, verbs = { "transmute" }, forms = { "touch", "beam", "projectile" }, params = { move = "thorn_curse" } },
	{ id = "spirit_spirit_chains", effect = "SpiritArt", branches = { "binding" }, properties = { "bond" }, verbs = { "bind" }, forms = { "touch", "beam" }, params = { move = "spirit_chains" } },
	{ id = "spirit_soul_tether", effect = "SpiritArt", branches = { "binding" }, properties = { "bond" }, verbs = { "bind" }, forms = { "chain" }, params = { move = "soul_tether" } },
	{ id = "spirit_shared_fate", effect = "SpiritArt", branches = { "pactcraft" }, properties = { "will" }, verbs = { "bind" }, forms = { "touch", "beam" }, params = { move = "shared_fate" } },
	{ id = "spirit_grave_hand", effect = "SpiritArt", branches = { "necrourgy" }, properties = { "unlife" }, verbs = { "generate" }, forms = { "touch", "beam" }, params = { move = "grave_hand" } },
	{ id = "spirit_spirit_wolves", effect = "SpiritArt", branches = { "revenancy" }, properties = { "soul" }, verbs = { "generate" }, forms = { "summon" }, params = { move = "spirit_wolves" } },
	{ id = "spirit_ghost_form", effect = "SpiritArt", branches = { "deathspeech" }, properties = { "soul" }, verbs = { "transmute" }, forms = { "aura" }, params = { move = "ghost_form" }, instant = true },
	{ id = "spirit_wail", effect = "SpiritArt", branches = { "necrourgy" }, properties = { "soul" }, verbs = { "release" }, forms = { "burst", "aura" }, params = { move = "wail" }, instant = true },
	{ id = "spirit_grave_mist", effect = "SpiritArt", branches = { "deathspeech" }, properties = { "unlife" }, verbs = { "generate" }, forms = { "zone" }, params = { move = "grave_mist" } },

	-- ─── Mind's spells (Effects/MindArt, Data/MindTuning, docs/DomainIdeas.md) ─────
	-- Narrow: the root keeps Psychic Spike (the strike: perception generate) and Sense, Dread's burst stays
	-- fear, Charm's touch stays charm, Illusion's burst stays blinding, Veiling's reduce aura stays the veil,
	-- Insight's sense stays Sense, and Mindlink (the Space hybrid) stays its own.
	{ id = "mind_far_eye", effect = "MindArt", branches = { "farsight" }, properties = { "perception" }, verbs = { "amplify" }, forms = { "projectile" }, params = { move = "far_eye", look = "eye", flight = { speed = 1.2 } } },
	{ id = "mind_weak_spot", effect = "MindArt", branches = { "insight" }, properties = { "perception" }, verbs = { "amplify" }, forms = { "touch", "beam" }, params = { move = "weak_spot" } },
	{ id = "mind_rally", effect = "MindArt", branches = { "empathy" }, properties = { "emotion" }, verbs = { "amplify" }, forms = { "aura" }, params = { move = "rally" }, instant = true },
	{ id = "mind_despair", effect = "MindArt", branches = { "dread" }, properties = { "emotion" }, verbs = { "reduce" }, forms = { "zone" }, params = { move = "despair" } },
	{ id = "mind_pacify", effect = "MindArt", branches = { "charm" }, properties = { "emotion" }, verbs = { "reduce" }, forms = { "zone" }, params = { move = "pacify" } },
	{ id = "mind_mirror_images", effect = "MindArt", branches = { "illusion" }, properties = { "illusion" }, verbs = { "generate" }, forms = { "aura" }, params = { move = "mirror_images" }, instant = true },
	{ id = "mind_phantom_blade", effect = "MindArt", branches = { "phantasm" }, properties = { "illusion" }, verbs = { "generate" }, forms = { "projectile" }, params = { move = "phantom_blade", look = "blade" } },
	{ id = "mind_false_wall", effect = "MindArt", branches = { "phantasm" }, properties = { "illusion" }, verbs = { "transmute" }, forms = { "wall" }, params = { move = "false_wall" } },
	{ id = "mind_phantom_beast", effect = "MindArt", branches = { "phantasm" }, properties = { "illusion" }, verbs = { "generate" }, forms = { "summon" }, params = { move = "phantom_beast" } },
	{ id = "mind_vanish", effect = "MindArt", branches = { "veiling" }, properties = { "illusion" }, verbs = { "amplify" }, forms = { "aura" }, params = { move = "vanish" }, instant = true },
	{ id = "mind_mirage_pit", effect = "MindArt", branches = { "grandillusion" }, properties = { "illusion" }, verbs = { "transmute" }, forms = { "zone" }, params = { move = "mirage_pit" } },
	{ id = "mind_forget_me", effect = "MindArt", branches = { "oblivion" }, properties = { "memory" }, verbs = { "reduce" }, forms = { "touch", "beam" }, params = { move = "forget_me" } },
	{ id = "mind_mind_spike", effect = "MindArt", branches = { "telepathy" }, properties = { "thought" }, verbs = { "generate" }, forms = { "projectile" }, params = { move = "mind_spike", look = "spike" } },
	{ id = "mind_psychic_push", effect = "MindArt", branches = { "telepathy" }, properties = { "thought" }, verbs = { "release" }, forms = { "beam" }, params = { move = "psychic_push" } },
	{ id = "mind_whispers", effect = "MindArt", branches = { "telepathy" }, properties = { "thought" }, verbs = { "generate" }, forms = { "zone" }, params = { move = "whispers" } },
	{ id = "mind_puppet", effect = "MindArt", branches = { "dominion" }, properties = { "will" }, verbs = { "bind" }, forms = { "touch", "beam" }, params = { move = "puppet" } },

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
