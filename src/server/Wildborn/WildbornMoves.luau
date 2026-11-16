--!strict
--[[
	WildbornMoves: the move library Wildborn fight with (docs/Wildborn.md; numbers per enemy in
	Wildborn/Data/Wildborn). Server-side, server-authoritative: every hit is decided here and goes
	through Cast/Damage (wards, guards, parries, resistances, PvP rules), slows and roots are real
	statuses (Cast/StatusEffects), and knockback goes to the player's own client (WorldEffect
	"knockback", as Effects/Force). Clients only DRAW (remote WildbornCue, Controllers/WildbornController),
	and only players within cueRange are told.

		bolt      projectiles (count, spread, splash, status) flown here; `chain` = a lightning chain
		          that jumps from the target to others nearby instead
		lob       an arcing boulder (or a few) landing where the target stood, warned on the ground
		dash      runs at the target leaving a burning trail, then strikes
		blink     steps to the target's flank or back (after-image), optionally strikes; `clones`
		          leaves after-images that each fire at the target
		echo      strikes, then the same strike again a moment later wherever the target is then
		burst     a warned blast around itself (status, knockback, heal)
		eruption  spikes, vines or a wave out of the ground: a line, a cone, a wave, a ring at the
		          target, or under everyone near (warned, then they rise)
		zone      a lingering area (whirlpool, static, tear, blizzard, maelstrom, petals) that ticks
		          and can pull
		tether    drains one target (or everyone in range) and heals itself
		rain      meteors, lightning or an anvil falling on warned spots
		pull      drags everyone in range in, then slams
		stasis    stops time around the target (or itself) for a moment; `pull` snaps them in after
		rally     once, low on health: heals, may hasten, may blast everyone close

	run(actor, move, target) returns how long the actor stands casting. Projectiles and zones step
	in one Heartbeat (step), capped by maxProjectiles and maxZones.
]]

local ReplicatedStorage = game:GetService("ReplicatedStorage")
local RunService = game:GetService("RunService")

local Net = require(ReplicatedStorage.Shared.Net)
local Cast = script.Parent.Parent.Magic.Cast
local Damage = require(Cast.Damage)
local StatusEffects = require(Cast.StatusEffects)
local Data = require(script.Parent.Data.Wildborn)

local T = Data.tuning

-- Someone a move can reach: a player (`player` set) or an NPC's body (no player; docs/NpcFights.md).
export type View = { player: Player?, model: Model, humanoid: Humanoid, root: BasePart, position: Vector3 }
export type Actor = {
	enemy: Data.Enemy,
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	rng: Random,
	lastHit: { [Humanoid]: number },
}

type Projectile = {
	id: number,
	actor: Actor,
	move: Data.Move,
	position: Vector3,
	velocity: Vector3,
	expires: number,
	radius: number,
}
type Zone = {
	actor: Actor,
	move: Data.Move,
	at: Vector3,
	ends: number,
	nextTick: number,
}

local WildbornMoves = {}

local playersNear: () -> { View } = function()
	return {}
end
-- Everyone a move can hurt: the players and the NPC bodies near (Services/WildbornService).
-- Cues go to players only.
local targetsNear: () -> { View } = function()
	return playersNear()
end
local projectiles: { Projectile } = {}
local zones: { Zone } = {}
local projectileId = 0

function WildbornMoves.setPlayers(fn: () -> { View })
	playersNear = fn
end

function WildbornMoves.setTargets(fn: () -> { View })
	targetsNear = fn
end

local function alive(actor: Actor): boolean
	return actor.model.Parent ~= nil and actor.humanoid.Health > 0
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function colors(actor: Actor): (Color3, Color3)
	local theme = Data.themes[actor.enemy.theme]
	return theme.primary, theme.secondary
end

-- Tell the players near `at` to draw something.
local function cue(actor: Actor, kind: string, at: Vector3, payload: { [string]: any })
	local primary, secondary = colors(actor)
	payload.kind = kind
	payload.primary = primary
	payload.secondary = secondary
	payload.scale = actor.enemy.scale
	for _, view in playersNear() do
		if view.player and (view.position - at).Magnitude <= T.cueRange then
			Net.fire("WildbornCue", view.player :: Player, payload)
		end
	end
end

local function pushPlayer(view: View, velocity: Vector3)
	if view.player then
		Net.fire("WorldEffect", view.player :: Player, { kind = "knockback", velocity = velocity })
	elseif not view.root.Anchored then
		view.root.AssemblyLinearVelocity += velocity -- an NPC's body: the server moves it
	end
