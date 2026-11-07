--!strict
--[[
	TownRepairService: places remember what happened to them, and recover (docs/TownRepair.md). Numbers and
	words: Towns/Data/Repair. Decisions: Towns/RepairRules.

	This should feel like the world going on, not a feature (owner, 2026-11-07), so there's no interface.

	GROUND     A fire that isn't saved (a loose spell's, a Titan's: FireSim.onBurnedOut) leaves the grass
	           burned bare. It grows back a quarter at a time, over 10 to 20 minutes.
	BUILDINGS  Any fire that chars part of a town (FireSim.onCharred) gets repaired, whatever started it. Near
	           a player, someone from the town walks over and works on it, part by part, usually the builder.
	           With nobody around to see, it still gets done, more slowly. A repaired part stays a little
	           paler, so a patched building looks patched.
	SAVED      Nothing. This server's town recovers on this server. Ground that burned bare is a live terrain
	           edit that never reaches the saved log.
	LIMITS     Only charring. A building that collapsed (Rubble) isn't rebuilt. Trees and anything else outside
	           a town stay charred, and ordinary fires still leave their permanent scorch.

	Flag: town_repair_enabled. Admin: townrepair status | burn | scar | heal.
]]

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Seed = require(Shared.Magic.Seed)

local Server = script.Parent.Parent
local Cast = Server.Magic.Cast
local EffectBudget = require(Cast.EffectBudget)
local FireSim = require(Cast.FireSim)
local ThermalSim = require(Cast.ThermalSim)
local NPCCombat = require(Server.NPC.NPCCombat)
local NPCLOD = require(Server.NPC.NPCLOD)
local Navigation = require(Server.NPC.NavigationService)
local Activities = require(Server.NPC.Data.Activities)
local Data = require(Server.Towns.Data.Repair)
local Rules = require(Server.Towns.RepairRules)
local TerrainBuilder = require(Server.World.TerrainBuilder)

local T = Data.tuning

local TownRepairService = {
	name = "TownRepairService",
	dependencies = { "AdminService", "NPCService", "WorldService" },
}

type Charred = { part: BasePart, color: Color3, flammability: number }
type Building = { model: Model, parts: { Charred } }
type Job = {
	npc: any,
	building: Building,
	leash: { kind: string, position: Vector3 },
	working: boolean,
	giveUpAt: number,
	nextPart: number,
}
type Town = { id: string, buildings: { Building }, job: Job?, nextOffscreen: number }
type Scar = { x: number, y: number, z: number, material: string, heals: { number }, spots: { { x: number, z: number } }, done: { boolean } }

local log: any = nil
local npcs: any = nil
local worldService: any = nil

local towns: { [string]: Town } = {}
local scars: { Scar } = {}
local charredTotal = 0
local terrainParams: RaycastParams? = nil

local function enabled(): boolean
	return FeatureFlags.get("town_repair_enabled") == true
end

-- ─── Ground ─────────────────────────────────────────────────────────────────

local function surfaceAt(position: Vector3): (Vector3?, string?)
	local params = terrainParams
	if not params then
		params = RaycastParams.new()
		params.FilterType = Enum.RaycastFilterType.Include
		params.FilterDescendantsInstances = { workspace.Terrain }
		terrainParams = params
	end
	local hit = workspace:Raycast(position + Vector3.new(0, 20, 0), Vector3.new(0, -60, 0), params :: RaycastParams)
	if hit then
		return hit.Position, hit.Material.Name
	end
	return nil, nil
end

-- Never through world:edit: this must not reach the saved terrain.
local function replaceGround(from: string, to: string, x: number, y: number, z: number, size: number)
	TerrainBuilder.applyOp({ i = "", k = "replace", f = from, m = to, x = x, y = y, z = z, sx = size, sy = T.scarDepth, sz = size, t = 0 } :: any)
end

local function scarAt(position: Vector3)
	if #scars >= T.maxScars or not enabled() then
		return
	end
	local surface, material = surfaceAt(position)
	if not surface or not material or not Rules.scorches(material) then
		return
	end
	if EffectBudget.takeTerrainOps(1) < 1 then
		return
	end
	replaceGround(material, "Ground", surface.X, surface.Y, surface.Z, T.scarSize)
	local rng = Seed.random(worldService:getSeed(), string.format("scar:%d:%d", surface.X, surface.Z), "heal")
	table.insert(scars, {
		x = surface.X,
		y = surface.Y,
		z = surface.Z,
		material = material,
		heals = Rules.healTimes(os.clock(), rng),
		spots = Rules.quarters(surface.X, surface.Z, T.scarSize),
		done = { false, false, false, false },
	})
end

