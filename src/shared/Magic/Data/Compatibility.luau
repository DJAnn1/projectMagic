--!strict
--[[
	Compatibility
	The validity matrices of the spell grammar. A value of 0 means "invalid combination";
	any positive value is an efficiency multiplier that feeds power (directly) and cost
	(inversely, via Tuning.awkwardCostExponent). 1.0 = natural, <1 = awkward, >1 = excellent.

	Rows are arrays whose columns follow `categories` / `verbColumns`, so the tables read as
	a grid. The Registry checks every row has exactly the right number of columns.
]]

local Compatibility = {}

Compatibility.categories = {
	"Thermal",
	"Energetic",
	"Kinetic",
	"Material",
	"Fluid",
	"Vital",
	"Mental",
	"Spiritual",
	"Arcane",
	"Spatial",
	"Temporal",
	"Metaphysical",
}

-- Verb x Property-category
Compatibility.verbCategory = {
	--            Therm Enrg  Kine  Matr  Flui  Vital Ment  Spir  Arca  Spat  Temp  Meta
	generate  = { 1.15, 1.15, 1.00, 0.80, 0.90, 0.60, 0.80, 0.60, 0.50, 0.00, 0.00, 0.40 },
	amplify   = { 1.00, 1.00, 1.00, 1.00, 1.00, 1.10, 1.00, 1.00, 0.90, 0.90, 0.90, 0.80 },
	reduce    = { 1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.10, 1.00, 0.90, 0.80 },
	transfer  = { 1.15, 1.00, 1.10, 0.80, 1.00, 1.00, 0.90, 0.90, 1.00, 1.00, 0.70, 0.60 },
	redirect  = { 0.90, 1.10, 1.15, 0.60, 1.10, 0.60, 0.80, 0.70, 0.90, 1.00, 0.70, 0.60 },
	transmute = { 0.80, 0.80, 0.60, 1.15, 1.00, 0.90, 0.70, 0.80, 0.80, 0.60, 0.50, 1.00 },
	bind      = { 0.60, 0.70, 0.90, 0.90, 0.80, 0.90, 1.00, 1.15, 1.00, 1.10, 1.00, 0.90 },
	sense     = { 1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.10, 1.00, 1.15, 1.10, 1.00, 0.80 },
	store     = { 1.00, 1.10, 1.00, 0.00, 0.70, 0.80, 0.90, 1.00, 1.15, 0.70, 0.80, 0.00 },
	release   = { 1.00, 1.10, 1.10, 0.00, 0.80, 0.80, 0.80, 1.00, 1.10, 0.70, 0.80, 0.00 },
} :: { [string]: { number } }

-- Per-property exceptions to the Verb x Category grid: { [property] = { [verb] = efficiency } }.
-- Generate can't make Spatial or Temporal magic in general, but a pulse of runaway time
-- (tempo) or a sliver of opened space (distance) is how Time and Space strike (Data/Strikes).
-- Without these, Time and Space casters could only `sense` at Sensing.
Compatibility.propertyVerb = {
	tempo = { generate = 0.5 },
	distance = { generate = 0.5 },
} :: { [string]: { [string]: number } }

Compatibility.verbColumns = {
	"generate",
	"amplify",
	"reduce",
	"transfer",
	"redirect",
	"transmute",
	"bind",
	"sense",
	"store",
	"release",
}

-- Form x Verb
Compatibility.formVerb = {
	--             gen   amp   red   xfer  redir xmut  bind  sense store rel
	touch      = { 1.00, 1.00, 1.00, 1.10, 0.90, 1.10, 1.00, 1.00, 1.00, 1.00 },
	projectile = { 1.00, 0.90, 0.90, 0.00, 1.00, 0.80, 0.80, 0.00, 0.00, 1.10 },
	beam       = { 1.00, 1.00, 1.00, 1.00, 1.00, 0.90, 0.80, 1.10, 0.00, 1.00 },
	burst      = { 1.00, 1.00, 1.00, 0.00, 1.00, 0.80, 0.70, 1.00, 0.00, 1.10 },
	aura       = { 0.90, 1.10, 1.10, 1.00, 1.00, 0.80, 0.90, 1.00, 1.10, 0.90 },
	wall       = { 1.00, 0.90, 0.90, 0.00, 1.10, 0.90, 1.00, 0.80, 1.00, 0.00 },
	zone       = { 0.90, 1.00, 1.00, 0.90, 1.00, 0.80, 1.00, 1.00, 0.90, 0.90 },
	pillar     = { 1.10, 1.00, 0.90, 0.00, 1.00, 0.90, 0.90, 0.00, 0.00, 1.00 },
	chain      = { 1.00, 0.90, 0.90, 1.00, 1.00, 0.00, 1.00, 0.00, 0.00, 1.00 },
	summon     = { 1.00, 0.00, 0.00, 0.00, 0.00, 1.00, 1.00, 0.00, 0.00, 0.00 },
	ritual     = { 1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.00, 1.00 },
} :: { [string]: { number } }

-- Form x Property-category hard blocks (things that make no physical sense).
Compatibility.formCategoryBlocked = {
	summon = { "Spatial", "Temporal", "Arcane" }, -- you can't summon "a distance"
	pillar = { "Mental" },
	chain = { "Spatial", "Temporal" },
} :: { [string]: { string } }

return Compatibility
