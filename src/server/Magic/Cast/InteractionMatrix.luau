--!strict
--[[
	InteractionMatrix: emergent results when magic meets magic.

	Every cast leaves a PRESENCE where it lands: a few elemental tags derived from the recipe
	(tagsFor), a radius, a power and an owner, lasting presenceSeconds (or as long as its
	durational effect lives). When a new presence overlaps an existing one, from any caster
	(yourself included), the REACTIONS table is checked for each pair of tags. A reaction fires
	at most once per reactionCooldown in the same 16-stud cell, and at most 3 fire per presence.

	So a water mage drenching a burning house puts it out; a storm caller striking the river the
	water mage is standing in electrocutes everyone in it; an earth mage raising stone inside a
	gravity well gets a crushing collapse. None of that is scripted per spell pair.

	Handlers get `env` from EffectRunner (fire, thermal, status, damage, terrain, cue, dispel...).
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local Types = require(Shared.Magic.Types)
local T = require(script.Parent.Parent.Data.CastTuning)

export type Presence = {
	id: number,
	tags: { string },
	position: Vector3,
	radius: number,
	power: number,
	owner: number?,
	expires: number,
	effectId: number?, -- the durational effect it belongs to, if any (dispel/cancel stop it)
}

export type Reaction = {
	a: string,
	b: string, -- "*" = any tag
	result: string,
	description: string,
}

-- ─── Tags ───────────────────────────────────────────────────────────────────

local PROPERTY_TAGS: { [string]: { string } } = {
	temperature = { "heat" },
	combustion = { "fire", "heat" },
	luminosity = { "light" },
	shadow = { "dark" },
	radiation = { "heat" },
	charge = { "lightning" },
	momentum = { "force" },
	seismicity = { "stone" },
	contour = { "stone" },
	cohesion = { "stone" },
	hardness = { "stone" },
	density = { "stone" },
	magnetism = { "metal" },
	purity = { "metal" },
	humidity = { "water" },
	viscosity = { "water" },
	buoyancy = { "water" },
	phase = { "water" },
	vitality = { "life" },
	growth = { "life" },
	metabolism = { "life" },
	decay = { "rot" },
	toxin = { "rot" },
	weight = { "gravity" },
	tempo = { "time" },
	persistence = { "time" },
	aether = { "null" },
	essence = { "spirit" },
	warding = { "spirit" },
	soul = { "spirit" },
	unlife = { "rot", "spirit" },
	probability = { "reality" },
	law = { "reality" },
	substance = { "reality" },
	identity = { "reality" },
}

-- Reduce flips some tags (draining heat is cold, draining light is dark).
local REDUCE_FLIPS: { [string]: string } = { heat = "cold", light = "dark", water = "dry" }

local function tagsFor(stats: Types.SpellStats): { string }
	local recipe = stats.recipe
	local tags: { string } = {}
	local function add(tag: string)
		if not table.find(tags, tag) then
			table.insert(tags, tag)
		end
	end
	for _, tag in (PROPERTY_TAGS[recipe.property] or {}) :: { string } do
		add(if recipe.verb == "reduce" and REDUCE_FLIPS[tag] then REDUCE_FLIPS[tag] else tag)
	end
	-- Flow and pressure are water in water magic and wind in air magic.
	if recipe.property == "flow" or recipe.property == "pressure" then
		add(if table.find(stats.domains, "air") then "wind" else "water")
	end
	if recipe.property == "phase" and recipe.verb == "reduce" then
		add("ice")
	end
	if recipe.property == "orientation" and table.find(stats.domains, "gravity") then
		add("gravity")
	end
	if #tags == 0 then
		add(stats.domains[1]) -- every spell is at least its domain
	end
	return tags
end

-- ─── Reactions ──────────────────────────────────────────────────────────────

local REACTIONS: { Reaction } = {
	{ a = "null", b = "*", result = "dispel", description = "Void magic unmakes the other working." },
	{ a = "water", b = "fire", result = "extinguish", description = "Water puts the fire out in a burst of steam." },
	{ a = "water", b = "heat", result = "steam", description = "Scalding steam: burns, and blinds the area briefly." },
	{ a = "water", b = "cold", result = "freeze", description = "The water freezes; swimmers are caught in the ice." },
	{ a = "water", b = "lightning", result = "conduction", description = "Lightning runs through the water into everyone in it." },
	{ a = "metal", b = "lightning", result = "conduction", description = "Lightning leaps along metal into whoever is near it." },
	{ a = "ice", b = "heat", result = "melt", description = "Magic ice melts back to water." },
	{ a = "ice", b = "fire", result = "melt", description = "Magic ice melts back to water." },
	{ a = "stone", b = "gravity", result = "crush", description = "Stone under multiplied weight collapses on what's beneath." },
	{ a = "wind", b = "fire", result = "firestorm", description = "Wind feeds the fire: it roars and spreads far faster." },
	{ a = "life", b = "fire", result = "wildfire", description = "Fresh growth catches: the fire leaps across it." },
	{ a = "rot", b = "fire", result = "toxic_smoke", description = "Burning rot gives off poisonous smoke." },
	{ a = "cold", b = "wind", result = "blizzard", description = "Freezing wind: everyone in it slows and chills." },
	{ a = "light", b = "dark", result = "cancel", description = "Light and darkness cancel each other out." },
	{ a = "life", b = "rot", result = "cancel", description = "Growth and decay cancel each other out." },
	{ a = "time", b = "gravity", result = "shear", description = "Bent time and bent weight tear at bodies caught in both." },
}

local InteractionMatrix = {}
InteractionMatrix.reactions = REACTIONS
InteractionMatrix.tagsFor = tagsFor

-- Every reaction a pair of presences triggers (each listed once).
function InteractionMatrix.match(a: Presence, b: Presence): { Reaction }
	local out: { Reaction } = {}
	for _, r in REACTIONS do
		local forward = table.find(a.tags, r.a) and (r.b == "*" or table.find(b.tags, r.b))
		local backward = table.find(b.tags, r.a) and (r.b == "*" or table.find(a.tags, r.b))
		if forward or backward then
			table.insert(out, r)
		end
	end
	return out
end

-- ─── Handlers ───────────────────────────────────────────────────────────────

export type Env = {
	fire: any, -- FireSim
	thermal: any, -- ThermalSim
	status: any, -- StatusEffects
	damage: any, -- Damage
	terrain: any, -- TerrainDeform
	world: any, -- WorldStateService
	targets: (position: Vector3, radius: number) -> { any }, -- Targeting.inRadius wrapper
	cue: (kind: string, payload: { [string]: any }, position: Vector3, heavy: boolean) -> (),
	stopEffect: (effectId: number) -> (),
	dispelArea: (position: Vector3, radius: number, owner: number?) -> number,
}

local function strength(power: number): number
	return T.damage.perPower * math.max(0, power) ^ T.damage.exponent
end

local HANDLERS: { [string]: (env: Env, a: Presence, b: Presence, at: Vector3, radius: number) -> () } = {
	dispel = function(env, a, b, at, radius)
		-- The null presence survives; the other one (and its effect) is unmade.
		local other = if table.find(a.tags, "null") then b else a
		if other.effectId then
			env.stopEffect(other.effectId)
		end
		env.dispelArea(at, radius, nil)
	end,
	extinguish = function(env, _a, _b, at, radius)
		env.fire.extinguish(at, radius)
		env.cue("steam", { radius = radius }, at, false)
	end,
	steam = function(env, a, b, at, radius)
		env.fire.extinguish(at, radius)
		for _, hit in env.targets(at, radius) do
			env.status.apply(hit.humanoid, "burning", { duration = 2, magnitude = strength(math.min(a.power, b.power)) * 0.3 })
			env.status.apply(hit.humanoid, "blind", { duration = 3 })
		end
		env.cue("steam", { radius = radius }, at, false)
	end,
	freeze = function(env, _a, _b, at, radius)
		env.terrain.freeze(env.world, at, radius, 20)
		for _, hit in env.targets(at, radius) do
			if hit.humanoid:GetState() == Enum.HumanoidStateType.Swimming then
				env.status.apply(hit.humanoid, "root", { duration = 4 })
			end
		end
	end,
	conduction = function(env, a, b, at, radius)
		local charge = if table.find(a.tags, "lightning") then a else b
		local amount = strength(charge.power) * 0.8
		-- Everyone in the water, and everyone touching metal in the area, is shocked.
		for _, hit in env.targets(at, radius * 1.5) do
			local wet = hit.humanoid:GetState() == Enum.HumanoidStateType.Swimming
			local nearMetal = false
			if not wet then
				for _, part in env.thermal.partsNear(hit.root.Position, 4, 4) do
					if part.Material == Enum.Material.Metal or part.Material == Enum.Material.DiamondPlate or part.Material == Enum.Material.CorrodedMetal then
						nearMetal = true
						break
					end
				end
			end
			if wet or nearMetal then
				env.damage.apply(hit.humanoid, amount, charge.owner, "conduction")
			end
		end
		env.cue("conduction", { radius = radius * 1.5 }, at, false)
	end,
	melt = function(env, _a, _b, at, radius)
		env.terrain.meltAt(at, radius)
	end,
	crush = function(env, a, b, at, radius)
		local amount = strength(math.max(a.power, b.power)) * 0.6
		for _, hit in env.targets(at, radius) do
			env.damage.apply(hit.humanoid, amount, a.owner or b.owner, "crush")
			env.status.apply(hit.humanoid, "root", { duration = 2 })
		end
		env.world:damageStructures(at, radius, amount, "crush")
		env.cue("crush", { radius = radius }, at, false)
	end,
	firestorm = function(env, _a, _b, at, radius)
		env.fire.boost(at, radius * 3, 3, 15)
		env.fire.igniteGround(at, 1.5, nil)
		env.cue("firestorm", { radius = radius }, at, false)
	end,
	wildfire = function(env, _a, _b, at, radius)
		for i = 0, 5 do
			local angle = i * math.pi / 3
			env.fire.igniteGround(at + Vector3.new(math.cos(angle), 0, math.sin(angle)) * radius * 0.6, 1.2, nil)
		end
	end,
	toxic_smoke = function(env, a, b, at, radius)
		for _, hit in env.targets(at, radius * 1.5) do
			env.status.apply(hit.humanoid, "poison", { duration = 6, magnitude = strength(math.min(a.power, b.power)) * 0.15 })
		end
		env.cue("smoke", { radius = radius * 1.5 }, at, false)
	end,
	blizzard = function(env, _a, _b, at, radius)
		for _, hit in env.targets(at, radius * 1.5) do
			env.status.apply(hit.humanoid, "slow", { duration = 6 })
		end
		for _, part in env.thermal.partsNear(at, radius, 10) do
			env.thermal.addHeat(part, -400)
		end
		env.cue("blizzard", { radius = radius * 1.5 }, at, false)
	end,
	cancel = function(env, a, b, _at, _radius)
		for _, p in { a, b } do
			if p.effectId then
				env.stopEffect(p.effectId)
			end
		end
	end,
	shear = function(env, a, b, at, radius)
		local amount = strength(math.min(a.power, b.power)) * 0.5
		for _, hit in env.targets(at, radius) do
			env.damage.apply(hit.humanoid, amount, a.owner or b.owner, "shear")
		end
		env.cue("shear", { radius = radius }, at, false)
	end,
}

-- Runs a reaction's handler. Unknown results are ignored (data/handler mismatch logs in EffectRunner).
function InteractionMatrix.react(env: Env, reaction: Reaction, a: Presence, b: Presence): boolean
	local handler = HANDLERS[reaction.result]
	if not handler then
		return false
	end
	local at = (a.position + b.position) / 2
	local radius = math.max(4, math.min(a.radius, b.radius))
	handler(env, a, b, at, radius)
	return true
end

function InteractionMatrix.hasHandler(result: string): boolean
	return HANDLERS[result] ~= nil
end

-- Unused tag sanity: every reaction refers to tags something can produce (checked by Cast.spec).
function InteractionMatrix.producibleTags(): { [string]: boolean }
	local set: { [string]: boolean } = { wind = true, ice = true, gravity = true, cold = true, dark = true, dry = true }
	for _, tags in PROPERTY_TAGS do
		for _, tag in tags do
			set[tag] = true
		end
	end
	for id in Registry.domains do
		set[id] = true
	end
	return set
end

return InteractionMatrix
