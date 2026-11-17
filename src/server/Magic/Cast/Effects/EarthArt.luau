--!strict
--[[
	EarthArt: Earth's own spells (docs/DomainIdeas.md, "Earth"). Ordinary moves that fit their branch,
	each reached by a narrow route in Data/EffectLibrary ("earth_" .. move, with params.move). Numbers:
	Data/EarthTuning. Anything that lasts runs in Cast/ArtRuntime; looks in Client/Fx/EarthFx (cue kind
	"earth", bodies drawn through Fx/ArtFx).

	Stone (Lithomancy, Architectonics)
		stone_fist     a fist of rock tears out of the ground and flies, knocking its target back
		gravel_burst   the ground under the target bursts into flying stones, throwing people up
		spike_trail    stone spikes erupt one after another toward the target; they stand a while and block
		stone_step     a column pushes you up onto a ledge or roof, and stays a while
		stone_grip     stone climbs someone's legs and holds them until it cracks off
		ramp           a sloped stone ramp rises where you point (climb it, or run off it)
		boulder        a boulder that lands and rolls on, bowling people over
	Metal (Ferromancy, Alloycraft)
		iron_storm     metal shavings whirl in an area and cut; worse for anyone in metal, who's dragged in
		blade_rain     iron blades fall on marked spots
		quicksilver_lash  liquid metal whips out in an arc and drags whoever it catches toward you
	Crystal (Crystallurgy, Focuscraft)
		crystal_spires crystals burst up (hurting), stand and block, then shatter
		singing_shard  a shard sticks in its target and rings, hurting again with each pulse
		crystal_prison the target is encased in crystal for a moment
		geode_shell    crystal plates grow over you: a ward that chips away as it's hit
	Seismic (Faultwork)
		fissure        a crack runs along the ground toward the target, knocking down everyone on it
		ground_ripple  a wave runs out through the ground, throwing people up as it passes
	Sand (Sandshaping, Dunecalling)
		sand_blast     a cone of sand that blinds and pushes
		dust_cloud     dust hangs over an area, blinding foes in it
		quicksand      soft ground: slows, and holds anyone who stays in it too long
		dust_devil     a small sand whirlwind that wanders after people, blinding and stinging
		sand_shroud    whirling sand hides you at range and stings anyone close

	Stone that stands is a real anchored part (Slate, Glass for crystal): it blocks and can be stood on,
	never spawns solid inside someone (it waits, or stays passable), and crumbles at the end. Parts come
	from EffectBudget.takeParts. A backfire lands on the caster as any harmful spell's does.
]]

local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Types = require(Shared.Magic.Types)
local E = require(Shared.Magic.Data.EarthTuning)

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local DamageModel = require(Cast.DamageModel)
local EffectBudget = require(Cast.EffectBudget)
local LightningRods = require(Cast.LightningRods)
local Resistances = require(Cast.Resistances)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local R = require(Cast.ArtRuntime)

type Ctx = CastTypes.EffectContext
type Outcome = CastTypes.Outcome
type Hit = Targeting.Hit

local UP = Vector3.new(0, 1, 0)
local L = E.looks

local EarthArt = {}

function EarthArt.precheck(_params: { [string]: any }, _stats: Types.SpellStats, _player: Player): string?
	if FeatureFlags.get("earth_arts_enabled") == false then
		return "WORLD_STRAINED"
	end
	if R.count() >= R.caps.server then
		return "WORLD_STRAINED"
	end
	return nil
end

-- ─── Helpers ────────────────────────────────────────────────────────────────

local function at(curve: E.Curve, ctx: Ctx): number
	return E.at(curve, ctx.stats.recipe.power)
end

local function flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 0.01 then f.Unit else Vector3.new(0, 0, -1)
end

local function aimDir(ctx: Ctx): Vector3
	local d = ctx.point - ctx.origin
	if Vector3.new(d.X, 0, d.Z).Magnitude < 0.5 then
		return flat(ctx.root.CFrame.LookVector)
	end
	return flat(d)
end

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude

