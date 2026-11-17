--!strict
--[[
	AirArt: Air's own spells (docs/DomainIdeas.md, "Air"). Ordinary moves that fit their branch, each
	reached by a narrow route in Data/EffectLibrary ("air_" .. move, with params.move). Numbers:
	Data/AirTuning. Anything that lasts runs in Cast/ArtRuntime; looks in Client/Fx/AirFx (cue kind "air",
	bodies drawn through Fx/ArtFx).

	Windshaping, Tempest, Vacuity
		wind_blade     a fast crescent of wind that cuts its target and on through whoever stands behind
		gale           a cone of wind that throws everyone in front of you back
		twister        a small tornado wanders after people, throwing them up as it passes
		updraft        a column of rising air: anyone standing in it is lifted (you can ride it up)
		airless        the air round someone's head is gone: they choke and can't cast for a moment
		pressure_bomb  the air pulls in to a point, then blows out, hurling everyone away
		tailwind       wind at your back: you and allies near you run faster for a while
		windwall       a wall of wind that turns other people's bolts aside and shoves back anyone walking in
	Sonics, Echolocation, Thunderclap
		sonic_ring     a ring of sound runs along your aim, hitting and dazing everyone in its way
		shatter        a high note breaks conjured stone, ice and crystal where you aim; frozen people shatter too
		echo_pulse     a pulse only you hear back: everyone near is outlined to you for a moment, even through walls
		thunder_boom   a deafening crack: everyone near is dazed and thrown back
	Weathercraft, Rainmaking, Stormbrewing
		raincloud      a little cloud follows your target, raining on them (fires on them go out)
		call_lightning lightning from the sky where you aim; someone under your raincloud is always found, and hit harder
		hail           hailstones fall on marked spots

	A backfire lands on the caster as any harmful spell's does (Effects/Impact).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Types = require(Shared.Magic.Types)
local E = require(Shared.Magic.Data.AirTuning)

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local DamageModel = require(Cast.DamageModel)
local FireSim = require(Cast.FireSim)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local R = require(Cast.ArtRuntime)

type Ctx = CastTypes.EffectContext
type Outcome = CastTypes.Outcome
type Hit = Targeting.Hit

local UP = Vector3.new(0, 1, 0)

local flat, aimDir, ground, foesStruck, isPlayer, cone = R.flat, R.aimDir, R.ground, R.foesStruck, R.isPlayer, R.cone

local AirArt = {}

function AirArt.precheck(_params: { [string]: any }, _stats: Types.SpellStats, _player: Player): string?
	if FeatureFlags.get("air_arts_enabled") == false then
		return "WORLD_STRAINED"
	end
	if R.count() >= R.caps.server then
		return "WORLD_STRAINED"
	end
	return nil
end

local function at(curve: E.Curve, ctx: Ctx): number
	return E.at(curve, ctx.stats.recipe.power)
end

local function cue(ctx: Ctx, fields: { [string]: any }, position: Vector3, heavy: boolean?)
	R.cue(ctx, fields, position, heavy, "air")
end

local function friendsAround(ctx: Ctx, center: Vector3, radius: number): { Hit }
	local out: { Hit } = {}
	for _, hit in Targeting.inRadius(center, radius, 12) do
		if hit.model == ctx.character or (Targeting.canHelp(ctx.player, hit.model) and not Targeting.canHarm(ctx.player, hit.model)) then
			table.insert(out, hit)
		end
	end
	return out
end

local function rotateY(v: Vector3, degrees: number): Vector3
	return CFrame.Angles(0, math.rad(degrees), 0):VectorToWorldSpace(v)
end

-- Rained on by this caster's cloud (the Raincloud's body follows them).
local function soakedBy(owner: number, model: Model): boolean
	for _, body in R.bodiesOf(owner, "raincloud") do
		if body.data.model == model then
			return true
		end
	end
	return false
end

-- ─── Windshaping, Tempest, Vacuity ──────────────────────────────────────────

local function windBlade(ctx: Ctx): Outcome
	local T = E.wind_blade
	local dir = aimDir(ctx)
	local hits = 0
	local skip: { Instance } = { ctx.character }
	local main = foesStruck(ctx, 1)[1]
	local from = ctx.point
	if main then
		R.hit(ctx, main, T.share)
		R.push(main, dir * T.knock + UP * 6)
		table.insert(skip, main.model)
		from = main.root.Position
		hits += 1
	end
	-- It cuts on through whoever stands behind.
	local count = 0
	for _, hit in Targeting.alongBeam(from, from + dir * T.reach, 2, T.pierce + 2, skip) do
		if count >= T.pierce then
			break
		end
		if Targeting.canHarm(ctx.player, hit.model) then
			R.hit(ctx, hit, T.share * 0.7)
			count += 1
			hits += 1
		end
	end
	cue(ctx, { fx = "slice", from = from, to = from + dir * (if count > 0 then T.reach else 6) }, from)
	return { effective = hits > 0, hits = hits }
end

local function gale(ctx: Ctx): Outcome
	local T = E.gale
	local reach = at(T.reach, ctx)
	local dir = aimDir(ctx)
	local hits = 0
	for _, hit in cone(ctx, reach, T.arc, 10) do
		R.hit(ctx, hit, T.share)
		R.push(hit, dir * at(T.push, ctx) + UP * 12)
		hits += 1
	end
	cue(ctx, { fx = "gale", from = ctx.origin, dir = dir, reach = reach, arc = T.arc }, ctx.origin)
	return { effective = hits > 0, hits = hits, note = if hits == 0 then "The wind roars out, and finds nobody." else nil }
end

local function twister(ctx: Ctx): Outcome
	local T = E.twister
	for _, body in R.bodiesOf(ctx.player.UserId, "twister") do
		R.endBody(body)
	end
	R.spawn({
		look = "twister",
		ctx = ctx,
		position = ground(ctx.point),
		radius = T.radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		data = { wander = ctx.rng:NextNumber() * math.pi * 2, thrown = {} },
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
			R.place(body, ground(body.position + dir * T.speed * dt))
		end,
		tick = function(body)
			local now = os.clock()
			for _, hit in R.foesAround(body.ctx, body.position, T.radius) do
				R.hit(body.ctx, hit, T.share)
				-- Thrown up and round once a second at most (it would juggle them otherwise).
				if (body.data.thrown[hit.model] or 0) <= now then
					body.data.thrown[hit.model] = now + 1
					local around = flat(hit.root.Position - body.position):Cross(UP)
					R.push(hit, UP * T.lift + around * 14)
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "A twister spins up and goes looking for someone." }
end

local function updraft(ctx: Ctx): Outcome
	local T = E.updraft
	local height = at(T.height, ctx)
	R.spawn({
		look = "updraft",
		ctx = ctx,
		position = ground(ctx.point),
		radius = T.radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		-- Players ride it on their own client (a standing Humanoid pins itself against a server push:
		-- Client/Fx/AirFx carries them up to Height and holds them there); NPCs and creatures are pushed here.
		attrs = { Height = height, RiseSpeed = T.riseSpeed },
		tick = function(body)
			for _, hit in Targeting.inRadius(body.position + UP * (height / 2), T.radius + height / 2, 12) do
				local rel = hit.root.Position - body.position
				if not isPlayer(hit) and Vector3.new(rel.X, 0, rel.Z).Magnitude <= T.radius and rel.Y > -2 and rel.Y < height then
					R.push(hit, UP * T.lift)
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "Air rises where you point. Step in and it lifts you." }
end

local function airless(ctx: Ctx): Outcome
	local T = E.airless
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0, note = "The air thins, and there's nobody in it." }
	end
	local seconds = at(T.seconds, ctx)
	if isPlayer(target) then
		seconds = math.min(seconds, T.pvpSeconds)
	end
	R.hit(ctx, target, T.share)
	R.status(ctx, target.humanoid, "silence", seconds)
	R.status(ctx, target.humanoid, "suffocating", T.chokeSeconds, DamageModel.base(ctx.power) * T.chokeShare)
	cue(ctx, { fx = "airless", model = target.model, seconds = seconds }, target.root.Position)
	return { effective = true, hits = 1 }
end

local function pressureBomb(ctx: Ctx): Outcome
	local T = E.pressure_bomb
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 16))
	local center = ctx.point
	for _, hit in R.foesAround(ctx, center, radius) do
		R.push(hit, flat(center - hit.root.Position) * T.pull)
	end
	cue(ctx, { fx = "implode", at = center, radius = radius, seconds = T.pullTime }, center, true)
	local c = R.later(ctx)
	task.delay(T.pullTime, function()
		if not R.alive(c) then
			return
		end
		for _, hit in R.foesAround(c, center, radius) do
			R.hit(c, hit, T.share)
			R.push(hit, flat(hit.root.Position - center) * T.push + UP * 18)
		end
		cue(c, { fx = "blast", at = center, radius = radius }, center, true)
	end)
	return { effective = true, hits = 0 }
