--!strict
--[[
	Struggle: spell struggles (docs/SpellStruggle.md §5; numbers in Shared/Magic/Data/Struggle, maths
	in Shared/Magic/StruggleRules). Two spells met head-on, close in weight, and neither gave way.

	A SIDE is whatever cast one of the two spells:
		{ model, player?, courage? (an NPC mage, 0..1), weight, domain, tags,
		  land(target: Model?, at: Vector3, mult: number)   the spell lands (on target, or at `at`)
		  lose()                                             the spell is gone }
	Cast/Delivery builds sides from held flights (Services/StruggleService); CastService builds them
	for beams (Struggle.beam).

		begin(a, b, at) -> boolean     both casters are held ("struggling" status: no moving, no casting;
		                               model attribute Struggling = id) and the knot sits between them
		intent(player, "down" | "up" | "break")   the only input (remote StruggleIntent)
		beam(spec) -> result?          a beam meeting a remembered beam (and sweeping flights)
		rememberBeam(spec)             a beam that just landed, for beamMemory seconds
		list(), endAll(), isStruggling(model)

	Each tick (Data.tickRate a second) a side's push = weight x feed x surges x hurt (StruggleRules.push).
	Players feed while holding (or surging) and paying feedCost x weight reservoir a second; NPC mages
	feed by courage. The knot drifts toward the weaker side. Endings:
		overwhelmed   the knot reaches a caster: both spells land on them (winner full, + the loser's
		              own at loserShare), knockdown
		letgo         a caster lets go (jump, or an NPC losing its nerve): their spell is gone, they're
		              free at once, and the winner's spell lands letGoDelay s later where they stood,
		              on them only if they're still within dodgeStuds (a sideways dash escapes)
		broken        a caster is knocked down, frozen, held, killed, leaves or is pulled away: the
		              other wins at once
		burst         maxSeconds: each spell lands on the other caster at burstShare, and the knot
		              throws loose things (Cast/Explosion)
	A struggle whose caster is frozen in time pauses (TimeFrozen).

	Clients: remote Struggle { t = "start" | "tick" | "end" | "clash", ... } to players within cueRange
	(Controllers/StruggleController draws the beams and the knot; there is no meter).
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local Net = require(Shared.Net)
local Data = require(Shared.Magic.Data.Struggle)
local StruggleRules = require(Shared.Magic.StruggleRules)
local Cast = script.Parent
local StatusEffects = require(Cast.StatusEffects)
local Explosion = require(Cast.Explosion)

export type Side = {
	model: Model,
	player: Player?,
	courage: number?,
	weight: number,
	domain: string?,
	tags: { string },
	land: (target: Model?, at: Vector3, mult: number) -> (),
	lose: () -> (),
}

type Live = Side & {
	holding: boolean,
	surges: { number },
	lastSurge: number,
	lastHealth: number,
	hurtUntil: number,
	start: Vector3,
}

type Fight = {
	id: number,
	a: Live,
	b: Live,
	point: number,
	age: number,
	ended: boolean,
}

export type BeamSpec = {
	model: Model,
	player: Player?,
	origin: Vector3,
	point: Vector3,
	radius: number,
	weight: number,
	domain: string?,
	tags: { string },
	land: ((target: Model?, at: Vector3, mult: number) -> ())?, -- for remembering
}

local Struggle = {}

local fights: { Fight } = {}
local beams: { BeamSpec & { t: number } } = {}
local nextId = 0
local deps: any = nil

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

local function humanoidOf(model: Model): Humanoid?
	return model:FindFirstChildOfClass("Humanoid")
end

local function knotAt(f: Fight): Vector3?
	local ra, rb = rootOf(f.a.model), rootOf(f.b.model)
	if not ra or not rb then
		return nil
	end
	return ra.Position:Lerp(rb.Position, f.point) + Vector3.new(0, 1.2, 0)
end

local function listeners(at: Vector3): { Player }
	local out = {}
	for _, player in Players:GetPlayers() do
		local character = player.Character
		local root = character and rootOf(character)
		if root and (root.Position - at).Magnitude <= Data.cueRange then
			table.insert(out, player)
		end
	end
	return out
end

local function send(at: Vector3, payload: { [string]: any })
	local list = listeners(at)
	if #list > 0 then
		Net.fireList("Struggle", list, payload)
	end
end

local function message(f: Fight, t: string): { [string]: any }
	return {
		t = t,
		id = f.id,
		a = f.a.model,
		b = f.b.model,
		domainA = f.a.domain,
		domainB = f.b.domain,
		wa = f.a.weight,
		wb = f.b.weight,
		point = f.point,
	}
end

local function release(side: Live)
	side.model:SetAttribute("Struggling", nil)
	local humanoid = humanoidOf(side.model)
	if humanoid then
		StatusEffects.remove(humanoid, "struggling")
	end
end

local function sideFor(f: Fight, key: string): (Live, Live)
	if key == "a" then
		return f.a, f.b
	end
	return f.b, f.a
end

local function finish(f: Fight, how: string, loserKey: string?)
	if f.ended then
		return
	end
	f.ended = true
	local index = table.find(fights, f)
	if index then
		table.remove(fights, index)
	end
	local at = knotAt(f) or (f.a.start + f.b.start) / 2
	release(f.a)
	release(f.b)
	local ok, err = pcall(function()
		if how == "burst" then
			local ra, rb = rootOf(f.a.model), rootOf(f.b.model)
			f.a.land(if rb then f.b.model else nil, if rb then rb.Position else at, Data.burstShare)
			f.b.land(if ra then f.a.model else nil, if ra then ra.Position else at, Data.burstShare)
			Explosion.blast(at, 10, math.clamp(math.round(f.a.weight + f.b.weight), 3, 10), nil)
			return
		end
		local loser, winner = sideFor(f, loserKey or "a")
		loser.lose()
		local lroot = rootOf(loser.model)
		local alive = lroot ~= nil and (humanoidOf(loser.model) :: Humanoid).Health > 0
		if how == "overwhelmed" then
			winner.land(if alive then loser.model else nil, if lroot then lroot.Position else at, 1 + Data.loserShare * loser.weight / math.max(winner.weight, 1e-3))
			local humanoid = humanoidOf(loser.model)
			if alive and humanoid then
				StatusEffects.apply(humanoid, "knockdown", { duration = Data.knockdownSeconds })
			end
		elseif how == "letgo" and lroot then
			local stood = lroot.Position
			task.delay(Data.letGoDelay, function()
				local now = rootOf(loser.model)
				local stayed = now ~= nil and (now.Position - stood).Magnitude <= Data.dodgeStuds
				winner.land(if stayed then loser.model else nil, stood, 1)
			end)
		else
			winner.land(if alive then loser.model else nil, if lroot then lroot.Position else at, 1)
		end
	end)
	if not ok then
		warn("[Struggle] ending failed: " .. tostring(err))
	end
	local payload = message(f, "end")
	payload.how = how
	payload.loser = loserKey
	payload.at = at
	send(at, payload)
	if deps and deps.onEnded then
		pcall(deps.onEnded, f, how, loserKey)
	end
end

local function blocked(model: Model): boolean
	local humanoid = humanoidOf(model)
	if not humanoid or humanoid.Health <= 0 or not model.Parent then
		return true
	end
	return StatusEffects.has(humanoid, "knockdown") or StatusEffects.has(humanoid, "frozen") or StatusEffects.has(humanoid, "gravity_held")
end

local function feed(side: Live, dt: number, now: number): number
	if side.player then
		local wants = side.holding or now - side.lastSurge < Data.feedGrace
		if not wants then
			return Data.idleFeed
		end
		local reservoir = deps.reservoirs:get(side.player)
		if not reservoir then
			return Data.idleFeed
		end
		if reservoir.infinite then
			return 1
		end
		local cost = Data.feedCost * side.weight * dt
		if reservoir.current >= cost then
			reservoir.current -= cost
			return 1
		end
		return Data.idleFeed
	end
	return Data.npcFeedBase + Data.npcFeedCourage * math.clamp(side.courage or 0.5, 0, 1)
end

local function surgesOf(side: Live, now: number, rng: Random): number
	if not side.player then
		if rng:NextNumber() < Data.npcSurgeChance * math.clamp(side.courage or 0.5, 0, 1) then
			table.insert(side.surges, now)
		end
	end
	local n = 0
	for i = #side.surges, 1, -1 do
		if now - side.surges[i] > 1 then
			table.remove(side.surges, i)
		else
			n += 1
		end
	end
	return n
end

local function hurt(side: Live, now: number): boolean
	local humanoid = humanoidOf(side.model)
	if humanoid then
		if humanoid.Health < side.lastHealth - 0.5 then
			side.hurtUntil = now + Data.hurtSeconds
		end
		side.lastHealth = humanoid.Health
	end
	return now < side.hurtUntil
end

local rng = Random.new()

local function tick(dt: number)
	local now = os.clock()
	for _, f in table.clone(fights) do
		if f.ended then
			continue
		end
		-- Frozen in time: the knot waits.
		if f.a.model:GetAttribute("TimeFrozen") or f.b.model:GetAttribute("TimeFrozen") then
			continue
		end
		f.age += dt
		if blocked(f.a.model) then
			finish(f, "broken", "a")
			continue
		elseif blocked(f.b.model) then
			finish(f, "broken", "b")
			continue
		end
		local ra, rb = rootOf(f.a.model), rootOf(f.b.model)
		if not ra or not rb then
			finish(f, "broken", if ra then "b" else "a")
			continue
		end
		local gap = (ra.Position - rb.Position).Magnitude
		if gap > Data.breakGap then
			local movedA = (ra.Position - f.a.start).Magnitude
			local movedB = (rb.Position - f.b.start).Magnitude
			finish(f, "broken", if movedA >= movedB then "a" else "b")
			continue
		end
		local pushA = StruggleRules.push(f.a.weight, feed(f.a, dt, now), surgesOf(f.a, now, rng), hurt(f.a, now))
		local pushB = StruggleRules.push(f.b.weight, feed(f.b, dt, now), surgesOf(f.b, now, rng), hurt(f.b, now))
		f.point = StruggleRules.step(f.point, pushA, pushB, dt)
		local reached = StruggleRules.overwhelmed(f.point, gap)
		if reached then
			finish(f, "overwhelmed", reached)
			continue
		end
		-- An NPC mage with little nerve lets go when the knot is nearly on it.
		for _, key in { "a", "b" } do
			local side = if key == "a" then f.a else f.b
			local near = if key == "a" then f.point else 1 - f.point
			if not side.player and near <= Data.npcLetGoAt and (side.courage or 0.5) < Data.npcLetGoCourage then
				finish(f, "letgo", key)
				break
			end
		end
		if f.ended then
			continue
		end
		if f.age >= Data.maxSeconds then
			finish(f, "burst", nil)
			continue
		end
		local at = knotAt(f)
		if at then
			send(at, message(f, "tick"))
		end
	end
end

-- ─── API ────────────────────────────────────────────────────────────────────

-- deps: { reservoirs, onStarted(fight)?, onEnded(fight, how, loserKey)? }
function Struggle.setup(d: any)
	deps = d
	task.spawn(function()
		local interval = 1 / Data.tickRate
		local last = os.clock()
		while true do
			task.wait(interval)
			local now = os.clock()
			local ok, err = pcall(tick, now - last)
			last = now
			if not ok then
				warn("[Struggle] tick failed: " .. tostring(err))
			end
		end
	end)
end

function Struggle.isStruggling(model: Model): boolean
	return model:GetAttribute("Struggling") ~= nil
end

local function live(side: Side): Live
	local humanoid = humanoidOf(side.model)
	local root = rootOf(side.model)
	local l = table.clone(side) :: any
	l.holding = true
	l.surges = {}
	l.lastSurge = 0
	l.lastHealth = if humanoid then humanoid.Health else 0
	l.hurtUntil = 0
	l.start = if root then root.Position else Vector3.zero
	return l :: Live
end

function Struggle.begin(a: Side, b: Side, at: Vector3): boolean
	if #fights >= Data.maxStruggles or a.model == b.model then
		return false
	end
	if Struggle.isStruggling(a.model) or Struggle.isStruggling(b.model) or blocked(a.model) or blocked(b.model) then
		return false
	end
	local ra, rb = rootOf(a.model), rootOf(b.model)
	if not ra or not rb or (ra.Position - rb.Position).Magnitude > Data.maxGap then
		return false
	end
	local la, lb = live(a), live(b)
	-- Where along the line they met: the knot starts there.
	local line = rb.Position - ra.Position
	local point = math.clamp((at - ra.Position):Dot(line) / math.max(line:Dot(line), 1e-3), 0.15, 0.85)
	nextId += 1
	local f: Fight = { id = nextId, a = la, b = lb, point = point, age = 0, ended = false }
	table.insert(fights, f)
	for _, side in { la, lb } do
		side.model:SetAttribute("Struggling", f.id)
		local humanoid = humanoidOf(side.model)
		if humanoid then
			StatusEffects.apply(humanoid, "struggling", { duration = Data.maxSeconds + 2 })
		end
	end
	send(at, message(f, "start"))
	if deps and deps.onStarted then
		pcall(deps.onStarted, f)
	end
	return true
end

function Struggle.intent(player: Player, kind: string)
	for _, f in fights do
		local key = if f.a.player == player then "a" elseif f.b.player == player then "b" else nil
		if key then
			local side = if key == "a" then f.a else f.b
			if kind == "break" then
				finish(f, "letgo", key)
			elseif kind == "up" then
				side.holding = false
			elseif kind == "down" then
				side.holding = true
				local now = os.clock()
				if now - side.lastSurge >= 1 / Data.surgeCap then
					local reservoir = deps.reservoirs:get(player)
					local cost = Data.surgeCost * (if reservoir then reservoir.max else 0)
					if reservoir and (reservoir.infinite or reservoir.current >= cost) then
						if not reservoir.infinite then
							reservoir.current -= cost
						end
						side.lastSurge = now
						table.insert(side.surges, now)
					end
				end
			end
			return
		end
	end
end

-- A spell meeting another in the air: everyone near sees the clash (Controllers/StruggleController).
function Struggle.clashCue(at: Vector3, kind: string, domainA: string?, domainB: string?)
	send(at, { t = "clash", at = at, kind = kind, domainA = domainA, domainB = domainB })
end

--[[
	A beam is being cast (CastService.strike, before it resolves). Returns nil when it meets nothing,
	or { kind = "stopped" | "shatter", at, mult? } or, after YIELDING through a struggle,
	{ kind = "struggle", won, target?, at, mult }. `canCollide(a, b)` and `band` come from
	Services/StruggleService.
]]
function Struggle.beam(spec: BeamSpec, canCollide: (Model, Model) -> boolean, band: number?): { [string]: any }?
	local now = os.clock()
	for i = #beams, 1, -1 do
		if now - beams[i].t > Data.beamMemory or not beams[i].model.Parent then
			table.remove(beams, i)
		end
	end
	local dir = spec.point - spec.origin
	if dir.Magnitude < 1e-3 then
		return nil
	end
	local best, bestAt, bestDist = nil, nil, math.huge
	for _, other in beams do
		if other.model == spec.model or Struggle.isStruggling(other.model) then
			continue
		end
		local odir = other.point - other.origin
		if odir.Magnitude < 1e-3 or dir.Unit:Dot(odir.Unit) > Data.beamHeadOnDot then
			continue
		end
		local gap, onMine = StruggleRules.lineGap(spec.origin, spec.point, other.origin, other.point)
		if gap <= Data.beamCross + spec.radius and canCollide(spec.model, other.model) then
			local d = (onMine - spec.origin).Magnitude
			if d < bestDist then
				best, bestAt, bestDist = other, onMine, d
			end
		end
	end
	if not best or not bestAt then
		return nil
	end
	local other = best
	local wMine = spec.weight * StruggleRules.matchup(spec.tags, other.tags)
	local wOther = other.weight * StruggleRules.matchup(other.tags, spec.tags)
	local canStruggle = spec.player ~= nil and other.land ~= nil
	local kind, ratio = StruggleRules.outcome(wMine, wOther, -1, canStruggle, band)
	Struggle.clashCue(bestAt, kind, spec.domain, other.domain)
	if kind == "cut_a" or kind == "glance" then
		return nil
	elseif kind == "cut_b" then
		return { kind = "stopped", at = bestAt }
	elseif kind == "shatter" then
		return { kind = "shatter", at = bestAt, mult = Data.shatterShare }
	end
	-- A struggle: this cast waits on it.
	local thread = coroutine.running()
	local mine: Side = {
		model = spec.model,
		player = spec.player,
		weight = wMine,
		domain = spec.domain,
		tags = spec.tags,
		land = function(target: Model?, at: Vector3, mult: number)
			task.spawn(thread, { kind = "struggle", won = true, target = target, at = at, mult = mult })
		end,
		lose = function()
			task.spawn(thread, { kind = "struggle", won = false })
		end,
	}
	local theirs: Side = {
		model = other.model,
		player = other.player,
		weight = wOther,
		domain = other.domain,
		tags = other.tags,
		land = other.land :: any,
		lose = function() end,
	}
	if not Struggle.begin(theirs, mine, bestAt) then
		return { kind = "shatter", at = bestAt, mult = Data.shatterShare, ratio = ratio }
	end
	-- the beam we met is spent: nobody else can meet it now
	local index = table.find(beams, other)
	if index then
		table.remove(beams, index)
	end
	return coroutine.yield()
end

function Struggle.rememberBeam(spec: BeamSpec)
	local entry = table.clone(spec) :: any
	entry.t = os.clock()
	table.insert(beams, entry)
	while #beams > 64 do
		table.remove(beams, 1)
	end
end

function Struggle.list(): { { id: number, a: Model, b: Model, point: number, age: number, wa: number, wb: number } }
	local out = {}
	for _, f in fights do
		table.insert(out, { id = f.id, a = f.a.model, b = f.b.model, point = f.point, age = f.age, wa = f.a.weight, wb = f.b.weight })
	end
	return out
end

function Struggle.endAll(): number
	local n = #fights
	for _, f in table.clone(fights) do
		finish(f, "burst", nil)
	end
	return n
end

return Struggle
