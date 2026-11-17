--!strict
--[[
	EnergyArt: Energy's own spells (docs/DomainIdeas.md, "Energy"). Ordinary moves that fit their branch,
	each reached by a narrow route in Data/EffectLibrary ("energy_" .. move, with params.move). Numbers:
	Data/EnergyTuning. Anything that lasts runs in Cast/EnergyRuntime; looks in Client/Fx/EnergyFx.

	Fire (Pyromancy, Conflagration)
		ember_swarm   embers scatter out of the burst and light what they land on
		fire_whip     a lash of flame swung in an arc in front of you
		flame_serpent fire pulled out of a blaze winds at a target and coils round it (the blaze goes out)
		ring_of_fire  a circle of flame around where you stand; crossing it burns
		smother       fires go out into thick smoke that blinds foes inside; burning allies are put out
		kindle        your (or an ally's) hands burn for a while: whatever they strike catches fire
	Frost (Cryothermy)
		ice_spike_line spikes erupt one after another from you toward the target
		frost_lance    a long icicle that pins whoever it hits, then shatters
		hoarfrost      frosted ground: chills whoever stands on it; running across may put you down
		ice_mirror     a pane of ice that throws other people's bolts back the way they came
		flurry         snow whirling round you, chilling anyone close
	Heat (Calefaction)
		heat_haze      the air round you wobbles: bolts aimed at you drift off line
		boil           water you touch flashes into scalding steam (no water: an ordinary heat touch)
		searing_ground ground glowing red-hot for a while
	Light (Photomancy, Irradiance)
		prism_bolt     a bolt that breaks into a fan of coloured rays behind its target
		sunspot        a column of hard light: foes inside are dazzled, veils burn away
		wisps          small lights follow you, light the way and show veiled people
		flash          a blinding pop: everyone looking your way is blinded
		glowing_poison a sickly glow that hurts and that everyone can see, even through walls
	Shadow (Umbramancy)
		shadow_grasp   shadows reach up and hold someone's feet
		shade_cloak    you darken and are hard to see (longer at night)
		shadow_puppet  your shadow stands up and copies your blows, weaker
	Kinetic (Impetus, Deflection, Inertia)
		stomp          a shockwave along the ground: everyone standing on it falls
		ricochet       a bolt that bounces on to the next person, and the next
		repulse        bolts coming at you curve away
		inertia_lock   someone keeps sliding the way they were going and can't stop
		launch         hurls you or an ally forward through the air
	Lightning (Electromancy, Galvanism, Arcweaving)
		ball_lightning a slow ball that drifts toward people, zapping, then pops
		static_field   sparks jump between everyone inside: the more people, the more arcs
		arc_tether     two foes linked by an arc that hurts both until they pull apart (then it snaps)
		galvanise      a burst of speed with sparks at the feet
		arc_fence      a crackling fence: crossing it shocks and dazes

	A backfire lands on the caster as any harmful spell's does (Effects/Impact).
]]

local Lighting = game:GetService("Lighting")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Types = require(Shared.Magic.Types)
local E = require(Shared.Magic.Data.EnergyTuning)

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local FireSim = require(Cast.FireSim)
local ThermalSim = require(Cast.ThermalSim)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local PropertyBehaviour = require(Cast.PropertyBehaviour)
local R = require(Cast.EnergyRuntime)

type Ctx = CastTypes.EffectContext
type Outcome = CastTypes.Outcome
type Hit = Targeting.Hit

local UP = Vector3.new(0, 1, 0)

local EnergyArt = {}

function EnergyArt.precheck(_params: { [string]: any }, _stats: Types.SpellStats, _player: Player): string?
	if FeatureFlags.get("energy_arts_enabled") == false then
		return "WORLD_STRAINED"
	end
	if R.count() >= E.caps.server then
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

-- The ground under `position` (characters and energy bodies ignored), or `position` itself.
local function ground(position: Vector3): Vector3
	local ignore: { Instance } = {}
	local folder = workspace:FindFirstChild("EnergyBodies")
	if folder then
		table.insert(ignore, folder)
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

-- Who a point spell reached: the flight's hits, the target, or what the form selects; foes only.
local function foesStruck(ctx: Ctx, max: number?): { Hit }
	local out: { Hit } = {}
	for _, hit in Targeting.select(ctx, max) do
		if hit.model ~= ctx.character and Targeting.canHarm(ctx.player, hit.model) then
			table.insert(out, hit)
		end
	end
	return out
end

-- Someone to help: the ally the spell reached, else the caster.
local function friendOrSelf(ctx: Ctx): Hit?
	if ctx.stats.recipe.form ~= "aura" then
		for _, hit in Targeting.select(ctx, 1) do
			if hit.model ~= ctx.character and Targeting.canHelp(ctx.player, hit.model) and not Targeting.canHarm(ctx.player, hit.model) then
				return hit
			end
		end
	end
	return Targeting.characterOf(ctx.root)
end

local function rotateY(v: Vector3, degrees: number): Vector3
	return CFrame.Angles(0, math.rad(degrees), 0):VectorToWorldSpace(v)
end

local function serverTime(): number
	return workspace:GetServerTimeNow()
end

-- A body that rides along with someone (a kindled hand, an aura): it follows their root.
local function follow(model: Model): (R.Body, number) -> ()
	return function(body: R.Body, _dt: number)
		local root = model:FindFirstChild("HumanoidRootPart")
		local humanoid = model:FindFirstChildOfClass("Humanoid")
		if not model.Parent or not root or not root:IsA("BasePart") or not humanoid or humanoid.Health <= 0 then
			R.endBody(body)
			return
		end
		R.place(body, root.Position)
	end
end

local function waterNear(point: Vector3, radius: number): boolean
	local half = Vector3.one * radius
	local region = Region3.new(point - half, point + half):ExpandToGrid(4)
	local ok, materials, occupancy = pcall(function()
		return workspace.Terrain:ReadVoxels(region, 4)
	end)
	if not ok then
		return false
	end
	local size = materials.Size
	for x = 1, size.X do
		for y = 1, size.Y do
			for z = 1, size.Z do
				if materials[x][y][z] == Enum.Material.Water and occupancy[x][y][z] > 0.3 then
					return true
				end
			end
		end
	end
	return false
end

-- An ordinary effect (Effects/<name>) when the special one has nothing to work with.
local function fallback(ctx: Ctx, name: string, params: { [string]: any }): Outcome
	local module = script.Parent:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		return { effective = false, hits = 0 }
	end
	return (require(module) :: any).resolve(ctx, params)
end

-- ─── Fire ───────────────────────────────────────────────────────────────────

local function emberSwarm(ctx: Ctx): Outcome
	local T = E.ember_swarm
	local radius = math.clamp(ctx.stats.area, 4, 20)
	local hits = 0
	for _, hit in R.foesAround(ctx, ctx.point, radius) do
		if R.hit(ctx, hit, T.share, nil, {}) > 0 then
			R.burn(ctx, hit.humanoid, T.burnSeconds, T.burnShare)
			hits += 1
		end
	end
	local spots: { Vector3 } = {}
	for _ = 1, math.floor(at(T.embers, ctx)) do
		local angle = ctx.rng:NextNumber() * math.pi * 2
		local reach = math.sqrt(ctx.rng:NextNumber()) * radius * T.spread
		table.insert(spots, ground(ctx.point + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)))
	end
	R.cue(ctx, { fx = "embers", from = ctx.point + Vector3.new(0, 1, 0), spots = spots }, ctx.point, true)
	local c = R.later(ctx)
	local intensity = math.clamp(0.5 + ctx.stats.recipe.power * 0.08, 0.5, 1.4)
	task.delay(0.7, function()
		if not R.alive(c) then
			return
		end
		local seen: { [Model]: boolean } = {}
		for _, spot in spots do
			FireSim.igniteGround(spot, intensity, c.player.UserId)
			for _, hit in R.foesAround(c, spot, T.emberRadius, seen) do
				seen[hit.model] = true
				if R.hit(c, hit, T.emberShare) > 0 then
					R.burn(c, hit.humanoid, T.burnSeconds, T.burnShare)
				end
			end
		end
	end)
	return { effective = true, hits = hits }