end

-- One hit on one player: the boss's hitGap, then the normal pipeline.
local function hurt(actor: Actor, view: View, amount: number, move: Data.Move?, from: Vector3?)
	if amount <= 0 or view.humanoid.Health <= 0 then
		return
	end
	local now = os.clock()
	local gap = actor.enemy.hitGap
	if gap > 0 and now - (actor.lastHit[view.humanoid] or -math.huge) < gap then
		return
	end
	actor.lastHit[view.humanoid] = now
	local dealt = Damage.apply(view.humanoid, amount, nil, "wildborn", {
		domain = actor.enemy.domain,
		from = from or actor.root.Position,
		form = "area",
		power = actor.enemy.level,
		attacker = actor.model,
	})
	local status = move and move.status
	if dealt > 0 and status then
		StatusEffects.apply(view.humanoid, status.id, { duration = status.duration, magnitude = status.magnitude })
	end
end

local function withinOf(views: { View }, at: Vector3, radius: number): { View }
	local out: { View } = {}
	for _, view in views do
		if (view.position - at).Magnitude <= radius then
			table.insert(out, view)
		end
	end
	return out
end

-- Players and NPC bodies near a point right now (live positions: the providers read them fresh).
local function within(at: Vector3, radius: number): { View }
	return withinOf(targetsNear(), at, radius)
end

local function face(actor: Actor, at: Vector3)
	local look = Vector3.new(at.X - actor.root.Position.X, 0, at.Z - actor.root.Position.Z)
	if look.Magnitude > 0.1 then
		actor.root.CFrame = CFrame.lookAt(actor.root.Position, actor.root.Position + look.Unit)
	end
end

local function groundBelow(at: Vector3): Vector3
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Include
	params.FilterDescendantsInstances = { workspace.Terrain }
	local hit = workspace:Raycast(at + Vector3.new(0, 30, 0), Vector3.new(0, -80, 0), params)
	return if hit then hit.Position else at - Vector3.new(0, 3, 0)
end

-- Telegraph spots, then hit everyone within `radius` of any of them (once each), after `delay`.
local function strikeSpots(actor: Actor, move: Data.Move, spots: { Vector3 }, radius: number, delay: number, style: string, knockback: Vector3?)
	cue(actor, "marks", spots[1] or actor.root.Position, { spots = spots, radius = radius, delay = delay, style = style })
	task.delay(delay, function()
		if not actor.model.Parent then
			return
		end
		cue(actor, "strike", spots[1] or actor.root.Position, { spots = spots, radius = radius, style = style })
		local struck: { [Humanoid]: boolean } = {}
		for _, spot in spots do
			for _, view in within(spot, radius + 1) do
				if not struck[view.humanoid] then
					struck[view.humanoid] = true
					hurt(actor, view, move.damage, move, spot)
					if move.knockback then
						local away = knockback or Vector3.new(view.position.X - spot.X, 0, view.position.Z - spot.Z)
						local dir = if away.Magnitude > 0.1 then away.Unit else Vector3.new(0, 0, 1)
						pushPlayer(view, dir * move.knockback + Vector3.new(0, move.knockback * 0.4, 0))
					end
				end
			end
		end
	end)
end

-- ─── Kinds ──────────────────────────────────────────────────────────────────

local kinds: { [string]: (Actor, Data.Move, View) -> number } = {}

kinds.bolt = function(actor, move, target)
	local origin = actor.root.Position + Vector3.new(0, 2 * actor.enemy.scale, 0)
	if move.chain then
		-- Lightning that jumps: the target, then whoever is nearest each last one.
		local points = { origin }
		local hit: { [Humanoid]: boolean } = {}
		local current = target
		for _ = 1, move.chain do
			hit[current.humanoid] = true
			table.insert(points, current.position)
			hurt(actor, current, move.damage, move, actor.root.Position)
			local nextView, best = nil, move.chainRange or 30
			for _, view in targetsNear() do
				local d = (view.position - current.position).Magnitude
				if not hit[view.humanoid] and d < best then
					nextView, best = view, d
				end
			end
			if not nextView then
				break
			end
			current = nextView
		end
		cue(actor, "chain", origin, { points = points, style = move.style })
		return 0.5
	end
	if #projectiles >= T.maxProjectiles then
		return 0.3
	end
	local count = move.count or 1
	local base = (target.position + Vector3.new(0, 1, 0) - origin)
	local dir0 = if base.Magnitude > 0.1 then base.Unit else actor.root.CFrame.LookVector
	for i = 1, count do
		local angle = (i - (count + 1) / 2) * (move.spread or 0.12)
		local dir = (CFrame.Angles(0, angle, 0) * CFrame.new(Vector3.zero, dir0)).LookVector
		projectileId += 1
		local life = (move.max or 70) / move.speed + 0.3
		table.insert(projectiles, {
			id = projectileId,
			actor = actor,
			move = move,
			position = origin,
			velocity = dir * move.speed,
			expires = os.clock() + life,
			radius = (move.size or 2) / 2 + 1.5,
		})
		cue(actor, "bolt", origin, { id = projectileId, from = origin, velocity = dir * move.speed, life = life, size = move.size or 2, style = move.style })
	end
	return 0.45
