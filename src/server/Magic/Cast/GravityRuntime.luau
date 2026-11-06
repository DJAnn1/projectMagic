--!strict
--[[
	GravityRuntime: the powers that outlive their cast (docs/Gravity.md). Effects/GravityPower starts
	them, Services/GravityService steps them. Numbers: Shared/Magic/Data/GravityTuning + GravityRules.

	HOLD      The shared tool: the victim's root is anchored by the server, so they can't move,
	          whatever their client wants (CharacterSafety.holdArea freezes people the same way), and
	          the "gravity_held" status and GravityHeld attribute stop casts, dashes and attacks.
	          Something already anchored (a dummy, a storm node) can be held but never moved.
	          After a hold there's a short immunity. A warded quest NPC can't be held by outsiders.
	GRIP      Pins one target and tightens: damage ramps, and near the end it can finish them.
	          Slips if you lose sight of them, they get too far, you die, or they stop being harmable.
	LIFT      Seizes a target, raises it, hangs, then drives it into the ground at the aim.
	WELL      Drags everyone in reach toward a point and crushes at the middle. Players drag on their
	          own client (the "gravity_pull" cue), so ignoring it denies only the drag: the crush is
	          the server's. NPCs and loose parts are moved here.
	SINGULARITY  Holds up to maxTargets, pulls them together, then detonates.
	SHIELDS   Orbit Shield stops hostile projectiles, one piece each. Bend Path curves them away, or
	          turns them back. Both hook Delivery.interceptor.
	FLIGHT    Players own their physics, so their client flies and this checks it: reservoir drain,
	          speed and height. Being held, silenced, knocked down or empty ends it.
	METEOR    At Master, a dive out of flight: anchored by the server, driven into the ground, and
	          damage by how far you fell.

	CRIMES    Settlement law only sees hits dealt while the spell resolves (CastService records that
	          thread), so every harmful power lands its first hit there. Later hits on NPCs still
	          reach FactionService through TargetDamaged.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local G = require(Shared.Magic.Data.GravityTuning)
local Rules = require(Shared.Magic.GravityRules)

local Cast = script.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local Delivery = require(Cast.Delivery)
local EffectBudget = require(Cast.EffectBudget)
local PvpRules = require(Cast.PvpRules)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local TimeZones = require(Cast.TimeZones)
local WorldConfig = require(Cast.Parent.Parent.World.WorldConfig)
local TerrainDeform = require(Cast.Parent.Parent.World.TerrainDeform)

local HELD_ATTRIBUTE = "GravityHeld"

type Ctx = CastTypes.EffectContext
type Hit = CastTypes.Hit

type Hold = { hit: Hit, wasAnchored: boolean, expires: number }

type Grip = { id: number, ctx: Ctx, hold: Hold, started: number, nextTick: number, nextSight: number, expires: number, maxRange: number }

type Lift = { ctx: Ctx, hold: Hold, start: Vector3, top: Vector3, offset: number, height: number, age: number, landing: Vector3?, from: Vector3? }

type Well = { id: number, ctx: Ctx, center: Vector3, radius: number, expires: number, nextTick: number, nextCrush: number }

type Singularity = { id: number, ctx: Ctx, center: Vector3, radius: number, holds: { Hold }, age: number, nextTick: number }

type Orbit = { id: number, userId: number, root: BasePart, pieces: number, expires: number }

type Bend = { id: number, userId: number, root: BasePart, radius: number, chance: number, expires: number, rng: Random }

type Flying = {
	ctx: Ctx,
	player: Player,
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	flight: Rules.Flight,
	check: number,
	lastPosition: Vector3,
	strikes: number,
}

type Meteor = { ctx: Ctx, model: Model, root: BasePart, ground: Vector3, height: number }

local GravityRuntime = {}

local runner: any = nil
local world: any = nil
local log: any = nil

local holds: { [Humanoid]: Hold } = {}
local holdCount = 0
local immuneUntil: { [Humanoid]: number } = setmetatable({}, { __mode = "k" }) :: any
local grips: { [number]: Grip } = {} -- by caster
local lifts: { Lift } = {}
local wells: { Well } = {}
local singularities: { Singularity } = {}
local orbits: { [number]: Orbit } = {} -- by caster
local bends: { [number]: Bend } = {} -- by caster
local flights: { [Player]: Flying } = {}
local meteors: { Meteor } = {}
local craterCells: { [string]: number } = {} -- "x,z" cell -> when another crater may land there
local nextCrater = 0
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
		runner:cue("gravity", payload, position, heavy == true)
	end
end

local function flat(a: Vector3, b: Vector3): number
	return Vector3.new(a.X - b.X, 0, a.Z - b.Z).Magnitude
end

local function alive(hit: Hit): boolean
	return hit.model.Parent ~= nil and hit.humanoid.Parent ~= nil and hit.humanoid.Health > 0
end

local function hitFor(model: Model, humanoid: Humanoid, root: BasePart): Hit
	return { model = model, humanoid = humanoid, root = root, distance = 0 }
end

-- Keeps a stored cast's context current: guards and resistances judge from where the caster is now.
local function refresh(ctx: Ctx): boolean
	local root = ctx.root
	if not root.Parent or ctx.player.Character ~= ctx.character then
		return false
	end
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid or humanoid.Health <= 0 then
		return false
	end
	ctx.origin = root.Position
	return true
end

-- ─── The ground ─────────────────────────────────────────────────────────────

-- The first solid thing under a point, ignoring characters. Roofs count, so a thrown target lands on
-- top of a building, not inside it.
local function groundBelow(from: Vector3, ignore: Instance?): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded: { Instance } = {}
	if ignore then
		table.insert(excluded, ignore)
	end
	local magicFx = workspace:FindFirstChild("MagicFx")
	if magicFx then
		table.insert(excluded, magicFx)
	end
	local start = from + Vector3.new(0, 4, 0)
	for _ = 1, 6 do
		params.FilterDescendantsInstances = excluded
		local result = workspace:Raycast(start, Vector3.new(0, -600, 0), params)
		if not result then
			return nil
		end
		local instance = result.Instance
		if instance:IsA("Terrain") or ((instance :: BasePart).CanCollide and not Targeting.characterOf(instance)) then
			return result.Position
		end
		table.insert(excluded, instance) -- leaves, glass, someone's head
	end
	return nil
end

-- ─── Holding ────────────────────────────────────────────────────────────────

-- Can the server hold this body right now? (Nil = no: already held, immune, warded or at the cap.)
function GravityRuntime.hold(hit: Hit, sourceUserId: number, seconds: number, force: boolean?): Hold?
	local humanoid = hit.humanoid
	if holds[humanoid] or not alive(hit) then
		return nil
	end
	-- `force`: a Timestop freezes everything, whatever protects it from a mere grip.
	if not force then
		if holdCount >= G.hold.maxHolds or (immuneUntil[humanoid] or 0) > now() then
			return nil
		end
		-- Quest NPCs under someone's ward can't be frozen by anyone else (Damage.apply refuses their hits).
		local ward = humanoid:GetAttribute("QuestWard")
		if typeof(ward) == "number" and ward ~= sourceUserId then
			return nil
		end
	end
	-- Stasis looks after its own anchoring, so it doesn't count as "already anchored" here: that would
	-- leave an NPC anchored for good once both had ended.
	local fixed = hit.root.Anchored and humanoid:GetAttribute("StasisAnchored") ~= true
	local hold: Hold = { hit = hit, wasAnchored = fixed, expires = now() + seconds }
	holds[humanoid] = hold
	holdCount += 1
	hit.model:SetAttribute(HELD_ATTRIBUTE, true)
	hit.root.Anchored = true
	StatusEffects.apply(humanoid, "gravity_held", { duration = seconds + 0.25, source = sourceUserId })
	return hold
end

-- Puts someone down. Safe to call twice.
function GravityRuntime.release(hold: Hold)
	local hit = hold.hit
	if holds[hit.humanoid] ~= hold then
		return
	end
	holds[hit.humanoid] = nil
	holdCount -= 1
	immuneUntil[hit.humanoid] = now() + G.hold.immunitySeconds
	if hit.model.Parent then
		hit.model:SetAttribute(HELD_ATTRIBUTE, nil)
	end
	if hit.root.Parent then
		-- Stasis keeps an NPC anchored by its own attribute; a player is never anchored by a status.
		hit.root.Anchored = hold.wasAnchored or hit.humanoid:GetAttribute("StasisAnchored") == true
	end
	if hit.humanoid.Parent then
		StatusEffects.remove(hit.humanoid, "gravity_held")
	end
end

local function moveHeld(hold: Hold, position: Vector3)
	if not hold.wasAnchored and hold.hit.model.Parent then
		hold.hit.model:PivotTo(CFrame.new(position) * hold.hit.root.CFrame.Rotation)
	end
end

-- Who has this body, if anyone (Cast/TimeRuntime: a recall outranks a hold).
function GravityRuntime.holdOf(humanoid: Humanoid): Hold?
	return holds[humanoid]
end

function GravityRuntime.releaseFor(humanoid: Humanoid)
	local hold = holds[humanoid]
	if hold then
		GravityRuntime.release(hold)
	end
end

-- Pushes a character: players on their own client, everyone else here.
local function launch(hit: Hit, velocity: Vector3)
	local player = Players:GetPlayerFromCharacter(hit.model)
	if player then
		Net.fire("WorldEffect", player, { kind = "knockback", velocity = velocity })
	elseif not hit.root.Anchored then
		hit.root.AssemblyLinearVelocity += velocity
	end
end

-- ─── Crushing Grip ──────────────────────────────────────────────────────────

local function gripTick(grip: Grip, t: number)
	local ctx, hit = grip.ctx, grip.hold.hit
	local elapsed = t - grip.started
	DamageModel.hit(ctx, hit, Rules.gripShare(elapsed), "crushing", { noFalloff = true })
	if hit.humanoid.Health <= 0 then
		return
	end
	if Rules.gripExecutes(ctx.stats.masteryTier, hit.humanoid.Health / math.max(1, hit.humanoid.MaxHealth)) then
		Damage.apply(hit.humanoid, hit.humanoid.Health, ctx.player.UserId, "crushing", {
			domain = ctx.stats.domains[1],
			power = ctx.stats.recipe.power,
			from = ctx.origin,
			form = ctx.stats.recipe.form,
			property = ctx.stats.recipe.property,
			pierce = true,
			branch = ctx.stats.recipe.branch,
		})
	end
end

local function endGrip(grip: Grip)
	local userId = grip.ctx.player.UserId
	if grips[userId] == grip then
		grips[userId] = nil
	end
	local hit = grip.hold.hit
	if hit.root.Parent and hit.humanoid.Health <= 0 then
		fx("implode", { radius = 6 }, hit.root.Position, true)
	end
	fx("end", { id = grip.id }, hit.root.Position)
	GravityRuntime.release(grip.hold)
end

-- Returns whether it took hold. The first hit lands here, on the resolving thread (see CRIMES).
function GravityRuntime.startGrip(ctx: Ctx, hit: Hit): boolean
	local seconds = Rules.byTier(G.grip.duration, ctx.stats.masteryTier)
	local previous = grips[ctx.player.UserId]
	if previous and previous.hold.hit.humanoid == hit.humanoid then
		-- Casting again on who you already hold keeps them, and keeps the crush as tight as it was.
		local t = now()
		previous.ctx = ctx
		previous.expires = t + seconds
		previous.hold.expires = t + seconds
		StatusEffects.apply(hit.humanoid, "gravity_held", { duration = seconds + 0.25, source = ctx.player.UserId })
		gripTick(previous, t)
		return true
	end
	if previous then
		endGrip(previous)
	end
	local hold = GravityRuntime.hold(hit, ctx.player.UserId, seconds)
	if not hold then
		return false
	end
	local t = now()
	local grip: Grip = {
		id = newId(),
		ctx = ctx,
		hold = hold,
		started = t,
		nextTick = t + G.grip.tick,
		nextSight = t + G.grip.sightEvery,
		expires = t + seconds,
		maxRange = ctx.stats.range * G.grip.rangeMult + G.grip.rangeMargin,
	}
	grips[ctx.player.UserId] = grip
	fx("grip", { id = grip.id, model = hit.model, duration = seconds, caster = ctx.player.UserId }, hit.root.Position, true)
	gripTick(grip, t)
	return true
end

local function stepGrips(t: number, dt: number)
	for _, grip in table.clone(grips) do
		local ctx, hit = grip.ctx, grip.hold.hit
		-- A Timestop pauses it: nothing tightens, and no time passes for it.
		if TimeZones.stopped(hit.root.Position) then
			grip.expires += dt
			grip.started += dt
			grip.nextTick += dt
			grip.nextSight += dt
			grip.hold.expires += dt
			continue
		end
		-- The hold can go from under it too: a recall takes the victim out of your grip.
		if t >= grip.expires or holds[hit.humanoid] ~= grip.hold or not alive(hit) or not refresh(ctx) or not Targeting.canHarm(ctx.player, hit.model) or (hit.root.Position - ctx.origin).Magnitude > grip.maxRange then
			endGrip(grip)
		else
			if t >= grip.nextSight then
				grip.nextSight = t + G.grip.sightEvery
				if Targeting.occluded(ctx.origin + Vector3.new(0, 1.5, 0), hit, { ctx.character }) then
					endGrip(grip)
					continue
				end
			end
			if t >= grip.nextTick then
				grip.nextTick = t + G.grip.tick
				gripTick(grip, t)
			end
		end
	end
end

-- ─── Lift and Slam ──────────────────────────────────────────────────────────

function GravityRuntime.startLift(ctx: Ctx, hit: Hit): boolean
	local tier = ctx.stats.masteryTier
	local L = G.lift
	local hold = GravityRuntime.hold(hit, ctx.player.UserId, L.rise + L.hang + L.fall + 0.25)
	if not hold then
		return false
	end
	local start = hit.root.Position
	local ground = groundBelow(start, hit.model)
	local height = Rules.byTier(L.height, tier)
	table.insert(lifts, {
		ctx = ctx,
		hold = hold,
		start = start,
		top = start + Vector3.new(0, height, 0),
		offset = if ground then math.clamp(start.Y - ground.Y, 2, 8) else 3,
		height = height,
		age = 0,
		landing = nil,
		from = nil,
	})
	DamageModel.hit(ctx, hit, L.firstShare, "slam", { noFalloff = true })
	fx("lift", { model = hit.model, height = height, duration = L.rise + L.hang + L.fall }, start, true)
	return true
end

local function landLift(lift: Lift, landing: Vector3)
	local ctx, hit = lift.ctx, lift.hold.hit
	local L = G.lift
	moveHeld(lift.hold, landing)
	GravityRuntime.release(lift.hold)
	local tier = ctx.stats.masteryTier
	local share = Rules.slamShare(lift.height)
	local radius = L.splashRadius + L.splashPerTier * math.max(1, tier)
	fx("slam", { radius = radius }, landing, true)
	if not refresh(ctx) then
		return -- the caster is gone: the fall still happens, but nobody is credited with it
	end
	if alive(hit) and Targeting.canHarm(ctx.player, hit.model) then
		DamageModel.hit(ctx, hit, share, "slam", { noFalloff = true })
	end
	for _, near in Targeting.inRadius(landing, radius, L.maxSplash, { [ctx.character] = true, [hit.model] = true }) do
		if Targeting.canHarm(ctx.player, near.model) then
			DamageModel.hit(ctx, near, share * L.splashShare, "slam", { noFalloff = true })
		end
	end
end

local function stepLifts(dt: number)
	local L = G.lift
	for i = #lifts, 1, -1 do
		local lift = lifts[i]
		local hit = lift.hold.hit
		if TimeZones.stopped(hit.root.Position) then
			lift.hold.expires += dt -- it hangs in the air until time resumes
			continue
		end
		lift.age += dt
		if not alive(hit) or holds[hit.humanoid] ~= lift.hold then
			table.remove(lifts, i)
			GravityRuntime.release(lift.hold)
		elseif lift.age < L.rise then
			local a = lift.age / L.rise
			moveHeld(lift.hold, lift.start:Lerp(lift.top, 1 - (1 - a) * (1 - a)))
		elseif lift.age < L.rise + L.hang then
			moveHeld(lift.hold, lift.top)
		else
			if not lift.landing then
				local aimed = Rules.throwTarget(lift.top, lift.ctx.point, lift.ctx.stats.masteryTier)
				local ground = groundBelow(aimed, hit.model) or groundBelow(lift.top, hit.model)
				lift.landing = if ground then ground + Vector3.new(0, lift.offset, 0) else lift.start
				lift.from = lift.top
			end
			local a = (lift.age - L.rise - L.hang) / L.fall
			if a >= 1 then
				table.remove(lifts, i)
				landLift(lift, lift.landing :: Vector3)
			else
				moveHeld(lift.hold, (lift.from :: Vector3):Lerp(lift.landing :: Vector3, a * a))
			end
		end
	end
end

-- ─── Budgets for the area powers ────────────────────────────────────────────

function GravityRuntime.canStartArea(userId: number): boolean
	return EffectBudget.canAcquireActive(userId) and EffectBudget.available("mythicFields") > 0
end

local function takeArea(userId: number): boolean
	if not EffectBudget.acquireActive(userId) then
		return false
	end
	if not EffectBudget.acquire("mythicFields") then
		EffectBudget.releaseActive(userId)
		return false
	end
	return true
end

local function giveBackArea(userId: number)
	EffectBudget.releaseActive(userId)
	EffectBudget.release("mythicFields")
end

-- ─── Gravity Well ───────────────────────────────────────────────────────────

local function wellCrush(well: Well)
	local ctx = well.ctx
	local tier = ctx.stats.masteryTier
	local share = Rules.byTier(G.well.crushShare, tier)
	for _, hit in Targeting.inRadius(well.center, well.radius, G.well.maxTargets, { [ctx.character] = true }) do
		if Targeting.canHarm(ctx.player, hit.model) then
			local t = math.clamp(flat(hit.root.Position, well.center) / well.radius, 0, 1)
			DamageModel.hit(ctx, hit, share * (1 - t * 0.7), "crushing", { falloff = 1 })
		end
	end
end

function GravityRuntime.startWell(ctx: Ctx): boolean
	local userId = ctx.player.UserId
	if not takeArea(userId) then
		return false
	end
	local radius = Rules.wellRadius(ctx.stats.area)
	local seconds = Rules.byTier(G.well.seconds, ctx.stats.masteryTier)
	local t = now()
	local well: Well = { id = newId(), ctx = ctx, center = ctx.point, radius = radius, expires = t + seconds, nextTick = t, nextCrush = t + 1 }
	table.insert(wells, well)
	fx("well", { id = well.id, radius = radius, duration = seconds }, ctx.point, true)
	wellCrush(well)
	return true
end

local function pullLoose(well: Well, tier: number)
	local overlap = OverlapParams.new()
	overlap.MaxParts = G.well.maxLooseParts * 4
	local candidates: { BasePart } = {}
	for _, part in workspace:GetPartBoundsInRadius(well.center, well.radius, overlap) do
		if #candidates >= G.well.maxLooseParts then
			break
		end
		if not part.Anchored and not Targeting.characterOf(part) and part:GetNetworkOwner() == nil then
			table.insert(candidates, part)
		end
	end
	for i = 1, EffectBudget.takeParts(#candidates) do
		local part = candidates[i]
		local to = well.center - part.Position
		if to.Magnitude > 1 then
			part.AssemblyLinearVelocity = to.Unit * Rules.wellPull(tier, flat(part.Position, well.center), well.radius) * 1.5
		end
	end
end

local function stepWells(t: number, dt: number)
	for i = #wells, 1, -1 do
		local well = wells[i]
		local ctx = well.ctx
		if TimeZones.stopped(well.center) then
			well.expires += dt
			well.nextTick += dt
			well.nextCrush += dt
			continue
		end
		if t >= well.expires or not refresh(ctx) then
			table.remove(wells, i)
			giveBackArea(ctx.player.UserId)
			fx("end", { id = well.id }, well.center)
		elseif t >= well.nextTick then
			well.nextTick = t + G.well.tick
			local tier = ctx.stats.masteryTier
			for _, hit in Targeting.inRadius(well.center, well.radius, G.well.maxTargets, { [ctx.character] = true }) do
				if Targeting.canHarm(ctx.player, hit.model) and not holds[hit.humanoid] then
					local distance = flat(hit.root.Position, well.center)
					local speed = Rules.wellPull(tier, distance, well.radius)
					local player = Players:GetPlayerFromCharacter(hit.model)
					if player then
						Net.fire("WorldEffect", player, { kind = "gravity_pull", center = well.center, speed = speed, duration = G.well.tick + 0.15 })
					elseif not hit.root.Anchored and distance > 2 then
						local to = Vector3.new(well.center.X - hit.root.Position.X, 0, well.center.Z - hit.root.Position.Z)
						local v = hit.root.AssemblyLinearVelocity
						hit.root.AssemblyLinearVelocity = to.Unit * speed + Vector3.new(0, v.Y, 0)
					end
				end
			end
			pullLoose(well, tier)
			if t >= well.nextCrush then
				well.nextCrush = t + 1
				wellCrush(well)
			end
		end
	end
end

-- ─── Singularity ────────────────────────────────────────────────────────────

local function singularityTick(s: Singularity)
	local ctx = s.ctx
	for _, hold in s.holds do
		local hit = hold.hit
		if holds[hit.humanoid] == hold and alive(hit) and Targeting.canHarm(ctx.player, hit.model) then
			DamageModel.hit(ctx, hit, G.singularity.tickShare, "crushing", { noFalloff = true, noCrit = true })
		end
	end
end

function GravityRuntime.startSingularity(ctx: Ctx): boolean
	local userId = ctx.player.UserId
	if not takeArea(userId) then
		return false
	end
	local S = G.singularity
	local radius = Rules.singularityRadius(ctx.stats.area)
	local center = ctx.point + Vector3.new(0, 4, 0)
	local s: Singularity = { id = newId(), ctx = ctx, center = center, radius = radius, holds = {}, age = 0, nextTick = now() + S.tick }
	for _, hit in Targeting.inRadius(ctx.point, radius, S.maxTargets, { [ctx.character] = true }) do
		if Targeting.canHarm(ctx.player, hit.model) then
			local hold = GravityRuntime.hold(hit, userId, S.seconds + 0.25)
			if hold then
				table.insert(s.holds, hold)
			end
		end
	end
	table.insert(singularities, s)
	fx("singularity", { id = s.id, radius = radius, duration = S.seconds }, center, true)
	singularityTick(s)
	return true
end

local function detonate(s: Singularity)
	local ctx = s.ctx
	local S = G.singularity
	local share = Rules.blastShare(ctx.stats.masteryTier)
	local canCredit = refresh(ctx)
	for _, hold in s.holds do
		local hit = hold.hit
		local stillHeld = holds[hit.humanoid] == hold -- a recall may have taken them out of it
		GravityRuntime.release(hold)
		if stillHeld and alive(hit) then
			if canCredit and Targeting.canHarm(ctx.player, hit.model) then
				DamageModel.hit(ctx, hit, share, "crushing", { noFalloff = true })
			end
			if alive(hit) then
				local away = hit.root.Position - s.center
				local direction = if away.Magnitude > 0.5 then away.Unit else Vector3.new(0, 1, 0)
				launch(hit, (direction + Vector3.new(0, 0.5, 0)).Unit * S.blastLaunch)
			end
		end
	end
	giveBackArea(ctx.player.UserId)
	fx("end", { id = s.id }, s.center)
	fx("detonate", { radius = s.radius }, s.center, true)
	GravityRuntime.crater(s.center, Rules.singularityCrater(s.radius), ctx.player.UserId)
end

local function stepSingularities(dt: number, t: number)
	local S = G.singularity
	for i = #singularities, 1, -1 do
		local s = singularities[i]
		if TimeZones.stopped(s.center) then
			s.nextTick += dt
			for _, hold in s.holds do
				hold.expires += dt
			end
			continue
		end
		s.age += dt
		if s.age >= S.seconds then
			table.remove(singularities, i)
			detonate(s)
		else
			local rate = math.min(1, S.pullRate * dt)
			for _, hold in s.holds do
				if holds[hold.hit.humanoid] == hold and alive(hold.hit) then
					moveHeld(hold, hold.hit.root.Position:Lerp(s.center, rate))
				end
			end
			if t >= s.nextTick and refresh(s.ctx) then
				s.nextTick = t + S.tick
				singularityTick(s)
			end
		end
	end
end

-- ─── Orbit Shield and Bend Path ─────────────────────────────────────────────

function GravityRuntime.startOrbit(ctx: Ctx): number
	local tier = ctx.stats.masteryTier
	local pieces = Rules.byTier(G.orbit.pieces, tier)
	local seconds = Rules.seconds(G.orbit.seconds, G.orbit.secondsPerTier, tier)
	local userId = ctx.player.UserId
	local previous = orbits[userId]
	if previous then
		fx("end", { id = previous.id }, ctx.root.Position)
	end
	local orbit: Orbit = { id = newId(), userId = userId, root = ctx.root, pieces = pieces, expires = now() + seconds }
	orbits[userId] = orbit
	fx("orbit", { id = orbit.id, model = ctx.character, pieces = pieces, radius = G.orbit.radius, duration = seconds }, ctx.root.Position)
	return pieces
end

function GravityRuntime.startBend(ctx: Ctx)
	local tier = ctx.stats.masteryTier
	local seconds = Rules.seconds(G.bend.seconds, G.bend.secondsPerTier, tier)
	local radius = G.bend.radius + G.bend.radiusPerTier * math.max(1, tier)
	local userId = ctx.player.UserId
	local previous = bends[userId]
	if previous then
		fx("end", { id = previous.id }, ctx.root.Position)
	end
	local bend: Bend = { id = newId(), userId = userId, root = ctx.root, radius = radius, chance = Rules.byTier(G.bend.reflectChance, tier), expires = now() + seconds, rng = ctx.rng }
	bends[userId] = bend
	fx("bend", { id = bend.id, model = ctx.character, radius = radius, duration = seconds }, ctx.root.Position)
end

-- Would a projectile from this model be an attack on that player? NPC bolts always are.
local function hostile(owner: Model, userId: number): boolean
	local player = Players:GetPlayerFromCharacter(owner)
	if player then
		return player.UserId ~= userId and PvpRules.allowed(player.UserId, userId)
	end
	return true
end

local function intercept(position: Vector3, velocity: Vector3, flight: Delivery.Flight): (string?, any)
	if next(orbits) == nil and next(bends) == nil then
		return nil, nil
	end
	local t = now()
	local owner = flight.ownerModel
	for userId, orbit in orbits do
		if t >= orbit.expires or not orbit.root.Parent then
			orbits[userId] = nil
			fx("end", { id = orbit.id }, position)
		elseif (position - orbit.root.Position).Magnitude <= G.orbit.radius and hostile(owner, userId) then
			orbit.pieces -= 1
			if orbit.pieces <= 0 then
				orbits[userId] = nil
				fx("end", { id = orbit.id }, position)
			else
				fx("orbit_hit", { id = orbit.id, pieces = orbit.pieces }, position)
			end
			return "stop", nil
		end
	end
	if flight.bent then
		return nil, nil
	end
	for userId, bend in bends do
		if t >= bend.expires or not bend.root.Parent then
			bends[userId] = nil
			fx("end", { id = bend.id }, position)
		elseif (position - bend.root.Position).Magnitude <= bend.radius and hostile(owner, userId) then
			flight.bent = true
			if bend.rng:NextNumber() < bend.chance then
				local model = bend.root.Parent
				return "reflect", if model and model:IsA("Model") then model else nil
			end
			local away = position - bend.root.Position
			local speed = velocity.Magnitude
			local direction = if away.Magnitude > 0.1 and speed > 0.1 then (velocity.Unit + away.Unit * G.bend.turn).Unit else velocity.Unit
			return "bend", direction * speed
		end
	end
	return nil, nil
end

-- ─── Flight ─────────────────────────────────────────────────────────────────

local function setFlightAttributes(model: Model, flight: Rules.Flight?, meteor: boolean)
	model:SetAttribute("FlightSpeed", if flight then flight.speed else nil)
	model:SetAttribute("FlightCeiling", if flight then flight.ceiling else nil)
	model:SetAttribute("FlightMeteor", if flight and meteor then true else nil)
	model:SetAttribute("GravityFlight", if flight then true else nil) -- last: the client reads the others when this changes
end

function GravityRuntime.startFlight(ctx: Ctx)
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return
	end
	local tier = ctx.stats.masteryTier
	local flight = Rules.flight(tier)
	flights[ctx.player] = {
		ctx = ctx,
		player = ctx.player,
		model = ctx.character,
		humanoid = humanoid,
		root = ctx.root,
		flight = flight,
		check = 0,
		lastPosition = ctx.root.Position,
		strikes = 0,
	}
	setFlightAttributes(ctx.character, flight, tier >= G.meteor.minTier)
	fx("takeoff", { radius = 8 }, ctx.root.Position)
end

local function endFlight(player: Player, text: string?)
	local flying = flights[player]
	if not flying then
		return
	end
	flights[player] = nil
	if flying.model.Parent then
		setFlightAttributes(flying.model, nil, false)
	end
	if text and player.Parent then
		Net.fire("Notify", player, text)
	end
end

function GravityRuntime.isFlying(player: Player): boolean
	return flights[player] ~= nil
end

local function stepFlights(dt: number)
	for player, flying in table.clone(flights) do
		flying.check += dt
		if flying.check < G.flight.checkSeconds then
			continue
		end
		local elapsed = flying.check
		flying.check = 0
		local humanoid = flying.humanoid
		if not player.Parent or player.Character ~= flying.model or humanoid.Health <= 0 or not flying.root.Parent then
			endFlight(player)
			continue
		end
		-- Frozen in a Timestop: you stay in the air, and it costs nothing, until time resumes.
		if flying.model:GetAttribute("TimeFrozen") then
			flying.lastPosition = flying.root.Position
			continue
		end
		-- Being held or silenced, or knocked out of the air: you come down.
		if flying.model:GetAttribute(HELD_ATTRIBUTE) or StatusEffects.has(humanoid, "knockdown") or StatusEffects.blocksCasting(humanoid) then
			endFlight(player, "You've been dragged out of the air.")
			continue
		end
		local reservoirs = flying.ctx.services.reservoirs
		local state = reservoirs:get(player)
		if state and not state.infinite then
			state.current = math.max(0, state.current - state.max * flying.flight.drainShare * elapsed)
			reservoirs:push(player)
			if state.current <= 0 then
				endFlight(player, "Your reservoir is empty. You fall.")
				continue
			end
		end
		-- The client flies; the server checks it (Players own their characters' physics).
		local position = flying.root.Position
		local speed = (position - flying.lastPosition).Magnitude / math.max(elapsed, 1e-3)
		flying.lastPosition = position
		flying.model:SetAttribute("MoveAllowanceUntil", now() + 1)
		-- Over water, height counts from the water, as the client's own ray does, not from the sea bed.
		local height = position.Y - math.max(world:surfaceHeight(position.X, position.Z), WorldConfig.SEA_LEVEL)
		if Rules.flightViolation(flying.flight, speed, height) then
			flying.strikes += 1
			if flying.strikes >= G.flight.strikesToEnd then
				log:warn("flight_violation", { userId = player.UserId, speed = math.floor(speed), height = math.floor(height), allowed = flying.flight.speed, ceiling = flying.flight.ceiling })
				endFlight(player, "The sky won't hold you that way.")
			end
		else
			flying.strikes = 0
		end
	end
end

-- ─── Meteor Landing ─────────────────────────────────────────────────────────

-- A client's FlightIntent. "land" just ends the flight. "dive" needs Master, and height.
function GravityRuntime.flightIntent(player: Player, intent: string)
	local flying = flights[player]
	if not flying then
		return
	end
	if intent == "land" then
		endFlight(player)
		return
	end
	local ground = groundBelow(flying.root.Position, flying.model)
	local height = if ground then flying.root.Position.Y - ground.Y else 0
	if not ground or not Rules.canMeteor(flying.ctx.stats.masteryTier, height) then
		Net.fire("Notify", player, if flying.ctx.stats.masteryTier < G.meteor.minTier then "Only a Master can fall like that." else "You're too low to dive.")
		return
	end
	local ctx = flying.ctx
	endFlight(player)
	flying.root.Anchored = true
	flying.model:SetAttribute(HELD_ATTRIBUTE, true)
	table.insert(meteors, { ctx = ctx, model = flying.model, root = flying.root, ground = ground, height = height })
end

local function stepMeteors(dt: number)
	local M = G.meteor
	for i = #meteors, 1, -1 do
		local meteor = meteors[i]
		local ctx = meteor.ctx
		if not meteor.root.Parent then
			table.remove(meteors, i)
			continue
		end
		local position = meteor.root.Position
		if TimeZones.stopped(position, ctx.player.UserId) then
			continue -- someone else stopped time: it hangs mid-fall
		end
		local target = meteor.ground + Vector3.new(0, 3.2, 0)
		local remaining = position.Y - target.Y
		local step = M.speed * dt
		if remaining > step then
			meteor.model:PivotTo(meteor.root.CFrame + Vector3.new(0, -step, 0))
		else
			table.remove(meteors, i)
			meteor.model:PivotTo(CFrame.new(target) * meteor.root.CFrame.Rotation)
			meteor.root.Anchored = false
			meteor.model:SetAttribute(HELD_ATTRIBUTE, nil)
			local radius = Rules.meteorRadius(meteor.height)
			fx("slam", { radius = radius, heavy = true }, meteor.ground, true)
			GravityRuntime.crater(meteor.ground, Rules.meteorCrater(meteor.height), ctx.player.UserId)
			if refresh(ctx) then
				local share = Rules.meteorShare(meteor.height)
				for _, hit in Targeting.inRadius(meteor.ground, radius, M.maxTargets, { [ctx.character] = true }) do
					if Targeting.canHarm(ctx.player, hit.model) then
						local t = math.clamp((hit.root.Position - meteor.ground).Magnitude / radius, 0, 1)
						DamageModel.hit(ctx, hit, share * (1 - 0.55 * t), "slam", { falloff = 1 })
						if alive(hit) then
							local away = hit.root.Position - meteor.ground
							local direction = if away.Magnitude > 0.5 then away.Unit else Vector3.new(0, 1, 0)
							launch(hit, (direction + Vector3.new(0, 0.6, 0)).Unit * 70 * (1 - 0.5 * t))
						end
					end
				end
			end
		end
	end
end

-- ─── Craters ────────────────────────────────────────────────────────────────

--[[
	A hole in the world, kept by every server (TerrainDeform.commit). Only carving and natural ground,
	like a quake's rupture. Inside a town it's a scorch mark, not a hole: a permanent pit under streets
	and foundations couldn't be mended. Near-repeats are skipped, so one spot can't fill the save.
]]
function GravityRuntime.crater(position: Vector3, radius: number, userId: number)
	if not world then
		return
	end
	local y = TerrainDeform.surfaceAt(world, position.X, position.Z)
	local x, z = position.X, position.Z
	if y < WorldConfig.SEA_LEVEL + G.crater.minAboveSea then
		return -- under the sea, or so low it would flood
	end
	local cell = string.format("%d,%d", x // G.crater.cell, z // G.crater.cell)
	local t = now()
	if (craterCells[cell] or 0) > t or t < nextCrater then
		return
	end
	craterCells[cell] = t + G.crater.cellSeconds
	nextCrater = t + G.crater.minGap
	local inTown = world:settlementAt(x, z) ~= nil
	local ops = if inTown then TerrainDeform.scorchOps(world, Vector3.new(x, y, z)) else Rules.craterOps(x, y, z, radius)
	if not inTown then
		-- The bowl first: when the budget runs short, only the rim goes.
		local granted = EffectBudget.takeTerrainOps(#ops)
		while #ops > granted do
			table.remove(ops)
		end
	end
	if #ops == 0 then
		return
	end
	task.spawn(function()
		local ok, err = pcall(TerrainDeform.commit, world, "crater", ops)
		if not ok then
			log:warn("crater_failed", { err = err, userId = userId })
		end
	end)
end

-- ─── Dispel ─────────────────────────────────────────────────────────────────

-- Dispel ends other people's gravity in the area (EffectRunner.dispelArea). Returns how many.
function GravityRuntime.dispel(position: Vector3, radius: number, owner: number?): number
	local count = 0
	for userId, grip in table.clone(grips) do
		if userId ~= owner and (grip.hold.hit.root.Position - position).Magnitude <= radius then
			endGrip(grip)
			count += 1
		end
	end
	for i = #wells, 1, -1 do
		local well = wells[i]
		if well.ctx.player.UserId ~= owner and (well.center - position).Magnitude <= radius + well.radius then
			table.remove(wells, i)
			giveBackArea(well.ctx.player.UserId)
			fx("end", { id = well.id }, well.center)
			count += 1
		end
	end
	for userId, orbit in orbits do
		if userId ~= owner and orbit.root.Parent and (orbit.root.Position - position).Magnitude <= radius then
			orbits[userId] = nil
			fx("end", { id = orbit.id }, position)
			count += 1
		end
	end
	for userId, bend in bends do
		if userId ~= owner and bend.root.Parent and (bend.root.Position - position).Magnitude <= radius then
			bends[userId] = nil
			fx("end", { id = bend.id }, position)
			count += 1
		end
	end
	return count
end

-- ─── Lifecycle ──────────────────────────────────────────────────────────────

-- Anything held past its time is let go, whichever power forgot (a safety net, not the normal path).
local function stepHolds(t: number)
	for _, hold in table.clone(holds) do
		if t >= hold.expires + 1 or not alive(hold.hit) then
			GravityRuntime.release(hold)
		end
	end
end

local function stepAll(dt: number)
	local t = now()
	stepGrips(t, dt)
	stepLifts(dt)
	stepWells(t, dt)
	stepSingularities(dt, t)
	stepFlights(dt)
	stepMeteors(dt)
	stepHolds(t)
end

function GravityRuntime.step(dt: number)
	local ok, err = pcall(stepAll, dt)
	if not ok and log then
		log:throttled("gravity_step", 30, "Error", "gravity_step_failed", { err = err })
	end
end

function GravityRuntime.start(effectRunner: any, worldService: any, logger: any)
	runner, world, log = effectRunner, worldService, logger
	Delivery.interceptor = intercept
end

function GravityRuntime.report(): string
	local count = function(t: { [any]: any }): number
		local n = 0
		for _ in t do
			n += 1
		end
		return n
	end
	return string.format(
		"holds %d · grips %d · lifts %d · wells %d · singularities %d · orbit shields %d · bends %d · flying %d · meteors %d",
		holdCount, count(grips), #lifts, #wells, #singularities, count(orbits), count(bends), count(flights), #meteors
	)
end

-- Exposed for specs: a held body's bookkeeping, without a live server.
GravityRuntime.heldAttribute = HELD_ATTRIBUTE
GravityRuntime.hitFor = hitFor

return GravityRuntime