end

local function fireWhip(ctx: Ctx): Outcome
	local T = E.fire_whip
	local reach = at(T.reach, ctx)
	local dir = aimDir(ctx)
	local hits = 0
	for _, hit in Targeting.inCone(ctx.origin, dir, reach, T.arc / 2, T.maxTargets, { [ctx.character] = true }) do
		if Targeting.canHarm(ctx.player, hit.model) and R.hit(ctx, hit, T.share, "combustion") > 0 then
			R.burn(ctx, hit.humanoid, T.burnSeconds, T.burnShare)
			hits += 1
		end
	end
	R.cue(ctx, { fx = "whip", from = ctx.origin, dir = dir, reach = reach, arc = T.arc }, ctx.origin)
	return { effective = hits > 0, hits = hits, note = if hits == 0 then "The whip cracks on empty air." else nil }
end

local function flameSerpent(ctx: Ctx): Outcome
	local T = E.flame_serpent
	-- The blaze it was pulled from goes out.
	for _, fire in FireSim.firesNear(ctx.origin, T.sourceRadius, 4) do
		FireSim.extinguish(fire.position, 4)
	end
	local target = foesStruck(ctx, 1)[1]
	if not target then
		R.cue(ctx, { fx = "coil", at = ctx.point }, ctx.point)
		return { effective = false, hits = 0, note = "The serpent finds no one, and burns out." }
	end
	R.hit(ctx, target, T.share, "combustion")
	R.burn(ctx, target.humanoid, T.burnSeconds, T.burnShare)
	local c = R.later(ctx)
	task.spawn(function()
		for _ = 1, T.coils do
			task.wait(T.coilEvery)
			if not R.alive(c) or target.humanoid.Health <= 0 or not target.model.Parent then
				return
			end
			R.cue(c, { fx = "coil", at = target.root.Position, model = target.model }, target.root.Position)
			R.hit(c, target, T.coilShare)
		end
	end)
	return { effective = true, hits = 1 }
