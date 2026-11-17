--!strict
--[[
	EnergyRuntime: what Energy's spells leave running (docs/DomainIdeas.md, "Energy"): rings of fire,
	burning ground, frost, smoke, ice mirrors, wisps, a shadow puppet, balls of lightning, tethers,
	fences, kindled hands, auras. Effects/EnergyArt casts; this keeps them going.

	A BODY is one lasting thing. Each has a small invisible anchored part in workspace.EnergyBodies,
	tagged "EnergyBody" with attributes (EnergyLook = the move, Owner, Radius, Ends in server time, and
	whatever the move adds), which Client/Fx/EnergyFx draws. Bodies may:
		tick(body)              every `every` seconds (hurting, chilling, revealing...)
		move(body, dt)          every frame (wisps follow, a ball of lightning drifts)
		deflect(body, position, velocity, flight) -> (action, value)?   a bolt passing it (Delivery)
		ownerHit(body, victim)  their owner just hurt someone (a kindled hand, the shadow puppet)
		finish(body)            once, as it ends (a ball of lightning pops)
	Capped per player (Data/EnergyTuning.caps.perPlayer: a new one ends the oldest) and per server.
	Every hit goes through Cast/DamageModel and Cast/Damage (wards, guards, PvP), only on people the
	caster may harm (Targeting.canHarm). Services/EnergyService steps and wraps Delivery.interceptor.

	Known gap (as for Shapes): hits after the cast resolved aren't judged by settlement law.
]]

local CollectionService = game:GetService("CollectionService")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local E = require(Shared.Magic.Data.EnergyTuning)

local Cast = script.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
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

local EnergyRuntime = {}

EnergyRuntime.TAG = "EnergyBody"

local bodies: { Body } = {}
local nextId = 0
local log: any = nil

local function folder(): Folder
	local f = workspace:FindFirstChild("EnergyBodies")
	if f and f:IsA("Folder") then
		return f
	end
	local made = Instance.new("Folder")
	made.Name = "EnergyBodies"
	made.Parent = workspace
	return made
end

-- A frozen copy of the cast for work that happens later (the live one is reused by echoes).
function EnergyRuntime.later(ctx: Ctx): Ctx
	local copy = table.clone(ctx)
	copy.delivered = nil
	copy.target = nil
	return copy
end

function EnergyRuntime.alive(ctx: Ctx): boolean
	return ctx.player ~= nil and ctx.player.Parent ~= nil and ctx.character.Parent ~= nil
end

function EnergyRuntime.endBody(body: Body)
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
			warn("[Energy] finish " .. body.look .. ": " .. tostring(err))
		end
	end
	body.part:Destroy()
end

function EnergyRuntime.bodiesOf(owner: number, look: string?): { Body }
	local out: { Body } = {}
	for _, b in bodies do
		if b.owner == owner and (look == nil or b.look == look) then
			table.insert(out, b)
		end
	end
	return out
end

