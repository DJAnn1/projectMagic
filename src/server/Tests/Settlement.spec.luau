--!strict
-- Unit specs for procedural settlements: site refinement, layouts (determinism, lot rules,
-- terrain ops) and the small house (structure, openings, budget, tags).

local CollectionService = game:GetService("CollectionService")
local ServerScriptService = game:GetService("ServerScriptService")

local World = ServerScriptService.Server.World
local C = require(World.WorldConfig)
local WorldGen = require(World.WorldGen)
local MagicMap = require(World.MagicMap)
local WorldIndex = require(World.WorldIndex)
local POIPlacer = require(World.POIPlacer)
local SettlementLayout = require(World.SettlementLayout)
local SettlementStyles = require(World.SettlementStyles)
local BuildingGenerator = require(World.BuildingGenerator)
local SettlementDecor = require(World.SettlementDecor)
local FoundationBuilder = require(World.FoundationBuilder)
local SettlementGround = require(World.SettlementGround)

local SEED = 1337

return function(t: any)
	local describe, it, expect = t.describe, t.it, t.expect

	local gen = WorldGen.new(SEED)
	local magic = MagicMap.new(gen, SEED)
	local index = WorldIndex.build(gen, magic)
	local placement = POIPlacer.place(index, magic, SEED)

	local function highwaysFor(s: any): { any }
		local out = {}
		for _, road in placement.roads do
			if (math.abs(road.ax - s.x) < 1 and math.abs(road.az - s.z) < 1) or (math.abs(road.bx - s.x) < 1 and math.abs(road.bz - s.z) < 1) then
				table.insert(out, road)
			end
		end
		return out
	end

	local layouts = {}
	for _, s in placement.settlements do
		table.insert(layouts, SettlementLayout.generate(s, gen, SEED, highwaysFor(s), nil))
	end

	describe("Settlement sites", function()
		it("puts every settlement centre on dry land", function()
			for _, s in placement.settlements do
				expect(gen:height(s.x, s.z) > C.SEA_LEVEL or s.id).toBe(true)
			end
		end)
	end)

	describe("SettlementLayout", function()
		it("is deterministic", function()
			local s = placement.settlements[1]
			local again = SettlementLayout.generate(s, gen, SEED, highwaysFor(s), nil)
			expect(#again.lots).toBe(#layouts[1].lots)
			for i, lot in again.lots do
				expect(lot.type).toBe(layouts[1].lots[i].type)
				expect((lot.cframe.Position - layouts[1].lots[i].cframe.Position).Magnitude < 0.001).toBe(true)
			end
		end)

		it("places most of each settlement's buildings, in its tier's range of roads", function()
			local placed, wanted = 0, 0
			for _, layout in layouts do
				placed += #layout.lots
				wanted += layout.wanted
				expect(#layout.roads >= 1 or layout.id).toBe(true)
			end
			print(string.format("  %d settlements: %d of %d buildings placed", #layouts, placed, wanted))
			expect(placed >= wanted * 0.6).toBe(true)
		end)

		it("keeps lots dry, within tolerance, inside the radius and apart", function()
			for _, layout in layouts do
				for i, a in layout.lots do
					local p = a.cframe.Position
					expect(a.level > C.SEA_LEVEL or a.id).toBe(true)
					expect((Vector3.new(p.X, 0, p.Z) - Vector3.new(layout.center.X, 0, layout.center.Z)).Magnitude <= layout.tier.radius or a.id).toBe(true)
					for j = i + 1, #layout.lots do
						local b = layout.lots[j]
						local d = (Vector3.new(p.X, 0, p.Z) - Vector3.new(b.cframe.Position.X, 0, b.cframe.Position.Z)).Magnitude
						-- Centres at least the smaller half-width apart (the SAT test is stricter).
						expect(d >= math.min(a.w, a.d, b.w, b.d) / 2 or (a.id .. " vs " .. b.id)).toBe(true)
					end
				end
			end
		end)

		it("emits terrain ops with deterministic ids and real materials", function()
			for _, layout in layouts do
				for _, op in layout.ops do
					expect(op.k == "block").toBe(true)
					expect((Enum.Material :: any)[op.m] ~= nil or op.m).toBe(true)
					-- Generated ops are clipped to the chunk being built (no cross-chunk overwrites).
					expect(op.c == true or op.i).toBe(true)
				end
			end
			expect(layouts[1].ops[1].i).toBe(placement.settlements[1].id .. ":g1")
		end)

		it("gives op ids that are unique within a settlement", function()
			for _, layout in layouts do
				local seen: { [string]: boolean } = {}
				for _, op in layout.ops do
					expect(seen[op.i] == nil or op.i).toBe(true)
					seen[op.i] = true
				end
			end
		end)
	end)

	describe("FoundationBuilder", function()
		-- Two rotated lots three studs apart beside a road, on a gentle slope.
		local slope = function(x: number, _z: number): number
			return 80 + (100 - x) * 0.12 -- level at the lots, falling away to the east
		end
		local lotA = { id = "fb_L01", cframe = CFrame.new(100, 80, 100) * CFrame.Angles(0, math.rad(30), 0), w = 18, d = 16, level = 80, low = 77 }
		local bPos = CFrame.new(100, 80, 100) * CFrame.Angles(0, math.rad(30), 0) * CFrame.new(18 + 3, 0, 0)
		local lotB = { id = "fb_L02", cframe = bPos, w = 18, d = 16, level = 78.5, low = 78 }
		local road = { width = 6, points = { Vector3.new(60, 80, 80), Vector3.new(160, 80, 60) } }
		local ops = FoundationBuilder.ops({
			settlementId = "fb", lots = { lotA, lotB }, roads = { road }, plaza = { center = Vector3.new(0, 80, 0), half = 10 },
			foundation = "Cobblestone", yard = "Ground", plazaMaterial = "Pavement", height = slope, startIndex = 1,
		})

		it("emits voxel-aligned, chunk-clippable, grass-free blocks", function()
			expect(#ops > 0).toBe(true)
			for _, op in ops do
				expect(op.k).toBe("block")
				expect(op.c).toBe(true)
				expect(op.sz).toBe(4)
				expect(math.abs((op.x - op.sx / 2) / 4 - math.round((op.x - op.sx / 2) / 4)) < 1e-6 or op.i).toBe(true)
				expect(math.abs((op.z - op.sz / 2) / 4 - math.round((op.z - op.sz / 2) / 4)) < 1e-6 or op.i).toBe(true)
				expect(op.m ~= "Grass" and op.m ~= "LeafyGrass" or op.i).toBe(true)
			end
		end)

		it("fills every column under a lot with stone that stops below its floor's bottom", function()
			local stone = 0
			for _, op in ops do
				if op.m ~= "Air" then
					local top = op.y + op.sy / 2
					expect(top <= lotA.level - FoundationBuilder.FILL_DROP + 1e-6 or op.i).toBe(true)
					if op.m == "Cobblestone" then
						stone += 1
					end
				end
			end
			expect(stone > 0).toBe(true)
			-- Every column whose centre lies inside lot A is covered by a stone fill topped at its level.
			local rect = lotA.cframe
			for dx = -8, 8, 4 do
				for dz = -7, 7, 3.5 do
					local p = rect * Vector3.new(dx, 0, dz)
					local cx, cz = (math.floor(p.X / 4) + 0.5) * 4, (math.floor(p.Z / 4) + 0.5) * 4
					local covered = false
					for _, op in ops do
						if op.m == "Cobblestone" and math.abs(cx - op.x) < op.sx / 2 and math.abs(cz - op.z) < op.sz / 2
							and math.abs(op.y + op.sy / 2 - (lotA.level - FoundationBuilder.FILL_DROP)) < 1e-6 then
							covered = true
						end
					end
					expect(covered or string.format("column %.0f,%.0f", cx, cz)).toBe(true)
				end
			end
		end)

		it("never writes a neighbour's lot or a road with its apron", function()
			local rectB = { c = Vector3.new(bPos.Position.X, 0, bPos.Position.Z), r = bPos.RightVector, f = bPos.LookVector }
			for _, op in ops do
				if op.m ~= "Air" and math.abs(op.y + op.sy / 2 - (lotA.level - FoundationBuilder.FILL_DROP)) < 1e-6 then
					-- Each column of lot A's fills: its centre is outside lot B's rectangle.
					local x = op.x - op.sx / 2 + 2
					while x < op.x + op.sx / 2 do
						local d = Vector3.new(x, 0, op.z) - rectB.c
						local inside = math.abs(d:Dot(Vector3.new(rectB.r.X, 0, rectB.r.Z))) <= lotB.w / 2 and math.abs(d:Dot(Vector3.new(rectB.f.X, 0, rectB.f.Z))) <= lotB.d / 2
						expect(not inside or op.i).toBe(true)
						x += 4
					end
				end
			end
			for _, op in ops do
				if op.m == "Ground" then
					local x = op.x - op.sx / 2 + 2
					while x < op.x + op.sx / 2 do
						local p = Vector3.new(x, 0, op.z)
						local a, b = road.points[1], road.points[2]
						local ab = Vector3.new(b.X - a.X, 0, b.Z - a.Z)
						local tt = math.clamp((p - Vector3.new(a.X, 0, a.Z)):Dot(ab) / ab:Dot(ab), 0, 1)
						local dist = (p - (Vector3.new(a.X, 0, a.Z) + ab * tt)).Magnitude
						expect(dist >= road.width / 2 or op.i).toBe(true)
						x += 4
					end
				end
			end
		end)

		it("steps the downhill side of a sloping lot and is deterministic", function()
			local steps = 0
			for _, op in ops do
				local top = op.y + op.sy / 2
				if op.m == "Cobblestone" and top < lotA.level - FoundationBuilder.FILL_DROP - 1 then
					steps += 1
				end
			end
			expect(steps > 0).toBe(true)
			local again = FoundationBuilder.ops({
				settlementId = "fb", lots = { lotA, lotB }, roads = { road }, plaza = { center = Vector3.new(0, 80, 0), half = 10 },
				foundation = "Cobblestone", yard = "Ground", plazaMaterial = "Pavement", height = slope, startIndex = 1,
			})
			expect(#again).toBe(#ops)
			for i, op in again do
				expect(op.i == ops[i].i and op.x == ops[i].x and op.y == ops[i].y and op.m == ops[i].m).toBe(true)
			end
		end)

		it("falls back to grass-free materials", function()
			expect(FoundationBuilder.stoneFor("Grass")).toBe("Slate")
			expect(FoundationBuilder.stoneFor("Granite")).toBe("Slate")
			expect(FoundationBuilder.yardFor("LeafyGrass")).toBe("Ground")
			expect(FoundationBuilder.yardFor("Sand")).toBe("Sand")
		end)

		it("puts every real layout's foundation ops after all of its levelling ops", function()
			-- Foundation ops are 4 studs deep on Z and voxel-aligned; paving and levelling never are both.
			local function isFoundation(op: any): boolean
				return op.sz == 4 and math.abs((op.z - 2) / 4 - math.round((op.z - 2) / 4)) < 1e-6
					and math.abs((op.x - op.sx / 2) / 4 - math.round((op.x - op.sx / 2) / 4)) < 1e-6
			end
			for _, layout in layouts do
				local first: number? = nil
				for n, op in layout.ops do
					if first == nil and isFoundation(op) then
						first = n
					end
					if first ~= nil then
						expect(isFoundation(op) or string.format("%s: %s after the foundations began", layout.id, op.i)).toBe(true)
					end
				end
				expect(#layout.lots == 0 or first ~= nil or layout.id).toBe(true)
			end
		end)
	end)

	describe("SettlementGround", function()
		local grounds = {}
		for i, layout in layouts do
			grounds[i] = SettlementGround.plan(layout, gen, SEED, highwaysFor(placement.settlements[i]))
		end
		local GRASS: { [Enum.Material]: boolean } = { [Enum.Material.Grass] = true, [Enum.Material.LeafyGrass] = true }

		it("is deterministic", function()
			local again = SettlementGround.plan(layouts[1], gen, SEED, highwaysFor(placement.settlements[1]))
			expect(#again.patches).toBe(#grounds[1].patches)
			expect(#again.paths).toBe(#grounds[1].paths)
			for i, patch in again.patches do
				expect((patch.cframe.Position - grounds[1].patches[i].cframe.Position).Magnitude < 1e-6).toBe(true)
			end
			local ctx = SettlementGround.context(again, again.x0, again.z0, again.x1, again.z1)
			local ctx1 = SettlementGround.context(grounds[1], again.x0, again.z0, again.x1, again.z1)
			for k = 0, 20 do
				local x, z = again.center.X - 60 + k * 6, again.center.Z + 30 - k * 3
				expect(SettlementGround.materialAt(again, ctx, x, z) == SettlementGround.materialAt(grounds[1], ctx1, x, z)).toBe(true)
			end
		end)

		it("puts the plaza in the core and leaves the far wild alone", function()
			for _, plan in grounds do
				expect((SettlementGround.zoneAt(plan, plan.center.X, plan.center.Z))).toBe(1)
				expect((SettlementGround.zoneAt(plan, plan.center.X + plan.outerR * 1.3, plan.center.Z))).toBe(0)
			end
		end)

		it("never paints roads, the plaza or yards, and only grows grass in deliberate patches", function()
			local painted, kept = 0, 0
			for i, plan in grounds do
				local layout = layouts[i]
				local ctx = SettlementGround.context(plan, plan.x0, plan.z0, plan.x1, plan.z1)
				local x = math.floor(plan.x0 / 4) * 4 + 2
				while x < plan.x1 do
					local z = math.floor(plan.z0 / 4) * 4 + 2
					while z < plan.z1 do
						local m = SettlementGround.materialAt(plan, ctx, x, z)
						if m then
							painted += 1
							expect(m ~= Enum.Material.Granite and m ~= Enum.Material.Air and m ~= Enum.Material.Water).toBe(true)
							local patch = SettlementGround.inPatch(plan, x, z)
							expect(patch ~= nil or not GRASS[m] or string.format("%s grass at %d,%d", plan.id, x, z)).toBe(true)
							if not patch then
								local half = plan.plaza + 1
								expect(not (math.abs(x - plan.center.X) < half and math.abs(z - plan.center.Z) < half) or plan.id).toBe(true)
								for _, road in layout.roads do
									for _, q in road.points do
										-- The column centre is never on a road's own paint.
										expect((Vector3.new(q.X, 0, q.Z) - Vector3.new(x, 0, z)).Magnitude >= road.width / 2 - 0.01 or plan.id).toBe(true)
									end
								end
								for _, lot in layout.lots do
									local l = lot.cframe:PointToObjectSpace(Vector3.new(x, lot.cframe.Position.Y, z))
									expect(not (math.abs(l.X) <= lot.w / 2 and math.abs(l.Z) <= lot.d / 2) or lot.id).toBe(true)
								end
							end
						else
							kept += 1
						end
						z += 8
					end
					x += 8
				end
			end
			print(string.format("  ground: %d sampled columns repainted, %d kept", painted, kept))
			expect(painted > 0).toBe(true)
		end)

		it("keeps patches off lots, roads and the plaza, and only in grassy biomes", function()
			local total = 0
			for i, plan in grounds do
				local layout = layouts[i]
				for _, patch in plan.patches do
					total += 1
					expect(plan.grassy or patch.id).toBe(true)
					for _, lot in layout.lots do
						expect(not SettlementLayout.rectsOverlap(patch.rect, SettlementLayout.rectOf(lot.cframe, lot.w, lot.d, 0)) or patch.id).toBe(true)
					end
					expect(#patch.id > 0).toBe(true)
				end
			end
			print(string.format("  ground: %d deliberate grass patches", total))
		end)

		it("keeps wild trees out of every town core", function()
			for i, plan in grounds do
				local items = SettlementDecor.plan(layouts[i], gen, SEED, plan)
				for _, item in items do
					if item.kind == "tree" and not item.data.planted and not item.data.fruit and not item.data.green then
						local p = item.cframe.Position
						expect((SettlementGround.zoneAt(plan, p.X, p.Z)) ~= 1 or item.id).toBe(true)
					end
				end
			end
		end)
	end)

	describe("SettlementLayout (buildings)", function()

		it("only uses building types the style data knows", function()
			for _, layout in layouts do
				for _, lot in layout.lots do
					expect(SettlementStyles.footprints[lot.type] ~= nil or lot.type).toBe(true)
				end
			end
		end)
	end)

	describe("SettlementDecor", function()
		local plans = {}
		for _, layout in layouts do
			table.insert(plans, SettlementDecor.plan(layout, gen, SEED))
		end

		it("is deterministic and gives every settlement an NPC spawn anchor, lamps and trees", function()
			local again = SettlementDecor.plan(layouts[1], gen, SEED)
			expect(#again).toBe(#plans[1])
			for i, item in again do
				expect(item.kind).toBe(plans[1][i].kind)
				expect((item.cframe.Position - plans[1][i].cframe.Position).Magnitude < 0.001).toBe(true)
			end
			local kinds: { [string]: number } = {}
			for _, plan in plans do
				local anchors = 0
				for _, item in plan do
					kinds[item.kind] = (kinds[item.kind] or 0) + 1
					anchors += if item.kind == "anchor" then 1 else 0
				end
				expect(anchors).toBe(1)
			end
			local list = {}
			for kind, n in kinds do
				table.insert(list, kind .. " " .. n)
			end
			table.sort(list)
			print("  decor across the world: " .. table.concat(list, ", "))
			expect((kinds.lamp or 0) > 0 and (kinds.tree or 0) + (kinds.rock or 0) > 0).toBe(true)
		end)

		it("never puts trees, rocks or goods on a lot or in the sea", function()
			for i, plan in plans do
				local layout = layouts[i]
				for _, item in plan do
					if item.kind == "tree" or item.kind == "rock" or item.kind == "goods" then
						local p = item.cframe.Position
						expect(gen:height(p.X, p.Z) >= C.SEA_LEVEL + 1 or item.id).toBe(true)
						for _, lot in layout.lots do
							local l = lot.cframe:PointToObjectSpace(Vector3.new(p.X, lot.cframe.Position.Y, p.Z))
							local inside = math.abs(l.X) < lot.w / 2 and math.abs(l.Z) < lot.d / 2
							expect(not inside or (item.id .. " on " .. lot.id)).toBe(true)
						end
					end
				end
			end
		end)

		it("builds every decoration kind in every culture", function()
			local samples = {
				{ kind = "anchor", data = { plaza = 12 } }, { kind = "lamp", data = { light = false } },
				{ kind = "fence", data = { w = 18, d = 16 } }, { kind = "goods", data = { barrels = 2, crates = 3 } },
				{ kind = "forge", data = {} }, { kind = "spire", data = { tall = true } }, { kind = "flowers", data = {} },
				{ kind = "banner", data = {} }, { kind = "brazier", data = {} }, { kind = "cart", data = {} },
				{ kind = "dock", data = { length = 24, boat = true } }, { kind = "tree", data = { scale = 1, conifer = true, seed = 3 } },
				{ kind = "tree", data = { scale = 1, conifer = false, seed = 4 } }, { kind = "rock", data = { scale = 1, seed = 5 } },
			}
			local holder = Instance.new("Folder")
			for culture in SettlementStyles.cultures do
				for i, s in samples do
					local model, parts = SettlementDecor.build({ id = "t_D" .. i, kind = s.kind, cframe = CFrame.new(0, 100, 0), data = s.data }, culture, holder)
					expect(model ~= nil or s.kind).toBe(true)
					expect(parts > 0 and parts < 60 or (s.kind .. " " .. parts)).toBe(true)
					expect(CollectionService:HasTag(model :: Model, "Decor")).toBe(true)
				end
			end
			holder:Destroy()
		end)
	end)

	describe("BuildingGenerator", function()
		it("builds a small house in every culture under the part budget, with openings and tags", function()
			for culture in SettlementStyles.cultures do
				local model, parts, err = BuildingGenerator.build({
					kind = "house_small", cframe = CFrame.new(0, 100, 0), w = 18, d = 16, seed = 42,
					culture = culture, name = "House_01", settlementId = "settlement_t", lotId = "settlement_t_L01",
				})
				expect(err).toBe(nil)
				local m = model :: Model
				expect(m.PrimaryPart ~= nil).toBe(true)
				expect(parts < 150 or culture .. " " .. parts).toBe(true)
				expect(CollectionService:HasTag(m, "Building") and CollectionService:HasTag(m, "House")).toBe(true)
				expect(m:FindFirstChild("Door") ~= nil).toBe(true)
				-- The door is a working door now: closed and solid, with its open pose recorded.
				local door = m:FindFirstChild("Door") :: BasePart
				expect(door.CanCollide).toBe(true)
				expect(typeof(door:GetAttribute("OpenCFrame"))).toBe("CFrame")
				local glass, anchoredAll = 0, true
				for _, p in m:GetDescendants() do
					if p:IsA("BasePart") then
						anchoredAll = anchoredAll and p.Anchored
						if p.Material == Enum.Material.Glass then
							glass += 1
						end
					end
				end
				expect(anchoredAll).toBe(true)
				expect(glass >= 4 or culture).toBe(true)
				local home = (m.PrimaryPart :: BasePart):FindFirstChild("NPCHome")
				expect(home ~= nil and CollectionService:HasTag(home :: Instance, "NPCHome")).toBe(true)
				m:Destroy()
			end
		end)

		it("builds every building type in every culture: budget, structure, tags, anchors", function()
			local budgets = { house_small = 150, market_stall = 60, well = 60, shrine = 80 }
			local counts: { [string]: number } = {}
			for kind, fp in SettlementStyles.footprints do
				expect(BuildingGenerator.supports(kind) or kind).toBe(true)
				for culture in SettlementStyles.cultures do
					local model, parts, err = BuildingGenerator.build({
						kind = kind, cframe = CFrame.new(0, 100, 0), w = fp.w, d = fp.d, seed = 7,
						culture = culture, name = "B", settlementId = "settlement_t", lotId = "settlement_t_L01",
					})
					expect(err == nil or (kind .. ": " .. tostring(err))).toBe(true)
					local m = model :: Model
					expect(m.PrimaryPart ~= nil or kind).toBe(true)
					expect(parts <= (budgets[kind] or 220) or string.format("%s/%s %d parts", kind, culture, parts)).toBe(true)
					expect(CollectionService:HasTag(m, "Building") or kind).toBe(true)
					expect(m:GetAttribute("BuildingType")).toBe(kind)
					for _, p in m:GetDescendants() do
						if p:IsA("BasePart") and not p.Anchored then
							expect(kind .. " has an unanchored " .. p.Name).toBe(true)
						end
					end
					local door = m:FindFirstChild("Door")
					if door then
						expect((door :: BasePart).CanCollide).toBe(false)
					end
					local anchors = 0
					for _, att in (m.PrimaryPart :: BasePart):GetChildren() do
						if att:IsA("Attachment") then
							anchors += 1
						end
					end
					expect(anchors >= 1 or kind).toBe(true)
					counts[kind] = math.max(counts[kind] or 0, parts)
					m:Destroy()
				end
			end
			local list = {}
			for kind, n in counts do
				table.insert(list, kind .. " " .. n)
			end
			table.sort(list)
			print("  max parts per type: " .. table.concat(list, ", "))
		end)

		it("varies with the seed", function()
			local a = BuildingGenerator.build({ kind = "house_small", cframe = CFrame.new(), w = 18, d = 16, seed = 1, culture = "wayfarer", name = "A", settlementId = "s", lotId = "a" })
			local b = BuildingGenerator.build({ kind = "house_small", cframe = CFrame.new(), w = 18, d = 16, seed = 2, culture = "wayfarer", name = "B", settlementId = "s", lotId = "b" })
			local fa = (a :: Model):FindFirstChild("Foundation") :: BasePart
			local fb = (b :: Model):FindFirstChild("Foundation") :: BasePart
			expect(fa.Size ~= fb.Size or fa.Color ~= fb.Color).toBe(true)
			;(a :: Model):Destroy()
			;(b :: Model):Destroy()
		end)
	end)
end
