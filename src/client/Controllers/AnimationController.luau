--!strict
--[[
	AnimationController: plays the local character's combat animations (docs/Combat.md §11).
	Never authority: the server sets the character's action state (ActionRules attributes) and
	this follows it. Tracks are played on the character's own Animator, so every other client
	sees them through Roblox's normal animation replication.

	TRACKS     every clip in Data/CombatAnimations, loaded on each spawn (priority, looped). A clip
	           whose asset failed to load (ContentProvider status, or Length still 0 after
	           LOAD_GRACE seconds) is marked unavailable and logged once; its state still works,
	           just without that clip.
	STATES     on every ActionStateSeq change: stop the old state's clips, play the new entry clip
	           (speed from ActionRules.playbackSpeed, so a cast's "Release" lands at its cast
	           time), then its loop clip once the entry ends. ActionReactSeq plays a one-shot
	           reaction (BlockHit) on top.
	PREDICTION CastClient calls predict("casting", castTime, domain) so the clip starts at the key
	           press. When the server's matching state arrives within PREDICT_WINDOW the clip is
	           kept (speed re-fitted to the server's duration); a refusal calls cancelPrediction.
	MARKERS    marker(clip, name) -> Signal. Fires on the real keyframe marker or, if it hasn't
	           fired by then, at the data's `at` fraction of the clip (fallback), once per play.
	DEBUG      flag combat_anim_debug: a state label over every character and NPC within
	           DEBUG_RANGE (local billboards, 5 Hz). The flag replicates to everyone: Studio use.

	API: play(name, opts?) -> AnimationTrack?, stop(name, fade?), stopAll(fade?), available(name),
	     predict(state, duration?, domain?, variant?), cancelPrediction(), hitStop(seconds), state(): string,
	     stateChanged Signal(state, previous), marker(clip, name) -> Signal.
]]

local ContentProvider = game:GetService("ContentProvider")
local Players = game:GetService("Players")
local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Signal = require(Shared.Core.Signal)
local Logger = require(Shared.Core.Logger)
local FeatureFlags = require(Shared.Core.FeatureFlags)
local ActionRules = require(Shared.Magic.ActionRules)
local Data = require(Shared.Magic.Data.CombatAnimations)

local A = ActionRules.ATTR
local LOAD_GRACE = 6 -- seconds after loading before a 0-length track counts as failed
local PREDICT_WINDOW = 1.5 -- seconds a prediction waits for the server's state
local DEBUG_RANGE = 120
local DEBUG_HZ = 5

local log = Logger.new("AnimationController")
local localPlayer = Players.LocalPlayer

local AnimationController = {
	name = "AnimationController",
	dependencies = {},
}

AnimationController.stateChanged = Signal.new()

type Loaded = {
	track: AnimationTrack,
	def: Data.AnimationDef,
	token: number, -- increments per play: fallback markers only fire for their own play
	fired: { [string]: number }, -- marker name -> token it last fired for
}

local animations: { [string]: Animation } = {} -- one Animation instance per clip, reused per spawn
local loaded: { [string]: Loaded } = {}
local unavailable: { [string]: boolean } = {}
local warned: { [string]: boolean } = {}
local markerSignals: { [string]: Signal.Signal } = {}
local characterConnections: { RBXScriptConnection } = {}

local current = { state = "idle", seq = 0, entry = nil :: string?, loop = nil :: string? }
local stateToken = 0 -- increments per entered state; delayed steps (loop, freeze) check it
local prediction: { state: string, at: number }? = nil

local function warnOnce(key: string, event: string, fields: { [string]: any })
	if warned[key] then
		return
	end
	warned[key] = true
	log:warn(event, fields)
end

local function markerSignal(clip: string, name: string): Signal.Signal
	local key = clip .. "/" .. name
	local signal = markerSignals[key]
	if not signal then
		signal = Signal.new()
		markerSignals[key] = signal
	end
	return signal
end

local function fireMarker(clip: string, entry: Loaded, name: string, token: number)
	if entry.fired[name] == token then
		return -- the real marker and the fallback both arrived: once is enough
	end
	entry.fired[name] = token
	markerSignal(clip, name):Fire(clip, name)
end

-- ─── Loading ────────────────────────────────────────────────────────────────

local function animationFor(name: string): Animation
	local animation = animations[name]
	if not animation then
		animation = Instance.new("Animation")
		animation.Name = name
		animation.AnimationId = "rbxassetid://" .. tostring(Data.animations[name].id)
		animations[name] = animation
	end
	return animation
end

local function markUnavailable(name: string, why: string)
	unavailable[name] = true
	warnOnce("load:" .. name, "animation_unavailable", { clip = name, id = Data.animations[name].id, why = why })
end

local function unloadAll()
	for _, connection in characterConnections do
		connection:Disconnect()
	end
	table.clear(characterConnections)
	for _, entry in loaded do
		entry.track:Stop(0)
		entry.track:Destroy()
	end
	table.clear(loaded)
	current = { state = "idle", seq = 0, entry = nil, loop = nil }
	prediction = nil
end

local function loadTracks(animator: Animator)
	for name, def in Data.animations do
		if unavailable[name] then
			continue
		end
		local ok, track = pcall(function()
			return animator:LoadAnimation(animationFor(name))
		end)
		if not ok or not track then
			markUnavailable(name, "LoadAnimation failed: " .. tostring(track))
			continue
		end
		track.Priority = ActionRules.priorityOf(name)
		track.Looped = def.looped == true
		local entry: Loaded = { track = track, def = def, token = 0, fired = {} }
		for _, marker in def.markers do
			table.insert(characterConnections, track:GetMarkerReachedSignal(marker.name):Connect(function()
				fireMarker(name, entry, marker.name, entry.token)
			end))
		end
		loaded[name] = entry
	end
	-- A clip the account can't use loads as a track that never gets a Length.
	task.delay(LOAD_GRACE, function()
		for name, entry in loaded do
			if entry.track.Length <= 0 and not unavailable[name] then
				markUnavailable(name, "track length still 0 (not owned by the place's creator?)")
			end
		end
	end)
end

-- ─── Playback ───────────────────────────────────────────────────────────────

export type PlayOptions = {
	speed: number?,
	duration: number?, -- fit the clip's Release/end to this many seconds
	domain: string?,
	fade: number?,
}

function AnimationController.available(_self: any, name: string): boolean
	return loaded[name] ~= nil and not unavailable[name]
end

function AnimationController.play(_self: any, name: string, opts: PlayOptions?): AnimationTrack?
	local entry = loaded[name]
	if not entry or unavailable[name] then
		return nil
	end
	local o: PlayOptions = opts or {}
	local track = entry.track
	local speed = o.speed or ActionRules.playbackSpeed(name, track.Length, o.duration, o.domain)
	track:Play(o.fade or entry.def.fadeIn, ActionRules.weightFor(o.domain), speed)
	entry.token += 1
	local token = entry.token
	-- Fallback markers: fire at the data's fraction unless the real marker beat us to it.
	local clip = if track.Length > 0 then track.Length else entry.def.approxLength
	for _, marker in entry.def.markers do
		task.delay(clip * marker.at / speed, function()
			if entry.token == token and loaded[name] == entry then
				fireMarker(name, entry, marker.name, token)
			end
		end)
	end
	return track
end

function AnimationController.stop(_self: any, name: string, fade: number?)
	local entry = loaded[name]
	if entry and entry.track.IsPlaying then
		entry.track:Stop(fade or entry.def.fadeOut)
	end
end

function AnimationController.stopAll(self: any, fade: number?)
	for name in loaded do
		self:stop(name, fade)
	end
end

function AnimationController.marker(_self: any, clip: string, name: string): Signal.Signal
	return markerSignal(clip, name)
end

function AnimationController.state(_self: any): string
	return current.state
end

-- Plays a state's clips. `seq` tags the play so a later state cancels the pending loop clip.
local function enterState(state: string, seq: number, duration: number, domain: string?, variant: string?)
	local self = AnimationController
	local previous = current.state
	local entryClip, loopClip = ActionRules.clipsFor(state, variant)
	local def = Data.states[state]

	-- Resume: the previous state froze this same clip at a marker (charging's wind-up pose), so
	-- the new state (the release) carries on from that pose instead of starting over.
	local prevDef = Data.states[previous]
	local resumeAt = if entryClip and prevDef and prevDef.holdAt and current.entry == entryClip
		then ActionRules.markerFraction(entryClip, prevDef.holdAt)
		else nil
	local held = entryClip and loaded[entryClip]
	local resuming = resumeAt ~= nil and held ~= nil and held.track.IsPlaying

	-- Stop the old state's clips (unless the new state plays the same loop: no restart flicker).
	if current.entry and not resuming then
		self:stop(current.entry)
	end
	if current.loop and current.loop ~= loopClip then
		self:stop(current.loop)
	end
	current = { state = state, seq = seq, entry = entryClip, loop = loopClip }
	stateToken += 1
	local token = stateToken

	local entryTrack: AnimationTrack? = nil
	if resuming and held then
		local track = held.track
		local finish = if def.scaleToDuration then duration else Data.animations[entryClip :: string].approxLength
		track:AdjustSpeed(ActionRules.resumeSpeed(entryClip :: string, track.Length, resumeAt :: number, finish))
		entryTrack = track
	elseif entryClip then
		entryTrack = self:play(entryClip, { duration = if def.scaleToDuration then duration else nil, domain = domain })
	end

	-- Hold: freeze the clip when it reaches the marker, while this state lasts.
	local holdAt = def.holdAt
	if entryTrack and entryClip and holdAt then
		local fraction = ActionRules.markerFraction(entryClip, holdAt) or 1
		local clip = if entryTrack.Length > 0 then entryTrack.Length else Data.animations[entryClip].approxLength
		local track = entryTrack
		task.delay(clip * fraction / math.max(track.Speed, 0.01), function()
			if stateToken == token and track.IsPlaying then
				track:AdjustSpeed(0)
			end
		end)
	end
	if loopClip then
		local loopEntry = loaded[loopClip]
		if not entryTrack then
			if not (loopEntry and loopEntry.track.IsPlaying) then
				self:play(loopClip, { domain = domain })
			end
		else
			-- After the entry clip: the loop, if this state is still the one playing. With no
			-- usable loop clip (e.g. Block failed to load), the entry clip holds its last pose.
			local clip = if entryTrack.Length > 0 then entryTrack.Length else Data.animations[entryClip :: string].approxLength
			local loopUsable = self:available(loopClip)
			local track = entryTrack
			local lead = if loopUsable then Data.animations[loopClip].fadeIn else 0.03
			task.delay(math.max(0, clip / math.max(track.Speed, 0.01) - lead), function()
				if stateToken ~= token then
					return
				end
				if loopUsable then
					self:play(loopClip, { domain = domain })
				elseif track.IsPlaying then
					track:AdjustSpeed(0)
				end
			end)
		end
	end
	if previous ~= state then
		AnimationController.stateChanged:Fire(state, previous)
	end
end

-- The server's state changed (ActionStateSeq): follow it.
local function onServerState(character: Model)
	local snapshot = ActionRules.read(character)
	local p = prediction
	if p and p.state == snapshot.state and os.clock() - p.at < PREDICT_WINDOW then
		-- Our prediction was right: keep the clip, re-fit its speed to the server's duration.
		prediction = nil
		current.seq = snapshot.seq
		local entryClip = current.entry
		local entry = entryClip and loaded[entryClip]
		local def = Data.states[snapshot.state]
		if entry and entry.track.IsPlaying and def.scaleToDuration then
			entry.track:AdjustSpeed(ActionRules.playbackSpeed(entryClip :: string, entry.track.Length, snapshot.duration, snapshot.domain))
		end
		return
	end
	prediction = nil
	local remaining = if snapshot.untilTime > 0 then snapshot.untilTime - workspace:GetServerTimeNow() else 0
	if snapshot.untilTime > 0 and remaining <= 0 then
		return -- arrived after it already ended (lag spike): don't play a stale clip
	end
	enterState(snapshot.state, snapshot.seq, if remaining > 0 then remaining else snapshot.duration, snapshot.domain, snapshot.variant)
end

function AnimationController.predict(_self: any, state: string, duration: number?, domain: string?, variant: string?)
	if not Data.states[state] or not localPlayer.Character then
		return
	end
	prediction = { state = state, at = os.clock() }
	enterState(state, -1, duration or Data.states[state].duration, domain, variant)
end

-- Hit-stop: the playing action clip freezes for a moment when your blow lands, then carries on.
function AnimationController.hitStop(_self: any, seconds: number)
	local clip = current.entry
	local entry = clip and loaded[clip]
	if not entry or not entry.track.IsPlaying then
		return
	end
	local track = entry.track
	local speed = track.Speed
	if speed <= 0 then
		return
	end
	track:AdjustSpeed(0)
	task.delay(seconds, function()
		if track.IsPlaying and track.Speed == 0 then
			track:AdjustSpeed(speed)
		end
	end)
end

-- The server refused: go back to whatever the server says we're doing.
function AnimationController.cancelPrediction(_self: any)
	if not prediction then
		return
	end
	prediction = nil
	local character = localPlayer.Character
	if character and current.seq == -1 then
		local snapshot = ActionRules.read(character)
		enterState(snapshot.state, snapshot.seq, snapshot.duration, snapshot.domain, snapshot.variant)
	end
end

-- ─── Character lifecycle ────────────────────────────────────────────────────

--[[
	Points the default Animate script's locomotion sets at our clips (Data.locomotion). Animate
	watches its Animation children and reloads a set when an id changes, so this works whether it
	runs before or after Animate has started. Only touches ids that differ, so it is idempotent.
]]
local function applyLocomotion(character: Model)
	local animate = character:WaitForChild("Animate", 10)
	if not animate or character ~= localPlayer.Character then
		return
	end
	for setName, clipName in Data.locomotion do
		local clip = Data.animations[clipName]
		local folder = animate:FindFirstChild(setName)
		if clip and folder and not unavailable[clipName] then
			local id = "rbxassetid://" .. tostring(clip.id)
			for _, anim in folder:GetChildren() do
				if anim:IsA("Animation") and anim.AnimationId ~= id then
					anim.AnimationId = id
				end
			end
		end
	end
end

local function onCharacter(character: Model)
	unloadAll()
	local humanoid = character:WaitForChild("Humanoid", 10)
	local animator = humanoid and humanoid:WaitForChild("Animator", 10)
	if not animator or not animator:IsA("Animator") or character ~= localPlayer.Character then
		return
	end
	-- The avatar type comes from Game Settings › Avatar; clips for the other rig load but never move.
	local rigType = (humanoid :: Humanoid).RigType.Name
	if rigType ~= Data.rigType then
		warnOnce("rig", "rig_mismatch", {
			avatar = rigType,
			clips = Data.rigType,
			fix = "Game Settings > Avatar > Avatar Type = " .. Data.rigType,
		})
	end
	-- Every body gets a fresh try at clips that failed before (an asset fixed mid-session loads).
	table.clear(unavailable)
	table.clear(warned)
	loadTracks(animator)
	-- After loadTracks, so a Run clip that failed to load (unavailable) keeps Roblox's default.
	task.spawn(applyLocomotion, character)
	table.insert(characterConnections, character:GetAttributeChangedSignal(A.seq):Connect(function()
		onServerState(character)
	end))
	table.insert(characterConnections, character:GetAttributeChangedSignal(A.reactSeq):Connect(function()
		local clip = character:GetAttribute(A.react)
		if typeof(clip) == "string" and Data.animations[clip] then
			local track = AnimationController:play(clip)
			if not track then
				log:warn("animation_not_played", { clip = clip, why = if unavailable[clip] then "unavailable (see animation_unavailable)" else "not loaded on this character" })
			elseif RunService:IsStudio() then
				log:info("animation_played", { clip = clip, length = track.Length, speed = track.Speed, priority = track.Priority.Name })
			end
		end
	end))
	-- Spawned mid-state (rare: a respawn keeps no state, but a reconnect could): catch up.
	if ActionRules.read(character).seq > 0 then
		onServerState(character)
	end
end

-- ─── Debug labels ───────────────────────────────────────────────────────────

local labels: { [Model]: BillboardGui } = {}

local function clearLabels()
	for _, gui in labels do
		gui:Destroy()
	end
	table.clear(labels)
end

local function labelFor(model: Model): BillboardGui
	local gui = labels[model]
	if not gui then
		local g = Instance.new("BillboardGui")
		g.Name = "ActionStateLabel"
		g.Size = UDim2.fromOffset(160, 22)
		g.StudsOffset = Vector3.new(0, 4.2, 0)
		g.AlwaysOnTop = true
		g.LightInfluence = 0
		g.ResetOnSpawn = false
		local text = Instance.new("TextLabel")
		text.Name = "Text"
		text.BackgroundTransparency = 0.35
		text.BackgroundColor3 = Color3.fromRGB(20, 18, 26)
		text.TextColor3 = Color3.fromRGB(240, 232, 214)
		text.Font = Enum.Font.Code
		text.TextScaled = true
		text.Size = UDim2.fromScale(1, 1)
		text.Parent = g
		g.Parent = localPlayer:WaitForChild("PlayerGui")
		labels[model] = g
		gui = g
	end
	return gui :: BillboardGui
end

local function refreshLabels()
	local camera = workspace.CurrentCamera
	local here = camera and camera.Focus.Position or Vector3.zero
	local seen: { [Model]: boolean } = {}
	local candidates: { Model } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(candidates, player.Character)
		end
	end
	local npcs = workspace:FindFirstChild("NPCs")
	if npcs then
		for _, child in npcs:GetChildren() do
			if child:IsA("Model") then
				table.insert(candidates, child)
			end
		end
	end
	local t = workspace:GetServerTimeNow()
	for _, model in candidates do
		local root = model:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") and (root.Position - here).Magnitude <= DEBUG_RANGE then
			seen[model] = true
			local snapshot = ActionRules.read(model)
			local state = ActionRules.effective(snapshot, t)
			local left = if snapshot.untilTime > 0 then math.max(0, snapshot.untilTime - t) else nil
			local gui = labelFor(model)
			gui.Adornee = root
			local text = gui:FindFirstChild("Text") :: TextLabel
			text.Text = if left then string.format("%s %.1fs #%d", state, left, snapshot.seq) else string.format("%s #%d", state, snapshot.seq)
		end
	end
	for model, gui in labels do
		if not seen[model] then
			gui:Destroy()
			labels[model] = nil
		end
	end
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

function AnimationController.init(_self: any, _ctx: any)
	for _, pair in Data.duplicates do
		log:warn("animation_duplicate_id", { a = pair.a, b = pair.b, id = pair.id })
	end
end

function AnimationController.start(_self: any, _ctx: any)
	localPlayer.CharacterAdded:Connect(onCharacter)
	localPlayer.CharacterRemoving:Connect(function()
		unloadAll()
	end)
	if localPlayer.Character then
		task.spawn(onCharacter, localPlayer.Character)
	end

	-- Preload every clip once; a failed fetch marks the clip unavailable before anything plays it.
	local list: { Instance } = {}
	local byId: { [string]: string } = {}
	for name in Data.animations do
		local animation = animationFor(name)
		table.insert(list, animation)
		byId[animation.AnimationId] = name
	end
	task.spawn(function()
		pcall(function()
			ContentProvider:PreloadAsync(list, function(contentId: string, status: Enum.AssetFetchStatus)
				local name = byId[contentId]
				if name and status ~= Enum.AssetFetchStatus.Success then
					markUnavailable(name, "preload " .. status.Name)
				end
			end)
		end)
	end)

	local elapsed = 0
	RunService.Heartbeat:Connect(function(dt)
		if FeatureFlags.get("combat_anim_debug") ~= true then
			if next(labels) then
				clearLabels()
			end
			return
		end
		elapsed += dt
		if elapsed >= 1 / DEBUG_HZ then
			elapsed = 0
			refreshLabels()
		end
	end)
end

return AnimationController
