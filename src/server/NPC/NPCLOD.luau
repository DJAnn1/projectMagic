--!strict
--[[
	NPCLOD: how much of an NPC exists, decided by how close the nearest player is.

	TIERS (distance from the nearest player's character, with hysteresis)
	    T0  < 110 studs (leave at 140)   a full rig: Humanoid, pathfinding, walk/idle/cast animations,
	                                     a name tag and a "Talk" prompt. Brain every 1 s.
	    T1  < 350 studs (leave at 400)   the same rig ANCHORED: no physics, no pathfinding; it hops
	                                     toward its destination every 2 s. Brain every 5 s.
	    T2  beyond                       no Instances at all: a data record. Brain once per game hour,
	                                     batched (ParallelPool when large).
	CAPS   at most MAX_T0 and MAX_T1 NPCs; when more qualify, the closest win (the rest stay a tier
	       down). A settlement with no player within 1500 studs skips per-NPC distance checks.
	PROMOTE/DEMOTE  at most SPAWNS_PER_STEP rig changes per LOD pass, so a player teleporting into
	       a city spreads 40 spawns over a couple of seconds instead of one frame.

	RIG POOL  rigs are built once (Players:CreateHumanoidModelFromDescription, R6, no assets) by a
	       background warm-up, recoloured per NPC on acquire (skin, shirt, trousers), and parked
	       (Parent = nil) on release. Nothing is destroyed during play.
	PATHFINDING  T0 only. Paths are cached per (settlement, from-cell, to-cell) on an 8-stud grid and
	       shared by every NPC walking the same route; at most PATHS_PER_SECOND ComputeAsync calls,
	       queued; while a path is pending the NPC walks straight. Waypoints are followed by a
	       stepped MoveTo (no per-NPC event connections); no progress for 3 s -> jump; 6 s ->
	       snap to the next waypoint.
]]

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")

local Shared = game:GetService("ReplicatedStorage").Shared
local ActionRules = require(Shared.Magic.ActionRules)
local CombatAnimations = require(Shared.Magic.Data.CombatAnimations)

local Magic = script.Parent.Parent.Magic
local Gear = require(Magic.Data.Gear)
local Resistances = require(Magic.Cast.Resistances)
local ActionState = require(Magic.Cast.ActionState)
local NpcLooks = require(script.Parent.NpcLooks)

local LOD = {}

local T0_IN, T0_OUT = 110, 140
local T1_IN, T1_OUT = 350, 400
local MAX_T0, MAX_T1 = 40, 100
local SETTLEMENT_SKIP = 1500
local SPAWNS_PER_STEP = 6
local PATHS_PER_SECOND = 4
local PATH_TTL = 300
local HOP = 30
local WALK_SPEED = 10

-- Rigs use the rig type the combat clips were authored for (CombatAnimations.rigType), so the
-- ambient clips are Roblox's defaults for that rig.
local RIG_TYPE = (Enum.HumanoidRigType :: any)[CombatAnimations.rigType] :: Enum.HumanoidRigType
local AMBIENT = {
	R6 = {
		idle = "rbxassetid://180435571",
		walk = "rbxassetid://180426354",
		cast = "rbxassetid://128777973", -- the default wave
	},
	R15 = {
		idle = "rbxassetid://507766388",
		walk = "rbxassetid://507777826",
		cast = "rbxassetid://507770239",
	},
}
local ANIMATIONS = AMBIENT[CombatAnimations.rigType]

LOD.limits = { maxT0 = MAX_T0, maxT1 = MAX_T1 }

-- ─── Rig pool ───────────────────────────────────────────────────────────────

type Rig = {
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	tracks: { [string]: AnimationTrack },
	prompt: ProximityPrompt,
	label: TextLabel,
	look: NpcLooks.Look?, -- what the current wearer has on (re-applied once accessories load)
}

local pool: { Rig } = {}
local rigByModel: { [Model]: Rig } = setmetatable({}, { __mode = "k" }) :: any
local built = 0
local folder: Folder? = nil
local warming = false

local function buildRig(): Rig?
	local ok, model = pcall(function()
		local description = Instance.new("HumanoidDescription")
		return Players:CreateHumanoidModelFromDescription(description, RIG_TYPE)
	end)
	if not ok or not model then
		return nil
	end
	local humanoid = model:FindFirstChildOfClass("Humanoid") :: Humanoid
	local root = model:FindFirstChild("HumanoidRootPart") :: BasePart
	if not humanoid or not root then
		return nil
	end
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.WalkSpeed = WALK_SPEED
	humanoid.BreakJointsOnDeath = false
	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		animator = Instance.new("Animator")
		animator.Parent = humanoid
	end
	local tracks: { [string]: AnimationTrack } = {}
	for name, id in ANIMATIONS do
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok2, track = pcall(function()
			return (animator :: Animator):LoadAnimation(animation)
		end)
		if ok2 and track then
			track.Looped = name ~= "cast"
			tracks[name] = track
		end
	end
	-- Combat clips (Data/CombatAnimations), keyed by their capitalised names (no clash with the
	-- lowercase ambient ones above). Played only at T0, by followState below.
	for name, def in CombatAnimations.animations do
		local animation = Instance.new("Animation")
		animation.AnimationId = "rbxassetid://" .. tostring(def.id)
		local ok2, track = pcall(function()
			return (animator :: Animator):LoadAnimation(animation)
		end)
		if ok2 and track then
			track.Priority = ActionRules.priorityOf(name)
			track.Looped = def.looped == true
			tracks[name] = track
		end
	end

	local prompt = Instance.new("ProximityPrompt")
	prompt.ActionText = "Talk"
	prompt.KeyboardKeyCode = Enum.KeyCode.E
	prompt.MaxActivationDistance = 10
	prompt.RequiresLineOfSight = false
	prompt.Enabled = false
	prompt.Parent = root

	local billboard = Instance.new("BillboardGui")
	billboard.Size = UDim2.fromOffset(200, 40)
	billboard.StudsOffset = Vector3.new(0, 3.2, 0)
	billboard.MaxDistance = 60
	billboard.AlwaysOnTop = false
	local label = Instance.new("TextLabel")
	label.BackgroundTransparency = 1
	label.Size = UDim2.fromScale(1, 1)
	label.TextScaled = true
	label.TextColor3 = Color3.fromRGB(240, 232, 214)
	label.TextStrokeTransparency = 0.4
	label.Font = Enum.Font.BuilderSansMedium
	label.Parent = billboard
	billboard.Parent = model:FindFirstChild("Head") or root

	built += 1
	local rig: Rig = { model = model, humanoid = humanoid, root = root, tracks = tracks, prompt = prompt, label = label }
	rigByModel[model] = rig
	return rig
end

-- Builds rigs in the background until the pool holds `target` (yields between builds).
local looksLoading = false

function LOD.prewarm(target: number)
	-- Hair, hats and beards (NPC/NpcLooks): load the catalog accessories once, in the background,
	-- then re-dress every rig already in use.
	if not looksLoading then
		looksLoading = true
		task.spawn(function()
			local _, bad, ids = NpcLooks.preload(function()
				for model, rig in rigByModel do
					if model.Parent and rig.look then
						NpcLooks.apply(model, rig.humanoid, rig.look)
					end
				end
			end)
			if bad > 0 then
				warn(string.format("[NpcLooks] %d accessories failed to load and are skipped: %s", bad, table.concat(ids :: any, ", ")))
			end
		end)
	end
	if warming then
		return
	end
	warming = true
	task.spawn(function()
		while built < target do
			local rig = buildRig()
			if not rig then
				break
			end
			table.insert(pool, rig)
			task.wait(0.05)
		end
		warming = false
	end)
end

function LOD.poolStats(): (number, number)
	return #pool, built
end

-- Part names for both rigs (missing ones are skipped). R6 arms are one part, so they take skin:
-- a short-sleeved look.
local SKIN = { "Head", "LeftHand", "RightHand", "LeftLowerArm", "RightLowerArm", "Left Arm", "Right Arm" }
local SHIRT = { "UpperTorso", "LowerTorso", "LeftUpperArm", "RightUpperArm", "Torso" }
local LEGS = { "LeftUpperLeg", "RightUpperLeg", "LeftLowerLeg", "RightLowerLeg", "LeftFoot", "RightFoot", "Left Leg", "Right Leg" }

local function dress(rig: Rig, npc: any)
	local a = npc.appearance
	for _, list in { { SKIN, a.skin }, { SHIRT, a.shirt }, { LEGS, a.trousers } } :: { { any } } do
		for _, name in list[1] :: { string } do
			local part = rig.model:FindFirstChild(name)
			if part and part:IsA("BasePart") then
				part.Color = list[2] :: Color3
			end
		end
	end
	-- Hair, headwear, beard, scarf and body scale, chosen from the NPC's seed (NPC/NpcLooks).
	local look = NpcLooks.choose(npc)
	rig.look = look
	NpcLooks.apply(rig.model, rig.humanoid, look)
	rig.model.Name = npc.name
	rig.model:SetAttribute("NpcId", npc.id)
	rig.model:SetAttribute("MagicSignature", npc.signatureJson)
	rig.label.Text = string.format("%s\n%s", npc.name, npc.occupationName)
	rig.prompt.ObjectText = npc.name
	rig.humanoid.Health = rig.humanoid.MaxHealth
	-- A pooled rig may still carry the last wearer's fight: clear it, then put on this NPC's gear.
	local h = rig.humanoid
	for _, attribute in { "KnockedDown", "KnockdownImmuneUntil", "FlinchUntil", "LastMagicAttacker", "LastMagicHitAt", "QuestWard", "QuestSanction" } do
		h:SetAttribute(attribute, nil)
	end
	for _, attribute in ActionRules.ATTR do
		rig.model:SetAttribute(attribute, nil)
	end
	h.PlatformStand = false
	for _, slot in Gear.slots do
		Resistances.setGear(h, slot, nil)
	end
	for _, itemId in (Gear.byOccupation[npc.occupation] or {}) :: { string } do
		local item = Gear.items[itemId]
		if item then
			Resistances.setGear(h, item.slot, itemId)
		end
	end
end

local function acquire(npc: any): Rig?
	local rig = table.remove(pool)
	if not rig then
		return nil
	end
	dress(rig, npc)
	return rig
end

local function release(rig: Rig)
	for _, track in rig.tracks do
		track:Stop(0)
	end
	rig.prompt.Enabled = false
	rig.model:SetAttribute("NpcId", nil)
	rig.model.Parent = nil
	table.insert(pool, rig)
end

-- A rig whose Humanoid died can't be revived (Health won't bring a Dead humanoid back), so it is
-- destroyed instead of pooled; prewarm() builds a replacement.
function LOD.discard(npc: any)
	local rig: Rig? = npc.rig
	if rig then
		npc.position = rig.root.Position
		rig.model:Destroy()
		built -= 1
		npc.rig = nil
	end
	npc.tier = 2