local function ground(position: Vector3): Vector3
	local ignore: { Instance } = {}
	local folder = workspace:FindFirstChild("ArtBodies")
	if folder then
		table.insert(ignore, folder)
	end
	local stone = workspace:FindFirstChild("ArtStone")
	if stone then
		table.insert(ignore, stone)
	end
	for _, player in Players:GetPlayers() do
		if player.Character then
			table.insert(ignore, player.Character)
		end
	end
	groundParams.FilterDescendantsInstances = ignore
	local result = workspace:Raycast(position + Vector3.new(0, 12, 0), Vector3.new(0, -40, 0), groundParams)
	return if result then result.Position else position
end

local function foesStruck(ctx: Ctx, max: number?): { Hit }
	local out: { Hit } = {}
	for _, hit in Targeting.select(ctx, max) do
		if hit.model ~= ctx.character and Targeting.canHarm(ctx.player, hit.model) then
			table.insert(out, hit)
		end
	end
	return out
end

local function cue(ctx: Ctx, fields: { [string]: any }, position: Vector3, heavy: boolean?)
	R.cue(ctx, fields, position, heavy, "earth")
end

local function isPlayer(hit: Hit): boolean
	return Players:GetPlayerFromCharacter(hit.model) ~= nil
end

local function stoneFolder(): Folder
	local f = workspace:FindFirstChild("ArtStone")
	if f and f:IsA("Folder") then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "ArtStone"
	made.Parent = workspace
	return made
end

-- Is anyone standing where a solid part would go? (It must never close round a body.)
local function bodyInside(cframe: CFrame, size: Vector3): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { stoneFolder() }
	for _, part in workspace:GetPartBoundsInBox(cframe, size + Vector3.new(0.6, 0.6, 0.6), params) do
		if Targeting.characterOf(part) then
			return true
		end
	end
	return false
end

-- A real piece of stone: anchored, blocks and holds weight, unless someone stands where it rises.
-- Crumbles (a quick sink and fade) after `seconds`. Nil when the part budget is spent.
local function raiseStone(props: { [string]: any }, seconds: number): Part?
	if EffectBudget.takeParts(1) < 1 then
		return nil
	end
	local p = Instance.new("Part")
	p.Name = "EarthStone"
	p.Anchored = true
	p.CanQuery = true
	p.CanTouch = false
	p.Material = Enum.Material.Slate
	p.Color = L.stone
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.CanCollide = props.CanCollide ~= false and not bodyInside(p.CFrame, p.Size)
	p.Parent = stoneFolder()
	task.delay(seconds, function()
		if not p.Parent then
			return
		end
		p.CanCollide = false
		local tween = TweenService:Create(p, TweenInfo.new(0.6, Enum.EasingStyle.Quad, Enum.EasingDirection.In), {
			CFrame = p.CFrame - Vector3.new(0, p.Size.Y * 0.6, 0),
			Transparency = 1,
		})
		tween:Play()
		task.delay(0.65, function()
			p:Destroy()
		end)
	end)
	return p
end

local function cone(ctx: Ctx, reach: number, arc: number, max: number): { Hit }
	local out: { Hit } = {}
	for _, hit in Targeting.inCone(ctx.origin, aimDir(ctx), reach, arc / 2, max, { [ctx.character] = true }) do
		if Targeting.canHarm(ctx.player, hit.model) then
			table.insert(out, hit)
		end
	end
	return out
end

-- ─── Stone ──────────────────────────────────────────────────────────────────

local function stoneFist(ctx: Ctx): Outcome
	local T = E.stone_fist
	local target = foesStruck(ctx, 1)[1]
	local skip: { [Model]: boolean } = {}
	local hits = 0
	local dir = aimDir(ctx)
	if target then
		R.hit(ctx, target, T.share)
		R.push(target, dir * T.knock + UP * 12)
		skip[target.model] = true
		hits += 1
	end
	local spot = if target then target.root.Position else ctx.point
	for _, hit in R.foesAround(ctx, spot, T.splash, skip) do
		R.hit(ctx, hit, T.splashShare)
		hits += 1
	end
	cue(ctx, { fx = "rubble", at = spot, radius = T.splash }, spot)
	return { effective = hits > 0, hits = hits }
end

local function gravelBurst(ctx: Ctx): Outcome
	local T = E.gravel_burst
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 16))
	local center = ground(ctx.point)
	local hits = 0
	for _, hit in R.foesAround(ctx, center, radius) do
		R.hit(ctx, hit, T.share, nil, {})
		R.push(hit, UP * T.lift + flat(hit.root.Position - center) * 8)
		hits += 1
	end
	cue(ctx, { fx = "gravel", at = center, radius = radius }, center, true)
	return { effective = true, hits = hits }
