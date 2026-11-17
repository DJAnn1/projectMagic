--!strict
--[[
	VoidArt: Void's own spells (docs/DomainIdeas.md, "Void"). Void takes away: other people's magic, light,
	charge, presence. Ordinary moves that fit their branch, each reached by a narrow route in
	Data/EffectLibrary ("void_" .. move, with params.move). Numbers: Data/VoidTuning. Anything that lasts
	runs in Cast/ArtRuntime; looks in Client/Fx/VoidFx (cue kind "void", bodies drawn through Fx/ArtFx).

	Negation, Dispelling, Antimagic
		null_bolt       a black bolt that tears good statuses off whoever it hits
		unravel         a beam that unmakes conjured things along it: other people's lasting spells end,
		                conjured stone, ice and wood come apart, and statuses on anyone in it are dispelled
		antimagic_shell a dark film over you: magic hits you softer, and harmful spells can't hold on to you
		null_ground     a patch where no magic works but yours: foes inside can't cast, and other people's
		                lasting spells there end
	Dampening, Silence, Eclipse
		black_sun       a dark disc overhead: under it foes are blinded and chilled
		hush            a single target can't make a sound, so can't cast, for a moment
		ground_out      a patch where lightning dies: charge bolts flying into it fizzle
	Absorption, Siphoning
		sponge          you swallow the next bolts that would hit you; each refills your reservoir
		hungry_mouth    a fist-sized black hole: bolts flying past are eaten, and people are drawn toward it
	Obscurance, Nullsign
		shadow_step     you step out of sight and come back where you aim (up to a distance)
		rift_mote       a small black tear that pulls people in, then collapses on them
		black_flame     a cold black fire that burns magic, not flesh: a player's reservoir drains
		unseen          you leave no trace: veiled, and Sense and echoes can't find you

	A backfire lands on the caster as any harmful spell's does (Effects/Impact).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Types = require(Shared.Magic.Types)
local E = require(Shared.Magic.Data.VoidTuning)

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local DamageModel = require(Cast.DamageModel)
local PropertyBehaviour = require(Cast.PropertyBehaviour)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local R = require(Cast.ArtRuntime)

type Ctx = CastTypes.EffectContext
type Outcome = CastTypes.Outcome
type Hit = Targeting.Hit

local UP = Vector3.new(0, 1, 0)

local flat, aimDir, ground, foesStruck, isPlayer = R.flat, R.aimDir, R.ground, R.foesStruck, R.isPlayer

-- Every harmful status: what Antimagic Shell won't let hold on (except being down, which isn't magic).
local HARMFUL: { string } = {}
for id, def in StatusEffects.defs do
	if def.harmful then
		table.insert(HARMFUL, id)
	end
end
table.sort(HARMFUL)

local VoidArt = {}

function VoidArt.precheck(_params: { [string]: any }, _stats: Types.SpellStats, _player: Player): string?
	if FeatureFlags.get("void_arts_enabled") == false then
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
	R.cue(ctx, fields, position, heavy, "void")
end

local function serverTime(): number
	return workspace:GetServerTimeNow()
end

-- Ends other people's lasting spells that `inside(body)` says are reached. Returns how many.
local function unmakeBodies(ctx: Ctx, max: number, inside: (R.Body) -> boolean): number
	local owner = ctx.player.UserId
	local ended = 0
	for _, body in R.all() do
		if ended >= max then
			break
		end
		if body.owner ~= owner and not body.ended and inside(body) then
			cue(ctx, { fx = "unmade", at = body.position }, body.position)
			R.endBody(body)
			ended += 1
		end
	end
	return ended
end

local function distanceToSegment(p: Vector3, a: Vector3, b: Vector3): number
	local ab = b - a
	local t = math.clamp((p - a):Dot(ab) / math.max(ab:Dot(ab), 1e-6), 0, 1)
	return (p - (a + ab * t)).Magnitude
end

-- ─── Negation, Dispelling, Antimagic ────────────────────────────────────────

local function nullBolt(ctx: Ctx): Outcome
	local T = E.null_bolt
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0 }
	end
	R.hit(ctx, target, T.share)
	local stripped = StatusEffects.stripBeneficial(target.humanoid, math.floor(at(T.strips, ctx)))
	cue(ctx, { fx = "null", at = target.root.Position }, target.root.Position)
	return { effective = true, hits = 1, note = if stripped > 0 then string.format("%d of their protections come apart.", stripped) else nil }