end

-- ─── Tier assignment ────────────────────────────────────────────────────────

local function playerPositions(): { Vector3 }
	local list = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and character:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			table.insert(list, root.Position)
		end
	end
	return list
end

--[[
	Decides every NPC's tier (npc.tier) from player distance, with hysteresis and caps.
	`settlements` = { { x, z, npcs = { ... } } }. Returns the NPCs whose tier changed.
]]
function LOD.assign(settlements: { any }): { any }
	local players = playerPositions()
	local wants: { { npc: any, d: number, tier: number } } = {}
	for _, s in settlements do
		local near = false
		for _, p in players do
			if (Vector3.new(p.X - s.x, 0, p.Z - s.z)).Magnitude < SETTLEMENT_SKIP then
				near = true
				break
			end
		end
		for _, npc in s.npcs do
			local forced = npc.forcedTier
			if forced and not npc.knockedOut then
				-- Admin override: distance 0 sorts it first, so the caps keep it.
				table.insert(wants, { npc = npc, d = 0, tier = forced })
				continue
			end
			if not near or npc.knockedOut then
				table.insert(wants, { npc = npc, d = math.huge, tier = 2 })
				continue
			end
			local d = math.huge
			for _, p in players do
				d = math.min(d, (p - npc.position).Magnitude)
			end
			local current = npc.tier or 2
			local tier = if d < (if current == 0 then T0_OUT else T0_IN) then 0
				elseif d < (if current <= 1 then T1_OUT else T1_IN) then 1
				else 2
			table.insert(wants, { npc = npc, d = d, tier = tier })
		end
	end
	table.sort(wants, function(a, b)
		return a.d < b.d
	end)
	local t0, t1 = 0, 0
	local changed: { any } = {}
	local spawns = 0
	for _, w in wants do
		local tier = w.tier
		if tier == 0 and t0 >= MAX_T0 then
			tier = 1
		end
		if tier == 1 and t1 >= MAX_T1 then
			tier = 2
		end
		-- Rig-count changes are rate limited; demotions to T2 always go through (they free rigs).
		local needsRig = tier < 2 and (w.npc.tier or 2) == 2
		if needsRig and spawns >= SPAWNS_PER_STEP then
			tier = 2
		end
		if tier == 0 then
			t0 += 1
		elseif tier == 1 then
			t1 += 1
		end
		if tier ~= (w.npc.tier or 2) then
			if needsRig then
				spawns += 1
			end
			w.npc.tier = tier
			table.insert(changed, w.npc)
		end
	end
	return changed
