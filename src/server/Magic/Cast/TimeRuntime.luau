--!strict
--[[
	TimeRuntime: the Time powers that outlive their cast (docs/Time.md). Effects/TimePower starts them,
	Services/TimeService steps them and takes the client's TimeIntent.
	Numbers: Shared/Magic/Data/TimeTuning. Decisions: Shared/Magic/TimeRules.

	SELF TIMELINE   Mark yourself: position, health, reservoir (with strain, burnout and lockouts),
	                stamina, dash charges, statuses and spell cooldowns. Recall puts all of it back.
	                The recall's own cooldown is what stops an endless loop.
	                Never touched: items, coins, XP, quests, reputation or crimes. Those reach a
	                DataStore, so rewinding them would let people duplicate things.
	LAST MOMENT     At Grandmaster, a killing blow with a live mark recalls you instead. It goes through
	                Damage.interceptor, so it sees every Damage.apply hit and overdraw backlash.
	TARGET TIMELINE Mark someone. "Release" snaps them back to where you marked them, stunned and hurt.
	STORED MOMENT   Your projectiles hang in the air. "Release" sends them all at once at your aim, or
	                at whoever you've just recalled.
	TIMESTOP        Everyone you may harm in the zone freezes (a real server hold plus Stasis), and
	                every projectile in it hangs until time resumes, yours included.
	BORROWED WOUND  On an enemy: hits are held back, then land together, harder. On yourself: hits are
	                held back, then you pay less of them.
	FUTURE SIGHT    You see where nearby spells are aimed, and some hits simply miss you.
	TIME LOOP       A target keeps being snapped back to where it stood.

	No state buffer: a mark snapshots when you mark, so nothing is recorded for anyone who isn't using
	Time. The Time dash's short rewind has its own history in Services/MovementService.
	Duels: you can't recall during one, and PvpRules still decides who you can touch.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local T = require(Shared.Magic.Data.TimeTuning)
local Rules = require(Shared.Magic.TimeRules)

local Cast = script.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local Delivery = require(Cast.Delivery)
local GravityRuntime = require(Cast.GravityRuntime)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)

type Ctx = CastTypes.EffectContext
type Hit = CastTypes.Hit

type SelfMark = {
	id: number,
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	cframe: CFrame,
	health: number,
	reservoir: { current: number, strain: number, burnoutUntil: number, lockouts: { [string]: number } }?,
	stamina: number?,
	charges: number?,
	statuses: { StatusEffects.Snapshot },
	cooldowns: { [string]: number },
	expires: number,
	tier: number,
	reservoirs: any,
}

type TargetMark = { id: number, hit: Hit, position: Vector3, expires: number, ctx: Ctx }

type Stored = { ctx: Ctx, expires: number, capacity: number, flights: { Delivery.Flight } }

type Stop = {
	id: number,
	ctx: Ctx,
	center: Vector3,
	radius: number,
	expires: number,
	nextScan: number,
	frozen: { [Humanoid]: any },
	flights: { Delivery.Flight },
}

type Wound = { total: number, mult: number, expires: number, source: number?, humanoid: Humanoid, domain: string, power: number, branch: string }

type Sight = { expires: number, dodge: number, player: Player, rng: Random }

type Loop = { ctx: Ctx, hit: Hit, position: Vector3, left: number, nextAt: number }

type Stun = { hold: any, expires: number }

export type Hooks = {
	cooldownsOf: (Player) -> { [string]: number },
	setCooldowns: (Player, { [string]: number }) -> (),
	stamina: any,
	chargesOf: (Player) -> number?,
	setCharges: (Player, number) -> (),
}

local TimeRuntime = {}

local runner: any = nil
local log: any = nil
local hooks: Hooks? = nil

local selfMarks: { [Player]: SelfMark } = {}
local recallReady: { [Player]: number } = {}
local lastMomentReady: { [Player]: number } = {}
local targetMarks: { [number]: { TargetMark } } = {}
local stored: { [number]: Stored } = {}
local releasedFromStored: { [Delivery.Flight]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local stops: { Stop } = {}
local stopReady: { [number]: number } = {}
local wounds: { [Humanoid]: Wound } = {}
local sights: { [Humanoid]: Sight } = {}
local loops: { Loop } = {}
local stuns: { Stun } = {}
local nextId = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local function newId(): number
	nextId += 1
	return nextId
end

local function fx(name: string, payload: { [string]: any }, position: Vector3, heavy: boolean?)
	if runner then
		payload.fx = name
		runner:cue("time", payload, position, heavy == true)
	end
end

local function alive(hit: Hit): boolean
	return hit.model.Parent ~= nil and hit.humanoid.Parent ~= nil and hit.humanoid.Health > 0
end

local function refresh(ctx: Ctx): boolean
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not ctx.root.Parent or ctx.player.Character ~= ctx.character or not humanoid or humanoid.Health <= 0 then
		return false
	end
	ctx.origin = ctx.root.Position
	return true
end

-- What the client's panel shows (TimeClient reads these Player attributes).
local function publish(player: Player)
	local mark = selfMarks[player]
	player:SetAttribute("TimeMarkUntil", if mark then mark.expires else nil)
	player:SetAttribute("TimeRecallReady", recallReady[player])
	local marks = targetMarks[player.UserId]
	player:SetAttribute("TimeMarks", if marks and #marks > 0 then #marks else nil)
	local s = stored[player.UserId]
	player:SetAttribute("TimeHeld", if s then #s.flights else nil)
	player:SetAttribute("TimeStoredUntil", if s then s.expires else nil)
end

-- A body that was put somewhere stops, and an unanchored server-owned one doesn't keep its old speed.
local function moveBody(hit: Hit, position: Vector3)
	if hit.root.Anchored and hit.humanoid:GetAttribute("StasisAnchored") ~= true and not hit.model:GetAttribute(GravityRuntime.heldAttribute) then
		return -- a dummy or a storm node: time can't move what's fixed in place
	end
	hit.model:PivotTo(CFrame.new(position) * hit.root.CFrame.Rotation)
	if not hit.root.Anchored then
		hit.root.AssemblyLinearVelocity = Vector3.zero
	end
end

local function stun(hit: Hit, sourceUserId: number, seconds: number)
	local hold = GravityRuntime.hold(hit, sourceUserId, seconds)
	if hold then
		table.insert(stuns, { hold = hold, expires = now() + seconds })
	end
end

-- ─── Self Timeline ──────────────────────────────────────────────────────────

function TimeRuntime.markSelf(ctx: Ctx)
	local player = ctx.player
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local previous = selfMarks[player]
	if previous then
		fx("end", { id = previous.id }, previous.cframe.Position)
	end
	local tier = ctx.stats.masteryTier
	local window = Rules.byTier(T.selfTimeline.window, tier)
	local reservoirs = ctx.services.reservoirs
	local state = reservoirs:get(player)
	local h = hooks
	local mark: SelfMark = {
		id = newId(),
		model = ctx.character,
		humanoid = humanoid,
		root = ctx.root,
		cframe = ctx.root.CFrame,
		health = humanoid.Health,
		reservoir = if state then { current = state.current, strain = state.strain, burnoutUntil = state.burnoutUntil, lockouts = table.clone(state.lockouts) } else nil,
		stamina = if h then (h.stamina:get(player)) else nil,
		charges = if h then h.chargesOf(player) else nil,
		statuses = StatusEffects.snapshot(humanoid),
		cooldowns = if h then Rules.cooldownsLeft(h.cooldownsOf(player), now()) else {},
		expires = now() + window,
		tier = tier,
		reservoirs = reservoirs,
	}
	selfMarks[player] = mark
	publish(player)
	fx("afterimage", { id = mark.id, model = ctx.character, duration = window }, ctx.root.Position)
end

local function dropMark(player: Player, mark: SelfMark)
	if selfMarks[player] == mark then
		selfMarks[player] = nil
		fx("end", { id = mark.id }, mark.cframe.Position)
		publish(player)
	end
end

-- Puts everything back. The caller has already decided it's allowed.
local function applyRecall(player: Player, mark: SelfMark)
	local from = mark.root.Position
	GravityRuntime.releaseFor(mark.humanoid) -- time outranks gravity: a grip can't hold your past

	local state = mark.reservoirs:get(player)
	local saved = mark.reservoir
	if state and saved then
		state.current, state.strain, state.burnoutUntil = saved.current, saved.strain, saved.burnoutUntil
		state.lockouts = table.clone(saved.lockouts)
		mark.reservoirs:push(player)
	end
	local h = hooks
	if h then
		if mark.stamina then
			h.stamina:set(player, mark.stamina)
		end
		if mark.charges then
			h.setCharges(player, mark.charges)
		end
		h.setCooldowns(player, Rules.cooldownsRestored(mark.cooldowns, now()))
	end
	StatusEffects.restore(mark.humanoid, mark.statuses)
	wounds[mark.humanoid] = nil -- what you owed hadn't happened yet, back then
	mark.humanoid.Health = math.clamp(mark.health, 1, mark.humanoid.MaxHealth)
	mark.model:PivotTo(mark.cframe)
	mark.root.AssemblyLinearVelocity = Vector3.zero
	selfMarks[player] = nil
	fx("end", { id = mark.id }, from)
	fx("recall", { to = mark.cframe.Position, heavy = true }, from, true)
	publish(player)
end

local REFUSALS: { [string]: string } = {
	NO_MARK = "You have no mark to return to.",
	IN_DUEL = "A duel's result can't be undone.",
	TIME_STOPPED = "Time has stopped around you.",
	TOO_SOON = "Your timeline hasn't settled yet.",
}

-- Returns why not, or nil when it worked.
function TimeRuntime.recallSelf(player: Player): string?
	local mark = selfMarks[player]
	local t = now()
	local valid = mark ~= nil and mark.model == player.Character and mark.humanoid.Health > 0
	local reason = Rules.recallRefusal(
		valid,
		if mark then mark.expires else 0,
		recallReady[player] or 0,
		t,
		mark ~= nil and mark.humanoid:GetAttribute("DuelId") ~= nil,
		mark ~= nil and mark.humanoid:GetAttribute("Status_stasis") ~= nil
	)
	-- In a Meteor dive: nothing to hold on to, and the landing wouldn't be yours.
	if not reason and mark and mark.model:GetAttribute(GravityRuntime.heldAttribute) and not GravityRuntime.holdOf(mark.humanoid) then
		reason = "TOO_SOON"
	end
	if reason or not mark then
		return reason
	end
	recallReady[player] = t + Rules.byTier(T.selfTimeline.cooldown, mark.tier)
	applyRecall(player, mark)
	log:info("time_recall", { userId = player.UserId })
	return nil
end

function TimeRuntime.refusalText(reason: string): string
	return REFUSALS[reason] or "Time won't turn back for you yet."
end

-- ─── Target Timeline and Stored Moment: both answer to "release" ────────────

function TimeRuntime.markTarget(ctx: Ctx, hit: Hit)
	local userId = ctx.player.UserId
	local tier = ctx.stats.masteryTier
	local list = targetMarks[userId] or {}
	targetMarks[userId] = list
	local window = Rules.byTier(T.targetTimeline.window, tier)
	local mark: TargetMark = { id = newId(), hit = hit, position = hit.root.Position, expires = now() + window, ctx = ctx }
	-- Marking someone again replaces their old mark, so end that one's afterimage too.
	for _, existing in list do
		if existing.hit.humanoid == hit.humanoid then
			fx("end", { id = existing.id }, existing.position)
		end
	end
	local pushed = Rules.addMark(list, mark, Rules.byTier(T.targetTimeline.marks, tier), function(a: TargetMark, b: TargetMark): boolean
		return a.hit.humanoid == b.hit.humanoid
	end)
	if pushed then
		fx("end", { id = pushed.id }, pushed.position)
	end
	publish(ctx.player)
	fx("afterimage", { id = mark.id, model = hit.model, duration = window }, mark.position)
end

function TimeRuntime.startStored(ctx: Ctx)
	local tier = ctx.stats.masteryTier
	local userId = ctx.player.UserId
	local existing = stored[userId]
	local seconds = Rules.byTier(T.stored.seconds, tier)
	stored[userId] = {
		ctx = ctx,
		expires = now() + seconds,
		capacity = Rules.byTier(T.stored.capacity, tier),
		flights = if existing then existing.flights else {},
	}
	publish(ctx.player)
end

local function releaseStored(userId: number, aim: Vector3?, homing: BasePart?)
	local s = stored[userId]
	if not s then
		return
	end
	stored[userId] = nil
	for _, flight in s.flights do
		releasedFromStored[flight] = true
		Delivery.release(flight, aim, homing)
	end
end

-- The release key: everyone you marked snaps back, then your hanging spells fly, at them if you can.
function TimeRuntime.release(player: Player, aim: Vector3?)
	local userId = player.UserId
	local t = now()
	local firstRecalled: BasePart? = nil
	local list = targetMarks[userId]
	targetMarks[userId] = nil
	for _, mark in (list or {}) :: { TargetMark } do
		local ctx, hit = mark.ctx, mark.hit
		fx("end", { id = mark.id }, mark.position)
		if t < mark.expires and alive(hit) and refresh(ctx) and Targeting.canHarm(player, hit.model) then
			local from = hit.root.Position
			moveBody(hit, mark.position)
			stun(hit, userId, Rules.byTier(T.targetTimeline.stun, ctx.stats.masteryTier))
			DamageModel.hit(ctx, hit, T.targetTimeline.share, "rewound", { noFalloff = true })
			fx("recall", { to = mark.position }, from, true)
			firstRecalled = firstRecalled or hit.root
		end
	end
	if firstRecalled then
		releaseStored(userId, firstRecalled.Position, firstRecalled)
	else
		releaseStored(userId, aim, nil)
	end
	publish(player)
end

-- ─── Timestop ───────────────────────────────────────────────────────────────

function TimeRuntime.stopRefusal(userId: number): string?
	return if (stopReady[userId] or 0) > now() then "TIMESTOP_COOLDOWN" else nil
end

function TimeRuntime.startStop(ctx: Ctx): number
	local tier = ctx.stats.masteryTier
	local seconds = Rules.byTier(T.timestop.seconds, tier)
	local radius = Rules.stopRadius(ctx.stats.area)
	local t = now()
	stopReady[ctx.player.UserId] = t + Rules.byTier(T.timestop.cooldown, tier)
	local stop: Stop = { id = newId(), ctx = ctx, center = ctx.point, radius = radius, expires = t + seconds, nextScan = t, frozen = {}, flights = {} }
	table.insert(stops, stop)
	fx("stop", { id = stop.id, radius = radius, duration = seconds, caster = ctx.player.UserId }, ctx.point, true)
	log:info("timestop", { userId = ctx.player.UserId, seconds = seconds, radius = radius })
	return seconds
end

local function scanStop(stop: Stop, t: number)
	local ctx = stop.ctx
	local remaining = stop.expires - t
	for _, hit in Targeting.inRadius(stop.center, stop.radius, T.timestop.maxTargets, { [ctx.character] = true }) do
		if not stop.frozen[hit.humanoid] and Targeting.canHarm(ctx.player, hit.model) then
			-- Stasis first: an NPC it anchors isn't "already anchored" to the hold (GravityRuntime.hold).
			StatusEffects.apply(hit.humanoid, "stasis", { duration = remaining + 0.1, source = ctx.player.UserId })
			local hold = GravityRuntime.hold(hit, ctx.player.UserId, remaining + 0.1)
			if hold then
				stop.frozen[hit.humanoid] = hold
			else
				StatusEffects.remove(hit.humanoid, "stasis") -- immune, or something else already has them
			end
		end
	end
end

local function endStop(stop: Stop)
	for humanoid, hold in stop.frozen do
		GravityRuntime.release(hold)
		if humanoid.Parent then
			StatusEffects.remove(humanoid, "stasis")
		end
	end
	for _, flight in stop.flights do
		Delivery.release(flight, nil, nil) -- on with what they were doing
	end
	fx("end", { id = stop.id }, stop.center)
end

-- Projectiles hang inside a stopped zone, and a caster's own during a Stored Moment.
local function hanger(position: Vector3, flight: Delivery.Flight, age: number): number?
	local t = now()
	for _, stop in stops do
		if (position - stop.center).Magnitude <= stop.radius then
			table.insert(stop.flights, flight)
			return stop.expires - t
		end
	end
	if age < T.stored.hangAfter or releasedFromStored[flight] then
		return nil
	end
	local owner = Players:GetPlayerFromCharacter(flight.ownerModel)
	local s = owner and stored[owner.UserId]
	if s and owner and #s.flights < s.capacity then
		table.insert(s.flights, flight)
		publish(owner)
		return s.expires - t
	end
	return nil
end

-- ─── Borrowed Wound, Future Sight, Last Moment: all in the damage path ──────

function TimeRuntime.startWoundOn(ctx: Ctx, hit: Hit, onSelf: boolean)
	local tier = ctx.stats.masteryTier
	local seconds = Rules.byTier(T.wound.seconds, tier)
	wounds[hit.humanoid] = {
		total = 0,
		mult = Rules.byTier(if onSelf then T.wound.selfMult else T.wound.targetMult, tier),
		expires = now() + seconds,
		source = if onSelf then nil else ctx.player.UserId,
		humanoid = hit.humanoid,
		domain = ctx.stats.domains[1],
		power = ctx.stats.recipe.power,
		branch = ctx.stats.recipe.branch,
	}
	fx("wound", { model = hit.model, duration = seconds }, hit.root.Position)
end

function TimeRuntime.startSight(ctx: Ctx)
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local tier = ctx.stats.masteryTier
	local seconds = Rules.byTier(T.foresight.seconds, tier)
	StatusEffects.apply(humanoid, "foreseeing", { duration = seconds, source = ctx.player.UserId })
	sights[humanoid] = { expires = now() + seconds, dodge = Rules.byTier(T.foresight.dodge, tier), player = ctx.player, rng = ctx.rng }
end

-- Someone cast near a person with Future Sight: they see where it's going.
function TimeRuntime.onSpellCast(casterUserId: number?, point: Vector3?)
	if not point then
		return
	end
	local t = now()
	for humanoid, sight in sights do
		if t >= sight.expires or not humanoid.Parent then
			sights[humanoid] = nil
		elseif sight.player.UserId ~= casterUserId then
			local root = humanoid.RootPart
			if root and (root.Position - point).Magnitude <= T.foresight.seeRadius then
				Net.fire("WorldEffect", sight.player, { kind = "time", fx = "foresee", position = point, radius = 8 })
			end
		end
	end
end

--[[
	Damage.interceptor: runs inside Damage.apply with what's about to land, and on overdraw backlash.
	Order: a blow that would kill triggers your mark. Otherwise a wound holds it back, or you foresaw it.
]]
local function intercept(humanoid: Humanoid, amount: number, source: number?, kind: string, info: Damage.Info?): number
	local model = humanoid.Parent
	local player = if model and model:IsA("Model") then Players:GetPlayerFromCharacter(model) else nil
	local t = now()

	if player then
		local mark = selfMarks[player]
		if mark and mark.humanoid == humanoid and Rules.savesFromDeath(amount, humanoid.Health, true, mark.expires, mark.tier, lastMomentReady[player] or 0, t) then
			lastMomentReady[player] = t + Rules.byTier(T.lastMoment.cooldown, mark.tier)
			applyRecall(player, mark)
			log:info("time_last_moment", { userId = player.UserId, source = source, kind = kind })
			return 0
		end
	end

	if kind == "internal" or (info and info.undeferred) then
		return amount
	end
	local wound = wounds[humanoid]
	if wound and t < wound.expires then
		wound.total += amount
		return 0
	end
	local sight = sights[humanoid]
	if sight and t < sight.expires and info and info.from and sight.rng:NextNumber() < sight.dodge then
		local root = humanoid.RootPart
		if root and runner then
			runner:cue("statusTag", { status = "foreseen", name = "Foreseen", harmful = false, caster = source }, root.Position + Vector3.new(0, 3, 0), false)
		end
		return 0
	end
	return amount
end

local function stepWounds(t: number)
	for humanoid, wound in wounds do
		if t >= wound.expires or not humanoid.Parent or humanoid.Health <= 0 then
			wounds[humanoid] = nil
			local total = Rules.woundTotal(wound.total, wound.mult)
			if total > 0 and humanoid.Parent and humanoid.Health > 0 then
				Damage.apply(humanoid, total, wound.source, "borrowed_wound", {
					domain = wound.domain,
					power = wound.power,
					branch = wound.branch,
					undeferred = true,
				})
				local root = humanoid.RootPart
				if root then
					fx("wound_land", { radius = 7 }, root.Position, true)
				end
			end
		end
	end
end

-- ─── Time Loop ──────────────────────────────────────────────────────────────

function TimeRuntime.startLoop(ctx: Ctx, hit: Hit)
	table.insert(loops, {
		ctx = ctx,
		hit = hit,
		position = hit.root.Position,
		left = Rules.byTier(T.loop.loops, ctx.stats.masteryTier),
		nextAt = now() + T.loop.interval,
	})
	fx("loop", { radius = 7 }, hit.root.Position)
end

local function stepLoops(t: number)
	for i = #loops, 1, -1 do
		local loop = loops[i]
		local ctx, hit = loop.ctx, loop.hit
		if not alive(hit) or loop.left <= 0 or not refresh(ctx) or not Targeting.canHarm(ctx.player, hit.model) then
			table.remove(loops, i)
		elseif t >= loop.nextAt then
			loop.nextAt = t + T.loop.interval
			loop.left -= 1
			local from = hit.root.Position
			moveBody(hit, loop.position)
			stun(hit, ctx.player.UserId, T.loop.stun)
			DamageModel.hit(ctx, hit, T.loop.share, "rewound", { noFalloff = true })
			fx("recall", { to = loop.position }, from)
		end
	end
end

-- ─── Stepping ───────────────────────────────────────────────────────────────

local function stepAll()
	local t = now()

	for player, mark in table.clone(selfMarks) do
		if t >= mark.expires or not player.Parent or player.Character ~= mark.model then
			dropMark(player, mark)
		end
	end

	for userId, list in table.clone(targetMarks) do
		local changed = false
		for i = #list, 1, -1 do
			local mark = list[i]
			if t >= mark.expires or not alive(mark.hit) then
				table.remove(list, i)
				fx("end", { id = mark.id }, mark.position)
				changed = true
			end
		end
		if #list == 0 then
			targetMarks[userId] = nil
		end
		if changed then
			local player = Players:GetPlayerByUserId(userId)
			if player then
				publish(player)
			end
		end
	end

	for userId, s in table.clone(stored) do
		if t >= s.expires then
			releaseStored(userId, nil, nil)
			local player = Players:GetPlayerByUserId(userId)
			if player then
				publish(player)
			end
		end
	end

	for i = #stops, 1, -1 do
		local stop = stops[i]
		if t >= stop.expires then
			table.remove(stops, i)
			endStop(stop)
		elseif t >= stop.nextScan then
			stop.nextScan = t + T.timestop.scanEvery
			scanStop(stop, t)
		end
	end

	for i = #stuns, 1, -1 do
		local s = stuns[i]
		if t >= s.expires then
			table.remove(stuns, i)
			GravityRuntime.release(s.hold)
		end
	end

	stepWounds(t)
	stepLoops(t)
end

function TimeRuntime.step(_dt: number)
	local ok, err = pcall(stepAll)
	if not ok and log then
		log:throttled("time_step", 30, "Error", "time_step_failed", { err = err })
	end
end

-- Dispel ends other people's Time near a point (EffectRunner.dispelArea). Returns how many.
function TimeRuntime.dispel(position: Vector3, radius: number, owner: number?): number
	local count = 0
	for i = #stops, 1, -1 do
		local stop = stops[i]
		if stop.ctx.player.UserId ~= owner and (stop.center - position).Magnitude <= radius + stop.radius then
			table.remove(stops, i)
			endStop(stop)
			count += 1
		end
	end
	for humanoid, wound in wounds do
		local root = humanoid.RootPart
		if wound.source ~= owner and root and (root.Position - position).Magnitude <= radius then
			wound.expires = 0 -- it lands now
			count += 1
		end
	end
	return count
end

function TimeRuntime.forget(player: Player)
	selfMarks[player] = nil
	recallReady[player] = nil
	lastMomentReady[player] = nil
	targetMarks[player.UserId] = nil
	stopReady[player.UserId] = nil
	if stored[player.UserId] then
		releaseStored(player.UserId, nil, nil)
	end
end

function TimeRuntime.start(effectRunner: any, logger: any, serviceHooks: Hooks)
	runner, log, hooks = effectRunner, logger, serviceHooks
	Damage.interceptor = intercept
	Delivery.hanger = hanger
end

function TimeRuntime.report(): string
	local function count(t: { [any]: any }): number
		local n = 0
		for _ in t do
			n += 1
		end
		return n
	end
	return string.format(
		"self marks %d · target marks %d · stored %d · stops %d · wounds %d · sights %d · loops %d · stuns %d",
		count(selfMarks), count(targetMarks), count(stored), #stops, count(wounds), count(sights), #loops, #stuns
	)
end

return TimeRuntime
