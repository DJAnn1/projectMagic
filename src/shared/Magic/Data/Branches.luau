--!strict
--[[
	Branches: the study tree.

	roots[domainId] is the tier-0 node for that Domain; its id MUST equal the domain id.
	Tier = depth in the tree (root 0). Hybrids start at Tuning.hybridTier.

	Rules (enforced by Registry / MagicCore):
	- `id` is globally unique and saved; never rename (alias instead). Moving a node changes
	  its tier but not its id, so saves survive restructuring.
	- `properties` are granted IN ADDITION to the parent's; they must belong to the node's domain(s).
	- A node unlocks when its parent is unlocked AND parent mastery >= Tuning.unlockMastery[tier]
	  AND every explicit `prerequisites` entry is met.
	- `maxPower` defaults to Tuning.tierMaxPower[tier]; world-altering nodes raise it to 10.
]]
local Types = require(script.Parent.Parent.Types)

type Node = Types.BranchNode

local roots: { [string]: Node } = {
	-- ─── ENERGY ─────────────────────────────────────────────────────────────
	energy = {
		id = "energy",
		name = "Raw Energy",
		description = "Untrained channelling of heat, light and force. Candles, sparks, nudges.",
		properties = { "temperature", "luminosity", "momentum" },
		children = {
			{
				id = "thermal",
				name = "Thermal Arts",
				description = "Moving heat into and out of things.",
				properties = { "combustion" },
				children = {
					{
						id = "pyromancy",
						name = "Pyromancy",
						description = "Kindling, shaping and feeding open flame.",
						children = {
							{ id = "conflagration", name = "Conflagration", description = "Self-sustaining wildfires and firestorms.", maxPower = 10, tags = { "worldAltering" } },
						},
					},
					{
						id = "cryothermy",
						name = "Cryothermy",
						description = "Cold-draw: pulling heat out of matter until it freezes or shatters.",
						children = {
							{ id = "stillfrost", name = "Stillfrost", description = "Drawing heat so completely that motion itself slows." },
						},
					},
					{ id = "calefaction", name = "Calefaction", description = "Precise heat transfer: smithing, cooking, siphoning warmth between bodies." },
				},
			},
			{
				id = "luminous",
				name = "Luminous Arts",
				description = "Making, bending and removing light.",
				properties = { "shadow" },
				children = {
					{
						id = "photomancy",
						name = "Photomancy",
						description = "Flares, lenses and cutting beams of light.",
						children = {
							{ id = "irradiance", name = "Irradiance", description = "Invisible, penetrating light that burns from within.", properties = { "radiation" } },
						},
					},
					{ id = "umbramancy", name = "Umbramancy", description = "Shaping shadow: cloaks of darkness, shadow puppets, blinding gloom." },
				},
			},
			{
				id = "kinetic",
				name = "Kinetic Arts",
				description = "Force, impact and momentum.",
				children = {
					{ id = "impetus", name = "Impetus", description = "Shoves, strikes and launches." },
					{
						id = "deflection",
						name = "Deflection",
						description = "Catching and redirecting incoming momentum.",
						children = {
							{ id = "inertia", name = "Inertial Command", description = "Stopping avalanches and arrows alike; redirecting momentum at scale." },
						},
					},
				},
			},
			{
				id = "electric",
				name = "Electromancy",
				description = "Charge, current and spark.",
				properties = { "charge" },
				children = {
					{ id = "galvanism", name = "Galvanism", description = "Currents through bodies: stuns, jolts, restarting hearts." },
					{ id = "arcweaving", name = "Arcweaving", description = "Shaping arcs between points; electrical traps and conduits." },
				},
			},
		},
	},

	-- ─── EARTH ──────────────────────────────────────────────────────────────
	earth = {
		id = "earth",
		name = "Raw Earth",
		description = "Feeling and nudging the solid world: firming soil, lifting pebbles.",
		properties = { "hardness", "density", "contour" },
		children = {
			{
				id = "geomancy",
				name = "Geomancy",
				description = "Shaping stone and soil.",
				properties = { "cohesion" },
				children = {
					{
						id = "lithomancy",
						name = "Lithomancy",
						description = "Precise stoneshaping: walls, stairs, bridges.",
						children = {
							{ id = "architectonics", name = "Architectonics", description = "Raising fortresses and canyons in a single working.", maxPower = 10, tags = { "worldAltering" } },
						},
					},
					{
						id = "metallurgy",
						name = "Metallurgy",
						description = "Iron, bronze, steel and alloys; hardening flesh into metal.",
						properties = { "magnetism", "purity" },
						children = {
							{ id = "ferromancy", name = "Ferromancy", description = "Magnetism: pulling blades from hands, levitating iron." },
							{ id = "alloycraft", name = "Alloycraft", description = "Refining, alloying and transmuting metals." },
						},
					},
					{
						id = "crystallurgy",
						name = "Crystallurgy",
						description = "Growing gems and tuning their resonance.",
						properties = { "resonance", "purity" },
						children = {
							{ id = "focuscraft", name = "Focuscraft", description = "Crafting resonant crystal foci that amplify other magic." },
						},
					},
				},
			},
			{
				id = "seismic",
				name = "Seismic Arts",
				description = "Tremors and the stresses inside the ground.",
				properties = { "seismicity" },
				children = {
					{
						id = "faultwork",
						name = "Faultwork",
						description = "Finding, loading and releasing faults.",
						children = {
							{ id = "cataclysm", name = "Cataclysm", description = "True earthquakes. Cities fall.", maxPower = 10, tags = { "worldAltering" } },
						},
					},
					{ id = "tremorsense", name = "Tremorsense", description = "Feeling footsteps, tunnels and buried things through the ground." },
				},
			},
			{
				id = "sandshaping",
				name = "Sandshaping",
				description = "Loose earth: sand, gravel, dust and erosion.",
				properties = { "cohesion" },
				children = {
					{ id = "dunecalling", name = "Dunecalling", description = "Moving dunes and swallowing ground." },
				},
			},
		},
	},

	-- ─── WATER ──────────────────────────────────────────────────────────────
	water = {
		id = "water",
		name = "Raw Water",
		description = "Drawing moisture, warming or chilling a cup, nudging a stream.",
		properties = { "humidity", "flow", "temperature" },
		children = {
			{
				id = "hydromancy",
				name = "Hydromancy",
				description = "Command of bodies of water.",
				properties = { "pressure", "viscosity" },
				children = {
					{
						id = "tidal",
						name = "Tidal Arts",
						description = "Waves, currents and tides.",
						properties = { "buoyancy" },
						children = {
							{ id = "tsunamancy", name = "Tsunamancy", description = "Raising the sea against the land.", maxPower = 10, tags = { "worldAltering" } },
						},
					},
					{
						id = "glaciation",
						name = "Glaciation",
						description = "Ice: freezing, shaping, shattering.",
						properties = { "phase" },
						children = {
							{ id = "permafrost", name = "Permafrost", description = "Glaciers on demand; locking a valley in ice." },
						},
					},
					{
						id = "vapor",
						name = "Vaporism",
						description = "Steam, mist and clouds.",
						properties = { "phase" },
						children = {
							{ id = "fogweaving", name = "Fogweaving", description = "Fog banks that blind, chill or scald." },
						},
					},
					{ id = "hydrostatics", name = "Hydrostatics", description = "Pressure: water jets, crushing depth, cutting streams." },
				},
			},
			{
				id = "purification",
				name = "Purification",
				description = "Cleansing and desalinating water.",
				properties = { "purity" },
				children = {
					{ id = "wellspring", name = "Wellspring", description = "Finding and calling up hidden water." },
				},
			},
		},
	},

	-- ─── AIR ────────────────────────────────────────────────────────────────
	air = {
		id = "air",
		name = "Raw Air",
		description = "Breezes, whispers carried, a door slammed by wind.",
		properties = { "flow", "pressure", "sound" },
		children = {
			{
				id = "aeromancy",
				name = "Aeromancy",
				description = "Wind and air pressure.",
				properties = { "buoyancy" },
				children = {
					{
						id = "windshaping",
						name = "Windshaping",
						description = "Gusts, updrafts, gliding and wind blades.",
						children = {
							{ id = "tempest", name = "Tempest", description = "Hurricanes and tornadoes.", maxPower = 10, tags = { "worldAltering" } },
						},
					},
					{ id = "vacuity", name = "Vacuity", description = "Removing air: vacuums, suffocation, silence of airlessness.", properties = { "breath" } },
				},
			},
			{
				id = "sonics",
				name = "Sonic Arts",
				description = "Sound as tool and weapon.",
				children = {
					{ id = "echolocation", name = "Echolocation", description = "Seeing by sound." },
					{ id = "thunderclap", name = "Thunderclap", description = "Concussive booms that stun and shatter glass." },
				},
			},
			{
				id = "weathercraft",
				name = "Weathercraft",
				description = "Local weather: rain, heat, cold, static.",
				properties = { "humidity", "temperature", "charge" },
				children = {
					{ id = "rainmaking", name = "Rainmaking", description = "Calling and dismissing rain." },
					{ id = "stormbrewing", name = "Stormbrewing", description = "Building storm cells over hours." },
				},
			},
		},
	},

	-- ─── LIFE ───────────────────────────────────────────────────────────────
	life = {
		id = "life",
		name = "Raw Life",
		description = "Closing small cuts, coaxing a seed to sprout.",
		properties = { "vitality", "growth" },
		children = {
			{
				id = "restoration",
				name = "Restoration",
				description = "Healing the body.",
				properties = { "metabolism" },
				children = {
					{
						id = "mending",
						name = "Mending",
						description = "Bones, organs, lost blood.",
						children = {
							{ id = "resurgence", name = "Resurgence", description = "Pulling the dying back from the edge." },
						},
					},
					{ id = "purgation", name = "Purgation", description = "Drawing out poison and disease.", properties = { "toxin" } },
				},
			},
			{
				id = "flora",
				name = "Floramancy",
				description = "Plant growth and form.",
				children = {
					{ id = "arborism", name = "Arborism", description = "Trees: growing, walking, shaping living wood." },
					{ id = "mycology", name = "Mycology", description = "Fungi, rot and the networks beneath forests.", properties = { "decay" } },
				},
			},
			{
				id = "fauna",
				name = "Faunacraft",
				description = "Beasts and their instincts.",
				properties = { "instinct" },
				children = {
					{ id = "beastspeech", name = "Beastspeech", description = "Understanding and calming animals." },
					{ id = "wildshape", name = "Wildshape", description = "Taking on animal traits or forms.", properties = { "metabolism" }, maxPower = 8 },
				},
			},
			{
				id = "blight",
				name = "Blight",
				description = "Decay and disease.",
				properties = { "decay", "toxin" },
				children = {
					{
						id = "pestilence",
						name = "Pestilence",
						description = "Spreading sickness.",
						children = {
							{ id = "greatplague", name = "Great Plague", description = "Disease that sweeps regions.", maxPower = 10, tags = { "worldAltering", "forbidden" } },
						},
					},
					{ id = "withering", name = "Withering", description = "Draining the life out of a body or a field." },
				},
			},
		},
	},

	-- ─── MIND ───────────────────────────────────────────────────────────────
	mind = {
		id = "mind",
		name = "Raw Mind",
		description = "Noticing more than others; calming a frightened horse.",
		properties = { "perception", "emotion" },
		children = {
			{
				id = "perceptics",
				name = "Perceptics",
				description = "Sharpening and extending the senses.",
				children = {
					{ id = "farsight", name = "Farsight", description = "Seeing far-off places." },
					{ id = "insight", name = "Insight", description = "Reading intentions and surface thoughts.", properties = { "thought" } },
				},
			},
			{
				id = "empathy",
				name = "Empathy",
				description = "Reading and nudging emotion.",
				children = {
					{ id = "charm", name = "Charm", description = "Warmth, trust, affection." },
					{ id = "dread", name = "Dread", description = "Fear, despair, panic." },
				},
			},
			{
				id = "illusion",
				name = "Illusion",
				description = "False sensations.",
				properties = { "illusion" },
				children = {
					{
						id = "phantasm",
						name = "Phantasms",
						description = "Convincing illusory objects and creatures.",
						children = {
							{ id = "grandillusion", name = "Grand Illusion", description = "Whole districts that aren't there.", maxPower = 10, tags = { "worldAltering" } },
						},
					},
					{ id = "veiling", name = "Veiling", description = "Making minds fail to notice something." },
				},
			},
			{
				id = "mnemonics",
				name = "Mnemonics",
				description = "Memory: recall, sharing, editing.",
				properties = { "memory" },
				children = {
					{ id = "oblivion", name = "Oblivion", description = "Erasing memory.", tags = { "forbidden" } },
				},
			},
			{
				id = "telepathy",
				name = "Telepathy",
				description = "Mind-to-mind speech.",
				properties = { "thought" },
				children = {
					{ id = "dominion", name = "Dominion", description = "Overriding another's will.", properties = { "will" }, tags = { "forbidden" } },
				},
			},
		},
	},

	-- ─── SPIRIT ─────────────────────────────────────────────────────────────
	spirit = {
		id = "spirit",
		name = "Raw Spirit",
		description = "Sensing spirits; a ward against bad dreams.",
		properties = { "essence", "warding" },
		children = {
			{
				id = "warding",
				name = "Warding",
				description = "Seals and protections.",
				children = {
					{
						id = "sanctum",
						name = "Sanctums",
						description = "Large, lasting wards on places.",
						children = {
							{ id = "hallowing", name = "Hallowing", description = "Consecrating whole regions.", maxPower = 10, tags = { "worldAltering" } },
						},
					},
					{ id = "counterwarding", name = "Counterwarding", description = "Breaking others' wards." },
				},
			},
			{
				id = "hexcraft",
				name = "Hexcraft",
				description = "Curses and ill-luck.",
				properties = { "malediction" },
				children = {
					{ id = "greatercurses", name = "Greater Curses", description = "Generational and bloodline curses.", tags = { "forbidden" } },
				},
			},
			{
				id = "binding",
				name = "Binding",
				description = "Tying beings and things together.",
				properties = { "bond" },
				children = {
					{ id = "pactcraft", name = "Pactcraft", description = "Magically enforced oaths and contracts.", properties = { "will" } },
					{ id = "soulbinding", name = "Soulbinding", description = "Binding souls to objects or places.", properties = { "soul" } },
				},
			},
			{
				id = "necrourgy",
				name = "Necrourgy",
				description = "Dealing with the dead.",
				properties = { "unlife", "soul" },
				children = {
					{ id = "deathspeech", name = "Deathspeech", description = "Speaking with the departed." },
					{ id = "revenancy", name = "Revenancy", description = "Giving the dead a brief second motion." },
				},
			},
		},
	},

	-- ─── VOID ───────────────────────────────────────────────────────────────
	void = {
		id = "void",
		name = "Raw Void",
		description = "Muffling, dimming, making a spark fizzle.",
		properties = { "aether", "presence" },
		children = {
			{
				id = "negation",
				name = "Negation",
				description = "Cancelling active magic.",
				children = {
					{
						id = "dispelling",
						name = "Dispelling",
						description = "Unweaving spells and enchantments.",
						children = {
							{ id = "antimagic", name = "Antimagic", description = "Fields where no magic works at all.", maxPower = 10, tags = { "worldAltering" } },
						},
					},
				},
			},
			{
				id = "dampening",
				name = "Dampening",
				description = "Suppressing physical energies.",
				properties = { "momentum", "sound", "luminosity", "temperature", "charge" },
				children = {
					{ id = "silence", name = "Silence", description = "Zones of no sound." },
					{ id = "eclipse", name = "Eclipse", description = "Swallowing light." },
					{ id = "stillness", name = "Stillness", description = "Draining motion and heat." },
				},
			},
			{
				id = "absorption",
				name = "Absorption",
				description = "Drinking in energy and essence.",
				properties = { "essence" },
				children = {
					{ id = "siphoning", name = "Siphoning", description = "Stealing reservoirs and life-force." },
				},
			},
			{
				id = "obscurance",
				name = "Obscurance",
				description = "Hiding from magical senses.",
				children = {
					{ id = "nullsign", name = "Nullsign", description = "Erasing all magical trace of an act." },
				},
			},
		},
	},

	-- ─── SPACE ──────────────────────────────────────────────────────────────
	space = {
		id = "space",
		name = "Raw Space",
		description = "Knowing exactly how far things are; a nudge of reach.",
		properties = { "distance", "presence" },
		children = {
			{
				id = "translocation",
				name = "Translocation",
				description = "Moving things without crossing the space between.",
				properties = { "position" },
				children = {
					{ id = "blinking", name = "Blinking", description = "Short line-of-sight teleports." },
					{
						id = "gatecraft",
						name = "Gatecraft",
						description = "Portals.",
						properties = { "boundary" },
						children = {
							{ id = "worldgates", name = "Worldgates", description = "Permanent gates across the world.", maxPower = 10, tags = { "worldAltering" } },
						},
					},
				},
			},
			{
				id = "folding",
				name = "Folding",
				description = "Shortening or lengthening space.",
				properties = { "volume" },
				children = {
					{ id = "pocketcraft", name = "Pocketcraft", description = "Bags larger inside than out; hidden rooms." },
				},
			},
			{
				id = "containment",
				name = "Containment",
				description = "Sealing regions of space.",
				properties = { "boundary", "volume" },
				children = {
					{ id = "sealing", name = "Sealing", description = "Prisons with no doors." },
				},
			},
			{
				id = "spatialsense",
				name = "Spatial Sense",
				description = "Perceiving space itself.",
				properties = { "orientation" },
				children = {
					{ id = "clairsentience", name = "Clairsentience", description = "Being aware of everything in a region at once." },
				},
			},
		},
	},

	-- ─── TIME (mythic) ──────────────────────────────────────────────────────
	time = {
		id = "time",
		name = "Raw Time",
		description = "A moment that feels longer than it should.",
		properties = { "tempo" },
		children = {
			{
				id = "chronokinesis",
				name = "Chronokinesis",
				description = "Local tempo.",
				children = {
					{ id = "hastening", name = "Hastening", description = "Speeding a body's time." },
					{ id = "stasis", name = "Stasis", description = "Freezing a thing in time.", properties = { "persistence" } },
				},
			},
			{
				id = "aeonics",
				name = "Aeonics",
				description = "Age and wear.",
				properties = { "age", "decay" },
				children = {
					{ id = "rejuvenation", name = "Rejuvenation", description = "Turning back an object's or body's age." },
				},
			},
			{
				id = "causality",
				name = "Causality",
				description = "Cause and effect.",
				properties = { "sequence", "foresight" },
				children = {
					{ id = "precognition", name = "Precognition", description = "Seeing seconds ahead." },
					{
						id = "rewind",
						name = "Rewind",
						description = "Undoing the last few seconds locally.",
						children = {
							{ id = "unhappening", name = "Unhappening", description = "Making an event never have occurred.", maxPower = 10, tags = { "worldAltering", "forbidden" } },
						},
					},
				},
			},
		},
	},

	-- ─── GRAVITY (mythic) ───────────────────────────────────────────────────
	gravity = {
		id = "gravity",
		name = "Raw Gravity",
		description = "A lighter step; a heavier blow.",
		properties = { "weight" },
		children = {
			{
				id = "weightcraft",
				name = "Weightcraft",
				description = "Changing how heavy things are.",
				properties = { "buoyancy", "density" },
				children = {
					{ id = "levitation", name = "Levitation", description = "Floating and flight." },
					{ id = "crushing", name = "Crushing", description = "Pinning and compressing." },
				},
			},
			{
				id = "vectoring",
				name = "Vectoring",
				description = "Changing which way is down.",
				properties = { "orientation", "momentum" },
				children = {
					{ id = "inversion", name = "Inversion", description = "Walking on walls; dropping enemies into the sky." },
				},
			},
			{
				id = "attraction",
				name = "Attraction",
				description = "Pulling things together.",
				properties = { "cohesion" },
				children = {
					{
						id = "orbitcraft",
						name = "Orbitcraft",
						description = "Debris that circles the caster.",
						children = {
							{ id = "collapse", name = "Collapse", description = "Gravity wells that fold a landscape inward.", maxPower = 10, tags = { "worldAltering" } },
						},
					},
				},
			},
		},
	},

	-- ─── REALITY (mythic) ───────────────────────────────────────────────────
	reality = {
		id = "reality",
		name = "Raw Reality",
		description = "Luck that is a little too good.",
		properties = { "probability" },
		children = {
			{
				id = "fortune",
				name = "Fortune",
				description = "Bending odds.",
				children = {
					{ id = "fatebending", name = "Fatebending", description = "Forcing a specific outcome." },
				},
			},
			{
				id = "substantiation",
				name = "Substantiation",
				description = "Existence and non-existence.",
				properties = { "substance", "persistence" },
				children = {
					{ id = "conjuration", name = "Conjuration", description = "Matter from nothing." },
					{ id = "unmaking", name = "Unmaking", description = "Matter to nothing.", tags = { "forbidden" } },
				},
			},
			{
				id = "lawcraft",
				name = "Lawcraft",
				description = "Local rules of the world.",
				properties = { "law", "identity", "sequence" },
				children = {
					{ id = "polymorphy", name = "Polymorphy", description = "Changing what a thing is." },
					{
						id = "edict",
						name = "Edicts",
						description = "Small, temporary changes to local physics.",
						children = {
							{ id = "worldlaw", name = "Worldlaw", description = "Rewriting the rules of a region.", maxPower = 10, tags = { "worldAltering", "forbidden" } },
						},
					},
				},
			},
		},
	},
}

