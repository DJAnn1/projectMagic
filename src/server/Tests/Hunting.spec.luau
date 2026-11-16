--!strict
--[[
	Hunting.spec: game animals, herds, shorelines and fishers (docs/Hunting.md). What matters most: the
	critters' dens didn't move when herds were added; herds are seeded, outside towns and clear of dens;
	game is harmless, silent and drops things that exist; a shore spot stands on dry ground facing water,
	and an inland town has none; fishers with no shore mend nets instead of fishing on grass.
]]

local ServerScriptService = game:GetService("ServerScriptService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local ItemDatabase = require(ReplicatedStorage.Shared.Items.ItemDatabase)
local Server = ServerScriptService.Server
local Creatures = require(Server.Creatures.Data.Creatures)
local CreatureRules = require(Server.Creatures.CreatureRules)
local Shore = require(Server.Life.Shore)
local ActivityRules = require(Server.Life.ActivityRules)
local Flags = require(Server.Config.Flags)

local T = Creatures.tuning
local SEA = 48

local TOWNS: { CreatureRules.Town } = {
	{ id = "a", x = 0, z = 0, radius = 60, biome = "grasslands" },
	{ id = "b", x = 900, z = 0, radius = 80, biome = "deep_forest" },
}

local function flatLand(_x: number, _z: number): (number, number)
	return 80, 0.1
end

-- A coast: land west of x = 120, sea east of it, sloping down to the water.
local function coast(x: number, _z: number): number
	if x < 120 then
		return SEA + math.clamp((120 - x) / 10, 1, 20)
	end
	return SEA - 6
end

local function fisher(noShore: boolean?): any
	return { id = "f#1", seed = 777, occupation = "fisher", quirks = {}, traits = { extraversion = 0.5 }, ageBand = "adult", noShore = noShore }
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Hunting and fishing (docs/Hunting.md)", function()
		it("game is harmless, silent, flees, and drops things that exist", function()
			expect(#Creatures.gameIds >= 3).toBe(true)
			for _, id in Creatures.gameIds do
				local def = Creatures.defs[id]
				expect(def.game).toBe(true)
				expect(def.bite == nil).toBe(true)
				expect(def.behaviour).toBe("flee")
				expect(def.silent).toBe(true)
				expect(table.find(Creatures.ids, id) == nil).toBe(true) -- never a critter den
				for _, entry in def.loot do
					if not ItemDatabase.get(entry.item) then
						error(id .. " drops unknown item " .. entry.item)
					end
				end
			end
		end)

		it("herds are seeded, outside towns and clear of the critters' dens, which didn't move", function()
			local dens = CreatureRules.planDens(1337, TOWNS, flatLand, SEA)
			local before = CreatureRules.planDens(1337, TOWNS, flatLand, SEA)
			local herds = CreatureRules.planHerds(1337, TOWNS, flatLand, SEA, dens)
			local again = CreatureRules.planHerds(1337, TOWNS, flatLand, SEA, before)
			expect(#herds).toBe(#again)
			expect(#herds >= #TOWNS * 2).toBe(true)
			for i, herd in herds do
				expect(herd.id).toBe(again[i].id)
				expect(herd.x).toBe(again[i].x)
				expect(Creatures.defs[herd.type].game).toBe(true)
				expect(string.find(herd.id, ":herd", 1, true) ~= nil).toBe(true)
				for _, town in TOWNS do
					expect(math.sqrt((town.x - herd.x) ^ 2 + (town.z - herd.z) ^ 2) >= town.radius + T.townMargin).toBe(true)
				end
				for _, den in dens do
					expect(math.sqrt((den.x - herd.x) ^ 2 + (den.z - herd.z) ^ 2) >= T.denSpacing).toBe(true)
				end
			end
			-- planHerds must not touch the dens list it was given
			expect(#dens).toBe(#before)
		end)

		it("a shore spot stands on dry ground with water in front of it; inland has none", function()
			local spots = Shore.find({ x = 0, z = 0, radius = 60 }, coast, SEA)
			expect(#spots > 0).toBe(true)
			for _, spot in spots do
				expect(coast(spot.at.X, spot.at.Z) >= SEA + 0.5).toBe(true)
				expect(coast(spot.water.X, spot.water.Z) < SEA).toBe(true)
				expect((spot.water - Vector3.new(spot.at.X, SEA, spot.at.Z)).Magnitude < 10).toBe(true)
			end
			local inland = Shore.find({ x = 0, z = 0, radius = 60 }, function()
				return SEA + 30
			end, SEA)
			expect(#inland).toBe(0)
			expect(Shore.pick(inland, 5) == nil).toBe(true)
			expect(Shore.pick(spots, 5) ~= nil).toBe(true)
		end)

		it("fishers fish by the water and mend nets where there is none", function()
			local by = ActivityRules.pick(fisher(false), "work", 3)
			expect(by ~= nil and by.id).toBe("fishing")
			local inland = ActivityRules.pick(fisher(true), "work", 3)
			expect(inland ~= nil and inland.id).toBe("mending_nets")
			expect((Flags :: any).hunting_enabled ~= nil).toBe(true)
		end)
	end)
end