end

local function ringOfFire(ctx: Ctx): Outcome
	local T = E.ring_of_fire
	local radius = at(T.radius, ctx)
	local center = ground(ctx.origin)
	R.spawn({
		look = "ring_of_fire",
		ctx = ctx,
		position = center,
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius + T.band) do
				local d = Vector3.new(hit.root.Position.X - body.position.X, 0, hit.root.Position.Z - body.position.Z).Magnitude
				if d >= body.radius - T.band then
					R.hit(body.ctx, hit, T.share)
					R.burn(body.ctx, hit.humanoid, T.burnSeconds, T.burnShare)
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "Fire rises in a ring around you. Anyone who crosses it burns." }
end

local function smother(ctx: Ctx): Outcome
	local T = E.smother
	local center = if ctx.stats.recipe.form == "aura" then ctx.origin else ctx.point
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 20))
	local out = FireSim.extinguish(center, radius)
	local cleared = 0
	for _, hit in Targeting.inRadius(center, radius, 12) do
		if Targeting.canHelp(ctx.player, hit.model) and StatusEffects.cleanse(hit.humanoid, { "burning" }) > 0 then
			cleared += 1
		end
	end
	R.spawn({
		look = "smother",
		ctx = ctx,
		position = ground(center),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "blind", T.blindSeconds)
			end
		end,
	})
	local note = if out > 0 then string.format("%d fire%s choke out into smoke.", out, if out == 1 then "" else "s") else "Smoke rolls out where you point."
	return { effective = true, hits = cleared, note = note }
end

local function kindle(ctx: Ctx): Outcome
	local T = E.kindle
	local who = friendOrSelf(ctx)
	if not who then
		return { effective = false, hits = 0 }
	end
	-- One kindling per body: a new one replaces it.
	for _, body in R.bodiesOf(ctx.player.UserId, "kindle") do
		if body.data.wielder == who.model then
			R.endBody(body)
		end
	end
	local wielderPlayer = Players:GetPlayerFromCharacter(who.model)
	R.spawn({
		look = "kindle",
		ctx = ctx,
		position = who.root.Position,
		radius = 2,
		seconds = at(T.seconds, ctx),
		links = { Model = who.model },
		data = { wielder = who.model, lit = {} },
		move = follow(who.model),
		ownerHit = function(body, victim: Humanoid)
			local now = os.clock()
			if victim.Health <= 0 or (body.data.lit[victim] or 0) > now then
				return
			end
			body.data.lit[victim] = now + T.gap
			StatusEffects.apply(victim, "burning", {
				duration = T.burnSeconds,
				magnitude = DamageModel.base(body.ctx.power) * T.burnShare,
				source = if wielderPlayer then wielderPlayer.UserId else body.owner,
			})
		end,
	})
	return { effective = true, hits = 1, note = if who.model == ctx.character then "Your hands burn. Whatever you strike catches fire." else "Their hands burn. Whatever they strike catches fire." }
end

-- ─── Frost ──────────────────────────────────────────────────────────────────

local function iceSpikeLine(ctx: Ctx): Outcome
	local T = E.ice_spike_line
	local dir = aimDir(ctx)
	local length = at(T.length, ctx)
	local spots: { Vector3 } = {}
	for d = T.step, length, T.step do
		table.insert(spots, ground(ctx.origin + dir * d))
	end
	R.cue(ctx, { fx = "spikes", spots = spots, delay = T.stepDelay, radius = T.radius }, ctx.origin, true)
	local c = R.later(ctx)
	local seen: { [Model]: boolean } = {}
	task.spawn(function()
		for _, spot in spots do
			task.wait(T.stepDelay)
			if not R.alive(c) then
				return
			end
			for _, hit in R.foesAround(c, spot, T.radius, seen) do
				seen[hit.model] = true
				R.hit(c, hit, T.share, "cold")
				R.push(hit, UP * T.lift)
			end
		end
	end)
	return { effective = true, hits = 0 }
end

local function frostLance(ctx: Ctx): Outcome
	local T = E.frost_lance
	local target = foesStruck(ctx, 1)[1]
	local hits = 0
	local skip: { [Model]: boolean } = {}
	if target then
		R.hit(ctx, target, T.share, "cold")
		local isPlayer = Players:GetPlayerFromCharacter(target.model) ~= nil
		R.status(ctx, target.humanoid, "root", if isPlayer then math.min(T.pinSeconds, 1) else T.pinSeconds)
		skip[target.model] = true
		hits += 1
	end
	local spot = if target then target.root.Position else ctx.point
	for _, hit in R.foesAround(ctx, spot, T.shardRadius, skip) do
		R.hit(ctx, hit, T.shardShare, "cold")
		hits += 1
	end
	R.cue(ctx, { fx = "shatter", at = spot, radius = T.shardRadius }, spot)
	return { effective = hits > 0, hits = hits }
end