end

-- Brings an NPC's Instances in line with its tier. Returns false when the pool was empty.
function LOD.sync(npc: any, groundAt: (Vector3) -> Vector3): boolean
	local tier = npc.tier or 2
	local rig: Rig? = npc.rig
	if tier == 2 then
		if rig then
			if rig.model.Parent then
				npc.position = rig.root.Position
			end
			release(rig)
			npc.rig = nil
		end
		return true
	end
	if not rig then
		rig = acquire(npc)
		if not rig then
			npc.tier = 2
			return false
		end
		npc.rig = rig
		rig.model:PivotTo(CFrame.new(groundAt(npc.position) + Vector3.new(0, 3, 0)))
		if not folder then
			local f = Instance.new("Folder")
			f.Name = "NPCs"
			f.Parent = workspace
			folder = f
		end
		rig.model.Parent = folder
	end
	local r = rig :: Rig
	r.root.Anchored = tier == 1 or npc.frozen == true
	r.humanoid.PlatformStand = false
	r.prompt.Enabled = tier == 0
	if tier == 0 then
		pcall(function()
			r.root:SetNetworkOwner(nil)
		end)
		if r.tracks.idle and not r.tracks.idle.IsPlaying then
			r.tracks.idle:Play()
		end
	else
		for _, track in r.tracks do
			track:Stop(0.2)
		end
	end
	return true
