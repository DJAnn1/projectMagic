--!strict
--[[
	WildbornRules: the pure decisions about Wildborn (docs/Wildborn.md). No Instances, no services.

		WildbornRules.planHaunts(seed, sampler, towns, worldSize, seaLevel)   where ordinary Wildborn
		    live: a grid of hauntCell cells over the island; a dry, wild cell (townClearance from any
		    town) of a theme's biome gets a haunt with hauntChance x the biome's weight. Seeded per
		    cell, so every server plans the same haunts. At most hauntMax, nearest-first is irrelevant.
		WildbornRules.planLairs(seed, sampler, towns, worldSize, seaLevel)    one lair per theme: the
		    best dry cell of its biomes (weight, then flatness, then a seeded tiebreak) at least
		    lairClearance from any town. nil for a theme whose biomes the world doesn't have.
		WildbornRules.chooseMove(enemy, view)   the first of its moves that's ready and in range
		    (cooldown over, distance within min..max, `below` health share, `once` not yet used), or
		    nil: then it walks in and uses its plain blow.
		WildbornRules.bossBack(killedAt, now)   is a beaten boss back yet (bossReturnSeconds)
		WildbornRules.shouldReturn(distanceHome, leash)   gone too far from home
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local Seed = require(ReplicatedStorage.Shared.Magic.Seed)
local Data = require(script.Parent.Data.Wildborn)

local T = Data.tuning

export type Sample = { biome: string, height: number, slope: number }
export type Sampler = (x: number, z: number) -> Sample
export type Town = { x: number, z: number }
export type Haunt = { id: string, enemy: string, theme: string, x: number, z: number, count: number }
export type Lair = { id: string, enemy: string, theme: string, x: number, z: number }
export type View = { distance: number, healthShare: number, now: number, readyAt: { [number]: number }, used: { [number]: boolean } }

local WildbornRules = {}

local function nearTown(towns: { Town }, x: number, z: number, clearance: number): boolean
	for _, town in towns do
		local dx, dz = town.x - x, town.z - z
		if dx * dx + dz * dz < clearance * clearance then
			return true
		end
	end
	return false
end

-- Which theme a biome belongs to most, and how strongly (several themes can share a biome).
local function themesFor(biome: string): { { theme: string, weight: number } }
	local out: { { theme: string, weight: number } } = {}
	for _, themeId in Data.themeOrder do
		local weight = Data.themes[themeId].biomes[biome]
		if weight then
			table.insert(out, { theme = themeId, weight = weight })
		end
	end
	return out
end

local function cells(worldSize: number): { { x: number, z: number, i: number, j: number } }
	local out = {}
	local half = worldSize / 2
	local n = math.floor(worldSize / T.hauntCell)
	for i = 0, n - 1 do
		for j = 0, n - 1 do
			table.insert(out, { x = -half + (i + 0.5) * T.hauntCell, z = -half + (j + 0.5) * T.hauntCell, i = i, j = j })
		end
	end
	return out
end

function WildbornRules.planHaunts(seed: number, sample: Sampler, towns: { Town }, worldSize: number, seaLevel: number): { Haunt }
	local haunts: { Haunt } = {}
	for _, cell in cells(worldSize) do
		if #haunts >= T.hauntMax then
			break
		end
		local rng = Seed.random(seed, string.format("wild_cell:%d:%d", cell.i, cell.j), "wildborn_haunt")
		-- Somewhere inside the cell, not always its middle.
		local x = cell.x + (rng:NextNumber() - 0.5) * T.hauntCell * 0.6
		local z = cell.z + (rng:NextNumber() - 0.5) * T.hauntCell * 0.6
		local s = sample(x, z)
		if s.height > seaLevel + 2 and s.slope < 0.8 and not nearTown(towns, x, z, T.townClearance) then
			local options = themesFor(s.biome)
			if #options > 0 then
				local pick = options[rng:NextInteger(1, #options)]
				if rng:NextNumber() < T.hauntChance * pick.weight then
					local theme = Data.themes[pick.theme]
					table.insert(haunts, {
						id = string.format("haunt:%d:%d", cell.i, cell.j),
						enemy = theme.regular,
						theme = pick.theme,
						x = x,
						z = z,
						count = rng:NextInteger(T.hauntPack.min, T.hauntPack.max),
					})
				end
			end
		end
	end
	return haunts
end

function WildbornRules.planLairs(seed: number, sample: Sampler, towns: { Town }, worldSize: number, seaLevel: number): { [string]: Lair }
	local best: { [string]: { score: number, x: number, z: number } } = {}
	for _, cell in cells(worldSize) do
		local s = sample(cell.x, cell.z)
		if s.height > seaLevel + 2 and s.slope < 0.6 and not nearTown(towns, cell.x, cell.z, T.lairClearance) then
			for _, option in themesFor(s.biome) do
				local tiebreak = Seed.random(seed, string.format("wild_cell:%d:%d", cell.i, cell.j), "wildborn_lair:" .. option.theme):NextNumber()
				local score = option.weight * 2 + (0.6 - s.slope) + tiebreak * 0.5
				local current = best[option.theme]
				if not current or score > current.score then
					best[option.theme] = { score = score, x = cell.x, z = cell.z }
				end
			end
		end
	end
	local lairs: { [string]: Lair } = {}
	for themeId, spot in best do
		local theme = Data.themes[themeId]
		lairs[themeId] = { id = "lair:" .. themeId, enemy = theme.boss, theme = themeId, x = spot.x, z = spot.z }
	end
	return lairs
end

function WildbornRules.chooseMove(enemy: Data.Enemy, view: View): (number?, Data.Move?)
	for index, move in enemy.moves do
		local ready = view.now >= (view.readyAt[index] or 0)
		local inRange = view.distance >= (move.min or 0) and view.distance <= (move.max or math.huge)
		local healthOk = move.below == nil or view.healthShare < move.below
		local fresh = not (move.once and view.used[index])
		if ready and inRange and healthOk and fresh then
			return index, move
		end
	end
	return nil, nil
end

function WildbornRules.bossBack(killedAt: number?, now: number): boolean
	return killedAt == nil or now - killedAt >= T.bossReturnSeconds
end

function WildbornRules.shouldReturn(distanceHome: number, leash: number): boolean
	return distanceHome > leash
end

return WildbornRules