end

local function spikeTrail(ctx: Ctx): Outcome
	local T = E.spike_trail
	local dir = aimDir(ctx)
	local length = at(T.length, ctx)
	local spots: { Vector3 } = {}
	for d = T.step, length, T.step do
		table.insert(spots, ground(ctx.origin + dir * d))
	end
	local c = R.later(ctx)
	local seen: { [Model]: boolean } = {}
	task.spawn(function()
		for i, spot in spots do
			task.wait(T.stepDelay)
			if not R.alive(c) then
				return
			end
			for _, hit in R.foesAround(c, spot, T.radius, seen) do
				seen[hit.model] = true
				R.hit(c, hit, T.share)
				R.push(hit, UP * T.lift)
			end
			-- The spike itself: tilted a little, standing a while. Passable where someone was.
			local height = 4 + (i % 3) * 1.2
			local tilt = CFrame.Angles(c.rng:NextNumber(-0.2, 0.2), c.rng:NextNumber(0, math.pi), c.rng:NextNumber(-0.2, 0.2))
			raiseStone({
				Size = Vector3.new(1.8, height, 1.8),
				CFrame = CFrame.new(spot + UP * (height / 2 - 0.4)) * tilt,
				Color = if i % 2 == 0 then L.stone else L.stoneDark,
			}, T.stays)
		end
	end)
	cue(ctx, { fx = "spikes", spots = spots, delay = T.stepDelay }, ctx.origin, true)
	return { effective = true, hits = 0 }
end

local function stoneStep(ctx: Ctx): Outcome
	local T = E.stone_step
	local height = at(T.height, ctx)
	local base = ground(ctx.origin)
	local column = raiseStone({
		Size = Vector3.new(T.width, 0.4, T.width),
		CFrame = CFrame.new(base),
		CanCollide = false, -- it grows under you, solid once it's up
	}, at(T.seconds, ctx))
	if not column then
		return { effective = false, hits = 0, note = "The ground won't answer here." }
	end
	local character = ctx.character
	local root = ctx.root
	local steps = 8
	task.spawn(function()
		for i = 1, steps do
			if not column.Parent then
				return
			end
			local h = height * i / steps
			column.Size = Vector3.new(T.width, h, T.width)
			column.CFrame = CFrame.new(base + UP * (h / 2))
			-- Lift whoever stands on it (only the caster: it rises under you).
			if character.Parent and (Vector3.new(root.Position.X - base.X, 0, root.Position.Z - base.Z)).Magnitude < T.width then
				local feet = root.Position.Y - 3
				if feet < base.Y + h then
					character:PivotTo(character:GetPivot() + UP * (base.Y + h - feet + 0.1))
				end
			end
			task.wait(0.04)
		end
		column.CanCollide = true
	end)
	cue(ctx, { fx = "rubble", at = base, radius = 3 }, base)
	return { effective = true, hits = 0, note = "A column of stone lifts you." }
end

local function stoneGrip(ctx: Ctx): Outcome
	local T = E.stone_grip
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0, note = "Stone rises, and closes on nothing." }
	end
	local seconds = at(T.seconds, ctx)
	if isPlayer(target) then
		seconds = math.min(seconds, T.pvpSeconds)
	end
	R.hit(ctx, target, T.share)
	R.status(ctx, target.humanoid, "root", seconds)
	cue(ctx, { fx = "grip", model = target.model, seconds = seconds }, target.root.Position)
	return { effective = true, hits = 1 }
end

