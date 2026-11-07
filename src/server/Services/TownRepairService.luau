--!strict
--[[
	TownRepairService: places remember what happened to them, and recover (docs/TownRepair.md). Numbers and
	words: Towns/Data/Repair. Decisions: Towns/RepairRules.

	This should feel like the world going on, not a feature (owner, 2026-11-07), so there's no interface.

	GROUND     A fire that isn't saved (a loose spell's, a Titan's: FireSim.onBurnedOut) leaves the grass
	           burned bare. It grows back a quarter at a time, over 10 to 20 minutes.
	LIVING     A tree or hedge in town grows back by itself, slowly, looking as it did. Nobody comes to fix it.
	BUILDINGS  Any fire that chars part of a town (FireSim.onCharred) gets repaired, whatever started it. Near
	           a player, someone from the town walks over and works on it, part by part, usually the builder.
	           With nobody around to see, it still gets done, more slowly. A repaired part stays a little
	           paler, so a patched building looks patched.
	COLLAPSE   A town building that comes down, for any reason (WorldStateService.setCollapseHook), is put
	           back from the ground up with its own pieces, once the rubble has settled, one piece at a time.
	           Scaffolding goes up around it, and pieces rise into place. Workers stand outside it and move
	           round as they go. It takes many minutes with someone on it, and far longer with nobody around.
	           When it's done it's a real building again, and its damage comes off the town's record.
	RESIDENTS  Whoever lives or works there says so, and goes elsewhere (NPCService.setLotDown): to a friend's
	           house, or the tavern. Others are sent out of the footprint while it goes back up.
	MENDING    A building that's damaged but still standing slowly regains its strength by itself.
	SAVED      Nothing. This server's town recovers on this server. Ground that burned bare is a live terrain
	           edit that never reaches the saved log.
	LIMITS     Trees and anything else outside a town stay charred, and ordinary fires still leave their
	           permanent scorch. A piece that's been destroyed (fell out of the world) stays missing.

	Flag: town_repair_enabled. Admin: townrepair status | burn | scar | heal | collapse | rush.
]]

local CollectionService = game:GetService("CollectionService")
local TweenService = game:GetService("TweenService")

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
local Scaffold = require(Server.Towns.Scaffold)
local TerrainBuilder = require(Server.World.TerrainBuilder)

local T = Data.tuning

local TownRepairService = {
	name = "TownRepairService",
	dependencies = { "AdminService", "NPCService", "SettlementService", "WorldService", "WorldStateService" },
}

-- One thing to put right. `at` means it's a piece of a collapsed building, going back to that place.
type Charred = { part: BasePart, color: Color3, flammability: number, at: CFrame? }
type Building = {
	model: Model,
	parts: { Charred },
	rebuild: boolean,
	startAfter: number,
	all: { Charred },
	footprint: Rules.Footprint?,
	baseY: number,
	topY: number,
	lotId: string?,
	scaffold: Model?,
	nextKeepOut: number,
}
type Job = {
	npc: any,
	building: Building,
	leash: { kind: string, position: Vector3 },
	working: boolean,
	giveUpAt: number,
	nextPart: number,
	placed: number,
	turn: number,
}
type Town = { id: string, buildings: { Building }, job: Job?, nextOffscreen: number, nextLiving: number }
type Scar = { x: number, y: number, z: number, material: string, heals: { number }, spots: { { x: number, z: number } }, done: { boolean } }

local log: any = nil
local npcs: any = nil
local worldService: any = nil
local world: any = nil
local settlements: any = nil

local scaffoldCount = 0
local scaffoldFolder: Folder? = nil
local rushing = false -- admin: no settling, and a piece a second, so it can be tested
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
		town = { id = id, buildings = {}, job = nil, nextOffscreen = 0, nextLiving = 0 }
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
		building = { model = model, parts = {}, rebuild = false, startAfter = 0, all = {}, footprint = nil, baseY = 0, topY = 0, lotId = nil, scaffold = nil, nextKeepOut = 0 }
		table.insert(town.buildings, building :: Building)
	end
	table.insert((building :: Building).parts, { part = part, color = color, flammability = flammability })
	charredTotal += 1
end

local function placePiece(entry: Charred)
	local part = entry.part
	local at = entry.at
	if not at or not part.Parent then
		return
	end
	part.AssemblyLinearVelocity = Vector3.zero
	part.AssemblyAngularVelocity = Vector3.zero
	part.Anchored = true
	part.Color = entry.color
	-- It comes up into place, the last bit of being lifted there, and not flying across town.
	part.CFrame = at * CFrame.new(0, -T.riseFrom, 0)
	TweenService:Create(part, TweenInfo.new(T.pieceSeconds, Enum.EasingStyle.Quad, Enum.EasingDirection.Out), { CFrame = at }):Play()
