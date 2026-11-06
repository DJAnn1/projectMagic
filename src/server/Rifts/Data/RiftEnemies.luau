--!strict
--[[
	RiftEnemies: the bodies and attacks of what lives in a Rift (docs/Rifts.md). Each `def` is a
	Creatures.Def, so CreatureRig builds it like any creature: spells, statuses and lock-on work with no
	special code, and hitting one is never a crime. They aren't in Creatures.defs, so they never appear
	in dens. Rewards come from the run's contribution tiers, so xp and loot are empty.

		health   the base for one player; EventRules.healthFor scales it with who's inside
		attack   a telegraphed area hit, as in Social/Data/EventEnemies
		static   anchored in place

	Tuning status: first guesses, not yet played. The boss is meant to last about 2 minutes solo at power 3.
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
		behaviour = "swarm", -- unused: RiftService moves these itself
		leash = 0,
		bite = fields.bite,
		pack = { min = 1, max = 1 },
		respawn = { min = 0, max = 0 },
		resist = fields.resist,
		biomes = {},
		xp = 0,
		loot = {},
		body = fields.body,
		emit = fields.emit,
		nestColor = rgb(0, 0, 0),
	}
end

local RiftEnemies = {
	riftling = {
		static = false,
		def = def({
			id = "rift_riftling",
			name = "Riftling",
			domain = "void",
			level = 3,
			health = 60,
			walk = 14,
			hipHeight = 1.4,
			hitbox = Vector3.new(2.4, 3.6, 2.4),
			bite = { damage = 7, cooldown = 1.8, reach = 6, property = "momentum" },
			resist = { void = 0.3 },
			body = {
				{ name = "Head", shape = "Ball", size = Vector3.new(1.6, 1.6, 1.6), offset = Vector3.new(0, 1.2, 0), color = rgb(200, 150, 255), material = M.Neon },
				{ name = "Body", shape = "Ball", size = Vector3.new(2.4, 2.6, 2.4), offset = Vector3.new(0, -0.4, 0), color = rgb(40, 30, 60), material = M.SmoothPlastic },
			},
			emit = { color = rgb(180, 130, 255), rate = 5 },
		}),
	} :: Enemy,

	eye = {
		static = true,
		attack = { radius = 8, damage = 13, delay = 1.5, cooldown = 5.5, style = "bolt" },
		def = def({
			id = "rift_eye",
			name = "Watching Eye",
			domain = "energy",
			level = 4,
			health = 260,
			walk = 0,
			hipHeight = 1,
			hitbox = Vector3.new(6, 6, 6),
			resist = {},
			body = {
				{ name = "Head", shape = "Ball", size = Vector3.new(6, 6, 6), offset = Vector3.zero, color = rgb(235, 230, 215), material = M.SmoothPlastic },
				{ name = "Iris", shape = "Ball", size = Vector3.new(2.6, 2.6, 1.2), offset = Vector3.new(0, 0, -2.6), color = rgb(190, 120, 255), material = M.Neon },
			},
			emit = { color = rgb(190, 150, 255), rate = 6 },
		}),
	} :: Enemy,

	warden = {
		static = false,
		attack = { radius = 13, damage = 22, delay = 2, cooldown = 6.5, style = "slam" },
		def = def({
			id = "rift_warden",
			name = "Rift Warden",
			domain = "void",
			level = 6,
			health = 1500,
			walk = 11,
			hipHeight = 4.5,
			hitbox = Vector3.new(7, 11, 7),
			bite = { damage = 14, cooldown = 2.4, reach = 10, property = "momentum" },
			resist = {}, -- RiftService adds this Rift's weakness
			body = {
				{ name = "Head", shape = "Ball", size = Vector3.new(4, 4, 4), offset = Vector3.new(0, 5, 0), color = rgb(225, 180, 255), material = M.Neon },
				{ name = "Body", shape = "Block", size = Vector3.new(7, 7, 4.5), offset = Vector3.new(0, 0.6, 0), color = rgb(45, 35, 70), material = M.Slate },
				{ name = "Base", shape = "Ball", size = Vector3.new(5.4, 4, 5.4), offset = Vector3.new(0, -4.4, 0), color = rgb(30, 22, 48), material = M.Basalt, transparency = 0.2 },
			},
			emit = { color = rgb(200, 150, 255), rate = 14 },
		}),
	} :: Enemy,

	stormheart = {
		static = true,
		attack = { radius = 11, damage = 18, delay = 1.8, cooldown = 4.5, style = "bolt" },
		def = def({
			id = "rift_stormheart",
			name = "The Stormheart",
			domain = "energy",
			level = 6,
			health = 1100,
			walk = 0,
			hipHeight = 3,
			hitbox = Vector3.new(8, 10, 8),
			resist = {},
			body = {
				{ name = "Head", shape = "Ball", size = Vector3.new(7, 7, 7), offset = Vector3.new(0, 1, 0), color = rgb(190, 225, 255), material = M.Neon },
				{ name = "Body", shape = "Block", size = Vector3.new(6, 2, 6), offset = Vector3.new(0, -4, 0), color = rgb(40, 44, 70), material = M.Metal },
			},
			emit = { color = rgb(170, 210, 255), rate = 20 },
		}),
	} :: Enemy,

	pylon = {
		static = true,
		def = def({
			id = "rift_pylon",
			name = "Pylon",
			domain = "energy",
			level = 4,
			health = 170,
			walk = 0,
			hipHeight = 1,
			hitbox = Vector3.new(4, 9, 4),
			resist = {},
			body = {
				{ name = "Head", shape = "Ball", size = Vector3.new(2.4, 2.4, 2.4), offset = Vector3.new(0, 4, 0), color = rgb(200, 230, 255), material = M.Neon },
				{ name = "Body", shape = "Block", size = Vector3.new(2.6, 7, 2.6), offset = Vector3.new(0, -0.6, 0), color = rgb(60, 66, 96), material = M.Metal },
			},
			emit = { color = rgb(170, 210, 255), rate = 8 },
		}),
	} :: Enemy,

	twinEmber = {
		static = false,
		attack = { radius = 10, damage = 16, delay = 1.7, cooldown = 7, style = "slam" },
		def = def({
			id = "rift_twin_ember",
			name = "The Ember Twin",
			domain = "void",
			level = 5,
			health = 800,
			walk = 13,
			hipHeight = 3,
			hitbox = Vector3.new(5, 8, 5),
			bite = { damage = 10, cooldown = 2.2, reach = 8, property = "momentum" },
			resist = {},
			body = {
				{ name = "Head", shape = "Ball", size = Vector3.new(3, 3, 3), offset = Vector3.new(0, 3.4, 0), color = rgb(255, 170, 90), material = M.Neon },
				{ name = "Body", shape = "Block", size = Vector3.new(4.4, 5, 3), offset = Vector3.new(0, 0, 0), color = rgb(70, 36, 30), material = M.Slate },
			},
			emit = { color = rgb(255, 150, 80), rate = 10 },
		}),
	} :: Enemy,

	twinAsh = {
		static = false,
		attack = { radius = 10, damage = 16, delay = 1.7, cooldown = 7, style = "slam" },
		def = def({
			id = "rift_twin_ash",
			name = "The Ash Twin",
			domain = "void",
			level = 5,
			health = 800,
			walk = 13,
			hipHeight = 3,
			hitbox = Vector3.new(5, 8, 5),
			bite = { damage = 10, cooldown = 2.2, reach = 8, property = "momentum" },
			resist = {},
			body = {
				{ name = "Head", shape = "Ball", size = Vector3.new(3, 3, 3), offset = Vector3.new(0, 3.4, 0), color = rgb(190, 200, 220), material = M.Neon },
				{ name = "Body", shape = "Block", size = Vector3.new(4.4, 5, 3), offset = Vector3.new(0, 0, 0), color = rgb(44, 46, 58), material = M.Slate },
			},
			emit = { color = rgb(190, 200, 220), rate = 10 },
		}),
	} :: Enemy,

	wardenHurtAt = 0.5, -- below this share of health it attacks faster and calls for help
	wardenHurtCooldown = 0.65,
	wardenHelp = 3, -- riftlings it calls
	roomEnemies = 2, -- riftlings in each room, before the twist
	coilPulse = { radius = 9, damage = 10, delay = 1.6, cooldown = 7, style = "pulse" } :: Attack,
}

return RiftEnemies
