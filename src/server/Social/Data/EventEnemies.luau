--!strict
--[[
	EventEnemies: the bodies and attacks of shared-event enemies (docs/Social.md "Shared events").
	Each `def` is a Creatures.Def, so Creatures/CreatureRig builds it like any creature: spells, statuses
	and lock-on work with no special code, and hitting one is never a crime (Cast/Damage reads the
	Creature attribute). They aren't in Creatures.defs, so they never appear in dens.

		health    the base for one player; EventRules.healthFor scales it with the zone
		attack    a telegraphed area hit: { radius, damage, delay (seconds of warning), cooldown, style }
		          style is how the client draws the landing: "slam" | "bolt" | "pulse"
		static    anchored in place (nodes, shards)

	Tuning status: first guesses, not yet played.
]]

local Server = script.Parent.Parent.Parent
local Creatures = require(Server.Creatures.Data.Creatures)

local rgb = Color3.fromRGB
local M = Enum.Material

export type Attack = { radius: number, damage: number, delay: number, cooldown: number, style: string }
export type Enemy = { def: Creatures.Def, attack: Attack?, static: boolean }

local function def(fields: {
	id: string,
	name: string,
	domain: string,
	level: number,
	health: number,
	walk: number,
	hipHeight: number,
	hitbox: Vector3,
	bite: { damage: number, cooldown: number, reach: number, property: string }?,
	resist: { [string]: number },
	body: { Creatures.Part },
	emit: { color: Color3, rate: number }?,
}): Creatures.Def
	return {
		id = fields.id,
		name = fields.name,
		description = "",
		domain = fields.domain,
		level = fields.level,
		health = fields.health,
		walk = fields.walk,
		hipHeight = fields.hipHeight,
		hitbox = fields.hitbox,
		behaviour = "swarm", -- unused: SharedEventService moves these itself
		leash = 0,
		bite = fields.bite,
		pack = { min = 1, max = 1 },
		respawn = { min = 0, max = 0 },
		resist = fields.resist,
		biomes = {},
		xp = 0, -- rewards come from the event's contribution tiers, not per kill
		loot = {},
		body = fields.body,
		emit = fields.emit,
		nestColor = rgb(0, 0, 0),
	}
end

local function elemental(domain: string, name: string, color: Color3, glow: Color3, material: Enum.Material, resist: { [string]: number }, property: string): Enemy
	return {
		static = false,
		attack = { radius = 14, damage = 22, delay = 2.2, cooldown = 7, style = "slam" },
		def = def({
			id = "event_elemental_" .. domain,
			name = name,
			domain = domain,
			level = 5,
			health = 1200,
			walk = 11,
			hipHeight = 4,
			hitbox = Vector3.new(6, 9, 6),
			bite = { damage = 12, cooldown = 2.5, reach = 9, property = property },
			resist = resist,
			body = {
				{ name = "Head", shape = "Ball", size = Vector3.new(3.4, 3.4, 3.4), offset = Vector3.new(0, 4.2, 0), color = glow, material = M.Neon },
				{ name = "Body", shape = "Ball", size = Vector3.new(6, 6.6, 6), offset = Vector3.zero, color = color, material = material },
				{ name = "Base", shape = "Ball", size = Vector3.new(4, 3, 4), offset = Vector3.new(0, -4.2, 0), color = color, material = material, transparency = 0.25 },
			},
			emit = { color = glow, rate = 12 },
		}),
	}
end

