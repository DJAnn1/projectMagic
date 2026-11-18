--!strict
--[[
	Places.spec: seeded place histories (docs/WorldPlaces.md stage 0). What matters most: every
	server tells the same history; a deep place fits its land (ice halls in the frostpeaks, forges in
	the vents); the data never points at a builder, fate or occupant that doesn't exist; and the
	lines people will say hold no digits and no unfilled {tokens}.
]]

local ServerScriptService = game:GetService("ServerScriptService")

local Server = ServerScriptService.Server
local PlaceHistory = require(Server.Places.PlaceHistory)
local Kinds = require(Server.Places.Data.PlaceKinds)
local POIRules = require(Server.World.POIRules)
local Flags = require(Server.Config.Flags)

local CONTEXT: PlaceHistory.Context = { town = { id = "settlement_1", name = "Glenhold", culture = "forgehold", distance = 900 }, density = 1 }

local function poi(id: string, poiType: string, biome: string): any
	return { id = id, type = poiType, biome = biome, hidden = false, x = 0, z = 0, radius = 40, grants = {} }
end

local function clean(text: string): boolean
	return string.find(text, "%d") == nil and string.find(text, "[{}]") == nil
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Place data", function()
		it("only names builders, fates and occupants that exist", function()
			local function checkPicks(list: { Kinds.Pick }, into: { [string]: any })
				expect(#list > 0).toBe(true)
				for _, p in list do
					expect(into[p.id] ~= nil).toBe(true)
				end
			end
			for _, def in Kinds.deep do
				checkPicks(def.builders, Kinds.builders)
				checkPicks(def.fates, Kinds.fates)
				expect(#def.names > 0).toBe(true)
				expect(def.depths[1] >= 1 and def.depths[2] >= def.depths[1]).toBe(true)
			end
			for _, site in Kinds.sites do
				checkPicks(site.builders or { { id = "old_ones", w = 1 } }, Kinds.builders)
				checkPicks(site.fates or { { id = "abandoned", w = 1 } }, Kinds.fates)
			end
			for _, fate in Kinds.fates do
				checkPicks(fate.occupants, Kinds.occupants)
				expect(#fate.says > 0).toBe(true)
			end
			expect((Flags :: any).places_enabled ~= nil).toBe(true)
		end)

		it("give every dungeon biome at least one deep kind", function()
			for _, rule in POIRules :: { any } do
				if rule.type == "dungeon" then
					for _, biome in rule.biomes do
						local total = 0
						for _, p in PlaceHistory.deepWeights(biome, CONTEXT) do
							total += p.w
						end
						expect(total > 0).toBe(true)
					end
				end
			end
		end)

		it("never make towns, wonders or hidden sites into places", function()
			expect(Kinds.siteFor("settlement") == nil).toBe(true)
			expect(Kinds.siteFor("singing_caverns") == nil).toBe(true)
			expect(Kinds.siteFor("shrine_void") ~= nil).toBe(true)
			local hidden = poi("m1", "dungeon", "swamp")
			hidden.hidden = true
			expect(PlaceHistory.of(1337, hidden, CONTEXT) == nil).toBe(true)
		end)
	end)

	describe("Place histories", function()
		it("are the same on every server, and differ between worlds", function()
			local a = PlaceHistory.of(1337, poi("poi_7", "dungeon", "mountains"), CONTEXT) :: PlaceHistory.History
			local b = PlaceHistory.of(1337, poi("poi_7", "dungeon", "mountains"), CONTEXT) :: PlaceHistory.History
			expect(a.name).toBe(b.name)
			expect(a.kind).toBe(b.kind)
			expect(a.fate).toBe(b.fate)
			expect(a.occupant).toBe(b.occupant)
			expect(a.rooms).toBe(b.rooms)
			local names: { [string]: boolean } = {}
			local count = 0
			for seed = 1, 30 do
				local h = PlaceHistory.of(seed, poi("poi_7", "dungeon", "mountains"), CONTEXT) :: PlaceHistory.History
				if not names[h.name] then
					names[h.name] = true
					count += 1
				end
			end
			expect(count >= 10).toBe(true)
		end)

		it("fit their land", function()
			local function mostCommon(biome: string): string
				local counts: { [string]: number } = {}
				for seed = 1, 60 do
					local h = PlaceHistory.of(seed, poi("p", "dungeon", biome), CONTEXT) :: PlaceHistory.History
					counts[h.kind] = (counts[h.kind] or 0) + 1
				end
				local best, n = "", -1
				for kind, c in counts do
					if c > n then
						best, n = kind, c
					end
				end
				return best
			end
			expect(mostCommon("frostpeaks")).toBe("ice_hall")
			expect(mostCommon("volcanic_highlands")).toBe("vent_forge")
			t.log("deep kinds: swamp " .. mostCommon("swamp") .. ", mountains " .. mostCommon("mountains"))
		end)

		it("hold words people can say, and sane numbers", function()
			local types = { "dungeon", "ruined_library", "hermit_tower", "academy", "mine", "shrine_energy" }
			local biomes = { "mountains", "badlands", "swamp", "deep_forest", "frostpeaks", "volcanic_highlands", "ruinlands" }
			for seed = 1, 25 do
				for _, poiType in types do
					for _, biome in biomes do
						local h = PlaceHistory.of(seed, poi("q" .. seed, poiType, biome), CONTEXT) :: PlaceHistory.History
						expect(clean(h.name)).toBe(true)
						for _, line in h.lines do
							expect(clean(line)).toBe(true)
						end
						expect(#h.lines >= 1).toBe(true)
						expect(h.danger >= 0 and h.danger <= 1).toBe(true)
						if h.size == "deep" then
							local def = Kinds.deepById[h.kind]
							expect(h.depths ~= nil and (h.depths :: number) >= def.depths[1] and (h.depths :: number) <= def.depths[2]).toBe(true)
							expect(h.rooms ~= nil and (h.rooms :: number) >= def.rooms[1] and (h.rooms :: number) <= def.rooms[2]).toBe(true)
						end
					end
				end
			end
		end)

		it("say ages in words", function()
			expect(PlaceHistory.ageSays(5)).toBe("not long ago")
			expect(PlaceHistory.ageSays(70)).toBe("in my grandparents' time")
			expect(PlaceHistory.ageSays(900)).toBe("before anyone kept records")
		end)
	end)
end