end

local function unravel(ctx: Ctx): Outcome
	local T = E.unravel
	local dir = aimDir(ctx)
	local from = ctx.origin + UP * 1.5
	local to = from + dir * at(T.length, ctx)
	local ended = unmakeBodies(ctx, T.maxBodies, function(body)
		return distanceToSegment(body.position, from, to) <= T.width + math.min(body.radius, 6)
	end)
	-- Conjured stone, ice and wood along it come apart.
	local solids = 0
	local folder = workspace:FindFirstChild("ArtSolids")
	if folder then
		for _, p in folder:GetChildren() do
			if solids >= T.maxSolids then
				break
			end
			if p:IsA("BasePart") and distanceToSegment(p.Position, from, to) <= T.width + p.Size.Magnitude / 2 then
				cue(ctx, { fx = "unmade", at = p.Position }, p.Position)
				p:Destroy()
				solids += 1
			end
		end
	end
	local dispelled = 0
	for _, hit in Targeting.alongBeam(from, to, T.width, 8, { ctx.character }) do
		dispelled += StatusEffects.dispel(hit.humanoid)
	end
	cue(ctx, { fx = "unravel", from = from, to = to }, from)
	local total = ended + solids + dispelled
	return {
		effective = total > 0,
		hits = ended + solids,
		note = if total == 0 then "Nothing there was made by magic." else string.format("%d magical thing%s come apart.", total, if total == 1 then "" else "s"),
	}
end

local function antimagicShell(ctx: Ctx): Outcome
	local T = E.antimagic_shell
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return { effective = false, hits = 0 }
	end
	local seconds = at(T.seconds, ctx)
	StatusEffects.cleanse(humanoid, HARMFUL)
	StatusEffects.apply(humanoid, "ward", {
		duration = seconds,
		magnitude = DamageModel.base(ctx.power) * 0.5,
		source = ctx.player.UserId,
	})
	-- Every magic hit, whatever cast it (a player's spell, a Wildborn's boulder, an NPC mage's bolt), is
	-- softened at the damage step (Services/ArtService wraps Damage.interceptor).
	humanoid:SetAttribute("AntimagicUntil", serverTime() + seconds)
	humanoid:SetAttribute("AntimagicResist", at(T.resist, ctx))
	for _, body in R.bodiesOf(ctx.player.UserId, "antimagic_shell") do
		R.endBody(body)
	end
	R.spawn({
		look = "antimagic_shell",
		ctx = ctx,
		position = ctx.origin,
		radius = 3,
		seconds = seconds,
		every = T.every,
		links = { Model = ctx.character },
		tick = function(_body)
			StatusEffects.cleanse(humanoid, HARMFUL)
		end,
	})
	return { effective = true, hits = 0, note = "A dark film settles over you. Magic slides off it." }
end

local function nullGround(ctx: Ctx): Outcome
	local T = E.null_ground
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 16))
	local center = ground(ctx.point)
	local ended = unmakeBodies(ctx, 10, function(body)
		return (body.position - center).Magnitude <= radius
	end)
	local character = ctx.character
	R.spawn({
		look = "null_ground",
		ctx = ctx,
		position = center,
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		-- No magic but yours works there: bolts and boulders flying into it die.
		swallow = function(body, position: Vector3, ownerModel: Model?, _property: string?): boolean
			local rel = position - body.position
			if ownerModel == character or Vector3.new(rel.X, 0, rel.Z).Magnitude > body.radius or rel.Y < -4 or rel.Y > 30 then
				return false
			end
			R.cue(body.ctx, { fx = "fizzle", at = position }, position, false, "void")
			return true
		end,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "silence", T.silenceSeconds)
			end
		end,
	})
	return { effective = true, hits = ended, note = "Magic stops working there, except yours." }
end

-- ─── Dampening, Silence, Eclipse ────────────────────────────────────────────

