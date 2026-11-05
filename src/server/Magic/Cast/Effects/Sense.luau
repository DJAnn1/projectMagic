--!strict
--[[
	Sense: the caster perceives the property around the point. Always effective: noticing IS the
	effect. The answer goes to the caster as a short line, in words rather than numbers (exact
	numbers stay an admin tool), from what the server measured for the cast.

	What you sense depends on the property's category:
		Vital, Mental, Spiritual    living presences within the area
		Kinetic (seismicity)        stress stored in the ground
		Fluid                       water nearby
		Thermal                     warmth or cold
		Energetic                   charge in the air
		anything else               how thick the ambient magic is
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local Registry = require(Shared.Magic.Registry)
local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)

local Sense = {}

local function scale(value: number, words: { string }): string
	local index = math.clamp(math.floor(value * #words) + 1, 1, #words)
	return words[index]
end

function Sense.resolve(ctx: CastTypes.EffectContext, _params: { [string]: any }): CastTypes.Outcome
	if ctx.backfire then
		return { effective = false, hits = 0, note = "Your senses swim; whatever was there slips away." }
	end
	local stats = ctx.stats
	local property = Registry.properties[stats.recipe.property]
	local env: { [string]: number } = ctx.context.environment or {}
	local density = ctx.context.ambientDensity or 1
	local note: string

	if property.category == "Vital" or property.category == "Mental" or property.category == "Spiritual" then
		local count = #Targeting.inRadius(ctx.point, math.max(stats.area, 20), 50, { [ctx.character] = true })
		note = if count == 0
			then "You sense no other living presence nearby."
			else string.format("You sense %s %s nearby.", if count == 1 then "one" elseif count <= 3 then "a few" else "many", if count == 1 then "presence" else "presences")
	elseif stats.recipe.property == "seismicity" then
		note = "The ground beneath feels " .. scale(env.seismicStress or 0, { "settled", "uneasy", "strained", "close to breaking" }) .. "."
	elseif property.category == "Fluid" then
		local water = env.waterVolume or 0
		note = if water < 10 then "You sense almost no water here." elseif water < 2000 then "You sense water close by." else "You sense a great body of water."
	elseif property.category == "Thermal" then
		note = "The air feels " .. scale(env.temperature or 0.5, { "bitterly cold", "cool", "mild", "warm", "searing" }) .. "."
	elseif property.category == "Energetic" then
		note = "The sky feels " .. scale(env.stormCharge or 0, { "quiet", "restless", "charged", "ready to break" }) .. "."
	else
		note = "The ambient magic here is " .. scale(density / 3, { "almost dead", "thin", "steady", "rich", "overflowing" }) .. "."
	end
	return { effective = true, hits = 0, note = note }
end

return Sense
