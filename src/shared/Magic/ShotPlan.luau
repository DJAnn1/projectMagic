--!strict
--[[
	ShotPlan: how a cast's bolt will fly, worked out the way the server does it (CastService builds
	the context, Cast/Shapes.before tunes it, Cast/Delivery.plan launches it). Pure and shared, so
	the caster's client can put its own bolt in the air on the release frame (Client/Fx/LocalShots)
	without waiting a round trip for the server's "launch" cue. The server stays the only judge of
	where a bolt goes and what it hits: its cue corrects whatever this gets wrong.

		ShotPlan.of(recipe, stats, opts) -> Plan?
			nil for anything that isn't a bolt (form ~= "projectile")
			opts.held        seconds the charge was held (equip mode), nil for a tap or quick cast
			opts.hasTarget   a target was picked (homing needs one)
			opts.shapes      false when the spell_shapes_enabled flag is off
		ShotPlan.velocity(plan, origin, point, fallback) -> Vector3
			the launch velocity from `origin` (the hand) toward `point`

	Mirrors (keep in step if those change):
		speed    Aim.projectileSpeed(power) x charge stage speed x route flight.speed x 0.6 for a lob
		gravity  Aim.projectileGravity(domain); a lob or a route's flight.gravity makes it
		         max(g, 20) x (lob gravityMult x flight.gravity)
		homing   Homing modifier, a homing shape or flight.homing, and only with a target
		turnRate CombatTuning.projectile.homingTurn (server-only data: copied below)
		lifetime CombatTuning.projectile.maxLifetime (copied below)
]]

local Aim = require(script.Parent.Aim)
local Charge = require(script.Parent.Charge)
local Evolution = require(script.Parent.Evolution)
local SpellRoute = require(script.Parent.SpellRoute)
local SpellShape = require(script.Parent.SpellShape)

export type Plan = {
	speed: number,
	gravity: number,
	homing: boolean,
	turnRate: number,
	lifetime: number,
	radius: number,
	look: string?, -- the route's own bolt body (Data/EffectLibrary params.look)
	domain: string,
}

local HOMING_TURN = math.rad(160) -- CombatTuning.projectile.homingTurn
local LIFETIME = 4 -- CombatTuning.projectile.maxLifetime
local LOB_SPEED = 0.6 -- Cast/Shapes.before: a lob flies slower
local MIN_HEAVY_GRAVITY = 20 -- Cast/Delivery.plan: max(gravity, 20) once something makes it heavy

local ShotPlan = {}

function ShotPlan.of(
	recipe: { branch: string, property: string, verb: string, form: string, power: number },
	stats: any,
	opts: { held: number?, hasTarget: boolean?, shapes: boolean? }?
): Plan?
	if recipe.form ~= "projectile" then
		return nil
	end
	local o = opts or {}
	local ok, route = pcall(SpellRoute.find, recipe)
	if not ok or not route then
		return nil
	end
	local params: { [string]: any } = (route :: any).params or {}
	local domain: string = if stats.domains and stats.domains[1] then stats.domains[1] else "energy"

	local speedMult = 1
	-- The charge stage (CastService passes p.charge.speedMult). Charge.apply edits the stats it is
	-- given, so it gets a copy.
	if o.held and Charge.chargeableStats(stats) then
		local copy = table.clone(stats)
		copy.costBreakdown = table.clone(stats.costBreakdown or {})
		local applied = Charge.apply(copy, Charge.stageIndex(o.held, stats.castTime), o.held)
		speedMult *= applied.speedMult
	end

	-- The spell's shape (Shapes.find -> Shapes.before) comes before the route's own flight tune.
	local gravityMult: number? = nil
	local homing = stats.flags ~= nil and stats.flags.homing == true
	if o.shapes ~= false then
		local shape = Evolution.shape(SpellShape.of(recipe, route.id), stats.masteryTier or 0)
		if shape and shape.kind == "lob" then
			gravityMult = shape.gravityMult
			speedMult *= LOB_SPEED
		elseif shape and shape.kind == "homing" then
			homing = true
		end
	end
	local flight = params.flight
	if typeof(flight) == "table" then
		if typeof(flight.speed) == "number" then
			speedMult *= flight.speed
		end
		if flight.homing == true then
			homing = true
		end
		if typeof(flight.gravity) == "number" then
			gravityMult = (gravityMult or 1) * flight.gravity
		end
	end

	local gravity = Aim.projectileGravity(domain)
	if gravityMult then
		gravity = math.max(gravity, MIN_HEAVY_GRAVITY) * gravityMult
	end
	return {
		speed = Aim.projectileSpeed(recipe.power) * speedMult,
		gravity = gravity,
		homing = homing and o.hasTarget == true,
		turnRate = HOMING_TURN,
		lifetime = LIFETIME,
		radius = Aim.projectileRadius(recipe.power),
		look = if typeof(params.look) == "string" then params.look else nil,
		domain = domain,
	}
end

function ShotPlan.velocity(plan: Plan, origin: Vector3, point: Vector3, fallback: Vector3): Vector3
	return Aim.launchVelocity(origin, point, plan.speed, plan.gravity, fallback)
end

return ShotPlan
