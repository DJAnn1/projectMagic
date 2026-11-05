--!strict
-- Unit specs for functional buildings (docs/Buildings.md): floors, doors, interactables and
-- interior volumes from BuildingGenerator; the two-inventory transaction; recipes; seeded
-- container loot; access rules. Buildings are built detached (never parented to workspace).

local CollectionService = game:GetService("CollectionService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Interactables = require(Shared.World.Interactables)
local Recipes = require(Shared.Items.Data.Recipes)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local Server = ServerScriptService.Server
local BuildingGenerator = require(Server.World.BuildingGenerator)
local SettlementStyles = require(Server.World.SettlementStyles)
local FoundationBuilder = require(Server.World.FoundationBuilder)
local Inventory = require(Server.Items.Inventory)
local ContainerLoot = require(Server.Interact.ContainerLoot)
local Access = require(Server.Interact.Access)
local Lamps = require(Server.Interact.Lamps)
local Books = require(Server.Interact.Data.Books)
local FurnitureModels = require(Shared.World.FurnitureModels)
local HousingService = require(Server.Services.HousingService)

local function build(kind: string, culture: string?, seed: number?): Model
	local fp = SettlementStyles.footprints[kind]
	local model = BuildingGenerator.build({
		kind = kind, cframe = CFrame.new(10, 50, -20) * CFrame.Angles(0, math.rad(35), 0), w = fp.w, d = fp.d, seed = seed or 11,
		culture = culture or "wayfarer", name = "Spec_" .. kind, settlementId = "settlement_t", lotId = "settlement_t_L07",
	})
	return model :: Model
end

local function interactables(model: Model): { [string]: number }
	local counts: { [string]: number } = {}
	for _, d in model:GetDescendants() do
		if CollectionService:HasTag(d, "Interactable") then
			local kind = d:GetAttribute("Interactable") :: string
			counts[kind] = (counts[kind] or 0) + 1
		end
	end
	return counts
end

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	describe("Building floors and interiors", function()
		it("every roofed building has a collidable floor over its whole interior, flush with the foundation", function()
			for _, kind in { "house_small", "house_medium", "house_large", "smithy", "tavern", "magic_school" } do
				for culture in SettlementStyles.cultures do
					local m = build(kind, culture)
					local floor = m:FindFirstChild("Floor") :: BasePart
					local size = m:GetAttribute("InteriorSize") :: Vector3
					local cf = m:GetAttribute("InteriorCFrame") :: CFrame
					expect(if floor then true else kind).toBe(true)
					expect(floor.CanCollide).toBe(true)
					expect(CollectionService:HasTag(floor, "BuildingFloor")).toBe(true)
					expect(floor.Size.X >= size.X and floor.Size.Z >= size.Z or kind).toBe(true)
					local floorTop = (floor.CFrame * CFrame.new(0, floor.Size.Y / 2, 0)).Position.Y
					local interiorBottom = (cf * CFrame.new(0, -size.Y / 2, 0)).Position.Y
					expect(math.abs(floorTop - interiorBottom) < 0.2 or string.format("%s/%s floor %.2f interior %.2f", kind, culture, floorTop, interiorBottom)).toBe(true)
					local foundation = m:FindFirstChild("Foundation") :: BasePart
					local foundationTop = (foundation.CFrame * CFrame.new(0, foundation.Size.Y / 2, 0)).Position.Y
					expect(floorTop >= foundationTop and floorTop - foundationTop < 0.1).toBe(true)
					expect(size.Y >= 8).toBe(true)
					m:Destroy()
				end
			end
		end)

		it("keeps the floor slab thick and clear of the foundation terrain (no grass through floors)", function()
			-- The terrain FoundationBuilder fills stops FILL_DROP below the lot level; the slab's
			-- bottom must sit above that, and both modules must agree on the floor heights.
			expect(math.abs(FoundationBuilder.FLOOR_TOP - BuildingGenerator.FLOOR_TOP) < 1e-6).toBe(true)
			expect(math.abs(FoundationBuilder.FLOOR_BOTTOM - BuildingGenerator.FLOOR_BOTTOM) < 1e-6).toBe(true)
			expect(BuildingGenerator.FLOOR_BOTTOM > -FoundationBuilder.FILL_DROP + 0.5).toBe(true)
			expect(BuildingGenerator.FLOOR_TOP >= 1 and BuildingGenerator.FLOOR_TOP <= 2).toBe(true)
			for _, kind in { "house_small", "house_medium", "house_large", "smithy", "tavern", "barn", "magic_school", "watchtower" } do
				local m = build(kind)
				local floor = m:FindFirstChild("Floor") :: BasePart?
				if floor then
					expect(floor.Size.Y >= 1 or kind).toBe(true)
					local lot = m:GetAttribute("LotCFrame") :: CFrame
					local bottom = lot:PointToObjectSpace((floor.CFrame * CFrame.new(0, -floor.Size.Y / 2, 0)).Position).Y
					expect(math.abs(bottom - BuildingGenerator.FLOOR_BOTTOM) < 0.01 or string.format("%s floor bottom %.2f", kind, bottom)).toBe(true)
				end
				m:Destroy()
			end
		end)

		it("gives every doorway walkable steps from the yard up to the threshold", function()
			for _, kind in { "house_small", "house_medium", "house_large", "smithy", "tavern", "barn", "magic_school", "watchtower", "shrine" } do
				local m = build(kind)
				local lot = m:GetAttribute("LotCFrame") :: CFrame
				local tops: { number } = {}
				for _, d in m:GetChildren() do
					if d:IsA("BasePart") and string.sub(d.Name, 1, 4) == "Step" then
						table.insert(tops, lot:PointToObjectSpace((d.CFrame * CFrame.new(0, d.Size.Y / 2, 0)).Position).Y)
					end
				end
				table.sort(tops)
				expect(#tops > 0 or kind).toBe(true)
				local previous = BuildingGenerator.GROUND_Y
				for _, top in tops do
					expect(top - previous <= BuildingGenerator.STEP_RISE + 0.01 or string.format("%s step rises %.2f", kind, top - previous)).toBe(true)
					previous = top
				end
				if kind ~= "shrine" then
					local floorTop = BuildingGenerator.FLOOR_TOP
					expect(floorTop - previous <= 0.1 or string.format("%s threshold %.2f below the floor", kind, floorTop - previous)).toBe(true)
				end
				m:Destroy()
			end
		end)

		it("reaches the plinth down to the lowest ground on a sloping lot", function()
			local fp = SettlementStyles.footprints.house_small
			local flatModel = build("house_small")
			local sloped = BuildingGenerator.build({
				kind = "house_small", cframe = CFrame.new(10, 50, -20), w = fp.w, d = fp.d, seed = 11, drop = 5,
				culture = "wayfarer", name = "Spec_slope", settlementId = "settlement_t", lotId = "settlement_t_L08",
			}) :: Model
			local function bottomOf(m: Model): number
				local f = m:FindFirstChild("Foundation") :: BasePart
				local lot = m:GetAttribute("LotCFrame") :: CFrame
				return lot:PointToObjectSpace((f.CFrame * CFrame.new(0, -f.Size.Y / 2, 0)).Position).Y
			end
			expect(bottomOf(flatModel) <= -2 + 1e-3).toBe(true)
			expect(bottomOf(sloped) <= -6 + 1e-3).toBe(true)
			flatModel:Destroy()
			sloped:Destroy()
		end)
	end)

	describe("Doors", function()
		it("houses get a closed, solid door with poses, lock state and the lot as key", function()
			local m = build("house_medium")
			local door = m:FindFirstChild("Door") :: BasePart
			expect(CollectionService:HasTag(door, "Door")).toBe(true)
			expect(door.CanCollide).toBe(true)
			expect(door:GetAttribute("Interactable")).toBe("door")
			expect(door:GetAttribute("KeyId")).toBe("settlement_t_L07")
			local closed = door:GetAttribute("ClosedCFrame") :: CFrame
			local open = door:GetAttribute("OpenCFrame") :: CFrame
			expect((door.Position - closed.Position).Magnitude < 1e-3).toBe(true)
			-- Open swings inward: toward the interior, which is behind the leaf's LookVector.
			expect((open.Position - closed.Position):Dot(-closed.LookVector) > 0.5).toBe(true)
			expect(typeof(door:GetAttribute("Locked"))).toBe("boolean")
			m:Destroy()
		end)
		it("open-fronted buildings (the smithy) have no door leaf", function()
			local m = build("smithy")
			expect(m:FindFirstChild("Door")).toBe(nil)
			m:Destroy()
		end)
		it("lock state is seeded: the same lot always locks the same way", function()
			local a, b = build("house_small", "wayfarer", 99), build("house_small", "wayfarer", 99)
			expect((a:FindFirstChild("Door") :: BasePart):GetAttribute("Locked")).toBe((b:FindFirstChild("Door") :: BasePart):GetAttribute("Locked"))
			a:Destroy()
			b:Destroy()
		end)
	end)

	describe("Interactables", function()
		it("houses have a bed per NPC home, storage and a door, all with deterministic ids", function()
			for _, kind in { "house_small", "house_medium", "house_large" } do
				local m = build(kind)
				local counts = interactables(m)
				local homes = 0
				for _, d in m:GetDescendants() do
					if d:IsA("Attachment") and CollectionService:HasTag(d, "NPCHome") then
						homes += 1
					end
				end
				expect((counts.bed or 0) >= homes or kind).toBe(true)
				expect((counts.chest or 0) >= 1 or kind).toBe(true)
				expect(counts.door).toBe(1)
				local ids: { [string]: boolean } = {}
				for _, d in m:GetDescendants() do
					local id = d:GetAttribute("InteractId")
					if typeof(id) == "string" then
						expect(ids[id]).toBe(nil)
						ids[id] = true
						expect(string.sub(id, 1, 16)).toBe("settlement_t_L07")
					end
				end
				m:Destroy()
			end
		end)
		it("the smithy has a forge station and a crate", function()
			local m = build("smithy")
			local counts = interactables(m)
			expect(counts.forge).toBe(1)
			expect(counts.crate).toBe(1)
			m:Destroy()
		end)
		it("every tagged kind exists in the registry", function()
			for _, kind in { "house_small", "house_medium", "house_large", "smithy", "tavern", "market_stall", "magic_school", "barn" } do
				local m = build(kind)
				for k in interactables(m) do
					expect(Interactables[k] ~= nil or k).toBe(true)
				end
				m:Destroy()
			end
		end)
		it("bed seats never seat anyone on touch", function()
			local m = build("house_large")
			for _, d in m:GetDescendants() do
				if d:IsA("Seat") then
					expect(d.CanTouch).toBe(false)
					expect(d.CanCollide).toBe(false)
				end
			end
			m:Destroy()
		end)
	end)

	describe("Containers and crafting data", function()
		it("container loot is seeded", function()
			local a, ca = ContainerLoot.roll(1337, "x:chest1", "household", 1)
			local b, cb = ContainerLoot.roll(1337, "x:chest1", "household", 1)
			local c = ContainerLoot.roll(1337, "x:chest1", "household", 2)
			expect(a).toEqual(b)
			expect(ca).toBe(cb)
			expect(#a >= 1).toBe(true)
			local _ = c
		end)
		it("a transfer that copies a uid into both inventories rolls back both", function()
			local player, chest = Inventory.new(), Inventory.new()
			chest.cap = 8
			chest.slots["1"] = { i = "oak_staff", u = "c.1" }
			local ok, reason = Inventory.transactMany({ player, chest }, function(p, c)
				p.slots["1"] = table.clone(c.slots["1"]) -- forgot to remove it from the chest
				return true, nil
			end)
			expect(ok).toBe(false)
			expect(string.find(reason :: string, "two inventories", 1, true) ~= nil).toBe(true)
			expect(player.slots["1"]).toBe(nil)
			expect(chest.slots["1"].u).toBe("c.1")
		end)
		it("a container's capacity is fixed", function()
			local chest = Inventory.new()
			chest.cap = 2
			expect(Inventory.capacity(chest)).toBe(2)
			Inventory.add(chest, { i = "torch" }, "c")
			Inventory.add(chest, { i = "torch" }, "c")
			local added = Inventory.add(chest, { i = "torch" }, "c")
			expect(added).toBe(0)
		end)
		it("tag ingredients spend any matching items, all or nothing", function()
			local inv = Inventory.new()
			inv.slots["1"] = { i = "iron_ingot", n = 2 }
			local isIngot = function(def: any)
				return table.find(def.tags, "metal_ingot") ~= nil
			end
			expect(Inventory.removeMatching(inv, isIngot, 3)).toBe(false)
			expect(Inventory.countOf(inv, "iron_ingot")).toBe(2)
			expect(Inventory.removeMatching(inv, isIngot, 2)).toBe(true)
			expect(Inventory.countOf(inv, "iron_ingot")).toBe(0)
		end)
		it("every recipe names real items, and the forge has one", function()
			local forge = 0
			for _, r in Recipes.list do
				expect(ItemDatabase.get(r.output.item) ~= nil or r.id).toBe(true)
				if r.station == "forge" then
					forge += 1
				end
			end
			expect(forge > 0).toBe(true)
		end)
	end)

	describe("Functional rooms", function()
		it("every building kind gets the interactables it promises", function()
			local expected: { [string]: { string } } = {
				house_small = { "lamp", "bookshelf", "bed", "chest", "door" },
				house_medium = { "lamp", "wardrobe", "bed", "chest", "door", "bookshelf" },
				house_large = { "lamp", "wardrobe", "loom", "bed", "chest", "door", "hearth", "fireplace" },
				tavern = { "lamp", "notice_board", "hearth", "fireplace", "barrel", "chest", "door" },
				barn = { "workbench", "loom", "crate" },
				magic_school = { "alchemy_table", "enchanting_desk", "dummy", "mat", "bookshelf", "pedestal" },
				shrine = { "ward_stone", "mat" },
				well = { "well" },
				smithy = { "forge", "crate" },
			}
			for kind, kinds in expected do
				local m = build(kind)
				local counts = interactables(m)
				for _, k in kinds do
					expect(counts[k] ~= nil or (kind .. " lacks " .. k)).toBe(true)
				end
				m:Destroy()
			end
		end)
		it("lights start off and fireplaces start cold", function()
			local m = build("tavern")
			for _, d in m:GetDescendants() do
				local kind = d:GetAttribute("Interactable")
				if kind == "lamp" or kind == "fireplace" then
					expect(d:GetAttribute("Lit")).toBe(false)
					local light = d:FindFirstChildOfClass("PointLight")
					expect(light ~= nil and light.Enabled == false).toBe(true)
				end
			end
			m:Destroy()
		end)
		it("the training dummy is a damageable character that can't die", function()
			local m = build("magic_school")
			local dummy = m:FindFirstChild("TrainingDummy") :: Model
			expect(if dummy then true else false).toBe(true)
			expect(dummy:FindFirstChildOfClass("Humanoid") ~= nil).toBe(true)
			expect(dummy:FindFirstChild("HumanoidRootPart") ~= nil).toBe(true)
			local pedestal = m:FindFirstChild("Pedestal") :: BasePart
			expect(typeof(pedestal:GetAttribute("Domain"))).toBe("string")
			m:Destroy()
		end)
		it("stools and benches carry NPC seat anchors; the lot frame is recorded", function()
			for _, kind in { "house_medium", "tavern", "magic_school" } do
				local m = build(kind)
				local seats = 0
				for _, d in m:GetDescendants() do
					if d:IsA("Attachment") and CollectionService:HasTag(d, "NPCSeat") then
						seats += 1
					end
				end
				expect(seats > 0 or kind).toBe(true)
				expect(typeof(m:GetAttribute("LotCFrame"))).toBe("CFrame")
				m:Destroy()
			end
		end)
	end)

	describe("Lamps", function()
		it("night runs from 19:00 to 06:30 and belongs to the evening it began", function()
			expect(Lamps.phase(20, 5)).toBe("night:5")
			expect(Lamps.phase(3, 6)).toBe("night:5")
			expect(Lamps.phase(12, 6)).toBe("day:6")
		end)
		it("lights only at night, in occupied buildings, near players", function()
			expect(Lamps.wanted(true, true, true)).toBe(true)
			expect(Lamps.wanted(false, true, true)).toBe(false)
			expect(Lamps.wanted(true, false, true)).toBe(false)
			expect(Lamps.wanted(true, true, false)).toBe(false)
		end)
	end)

	describe("Furniture, books and stations", function()
		it("every furniture item has a model whose part count matches its budget info", function()
			for _, id in ItemDatabase.ids do
				local def = ItemDatabase.get(id) :: any
				local shape = def.data and def.data.furniture
				if shape then
					expect(FurnitureModels.has(shape) or id).toBe(true)
					local model = FurnitureModels.build(shape, def.color)
					local parts = 0
					for _, d in model:GetDescendants() do
						if d:IsA("BasePart") then
							parts += 1
						end
					end
					expect(parts).toBe(FurnitureModels.info(shape).parts)
					model:Destroy()
				end
			end
		end)
		it("every station has recipes, and every recipe's station exists", function()
			local stations: { [string]: boolean } = {}
			for _, def in Interactables do
				if def.station then
					stations[def.station.id] = true
				end
			end
			local used: { [string]: boolean } = {}
			for _, r in Recipes.list do
				expect(stations[r.station] or r.id).toBe(true)
				used[r.station] = true
			end
			for id in stations do
				expect(used[id] or ("no recipes for " .. id)).toBe(true)
			end
		end)
		it("homes stock common primers; schools the whole library", function()
			expect(#Books.common >= 5).toBe(true)
			expect(#Books.list > #Books.common).toBe(true)
		end)
		it("furniture must fit inside the rooms", function()
			local m = build("house_medium")
			local cf = m:GetAttribute("InteriorCFrame") :: CFrame
			local size = m:GetAttribute("InteriorSize") :: Vector3
			expect(HousingService.fits(m, cf, Vector3.new(2, 2, 2))).toBe(true)
			expect(HousingService.fits(m, cf * CFrame.new(size.X / 2, 0, 0), Vector3.new(2, 2, 2))).toBe(false)
			m:Destroy()
		end)
	end)

	describe("Access", function()
		it("private homes are off-limits, public buildings and your own home aren't", function()
			local fakePlayer: any = { UserId = 42, GetAttribute = function()
				return nil
			end }
			local home = build("house_small")
			local smithy = build("smithy")
			expect(home:GetAttribute("Access")).toBe("private")
			expect(Access.permits(fakePlayer, home)).toBe(false)
			expect(Access.permits(fakePlayer, smithy)).toBe(true)
			home:SetAttribute("OwnerUserId", 42)
			expect(Access.permits(fakePlayer, home)).toBe(true)
			expect(Access.theftSeverity(0)).toBe(1)
			expect(Access.theftSeverity(10000)).toBe(Access.MAX_THEFT_SEVERITY)
			home:Destroy()
			smithy:Destroy()
		end)
	end)
end
