--!strict
--[[
	Properties: WHAT a spell affects. Shared across domains; a Domain lists which ones it
	can touch and its Branches grant them progressively.

	costWeight : multiplier on cost (abstract/metaphysical things are expensive to touch)
	volatility : flat instability added to every spell using this property
	harmful    : can directly injure a living target
]]
local Types = require(script.Parent.Parent.Types)

local Properties: { [string]: Types.PropertyDef } = {
	-- Thermal
	temperature = { name = "Temperature", category = "Thermal", costWeight = 1.0, volatility = 0.06, harmful = true, description = "Heat content of matter, liquid or air." },
	combustion = { name = "Combustion", category = "Thermal", costWeight = 1.1, volatility = 0.10, harmful = true, description = "Readiness of matter to burn, and open flame itself." },

	-- Energetic
	luminosity = { name = "Luminosity", category = "Energetic", costWeight = 0.8, volatility = 0.03, harmful = true, description = "Visible light: glow, glare, focused beams." },
	shadow = { name = "Shadow", category = "Energetic", costWeight = 0.9, volatility = 0.03, harmful = false, description = "The absence or shaping of light: darkness, silhouettes, shade." },
	radiation = { name = "Radiation", category = "Energetic", costWeight = 1.5, volatility = 0.12, harmful = true, description = "Invisible, penetrating energy that sickens and burns." },
	charge = { name = "Charge", category = "Energetic", costWeight = 1.2, volatility = 0.10, harmful = true, description = "Electric potential: sparks, currents, lightning." },

	-- Kinetic
	momentum = { name = "Momentum", category = "Kinetic", costWeight = 1.0, volatility = 0.06, harmful = true, description = "Mass in motion: pushes, impacts, deflections." },
	seismicity = { name = "Seismicity", category = "Kinetic", costWeight = 1.3, volatility = 0.09, harmful = true, description = "Stored stress in the ground: tremors, quakes, faults." },
	sound = { name = "Sound", category = "Kinetic", costWeight = 0.8, volatility = 0.03, harmful = true, description = "Vibration through air or matter." },
	resonance = { name = "Resonance", category = "Kinetic", costWeight = 1.1, volatility = 0.07, harmful = true, description = "Sympathetic vibration within crystals and structures; amplifies or shatters." },
	weight = { name = "Weight", category = "Kinetic", costWeight = 1.4, volatility = 0.08, harmful = true, description = "The pull of the world on a body." },

	-- Material
	hardness = { name = "Hardness", category = "Material", costWeight = 1.0, volatility = 0.03, harmful = false, description = "Resistance to cutting, crushing and wear." },
	density = { name = "Density", category = "Material", costWeight = 1.1, volatility = 0.04, harmful = false, description = "How tightly matter is packed." },
	cohesion = { name = "Cohesion", category = "Material", costWeight = 1.1, volatility = 0.05, harmful = true, description = "What holds a solid together; reduce it and things crumble." },
	contour = { name = "Contour", category = "Material", costWeight = 1.0, volatility = 0.04, harmful = false, description = "The shape and elevation of terrain and solid masses." },
	magnetism = { name = "Magnetism", category = "Material", costWeight = 1.2, volatility = 0.06, harmful = true, description = "Attraction and repulsion between metals." },
	purity = { name = "Purity", category = "Material", costWeight = 1.0, volatility = 0.03, harmful = false, description = "Composition: alloys, impurities, refinement, clean water." },

	-- Fluid
	humidity = { name = "Humidity", category = "Fluid", costWeight = 0.8, volatility = 0.02, harmful = false, description = "Water suspended in air." },
	viscosity = { name = "Viscosity", category = "Fluid", costWeight = 1.0, volatility = 0.04, harmful = false, description = "How thick or runny a fluid is." },
	pressure = { name = "Pressure", category = "Fluid", costWeight = 1.1, volatility = 0.07, harmful = true, description = "Force exerted by fluid or air: jets, crush depth, vacuum." },
	flow = { name = "Flow", category = "Fluid", costWeight = 1.0, volatility = 0.05, harmful = true, description = "Movement of fluid: currents, winds, waves." },
	phase = { name = "Phase", category = "Fluid", costWeight = 1.2, volatility = 0.08, harmful = true, description = "Solid / liquid / gas state: freezing, melting, boiling." },
	buoyancy = { name = "Buoyancy", category = "Fluid", costWeight = 1.1, volatility = 0.05, harmful = false, description = "Lift within a fluid or air." },
	breath = { name = "Breath", category = "Fluid", costWeight = 1.3, volatility = 0.06, harmful = true, description = "Breathable air available to a creature." },

	-- Vital
	vitality = { name = "Vitality", category = "Vital", costWeight = 1.2, volatility = 0.04, harmful = true, description = "Health and life-force of a living body." },
	growth = { name = "Growth", category = "Vital", costWeight = 1.0, volatility = 0.04, harmful = false, description = "The rate at which living things grow and spread." },
	decay = { name = "Decay", category = "Vital", costWeight = 1.2, volatility = 0.07, harmful = true, description = "Rot, entropy of living matter, withering." },
	toxin = { name = "Toxin", category = "Vital", costWeight = 1.2, volatility = 0.07, harmful = true, description = "Poisons and disease." },
	instinct = { name = "Instinct", category = "Vital", costWeight = 1.2, volatility = 0.05, harmful = false, description = "The drives of beasts: hunger, fear, territory." },
	metabolism = { name = "Metabolism", category = "Vital", costWeight = 1.3, volatility = 0.06, harmful = true, description = "A body's internal processes and its physical form." },

	-- Mental
	perception = { name = "Perception", category = "Mental", costWeight = 1.0, volatility = 0.03, harmful = false, description = "What a mind can notice." },
	emotion = { name = "Emotion", category = "Mental", costWeight = 1.2, volatility = 0.06, harmful = false, description = "Feelings: courage, fear, calm, love, rage." },
	memory = { name = "Memory", category = "Mental", costWeight = 1.6, volatility = 0.08, harmful = false, description = "What a mind has recorded." },
	illusion = { name = "Illusion", category = "Mental", costWeight = 1.1, volatility = 0.04, harmful = false, description = "False sensations imposed on perceivers." },
	thought = { name = "Thought", category = "Mental", costWeight = 1.4, volatility = 0.06, harmful = false, description = "Active reasoning and inner speech." },
	will = { name = "Will", category = "Mental", costWeight = 1.6, volatility = 0.09, harmful = false, description = "Self-determination; the ability to resist or command." },

	-- Spiritual
	soul = { name = "Soul", category = "Spiritual", costWeight = 1.8, volatility = 0.10, harmful = true, description = "The persistent self that outlives the body." },
	warding = { name = "Warding", category = "Spiritual", costWeight = 1.0, volatility = 0.03, harmful = false, description = "Protective seals against magic, spirits and intrusion." },
	malediction = { name = "Malediction", category = "Spiritual", costWeight = 1.3, volatility = 0.08, harmful = true, description = "Curses: lingering ill-fortune bound to a target." },
	bond = { name = "Bond", category = "Spiritual", costWeight = 1.3, volatility = 0.06, harmful = false, description = "Ties between beings or between a being and an object: pacts, oaths, familiars." },
	essence = { name = "Essence", category = "Spiritual", costWeight = 1.4, volatility = 0.07, harmful = true, description = "Spiritual energy carried by every living thing." },
	unlife = { name = "Unlife", category = "Spiritual", costWeight = 1.6, volatility = 0.10, harmful = true, description = "Animating force of the dead." },

	-- Arcane
	aether = { name = "Aether", category = "Arcane", costWeight = 1.3, volatility = 0.06, harmful = false, description = "Magic itself: active spells, reservoirs, ambient density." },
	presence = { name = "Presence", category = "Arcane", costWeight = 1.1, volatility = 0.04, harmful = false, description = "How detectable a thing is to magical senses." },

	-- Spatial
	distance = { name = "Distance", category = "Spatial", costWeight = 1.5, volatility = 0.09, harmful = false, description = "The span between two points." },
	position = { name = "Position", category = "Spatial", costWeight = 1.6, volatility = 0.10, harmful = false, description = "Where a thing is." },
	volume = { name = "Volume", category = "Spatial", costWeight = 1.5, volatility = 0.08, harmful = false, description = "How much space a region contains." },
	boundary = { name = "Boundary", category = "Spatial", costWeight = 1.3, volatility = 0.06, harmful = false, description = "Edges between regions: seals, thresholds, cages." },
	orientation = { name = "Orientation", category = "Spatial", costWeight = 1.5, volatility = 0.09, harmful = true, description = "Which way is which, including which way is down." },

	-- Temporal
	tempo = { name = "Tempo", category = "Temporal", costWeight = 2.0, volatility = 0.12, harmful = false, description = "How fast time passes locally." },
	age = { name = "Age", category = "Temporal", costWeight = 1.9, volatility = 0.11, harmful = true, description = "How much time has acted on a thing." },
	persistence = { name = "Persistence", category = "Temporal", costWeight = 1.8, volatility = 0.10, harmful = false, description = "Resistance to change over time." },
	sequence = { name = "Sequence", category = "Temporal", costWeight = 2.4, volatility = 0.15, harmful = false, description = "The order of cause and effect." },
	foresight = { name = "Foresight", category = "Temporal", costWeight = 1.8, volatility = 0.08, harmful = false, description = "Glimpses of what is about to happen." },

	-- Metaphysical
	probability = { name = "Probability", category = "Metaphysical", costWeight = 2.2, volatility = 0.14, harmful = false, description = "The odds of outcomes." },
	substance = { name = "Substance", category = "Metaphysical", costWeight = 2.5, volatility = 0.15, harmful = true, description = "Whether something exists at all." },
	law = { name = "Law", category = "Metaphysical", costWeight = 3.0, volatility = 0.18, harmful = false, description = "Local rules of physics and magic." },
	identity = { name = "Identity", category = "Metaphysical", costWeight = 2.6, volatility = 0.16, harmful = true, description = "What a thing fundamentally is." },
}

return Properties