end

local function tailwind(ctx: Ctx): Outcome
	local T = E.tailwind
	local seconds = at(T.seconds, ctx)
	local count = 0
	for _, hit in friendsAround(ctx, ctx.origin, T.radius) do
		R.status(ctx, hit.humanoid, "haste", seconds)
		count += 1
	end
	-- One lasting look, on you (the wind streaming past); friends just run faster.
	for _, body in R.bodiesOf(ctx.player.UserId, "tailwind") do
		R.endBody(body)
	end
	R.spawn({
		look = "tailwind",
		ctx = ctx,
		position = ctx.origin,
		radius = T.radius,
		seconds = seconds,
		links = { Model = ctx.character },
	})
	return { effective = count > 0, hits = count, note = if count > 1 then "The wind takes you and your friends along." else "The wind is at your back." }
end

local function windwall(ctx: Ctx): Outcome
	local T = E.windwall
	local width = at(T.width, ctx)
	local base = ground(ctx.point)
	local normal = flat(ctx.origin - base) -- facing the caster
	local right = normal:Cross(UP).Unit
	local center = base + UP * (T.height / 2)
	local turned: { [any]: boolean } = setmetatable({}, { __mode = "k" }) :: any
	local character = ctx.character
	R.spawn({
		look = "windwall",
		ctx = ctx,
		position = center,
		radius = width / 2,
		seconds = at(T.seconds, ctx),
		every = T.every,
		cframe = CFrame.fromMatrix(center, right, UP),
		size = Vector3.new(width, T.height, 1),
		deflect = function(_body, position: Vector3, velocity: Vector3, flight: any): (string?, any)
			if turned[flight] or flight.ownerModel == character then
				return nil, nil
			end
			local rel = position - center
			if math.abs(rel:Dot(normal)) > T.thickness or math.abs(rel:Dot(right)) > width / 2 or math.abs(rel.Y) > T.height / 2 then
				return nil, nil
			end
			turned[flight] = true
			-- Turned aside along the wall, the way it was already leaning.
			local side = if velocity:Dot(right) >= 0 then 1 else -1
			return "bend", rotateY(velocity, T.turn * side)
		end,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, center, width / 2 + T.thickness) do
				local rel = hit.root.Position - center
				local d = rel:Dot(normal)
				if math.abs(d) <= T.thickness + 1 and math.abs(rel:Dot(right)) <= width / 2 then
					R.push(hit, normal * (if d >= 0 then 1 else -1) * T.push)
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "A wall of wind stands where you point. Bolts turn aside in it." }
end