end

local function repairPart(entry: Charred, living: boolean?)
	if entry.at then
		placePiece(entry)
		return
	end
	charredTotal -= 1
	local part = entry.part
	if part.Parent and not part:GetAttribute("Burning") then
		part.Color = if living then entry.color else Rules.freshColor(entry.color)
		part:SetAttribute("Flammability", entry.flammability)
		part:SetAttribute("Temperature", nil)
		ThermalSim.ensure(part)
	end
end

local function charredIn(parts: { Charred }): number
	local n = 0
	for _, entry in parts do
		if not entry.at then
			n += 1
		end
	end
	return n
end

local function removeScaffold(building: Building)
	local scaffold = building.scaffold
	if scaffold then
		building.scaffold = nil
		scaffoldCount -= 1
		scaffold:Destroy()
	end
end

local function ensureScaffold(building: Building)
	if building.scaffold or not building.rebuild or not building.footprint or scaffoldCount >= Data.scaffold.maxAlive or not scaffoldFolder then
		return
	end
	building.scaffold = Scaffold.build(building.footprint, building.baseY, building.topY, scaffoldFolder)
	scaffoldCount += 1
end

-- They've got somewhere else to be now, or they can go home. A few of them say so.
local function tellResidents(lotId: string?, down: boolean)
	if not lotId then
		return
	end
	local affected = npcs:setLotDown(lotId, down)
	for i, entry in affected do
		if i > T.maxResidentLines then
			break
		end
		local npc = entry.npc
		local seed = (npc.seed or 0) + i
		if down then
			if entry.friend then
				local lines = Data.lines.homeLostFriend
				npcs:speak(npc, string.format(lines[seed % #lines + 1], entry.friend), T.shoutRadius)
			else
				local lines = if entry.kind == "home" then Data.lines.homeLost else Data.lines.workLost
				npcs:speak(npc, lines[seed % #lines + 1], T.shoutRadius)
			end
		elseif entry.kind == "home" then
			local lines = Data.lines.homeBack
			npcs:speak(npc, lines[seed % #lines + 1], T.shoutRadius)
		end
	end
	if #affected > 0 then
		log:info("town_residents_moved", { lot = lotId, down = down, people = #affected })
	end
end

-- The last piece is in. Anything knocked out again goes back on the list. Otherwise it's a building again.
local function finishRebuild(town: Town, building: Building): boolean
	local out: { Charred } = {}
	for _, entry in building.all do
		local at = entry.at
		if at and entry.part.Parent and (not entry.part.Anchored or (entry.part.Position - at.Position).Magnitude > 0.5) then
			table.insert(out, entry)
		end
	end
	if #out > 0 then
		Rules.rebuildOrder(out)
		building.parts = out
		return false
	end
	local model = building.model
	CollectionService:RemoveTag(model, "Rubble")
	CollectionService:AddTag(model, "Structure")
	model:SetAttribute("Integrity", T.wholeIntegrity)
	world:addSettlementDelta("damage", town.id, -T.wholeIntegrity)
	settlements:clearInterior(model) -- a quake may have pushed ground up where the floor goes
	Navigation.Invalidate(model:GetPivot().Position, 40)
	removeScaffold(building)
	tellResidents(building.lotId, false)
	log:info("town_rebuilt", { town = town.id, building = model.Name })
	return true
end

-- Forgets parts that have gone, and anything with nothing left to do.
local function tidy(town: Town)
	for i = #town.buildings, 1, -1 do
		local building = town.buildings[i]
		for j = #building.parts, 1, -1 do
			local entry = building.parts[j]
			if not entry.part.Parent then
				table.remove(building.parts, j)
				if not entry.at then
					charredTotal -= 1
				end
			end
		end
		if not building.model.Parent then
			charredTotal -= charredIn(building.parts)
			removeScaffold(building)
			if building.rebuild then
				tellResidents(building.lotId, false)
			end
			table.remove(town.buildings, i)
		elseif #building.parts == 0 then
			if not building.rebuild or finishRebuild(town, building) then
				table.remove(town.buildings, i)
			end
		end
	end
end

local function secondsFor(building: Building): number
	return if rushing then 1 elseif building.rebuild then T.rebuildSeconds else T.workSeconds
end

local function whereOf(entry: Charred): Vector3
	local at = entry.at
	return if at then at.Position else entry.part.Position
end

-- It's coming down: remember where every piece belongs, while it's all still there.
local function onCollapse(model: Model, cause: string)
	local id = model:GetAttribute("SettlementId")
	if not enabled() or typeof(id) ~= "string" then
		return
	end
	local town = townFor(id)
	-- What had already been burned gets repaired along with the rest.
	local burned: { [BasePart]: Charred } = {}
	for i = #town.buildings, 1, -1 do
		local building = town.buildings[i]
		if building.model == model then
			for _, entry in building.parts do
				burned[entry.part] = entry
			end
			charredTotal -= charredIn(building.parts)
			table.remove(town.buildings, i)
		end
	end
	local pieces: { Charred } = {}
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part.Anchored then
			local charred = burned[part]
			table.insert(pieces, {
				part = part,
				color = if charred then Rules.freshColor(charred.color) else part.Color,
				flammability = 0,
				at = part.CFrame,
			})
			if charred then
				part:SetAttribute("Flammability", charred.flammability)
			end
		end
	end
	Rules.rebuildOrder(pieces)
	local places: { Vector3 } = {}
	local baseY, topY = math.huge, -math.huge
	for _, piece in pieces do
		local at = (piece.at :: CFrame).Position
		table.insert(places, at)
		baseY, topY = math.min(baseY, at.Y), math.max(topY, at.Y)
	end
	local lot = model:GetAttribute("LotId")
	local lotId: string? = if typeof(lot) == "string" then lot else nil
	table.insert(town.buildings, {
		model = model,
		parts = pieces,
		rebuild = true,
		startAfter = os.clock() + T.rebuildDelay,
		all = table.clone(pieces),
		footprint = Rules.footprint(places),
		baseY = baseY,
		topY = topY,
		lotId = lotId,
		scaffold = nil,
		nextKeepOut = 0,
	})
	tellResidents(lotId, true)
	log:info("town_collapse_noted", { town = id, building = model.Name, cause = cause, pieces = #pieces })
end

-- Damaged but still standing: a little stronger now and then, off the town's record as it goes.
local function mendStanding()
	for _, model in CollectionService:GetTagged("Structure") do
		local id = model:GetAttribute("SettlementId")
		local integrity = model:GetAttribute("Integrity")
		if typeof(id) == "string" and typeof(integrity) == "number" and integrity < T.wholeIntegrity then
			local after, gained = Rules.mended(integrity)
			model:SetAttribute("Integrity", after)
			world:addSettlementDelta("damage", id, -gained)
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
		NPCLOD.setProp(npc, nil)
	end
	if npc.leash == job.leash then
		npcs:setLeash(npc, nil)
	end
	if finished then
		say(npc, if job.building.rebuild then "rebuildFinish" else "finish", npc.seed or 0)
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
	-- Checked every tick: DailyLife puts their tool away when they're called off, maybe after this starts.
	if not npc.rig.prop then
		NPCLOD.setProp(npc, Activities.Props.hammer, Activities.clipHand.hammer)
	end
	if not job.working then
		local at: Vector3 = npc.rig.root.Position
		local close = Vector3.new(at.X - job.leash.position.X, 0, at.Z - job.leash.position.Z).Magnitude <= T.workReach
		if close and not job.working then
			NPCLOD.stopActivity(npc)
		end
		if close or now >= job.giveUpAt then
			job.working = true
			job.nextPart = now + secondsFor(building)
			Navigation.Face(npc, whereOf(entry))
			NPCLOD.playActivity(npc, "hammer", Activities.Clips.hammer, true)
		end
		return
	end
	if now >= job.nextPart then
		job.nextPart = now + secondsFor(building)
		table.remove(building.parts)
		repairPart(entry)
		job.placed += 1
		local following = building.parts[#building.parts]
		if following then
			Navigation.Face(npc, whereOf(following))
		end
		-- On a rebuild they work their way round it, not stand at one wall.
		local footprint = building.footprint
		if following and building.rebuild and footprint and job.placed % T.moveEvery == 0 then
			job.turn += 1
			local leash = { kind = "hold", position = Rules.spotAround(footprint, npc.position, 1) }
			job.leash = leash
			npcs:setLeash(npc, leash)
			job.working = false
			job.giveUpAt = now + T.walkSeconds
			NPCLOD.stopActivity(npc)
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
	local npc = findWorker(town, whereOf(entry))
	if not npc then
		return false
	end
	local footprint = building.footprint
	if not footprint then
		local cf, size = building.model:GetBoundingBox()
		footprint = Rules.footprintOf(cf, size)
		building.footprint = footprint
	end
	local spot = Rules.spotAround(footprint :: Rules.Footprint, npc.position, 0)
	local leash = { kind = "hold", position = spot }
	npcs:setLeash(npc, leash)
	town.job = { npc = npc, building = building, leash = leash, working = false, giveUpAt = now + T.walkSeconds, nextPart = 0, placed = 0, turn = 0 }
	say(npc, if building.rebuild then "rebuildStart" else "start", npc.seed or 0)
	log:info("town_repair_started", { town = town.id, npc = npc.id, occupation = npc.occupation, parts = #building.parts })
	return true
end

-- Nobody stays in a building going back up: that's how you get walled in.
local function keepOut(town: Town, building: Building, now: number)
	local footprint = building.footprint
	if not building.rebuild or not footprint or now < building.nextKeepOut then
		return
	end
	building.nextKeepOut = now + T.keepOutEvery
	local worker = if town.job then town.job.npc else nil
	for _, npc in npcs:all() do
		if npc ~= worker and npc.settlementId == town.id and npc.rig and npc.tier == 0 and not npc.leash and not npc.knockedOut and not NPCCombat.engaged(npc) then
			if Rules.inside(footprint, npc.rig.root.Position) then
				NPCLOD.setDestination(npc, Rules.spotAround(footprint, npc.rig.root.Position, 0))
			end
		end
	end
end

local function stepTown(town: Town, now: number)
	tidy(town)
	local building: Building? = nil
	local living: Building? = nil
	for _, candidate in town.buildings do
		if Rules.isLiving(candidate.model.Name) then
			living = living or candidate
		elseif rushing or now >= candidate.startAfter then
			building = building or candidate
			ensureScaffold(candidate)
			keepOut(town, candidate, now)
		end
	end
	if living and now >= town.nextLiving then
		town.nextLiving = now + T.livingSeconds
		local entry = table.remove(living.parts)
		if entry then
			repairPart(entry, true)
		end
	end
	local job = town.job
	if job then
		stepJob(town, job, now)
		return
	end
	if not building then
		return
	end
	if startJob(town, building, now) then
		return
	end
	-- Nobody there to see, or nobody free: it still gets done, more slowly.
	if now >= town.nextOffscreen then
		town.nextOffscreen = now + (if rushing then 1 elseif building.rebuild then T.rebuildOffscreenSeconds else T.offscreenSeconds)
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
		description = "How places recover: status, burn (char the town parts around you), scar (burn the grass around you), heal (regrow every scar now), collapse (bring down the buildings around you), rush (toggle: no settling, a piece a second)",
		args = { { name = "action", type = "enum", options = { "status", "burn", "scar", "heal", "collapse", "rush" } } },
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
						local waiting = 0
						for _, building in town.buildings do
							if building.rebuild then
								waiting += 1
							end
						end
						table.insert(lines, string.format("%s: %d parts in %d buildings (%d collapsed), %s", id, parts, #town.buildings, waiting, if job then tostring(job.npc.name) .. (if job.working then " working" else " on the way") else "nobody on it"))
					end
				end
				return table.concat(lines, "\n")
			elseif a.action == "rush" then
				rushing = not rushing
				return if rushing then "rushing: no settling, a piece a second" else "back to normal speed"
			elseif a.action == "heal" then
				local n = #scars
				healScars(true)
				return string.format("regrew %d scars", n)
			end
			local root = ctx.player.Character and ctx.player.Character:FindFirstChild("HumanoidRootPart")
			if not root then
				return "no character"
			end
			if a.action == "collapse" then
				local n = world:damageStructures(root.Position, 40, 1000, "admin")
				return string.format("%d buildings came down", n)
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
	world = ctx.get("WorldStateService")
	settlements = ctx.get("SettlementService")
	world:setCollapseHook(onCollapse)
	FireSim.onCharred = record
	FireSim.onBurnedOut = scarAt
	registerAdmin(ctx.get("AdminService"))
end

function TownRepairService.start(_self: any, _ctx: any)
	local folder = Instance.new("Folder")
	folder.Name = "Scaffolds"
	folder.Parent = workspace
	scaffoldFolder = folder
	task.spawn(function()
		local mendAcc = 0
		while true do
			task.wait(T.tickSeconds)
			if enabled() then
				local now = os.clock()
				mendAcc += T.tickSeconds
				if mendAcc >= T.mendEvery then
					mendAcc = 0
					local mendOk, mendErr = pcall(mendStanding)
					if not mendOk then
						log:throttled("repair_mend", 60, "Error", "town_repair_failed", { err = mendErr })
					end
				end
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