end

kinds.lob = function(actor, move, target)
	local count = move.count or 1
	for i = 1, count do
		task.delay((i - 1) * (move.interval or 0.4), function()
			if not alive(actor) then
				return
			end
			local view = target
			if view.humanoid.Health <= 0 then
				return
			end
			local from = actor.root.Position + Vector3.new(0, 3 * actor.enemy.scale, 0)
			local to = groundBelow(view.root.Position)
			local flight = math.max(0.45, (to - from).Magnitude / move.speed)
			cue(actor, "lob", from, { from = from, to = to, time = flight, size = move.size or 3, style = move.style })
			strikeSpots(actor, move, { to }, move.radius or 7, flight, move.style)
		end)
	end
	return 0.5 + (count - 1) * (move.interval or 0.4)
end

kinds.dash = function(actor, move, target)
	local origin = actor.root.Position
	local toTarget = Vector3.new(target.position.X - origin.X, 0, target.position.Z - origin.Z)
	if toTarget.Magnitude < 1 then
		return 0
	end
	local dir = toTarget.Unit
	local length = math.min(move.distance, toTarget.Magnitude - 3)
	local destination = origin + dir * math.max(0, length)
	local time = 0.4
	cue(actor, "dash", origin, { from = origin, to = destination, time = time, style = move.style })
	local steps = math.max(1, math.floor(length / 4))
	local struck: { [Humanoid]: boolean } = {}
	for i = 0, steps do
		local t = i / steps
		local spot = origin:Lerp(destination, t)
		task.delay(t * time, function()
			for _, view in within(spot, 4.5) do
				if not struck[view.humanoid] then
					struck[view.humanoid] = true
					hurt(actor, view, move.trailDamage or 0, move, spot)
				end
			end
		end)
	end
	task.delay(time, function()
		if not alive(actor) then
			return
		end
		actor.root.CFrame = CFrame.lookAt(destination, destination + dir)
		if target.humanoid.Health > 0 and flat(target.root.Position, destination) <= 7 then
			hurt(actor, target, move.endDamage or 0, move, destination)
		end
	end)
	return time + 0.2
end

kinds.blink = function(actor, move, target)
	local origin = actor.root.Position
	local destination: Vector3
	if move.where == "behind" then
		local look = target.root.CFrame.LookVector * Vector3.new(1, 0, 1)
		look = if look.Magnitude > 0.1 then look.Unit else Vector3.new(0, 0, 1)
		destination = target.position - look * (move.distance or 5)
	else
		local toTarget = Vector3.new(target.position.X - origin.X, 0, target.position.Z - origin.Z)
		local side = if toTarget.Magnitude > 0.1 then toTarget.Unit:Cross(Vector3.new(0, 1, 0)) else Vector3.new(1, 0, 0)
		destination = target.position + side * ((if actor.rng:NextNumber() < 0.5 then 1 else -1) * (move.distance or 5))
	end
	local delay = move.delay or 0
	local clones: { Vector3 } = {}
	for i = 0, (move.clones or 0) - 1 do
		local angle = (i / move.clones) * math.pi * 2
		table.insert(clones, target.position + Vector3.new(math.cos(angle) * 8, 0, math.sin(angle) * 8))
	end
	cue(actor, "blink", origin, { from = origin, to = destination, delay = delay, clones = clones, target = target.position, style = move.style })
	task.delay(delay, function()
		if not alive(actor) then
			return
		end
		actor.root.CFrame = CFrame.lookAt(destination, Vector3.new(target.position.X, destination.Y, target.position.Z))
		if (move.damage or 0) > 0 then
			if move.radius then
				for _, view in within(destination, move.radius) do
					hurt(actor, view, move.damage, move, destination)
				end
			elseif target.humanoid.Health > 0 and flat(target.root.Position, destination) <= 8 then
				hurt(actor, target, move.damage, move, destination)
			end
		end
	end)
	if #clones > 0 then
		task.delay(delay + 0.3, function()
			if not alive(actor) or target.humanoid.Health <= 0 then
				return
			end
			for _, spot in clones do
				cue(actor, "chain", spot, { points = { spot + Vector3.new(0, 3, 0), target.root.Position }, style = move.style })
				hurt(actor, target, move.cloneDamage or 0, move, spot)
			end
		end)
	end
	return delay + 0.3