-- ─── Sonics, Echolocation, Thunderclap ──────────────────────────────────────

local function sonicRing(ctx: Ctx): Outcome
	local T = E.sonic_ring
	local dir = aimDir(ctx)
	local from = ctx.origin + UP * 1.5
	local to = from + dir * at(T.length, ctx)
	local hits = 0
	for _, hit in Targeting.alongBeam(from, to, T.width, T.maxTargets, { ctx.character }) do
		if Targeting.canHarm(ctx.player, hit.model) then
			R.hit(ctx, hit, T.share, "sound")
			R.status(ctx, hit.humanoid, "dazed", T.dazeSeconds)
			hits += 1
		end
	end
	cue(ctx, { fx = "ring", from = from, to = to }, from)
	return { effective = true, hits = hits }
end

local function shatter(ctx: Ctx): Outcome
	local T = E.shatter
	local radius = at(T.radius, ctx)
	local center = ctx.point
	local broken: { Vector3 } = {}
	local folder = workspace:FindFirstChild("ArtSolids")
	if folder then
		for _, p in folder:GetChildren() do
			if #broken >= T.breakMax then
				break
			end
			if p:IsA("BasePart") and (p.Position - center).Magnitude <= radius + p.Size.Magnitude / 2 then
				table.insert(broken, p.Position)
				p:Destroy()
			end
		end
	end
	local hits = 0
	for _, hit in R.foesAround(ctx, center, radius) do
		-- Someone frozen solid shatters: double, and the ice is gone.
		local frozen = StatusEffects.has(hit.humanoid, "frozen")
		R.hit(ctx, hit, T.share * (if frozen then 2 else 1))
		if frozen then
			StatusEffects.remove(hit.humanoid, "frozen")
			table.insert(broken, hit.root.Position)
		end
		hits += 1
	end
	cue(ctx, { fx = "shatter", at = center, radius = radius, spots = broken }, center, true)
	local note = if #broken > 0 then string.format("%d thing%s shatter.", #broken, if #broken == 1 then "" else "s") else nil
	return { effective = hits > 0 or #broken > 0, hits = hits, note = note }
end

local function echoPulse(ctx: Ctx): Outcome
	local T = E.echo_pulse
	local radius = at(T.radius, ctx)
	local seconds = at(T.seconds, ctx)
	local models: { Model } = {}
	local now = workspace:GetServerTimeNow()
	for _, hit in Targeting.inRadius(ctx.origin, radius, T.maxShown, { [ctx.character] = true }) do
		-- Void's Unseen (Effects/VoidArt) leaves no echo.
		local unseen = hit.model:GetAttribute("Unseen")
		if not (typeof(unseen) == "number" and unseen > now) then
			StatusEffects.remove(hit.humanoid, "veiled")
			table.insert(models, hit.model)
		end
	end
	-- Only the caster sees the outlines (EchoFx checks `caster`); everyone near hears the click.
	cue(ctx, { fx = "echo", at = ctx.origin, radius = radius, seconds = seconds, models = models }, ctx.origin)
	return { effective = true, hits = #models, note = if #models == 0 then "The echo comes back empty." else string.format("The echo shows you %d %s.", #models, if #models == 1 then "body" else "bodies") }
end

local function thunderBoom(ctx: Ctx): Outcome
	local T = E.thunder_boom
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 20))
	local center = ctx.point
	local hits = 0
	for _, hit in R.foesAround(ctx, center, radius) do
		R.hit(ctx, hit, T.share, nil, {})
		R.status(ctx, hit.humanoid, "dazed", T.dazeSeconds)
		R.push(hit, flat(hit.root.Position - center) * T.push + UP * 10)
		hits += 1
	end
	cue(ctx, { fx = "boom", at = center, radius = radius }, center, true)
	return { effective = true, hits = hits }