end

-- ─── Pathfinding (T0) ───────────────────────────────────────────────────────

type CachedPath = { waypoints: { Vector3 }, at: number }

local pathCache: { [string]: CachedPath } = {}
local pathQueue: { { key: string, from: Vector3, to: Vector3 } } = {}
local queued: { [string]: boolean } = {}
local pathStats = { computed = 0, cacheHits = 0, failed = 0 }

local function cell(v: Vector3): string
	return math.floor(v.X / 8) .. "," .. math.floor(v.Z / 8)
end

local function pathKey(settlementId: string, from: Vector3, to: Vector3): string
	return settlementId .. ":" .. cell(from) .. ">" .. cell(to)
end

-- Cached waypoints for a route, or nil (and the route is queued for computing).
function LOD.pathFor(settlementId: string, from: Vector3, to: Vector3): { Vector3 }?
	local key = pathKey(settlementId, from, to)
	local cached = pathCache[key]
	if cached and os.clock() - cached.at < PATH_TTL then
		pathStats.cacheHits += 1
		return cached.waypoints
	end
	if not queued[key] then
		queued[key] = true
		table.insert(pathQueue, { key = key, from = from, to = to })
	end
	return nil
end

-- Background worker: computes queued paths within the per-second budget.
function LOD.startPathWorker()
	task.spawn(function()
		while true do
			task.wait(1 / PATHS_PER_SECOND)
			local job = table.remove(pathQueue, 1)
			if job then
				local path = PathfindingService:CreatePath({ AgentRadius = 1.5, AgentHeight = 5, AgentCanJump = true, WaypointSpacing = 6 })
				local ok = pcall(function()
					path:ComputeAsync(job.from, job.to)
				end)
				queued[job.key] = nil
				if ok and path.Status == Enum.PathStatus.Success then
					local waypoints = {}
					for _, wp in path:GetWaypoints() do
						table.insert(waypoints, wp.Position)
					end
					pathCache[job.key] = { waypoints = waypoints, at = os.clock() }
					pathStats.computed += 1
				else
					-- Remember failure briefly as a straight line, so we don't retry every frame.
					pathCache[job.key] = { waypoints = { job.to }, at = os.clock() - PATH_TTL + 30 }
					pathStats.failed += 1
				end
			end
		end
	end)
end

