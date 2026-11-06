--!strict
--[[
	TitanBodies: what a Titan is made of and how hard it hits (docs/Titans.md). Each `def` is a
	Creatures.Def, so CreatureRig builds it like any creature: spells, statuses and lock-on work with no
	special code, and hitting one is never a crime. They aren't in Creatures.defs, so they're never in dens.

		health    the base for one player at power 3 or below. It rises with who's fighting and how strong
		          they are, as Rift enemies do.
		weak      three breakable points that move with it: two knees and a crown you need range or flight for

	Tuning status: first guesses, not yet played. A Titan is meant to take a group, or a very strong mage.
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local T = require(Shared.Titans.Data.Titans)

local Server = script.Parent.Parent.Parent
local Creatures = require(Server.Creatures.Data.Creatures)

local rgb = Color3.fromRGB
local M = Enum.Material

export type Attack = { radius: number, damage: number, delay: number, cooldown: number, style: string }
export type Body = { def: Creatures.Def, stomp: Attack, foot: Attack, lightning: Attack }
export type Weak = { name: string, offset: Vector3, def: Creatures.Def }

local HEIGHT = 62

local function def(fields: { id: string, name: string, domain: string, level: number, health: number, hitbox: Vector3, resist: { [string]: number }, body: { Creatures.Part }, emit: { color: Color3, rate: number }? }): Creatures.Def
	return {
		id = fields.id,
		name = fields.name,
		description = "",
		domain = fields.domain,
		level = fields.level,
		health = fields.health,
		walk = 0, -- TitanService moves it
		hipHeight = fields.hitbox.Y / 2,
		hitbox = fields.hitbox,
		behaviour = "swarm", -- unused
		leash = 0,
		bite = nil,
		pack = { min = 1, max = 1 },
		respawn = { min = 0, max = 0 },
		resist = fields.resist,
		biomes = {},
		xp = 0, -- rewards come from contribution tiers, not per kill
		loot = {},
		body = fields.body,
		emit = fields.emit,
		nestColor = rgb(0, 0, 0),
	}
end

local function body(kind: T.Kind, material: Enum.Material, glowMaterial: Enum.Material): Body
	local color = kind.bone
	local glow = kind.color
	return {
		stomp = { radius = 18, damage = 34, delay = 2.2, cooldown = 6, style = "slam" },
		foot = { radius = 13, damage = 22, delay = 1, cooldown = 0, style = "slam" },
		lightning = { radius = 10, damage = 18, delay = 1.6, cooldown = 7, style = "bolt" },
		def = def({
			id = "titan_" .. kind.id,
			name = kind.name,
			domain = "earth",
			level = 7,
			health = 5000,
			hitbox = Vector3.new(26, HEIGHT, 18),
			resist = { [kind.weakness] = -0.3 },
			body = {
				{ name = "Head", shape = "Ball", size = Vector3.new(11, 12, 11), offset = Vector3.new(0, 25, 0), color = glow, material = glowMaterial },
				{ name = "Torso", shape = "Block", size = Vector3.new(24, 22, 14), offset = Vector3.new(0, 8, 0), color = color, material = material },
				{ name = "ArmL", shape = "Block", size = Vector3.new(7, 30, 7), offset = Vector3.new(-17, 3, 0), color = color, material = material },
				{ name = "ArmR", shape = "Block", size = Vector3.new(7, 30, 7), offset = Vector3.new(17, 3, 0), color = color, material = material },
				{ name = "LegL", shape = "Block", size = Vector3.new(9, 30, 10), offset = Vector3.new(-7, -16, 0), color = color, material = material },
				{ name = "LegR", shape = "Block", size = Vector3.new(9, 30, 10), offset = Vector3.new(7, -16, 0), color = color, material = material },
			},
			emit = { color = glow, rate = 24 },
		}),
	}
end

local function weak(id: string, name: string, offset: Vector3, health: number, kind: T.Kind): Weak
	return {
		name = name,
		offset = offset,
		def = def({
			id = "titan_weak_" .. id,
			name = name,
			domain = "earth",
			level = 6,
			health = health,
			hitbox = Vector3.new(7, 7, 7),
			resist = { [kind.weakness] = -0.3 },
			body = { { name = "Head", shape = "Ball", size = Vector3.new(6, 6, 6), offset = Vector3.zero, color = kind.color, material = M.Neon } },
			emit = { color = kind.color, rate = 8 },
		}),
	}
end

local function weakPoints(kind: T.Kind): { Weak }
	return {
		weak("knee_l", "Left Knee", Vector3.new(-7, -16, -6), 450, kind),
		weak("knee_r", "Right Knee", Vector3.new(7, -16, -6), 450, kind),
		weak("crown", "Crown", Vector3.new(0, 33, 0), 650, kind),
	}
end

local bodies: { [string]: Body } = {
	ashwalker = body(T.kinds.ashwalker, M.Basalt, M.Neon),
	stonefather = body(T.kinds.stonefather, M.Slate, M.Neon),
	stormcrown = body(T.kinds.stormcrown, M.Metal, M.Neon),
}

local TitanBodies = {
	bodies = bodies,
	weakPoints = weakPoints,
	height = HEIGHT,
}

return TitanBodies