local function hoarfrost(ctx: Ctx): Outcome
	local T = E.hoarfrost
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 18))
	R.spawn({
		look = "hoarfrost",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		data = { slipped = {} },
		tick = function(body)
			local now = os.clock()
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				PropertyBehaviour.applyControl(body.ctx, hit, "cold")
				local v = hit.root.AssemblyLinearVelocity
				local speed = Vector3.new(v.X, 0, v.Z).Magnitude
				if speed >= T.slipSpeed and (body.data.slipped[hit.model] or 0) <= now and body.ctx.rng:NextNumber() < T.slipChance then
					body.data.slipped[hit.model] = now + T.slipGap
					R.status(body.ctx, hit.humanoid, "knockdown", T.slipSeconds)
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "The ground frosts over. Anyone who runs on it may fall." }
end

local function iceMirror(ctx: Ctx): Outcome
	local T = E.ice_mirror
	local width = at(T.width, ctx)
	local base = ground(ctx.point)
	local normal = flat(ctx.origin - base) -- facing the caster
	local right = normal:Cross(UP).Unit
	local center = base + UP * (T.height / 2)
	local turned: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	R.spawn({
		look = "ice_mirror",
		ctx = ctx,
		position = center,
		radius = width / 2,
		seconds = at(T.seconds, ctx),
		cframe = CFrame.fromMatrix(center, right, UP),
		size = Vector3.new(width, T.height, 0.6),
		data = { normal = normal, right = right },
		deflect = function(body, position: Vector3, velocity: Vector3, flight: any): (string?, any)
			if turned[flight] or flight.ownerModel == body.ctx.character then
				return nil, nil
			end
			local rel = position - body.position
			local d = rel:Dot(normal)
			if math.abs(d) > T.thickness or math.abs(rel:Dot(right)) > width / 2 or math.abs(rel.Y) > T.height / 2 then
				return nil, nil
			end
			local into = velocity:Dot(normal)
			if into * d >= 0 then
				return nil, nil -- moving away from the pane
			end
			turned[flight] = true
			R.cue(body.ctx, { fx = "mirror_turn", at = position }, position)
			return "bend", velocity - normal * (2 * into)
		end,
	})
	return { effective = true, hits = 0, note = "A pane of ice stands where you point. Bolts that hit it come back." }
end

local function flurry(ctx: Ctx): Outcome
	local T = E.flurry
	R.spawn({
		look = "flurry",
		ctx = ctx,
		position = ctx.origin,
		radius = at(T.radius, ctx),
		seconds = at(T.seconds, ctx),
		every = T.every,
		links = { Model = ctx.character },
		move = follow(ctx.character),
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.hit(body.ctx, hit, T.share, "cold")
			end
		end,
	})
	return { effective = true, hits = 0 }
end

-- ─── Heat ───────────────────────────────────────────────────────────────────

local function heatHaze(ctx: Ctx): Outcome
	local T = E.heat_haze
	local degrees = at(T.degrees, ctx)
	local turned: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	local character = ctx.character
	R.spawn({
		look = "heat_haze",
		ctx = ctx,
		position = ctx.origin,
		radius = T.radius,
		seconds = at(T.seconds, ctx),
		links = { Model = character },
		move = follow(character),
		deflect = function(body, position: Vector3, velocity: Vector3, flight: any): (string?, any)
			if turned[flight] or flight.ownerModel == character then
				return nil, nil
			end
			local to = body.position - position
			if to.Magnitude > T.radius or velocity:Dot(to) <= 0 then
				return nil, nil
			end
			turned[flight] = true
			-- Off line, away from you: the side the bolt was already a little to.
			local side = if velocity:Cross(to).Y > 0 then -1 else 1
			return "bend", rotateY(velocity, degrees * side)
		end,
	})
	return { effective = true, hits = 0, note = "The air around you shimmers. Bolts aimed at you drift." }
end

local function boil(ctx: Ctx): Outcome
	local T = E.boil
	if not waterNear(ctx.point, T.waterRadius) then
		return fallback(ctx, "Thermal", { mode = "byVerb" })
	end
	local radius = at(T.radius, ctx)
	local hits = 0
	for _, hit in R.foesAround(ctx, ctx.point, radius) do
		if R.hit(ctx, hit, T.share, "heat") > 0 then
			R.status(ctx, hit.humanoid, "blind", T.blindSeconds)
			hits += 1
		end
	end
	R.cue(ctx, { fx = "steam", at = ctx.point, radius = radius }, ctx.point, true)
	return { effective = true, hits = hits, note = "The water flashes into scalding steam." }
end

local function searingGround(ctx: Ctx): Outcome
	local T = E.searing_ground
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 18))
	R.spawn({
		look = "searing_ground",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.hit(body.ctx, hit, T.share, "heat")
			end
			for _, part in ThermalSim.partsNear(body.position, body.radius, 6) do
				ThermalSim.addHeat(part, T.heat)
			end
		end,
	})
	return { effective = true, hits = 0, note = "The ground glows red-hot." }
end

-- ─── Light ──────────────────────────────────────────────────────────────────