local function healScars(force: boolean)
	local now = os.clock()
	local healed = 0
	for i = #scars, 1, -1 do
		local scar = scars[i]
		local left = 0
		for q = 1, 4 do
			if not scar.done[q] then
				if (force or now >= scar.heals[q]) and (force or healed < T.healsPerTick) and (force or EffectBudget.takeTerrainOps(1) >= 1) then
					replaceGround("Ground", scar.material, scar.spots[q].x, scar.y, scar.spots[q].z, T.scarSize / 2)
					scar.done[q] = true
					healed += 1
				else
					left += 1
				end
			end
		end
		if left == 0 then
			table.remove(scars, i)
		end
	end
end

-- ─── Buildings ──────────────────────────────────────────────────────────────

local function settlementOf(part: BasePart): string?
	local at: Instance? = part.Parent
	while at and at ~= workspace do
		local id = at:GetAttribute("SettlementId")
		if typeof(id) == "string" then
			return id
		end
		at = at.Parent
	end
	return nil
end

local function townFor(id: string): Town
	local town = towns[id]
	if not town then
		town = { id = id, buildings = {}, job = nil, nextOffscreen = 0 }
		towns[id] = town
	end
	return town
end

local function record(part: BasePart, color: Color3, flammability: number)
	if charredTotal >= T.maxParts or flammability <= 0 or not enabled() then
		return
	end
	local id = settlementOf(part)
	local model = part:FindFirstAncestorWhichIsA("Model")
	if not id or not model then
		return -- out in the wild: nobody's going to come and fix a tree
	end
	local town = townFor(id)
	local building: Building? = nil
	for _, b in town.buildings do
		if b.model == model then
			building = b
			break
		end
	end
	if not building then
		building = { model = model, parts = {} }
		table.insert(town.buildings, building :: Building)
	end
	table.insert((building :: Building).parts, { part = part, color = color, flammability = flammability })
	charredTotal += 1
end

local function repairPart(entry: Charred)
	charredTotal -= 1
	local part = entry.part
	if part.Parent and not part:GetAttribute("Burning") then
		part.Color = Rules.freshColor(entry.color)
		part:SetAttribute("Flammability", entry.flammability)
		part:SetAttribute("Temperature", nil)
		ThermalSim.ensure(part)
	end
end

-- Forgets parts that have gone (a collapse, say), and buildings with nothing left to do.
local function tidy(town: Town)
	for i = #town.buildings, 1, -1 do
		local building = town.buildings[i]
		for j = #building.parts, 1, -1 do
			if not building.parts[j].part.Parent then
				table.remove(building.parts, j)
				charredTotal -= 1
			end
		end
		if #building.parts == 0 or not building.model.Parent or CollectionService:HasTag(building.model, "Rubble") then
			charredTotal -= #building.parts
			table.remove(town.buildings, i)
		end
	end
end