end

kinds.echo = function(actor, move, target)
	cue(actor, "slash", target.position, { at = target.position, size = 7, style = move.style })
	hurt(actor, target, move.damage, move, actor.root.Position)
	task.delay(move.delay or 0.8, function()
		if not alive(actor) or target.humanoid.Health <= 0 then
			return
		end
		local at = target.root.Position
		cue(actor, "slash", at, { at = at, size = 11, style = move.style, echo = true })
		-- The echo lands wherever they are now: only dodged by being out of its reach.
		if flat(at, actor.root.Position) <= (move.max or 9) + 6 then
			actor.lastHit[target.humanoid] = nil
			hurt(actor, target, move.second or move.damage, move, actor.root.Position)
		end
	end)
	return 0.5
end

kinds.burst = function(actor, move, _target)
	local at = actor.root.Position
	local windup = move.windup or 0.4
	cue(actor, "marks", at, { spots = { groundBelow(at) }, radius = move.radius, delay = windup, style = move.style })
	task.delay(windup, function()
		if not alive(actor) then
			return
		end
		local center = actor.root.Position
		cue(actor, "burst", center, { at = center, radius = move.radius, style = move.style })
		for _, view in within(center, move.radius) do
			hurt(actor, view, move.damage, move, center)
			if move.knockback then
				local away = Vector3.new(view.position.X - center.X, 0, view.position.Z - center.Z)
				local dir = if away.Magnitude > 0.1 then away.Unit else Vector3.new(0, 0, 1)
				pushPlayer(view, dir * move.knockback + Vector3.new(0, move.knockback * 0.4, 0))
			end
		end
		if move.heal then
			actor.humanoid.Health = math.min(actor.humanoid.MaxHealth, actor.humanoid.Health + move.heal)
		end
	end)
	return windup + 0.3
end

kinds.eruption = function(actor, move, target)
	local origin = groundBelow(actor.root.Position)
	local toTarget = Vector3.new(target.position.X - origin.X, 0, target.position.Z - origin.Z)
	local dir = if toTarget.Magnitude > 0.1 then toTarget.Unit else actor.root.CFrame.LookVector * Vector3.new(1, 0, 1)
	local side = dir:Cross(Vector3.new(0, 1, 0))
	local pattern = move.pattern
	if pattern == "everyone" then
		for _, view in within(actor.root.Position, move.within or 60) do
			strikeSpots(actor, move, { groundBelow(view.root.Position) }, move.radius or 3.5, move.delay or 0.4, move.style)
		end
		return 0.6
	elseif pattern == "target" then
		local center = groundBelow(target.root.Position)
		local spots = { center }
		strikeSpots(actor, move, spots, (move.radius or 3) + 1.5, move.delay or 0.4, move.style)
		return 0.5
	end
	-- Rows marching out from it, each a little later than the last.
	local rows = if pattern == "cone" then (move.rows or 5) else (move.count or 6)
	local perRow = if pattern == "cone" then (move.count or 5) else 1
	for row = 1, rows do
		local spots: { Vector3 } = {}
		for c = 1, perRow do
			local offset = if perRow > 1 then (c - (perRow + 1) / 2) * 3.5 * (row / rows + 0.4) else 0
			table.insert(spots, origin + dir * (row * (move.spacing or 4)) + side * offset)
		end
		local radius = if pattern == "wave" then (move.width or 8) / 2 else (move.radius or 3.5)
		task.delay((row - 1) * 0.06, function()
			if alive(actor) then
				strikeSpots(actor, move, spots, radius, move.delay or 0.35, move.style, if pattern == "wave" then dir else nil)
			end
		end)
	end
	return 0.5
end

kinds.zone = function(actor, move, target)
	if #zones >= T.maxZones then
		return 0.3
	end
	local at = groundBelow(if move.at == "self" then actor.root.Position else target.root.Position)
	table.insert(zones, { actor = actor, move = move, at = at, ends = os.clock() + move.duration, nextTick = os.clock() + (move.tick or 0.5) })
	cue(actor, "zone", at, { at = at, radius = move.radius, duration = move.duration, style = move.style })
	return 0.6