local function ramp(ctx: Ctx): Outcome
	local T = E.ramp
	local length, rise = at(T.length, ctx), at(T.rise, ctx)
	local dir = aimDir(ctx)
	local start = ground(ctx.point)
	local center = start + dir * (length / 2) + UP * (rise / 2 - 0.3)
	-- WedgePart: full height at +Z (as BuildingGenerator's roofs), so +Z points away from you.
	local frame = CFrame.lookAt(center, center - dir)
	if EffectBudget.takeParts(1) < 1 then
		return { effective = false, hits = 0, note = "The ground won't answer here." }
	end
	local wedge = Instance.new("WedgePart")
	wedge.Name = "EarthRamp"
	wedge.Anchored = true
	wedge.Material = Enum.Material.Slate
	wedge.Color = L.stone
	wedge.Size = Vector3.new(T.width, rise, length)
	wedge.CFrame = frame
	wedge.CanCollide = not bodyInside(frame, wedge.Size)
	wedge.Parent = stoneFolder()
	task.delay(at(T.seconds, ctx), function()
		if wedge.Parent then
			wedge.CanCollide = false
			TweenService:Create(wedge, TweenInfo.new(0.8), { Transparency = 1, CFrame = wedge.CFrame - UP * rise }):Play()
			task.delay(0.85, function()
				wedge:Destroy()
			end)
		end
	end)
	cue(ctx, { fx = "rubble", at = start + dir * (length / 2), radius = length / 2 }, start, true)
	return { effective = true, hits = 0, note = "A ramp of stone rises where you point." }
end

local function boulder(ctx: Ctx): Outcome
	local T = E.boulder
	local dir = aimDir(ctx)
	local hits = 0
	for _, hit in foesStruck(ctx, 1) do
		R.hit(ctx, hit, T.share)
		R.status(ctx, hit.humanoid, "knockdown", T.downSeconds)
		hits += 1
	end
	local roll = at(T.roll, ctx)
	local start = ground(ctx.point) + UP * T.radius
	R.spawn({
		look = "boulder",
		ctx = ctx,
		position = start,
		radius = T.radius,
		seconds = roll / T.rollSpeed + 0.2,
		attrs = { DirX = dir.X, DirZ = dir.Z },
		data = { struck = {} },
		move = function(body, dt)
			local nextPos = body.position + dir * (T.rollSpeed * dt)
			local g = ground(nextPos)
			R.place(body, Vector3.new(nextPos.X, g.Y + T.radius, nextPos.Z))
			for _, hit in R.foesAround(body.ctx, body.position, T.radius + 1.5, body.data.struck) do
				body.data.struck[hit.model] = true
				R.hit(body.ctx, hit, T.share)
				R.status(body.ctx, hit.humanoid, "knockdown", T.downSeconds)
				R.push(hit, dir * 30 + UP * 14)
			end
		end,
	})
	return { effective = true, hits = hits }
end

-- ─── Metal ──────────────────────────────────────────────────────────────────

local function ironStorm(ctx: Ctx): Outcome
	local T = E.iron_storm
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 16))
	R.spawn({
		look = "iron_storm",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				local metal = LightningRods.metalWeight(hit.model) > 0
				R.hit(body.ctx, hit, T.share * (if metal then T.metalMult else 1))
				if metal then
					R.push(hit, flat(body.position - hit.root.Position) * T.drag)
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "Iron shavings whirl where you point. Anyone in metal suffers most." }
end

local function bladeRain(ctx: Ctx): Outcome
	local T = E.blade_rain
	local radius = at(T.radius, ctx)
	local spots: { Vector3 } = {}
	for i = 1, math.floor(at(T.blades, ctx)) do
		local angle = ctx.rng:NextNumber() * math.pi * 2
		local reach = if i == 1 then 0 else math.sqrt(ctx.rng:NextNumber()) * radius
		table.insert(spots, ground(ctx.point + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)))
	end
	cue(ctx, { fx = "blades_warn", spots = spots, delay = T.warn, radius = T.hitRadius }, ctx.point, true)
	local c = R.later(ctx)
	task.delay(T.warn, function()
		if not R.alive(c) then
			return
		end
		cue(c, { fx = "blades", spots = spots }, c.point, true)
		for i, spot in spots do
			task.delay((i - 1) * 0.05, function()
				for _, hit in R.foesAround(c, spot, T.hitRadius) do
					R.hit(c, hit, T.share)
				end
			end)
		end
	end)
	return { effective = true, hits = 0 }
end

local function quicksilverLash(ctx: Ctx): Outcome
	local T = E.quicksilver_lash
	local reach = at(T.reach, ctx)
	local hits = 0
	for _, hit in cone(ctx, reach, T.arc, T.maxTargets) do
		if R.hit(ctx, hit, T.share) > 0 then
			R.push(hit, flat(ctx.origin - hit.root.Position) * T.pull + UP * 6)
			hits += 1
		end
	end
	cue(ctx, { fx = "lash", from = ctx.origin, dir = aimDir(ctx), reach = reach, arc = T.arc }, ctx.origin)
	return { effective = hits > 0, hits = hits, note = if hits == 0 then "The metal snaps back to your hand empty." else nil }