local function prismBolt(ctx: Ctx): Outcome
	local T = E.prism_bolt
	local hits = 0
	local skip: { Instance } = { ctx.character }
	local main = foesStruck(ctx, 1)[1]
	local from = if main then main.root.Position else ctx.point
	if main then
		R.hit(ctx, main, T.share, "luminosity")
		table.insert(skip, main.model)
		hits += 1
	end
	local dir = aimDir(ctx)
	local rays = math.floor(at(T.rays, ctx))
	local length = at(T.length, ctx)
	local ends: { Vector3 } = {}
	local struck: { [Model]: boolean } = {}
	for i = 1, rays do
		local t = if rays == 1 then 0.5 else (i - 1) / (rays - 1)
		local to = from + rotateY(dir, (t - 0.5) * T.fan) * length
		table.insert(ends, to)
		for _, hit in Targeting.alongBeam(from, to, 1.5, 3, skip) do
			if not struck[hit.model] and Targeting.canHarm(ctx.player, hit.model) then
				struck[hit.model] = true
				R.hit(ctx, hit, T.rayShare)
				hits += 1
				break
			end
		end
	end
	R.cue(ctx, { fx = "prism", from = from, ends = ends }, from)
	return { effective = true, hits = hits }
end

local function sunspot(ctx: Ctx): Outcome
	local T = E.sunspot
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 16))
	R.spawn({
		look = "sunspot",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in Targeting.inRadius(body.position, body.radius, 12) do
				StatusEffects.remove(hit.humanoid, "veiled")
			end
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "blind", T.blindSeconds)
				R.hit(body.ctx, hit, T.share)
			end
		end,
	})
	return { effective = true, hits = 0, note = "Hard light pours down where you point." }
end

local function wisps(ctx: Ctx): Outcome
	local T = E.wisps
	for _, body in R.bodiesOf(ctx.player.UserId, "wisps") do
		R.endBody(body)
	end
	R.spawn({
		look = "wisps",
		ctx = ctx,
		position = ctx.origin,
		radius = T.reveal,
		seconds = at(T.seconds, ctx),
		every = T.every,
		attrs = { Count = T.count },
		links = { Model = ctx.character },
		move = follow(ctx.character),
		tick = function(body)
			for _, hit in Targeting.inRadius(body.position, T.reveal, 12, { [body.ctx.character] = true }) do
				if StatusEffects.has(hit.humanoid, "veiled") then
					StatusEffects.remove(hit.humanoid, "veiled")
					R.cue(body.ctx, { fx = "reveal", at = hit.root.Position }, hit.root.Position)
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "Small lights gather round you. They show what hides." }
end

local function flash(ctx: Ctx): Outcome
	local T = E.flash
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 24))
	local seconds = at(T.blindSeconds, ctx)
	local hits = 0
	for _, hit in R.foesAround(ctx, ctx.origin, radius) do
		local to = ctx.origin - hit.root.Position
		if to.Magnitude < 2 or hit.root.CFrame.LookVector:Dot(to.Unit) >= T.facing then
			R.status(ctx, hit.humanoid, "blind", seconds)
			hits += 1
		end
	end
	R.cue(ctx, { fx = "flash", at = ctx.origin + Vector3.new(0, 1.5, 0), radius = radius }, ctx.origin, true)
	return { effective = hits > 0, hits = hits, note = if hits == 0 then "Light bursts from you, but nobody was looking." else nil }
end

local function glowingPoison(ctx: Ctx): Outcome
	local T = E.glowing_poison
	local seconds = at(T.seconds, ctx)
	local hits = 0
	for _, hit in foesStruck(ctx) do
		R.hit(ctx, hit, T.share)
		R.status(ctx, hit.humanoid, "irradiated", seconds, DamageModel.base(ctx.power) * T.dotShare)
		StatusEffects.remove(hit.humanoid, "veiled")
		hit.model:SetAttribute("EnergyGlow", serverTime() + seconds)
		R.cue(ctx, { fx = "glow", model = hit.model, seconds = seconds }, hit.root.Position)
		hits += 1
	end
	return { effective = hits > 0, hits = hits }
end

-- ─── Shadow ─────────────────────────────────────────────────────────────────

local function shadowGrasp(ctx: Ctx): Outcome
	local T = E.shadow_grasp
	local target = foesStruck(ctx, 1)[1]
	if not target then
		R.cue(ctx, { fx = "grasp", at = ground(ctx.point) }, ctx.point)
		return { effective = false, hits = 0, note = "Shadows reach up, and close on nothing." }
	end
	local isPlayer = Players:GetPlayerFromCharacter(target.model) ~= nil
	local seconds = at(T.seconds, ctx)
	R.hit(ctx, target, T.share)
	R.status(ctx, target.humanoid, "root", if isPlayer then math.min(seconds, T.pvpSeconds) else seconds)
	R.cue(ctx, { fx = "grasp", at = ground(target.root.Position), model = target.model, seconds = seconds }, target.root.Position)
	return { effective = true, hits = 1 }
end

