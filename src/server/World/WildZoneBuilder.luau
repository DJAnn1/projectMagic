--!strict
--[[
	WildZoneBuilder: a zone's landmarks, seeded, so it looks the same on every server (docs/WildZones.md).
	It only builds; Services/WildZoneService decides when, and puts the prompt on the heart.

		build(zone, seed, heightAt) -> (Model, BasePart)   the model, parented, and its heart

	STRUCTURE  Everything is anchored and tagged NoMagicEdit, and won't burn, so spells can't move or phase
	           it, and the Vale's stepping stones can't be taken away from under you.
	HEIGHTS    Read from the generator, so it doesn't matter whether every chunk under it is built yet.
	BUDGET     About 15 to 30 parts a zone, only while someone is near. At most a few zones are awake at once.
]]

local CollectionService = game:GetService("CollectionService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Seed = require(Shared.Magic.Seed)

local Rules = require(script.Parent.WildZoneRules)
local C = require(script.Parent.WorldConfig)

local rgb = Color3.fromRGB
local M = Enum.Material

local WildZoneBuilder = {}

type Ctx = {
	model: Model,
	zone: Rules.Placed,
	rng: Random,
	heightAt: (number, number) -> number,
}

local function part(ctx: Ctx, name: string, size: Vector3, cframe: CFrame, color: Color3, material: Enum.Material, solid: boolean): Part
	local p = Instance.new("Part")
	p.Name = name
	p.Size = size
	p.CFrame = cframe
	p.Color = color
	p.Material = material
	p.Anchored = true
	p.CanCollide = solid
	p.CanQuery = solid
	p.CanTouch = false
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	p:SetAttribute("Flammability", 0)
	CollectionService:AddTag(p, "NoMagicEdit")
	p.Parent = ctx.model
	return p
end

-- A seeded spot inside the zone, between these shares of its radius, and the ground there.
local function spot(ctx: Ctx, from: number, to: number): (number, number, number)
	local angle = ctx.rng:NextNumber() * 2 * math.pi
	local distance = ctx.zone.def.radius * (from + ctx.rng:NextNumber() * (to - from))
	local x, z = ctx.zone.x + math.cos(angle) * distance, ctx.zone.z + math.sin(angle) * distance
	return x, ctx.heightAt(x, z), z
end

local function vale(ctx: Ctx, ground: number)
	-- Stepping stones spiralling up to the heart. At 30% gravity a jump clears about 20 studs up and
	-- about 25 across. These rise 11 at a time with gaps of about 10, so it's a climb, not a test.
	local lift = ctx.zone.def.heartLift or 0
	local steps = 4
	for i = 1, steps do
		local angle = i * 1.1
		local reach = 30 - i * 4
		local at = Vector3.new(ctx.zone.x + math.cos(angle) * reach, ground + lift * (i / steps) - 3, ctx.zone.z + math.sin(angle) * reach)
		part(ctx, "Stone", Vector3.new(14, 2.5, 14), CFrame.new(at), rgb(120, 125, 140), M.Slate, true)
	end
	-- And loose stones hanging over the whole valley.
	for _ = 1, 14 do
		local x, y, z = spot(ctx, 0.3, 0.95)
		local size = 4 + ctx.rng:NextNumber() * 12
		local spin = CFrame.Angles(ctx.rng:NextNumber(), ctx.rng:NextNumber() * 6, ctx.rng:NextNumber())
		part(ctx, "Drifter", Vector3.new(size, size * 0.5, size * 0.8), CFrame.new(x, y + 10 + ctx.rng:NextNumber() * 50, z) * spin, rgb(130, 135, 150), M.Slate, true)
	end
end

local function wood(ctx: Ctx)
	for _ = 1, 9 do
		local x, y, z = spot(ctx, 0.2, 0.95)
		local height = 26 + ctx.rng:NextNumber() * 14
		part(ctx, "Trunk", Vector3.new(4, height, 4), CFrame.new(x, y + height / 2 - 1, z), rgb(66, 54, 42), M.Wood, true)
	end
	-- Leaves that stopped falling.
	for _ = 1, 16 do
		local x, y, z = spot(ctx, 0.05, 0.95)
		local spin = CFrame.Angles(ctx.rng:NextNumber() * 3, ctx.rng:NextNumber() * 3, 0)
		part(ctx, "StillLeaf", Vector3.new(1.4, 0.12, 1), CFrame.new(x, y + 3 + ctx.rng:NextNumber() * 14, z) * spin, rgb(200, 210, 120), M.Neon, false)
	end
end

local function shore(ctx: Ctx)
	local placed = 0
	for _ = 1, 40 do
		if placed >= 12 then
			break
		end
		local x, y, z = spot(ctx, 0.1, 1)
		if y < C.SEA_LEVEL then
			local flame = part(ctx, "SeaFire", Vector3.new(10, 1, 10), CFrame.new(x, C.SEA_LEVEL + 0.5, z), rgb(255, 120, 40), M.Neon, false)
			flame.Transparency = 1
			local fire = Instance.new("Fire")
			fire.Size = 10 + ctx.rng:NextNumber() * 6
			fire.Heat = 14
			fire.Parent = flame
			placed += 1
		end
	end
	for _ = 1, 7 do
		local x, y, z = spot(ctx, 0.05, 0.6)
		if y >= C.SEA_LEVEL then
			local height = 6 + ctx.rng:NextNumber() * 8
			part(ctx, "Burned", Vector3.new(2, height, 2), CFrame.new(x, y + height / 2 - 1, z), rgb(30, 24, 22), M.Basalt, true)
		end
	end
end

local function moor(ctx: Ctx)
	for _ = 1, 12 do
		local x, y, z = spot(ctx, 0.1, 0.95)
		local spin = CFrame.Angles(ctx.rng:NextNumber() * 0.9, ctx.rng:NextNumber() * 6, ctx.rng:NextNumber() * 0.9)
		local size = Vector3.new(6 + ctx.rng:NextNumber() * 8, 1.6, 4 + ctx.rng:NextNumber() * 6)
		part(ctx, "Slab", size, CFrame.new(x, y + 2 + ctx.rng:NextNumber() * 10, z) * spin, rgb(104, 96, 118), M.Slate, true)
	end
end

local function hollow(ctx: Ctx)
	for _ = 1, 9 do
		local x, y, z = spot(ctx, 0.15, 0.95)
		local height = 16 + ctx.rng:NextNumber() * 16
		part(ctx, "Silence", Vector3.new(4, height, 4), CFrame.new(x, y + height / 2 - 1, z) * CFrame.Angles(0, ctx.rng:NextNumber() * 3, 0), rgb(16, 16, 22), M.Basalt, true)
	end
end

local function riot(ctx: Ctx)
	for _ = 1, 12 do
		local x, y, z = spot(ctx, 0.1, 0.95)
		local height = 10 + ctx.rng:NextNumber() * 22
		part(ctx, "Stalk", Vector3.new(2, height, 2), CFrame.new(x, y + height / 2 - 1, z), rgb(60, 130, 60), M.Grass, true)
		local bloom = 7 + ctx.rng:NextNumber() * 8
		local head = part(ctx, "Bloom", Vector3.new(bloom, bloom * 0.45, bloom), CFrame.new(x, y + height, z), ctx.zone.def.color:Lerp(rgb(255, 220, 240), ctx.rng:NextNumber()), M.SmoothPlastic, true)
		local mesh = Instance.new("SpecialMesh")
		mesh.MeshType = Enum.MeshType.Sphere
		mesh.Parent = head
	end
end

function WildZoneBuilder.build(zone: Rules.Placed, worldSeed: number, heightAt: (number, number) -> number): (Model, BasePart)
	local model = Instance.new("Model")
	model.Name = "WildZone_" .. zone.id
	local ctx: Ctx = { model = model, zone = zone, rng = Seed.random(worldSeed, "wild_zone:" .. zone.id, "decor"), heightAt = heightAt }
	local def = zone.def
	local ground = math.max(heightAt(zone.x, zone.z), C.SEA_LEVEL)

	local kind = def.decor
	if kind == "vale" then
		vale(ctx, ground)
	elseif kind == "wood" then
		wood(ctx)
	elseif kind == "shore" then
		shore(ctx)
	elseif kind == "moor" then
		moor(ctx)
	elseif kind == "hollow" then
		hollow(ctx)
	else
		riot(ctx)
	end

	-- The heart: what you came for.
	local lift = def.heartLift or 0
	local heart = part(ctx, "Heart", Vector3.new(5, 5, 5), CFrame.new(zone.x, ground + lift + 5, zone.z), def.color, M.Neon, false)
	heart.Shape = Enum.PartType.Ball -- not solid: it never blocks a shot or a step
	local glow = Instance.new("PointLight")
	glow.Color = def.color
	glow.Range = 34
	glow.Brightness = 1.6
	glow.Shadows = false
	glow.Parent = heart
	local motes = Instance.new("ParticleEmitter")
	motes.Color = ColorSequence.new(def.color)
	motes.Rate = 10
	motes.Lifetime = NumberRange.new(1, 2)
	motes.Speed = NumberRange.new(1, 4)
	motes.SpreadAngle = Vector2.new(180, 180)
	motes.Size = NumberSequence.new(0.5, 0)
	motes.LightEmission = 0.8
	motes.Parent = heart
	if lift == 0 then
		part(ctx, "HeartStone", Vector3.new(9, 2, 9), CFrame.new(zone.x, ground + 1, zone.z), rgb(58, 54, 66), M.Slate, true)
	end

	model.PrimaryPart = heart
	model.Parent = workspace
	return model, heart
end

return WildZoneBuilder
