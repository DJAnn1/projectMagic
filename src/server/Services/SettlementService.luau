--!strict
--[[
	SettlementService: procedural settlements in the live world.

	FLOW
	  POIPlacer chooses and refines the sites (SettlementSites) while the world index is built.
	  init   registers a generated-ops provider with WorldStateService: whenever a chunk is built,
	         the paving and levelling ops (SettlementLayout) of every settlement touching it are
	         applied with the chunk, BEFORE saved player edits. Nothing here is ever saved: it is
	         regenerated identically from the seed.
	  start  computes every layout in a Scheduler job (spread over frames), then logs the summary.
	         A chunk built before its settlement's layout is ready computes that one layout on
	         the spot (same result: layouts are pure).
	  ChunkBuilt  every lot whose centre lies in the new chunk gets its building (BuildingGenerator)
	         in a Scheduler job, a few per frame, under Workspace.Settlements.<SettlementName>.
	         Lots of kinds without a generator yet stay levelled and are counted as "planned".

	INTERIORS STAY CLEAR (the missing-floor fix, docs/Buildings.md §1): a lot's levelling op is
	bucketed only into the chunks it overlaps, but a street or a neighbouring lot's op can reach
	into it from a chunk the lot doesn't touch. When that chunk is built later, its ops are
	replayed and fill terrain back over the floor. So every building's interior box
	(InteriorCFrame / InteriorSize) is cleared to air when it's built AND again after every later
	chunk build near it. Not saved: it's re-derived on every server like the buildings.

	Buildings are Models with ModelStreamingMode = Atomic, so StreamingEnabled streams each one
	in and out whole. Terrain is still built on demand around players, so towns appear as people
	approach them; `buildsettlement` builds one at once.

	FOR THE NPC SYSTEM (NPCService assigns homes and workplaces from layout data, so it works for
	NPCs far from any player, before the buildings exist):
	  layoutFor(settlementId)        the layout (computed on demand; may yield outside jobs)
	  homes(settlementId)            house lots (and the tavern's room) with their bed counts
	  workplaces(settlementId)       lots that have an NPCWork anchor, with their kinds
	  anchor(lotId, name, slot?)     a named anchor's world position: the real Attachment once the
	                                 building exists, else a planned point inside the lot
	  spawnPoints(settlementId)      the plaza NPCSpawn points
	  setOwner(lotId, npcId)         OwnerNPCId (applied now, or when the building is built)
	  lotName(lotId)                 "House_03" etc.
	Topics.BuildingBuilt fires when a building appears, so NPCs re-target its real anchors.

	THE GROUND (docs/Settlements.md §5c): with each layout comes a SettlementGround plan (the town
mask, its materials, grass patches, desire paths). setGroundPass gives WorldStateService one
painter per settlement touching a chunk; it runs inside the chunk job after the generated ops and
before saved edits, rewriting surface materials in the mask. Decor uses the same plan (trees keep
out of the core, gardens get fences). Puddles (tag "Puddle") show while the weather is wet.

FOUNDATIONS ARE VERIFIED (docs/Settlements.md §5b): after a building is built, and again after
every later chunk build near it, FoundationBuilder.verify raycasts the terrain under its floor
and reads the voxels around it. Failures are logged once (`foundation_failed`, with the floor
top, the lot ground, the highest terrain and the counts), recovery is logged too
(`foundation_fixed`), and in Studio red markers show where (flag `foundation_markers`).
foundationReport(lotId) / verifyFoundation(model) serve buildingcheck and buildingaudit.

Admin (World): settlements · settlementinfo <settlement> · buildsettlement <settlement>
	Overlay: overlay lots (lot outlines by type, streets, failed lots in red)
]]

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Topics = require(Shared.Core.Topics)

local Server = script.Parent.Parent
local Scheduler = require(Server.Core.Scheduler)
local WorldGen = require(Server.World.WorldGen)
local WorldConfig = require(Server.World.WorldConfig)
local SettlementLayout = require(Server.World.SettlementLayout)
local SettlementStyles = require(Server.World.SettlementStyles)
local BuildingGenerator = require(Server.World.BuildingGenerator)
local SettlementDecor = require(Server.World.SettlementDecor)
local FoundationBuilder = require(Server.World.FoundationBuilder)
local SettlementGround = require(Server.World.SettlementGround)
local RunService = game:GetService("RunService")

local OP_MARGIN = 30 -- studs beyond a settlement's radius its ops may reach
local PUDDLE_INTERVAL = 15 -- seconds between puddle visibility updates
local PUDDLE_WET = 0.15 -- wetness above which puddles show
local BEDS: { [string]: number } = { house_small = 1, house_medium = 2, house_large = 3, tavern = 1 }
local WORKPLACES: { [string]: boolean } = {
	smithy = true, tavern = true, market_stall = true, watchtower = true, barn = true, magic_school = true, shrine = true,
}

local SettlementService = {
	name = "SettlementService",
	dependencies = { "WorldService", "WorldStateService", "AdminService" },
}

type Entry = {
	settlement: any,
	layout: SettlementLayout.Layout?,
	ground: SettlementGround.Plan?,
	computing: boolean,
	buckets: { [string]: { any } }, -- chunk key -> ops
	names: { [string]: string }, -- lot id -> building name
	built: { [string]: Model },
	parts: number,
	folder: Model?,
	decor: { SettlementDecor.Item },
	decorBuilt: { [string]: Model },
	decorParts: number,
}

local log: any = nil
local bus: any = nil
local flags: any = nil
local worldService: any = nil
local world: any = nil
local worldSeed = 0
local entries: { [string]: Entry } = {}
local order: { Entry } = {}
local totals = { buildings = 0, parts = 0 }
local foundations: { [string]: FoundationBuilder.Report } = {} -- lot id -> latest verification
local lotIndex: { [string]: { entry: Entry, lot: SettlementLayout.Lot } } = {}
local owners: { [string]: string } = {}
local root: Folder? = nil

local function chunkKey(cx: number, cz: number): string
	return cx .. "," .. cz
end

local function ensureEntries()
	if #order > 0 then
		return
	end
	for _, s in world:placement().settlements do
		local entry: Entry = { settlement = s, layout = nil, ground = nil, computing = false, buckets = {}, names = {}, built = {}, parts = 0, folder = nil, decor = {}, decorBuilt = {}, decorParts = 0 }
		entries[s.id] = entry
		table.insert(order, entry)
	end
end

local function highwaysFor(s: any): { any }
	local out = {}
	for _, road in world:placement().roads do
		if (math.abs(road.ax - s.x) < 1 and math.abs(road.az - s.z) < 1) or (math.abs(road.bx - s.x) < 1 and math.abs(road.bz - s.z) < 1) then
			table.insert(out, road)
		end
	end
	return out
end

-- Building names: <Kind>_<NN>, numbered per kind in lot order (deterministic).
local function nameLots(entry: Entry, layout: SettlementLayout.Layout)
	local counts: { [string]: number } = {}
	for _, lot in layout.lots do
		counts[lot.type] = (counts[lot.type] or 0) + 1
		local label = SettlementStyles.labels[lot.type] or lot.type
		entry.names[lot.id] = string.format("%s_%02d", label, counts[lot.type])
	end
end

local function bucketOps(entry: Entry, layout: SettlementLayout.Layout)
	for _, op in layout.ops do
		local hx, hz = op.sx / 2, op.sz / 2
		local cx0, cz0 = WorldGen.chunkOf(op.x - hx, op.z - hz)
		local cx1, cz1 = WorldGen.chunkOf(op.x + hx, op.z + hz)
		for cz = cz0, cz1 do
			for cx = cx0, cx1 do
				local key = chunkKey(cx, cz)
				entry.buckets[key] = entry.buckets[key] or {}
				table.insert(entry.buckets[key], op)
			end
		end
	end
end

-- The layout for a settlement, computed once (yields only inside a Scheduler job).
local function ensureLayout(entry: Entry): SettlementLayout.Layout
	while entry.computing do
		task.wait(0.05)
	end
	local existing = entry.layout
	if existing then
		return existing
	end
	entry.computing = true
	local ok, result = pcall(SettlementLayout.generate, entry.settlement, world:gen(), worldSeed, highwaysFor(entry.settlement), Scheduler.checkpoint)
	entry.computing = false
	if not ok then
		log:error("settlement_layout_failed", { settlement = entry.settlement.id, err = tostring(result) })
		local empty: any = { id = entry.settlement.id, name = entry.settlement.name, culture = entry.settlement.culture, size = entry.settlement.size,
			tier = SettlementStyles.tiers[entry.settlement.size], center = Vector3.new(entry.settlement.x, 0, entry.settlement.z), plaza = 0,
			roads = {}, lots = {}, failures = {}, wanted = 0, ops = {} }
		entry.layout = empty
		return empty
	end
	local layout: SettlementLayout.Layout = result
	nameLots(entry, layout)
	bucketOps(entry, layout)
	local groundOk, groundPlan = pcall(SettlementGround.plan, layout, world:gen(), worldSeed, highwaysFor(entry.settlement))
	if groundOk then
		entry.ground = groundPlan
	else
		log:error("settlement_ground_failed", { settlement = entry.settlement.id, err = tostring(groundPlan) })
	end
	local planned, decor = pcall(SettlementDecor.plan, layout, world:gen(), worldSeed, entry.ground)
	if planned then
		entry.decor = decor
	else
		log:error("settlement_decor_failed", { settlement = entry.settlement.id, err = tostring(decor) })
	end
	for _, lot in layout.lots do
		lotIndex[lot.id] = { entry = entry, lot = lot }
	end
	entry.layout = layout
	return layout
end

local function touches(s: any, cx: number, cz: number): boolean
	local ox, oz = WorldGen.chunkOrigin(cx, cz)
	local size = WorldConfig.CHUNK_SIZE
	local tier = SettlementStyles.tiers[s.size]
	local reach = (if tier then tier.radius else 120) + OP_MARGIN
	return s.x + reach >= ox and s.x - reach <= ox + size and s.z + reach >= oz and s.z - reach <= oz + size
end

-- Provider for WorldStateService: the generated ops for one chunk (settlements only).
local function opsForChunk(cx: number, cz: number): { any }
	ensureEntries()
	local out = {}
	for _, entry in order do
		if touches(entry.settlement, cx, cz) then
			ensureLayout(entry)
			for _, op in (entry.buckets[chunkKey(cx, cz)] or {}) :: { any } do
				table.insert(out, op)
			end
		end
	end
	return out
end

-- Provider for WorldStateService: one ground painter per settlement whose mask touches the chunk.
local function paintersForChunk(cx: number, cz: number): { (any) -> () }
	ensureEntries()
	local ox, oz = WorldGen.chunkOrigin(cx, cz)
	local size = WorldConfig.CHUNK_SIZE
	local out = {}
	for _, entry in order do
		if touches(entry.settlement, cx, cz) then
			ensureLayout(entry)
			local plan = entry.ground
			if plan and plan.x1 >= ox and plan.x0 <= ox + size and plan.z1 >= oz and plan.z0 <= oz + size then
				local gen = world:gen()
				table.insert(out, function(clip: any)
					SettlementGround.paint(plan, clip, gen, Scheduler.checkpoint)
				end)
			end
		end
	end
	return out
end

local function folderFor(entry: Entry): Model
	local existing = entry.folder
	if existing and existing.Parent then
		return existing
	end
	if not root or not root.Parent then
		local f = workspace:FindFirstChild("Settlements") or Instance.new("Folder")
		f.Name = "Settlements"
		f.Parent = workspace
		root = f :: Folder
	end
	local s = entry.settlement
	local name = s.name
	for _, other in order do
		if other ~= entry and other.settlement.name == name then
			name = s.name .. " (" .. s.id .. ")"
		end
	end
	local model = Instance.new("Model")
	model.Name = name
	model:SetAttribute("SettlementId", s.id)
	model:SetAttribute("Culture", s.culture)
	model:SetAttribute("Tier", SettlementStyles.tiers[s.size].label)
	model.Parent = root
	entry.folder = model
	return model
end

-- Clears terrain out of a building's interior volume (above the floor, inside the walls).
-- Returns false for buildings without one (stalls, wells).
local function clearInterior(model: Model): boolean
	local cf = model:GetAttribute("InteriorCFrame")
	local size = model:GetAttribute("InteriorSize")
	if typeof(cf) ~= "CFrame" or typeof(size) ~= "Vector3" then
		return false
	end
	workspace.Terrain:FillBlock(cf, size, Enum.Material.Air)
	return true
end

-- Verifies one building's foundation (FoundationBuilder.verify), keeps the report, logs a change
-- of state (first failure, or a recovery) and refreshes the Studio markers.
local function verifyFoundation(model: Model): FoundationBuilder.Report
	local report = FoundationBuilder.verify(model)
	local lotId = tostring(model:GetAttribute("LotId") or model.Name)
	local previous = foundations[lotId]
	foundations[lotId] = report
	if report.checked and not report.ok and (not previous or previous.ok) then
		log:warn("foundation_failed", {
			lot = lotId, building = model.Name, kind = model:GetAttribute("BuildingType"),
			floorTop = math.floor(report.floorTop * 100) / 100, ground = math.floor(report.ground * 100) / 100,
			terrainTop = if report.terrainTop then math.floor(report.terrainTop * 100) / 100 else nil,
			hits = #report.hits, rays = report.points, grass = report.grass,
		})
	elseif report.checked and report.ok and previous and not previous.ok then
		log:info("foundation_fixed", { lot = lotId, building = model.Name })
	end
	FoundationBuilder.flag(model, report, RunService:IsStudio() and flags ~= nil and flags.get("foundation_markers") == true)
	return report
end

-- Re-clears every built interior within reach of a chunk that was just built (its ops may have
-- filled terrain over a neighbouring building's floor), and re-verifies its foundation.
local INTERIOR_REACH = 24 -- studs: streets and lot margins that can spill across a chunk edge
local function reclearNear(cx: number, cz: number)
	local ox, oz = WorldGen.chunkOrigin(cx, cz)
	local size = WorldConfig.CHUNK_SIZE
	for _, entry in order do
		if touches(entry.settlement, cx, cz) then
			for _, model in entry.built do
				local cf = model:GetAttribute("InteriorCFrame")
				if typeof(cf) == "CFrame" and model.Parent then
					local p = cf.Position
					if p.X >= ox - INTERIOR_REACH - 20 and p.X <= ox + size + INTERIOR_REACH + 20
						and p.Z >= oz - INTERIOR_REACH - 20 and p.Z <= oz + size + INTERIOR_REACH + 20 then
						clearInterior(model)
						verifyFoundation(model)
					end
				end
			end
		end
	end
end

-- Builds the building on one lot (no-op if built or its kind has no generator yet).
local function buildLot(entry: Entry, lot: SettlementLayout.Lot): boolean
	if entry.built[lot.id] or not BuildingGenerator.supports(lot.type) then
		return false
	end
	local model, parts, err = BuildingGenerator.build({
		kind = lot.type,
		cframe = lot.cframe,
		w = lot.w,
		d = lot.d,
		seed = lot.seed,
		culture = entry.settlement.culture,
		name = entry.names[lot.id] or lot.id,
		settlementId = entry.settlement.id,
		lotId = lot.id,
		drop = lot.level - (lot.low or lot.level),
		path = entry.ground ~= nil and entry.ground.frontPaths[lot.id] == true,
		parent = folderFor(entry),
	})
	if not model then
		log:warn("building_failed", { lot = lot.id, err = err })
		return false
	end
	entry.built[lot.id] = model
	clearInterior(model)
	verifyFoundation(model)
	entry.parts += parts
	totals.buildings += 1
	totals.parts += parts
	local owner = owners[lot.id]
	if owner then
		model:SetAttribute("OwnerNPCId", owner)
	end
	bus:publish(Topics.BuildingBuilt, { lotId = lot.id, settlementId = entry.settlement.id, kind = lot.type })
	return true
end

-- Builds one decoration item (no-op if built). Decor lives in <Settlement>/Decor.
local function buildDecor(entry: Entry, item: SettlementDecor.Item): boolean
	if entry.decorBuilt[item.id] then
		return false
	end
	local settlementModel = folderFor(entry)
	local folder = settlementModel:FindFirstChild("Decor")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "Decor"
		folder.Parent = settlementModel
	end
	local model, parts = SettlementDecor.build(item, entry.settlement.culture, folder :: Instance)
	if not model then
		return false
	end
	entry.decorBuilt[item.id] = model
	entry.decorParts += parts
	totals.parts += parts
	return true
end

local function onChunkBuilt(payload: any)
	ensureEntries()
	local cx, cz = payload.cx, payload.cz
	reclearNear(cx, cz)
	local due: { { entry: Entry, lot: SettlementLayout.Lot } } = {}
	local decorDue: { { entry: Entry, item: SettlementDecor.Item } } = {}
	for _, entry in order do
		if touches(entry.settlement, cx, cz) then
			local layout = entry.layout
			if layout then
				for _, lot in layout.lots do
					local lcx, lcz = WorldGen.chunkOf(lot.cframe.Position.X, lot.cframe.Position.Z)
					if lcx == cx and lcz == cz and not entry.built[lot.id] and BuildingGenerator.supports(lot.type) then
						table.insert(due, { entry = entry, lot = lot })
					end
				end
				for _, item in entry.decor do
					local icx, icz = WorldGen.chunkOf(item.cframe.Position.X, item.cframe.Position.Z)
					if icx == cx and icz == cz and not entry.decorBuilt[item.id] then
						table.insert(decorDue, { entry = entry, item = item })
					end
				end
			end
		end
	end
	if #due == 0 and #decorDue == 0 then
		return
	end
	Scheduler.spawn("buildings " .. cx .. "," .. cz, function()
		for _, item in due do
			buildLot(item.entry, item.lot)
			Scheduler.checkpoint()
		end
		for _, pending in decorDue do
			buildDecor(pending.entry, pending.item)
			Scheduler.checkpoint()
		end
	end, Scheduler.Priority.Normal)
end

-- ─── Debug ──────────────────────────────────────────────────────────────────

local function summary(): string
	local lines = {}
	local planned, failed, buildable = 0, 0, 0
	for _, entry in order do
		local layout = entry.layout
		if layout then
			local supported = 0
			for _, lot in layout.lots do
				if BuildingGenerator.supports(lot.type) then
					supported += 1
				end
			end
			planned += #layout.lots
			failed += #layout.failures
			buildable += supported
			local builtCount = 0
			for _ in entry.built do
				builtCount += 1
			end
			local decorBuilt = 0
			for _ in entry.decorBuilt do
				decorBuilt += 1
			end
			table.insert(lines, string.format("%-18s %-7s %-9s lots %2d/%2d placed, %2d failed, %2d built (%d parts), %d roads, decor %d/%d (%d parts)",
				entry.settlement.name .. " (" .. entry.settlement.id .. ")", layout.tier.label, entry.settlement.culture,
				#layout.lots, layout.wanted, #layout.failures, builtCount, entry.parts, #layout.roads, decorBuilt, #entry.decor, entry.decorParts))
		end
	end
	table.insert(lines, 1, string.format("%d settlements · %d lots placed · %d failed · %d buildable · %d buildings built · %d parts (buildings + decor) · %d lights",
		#order, planned, failed, buildable, totals.buildings, totals.parts, BuildingGenerator.lightsUsed()))
	return table.concat(lines, "\n")
end

local function info(entry: Entry): string
	local layout = ensureLayout(entry)
	local byType: { [string]: number } = {}
	for _, lot in layout.lots do
		byType[lot.type] = (byType[lot.type] or 0) + 1
	end
	local kinds = {}
	for kind, n in byType do
		table.insert(kinds, string.format("%s %d%s", kind, n, if BuildingGenerator.supports(kind) then "" else " (planned)"))
	end
	table.sort(kinds)
	local lines = {
		string.format("%s (%s): %s %s, centre (%.0f, %.0f, %.0f), plaza %d, %d roads", layout.name, layout.id, layout.tier.label, layout.culture,
			layout.center.X, layout.center.Y, layout.center.Z, layout.plaza, #layout.roads),
		"lots: " .. table.concat(kinds, ", "),
		string.format("%d terrain ops · %d buildings built (%d parts)", #layout.ops, (function()
			local n = 0
			for _ in entry.built do
				n += 1
			end
			return n
		end)(), entry.parts),
	}
	for _, f in layout.failures do
		table.insert(lines, string.format("  FAILED %s at (%.0f, %.0f): %s", f.type, f.x, f.z, f.reason))
	end
	return table.concat(lines, "\n")
end

-- ─── NPC system API ─────────────────────────────────────────────────────────

function SettlementService.layoutFor(_self: any, settlementId: string): SettlementLayout.Layout?
	ensureEntries()
	local entry = entries[settlementId]
	return if entry then ensureLayout(entry) else nil
end

-- House lots (plus the tavern's room) with bed counts, in lot order.
function SettlementService.homes(self: any, settlementId: string): { { lotId: string, kind: string, beds: number } }
	local layout = self:layoutFor(settlementId)
	local out = {}
	for _, lot in (if layout then layout.lots else {}) :: { SettlementLayout.Lot } do
		local beds = BEDS[lot.type]
		if beds then
			table.insert(out, { lotId = lot.id, kind = lot.type, beds = beds })
		end
	end
	return out
end

-- Lots with an NPCWork anchor, in lot order.
function SettlementService.workplaces(self: any, settlementId: string): { { lotId: string, kind: string } }
	local layout = self:layoutFor(settlementId)
	local out = {}
	for _, lot in (if layout then layout.lots else {}) :: { SettlementLayout.Lot } do
		if WORKPLACES[lot.type] then
			table.insert(out, { lotId = lot.id, kind = lot.type })
		end
	end
	return out
end

--[[
	A building anchor's world position. `name` is "NPCHome", "NPCWork" or "Entrance"; homes have
	one anchor per bed ("NPCHome", "NPCHome2", "NPCHome3"), chosen by `slot`. Before the building
	exists, a planned point inside the lot stands in (home: towards the back; work: the middle).
]]
function SettlementService.anchor(_self: any, lotId: string, name: string, slot: number?): Vector3?
	local found = lotIndex[lotId]
	if not found then
		return nil
	end
	local lot = found.lot
	local model = found.entry.built[lotId]
	if model and model.PrimaryPart then
		local wanted = if slot and slot > 1 then name .. slot else name
		local attachment = model.PrimaryPart:FindFirstChild(wanted) or model.PrimaryPart:FindFirstChild(name)
		if attachment and attachment:IsA("Attachment") then
			return attachment.WorldPosition
		end
	end
	local offset = if name == "NPCHome" then Vector3.new(((slot or 1) - 2) * 3, 4, lot.d * 0.2)
		elseif name == "Entrance" then Vector3.new(0, 3, -lot.d / 2 - 3)
		else Vector3.new(0, 4, 0)
	return (lot.cframe * offset)
end

-- The plaza NPCSpawn points (the same four the decor anchor carries).
function SettlementService.spawnPoints(self: any, settlementId: string): { Vector3 }
	local layout = self:layoutFor(settlementId)
	if not layout then
		return {}
	end
	local r = layout.plaza * 0.75
	local c = layout.center + Vector3.new(0, 3, 0)
	return { c + Vector3.new(r, 0, 0), c + Vector3.new(-r, 0, 0), c + Vector3.new(0, 0, r), c + Vector3.new(0, 0, -r) }
end

-- The built building on a lot (nil until its chunk has been built on this server).
function SettlementService.modelOf(_self: any, lotId: string): Model?
	local found = lotIndex[lotId]
	local model = found and found.entry.built[lotId]
	return if model and model.Parent then model else nil
end

-- The NPC household head living on a lot (nil = vacant: housing may sell it).
function SettlementService.npcOwnerOf(_self: any, lotId: string): string?
	return owners[lotId]
end

function SettlementService.setOwner(_self: any, lotId: string, npcId: string?)
	owners[lotId] = npcId
	local found = lotIndex[lotId]
	local model = found and found.entry.built[lotId]
	if model then
		model:SetAttribute("OwnerNPCId", npcId or "")
	end
end

-- The name of the settlement a lot belongs to ("Glenhold"), or nil for an unknown lot.
function SettlementService.townOf(_self: any, lotId: string): string?
	local found = lotIndex[lotId]
	local settlement = found and found.entry.settlement
	return if settlement and typeof(settlement.name) == "string" then settlement.name else nil
end

function SettlementService.lotName(_self: any, lotId: string): string
	local found = lotIndex[lotId]
	return if found then found.entry.names[lotId] or lotId else lotId
end

-- Overlay data (Admin/Commands/Overlays "lots"): settlements within `radius` of a point.
function SettlementService.overlayData(_self: any, center: Vector3, radius: number): { any }
	ensureEntries()
	local out = {}
	for _, entry in order do
		local s = entry.settlement
		if (Vector3.new(s.x, 0, s.z) - Vector3.new(center.X, 0, center.Z)).Magnitude <= radius + 200 then
			local layout = ensureLayout(entry)
			local lots, roads, failures = {}, {}, {}
			for _, lot in layout.lots do
				local cf = lot.cframe
				local corners = {}
				for _, c in { Vector3.new(-1, 0, -1), Vector3.new(1, 0, -1), Vector3.new(1, 0, 1), Vector3.new(-1, 0, 1) } do
					local p = cf * Vector3.new(c.X * lot.w / 2, 0, c.Z * lot.d / 2)
					table.insert(corners, { x = p.X, y = lot.level, z = p.Z })
				end
				local front = cf * Vector3.new(0, 0, -lot.d / 2)
				table.insert(lots, { type = lot.type, corners = corners, built = entry.built[lot.id] ~= nil, buildable = BuildingGenerator.supports(lot.type), name = entry.names[lot.id], front = { x = front.X, y = lot.level, z = front.Z } })
			end
			for _, road in layout.roads do
				local points = {}
				for _, p in road.points do
					table.insert(points, { x = p.X, y = p.Y, z = p.Z })
				end
				table.insert(roads, { kind = road.kind, width = road.width, points = points })
			end
			for _, f in layout.failures do
				table.insert(failures, { x = f.x, z = f.z, y = world:surfaceHeight(f.x, f.z), text = f.type .. ": " .. f.reason })
			end
			table.insert(out, { name = layout.name, center = { x = layout.center.X, y = layout.center.Y, z = layout.center.Z }, plaza = layout.plaza, lots = lots, roads = roads, failures = failures })
		end
	end
	return out
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "settlements", category = "World", description = "Every settlement: tier, culture, lots placed/failed, buildings built, parts",
		handler = function()
			ensureEntries()
			return summary()
		end,
	})

	admin:Register({
		name = "settlementinfo", category = "World", description = "One settlement's layout: lots by type, terrain ops, failed lots and why",
		args = { { name = "settlement", type = "settlement" } },
		handler = function(_, a)
			ensureEntries()
			local entry = entries[a.settlement.id]
			return if entry then info(entry) else "unknown settlement"
		end,
	})

	admin:Register({
		name = "buildsettlement", category = "World", description = "Build a settlement's terrain and buildings now (normally they appear as players approach)",
		args = { { name = "settlement", type = "settlement" } },
		handler = function(_, a)
			ensureEntries()
			local entry = entries[a.settlement.id]
			if not entry then
				return "unknown settlement"
			end
			local layout = ensureLayout(entry)
			local tier = layout.tier
			local chunks = math.ceil((tier.radius + OP_MARGIN) / WorldConfig.CHUNK_SIZE)
			world:awaitArea(layout.center.X, layout.center.Z, chunks)
			local count = 0
			for _, lot in layout.lots do
				if buildLot(entry, lot) then
					count += 1
				end
				if count % 4 == 0 then
					task.wait()
				end
			end
			local decorCount = 0
			for _, item in entry.decor do
				if buildDecor(entry, item) then
					decorCount += 1
					if decorCount % 20 == 0 then
						task.wait()
					end
				end
			end
			return string.format("%s: terrain ready, %d new buildings, %d new decorations (%d + %d parts)", layout.name, count, decorCount, entry.parts, entry.decorParts)
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

-- Clears a building's interior of terrain now (the building check, admin tools).
function SettlementService.clearInterior(_self: any, model: Model): boolean
	return clearInterior(model)
end

-- Re-runs the foundation verification for one building now (buildingcheck / buildingaudit).
function SettlementService.verifyFoundation(_self: any, model: Model): FoundationBuilder.Report
	return verifyFoundation(model)
end

-- A settlement's ground plan (mask, materials, patches, paths); nil until its layout exists.
function SettlementService.groundFor(_self: any, settlementId: string): SettlementGround.Plan?
	local entry = entries[settlementId]
	return entry and entry.ground
end

-- Shows or hides built puddles by the weather where they lie (wet biomes keep theirs).
local function updatePuddles()
	for _, model in CollectionService:GetTagged("Puddle") do
		if model:IsA("Model") and model:IsDescendantOf(workspace) and not model:GetAttribute("AlwaysWet") then
			local pivot = model:GetPivot().Position
			local wet = world:wetnessAt(pivot.X, pivot.Z) > PUDDLE_WET
			local transparency = if wet then 0.35 else 1
			for _, p in model:GetChildren() do
				if p:IsA("BasePart") and p.Transparency ~= transparency then
					p.Transparency = transparency
				end
			end
		end
	end
end

-- The latest foundation report for a lot (nil until its building has been built and checked).
function SettlementService.foundationReport(_self: any, lotId: string): FoundationBuilder.Report?
	return foundations[lotId]
end

-- Counts over every checked building: (checked, failed, failing lot ids).
function SettlementService.foundationSummary(_self: any): (number, number, { string })
	local checked, failed, failing = 0, 0, {}
	for lotId, report in foundations do
		if report.checked then
			checked += 1
			if not report.ok then
				failed += 1
				table.insert(failing, lotId)
			end
		end
	end
	table.sort(failing)
	return checked, failed, failing
end

function SettlementService.init(_self: any, ctx: any)
	log, bus, flags = ctx.log, ctx.bus, ctx.flags
	worldService = ctx.get("WorldService")
	world = ctx.get("WorldStateService")
	world:setGeneratedOps(opsForChunk)
	world:setGroundPass(paintersForChunk)
	bus:subscribe(Topics.ChunkBuilt, onChunkBuilt)
	registerAdmin(ctx.get("AdminService"))
end

function SettlementService.start(_self: any, _ctx: any)
	worldSeed = worldService:getSeed()
	world:awaitReady()
	ensureEntries()
	local started = os.clock()
	local job = Scheduler.spawn("settlement layouts", function()
		for _, entry in order do
			ensureLayout(entry)
			Scheduler.checkpoint()
		end
	end, Scheduler.Priority.Normal)
	Scheduler.await(job)

	local lots, failed, ops = 0, 0, 0
	for _, entry in order do
		local layout = entry.layout
		if layout then
			lots += #layout.lots
			failed += #layout.failures
			ops += #layout.ops
			for _, f in layout.failures do
				log:warn("settlement_lot_failed", { settlement = entry.settlement.id, type = f.type, reason = f.reason, x = math.floor(f.x), z = math.floor(f.z) })
			end
		end
	end
	log:info("settlements_ready", { settlements = #order, lots = lots, failed = failed, ops = ops, ms = math.floor((os.clock() - started) * 1000) })

	-- Spawn on the spawn city's paved plaza: dry and flat by construction. Off-centre, toward the
	-- first street, so nobody appears inside the well or shrine. (setSpawn checks it's dry.)
	local first = order[1] and order[1].layout
	if first then
		local toward = if first.roads[1] then (first.roads[1].points[1] - first.center) else Vector3.new(1, 0, 0)
		local flatDir = Vector3.new(toward.X, 0, toward.Z)
		local dir = if flatDir.Magnitude > 0.1 then flatDir.Unit else Vector3.new(1, 0, 0)
		task.spawn(function()
			world:setSpawn(first.center + dir * (first.plaza * 0.6))
		end)
	end
	-- The full table (also the `settlements` admin command) only with debug_verbose_boot; printed
	-- here it always read "0 buildings built", because buildings come with chunk builds later.
	if flags and flags.get("debug_verbose_boot") == true then
		print(summary())
	end
	task.spawn(function()
		while true do
			task.wait(PUDDLE_INTERVAL)
			local ok, err = pcall(updatePuddles)
			if not ok then
				log:warn("puddles_failed", { err = tostring(err) })
			end
		end
	end)
	-- Buildings already under way for chunks built before now (the spawn area) are counted later.
	task.delay(20, function()
		local checked, failedFoundations = SettlementService:foundationSummary()
		log:info("settlement_buildings", { built = totals.buildings, parts = totals.parts, tagged = #CollectionService:GetTagged("Building"), decor = #CollectionService:GetTagged("Decor"), lights = BuildingGenerator.lightsUsed(),
			foundationsChecked = checked, foundationsFailed = failedFoundations })
	end)
end

return SettlementService