local function blackSun(ctx: Ctx): Outcome
	local T = E.black_sun
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 18))
	R.spawn({
		look = "black_sun",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		attrs = { Height = T.height },
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "blind", T.blindSeconds)
				PropertyBehaviour.applyControl(body.ctx, hit, "cold")
			end
		end,
	})
	return { effective = true, hits = 0, note = "A black disc hangs over the place. It's night and winter under it." }
end

local function hush(ctx: Ctx): Outcome
	local T = E.hush
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0 }
	end
	local seconds = at(T.seconds, ctx)
	if isPlayer(target) then
		seconds = math.min(seconds, T.pvpSeconds)
	end
	R.hit(ctx, target, T.share)
	R.status(ctx, target.humanoid, "silence", seconds)
	cue(ctx, { fx = "hush", model = target.model, seconds = seconds }, target.root.Position)
	return { effective = true, hits = 1 }
end

local function groundOut(ctx: Ctx): Outcome
	local T = E.ground_out
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 18))
	local center = ground(ctx.point)
	local character = ctx.character
	R.spawn({
		look = "ground_out",
		ctx = ctx,
		position = center,
		radius = radius,
		seconds = at(T.seconds, ctx),
		swallow = function(body, position: Vector3, ownerModel: Model?, property: string?): boolean
			if property ~= "charge" or ownerModel == character or (position - body.position).Magnitude > body.radius + 4 then
				return false
			end
			R.cue(body.ctx, { fx = "fizzle", at = position }, position, false, "void")
			return true
		end,
	})
	return { effective = true, hits = 0, note = "Lightning dies here. Charged bolts that fly in fizzle out." }
end

-- ─── Absorption, Siphoning ──────────────────────────────────────────────────

local function sponge(ctx: Ctx): Outcome
	local T = E.sponge
	local character = ctx.character
	local player = ctx.player
	local reservoirs = ctx.services.reservoirs
	for _, body in R.bodiesOf(player.UserId, "sponge") do
		R.endBody(body)
	end
	R.spawn({
		look = "sponge",
		ctx = ctx,
		position = ctx.origin,
		radius = T.reach,
		seconds = at(T.seconds, ctx),
		links = { Model = character },
		data = { charges = math.floor(at(T.charges, ctx)) },
		move = function(body, _dt)
			local root = character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				R.place(body, root.Position)
			end
		end,
		swallow = function(body, position: Vector3, ownerModel: Model?, _property: string?): boolean
			if ownerModel == character or body.data.charges <= 0 or (position - body.position).Magnitude > T.reach then
				return false
			end
			body.data.charges -= 1
			local mine = reservoirs and reservoirs:get(player)
			if mine then
				mine.current = math.min(mine.max, mine.current + mine.max * T.refill)
				reservoirs:push(player)
			end
			R.cue(body.ctx, { fx = "swallow", at = position }, position, false, "void")
			if body.data.charges <= 0 then
				task.defer(R.endBody, body)
			end
			return true
		end,
	})
	return { effective = true, hits = 0, note = "Your hand opens on nothing. The next bolts that reach you are swallowed." }
end

local function hungryMouth(ctx: Ctx): Outcome
	local T = E.hungry_mouth
	local radius = at(T.radius, ctx)
	local center = ctx.point + UP * 2
	local character = ctx.character
	R.spawn({
		look = "hungry_mouth",
		ctx = ctx,
		position = center,
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		swallow = function(body, position: Vector3, ownerModel: Model?, _property: string?): boolean
			if ownerModel == character then
				return false
			end
			-- It draws in from above as well as round it: anything flying over it within its reach is eaten.
			local rel = position - body.position
			if Vector3.new(rel.X, 0, rel.Z).Magnitude > body.radius or rel.Y < -4 or rel.Y > body.radius * T.reachUp then
				return false
			end
			R.cue(body.ctx, { fx = "swallow", at = position }, position, false, "void")
			return true
		end,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.push(hit, flat(body.position - hit.root.Position) * T.pull)
			end
		end,
	})
	return { effective = true, hits = 0, note = "A small black hole hangs where you point. It eats what flies past." }