local function shadeCloak(ctx: Ctx): Outcome
	local T = E.shade_cloak
	local clock = Lighting.ClockTime
	local night = clock < 6 or clock >= 18.5
	local seconds = at(T.seconds, ctx) * (if night then T.nightMult else 1)
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return { effective = false, hits = 0 }
	end
	R.status(ctx, humanoid, "veiled", seconds)
	R.cue(ctx, { fx = "cloak", model = ctx.character, seconds = seconds }, ctx.origin)
	return { effective = true, hits = 0, note = if night then "The dark takes you in." else "You darken. In shade or at night it would hold longer." }
end

local function shadowPuppet(ctx: Ctx): Outcome
	local T = E.shadow_puppet
	for _, body in R.bodiesOf(ctx.player.UserId, "shadow_puppet") do
		R.endBody(body)
	end
	local character = ctx.character
	R.spawn({
		look = "shadow_puppet",
		ctx = ctx,
		position = ctx.origin,
		radius = 2,
		seconds = at(T.seconds, ctx),
		links = { Model = character },
		data = { gap = {} },
		move = function(body, dt)
			local root = character:FindFirstChild("HumanoidRootPart")
			if not root or not root:IsA("BasePart") then
				R.endBody(body)
				return
			end
			-- A step behind you and to the left, catching up smoothly.
			local want = (root.CFrame * CFrame.new(-3.2, 0, 3.2)).Position -- where the client draws it (EnergyFx PUPPET_OFFSET)
			R.place(body, body.position:Lerp(want, math.clamp(dt * 8, 0, 1)))
		end,
		ownerHit = function(body, victim: Humanoid)
			local now = os.clock()
			if (body.data.gap[victim] or 0) > now then
				return
			end
			body.data.gap[victim] = now + T.gap
			task.delay(T.delay, function()
				local model = victim.Parent
				if body.ended or victim.Health <= 0 or not model or not model:IsA("Model") then
					return
				end
				local hit = Targeting.characterOf(model)
				if not hit or not Targeting.canHarm(body.ctx.player, model) then
					return
				end
				local result = DamageModel.compute(body.ctx, hit, T.share, { noFalloff = true })
				-- No attacker: the puppet's copy mustn't be copied again.
				Damage.apply(victim, result.amount, body.owner, "energy", {
					domain = "energy",
					crit = result.crit,
					power = body.ctx.stats.recipe.power,
					from = body.position,
					property = "shadow",
					form = "touch",
					branch = body.ctx.stats.recipe.branch,
				})
				R.cue(body.ctx, { fx = "puppet_strike", from = body.position, to = hit.root.Position }, hit.root.Position)
			end)
		end,
	})
	return { effective = true, hits = 0, note = "Your shadow stands up beside you. It copies your blows." }
end

-- ─── Kinetic ────────────────────────────────────────────────────────────────

local function stomp(ctx: Ctx): Outcome
	local T = E.stomp
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 20))
	local center = ground(ctx.origin)
	local hits = 0
	for _, hit in R.foesAround(ctx, center, radius) do
		if hit.humanoid.FloorMaterial ~= Enum.Material.Air then
			R.hit(ctx, hit, T.share, nil, {})
			R.status(ctx, hit.humanoid, "knockdown", T.downSeconds)
			R.push(hit, flat(hit.root.Position - center) * 10 + UP * T.lift)
			hits += 1
		end
	end
	R.cue(ctx, { fx = "stomp", at = center, radius = radius }, center, true)
	return { effective = hits > 0, hits = hits, note = if hits == 0 then "The ground jumps, but nobody was standing on it." else nil }
end

local function ricochet(ctx: Ctx): Outcome
	local T = E.ricochet
	local main = foesStruck(ctx, 1)[1]
	if not main then
		return { effective = false, hits = 0 }
	end
	R.hit(ctx, main, 1, "momentum")
	local c = R.later(ctx)
	local bounces = math.floor(at(T.bounces, ctx))
	task.spawn(function()
		local struck: { [Model]: boolean } = { [main.model] = true, [c.character] = true }
		local from = main.root.Position
		for i = 1, bounces do
			task.wait(0.12)
			if not R.alive(c) then
				break
			end
			local nextHit: Hit? = nil
			for _, hit in Targeting.inRadius(from, T.reach, 6, struck) do
				if Targeting.canHarm(c.player, hit.model) and not Targeting.occluded(from, hit, { c.character }) then
					nextHit = hit
					break
				end
			end
			if not nextHit then
				break
			end
			struck[nextHit.model] = true
			R.hit(c, nextHit, T.falloff ^ i)
			R.cue(c, { fx = "ricochet", from = from, to = nextHit.root.Position }, nextHit.root.Position)
			from = nextHit.root.Position
		end
	end)
	return { effective = true, hits = 1 }
end

