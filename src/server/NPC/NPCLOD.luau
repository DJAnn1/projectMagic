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
	WALKING  T0 walking is NPC/NavigationService's. Animation of walk and idle is NPC/NPCAnimator's.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local ActionRules = require(Shared.Magic.ActionRules)
local CombatAnimations = require(Shared.Magic.Data.CombatAnimations)

local Magic = script.Parent.Parent.Magic
local Gear = require(Magic.Data.Gear)
local Resistances = require(Magic.Cast.Resistances)
local ActionState = require(Magic.Cast.ActionState)
local NpcLooks = require(script.Parent.NpcLooks)
local Activities = require(script.Parent.Data.Activities)
local Navigation = require(script.Parent.NavigationService)

local LOD = {}

local leaveT0: (any) -> ()

local T0_IN, T0_OUT = 110, 140
local T1_IN, T1_OUT = 350, 400
local MAX_T0, MAX_T1 = 40, 100
local SETTLEMENT_SKIP = 1500
local SPAWNS_PER_STEP = 6
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
	prop: Instance?, -- what they're carrying (LOD.setProp)
	agent: any?, -- the pathfinding agent measured from this body (NavigationService)
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
	-- These tracks are the only animation: a default Animate script would fight NPCAnimator.
	local animate = model:FindFirstChild("Animate")
	if animate then
		animate:Destroy()
	end
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
			track.Priority = if name == "walk" then Enum.AnimationPriority.Movement
				elseif name == "idle" then Enum.AnimationPriority.Idle
				else Enum.AnimationPriority.Action
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
	rig.agent = nil -- a new body: NavigationService measures it again
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
	if rig.prop then
		rig.prop:Destroy()
		rig.prop = nil
	end
	rig.model:SetAttribute("NpcId", nil)
	rig.model.Parent = nil
	table.insert(pool, rig)
end

-- NPCService's cleanup (NPCAnimator, NPCConversation require this module, so it can't call them).
LOD.onLeaveT0 = nil :: ((any) -> ())?

-- The rig is no longer walking under Navigation, or stopping being a rig altogether.
leaveT0 = function(npc: any)
	Navigation.Forget(npc)
	local hook = LOD.onLeaveT0
	if hook then
		hook(npc)
	end
end

-- A rig whose Humanoid died can't be revived (Health won't bring a Dead humanoid back), so it is
-- destroyed instead of pooled; prewarm() builds a replacement.
function LOD.discard(npc: any)
	local rig: Rig? = npc.rig
	if rig then
		leaveT0(npc)
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
			-- Someone in a conversation stays a full rig, however far off the cap would push them.
			local forced = npc.forcedTier or (if npc.talk then 0 else nil)
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
			leaveT0(npc)
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
	else
		leaveT0(npc)
		for _, track in r.tracks do
			track:Stop(0.2)
		end
	end
	return true
end

-- ─── Movement ───────────────────────────────────────────────────────────────
-- T0 walking belongs to NPC/NavigationService: it picks up npc.destination on its next Step.

-- Sets where an NPC is heading (a world position).
function LOD.setDestination(npc: any, destination: Vector3)
	npc.destination = destination
end

function LOD.arrived(npc: any): boolean
	local dest = npc.destination
	return dest == nil or Vector3.new(dest.X - npc.position.X, 0, dest.Z - npc.position.Z).Magnitude < 4
end

function LOD.pathStats(): { [string]: number }
	return Navigation.Stats()
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

-- ─── Daily life: activity clips and carried props (NPC/DailyLife) ───────────
-- Loaded the first time a rig needs them, kept in rig.tracks under "a:<slot>" so every existing
-- "stop all tracks" path covers them. One activity clip at a time.

local activityChecked: { [string]: boolean } = {}
-- Which play of a held clip is current, so an old freeze can't catch a newer play.
local holdTokens: { [AnimationTrack]: number } = setmetatable({}, { __mode = "k" }) :: any