end

-- ─── Crystal ────────────────────────────────────────────────────────────────

local function crystalSpires(ctx: Ctx): Outcome
	local T = E.crystal_spires
	local radius = at(T.radius, ctx)
	local center = ground(ctx.point)
	local spires: { Vector3 } = {}
	local hits = 0
	local seen: { [Model]: boolean } = {}
	for i = 1, math.floor(at(T.count, ctx)) do
		local angle = (i / at(T.count, ctx)) * math.pi * 2 + ctx.rng:NextNumber(-0.4, 0.4)
		local reach = if i == 1 then 0 else radius * ctx.rng:NextNumber(0.35, 1)
		local spot = ground(center + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach))
		table.insert(spires, spot)
		for _, hit in R.foesAround(ctx, spot, 2.6, seen) do
			seen[hit.model] = true
			R.hit(ctx, hit, T.share)
			R.push(hit, UP * 20)
			hits += 1
		end
		local height = ctx.rng:NextNumber(4, 7.5)
		raiseStone({
			Size = Vector3.new(1.4, height, 1.4),
			CFrame = CFrame.new(spot + UP * (height / 2 - 0.5)) * CFrame.Angles(ctx.rng:NextNumber(-0.35, 0.35), ctx.rng:NextNumber(0, math.pi), ctx.rng:NextNumber(-0.35, 0.35)),
			Material = Enum.Material.Glass,
			Color = L.crystal,
			Transparency = 0.25,
		}, T.shatterAfter)
	end
	cue(ctx, { fx = "spires", spots = spires }, center, true)
	local c = R.later(ctx)
	task.delay(T.shatterAfter, function()
		if not R.alive(c) then
			return
		end
		cue(c, { fx = "spires_shatter", spots = spires }, center, true)
		local struck: { [Model]: boolean } = {}
		for _, spot in spires do
			for _, hit in R.foesAround(c, spot, T.shatterRadius, struck) do
				struck[hit.model] = true
				R.hit(c, hit, T.shatterShare)
			end
		end
	end)
	return { effective = true, hits = hits }
end

local function singingShard(ctx: Ctx): Outcome
	local T = E.singing_shard
	local target = foesStruck(ctx, 1)[1]
	if not target then
		cue(ctx, { fx = "shard_ring", at = ctx.point }, ctx.point)
		return { effective = false, hits = 0 }
	end
	R.hit(ctx, target, T.share)
	local c = R.later(ctx)
	task.spawn(function()
		for _ = 1, T.pulses do
			task.wait(T.every)
			if not R.alive(c) or target.humanoid.Health <= 0 or not target.model.Parent then
				return
			end
			R.hit(c, target, T.pulseShare)
			cue(c, { fx = "shard_ring", at = target.root.Position, model = target.model }, target.root.Position)
		end
	end)
	return { effective = true, hits = 1 }
end

local function crystalPrison(ctx: Ctx): Outcome
	local T = E.crystal_prison
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0, note = "Crystal grows, and holds nothing." }
	end
	local seconds = at(T.seconds, ctx)
	if isPlayer(target) then
		seconds = math.min(seconds, T.pvpSeconds)
	end
	R.hit(ctx, target, T.share)
	R.status(ctx, target.humanoid, "stasis", seconds)
	cue(ctx, { fx = "prison", model = target.model, seconds = seconds }, target.root.Position)
	return { effective = true, hits = 1 }
end

