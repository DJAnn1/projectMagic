--!strict
--[[
	WildZoneService: permanent regions where the world's rules are broken (docs/WildZones.md).
	Content: Shared/World/WildZones. Decisions: World/WildZoneRules. Parts: World/WildZoneBuilder.

	PLACEMENT  Once, from the world seed, so every zone is in the same place on every server. Each also
	           becomes a place on the map (WorldStateService.addPOI).
	MAGIC      Each zone is a modifier that never runs out, so casts, reservoirs and environment facts all
	           read it the way they read a weather event, with no zone-specific code.
	PEOPLE     Four times a second, for each player: which zone are they in, and what does it do?
	           Gravity is a VectorForce on the character, as Cast/FieldEffects does. The owning client
	           simulates it. It stands aside while you fly or ride, and those have their own height checks.
	WAKING     Landmarks exist only while someone is near, and guards only once they're close. Nobody near
	           means no parts and nearly no cost: six distance checks per player.
	HEART      A server-side prompt. Touching it pays once ever per zone (data.wildZones.attuned), and its
	           harvest once per real day (data.wildZones.harvest), in the session-locked save, so hopping
	           servers doesn't reset either.
	PVP        On, as everywhere (owner, 2026-11-06).
	INTENTS    None. WildZoneState only tells you where you are.

	Flag: wild_zones_enabled. Admin: wildzone list | goto <zone> | where | reset.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Seed = require(Shared.Magic.Seed)
local W = require(Shared.World.WildZones)

local Server = script.Parent.Parent
local Rules = require(Server.World.WildZoneRules)
local WildZoneBuilder = require(Server.World.WildZoneBuilder)
local WorldConfig = require(Server.World.WorldConfig)
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

local WildZoneService = {
	name = "WildZoneService",
	dependencies = { "AdminService", "CreatureService", "InventoryService", "JournalService", "PlayerDataService", "ProgressionService", "ReservoirService", "WorldService", "WorldStateService" },
}

type ZoneState = {
	placed: Rules.Placed,
	model: Model?,
	group: any?, -- CreatureService's temporary den
	groupAt: number, -- os.clock(): when guards may come back
	nextBoost: number,
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
		record.harvest[id] = day
		local rng = Seed.random(worldService:getSeed(), "player:" .. player.UserId, "wild_zone:" .. id, day)
		for _, entry in Rules.rollHarvest(def, rng) do
			local added = inventory:give(player, entry.item, entry.n)
			if added > 0 then
				table.insert(said, string.format("%s x%d", entry.item, added))
			else
				log:info("wild_zone_no_room", { userId = player.UserId, item = entry.item })
			end
		end
		log:info("wild_zone_harvest", { userId = player.UserId, zone = id, day = day })
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
	prompt.Triggered:Connect(function(player: Player)
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
			-- Time crawls for what lives here as well.
			if p.def.crawl then
				local folder = workspace:FindFirstChild("Creatures")
				if folder then
					for _, model in folder:GetChildren() do
						local humanoid = model:FindFirstChildOfClass("Humanoid")
						local root = model:FindFirstChild("HumanoidRootPart")
						if humanoid and root and root:IsA("BasePart") and Vector3.new(root.Position.X - p.x, 0, root.Position.Z - p.z).Magnitude <= p.def.radius then
							StatusEffects.apply(humanoid, "zone_crawl", { duration = 1.5 })
						end
					end
				end
			end
		end
	end
end

-- ─── People ─────────────────────────────────────────────────────────────────

local function clearLift(person: PlayerState)
	local lift = person.lift
	if lift then
		person.lift = nil
		lift.force:Destroy()
		lift.attachment:Destroy()
	end
end

local function setLift(person: PlayerState, root: BasePart, mult: number)
	local lift = person.lift
	if lift and lift.root ~= root then
		clearLift(person)
		lift = nil
	end
	if not lift then
		local attachment = Instance.new("Attachment")
		attachment.Name = FORCE_NAME
		attachment.Parent = root
		local force = Instance.new("VectorForce")
		force.Name = FORCE_NAME
		force.RelativeTo = Enum.ActuatorRelativeTo.World
		force.ApplyAtCenterOfMass = true
		force.Attachment0 = attachment
		force.Parent = root
		lift = { root = root, force = force, attachment = attachment }
		person.lift = lift
	end
	-- Net acceleration = mult x g downward: add (1 - mult) x g upward against normal gravity.
	(lift :: Lift).force.Force = Vector3.new(0, root.AssemblyMass * workspace.Gravity * (1 - mult), 0)
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
				state.data.wildZones = { found = {}, attuned = {}, harvest = {} }
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

local function planWorld()
	world:awaitReady()
	local placement = world:placement()
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
		local zone: ZoneState = { placed = p, model = nil, group = nil, groupAt = 0, nextBoost = 0 }
		table.insert(zones, zone)
		byPlaced[p] = zone
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
	registerAdmin(ctx.get("AdminService"))
end

function WildZoneService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		people[player] = nil
	end)
	task.spawn(function()
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
