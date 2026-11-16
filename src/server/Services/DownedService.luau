--!strict
--[[
	DownedService: losing leads somewhere (docs/LivingHistory.md §7, Living History stage 3).

	DOWN       A blow that would kill a player, from anything but another player (creatures, Wildborn,
	           ferals, event enemies, Titans, your own overdraw), downs them instead (Damage.downer):
	           1 health, attribute Downed, HealthFloor 1, status `downed` (no moving or casting).
	           Creatures, Wildborn and NPC fighters stop seeing them (DownedRules.ignored) until a few
	           seconds after they're up. Another player's blow, or a Rift, is a death as before.
	OUTCOME    DownedRules.choose, by where and what:
	             carry    a free townsperson within carryReach: a fade, and you wake beside the town's
	                      healer, who says who brought you. The carrier remembers (owes_me); talking to
	                      them later is your thanks (their regard for you rises once).
	             wake     nobody came: you come round where you fell after wakeSeconds.
	             capture  deep wilds, a Wildborn did it: a fade, and you wake in its haunt or lair. It
	                      leaves you be inside its ring, fights you if you step out while it watches,
	                      and after holdSeconds wanders off. Escaping is noticed by distance.
	             spawn    nothing else: the blow kills, as before.
	           Never the same outcome twice in a row; no capture within captureGap. Never gear.
	PURSE      Any downing with purseMin+ coins: purseShare of them drop where you fell. Only you, or a
	           passer-by in a town, can pick it up. An honest finder (or one who likes you) gives it back
	           the next time they see you or you talk to them; a dishonest one keeps it, and someone else
	           in that town may tell you who, if you ask for news. Unclaimed purses go after purseLife.
	QUIET      Every Journal line here is quiet (no toast). No cards, no markers.

	Flag downed_enabled. Admin: downme [outcome], purse [list|drop|clear] [amount], downed [reset].
	Log: player_downed, downed_outcome, downed_thanked, purse_dropped, purse_recovered, purse_found,
	purse_returned, purse_kept, capture_escaped.
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Topics = require(Shared.Core.Topics)
local Net = require(Shared.Net)
local Seed = require(Shared.Magic.Seed)
local OmenRules = require(Shared.Magic.OmenRules)

local Server = script.Parent.Parent
local Rules = require(Server.Downed.DownedRules)
local LineData = require(Server.Downed.Data.DownedLines)
local Damage = require(Server.Magic.Cast.Damage)
local StatusEffects = require(Server.Magic.Cast.StatusEffects)
local RelationshipGraph = require(Server.NPC.RelationshipGraph)
local PromptRouter = require(Server.Interact.PromptRouter)
local Util = require(Server.Admin.Util)

local T = Rules.Tuning
local Lines = LineData.lines

local DownedService = {
	name = "DownedService",
	dependencies = {
		"AdminService",
		"AmbientLifeService",
		"InventoryService",
		"JournalService",
		"NPCService",
		"WildbornService",
		"WorldService",
		"WorldStateService",
	},
}

type Down = {
	token: number,
	character: Model?, -- the body that went down: a later one is never touched
	outcome: string,
	at: Vector3,
	where: string,
	town: any?, -- the town it happened in or nearest to
	carrier: any?,
	captor: Model?,
	center: Vector3?,
	captorName: string?,
	heldSince: number?,
}

type Purse = {
	id: number,
	owner: number,
	amount: number,
	part: BasePart,
	town: string?, -- dropped inside this town's reach: a passer-by may find it
	droppedAt: number,
	findAt: number,
}

type Held = { owner: number, amount: number } -- a finder carrying someone's purse back to them
type Kept = { owner: number, finder: string, finderName: string, town: string, at: number, told: boolean }

local log: any = nil
local npcs: any = nil
local ambient: any = nil
local inventory: any = nil
local journal: any = nil
local wildborn: any = nil
local world: any = nil
local worldService: any = nil

local downs: { [Player]: Down } = {}
local lastOutcome: { [number]: string } = {}
local lastCapture: { [number]: number } = {}
local lastPurse: { [number]: boolean } = {}
local forced: { [number]: string } = {} -- admin downme: the next outcome
local carriedBy: { [number]: { npc: string, at: number, greeted: boolean } } = {}
local purses: { Purse } = {}
local held: { [string]: { Held } } = {} -- npc id -> purses they mean to give back
local kept: { Kept } = {}
local folder: Folder? = nil
local counter = 0
local tokens = 0
local counts: { [string]: number } = { downed = 0, carry = 0, wake = 0, capture = 0, spawn = 0, death = 0, purses = 0, returned = 0, kept = 0 }

local function enabled(): boolean
	return FeatureFlags.get("downed_enabled") == true
end

local function rngFor(salt: string): Random
	counter += 1
	return Seed.random(worldService:getSeed(), "downed", salt, counter)
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function fill(text: string, vars: { [string]: string }): string
	return (string.gsub(text, "{(%w+)}", function(key)
		return vars[key] or ""
	end))
end

local function journalLine(player: Player, key: string, vars: { [string]: string })
	local list = LineData.journal[key]
	if not list or #list == 0 then
		return
	end
	local text = fill(list[rngFor("journal" .. key):NextInteger(1, #list)], vars)
	journal:log(player, "downed", text, { quiet = true })
end

local function playerOf(humanoid: Humanoid): Player?
	local model = humanoid.Parent
	return if model and model:IsA("Model") then Players:GetPlayerFromCharacter(model) else nil
end

-- Which Wildborn home the blow came from, for the log (who downs a captive matters).
local function homeOf(info: any): string?
	local attacker = info and info.attacker
	if typeof(attacker) == "Instance" then
		local home = attacker:GetAttribute("WildbornHome")
		return if typeof(home) == "string" then home else nil
	end
	return nil
end

local function humanoidOf(player: Player): Humanoid?
	local character = player.Character
	return character and character:FindFirstChildOfClass("Humanoid")
end

local terrainParams = RaycastParams.new()
terrainParams.FilterType = Enum.RaycastFilterType.Exclude
terrainParams.IgnoreWater = false

-- Standing ground at (x, z): the first solid thing under the sky, people and loose parts aside.
local function groundAt(x: number, z: number, from: number?): Vector3
	local top = (from or world:surfaceHeight(x, z)) + 40
	local skip: { Instance } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(skip, player.Character)
		end
	end
	if folder then
		table.insert(skip, folder)
	end
	terrainParams.FilterDescendantsInstances = skip
	local hit = workspace:Raycast(Vector3.new(x, top, z), Vector3.new(0, -200, 0), terrainParams)
	return if hit then hit.Position else Vector3.new(x, world:surfaceHeight(x, z), z)
end

-- ─── Where ──────────────────────────────────────────────────────────────────

-- The nearest town and how far its edge... its centre is.
local function nearestTown(at: Vector3): (any?, number)
	local best, bestD = nil, math.huge
	for _, town in npcs:towns() do
		local d = Vector3.new(town.x - at.X, 0, town.z - at.Z).Magnitude
		if d < bestD then
			best, bestD = town, d
		end
	end
	return best, bestD
end

local function townName(town: any?): string
	return if town and town.settlement and town.settlement.name then tostring(town.settlement.name) else "town"
end

local function whereOf(at: Vector3, town: any?, distance: number): string
	if not town then
		return "out in the wilds"
	end
	if distance <= town.radius * 1.3 then -- the same edge as a purse a passer-by may find
		return "in " .. townName(town)
	end
	return string.format("out %s of %s", OmenRules.bearing(town.x, town.z, at.X, at.Z), townName(town))
end

local function free(npc: any): boolean
	return npc.rig ~= nil
		and not npc.knockedOut
		and not npc.combat
		and not npc.talk
		and not npc.leash
		and npc.action ~= "sleep"
		and npc.action ~= "shelter"
		and npc.occupation ~= "child"
end

-- The nearest free townsperson within reach who doesn't dislike you too much, or nil.
local function carrierNear(player: Player, at: Vector3): any?
	local subject = "u:" .. player.UserId
	local best, bestD = nil, T.carryReach
	for _, town in npcs:towns() do
		if Vector3.new(town.x - at.X, 0, town.z - at.Z).Magnitude <= town.radius * 1.5 + T.carryReach then
			for _, npc in town.npcs do
				local d = flat(npc.position, at)
				if d <= bestD and free(npc) then
					local edge = RelationshipGraph.peek(npc.id, subject)
					if not edge or edge.affinity >= T.carryMinAffinity then
						best, bestD = npc, d
					end
				end
			end
		end
	end
	return best
end

local function townById(id: string?): any?
	if not id then
		return nil
	end
	for _, town in npcs:towns() do
		if town.id == id then
			return town
		end
	end
	return nil
end

local function healerOf(town: any): any?
	for _, occupation in T.healerOccupations do
		for _, npc in town.npcs do
			if npc.occupation == occupation and not npc.knockedOut then
				return npc
			end
		end
	end
	return nil
end

-- ─── Purses ─────────────────────────────────────────────────────────────────

local function removePurse(purse: Purse)
	local i = table.find(purses, purse)
	if i then
		table.remove(purses, i)
	end
	if purse.part.Parent then
		purse.part:Destroy()
	end
end

local function dropPurse(player: Player, at: Vector3, amount: number, town: any?, inTown: boolean): boolean
	if amount <= 0 or not inventory:addCurrency(player, -amount, "dropped when downed") then
		return false
	end
	counts.purses += 1
	local ground = groundAt(at.X, at.Z, at.Y)
	local part = Instance.new("Part")
	part.Name = "Purse"
	part.Size = Vector3.new(0.9, 0.7, 0.9)
	part.Shape = Enum.PartType.Ball
	part.Material = Enum.Material.Fabric
	part.Color = Color3.fromRGB(110, 78, 48)
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = true
	part.CFrame = CFrame.new(ground + Vector3.new(0, 0.35, 0))
	part:SetAttribute("PurseOwner", player.UserId)
	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Pick up"
	prompt.ObjectText = "Purse"
	prompt.MaxActivationDistance = 8
	prompt.RequiresLineOfSight = false
	prompt.Parent = part
	part.Parent = folder
	local rng = rngFor("purse")
	local purse: Purse = {
		id = counts.purses,
		owner = player.UserId,
		amount = amount,
		part = part,
		town = if inTown and town then town.id else nil,
		droppedAt = os.clock(),
		findAt = os.clock() + T.findAfter[1] + rng:NextNumber() * (T.findAfter[2] - T.findAfter[1]),
	}
	table.insert(purses, purse)
	PromptRouter.connect(prompt, function(who: Player)
		if who.UserId ~= purse.owner then
			return false, "NOT_YOURS", "That's not yours."
		end
		if not table.find(purses, purse) then
			return false, "GONE", nil
		end
		removePurse(purse)
		inventory:addCurrency(who, purse.amount, "purse picked up")
		journalLine(who, "purse_own", {})
		log:info("purse_recovered", { userId = who.UserId, amount = purse.amount })
		return true
	end)
	journalLine(player, "purse_lost", {})
	log:info("purse_dropped", { userId = player.UserId, amount = amount, town = purse.town, x = math.floor(at.X), z = math.floor(at.Z) })
	return true
end

-- Gives a held purse back, if `npc` holds one for `player`. Returns the line said, or nil.
local function giveBack(npc: any, player: Player, line: string?): string?
	local list = held[npc.id]
	if not list then
		return nil
	end
	for i, h in list do
		if h.owner == player.UserId then
			table.remove(list, i)
			if #list == 0 then
				held[npc.id] = nil
			end
			inventory:addCurrency(player, h.amount, "purse returned")
			counts.returned += 1
			journalLine(player, "purse_returned", { finder = tostring(npc.name) })
			npcs:questBond(npc, player, 0.03, nil)
			log:info("purse_returned", { userId = player.UserId, npc = npc.id, amount = h.amount })
			return line or ambient:lineFor(npc, player, { "purse_return" }, Lines, {})
		end
	end
	return nil
end

-- A passer-by in town notices a purse lying there.
local function findPurses()
	local clock = os.clock()
	for i = #purses, 1, -1 do
		local purse = purses[i]
		if clock - purse.droppedAt >= T.purseLife then
			removePurse(purse)
			log:info("purse_lost", { userId = purse.owner, amount = purse.amount })
		elseif purse.town and clock >= purse.findAt then
			local town = townById(purse.town)
			local at = purse.part.Position
			local finder, bestD = nil, T.findRadius
			for _, npc in (if town then town.npcs else {}) :: { any } do
				local d = flat(npc.position, at)
				if d <= bestD and free(npc) then
					finder, bestD = npc, d
				end
			end
			if finder then
				removePurse(purse)
				local said = ambient:lineFor(finder, nil, { "purse_found" }, Lines, {})
				if said then
					npcs:speak(finder, said, 40)
				end
				local edge = RelationshipGraph.peek(finder.id, "u:" .. purse.owner)
				local returns = Rules.returns(finder.traits, if edge then edge.affinity else 0, rngFor("returns" .. finder.id):NextNumber())
				if returns then
					held[finder.id] = held[finder.id] or {}
					table.insert(held[finder.id], { owner = purse.owner, amount = purse.amount })
				else
					counts.kept += 1
					table.insert(kept, { owner = purse.owner, finder = finder.id, finderName = tostring(finder.name), town = purse.town :: string, at = clock, told = false })
					if #kept > 40 then
						table.remove(kept, 1)
					end
				end
				log:info("purse_found", { owner = purse.owner, npc = finder.id, amount = purse.amount, returns = returns })
			end
		end
	end
end

-- ─── Getting up ─────────────────────────────────────────────────────────────

local function release(player: Player, down: Down, healthShare: number)
	local humanoid = humanoidOf(player)
	downs[player] = nil
	if not humanoid or humanoid.Health <= 0 or humanoid.Parent ~= down.character then
		return
	end
	humanoid:SetAttribute("Downed", nil)
	humanoid:SetAttribute("HealthFloor", nil)
	humanoid:SetAttribute("DownedGraceUntil", workspace:GetServerTimeNow() + T.graceSeconds)
	StatusEffects.remove(humanoid, "downed")
	humanoid.Health = math.max(humanoid.Health, humanoid.MaxHealth * healthShare)
	Net.fire("Downed", player, "wake")
	log:info("downed_outcome", { userId = player.UserId, outcome = down.outcome, where = down.where })
end

local function stillDown(player: Player, down: Down): boolean
	return player.Parent ~= nil and downs[player] == down and player.Character == down.character and humanoidOf(player) ~= nil and (humanoidOf(player) :: Humanoid).Health > 0
end

local function moveTo(player: Player, spot: Vector3)
	local character = player.Character
	if character then
		character:PivotTo(CFrame.new(spot + Vector3.new(0, 3, 0)))
	end
end

local function runCarry(player: Player, down: Down)
	task.wait(T.downSeconds)
	if not stillDown(player, down) then
		return
	end
	local carrier = down.carrier
	Net.fire("Downed", player, "fade")
	task.wait(T.fadeSeconds + 0.4)
	if not stillDown(player, down) then
		return
	end
	local town = townById(carrier and carrier.settlementId) or down.town
	local healer = if town then healerOf(town) else nil
	local spot: Vector3
	if healer then
		local at: Vector3 = if healer.rig then healer.rig.root.Position else healer.position
		local angle = rngFor("healer"):NextNumber() * 2 * math.pi
		spot = groundAt(at.X + math.cos(angle) * 4, at.Z + math.sin(angle) * 4, at.Y)
	elseif town then
		spot = groundAt(town.x + 6, town.z + 6)
	else
		spot = down.at
	end
	moveTo(player, spot)
	task.wait(0.8)
	if not stillDown(player, down) then
		return
	end
	local carrierName = if carrier then tostring(carrier.name) else "someone"
	if carrier then
		npcs:remember(carrier, "owes_me", "u:" .. player.UserId, 0.7, { note = "carried" })
		carriedBy[player.UserId] = { npc = carrier.id, at = os.clock(), greeted = false }
	end
	release(player, down, T.wakeHealth.carry)
	if healer then
		local line = ambient:lineFor(healer, player, { "healer_wake" }, Lines, { carrier = carrierName })
		if line then
			ambient:markGreeted(healer, player)
			npcs:speak(healer, line, 40)
		end
		journalLine(player, "carry", { where = down.where, healer = tostring(healer.name), carrier = carrierName })
	else
		journalLine(player, "carry_nohealer", { where = down.where, town = townName(town), carrier = carrierName })
	end
end

local function runWake(player: Player, down: Down)
	task.wait(T.wakeSeconds)
	if not stillDown(player, down) then
		return
	end
	release(player, down, T.wakeHealth.wake)
	journalLine(player, "wake", { where = down.where })
end

local function runCapture(player: Player, down: Down)
	task.wait(T.downSeconds)
	if not stillDown(player, down) then
		return
	end
	local captor = down.captor
	local center = down.center
	-- Its den: walls with one way out, and it stands in it (WildbornService.denOf).
	local den = if captor then wildborn:denOf(captor) else nil
	if den then
		center = den.center
	end
	if not captor or not center then
		release(player, down, T.wakeHealth.wake)
		return
	end
	Net.fire("Downed", player, "fade")
	task.wait(T.fadeSeconds + 0.4)
	if not stillDown(player, down) then
		return
	end
	local angle = rngFor("lair"):NextNumber() * 2 * math.pi
	local reach = if den then 2 else 6
	local spot = groundAt(center.X + math.cos(angle) * reach, center.Z + math.sin(angle) * reach, center.Y)
	local radius = if den then den.radius + 1.5 else T.holdRadius
	if not wildborn:hold(captor, player.UserId, center, radius, T.holdSeconds + 2, T.wanderSeconds, if den then den.post else nil) then
		-- Its captor is gone (killed, or its haunt emptied): nobody drags them anywhere.
		log:info("capture_lost", { userId = player.UserId })
		release(player, down, T.wakeHealth.wake)
		journalLine(player, "wake", { where = down.where })
		return
	end
	moveTo(player, spot)
	lastCapture[player.UserId] = os.clock()
	task.wait(0.8)
	if not stillDown(player, down) then
		return
	end
	-- Held, not hurt: they get up inside its ring. Watch for them getting away.
	release(player, down, T.wakeHealth.capture)
	journalLine(player, if den then "capture_den" else "capture", {})
	log:info("captive_held", { userId = player.UserId, home = homeOf({ attacker = captor }), den = den ~= nil })
	local since = os.clock()
	task.spawn(function()
		while player.Parent do
			task.wait(1)
			local humanoid = humanoidOf(player)
			local root = humanoid and humanoid.RootPart
			if not humanoid or not root or humanoid.Health <= 0 then
				return
			end
			local living, holding = wildborn:holding(captor, player.UserId)
			local away = flat(root.Position, center) > T.escapeRadius
			local how: string? = nil
			if not living then
				how = "fought"
			elseif away then
				how = if holding then "walked" else "waited"
			end
			if how then
				journalLine(player, "escaped_" .. how, {})
				log:info("capture_escaped", { userId = player.UserId, how = how, seconds = math.floor(os.clock() - since) })
				return
			end
			if os.clock() - since > T.holdSeconds + T.wanderSeconds + 120 then
				return -- they stayed: nothing more to notice
			end
		end
	end)
end

-- ─── The hook ───────────────────────────────────────────────────────────────

local function inRift(at: Vector3, info: any): boolean
	local attacker = info and info.attacker
	if typeof(attacker) == "Instance" and attacker:GetAttribute("RiftEnemy") ~= nil then
		return true
	end
	return math.abs(at.X) > 2300 or math.abs(at.Z) > 2300 -- the Rift pocket sits off the island
end

-- Damage.downer: a lethal blow is about to land on `humanoid`. True = downed instead.
local function downer(humanoid: Humanoid, sourceUserId: number?, kind: string, info: any): boolean
	local player = playerOf(humanoid)
	if not player or not enabled() then
		return false
	end
	if humanoid:GetAttribute("Downed") == true then
		return true -- already down: nothing finishes them
	end
	local root = humanoid.RootPart
	if not root then
		return false
	end
	local at = root.Position
	local town, distance = nearestTown(at)
	local attacker = info and info.attacker
	local captor = if typeof(attacker) == "Instance" and attacker:IsA("Model") then wildborn:captorOf(attacker) else nil
	local carrier = carrierNear(player, at)
	local uid = player.UserId
	local outcome: string = forced[uid] or Rules.choose({
		pvp = sourceUserId ~= nil and sourceUserId > 0 and sourceUserId ~= uid,
		rift = inRift(at, info),
		carrier = carrier ~= nil,
		deep = Rules.deep(distance),
		wildborn = captor ~= nil,
		captureReady = os.clock() - (lastCapture[uid] or -math.huge) >= T.captureGap,
		last = lastOutcome[uid],
	}, rngFor("choose" .. uid):NextNumber())
	forced[uid] = nil
	if outcome == "death" then
		counts.death += 1
		return false
	end
	local inTown = town ~= nil and distance <= town.radius * 1.3
	local where = whereOf(at, town, distance)
	-- The purse: whatever comes next, some coin stays where you fell.
	local amount = Rules.purse(inventory:currency(player), lastPurse[uid] == true, rngFor("purse" .. uid):NextNumber())
	lastPurse[uid] = amount > 0
	if amount > 0 then
		task.spawn(dropPurse, player, at, amount, town, inTown)
	end
	if outcome == "spawn" then
		counts.spawn += 1
		lastOutcome[uid] = outcome
		log:info("player_downed", { userId = uid, outcome = outcome, by = kind, where = where, purse = amount, home = homeOf(info) })
		return false
	end
	if outcome == "capture" and not captor then
		-- Forced by an admin with no Wildborn behind it: the nearest one takes them.
		local model = wildborn:nearestCaptor(at, 300)
		captor = model and wildborn:captorOf(model)
		attacker = model
		if not captor then
			outcome = "wake"
		end
	end
	if outcome == "carry" and not carrier then
		outcome = "wake"
	end
	counts.downed += 1
	counts[outcome] = (counts[outcome] or 0) + 1
	lastOutcome[uid] = outcome
	log:info("player_downed", { userId = uid, outcome = outcome, by = kind, where = where, purse = amount, home = homeOf(info) })
	tokens += 1
	local down: Down = {
		token = tokens,
		character = player.Character,
		outcome = outcome,
		at = at,
		where = where,
		town = town,
		carrier = carrier,
		captor = if outcome == "capture" then attacker else nil,
		center = if outcome == "capture" and captor then captor.center else nil,
		captorName = if captor then captor.name else nil,
	}
	downs[player] = down
	humanoid:SetAttribute("Downed", true)
	humanoid:SetAttribute("HealthFloor", 1)
	StatusEffects.apply(humanoid, "downed", { duration = T.maxDown })
	Net.fire("Downed", player, "down")
	task.spawn(function()
		local ok, err = pcall(function()
			if outcome == "carry" then
				runCarry(player, down)
			elseif outcome == "capture" then
				runCapture(player, down)
			else
				runWake(player, down)
			end
		end)
		if not ok then
			log:warn("downed_failed", { userId = uid, outcome = outcome, err = tostring(err) })
		end
		-- Whatever went wrong, nobody stays down.
		if downs[player] == down then
			release(player, down, T.wakeHealth.wake)
		end
	end)
	return true
end

-- ─── People ─────────────────────────────────────────────────────────────────

local function greetHook(npc: any, player: Player, close: boolean, _clock: number): any?
	if not enabled() or not close then
		return nil
	end
	if held[npc.id] then
		for _, h in held[npc.id] do
			if h.owner == player.UserId then
				return {
					categories = { "purse_return" },
					lines = Lines,
					vars = {},
					said = function(text: string)
						giveBack(npc, player, text)
					end,
				}
			end
		end
	end
	local carried = carriedBy[player.UserId]
	if carried and carried.npc == npc.id and not carried.greeted then
		carried.greeted = true
		return {
			categories = { "carrier_greet" },
			lines = Lines,
			vars = {},
			said = function(_text: string)
				log:info("downed_greeted", { userId = player.UserId, npc = npc.id })
			end,
		}
	end
	return nil
end

local function onTalked(payload: any)
	local player: Player? = payload.player
	local npc = player and npcs:get(payload.npcId)
	if not player or not npc or not enabled() then
		return
	end
	local returned = giveBack(npc, player, nil)
	if returned then
		task.delay(2.2, function()
			npcs:speak(npc, returned, 30)
		end)
		return
	end
	local carried = carriedBy[player.UserId]
	if carried and carried.npc == npc.id and os.clock() - carried.at <= T.thankWindow then
		carriedBy[player.UserId] = nil
		npcs:questBond(npc, player, T.thankBond, nil)
		journalLine(player, "thanked", { carrier = tostring(npc.name) })
		log:info("downed_thanked", { userId = player.UserId, npc = npc.id })
		local line = ambient:lineFor(npc, player, { "carrier_thanks" }, Lines, {})
		if line then
			task.delay(2.2, function()
				npcs:speak(npc, line, 30)
			end)
		end
	end
end

-- Asked for news: someone else in town lets slip who kept your purse.
local function rumorHook(player: Player, npc: any): string?
	if not enabled() then
		return nil
	end
	local clock = os.clock()
	for _, k in kept do
		if not k.told and k.owner == player.UserId and k.town == npc.settlementId and k.finder ~= npc.id and clock - k.at <= T.keptKeep then
			local text = ambient:lineFor(npc, player, { "purse_kept" }, Lines, { finder = k.finderName })
			if text then
				k.told = true
				journalLine(player, "purse_kept", { finder = k.finderName, town = townName(townById(k.town)) })
				log:info("purse_kept", { userId = player.UserId, finder = k.finder, teller = npc.id })
				return text
			end
		end
	end
	return nil
end

-- ─── Admin ──────────────────────────────────────────────────────────────────

local function registerAdmin(admin: any)
	admin:Register({
		name = "downme",
		category = "Spells",
		description = "Go down right now as if something had beaten you: auto (the rules decide), carry (nearest townsperson within reach), wake (where you are), capture (the nearest living Wildborn within 300 studs drags you home), or spawn",
		args = { { name = "outcome", type = "enum", options = { "auto", "carry", "wake", "capture", "spawn" }, default = "auto" } },
		handler = function(ctx: any, a: any)
			local humanoid = Util.humanoidOf(ctx.player)
			if not humanoid or humanoid.Health <= 0 then
				return "no character"
			end
			if humanoid:GetAttribute("Downed") then
				return "already down"
			end
			if a.outcome ~= "auto" then
				forced[ctx.player.UserId] = a.outcome
			end
			Damage.apply(humanoid, humanoid.Health + 1, nil, "admin_downme", {})
			local down = downs[ctx.player]
			return if down then "down: " .. down.outcome .. " (" .. down.where .. ")" else "not downed: the blow killed you (spawn or flag off)"
		end,
	})
	admin:Register({
		name = "purse",
		category = "Spells",
		description = "Purses: list those lying about, who holds one to give back and who kept one; drop one of yours here (amount coins); or clear them all",
		args = {
			{ name = "action", type = "enum", options = { "list", "drop", "clear" }, default = "list" },
			{ name = "amount", type = "integer", min = 1, max = 100000, default = 20 },
		},
		handler = function(ctx: any, a: any)
			if a.action == "drop" then
				local root = Util.rootOf(ctx.player)
				if not root then
					return "no character"
				end
				local town, distance = nearestTown(root.Position)
				local inTown = town ~= nil and distance <= town.radius * 1.3
				local ok = dropPurse(ctx.player, root.Position, a.amount, town, inTown)
				return if ok then string.format("dropped %d coins%s", a.amount, if inTown then " in " .. townName(town) .. " (a passer-by may find it in " .. T.findAfter[1] .. "-" .. T.findAfter[2] .. " s)" else " in the wilds (only you can pick it up)") else "not enough coins"
			elseif a.action == "clear" then
				for i = #purses, 1, -1 do
					removePurse(purses[i])
				end
				table.clear(held)
				table.clear(kept)
				return "cleared every purse"
			end
			local holding = 0
			for _, list in held do
				holding += #list
			end
			local lines = { string.format("purses %d lying · held %d · kept %d · returned %d", #purses, holding, #kept, counts.returned) }
			local clock = os.clock()
			for _, p in purses do
				table.insert(lines, string.format("#%d owner %d · %d coins · %s · %d s old, found after %d s", p.id, p.owner, p.amount, p.town or "wilds", math.floor(clock - p.droppedAt), math.floor(p.findAt - p.droppedAt)))
			end
			for npcId, list in held do
				for _, h in list do
					table.insert(lines, string.format("%s holds %d coins for %d", npcs:nameOf(npcId), h.amount, h.owner))
				end
			end
			for _, k in kept do
				table.insert(lines, string.format("%s kept %d's purse in %s%s", k.finderName, k.owner, k.town, if k.told then " (told)" else ""))
			end
			return table.concat(lines, "\n")
		end,
	})
	admin:Register({
		name = "downed",
		category = "Spells",
		description = "Losing (docs/LivingHistory.md §7): who's down, your last outcome and capture cooldown, the counts; or reset your last outcome, capture cooldown and purse so the next loss is fresh",
		args = { { name = "action", type = "enum", options = { "status", "reset" }, default = "status" } },
		handler = function(ctx: any, a: any)
			local uid = ctx.player.UserId
			if a.action == "reset" then
				lastOutcome[uid], lastCapture[uid], lastPurse[uid], carriedBy[uid] = nil, nil, nil, nil
				return "reset: any outcome can happen next"
			end
			local lines = {
				string.format("on=%s · downed %d · carry %d · wake %d · capture %d · spawn %d · death %d · purses %d", tostring(enabled()), counts.downed, counts.carry, counts.wake, counts.capture, counts.spawn, counts.death, counts.purses),
				string.format("you: last %s · capture %s · last purse %s · carried by %s", lastOutcome[uid] or "none",
					if lastCapture[uid] then string.format("%d s ago", math.floor(os.clock() - lastCapture[uid])) else "never",
					tostring(lastPurse[uid] == true), if carriedBy[uid] then npcs:nameOf(carriedBy[uid].npc) else "nobody"),
			}
			for player, down in downs do
				table.insert(lines, string.format("%s is down: %s, %s", player.Name, down.outcome, down.where))
			end
			local root = Util.rootOf(ctx.player)
			if root then
				local town, distance = nearestTown(root.Position)
				local carrier = carrierNear(ctx.player, root.Position)
				table.insert(lines, string.format("here: %s · %d studs from %s (deep from %d) · carrier %s", whereOf(root.Position, town, distance), math.floor(distance), townName(town), T.deepFrom, if carrier then tostring(carrier.name) else "none"))
			end
			return table.concat(lines, "\n")
		end,
	})
end

-- ─── Boot ───────────────────────────────────────────────────────────────────

function DownedService.init(_self: any, ctx: any)
	log = ctx.log
	npcs = ctx.get("NPCService")
	ambient = ctx.get("AmbientLifeService")
	inventory = ctx.get("InventoryService")
	journal = ctx.get("JournalService")
	wildborn = ctx.get("WildbornService")
	world = ctx.get("WorldStateService")
	worldService = ctx.get("WorldService")
	registerAdmin(ctx.get("AdminService"))
	Damage.downer = downer
	ambient:setGreetHook(greetHook)
	npcs:setRumorHook(rumorHook)
	ctx.bus:subscribe(Topics.NpcTalked, onTalked)
	Players.PlayerRemoving:Connect(function(player)
		downs[player] = nil
		forced[player.UserId] = nil
	end)
end

function DownedService.start(_self: any, _ctx: any)
	local parent = Instance.new("Folder")
	parent.Name = "Purses"
	parent.Parent = workspace
	folder = parent
	task.spawn(function()
		world:awaitReady()
		while true do
			task.wait(5)
			local ok, err = pcall(findPurses)
			if not ok then
				log:warn("purse_tick_failed", { err = tostring(err) })
			end
		end
	end)
end

return DownedService