local function geodeShell(ctx: Ctx): Outcome
	local T = E.geode_shell
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return { effective = false, hits = 0 }
	end
	local seconds = at(T.seconds, ctx)
	local shield = DamageModel.base(ctx.power) * 2.4
	StatusEffects.apply(humanoid, "ward", {
		duration = seconds,
		magnitude = shield,
		source = ctx.player.UserId,
		resist = Resistances.wardFor(ctx.stats.recipe.power),
	})
	for _, body in R.bodiesOf(ctx.player.UserId, "geode_shell") do
		R.endBody(body)
	end
	R.spawn({
		look = "geode_shell",
		ctx = ctx,
		position = ctx.origin,
		radius = 2,
		seconds = seconds,
		every = 0.25,
		attrs = { Plates = T.plates, Left = 1 },
		links = { Model = ctx.character },
		data = { full = shield },
		move = function(body, _dt)
			local root = ctx.character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				R.place(body, root.Position)
			end
		end,
		tick = function(body)
			-- The plates chip off as the ward is used; it's gone when they are.
			if not StatusEffects.has(humanoid, "ward") then
				R.endBody(body)
				return
			end
			local left = 0
			for _, s in StatusEffects.snapshot(humanoid) do
				if s.id == "ward" then
					left = math.clamp(s.magnitude / body.data.full, 0, 1)
				end
			end
			body.part:SetAttribute("Left", left)
		end,
	})
	return { effective = true, hits = 0, note = "Crystal plates grow over you." }
end

-- ─── Seismic ────────────────────────────────────────────────────────────────

local function fissure(ctx: Ctx): Outcome
	local T = E.fissure
	local dir = aimDir(ctx)
	local length = at(T.length, ctx)
	local from = ground(ctx.origin + dir * 2)
	local to = ground(ctx.origin + dir * length)
	cue(ctx, { fx = "fissure", from = from, to = to, speed = T.speed }, from, true)
	local c = R.later(ctx)
	local seen: { [Model]: boolean } = {}
	task.spawn(function()
		local step = 3
		for d = 2, length, step do
			task.wait(step / T.speed)
			if not R.alive(c) then
				return
			end
			local spot = c.origin + dir * d
			for _, hit in R.foesAround(c, spot, T.width, seen) do
				if hit.humanoid.FloorMaterial ~= Enum.Material.Air then
					seen[hit.model] = true
					R.hit(c, hit, T.share)
					R.status(c, hit.humanoid, "knockdown", T.downSeconds)
				end
			end
		end
	end)
	return { effective = true, hits = 0 }
end

local function groundRipple(ctx: Ctx): Outcome
	local T = E.ground_ripple
	local radius = at(T.radius, ctx)
	local center = ground(ctx.point)
	cue(ctx, { fx = "ripple", at = center, radius = radius, speed = T.speed }, center, true)
	local c = R.later(ctx)
	local seen: { [Model]: boolean } = {}
	task.spawn(function()
		local r = 0
		while r < radius do
			task.wait(0.08)
			r += T.speed * 0.08
			if not R.alive(c) then
				return
			end
			for _, hit in R.foesAround(c, center, r + T.band, seen) do
				local d = Vector3.new(hit.root.Position.X - center.X, 0, hit.root.Position.Z - center.Z).Magnitude
				if d >= r - T.band and hit.humanoid.FloorMaterial ~= Enum.Material.Air then
					seen[hit.model] = true
					R.hit(c, hit, T.share)
					R.push(hit, UP * T.lift + flat(hit.root.Position - center) * 10)
				end
			end
		end
	end)
	return { effective = true, hits = 0 }
end

-- ─── Sand ───────────────────────────────────────────────────────────────────

local function sandBlast(ctx: Ctx): Outcome
	local T = E.sand_blast
	local reach = at(T.reach, ctx)
	local dir = aimDir(ctx)
	local hits = 0
	for _, hit in cone(ctx, reach, T.arc, 8) do
		R.hit(ctx, hit, T.share)
		R.status(ctx, hit.humanoid, "blind", T.blindSeconds)
		R.push(hit, dir * T.push + UP * 6)
		hits += 1
	end
	cue(ctx, { fx = "sandblast", from = ctx.origin, dir = dir, reach = reach, arc = T.arc }, ctx.origin)
	return { effective = hits > 0, hits = hits }
end

local function dustCloud(ctx: Ctx): Outcome
	local T = E.dust_cloud
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 16))
	R.spawn({
		look = "dust_cloud",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "blind", T.blindSeconds)
			end
		end,
	})
	return { effective = true, hits = 0 }
end

