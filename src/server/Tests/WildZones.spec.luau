--!strict
--[[
	WildZones.spec: the rules behind Wild Zones, with no live players (docs/WildZones.md). The ones that
	matter most: every server agrees where they are, no zone lands on a town, a tide can't fling anyone
	into the sky, and a harvest can't be taken twice in a day.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local Rules = require(Server.World.WildZoneRules)
local Biomes = require(Server.World.Biomes)
local WorldConfig = require(Server.World.WorldConfig)
local WorldGen = require(Server.World.WorldGen)
local Creatures = require(Server.Creatures.Data.Creatures)
local Flags = require(Server.Config.Flags)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)

local Shared = ReplicatedStorage.Shared
local W = require(Shared.World.WildZones)
local Registry = require(Shared.Magic.Registry)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local MapData = require(Shared.World.MapData)
local Remotes = require(Shared.Net.Remotes)
local StatusInfo = require(Shared.Magic.Data.StatusInfo)

-- A big square of land with a shoreline along one side, like a small island.
local function island(): { Rules.Cell }
	local cells: { Rules.Cell } = {}
	for gz = -20, 20 do
		for gx = -20, 20 do
			local ocean = gx > 17
			table.insert(cells, {
				x = gx * 128,
				z = gz * 128,
				biome = if gz < 0 then "grasslands" else "ruinlands",
				ocean = ocean,
				slope = 0.1,
				coastDistance = if gx >= 16 then 0 else 5,
			})
		end
	end
	return cells
end

local TOWNS: { Rules.Spot } = { { x = 0, z = 0 }, { x = 900, z = 500 } }

local function distance(a: { x: number, z: number }, b: { x: number, z: number }): number
	return math.sqrt((a.x - b.x) ^ 2 + (a.z - b.z) ^ 2)
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Wild zone data", function()
		it("every id in the list exists, and every zone is in the list", function()
			for _, id in W.ids do
				expect(W.zones[id] ~= nil).toBe(true)
			end
			for id, zone in W.zones do
				expect(table.find(W.ids, id) ~= nil).toBe(true)
				expect(zone.id).toBe(id)
			end
		end)
		it("every zone actually breaks a rule", function()
			for id, zone in W.zones do
				local any = zone.gravity or zone.tide or zone.crawl or zone.burnsSwimmers or zone.healShare or zone.density
				if not any then
					error(id .. " changes nothing about the world")
				end
			end
		end)
		it("every zone has words for the player", function()
			for _, zone in W.zones do
				expect(#zone.name > 0 and #zone.rule > 0 and #zone.arrive > 0).toBe(true)
			end
		end)
		it("biases name real domains, biomes real biomes", function()
			for _, zone in W.zones do
				for domain in (zone.bias or {}) :: { [string]: number } do
					expect(Registry.domains[domain] ~= nil).toBe(true)
				end
				for _, biome in zone.biomes do
					expect(Biomes.defs[biome] ~= nil).toBe(true)
				end
			end
		end)
		it("guards are real creatures, and harvests real items", function()
			for _, zone in W.zones do
				expect(Creatures.defs[zone.creatures.type] ~= nil).toBe(true)
				expect(#zone.harvest > 0).toBe(true)
				for _, entry in zone.harvest do
					expect(ItemDatabase.get(entry.item) ~= nil).toBe(true)
				end
			end
		end)
		it("every zone's heart always gives something", function()
			for id, zone in W.zones do
				local certain = false
				for _, entry in zone.harvest do
					certain = certain or entry.chance >= 1
				end
				if not certain then
					error(id .. " could give nothing at all")
				end
			end
		end)
		it("the crawl is a real status the HUD can name", function()
			expect(StatusEffects.has ~= nil).toBe(true)
			expect(StatusInfo.zone_crawl ~= nil).toBe(true)
		end)
		it("declares its flag and remote, and clients can't send anything", function()
			expect((Flags :: any).wild_zones_enabled ~= nil).toBe(true)
			expect(Remotes.WildZoneState.from).toBe("Server")
		end)
		it("shows on the map as itself, under its own name, while it's uncovered", function()
			expect(MapData.poiStyle("wild_zone").label).toBe("Wild zone")
			local bits: { [string]: number } = {}
			MapData.reveal(bits, MapData.cellIndex(100, 100))
			local known = MapData.knownPois({ { id = "z", type = "wild_zone", name = "The Slow Wood", x = 100, z = 100, hidden = false } }, bits)
			expect(#known).toBe(1)
			expect(known[1].name).toBe("The Slow Wood")
			expect(#MapData.knownPois({ { id = "z", type = "wild_zone", name = "x", x = 1500, z = 1500, hidden = false } }, bits)).toBe(0)
		end)
	end)

	describe("Wild zone placement", function()
		it("every server places them the same", function()
			local a = Rules.plan(1337, island(), TOWNS, {})
			local b = Rules.plan(1337, island(), TOWNS, {})
			expect(#a).toBe(#b)
			for i, zone in a do
				expect(zone.id).toBe(b[i].id)
				expect(zone.x).toBe(b[i].x)
				expect(zone.z).toBe(b[i].z)
			end
		end)
		it("a different world seed places them differently", function()
			local a = Rules.plan(1337, island(), TOWNS, {})
			local b = Rules.plan(2024, island(), TOWNS, {})
			local differs = false
			for i, zone in a do
				differs = differs or zone.x ~= b[i].x or zone.z ~= b[i].z
			end
			expect(differs).toBe(true)
		end)
		it("places all six when there's room", function()
			expect(#Rules.plan(1337, island(), TOWNS, {})).toBe(#W.ids)
		end)
		it("keeps clear of every town", function()
			for seed = 1, 10 do
				for _, zone in Rules.plan(seed, island(), TOWNS, {}) do
					for _, town in TOWNS do
						expect(distance(zone, town) >= zone.def.radius + W.townClear).toBe(true)
					end
				end
			end
		end)
		it("keeps zones apart", function()
			for seed = 1, 10 do
				local zones = Rules.plan(seed, island(), TOWNS, {})
				for i, a in zones do
					for j, b in zones do
						if i < j then
							expect(distance(a, b) >= a.def.radius + b.def.radius + W.zoneGap).toBe(true)
						end
					end
				end
			end
		end)
		it("is on land, and the Burning Shore is on the coast", function()
			for seed = 1, 10 do
				for _, zone in Rules.plan(seed, island(), TOWNS, {}) do
					expect(zone.x <= 17 * 128).toBe(true)
					if zone.id == "shore" then
						expect(zone.x >= 16 * 128).toBe(true)
					end
				end
			end
		end)
		it("prefers its own ground when it's free", function()
			local zones = Rules.plan(1337, island(), {}, {})
			for _, zone in zones do
				if zone.id == "hollow" then
					expect(zone.biome).toBe("ruinlands")
				end
			end
		end)
		it("leaves a zone out rather than put it on a town", function()
			local tiny: { Rules.Cell } = { { x = 0, z = 0, biome = "grasslands", ocean = false, slope = 0, coastDistance = 5 } }
			expect(#Rules.plan(1337, tiny, { { x = 0, z = 0 } }, {})).toBe(0)
		end)
		it("gives way on other places before it gives up", function()
			local tiny: { Rules.Cell } = { { x = 0, z = 0, biome = "grasslands", ocean = false, slope = 0, coastDistance = 5 } }
			expect(#Rules.plan(1337, tiny, {}, { { x = 10, z = 10 } }) >= 1).toBe(true)
		end)
		it("knows which zone you're in", function()
			local zones = Rules.plan(1337, island(), TOWNS, {})
			local zone = zones[1]
			expect(Rules.zoneAt(zones, zone.x + zone.def.radius - 1, zone.z)).toBe(zone)
			expect(Rules.zoneAt(zones, 0, 0)).toBe(nil)
			expect(Rules.zoneAt(zones, 6000, 0)).toBe(nil) -- a Rift's pocket is never in a zone
		end)
	end)

	describe("Wild zone rules", function()
		it("the Vale's gravity is low all the time, and nothing lifts you", function()
			local g = Rules.gravityAt(W.zones.vale, 7, 0)
			expect(g).toBe(W.zones.vale.gravity)
			expect((g :: number) > 0 and (g :: number) < 1).toBe(true)
		end)
		it("a zone with no gravity rule leaves it alone", function()
			expect(Rules.gravityAt(W.zones.hollow, 7, 0)).toBe(nil)
		end)
		it("the Moor lifts you only while the ground has let go", function()
			local tide = W.zones.moor.tide :: W.Tide
			expect(Rules.gravityAt(W.zones.moor, tide.every * 4 + 0.1, 0)).toBe(tide.mult)
			expect(Rules.gravityAt(W.zones.moor, tide.every * 4 + tide.lasts + 1, 0)).toBe(nil)
		end)
		it("a tide stops at its ceiling, so nobody is flung into the sky", function()
			local tide = W.zones.moor.tide :: W.Tide
			expect(Rules.gravityAt(W.zones.moor, tide.every * 4 + 0.1, tide.ceiling + 1)).toBe(0)
		end)
		it("a tide really lifts you: it pushes, and then holds you weightless", function()
			-- A gentle lift alone did nothing: a standing Humanoid pins itself to the floor.
			local tide = W.zones.moor.tide :: W.Tide
			expect(tide.kick > 0).toBe(true)
			expect(tide.mult <= 0).toBe(true)
		end)
		it("a tide lifts you far enough to feel, and no further than its ceiling", function()
			local tide = W.zones.moor.tide :: W.Tide
			local rise = tide.kick * tide.lasts + 0.5 * math.abs(tide.mult) * workspace.Gravity * tide.lasts ^ 2
			expect(rise >= 20).toBe(true)
			expect(rise <= tide.ceiling).toBe(true)
		end)
		it("counts down to the next tide, and says 0 while it's on", function()
			local tide = W.zones.moor.tide :: W.Tide
			expect(Rules.nextTide(W.zones.moor, tide.every * 2 + 0.5)).toBe(0)
			expect(Rules.nextTide(W.zones.moor, tide.every * 2 + tide.lasts + 1)).toBeNear(tide.every - tide.lasts - 1, 0.001)
			expect(Rules.nextTide(W.zones.vale, 5)).toBe(nil)
		end)
		it("what a zone does to magic never runs out, and covers exactly the zone", function()
			local zone = Rules.plan(1337, island(), TOWNS, {})[1]
			local modifier = Rules.modifierOf(zone)
			expect(modifier.expiresAt).toBe(math.huge)
			expect(modifier.radius).toBe(zone.def.radius)
			expect(modifier.x).toBe(zone.x)
		end)
		it("the Hollow really does choke magic", function()
			expect((W.zones.hollow.density :: number) < 0.5).toBe(true)
		end)
		it("the Shore makes fire stronger and water weaker", function()
			local bias = W.zones.shore.bias :: { [string]: number }
			expect(bias.energy > 1).toBe(true)
			expect(bias.water < 1).toBe(true)
		end)
	end)

	describe("Wild zone terrain", function()
		local FLAT = 100
		local SEA = 48
		local function flat(_x: number, _z: number): number
			return FLAT
		end
		local function zoneOf(id: string): Rules.Placed
			return { id = id, def = W.zones[id], x = 128, z = -256, biome = "grasslands" }
		end

		it("every zone shapes its ground, within its budget", function()
			for _, id in W.ids do
				local ops = Rules.terrainOps(zoneOf(id), 1337, flat, SEA)
				if #ops == 0 or #ops > W.maxOpsPerZone then
					error(string.format("%s has %d terrain ops", id, #ops))
				end
			end
		end)
		it("every op is the same on every server, and has a unique id", function()
			for _, id in W.ids do
				local a = Rules.terrainOps(zoneOf(id), 1337, flat, SEA)
				local b = Rules.terrainOps(zoneOf(id), 1337, flat, SEA)
				expect(a).toEqual(b)
				local seen: { [string]: boolean } = {}
				for _, op in a do
					expect(seen[op.i]).toBe(nil)
					seen[op.i] = true
				end
			end
		end)
		it("every op is marked as generated, so saved edits stay on top of it", function()
			for _, id in W.ids do
				for _, op in Rules.terrainOps(zoneOf(id), 1337, flat, SEA) do
					expect(op.c).toBe(true)
				end
			end
		end)
		it("uses only real terrain materials", function()
			for _, id in W.ids do
				for _, op in Rules.terrainOps(zoneOf(id), 1337, flat, SEA) do
					expect((Enum.Material :: any)[op.m] ~= nil).toBe(true)
					if op.f then
						expect((Enum.Material :: any)[op.f] ~= nil).toBe(true)
					end
				end
			end
		end)
		it("stays inside the zone", function()
			for _, id in W.ids do
				local zone = zoneOf(id)
				for _, op in Rules.terrainOps(zone, 1337, flat, SEA) do
					local reach = if op.k == "ball" then op.r else W.paintCell
					expect(math.sqrt((op.x - zone.x) ^ 2 + (op.z - zone.z) ^ 2) <= zone.def.radius + reach).toBe(true)
				end
			end
		end)
		it("paint squares line up with chunks, so each belongs to exactly one", function()
			for _, op in Rules.terrainOps(zoneOf("riot"), 1337, flat, SEA) do
				if op.k == "replace" then
					expect(#Rules.chunksOf(op, WorldGen.chunkOf)).toBe(1)
					expect(math.abs((op.x - W.paintCell / 2) % W.paintCell) < 0.001).toBe(true)
				end
			end
			expect((WorldConfig.CHUNK_SIZE % W.paintCell)).toBe(0)
		end)
		it("a ball runs in every chunk it reaches", function()
			local size = WorldConfig.CHUNK_SIZE
			local chunks = Rules.chunksOf({ k = "ball", x = size, z = 0, r = 20 }, WorldGen.chunkOf)
			expect(#chunks >= 2).toBe(true)
		end)
		it("no mound buries the heart", function()
			for _, id in W.ids do
				local zone = zoneOf(id)
				for _, op in Rules.terrainOps(zone, 1337, flat, SEA) do
					if op.k == "ball" and id ~= "vale" then
						expect(math.sqrt((op.x - zone.x) ^ 2 + (op.z - zone.z) ^ 2) - op.r >= W.heartClear - 0.01).toBe(true)
					end
				end
			end
		end)
		it("the Vale's islands hang clear of the ground, and one holds up the heart", function()
			local zone = zoneOf("vale")
			local underHeart = false
			for _, op in Rules.terrainOps(zone, 1337, flat, SEA) do
				if op.k == "ball" then
					expect(op.y - op.r > FLAT).toBe(true)
				end
				if op.m == "Grass" and op.x == zone.x and op.z == zone.z then
					underHeart = true
					local heartAt = FLAT + (zone.def.heartLift :: number) + 5
					expect(op.y + op.r <= heartAt).toBe(true)
				end
			end
			expect(underHeart).toBe(true)
		end)
		it("the Riot's ground burns best of all", function()
			expect(W.zones.riot.terrain.paint).toBe("LeafyGrass")
		end)
		it("never paints over the sea", function()
			local function under(_x: number, _z: number): number
				return SEA - 5
			end
			for _, op in Rules.terrainOps(zoneOf("shore"), 1337, under, SEA) do
				expect(op.k ~= "replace").toBe(true)
			end
		end)
	end)

	describe("Wild zone rumours", function()
		local zones = Rules.plan(1337, island(), TOWNS, {})

		it("every zone has a rumour with a place for the direction", function()
			for id, zone in W.zones do
				local ok = select(2, string.gsub(zone.rumor, "%%s", "")) == 1
				if not ok then
					error(id .. "'s rumour needs exactly one %s")
				end
			end
		end)
		it("tells you of the nearest zone you don't know", function()
			local zone = zones[1]
			local told = Rules.rumorFor(zones, {}, {}, zone.x + 1, zone.z, 0)
			expect(told).toBe(zone)
		end)
		it("never repeats what you've found or already heard", function()
			local found: { [string]: number } = {}
			local heard: { [string]: number } = {}
			for i, zone in zones do
				if i % 2 == 0 then
					found[zone.id] = 1
				else
					heard[zone.id] = 1
				end
			end
			expect(Rules.rumorFor(zones, found, heard, 0, 0, 0)).toBe(nil)
		end)
		it("not everyone knows", function()
			expect(Rules.rumorFor(zones, {}, {}, 0, 0, 0.99)).toBe(nil)
		end)
		it("points the right way", function()
			expect(Rules.bearing(0, 0, 100, 0)).toBe("east")
			expect(Rules.bearing(0, 0, 0, -100)).toBe("north")
			expect(Rules.bearing(0, 0, -100, 0)).toBe("west")
			expect(Rules.bearing(0, 0, 0, 100)).toBe("south")
		end)
	end)

	describe("Wild zone hearts", function()
		it("one harvest per zone per day", function()
			local harvests: { [string]: number } = {}
			local day = Rules.dayOf(1794000000)
			expect(Rules.canHarvest(harvests, "vale", day)).toBe(true)
			harvests.vale = day
			expect(Rules.canHarvest(harvests, "vale", day)).toBe(false)
			expect(Rules.canHarvest(harvests, "moor", day)).toBe(true)
			expect(Rules.canHarvest(harvests, "vale", day + 1)).toBe(true)
		end)
		it("a day is a real day", function()
			expect(Rules.dayOf(86400 * 5 + 10)).toBe(5)
			expect(Rules.dayOf(86400 * 5 - 10)).toBe(4)
		end)
		it("the same day rolls the same for the same player", function()
			local a = Rules.rollHarvest(W.zones.moor, Random.new(42))
			local b = Rules.rollHarvest(W.zones.moor, Random.new(42))
			expect(a).toEqual(b)
		end)
		it("relics stay rare", function()
			for _, zone in W.zones do
				for _, entry in zone.harvest do
					if entry.item == "time_relic" or entry.item == "gravity_relic" then
						expect(entry.chance <= 0.05).toBe(true)
					end
				end
			end
		end)
	end)
end
