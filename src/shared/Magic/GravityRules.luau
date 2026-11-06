--!strict
--[[
	GravityRules: the numbers behind the gravity powers, with no Instances, so Tests/Gravity.spec can
	check them (docs/Gravity.md). Server/Magic/Cast/GravityRuntime does the running.
]]

local G = require(script.Parent.Data.GravityTuning)

local GravityRules = {}

-- A value from a per-tier list. Below Sensing counts as Sensing; past the end, the last one.
function GravityRules.byTier(list: { number }, tier: number): number
	return list[math.clamp(math.floor(tier), 1, #list)]
end

local byTier = GravityRules.byTier

export type Flight = { speed: number, ceiling: number, drainShare: number }

function GravityRules.flight(tier: number): Flight
	return { speed = byTier(G.flight.speed, tier), ceiling = byTier(G.flight.ceiling, tier), drainShare = byTier(G.flight.drainShare, tier) }
end

-- Is this measured movement more than flight allows? Knockback and hastes fit inside the margins.
function GravityRules.flightViolation(flight: Flight, speed: number, heightAboveGround: number): boolean
	local f = G.flight
	return speed > flight.speed * f.speedSlack + f.speedMargin or heightAboveGround > flight.ceiling * f.heightSlack + f.heightMargin
end

function GravityRules.canMeteor(tier: number, height: number): boolean
	return tier >= G.meteor.minTier and height >= G.meteor.minHeight
end

function GravityRules.meteorShare(height: number): number
	return math.min(G.meteor.maxShare, G.meteor.share + G.meteor.sharePerStud * math.max(0, height))
end

function GravityRules.meteorRadius(height: number): number
	return math.min(G.meteor.maxRadius, G.meteor.radius + G.meteor.radiusPerStud * math.max(0, height))
end

-- The grip tightens the longer it holds.
function GravityRules.gripShare(elapsed: number): number
	return G.grip.share * (1 + G.grip.ramp * math.max(0, elapsed))
end

function GravityRules.gripExecutes(tier: number, healthShare: number): boolean
	local at = byTier(G.grip.execute, tier)
	return at > 0 and healthShare <= at
end

function GravityRules.slamShare(height: number): number
	return G.lift.slamShare + G.lift.slamPerStud * math.max(0, height)
end

-- Where a throw lands: toward the aim, at most `throw` studs from the start, flat.
function GravityRules.throwTarget(start: Vector3, aim: Vector3, tier: number): Vector3
	local reach = byTier(G.lift.throw, tier)
	local flat = Vector3.new(aim.X - start.X, 0, aim.Z - start.Z)
	if reach <= 0 or flat.Magnitude < 0.1 then
		return start
	end
	return start + flat.Unit * math.min(reach, flat.Magnitude)
end

-- How fast a well drags you, by how far from its middle you are (0 past the rim).
function GravityRules.wellPull(tier: number, distance: number, radius: number): number
	if radius <= 0 or distance > radius then
		return 0
	end
	local t = math.clamp(distance / radius, 0, 1)
	return byTier(G.well.pull, tier) * (1 - (1 - G.well.edgePull) * t)
end

function GravityRules.wellRadius(area: number): number
	return math.clamp(area, G.well.radiusMin, G.well.radiusMax)
end

function GravityRules.singularityRadius(area: number): number
	return math.clamp(area, G.singularity.radiusMin, G.singularity.radiusMax)
end

function GravityRules.blastShare(tier: number): number
	return G.singularity.blastShare + G.singularity.blastPerTier * math.max(1, tier)
end

-- Multiples of normal gravity in a field. "light" isn't scaled: it's already nearly weightless.
function GravityRules.fieldMult(mode: string, tier: number): number?
	if mode == "heavy" then
		return byTier(G.field.heavy, tier)
	elseif mode == "invert" then
		return byTier(G.field.invert, tier)
	end
	return nil
end

function GravityRules.seconds(base: number, perTier: number, tier: number): number
	return base + perTier * math.max(1, tier)
end

return GravityRules