function LOD.stopActivity(npc: any)
	local rig: Rig? = npc.rig
	if rig then
		for name, track in rig.tracks do
			if string.sub(name, 1, 2) == "a:" and track.IsPlaying then
				track:Stop(0.2)
			end
		end
	end
end

function LOD.playActivity(npc: any, slot: string, animationId: string, looped: boolean)
	local rig: Rig? = npc.rig
	if not rig or rig.root.Anchored then
		return
	end
	local key = "a:" .. slot
	local track = rig.tracks[key]
	if not track then
		local animator = rig.humanoid:FindFirstChildOfClass("Animator")
		if not animator then
			return
		end
		local animation = Instance.new("Animation")
		animation.AnimationId = animationId
		local ok, loaded = pcall(function()
			return animator:LoadAnimation(animation)
		end)
		if not ok or not loaded then
			return
		end
		loaded.Priority = Enum.AnimationPriority.Action
		rig.tracks[key] = loaded
		track = loaded
		-- A clip with no length plays nothing, silently: it has only one keyframe, or it couldn't load.
		-- Say so once per slot.
		if not activityChecked[slot] then
			activityChecked[slot] = true
			task.delay(5, function()
				if loaded.Length <= 0 then
					warn(string.format("[DailyLife] clip '%s' (%s) has no length: only one keyframe, or it couldn't load (check ownership)", slot, animationId))
				end
			end)
		end
	end
	if looped and track.IsPlaying then
		return
	end
	if not looped and not takeClip() then
		return
	end
	for name, other in rig.tracks do
		if string.sub(name, 1, 2) == "a:" and name ~= key and other.IsPlaying then
			other:Stop(0.2)
		end
	end
	local hold = looped and Activities.holdAtEnd[slot] == true
	track.Looped = looped and not hold
	track:Play(0.2)
	local playing = track
	local token = (holdTokens[playing] or 0) + 1
	holdTokens[playing] = token
	if hold or not looped then
		-- Ended by hand, because Looped set here may not reach clients: they use the setting the
		-- animation was published with, so a clip published looping would repeat forever.
		-- A pose freezes on its last frame. A one-shot stops.
		task.spawn(function()
			local waited = 0
			while playing.Length <= 0 and waited < 3 do
				task.wait(0.1)
				waited += 0.1
			end
			if playing.Length <= 0 then
				return
			end
			task.wait(math.max(0, playing.Length - playing.TimePosition - (if hold then 0.05 else 0.2)))
			if holdTokens[playing] == token and playing.IsPlaying then
				if hold then
					playing:AdjustSpeed(0)
				else
					playing:Stop(0.2)
				end
			end
		end)
	end
end

-- Welds a prop (Data/Activities.Props) to an arm, the right unless hand is "left". Nil removes the
-- current one.
function LOD.setProp(npc: any, parts: { any }?, hand: string?)
	local rig: Rig? = npc.rig
	if not rig then
		return
	end
	if rig.prop then
		rig.prop:Destroy()
		rig.prop = nil
	end
	if not parts then
		return
	end
	local arm = if hand == "left"
		then rig.model:FindFirstChild("Left Arm") or rig.model:FindFirstChild("LeftHand")
		else rig.model:FindFirstChild("Right Arm") or rig.model:FindFirstChild("RightHand")
	if not arm or not arm:IsA("BasePart") then
		return
	end
	local holder = Instance.new("Folder")
	holder.Name = "CarriedProp"
	for _, def in parts do
		local part = Instance.new("Part")
		part.Name = "Prop"
		part.Size = def.size
		part.Color = def.color
		part.Material = def.material
		part.CanCollide = false
		part.CanTouch = false
		part.CanQuery = false
		part.Massless = true
		part.CastShadow = false
		part.TopSurface = Enum.SurfaceType.Smooth
		part.BottomSurface = Enum.SurfaceType.Smooth
		part:SetAttribute("Flammability", 0)
		part.CFrame = arm.CFrame * CFrame.new(def.offset)
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = arm
		weld.Part1 = part
		weld.Parent = part
		part.Parent = holder
	end
	holder.Parent = rig.model
	rig.prop = holder
end

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
