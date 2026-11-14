--!strict
--[[
	Evolution: how a spell grows with mastery, and what its verb adds (docs/SpellOverhaul.md §9,
	stage 4; data in Data/Evolutions). Pure and shared, so the server (Cast/Shapes,
	Cast/PropertyBehaviour) and the Composer always agree.

		Evolution.shape(shape, tier) -> Shape?        the shape grown for this mastery (a copy)
		Evolution.masterReady(tier) / finisherReady(tier)
		Evolution.durationMult(tier) -> number
		Evolution.finisher(behaviourId) -> Finisher?
		Evolution.finisherMult(tier) -> number
		Evolution.flavour(verb, routeId) -> Flavour?  nil off the plain-damage route
		Evolution.lines(recipe, routeId, shape, behaviourId, tier) -> { {text, reached} }
		                                               the Composer's mastery and verb lines
]]

local Data = require(script.Parent.Data.Evolutions)
local Behaviours = require(script.Parent.Data.PropertyBehaviours)
local ShapeData = require(script.Parent.Data.SpellShapes)

local Evolution = {}

local T = Data.tiers

function Evolution.shape(shape: { [string]: any }?, tier: number): { [string]: any }?
	if not shape then
		return nil
	end
	local grow = Data.shapeGrowth[shape.kind]
	local times = (if tier >= T.expert then 1 else 0) + (if tier >= T.transcendent then 1 else 0)
	if not grow or times == 0 then
		return shape
	end
	local out = table.clone(shape)
	for key, add in grow do
		if typeof(out[key]) == "number" then
			out[key] += add * times
		end
	end
	return out
end

function Evolution.masterReady(tier: number): boolean
	return tier >= T.master
end

function Evolution.finisherReady(tier: number): boolean
	return tier >= T.grandmaster
end

function Evolution.durationMult(tier: number): number
	return if tier >= T.master then Data.master.durationMult else 1
end

function Evolution.finisher(behaviourId: string?): Data.Finisher?
	return if behaviourId then Data.finishers[behaviourId] else nil
end

function Evolution.finisherMult(tier: number): number
	return if tier >= T.transcendent then Data.transcendent.finisherMult else 1
end

function Evolution.flavour(verb: string, routeId: string?): Data.Flavour?
	if not routeId or not Data.flavourRoutes[routeId] then
		return nil
	end
	return Data.verbs[verb]
end

-- Which behaviour a damaging route's hits carry (the same choice Cast/Shapes makes): the thermal
-- routes know better than the property. Nil off the damaging routes.
function Evolution.behaviourFor(recipe: { property: string, verb: string }, routeId: string?): string?
	if not routeId or not ShapeData.routes[routeId] then
		return nil
	elseif routeId == "thermal" then
		return if recipe.verb == "reduce" then "cold" else "heat"
	elseif routeId == "ignite" then
		return "combustion"
	end
	local behaviour = Behaviours[recipe.property]
	if not behaviour then
		return nil
	end
	local variant = behaviour.byVerb and behaviour.byVerb[recipe.verb]
	return if variant and Behaviours[variant] then variant else recipe.property
end

export type Line = { text: string, reached: boolean }

function Evolution.lines(recipe: { verb: string }, routeId: string?, shape: { [string]: any }?, behaviourId: string?, tier: number): { Line }
	local out: { Line } = {}
	local flavour = Evolution.flavour(recipe.verb, routeId)
	if flavour then
		table.insert(out, { text = flavour.words, reached = true })
	end
	local shapeWords = shape and Data.shapeWords[shape.kind]
	if shapeWords then
		table.insert(out, { text = "Expert: " .. shapeWords .. ".", reached = tier >= T.expert })
	end
	if behaviourId then
		table.insert(out, { text = "Master: its effects work at any power and last longer.", reached = tier >= T.master })
		local finisher = Data.finishers[behaviourId]
		if finisher then
			table.insert(out, { text = "Grandmaster: " .. finisher.words .. ".", reached = tier >= T.grandmaster })
		end
	end
	if shapeWords or (behaviourId and Data.finishers[behaviourId]) then
		table.insert(out, { text = "Transcendent: all of it, stronger still.", reached = tier >= T.transcendent })
	end
	return out
end

return Evolution
