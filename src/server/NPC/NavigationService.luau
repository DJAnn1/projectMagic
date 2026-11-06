--!strict
--[[
	NavigationService: the one owner of NPC movement on T0 rigs (docs/NPCMovement.md). Everything else
	asks here: nothing else calls MoveTo or Move, or writes WalkSpeed or Jump on an NPC.
	Still outside it until the LOD stage: NPCLOD's T1 hops and spawn placement.

		Navigation.MoveTo(npc, position, options?)   options: { style? = "walk" | "stroll" | "hurry" | "sneak" | "limp" }
		Navigation.Stop(npc)
		Navigation.Pause(npc, reason) / Resume(npc, reason) / IsPaused(npc)
		Navigation.IsMoving(npc)
		Navigation.Arrived(npc, goal) / Failed(npc, reason, goal) / Blocked(npc, index) / Stuck(npc, level)   signals
	For fights, which steer directly at a moving target and don't path:
		Navigation.Steer(npc, point) / Halt(npc) / SetSpeed(npc, speed) / FaceNow(npc, direction) / Jump(npc)
	Plumbing:
		Navigation.Step(npc, clock)                  10 Hz, T0 only (NPCService)
		Navigation.Face(npc, position?)              smooth turn while standing; nil lets go
		Navigation.Forget(npc)                       the rig left T0
		Navigation.Invalidate(position, radius)      terrain or buildings changed here
		Navigation.RecentlyFailed(npc, position)     don't send them straight back
		Navigation.Report(npc) / Debug(npc) / Stats()

	HOW A MOVE GOES
		1  Close and clear (a sweep finds nothing solid): walk straight there, no path needed.
		2  A cached route whose start is near this NPC and in clear view of it.
		3  Otherwise queue a path, PATHS_PER_SECOND server-wide. THE NPC WAITS: it never walks straight
		   at a target it has no route to, which is how they ended up pressed against walls.
		4  Validate: a path must exist, not be absurdly long, and not pass a locked door this NPC can't
		   open. If not, try spots around the goal (ring search). Out of tries: Failed, so the brain
		   picks something else.

	STUCK (no real movement over STUCK_WINDOW, or past a waypoint's own deadline)
		1 jump · 2 re-path · 3 try a spot near the goal · 4 only out of every player's sight, move to the
		last known good ground and log why. In sight: Failed instead. Never a teleport in view.

	DOORS  Doors.register puts a PassThrough PathfindingModifier on every leaf, so routes may cross a
	closed door. A walker opens a door just ahead of it, through the same Doors.open players use, if
	it's unlocked or the NPC holds the key (it lives or works there). Locked to this NPC: an obstacle.
]]

local Players = game:GetService("Players")
local PathfindingService = game:GetService("PathfindingService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Signal = require(Shared.Core.Signal)

local Doors = require(script.Parent.Parent.Interact.Doors)
local WorldClock = require(script.Parent.WorldClock)

local Navigation = {}

Navigation.Arrived = Signal.new()
Navigation.Failed = Signal.new()
Navigation.Blocked = Signal.new()
Navigation.Stuck = Signal.new()
Navigation.DoorOpened = Signal.new()

-- ─── Tuning ─────────────────────────────────────────────────────────────────

local T = table.freeze({
	pathsPerSecond = 6,
	queueMax = 80,
	cacheMax = 300,
	cacheSeconds = 180,
	cacheCell = 4, -- start and goal cells of a cached route
	cacheStartReach = 7, -- a route is only reused if its start is this close, and in clear view
	direct = 24, -- a clear straight walk up to this far needs no path
	directMaxRise = 4,
	waypointSpacing = 4,
	smoothReach = 8, -- how many points ahead a smoothed route may skip
	smoothChecks = 40, -- straight-line checks per route
	goodSpacing = 8, -- remembered safe spots are at least this far apart
	reachWaypoint = 2.4,
	reachGoal = 1.8,
	maxPathRatio = 4, -- a path over 4 x the straight distance + maxPathExtra is rejected
	maxPathExtra = 80,
	maxAttempts = 6, -- the goal, then spots around it
	repathGap = 1.5,
	stuckWindow = 1.5,
	stuckMoved = 0.75, -- less than this in a window is no progress
	waypointGrace = 3, -- each waypoint's deadline: distance / speed x 2.5 + this
	reissue = 1, -- MoveTo again this often: Humanoid gives up on one after 8 s
	doorLook = 7,
	doorSegment = 3.2,
	doorEvery = 0.3,
	slowNear = 4, -- ease off this close to the goal
	slowShare = 0.6,
	failCooldown = 60, -- real seconds before an NPC is sent back to a place it couldn't reach
	failReach = 6,
	seenClose = 30, -- a player this close always counts as seeing
	seenFar = 220, -- beyond this nobody counts as seeing
	voidMargin = 14, -- this far below the generated surface: fallen through
	goodEvery = 1,
	history = 12,
	faceRate = 7, -- how quickly they turn, radians per second
	agentClearance = 0.25,
	agentMaxRadius = 1.5, -- doorways are 4 studs (3.5 inside): a wider agent could never fit
})

-- Studs per second. Each person varies by up to ±varySpeed around them, from their seed.
local STYLES: { [string]: number } = { stroll = 7, walk = 10, hurry = 14, sneak = 6, limp = 5 }
local VARY_SPEED = 0.1

Navigation.STYLES = STYLES
Navigation.T = T

export type Agent = { radius: number, height: number, key: string, params: { [string]: any } }

type Waypoint = { p: Vector3, jump: boolean }

type Route = {
	key: string,
	waypoints: { Waypoint },
	length: number,
	at: number,
	path: Path?,
	connection: RBXScriptConnection?,
	dead: boolean,
}

type Nav = {
	npc: any,
	goal: Vector3?, -- the requested place
	target: Vector3?, -- what we're really routing to (a ring spot if the goal itself failed)
	status: string, -- idle | queued | walking | arrived | failed
	style: string,
	waypoints: { Waypoint }?,
	route: Route?,
	index: number,
	attempt: number,
	request: number, -- only the newest path request may land
	pauses: { [string]: boolean },
	halted: boolean,
	issued: Vector3?,
	nextIssue: number,
	deadline: number,
	sampleAt: number,
	samplePos: Vector3,
	level: number,
	nextRepath: number,
	nextDoor: number,
	nextGoalCheck: number,
	nextGood: number,
	jumpedAt: number?,
	face: Vector3?,
	history: { string },
	lastStuck: string?,
}

local deps: any = {}
local navs: { [any]: Nav } = {}
local cache: { [string]: Route } = {}
local cacheCount = 0
local queue: { any } = {}
local nextRequest = 0
local stats = { computed = 0, failed = 0, cacheHits = 0, direct = 0, blocked = 0, stuck = 0, recovered = 0, doors = 0, failures = 0, msTotal = 0 }

-- ─── Pure rules (Tests/NpcMovement.spec) ────────────────────────────────────

-- From a body's real size: wide enough for its shoulders, but always able to fit a doorway.
function Navigation.agentRadius(bodyWidth: number): number
	local r = bodyWidth / 2 + T.agentClearance
	return math.min(T.agentMaxRadius, math.ceil(r * 4) / 4)
end

function Navigation.pathAcceptable(length: number, straight: number): boolean
	return length <= straight * T.maxPathRatio + T.maxPathExtra
end

-- What a stuck NPC tries next. 1 jump, 2 re-path, 3 a spot near the goal, 4 last resort.
function Navigation.escalation(level: number): string
	return if level <= 1 then "jump" elseif level == 2 then "repath" elseif level == 3 then "alternate" else "lastResort"
end

-- Spots to try around a goal: the goal, then closer rings before further ones.
function Navigation.ringOffset(attempt: number): Vector3
	if attempt <= 1 then
		return Vector3.zero
	end
	local reach = if attempt <= 4 then 3.5 else 7
	local angle = (attempt - 2) * 2.1
	return Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)
end

function Navigation.speedFor(style: string, seed: number): number
	local base = STYLES[style] or STYLES.walk
	return base * (1 - VARY_SPEED + 2 * VARY_SPEED * ((seed % 100) / 100))
end

-- How this person walks right now, unless the caller says otherwise.
function Navigation.styleOf(npc: any): string
	local now = WorldClock.now()
	if (npc.threatUntil or -1) > now then
		return "hurry"
	elseif npc.magic and (npc.magic.injuredUntil or -1) > now then
		return "limp"
	elseif npc.ageBand == "child" then
		return "hurry"
	elseif npc.occupation == "retired" then
		return "stroll"
	end
	return "walk"
end

-- ─── Small helpers ──────────────────────────────────────────────────────────

local function note(nav: Nav, text: string)
	table.insert(nav.history, string.format("%.0fs %s", os.clock(), text))
	while #nav.history > T.history do
		table.remove(nav.history, 1)
	end
end

local function navOf(npc: any): Nav
	local nav = navs[npc]
	if not nav then
		local clock = os.clock()
		local position: Vector3 = npc.position
		nav = {
			npc = npc,
			goal = nil,
			target = nil,
			status = "idle",
			style = "walk",
			waypoints = nil,
			route = nil,
			index = 1,
			attempt = 1,
			request = 0,
			pauses = {},
			halted = false,
			issued = nil,
			nextIssue = 0,
			deadline = math.huge,
			sampleAt = clock,
			samplePos = position,
			level = 0,
			nextRepath = 0,
			nextDoor = 0,
			nextGoalCheck = 0,
			nextGood = 0,
			jumpedAt = nil,
			face = nil,
			history = {},
			lastStuck = nil,
		}
		navs[npc] = nav
	end
	return nav
end

local function flatDistance(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function solidParams(ignore: { Instance }): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = ignore
	params.RespectCanCollide = true
	params.IgnoreWater = false
	return params
end

local function npcFolder(): { Instance }
	local folder = workspace:FindFirstChild("NPCs")
	return if folder then { folder } else {}
end

-- Nothing solid on a straight, level-ish walk between two ground points. `radius`: how wide a body
-- has to fit (default a narrow one, for a short direct walk).
local function clearWalk(from: Vector3, to: Vector3, radius: number?): boolean
	if math.abs(to.Y - from.Y) > T.directMaxRise then
		return false
	end
	-- `from` is a root part, about 3 above the ground. Knee height catches fences and walls too low
	-- for a chest-height sweep; sloping ground also hits it, and that just means "use a path".
	local params = solidParams(npcFolder())
	for _, height in { -1.5, 0.8 } do
		local start = from + Vector3.new(0, height, 0)
		local finish = Vector3.new(to.X, start.Y, to.Z)
		if (finish - start).Magnitude >= 0.5 and workspace:Spherecast(start, radius or 0.9, finish - start, params) then
			return false
		end
	end
	return true
end

local function currentSpeed(nav: Nav): number
	return Navigation.speedFor(nav.style, nav.npc.seed or 0)
end

-- WalkSpeed belongs to StatusEffects while a slow or haste is active: then we set its base instead.
local function applySpeed(humanoid: Humanoid, speed: number)
	if humanoid:GetAttribute("MagicBaseWalk") ~= nil then
		humanoid:SetAttribute("MagicBaseWalk", speed)
	elseif math.abs(humanoid.WalkSpeed - speed) > 0.05 then
		humanoid.WalkSpeed = speed
	end
end

-- ─── Agents: measured from the real body ────────────────────────────────────

local function measure(rig: any): Agent
	local model: Model = rig.model
	local root: BasePart = rig.root
	local head = model:FindFirstChild("Head")
	local leg = model:FindFirstChild("Left Leg") or model:FindFirstChild("LeftFoot")
	local torso = model:FindFirstChild("Torso") or model:FindFirstChild("UpperTorso") or root
	local height = 5
	if head and leg and head:IsA("BasePart") and leg:IsA("BasePart") then
		height = (head.Position.Y + head.Size.Y / 2) - (leg.Position.Y - leg.Size.Y / 2)
	end
	height = math.ceil(height * 2) / 2
	local width = if torso:IsA("BasePart") then math.max(torso.Size.X, root.Size.X) else root.Size.X
	local radius = Navigation.agentRadius(width)
	return {
		radius = radius,
		height = height,
		key = radius .. "x" .. height,
		params = {
			AgentRadius = radius,
			AgentHeight = height,
			AgentCanJump = true,
			AgentCanClimb = false,
			WaypointSpacing = T.waypointSpacing,
			Costs = { Water = 20, CrackedLava = math.huge, NpcDoor = 2 },
		},
	}
end

local function agentOf(rig: any): Agent
	if not rig.agent then
		rig.agent = measure(rig)
	end
	return rig.agent
end

-- ─── The route cache ────────────────────────────────────────────────────────

local function cellOf(v: Vector3): string
	return math.floor(v.X / T.cacheCell) .. "," .. math.floor(v.Z / T.cacheCell)
end

local function routeKey(agent: Agent, from: Vector3, to: Vector3): string
	return agent.key .. "|" .. cellOf(from) .. ">" .. cellOf(to)
end

local function killRoute(route: Route)
	route.dead = true
	if route.connection then
		route.connection:Disconnect()
		route.connection = nil
	end
	if route.path then
		route.path:Destroy()
		route.path = nil
	end
	if cache[route.key] == route then
		cache[route.key] = nil
		cacheCount -= 1
	end
end

local function storeRoute(route: Route)
	if cacheCount >= T.cacheMax then
		-- Full: drop everything past its time, or if nothing is, the lot.
		local now = os.clock()
		local dropped = false
		for _, other in table.clone(cache) do
			if now - other.at > T.cacheSeconds then
				killRoute(other)
				dropped = true
			end
		end
		if not dropped then
			for _, other in table.clone(cache) do
				killRoute(other)
			end
		end
	end
	local previous = cache[route.key]
	if previous then
		killRoute(previous)
	end
	cache[route.key] = route
	cacheCount += 1
end

-- ─── Starting and ending a walk ─────────────────────────────────────────────

local request: (nav: Nav) -> ()

local function haltRig(nav: Nav)
	local rig = nav.npc.rig
	if rig and not nav.halted then
		nav.halted = true
		nav.issued = nil
		-- Walk on to where you already are: the Humanoid's own move ends, and it stops cleanly.
		rig.humanoid:MoveTo(rig.root.Position)
		rig.humanoid:Move(Vector3.zero)
	end
end

local function fail(nav: Nav, reason: string)
	local goal = nav.goal
	nav.status = "failed"
	nav.waypoints, nav.route = nil, nil
	stats.failures += 1
	note(nav, "FAILED " .. reason)
	haltRig(nav)
	local npc = nav.npc
	if goal then
		npc.navFails = npc.navFails or {}
		table.insert(npc.navFails, { p = goal, untilAt = os.clock() + T.failCooldown })
	end
	Navigation.Failed:Fire(npc, reason, goal)
end

local function startWalking(nav: Nav, waypoints: { Waypoint }, route: Route?)
	nav.waypoints, nav.route = waypoints, route
	nav.index = 1
	nav.jumpedAt = nil
	nav.status = "walking"
	nav.halted = false
	nav.issued = nil
	nav.nextIssue = 0
	nav.deadline = math.huge
	local clock = os.clock()
	nav.sampleAt, nav.samplePos = clock, nav.npc.position
end

local function targetFor(nav: Nav): Vector3
	local spot = (nav.goal :: Vector3) + Navigation.ringOffset(nav.attempt)
	-- Stand it on whatever is really there: terrain, a floor, a road. Generated heights can be studs
	-- off a levelled town, and that fails as "finish not empty". Starts low enough to stay under a
	-- roof when the goal is indoors.
	local hit = workspace:Raycast(spot + Vector3.new(0, 3, 0), Vector3.new(0, -16, 0), solidParams(npcFolder()))
	return if hit then hit.Position + Vector3.new(0, 3, 0) else spot
end

-- A closed door on this route that this NPC has no way through.
local function canOpen(npc: any, leaf: BasePart): boolean
	if leaf:GetAttribute("Locked") ~= true then
		return true
	end
	local keyId = leaf:GetAttribute("KeyId")
	return (npc.home and npc.home.lot == keyId) or (npc.work and npc.work.lot == keyId) or false
end

local function crossesLockedDoor(npc: any, waypoints: { Waypoint }): boolean
	for _, wp in waypoints do
		for _, leaf in Doors.near(wp.p, 3) do
			if not Doors.isOpen(leaf) and not canOpen(npc, leaf) then
				return true
			end
		end
	end
	return false
end

--[[
	A path comes back as a point every few studs, zig-zagging on the coarse navmesh. Followed literally
	the NPC keeps correcting its heading, which reads as a wobble. So: from each point, jump to the
	furthest one ahead with a clear straight walk. Jump points are always kept. Bounded, and it only
	runs once per computed route, since routes are cached.
]]
local function smoothed(waypoints: { Waypoint }, radius: number): { Waypoint }
	if #waypoints <= 2 then
		return waypoints
	end
	local out: { Waypoint } = { waypoints[1] }
	local i = 1
	local checks = 0
	while i < #waypoints do
		local furthest = i + 1
		local last = math.min(#waypoints, i + T.smoothReach)
		-- Never past a jump: it has to happen where the path says.
		for k = i + 1, last do
			if waypoints[k].jump then
				last = k
				break
			end
		end
		for j = last, i + 2, -1 do
			if checks >= T.smoothChecks then
				break
			end
			checks += 1
			if clearWalk(waypoints[i].p + Vector3.new(0, 3, 0), waypoints[j].p, radius) then
				furthest = j
				break
			end
		end
		table.insert(out, waypoints[furthest])
		i = furthest
	end
	return out
end

local function nextAttempt(nav: Nav, why: string)
	note(nav, why)
	nav.attempt += 1
	if nav.attempt > T.maxAttempts then
		fail(nav, why)
		return
	end
	request(nav)
end

request = function(nav: Nav)
	local npc = nav.npc
	local rig = npc.rig
	if not rig or not nav.goal then
		return
	end
	local from: Vector3 = rig.root.Position
	local target = targetFor(nav)
	nav.target = target
	nextRequest += 1
	nav.request = nextRequest
	nav.nextRepath = os.clock() + T.repathGap

	-- 1. Close and clear.
	if flatDistance(from, target) <= T.direct and clearWalk(from, target) then
		stats.direct += 1
		startWalking(nav, { { p = target, jump = false } }, nil)
		return
	end

	-- 2. A cached route that really starts from here.
	local agent = agentOf(rig)
	local cached = cache[routeKey(agent, from, target)]
	if cached and not cached.dead and os.clock() - cached.at < T.cacheSeconds then
		local first = cached.waypoints[1]
		if first and (first.p - from).Magnitude <= T.cacheStartReach and clearWalk(from, first.p) and not crossesLockedDoor(npc, cached.waypoints) then
			stats.cacheHits += 1
			startWalking(nav, cached.waypoints, cached)
			return
		end
	end

	-- 3. Queue it, and wait. Standing still beats walking into a wall.
	nav.status = "queued"
	haltRig(nav)
	if #queue >= T.queueMax then
		table.remove(queue, 1)
	end
	table.insert(queue, { nav = nav, id = nextRequest, from = from, target = target, agent = agent })
end

local function compute(job: any)
	local nav: Nav = job.nav
	if nav.request ~= job.id or navs[nav.npc] ~= nav then
		return -- superseded while it waited
	end
	local started = os.clock()
	local path = PathfindingService:CreatePath(job.agent.params)
	local ok = pcall(function()
		path:ComputeAsync(job.from, job.target)
	end)
	stats.msTotal += (os.clock() - started) * 1000
	if nav.request ~= job.id or navs[nav.npc] ~= nav then
		path:Destroy()
		return
	end
	if not ok or path.Status ~= Enum.PathStatus.Success then
		stats.failed += 1
		local status = if ok then path.Status.Name else "error"
		path:Destroy()
		nextAttempt(nav, "no path: " .. status)
		return
	end
	stats.computed += 1
	local waypoints: { Waypoint } = {}
	local length = 0
	local last: Vector3 = job.from
	for _, wp in path:GetWaypoints() do
		table.insert(waypoints, { p = wp.Position, jump = wp.Action == Enum.PathWaypointAction.Jump })
		length += (wp.Position - last).Magnitude
		last = wp.Position
	end
	if #waypoints == 0 or not Navigation.pathAcceptable(length, (job.target - job.from).Magnitude) then
		path:Destroy()
		nextAttempt(nav, string.format("path rejected: %.0f studs", length))
		return
	end
	if crossesLockedDoor(nav.npc, waypoints) then
		path:Destroy()
		nextAttempt(nav, "path crosses a locked door")
		return
	end
	waypoints = smoothed(waypoints, job.agent.radius)
	local route: Route = { key = routeKey(job.agent, job.from, job.target), waypoints = waypoints, length = length, at = os.clock(), path = path, connection = nil, dead = false }
	route.connection = path.Blocked:Connect(function(index: number)
		stats.blocked += 1
		killRoute(route)
		for _, other in navs do
			if other.route == route and other.status == "walking" and index >= other.index then
				note(other, "path blocked at waypoint " .. index)
				Navigation.Blocked:Fire(other.npc, index)
				other.nextRepath = 0
				request(other)
			end
		end
	end)
	storeRoute(route)
	note(nav, string.format("path %d waypoints, %.0f studs", #waypoints, length))
	startWalking(nav, waypoints, route)
end

-- The one worker: ComputeAsync yields, so paths never hold up a frame.
function Navigation.start()
	task.spawn(function()
		while true do
			task.wait(1 / T.pathsPerSecond)
			local job = table.remove(queue, 1)
			if job then
				local ok, err = pcall(compute, job)
				if not ok and deps.log then
					deps.log:error("nav_compute_failed", { err = err })
				end
			end
		end
	end)
end

function Navigation.init(dependencies: { [string]: any })
	deps = dependencies
end

-- ─── The public moves ───────────────────────────────────────────────────────

function Navigation.MoveTo(npc: any, position: Vector3, options: { style: string? }?)
	npc.destination = position
	local rig = npc.rig
	if not rig or npc.tier ~= 0 then
		return -- no body to walk: NPCLOD handles the far tiers until the LOD stage
	end
	local nav = navOf(npc)
	nav.goal = position
	nav.style = if options and options.style then options.style else Navigation.styleOf(npc)
	nav.attempt = 1
	nav.level = 0
	if next(nav.pauses) == nil then
		request(nav)
	else
		nav.status = "idle" -- picked up on Resume
	end
end

function Navigation.Stop(npc: any)
	local nav = navOf(npc)
	nav.request = -1
	nav.goal, nav.target, nav.waypoints, nav.route = nil, nil, nil, nil
	nav.status = "idle"
	npc.destination = npc.position
	haltRig(nav)
end

function Navigation.Pause(npc: any, reason: string)
	local nav = navOf(npc)
	nav.pauses[reason] = true
	nav.request = -1 -- a path landing now would start them walking again
	nav.waypoints, nav.route = nil, nil
	nav.status = "idle"
	haltRig(nav)
	note(nav, "paused: " .. reason)
end

function Navigation.Resume(npc: any, reason: string)
	local nav = navs[npc]
	if not nav then
		return
	end
	nav.pauses[reason] = nil
	note(nav, "resumed: " .. reason)
	if next(nav.pauses) == nil then
		nav.nextGoalCheck = 0
		nav.goal = nil -- Step takes up npc.destination afresh from wherever they now stand
	end
end

function Navigation.IsPaused(npc: any): boolean
	local nav = navs[npc]
	return nav ~= nil and next(nav.pauses) ~= nil
end

function Navigation.IsMoving(npc: any): boolean
	local nav = navs[npc]
	return nav ~= nil and nav.status == "walking"
end

function Navigation.Face(npc: any, position: Vector3?)
	local nav = navOf(npc)
	nav.face = position
	local rig = npc.rig
	if rig then
		rig.humanoid.AutoRotate = position == nil
	end
end

function Navigation.Forget(npc: any)
	local nav = navs[npc]
	if nav then
		nav.request = -1
		navs[npc] = nil
	end
	local rig = npc.rig
	if rig then
		rig.humanoid.AutoRotate = true
	end
end

function Navigation.RecentlyFailed(npc: any, position: Vector3): boolean
	local fails = npc.navFails
	if not fails then
		return false
	end
	local now = os.clock()
	for i = #fails, 1, -1 do
		local f = fails[i]
		if f.untilAt <= now then
			table.remove(fails, i)
		elseif (f.p - position).Magnitude <= T.failReach then
			return true
		end
	end
	return false
end

function Navigation.Invalidate(position: Vector3, radius: number)
	for _, route in table.clone(cache) do
		for _, wp in route.waypoints do
			if (wp.p - position).Magnitude <= radius + 8 then
				killRoute(route)
				break
			end
		end
	end
	for _, nav in navs do
		if nav.status == "walking" and nav.route and nav.route.dead then
			note(nav, "route invalidated")
			request(nav)
		end
	end
end

-- ─── Direct control, for fights ─────────────────────────────────────────────

function Navigation.Steer(npc: any, point: Vector3)
	local rig = npc.rig
	if rig then
		local nav = navOf(npc)
		nav.status, nav.waypoints, nav.route, nav.request = "idle", nil, nil, -1
		nav.goal = nil -- after the fight, Step takes up npc.destination from wherever they end up
		nav.halted = false
		rig.humanoid:MoveTo(point)
	end
end

-- Stands still for now, without giving up the walk: being knocked down isn't being stuck.
function Navigation.Halt(npc: any)
	local rig = npc.rig
	if rig then
		local nav = navOf(npc)
		nav.halted = true
		nav.issued = nil
		nav.sampleAt, nav.samplePos = os.clock(), rig.root.Position
		nav.deadline = math.huge
		rig.humanoid:Move(Vector3.zero)
		rig.humanoid:MoveTo(rig.root.Position)
	end
end

function Navigation.SetSpeed(npc: any, speed: number)
	local rig = npc.rig
	if rig then
		applySpeed(rig.humanoid, speed)
	end
end

function Navigation.FaceNow(npc: any, direction: Vector3)
	local rig = npc.rig
	if rig and not rig.root.Anchored and direction.Magnitude > 0.01 then
		rig.root.CFrame = CFrame.lookAt(rig.root.Position, rig.root.Position + direction)
	end
end

function Navigation.Jump(npc: any)
	local rig = npc.rig
	if rig then
		rig.humanoid.Jump = true
	end
end

-- ─── Being seen, and the last resort ────────────────────────────────────────

local function anyoneSees(position: Vector3): boolean
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local head = character and character:FindFirstChild("Head")
		if head and head:IsA("BasePart") then
			local d = (head.Position - position).Magnitude
			if d <= T.seenClose then
				return true
			end
			if d <= T.seenFar then
				local params = solidParams({ character, table.unpack(npcFolder()) })
				local eye = position + Vector3.new(0, 2, 0)
				if not workspace:Raycast(head.Position, eye - head.Position, params) then
					return true
				end
			end
		end
	end
	return false
end

-- The solid, dry ground under a remembered root position: nil if there isn't any. Starts just above
-- it, so an NPC who was indoors can't end up on the roof.
local function verifiedGround(position: Vector3): Vector3?
	local hit = workspace:Raycast(position + Vector3.new(0, 1, 0), Vector3.new(0, -12, 0), solidParams(npcFolder()))
	if not hit or hit.Material == Enum.Material.Water or hit.Material == Enum.Material.CrackedLava then
		return nil
	end
	return hit.Position
end

local function recover(nav: Nav, reason: string): boolean
	local npc = nav.npc
	local rig = npc.rig
	if not rig then
		return false
	end
	local from: Vector3 = rig.root.Position
	if anyoneSees(from) then
		return false
	end
	-- The older remembered spot first: the newer one is often right where they're stuck. A spot this
	-- close wouldn't change anything, so it doesn't count as a recovery.
	local ground: Vector3? = nil
	for _, spot in { npc.olderGoodPosition, npc.lastGoodPosition } :: { Vector3? } do
		local candidate = spot and verifiedGround(spot)
		if candidate and (candidate - from).Magnitude >= T.goodSpacing / 2 and not anyoneSees(candidate) then
			ground = candidate
			break
		end
	end
	if not ground then
		return false
	end
	rig.model:PivotTo(CFrame.new(ground + Vector3.new(0, agentOf(rig).height / 2 + 0.5, 0)))
	npc.position = ground
	stats.recovered += 1
	nav.halted = false
	nav.samplePos, nav.sampleAt = ground, os.clock()
	note(nav, "RECOVERED: " .. reason)
	if deps.log then
		deps.log:info("npc_recovered", {
			npc = npc.id,
			reason = reason,
			fromX = math.floor(from.X),
			fromY = math.floor(from.Y),
			fromZ = math.floor(from.Z),
			toX = math.floor(ground.X),
			toY = math.floor(ground.Y),
			toZ = math.floor(ground.Z),
		})
	end
	return true
end

-- ─── Stepping ───────────────────────────────────────────────────────────────

local function escalate(nav: Nav, why: string)
	nav.level += 1
	stats.stuck += 1
	local action = Navigation.escalation(nav.level)
	nav.lastStuck = string.format("level %d (%s): %s", nav.level, action, why)
	note(nav, "STUCK " .. (nav.lastStuck :: string))
	Navigation.Stuck:Fire(nav.npc, nav.level)
	if action == "jump" then
		Navigation.Jump(nav.npc)
	elseif action == "repath" then
		if nav.route then
			killRoute(nav.route)
		end
		request(nav)
	elseif action == "alternate" then
		if nav.route then
			killRoute(nav.route)
		end
		nav.attempt = math.max(nav.attempt, 1) + 1
		request(nav)
	else
		if recover(nav, why) then
			nav.level = 0
			nav.attempt = 1
			request(nav)
		else
			fail(nav, "stuck: " .. why)
		end
	end
end

local function openDoorsAhead(nav: Nav, position: Vector3, target: Vector3, clock: number)
	if clock < nav.nextDoor then
		return
	end
	nav.nextDoor = clock + T.doorEvery
	local toTarget = target - position
	for _, leaf in Doors.near(position, T.doorLook) do
		if not Doors.isOpen(leaf) then
			local closed = leaf:GetAttribute("ClosedCFrame")
			if typeof(closed) == "CFrame" then
				-- Only a door they're heading through, not every door they pass in the street.
				local along = closed.Position - position
				local t = if toTarget.Magnitude > 0.1 then math.clamp(along:Dot(toTarget.Unit), 0, T.doorLook) else 0
				local nearest = position + (if toTarget.Magnitude > 0.1 then toTarget.Unit * t else Vector3.zero)
				if flatDistance(nearest, closed.Position) <= T.doorSegment then
					if canOpen(nav.npc, leaf) then
						if Doors.open(leaf) then
							stats.doors += 1
							note(nav, "opened a door")
							Navigation.DoorOpened:Fire(nav.npc, leaf)
						end
					else
						note(nav, "door locked to them")
						nav.level = 1 -- the next stuck check goes straight to a re-path
					end
				end
			end
		end
	end
end

local function stepFacing(nav: Nav, root: BasePart, dt: number)
	local face = nav.face
	if not face or root.Anchored or nav.status == "walking" then
		return
	end
	local flat = Vector3.new(face.X - root.Position.X, 0, face.Z - root.Position.Z)
	if flat.Magnitude < 0.5 then
		return
	end
	local current = root.CFrame.LookVector
	local currentFlat = Vector3.new(current.X, 0, current.Z)
	if currentFlat.Magnitude < 0.01 then
		return
	end
	local angle = math.acos(math.clamp(currentFlat.Unit:Dot(flat.Unit), -1, 1))
	if angle < 0.03 then
		return
	end
	local share = math.min(1, T.faceRate * dt / angle)
	root.CFrame = root.CFrame:Lerp(CFrame.lookAt(root.Position, root.Position + flat), share)
end

local function safetyCheck(nav: Nav, root: BasePart, humanoid: Humanoid, clock: number)
	if clock < nav.nextGood then
		return
	end
	nav.nextGood = clock + T.goodEvery
	local npc = nav.npc
	local position = root.Position
	local world = deps.world
	if world and position.Y < world:surfaceHeight(position.X, position.Z) - T.voidMargin then
		-- A fallen NPC is under the world, where nobody sees it. Nowhere good yet: leave it to Failed.
		if not recover(nav, "below the terrain") then
			note(nav, "below the terrain, with no safe place to go")
		end
		return
	end
	local floor = humanoid.FloorMaterial
	if floor ~= Enum.Material.Air and floor ~= Enum.Material.Water then
		-- Two spots a real distance apart, or both would soon be wherever they're stuck.
		local good: Vector3? = npc.lastGoodPosition
		if not good or (position - good).Magnitude >= T.goodSpacing then
			npc.olderGoodPosition = good
			npc.lastGoodPosition = position
		end
	end
end

function Navigation.Step(npc: any, clock: number)
	local rig = npc.rig
	if not rig then
		return
	end
	local root: BasePart = rig.root
	local humanoid: Humanoid = rig.humanoid
	local position = root.Position
	npc.position = position
	local nav = navOf(npc)

	safetyCheck(nav, root, humanoid, clock)
	stepFacing(nav, root, 0.1)

	if next(nav.pauses) ~= nil then
		return
	end

	-- A new destination from anywhere (the brain, a scene, a quest): take it up.
	local destination: Vector3? = npc.destination
	if destination and clock >= nav.nextGoalCheck then
		local goal = nav.goal
		if not goal or (goal - destination).Magnitude > 2 then
			nav.nextGoalCheck = clock + 1
			Navigation.MoveTo(npc, destination)
		end
	end

	if nav.status == "queued" and clock >= nav.nextRepath + 8 then
		request(nav) -- its place in a full queue was dropped: ask again
	end
	if nav.status ~= "walking" then
		haltRig(nav)
		return
	end
	local waypoints = nav.waypoints
	if not waypoints then
		return
	end

	local wp = waypoints[nav.index]
	if not wp then
		return
	end
	local atEnd = nav.index >= #waypoints
	local flat = flatDistance(position, wp.p)
	local rise = math.abs(position.Y - wp.p.Y)
	if flat <= (if atEnd then T.reachGoal else T.reachWaypoint) and rise < 8 then
		if atEnd then
			nav.status = "arrived"
			nav.waypoints, nav.route = nil, nil
			nav.level = 0
			note(nav, "arrived")
			haltRig(nav)
			Navigation.Arrived:Fire(npc, nav.goal)
			return
		end
		nav.index += 1
		wp = waypoints[nav.index]
		flat = flatDistance(position, wp.p)
		nav.issued = nil
		nav.deadline = math.huge
	end

	-- Speed: their own pace, easing off at the very end instead of snapping to a stop.
	local speed = currentSpeed(nav)
	if nav.index >= #waypoints and flat < T.slowNear then
		speed *= T.slowShare
	end
	applySpeed(humanoid, speed)

	if nav.deadline == math.huge then
		nav.deadline = clock + flat / math.max(speed, 1) * 2.5 + T.waypointGrace
	end
	openDoorsAhead(nav, position, wp.p, clock)
	-- Once per waypoint: set on every step, this was a hop every time they landed.
	if wp.jump and flat < 4 and nav.jumpedAt ~= nav.index then
		nav.jumpedAt = nav.index
		humanoid.Jump = true
	end
	if nav.issued ~= wp.p or clock >= nav.nextIssue then
		nav.issued = wp.p
		nav.nextIssue = clock + T.reissue
		nav.halted = false
		humanoid:MoveTo(wp.p)
	end

	-- Progress: how far they REALLY moved, whatever the waypoints say. Slowed to a standstill by a
	-- status isn't being stuck.
	if clock >= nav.sampleAt + T.stuckWindow then
		local moved = flatDistance(position, nav.samplePos)
		nav.sampleAt, nav.samplePos = clock, position
		if humanoid.WalkSpeed >= 1 then
			if moved < T.stuckMoved then
				escalate(nav, string.format("moved %.1f studs in %.1f s", moved, T.stuckWindow))
				return
			elseif moved > T.stuckMoved * 2 then
				nav.level = 0
			end
		end
	end
	if clock >= nav.deadline then
		nav.deadline = math.huge
		escalate(nav, "past a waypoint's deadline")
	end
end

-- ─── Reports ────────────────────────────────────────────────────────────────

function Navigation.Stats(): { [string]: number }
	return {
		computed = stats.computed,
		cacheHits = stats.cacheHits,
		failed = stats.failed,
		queued = #queue,
		direct = stats.direct,
		blocked = stats.blocked,
		stuck = stats.stuck,
		recovered = stats.recovered,
		doors = stats.doors,
		failures = stats.failures,
		cached = cacheCount,
		avgMs = if stats.computed + stats.failed > 0 then stats.msTotal / (stats.computed + stats.failed) else 0,
	}
end

-- What the overlay draws for one NPC, or nil if Navigation isn't driving it.
function Navigation.Debug(npc: any): { [string]: any }?
	local nav = navs[npc]
	if not nav then
		return nil
	end
	local points: { Vector3 } = {}
	for i = nav.index, #(nav.waypoints or {}) do
		table.insert(points, (nav.waypoints :: { Waypoint })[i].p)
	end
	local pauses: { string } = {}
	for reason in nav.pauses do
		table.insert(pauses, reason)
	end
	return {
		status = if #pauses > 0 then "paused:" .. table.concat(pauses, ",") else nav.status,
		goal = nav.goal,
		target = nav.target,
		points = points,
		lastStuck = nav.lastStuck,
		level = nav.level,
	}
end

function Navigation.Report(npc: any): string
	local nav = navs[npc]
	if not nav then
		return string.format("%s: not driven by Navigation (tier %s)", npc.name, tostring(npc.tier))
	end
	local rig = npc.rig
	local agent = if rig then agentOf(rig) else nil
	local lines = {
		string.format(
			"%s: %s, style %s, waypoint %d/%d, attempt %d, stuck level %d",
			npc.name, if next(nav.pauses) ~= nil then "paused" else nav.status, nav.style, nav.index, #(nav.waypoints or {}), nav.attempt, nav.level
		),
		if agent then string.format("agent: radius %.2f, height %.1f", agent.radius, agent.height) else "agent: no rig",
	}
	if rig then
		local velocity = rig.root.AssemblyLinearVelocity
		local owner = "?"
		local ok, networkOwner = pcall(function()
			return rig.root:GetNetworkOwner()
		end)
		if ok then
			owner = if networkOwner then networkOwner.Name else "server"
		end
		table.insert(lines, string.format("speed %.1f, walk speed %.1f, network owner %s, Animate script: %s", Vector3.new(velocity.X, 0, velocity.Z).Magnitude, rig.humanoid.WalkSpeed, owner, tostring(rig.model:FindFirstChild("Animate") ~= nil)))
	end
	if nav.lastStuck then
		table.insert(lines, "last stuck: " .. nav.lastStuck)
	end
	table.insert(lines, "history:")
	for _, line in nav.history do
		table.insert(lines, "  " .. line)
	end
	return table.concat(lines, "\n")
end

return Navigation
