--!strict
--[[
	WildZoneService: permanent regions where the world's rules are broken (docs/WildZones.md).
	Content: Shared/World/WildZones. Decisions: World/WildZoneRules. Parts: World/WildZoneBuilder.

	PLACEMENT  Once, from the world seed, so every zone is in the same place on every server. Each also
	           becomes a place on the map (WorldStateService.addPOI).
	TERRAIN    Generated ops applied as each chunk builds (WorldStateService.addGeneratedOps), so they're
	           never saved. The first chunk to ask triggers the plan, so a zone near the spawn is shaped
	           even if its chunks build before this service's own thread has run.
	EVERYTHING ELSE  Creatures obey a zone's gravity, crawl and healing. Loose objects hop when the Moor
	           lets go. Only what's near an awake zone is touched.
	RUMOURS    Asking a townsperson for rumours may name a zone you don't know (NPCService.setRumorHook):
	           a journal line, and its spot uncovered on your map (MapService.revealArea).
	MAGIC      Each zone is a modifier that never runs out, so casts, reservoirs and environment facts all
	           read it the way they read a weather event, with no zone-specific code.
	PEOPLE     Four times a second, for each player: which zone are they in, and what does it do?
	           Gravity is a VectorForce on the character, as Cast/FieldEffects does. The owning client
	           simulates it. It stands aside while you fly or ride, and those have their own height checks.
	WAKING     Landmarks exist only while someone is near, and guards only once they're close. Nobody near
	           means no parts and nearly no cost: six distance checks per player.
	HEART      A server-side prompt. Touching it pays once ever per zone (data.wildZones.attuned), and its
	           harvest once per real day (data.wildZones.harvest), in the session-locked save, so hopping
	           servers doesn't reset either. Bags too full for any of it: the day isn't spent.
	PVP        On, as everywhere (owner, 2026-11-06).
	INTENTS    None. WildZoneState only tells you where you are.

	Flag: wild_zones_enabled. Admin: wildzone list | goto <zone> | where | reset.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Seed = require(Shared.Magic.Seed)
local W = require(Shared.World.WildZones)

local Server = script.Parent.Parent
local PromptRouter = require(Server.Interact.PromptRouter)
local Rules = require(Server.World.WildZoneRules)
local WildZoneBuilder = require(Server.World.WildZoneBuilder)
local WorldConfig = require(Server.World.WorldConfig)
local WorldGen = require(Server.World.WorldGen)
local Targeting = require(Server.Magic.Cast.Targeting)
local Creatures = require(Server.Creatures.Data.Creatures)
local Damage = require(Server.Magic.Cast.Damage)
local FireSim = require(Server.Magic.Cast.FireSim)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local TimeZones = require(Server.Magic.Cast.TimeZones)
local Util = require(Server.Admin.Util)

local STEP_SECONDS = 0.25
local FORCE_NAME = "WildZoneForce"
local BOOST_EVERY = 20 -- seconds between refreshing a zone's fire boost
local BURN_DPS = 6
local LOOSE_CAP = 30 -- loose objects the Moor throws up at once

local WildZoneService = {
	name = "WildZoneService",
	dependencies = { "AdminService", "CreatureService", "InventoryService", "JournalService", "MapService", "NPCService", "PlayerDataService", "ProgressionService", "ReservoirService", "WorldService", "WorldStateService" },
}

local RUMOR_REVEAL = 96 -- studs of map uncovered around a zone you've heard about

type ZoneState = {
	placed: Rules.Placed,
	model: Model?,
	group: any?, -- CreatureService's temporary den
	groupAt: number, -- os.clock(): when guards may come back
	nextBoost: number,
	tideOn: boolean, -- for noticing the moment the ground lets go
}

type Lift = { root: BasePart, force: VectorForce, attachment: Attachment }
type PlayerState = { zone: ZoneState?, lift: Lift? }

local log: any = nil
local world: any = nil
local worldService: any = nil
local creatures: any = nil
local inventory: any = nil
local journal: any = nil
local playerData: any = nil
local progression: any = nil
local reservoirs: any = nil
local map: any = nil

local planned = false
local opsByChunk: { [string]: { any } } = {}
local creatureLifts: { [BasePart]: Lift } = {}

local zones: { ZoneState } = {}
local placed: { Rules.Placed } = {}
local byPlaced: { [Rules.Placed]: ZoneState } = {}
local people: { [Player]: PlayerState } = {}
local live = false -- are the modifiers and POIs in force?

local function enabled(): boolean
	return FeatureFlags.get("wild_zones_enabled") == true
end

local function heightAt(x: number, z: number): number
	return world:surfaceHeight(x, z)
end

local function recordOf(state: any): any
	local record = state.data.wildZones
	if not record then
		record = {}
		state.data.wildZones = record
	end
	record.found = record.found or {}
	record.attuned = record.attuned or {}
	record.harvest = record.harvest or {}
	record.heard = record.heard or {}
	return record
end

local function bestBranch(state: any): string?
	local best, bestXp = nil, -1
	for branchId in state.data.progression.unlocked do
		local xp = state.data.progression.xp[branchId] or 0
		if xp > bestXp then
			best, bestXp = branchId, xp
		end
	end
	return best
end

-- ─── The heart ──────────────────────────────────────────────────────────────

local function touchHeart(zone: ZoneState, player: Player)
	local state = playerData:get(player)
	if not state then
		return
	end
	local record = recordOf(state)
	local def = zone.placed.def
	local id = zone.placed.id
	local said: { string } = {}

	if not record.attuned[id] then
		record.attuned[id] = os.time()
		progression:awardQuest(player, bestBranch(state), W.attuneXp)
		journal:log(player, "discovery", string.format("You touched the heart of %s. %s", def.name, def.rule))
		table.insert(said, string.format("%d XP", W.attuneXp))
	end

	local day = Rules.dayOf(os.time())
	if Rules.canHarvest(record.harvest, id, day) then
		-- The same roll however often you try today, so emptying your bags can't re-roll it.
		local rng = Seed.random(worldService:getSeed(), "player:" .. player.UserId, "wild_zone:" .. id, day)
		local gave, missed = 0, 0
		for _, entry in Rules.rollHarvest(def, rng) do
			local added = inventory:give(player, entry.item, entry.n)
			if added > 0 then
				gave += 1
				table.insert(said, string.format("%s x%d", entry.item, added))
			else
				missed += 1
				log:info("wild_zone_no_room", { userId = player.UserId, item = entry.item })
			end
		end
		-- Nothing fit: the day isn't spent, so a full bag doesn't cost you the harvest.
		if gave > 0 then
			record.harvest[id] = day
			log:info("wild_zone_harvest", { userId = player.UserId, zone = id, day = day, missed = missed })
		elseif missed > 0 then
			Net.fire("Notify", player, string.format("Your bags are too full for what %s has for you. Make room and come back.", def.name))
			return
		end
	end

	if #said > 0 then
		Net.fire("Notify", player, string.format("%s gives: %s.", def.name, table.concat(said, ", ")))
	else
		Net.fire("Notify", player, string.format("%s has nothing more for you today.", def.name))
	end
end

-- ─── Waking ─────────────────────────────────────────────────────────────────

local function wake(zone: ZoneState)
	local model, heart = WildZoneBuilder.build(zone.placed, worldService:getSeed(), heightAt)
	zone.model = model
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Touch the heart"
	prompt.ObjectText = zone.placed.def.name
	prompt.HoldDuration = 1
	prompt.MaxActivationDistance = 16
	prompt.RequiresLineOfSight = false
	prompt.Parent = heart
	PromptRouter.connect(prompt, function(player: Player)
		touchHeart(zone, player)
	end)
	log:info("wild_zone_awake", { zone = zone.placed.id })
end

local function sleep(zone: ZoneState)
	if zone.model then
		zone.model:Destroy()
		zone.model = nil
	end
	if zone.group then
		creatures:clearGroup(zone.group)
		zone.group = nil
	end
end

-- Once a second: wake and sleep landmarks, and bring out the heart's guards.
local function wakeTick()
	local now = os.clock()
	local wakeRadius = Creatures.tuning.wakeRadius
	local camp = Creatures.tuning.campRadius
	for _, zone in zones do
		local p = zone.placed
		local nearest = math.huge
		for _, player in Players:GetPlayers() do
			local root = player.Character and player.Character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				nearest = math.min(nearest, Vector3.new(root.Position.X - p.x, 0, root.Position.Z - p.z).Magnitude)
			end
		end
		if zone.model and nearest > p.def.radius + W.sleepMargin then
			sleep(zone)
		elseif not zone.model and nearest <= p.def.radius + W.wakeMargin then
			wake(zone)
		end
		if zone.model then
			-- Guards: only with the ground built, and never popping into being on top of someone.
			local alive = if zone.group then creatures:groupAlive(zone.group) else 0
			if alive == 0 and now >= zone.groupAt and nearest <= wakeRadius and nearest > camp and world:isChunkBuilt(p.x, p.z) then
				if zone.group then
					creatures:clearGroup(zone.group)
				end
				local at = Vector3.new(p.x + 14, heightAt(p.x, p.z), p.z + 14)
				zone.group = creatures:spawnGroup(p.def.creatures.type, p.def.creatures.count, at)
				zone.groupAt = now + W.creatureRespawn
			end
			-- Fire's boost expires, so it's topped up while anyone could see it.
			local spread = p.def.fireSpread
			if spread and now >= zone.nextBoost then
				zone.nextBoost = now + BOOST_EVERY
				FireSim.boost(Vector3.new(p.x, heightAt(p.x, p.z), p.z), p.def.radius, spread, BOOST_EVERY + 2)
			end
		end
	end
end

-- ─── Forces ─────────────────────────────────────────────────────────────────

local function newLift(root: BasePart): Lift
	local attachment = Instance.new("Attachment")
	attachment.Name = FORCE_NAME
	attachment.Parent = root
	local force = Instance.new("VectorForce")
	force.Name = FORCE_NAME
	force.RelativeTo = Enum.ActuatorRelativeTo.World
	force.ApplyAtCenterOfMass = true
	force.Attachment0 = attachment
	force.Parent = root
	return { root = root, force = force, attachment = attachment }
end

local function endLift(lift: Lift)
	lift.force:Destroy()
	lift.attachment:Destroy()
end

-- Net acceleration = mult x g downward: add (1 - mult) x g upward against normal gravity.
local function pull(lift: Lift, mult: number)
	lift.force.Force = Vector3.new(0, lift.root.AssemblyMass * workspace.Gravity * (1 - mult), 0)
end

-- ─── Creatures and loose objects ────────────────────────────────────────────

-- What the zone does to whatever lives in it. A creature is server-owned, so the server can knock it
-- loose itself. Budget: the awake zones' creatures only, and creatures_max_alive caps those.
local function stepCreatures(zone: ZoneState, t: number, letGo: boolean, present: { [BasePart]: boolean })
	local folder = workspace:FindFirstChild("Creatures")
	if not folder then
		return
	end
	local p = zone.placed
	local def = p.def
	for _, model in folder:GetChildren() do
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		local root = model:FindFirstChild("HumanoidRootPart")
		if humanoid and humanoid.Health > 0 and root and root:IsA("BasePart") and not root.Anchored then
			local at = root.Position
			if Vector3.new(at.X - p.x, 0, at.Z - p.z).Magnitude <= def.radius and not TimeZones.stopped(at) then
				if def.crawl then
					StatusEffects.apply(humanoid, "zone_crawl", { duration = 0.75 })
				end
				local heal = def.healShare
				if heal and humanoid.Health < humanoid.MaxHealth then
					Damage.heal(humanoid, humanoid.MaxHealth * heal * STEP_SECONDS, nil)
				end
				local height = at.Y - math.max(heightAt(at.X, at.Z), WorldConfig.SEA_LEVEL)
				local mult = if model:GetAttribute("GravityHeld") then nil else Rules.gravityAt(def, t, height)
				if mult then
					present[root] = true
					local lift = creatureLifts[root]
					if not lift then
						lift = newLift(root)
						creatureLifts[root] = lift
					end
					pull(lift, mult)
				end
				if letGo and def.tide then
					humanoid:ChangeState(Enum.HumanoidStateType.Freefall)
					root.AssemblyLinearVelocity += Vector3.new(0, def.tide.kick, 0)
				end
			end
		end
	end
end

-- The moment the Moor lets go, whatever isn't nailed down hops too. Capped, and rare: it's every 15 s.
local function liftLooseObjects(zone: ZoneState)
	local p = zone.placed
	local tide = p.def.tide
	if not tide then
		return
	end
	local params = OverlapParams.new()
	params.MaxParts = LOOSE_CAP * 4
	local center = Vector3.new(p.x, heightAt(p.x, p.z), p.z)
	local seen: { [BasePart]: boolean } = {}
	local moved = 0
	for _, part in workspace:GetPartBoundsInRadius(center, p.def.radius, params) do
		if moved >= LOOSE_CAP then
			break
		end
		if not part.Anchored and not Targeting.characterOf(part) and not CollectionService:HasTag(part, "NoMagicEdit") then
			local root = part.AssemblyRootPart
			if root and not seen[root] then
				seen[root] = true
				local ok, owner = pcall(root.GetNetworkOwner, root)
				if ok and owner == nil then
					root.AssemblyLinearVelocity += Vector3.new(0, tide.kick, 0)
					moved += 1
				end
			end
		end
	end
end

local function stepZones(t: number)
	local present: { [BasePart]: boolean } = {}
	for _, zone in zones do
		if zone.model then
			local tide = zone.placed.def.tide
			local on = tide ~= nil and t % tide.every < tide.lasts
			local letGo = on and not zone.tideOn
			zone.tideOn = on
			stepCreatures(zone, t, letGo, present)
			if letGo then
				liftLooseObjects(zone)
			end
		end
	end
	for root, lift in creatureLifts do
		if not present[root] or not root.Parent then
			creatureLifts[root] = nil
			endLift(lift)
		end
	end
end

-- ─── People ─────────────────────────────────────────────────────────────────

local function clearLift(person: PlayerState)
	local lift = person.lift
	if lift then
		person.lift = nil
		endLift(lift)
	end
end

local function setLift(person: PlayerState, root: BasePart, mult: number)
	local lift = person.lift
	if lift and lift.root ~= root then
		clearLift(person)
		lift = nil
	end
	if not lift then
		lift = newLift(root)
		person.lift = lift
	end
	pull(lift :: Lift, mult)
end

local function enterZone(player: Player, person: PlayerState, zone: ZoneState?)
	person.zone = zone
	if not zone then
		Net.fire("WildZoneState", player, { id = false })
		return
	end
	local def = zone.placed.def
	Net.fire("WildZoneState", player, { id = zone.placed.id })
	Net.fire("Notify", player, def.arrive)
	local state = playerData:get(player)
	if state then
		local record = recordOf(state)
		if not record.found[zone.placed.id] then
			record.found[zone.placed.id] = os.time()
			journal:log(player, "discovery", string.format("You found %s. %s", def.name, def.rule))
			log:info("wild_zone_found", { userId = player.UserId, zone = zone.placed.id })
		end
	end
end

local function stepPlayer(player: Player, dt: number, t: number)
	local person = people[player]
	if not person then
		person = { zone = nil, lift = nil }
		people[player] = person
	end
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not character or not humanoid or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
		clearLift(person)
		return
	end
	local p = root.Position
	local found = Rules.zoneAt(placed, p.X, p.Z)
	local zone = if found then byPlaced[found] else nil
	if zone ~= person.zone then
		enterZone(player, person, zone)
	end
	if not zone then
		clearLift(person)
		return
	end
	local def = zone.placed.def

	-- A Timestop freezes the zone's rules as well as everything else.
	if TimeZones.stopped(p) then
		return
	end

	-- Gravity stands aside for flight and riding: they steer your height themselves, and check it.
	local free = not character:GetAttribute("GravityFlight") and not character:GetAttribute("TravelStyle") and not character:GetAttribute("GravityHeld")
	local height = p.Y - math.max(heightAt(p.X, p.Z), WorldConfig.SEA_LEVEL)
	local mult = if free then Rules.gravityAt(def, t, height) else nil
	if mult then
		setLift(person, root, mult)
	else
		clearLift(person)
	end

	if def.crawl then
		StatusEffects.apply(humanoid, "zone_crawl", { duration = 0.75 })
	end
	local pour = def.reservoirPerSecond
	if pour then
		local reservoir = reservoirs:get(player)
		if reservoir and reservoir.current < reservoir.max then
			reservoir.current = math.min(reservoir.max, reservoir.current + reservoir.max * pour * dt)
			reservoirs:push(player)
		end
	end
	local heal = def.healShare
	if heal and humanoid.Health < humanoid.MaxHealth then
		Damage.heal(humanoid, humanoid.MaxHealth * heal * dt, nil)
	end
	if def.burnsSwimmers and humanoid:GetState() == Enum.HumanoidStateType.Swimming then
		StatusEffects.apply(humanoid, "burning", { duration = 1.5, magnitude = BURN_DPS })
	end
end

-- ─── Switching on and off ───────────────────────────────────────────────────

local function setLive(on: boolean)
	if live == on then
		return
	end
	live = on
	for _, zone in zones do
		if on then
			world:addModifier(Rules.modifierOf(zone.placed))
		else
			world:removeModifier("wild_zone:" .. zone.placed.id)
			sleep(zone)
		end
	end
	if not on then
		for root, lift in creatureLifts do
			creatureLifts[root] = nil
			endLift(lift)
		end
		for player, person in people do
			clearLift(person)
			if person.zone then
				person.zone = nil
				Net.fire("WildZoneState", player, { id = false })
			end
		end
	end
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "wildzone",
		category = "World",
		description = "Wild zones: list them, go to one, say which you're in, or forget your visits and harvests",
		args = {
			{ name = "action", type = "enum", options = { "list", "goto", "where", "reset" } },
			{ name = "zone", type = "enum", options = table.clone(W.ids), optional = true },
		},
		handler = function(ctx: any, a: any)
			if #zones == 0 then
				return "no wild zones placed (the world may still be generating)"
			end
			if a.action == "list" then
				local lines = {}
				for _, zone in zones do
					local p = zone.placed
					table.insert(lines, string.format("%s  %s  (%.0f, %.0f) r%d in %s  %s", p.id, p.def.name, p.x, p.z, p.def.radius, p.biome, if zone.model then "awake" else "asleep"))
				end
				return table.concat(lines, "\n")
			elseif a.action == "reset" then
				local state = playerData:get(ctx.player)
				if not state then
					return "not ready"
				end
				state.data.wildZones = { found = {}, attuned = {}, harvest = {}, heard = {} }
				return "forgotten"
			elseif a.action == "where" then
				local root = Util.rootOf(ctx.player)
				local here = root and Rules.zoneAt(placed, root.Position.X, root.Position.Z)
				return if here then here.def.name .. ": " .. here.def.rule else "not in a wild zone"
			end
			if not a.zone then
				return "which? " .. table.concat(W.ids, ", ")
			end
			for _, zone in zones do
				if zone.placed.id == a.zone then
					local ok, message = Util.teleport(ctx.player, world, Vector3.new(zone.placed.x, 0, zone.placed.z), true)
					return if ok then zone.placed.def.name else message
				end
			end
			return a.zone .. " found nowhere to go in this world"
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

-- The plan and each zone's terrain. Yields nowhere: a chunk's build may be the first to ask.
local function planWorld()
	local placement = world:placement()
	if planned or not placement then
		return -- not ready yet: a chunk can't build before it is, but don't mark an empty plan as done
	end
	planned = true
	local cells: { Rules.Cell } = {}
	for _, cell in world:index().cells do
		table.insert(cells, { x = cell.x, z = cell.z, biome = cell.sample.biome, ocean = cell.ocean, slope = cell.slope, coastDistance = cell.coastDistance })
	end
	local towns: { Rules.Spot } = {}
	local pois: { Rules.Spot } = {}
	for _, poi in placement.pois do
		table.insert(if poi.settlement then towns else pois, { x = poi.x, z = poi.z })
	end
	placed = Rules.plan(worldService:getSeed(), cells, towns, pois)
	for _, p in placed do
		local zone: ZoneState = { placed = p, model = nil, group = nil, groupAt = 0, nextBoost = 0, tideOn = false }
		table.insert(zones, zone)
		byPlaced[p] = zone
		local ops = Rules.terrainOps(p, worldService:getSeed(), heightAt, WorldConfig.SEA_LEVEL)
		for _, op in ops do
			for _, key in Rules.chunksOf(op, WorldGen.chunkOf) do
				local list = opsByChunk[key]
				if not list then
					list = {}
					opsByChunk[key] = list
				end
				table.insert(list, op)
			end
		end
		log:info("wild_zone_terrain", { zone = p.id, ops = #ops })
		world:addPOI({
			id = "wild_zone_" .. p.id,
			type = "wild_zone",
			name = p.def.name,
			x = p.x,
			z = p.z,
			biome = p.biome,
			radius = p.def.radius,
			hidden = false,
			grants = {},
			settlement = nil,
			hints = {},
		})
	end
	log:info("wild_zones_placed", { zones = #placed, wanted = #W.ids })
end

-- Where each wild zone lies, for townspeople to talk about (Services/RumorService).
function WildZoneService.places(_self: any): { { id: string, name: string, x: number, z: number } }
	local out = {}
	for _, p in placed do
		table.insert(out, { id = p.id, name = p.def.name, x = p.x, z = p.z })
	end
	return out
end

function WildZoneService.init(_self: any, ctx: any)
	log = ctx.log
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	creatures = ctx.get("CreatureService")
	inventory = ctx.get("InventoryService")
	journal = ctx.get("JournalService")
	playerData = ctx.get("PlayerDataService")
	progression = ctx.get("ProgressionService")
	reservoirs = ctx.get("ReservoirService")
	map = ctx.get("MapService")
	registerAdmin(ctx.get("AdminService"))
	world:addGeneratedOps(function(cx: number, cz: number): { any }
		if not enabled() then
			return {}
		end
		planWorld()
		return opsByChunk[cx .. "," .. cz] or {}
	end)
	-- Someone asked a townsperson for rumours: they may know of a zone you don't.
	ctx.get("NPCService"):setRumorHook(function(player: Player, npc: any): string?
		local state = playerData:get(player)
		if not state or not enabled() or not planned then
			return nil
		end
		local record = recordOf(state)
		local at: Vector3 = npc.position
		local roll = Seed.random(worldService:getSeed(), "player:" .. player.UserId, "wild_rumor:" .. tostring(npc.id)):NextNumber()
		local zone = Rules.rumorFor(placed, record.found, record.heard, at.X, at.Z, roll)
		if not zone then
			return nil
		end
		record.heard[zone.id] = os.time()
		local text = string.format(zone.def.rumor, Rules.bearing(at.X, at.Z, zone.x, zone.z))
		journal:log(player, "rumor", string.format("%s said: \"%s\"", tostring(npc.name), text))
		map:revealArea(player, zone.x, zone.z, RUMOR_REVEAL)
		Net.fire("Notify", player, string.format("Marked on your map: %s.", zone.def.name))
		log:info("wild_zone_rumor", { userId = player.UserId, zone = zone.id, npc = npc.id })
		return text
	end)
end

function WildZoneService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		people[player] = nil
	end)
	task.spawn(function()
		world:awaitReady()
		planWorld()
		local acc = 0
		local function step()
			local on = enabled()
			setLive(on)
			if not on then
				return
			end
			local t = workspace:GetServerTimeNow()
			for _, player in Players:GetPlayers() do
				stepPlayer(player, STEP_SECONDS, t)
			end
			stepZones(t)
			acc += STEP_SECONDS
			if acc >= 1 then
				acc = 0
				wakeTick()
			end
		end
		while true do
			task.wait(STEP_SECONDS)
			-- One failure mustn't stop this loop: every zone on this server would stop working.
			local ok, err = pcall(step)
			if not ok then
				log:throttled("wild_zone_step", 30, "Error", "wild_zone_step_failed", { err = err })
			end
		end
	end)
end

return WildZoneService
