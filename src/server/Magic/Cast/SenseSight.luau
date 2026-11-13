--!strict
--[[
	SenseSight: what a Sense spell lets the caster SEE (docs/SenseSight.md; numbers and words in
	Shared/Magic/Data/SenseSight, pure rules in Shared/Magic/SenseRules).

	Cast/Effects/Sense calls SenseSight.reveal(ctx, kind) for a property with a kind. The server
	gathers what is really there around the point, within the radius, and sends it to the caster
	alone (remote SenseReveal through the hooks SenseService sets). The client draws it for a while
	(Controllers/SenseController). Nothing is sent to anyone else, and nothing outside the radius.

		heat     bodies (people and beasts, through walls), fires (FireSim), lit lamps and hearths
		         (Interact/Lamps `Lit`), parts hotter than hotAt or colder than coldAt (ThermalSim
		         `Temperature`)
		metal    parts of a conducting metal (LightningRods.isMetal), people wearing metal
		         (LightningRods.metalWeight >= minWeight)
		ley      the ley lines of WorldStateService:magicMap() clipped to the circle, nexuses inside it
		tracks   the TrackStore SenseService fills (everyone's recent footprints), minus your own

	Payload (SenseReveal): { kind, center, radius, duration, bodies = { Model }, spots = { { p, s,
	cold } }, parts = { BasePart }, lines = { { a, b, d } }, nexuses = { { p, d, s } }, prints = {
	{ p, h, age, k } } }. Only the lists the kind uses are filled.

	Cost per reveal: at most one GetPartBoundsInRadius (caps.queryParts) and one Targeting.inRadius;
	ley: one segment test per ley line (36 in a world); tracks: the grid cells under the circle.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Data = require(Shared.Magic.Data.SenseSight)
local SenseRules = require(Shared.Magic.SenseRules)

local Cast = script.Parent
local CastTypes = require(Cast.CastTypes)
local Targeting = require(Cast.Targeting)
local FireSim = require(Cast.FireSim)
local LightningRods = require(Cast.LightningRods)

local SenseSight = {}

export type Hooks = {
	send: (Player, { [string]: any }) -> (),
	revealed: (Player, string, number) -> (), -- (player, kind, things shown): the Journal line
}

local hooks: Hooks? = nil
local tracks: SenseRules.TrackStore? = nil

function SenseSight.setHooks(h: Hooks)
	hooks = h
end

function SenseSight.setTracks(store: SenseRules.TrackStore)
	tracks = store
end

-- Parts around the point that aren't anyone's body.
local function worldParts(point: Vector3, radius: number): { BasePart }
	local params = OverlapParams.new()
	params.MaxParts = Data.caps.queryParts
	local out: { BasePart } = {}
	for _, part in workspace:GetPartBoundsInRadius(point, radius, params) do
		if not part:IsA("Terrain") and not Targeting.characterOf(part) then
			table.insert(out, part)
		end
	end
	table.sort(out, function(a, b)
		return (a.Position - point).Magnitude < (b.Position - point).Magnitude
	end)
	return out
end

local function gatherHeat(payload: { [string]: any }, point: Vector3, radius: number, caster: Model): number
	local caps = Data.caps
	local bodies: { Model } = {}
	for _, hit in Targeting.inRadius(point, radius, caps.bodies, { [caster] = true }) do
		table.insert(bodies, hit.model)
	end
	local spots: { { [string]: any } } = {}
	for _, fire in FireSim.firesNear(point, radius, caps.spots) do
		table.insert(spots, { p = fire.position, s = math.clamp(0.6 + 0.2 * fire.intensity, 0.6, 1) })
	end
	for _, part in worldParts(point, radius) do
		if #spots >= caps.spots then
			break
		end
		local temperature = part:GetAttribute("Temperature")
		if part:GetAttribute("Lit") == true then
			table.insert(spots, { p = part.Position, s = 0.7 })
		elseif typeof(temperature) == "number" and temperature >= Data.heat.hotAt then
			table.insert(spots, { p = part.Position, s = math.clamp(0.4 + (temperature - Data.heat.hotAt) / 200, 0.4, 1) })
		elseif typeof(temperature) == "number" and temperature <= Data.heat.coldAt then
			table.insert(spots, { p = part.Position, s = math.clamp(0.4 + (Data.heat.coldAt - temperature) / 60, 0.4, 1), cold = true })
		end
	end
	payload.bodies, payload.spots = bodies, spots
	return #bodies + #spots
end

local function gatherMetal(payload: { [string]: any }, point: Vector3, radius: number, caster: Model): number
	local caps = Data.caps
	local parts: { BasePart } = {}
	for _, part in worldParts(point, radius) do
		if #parts >= caps.metalParts then
			break
		end
		if LightningRods.isMetal(part) then
			table.insert(parts, part)
		end
	end
	local bodies: { Model } = {}
	for _, hit in Targeting.inRadius(point, radius, caps.bodies * 2, { [caster] = true }) do
		if #bodies >= caps.bodies then
			break
		end
		if LightningRods.metalWeight(hit.model) >= Data.metal.minWeight then
			table.insert(bodies, hit.model)
		end
	end
	payload.parts, payload.bodies = parts, bodies
	return #parts + #bodies
end

local function gatherLey(payload: { [string]: any }, point: Vector3, radius: number, world: any): number
	local map = world and world:magicMap()
	if not map then
		return 0
	end
	local lines: { { [string]: any } } = {}
	for _, line in map.lines do
		if #lines >= Data.caps.leyLines then
			break
		end
		local x1, z1, x2, z2 = SenseRules.clipSegment(line.a.x, line.a.z, line.b.x, line.b.z, point.X, point.Z, radius)
		if x1 and z1 and x2 and z2 then
			table.insert(lines, { a = Vector3.new(x1, 0, z1), b = Vector3.new(x2, 0, z2), d = line.domain })
		end
	end
	local nexuses: { { [string]: any } } = {}
	for _, nexus in map.nexuses do
		if #nexuses >= Data.caps.nexuses then
			break
		end
		if (Vector2.new(nexus.x, nexus.z) - Vector2.new(point.X, point.Z)).Magnitude <= radius then
			table.insert(nexuses, { p = Vector3.new(nexus.x, 0, nexus.z), d = nexus.domain, s = nexus.strength })
		end
	end
	payload.lines, payload.nexuses = lines, nexuses
	return #lines + #nexuses
end

local function gatherTracks(payload: { [string]: any }, point: Vector3, radius: number, casterKey: string): number
	local store = tracks
	if not store then
		return 0
	end
	local now = workspace:GetServerTimeNow()
	local prints: { { [string]: any } } = {}
	for _, p in store:query(point, radius, now, casterKey, Data.caps.prints) do
		table.insert(prints, { p = Vector3.new(p.x, p.y, p.z), h = p.heading, age = now - p.t, k = p.kind })
	end
	payload.prints = prints
	return #prints
end

--[[
	Shows `kind` to `player` around `point`. Returns (things shown, the line for the caster).
	Used by the Sense resolver and by the admin command `sensesight`.
]]
function SenseSight.revealAt(player: Player, caster: Model, point: Vector3, kind: string, power: number, area: number?, world: any): (number, string)
	local def = Data.kinds[kind]
	if not def then
		return 0, ""
	end
	local radius = SenseRules.radiusFor(power, area)
	local payload: { [string]: any } = {
		kind = kind,
		center = point,
		radius = radius,
		duration = SenseRules.durationFor(power),
	}
	local count = 0
	if kind == "heat" then
		count = gatherHeat(payload, point, radius, caster)
	elseif kind == "metal" then
		count = gatherMetal(payload, point, radius, caster)
	elseif kind == "ley" then
		count = gatherLey(payload, point, radius, world)
	elseif kind == "tracks" then
		count = gatherTracks(payload, point, radius, "p" .. player.UserId)
	end
	local h = hooks
	if h then
		h.send(player, payload)
		h.revealed(player, kind, count)
	end
	return count, if count > 0 then def.found else def.empty
end

-- The Sense resolver's entry point.
function SenseSight.reveal(ctx: CastTypes.EffectContext, kind: string): (number, string)
	return SenseSight.revealAt(ctx.player, ctx.character, ctx.point, kind, ctx.power, ctx.stats.area, ctx.world)
end

return SenseSight
