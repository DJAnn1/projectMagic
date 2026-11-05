--!strict
--[[
	Aim: the geometry of where a spell goes, shared by the server (CastService's range and sight
	checks, Cast/Delivery's flights, Cast/Targeting) and the client's reticle
	(Controllers/ReticleController). One copy of the maths, so the reticle can never promise a
	shot the server then refuses, or hide one it would allow. docs/Casting.md §7.

	ORIGINS
		muzzle(rootPosition)   where spells leave the body: the chest, muzzleHeight above the root.
		                       Range is measured from here, projectiles launch from here and beams
		                       start here. (The hand moves with the animation, which the server
		                       can't see, so the chest is the honest origin; the hand glow is cosmetic.)
		eye(character)         the head (or the root): the line-of-sight check starts here.
	RANGE    withinRange(muzzle, point, range): range x rangeTolerance + rangeSlack (latency, jitter).
	SIGHT    lineOfSight(from, to, ignore): nothing solid (CanCollide parts, terrain) blocks the line
	         short of `to` by more than losTolerance; characters and non-colliding parts don't block.
	FLIGHT   projectileSpeed/Gravity/Radius, launchVelocity (the lift that lands an arc on the aim
	         point), positionAt (ballistics), as Delivery flies them.
	SHAPES   reticleKind(form): which reticle a form gets; beamRadius, chainJump, touch cone.

	Not a secret: these are the rules of aiming, which any player can observe anyway.
]]

local Aim = {}

Aim.tuning = {
	muzzleHeight = 1.5, -- studs above the HumanoidRootPart
	rangeTolerance = 1.1, -- aim may be this much beyond stats.range (latency, aim jitter)
	rangeSlack = 6, -- plus this many studs
	losTolerance = 4, -- the line-of-sight ray may stop this short of the aim point
	selfCentred = { aura = true } :: { [string]: boolean }, -- forms that land on the caster, ignoring aim
	noLineOfSight = { aura = true, ritual = true } :: { [string]: boolean }, -- forms that skip the check
	projectile = {
		speedBase = 95, -- studs/s at P1
		speedPerPower = 9,
		maxSpeed = 220,
		radiusBase = 1.1, -- hit sphere radius (studs)
		radiusPerPower = 0.12,
		rangeMult = 1.25, -- flies up to stats.range x this before it fizzles in the air
		-- Downward pull (studs/s²) by domain: earth is lobbed, water arcs a little.
		gravityByDomain = { earth = 70, water = 30, life = 12 } :: { [string]: number },
	},
	beam = {
		radius = 0.9, -- thickness of the beam's hit sweep
		radiusPerPower = 0.08,
	},
	touch = {
		coneDegrees = 55, -- half-angle in front of the caster
		reachSlack = 2, -- studs past stats.range
	},
	chain = {
		jumpBase = 10, -- studs a chain can leap to its next target
		jumpPerPower = 1.2,
	},
}

local T = Aim.tuning

export type ReticleKind = "arc" | "line" | "chain" | "cone" | "ground" | "wall" | "self"

local KIND_BY_FORM: { [string]: ReticleKind } = {
	projectile = "arc",
	beam = "line",
	chain = "chain",
	touch = "cone",
	burst = "ground",
	zone = "ground",
	pillar = "ground",
	summon = "ground",
	ritual = "ground",
	wall = "wall",
	aura = "self",
}

function Aim.reticleKind(form: string): ReticleKind
	return KIND_BY_FORM[form] or "ground"
end

function Aim.muzzle(rootPosition: Vector3): Vector3
	return rootPosition + Vector3.new(0, T.muzzleHeight, 0)
end

function Aim.eye(character: Model): Vector3?
	local head = character:FindFirstChild("Head")
	if head and head:IsA("BasePart") then
		return head.Position
	end
	local root = character:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root.Position else nil
end

function Aim.maxDistance(range: number): number
	return range * T.rangeTolerance + T.rangeSlack
end

function Aim.withinRange(muzzle: Vector3, point: Vector3, range: number): boolean
	return (point - muzzle).Magnitude <= Aim.maxDistance(range)
end

-- ─── Line of sight ──────────────────────────────────────────────────────────

local function characterModel(instance: Instance): Model?
	local model = instance:FindFirstAncestorOfClass("Model")
	while model do
		if model:FindFirstChildOfClass("Humanoid") then
			return model
		end
		model = model:FindFirstAncestorOfClass("Model")
	end
	return nil
end

local function isSolid(instance: Instance): boolean
	return instance:IsA("Terrain") or (instance:IsA("BasePart") and instance.CanCollide)
end

-- (clear, blockedAt?). Looks past characters and non-colliding parts (at most 8 of them).
function Aim.lineOfSight(from: Vector3, to: Vector3, ignore: { Instance }, tolerance: number?): (boolean, Vector3?)
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded = table.clone(ignore)
	local origin = from
	for _ = 1, 8 do
		params.FilterDescendantsInstances = excluded
		local result = workspace:Raycast(origin, to - origin, params)
		if not result then
			return true, nil
		end
		local character = characterModel(result.Instance)
		if isSolid(result.Instance) and not character then
			return (result.Position - to).Magnitude <= (tolerance or T.losTolerance), result.Position
		end
		table.insert(excluded, character or result.Instance)
		origin = result.Position
	end
	return true, nil
end

-- ─── Projectile flight ──────────────────────────────────────────────────────

function Aim.projectileSpeed(power: number): number
	local P = T.projectile
	return math.min(P.maxSpeed, P.speedBase + P.speedPerPower * (power - 1))
end

function Aim.projectileGravity(domain: string?): number
	return T.projectile.gravityByDomain[domain or ""] or 0
end

function Aim.projectileRadius(power: number): number
	return T.projectile.radiusBase + T.projectile.radiusPerPower * (power - 1)
end

function Aim.flightDistance(range: number): number
	return math.max(10, range * T.projectile.rangeMult)
end

-- The launch velocity from `muzzle` toward `point`: straight at it, plus the lift that brings a
-- falling arc back down onto it. `fallback` is the direction when the point is on the muzzle.
function Aim.launchVelocity(muzzle: Vector3, point: Vector3, speed: number, gravity: number, fallback: Vector3): Vector3
	local aim = point - muzzle
	local distance = aim.Magnitude
	local direction = if distance > 0.1 then aim.Unit else fallback
	local velocity = direction * speed
	if gravity > 0 and distance > 0.1 then
		local t = distance / speed
		velocity += Vector3.new(0, gravity * t * 0.5, 0)
	end
	return velocity
end

-- Where a launched projectile is after `t` seconds (no homing, no bounces).
function Aim.positionAt(origin: Vector3, velocity: Vector3, gravity: number, t: number): Vector3
	return origin + velocity * t - Vector3.new(0, 0.5 * gravity * t * t, 0)
end

-- ─── Other shapes ───────────────────────────────────────────────────────────

function Aim.beamRadius(power: number): number
	return T.beam.radius + T.beam.radiusPerPower * power
end

function Aim.chainJump(power: number): number
	return T.chain.jumpBase + T.chain.jumpPerPower * (power - 1)
end

function Aim.touchReach(range: number): number
	return range + T.touch.reachSlack
end

return Aim