local function quicksand(ctx: Ctx): Outcome
	local T = E.quicksand
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 15))
	R.spawn({
		look = "quicksand",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		data = { stood = {} },
		tick = function(body)
			local inside: { [Model]: boolean } = {}
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				inside[hit.model] = true
				local stood = (body.data.stood[hit.model] or 0) + T.every
				body.data.stood[hit.model] = stood
				R.status(body.ctx, hit.humanoid, "slow", T.every + 0.3)
				R.hit(body.ctx, hit, T.share)
				if stood >= T.rootAfter then
					body.data.stood[hit.model] = 0
					R.status(body.ctx, hit.humanoid, "root", T.rootSeconds)
				end
			end
			for model in body.data.stood do
				if not inside[model] then
					body.data.stood[model] = nil
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "The ground goes soft. Anyone who lingers sinks." }
end

local function dustDevil(ctx: Ctx): Outcome
	local T = E.dust_devil
	for _, body in R.bodiesOf(ctx.player.UserId, "dust_devil") do
		R.endBody(body)
	end
	R.spawn({
		look = "dust_devil",
		ctx = ctx,
		position = ground(ctx.point),
		radius = T.radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		data = { wander = ctx.rng:NextNumber() * math.pi * 2 },
		move = function(body, dt)
			local foe: Hit? = nil
			for _, hit in Targeting.inRadius(body.position, T.seek, 6, { [body.ctx.character] = true }) do
				if Targeting.canHarm(body.ctx.player, hit.model) then
					foe = hit
					break
				end
			end
			local dir: Vector3
			if foe then
				dir = flat(foe.root.Position - body.position)
			else
				body.data.wander += (body.ctx.rng:NextNumber() - 0.5) * dt * 3
				dir = Vector3.new(math.cos(body.data.wander), 0, math.sin(body.data.wander))
			end
			local nextPos = body.position + dir * T.speed * dt
			R.place(body, ground(nextPos))
		end,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, T.radius) do
				R.hit(body.ctx, hit, T.share)
				R.status(body.ctx, hit.humanoid, "blind", T.blindSeconds)
			end
		end,
	})
	return { effective = true, hits = 0, note = "A little whirlwind of sand goes looking for someone." }
end

local function sandShroud(ctx: Ctx): Outcome
	local T = E.sand_shroud
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return { effective = false, hits = 0 }
	end
	local seconds = at(T.seconds, ctx)
	R.status(ctx, humanoid, "veiled", seconds)
	for _, body in R.bodiesOf(ctx.player.UserId, "sand_shroud") do
		R.endBody(body)
	end
	local character = ctx.character
	R.spawn({
		look = "sand_shroud",
		ctx = ctx,
		position = ctx.origin,
		radius = T.radius,
		seconds = seconds,
		every = T.every,
		links = { Model = character },
		move = function(body, _dt)
			local root = character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				R.place(body, root.Position)
			end
		end,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, T.radius) do
				R.hit(body.ctx, hit, T.share)
			end
		end,
	})
	return { effective = true, hits = 0, note = "Sand whirls round you. You're hard to see, and it stings anyone close." }
end

-- ─── Dispatch ───────────────────────────────────────────────────────────────

local MOVES: { [string]: (Ctx) -> Outcome } = {
	stone_fist = stoneFist,
	gravel_burst = gravelBurst,
	spike_trail = spikeTrail,
	stone_step = stoneStep,
	stone_grip = stoneGrip,
	ramp = ramp,
	boulder = boulder,
	iron_storm = ironStorm,
	blade_rain = bladeRain,
	quicksilver_lash = quicksilverLash,
	crystal_spires = crystalSpires,
	singing_shard = singingShard,
	crystal_prison = crystalPrison,
	geode_shell = geodeShell,
	fissure = fissure,
	ground_ripple = groundRipple,
	sand_blast = sandBlast,
	dust_cloud = dustCloud,
	quicksand = quicksand,
	dust_devil = dustDevil,
	sand_shroud = sandShroud,
}
EarthArt.moves = MOVES

function EarthArt.resolve(ctx: Ctx, params: { [string]: any }): Outcome
	if ctx.backfire then
		local module = script.Parent:FindFirstChild("Impact")
		if module and module:IsA("ModuleScript") then
			return (require(module) :: any).resolve(ctx, {})
		end
		return { effective = false, hits = 0, harmedSelf = true }
	end
	local move = MOVES[params.move]
	if not move then
		return { effective = false, hits = 0 }
	end
	return move(ctx)
end

return EarthArt