local function say(npc: any, kind: string, seed: number)
	local lines = Data.lines[kind]
	npcs:speak(npc, lines[seed % #lines + 1], T.shoutRadius)
end

local function endJob(town: Town, finished: boolean)
	local job = town.job
	town.job = nil
	if not job then
		return
	end
	local npc = job.npc
	if npc.rig then
		NPCLOD.stopActivity(npc)
	end
	if npc.leash == job.leash then
		npcs:setLeash(npc, nil)
	end
	if finished then
		say(npc, "finish", npc.seed or 0)
		log:info("town_repaired", { town = town.id, npc = npc.id, building = job.building.model.Name })
	end
end

local function jobStillOn(job: Job): boolean
	local npc = job.npc
	return npc.rig ~= nil
		and npc.tier == 0
		and not npc.knockedOut
		and npc.leash == job.leash
		and not NPCCombat.engaged(npc)
		and job.building.model.Parent ~= nil
end

local function stepJob(town: Town, job: Job, now: number)
	if not jobStillOn(job) then
		endJob(town, false)
		return
	end
	local building = job.building
	local entry = building.parts[#building.parts]
	if not entry then
		endJob(town, true)
		return
	end
	local npc = job.npc
	if not job.working then
		local at: Vector3 = npc.rig.root.Position
		local close = Vector3.new(at.X - job.leash.position.X, 0, at.Z - job.leash.position.Z).Magnitude <= T.workReach
		if close or now >= job.giveUpAt then
			job.working = true
			job.nextPart = now + T.workSeconds
			Navigation.Face(npc, entry.part.Position)
			NPCLOD.playActivity(npc, "hammer", Activities.Clips.hammer, true)
		end
		return
	end
	if now >= job.nextPart then
		job.nextPart = now + T.workSeconds
		table.remove(building.parts)
		repairPart(entry)
		local following = building.parts[#building.parts]
		if following then
			Navigation.Face(npc, following.part.Position)
		end
	end
end

local function findWorker(town: Town, position: Vector3): any?
	local people: { [string]: any } = {}
	local candidates: { Rules.Candidate } = {}
	for _, npc in npcs:all() do
		if npc.settlementId == town.id then
			people[npc.id] = npc
			local available = npc.rig ~= nil
				and npc.tier == 0
				and not npc.knockedOut
				and not npc.frozen
				and not npc.leash
				and npc.ageBand ~= "child"
				and not NPCCombat.engaged(npc)
				and not Navigation.IsPaused(npc)
			local at: Vector3 = npc.position
			table.insert(candidates, {
				id = npc.id,
				occupation = npc.occupation,
				available = available,
				distance = (at - position).Magnitude,
			})
		end
	end
	local id = Rules.pickWorker(candidates)
	return if id then people[id] else nil
end

local function startJob(town: Town, building: Building, now: number): boolean
	local entry = building.parts[#building.parts]
	if not entry then
		return false
	end
	local npc = findWorker(town, entry.part.Position)
	if not npc then
		return false
	end
	local spot = Rules.workSpot(entry.part.Position, npc.position)
	local leash = { kind = "hold", position = spot }
	npcs:setLeash(npc, leash)
	town.job = { npc = npc, building = building, leash = leash, working = false, giveUpAt = now + T.walkSeconds, nextPart = 0 }
	say(npc, "start", npc.seed or 0)
	log:info("town_repair_started", { town = town.id, npc = npc.id, occupation = npc.occupation, parts = #building.parts })
	return true
end

local function stepTown(town: Town, now: number)
	tidy(town)
	local job = town.job
	if job then
		stepJob(town, job, now)
		return
	end
	local building = town.buildings[1]
	if not building then
		return
	end
	if startJob(town, building, now) then
		return
	end
	-- Nobody there to see, or nobody free: it still gets done, more slowly.
	if now >= town.nextOffscreen then
		town.nextOffscreen = now + T.offscreenSeconds
		local entry = table.remove(building.parts)
		if entry then
			repairPart(entry)
		end
	end
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function nearestTownParts(position: Vector3, radius: number, max: number): { BasePart }
	local params = OverlapParams.new()
	params.MaxParts = 200
	local found: { BasePart } = {}
	for _, part in workspace:GetPartBoundsInRadius(position, radius, params) do
		if part.Anchored and part.Transparency < 1 and settlementOf(part) and part:FindFirstAncestorWhichIsA("Model") then
			table.insert(found, part)
			if #found >= max then
				break
			end
		end
	end
	return found
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "townrepair",
		category = "World",
		description = "How places recover: status, burn (char the town parts around you), scar (burn the grass around you), heal (regrow every scar now)",
		args = { { name = "action", type = "enum", options = { "status", "burn", "scar", "heal" } } },
		handler = function(ctx: any, a: any)
			if not enabled() then
				return "flag town_repair_enabled is off"
			end
			if a.action == "status" then
				local lines = { string.format("%d charred parts, %d scars", charredTotal, #scars) }
				for id, town in towns do
					local parts = 0
					for _, building in town.buildings do
						parts += #building.parts
					end
					if parts > 0 then
						local job = town.job
						table.insert(lines, string.format("%s: %d parts in %d buildings, %s", id, parts, #town.buildings, if job then tostring(job.npc.name) .. (if job.working then " working" else " on the way") else "nobody on it"))
					end
				end
				return table.concat(lines, "\n")
			elseif a.action == "heal" then
				local n = #scars
				healScars(true)
				return string.format("regrew %d scars", n)
			end
			local root = ctx.player.Character and ctx.player.Character:FindFirstChild("HumanoidRootPart")
			if not root then
				return "no character"
			end
			if a.action == "burn" then
				local n = 0
				for _, part in nearestTownParts(root.Position, 30, 12) do
					ThermalSim.ensure(part)
					local flammability = (part:GetAttribute("Flammability") :: number?) or 0
					if flammability > 0 then
						local color = part.Color
						part.Color = color:Lerp(Color3.new(0.08, 0.07, 0.06), 0.8)
						part:SetAttribute("Flammability", 0)
						record(part, color, flammability)
						n += 1
					end
				end
				return string.format("charred %d parts", n)
			end
			local before = #scars
			for x = -2, 2 do
				for z = -2, 2 do
					scarAt(root.Position + Vector3.new(x * T.scarSize, 0, z * T.scarSize))
				end
			end
			return string.format("%d new scars (only on grass, and within the terrain budget)", #scars - before)
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function TownRepairService.init(_self: any, ctx: any)
	log = ctx.log
	npcs = ctx.get("NPCService")
	worldService = ctx.get("WorldService")
	FireSim.onCharred = record
	FireSim.onBurnedOut = scarAt
	registerAdmin(ctx.get("AdminService"))
end

function TownRepairService.start(_self: any, _ctx: any)
	task.spawn(function()
		while true do
			task.wait(T.tickSeconds)
			if enabled() then
				local now = os.clock()
				-- One failure mustn't stop the rest of the island recovering.
				local ok, err = pcall(healScars, false)
				if not ok then
					log:throttled("repair_scars", 60, "Error", "town_repair_failed", { err = err })
				end
				for _, town in towns do
					local stepped, stepErr = pcall(stepTown, town, now)
					if not stepped then
						log:throttled("repair_town", 60, "Error", "town_repair_failed", { err = stepErr })
					end
				end
			end
		end
	end)
end

return TownRepairService
