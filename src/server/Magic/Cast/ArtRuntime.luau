--!strict
--[[
	ArtRuntime: what the domains' own spells leave running (docs/DomainIdeas.md): Energy's rings of fire,
	burning ground, frost, ice mirrors, wisps, shadow puppet, ball lightning, tethers and fences; Earth's
	spike walls, boulders, quicksand, dust, crystal spires... Effects/EnergyArt and Effects/EarthArt cast;
	this keeps them going.

	A BODY is one lasting thing. Each has a small invisible anchored part in workspace.ArtBodies, tagged
	"ArtBody" with attributes (ArtLook = the move, Owner, Radius, Ends in server time, and whatever the
	move adds), which Client/Fx/ArtFx draws with the domain's builders (Fx/EnergyFx, Fx/EarthFx). Bodies may:
		tick(body)              every `every` seconds (hurting, chilling, revealing...)
		move(body, dt)          every frame (wisps follow, a ball of lightning drifts)
		deflect(body, position, velocity, flight) -> (action, value)?   a bolt passing it (Delivery)
		ownerHit(body, victim)  their owner just hurt someone (a kindled hand, the shadow puppet)
		finish(body)            once, as it ends (a ball of lightning pops)
	Capped per player (ArtRuntime.caps.perPlayer: a new one ends the oldest) and per server.
	Every hit goes through Cast/DamageModel and Cast/Damage (wards, guards, PvP), only on people the
	caster may harm (Targeting.canHarm). Services/ArtService steps and wraps Delivery.interceptor.

	Known gap (as for Shapes): hits after the cast resolved aren't judged by settlement law.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")
local TweenService = game:GetService("TweenService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)

local Cast = script.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local EffectBudget = require(Cast.EffectBudget)
local DamageModel = require(Cast.DamageModel)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local PropertyBehaviour = require(Cast.PropertyBehaviour)

type Ctx = CastTypes.EffectContext

export type Body = {
	id: number,
	look: string,
	owner: number,
	ctx: Ctx,
	part: BasePart,
	position: Vector3,
	radius: number,
	ends: number, -- os.clock()
	every: number,
	nextTick: number,
	data: { [string]: any },
	tick: ((Body) -> ())?,
	move: ((Body, number) -> ())?,
	deflect: ((Body, Vector3, Vector3, any) -> (string?, any))?,
	ownerHit: ((Body, Humanoid) -> ())?,
	finish: ((Body) -> ())?,
	ended: boolean?,
}

export type SpawnOpts = {
	look: string,
	ctx: Ctx,
	position: Vector3,
	radius: number,
	seconds: number,
	every: number?,
	cframe: CFrame?, -- lines and panes: the part's frame (its size says how long and tall)
	size: Vector3?,
	attrs: { [string]: any }?,
	links: any?, -- { [name]: Instance }: ObjectValues under the part (a tether's two ends, a follower's Model)
	data: { [string]: any }?,
	tick: ((Body) -> ())?,
	move: ((Body, number) -> ())?,
	deflect: ((Body, Vector3, Vector3, any) -> (string?, any))?,
	ownerHit: ((Body, Humanoid) -> ())?,
	finish: ((Body) -> ())?,
}

local ArtRuntime = {}

ArtRuntime.TAG = "ArtBody"
-- Set by Services/DownedService: brings a downed player round where they lie (Life's Raise Them).
ArtRuntime.revive = nil :: ((Player, Player) -> boolean)?

ArtRuntime.caps = {
	server = 80, -- bodies on the whole server, every domain together
	perPlayer = 8, -- a ninth ends the caster's oldest
}

local bodies: { Body } = {}
local nextId = 0
local log: any = nil

local function folder(): Folder
	local f = workspace:FindFirstChild("ArtBodies")
	if f and f:IsA("Folder") then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "ArtBodies"
	made.Parent = workspace
	return made
end

-- A frozen copy of the cast for work that happens later (the live one is reused by echoes).
function ArtRuntime.later(ctx: Ctx): Ctx
	local copy = table.clone(ctx)
	copy.delivered = nil
	copy.target = nil
	return copy
end

function ArtRuntime.alive(ctx: Ctx): boolean
	local player: Player? = ctx.player
	return player ~= nil and player.Parent ~= nil and ctx.character.Parent ~= nil
end

function ArtRuntime.endBody(body: Body)
	if body.ended then
		return
	end
	body.ended = true
	for i, b in bodies do
		if b == body then
			table.remove(bodies, i)
			break
		end
	end
	if body.finish then
		local ok, err = pcall(body.finish, body)
		if not ok then
			warn("[Art] finish " .. body.look .. ": " .. tostring(err))
		end
	end
	body.part:Destroy()
end

function ArtRuntime.bodiesOf(owner: number, look: string?): { Body }
	local out: { Body } = {}
	for _, b in bodies do
		if b.owner == owner and (look == nil or b.look == look) then
			table.insert(out, b)
		end
	end
	return out
end

function ArtRuntime.spawn(opts: SpawnOpts): Body?
	local caster: Player? = opts.ctx.player
	local owner = if caster then caster.UserId else 0
	-- The caster's oldest gives way to a new one; the server as a whole has a ceiling.
	local mine = ArtRuntime.bodiesOf(owner)
	if #mine >= ArtRuntime.caps.perPlayer then
		ArtRuntime.endBody(mine[1])
	end
	if #bodies >= ArtRuntime.caps.server then
		return nil
	end
	nextId += 1
	local part = Instance.new("Part")
	part.Name = opts.look
	part.Anchored = true
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Transparency = 1
	part.Size = opts.size or Vector3.one
	part.CFrame = opts.cframe or CFrame.new(opts.position)
	part:SetAttribute("ArtLook", opts.look)
	part:SetAttribute("Owner", owner)
	part:SetAttribute("Radius", opts.radius)
	part:SetAttribute("Ends", workspace:GetServerTimeNow() + opts.seconds)
	part:SetAttribute("Power", opts.ctx.stats.recipe.power)
	for k, v in (opts.attrs or {}) :: { [string]: any } do
		part:SetAttribute(k, v)
	end
	for name, target in (opts.links or {}) :: { [string]: Instance } do
		local link = Instance.new("ObjectValue")
		link.Name = name
		link.Value = target
		link.Parent = part
	end
	part.Parent = folder()
	CollectionService:AddTag(part, ArtRuntime.TAG)
	local now = os.clock()
	local body: Body = {
		id = nextId,
		look = opts.look,
		owner = owner,
		ctx = ArtRuntime.later(opts.ctx),
		part = part,
		position = opts.position,
		radius = opts.radius,
		ends = now + opts.seconds,
		every = opts.every or 1,
		nextTick = now + (opts.every or 1),
		data = opts.data or {},
		tick = opts.tick,
		move = opts.move,
		deflect = opts.deflect,
		ownerHit = opts.ownerHit,
		finish = opts.finish,
	}
	table.insert(bodies, body)
	return body
end

-- Moves a body's part (and where it counts from).
function ArtRuntime.place(body: Body, position: Vector3)
	body.position = position
	body.part.CFrame = CFrame.new(position)
end

-- ─── Hit helpers (shared with Effects/EnergyArt) ────────────────────────────

-- One hit of `share` of a normal one, plus `behaviour` (Data/PropertyBehaviours) when given.
function ArtRuntime.hit(ctx: Ctx, hit: Targeting.Hit, share: number, behaviour: string?, opts: DamageModel.Options?): number
	local dealt, result = DamageModel.hit(ctx, hit, share, "energy", opts or { noFalloff = true })
	if behaviour then
		PropertyBehaviour.apply(ctx, hit, dealt, result, behaviour)
	end
	return dealt
end

-- Everyone the caster may harm around `center` (never the caster).
function ArtRuntime.foesAround(ctx: Ctx, center: Vector3, radius: number, exclude: { [Model]: boolean }?): { Targeting.Hit }
	local skip = exclude or {}
	skip[ctx.character] = true
	local out: { Targeting.Hit } = {}
	for _, hit in Targeting.inRadius(center, radius, math.max(ctx.stats.maxTargets, 8), skip) do
		if ctx.player and Targeting.canHarm(ctx.player, hit.model) then
			table.insert(out, hit)
		end
	end
	return out
end

-- Sets someone alight for `seconds`, burning `share` of a normal hit each second.
function ArtRuntime.burn(ctx: Ctx, humanoid: Humanoid, seconds: number, share: number)
	StatusEffects.apply(humanoid, "burning", {
		duration = seconds,
		magnitude = DamageModel.base(ctx.power) * share,
		source = if ctx.player then ctx.player.UserId else nil,
	})
end

function ArtRuntime.status(ctx: Ctx, humanoid: Humanoid, id: string, seconds: number, magnitude: number?)
	StatusEffects.apply(humanoid, id, {
		duration = seconds,
		magnitude = magnitude,
		source = if ctx.player then ctx.player.UserId else nil,
	})
end

-- A push: a player's own client moves them (as Force and Shapes do), anything else here.
function ArtRuntime.push(hit: Targeting.Hit, velocity: Vector3)
	local player = Players:GetPlayerFromCharacter(hit.model)
	if player then
		Net.fire("WorldEffect", player, { kind = "knockback", velocity = velocity })
	else
		hit.root.AssemblyLinearVelocity += velocity
	end
end

-- Drags someone to `to` (a vine, a riptide, a magnet: a pull that has to arrive). A push alone is eaten
-- by ground friction within a couple of studs (owner, 2026-11-17: Vine Lash moved people ~2 studs), so:
-- a player gets a hop timed to land them there (their own client flies it); anyone else (NPCs, creatures,
-- practice dummies, anchored or not) is moved there over `seconds`.
local GRAVITY = 196.2
function ArtRuntime.drag(hit: Targeting.Hit, to: Vector3, seconds: number?)
	local t = math.clamp(seconds or 0.4, 0.15, 1)
	local from = hit.root.Position
	local flat = Vector3.new(to.X - from.X, 0, to.Z - from.Z)
	if flat.Magnitude < 1 then
		return
	end
	local player = Players:GetPlayerFromCharacter(hit.model)
	if player then
		-- Across in `t`, rising enough to land at the same height (gravity brings it back).
		local velocity = flat / t + Vector3.new(0, 0.5 * GRAVITY * t + (to.Y - from.Y) / t, 0)
		Net.fire("WorldEffect", player, { kind = "knockback", velocity = velocity })
		return
	end
	local model = hit.model
	local start = model:GetPivot()
	local goal = start + flat
	task.spawn(function()
		local steps = math.max(3, math.floor(t / 0.03))
		for i = 1, steps do
			if not model.Parent then
				return
			end
			local a = i / steps
			local eased = 1 - (1 - a) * (1 - a)
			-- A little arc so it reads as being pulled off the ground.
			model:PivotTo(start:Lerp(goal, eased) + Vector3.new(0, math.sin(a * math.pi) * 2, 0))
			task.wait(t / steps)
		end
	end)
end

-- A one-shot look for every client near: cue kind `kind` ("energy" -> Client/Fx/EnergyFx, "earth" -> EarthFx).
function ArtRuntime.cue(ctx: Ctx, fields: { [string]: any }, position: Vector3, heavy: boolean?, kind: string?)
	local payload: { [string]: any } = {
		caster = if ctx.player then ctx.player.UserId else nil,
		power = ctx.stats.recipe.power,
		masteryTier = ctx.stats.masteryTier,
	}
	for k, v in fields do
		payload[k] = v
	end
	ctx.runtime:cue(kind or "energy", payload, position, heavy == true)
end

-- ─── Shared helpers for the domains' resolvers (EnergyArt, EarthArt, WaterArt) ───

local groundParams = RaycastParams.new()
groundParams.FilterType = Enum.RaycastFilterType.Exclude

function ArtRuntime.flat(v: Vector3): Vector3
	local f = Vector3.new(v.X, 0, v.Z)
	return if f.Magnitude > 0.01 then f.Unit else Vector3.new(0, 0, -1)
end

function ArtRuntime.aimDir(ctx: CastTypes.EffectContext): Vector3
	local d = ctx.point - ctx.origin
	if Vector3.new(d.X, 0, d.Z).Magnitude < 0.5 then
		return ArtRuntime.flat(ctx.root.CFrame.LookVector)
	end
	return ArtRuntime.flat(d)
end

function ArtRuntime.ground(position: Vector3): Vector3
	local ignore: { Instance } = {}
	local bodiesFolder = workspace:FindFirstChild("ArtBodies")
	if bodiesFolder then
		table.insert(ignore, bodiesFolder)
	end
	local solids = workspace:FindFirstChild("ArtSolids")
	if solids then
		table.insert(ignore, solids)
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

function ArtRuntime.foesStruck(ctx: CastTypes.EffectContext, max: number?): { Targeting.Hit }
	local out: { Targeting.Hit } = {}
	for _, hit in Targeting.select(ctx, max) do
		if hit.model ~= ctx.character and Targeting.canHarm(ctx.player, hit.model) then
			table.insert(out, hit)
		end
	end
	return out
end

function ArtRuntime.isPlayer(hit: Targeting.Hit): boolean
	return Players:GetPlayerFromCharacter(hit.model) ~= nil
end

function ArtRuntime.solidFolder(): Folder
	local f = workspace:FindFirstChild("ArtSolids")
	if f and f:IsA("Folder") then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "ArtSolids"
	made.Parent = workspace
	return made
end

-- Is anyone standing where a solid part would go? (It must never close round a body.)
function ArtRuntime.bodyInside(cframe: CFrame, size: Vector3): boolean
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ArtRuntime.solidFolder() }
	for _, part in workspace:GetPartBoundsInBox(cframe, size + Vector3.new(0.6, 0.6, 0.6), params) do
		if Targeting.characterOf(part) then
			return true
		end
	end
	return false
end

-- A real standing thing (stone, ice, cloud): anchored, blocks and holds weight, unless someone stands
-- where it rises (then it stays passable). Sinks and fades after `seconds`. Nil when the part budget is
-- spent. Defaults to grey Slate; `props` sets anything else.
function ArtRuntime.solid(props: { [string]: any }, seconds: number): Part?
	if EffectBudget.takeParts(1) < 1 then
		return nil
	end
	local p = Instance.new("Part")
	p.Name = "ArtSolid"
	p.Anchored = true
	p.CanQuery = true
	p.CanTouch = false
	p.Material = Enum.Material.Slate
	p.Color = Color3.fromRGB(120, 112, 104)
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	for k, v in props do
		(p :: any)[k] = v
	end
	p.CanCollide = props.CanCollide ~= false and not ArtRuntime.bodyInside(p.CFrame, p.Size)
	p.Parent = ArtRuntime.solidFolder()
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

function ArtRuntime.cone(ctx: CastTypes.EffectContext, reach: number, arc: number, max: number): { Targeting.Hit }
	local out: { Targeting.Hit } = {}
	for _, hit in Targeting.inCone(ctx.origin, ArtRuntime.aimDir(ctx), reach, arc / 2, max, { [ctx.character] = true }) do
		if Targeting.canHarm(ctx.player, hit.model) then
			table.insert(out, hit)
		end
	end
	return out
end

-- ─── Stepping ───────────────────────────────────────────────────────────────

local function stepBody(body: Body, now: number, dt: number)
	if now >= body.ends or not ArtRuntime.alive(body.ctx) or not body.part.Parent then
		ArtRuntime.endBody(body)
		return
	end
	if body.move then
		body.move(body, dt)
	end
	if body.tick and now >= body.nextTick and not body.ended then
		body.nextTick += body.every
		body.tick(body)
	end
end

function ArtRuntime.step(dt: number)
	if #bodies == 0 then
		return
	end
	local now = os.clock()
	for i = #bodies, 1, -1 do
		local body = bodies[i]
		if body then
			local ok, err = pcall(stepBody, body, now, dt)
			if not ok then
				if log then
					log:throttled("art_" .. body.look, 30, "Warn", "art_step_failed", { look = body.look, err = err })
				end
				ArtRuntime.endBody(body)
			end
		end
	end
end

-- Delivery.interceptor's say: the first body that turns this bolt wins.
function ArtRuntime.intercept(position: Vector3, velocity: Vector3, flight: any): (string?, any)
	for _, body in bodies do
		if body.deflect and not body.ended then
			local action, value = body.deflect(body, position, velocity, flight)
			if action then
				return action, value
			end
		end
	end
	return nil, nil
end

-- Damage.listenAttacked: bodies that care hear when their wielder (data.wielder, a Model: a kindled
-- ally) or, without one, their owner's character lands a blow.
function ArtRuntime.attacked(victim: Humanoid, attacker: Model)
	local player = Players:GetPlayerFromCharacter(attacker)
	for _, body in bodies do
		local wielder = body.data.wielder
		local mine = if wielder ~= nil then wielder == attacker else (player ~= nil and body.owner == player.UserId)
		if body.ownerHit and mine and not body.ended then
			local ok, err = pcall(body.ownerHit, body, victim)
			if not ok then
				warn("[Art] ownerHit " .. body.look .. ": " .. tostring(err))
			end
		end
	end
end

function ArtRuntime.clear(owner: number?): number
	local n = 0
	for i = #bodies, 1, -1 do
		local body = bodies[i]
		if owner == nil or body.owner == owner then
			ArtRuntime.endBody(body)
			n += 1
		end
	end
	return n
end

-- Every running body (a copy): Void's Unravel and Null Ground end other people's.
function ArtRuntime.all(): { Body }
	return table.clone(bodies)
end

function ArtRuntime.count(): number
	return #bodies
end

function ArtRuntime.report(): string
	if #bodies == 0 then
		return "no domain spells running"
	end
	local lines: { string } = {}
	local now = os.clock()
	for _, b in bodies do
		table.insert(lines, string.format("%s by %d: %.0f s left, radius %.0f", b.look, b.owner, b.ends - now, b.radius))
	end
	return string.format("%d running\n%s", #bodies, table.concat(lines, "\n"))
end

function ArtRuntime.start(logger: any)
	log = logger
	Damage.listenAttacked(ArtRuntime.attacked)
end

return ArtRuntime