end

-- ─── Obscurance, Nullsign ───────────────────────────────────────────────────

local stepParams = RaycastParams.new()
stepParams.FilterType = Enum.RaycastFilterType.Exclude

local function shadowStep(ctx: Ctx): Outcome
	local T = E.shadow_step
	local reach = at(T.reach, ctx)
	local from = ctx.root.Position
	local want = ctx.point
	local d = Vector3.new(want.X - from.X, 0, want.Z - from.Z)
	if d.Magnitude > reach then
		d = d.Unit * reach
	end
	if d.Magnitude < 3 then
		return { effective = false, hits = 0, note = "Nowhere to step to." }
	end
	-- Not through walls: stop short of anything solid on the way.
	stepParams.FilterDescendantsInstances = { ctx.character }
	local hit = workspace:Raycast(from, d, stepParams)
	if hit then
		d = d.Unit * math.max(0, hit.Distance - 2.5)
		if d.Magnitude < 3 then
			return { effective = false, hits = 0, note = "Something stands in the way." }
		end
	end
	local landing = ground(from + d) + UP * 3
	cue(ctx, { fx = "step", from = from, to = landing }, from)
	ctx.character:PivotTo(CFrame.lookAt(landing, landing + flat(d)))
	return { effective = true, hits = 0 }
end

local function riftMote(ctx: Ctx): Outcome
	local T = E.rift_mote
	local radius = at(T.radius, ctx)
	R.spawn({
		look = "rift_mote",
		ctx = ctx,
		position = ctx.point + UP * 1.5,
		radius = radius,
		seconds = T.seconds,
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.push(hit, flat(body.position - hit.root.Position) * T.pull)
			end
		end,
		finish = function(body)
			if not R.alive(body.ctx) then
				return
			end
			for _, hit in R.foesAround(body.ctx, body.position, body.radius * 0.6) do
				R.hit(body.ctx, hit, T.share)
			end
			R.cue(body.ctx, { fx = "collapse", at = body.position, radius = body.radius * 0.6 }, body.position, true, "void")
		end,
	})
	return { effective = true, hits = 0 }
end

local function blackFlame(ctx: Ctx): Outcome
	local T = E.black_flame
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0 }
	end
	local victim = Players:GetPlayerFromCharacter(target.model)
	local reservoirs = ctx.services.reservoirs
	local theirs = victim and reservoirs and reservoirs:get(victim)
	local burned = 0
	if victim and theirs then
		burned = math.min(at(T.burn, ctx), math.max(0, theirs.current))
		theirs.current -= burned
		reservoirs:push(victim)
		R.hit(ctx, target, T.share)
	else
		R.hit(ctx, target, T.share + T.nonPlayerShare)
	end
	cue(ctx, { fx = "black_flame", model = target.model }, target.root.Position)
	return { effective = true, hits = 1, note = if burned > 0 then string.format("Their magic burns away (%d).", math.floor(burned)) else nil }
end

local function unseen(ctx: Ctx): Outcome
	local T = E.unseen
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return { effective = false, hits = 0 }
	end
	local seconds = at(T.seconds, ctx)
	R.status(ctx, humanoid, "veiled", seconds)
	ctx.character:SetAttribute("Unseen", serverTime() + seconds)
	cue(ctx, { fx = "unseen", at = ctx.origin }, ctx.origin)
	return { effective = true, hits = 0, note = "You leave no trace. Echoes and searching eyes pass over you." }
end

-- ─── Dispatch ───────────────────────────────────────────────────────────────

local MOVES: { [string]: (Ctx) -> Outcome } = {
	null_bolt = nullBolt,
	unravel = unravel,
	antimagic_shell = antimagicShell,
	null_ground = nullGround,
	black_sun = blackSun,
	hush = hush,
	ground_out = groundOut,
	sponge = sponge,
	hungry_mouth = hungryMouth,
	shadow_step = shadowStep,
	rift_mote = riftMote,
	black_flame = blackFlame,
	unseen = unseen,
}
VoidArt.moves = MOVES

function VoidArt.resolve(ctx: Ctx, params: { [string]: any }): Outcome
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

return VoidArt