-- Cross-domain branches. Unlock when ALL listed domains are awakened and every prerequisite is met.
local hybrids: { Types.HybridNode } = {
	{
		id = "mudshaping",
		name = "Clayshaping",
		description = "Mud and clay: sucking ground, golem bodies, pottery by thought.",
		domains = { "earth", "water" },
		properties = { "viscosity", "cohesion", "contour" },
		prerequisites = { { branch = "geomancy", mastery = 40 }, { branch = "hydromancy", mastery = 40 } },
	},
	{
		id = "stormcalling",
		name = "Stormcalling",
		description = "Lightning drawn from the sky and thrown with intent.",
		domains = { "energy", "air" },
		properties = { "charge", "pressure" },
		prerequisites = { { branch = "electric", mastery = 40 }, { branch = "aeromancy", mastery = 40 } },
		children = {
			{ id = "skyfire", name = "Skyfire", description = "Lightning storms that walk across the land.", maxPower = 10, tags = { "worldAltering" } },
		},
	},
	{
		id = "verdancy",
		name = "Verdancy",
		description = "Forest magic: roots that move earth, groves raised in a day.",
		domains = { "life", "earth" },
		properties = { "growth", "contour" },
		prerequisites = { { branch = "flora", mastery = 40 }, { branch = "geomancy", mastery = 30 } },
		children = {
			{ id = "wildwood", name = "Wildwood", description = "Whole forests grown, moved or awakened.", maxPower = 10, tags = { "worldAltering" } },
		},
	},
	{
		id = "mindlink",
		name = "Mindlink",
		description = "Telepathic links across any distance.",
		domains = { "space", "mind" },
		properties = { "thought", "distance" },
		prerequisites = { { branch = "telepathy", mastery = 40 }, { branch = "translocation", mastery = 40 } },
	},
	{
		id = "magmacraft",
		name = "Magmacraft",
		description = "Molten rock.",
		domains = { "energy", "earth" },
		properties = { "temperature", "contour", "density" },
		prerequisites = { { branch = "thermal", mastery = 40 }, { branch = "geomancy", mastery = 40 } },
		children = {
			{ id = "volcanism", name = "Volcanism", description = "Calling up volcanoes.", maxPower = 10, tags = { "worldAltering" } },
		},
	},
	{
		id = "mistweaving",
		name = "Mistweaving",
		description = "Fog that carries illusions.",
		domains = { "water", "mind" },
		properties = { "humidity", "illusion" },
		prerequisites = { { branch = "vapor", mastery = 35 }, { branch = "illusion", mastery = 35 } },
	},
	{
		id = "necromancy",
		name = "Necromancy",
		description = "Raising and commanding the rotting dead.",
		domains = { "life", "spirit" },
		properties = { "unlife", "decay", "soul" },
		prerequisites = { { branch = "blight", mastery = 45 }, { branch = "necrourgy", mastery = 45 } },
		tags = { "forbidden" },
		children = {
			{ id = "lichcraft", name = "Lichcraft", description = "Binding one's own soul beyond death.", tags = { "forbidden" } },
		},
	},
	{
		id = "runesmithing",
		name = "Runesmithing",
		description = "Wards and bonds forged into metal.",
		domains = { "spirit", "earth" },
		properties = { "warding", "purity", "bond" },
		prerequisites = { { branch = "warding", mastery = 40 }, { branch = "metallurgy", mastery = 40 } },
	},
	{
		id = "nullwarding",
		name = "Nullwarding",
		description = "Wards made of negation: barriers magic cannot cross.",
		domains = { "void", "spirit" },
		properties = { "aether", "warding" },
		prerequisites = { { branch = "negation", mastery = 40 }, { branch = "warding", mastery = 40 } },
	},
	{
		id = "singularity",
		name = "Singularity",
		description = "Points that devour matter and magic alike.",
		domains = { "gravity", "void" },
		properties = { "weight", "aether", "density" },
		prerequisites = { { branch = "attraction", mastery = 50 }, { branch = "absorption", mastery = 50 } },
	},
}

return {
	roots = roots,
	hybrids = hybrids,
}