local function repulse(ctx: Ctx): Outcome
	local T = E.repulse
	local character = ctx.character
	local turned: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	R.spawn({
		look = "repulse",
		ctx = ctx,
		position = ctx.origin,
		radius = T.radius,
		seconds = at(T.seconds, ctx),
		links = { Model = character },
		move = follow(character),
		deflect = function(body, position: Vector3, velocity: Vector3, flight: any): (string?, any)
			if turned[flight] or flight.ownerModel == character then
				return nil, nil
			end
			local away = position - body.position
			if away.Magnitude > T.radius or away.Magnitude < 0.1 then
				return nil, nil
			end
			local n = away.Unit
			local into = velocity:Dot(n)
			if into >= 0 then
				return nil, nil
			end
			turned[flight] = true
			R.cue(body.ctx, { fx = "repel", at = position }, position)
			return "bend", velocity - n * (2 * into)
		end,
	})
	return { effective = true, hits = 0, note = "The air round you pushes back. Bolts curve away." }
end

local function inertiaLock(ctx: Ctx): Outcome
	local T = E.inertia_lock
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0, note = "Nothing there to hold to its course." }
	end
	local v = target.root.AssemblyLinearVelocity
	local dir = Vector3.new(v.X, 0, v.Z)
	dir = if dir.Magnitude > 6 then dir.Unit else flat(target.root.Position - ctx.origin)
	local seconds = at(T.seconds, ctx)
	R.status(ctx, target.humanoid, "root", seconds)
	R.push(target, dir * T.speed + UP * 4)
	R.cue(ctx, { fx = "slide", model = target.model, dir = dir, seconds = seconds }, target.root.Position)
	return { effective = true, hits = 1 }
end

local function launch(ctx: Ctx): Outcome
	local T = E.launch
	local who = friendOrSelf(ctx)
	if not who then
		return { effective = false, hits = 0 }
	end
	local dir = flat(ctx.root.CFrame.LookVector)
	R.push(who, dir * at(T.forward, ctx) + UP * at(T.up, ctx))
	R.cue(ctx, { fx = "launch", at = who.root.Position, dir = dir }, who.root.Position)
	return { effective = true, hits = 1 }
end

-- ─── Lightning ──────────────────────────────────────────────────────────────

local function nearestFoe(ctx: Ctx, from: Vector3, reach: number): Hit?
	for _, hit in Targeting.inRadius(from, reach, 6, { [ctx.character] = true }) do
		if Targeting.canHarm(ctx.player, hit.model) then
			return hit
		end
	end
	return nil
end

local function ballLightning(ctx: Ctx): Outcome
	local T = E.ball_lightning
	local hits = 0
	for _, hit in foesStruck(ctx, 1) do
		R.hit(ctx, hit, T.zapShare, "charge")
		hits += 1
	end
	R.spawn({
		look = "ball_lightning",
		ctx = ctx,
		position = ctx.point + UP * 2,
		radius = T.zapRadius,
		seconds = at(T.seconds, ctx),
		every = T.zapEvery,
		move = function(body, dt)
			local foe = nearestFoe(body.ctx, body.position, T.seek)
			if foe then
				local to = foe.root.Position - body.position
				if to.Magnitude > 1 then
					R.place(body, body.position + to.Unit * math.min(to.Magnitude, T.drift * dt))
				end
			end
		end,
		tick = function(body)
			local foe = nearestFoe(body.ctx, body.position, T.zapRadius)
			if foe then
				R.hit(body.ctx, foe, T.zapShare, "charge")
				R.cue(body.ctx, { fx = "zap", from = body.position, to = foe.root.Position }, body.position)
			end
		end,
		finish = function(body)
			if not R.alive(body.ctx) then
				return
			end
			for _, hit in R.foesAround(body.ctx, body.position, T.popRadius) do
				R.hit(body.ctx, hit, T.popShare, "charge")
			end
			R.cue(body.ctx, { fx = "pop", at = body.position, radius = T.popRadius }, body.position)
		end,
	})
	return { effective = true, hits = hits }
end

local function staticField(ctx: Ctx): Outcome
	local T = E.static_field
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 18))
	R.spawn({
		look = "static_field",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			local inside = R.foesAround(body.ctx, body.position, body.radius)
			if #inside == 1 then
				R.hit(body.ctx, inside[1], T.aloneShare)
				return
			end
			local ends: { Vector3 } = {}
			local arcs = 0
			for i = 1, #inside do
				for j = i + 1, #inside do
					if arcs >= T.maxArcs then
						break
					end
					local a, b = inside[i], inside[j]
					if (a.root.Position - b.root.Position).Magnitude <= T.arcReach then
						arcs += 1
						R.hit(body.ctx, a, T.share)
						R.hit(body.ctx, b, T.share)
						table.insert(ends, a.root.Position)
						table.insert(ends, b.root.Position)
					end
				end
			end
			if arcs > 0 then
				R.cue(body.ctx, { fx = "arcs", points = ends }, body.position)
			end
		end,
	})
	return { effective = true, hits = 0, note = "The air crackles. Anyone standing close to someone else inside will feel it." }
end

