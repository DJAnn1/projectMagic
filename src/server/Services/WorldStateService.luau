--!strict
--[[
	WorldStateService: the live world.

	Start-up (in :start, spread across frames by the Scheduler):
		seed (WorldService) -> WorldGen -> MagicMap (ley network) -> WorldIndex (32x32 grid)
		-> POIPlacer (POIs, settlements, roads, hints) -> region state load -> WorldReady
	Then, continuously:
		- chunk streaming: builds the chunks around every player, nearest first
		- persistent terrain deltas: edit() applies + records ops; flushed per chunk and announced
		  to other servers, which re-fetch and replay them
		- tectonic stress, vegetation and ore per region, with lazy regeneration from timestamps
		- event modifiers (EventDirector) and magic "pressure" (what people cast where)
		- environment measurement for casts: castContext(position, radius) -> CastContext

	See docs/World.md. Admin commands: where, chunks, pois, stress, quake, tsunami (plus the
	world tools in Server/Admin/Commands/World, which use the admin API below).
]]

local CollectionService = game:GetService("CollectionService")
local MessagingService = game:GetService("MessagingService")
local Players = game:GetService("Players")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Signal = require(Shared.Core.Signal)
local Types = require(Shared.Magic.Types)
local Registry = require(Shared.Magic.Registry)
local Server = ServerScriptService.Server
local Scheduler = require(Server.Core.Scheduler)
local Schemas = require(Server.Persistence.Schemas)
local World = Server.World
local C = require(World.WorldConfig)
local Biomes = require(World.Biomes)
local WorldGen = require(World.WorldGen)
local MagicMap = require(World.MagicMap)
local WorldIndex = require(World.WorldIndex)
local POIPlacer = require(World.POIPlacer)
local TerrainBuilder = require(World.TerrainBuilder)
local Settlements = require(World.Settlements)
local CharacterSafety = require(World.CharacterSafety)
local Damage = require(script.Parent.Parent.Magic.Cast.Damage)

export type Modifier = {
	id: string,
	x: number,
	z: number,
	radius: number,
	density: number?, -- multiplier
	temperature: number?, -- additive 0..1 scale
	moisture: number?, -- additive
	stormCharge: number?, -- additive
	fuel: number?, -- additive
	expiresAt: number,
}

local DELTA_TOPIC = "WorldDeltas"
local PRESSURE_HALF_LIFE = 600

local WorldStateService = {
	name = "WorldStateService",
	dependencies = { "NetService", "DataService", "WorldService", "PlayerDataService", "AdminService", "ProgressionService" },
}

local log: any = nil
local bus: any = nil
local flags: any = nil
local dataService: any = nil
local worldService: any = nil
local playerData: any = nil
local progression: any = nil

local deltaStore: any = nil
local regionStore: any = nil
local settlementStore: any = nil

local gen: WorldGen.WorldGen? = nil
local magic: MagicMap.MagicMap? = nil
local index: WorldIndex.WorldIndex? = nil
local placement: POIPlacer.Placement? = nil
local ready = Signal.new()
local isReady = false

local built: { [string]: boolean } = {}
local building: { [string]: boolean } = {}
local generatedOps: ((number, number) -> { TerrainBuilder.TerrainOp })? = nil -- SettlementService
local groundPass: ((number, number) -> { TerrainBuilder.Painter })? = nil -- SettlementService (SettlementGround)
local appliedOps: { [string]: { [string]: boolean } } = {} -- chunkKey -> op ids applied
local pendingOps: { [string]: { TerrainBuilder.TerrainOp } } = {} -- chunkKey -> unflushed ops
local opCounter = 0

local regions: any = { stress = {}, vegetation = {}, ore = {} }
local dirtyRegions: { [string]: { [string]: boolean } } = { stress = {}, vegetation = {}, ore = {} }
local settlementDeltas: any = { prosperity = {}, relations = {}, damage = {} }
local modifiers: { [string]: Modifier } = {}
local pressure: { [string]: { [string]: { v: number, t: number } } } = {} -- regionId -> domain -> decaying
local lastRegionInfo: { [Player]: string } = {}

local function chunkKey(cx: number, cz: number): string
	return cx .. "," .. cz
end

-- Scoped by the world's generation (WorldService:scopedKey), so a reseed starts clean.
local function storeKeyFor(key: string): string
	return worldService:scopedKey("d_" .. string.gsub(key, ",", "_"))
end

-- ─── Readiness ──────────────────────────────────────────────────────────────

function WorldStateService.awaitReady(_self: any)
	if not isReady then
		ready:Wait()
	end
end

function WorldStateService.gen(_self: any): WorldGen.WorldGen
	return gen :: WorldGen.WorldGen
end

function WorldStateService.index(_self: any): WorldIndex.WorldIndex
	return index :: WorldIndex.WorldIndex
end

function WorldStateService.placement(_self: any): POIPlacer.Placement
	return placement :: POIPlacer.Placement
end

function WorldStateService.magicMap(_self: any): MagicMap.MagicMap
	return magic :: MagicMap.MagicMap
end

