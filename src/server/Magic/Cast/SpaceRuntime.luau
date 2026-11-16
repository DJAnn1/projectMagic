--!strict
--[[
	SpaceRuntime: Space's powers that outlive their cast (docs/Space.md, stage 1). Effects/SpacePower starts
	them; Services/SpaceService steps them (10 Hz) and wraps Delivery.interceptor.

	GATES   Linked pairs. Each gate is a standing ring facing out. A body (player, NPC, creature) whose root
	        comes within `radius` of one is put out of the other, `exitOffset` along its face, facing out; the
	        same body can't go back through for `bodyGap` s. Bolts and arrows (Delivery flights) are moved the
	        same way ("warp"), keeping their speed and leaving along the exit's face. Anyone may use a gate:
	        it's a hole in space, not a door with a lock (owner default, docs/Space.md §5).
	SEALS   Status `space_sealed` (no moving, no casting, no damage taken) plus a box here; a flight from
	        outside that reaches the box stops at its wall. Ends with the status (Dispel ends it too).
	STRIDE  Status `space_stride` plus a walk multiplier; ends early the moment the strider hurts someone
	        (Damage.listenAttacked, in SpaceService).
	DISLOCATION  dislocate(model, studs, rng): thrown that far in a random direction, onto whatever is there;
	        sometimes dropped from above it (a roof, a ledge, shallow water). Never inside anything.

	Cues: "space" with `fx` = gate_open | gate_close | gate_pass | seal | seal_end | swap | cut | stride |
	dislocate (Fx/SpaceFx).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local S = require(Shared.Magic.Data.SpaceTuning)

local Cast = script.Parent
local Delivery = require(Cast.Delivery)
local StatusEffects = require(Cast.StatusEffects)

local SpaceRuntime = {}

type Gate = {
	id: number,
	owner: number,
	a: CFrame, -- facing out of the gate (its LookVector is the way you leave it)
	b: CFrame?, -- nil while the far end is still opening (its ground is being built: a long gate)
	farAt: Vector3, -- where the far end was asked for
	forward: Vector3,
	seconds: number,
	untilAt: number,
	giveUpAt: number, -- a far end that can't open by now closes the near one too
	lasting: boolean?, -- a Worldgate (stage 3): an hour, its own cap, one per caster
	parts: { Instance }?, -- a Worldgate's rings, real parts so anyone who comes by later sees them
}

type Seal = { id: number, humanoid: Humanoid, root: BasePart, center: Vector3, half: number }
type Stretch = { id: number, owner: number, ownerModel: Model?, center: Vector3, radius: number, untilAt: number, slowed: { [any]: boolean } }

-- Stretch zones (stage 2), declared here because the flight interceptor below reads them.
local stretches: { Stretch } = {}
local stretchIntercept: (Vector3, Vector3, any) -> Vector3?

local runner: any = nil
local log: any = nil
local nextId = 0

local gates: { Gate } = {}
local seals: { [Humanoid]: Seal } = {}
local strides: { [Humanoid]: boolean } = {}
local lastPass: { [Model]: number } = setmetatable({}, { __mode = "k" }) :: any
local flightPass: { [any]: number } = setmetatable({}, { __mode = "k" }) :: any

local function newId(): number
	nextId += 1
	return nextId
end

local function fx(name: string, payload: { [string]: any }, position: Vector3)
	if runner then
		payload.fx = name
		runner:cue("space", payload, position, false)
	end
end

-- A standing spot at (or just above) a point, or nil when there's no room: never inside a wall or the ground.
local CLEARANCE = Vector3.new(3, 5, 3)
function SpaceRuntime.standAt(point: Vector3, ignore: { Instance }, dropFrom: number?): CFrame?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	local from = dropFrom or 6
	local hit = workspace:Raycast(point + Vector3.new(0, from, 0), Vector3.new(0, -(from + 14), 0), params)
	if not hit then
		return nil
	end
	local stand = CFrame.new(hit.Position + Vector3.new(0, CLEARANCE.Y / 2 + 0.5, 0))
	local overlap = OverlapParams.new()
	overlap.FilterType = Enum.RaycastFilterType.Exclude
	overlap.FilterDescendantsInstances = ignore
	for _, part in workspace:GetPartBoundsInBox(stand, CLEARANCE, overlap) do
		if part.CanCollide then
			return nil
		end
	end
	return stand
end

local function flatLook(from: Vector3, toward: Vector3, fallback: Vector3): Vector3
	local d = Vector3.new(toward.X - from.X, 0, toward.Z - from.Z)
	if d.Magnitude < 0.1 then
		d = Vector3.new(fallback.X, 0, fallback.Z)
	end
	return if d.Magnitude > 0.01 then d.Unit else Vector3.new(0, 0, -1)
end

-- ─── Gates ─────────────────────────────────────────────────────────────────

-- A gate is drawn for anyone near EITHER end: the cue goes out at both (clients ignore a second copy).
local function gateFx(name: string, gate: Gate, payload: { [string]: any })
	payload.id = gate.id
	fx(name, table.clone(payload), gate.a.Position)
	local b = gate.b
	if b and (b.Position - gate.a.Position).Magnitude > 150 then
		fx(name, table.clone(payload), b.Position)
	end
end

-- A Worldgate's rings as real parts (anchored, no collision): the cue only reaches people near at the time.
local function worldgateRing(cf: CFrame): { Instance }
	local folder = workspace:FindFirstChild("SpaceGates")
	if not folder then
		folder = Instance.new("Folder")
		folder.Name = "SpaceGates"
		folder.Parent = workspace
	end
	local d = S.gate.radius * 2
	local face = cf * CFrame.new(0, 1, 0) * CFrame.Angles(0, math.pi / 2, 0)
	local out: { Instance } = {}
	-- { diameter, colour, material, transparency, thickness }
	local specs: { { any } } = { { d + 0.8, S.looks.rim, Enum.Material.Neon, 0.1, 0.2 }, { d, S.looks.deep, Enum.Material.Glass, 0.05, 0.3 } }
	for i, spec in specs do
		local p = Instance.new("Part")
		p.Name = if i == 1 then "WorldgateRim" else "WorldgateHole"
		p.Shape = Enum.PartType.Cylinder
		p.Size = Vector3.new(spec[5], spec[1], spec[1])
		p.CFrame = face
		p.Color = spec[2]
		p.Material = spec[3]
		p.Transparency = spec[4]
		p.Anchored = true
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.CastShadow = false
		p:SetAttribute("Flammability", 0)
		if i == 2 then
			local e = Instance.new("ParticleEmitter")
			e.Color = ColorSequence.new(S.looks.star)
			e.LightEmission = 1
			e.Size = NumberSequence.new(0.18, 0)
			e.Lifetime = NumberRange.new(0.6, 1.2)
			e.Speed = NumberRange.new(0.5, 2)
			e.SpreadAngle = Vector2.new(180, 180)
			e.Rate = 10
			e.Parent = p
			local light = Instance.new("PointLight")
			light.Color = S.looks.rim
			light.Range = 12
			light.Brightness = 1.2
			light.Parent = p
		end
		p.Parent = folder
		table.insert(out, p)
	end
	return out
end

local function closeGate(gate: Gate, why: string)
	local index = table.find(gates, gate)
	if index then
		table.remove(gates, index)
	end
	for _, inst in (gate.parts or {}) :: { Instance } do
		inst:Destroy()
	end
	gateFx("gate_close", gate, {})
	if log then
		log:info("space_gate_closed", { owner = gate.owner, why = why })
	end
end

function SpaceRuntime.canOpenGate(): boolean
	return #gates < S.gate.maxServer
end

-- Set by Services/SpaceService: the world's chunk building (a far end may be somewhere nobody is), each
-- player's map waypoint (MapWaypoint), and whether they've uncovered a spot on their map (MapService).
SpaceRuntime.world = nil :: any
local waypoints: { [Player]: Vector3? } = setmetatable({}, { __mode = "k" }) :: any
SpaceRuntime.seenHook = nil :: ((Player, number, number) -> boolean)?

-- Stage 2 hooks (SpaceService): your party mates (PartyService), and opening your pocket (ContainerService
-- with your saved data.spacePocket, its size set to `slots`).
SpaceRuntime.matesHook = nil :: ((Player) -> { Player })?
SpaceRuntime.pocketHook = nil :: ((Player, number, number) -> (boolean, string?))?
-- Mindlink (Services/MindlinkService): offers the caster the minds they can reach. (ok, note)
SpaceRuntime.mindlinkHook = nil :: ((Player, Model?) -> (boolean, string?))?

function SpaceRuntime.mindlink(player: Player, target: Model?): (boolean, string?)
	local hook = SpaceRuntime.mindlinkHook
	if not hook then
		return false, "No mind answers."
	end
	return hook(player, target)
end

function SpaceRuntime.matesOf(player: Player): { Player }
	local hook = SpaceRuntime.matesHook
	return if hook then hook(player) else {}
end

function SpaceRuntime.openPocket(player: Player, slots: number, seconds: number): (boolean, string?)
	local hook = SpaceRuntime.pocketHook
	if not hook then
		return false, "Your pocket won't open here."
	end
	return hook(player, slots, seconds)
end

function SpaceRuntime.setWaypoint(player: Player, point: Vector3?)
	waypoints[player] = point
end

function SpaceRuntime.waypointOf(player: Player): Vector3?
	return waypoints[player]
end

function SpaceRuntime.hasSeen(player: Player, x: number, z: number): boolean
	local hook = SpaceRuntime.seenHook
	return hook == nil or hook(player, x, z)
end

-- A standing spot near `point`: the point itself, else rings around it (a far end on a slope or in trees).
local function standNear(point: Vector3, ignore: { Instance }): CFrame?
	local spot = SpaceRuntime.standAt(point, ignore, 40)
	if spot then
		return spot
	end
	for ring = 1, 3 do
		for i = 0, 7 do
			local a = i / 8 * math.pi * 2
			spot = SpaceRuntime.standAt(point + Vector3.new(math.cos(a), 0, math.sin(a)) * ring * 6, ignore, 40)
			if spot then
				return spot
			end
		end
	end
	return nil
end

local function finishOpening(gate: Gate, farSpot: CFrame)
	local forward = gate.forward
	gate.b = CFrame.lookAt(farSpot.Position, farSpot.Position + forward) -- faces on, away from the caster
	gate.untilAt = os.clock() + gate.seconds
	local b = gate.b :: CFrame
	if gate.lasting then
		local parts = worldgateRing(gate.a)
		for _, inst in worldgateRing(b) do
			table.insert(parts, inst)
		end
		gate.parts = parts
	end
	gateFx(if gate.lasting then "gate_pass" else "gate_open", gate, { a = gate.a, b = b, seconds = gate.seconds, radius = S.gate.radius, caster = gate.owner })
	if log then
		log:info(if gate.lasting then "space_worldgate_opened" else "space_gate_opened", { owner = gate.owner, seconds = gate.seconds, studs = math.floor((b.Position - gate.a.Position).Magnitude) })
	end
end

--[[
	Opens a pair: `near` in front of the caster, `far` at `farAt` (the aim point, or a waypoint across the map).
	The near one faces back toward the caster (you walk into it and out of the far one, which faces away from
	you). A far end on ground nobody has built yet waits for it (requestArea), up to farWait seconds.
	Returns the gate, or nil and why.
]]
function SpaceRuntime.openGate(owner: number, origin: Vector3, look: Vector3, farAt: Vector3, seconds: number, ignore: { Instance }, lasting: boolean?): (Gate?, string?)
	if #gates >= S.gate.maxServer then
		return nil, "Space here is already full of holes."
	end
	if lasting then
		local worldgates = 0
		for _, g in gates do
			if g.lasting and g.owner ~= owner then
				worldgates += 1
			end
		end
		if worldgates >= S.worldgate.maxServer then
			return nil, "The world already has as many lasting gates as it will bear."
		end
	end
	local forward = flatLook(origin, farAt, look)
	local nearSpot = SpaceRuntime.standAt(origin + forward * S.gate.frontOffset, ignore)
	if not nearSpot then
		return nil, "There's no room for a gate here."
	end
	if Vector3.new(farAt.X - origin.X, 0, farAt.Z - origin.Z).Magnitude < 12 then
		return nil, "Too close: the two ends would touch."
	end
	-- A third pair of yours closes your oldest (Worldgates count separately: one each).
	local mine = {}
	for _, gate in gates do
		if gate.owner == owner and (gate.lasting == true) == (lasting == true) then
			table.insert(mine, gate)
		end
	end
	while #mine >= (if lasting then S.worldgate.perCaster else S.gate.perCaster) do
		closeGate(table.remove(mine, 1) :: Gate, "replaced")
	end
	local gate: Gate = {
		id = newId(),
		owner = owner,
		a = CFrame.lookAt(nearSpot.Position, nearSpot.Position - forward), -- faces the caster
		b = nil,
		farAt = farAt,
		forward = forward,
		seconds = seconds,
		untilAt = math.huge,
		giveUpAt = os.clock() + S.gate.farWait,
		lasting = lasting,
	}
	local world = SpaceRuntime.world
	local built = world == nil or world:isChunkBuilt(farAt.X, farAt.Z)
	if built then
		local farSpot = standNear(farAt - forward * 1.5, ignore)
		if not farSpot then
			return nil, "There's no room for a gate there."
		end
		table.insert(gates, gate)
		finishOpening(gate, farSpot)
	else
		world:requestArea(farAt.X, farAt.Z, 1)
		table.insert(gates, gate)
		fx("gate_forming", { id = gate.id, a = gate.a, radius = S.gate.radius }, gate.a.Position)
	end
	return gate, nil
end

-- Which end a point is at, and the CFrame it comes out of. nil when it's at neither (or still opening).
local function gateAt(position: Vector3, reach: number): (Gate?, CFrame?, CFrame?)
	for _, gate in gates do
		local b = gate.b
		if b then
			if (position - gate.a.Position).Magnitude <= reach then
				return gate, gate.a, b
			elseif (position - b.Position).Magnitude <= reach then
				return gate, b, gate.a
			end
		end
	end
	return nil, nil, nil
end

local function bodies(): { Model }
	local out: { Model } = {}
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(out, player.Character)
		end
	end
	for _, name in { "NPCs", "Creatures", "Wildborn" } do
		local folder = workspace:FindFirstChild(name)
		if folder then
			for _, child in folder:GetChildren() do
				if child:IsA("Model") then
					table.insert(out, child)
				end
			end
		end
	end
	return out
end

local function stepGates(now: number)
	for i = #gates, 1, -1 do
		local gate = gates[i]
		if gate.b == nil then
			-- A long gate's far end, waiting for its ground.
			local world = SpaceRuntime.world
			if world and world:isChunkBuilt(gate.farAt.X, gate.farAt.Z) then
				local farSpot = standNear(gate.farAt - gate.forward * 1.5, {})
				if farSpot then
					finishOpening(gate, farSpot)
				else
					closeGate(gate, "no room at the far end")
				end
			elseif now >= gate.giveUpAt then
				closeGate(gate, "far end never opened")
			end
		elseif now >= gate.untilAt then
			closeGate(gate, "faded")
		end
	end
	if #gates == 0 then
		return
	end
	for _, model in bodies() do
		local root = model:FindFirstChild("HumanoidRootPart")
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 and not root.Anchored then
			local gate, from, to = gateAt(root.Position, S.gate.radius)
			if gate and from and to and now >= (lastPass[model] or 0) then
				lastPass[model] = now + S.gate.bodyGap
				local out = to.Position + to.LookVector * S.gate.exitOffset
				model:PivotTo(CFrame.lookAt(out, out + to.LookVector))
				root.AssemblyLinearVelocity = to.LookVector * math.min(root.AssemblyLinearVelocity.Magnitude, 40)
				fx("gate_pass", { id = gate.id, from = from.Position, to = out }, out)
			end
		end
	end
end

-- Delivery.interceptor's say for gates and seals.
function SpaceRuntime.intercept(position: Vector3, velocity: Vector3, flight: any): (string?, any)
	local now = os.clock()
	if #gates > 0 and now >= (flightPass[flight] or 0) then
		local _gate, _from, to = gateAt(position, S.gate.radius + 0.6)
		if to then
			flightPass[flight] = now + S.gate.flightGap
			local speed = velocity.Magnitude
			local dir = to.LookVector
			return "warp", { position = to.Position + Vector3.new(0, 1.5, 0) + dir * 3, velocity = dir * speed }
		end
	end
	if #stretches > 0 then
		local slowed = stretchIntercept(position, velocity, flight)
		if slowed then
			return "bend", slowed
		end
	end
	for _, seal in seals do
		local d = position - seal.center
		local h = seal.half
		-- The sealed can't cast, so anything reaching the box came from outside: it stops at the wall.
		if math.abs(d.X) <= h and math.abs(d.Y) <= h + 1 and math.abs(d.Z) <= h then
			return "stop", nil
		end
	end
	return nil, nil
end

-- ─── Seals ─────────────────────────────────────────────────────────────────

function SpaceRuntime.seal(humanoid: Humanoid, root: BasePart, seconds: number, source: number?): boolean
	if seals[humanoid] then
		return false
	end
	if not StatusEffects.apply(humanoid, "space_sealed", { duration = seconds, source = source }) then
		return false
	end
	local seal: Seal = { id = newId(), humanoid = humanoid, root = root, center = root.Position, half = S.seal.radius }
	seals[humanoid] = seal
	fx("seal", { id = seal.id, center = seal.center, half = seal.half, seconds = seconds }, seal.center)
	return true
end

local function stepSeals()
	for humanoid, seal in seals do
		if humanoid.Parent == nil or not StatusEffects.has(humanoid, "space_sealed") then
			seals[humanoid] = nil
			fx("seal_end", { id = seal.id }, seal.center)
		end
	end
end

-- ─── Stride ────────────────────────────────────────────────────────────────

function SpaceRuntime.stride(humanoid: Humanoid, seconds: number, walk: number, source: number?)
	StatusEffects.apply(humanoid, "space_stride", { duration = seconds, source = source })
	StatusEffects.setWalkMultiplier(humanoid, "space_stride", walk)
	strides[humanoid] = true
end

function SpaceRuntime.endStride(humanoid: Humanoid)
	if strides[humanoid] then
		strides[humanoid] = nil
		StatusEffects.remove(humanoid, "space_stride")
		StatusEffects.setWalkMultiplier(humanoid, "space_stride", nil)
	end
end

local function stepStrides()
	for humanoid in strides do
		if humanoid.Parent == nil or not StatusEffects.has(humanoid, "space_stride") then
			strides[humanoid] = nil
			if humanoid.Parent then
				StatusEffects.setWalkMultiplier(humanoid, "space_stride", nil)
			end
		end
	end
end

function SpaceRuntime.isStriding(humanoid: Humanoid): boolean
	return strides[humanoid] == true
end

-- ─── Dislocation ───────────────────────────────────────────────────────────

-- Thrown `studs` in a random direction, onto whatever is there; sometimes dropped from above it. Tries a few
-- directions before giving up (then nothing happens: never inside anything).
function SpaceRuntime.dislocate(model: Model, studs: number, rng: Random): boolean
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") then
		return false
	end
	local from = root.Position
	local up = rng:NextNumber() < S.dislocation.upChance
	for _ = 1, 6 do
		local angle = rng:NextNumber() * math.pi * 2
		local target = from + Vector3.new(math.cos(angle), 0, math.sin(angle)) * studs
		local stand = SpaceRuntime.standAt(target, { model }, 30)
		if stand then
			local landing = if up then stand + Vector3.new(0, S.dislocation.dropFrom, 0) else stand
			model:PivotTo(landing * CFrame.Angles(0, rng:NextNumber() * math.pi * 2, 0))
			fx("dislocate", { from = from, to = landing.Position }, landing.Position)
			return true
		end
	end
	return false
end

-- ─── Anchor and Recall (stage 2) ───────────────────────────────────────────

local anchors: { [Player]: CFrame } = setmetatable({}, { __mode = "k" }) :: any
local recalling: { [Player]: boolean } = setmetatable({}, { __mode = "k" }) :: any

function SpaceRuntime.setAnchor(player: Player, at: CFrame)
	anchors[player] = at
	fx("anchor", { at = at.Position, caster = player.UserId }, at.Position)
end

function SpaceRuntime.anchorOf(player: Player): CFrame?
	return anchors[player]
end

--[[
	Takes `player` (and `mates`, already chosen by the caller) back to their anchor. A far anchor's ground may
	not be built: it's asked for, and the recall waits up to anchor.wait seconds (the caster is told). Returns
	false and why when it can't start.
]]
function SpaceRuntime.recall(player: Player, mates: { Player }): (boolean, string?)
	local anchor = anchors[player]
	if not anchor then
		return false, "You've left no anchor to return to. Bind space where you stand first."
	end
	if recalling[player] then
		return false, "You're already on your way back."
	end
	local function go()
		local everyone = { player }
		for _, mate in mates do
			table.insert(everyone, mate)
		end
		for i, who in everyone do
			local character = who.Character
			if character then
				local from = character:GetPivot().Position
				-- Mates arrive in a ring round the anchor, not inside each other.
				local offset = if i == 1 then Vector3.zero else Vector3.new(math.cos(i), 0, math.sin(i)) * 4
				local spot = SpaceRuntime.standAt(anchor.Position + offset, { character }, 20) or anchor
				character:PivotTo(CFrame.new(spot.Position) * anchor.Rotation)
				fx("dislocate", { from = from, to = spot.Position }, spot.Position)
			end
		end
	end
	local world = SpaceRuntime.world
	if world == nil or world:isChunkBuilt(anchor.Position.X, anchor.Position.Z) then
		go()
		return true, nil
	end
	recalling[player] = true
	world:requestArea(anchor.Position.X, anchor.Position.Z, 1)
	task.spawn(function()
		local giveUp = os.clock() + S.anchor.wait
		while os.clock() < giveUp and not world:isChunkBuilt(anchor.Position.X, anchor.Position.Z) do
			task.wait(0.25)
		end
		recalling[player] = nil
		if player.Parent and world:isChunkBuilt(anchor.Position.X, anchor.Position.Z) then
			go()
		end
	end)
	return true, nil
end

-- ─── Stretch (stage 2) ─────────────────────────────────────────────────────

function SpaceRuntime.canStretch(): boolean
	return #stretches < S.stretch.maxServer
end

function SpaceRuntime.stretch(owner: number, ownerModel: Model?, center: Vector3, radius: number, seconds: number): boolean
	if #stretches >= S.stretch.maxServer then
		return false
	end
	local mine = {}
	for _, s in stretches do
		if s.owner == owner then
			table.insert(mine, s)
		end
	end
	while #mine >= S.stretch.perCaster do
		local old = table.remove(mine, 1) :: Stretch
		table.remove(stretches, table.find(stretches, old) :: number)
		fx("stretch_end", { id = old.id }, old.center)
	end
	local s: Stretch = { id = newId(), owner = owner, ownerModel = ownerModel, center = center, radius = radius, untilAt = os.clock() + seconds, slowed = setmetatable({}, { __mode = "k" }) :: any }
	table.insert(stretches, s)
	fx("stretch", { id = s.id, center = center, radius = radius, seconds = seconds }, center)
	return true
end

local function stepStretches(now: number)
	for i = #stretches, 1, -1 do
		local s = stretches[i]
		if now >= s.untilAt then
			table.remove(stretches, i)
			fx("stretch_end", { id = s.id }, s.center)
		else
			for _, model in bodies() do
				if model ~= s.ownerModel then
					local root = model:FindFirstChild("HumanoidRootPart")
					local humanoid = model:FindFirstChildOfClass("Humanoid")
					if root and root:IsA("BasePart") and humanoid and humanoid.Health > 0 then
						local d = Vector3.new(root.Position.X - s.center.X, 0, root.Position.Z - s.center.Z).Magnitude
						if d <= s.radius then
							StatusEffects.apply(humanoid, "space_stretched", { duration = 0.5, source = s.owner })
						end
					end
				end
			end
		end
	end
end

-- A bolt from anyone but the stretch's maker slows as it crosses, once per stretch.
stretchIntercept = function(position: Vector3, velocity: Vector3, flight: any): Vector3?
	for _, s in stretches do
		if flight.ownerModel ~= s.ownerModel and not s.slowed[flight] then
			local d = Vector3.new(position.X - s.center.X, 0, position.Z - s.center.Z).Magnitude
			if d <= s.radius then
				s.slowed[flight] = true
				return velocity * S.stretch.boltMult
			end
		end
	end
	return nil
end

-- ─── Hideaway (stage 3) ────────────────────────────────────────────────────

type Hideaway = { player: Player, slot: number, returnTo: CFrame, untilAt: number, model: Model }

local hideaways: { [Player]: Hideaway } = {}
local hideSlots: { [number]: boolean } = {}

local function roomPart(model: Model, name: string, size: Vector3, cf: CFrame, color: Color3, material: Enum.Material, transparency: number)
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cf
	p.Color = color
	p.Material = material
	p.Transparency = transparency
	p.Anchored = true
	p.CanCollide = true
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p:SetAttribute("Flammability", 0)
	p:SetAttribute("Protected", true) -- Reality's Unmake and the like leave it alone
	p.Parent = model
	return p
end

-- A small sealed room: a dark floor, glassy walls full of stars, a light. Nothing in it but you.
local function buildRoom(slot: number): (Model, CFrame)
	local H = S.hideaway
	local center = H.origin + Vector3.new(0, 0, slot * H.spacing)
	local model = Instance.new("Model")
	model.Name = "SpaceHideaway"
	local size = H.size
	local floor = roomPart(model, "Floor", Vector3.new(size.X, 1, size.Z), CFrame.new(center), S.looks.deep, Enum.Material.Slate, 0)
	roomPart(model, "Ceiling", Vector3.new(size.X, 1, size.Z), CFrame.new(center + Vector3.new(0, size.Y, 0)), S.looks.deep, Enum.Material.Glass, 0.2)
	for _, side in { Vector3.new(1, 0, 0), Vector3.new(-1, 0, 0), Vector3.new(0, 0, 1), Vector3.new(0, 0, -1) } do
		local wallSize = if side.X ~= 0 then Vector3.new(1, size.Y, size.Z) else Vector3.new(size.X, size.Y, 1)
		local wall = roomPart(model, "Wall", wallSize, CFrame.new(center + Vector3.new(side.X * size.X / 2, size.Y / 2, side.Z * size.Z / 2)), S.looks.rim, Enum.Material.ForceField, 0.15)
		local e = Instance.new("ParticleEmitter")
		e.Color = ColorSequence.new(S.looks.star)
		e.LightEmission = 1
		e.Size = NumberSequence.new(0.15, 0)
		e.Lifetime = NumberRange.new(1, 2)
		e.Speed = NumberRange.new(0.2, 0.6)
		e.Rate = 6
		e.Parent = wall
	end
	local light = Instance.new("PointLight")
	light.Color = S.looks.star
	light.Range = 24
	light.Brightness = 1.5
	light.Parent = floor
	model.PrimaryPart = floor
	model.Parent = workspace
	return model, CFrame.new(center + Vector3.new(0, 3.5, 0))
end

local function leaveHideaway(player: Player, why: string)
	local h = hideaways[player]
	if not h then
		return
	end
	hideaways[player] = nil
	hideSlots[h.slot] = nil
	local character = player.Character
	if character and character.Parent then
		character:PivotTo(h.returnTo)
		fx("dislocate", { from = h.returnTo.Position, to = h.returnTo.Position }, h.returnTo.Position)
	end
	h.model:Destroy()
	if log then
		log:info("space_hideaway_left", { userId = player.UserId, why = why })
	end
end

function SpaceRuntime.inHideaway(player: Player): boolean
	return hideaways[player] ~= nil
end

-- Steps `player` out of the world into their own sealed room for `seconds`; cast again inside to come back.
function SpaceRuntime.enterHideaway(player: Player, seconds: number): (boolean, string?)
	if hideaways[player] then
		leaveHideaway(player, "cast again")
		return true, "You step back into the world where you left it."
	end
	local character = player.Character
	if not character then
		return false, nil
	end
	local slot = 0
	while hideSlots[slot] do
		slot += 1
	end
	hideSlots[slot] = true
	local model, inside = buildRoom(slot)
	local returnTo = character:GetPivot()
	hideaways[player] = { player = player, slot = slot, returnTo = returnTo, untilAt = os.clock() + seconds, model = model }
	fx("dislocate", { from = returnTo.Position, to = returnTo.Position }, returnTo.Position)
	character:PivotTo(inside * returnTo.Rotation)
	if log then
		log:info("space_hideaway_entered", { userId = player.UserId, seconds = seconds, slot = slot })
	end
	return true, string.format("You fold yourself out of the world. %d seconds, or cast it again to step back.", math.floor(seconds))
end

local function stepHideaways(now: number)
	for player, h in hideaways do
		if not player.Parent then
			hideaways[player] = nil
			hideSlots[h.slot] = nil
			h.model:Destroy()
		elseif now >= h.untilAt then
			leaveHideaway(player, "time")
		else
			-- Died or respawned inside: the room has nobody to hold.
			local character = player.Character
			local humanoid = character and character:FindFirstChildOfClass("Humanoid")
			if not humanoid or humanoid.Health <= 0 then
				hideaways[player] = nil
				hideSlots[h.slot] = nil
				h.model:Destroy()
			end
		end
	end
end

-- ─── NPC Space mages (stage 3) ─────────────────────────────────────────────

-- An NPC slips away from someone too close: `studs` back along `away`, onto a standing spot. Returns
-- whether it moved.
function SpaceRuntime.blinkAway(model: Model, away: Vector3, studs: number): boolean
	local root = model:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or root.Anchored then
		return false
	end
	local from = root.Position
	for _, turn in { 0, 0.6, -0.6, 1.2, -1.2 } do
		local dir = (CFrame.Angles(0, turn, 0) * away)
		local spot = SpaceRuntime.standAt(from + dir * studs, { model }, 12)
		if spot then
			model:PivotTo(CFrame.lookAt(spot.Position, spot.Position - dir))
			fx("dislocate", { from = from, to = spot.Position }, spot.Position)
			return true
		end
	end
	return false
end

-- ─── Dispel and admin ──────────────────────────────────────────────────────

-- Closes gates touching the area (a Dispel), or every gate of `owner`. Returns how many.
function SpaceRuntime.closeGates(position: Vector3?, radius: number?, owner: number?): number
	local n = 0
	for i = #gates, 1, -1 do
		local gate = gates[i]
		local b = gate.b
		local near = position ~= nil and ((gate.a.Position - position).Magnitude <= (radius or 0) or (b ~= nil and (b.Position - position).Magnitude <= (radius or 0)))
		if near or (owner ~= nil and gate.owner == owner) or (position == nil and owner == nil) then
			closeGate(gate, "dispelled")
			n += 1
		end
	end
	return n
end

function SpaceRuntime.report(): string
	local sealed, striding = 0, 0
	for _ in seals do
		sealed += 1
	end
	for _ in strides do
		striding += 1
	end
	local lines = { string.format("gates %d / %d, sealed %d, striding %d", #gates, S.gate.maxServer, sealed, striding) }
	for _, gate in gates do
		local b = gate.b
		if b then
			table.insert(lines, string.format("  gate %d by %d: %.0f studs, %.0f s left", gate.id, gate.owner, (b.Position - gate.a.Position).Magnitude, gate.untilAt - os.clock()))
		else
			table.insert(lines, string.format("  gate %d by %d: far end still opening at (%.0f, %.0f)", gate.id, gate.owner, gate.farAt.X, gate.farAt.Z))
		end
	end
	return table.concat(lines, "\n")
end

function SpaceRuntime.step(_dt: number)
	local now = os.clock()
	stepGates(now)
	stepStretches(now)
	stepHideaways(now)
	stepSeals()
	stepStrides()
end

function SpaceRuntime.start(effectRunner: any, logger: any)
	runner, log = effectRunner, logger
	local nextInterceptor = Delivery.interceptor
	Delivery.interceptor = function(position: Vector3, velocity: Vector3, flight: Delivery.Flight): (string?, any)
		local action, value = SpaceRuntime.intercept(position, velocity, flight)
		if action then
			return action, value
		end
		if nextInterceptor then
			return nextInterceptor(position, velocity, flight)
		end
		return nil, nil
	end
end

return SpaceRuntime
