--!strict
--[[
	Delivery: projectiles that actually fly. A projectile-form spell is no longer decided by an
	instant ray at resolve time: it travels on the server, and the effect lands where and on whom
	it really hits.

		Delivery.plan(ctx) -> Flight          launch parameters from the caster's stats (no side effects)
		Delivery.fly(flight, ignore) -> Impact   YIELDS until the flight ends (Heartbeat-stepped)
		Delivery.capacity() -> boolean        false when maxActive flights are in the air (the cast
		                                      then falls back to Targeting's instant line)

	FLIGHT (numbers in Data/CombatTuning.projectile)
		speed      speedBase + speedPerPower x (P-1), capped
		gravity    by domain (earth lobs, water arcs); the launch adds the lift that lands it on
		           the aim point, so arcs still hit what was aimed at
		homing     with the Homing modifier and a validated target: steers toward the target's
		           root at up to homingTurn rad/s
		piercing   with the Piercing modifier: passes through 1 + pierceCount characters
		bounce     `bounces` ricochets off solid surfaces (0 by default)
		end        a character (no pierce left), a solid surface, or range x rangeMult / maxLifetime
		           (fizzles in the air: the effect still lands there)
		splash     an impact on a surface within `splash` studs of a character also hits it, so a
		           ground shot at someone's feet counts
		parry      a flight reaching someone whose guard is in its parry window (Cast/Guard) turns
		           back at its caster, homing, with a fresh range and a new projectile id
		           (flight.onReflect lets the caster's side re-cue the visuals). It can then hit
		           the caster; the Impact names who turned it (reflectedBy).

	One Heartbeat connection steps every flight; each step is one Spherecast (a few more only when
	passing through non-solid parts). Clients get the same launch numbers in the "launch" cue and
	simulate the same path for the visuals (Fx/SpellFx), then snap to the server's impact point.
]]

local RunService = game:GetService("RunService")

local Registry = require(game:GetService("ReplicatedStorage").Shared.Magic.Registry)
local Aim = require(game:GetService("ReplicatedStorage").Shared.Magic.Aim)
local Cast = script.Parent
local C = require(Cast.Parent.Data.CombatTuning)
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local Guard = require(Cast.Guard)

local P = C.projectile

export type Flight = {
	id: number,
	origin: Vector3,
	velocity: Vector3,
	gravity: number, -- studs/s² downward
	radius: number,
	homing: BasePart?,
	turnRate: number,
	pierce: number, -- characters it may pass through (0 = stops at the first)
	bounces: number,
	maxDistance: number,
	lifetime: number,
	ownerModel: Model,
	property: string?, -- for guards: unblockable categories never parry
	piercing: boolean?,
	onReflect: ((oldId: number, at: Vector3, velocity: Vector3) -> ())?, -- set by the caster's side
	onBend: ((oldId: number, at: Vector3, velocity: Vector3, hangSeconds: number?) -> ())?, -- set by the caster's side: re-draw a curved or hanging flight
	bent: boolean?, -- Bend Path has already had its say on this flight
}

export type Impact = {
	point: Vector3,
	normal: Vector3?,
	hits: { CastTypes.Hit },
	surface: boolean, -- ended on terrain or a solid part
	expired: boolean, -- ran out of range or time in the air
	flightTime: number,
	reflectedBy: Model?, -- a parry turned it back (the caster may be among the hits)
}

type Live = {
	flight: Flight,
	thread: thread,
	position: Vector3,
	velocity: Vector3,
	travelled: number,
	age: number,
	bounces: number,
	pierce: number,
	hits: { CastTypes.Hit },
	excluded: { Instance },
	params: RaycastParams,
	reflectedBy: Model?,
	hanging: boolean?, -- Time holds it in the air until Delivery.release
}

local Delivery = {}

--[[
	Set by Cast/GravityRuntime. Called once per step for each flight, before it moves. Returns:
		"stop"              the flight ends here (Orbit Shield)
		"reflect", model    it turns back at its caster, as a parry does, turned by `model` (Bend Path)
		"bend", velocity    it carries on with this velocity, no longer homing (Bend Path)
		nil                 nothing
]]
Delivery.interceptor = nil :: ((position: Vector3, velocity: Vector3, flight: Flight) -> (string?, any))?

--[[
	Set by Cast/TimeRuntime. Called once per step for each flight: a number means "hang here for up to
	this many seconds", until Delivery.release. A hanging flight doesn't age or check anything.
]]
Delivery.hanger = nil :: ((position: Vector3, flight: Flight, age: number) -> number?)?

local live: { Live } = {}
local nextId = 0
local stepper: RBXScriptConnection? = nil

local function finish(entry: Live, point: Vector3, normal: Vector3?, surface: boolean, expired: boolean)
	local index = table.find(live, entry)
	if index then
		table.remove(live, index)
	end
	-- Splash: an impact right beside a character still hits it.
	if #entry.hits == 0 and not expired then
		local spared = entry.reflectedBy or entry.flight.ownerModel
		for _, near in Targeting.inRadius(point, P.splash, 1, { [spared] = true }) do
			table.insert(entry.hits, near)
		end
	end
	task.spawn(entry.thread, {
		point = point,
		normal = normal,
		hits = entry.hits,
		surface = surface,
		expired = expired,
		flightTime = entry.age,
		reflectedBy = entry.reflectedBy,
	} :: Impact)
end

-- A parried flight turns back at whoever cast it: homing on them, a fresh range, and the
-- parrier can't be hit by it again (the caster now can).
local function reflect(entry: Live, parrier: Model, at: Vector3)
	local f = entry.flight
	local owner = f.ownerModel
	local ownerRoot = owner and owner:FindFirstChild("HumanoidRootPart")
	local speed = entry.velocity.Magnitude
	local direction = if ownerRoot and ownerRoot:IsA("BasePart") and (ownerRoot.Position - at).Magnitude > 0.5
		then (ownerRoot.Position - at).Unit
		else -entry.velocity.Unit
	entry.velocity = direction * speed
	entry.reflectedBy = parrier
	entry.position = at + direction * (f.radius + 0.1)
	entry.travelled, entry.age, entry.pierce = 0, 0, 0
	local index = table.find(entry.excluded, owner)
	if index then
		table.remove(entry.excluded, index)
	end
	table.insert(entry.excluded, parrier)
	if ownerRoot and ownerRoot:IsA("BasePart") then
		f.homing = ownerRoot
		f.turnRate = math.max(f.turnRate, math.rad(240))
	end
	local oldId = f.id
	nextId += 1
	f.id = nextId
	local hook = f.onReflect
	if hook then
		task.spawn(hook, oldId, entry.position, entry.velocity)
	end
end

local function step(entry: Live, dt: number)
	local f = entry.flight
	if entry.hanging then
		return
	end
	entry.age += dt

	local hanger = Delivery.hanger
	if hanger then
		local seconds = hanger(entry.position, f, entry.age)
		if seconds then
			entry.hanging = true
			local oldId = f.id
			nextId += 1
			f.id = nextId
			local hook = f.onBend
			if hook then
				-- Barely moving, not zero: the client's flight draws its direction from this.
				task.spawn(hook, oldId, entry.position, Vector3.new(0, 0.01, 0), seconds)
			end
			return
		end
	end

	local interceptor = Delivery.interceptor
	if interceptor then
		local action, value = interceptor(entry.position, entry.velocity, f)
		if action == "stop" then
			finish(entry, entry.position, nil, true, false)
			return
		elseif action == "reflect" and value then
			reflect(entry, value, entry.position)
			return
		elseif action == "bend" then
			entry.velocity = value
			f.homing = nil
			local oldId = f.id
			nextId += 1
			f.id = nextId
			local hook = f.onBend
			if hook then
				task.spawn(hook, oldId, entry.position, entry.velocity)
			end
		end
	end

	-- Homing: turn the velocity toward the target, at most turnRate x dt radians this step.
	local target = f.homing
	if target and target.Parent then
		local to = target.Position - entry.position
		local speed = entry.velocity.Magnitude
		if to.Magnitude > 0.5 and speed > 0.1 then
			local current = entry.velocity.Unit
			local desired = to.Unit
			local angle = math.acos(math.clamp(current:Dot(desired), -1, 1))
			local maxTurn = f.turnRate * dt
			local t = if angle > 1e-4 then math.min(1, maxTurn / angle) else 1
			local turned = current:Lerp(desired, t)
			entry.velocity = (if turned.Magnitude > 1e-3 then turned.Unit else desired) * speed
		end
	end
	entry.velocity -= Vector3.new(0, f.gravity * dt, 0)

	local move = entry.velocity * dt
	for _ = 1, 4 do -- passes through non-solid parts and pierced characters within one step
		if move.Magnitude < 1e-3 then
			break
		end
		entry.params.FilterDescendantsInstances = entry.excluded
		local result = workspace:Spherecast(entry.position, f.radius, move, entry.params)
		if not result then
			entry.position += move
			entry.travelled += move.Magnitude
			break
		end
		local reached = result.Position
		local travelledNow = (reached - entry.position).Magnitude
		local hit = Targeting.characterOf(result.Instance)
		if
			hit
			and not entry.reflectedBy
			and Guard.parryProjectile(hit.model, entry.position, { property = f.property, pierce = f.piercing })
		then
			reflect(entry, hit.model, reached)
			return
		end
		if hit then
			table.insert(entry.hits, hit)
			table.insert(entry.excluded, hit.model)
			if entry.pierce <= 0 then
				finish(entry, reached, result.Normal, false, false)
				return
			end
			entry.pierce -= 1
		elseif result.Instance:IsA("Terrain") or (result.Instance :: BasePart).CanCollide then
			if entry.bounces > 0 then
				entry.bounces -= 1
				entry.velocity -= 2 * entry.velocity:Dot(result.Normal) * result.Normal
				entry.position = reached + result.Normal * (f.radius + 0.05)
				entry.travelled += travelledNow
				return
			end
			finish(entry, reached, result.Normal, true, false)
			return
		else
			table.insert(entry.excluded, result.Instance) -- glass panes, leaves, effects
		end
		-- Continue the rest of this step's move from where the cast stopped.
		local remaining = move.Magnitude - travelledNow
		entry.position = reached
		entry.travelled += travelledNow
		move = move.Unit * math.max(0, remaining)
	end

	if entry.travelled >= f.maxDistance or entry.age >= f.lifetime then
		finish(entry, entry.position, nil, false, true)
	end
end

local function ensureStepper()
	if stepper then
		return
	end
	stepper = RunService.Heartbeat:Connect(function(dt)
		-- Iterate a snapshot: finish() removes entries.
		for _, entry in table.clone(live) do
			local ok, err = pcall(step, entry, dt)
			if not ok then
				warn("[Delivery] flight step failed: " .. tostring(err))
				finish(entry, entry.position, nil, false, true)
			end
		end
		if #live == 0 and stepper then
			stepper:Disconnect()
			stepper = nil
		end
	end)
end

-- Characters a Piercing projectile passes through (the modifier's data, Modifiers.piercing).
local function pierceCount(): number
	local params = Registry.modifiers.piercing and Registry.modifiers.piercing.params
	local n = params and params.pierceCount
	return if typeof(n) == "number" then n else 2
end

function Delivery.capacity(): boolean
	return #live < P.maxActive
end

--[[
	Lets a hanging flight go. With `aim` it flies at that point, at the speed it had; without, it carries
	on as it was. With `homing`, it steers at that part, as the Homing modifier does.
]]
function Delivery.release(flight: Flight, aim: Vector3?, homing: BasePart?)
	for _, entry in live do
		if entry.flight == flight and entry.hanging then
			entry.hanging = false
			if aim and (aim - entry.position).Magnitude > 0.5 then
				entry.velocity = (aim - entry.position).Unit * entry.velocity.Magnitude
			end
			if homing then
				flight.homing = homing
				flight.turnRate = math.max(flight.turnRate, math.rad(240))
			end
			local oldId = flight.id
			nextId += 1
			flight.id = nextId
			local hook = flight.onBend
			if hook then
				task.spawn(hook, oldId, entry.position, entry.velocity)
			end
			return
		end
	end
end

-- A fresh projectile id for flights built outside plan() (weapon arrows: Services/WeaponService).
function Delivery.newId(): number
	nextId += 1
	return nextId
end

-- Launch parameters for this cast (or echo). The muzzle is the caster's chest.
function Delivery.plan(ctx: CastTypes.EffectContext): Flight
	local stats = ctx.stats
	local power = stats.recipe.power
	-- The same maths the client's reticle arc uses (Shared/Magic/Aim).
	local speed = Aim.projectileSpeed(power) * (ctx.speedMult or 1) -- a full charge flies faster
	local gravity = Aim.projectileGravity(stats.domains[1])
	local muzzle = Aim.muzzle(ctx.origin)
	local velocity = Aim.launchVelocity(muzzle, ctx.point, speed, gravity, ctx.root.CFrame.LookVector)
	local homing: BasePart? = nil
	if stats.flags.homing and ctx.target then
		local hit = Targeting.characterOf(ctx.target)
		homing = if hit then hit.root else nil
	end
	nextId += 1
	return {
		id = nextId,
		origin = muzzle,
		velocity = velocity,
		gravity = gravity,
		radius = Aim.projectileRadius(power),
		homing = homing,
		turnRate = P.homingTurn,
		pierce = if stats.flags.piercing then pierceCount() else 0,
		bounces = P.bounces,
		maxDistance = Aim.flightDistance(stats.range),
		lifetime = P.maxLifetime,
		ownerModel = ctx.character,
		property = stats.recipe.property,
		piercing = stats.flags.piercing == true,
		onReflect = nil,
	}
end

-- Flies `flight` and yields until it ends. `ignore` is never hit (the caster, their constructs).
function Delivery.fly(flight: Flight, ignore: { Instance }): Impact
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.RespectCanCollide = false
	local entry: Live = {
		flight = flight,
		thread = coroutine.running(),
		position = flight.origin,
		velocity = flight.velocity,
		travelled = 0,
		age = 0,
		bounces = flight.bounces,
		pierce = flight.pierce,
		hits = {},
		excluded = table.clone(ignore),
		params = params,
	}
	table.insert(live, entry)
	ensureStepper()
	return coroutine.yield()
end

return Delivery