function LOD.pathStats(): { [string]: number }
	return { computed = pathStats.computed, cacheHits = pathStats.cacheHits, failed = pathStats.failed, queued = #pathQueue }
end

-- ─── Movement ───────────────────────────────────────────────────────────────

-- Sets where an NPC is heading (a world position). Movement happens in step*().
function LOD.setDestination(npc: any, destination: Vector3)
	npc.destination = destination
	npc.waypoints = nil
	npc.waypointIndex = 1
	npc.lastProgress = os.clock()
	npc.lastDistance = math.huge
end

function LOD.arrived(npc: any): boolean
	local dest = npc.destination
	return dest == nil or Vector3.new(dest.X - npc.position.X, 0, dest.Z - npc.position.Z).Magnitude < 4
end

-- T0: walk the cached path (or straight while it's computing). Call ~10 times a second.
function LOD.stepT0(npc: any)
	local rig: Rig? = npc.rig
	local dest: Vector3? = npc.destination
	if not rig or not dest then
		return
	end
	npc.position = rig.root.Position
	if LOD.arrived(npc) then
		rig.humanoid:Move(Vector3.zero)
		if rig.tracks.walk and rig.tracks.walk.IsPlaying then
			rig.tracks.walk:Stop(0.2)
			if rig.tracks.idle then
				rig.tracks.idle:Play()
			end
		end
		return
	end
	if not npc.waypoints then
		npc.waypoints = LOD.pathFor(npc.settlementId, npc.position, dest)
		npc.waypointIndex = 1
	end
	local waypoints: { Vector3 } = npc.waypoints or { dest }
	local target = waypoints[npc.waypointIndex] or dest
	local flat = Vector3.new(target.X - npc.position.X, 0, target.Z - npc.position.Z).Magnitude
	if flat < 3 and npc.waypointIndex < #waypoints then
		npc.waypointIndex += 1
		target = waypoints[npc.waypointIndex]
	end
	rig.humanoid:MoveTo(target)
	if rig.tracks.walk and not rig.tracks.walk.IsPlaying then
		rig.tracks.walk:Play()
		if rig.tracks.idle then
			rig.tracks.idle:Stop(0.2)
		end
	end
	-- Stuck handling.
	local now = os.clock()
	if flat < npc.lastDistance - 0.5 then
		npc.lastDistance = flat
		npc.lastProgress = now
	elseif now - npc.lastProgress > 6 then
		rig.model:PivotTo(CFrame.new(target + Vector3.new(0, 3, 0)))
		npc.lastProgress, npc.lastDistance = now, math.huge
	elseif now - npc.lastProgress > 3 then
		rig.humanoid.Jump = true
	end
end

-- T1: hop up to HOP studs toward the destination (anchored, no physics). Call every ~2 s.
function LOD.stepT1(npc: any, groundAt: (Vector3) -> Vector3)
	local dest: Vector3? = npc.destination
	if not dest then
		return
	end
	local offset = Vector3.new(dest.X - npc.position.X, 0, dest.Z - npc.position.Z)
	local nextPos = if offset.Magnitude <= HOP then dest else npc.position + offset.Unit * HOP
	npc.position = groundAt(nextPos)
	local rig: Rig? = npc.rig
	if rig then
		local look = if offset.Magnitude > 0.1 then offset.Unit else Vector3.new(0, 0, -1)
		rig.model:PivotTo(CFrame.lookAt(npc.position + Vector3.new(0, 3, 0), npc.position + Vector3.new(0, 3, 0) + look))
	end
end

-- T2 / arrival: no movement, just be there.
function LOD.teleport(npc: any, groundAt: (Vector3) -> Vector3)
	if npc.destination then
		npc.position = groundAt(npc.destination)
	end
end

function LOD.playCast(npc: any)
	local rig: Rig? = npc.rig
	if rig and rig.tracks.cast then
		rig.tracks.cast:Play(0.1)
	end
end

-- ─── Combat animations (ActionState) ────────────────────────────────────────
-- An NPC rig's clips follow its action state, like a player's client does (docs/Combat.md §11).
-- Only T0 rigs (unanchored, parented) animate, and at most COMBAT_CLIPS_PER_SECOND clip starts
-- happen server-wide per second; over budget the state still applies, just without a clip.

local COMBAT_CLIPS_PER_SECOND = 30
local clipBudget, clipWindow = COMBAT_CLIPS_PER_SECOND, 0

local function takeClip(): boolean
	local t = os.clock()
	if t - clipWindow >= 1 then
		clipWindow, clipBudget = t, COMBAT_CLIPS_PER_SECOND
	end
	if clipBudget <= 0 then
		return false
	end
	clipBudget -= 1
	return true
end

local function playClip(rig: Rig, name: string, duration: number?, domain: string?): AnimationTrack?
	local track = rig.tracks[name]
	if not track or not takeClip() then
		return nil
	end
	local def = CombatAnimations.animations[name]
	track:Play(def.fadeIn, ActionRules.weightFor(domain), ActionRules.playbackSpeed(name, track.Length, duration, domain))
	return track
end

local function followState(model: Model, state: string, previous: string, info: ActionState.Info)
	local rig = rigByModel[model]
	if not rig or not model.Parent or rig.root.Anchored then
		return
	end
	local entryClip, loopClip = ActionRules.clipsFor(state, info.variant)
	local oldEntry, oldLoop = ActionRules.clipsFor(previous, nil)
	-- Resume a clip the previous state froze (charging's wind-up) instead of restarting it.
	local prevDef = CombatAnimations.states[previous]
	local resumeAt = if entryClip and prevDef and prevDef.holdAt and oldEntry == entryClip
		then ActionRules.markerFraction(entryClip, prevDef.holdAt)
		else nil
	local held = entryClip and rig.tracks[entryClip]
	local resuming = resumeAt ~= nil and held ~= nil and held.IsPlaying
	for _, name in { oldEntry, oldLoop } :: { string? } do
		local track = name and rig.tracks[name]
		if track and track.IsPlaying and name ~= loopClip and not (resuming and name == entryClip) then
			track:Stop(CombatAnimations.animations[name :: string].fadeOut)
		end
	end
	if state == "staggered" or state == "idle" then
		return
	end
	local def = CombatAnimations.states[state]
	local entry: AnimationTrack? = nil
	if resuming and held then
		local finish = if def.scaleToDuration then info.duration else CombatAnimations.animations[entryClip :: string].approxLength
		held:AdjustSpeed(ActionRules.resumeSpeed(entryClip :: string, held.Length, resumeAt :: number, finish))
		entry = held
	elseif entryClip then
		entry = playClip(rig, entryClip, if def.scaleToDuration then info.duration else nil, info.domain)
	end
	-- Hold: freeze at the marker while this state lasts (the NPC's charge telegraph).
	if entry and entryClip and def.holdAt then
		local fraction = ActionRules.markerFraction(entryClip, def.holdAt) or 1
		local clip = if entry.Length > 0 then entry.Length else CombatAnimations.animations[entryClip].approxLength
		local track = entry
		task.delay(clip * fraction / math.max(track.Speed, 0.01), function()
			if model:GetAttribute(ActionRules.ATTR.seq) == info.seq and track.IsPlaying then
				track:AdjustSpeed(0)
			end
		end)
	end
	-- No CastSpell clip (failed to load, or over budget): the old ambient cast gesture instead.
	if not entry and state == "casting" and rig.tracks.cast then
		rig.tracks.cast:Play(0.1)
	end
	if loopClip then
		local wait = if entry
			then (if entry.Length > 0 then entry.Length else CombatAnimations.animations[entryClip :: string].approxLength) / math.max(entry.Speed, 0.01)
			else 0
		task.delay(math.max(0, wait - 0.03), function() -- just before a one-shot entry clip ends
			if model:GetAttribute(ActionRules.ATTR.seq) == info.seq and not rig.root.Anchored then
				local loop = rig.tracks[loopClip]
				if loop and loop.Length > 0 and not loop.IsPlaying then
					playClip(rig, loopClip, nil, info.domain)
				elseif entry and entry.IsPlaying and (not loop or loop.Length <= 0) then
					entry:AdjustSpeed(0) -- no usable loop clip (Block failed to load): hold the pose
				end
			end
		end)
	end
end

ActionState.changed:Connect(followState)

function LOD.counts(settlements: { any }): (number, number, number)
	local a, b, c = 0, 0, 0
	for _, s in settlements do
		for _, npc in s.npcs do
			local tier = npc.tier or 2
			if tier == 0 then
				a += 1
			elseif tier == 1 then
				b += 1
			else
				c += 1
			end
		end
	end
	return a, b, c
end

return LOD