end

kinds.tether = function(actor, move, target)
	local victims: { View } = if move.all then within(actor.root.Position, move.range or 30) else { target }
	local models: { Model } = {}
	for _, view in victims do
		table.insert(models, view.model)
	end
	cue(actor, "tether", actor.root.Position, { from = actor.model, to = models, duration = move.ticks * move.interval, style = move.style })
	for tick = 1, move.ticks do
		task.delay((tick - 1) * move.interval, function()
			if not alive(actor) then
				return
			end
			for _, view in victims do
				if view.humanoid.Health > 0 and (view.root.Position - actor.root.Position).Magnitude <= (move.range or 30) + 10 then
					actor.lastHit[view.humanoid] = nil -- a drain is many small sips, not chained blows
					hurt(actor, view, move.damage, move, actor.root.Position)
					actor.humanoid.Health = math.min(actor.humanoid.MaxHealth, actor.humanoid.Health + move.damage * (move.heal or 0))
				end
			end
		end)
	end
	return move.ticks * move.interval
end

kinds.rain = function(actor, move, target)
	local center: Vector3
	if move.center == "self" then
		center = actor.root.Position
	elseif move.center == "ahead" then
		center = actor.root.Position + actor.root.CFrame.LookVector * 30
	else
		center = target.root.Position
	end
	for i = 1, move.count do
		task.delay((i - 1) * (move.interval or 0.2), function()
			if not alive(actor) then
				return
			end
			local angle = actor.rng:NextNumber() * math.pi * 2
			local r = actor.rng:NextNumber() * (move.spread or 0)
			local spot = groundBelow(center + Vector3.new(math.cos(angle) * r, 0, math.sin(angle) * r))
			cue(actor, "fall", spot, { at = spot, time = move.delay, style = move.style, radius = move.radius })
			strikeSpots(actor, move, { spot }, move.radius, move.delay, move.style)
		end)
	end
	return 0.6
end

kinds.pull = function(actor, move, _target)
	local center = actor.root.Position
	local pulled = within(center, move.range or 60)
	local models: { Model } = {}
	for _, view in pulled do
		local toward = Vector3.new(center.X - view.position.X, 0, center.Z - view.position.Z)
		if toward.Magnitude > 1 then
			pushPlayer(view, toward.Unit * (move.speed or 70))
		end
		table.insert(models, view.model)
	end
	cue(actor, "tether", center, { from = actor.model, to = models, duration = 0.4, style = move.style })
	local slam = { damage = move.damage, knockback = move.knockback }
	task.delay(move.delay or 0.5, function()
		if not alive(actor) then
			return
		end
		local at = actor.root.Position
		cue(actor, "burst", at, { at = at, radius = move.radius, style = "slam" })
		for _, view in within(at, move.radius or 18) do
			hurt(actor, view, slam.damage, nil, at)
			local away = Vector3.new(view.position.X - at.X, 0, view.position.Z - at.Z)
			if away.Magnitude > 0.1 and slam.knockback then
				pushPlayer(view, away.Unit * slam.knockback + Vector3.new(0, slam.knockback * 0.4, 0))
			end
		end
	end)
	return (move.delay or 0.5) + 0.3
end

kinds.stasis = function(actor, move, target)
	local center = if move.around == "self" then actor.root.Position else target.root.Position
	local caught = within(center, move.radius)
	local models: { Model } = {}
	for _, view in caught do
		StatusEffects.apply(view.humanoid, "stasis", { duration = move.duration })
		table.insert(models, view.model)
	end
	cue(actor, "stasis", center, { at = center, radius = move.radius, duration = move.duration, caught = models, style = move.style })
	if move.pull then
		task.delay(move.duration, function()
			if not alive(actor) then
				return
			end
			local at = actor.root.Position
			for _, view in caught do
				local toward = Vector3.new(at.X - view.position.X, 0, at.Z - view.position.Z)
				if toward.Magnitude > 1 then
					pushPlayer(view, toward.Unit * move.pull + Vector3.new(0, 25, 0))
				end
				hurt(actor, view, move.damage, nil, at)
			end
		end)
	else
		for _, view in caught do
			hurt(actor, view, move.damage, nil, center)
		end
	end
	return 0.6
end

