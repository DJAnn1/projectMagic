--!strict
--[[
	ActivityController: draws what every NPC is doing, from the NpcActivity attribute alone
	(Shared/Life/ActivityState, docs/Activities.md). Nothing here decides anything: the server's
	ActivityService does, and every client draws the same thing from the same record and clock.

	PER NPC, by distance from the camera (re-sorted 5 times a second, nearest first):
		full    within FULL_RANGE, up to MAX_FULL: the pose (procedural, or the activity's clip when its
		        slot is filled), held props, the set piece at the spot, small effects on the person
		props   within PROP_RANGE, up to MAX_PROPS: props and the reduced loop (fewer joints moving)
		none    beyond: nothing per person. Stations still show from afar (StationFx's smoke).
	Phones and reduced effects halve the caps. Interrupted NPCs (talking, greeted) freeze the pose and
	keep or put down the tool, as their activity says.

	STRIKES  A tool landing (the hammer, the axe, the hoe) is worked out from the same clock as the pose,
	         so the anvil's sparks (StationFx.strike) and the woodpile's chips happen on the blow.
	DEBUG    The actlabels admin command (ActivityDebug remote, to that admin only) shows activity, phase,
	         station, reason and progress over every NPC within DEBUG_RANGE.

	Budget: one PreAnimation and one PreSimulation pass over posed rigs (≤ MAX_FULL), a 5 Hz sort and
	attach pass, StationFx at 5 Hz. No remotes.
]]

local CollectionService = game:GetService("CollectionService")
local RunService = game:GetService("RunService")
local UserInputService = game:GetService("UserInputService")

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Net = require(Shared.Net)
local ActivityLibrary = require(Shared.Life.Data.ActivityLibrary)
local ActivityPoses = require(Shared.Life.Data.ActivityPoses)
local ActivityState = require(Shared.Life.ActivityState)
local StationTypes = require(Shared.Life.Data.StationTypes)

local Client = script.Parent.Parent
local Fx = Client:WaitForChild("Fx")
local ActivityPoser = require(Fx.ActivityPoser)
local ActivityProps = require(Fx.ActivityProps)
local SetPieces = require(Fx.SetPieces)
local StationFx = require(Fx.StationFx)
local KenneyTextures = require(Fx.KenneyTextures)
local Theme = require(Client:WaitForChild("UI").Theme)

local FULL_RANGE = 70
local PROP_RANGE = 140
local MAX_FULL = 24
local MAX_PROPS = 40
local DEBUG_RANGE = 120
local SORT_EVERY = 0.2
local CLIP_GAP = 0.35 -- seconds between replays of a one-shot activity clip

type Activity = ActivityLibrary.Activity

type Npc = {
	model: Model,
	root: BasePart?,
	raw: string?,
	state: ActivityState.State?,
	def: Activity?,
	rp: ActivityPoser.RigPose?,
	tier: string, -- "full" | "props" | "none"
	held: { [string]: ActivityProps.Held },
	piece: SetPieces.Piece?,
	pieceKey: string?,
	frame: CFrame?,
	clip: AnimationTrack?,
	clipSlot: string?,
	clipBad: boolean,
	nextPlay: number,
	strikeAt: number?,
	lastT: number,
	vfx: { [string]: ParticleEmitter },
	vfxAnchor: Attachment?,
	label: BillboardGui?,
}

local ActivityController = {
	name = "ActivityController",
	dependencies = {},
}

local npcs: { [Model]: Npc } = {}
local debugOn = false
local sortAt = 0
local debugAt = 0

local function quality(): number
	local q = 1
	if UserInputService.TouchEnabled and not UserInputService.KeyboardEnabled then
		q *= 0.5
	end
	if Theme.settings.reducedEffects then
		q *= 0.5
	end
	return q
end

local function effectsOn(): boolean
	return not Theme.settings.reducedEffects
end

-- ─── Decoding ───────────────────────────────────────────────────────────────

local function decode(n: Npc)
	local raw = n.model:GetAttribute(ActivityState.ATTR)
	if raw == n.raw then
		return
	end
	n.raw = if typeof(raw) == "string" then raw else nil
	local state = ActivityState.decode(raw)
	n.state = state
	n.def = if state then ActivityLibrary.byIndex[state.index] else nil
end

-- ─── Props ──────────────────────────────────────────────────────────────────

local function setProps(n: Npc, want: { [string]: string })
	for hand, held in n.held do
		if want[hand] ~= held.id then
			ActivityProps.detach(held)
			n.held[hand] = nil
		end
	end
	for hand, id in want do
		if not n.held[hand] then
			local held = ActivityProps.attach(n.model, id, hand)
			if held then
				n.held[hand] = held
			end
		end
	end
end

local function wantedProps(n: Npc, now: number): { [string]: string }
	local state, def = n.state, n.def
	if not state or not def or n.tier == "none" then
		return {}
	end
	if not ActivityState.propsOut(state, now, def.carry, def.interrupt) then
		return {}
	end
	local out: { [string]: string } = {}
	if def.props.right then
		out.right = def.props.right
	end
	if def.props.left then
		out.left = def.props.left
	end
	return out
end

-- ─── Effects on the person ──────────────────────────────────────────────────

local VFX: { [string]: { [string]: any } } = {
	flour = { Texture = KenneyTextures.smoke_02, Color = ColorSequence.new(Color3.fromRGB(250, 246, 236)), Size = NumberSequence.new(0.3, 0.8), Lifetime = NumberRange.new(0.6, 1), Speed = NumberRange.new(0.5, 1.5), Transparency = NumberSequence.new(0.5, 1), Rate = 4, LightInfluence = 1 },
	dust = { Texture = KenneyTextures.smoke_05, Color = ColorSequence.new(Color3.fromRGB(196, 178, 140)), Size = NumberSequence.new(0.6, 1.8), Lifetime = NumberRange.new(0.8, 1.4), Speed = NumberRange.new(0.5, 2), Transparency = NumberSequence.new(0.55, 1), Rate = 6, LightInfluence = 1 },
	dirt = { Texture = KenneyTextures.dirt_02, Color = ColorSequence.new(Color3.fromRGB(110, 80, 52)), Size = NumberSequence.new(0.3, 0.1), Lifetime = NumberRange.new(0.4, 0.7), Speed = NumberRange.new(4, 7), SpreadAngle = Vector2.new(50, 50), Acceleration = Vector3.new(0, -30, 0), Rate = 0, LightInfluence = 1 },
	chips = { Texture = KenneyTextures.dirt_01, Color = ColorSequence.new(Color3.fromRGB(196, 160, 112)), Size = NumberSequence.new(0.2, 0.05), Lifetime = NumberRange.new(0.4, 0.6), Speed = NumberRange.new(5, 9), SpreadAngle = Vector2.new(60, 60), Acceleration = Vector3.new(0, -30, 0), Rate = 0, LightInfluence = 1 },
	prayer = { Texture = KenneyTextures.light_02, Color = ColorSequence.new(Color3.fromRGB(255, 236, 190)), Size = NumberSequence.new(0.3, 0), Lifetime = NumberRange.new(1.5, 2.5), Speed = NumberRange.new(0.2, 0.6), SpreadAngle = Vector2.new(180, 180), LightEmission = 1, Rate = 4, LightInfluence = 0 },
	-- Stage 2 (2026-11-07). Rate 0 = only on a strike (the tool landing).
	grit = { Texture = KenneyTextures.dirt_01, Color = ColorSequence.new(Color3.fromRGB(140, 134, 124)), Size = NumberSequence.new(0.3, 0.08), Lifetime = NumberRange.new(0.4, 0.7), Speed = NumberRange.new(5, 9), SpreadAngle = Vector2.new(60, 60), Acceleration = Vector3.new(0, -30, 0), Rate = 0, LightInfluence = 1 },
	shavings = { Texture = KenneyTextures.dirt_01, Color = ColorSequence.new(Color3.fromRGB(222, 190, 140)), Size = NumberSequence.new(0.15, 0.05), Lifetime = NumberRange.new(0.5, 0.8), Speed = NumberRange.new(1, 3), SpreadAngle = Vector2.new(50, 50), Acceleration = Vector3.new(0, -14, 0), Rate = 0, LightInfluence = 1 },
	leaves = { Texture = KenneyTextures.dirt_02, Color = ColorSequence.new(Color3.fromRGB(110, 160, 80)), Size = NumberSequence.new(0.18, 0.05), Lifetime = NumberRange.new(0.6, 1.1), Speed = NumberRange.new(0.5, 1.5), SpreadAngle = Vector2.new(90, 90), Acceleration = Vector3.new(0, -3, 0), Rate = 3, LightInfluence = 1 },
	spray = { Texture = KenneyTextures.circle_05, Color = ColorSequence.new(Color3.fromRGB(210, 232, 255)), Size = NumberSequence.new(0.15, 0.4), Lifetime = NumberRange.new(0.8, 1.4), Speed = NumberRange.new(0.5, 1.5), SpreadAngle = Vector2.new(180, 180), Transparency = NumberSequence.new(0.4, 1), Acceleration = Vector3.new(0, -2, 0), Rate = 6, LightInfluence = 1 },
	wind = { Texture = KenneyTextures.smoke_05, Color = ColorSequence.new(Color3.fromRGB(235, 245, 255)), Size = NumberSequence.new(0.5, 1.6), Lifetime = NumberRange.new(0.6, 1), Speed = NumberRange.new(3, 6), SpreadAngle = Vector2.new(25, 25), Transparency = NumberSequence.new(0.75, 1), Rate = 5, LightInfluence = 1 },
	suds = { Texture = KenneyTextures.circle_05, Color = ColorSequence.new(Color3.fromRGB(250, 250, 255)), Size = NumberSequence.new(0.2, 0.35), Lifetime = NumberRange.new(0.8, 1.4), Speed = NumberRange.new(0.2, 0.8), SpreadAngle = Vector2.new(120, 120), Transparency = NumberSequence.new(0.2, 1), Acceleration = Vector3.new(0, 1, 0), Rate = 5, LightInfluence = 1 },
}

local function dropVfx(n: Npc)
	for _, e in n.vfx do
		e:Destroy()
	end
	table.clear(n.vfx)
	if n.vfxAnchor then
		n.vfxAnchor:Destroy()
		n.vfxAnchor = nil
	end
end

local function syncVfx(n: Npc, on: boolean)
	local def = n.def
	if not on or not def or #def.vfx == 0 or not effectsOn() then
		dropVfx(n)
		return
	end
	-- At the tool's working end, else between the hands.
	local held = n.held.right
	local parent: Instance? = if held then held.tip else nil
	if not parent then
		if not n.vfxAnchor then
			local torso = n.model:FindFirstChild("Torso")
			if torso then
				local a = Instance.new("Attachment")
				a.Name = "ActivityVfx"
				a.Position = Vector3.new(0, -0.4, -1.4)
				a.Parent = torso
				n.vfxAnchor = a
			end
		end
		parent = n.vfxAnchor
	end
	if not parent then
		return
	end
	for _, id in def.vfx do
		local e = n.vfx[id]
		if e and e.Parent ~= parent then
			e.Parent = parent
		elseif not e then
			local spec = VFX[id]
			if spec then
				local made = Instance.new("ParticleEmitter")
				for k, v in spec do
					(made :: any)[k] = v
				end
				made.Parent = parent
				n.vfx[id] = made
			end
		end
	end
end

-- ─── Stations and spots ─────────────────────────────────────────────────────

-- Where the body goes for sit and lie: the BodyCFrame of the station's use point nearest the rig.
local function bodyOf(n: Npc): CFrame?
	local state = n.state
	if not state or state.station == "" or not n.root then
		return nil
	end
	local part = StationFx.partFor(state.station)
	if not part then
		return nil
	end
	local best, bestD = nil :: CFrame?, math.huge
	for _, child in part:GetChildren() do
		if child:IsA("Attachment") and CollectionService:HasTag(child, StationTypes.POINT_TAG) then
			local body = child:GetAttribute(StationTypes.ATTR.body)
			if typeof(body) == "CFrame" then
				local d = (child.WorldPosition - (n.root :: BasePart).Position).Magnitude
				if d < bestD then
					best, bestD = body, d
				end
			end
		end
	end
	return best
end

local function dropPiece(n: Npc)
	if n.piece then
		SetPieces.destroy(n.piece)
	end
	n.piece, n.pieceKey, n.frame = nil, nil, nil
end

local function pieceCtx(n: Npc): SetPieces.Ctx
	local state = n.state :: ActivityState.State
	local held = n.held.right
	return {
		model = n.model,
		frame = n.frame :: CFrame,
		body = bodyOf(n),
		tip = if held then held.tip else nil,
		domain = if state.domain ~= "" then state.domain else (n.def and n.def.domain) or "energy",
		tier = math.max(state.tier, 1),
		signature = n.model:GetAttribute("MagicSignature") :: string?,
		effects = effectsOn(),
	}
end

local function syncPiece(n: Npc, now: number)
	local state, def = n.state, n.def
	local working = state and def and def.setPiece and n.tier == "full" and (state.phase == "W" or state.phase == "I" or (state.phase == "F" and n.piece ~= nil))
	if not working or not state or not def or not n.root then
		dropPiece(n)
		return
	end
	-- One piece per piece of work being done here (a new activity or a new start makes a new one).
	local key = string.format("%d:%.1f", state.index, state.start)
	if n.pieceKey ~= key then
		dropPiece(n)
		local r = n.root :: BasePart
		local look = r.CFrame.LookVector
		n.frame = CFrame.lookAt(r.Position - Vector3.new(0, 3, 0), r.Position - Vector3.new(0, 3, 0) + Vector3.new(look.X, 0, look.Z))
		n.pieceKey = key
		n.piece = SetPieces.create(def.setPiece :: string, pieceCtx(n))
	end
	local piece = n.piece
	if piece then
		local progress, pieces = ActivityState.progress(state, now)
		SetPieces.update(piece, pieceCtx(n), progress, pieces, now - state.start)
	end
end

-- ─── Clips and poses ────────────────────────────────────────────────────────

local function stopClip(n: Npc)
	if n.clip and n.clip.IsPlaying then
		n.clip:Stop(0.2)
	end
end

-- The activity's own animation, played on this client when its slot is filled. Falls back to the
-- procedural pose for good if the clip turns out empty (it couldn't load here).
local function clipFor(n: Npc): AnimationTrack?
	local def = n.def
	if not def or not def.clip or n.clipBad or not ActivityPoses.hasClip(def.clip) then
		return nil
	end
	if n.clipSlot == def.clip and n.clip then
		return n.clip
	end
	stopClip(n)
	local humanoid = n.model:FindFirstChildOfClass("Humanoid")
	local animator = humanoid and humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		return nil
	end
	local animation = Instance.new("Animation")
	animation.AnimationId = ActivityPoses.slots[def.clip]
	local ok, track = pcall(function()
		return (animator :: Animator):LoadAnimation(animation)
	end)
	if not ok or not track then
		n.clipBad = true
		return nil
	end
	track.Priority = Enum.AnimationPriority.Action
	track.Looped = false
	n.clip, n.clipSlot = track, def.clip
	n.nextPlay = 0
	task.delay(3, function()
		if n.clip == track and track.Length <= 0 then
			n.clipBad = true -- it never loaded here: the procedural pose takes over
		end
	end)
	return track
end

local function strike(n: Npc)
	local state = n.state
	if not state then
		return
	end
	if state.station ~= "" then
		StationFx.strike(state.station)
	end
	if n.piece then
		SetPieces.strike(n.piece)
	end
	local dirt = n.vfx.dirt or n.vfx.chips or n.vfx.grit or n.vfx.shavings
	if dirt then
		dirt:Emit(6)
	end
end

local function animate(n: Npc, now: number)
	local state, def, rp = n.state, n.def, n.rp
	if not state or not def or not rp or n.tier == "none" then
		if rp then
			ActivityPoser.clear(rp)
		end
		stopClip(n)
		return
	end
	local weight = ActivityState.weight(state, now)
	local t = if state.phase == "I" then state.phaseAt - state.start else now - state.start
	local pose = ActivityPoses.poses[def.pose]
	local track = if n.tier == "full" and state.phase == "W" then clipFor(n) else nil
	if track and not n.clipBad then
		-- The clip does the work; strikes come from its timing.
		ActivityPoser.clear(rp)
		if not track.IsPlaying and now >= n.nextPlay then
			track:Play(0.15)
			local length = if track.Length > 0 then track.Length else 1
			n.nextPlay = now + length + CLIP_GAP
			n.strikeAt = now + length * (def.strikeAt or 0.5)
		end
		if n.strikeAt and now >= n.strikeAt then
			n.strikeAt = nil
			strike(n)
		end
		n.lastT = t
		return
	end
	stopClip(n)
	if weight <= 0 or not pose then
		ActivityPoser.clear(rp)
		n.lastT = t
		return
	end
	ActivityPoser.set(rp, def.pose, state.variant, t, weight, n.tier ~= "full", bodyOf(n))
	-- Strikes on a procedural pose: a tool lands at every period boundary.
	if n.tier == "full" and state.phase == "W" and pose then
		local hasStrike = false
		for _, m in pose.motion do
			if m.shape == "strike" then
				hasStrike = true
			end
		end
		if hasStrike then
			local v = pose.variants[math.clamp(state.variant, 1, #pose.variants)] or pose.variants[1]
			if ActivityPoses.strikesBetween(n.lastT, t, pose.period / v.speed) > 0 then
				strike(n)
			end
		end
	end
	n.lastT = t
end

-- ─── Debug labels ───────────────────────────────────────────────────────────

local function dropLabel(n: Npc)
	if n.label then
		n.label:Destroy()
		n.label = nil
	end
end

local function updateLabel(n: Npc, now: number, distance: number)
	if not debugOn or distance > DEBUG_RANGE then
		dropLabel(n)
		return
	end
	local head = n.model:FindFirstChild("Head")
	if not head then
		return
	end
	local label = n.label
	if not label then
		local gui = Instance.new("BillboardGui")
		gui.Name = "ActivityDebug"
		gui.Size = UDim2.fromOffset(240, 64)
		gui.StudsOffset = Vector3.new(0, 4.6, 0)
		gui.AlwaysOnTop = true
		gui.MaxDistance = DEBUG_RANGE
		local text = Instance.new("TextLabel")
		text.Name = "Text"
		text.BackgroundTransparency = 0.35
		text.BackgroundColor3 = Color3.fromRGB(10, 10, 16)
		text.TextColor3 = Color3.fromRGB(230, 240, 255)
		text.Font = Enum.Font.RobotoMono
		text.TextSize = 12
		text.TextWrapped = true
		text.Size = UDim2.fromScale(1, 1)
		text.Parent = gui
		gui.Adornee = head :: BasePart
		gui.Parent = n.model
		n.label = gui
		label = gui
	end
	local text = (label :: BillboardGui):FindFirstChild("Text") :: TextLabel
	local state, def = n.state, n.def
	if not state or not def then
		text.Text = "(no activity)"
		return
	end
	local progress = ActivityState.progress(state, now)
	text.Text = string.format("%s · %s\n%s\n%s · %d%% · %s",
		def.id, ActivityState.phaseNames[state.phase],
		if state.station ~= "" then state.station else "(spot)",
		ActivityLibrary.reasons[state.reason] or state.reason, math.floor(progress * 100), n.tier)
end

-- ─── Tracking ───────────────────────────────────────────────────────────────

local function release(n: Npc)
	setProps(n, {})
	dropPiece(n)
	dropVfx(n)
	dropLabel(n)
	stopClip(n)
	if n.rp then
		ActivityPoser.clear(n.rp)
	end
end

local function track(model: Instance)
	if not model:IsA("Model") or npcs[model] then
		return
	end
	local n: Npc = {
		model = model, root = nil, raw = nil, state = nil, def = nil, rp = nil, tier = "none", held = {},
		piece = nil, pieceKey = nil, frame = nil, clip = nil, clipSlot = nil, clipBad = false, nextPlay = 0,
		strikeAt = nil, lastT = 0, vfx = {}, vfxAnchor = nil, label = nil,
	}
	npcs[model] = n
	model:GetAttributeChangedSignal(ActivityState.ATTR):Connect(function()
		decode(n)
	end)
	decode(n)
end

local function untrack(model: Instance)
	local n = npcs[model :: Model]
	if n then
		release(n)
		npcs[model :: Model] = nil
	end
end

local function sortPass(now: number)
	local camera = workspace.CurrentCamera
	if not camera then
		return
	end
	local eye = camera.CFrame.Position
	local q = quality()
	local maxFull, maxProps = math.floor(MAX_FULL * q), math.floor(MAX_PROPS * q)
	local list: { { n: Npc, d: number } } = {}
	for model, n in npcs do
		if not model.Parent then
			untrack(model)
			continue
		end
		if not n.root or not n.root.Parent then
			local r = model:FindFirstChild("HumanoidRootPart")
			n.root = if r and r:IsA("BasePart") then r else nil
			n.rp = nil
		end
		if n.root and not n.rp then
			n.rp = ActivityPoser.prepare(model)
		end
		local d = if n.root then (n.root.Position - eye).Magnitude else math.huge
		table.insert(list, { n = n, d = d })
	end
	table.sort(list, function(a, b)
		return a.d < b.d
	end)
	local full, props = 0, 0
	for _, item in list do
		local n = item.n
		local tier = "none"
		if n.def and n.root then
			if item.d <= FULL_RANGE and full < maxFull then
				tier = "full"
				full += 1
			elseif item.d <= PROP_RANGE and props < maxProps then
				tier = "props"
				props += 1
			end
		end
		n.tier = tier
		setProps(n, wantedProps(n, now))
		syncVfx(n, tier == "full" and n.state ~= nil and (n.state.phase == "W" or n.state.phase == "P"))
		syncPiece(n, now)
		if now >= debugAt then
			updateLabel(n, now, item.d)
		end
	end
	if now >= debugAt then
		debugAt = now + 0.5
	end
	StationFx.step(eye, now, q)
end

function ActivityController.init(_self: any, _ctx: any) end

function ActivityController.start(_self: any, _ctx: any)
	task.spawn(function()
		local folder = workspace:WaitForChild("NPCs", 120)
		if not folder then
			return
		end
		folder.ChildAdded:Connect(track)
		folder.ChildRemoved:Connect(untrack)
		for _, child in folder:GetChildren() do
			track(child)
		end
	end)
	CollectionService:GetInstanceAddedSignal(StationTypes.TAG):Connect(StationFx.track)
	CollectionService:GetInstanceRemovedSignal(StationTypes.TAG):Connect(StationFx.untrack)
	for _, part in CollectionService:GetTagged(StationTypes.TAG) do
		StationFx.track(part)
	end
	Net.listen("ActivityDebug", function(on: any)
		debugOn = on == true
		if not debugOn then
			for _, n in npcs do
				dropLabel(n)
			end
		end
	end)
	RunService.PreAnimation:Connect(ActivityPoser.restore)
	RunService.PreSimulation:Connect(function()
		local now = workspace:GetServerTimeNow()
		for _, n in npcs do
			if n.tier ~= "none" and n.rp then
				animate(n, now)
			elseif n.rp and n.rp.target then
				ActivityPoser.clear(n.rp)
			end
		end
		ActivityPoser.step()
	end)
	RunService.Heartbeat:Connect(function()
		local now = workspace:GetServerTimeNow()
		if now >= sortAt then
			sortAt = now + SORT_EVERY
			sortPass(now)
		end
	end)
end

-- For the Observe tooltip: the decoded state of an NPC model (nil when it has none).
function ActivityController.stateOf(model: Model): (ActivityState.State?, Activity?)
	local n = npcs[model]
	if not n then
		return nil, nil
	end
	return n.state, n.def
end

return ActivityController