local function arcTether(ctx: Ctx): Outcome
	local T = E.arc_tether
	local struck = foesStruck(ctx, 2)
	local a = struck[1]
	if not a then
		return fallback(ctx, "Impact", {})
	end
	local b = struck[2]
	if not b then
		for _, hit in Targeting.inRadius(a.root.Position, T.findReach, 6, { [a.model] = true, [ctx.character] = true }) do
			if Targeting.canHarm(ctx.player, hit.model) then
				b = hit
				break
			end
		end
	end
	if not b then
		return fallback(ctx, "Impact", {})
	end
	local pa, pb = a, b
	R.spawn({
		look = "arc_tether",
		ctx = ctx,
		position = (pa.root.Position + pb.root.Position) / 2,
		radius = E.caps.tetherReach,
		seconds = at(T.seconds, ctx),
		every = T.every,
		links = { A = pa.root, B = pb.root },
		move = function(body, _dt)
			if not pa.model.Parent or not pb.model.Parent or pa.humanoid.Health <= 0 or pb.humanoid.Health <= 0 then
				R.endBody(body)
				return
			end
			R.place(body, (pa.root.Position + pb.root.Position) / 2)
		end,
		tick = function(body)
			if (pa.root.Position - pb.root.Position).Magnitude > E.caps.tetherReach then
				R.hit(body.ctx, pa, T.snapShare, "charge")
				R.hit(body.ctx, pb, T.snapShare, "charge")
				R.cue(body.ctx, { fx = "snap", from = pa.root.Position, to = pb.root.Position }, body.position)
				R.endBody(body)
				return
			end
			R.hit(body.ctx, pa, T.share)
			R.hit(body.ctx, pb, T.share)
		end,
	})
	return { effective = true, hits = 2, note = "An arc ties them together. If they pull apart, it snaps." }
end

local function galvanise(ctx: Ctx): Outcome
	local T = E.galvanise
	local who = friendOrSelf(ctx)
	if not who then
		return { effective = false, hits = 0 }
	end
	local seconds = at(T.seconds, ctx)
	R.status(ctx, who.humanoid, "haste", seconds)
	R.spawn({
		look = "galvanise",
		ctx = ctx,
		position = who.root.Position,
		radius = 2,
		seconds = seconds,
		links = { Model = who.model },
		data = { wielder = who.model },
		move = follow(who.model),
	})
	return { effective = true, hits = 1 }
end

local function arcFence(ctx: Ctx): Outcome
	local T = E.arc_fence
	local length = at(T.length, ctx)
	local dir = aimDir(ctx)
	local right = dir:Cross(UP).Unit
	local center = ground(ctx.point)
	local a, b = center - right * (length / 2), center + right * (length / 2)
	R.spawn({
		look = "arc_fence",
		ctx = ctx,
		position = center,
		radius = length / 2,
		seconds = at(T.seconds, ctx),
		every = 0.2,
		cframe = CFrame.fromMatrix(center + UP * 2.5, right, UP),
		size = Vector3.new(length, 5, 0.5),
		data = { gap = {} },
		tick = function(body)
			local now = os.clock()
			for _, hit in R.foesAround(body.ctx, center, length / 2 + T.reach) do
				local p = hit.root.Position
				local ab = b - a
				local t = math.clamp((p - a):Dot(ab) / ab:Dot(ab), 0, 1)
				local closest = a + ab * t
				local off = Vector3.new(p.X - closest.X, 0, p.Z - closest.Z).Magnitude
				if off <= T.reach and math.abs(p.Y - closest.Y) < 7 and (body.data.gap[hit.model] or 0) <= now then
					body.data.gap[hit.model] = now + T.gap
					R.hit(body.ctx, hit, T.share, "charge")
					R.status(body.ctx, hit.humanoid, "dazed", T.dazeSeconds)
					R.cue(body.ctx, { fx = "zap", from = closest + UP * 2.5, to = p }, p)
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "A crackling fence stands where you point." }
end

-- ─── Dispatch ───────────────────────────────────────────────────────────────

local MOVES: { [string]: (Ctx) -> Outcome } = {
	ember_swarm = emberSwarm,
	fire_whip = fireWhip,
	flame_serpent = flameSerpent,
	ring_of_fire = ringOfFire,
	smother = smother,
	kindle = kindle,
	ice_spike_line = iceSpikeLine,
	frost_lance = frostLance,
	hoarfrost = hoarfrost,
	ice_mirror = iceMirror,
	flurry = flurry,
	heat_haze = heatHaze,
	boil = boil,
	searing_ground = searingGround,
	prism_bolt = prismBolt,
	sunspot = sunspot,
	wisps = wisps,
	flash = flash,
	glowing_poison = glowingPoison,
	shadow_grasp = shadowGrasp,
	shade_cloak = shadeCloak,
	shadow_puppet = shadowPuppet,
	stomp = stomp,
	ricochet = ricochet,
	repulse = repulse,
	inertia_lock = inertiaLock,
	launch = launch,
	ball_lightning = ballLightning,
	static_field = staticField,
	arc_tether = arcTether,
	galvanise = galvanise,
	arc_fence = arcFence,
}
EnergyArt.moves = MOVES

function EnergyArt.resolve(ctx: Ctx, params: { [string]: any }): Outcome
	if ctx.backfire then
		return fallback(ctx, "Impact", {})
	end
	local move = MOVES[params.move]
	if not move then
		return { effective = false, hits = 0 }
	end
	return move(ctx)
end

return EnergyArt