end

-- ─── Weathercraft ───────────────────────────────────────────────────────────

local function raincloud(ctx: Ctx): Outcome
	local T = E.raincloud
	local target: Hit? = Targeting.select(ctx, 1)[1]
	if not target or target.model == ctx.character then
		target = Targeting.characterOf(ctx.root)
	end
	if not target then
		return { effective = false, hits = 0 }
	end
	local model = target.model
	-- One cloud per head: a new one replaces it.
	for _, body in R.bodiesOf(ctx.player.UserId, "raincloud") do
		if body.data.model == model then
			R.endBody(body)
		end
	end
	local humanoid = target.humanoid
	R.spawn({
		look = "raincloud",
		ctx = ctx,
		position = target.root.Position,
		radius = 3,
		seconds = at(T.seconds, ctx),
		every = T.every,
		links = { Model = model },
		data = { model = model },
		move = function(body, _dt)
			local root = model:FindFirstChild("HumanoidRootPart")
			if not model.Parent or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
				R.endBody(body)
				return
			end
			R.place(body, root.Position)
		end,
		tick = function(body)
			StatusEffects.cleanse(humanoid, { "burning" })
			FireSim.extinguish(body.position, 3)
		end,
	})
	local name = if Players:GetPlayerFromCharacter(model) == ctx.player then "you" else "them"
	return { effective = true, hits = 1, note = string.format("A little cloud follows %s, raining. Lightning will find it.", name) }
