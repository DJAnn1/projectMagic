--!strict
-- Unit specs for world generation: determinism, biome coverage, magic map, POIs, scheduler.

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local World = Server.World
local C = require(World.WorldConfig)
local WorldGen = require(World.WorldGen)
local MagicMap = require(World.MagicMap)
local WorldIndex = require(World.WorldIndex)
local POIPlacer = require(World.POIPlacer)
local Settlements = require(World.Settlements)
local Biomes = require(World.Biomes)
local Scheduler = require(Server.Core.Scheduler)

local SEED = 1337

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	local gen = WorldGen.new(SEED)
	local magic = MagicMap.new(gen, SEED)
	local index = WorldIndex.build(gen, magic)

	describe("WorldGen", function()
		it("is deterministic per seed", function()
			local other = WorldGen.new(SEED)
			for _, p in { { 0, 0 }, { 731, -1200 }, { -1900, 1500 } } do
				local a, b = gen:sample(p[1], p[2]), other:sample(p[1], p[2])
				expect(a.height).toBe(b.height)
				expect(a.biome).toBe(b.biome)
			end
			expect(WorldGen.new(SEED + 1):height(731, -1200) ~= gen:height(731, -1200)).toBe(true)
		end)
		it("rings the continent with ocean", function()
			local edge = C.WORLD_SIZE / 2 - 32
			for _, p in { { edge, 0 }, { -edge, 0 }, { 0, edge }, { 0, -edge } } do
				expect(gen:sample(p[1], p[2]).biome).toBe("ocean")
			end
		end)
		it("produces a varied world (at least 8 surface biomes on the coarse grid)", function()
			local seen: { [string]: number } = {}
			local count = 0
			for _, cell in index.cells do
				if not seen[cell.sample.biome] then
					count += 1
				end
				seen[cell.sample.biome] = (seen[cell.sample.biome] or 0) + 1
			end
			local parts = {}
			for _, id in Biomes.order do
				if seen[id] then
					table.insert(parts, string.format("%s %d", id, seen[id]))
				end
			end
			print(string.format("  world %d: %d biomes on the 32x32 grid: %s", SEED, count, table.concat(parts, ", ")))
			expect(count >= 8).toBe(true)
		end)
		it("knows every biome it assigns", function()
			for _, cell in index.cells do
				expect(Biomes.defs[cell.sample.biome] ~= nil).toBe(true)
			end
		end)
	end)

	describe("MagicMap", function()
		it("builds a connected ley network", function()
			expect(#magic.nexuses >= 5).toBe(true)
			expect(#magic.lines >= #magic.nexuses - 1).toBe(true) -- spanning tree at least
		end)
		it("keeps density within 0..3 and is strongest at a nexus", function()
			local nexus = magic.nexuses[1]
			local atNexus = magic:densityAt(nexus.x, nexus.z)
			expect(atNexus > 1).toBe(true)
			for _, cell in index.cells do
				expect(cell.density >= 0 and cell.density <= 3).toBe(true)
			end
		end)
		it("boosts aligned domains and suppresses opposed ones", function()
			for _, cell in index.cells do
				if cell.sample.biome == "volcanic_highlands" then
					local bias = magic:resonanceAt(cell.x, cell.z, cell.sample)
					expect(bias.energy > 1).toBe(true)
					expect(bias.water < 1).toBe(true)
					return
				end
			end
		end)
	end)

	describe("WorldIndex", function()
		it("finds open sea connected to the edge and a coastline", function()
			local open, coast = 0, 0
			for _, cell in index.cells do
				open += if cell.openSea then 1 else 0
				coast += if not cell.ocean and cell.coastDistance == 0 then 1 else 0
			end
			expect(open > 0).toBe(true)
			expect(coast > 0).toBe(true)
		end)
	end)

	describe("POIPlacer", function()
		local placement = POIPlacer.place(index, magic, SEED)
		it("is deterministic", function()
			local again = POIPlacer.place(index, magic, SEED)
			expect(#again.pois).toBe(#placement.pois)
			expect(again.pois[1].x).toBe(placement.pois[1].x)
		end)
		it("places each mythic site exactly once, hidden, with lore hints elsewhere", function()
			for _, mythic in { "time", "gravity", "reality" } do
				local count = 0
				for _, poi in placement.pois do
					if poi.grants.mythic == mythic then
						count += 1
						expect(poi.hidden).toBe(true)
					end
				end
				expect(count).toBe(1)
				expect(placement.hintText["hint:" .. mythic .. ":1"] ~= nil).toBe(true)
			end
		end)
		it("founds settlements with cultures, sizes and roads", function()
			expect(#placement.settlements >= 6).toBe(true)
			expect(placement.settlements[1].size).toBe("city")
			for _, s in placement.settlements do
				expect(Settlements.cultures[s.culture] ~= nil).toBe(true)
			end
			expect(#placement.roads >= #placement.settlements - 1).toBe(true)
		end)
		it("keeps POIs off the ocean unless they belong there", function()
			for _, poi in placement.pois do
				local cell = index:cellAt(poi.x, poi.z)
				if poi.type ~= "ocean_trench" and poi.type ~= "sunken_shrine" then
					expect(cell.ocean and poi.type or "land").toBe("land")
				end
			end
		end)
	end)

	describe("Settlements", function()
		it("punishes forbidden magic and rewards revered magic", function()
			local town: any = { id = "s", name = "Test", culture = "forgehold", size = "town", x = 0, z = 0, population = 1, relations = {} }
			expect((Settlements.judgeCast(town, { "spirit" }, { "forbidden" }, true))).toBe(-25)
			expect((Settlements.judgeCast(town, { "earth" }, {}, false))).toBe(0.5)
		end)
	end)

	describe("Scheduler", function()
		it("spreads a long job across frames within the budget", function()
			local frames = 0
			local lastFrame = -1
			local job = Scheduler.spawn("spec busy job", function()
				for _ = 1, 40 do
					local started = os.clock()
					while os.clock() - started < 0.001 do
						-- 1 ms of work
					end
					if lastFrame ~= time() then
						lastFrame = time()
						frames += 1
					end
					Scheduler.checkpoint()
				end
			end)
			Scheduler.await(job)
			expect(frames > 1).toBe(true)
		end)
	end)
end
