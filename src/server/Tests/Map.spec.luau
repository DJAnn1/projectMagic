--!strict
--[[
	Map.spec: the map's grid and what it reveals, with no live players (docs/Map.md). The important part
	is what must never reach a client: cells you haven't uncovered, and hidden sites.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Biomes = require(Server.World.Biomes)
local WorldConfig = require(Server.World.WorldConfig)

local Shared = ReplicatedStorage.Shared
local MapData = require(Shared.World.MapData)
local Remotes = require(Shared.Net.Remotes)
local Controls = require(Shared.UI.Controls)

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("The map's grid", function()
		it("matches the world's size", function()
			expect(MapData.worldSize).toBe(WorldConfig.WORLD_SIZE)
			expect(MapData.cols * MapData.cell).toBe(WorldConfig.WORLD_SIZE)
		end)
		it("every biome has a look", function()
			for id in Biomes.defs do
				local found = false
				for _, style in MapData.biomes do
					found = found or style.id == id
				end
				if not found then
					error("no map style for biome " .. id)
				end
			end
		end)
		it("a cell's centre is in that cell", function()
			for _, index in { 0, 1, 63, 64, 2000, 4095 } do
				local x, z = MapData.cellCentre(index)
				expect(MapData.cellIndex(x, z)).toBe(index)
			end
		end)
		it("anywhere off the island lands on its edge", function()
			expect(MapData.cellIndex(-99999, -99999)).toBe(0)
			expect(MapData.cellIndex(99999, 99999)).toBe(MapData.cols * MapData.cols - 1)
		end)
		it("world to map and back agree", function()
			local u, v = MapData.toMap(512, -256)
			local x, z = MapData.fromMap(u, v)
			expect(x).toBeNear(512, 0.001)
			expect(z).toBeNear(-256, 0.001)
		end)
		it("every biome and shade has a colour, and they differ by height", function()
			for _, style in MapData.biomes do
				local low = MapData.encodeCell(style.id, 50, 48)
				local high = MapData.encodeCell(style.id, 400, 48)
				expect(low ~= high).toBe(true)
				expect(MapData.colorOf(low) ~= nil).toBe(true)
				expect(MapData.colorOf(high) ~= nil).toBe(true)
			end
		end)
		it("an uncovered cell has no colour", function()
			expect(MapData.colorOf(MapData.unknown)).toBe(nil)
		end)
		it("no code is mistaken for an uncovered cell", function()
			for _, style in MapData.biomes do
				expect(MapData.encodeCell(style.id, 0, 48) ~= MapData.unknown).toBe(true)
			end
		end)
	end)

	describe("Uncovering", function()
		it("starts with nothing", function()
			expect(MapData.isRevealed({}, 100)).toBe(false)
		end)
		it("remembers each cell, and says when it's news", function()
			local bits: { [string]: number } = {}
			expect(MapData.reveal(bits, 100)).toBe(true)
			expect(MapData.reveal(bits, 100)).toBe(false)
			expect(MapData.isRevealed(bits, 100)).toBe(true)
			expect(MapData.isRevealed(bits, 101)).toBe(false)
		end)
		it("every cell survives, at both ends of a word", function()
			local bits: { [string]: number } = {}
			for index = 0, MapData.cols * MapData.cols - 1 do
				MapData.reveal(bits, index)
			end
			for index = 0, MapData.cols * MapData.cols - 1 do
				if not MapData.isRevealed(bits, index) then
					error("lost cell " .. index)
				end
			end
		end)
		it("uses string keys, as a DataStore needs", function()
			local bits: { [string]: number } = {}
			MapData.reveal(bits, 100)
			for key in bits do
				expect(typeof(key)).toBe("string")
			end
		end)
		it("uncovers around you, and returns only what's new", function()
			local bits: { [string]: number } = {}
			local first = MapData.revealAround(bits, 0, 0, 192)
			expect(#first > 0).toBe(true)
			expect(MapData.isRevealed(bits, MapData.cellIndex(0, 0))).toBe(true)
			expect(MapData.isRevealed(bits, MapData.cellIndex(1500, 1500))).toBe(false)
			expect(#MapData.revealAround(bits, 0, 0, 192)).toBe(0)
		end)
		it("works at the very edge of the island", function()
			local bits: { [string]: number } = {}
			expect(#MapData.revealAround(bits, 2047, 2047, 192) > 0).toBe(true)
			expect(#MapData.revealAround(bits, -2047, -2047, 192) > 0).toBe(true)
		end)
		it("you see further from up high, to a limit", function()
			expect(MapData.radiusAt(0)).toBe(MapData.revealRadius)
			expect(MapData.radiusAt(100) > MapData.radiusAt(0)).toBe(true)
			expect(MapData.radiusAt(100000)).toBe(MapData.maxRevealRadius)
			expect(MapData.radiusAt(-50)).toBe(MapData.revealRadius)
		end)
	end)

	describe("What a client may see", function()
		it("the grid hides everything you haven't uncovered", function()
			local grid = string.rep("5", 10)
			local bits: { [string]: number } = {}
			MapData.reveal(bits, 2)
			expect(MapData.visibleGrid(grid, bits)).toBe("..5.......")
		end)
		it("a place you haven't uncovered stays unknown", function()
			local pois = { { id = "a", type = "mine", x = 1000, z = 1000, hidden = false } }
			expect(#MapData.knownPois(pois, {})).toBe(0)
		end)
		it("a place in uncovered ground is known", function()
			local pois = { { id = "a", type = "mine", x = 1000, z = 1000, hidden = false } }
			local bits: { [string]: number } = {}
			MapData.reveal(bits, MapData.cellIndex(1000, 1000))
			local known = MapData.knownPois(pois, bits)
			expect(#known).toBe(1)
			expect(known[1].id).toBe("a")
		end)
		it("a hidden site never shows, even if you stand on it", function()
			local pois = { { id = "secret", type = "mythic_stopped_clock", x = 1000, z = 1000, hidden = true } }
			local bits: { [string]: number } = {}
			MapData.reveal(bits, MapData.cellIndex(1000, 1000))
			expect(#MapData.knownPois(pois, bits)).toBe(0)
		end)
		it("a town shows its name", function()
			local pois = { { id = "t", type = "settlement", x = 0, z = 0, hidden = false, settlement = { name = "Glenhold" } } }
			local bits: { [string]: number } = {}
			MapData.reveal(bits, MapData.cellIndex(0, 0))
			expect(MapData.knownPois(pois, bits)[1].name).toBe("Glenhold")
		end)
		it("nothing about a known place gives away its secrets", function()
			local pois = { { id = "a", type = "mine", x = 0, z = 0, hidden = false, grants = { mythic = "time" }, hints = { "h" } } }
			local bits: { [string]: number } = {}
			MapData.reveal(bits, MapData.cellIndex(0, 0))
			local known: any = MapData.knownPois(pois, bits)[1]
			expect(known.grants).toBe(nil)
			expect(known.hints).toBe(nil)
		end)
	end)

	describe("How places look", function()
		it("a shrine names its domain", function()
			expect(MapData.poiStyle("shrine_water").label).toBe("Shrine of Water")
		end)
		it("an unknown type still draws", function()
			expect(MapData.poiStyle("nonsense").glyph ~= nil).toBe(true)
		end)
	end)

	describe("Map wiring", function()
		it("the remotes and key exist, and the old all-places message is gone", function()
			expect(Remotes.RequestMap.from).toBe("Client")
			expect(Remotes.MapReveal.from).toBe("Server")
			expect((Remotes :: any).PoiMarkers).toBe(nil)
			expect(Controls.key("open_map", "keyboard")).toBe(Enum.KeyCode.M)
		end)
	end)
end