end

local function callLightning(ctx: Ctx): Outcome
	local T = E.call_lightning
	local spot = ctx.point
	local owner = ctx.player.UserId
	-- Someone under your raincloud near the aim draws it to them.
	for _, body in R.bodiesOf(owner, "raincloud") do
		if (body.position - spot).Magnitude <= 25 then
			spot = body.position
			break
		end
	end
	local landing = ground(spot)
	cue(ctx, { fx = "strike_warn", at = landing, radius = T.radius, delay = T.warn }, landing, true)
	local c = R.later(ctx)
	task.delay(T.warn, function()
		if not R.alive(c) then
			return
		end
		-- A soaked target is found wherever they stepped in the warning.
		for _, body in R.bodiesOf(owner, "raincloud") do
			if (body.position - landing).Magnitude <= 12 then
				landing = ground(body.position)
				break
			end
		end
		cue(c, { fx = "strike", at = landing }, landing, true)
		for _, hit in R.foesAround(c, landing, T.radius) do
			local soaked = soakedBy(owner, hit.model)
			R.hit(c, hit, T.share * (if soaked then T.soakedMult else 1), "charge")
			R.status(c, hit.humanoid, "dazed", T.dazeSeconds)
		end
	end)
	return { effective = true, hits = 0 }
end

local function hail(ctx: Ctx): Outcome
	local T = E.hail
	local radius = at(T.radius, ctx)
	local spots: { Vector3 } = {}
	for i = 1, math.floor(at(T.stones, ctx)) do
		local angle = ctx.rng:NextNumber() * math.pi * 2
		local reach = if i == 1 then 0 else math.sqrt(ctx.rng:NextNumber()) * radius
		table.insert(spots, ground(ctx.point + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)))
	end
	cue(ctx, { fx = "hail_warn", spots = spots, delay = T.warn, radius = T.hitRadius }, ctx.point, true)
	local c = R.later(ctx)
	task.delay(T.warn, function()
		if not R.alive(c) then
			return
		end
		cue(c, { fx = "hail", spots = spots }, c.point, true)
		for i, spot in spots do
			task.delay((i - 1) * 0.04, function()
				for _, hit in R.foesAround(c, spot, T.hitRadius) do
					R.hit(c, hit, T.share, "cold")
				end
			end)
		end
	end)
	return { effective = true, hits = 0 }
end

-- ─── Dispatch ───────────────────────────────────────────────────────────────

local MOVES: { [string]: (Ctx) -> Outcome } = {
	wind_blade = windBlade,
	gale = gale,
	twister = twister,
	updraft = updraft,
	airless = airless,
	pressure_bomb = pressureBomb,
	tailwind = tailwind,
	windwall = windwall,
	sonic_ring = sonicRing,
	shatter = shatter,
	echo_pulse = echoPulse,
	thunder_boom = thunderBoom,
	raincloud = raincloud,
	call_lightning = callLightning,
	hail = hail,
}
AirArt.moves = MOVES

function AirArt.resolve(ctx: Ctx, params: { [string]: any }): Outcome
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

return AirArt