kinds.rally = function(actor, move, _target)
	local humanoid = actor.humanoid
	humanoid.Health = math.min(humanoid.MaxHealth, humanoid.Health + humanoid.MaxHealth * (move.heal or 0))
	local at = actor.root.Position
	cue(actor, "rally", at, { at = at, radius = move.radius or 20, style = move.style })
	if move.haste then
		local base = actor.enemy.walk
		humanoid.WalkSpeed = base * move.haste
		task.delay(move.hasteFor or 8, function()
			if humanoid.Parent then
				humanoid.WalkSpeed = base
			end
		end)
	end
	if (move.damage or 0) > 0 then
		for _, view in within(at, move.radius or 20) do
			hurt(actor, view, move.damage, move, at)
		end
	end
	return 1
end

-- ─── Public ─────────────────────────────────────────────────────────────────

function WildbornMoves.run(actor: Actor, move: Data.Move, target: View): number
	local fn = kinds[move.move]
	if not fn then
		return 0
	end
	face(actor, target.position)
	return fn(actor, move, target)
end

-- Its plain blow, within reach.
function WildbornMoves.melee(actor: Actor, target: View)
	local m = actor.enemy.melee
	face(actor, target.position)
	cue(actor, "slash", target.position, { at = target.position, size = 5, style = "melee" })
	hurt(actor, target, m.damage, if m.status then { status = m.status } else nil, actor.root.Position)
end

function WildbornMoves.kinds(): { string }
	local out: { string } = {}
	for name in kinds do
		table.insert(out, name)
	end
	table.sort(out)
	return out
end

-- Forget an actor that died or slept: its projectiles and zones go with it.
function WildbornMoves.forget(actor: Actor)
	for i = #projectiles, 1, -1 do
		if projectiles[i].actor == actor then
			table.remove(projectiles, i)
		end
	end
	for i = #zones, 1, -1 do
		if zones[i].actor == actor then
			table.remove(zones, i)
		end
	end
end

local rayParams = RaycastParams.new()
rayParams.FilterType = Enum.RaycastFilterType.Include
rayParams.FilterDescendantsInstances = { workspace.Terrain }

local function stepProjectiles(views: { View }, dt: number, now: number)
	for i = #projectiles, 1, -1 do
		local p = projectiles[i]
		local nextPosition = p.position + p.velocity * dt
		local done = now >= p.expires or not p.actor.model.Parent
		local hitAt: Vector3? = nil
		if not done then
			for _, view in views do
				if (view.position - nextPosition).Magnitude <= p.radius then
					hurt(p.actor, view, p.move.damage, p.move, p.position)
					hitAt = nextPosition
					break
				end
			end
			if not hitAt then
				local wall = workspace:Raycast(p.position, nextPosition - p.position, rayParams)
				if wall then
					hitAt = wall.Position
				end
			end
		end
		if hitAt and p.move.splash then
			for _, view in withinOf(views, hitAt, p.move.splash) do
				hurt(p.actor, view, p.move.damage * 0.5, p.move, hitAt)
			end
		end
		if hitAt or done then
			table.remove(projectiles, i)
			if hitAt then
				cue(p.actor, "boltEnd", hitAt, { id = p.id, at = hitAt, style = p.move.style })
			end
		else
			p.position = nextPosition
		end
	end
end

local function stepZones(views: { View }, now: number)
	for i = #zones, 1, -1 do
		local z = zones[i]
		if now >= z.ends or not alive(z.actor) then
			table.remove(zones, i)
		elseif now >= z.nextTick then
			z.nextTick = now + (z.move.tick or 0.5)
			for _, view in withinOf(views, z.at, z.move.radius) do
				z.actor.lastHit[view.humanoid] = nil -- zone ticks are the zone's own rhythm
				hurt(z.actor, view, z.move.damage, z.move, z.at)
				if z.move.pull then
					local toward = Vector3.new(z.at.X - view.position.X, 0, z.at.Z - view.position.Z)
					if toward.Magnitude > 1.5 then
						pushPlayer(view, toward.Unit * z.move.pull)
					end
				end
			end
		end
	end
end

function WildbornMoves.start()
	RunService.Heartbeat:Connect(function(dt)
		if #projectiles == 0 and #zones == 0 then
			return
		end
		local now = os.clock()
		local views = targetsNear() -- one fresh look at everyone per frame
		stepProjectiles(views, dt, now)
		stepZones(views, now)
	end)
end

function WildbornMoves.counts(): (number, number)
	return #projectiles, #zones
end

return WildbornMoves