local EventEnemies = {
	-- One is chosen by the plan's seeded `variant`. Each is weak to something, as creatures are.
	elementals = {
		elemental("energy", "Cinder Elemental", rgb(120, 50, 30), rgb(255, 150, 60), M.Basalt, { energy = 0.6, water = -0.3 }, "temperature"),
		elemental("water", "Tide Elemental", rgb(40, 90, 150), rgb(120, 210, 255), M.Glass, { water = 0.6, energy = -0.3 }, "momentum"),
		elemental("earth", "Stone Elemental", rgb(90, 80, 70), rgb(210, 180, 120), M.Slate, { earth = 0.6, air = -0.3 }, "momentum"),
		elemental("air", "Gale Elemental", rgb(170, 190, 200), rgb(235, 250, 255), M.SmoothPlastic, { air = 0.6, earth = -0.3 }, "momentum"),
	} :: { Enemy },

	node = {
		static = true,
		attack = { radius = 9, damage = 14, delay = 1.6, cooldown = 6, style = "bolt" },
		def = def({
			id = "event_storm_node",
			name = "Static Node",
			domain = "energy",
			level = 4,
			health = 350,
			walk = 0,
			hipHeight = 5,
			hitbox = Vector3.new(5, 7, 5),
			resist = { energy = 0.6, earth = -0.3 },
			body = {
				{ name = "Head", shape = "Ball", size = Vector3.new(2.4, 2.4, 2.4), offset = Vector3.new(0, 2.4, 0), color = rgb(230, 240, 255), material = M.Neon },
				{ name = "Body", shape = "Block", size = Vector3.new(2.2, 5, 2.2), offset = Vector3.new(0, -0.8, 0), color = rgb(70, 80, 120), material = M.Metal },
			},
			emit = { color = rgb(170, 200, 255), rate = 10 },
		}),
	} :: Enemy,

	raider = {
		static = false,
		def = def({
			id = "event_raider",
			name = "Hollow Raider",
			domain = "void",
			level = 3,
			health = 70,
			walk = 13,
			hipHeight = 1.6,
			hitbox = Vector3.new(2.6, 5, 2.6),
			bite = { damage = 7, cooldown = 2, reach = 6, property = "momentum" },
			resist = { void = 0.4, energy = -0.2 },
			body = {
				{ name = "Head", shape = "Ball", size = Vector3.new(1.6, 1.8, 1.6), offset = Vector3.new(0, 1.9, 0), color = rgb(30, 25, 40), material = M.SmoothPlastic },
				{ name = "Body", shape = "Block", size = Vector3.new(2.2, 3.4, 1.4), offset = Vector3.new(0, 0, 0), color = rgb(45, 35, 60), material = M.Fabric },
				{ name = "Eyes", shape = "Block", size = Vector3.new(1, 0.2, 0.2), offset = Vector3.new(0, 2, -0.75), color = rgb(190, 120, 255), material = M.Neon },
			},
		}),
	} :: Enemy,
	raiderAggro = 22, -- studs: a raider turns on a player this close, else keeps marching
	siege = {
		waves = { 6, 8, 10 },
		extraPerPlayers = 3, -- one more raider per wave per this many players in the zone
		maxExtra = 4,
		waveGap = 60, -- seconds until the next wave even if this one is still alive
		spawnDistance = 85, -- studs from the plaza
		plazaRadius = 14, -- a raider this close has got through
		breachLimit = 6, -- this many through and the siege is lost
	},

	shard = {
		static = true,
		attack = { radius = 10, damage = 12, delay = 1.6, cooldown = 8, style = "pulse" },
		def = def({
			id = "event_comet_shard",
			name = "Comet Shard",
			domain = "energy",
			level = 3,
			health = 140,
			walk = 0,
			hipHeight = 1.5,
			hitbox = Vector3.new(4, 5, 4),
			resist = { energy = 0.4, water = -0.3 },
			body = {
				{ name = "Head", shape = "Block", size = Vector3.new(1.6, 2.6, 1.6), offset = Vector3.new(0, 1.2, 0), color = rgb(190, 225, 255), material = M.Neon },
				{ name = "Body", shape = "Block", size = Vector3.new(3, 3, 3), offset = Vector3.new(0, -0.8, 0), color = rgb(60, 55, 75), material = M.Basalt },
			},
			emit = { color = rgb(170, 215, 255), rate = 6 },
		}),
	} :: Enemy,
	comet = {
		shards = 8,
		fallSeconds = 3, -- the warning before it lands
		impactRadius = 24,
		impactDamage = 25,
	},

	nodes = 3,
	ringRadius = 34, -- studs from the centre for nodes and shards
	pulseRange = 16, -- a shard only pulses with a player this close
}

return EventEnemies
