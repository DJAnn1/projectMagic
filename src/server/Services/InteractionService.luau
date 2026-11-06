--!strict
--[[
	InteractionService: every interactable thing in the world (docs/Buildings.md §2-4).

	Generators tag parts "Interactable" with an Interactable kind (Shared/World/Interactables).
	This service gives each one a ProximityPrompt from that registry and routes the server-side
	Triggered event to the kind's handler; clients never send anything for prompts, and every
	handler re-checks that the player is alive and in reach.

	HANDLERS
		door       open / close (Interact/Doors). From the inside a locked door just unbolts.
		           From the outside, locked doors try, in order:
		             1. a key: an item whose definition has data.opens == the door's KeyId, or a
		                skeleton key (data.opens = "*", lock tier <= 2)
		             2. metal magic: Metallurgy Adept or Ferromancy Novice unlocks it for
		                8 x LockTier reservoir
		             3. a lockpick: 55% (tier 1) / 40% (tier 2); a failed pick breaks half the time
		           Forcing a lock you aren't allowed past is a crime (Interact/Access, severity 2):
		           the first press warns you, a second press within 6 s goes ahead.
		seat       beds ("Rest": Resting reservoir regen, +1.5% max health a second) and meditation
		           mats ("Meditate": the Meditating rate, 4x). Jump to get up.
		container  ContainerService:open (chests, barrels, crates, wardrobes; your own storage at home)
		station    CraftingService:open (forge, workbench, loom, hearth, alchemy table, enchanting desk)
		light      toggle a lamp or fireplace by hand until the next dusk/dawn (Interact/Lamps lights
		           them automatically at night in occupied buildings near players)
		book       read the shelf's seeded book (Interact/Data/Books): study XP, or lore if the branch
		           is still locked; once per shelf
		notice     opens your Journal's quests (offers and the trouble nearby)
		drink      a well: +10% max health, puts out burning (20 s per player)
		dummy      resets the training dummy's damage readout (it never dies; it heals after 4 s)
		ward       a shrine's ward stone: a Ward (all magic resisted by a power-3 ward) for 5 min;
		           10 min per player per stone
		insight    a magic school's focus crystal: a one-time insight in its domain
		deed / decor   HousingService (buy or give up a house; pick up your furniture)

	NPC DOORS: a walking NPC opens the door on its route (NPC/NavigationService), if it's unlocked or
	the NPC lives or works there; doors close themselves after Doors.AUTO_CLOSE seconds.

	ADMIN (category World)
		buildingcheck [kind] [teleport]   teleports you inside the nearest built building of a kind
		                                  and prints a checklist: floor, terrain, door swing, prompts,
		                                  interactables, beds vs NPC homes, containers, part count
		buildingaudit                     the same checks over every built building (no teleport)
		door <open|close|lock|unlock>     the nearest door within 20 studs
		lights                            lamps registered, lit now, and the cap
		lamps <on|off|auto>               force every lamp near you on/off for this phase, or back to auto
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local ServerScriptService = game:GetService("ServerScriptService")

local Shared = ReplicatedStorage.Shared
local Registry = require(Shared.Magic.Registry)
local Net = require(Shared.Net)
local Topics = require(Shared.Core.Topics)
local Seed = require(Shared.Magic.Seed)
local MagicCore = require(Shared.Magic.MagicCore)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local Interactables = require(Shared.World.Interactables)

local Server = ServerScriptService.Server
local Inventory = require(Server.Items.Inventory)
local Access = require(Server.Interact.Access)
local Doors = require(Server.Interact.Doors)
local Lamps = require(Server.Interact.Lamps)
local Books = require(Server.Interact.Data.Books)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local Resistances = require(Server.Magic.Cast.Resistances)
local WorldClock = require(Server.NPC.WorldClock)
local Util = require(Server.Admin.Util)

local TRIGGER_GAP = 0.25 -- seconds between two prompt uses by one player
local CONFIRM_SECONDS = 6
local REST_HEAL_SHARE = 0.015
local PICK_CHANCE = { 0.55, 0.4 }
local MAGIC_COST_PER_TIER = 8
local DRINK_COOLDOWN = 20
local WARD_COOLDOWN = 600
local WARD_SECONDS = 300
local DUMMY_IDLE_RESET = 4

local InteractionService = {
	name = "InteractionService",
	dependencies = {
		"NetService",
		"PlayerDataService",
		"WorldService",
		"WorldStateService",
		"InventoryService",
		"ReservoirService",
		"ContainerService",
		"CraftingService",
		"SettlementService",
		"ProgressionService",
		"HousingService",
		"AdminService",
	},
}

local log: any = nil
local bus: any = nil
local flags: any = nil
local playerData: any = nil
local worldService: any = nil
local world: any = nil
local inventory: any = nil
local reservoirs: any = nil
local containers: any = nil
local crafting: any = nil
local settlements: any = nil
local progression: any = nil
local housing: any = nil

local prompts: { [BasePart]: ProximityPrompt } = {}
local lastTrigger: { [Player]: number } = {}
local pending: { [Player]: { id: string, method: string, expires: number } } = {}
local pickAttempts: { [Player]: number } = {}
local resting: { [Seat]: Player } = {}
local cooldowns: { [Player]: { [string]: number } } = {}

type Dummy = { humanoid: Humanoid, label: TextLabel, last: number, total: number, hits: number, firstHit: number, lastHit: number, health: number }
local dummies: { [Humanoid]: Dummy } = {}

-- Per-player cooldown on a key; true (and starts it) when ready.
local function ready(player: Player, key: string, seconds: number): boolean
	local mine = cooldowns[player] or {}
	cooldowns[player] = mine
	local t = os.clock()
	if (mine[key] or 0) > t then
		return false
	end
	mine[key] = t + seconds
	return true
end

local function notify(player: Player, text: string)
	Net.fire("Notify", player, text)
end

local function defOf(part: Instance): Interactables.Def?
	local kind = part:GetAttribute("Interactable")
	return if typeof(kind) == "string" then Interactables[kind] else nil
end

local function aliveRoot(player: Player): (BasePart?, Humanoid?)
	local character = player.Character
	local root = character and character:FindFirstChild("HumanoidRootPart") :: BasePart?
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not root or not humanoid or humanoid.Health <= 0 then
		return nil, nil
	end
	return root, humanoid
end

-- ─── Doors ──────────────────────────────────────────────────────────────────

local function doorText(leaf: BasePart)
	local prompt = prompts[leaf]
	if not prompt then
		return
	end
	if Doors.isOpen(leaf) then
		prompt.ActionText, prompt.ObjectText = "Close", "Door"
	elseif leaf:GetAttribute("Locked") == true then
		prompt.ActionText, prompt.ObjectText = "Unlock", "Locked door"
	else
		prompt.ActionText, prompt.ObjectText = "Open", "Door"
	end
end

-- A key in the grid that opens this door (by its definition's data.opens).
local function hasKey(player: Player, leaf: BasePart): string?
	local inv = inventory:inventoryOf(player)
	if not inv then
		return nil
	end
	local keyId = leaf:GetAttribute("KeyId")
	local tier = leaf:GetAttribute("LockTier") or 1
	for _, rec in inv.slots do
		local def = ItemDatabase.get(rec.i)
		local opens = def and def.data and def.data.opens
		if opens == keyId or (opens == "*" and tier <= 2) then
			return (def :: any).name
		end
	end
	return nil
end

local function canMetalMagic(player: Player): boolean
	local data = playerData:get(player)
	if not data then
		return false
	end
	return MagicCore.masteryTier(data.caster, "metallurgy") >= 3 or MagicCore.masteryTier(data.caster, "ferromancy") >= 2
end

-- First use of a lock-forcing method on a door you aren't allowed past only warns.
local function confirmed(player: Player, leaf: BasePart, method: string, warning: string): boolean
	local id = leaf:GetAttribute("InteractId") :: string
	local p = pending[player]
	local t = os.clock()
	if p and p.id == id and p.method == method and t <= p.expires then
		pending[player] = nil
		return true
	end
	pending[player] = { id = id, method = method, expires = t + CONFIRM_SECONDS }
	notify(player, warning)
	return false
end

local function crime(player: Player, leaf: BasePart, what: string)
	local building = Access.buildingOf(leaf)
	if Access.permits(player, building) then
		return
	end
	bus:publish(Topics.CrimeCommitted, {
		player = player,
		settlementId = Access.settlementOf(building),
		severity = Access.LOCKPICK_SEVERITY,
		reason = what .. " at " .. Access.describe(building),
	})
end

local function useDoor(player: Player, leaf: BasePart)
	if Doors.isOpen(leaf) then
		if not Doors.close(leaf) then
			notify(player, "Someone's in the doorway.")
		end
		return
	end
	if leaf:GetAttribute("Locked") ~= true or flags.get("buildings_lock_doors") == false then
		Doors.open(leaf)
		return
	end
	-- The owner of a house has its key.
	local kind, ownerId = Access.ownerOf(Access.buildingOf(leaf))
	if kind == "player" and ownerId == player.UserId then
		Doors.unlock(leaf)
		Doors.open(leaf)
		return
	end
	-- From the inside a lock is just a bolt: nobody gets shut in. (The leaf's LookVector points
	-- out to the street, so the interior is behind it.)
	local root = aliveRoot(player)
	local closedCF = leaf:GetAttribute("ClosedCFrame")
	if root and typeof(closedCF) == "CFrame" and (root.Position - closedCF.Position):Dot(-closedCF.LookVector) > 0 then
		Doors.unlock(leaf)
		Doors.open(leaf)
		notify(player, "You slide the bolt back.")
		return
	end
	local permitted = Access.permits(player, Access.buildingOf(leaf))
	local tier = (leaf:GetAttribute("LockTier") :: number?) or 1

	-- 1. A key.
	local key = hasKey(player, leaf)
	if key then
		Doors.unlock(leaf)
		Doors.open(leaf)
		notify(player, "Unlocked with the " .. key .. ".")
		return
	end

	-- 2. Metal magic: feel for the pins and turn them.
	if canMetalMagic(player) then
		local state = reservoirs:get(player)
		local cost = MAGIC_COST_PER_TIER * tier
		if state and state.current >= cost then
			if not permitted and not confirmed(player, leaf, "magic", "This isn't your door: turning the lock with magic is a crime here. Use it again to go ahead.") then
				return
			end
			state.current -= cost
			reservoirs:push(player)
			Doors.unlock(leaf)
			Doors.open(leaf)
			crime(player, leaf, "forcing a lock with magic")
			notify(player, "The iron in the lock turns at your touch.")
			return
		end
	end

	-- 3. A lockpick.
	local inv = inventory:inventoryOf(player)
	if inv and Inventory.countOf(inv, "lockpick") > 0 then
		if not permitted and not confirmed(player, leaf, "pick", "Picking this lock is a crime here. Use it again to go ahead.") then
			return
		end
		pickAttempts[player] = (pickAttempts[player] or 0) + 1
		local rng = Seed.random(worldService:getSeed(), "player:" .. player.UserId, "lockpick", pickAttempts[player])
		local success = rng:NextNumber() < (PICK_CHANCE[tier] or 0.3)
		crime(player, leaf, "picking a lock")
		if success then
			Doors.unlock(leaf)
			Doors.open(leaf)
			notify(player, "Click. The lock gives.")
		elseif rng:NextNumber() < 0.5 then
			inventory:take(player, "lockpick", 1, "lockpick broke")
			notify(player, "The pick snaps in the lock.")
		else
			notify(player, "The pins won't line up. Try again.")
		end
		return
	end
	notify(player, if canMetalMagic(player) then "It's locked, and you're too drained to work the lock with magic." else "It's locked.")
end

-- ─── Beds ───────────────────────────────────────────────────────────────────

local function useBed(player: Player, seat: Seat, humanoid: Humanoid)
	if seat.Occupant and seat.Occupant ~= humanoid then
		notify(player, "Someone's already resting there.")
		return
	end
	seat:Sit(humanoid)
end

local function watchSeat(seat: Seat, activity: string)
	seat:GetPropertyChangedSignal("Occupant"):Connect(function()
		local occupant = seat.Occupant
		local previous = resting[seat]
		if previous then
			resting[seat] = nil
			reservoirs:setActivity(previous, "Normal")
		end
		local player = occupant and Players:GetPlayerFromCharacter(occupant.Parent)
		if player then
			resting[seat] = player
			reservoirs:setActivity(player, activity)
		end
	end)
end

-- ─── Lights, books, wells, wards, insight ───────────────────────────────────

local function lightText(part: BasePart)
	local prompt = prompts[part]
	if not prompt then
		return
	end
	local fire = part:GetAttribute("Interactable") == "fireplace"
	if Lamps.isLit(part) then
		prompt.ActionText = if fire then "Put out" else "Douse"
	else
		prompt.ActionText = if fire then "Light fire" else "Light"
	end
end

local function useLight(part: BasePart)
	Lamps.set(part, not Lamps.isLit(part), Lamps.phase(WorldClock.hour(), WorldClock.day()))
end

local function bookFor(part: BasePart): Books.Book
	local building = Access.buildingOf(part)
	local pool = if building and building:GetAttribute("BuildingType") == "magic_school" then Books.list else Books.common
	local index = Seed.derive(worldService:getSeed(), tostring(part:GetAttribute("InteractId")), "book") % #pool + 1
	return pool[index]
end

local function useBook(player: Player, part: BasePart)
	local book = bookFor(part)
	local branch = Registry.branches[book.branch]
	local branchName = if branch then branch.name else book.branch
	local result, reason = progression:awardStudy(player, book.branch, "book", tostring(part:GetAttribute("InteractId")), { lore = { book.id } })
	if result then
		notify(player, string.format("You read \"%s\" and understand %s a little better.", book.title, branchName))
	elseif reason == "LORE_ONLY" then
		notify(player, string.format("You read \"%s\". It will make more sense once you can practise %s.", book.title, branchName))
	elseif reason == "ALREADY_STUDIED" then
		notify(player, string.format("You've already read \"%s\".", book.title))
	else
		notify(player, string.format("You leaf through \"%s\".", book.title))
	end
end

local function useWell(player: Player, humanoid: Humanoid)
	if not ready(player, "well", DRINK_COOLDOWN) then
		notify(player, "You've had your fill for now.")
		return
	end
	StatusEffects.cleanse(humanoid, { "burning" })
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + humanoid.MaxHealth * 0.1)
	notify(player, "Cold, clean water.")
end

local function useWard(player: Player, humanoid: Humanoid, part: BasePart)
	if not ready(player, "ward:" .. tostring(part:GetAttribute("InteractId")), WARD_COOLDOWN) then
		notify(player, "The stone is quiet for you. Come back later.")
		return
	end
	StatusEffects.apply(humanoid, "ward", { duration = WARD_SECONDS, resist = Resistances.wardFor(3), source = player.UserId })
	notify(player, "The stone hums, and a ward settles around you.")
end

local function useInsight(player: Player, part: BasePart)
	local domain = part:GetAttribute("Domain")
	if typeof(domain) ~= "string" then
		return
	end
	local insightId = string.format("%s:crystal_%s", domain, tostring(part:GetAttribute("InteractId")))
	local state = playerData:get(player)
	if state and state.data.progression.records.insights[insightId] then
		notify(player, "You've already learned what this crystal can teach.")
		return
	end
	progression:studyInsight(player, insightId, nil)
	local d = Registry.domains[domain]
	notify(player, string.format("The crystal shows you %s from the inside.", if d then d.name else domain))
end

-- ─── Training dummies ───────────────────────────────────────────────────────

local function dummyText(d: Dummy)
	local window = math.max(1, d.lastHit - d.firstHit)
	d.label.Text = string.format("last %.1f  ·  total %.0f  ·  %d hits%s", d.last, d.total, d.hits,
		if d.total > 0 then string.format("\n≈ %.1f per second", d.total / math.max(1, window)) else "")
end

local function setupDummy(root: BasePart)
	local model = root.Parent
	local humanoid = model and model:FindFirstChildOfClass("Humanoid")
	if not model or not humanoid or dummies[humanoid] then
		return
	end
	humanoid:SetStateEnabled(Enum.HumanoidStateType.Dead, false)
	local head = model:FindFirstChild("Head") or root
	local gui = Instance.new("BillboardGui")
	gui.Name = "DummyReadout"
	gui.Size = UDim2.fromOffset(220, 46)
	gui.StudsOffset = Vector3.new(0, 2.4, 0)
	gui.MaxDistance = 60
	gui.AlwaysOnTop = true
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.Font = Enum.Font.RobotoMono
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(250, 236, 200)
	label.TextStrokeTransparency = 0.4
	label.Parent = gui
	gui.Parent = head
	local d: Dummy = { humanoid = humanoid, label = label, last = 0, total = 0, hits = 0, firstHit = 0, lastHit = 0, health = humanoid.Health }
	dummies[humanoid] = d
	dummyText(d)
	humanoid.HealthChanged:Connect(function(health)
		local dealt = d.health - health
		d.health = health
		if dealt > 0 then
			if d.hits == 0 then
				d.firstHit = os.clock()
			end
			d.last = dealt
			d.total += dealt
			d.hits += 1
			d.lastHit = os.clock()
			dummyText(d)
		end
		if health < humanoid.MaxHealth * 0.2 then
			humanoid.Health = humanoid.MaxHealth
			d.health = humanoid.MaxHealth
		end
	end)
end

local function resetDummy(root: BasePart)
	local humanoid = root.Parent and root.Parent:FindFirstChildOfClass("Humanoid")
	local d = humanoid and dummies[humanoid]
	if d then
		d.last, d.total, d.hits = 0, 0, 0
		d.humanoid.Health = d.humanoid.MaxHealth
		d.health = d.humanoid.MaxHealth
		dummyText(d)
	end
end

local function idleDummies()
	local t = os.clock()
	for humanoid, d in dummies do
		if not humanoid.Parent then
			dummies[humanoid] = nil
		elseif d.hits > 0 and t - d.lastHit > DUMMY_IDLE_RESET and humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = humanoid.MaxHealth
			d.health = humanoid.MaxHealth
		end
	end
end

-- ─── Prompts ────────────────────────────────────────────────────────────────

local function onTriggered(part: BasePart, player: Player)
	if flags.get("interact_enabled") == false then
		return
	end
	local t = os.clock()
	if lastTrigger[player] and t - lastTrigger[player] < TRIGGER_GAP then
		return
	end
	lastTrigger[player] = t
	local def = defOf(part)
	local root, humanoid = aliveRoot(player)
	if not def or not root or not humanoid or not part:IsDescendantOf(workspace) then
		return
	end
	if (root.Position - part.Position).Magnitude > def.distance + 6 then
		return
	end
	local ok, err = pcall(function()
		if def.handler == "door" then
			useDoor(player, part)
		elseif def.handler == "seat" and part:IsA("Seat") then
			useBed(player, part, humanoid)
		elseif def.handler == "container" then
			local opened, why = containers:open(player, part)
			if not opened and why then
				notify(player, if string.match(why, "^[A-Z_]+$") then "You can't reach that." else why)
			end
		elseif def.handler == "station" then
			crafting:open(player, part)
		elseif def.handler == "light" then
			useLight(part)
		elseif def.handler == "book" then
			useBook(player, part)
		elseif def.handler == "notice" then
			Net.fire("OpenScreen", player, { id = "Journal" })
		elseif def.handler == "drink" then
			useWell(player, humanoid)
		elseif def.handler == "dummy" then
			resetDummy(part)
		elseif def.handler == "ward" then
			useWard(player, humanoid, part)
		elseif def.handler == "insight" then
			useInsight(player, part)
		elseif def.handler == "deed" then
			housing:deed(player, part)
		elseif def.handler == "decor" then
			housing:pickUp(player, part)
		end
	end)
	if not ok then
		log:error("interact_failed", { kind = part:GetAttribute("Interactable"), id = part:GetAttribute("InteractId"), err = tostring(err) })
	end
end

local function setup(instance: Instance)
	if not instance:IsA("BasePart") or prompts[instance] then
		return
	end
	local part = instance :: BasePart
	local def = defOf(part)
	if not def then
		return
	end
	local prompt = Instance.new("ProximityPrompt")
	prompt.Name = "Interact"
	prompt.ActionText = def.action
	prompt.ObjectText = def.object
	prompt.HoldDuration = def.hold
	prompt.MaxActivationDistance = def.distance
	prompt.RequiresLineOfSight = def.los ~= false
	prompt.Exclusivity = Enum.ProximityPromptExclusivity.OnePerButton
	if def.key then
		prompt.KeyboardKeyCode = (Enum.KeyCode :: any)[def.key]
		prompt.GamepadKeyCode = Enum.KeyCode.ButtonY
	end
	local signText, signAction = part:GetAttribute("SignText"), part:GetAttribute("SignAction")
	if typeof(signText) == "string" and typeof(signAction) == "string" then
		prompt.ObjectText, prompt.ActionText = signText, signAction
	end
	prompt.Parent = part
	prompts[part] = prompt
	prompt.Triggered:Connect(function(player)
		onTriggered(part, player)
	end)
	if def.handler == "door" then
		Doors.register(part)
		doorText(part)
	elseif def.handler == "seat" and part:IsA("Seat") then
		watchSeat(part, if part:GetAttribute("Interactable") == "mat" then "Meditating" else "Resting")
	elseif def.handler == "light" then
		Lamps.register(part)
		lightText(part)
	elseif def.handler == "dummy" then
		setupDummy(part)
	end
end

local function teardown(instance: Instance)
	if instance:IsA("BasePart") then
		prompts[instance] = nil
		Doors.unregister(instance)
		Lamps.unregister(instance)
	end
end

-- ─── Loops ──────────────────────────────────────────────────────────────────

local function lampTick()
	local players: { Vector3 } = {}
	local occupants: { Vector3 } = {}
	for _, p in Players:GetPlayers() do
		local root = p.Character and p.Character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			table.insert(players, root.Position)
			table.insert(occupants, root.Position)
		end
	end
	local folder = workspace:FindFirstChild("NPCs")
	if folder then
		for _, rig in folder:GetChildren() do
			local root = rig:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				table.insert(occupants, root.Position)
			end
		end
	end
	Lamps.tick(WorldClock.hour(), WorldClock.day(), players, occupants)
end

local function healResting()
	for seat, player in resting do
		local humanoid = seat.Occupant
		if not humanoid or not player.Parent then
			resting[seat] = nil
		elseif seat:GetAttribute("Interactable") == "bed" and humanoid.Health > 0 and humanoid.Health < humanoid.MaxHealth then
			humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + humanoid.MaxHealth * REST_HEAL_SHARE)
		end
	end
end

-- ─── Building check (admin) ─────────────────────────────────────────────────

local KIND_TAG: { [string]: string } = { house = "House", smithy = "Smithy", tavern = "Tavern" }

local function nearestBuilding(position: Vector3, kind: string): Model?
	local best, bestD = nil, math.huge
	for _, model in CollectionService:GetTagged("Building") do
		if model:IsA("Model") and model:IsDescendantOf(workspace) and typeof(model:GetAttribute("InteriorCFrame")) == "CFrame"
			and (kind == "any" or CollectionService:HasTag(model, KIND_TAG[kind] or "")) then
			local d = ((model:GetAttribute("InteriorCFrame") :: CFrame).Position - position).Magnitude
			if d < bestD then
				best, bestD = model, d
			end
		end
	end
	return best
end

-- Terrain voxels inside the interior box (sampled every 2 studs at three heights).
local function terrainInside(model: Model): number
	local cf = model:GetAttribute("InteriorCFrame") :: CFrame
	local size = model:GetAttribute("InteriorSize") :: Vector3
	local terrain = workspace.Terrain
	local found = 0
	for _, h in { 1, 3, 5 } do
		local y = -size.Y / 2 + h
		local x = -size.X / 2 + 1
		while x <= size.X / 2 - 1 do
			local z = -size.Z / 2 + 1
			while z <= size.Z / 2 - 1 do
				local p = cf * Vector3.new(x, y, z)
				local region = Region3.new(p - Vector3.new(2, 2, 2), p + Vector3.new(2, 2, 2)):ExpandToGrid(4)
				local materials, occupancy = terrain:ReadVoxels(region, 4)
				local m, o = materials[1][1][1], occupancy[1][1][1]
				if m ~= Enum.Material.Air and o > 0.15 then
					found += 1
				end
				z += 2
			end
			x += 2
		end
	end
	return found
end

-- Every check for one building; returns (lines, failures).
local function checkBuilding(model: Model, exerciseDoor: boolean): ({ string }, number)
	local lines: { string } = {}
	local failures = 0
	local function line(ok: boolean, text: string)
		table.insert(lines, (if ok then "✓ " else "✗ ") .. text)
		if not ok then
			failures += 1
		end
	end
	local cf = model:GetAttribute("InteriorCFrame") :: CFrame
	local size = model:GetAttribute("InteriorSize") :: Vector3
	local floorTop = cf.Position.Y - size.Y / 2 - 0.1

	-- Floor.
	local floor = model:FindFirstChild("Floor")
	if floor and floor:IsA("BasePart") then
		local top = floor.Position.Y + floor.Size.Y / 2
		local covers = floor.Size.X >= size.X and floor.Size.Z >= size.Z
		line(floor.CanCollide, "floor is collidable")
		line(covers, string.format("floor covers the interior (%.0f x %.0f studs)", floor.Size.X, floor.Size.Z))
		line(math.abs(top - floorTop) < 0.3, string.format("floor top at %.1f (interior starts at %.1f)", top, floorTop))
	else
		line(false, "floor part present")
	end

	-- Terrain inside, and what's underfoot.
	local intrusions = terrainInside(model)
	if intrusions > 0 then
		settlements:clearInterior(model)
		local after = terrainInside(model)
		line(after == 0, string.format("terrain inside the rooms: %d sample(s) found, %d after clearing", intrusions, after))
	else
		line(true, "no terrain inside the rooms")
	end
	-- Foundation: terrain under the floor stays below its bottom, no grass (FoundationBuilder).
	local foundation = settlements:verifyFoundation(model)
	if foundation.checked then
		for _, text in foundation.lines do
			table.insert(lines, text)
		end
		if not foundation.ok then
			failures += 1
		end
	end
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local exclude: { Instance } = {}
	for _, p in Players:GetPlayers() do
		if p.Character then
			table.insert(exclude, p.Character)
		end
	end
	params.FilterDescendantsInstances = exclude
	local hit = workspace:Raycast(cf.Position + Vector3.new(0, size.Y / 2 - 1, 0), Vector3.new(0, -size.Y, 0), params)
	line(hit ~= nil and hit.Instance ~= workspace.Terrain and hit.Instance:IsDescendantOf(model),
		"standing in the middle you land on " .. (if hit then hit.Instance.Name else "nothing"))
	line(size.Y >= 8, string.format("headroom %.0f studs", size.Y))

	-- Door.
	local doors: { BasePart } = {}
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and CollectionService:HasTag(d, "Door") then
			table.insert(doors, d)
		end
	end
	if #doors == 0 then
		table.insert(lines, "· no door leaf (an open-fronted building)")
	end
	for _, leaf in doors do
		line(if prompts[leaf] then true else false, "door has a prompt")
		local lockedText = if leaf:GetAttribute("Locked") then string.format("locked, tier %d, key %s", (leaf:GetAttribute("LockTier") :: number?) or 1, tostring(leaf:GetAttribute("KeyId"))) else "unlocked"
		table.insert(lines, "· door is " .. lockedText)
		if exerciseDoor then
			if Doors.isOpen(leaf) then
				Doors.close(leaf)
				task.wait(0.6)
			end
			local wasClosedSolid = leaf.CanCollide
			Doors.open(leaf)
			task.wait(0.6)
			local openCF = leaf:GetAttribute("OpenCFrame") :: CFrame
			local opened = not leaf.CanCollide and (leaf.Position - openCF.Position).Magnitude < 0.2
			local closed = Doors.close(leaf)
			task.wait(0.6)
			local closedCF = leaf:GetAttribute("ClosedCFrame") :: CFrame
			local shut = leaf.CanCollide and (leaf.Position - closedCF.Position).Magnitude < 0.2
			line(wasClosedSolid and opened and closed and shut, string.format("door swings open (passable) and shut (solid)%s", if closed then "" else ": someone stood in the doorway"))
		end
	end

	-- Interactables.
	local counts: { [string]: number } = {}
	local missing = 0
	local beds, items = 0, 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") and CollectionService:HasTag(d, "Interactable") then
			local kind = d:GetAttribute("Interactable") :: string
			counts[kind] = (counts[kind] or 0) + 1
			if not prompts[d] then
				missing += 1
			end
			if kind == "bed" then
				beds += 1
			end
			local def = defOf(d)
			if def and def.container then
				local inv = containers:peek(d)
				if inv then
					for _, rec in inv.slots do
						items += if rec.n then rec.n else 1
					end
				end
			end
		end
	end
	local kinds = {}
	local total = 0
	for kind, n in counts do
		table.insert(kinds, kind .. " " .. n)
		total += n
	end
	table.sort(kinds)
	line(total > 0 and missing == 0, string.format("%d interactables found (%s)%s", total, table.concat(kinds, ", "),
		if missing > 0 then string.format(", %d without a prompt", missing) else ""))
	local homes = 0
	for _, d in model:GetDescendants() do
		if d:IsA("Attachment") and CollectionService:HasTag(d, "NPCHome") then
			homes += 1
		end
	end
	if homes > 0 or beds > 0 then
		line(beds >= homes, string.format("%d bed(s) to rest in, %d NPC home anchor(s)", beds, homes))
	end
	table.insert(lines, string.format("· containers hold %d item(s) right now", items))
	local parts, lights = 0, 0
	for _, d in model:GetDescendants() do
		if d:IsA("BasePart") then
			parts += 1
		elseif d:IsA("PointLight") then
			lights += 1
		end
	end
	line(parts <= 220, string.format("%d parts, %d light(s)", parts, lights))
	return lines, failures
end

local function registerAdmin(admin: any)
	admin:Register({
		name = "buildingcheck", aliases = { "househere" }, category = "World",
		description = "Teleport inside the nearest built building of a kind and print a checklist (floor, terrain, door, interactables)",
		args = {
			{ name = "kind", type = "enum", options = { "house", "smithy", "tavern", "any" }, default = "house" },
			{ name = "teleport", type = "boolean", default = true },
		},
		handler = function(ctx, a)
			local root = Util.rootOf(ctx.player)
			if not root then
				return "no character"
			end
			local model = nearestBuilding(root.Position, a.kind)
			if not model then
				return string.format("No built %s yet. Walk into a town (buildings appear as their chunks load) or run buildsettlement <name>.", a.kind)
			end
			local cf = model:GetAttribute("InteriorCFrame") :: CFrame
			local size = model:GetAttribute("InteriorSize") :: Vector3
			if a.teleport then
				local inside = cf * Vector3.new(size.X * 0.25, -size.Y / 2 + 3.2, -size.Z * 0.25) -- a front corner, clear of furniture
				Util.teleport(ctx.player, world, inside, false)
			end
			local lines, failures = checkBuilding(model, true)
			table.insert(lines, 1, string.format("%s (%s, %s) · %s", model.Name, tostring(model:GetAttribute("BuildingType")), tostring(model:GetAttribute("SettlementId")),
				if failures == 0 then "all checks passed" else failures .. " check(s) failed"))
			return table.concat(lines, "\n")
		end,
	})

	admin:Register({
		name = "buildingaudit", category = "World",
		description = "Run the building checks (no teleport, no door swings) on every built building and summarise",
		handler = function()
			local checked, failed = 0, 0
			local worst: { string } = {}
			for _, model in CollectionService:GetTagged("Building") do
				if model:IsA("Model") and model:IsDescendantOf(workspace) and typeof(model:GetAttribute("InteriorCFrame")) == "CFrame" then
					checked += 1
					local lines, failures = checkBuilding(model, false)
					if failures > 0 then
						failed += 1
						if #worst < 8 then
							local bad = {}
							for _, l in lines do
								if string.sub(l, 1, 3) == "✗" then
									table.insert(bad, l)
								end
							end
							table.insert(worst, model.Name .. ": " .. table.concat(bad, "; "))
						end
					end
				end
			end
			return string.format("%d buildings checked, %d with failures; %d doors registered, %d containers opened so far\n%s",
				checked, failed, Doors.count(), containers:count(), table.concat(worst, "\n"))
		end,
	})

	admin:Register({
		name = "lights", category = "World", description = "Lamps and fireplaces: how many exist, how many are lit, and the cap",
		handler = function()
			return string.format("%d lamps and fireplaces, %d lit (cap %d). Game time %02d:%02d.", Lamps.count(), Lamps.litCount(), Lamps.CAP,
				math.floor(WorldClock.hour()), math.floor((WorldClock.hour() % 1) * 60))
		end,
	})

	admin:Register({
		name = "lamps", category = "World", description = "Force every lamp and fireplace within 60 studs on or off for this phase, or back to automatic",
		args = { { name = "mode", type = "enum", options = { "on", "off", "auto" } } },
		handler = function(ctx, a)
			local root = Util.rootOf(ctx.player)
			if not root then
				return "no character"
			end
			local phase = Lamps.phase(WorldClock.hour(), WorldClock.day())
			local n = 0
			for _, part in CollectionService:GetTagged("Interactable") do
				if part:IsA("BasePart") and (part:GetAttribute("Interactable") == "lamp" or part:GetAttribute("Interactable") == "fireplace")
					and (part.Position - root.Position).Magnitude <= 60 then
					n += 1
					if a.mode == "auto" then
						part:SetAttribute("ManualPhase", nil)
					else
						Lamps.set(part, a.mode == "on", phase)
					end
				end
			end
			if a.mode == "auto" then
				lampTick()
			end
			return string.format("%d light(s) %s", n, if a.mode == "auto" then "back on automatic" else "turned " .. a.mode)
		end,
	})

	admin:Register({
		name = "door", category = "World", description = "Open, close, lock or unlock the nearest door (within 20 studs)",
		args = { { name = "action", type = "enum", options = { "open", "close", "lock", "unlock" } } },
		handler = function(ctx, a)
			local root = Util.rootOf(ctx.player)
			if not root then
				return "no character"
			end
			local best, bestD = nil, 20
			for _, leaf in Doors.near(root.Position, 20) do
				local d = (leaf.Position - root.Position).Magnitude
				if d < bestD then
					best, bestD = leaf, d
				end
			end
			if not best then
				return "no door within 20 studs"
			end
			if a.action == "open" then
				Doors.open(best)
			elseif a.action == "close" then
				if not Doors.close(best) then
					return "someone is standing in the doorway"
				end
			elseif a.action == "lock" then
				Doors.lock(best)
			else
				Doors.unlock(best)
			end
			return string.format("%s: %s (%s)", tostring(best:GetAttribute("InteractId")), a.action, if best:GetAttribute("Locked") then "locked" else "unlocked")
		end,
	})
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function InteractionService.init(_self: any, ctx: any)
	log, bus, flags = ctx.log, ctx.bus, ctx.flags
	playerData = ctx.get("PlayerDataService")
	worldService = ctx.get("WorldService")
	world = ctx.get("WorldStateService")
	inventory = ctx.get("InventoryService")
	reservoirs = ctx.get("ReservoirService")
	containers = ctx.get("ContainerService")
	crafting = ctx.get("CraftingService")
	settlements = ctx.get("SettlementService")
	progression = ctx.get("ProgressionService")
	housing = ctx.get("HousingService")
	Doors.onChanged = doorText
	Lamps.onChanged = lightText
	registerAdmin(ctx.get("AdminService"))
end

function InteractionService.start(_self: any, _ctx: any)
	CollectionService:GetInstanceAddedSignal("Interactable"):Connect(setup)
	CollectionService:GetInstanceRemovedSignal("Interactable"):Connect(teardown)
	for _, instance in CollectionService:GetTagged("Interactable") do
		setup(instance)
	end
	Players.PlayerRemoving:Connect(function(player)
		lastTrigger[player] = nil
		pending[player] = nil
		pickAttempts[player] = nil
		cooldowns[player] = nil
	end)
	local ticks = 0
	while true do
		task.wait(0.3)
		ticks += 1
		Doors.tick(os.clock())
		if ticks % 3 == 0 then
			healResting()
			idleDummies()
		end
		if ticks % 10 == 0 then
			lampTick()
		end
	end
end

return InteractionService