-- Services the world effects (Effects/*) need, without making them Bootstrap modules.
function WorldStateService.services(_self: any): { progression: any, chronicle: any, playerData: any }
	return { progression = progression, chronicle = worldService, playerData = playerData }
end

-- ─── Region state: stress, vegetation, ore ─────────────────────────────────

local function regionIdAt(x: number, z: number): string
	local rx, rz = WorldIndex.regionOf(x, z)
	return WorldIndex.regionId(rx, rz)
end

-- The stress a region rests at (its "full" value): faults hold more.
local function equilibriumStress(cell: WorldIndex.Cell): number
	return math.clamp(0.1 + 0.75 * cell.sample.fault ^ 2 + Biomes.defs[cell.sample.biome].stressBias, 0, C.stress.max)
end

-- Tectonic stress 0..1, regenerating lazily toward equilibrium since its last change.
function WorldStateService.stressAt(_self: any, x: number, z: number): number
	local cell = (index :: WorldIndex.WorldIndex):cellAt(x, z)
	local cap = equilibriumStress(cell)
	local entry = regions.stress[WorldIndex.regionId(cell.rx, cell.rz)]
	if not entry then
		return cap
	end
	local days = math.max(0, os.time() - entry.t) / 86400
	if entry.s > cap then
		-- Overloaded (unrest, aftershock transfer): relaxes back toward equilibrium.
		return math.max(cap, entry.s - C.stress.regenPerDay * days)
	end
	return math.min(cap, entry.s + C.stress.regenPerDay * days)
end

--[[
	Releases tectonic stress at a point (an earthquake). A share of the released stress is pushed
	into the four neighbouring regions (possibly beyond their equilibrium), so quakes can
	trigger aftershocks next door. Returns the amount actually released.
]]
function WorldStateService.releaseStress(self: any, x: number, z: number, amount: number): number
	local idx = index :: WorldIndex.WorldIndex
	local cell = idx:cellAt(x, z)
	local current = self:stressAt(x, z)
	local released = math.clamp(amount, 0, current)
	local now = os.time()
	local id = WorldIndex.regionId(cell.rx, cell.rz)
	regions.stress[id] = { s = current - released, t = now }
	dirtyRegions.stress[id] = true
	for _, neighbor in idx:neighbors(cell) do
		local nid = WorldIndex.regionId(neighbor.rx, neighbor.rz)
		local value = self:stressAt(neighbor.x, neighbor.z) + released * C.stress.transfer / 4
		regions.stress[nid] = { s = math.min(C.stress.max, value), t = now }
		dirtyRegions.stress[nid] = true
	end
	return released
end

-- Adds tectonic stress (volcanic unrest, aftershock loading). May exceed equilibrium briefly.
function WorldStateService.addStress(self: any, x: number, z: number, amount: number)
	local id = regionIdAt(x, z)
	regions.stress[id] = { s = math.min(C.stress.max, self:stressAt(x, z) + amount), t = os.time() }
	dirtyRegions.stress[id] = true
end

function WorldStateService.nexuses(_self: any): { MagicMap.Nexus }
	return if magic then magic.nexuses else {}
end

-- Vegetation multiplier (burned/salted land recovers over ~10 days).
function WorldStateService.vegetationAt(_self: any, x: number, z: number): number
	local entry = regions.vegetation[regionIdAt(x, z)]
	if not entry then
		return 1
	end
	local days = math.max(0, os.time() - entry.t) / 86400
	return math.min(1, entry.v + 0.1 * days)
end

function WorldStateService.setVegetation(_self: any, x: number, z: number, value: number)
	local id = regionIdAt(x, z)
	regions.vegetation[id] = { v = math.clamp(value, 0, 1), t = os.time() }
	dirtyRegions.vegetation[id] = true
end

-- ─── Event modifiers and magic pressure ─────────────────────────────────────

function WorldStateService.addModifier(_self: any, modifier: Modifier)
	modifiers[modifier.id] = modifier
end

function WorldStateService.removeModifier(_self: any, id: string)
	modifiers[id] = nil
end

local function modifiersAt(x: number, z: number): { Modifier }
	local now = os.time()
	local out = {}
	for id, m in modifiers do
		if now >= m.expiresAt then
			modifiers[id] = nil
		elseif (m.x - x) ^ 2 + (m.z - z) ^ 2 <= m.radius * m.radius then
			table.insert(out, m)
		end
	end
	return out
end

-- How wet the ground is from weather right now (0..1): active events' moisture plus half their
-- storm charge. Cheap (no voxel reads); puddles in towns follow it.
function WorldStateService.wetnessAt(_self: any, x: number, z: number): number
	local wet = 0
	for _, m in modifiersAt(x, z) do
		wet += (m.moisture or 0) + (m.stormCharge or 0) * 0.5
	end
	return math.clamp(wet, 0, 1)
end

-- Records that magic was cast here; the EventDirector reads this (fire use brings drought, etc.).
function WorldStateService.noteMagic(_self: any, position: Vector3, domains: { string }, power: number)
	local id = regionIdAt(position.X, position.Z)
	local region = pressure[id] or {}
	pressure[id] = region
	local now = os.time()
	for _, d in domains do
		local entry = region[d]
		local v = if entry then entry.v * 0.5 ^ ((now - entry.t) / PRESSURE_HALF_LIFE) else 0
		region[d] = { v = v + power, t = now }
	end
end

-- Decayed magic pressure per domain around a point (this region only).
function WorldStateService.pressureAt(_self: any, x: number, z: number): { [string]: number }
	local out = {}
	local now = os.time()
	for d, entry in pressure[regionIdAt(x, z)] or {} do
		out[d] = entry.v * 0.5 ^ ((now - entry.t) / PRESSURE_HALF_LIFE)
	end
	return out
end

-- ─── Magic map and environment ──────────────────────────────────────────────

function WorldStateService.densityAt(_self: any, x: number, z: number): number
	local density = (magic :: MagicMap.MagicMap):densityAt(x, z)
	for _, m in modifiersAt(x, z) do
		density *= m.density or 1
	end
	return math.clamp(density, 0, 3)
end

-- Estimated water volume (studs³) within `radius`: open sea from the coarse index (cheap),
-- plus a precise voxel read for small radii (ponds, rivers, flooded basins).
function WorldStateService.waterVolumeAt(_self: any, position: Vector3, radius: number): number
	local idx = index :: WorldIndex.WorldIndex
	local volume = 0
	local cellArea = C.REGION_SIZE * C.REGION_SIZE
	local reach = math.ceil(radius / C.REGION_SIZE)
	local rx0, rz0 = WorldIndex.regionOf(position.X, position.Z)
	for dz = -reach, reach do
		for dx = -reach, reach do
			local cell = idx:cell(rx0 + dx, rz0 + dz)
			if cell and cell.ocean and (cell.x - position.X) ^ 2 + (cell.z - position.Z) ^ 2 <= (radius + C.REGION_SIZE) ^ 2 then
				volume += math.max(0, C.SEA_LEVEL - cell.sample.height) * cellArea
			end
		end
	end
	if volume == 0 and radius <= 64 then
		local half = Vector3.new(radius, 16, radius)
		local region = Region3.new(position - half, position + half):ExpandToGrid(C.VOXEL)
		local materials, occupancy = workspace.Terrain:ReadVoxels(region, C.VOXEL)
		local size = materials.Size
		for x = 1, size.X do
			for y = 1, size.Y do
				for z = 1, size.Z do
					if materials[x][y][z] == Enum.Material.Water then
						volume += occupancy[x][y][z] * C.VOXEL ^ 3
					end
				end
			end
		end
	end
	return volume
end

-- Share (0..1) of solid terrain in a block beneath a point.
function WorldStateService.groundMassAt(_self: any, position: Vector3, radius: number): number
	local r = math.clamp(radius, 8, 32)
	local min = Vector3.new(position.X - r, position.Y - 40, position.Z - r)
	local max = Vector3.new(position.X + r, position.Y, position.Z + r)
	local materials, occupancy = workspace.Terrain:ReadVoxels(Region3.new(min, max):ExpandToGrid(C.VOXEL), C.VOXEL)
	local size = materials.Size
	local solid, total = 0, 0
	for x = 1, size.X do
		for y = 1, size.Y do
			for z = 1, size.Z do
				total += 1
				local material = materials[x][y][z]
				if material ~= Enum.Material.Air and material ~= Enum.Material.Water then
					solid += occupancy[x][y][z]
				end
			end
		end
	end
	return if total > 0 then solid / total else 0
end

--[[
	World facts near a cast, for EnvironmentRules (CastContext.environment). Radius is the spell's
	area of effect; reads are bounded so this costs at most a few ms.
]]
function WorldStateService.environmentAt(self: any, position: Vector3, radius: number): { [string]: number }
	local s = (gen :: WorldGen.WorldGen):sample(position.X, position.Z)
	local biome = Biomes.defs[s.biome]
	local temperature, moisture, storm, fuelBonus = s.temperature, s.moisture, biome.storm, 0
	for _, m in modifiersAt(position.X, position.Z) do
		temperature += m.temperature or 0
		moisture += m.moisture or 0
		storm += m.stormCharge or 0
		fuelBonus += m.fuel or 0
	end
	moisture = math.clamp(moisture, 0, 1)
	return {
		waterVolume = self:waterVolumeAt(position, math.clamp(radius, 16, 600)),
		groundMass = self:groundMassAt(position, radius),
		seismicStress = self:stressAt(position.X, position.Z),
		fuel = math.clamp(biome.fuel * self:vegetationAt(position.X, position.Z) * (1 - 0.5 * moisture) + fuelBonus, 0, 1),
		stormCharge = math.clamp(storm, 0, 1),
		temperature = math.clamp(temperature, 0, 1),
		moisture = moisture,
	}
end

-- Everything MagicCore needs about a place: density, resonance and environment facts.
function WorldStateService.castContext(self: any, position: Vector3, radius: number?): Types.CastContext
	local s = (gen :: WorldGen.WorldGen):sample(position.X, position.Z)
	return {
		ambientDensity = self:densityAt(position.X, position.Z),
		ambientBias = (magic :: MagicMap.MagicMap):resonanceAt(position.X, position.Z, s),
		environment = self:environmentAt(position, radius or 32),
	}
end

-- ─── Terrain edits and persistence ──────────────────────────────────────────

-- Chunks an op's bounding box touches.
local function chunksForOp(op: TerrainBuilder.TerrainOp): { string }
	local hx = (op.r or (op.sx or 4) / 2)
	local hz = (op.r or (op.sz or 4) / 2)
	local cx0, cz0 = WorldGen.chunkOf(op.x - hx, op.z - hz)
	local cx1, cz1 = WorldGen.chunkOf(op.x + hx, op.z + hz)
	local n = WorldGen.chunkCount()
	local out = {}
	for cz = math.max(0, cz0), math.min(n - 1, cz1) do
		for cx = math.max(0, cx0), math.min(n - 1, cx1) do
			table.insert(out, chunkKey(cx, cz))
		end
	end
	return out
end

--[[
	Applies terrain ops now AND records them for persistence. Ops get unique ids; they are
	idempotent, so replaying on another server (or after a restart) reproduces the same result.
	Call from inside a Scheduler job for big batches (it checkpoints).
]]
function WorldStateService.edit(_self: any, cause: string, ops: { TerrainBuilder.TerrainOp })
	local now = os.time()
	for i, op in ops do
		opCounter += 1
		op.i = string.sub(game.JobId, 1, 8) .. ":" .. opCounter
		op.t = now
		op.x, op.y, op.z = math.floor(op.x + 0.5), math.floor(op.y + 0.5), math.floor(op.z + 0.5)
		TerrainBuilder.applyOp(op)
		for _, key in chunksForOp(op) do
			pendingOps[key] = pendingOps[key] or {}
			table.insert(pendingOps[key], op)
			appliedOps[key] = appliedOps[key] or {}
			appliedOps[key][op.i] = true
		end
		if i % 10 == 0 then
			Scheduler.checkpoint()
		end
	end
	-- Anyone the new terrain filled in around is lifted onto it (before physics shoves them down).
	if #ops > 0 then
		local lo, hi = Vector3.new(math.huge, math.huge, math.huge), Vector3.new(-math.huge, -math.huge, -math.huge)
		for _, op in ops do
			local r = op.r or math.max(op.sx or 4, op.sy or 4, op.sz or 4) / 2
			lo = lo:Min(Vector3.new(op.x - r, op.y - r, op.z - r))
			hi = hi:Max(Vector3.new(op.x + r, op.y + r, op.z + r))
		end
		CharacterSafety.checkArea((lo + hi) / 2, (hi - lo).Magnitude / 2)
	end
	log:info("terrain_edit", { cause = cause, ops = #ops })
end

-- Keeps a chunk log under the cap: prunes the oldest small ops first, then the oldest.
local function prune(ops: { TerrainBuilder.TerrainOp }): { TerrainBuilder.TerrainOp }
	local cap = C.deltas.maxOpsPerChunk
	if #ops <= cap then
		return ops
	end
	local keep = table.clone(ops)
	table.sort(keep, function(a, b)
		return a.t < b.t
	end)
	local i = 1
	while #keep > cap and i <= #keep do
		local op = keep[i]
		if (op.r or 99) <= C.deltas.smallOpRadius then
			table.remove(keep, i)
		else
			i += 1
		end
	end
	while #keep > cap do
		table.remove(keep, 1)
	end
	return keep
end

local function flushDeltas()
	local changed = {}
	for key, ops in pendingOps do
		pendingOps[key] = nil
		local _, err = deltaStore:update(storeKeyFor(key), function(record)
			local have: { [string]: boolean } = {}
			for _, op in record.ops do
				have[op.i] = true
			end
			for _, op in ops do
				if not have[op.i] then
					table.insert(record.ops, op)
				end
			end
			record.ops = prune(record.ops)
			record.rev += 1
			return record
		end)
		if err then
			log:warn("delta_flush_failed", { chunk = key, err = err })
			pendingOps[key] = ops -- retry next flush
		else
			table.insert(changed, key)
		end
	end
	if #changed > 0 and flags.get("world_messaging") and not dataService:isMock() then
		pcall(function()
			MessagingService:PublishAsync(DELTA_TOPIC, { origin = game.JobId, chunks = changed })
		end)
	end
end

local function loadOps(key: string): { TerrainBuilder.TerrainOp }
	local record = deltaStore:read(storeKeyFor(key))
	return if record then record.ops else {}
end

-- Another server changed these chunks: replay the ops we haven't applied yet.
local function onRemoteDeltas(message: any)
	local data = message.Data
	if typeof(data) ~= "table" or data.origin == game.JobId or typeof(data.chunks) ~= "table" then
		return
	end
	for _, key in data.chunks do
		if typeof(key) == "string" and built[key] then
			local ops = loadOps(key)
			Scheduler.spawn("remote deltas " .. key, function()
				local applied = appliedOps[key] or {}
				appliedOps[key] = applied
				for i, op in ops do
					if not applied[op.i] then
						applied[op.i] = true
						TerrainBuilder.applyOp(op)
					end
					if i % 20 == 0 then
						Scheduler.checkpoint()
					end
				end
			end, Scheduler.Priority.Normal)
		end
	end
end

local function flushRegions()
	local any = false
	for _, set in dirtyRegions do
		if next(set) then
			any = true
		end
	end
	if not any then
		return
	end
	local snapshot = { stress = {}, vegetation = {}, ore = {} }
	for kind, set in dirtyRegions do
		for id in set do
			snapshot[kind][id] = regions[kind][id]
		end
		dirtyRegions[kind] = {}
	end
	regionStore:update(worldService:scopedKey("regions"), function(record)
		for kind, entries in snapshot do
			for id, entry in entries do
				local existing = record[kind][id]
				-- Newer change wins (entries carry their timestamp).
				if not existing or typeof(entry) ~= "table" or (existing.t or 0) <= (entry.t or 0) then
					record[kind][id] = entry
				end
			end
		end
		return record
	end)
end

local function flushSettlements()
	local deltas = settlementDeltas
	if next(deltas.prosperity) == nil and next(deltas.relations) == nil and next(deltas.damage) == nil then
		return
	end
	settlementDeltas = { prosperity = {}, relations = {}, damage = {} }
	settlementStore:update(worldService:scopedKey("settlements"), function(record)
		for kind, entries in deltas do
			for id, value in entries do
				record[kind][id] = (record[kind][id] or 0) + value
			end
		end
		return record
	end)
end

-- ─── Settlements ────────────────────────────────────────────────────────────

function WorldStateService.settlementAt(_self: any, x: number, z: number): Settlements.Settlement?
	if not placement then
		return nil
	end
	for _, poi in placement.pois do
		local s = poi.settlement
		if s and (poi.x - x) ^ 2 + (poi.z - z) ^ 2 <= poi.radius * poi.radius then
			return s
		end
	end
	return nil
end

-- Judges a cast inside a settlement and adjusts the caster's reputation there.
function WorldStateService.judgeCast(self: any, player: Player, stats: Types.SpellStats, position: Vector3)
	local settlement = self:settlementAt(position.X, position.Z)
	local state = playerData:get(player)
	if not settlement or not state then
		return
	end
	local branch = Registry.branches[stats.recipe.branch]
	local delta, reason = Settlements.judgeCast(settlement, stats.domains, branch.tags, stats.harmful)
	if delta ~= 0 then
		local reputation = state.data.reputation
		reputation[settlement.id] = (reputation[settlement.id] or 0) + Settlements.scaleReputation(settlement, delta)
		if reason then
			log:info("cast_judged", { userId = player.UserId, settlement = settlement.id, delta = delta, reason = reason })
		end
		if delta < 0 then
			-- A crime: ReputationService turns it into infamy, Concord standing, and maybe a bounty.
			bus:publish(Topics.CrimeCommitted, { player = player, settlementId = settlement.id, severity = -delta, reason = reason or "unlawful magic" })
		end
	end
end

function WorldStateService.addSettlementDelta(_self: any, kind: string, id: string, amount: number)
	settlementDeltas[kind][id] = (settlementDeltas[kind][id] or 0) + amount
end

-- ─── Structures and characters ──────────────────────────────────────────────

--[[
	Damages tagged structures (CollectionService tag "Structure"; attributes Integrity default 100,
	Robustness default 1) with linear falloff. At 0 integrity a structure collapses: its parts
	unanchor and it's re-tagged "Rubble". Settlement buildings (attribute SettlementId) record
	damage into the settlement's persistent state. Returns how many structures collapsed.
]]
function WorldStateService.damageStructures(self: any, position: Vector3, radius: number, amount: number, cause: string): number
	local params = OverlapParams.new()
	params.MaxParts = 400
	local models: { [Model]: boolean } = {}
	for _, part in workspace:GetPartBoundsInRadius(position, radius, params) do
		local model = part:FindFirstAncestorWhichIsA("Model")
		if model and CollectionService:HasTag(model, "Structure") then
			models[model] = true
		end
	end
	local collapsed = 0
	for model in models do
		local pivot = model:GetPivot().Position
		local falloff = math.clamp(1 - (pivot - position).Magnitude / radius, 0, 1)
		local robustness = model:GetAttribute("Robustness") or 1
		local integrity = (model:GetAttribute("Integrity") or 100) - amount * falloff / robustness
		model:SetAttribute("Integrity", integrity)
		local settlementId = model:GetAttribute("SettlementId")
		if typeof(settlementId) == "string" then
			self:addSettlementDelta("damage", settlementId, amount * falloff / robustness)
		end
		if integrity <= 0 then
			collapsed += 1
			CollectionService:RemoveTag(model, "Structure")
			CollectionService:AddTag(model, "Rubble")
			for _, descendant in model:GetDescendants() do
				if descendant:IsA("BasePart") then
					descendant.Anchored = false
				end
			end
		end
	end
	if collapsed > 0 then
		log:info("structures_collapsed", { cause = cause, count = collapsed })
	end
	return collapsed
end

--[[
	Damages characters with falloff. Other players are only hurt when the `pvp_enabled` flag is
	on; the caster is always affected by their own disaster (that's how "survive a collapse you
	caused" happens). Returns a map of hit humanoids -> damage dealt.
]]
-- Quake damage (World/Effects/Earthquake): everyone within `radius`, strongest at the centre.
-- Players and NPC rigs alike, through Cast/Damage (damage numbers, NPC aggro, wards). Other players
-- only with pvp_enabled; the caster is always caught by their own quake; natural quakes (no
-- caster) hit everyone. No `from`: a raised guard doesn't stop the ground shaking under you.
function WorldStateService.damageCharacters(_self: any, position: Vector3, radius: number, amount: number, caster: Player?): { [Humanoid]: number }
	local hits = {}
	local function consider(character: Model?, player: Player?)
		local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
		local humanoid = character and character:FindFirstChildOfClass("Humanoid")
		if not root or not humanoid or humanoid.Health <= 0 then
			return
		end
		local distance = (root.Position - position).Magnitude
		if distance > radius then
			return
		end
		if player and not (player == caster or caster == nil or flags.get("pvp_enabled")) then
			return
		end
		local dealt = Damage.apply(humanoid, amount * (1 - distance / radius), if caster then caster.UserId else nil, "quake", {
			domain = "earth",
		})
		if dealt > 0 then
			hits[humanoid] = dealt
		end
	end
	for _, player in Players:GetPlayers() do
		consider(player.Character, player)
	end
	-- NPC rigs (only those near players exist as rigs; far NPCs are data and take no damage).
	local npcs = workspace:FindFirstChild("NPCs")
	if npcs then
		for _, child in npcs:GetChildren() do
			if child:IsA("Model") then
				consider(child, nil)
			end
		end
	end
	return hits
end

-- ─── Chunk streaming ────────────────────────────────────────────────────────

local function buildChunk(cx: number, cz: number)
	local key = chunkKey(cx, cz)
	if built[key] or building[key] then
		return
	end
	building[key] = true
	task.spawn(function()
		-- Generated ops (settlement paving and levelling) first, then saved edits on top of them.
		-- Both are fetched before the job: the DataStore read yields, and jobs must not.
		local ops: { TerrainBuilder.TerrainOp } = {}
		local provider = generatedOps
		if provider then
			local ok, generated = pcall(provider, cx, cz)
			if ok then
				ops = generated
			else
				log:error("generated_ops_failed", { chunk = key, err = tostring(generated) })
			end
		end
		for _, op in loadOps(key) do
			table.insert(ops, op)
		end
		local applied = appliedOps[key] or {}
		appliedOps[key] = applied
		for _, op in ops do
			applied[op.i] = true
		end
		-- The ground painters for this chunk (fetched here too: computing a layout may yield).
		local painters: { TerrainBuilder.Painter } = {}
		local groundProvider = groundPass
		if groundProvider then
			local ok, result = pcall(groundProvider, cx, cz)
			if ok then
				painters = result
			else
				log:error("ground_pass_failed", { chunk = key, err = tostring(result) })
			end
		end
		local originX, originZ = WorldGen.chunkOrigin(cx, cz)
		local roads = POIPlacer.roadsInChunk((placement :: POIPlacer.Placement).roads, originX, originZ, C.CHUNK_SIZE)
		local runtime = flags.get("terrain_generate_at_runtime")
		Scheduler.spawn("chunk " .. key, function()
			if runtime then
				TerrainBuilder.buildChunk(gen :: WorldGen.WorldGen, cx, cz, roads, ops, painters)
			else
				-- Baked terrain: only replay ops (generated clipped to the chunk, ground pass, edits).
				TerrainBuilder.applyChunkOps(cx, cz, ops, painters)
			end
		end, Scheduler.Priority.Normal, function()
			building[key] = nil
			built[key] = true
			bus:publish(Topics.ChunkBuilt, { cx = cx, cz = cz })
		end)
	end)
end

-- Chunks within `radius` of a point, nearest first.
local function chunksAround(x: number, z: number, radius: number): { { number } }
	local ccx, ccz = WorldGen.chunkOf(x, z)
	local n = WorldGen.chunkCount()
	local list = {}
	for dz = -radius, radius do
		for dx = -radius, radius do
			local cx, cz = ccx + dx, ccz + dz
			if cx >= 0 and cz >= 0 and cx < n and cz < n then
				table.insert(list, { cx, cz, dx * dx + dz * dz })
			end
		end
	end
	table.sort(list, function(a, b)
		return a[3] < b[3]
	end)
	return list
end

function WorldStateService.isChunkBuilt(_self: any, x: number, z: number): boolean
	local cx, cz = WorldGen.chunkOf(x, z)
	return built[chunkKey(cx, cz)] == true
end

-- Ensures the area around a point is built (e.g. before teleporting a player there).
function WorldStateService.requestArea(_self: any, x: number, z: number, radiusChunks: number)
	for _, entry in chunksAround(x, z, radiusChunks) do
		buildChunk(entry[1], entry[2])
	end
end

-- Yields until every chunk within `radiusChunks` of a point is built.
function WorldStateService.awaitArea(self: any, x: number, z: number, radiusChunks: number)
	self:requestArea(x, z, radiusChunks)
	while true do
		local done = true
		for _, entry in chunksAround(x, z, radiusChunks) do
			if not built[chunkKey(entry[1], entry[2])] then
				done = false
				break
			end
		end
		if done then
			return
		end
		task.wait(0.25)
	end
end

--[[
	Nearest dry, walkable ground to (x, z): at least 6 studs above sea level with a gentle slope.
	Searches rings of 16-stud spacing out to `maxRadius`; if nothing qualifies, returns the
	highest point found. Returns (x, groundY, z). Used for spawns and teleports.
]]
-- Ring search: the first point within maxRadius at least `above` studs over the sea with a
-- slope under `maxSlope`, nearest first. Nil when none.
local function ringSearch(x: number, z: number, maxRadius: number, above: number, maxSlope: number): (number?, number?, number?)
	local g = gen :: WorldGen.WorldGen
	for r = 0, maxRadius, 16 do
		local steps = if r == 0 then 1 else math.max(8, math.floor(2 * math.pi * r / 16))
		for i = 0, steps - 1 do
			local angle = i / steps * 2 * math.pi
			local px, pz = x + math.cos(angle) * r, z + math.sin(angle) * r
			local h = g:height(px, pz)
			if h >= C.SEA_LEVEL + above then
				local slope = math.max(math.abs(g:height(px + 8, pz) - h), math.abs(g:height(px, pz + 8) - h)) / 8
				if slope < maxSlope then
					return px, h, pz
				end
			end
		end
	end
	return nil, nil, nil
end

--[[
	Never returns water: (1) gentle ground 6+ studs above the sea within maxRadius; (2) any
	ground 3+ above the sea with a slope under 1 within maxRadius; (3) the nearest dry land cell
	of the coarse index, anywhere, searched the same way around its centre.
]]
function WorldStateService.findDryLand(_self: any, x: number, z: number, maxRadius: number): (number, number, number)
	local px, h, pz = ringSearch(x, z, maxRadius, 6, 0.5)
	if px and h and pz then
		return px, h, pz
	end
	px, h, pz = ringSearch(x, z, maxRadius, 3, 1)
	if px and h and pz then
		return px, h, pz
	end
	local best, bestD = nil :: WorldIndex.Cell?, math.huge
	for _, cell in (index :: WorldIndex.WorldIndex).cells do
		if not cell.ocean and cell.sample.height >= C.SEA_LEVEL + 6 then
			local d = (cell.x - x) ^ 2 + (cell.z - z) ^ 2
			if d < bestD then
				best, bestD = cell, d
			end
		end
	end
	if best then
		px, h, pz = ringSearch(best.x, best.z, 96, 3, 1)
		if px and h and pz then
			return px, h, pz
		end
		return best.x, best.sample.height, best.z
	end
	local g = gen :: WorldGen.WorldGen
	return x, math.max(g:height(x, z), C.SEA_LEVEL), z
end

-- The surface height at a point (generated terrain; ignores edits).
function WorldStateService.surfaceHeight(_self: any, x: number, z: number): number
	return (gen :: WorldGen.WorldGen):height(x, z)
end

local function streamLoop()
	while true do
		task.wait(1)
		-- Keep up to 2 chunks in flight; the Scheduler budget bounds the per-frame cost anyway.
		local inFlight = 0
		for _ in building do
			inFlight += 1
		end
		if inFlight >= 2 then
			continue
		end
		local best: { number }? = nil
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				for _, entry in chunksAround(root.Position.X, root.Position.Z, C.STREAM_RADIUS_CHUNKS) do
					local key = chunkKey(entry[1], entry[2])
					if not built[key] and not building[key] and (not best or entry[3] < best[3]) then
						best = entry
					end
				end
			end
		end
		if best then
			buildChunk(best[1], best[2])
		end
	end
end

-- ─── Region info for clients ────────────────────────────────────────────────

local function regionInfoLoop()
	while true do
		task.wait(2)
		for _, player in Players:GetPlayers() do
			local character = player.Character
			local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
			if root then
				local p = root.Position
				local id = regionIdAt(p.X, p.Z)
				if lastRegionInfo[player] ~= id then
					lastRegionInfo[player] = id
					local s = (gen :: WorldGen.WorldGen):sample(p.X, p.Z)
					local resonance = (magic :: MagicMap.MagicMap):resonanceAt(p.X, p.Z, s)
					Net.fire("RegionInfo", player, {
						biome = s.biome,
						biomeName = Biomes.defs[s.biome].name,
						density = math.floor(WorldStateService:densityAt(p.X, p.Z) * 100 + 0.5) / 100,
						resonance = resonance,
						settlement = (WorldStateService:settlementAt(p.X, p.Z) or {} :: any).name,
					})
				end
			end
		end
	end
end

-- ─── Admin commands ─────────────────────────────────────────────────────────

local function rootOf(player: Player): BasePart?
	local character = player.Character
	return character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
end

local function registerAdmin(admin: any)
	-- Argument types other admin tools reuse (teleport, structures, events).
	admin:RegisterType("settlement", {
		parse = function(raw)
			if not placement then
				return nil, "world not ready"
			end
			local names = {}
			for _, s in placement.settlements do
				if string.lower(s.id) == string.lower(raw) then
					return s, nil
				end
				table.insert(names, s.name)
			end
			local name, err = admin.matchOption(raw, names)
			for _, s in placement.settlements do
				if s.name == name then
					return s, nil
				end
			end
			return nil, err
		end,
		options = function()
			local names = {}
			for _, s in (if placement then placement.settlements else {}) :: { Settlements.Settlement } do
				table.insert(names, s.name)
			end
			table.sort(names)
			return names
		end,
	})
	admin:RegisterType("poi", {
		parse = function(raw)
			if not placement then
				return nil, "world not ready"
			end
			if placement.byId[raw] then
				return placement.byId[raw], nil
			end
			local ids = {}
			for _, poi in placement.pois do
				table.insert(ids, poi.id)
			end
			local id, err = admin.matchOption(raw, ids)
			return if id then placement.byId[id] else nil, err
		end,
		options = function()
			local ids = {}
			for _, poi in (if placement then placement.pois else {}) :: { POIPlacer.POI } do
				table.insert(ids, poi.id)
			end
			table.sort(ids)
			return ids
		end,
	})
	local biomeIds = {}
	for id in Biomes.defs do
		table.insert(biomeIds, id)
	end
	table.sort(biomeIds)
	admin:RegisterType("biome", {
		parse = function(raw)
			return admin.matchOption(raw, biomeIds)
		end,
		options = function()
			return biomeIds
		end,
	})

	admin:Register({
		name = "where", category = "World", description = "Biome, magic and environment at your position",
		handler = function(ctx)
			local root = rootOf(ctx.player)
			if not root or not isReady then
				return "no character or world not ready"
			end
			local p = root.Position
			local s = (gen :: WorldGen.WorldGen):sample(p.X, p.Z)
			local cctx = WorldStateService:castContext(p, 32)
			local env = cctx.environment or {}
			local bias = {}
			for d, v in (cctx.ambientBias or {}) :: { [string]: number } do
				table.insert(bias, string.format("%s %.2f", d, v))
			end
			table.sort(bias)
			local settlement = WorldStateService:settlementAt(p.X, p.Z)
			local cx, cz = WorldGen.chunkOf(p.X, p.Z)
			return string.format(
				"(%.0f, %.0f, %.0f) chunk %d,%d | %s | height %.0f temp %.2f moist %.2f fault %.2f | density %.2f\nresonance: %s\nstress %.2f groundMass %.2f water %.0f fuel %.2f storm %.2f%s",
				p.X, p.Y, p.Z, cx, cz, Biomes.defs[s.biome].name, s.height, s.temperature, s.moisture, s.fault, cctx.ambientDensity or 0,
				table.concat(bias, ", "), env.seismicStress or 0, env.groundMass or 0, env.waterVolume or 0, env.fuel or 0, env.stormCharge or 0,
				if settlement then string.format("\nin %s (%s %s)", settlement.name, settlement.size, Settlements.cultures[settlement.culture].name) else ""
			)
		end,
	})

	admin:Register({
		name = "chunks", category = "World", description = "Terrain build status",
		handler = function()
			local count, inFlight = 0, 0
			for _ in built do
				count += 1
			end
			for _ in building do
				inFlight += 1
			end
			local n = WorldGen.chunkCount()
			return string.format("built %d / %d chunks, building %d, scheduler jobs %d", count, n * n, inFlight, Scheduler.pending())
		end,
	})

	admin:Register({
		name = "pois", category = "World", description = "List points of interest (hidden ones marked *)",
		args = { { name = "type", type = "string", optional = true, hint = "filter, e.g. shrine, mythic, mine" } },
		handler = function(_, a)
			if not placement then
				return "world not ready"
			end
			local lines = {}
			for _, poi in placement.pois do
				if not a.type or string.find(poi.type, a.type, 1, true) then
					table.insert(lines, string.format("%s%s (%.0f, %.0f) %s%s", if poi.hidden then "*" else "", poi.id, poi.x, poi.z, poi.biome,
						if poi.settlement then string.format(" - %s, %s %s", poi.settlement.name, poi.settlement.size, poi.settlement.culture) else ""))
				end
			end
			return if #lines > 0 then table.concat(lines, "\n") else "(none)"
		end,
	})

	admin:Register({
		name = "stress", category = "World", description = "Tectonic stress around you",
		handler = function(ctx)
			local root = rootOf(ctx.player)
			if not root then
				return "no character"
			end
			local p = root.Position
			return string.format("stress here %.3f (regenerates %.2f/day toward the fault's equilibrium)", WorldStateService:stressAt(p.X, p.Z), C.stress.regenPerDay)
		end,
	})

	admin:Register({
		name = "quake", category = "World", description = "Grandmaster earthquake at your position (or a point)",
		args = {
			{ name = "power", type = "integer", min = 1, max = 10, default = 8, slider = true },
			{ name = "at", type = "vector3", optional = true, hint = "@cursor or x,y,z (default: you)" },
		},
		handler = function(ctx, a)
			local root = rootOf(ctx.player)
			local at: Vector3? = a.at or (root and root.Position)
			if not at then
				return "no character"
			end
			local Earthquake = require(World.Effects.Earthquake)
			return Earthquake.adminCast(WorldStateService, ctx.player, at, a.power)
		end,
	})

	admin:Register({
		name = "tsunami", category = "World", description = "Grandmaster tsunami from the sea toward your position (or a point)",
		args = {
			{ name = "power", type = "integer", min = 1, max = 10, default = 10, slider = true },
			{ name = "at", type = "vector3", optional = true, hint = "@cursor or x,y,z (default: you)" },
		},
		handler = function(ctx, a)
			local root = rootOf(ctx.player)
			local at: Vector3? = a.at or (root and root.Position)
			if not at then
				return "no character"
			end
			local Tsunami = require(World.Effects.Tsunami)
			return Tsunami.adminCast(WorldStateService, ctx.player, at, a.power)
		end,
	})
end

-- ─── Admin API (Server/Admin/Commands/World) ────────────────────────────────

-- Persisted ops for a chunk: (saved, unflushed). Yields (DataStore read).
function WorldStateService.chunkDeltas(_self: any, cx: number, cz: number): ({ TerrainBuilder.TerrainOp }, { TerrainBuilder.TerrainOp })
	local key = chunkKey(cx, cz)
	return loadOps(key), pendingOps[key] or {}
end

-- Deletes a chunk's saved edits (every server). Yields. Returns how many ops were removed.
function WorldStateService.clearChunkDeltas(_self: any, cx: number, cz: number): number
	local key = chunkKey(cx, cz)
	local removed = #(pendingOps[key] or {})
	pendingOps[key] = nil
	deltaStore:update(storeKeyFor(key), function(record)
		removed += #record.ops
		record.ops = {}
		record.rev += 1
		return record
	end)
	return removed
end

--[[
	Back to the generated state: clears the chunk's saved edits, wipes its terrain and builds it
	again from the seed. Only possible when terrain is generated at runtime (baked terrain has
	nothing to rebuild from). Edits that spanned a border still live in the neighbour's log.
]]
function WorldStateService.resetChunk(self: any, cx: number, cz: number): (boolean, string)
	if not flags.get("terrain_generate_at_runtime") then
		return false, "terrain is baked (terrain_generate_at_runtime is off): nothing to regenerate from"
	end
	local key = chunkKey(cx, cz)
	if building[key] then
		return false, "chunk is building; try again in a moment"
	end
	local removed = self:clearChunkDeltas(cx, cz)
	-- The chunk is empty for a few frames while it rebuilds: hold anyone standing in it.
	local ox, oz = WorldGen.chunkOrigin(cx, cz)
	local release = CharacterSafety.holdArea(Vector3.new(ox - 4, 0, oz - 4), Vector3.new(ox + C.CHUNK_SIZE + 4, 0, oz + C.CHUNK_SIZE + 4))
	appliedOps[key] = nil
	built[key] = nil
	TerrainBuilder.clearChunk(cx, cz)
	buildChunk(cx, cz)
	task.spawn(function()
		local waited = 0
		while not built[key] and waited < 30 do
			task.wait(0.2)
			waited += 0.2
		end
		release()
	end)
	return true, string.format("chunk %d,%d regenerating (%d saved edits removed)", cx, cz, removed)
end

-- Clears every settlement's saved state (prosperity, relations drift, damage). Yields.
function WorldStateService.clearSettlementState(_self: any)
	settlementDeltas = { prosperity = {}, relations = {}, damage = {} }
	settlementStore:update(worldService:scopedKey("settlements"), function(record)
		record.prosperity, record.relations, record.damage = {}, {}, {}
		return record
	end)
end

-- Settlements (and any other generated layer) register terrain ops to apply with each chunk.
-- Call from a service's init, before chunks start building. The ops are never saved.
function WorldStateService.setGeneratedOps(_self: any, provider: (number, number) -> { TerrainBuilder.TerrainOp })
	generatedOps = provider
end

-- Ground painters for a chunk (SettlementService); they run after the generated ops, before edits.
function WorldStateService.setGroundPass(_self: any, provider: (number, number) -> { TerrainBuilder.Painter })
	groundPass = provider
end

-- ─── Spawn ─────────────────────────────────────────────────────────────────

local SPAWN_PAD = 6
local spawnPart: SpawnLocation? = nil

local surfaceParams = RaycastParams.new()
surfaceParams.FilterType = Enum.RaycastFilterType.Include
surfaceParams.FilterDescendantsInstances = { workspace.Terrain }
surfaceParams.IgnoreWater = false

-- The built terrain surface at (x, z): (height, material) or nil where nothing is built.
local function builtSurface(x: number, z: number): (number?, Enum.Material?)
	local from = Vector3.new(x, C.MAX_HEIGHT + 300, z)
	local hit = workspace:Raycast(from, Vector3.new(0, C.BEDROCK_Y - from.Y, 0), surfaceParams)
	if not hit then
		return nil, nil
	end
	return hit.Position.Y, hit.Material
end

-- Dry ground on the BUILT terrain: the point itself, then rings out to maxRadius. A spot counts
-- when it and the four points a pad-width away are all solid ground above the sea (so random
-- spawn offsets inside the pad never land in water).
local function verifiedDry(at: Vector3, maxRadius: number): Vector3?
	local function dry(x: number, z: number): number?
		local y, material = builtSurface(x, z)
		if not y or material == Enum.Material.Water or y < C.SEA_LEVEL + 1 then
			return nil
		end
		return y
	end
	for r = 0, maxRadius, 8 do
		local steps = if r == 0 then 1 else math.max(8, math.floor(2 * math.pi * r / 8))
		for i = 0, steps - 1 do
			local angle = i / steps * 2 * math.pi
			local x, z = at.X + math.cos(angle) * r, at.Z + math.sin(angle) * r
			local y = dry(x, z)
			local m = SPAWN_PAD / 2 + 2
			if y and dry(x + m, z) and dry(x - m, z) and dry(x, z + m) and dry(x, z - m) then
				return Vector3.new(x, y, z)
			end
		end
	end
	return nil
end

--[[
	Moves the world spawn (e.g. SettlementService puts it on the spawn city's plaza), only if the
	new spot is verified dry on the built terrain. Yields while that area builds. Returns success.
]]
function WorldStateService.setSpawn(self: any, position: Vector3): boolean
	-- Settlement layouts can finish before start() has created the spawn: wait for it (60 s max).
	local waited = 0
	while not spawnPart and waited < 60 do
		task.wait(0.5)
		waited += 0.5
	end
	self:awaitArea(position.X, position.Z, 1)
	local at = verifiedDry(position, 24)
	local part = spawnPart
	if not at or not part then
		log:warn("spawn_move_refused", { x = math.floor(position.X), z = math.floor(position.Z), reason = if part then "not dry" else "no spawn yet" })
		return false
	end
	part.Position = at + Vector3.new(0, 4, 0)
	log:info("spawn_moved", { x = math.floor(at.X), y = math.floor(at.Y), z = math.floor(at.Z) })
	return true
end

function WorldStateService.spawnPoint(_self: any): Vector3?
	local part = spawnPart
	return if part then part.Position else nil
end

-- CharacterSafety reports rescues here (so they show in the log with the other world events).
function WorldStateService.logRescue(_self: any, player: Player, reason: string, from: Vector3, to: Vector3)
	log:info("character_rescued", { userId = player.UserId, reason = reason, fromY = math.floor(from.Y), toY = math.floor(to.Y) })
end

-- Adds a POI at runtime (admin spawn). POIService reads placement.pois live, so it works at
-- once; it is NOT saved and disappears when the server restarts.
function WorldStateService.addPOI(_self: any, poi: POIPlacer.POI)
	local p = placement :: POIPlacer.Placement
	table.insert(p.pois, poi)
	p.byId[poi.id] = poi
	if poi.settlement then
		table.insert(p.settlements, poi.settlement)
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function WorldStateService.init(_self: any, ctx: any)
	log, bus, flags = ctx.log, ctx.bus, ctx.flags
	dataService = ctx.get("DataService")
	worldService = ctx.get("WorldService")
	playerData = ctx.get("PlayerDataService")
	progression = ctx.get("ProgressionService")
	deltaStore = dataService:openStore(Schemas.WorldDeltas)
	regionStore = dataService:openStore(Schemas.Regions)
	settlementStore = dataService:openStore(Schemas.SettlementState)
	registerAdmin(ctx.get("AdminService"))
	Scheduler.setBudgetMs(flags.get("world_build_budget_ms") or 4)
	-- Characters wait until the spawn area's terrain exists (re-enabled in :start).
	Players.CharacterAutoLoads = false

	game:BindToClose(function()
		flushDeltas()
		flushRegions()
		flushSettlements()
	end)
	Players.PlayerRemoving:Connect(function(player)
		lastRegionInfo[player] = nil
	end)
end

function WorldStateService.start(_self: any, _ctx: any)
	local seed = worldService:getSeed()
	local started = os.clock()
	gen = WorldGen.new(seed)
	magic = MagicMap.new(gen :: WorldGen.WorldGen, seed)

	local job = Scheduler.spawn("world index + POIs", function()
		index = WorldIndex.build(gen :: WorldGen.WorldGen, magic :: MagicMap.MagicMap, Scheduler.checkpoint)
		placement = POIPlacer.place(index :: WorldIndex.WorldIndex, magic :: MagicMap.MagicMap, seed, Scheduler.checkpoint)
	end, Scheduler.Priority.High)
	Scheduler.await(job)

	local saved = regionStore:read(worldService:scopedKey("regions"))
	if saved then
		regions = saved
	end

	isReady = true
	log:info("world_generated", {
		ms = math.floor((os.clock() - started) * 1000),
		nexuses = #(magic :: MagicMap.MagicMap).nexuses,
		leyLines = #(magic :: MagicMap.MagicMap).lines,
		pois = #(placement :: POIPlacer.Placement).pois,
		settlements = #(placement :: POIPlacer.Placement).settlements,
	})
	ready:Fire()
	bus:publish(Topics.WorldReady, {})

	if flags.get("world_messaging") and not dataService:isMock() then
		pcall(function()
			MessagingService:SubscribeAsync(DELTA_TOPIC, onRemoteDeltas)
		end)
	end

	-- Spawn: the largest settlement (cities come first). Build its area BEFORE characters load,
	-- so nobody falls through a world that doesn't exist yet.
	local home = (placement :: POIPlacer.Placement).settlements[1]
	local spawnX, _, spawnZ = WorldStateService:findDryLand(if home then home.x else 0, if home then home.z else 0, 320)
	WorldStateService:awaitArea(spawnX, spawnZ, C.SPAWN_RADIUS_CHUNKS)
	-- Checked against the BUILT terrain (generated heights ignore water and edits).
	local spawnAt = verifiedDry(Vector3.new(spawnX, 0, spawnZ), 160) or Vector3.new(spawnX, (gen :: WorldGen.WorldGen):height(spawnX, spawnZ), spawnZ)
	local spawn = Instance.new("SpawnLocation")
	spawn.Name = "WorldSpawn"
	spawn.Anchored = true
	spawn.Neutral = true
	spawn.Transparency = 1
	spawn.CanCollide = false
	spawn.Size = Vector3.new(SPAWN_PAD, 1, SPAWN_PAD) -- small: players appear within this square
	spawn.Position = spawnAt + Vector3.new(0, 4, 0)
	spawn.Parent = workspace
	spawnPart = spawn
	Players.CharacterAutoLoads = true
	for _, player in Players:GetPlayers() do
		if not player.Character then
			task.spawn(player.LoadCharacter, player)
		end
	end
	log:info("spawn_ready", { x = math.floor(spawnAt.X), y = math.floor(spawnAt.Y), z = math.floor(spawnAt.Z), ms = math.floor((os.clock() - started) * 1000) })
	CharacterSafety.guardSpawns(function(): Vector3?
		local part = spawnPart
		return if part and part.Parent then part.Position else nil
	end)

	CharacterSafety.start(WorldStateService)
	task.spawn(streamLoop)
	task.spawn(regionInfoLoop)
	while true do
		task.wait(C.deltas.flushSeconds)
		flushDeltas()
		flushRegions()
		flushSettlements()
	end
end

return WorldStateService