function EnergyRuntime.spawn(opts: SpawnOpts): Body?
	local caster: Player? = opts.ctx.player
	local owner = if caster then caster.UserId else 0
	-- The caster's oldest gives way to a new one; the server as a whole has a ceiling.
	local mine = EnergyRuntime.bodiesOf(owner)
	if #mine >= E.caps.perPlayer then
		EnergyRuntime.endBody(mine[1])
	end
	if #bodies >= E.caps.server then
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
	part:SetAttribute("EnergyLook", opts.look)
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
	CollectionService:AddTag(part, EnergyRuntime.TAG)
	local now = os.clock()
	local body: Body = {
		id = nextId,
		look = opts.look,
		owner = owner,
		ctx = EnergyRuntime.later(opts.ctx),
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
function EnergyRuntime.place(body: Body, position: Vector3)
	body.position = position
	body.part.CFrame = CFrame.new(position)
end

-- ─── Hit helpers (shared with Effects/EnergyArt) ────────────────────────────

-- One hit of `share` of a normal one, plus `behaviour` (Data/PropertyBehaviours) when given.
function EnergyRuntime.hit(ctx: Ctx, hit: Targeting.Hit, share: number, behaviour: string?, opts: DamageModel.Options?): number
	local dealt, result = DamageModel.hit(ctx, hit, share, "energy", opts or { noFalloff = true })
	if behaviour then
		PropertyBehaviour.apply(ctx, hit, dealt, result, behaviour)
	end
	return dealt
end

-- Everyone the caster may harm around `center` (never the caster).
function EnergyRuntime.foesAround(ctx: Ctx, center: Vector3, radius: number, exclude: { [Model]: boolean }?): { Targeting.Hit }
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
function EnergyRuntime.burn(ctx: Ctx, humanoid: Humanoid, seconds: number, share: number)
	StatusEffects.apply(humanoid, "burning", {
		duration = seconds,
		magnitude = DamageModel.base(ctx.power) * share,
		source = if ctx.player then ctx.player.UserId else nil,
	})
end

function EnergyRuntime.status(ctx: Ctx, humanoid: Humanoid, id: string, seconds: number, magnitude: number?)
	StatusEffects.apply(humanoid, id, {
		duration = seconds,
		magnitude = magnitude,
		source = if ctx.player then ctx.player.UserId else nil,
	})
end

-- A push: a player's own client moves them (as Force and Shapes do), anything else here.
function EnergyRuntime.push(hit: Targeting.Hit, velocity: Vector3)
	local player = Players:GetPlayerFromCharacter(hit.model)
	if player then
		Net.fire("WorldEffect", player, { kind = "knockback", velocity = velocity })
	else
		hit.root.AssemblyLinearVelocity += velocity
	end
end

-- A one-shot look for every client near (Client/Fx/EnergyFx).
function EnergyRuntime.cue(ctx: Ctx, fields: { [string]: any }, position: Vector3, heavy: boolean?)
	local payload: { [string]: any } = {
		caster = if ctx.player then ctx.player.UserId else nil,
		power = ctx.stats.recipe.power,
		masteryTier = ctx.stats.masteryTier,
	}
	for k, v in fields do
		payload[k] = v
	end
	ctx.runtime:cue("energy", payload, position, heavy == true)
end

-- ─── Stepping ───────────────────────────────────────────────────────────────

local function stepBody(body: Body, now: number, dt: number)
	if now >= body.ends or not EnergyRuntime.alive(body.ctx) or not body.part.Parent then
		EnergyRuntime.endBody(body)
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

function EnergyRuntime.step(dt: number)
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
					log:throttled("energy_" .. body.look, 30, "Warn", "energy_step_failed", { look = body.look, err = err })
				end
				EnergyRuntime.endBody(body)
			end
		end
	end
end

-- Delivery.interceptor's say: the first body that turns this bolt wins.
function EnergyRuntime.intercept(position: Vector3, velocity: Vector3, flight: any): (string?, any)
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
function EnergyRuntime.attacked(victim: Humanoid, attacker: Model)
	local player = Players:GetPlayerFromCharacter(attacker)
	for _, body in bodies do
		local wielder = body.data.wielder
		local mine = if wielder ~= nil then wielder == attacker else (player ~= nil and body.owner == player.UserId)
		if body.ownerHit and mine and not body.ended then
			local ok, err = pcall(body.ownerHit, body, victim)
			if not ok then
				warn("[Energy] ownerHit " .. body.look .. ": " .. tostring(err))
			end
		end
	end
end

function EnergyRuntime.clear(owner: number?): number
	local n = 0
	for i = #bodies, 1, -1 do
		local body = bodies[i]
		if owner == nil or body.owner == owner then
			EnergyRuntime.endBody(body)
			n += 1
		end
	end
	return n
end

function EnergyRuntime.count(): number
	return #bodies
end

function EnergyRuntime.report(): string
	if #bodies == 0 then
		return "no Energy spells running"
	end
	local lines: { string } = {}
	local now = os.clock()
	for _, b in bodies do
		table.insert(lines, string.format("%s by %d: %.0f s left, radius %.0f", b.look, b.owner, b.ends - now, b.radius))
	end
	return string.format("%d running\n%s", #bodies, table.concat(lines, "\n"))
end

function EnergyRuntime.start(logger: any)
	log = logger
	Damage.listenAttacked(EnergyRuntime.attacked)
end

return EnergyRuntime
