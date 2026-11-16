--!strict
--[[
	RouteSummaries: what each EffectLibrary route does, in the player's words. Read by
	Magic/SpellOutcome for the Spell Composer. Every line is written from the route's resolver
	(Cast/Effects/*): describe what the code does today, not what the spell ought to do.
	Tests/SpellOutcome.spec fails if a route has no summary.

	kinds        the tag families, in display order: glyph + word (colour is never the only cue)
	routes       per route id:
	    kind       a key of `kinds`; "none" means the spell has no real effect
	    text       one sentence on what happens
	    byVerb / byProperty / byForm   overrides of kind and/or text (applied in that order: byForm wins)
	    lasts      the resolver reads stats.duration, so Lingering has something to extend
	builds       routes where the wall form really raises something
	areaShape    how a wall or summon form behaves when nothing is built
	deadModifiers  modifiers no code reads yet, and the warning to show
	wasted       warnings for modifiers the chosen effect can't use
]]

export type Variant = { kind: string?, text: string? }
export type Summary = {
	kind: string,
	text: string,
	byVerb: { [string]: Variant }?,
	byProperty: { [string]: Variant }?,
	byForm: { [string]: Variant }?,
	lasts: boolean?,
}

local SenseSight = require(script.Parent.SenseSight)
local Behaviours = require(script.Parent.PropertyBehaviours)

local RouteSummaries = {}

RouteSummaries.kinds = {
	attack = { glyph = "⚔", word = "Attack" },
	heal = { glyph = "✚", word = "Heal" },
	protect = { glyph = "◆", word = "Protect" },
	boost = { glyph = "✦", word = "Boost" },
	control = { glyph = "●", word = "Control" },
	move = { glyph = "➜", word = "Move" },
	land = { glyph = "▲", word = "Shape the world" },
	sense = { glyph = "◉", word = "Sense" },
	utility = { glyph = "◇", word = "Utility" },
	none = { glyph = "✗", word = "No real effect" },
} :: { [string]: { glyph: string, word: string } }

RouteSummaries.kindOrder = { "attack", "heal", "protect", "boost", "control", "move", "land", "sense", "utility" }

local routes: { [string]: Summary } = {
	-- World-scale
	earthquake = { kind = "land", text = "Shakes the whole area and scars the land for good." },
	tsunami = { kind = "land", text = "A great wave rolls in over the land." },

	-- Time
	self_timeline = { kind = "utility", text = "Marks this moment on you. Press N to snap back to it." },
	target_timeline = { kind = "control", text = "Marks someone. Press L to snap them back to that moment, stunned." },
	time_loop = { kind = "control", text = "Keeps snapping a target back to where they stood." },
	stored_moment = { kind = "utility", text = "Your projectiles hang in the air until you press L to send them." },
	borrowed_wound = {
		kind = "attack",
		text = "Hits on your target wait, then land harder.",
		byForm = { aura = { kind = "protect", text = "Hits on you wait, and cost you less." } },
	},
	future_sight = { kind = "protect", text = "Shows where nearby spells are aimed, and sometimes lets you not be there." },
	timestop = { kind = "control", text = "Freezes everyone you can harm in the area, and every projectile in it." },
	time_field = {
		kind = "control",
		text = "Leaves an area where time runs differently.",
		byVerb = { reduce = { text = "Leaves an area where time runs slow." }, amplify = { text = "Leaves an area where time runs fast." } },
		lasts = true,
	},
	tempo = {
		kind = "control",
		text = "Changes how fast someone moves through time.",
		byVerb = {
			amplify = { kind = "boost", text = "Hastes whoever it reaches, or you if it reaches nobody." },
			reduce = { text = "Slows whoever it reaches." },
		},
	},
	stasis = { kind = "control", text = "Holds whoever it reaches in stasis." },

	-- Reality
	worldlaw = {
		kind = "control",
		text = "Lays a law over a whole region for minutes.",
		byVerb = {
			reduce = { text = "Over a whole region, for minutes: nobody you could harm may cast." },
			amplify = { kind = "protect", text = "Over a whole region, for minutes: nobody can be hurt except by you." },
			bind = { kind = "protect", text = "Over a whole region, for minutes: hostile projectiles stop existing." },
			transmute = { kind = "heal", text = "Over a whole region, for minutes: harm on you and your allies heals instead." },
		},
	},
	edict = {
		kind = "control",
		text = "Lays down a local law for a while.",
		byVerb = {
			reduce = { text = "Hush: nobody you could harm may cast inside." },
			amplify = { kind = "protect", text = "Sanctuary: nobody inside can be hurt, except by you." },
			bind = { kind = "protect", text = "Severance: hostile projectiles stop existing inside." },
			transmute = { kind = "heal", text = "Reversal: harm on you and your allies inside heals instead." },
		},
	},
	favor = { kind = "boost", text = "Your hits crit more, some hits on you graze off, and you backfire less." },
	doom = { kind = "attack", text = "Their luck turns: you crit them more, their hits sometimes miss, and they backfire more." },
	certainty = { kind = "attack", text = "Your next few hits on them are certain to crit." },
	twist_of_fate = { kind = "protect", text = "The next few blows on you are cancelled and sent back at whoever dealt them." },
	conjure_being = {
		kind = "attack",
		text = "Conjures beings out of nothing: any elemental there is, Reality's own giants, or a double of whatever you aim at.",
		byVerb = {
			generate = { text = "Conjures a host out of nothing that fights beside you: any elemental there is, Reality's own giants, or a double of whatever you aim at." },
			bind = { kind = "protect", text = "Conjures guardians out of nothing that hold the ground you aim at: any elemental there is, Reality's own giants, or a double of whatever you aim at." },
			transmute = { text = "Conjures one colossal being out of nothing, bigger with power: any elemental there is, Reality's own giants, or a double of whatever you aim at." },
		},
	},
	remake_land = { kind = "land", text = "The ground where you aim becomes whatever you wish: lava, water, ice, stone, grass, sand and more. For good, on every server; never inside a town." },
	conjure_things = { kind = "land", text = "Whatever you wish appears where you aim for a while: a forest, a field of fire, floating lights, a spring, crystal spires, boulders." },
	-- Stage 1b: the properties that did nothing (docs/SpellOverhaul.md §11). Point forms reach
	-- whoever you aim at; area forms and auras cover everyone around (FOE) or you and your allies (FRIEND).
	veil_presence = { kind = "protect", text = "Hides your presence: magic and watching eyes lose track of you (and your allies, as an area or aura)." },
	expose = { kind = "control", text = "Makes their presence blaze: luck turns on them and crits find them easily." },
	weigh_down = { kind = "control", text = "Makes them heavy and thick: they slow to a crawl." },
	anchor_weight = { kind = "boost", text = "Packs you and your allies dense: slower, but every blow lands heavier." },
	featherweight = { kind = "move", text = "Makes you light as a feather: you jump far higher (your allies too, as an area or aura)." },
	mist = { kind = "protect", text = "A mist rises around you: you and your allies are hidden in it." },
	dry_air = { kind = "utility", text = "Dries the air: fires nearby go out, and burning stops on you and your allies." },
	keen_senses = { kind = "boost", text = "Sharpens your senses: you see blows coming and slip some of them (your allies too, as an area or aura)." },
	dull_senses = {
		kind = "control",
		text = "Dulls their senses.",
		byVerb = { reduce = { text = "Dims their senses: they're blinded for a moment." }, transmute = { text = "Twists their senses: they reel, dazed." } },
	},
	unward = { kind = "control", text = "Tears down wards and workings around where you aim (not your own)." },
	ward_more = { kind = "protect", text = "Seals you and your allies in a ward that soaks up harm and resists magic." },
	stunt = {
		kind = "control",
		text = "Stunts what grows in them.",
		byVerb = { reduce = { text = "Stunts them: they slow." }, transmute = { kind = "attack", text = "Turns their growth to rot: it eats at them for a while." } },
	},
	bloom = { kind = "heal", text = "A rush of growth closes wounds." },
	stone_skin = { kind = "protect", text = "Stone skin: a ward that soaks up harm (you, or whoever you touch; your allies as an area or aura)." },
	brittle = { kind = "control", text = "Makes them brittle: every hit hurts more for a while." },
	thicken = { kind = "control", text = "Thickens the air and ground: everyone around is slowed." },
	slick = { kind = "boost", text = "Makes everything slick: you move faster (your allies too, as an area or aura)." },
	sink = { kind = "control", text = "Takes their lift away: they sink and slow." },
	distance_pull = { kind = "move", text = "Folds the distance shut: they're dragged toward where you aim." },
	distance_push = { kind = "move", text = "Stretches the distance: they're thrown away." },
	courage = { kind = "boost", text = "Fills you with courage: you move faster (your allies too, as an area or aura)." },
	dread = { kind = "control", text = "Floods them with dread: they flee." },
	sway = { kind = "control", text = "Sways their heart: charmed, they won't fight you for a moment." },
	becalm = { kind = "control", text = "Binds their temper: calmed, they won't fight for a moment." },
	wellspring = { kind = "utility", text = "Draws magic up out of the world: you and your allies get reservoir back." },
	raise_stone = { kind = "land", text = "Stone spikes rise out of the ground where it lands." },
	purify = { kind = "heal", text = "Purifies you and your allies: poison, rot, hexes, sickness and burning are drawn out." },
	cage = { kind = "control", text = "Shuts them in a box of solid matter for a few seconds." },
	conjure = {
		kind = "land",
		text = "Makes solid matter from nothing for a while.",
		byForm = {
			touch = { text = "A step under your feet: stand on the air." },
			beam = { text = "A bridge from your feet to where you aim." },
			wall = { kind = "protect", text = "A wall of solid matter where you aim." },
			pillar = { text = "A pillar where you aim. Under your feet, it carries you up." },
			zone = { kind = "protect", text = "A bastion: a ring of walls with a roof." },
			burst = { kind = "protect", text = "A bastion: a ring of walls with a roof." },
			ritual = { kind = "protect", text = "A bastion: a ring of walls with a roof." },
		},
	},
	unmake = { kind = "attack", text = "Walls and things in reach stop existing for a while; people lose their wards and are hurt. Floors stay." },
	undying = { kind = "protect", text = "For a few seconds, nothing can take you below 1 health." },
	fray = { kind = "attack", text = "They become less real and take more damage." },
	polymorph = { kind = "control", text = "Turns them into a small creature that can't cast or fight. With nobody there, it changes what things are made of." },
	exchange = { kind = "heal", text = "You and your target swap how hurt you are. Only works if you'd gain." },

	-- Senses and charges
	sense = { kind = "sense", text = "Tells you what you can feel nearby, in a few words. It touches nobody." }, -- byProperty: Data/SenseSight (below)
	store = { kind = "utility", text = "Holds a charge for a short while. On its own that's all: a Release spell of the same property lets it out." },

	strike = { kind = "attack", text = "Your domain's first attack: hits what it reaches and adds a small extra." },

	-- Void
	dispel = { kind = "control", text = "Ends other people's magic in the area: fires, fields, magic walls and statuses." },
	silence = { kind = "control", text = "Silences everyone in the area." },
	darken = { kind = "control", text = "Blinds everyone in the area and puts out magic lights." },
	still = { kind = "control", text = "Slows everyone in the area and stops loose objects dead." },

	-- Gravity
	singularity = { kind = "attack", text = "Holds a crowd, pulls them together, then detonates." },
	orbit_shield = { kind = "protect", text = "Debris circles you and stops hostile projectiles." },
	gravity_well = { kind = "attack", text = "Drags everyone in reach toward the spot. The middle crushes." },
	flight = { kind = "move", text = "You take to the air until you land, run dry or get dragged down." },
	mass_shift = {
		kind = "boost",
		text = "Changes how heavy you are.",
		byVerb = {
			amplify = { text = "You turn heavy: you resist damage, hit harder and ignore knockback." },
			reduce = { text = "You turn light: you're fast and jump huge distances." },
		},
	},
	crushing_grip = { kind = "attack", text = "Pins one target and crushes them." },
	bend_path = { kind = "protect", text = "A bubble around you curves hostile projectiles away, or turns them back." },
	lift_slam = { kind = "attack", text = "Seizes one target, raises them and drives them into the ground." },
	gravity_field = { kind = "control", text = "Leaves an area where gravity changes.", lasts = true },
	reality = { kind = "control", text = "Leaves an area where the rules of the world change.", lasts = true },
	fortune = { kind = "boost", text = "Makes you and other players in the area luckier." },

	-- Space (Effects/SpacePower, docs/Space.md)
	space_gate = { kind = "move", text = "Opens two linked holes in space, one in front of you and one where you aim. Anyone can walk through, and bolts fired in come out the other end." },
	space_swap = { kind = "move", text = "You and your target change places." },
	space_seal = {
		kind = "control",
		text = "Closes space around your target: they can't move, cast or be hurt, and bolts stop at the wall.",
		byForm = {
			zone = { text = "Closes space around everyone in the area: they can't move, cast or be hurt." },
			burst = { text = "Closes space around everyone near you: they can't move, cast or be hurt." },
			ritual = { text = "Closes space around everyone in the area: they can't move, cast or be hurt." },
		},
	},
	space_stride = { kind = "move", text = "Space folds under your feet: every step covers far more ground, until you hurt someone." },
	space_pocket = { kind = "utility", text = "Opens your own pocket of space, wherever you are: what you put in it is kept, and only you can reach it." },
	space_anchor = { kind = "move", text = "Space remembers where you stand. Release it later to come back here." },
	space_recall = { kind = "move", text = "Takes you back to the spot you anchored, from as far as your mastery reaches. From Grandmaster, friends beside you come too." },
	space_stretch = { kind = "control", text = "Stretches space over an area: everyone else in it crawls, and other people's bolts slow as they cross." },
	space_cut = { kind = "attack", text = "Cuts space along your aim, hurting everyone it crosses. Guards can't turn it." },
	blink = {
		kind = "move",
		text = "Moves a body through space.",
		byVerb = {
			redirect = { text = "You step to where you aim." },
			transfer = { kind = "control", text = "Pulls your target to stand in front of you." },
		},
	},
	fold = { kind = "control", text = "Pulls everyone and everything in reach toward the spot." },

	-- Spirit, Life and Mind
	ward = { kind = "protect", text = "Shields you and other players in the area against harm." },
	cleanse = { kind = "heal", text = "Removes poison, rot, hexes and burning from you and other players in the area." },
	afflict = { kind = "attack", text = "Inflicts a lasting poison, rot or hex on whoever it reaches, with a little damage." },
	fear = { kind = "control", text = "Fills whoever it reaches with fear." },
	charm = { kind = "control", text = "Charms whoever it reaches." },
	illusion_blind = { kind = "control", text = "Blinds whoever it reaches with false sights." },
	veil = { kind = "boost", text = "Veils you from sight." },
	soothe = { kind = "control", text = "Calms whoever it reaches." },
	siphon = { kind = "attack", text = "Drinks life from whoever it reaches and heals you with half of it." },

	-- Energy
	light = { kind = "utility", text = "Makes a light that stays with you for a while.", lasts = true },
	ignite = { kind = "attack", text = "Sets people, flammable things and the ground alight. Strong fire jumps to whoever stands beside them." },
	heat_transfer = { kind = "attack", text = "Draws the heat out of a target and into what's around it. A person chilled this way is hurt a little." },
	thermal = {
		kind = "attack",
		text = "Burns whoever it reaches (they keep burning a moment) and heats what it lands on.",
		byVerb = { reduce = { kind = "control", text = "Chills: people slow more with every hit and three chills freeze them solid; things cool, fires go out and water freezes." } },
	},

	-- Water
	freeze = { kind = "control", text = "Turns a water surface to ice. Swimmers are caught; anyone else is chilled, and three chills freeze them solid. Fires go out.", lasts = true },
	pour = { kind = "land", text = "Pours a pool of water out of the air. It won't work where water already is.", lasts = true },
	current = { kind = "move", text = "Leaves a current that shoves everyone the way you aimed.", lasts = true },
	wave = { kind = "attack", text = "A wave rolls from you toward your aim, knocking people down." },

	-- Earth
	tremor = { kind = "control", text = "A local shudder: people and loose things are knocked about and buildings take light damage. The land doesn't change." },
	landslide = { kind = "land", text = "The slope where you aim slides downhill, for good." },
	stoneshape = { kind = "land", text = "Raises temporary stone: a wall, a pillar or a ring of spikes.", lasts = true },
	stonetouch = { kind = "land", text = "Draws a fist of stone up out of the ground where you touch; it sinks back after a while.", lasts = true },
	metal = {
		kind = "move",
		text = "Pulls loose metal toward you, or chunks out of ore, and hurts whoever the spell reaches.",
		byVerb = { redirect = { text = "Flings the loose metal around you at your aim, and hurts whoever the spell reaches." } },
	},

	-- General
	restore = { kind = "heal", text = "Heals whoever it reaches, or you if it reaches nobody." },
	construct = { kind = "land", text = "Builds a temporary wall or pillar.", lasts = true },
	binding = { kind = "control", text = "Roots whoever it reaches to the spot." },
	force = {
		kind = "move",
		text = "Pushes whoever it reaches away.",
		byVerb = {
			transfer = { text = "Pulls whoever it reaches toward you." },
			redirect = { text = "Shoves whoever it reaches the way you aim." },
		},
	},
	harm = { kind = "attack", text = "Damages whoever it reaches." }, -- byProperty: Data/PropertyBehaviours (below)
	manifest = { kind = "none", text = "Almost nothing happens. It shows its light and spends your magic, but it won't hurt, help or move anyone." },
}
-- Harmful spells say what their property does besides damage (docs/SpellOverhaul.md §2A).
do
	local byProperty: { [string]: Variant } = {}
	for propertyId, behaviour in Behaviours do
		byProperty[propertyId] = { text = "Damages whoever it reaches. " .. behaviour.summary }
	end
	routes.harm.byProperty = byProperty
end

-- Sense spells whose property SHOWS something (Data/SenseSight) say what they show.
do
	local byProperty: { [string]: Variant } = {}
	for _, kind in SenseSight.kinds do
		for _, property in kind.properties do
			byProperty[property] = { text = kind.summary }
		end
	end
	routes.sense.byProperty = byProperty
end

-- Stage 1c fallbacks (Data/PropertyFallbacks): one route per property, its words by verb; the kind
-- follows the status (harmful: control, else boost).
do
	local Fallbacks = require(script.Parent.PropertyFallbacks)
	local StatusInfo = require(script.Parent.StatusInfo)
	for property, verbs in Fallbacks.list do
		local byVerb: { [string]: Variant } = {}
		for verb, entry in verbs do
			local info = (StatusInfo :: any)[entry.status]
			local kind = if (info and info.harmful) or entry.on == "foe" then "control" elseif entry.status == "ward" then "protect" else "boost"
			byVerb[verb] = { kind = kind, text = entry.words .. "." }
		end
		routes["fallback_" .. property] = { kind = "utility", text = "A working of " .. property .. ".", byVerb = byVerb }
	end
end

-- Domain ultimates (Data/Ultimates, stage 5): one route each, named.
do
	local Ultimates = require(script.Parent.Ultimates)
	for id, u in Ultimates.list do
		routes["ult_" .. id] = { kind = "attack", text = string.format("%s, your domain's ultimate: %s Long to call again.", u.name, u.words) }
	end
end

RouteSummaries.routes = routes

RouteSummaries.builds = { construct = true, stoneshape = true } :: { [string]: boolean }
RouteSummaries.areaShape = "as a blast over the area where you aim"

RouteSummaries.deadModifiers = {
	linked = "Not working yet: you'd pay extra and nothing would be linked.",
	silent = "Not working yet: you'd pay extra and the spell would be just as loud.",
} :: { [string]: string }

RouteSummaries.wasted = {
	echoing = "This effect can't repeat, so you'd pay extra for no echoes.",
	channeled = "This effect can't be held, so it would only go off once.",
	lingering = "This effect has nothing lasting to extend, so it would just be weaker.",
} :: { [string]: string }

return RouteSummaries
