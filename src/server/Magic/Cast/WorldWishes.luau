--!strict
--[[
	WorldWishes: Reality's Conjuration rewriting the world where it lands (docs/Reality.md "World
	wishes"; owner, 2026-11-13: "a genie that can do whatever they want to the world"). Called by
	Effects/RealityPower. The recipe's `wish` (Shared/Magic/Wishes) says what.

		WorldWishes.remake(ctx) -> (ops, note?)       the ground becomes the wished material
		WorldWishes.remakeRefusal(userId) -> string?  before payment: the per-caster cooldown
		WorldWishes.things(ctx) -> (made, note?)      wished things appear for a while

	REMAKE (transmute): a near-round area (three overlapping boxes, an octagon) of every natural
	ground material becomes the wish's, from a little above the surface to `depth` below it.
	Only materials actually found there are rewritten (sampled with rays), so a cast is a dozen
	ops or so. It's PERSISTENT: TerrainDeform.commit -> WorldStateService:edit, replayed by every
	server. Hence the guards: never inside or touching a town (settlementAt at the centre and the
	rim), Granite (magic stone) is never a source, ops come from EffectBudget, and a cooldown per
	caster. Anyone the new ground fills around is lifted out (WorldStateService:edit ->
	CharacterSafety.checkArea).

	THINGS (amplify): anchored parts made for a while (trees, floating lights, crystal spires,
	boulders), a spring of water (TerrainDeform.pour, temporary), or a field of fire
	(FireSim.igniteGround, unsaved: the scorch it leaves isn't kept). Every part is charged to
	EffectBudget.takeParts; they fade and go when their time is up. Seeded by the cast's rng.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Wishes = require(Shared.Magic.Wishes)
local WishData = require(Shared.Magic.Data.Wishes)
local R = require(Shared.Magic.Data.RealityTuning)

local Cast = script.Parent
local Server = Cast.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local EffectBudget = require(Cast.EffectBudget)
local FireSim = require(Cast.FireSim)
local TerrainDeform = require(Server.World.TerrainDeform)

type Ctx = CastTypes.EffectContext

local WorldWishes = {}

-- Set by Services/RealityService: (event, fields) for the log.
WorldWishes.onEvent = nil :: ((string, { [string]: any }) -> ())?

local readyAt: { [number]: number } = {}
local folder: Folder? = nil

local function emit(event: string, fields: { [string]: any })
	local fn = WorldWishes.onEvent
	if fn then
		fn(event, fields)
	end
end

local function tierOf(ctx: Ctx): number
	return math.clamp(math.floor(math.max(1, ctx.stats.masteryTier or 1)), 1, 8)
end

local function folderOf(): Folder
	if folder and folder.Parent then
		return folder
	end
	local made = Instance.new("Folder")
	made.Name = "Wishes"
	made.Parent = workspace
	folder = made
	return made
end

local function groundParams(): RaycastParams
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local list: { Instance } = { folderOf() }
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(list, player.Character)
		end
	end
	local elementals = workspace:FindFirstChild("Elementals")
	if elementals then
		table.insert(list, elementals)
	end
	params.FilterDescendantsInstances = list
	return params
end

local function groundAt(x: number, z: number, nearY: number, params: RaycastParams): RaycastResult?
	return workspace:Raycast(Vector3.new(x, nearY + 40, z), Vector3.new(0, -120, 0), params)
end

-- ─── Remake the land ────────────────────────────────────────────────────────

function WorldWishes.remakeRefusal(userId: number): string?
	if os.clock() < (readyAt[userId] or 0) then
		return "REALITY_COOLDOWN"
	end
	return nil
end

local function touchesTown(world: any, center: Vector3, radius: number): boolean
	for i = 0, 8 do
		local offset = if i == 0 then Vector3.zero else Vector3.new(math.sin(i * math.pi / 4) * radius, 0, math.cos(i * math.pi / 4) * radius)
		local p = center + offset
		if world:settlementAt(p.X, p.Z) ~= nil then
			return true
		end
	end
	return false
end

function WorldWishes.remake(ctx: Ctx): (number, string?)
	local recipe: any = ctx.stats.recipe
	local wishId = if recipe.wish and Wishes.land(recipe.wish) then recipe.wish else WishData.landDefault
	local land = Wishes.land(wishId) :: { name: string, material: string }
	local tier = tierOf(ctx)
	local radius = Wishes.remakeRadius(recipe.power, tier)
	local center = ctx.point
	if touchesTown(ctx.world, center, radius) then
		return 0, "The town's ground holds its shape against you."
	end

	-- Which ground materials are actually here (a 5x5 grid of rays, water included).
	local params = groundParams()
	params.IgnoreWater = false
	local present: { [string]: boolean } = {}
	local top = -math.huge
	for gx = -2, 2 do
		for gz = -2, 2 do
			local x, z = center.X + gx * radius * 0.4, center.Z + gz * radius * 0.4
			local hit = groundAt(x, z, center.Y, params)
			if hit and hit.Instance == workspace.Terrain then
				present[hit.Material.Name] = true
				top = math.max(top, hit.Position.Y)
			end
		end
	end
	local surface = TerrainDeform.surfaceAt(ctx.world, center.X, center.Z)
	if top == -math.huge then
		top = surface
	end
	local sources: { string } = {}
	for _, name in WishData.landSources do
		-- Underground the sampled materials, plus the usual soil under them.
		if (present[name] or name == "Ground" or name == "Rock") and name ~= land.material then
			table.insert(sources, name)
		end
	end
	if #sources == 0 then
		return 0, "It's already " .. land.name .. "."
	end

	local water = land.material == "Water"
	local depth = if water then R.remake.waterDepth else R.remake.depth
	local ceiling = if water then math.max(surface, center.Y) + 1 else top + 2
	local floor = math.min(surface, center.Y) - depth
	local sy = math.max(4, ceiling - floor)
	local cy = (ceiling + floor) / 2
	local boxes = {
		{ sx = radius * 2, sz = radius * 1.2 },
		{ sx = radius * 1.2, sz = radius * 2 },
		{ sx = radius * 1.7, sz = radius * 1.7 },
	}
	local wanted = #boxes * #sources
	local granted = EffectBudget.takeTerrainOps(wanted)
	if granted < #sources then
		return 0, "The world won't hold any more of that right now."
	end
	local ops: { any } = {}
	for _, box in boxes do
		for _, source in sources do
			if #ops >= granted then
				break
			end
			table.insert(ops, { k = "replace", f = source, m = land.material, x = center.X, y = cy, z = center.Z, sx = box.sx, sy = sy, sz = box.sz })
		end
	end
	local applied = TerrainDeform.commit(ctx.world, "wish", ops)
	readyAt[ctx.player.UserId] = os.clock() + R.remake.cooldown[tier]
	emit("wish_remade", {
		userId = ctx.player.UserId,
		land = wishId,
		radius = math.floor(radius),
		ops = applied,
		x = math.floor(center.X),
		z = math.floor(center.Z),
	})
	return applied, nil
end

-- ─── Conjure things ─────────────────────────────────────────────────────────

local function makePart(props: { [string]: any }): Part
	local part = Instance.new("Part")
	part.Anchored = true
	part.CastShadow = true
	part.TopSurface = Enum.SurfaceType.Smooth
	part.BottomSurface = Enum.SurfaceType.Smooth
	for key, value in props do
		(part :: any)[key] = value
	end
	part:SetAttribute("ConjuredWish", true)
	return part
end

local function fadeLater(parts: { BasePart }, seconds: number)
	task.delay(seconds, function()
		for _, part in parts do
			if part.Parent then
				part.CanCollide = false
				TweenService:Create(part, TweenInfo.new(1.2), { Transparency = 1 }):Play()
				for _, light in part:GetChildren() do
					if light:IsA("PointLight") then
						TweenService:Create(light, TweenInfo.new(1.2), { Brightness = 0 }):Play()
					end
				end
			end
		end
		task.wait(1.3)
		for _, part in parts do
			part:Destroy()
		end
	end)
end

-- Spots on the ground spread over the area (seeded), with the ray that found each.
local function spots(ctx: Ctx, count: number, radius: number): { RaycastResult }
	local params = groundParams()
	local out: { RaycastResult } = {}
	for _ = 1, count * 2 do
		if #out >= count then
			break
		end
		local angle = ctx.rng:NextNumber() * math.pi * 2
		local distance = math.sqrt(ctx.rng:NextNumber()) * radius
		local hit = groundAt(ctx.point.X + math.sin(angle) * distance, ctx.point.Z + math.cos(angle) * distance, ctx.point.Y, params)
		if hit then
			table.insert(out, hit)
		end
	end
	return out
end

type Builder = (ctx: Ctx, hit: RaycastResult, add: (BasePart) -> ()) -> ()

local BUILDERS: { [string]: Builder } = {
	forest = function(ctx, hit, add)
		local height = 10 + ctx.rng:NextNumber() * 10
		local girth = 1.4 + height * 0.06
		local base = hit.Position
		add(makePart({
			Name = "WishTrunk",
			Shape = Enum.PartType.Cylinder,
			Size = Vector3.new(height, girth, girth),
			CFrame = CFrame.new(base + Vector3.new(0, height / 2 - 0.5, 0)) * CFrame.Angles(0, 0, math.rad(90)),
			Material = Enum.Material.Wood,
			Color = Color3.fromRGB(105, 72, 46),
		}))
		local crown = height * 0.55
		for i = 1, 2 do
			local size = crown * (if i == 1 then 1 else 0.7)
			local part = makePart({
				Name = "WishCanopy",
				Shape = Enum.PartType.Ball,
				Size = Vector3.new(size, size, size),
				CFrame = CFrame.new(base + Vector3.new((i - 1.5) * 1.2, height - 0.5 + (i - 1) * crown * 0.35, 0)),
				Material = Enum.Material.LeafyGrass,
				Color = Color3.fromRGB(62, 120 + math.floor(ctx.rng:NextNumber() * 30), 52),
				CanCollide = false,
			})
			part:SetAttribute("Flammability", 0.7)
			add(part)
		end
	end,
	lights = function(ctx, hit, add)
		local part = makePart({
			Name = "WishLight",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(1.3, 1.3, 1.3),
			CFrame = CFrame.new(hit.Position + Vector3.new(0, 5 + ctx.rng:NextNumber() * 6, 0)),
			Material = Enum.Material.Neon,
			Color = Color3.fromRGB(255, 226, 160),
			CanCollide = false,
			CanQuery = false,
			CastShadow = false,
		})
		local light = Instance.new("PointLight")
		light.Range = 18
		light.Brightness = 1.4
		light.Color = part.Color
		light.Parent = part
		add(part)
		TweenService:Create(part, TweenInfo.new(2 + ctx.rng:NextNumber() * 2, Enum.EasingStyle.Sine, Enum.EasingDirection.InOut, -1, true), {
			CFrame = part.CFrame + Vector3.new(0, 1.5, 0),
		}):Play()
	end,
	crystals = function(ctx, hit, add)
		local height = 6 + ctx.rng:NextNumber() * 12
		local width = 1.6 + height * 0.12
		local tilt = CFrame.Angles(math.rad(ctx.rng:NextNumber() * 24 - 12), ctx.rng:NextNumber() * math.pi, math.rad(ctx.rng:NextNumber() * 24 - 12))
		local part = makePart({
			Name = "WishCrystal",
			Size = Vector3.new(width, height, width),
			CFrame = CFrame.new(hit.Position + Vector3.new(0, height / 2 - 1, 0)) * tilt,
			Material = Enum.Material.Glass,
			Transparency = 0.2,
			Color = Color3.fromRGB(150, 120 + math.floor(ctx.rng:NextNumber() * 60), 235),
		})
		local light = Instance.new("PointLight")
		light.Range = 10
		light.Brightness = 0.6
		light.Color = part.Color
		light.Parent = part
		add(part)
	end,
	boulders = function(ctx, hit, add)
		local size = 4 + ctx.rng:NextNumber() * 6
		add(makePart({
			Name = "WishBoulder",
			Shape = Enum.PartType.Ball,
			Size = Vector3.new(size, size * 0.8, size),
			CFrame = CFrame.new(hit.Position + Vector3.new(0, size * 0.3, 0)) * CFrame.Angles(0, ctx.rng:NextNumber() * math.pi, 0),
			Material = Enum.Material.Rock,
			Color = Color3.fromRGB(110, 106, 100),
		}))
	end,
}

local PARTS_EACH: { [string]: number } = { forest = 3, lights = 1, crystals = 1, boulders = 1 }

function WorldWishes.things(ctx: Ctx): (number, string?)
	local recipe: any = ctx.stats.recipe
	local wishId = if recipe.wish and Wishes.thing(recipe.wish) then recipe.wish else WishData.thingDefault
	local tier = tierOf(ctx)
	local T = R.things
	local radius = T.radius[tier]
	local seconds = T.seconds[tier]
	local made = 0

	if wishId == "fire" then
		for _, hit in spots(ctx, T.fires[tier], radius) do
			if FireSim.igniteGround(hit.Position, 0.8, ctx.player.UserId, true) then
				made += 1
			end
		end
	elseif wishId == "spring" then
		local hit = groundAt(ctx.point.X, ctx.point.Z, ctx.point.Y, groundParams())
		local at = if hit then hit.Position else ctx.point
		if TerrainDeform.pour(ctx.world, at + Vector3.new(0, 1, 0), math.clamp(radius * 0.4, 4, 12), seconds) then
			made = 1
		end
	else
		local builder = BUILDERS[wishId]
		local each = PARTS_EACH[wishId] or 1
		local count = T.count[tier] * (if wishId == "lights" then 2 else 1)
		count = math.min(count, math.floor(T.maxParts / each))
		local granted = math.floor(EffectBudget.takeParts(count * each) / each)
		if granted <= 0 then
			return 0, "The world won't hold any more of that right now."
		end
		local parts: { BasePart } = {}
		local parent = folderOf()
		local function add(part: BasePart)
			part.Parent = parent
			table.insert(parts, part)
		end
		for _, hit in spots(ctx, granted, radius) do
			builder(ctx, hit, add)
			made += 1
		end
		fadeLater(parts, seconds)
	end
	if made == 0 then
		return 0, "Nothing took hold there."
	end
	emit("wish_conjured", { userId = ctx.player.UserId, thing = wishId, made = made, seconds = seconds })
	return made, nil
end

function WorldWishes.clear(): number
	local n = 0
	local f = workspace:FindFirstChild("Wishes")
	if f then
		n = #f:GetChildren()
		f:ClearAllChildren()
	end
	return n
end

return WorldWishes
