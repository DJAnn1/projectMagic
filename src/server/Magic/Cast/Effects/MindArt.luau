--!strict
--[[
	MindArt: Mind's own spells (docs/DomainIdeas.md, "Mind"): what people see, feel, remember and do.
	Ordinary moves that fit their branch, each reached by a narrow route in Data/EffectLibrary
	("mind_" .. move, with params.move). Numbers: Data/MindTuning. Anything that lasts runs in
	Cast/ArtRuntime; looks in Client/Fx/MindFx (cue kind "mind", bodies drawn through Fx/ArtFx).

	Perceptics, Farsight, Insight
		far_eye        an eye of light flies where you aim; you look out of it for a few seconds
		weak_spot      you see where they're weak: hits on them crit more and land harder for a while
	Empathy, Charm, Dread
		rally          you and allies near you take heart: faster, healed a little, fear and daze shaken off
		despair        a weight over an area: everyone in it slows and their spells go wrong more
		pacify         a calm over an area: foes in it stop fighting while they stand there
	Illusion, Phantasms, Grand Illusion, Veiling
		mirror_images  copies of you circle you; each takes a blow and vanishes
		phantom_blade  an imaginary blade that hurts because they believe it, and dazes
		false_wall     a wall that isn't there: bolts and people pass, but nobody sees through it
		phantom_beast  a monster only its victim sees, hounding them: they stay afraid
		vanish         you go unnoticed for a while
		mirage_pit     the ground looks like a drop: foes won't stay on it
	Mnemonics, Oblivion
		forget_me      your target forgets you: a Wildborn or creature stops chasing you, an NPC its grudge
	Telepathy, Dominion
		mind_spike     a thin violet bolt into the mind: hurts and dazes
		psychic_push   an invisible shove: everyone in front of you is thrown back
		whispers       voices in an area: foes in it are dazed and slowed
		puppet         you walk someone where you aim

	Forget Me works through ArtRuntime.forget (the services register how their minds forget); False Wall
	through ArtRuntime.screened (Cast/Concealment: Wildborn, creatures and NPC fighters can't see past it).
	A backfire lands on the caster as any harmful spell's does (Effects/Impact).
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Types = require(Shared.Magic.Types)
local E = require(Shared.Magic.Data.MindTuning)

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local R = require(Cast.ArtRuntime)

type Ctx = CastTypes.EffectContext
type Outcome = CastTypes.Outcome
type Hit = Targeting.Hit

local UP = Vector3.new(0, 1, 0)

local flat, aimDir, ground, foesStruck, isPlayer, cone = R.flat, R.aimDir, R.ground, R.foesStruck, R.isPlayer, R.cone

local MindArt = {}

function MindArt.precheck(_params: { [string]: any }, _stats: Types.SpellStats, _player: Player): string?
	if FeatureFlags.get("mind_arts_enabled") == false then
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
	R.cue(ctx, fields, position, heavy, "mind")
end

local function isFriend(ctx: Ctx, model: Model): boolean
	return model == ctx.character or (Targeting.canHelp(ctx.player, model) and not Targeting.canHarm(ctx.player, model))
end

-- ─── Perceptics ─────────────────────────────────────────────────────────────

local function farEye(ctx: Ctx): Outcome
	local T = E.far_eye
	local dir = aimDir(ctx)
	-- The eye opens where the bolt came down, looking on the way it was going (the caster's client).
	cue(ctx, { fx = "far_eye", at = ctx.point + UP * 4, dir = dir, seconds = at(T.seconds, ctx) }, ctx.point)
	return { effective = true, hits = 0, note = "You see out of the eye. Move to look back through your own." }
end

local function weakSpot(ctx: Ctx): Outcome
	local T = E.weak_spot
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0 }
	end
	local seconds = at(T.seconds, ctx)
	R.status(ctx, target.humanoid, "jinxed", seconds)
	R.status(ctx, target.humanoid, "crumbling", seconds)
	cue(ctx, { fx = "weak_spot", model = target.model, seconds = seconds }, target.root.Position)
	return { effective = true, hits = 1, note = "You see where they're weak. Hits on them land harder." }
end

-- ─── Empathy ────────────────────────────────────────────────────────────────

local function rally(ctx: Ctx): Outcome
	local T = E.rally
	local count = 0
	for _, hit in Targeting.inRadius(ctx.origin, T.radius, 12) do
		if isFriend(ctx, hit.model) then
			StatusEffects.cleanse(hit.humanoid, { "fear", "dazed", "charm", "calm" })
			R.status(ctx, hit.humanoid, "haste", at(T.hasteSeconds, ctx))
			Damage.heal(hit.humanoid, DamageModel.base(ctx.power) * T.heal, ctx.player.UserId, { domain = "mind" })
			count += 1
		end
	end
	cue(ctx, { fx = "rally", at = ctx.origin, radius = T.radius }, ctx.origin)
	return { effective = count > 0, hits = count }
end

local function despair(ctx: Ctx): Outcome
	local T = E.despair
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 16))
	R.spawn({
		look = "despair",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "slow", T.every + 0.4)
				R.status(body.ctx, hit.humanoid, "dazed", T.every + 0.4)
			end
		end,
	})
	return { effective = true, hits = 0 }
end

local function pacify(ctx: Ctx): Outcome
	local T = E.pacify
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 15))
	R.spawn({
		look = "pacify",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "calm", T.calmSeconds)
			end
		end,
	})
	return { effective = true, hits = 0, note = "A calm settles there. Anyone standing in it loses the will to fight." }
end

-- ─── Illusion ───────────────────────────────────────────────────────────────

local function mirrorImages(ctx: Ctx): Outcome
	local T = E.mirror_images
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return { effective = false, hits = 0 }
	end
	local seconds = at(T.seconds, ctx)
	local shield = DamageModel.base(ctx.power) * T.shield * T.images
	StatusEffects.apply(humanoid, "ward", { duration = seconds, magnitude = shield, source = ctx.player.UserId })
	for _, body in R.bodiesOf(ctx.player.UserId, "mirror_images") do
		R.endBody(body)
	end
	R.spawn({
		look = "mirror_images",
		ctx = ctx,
		position = ctx.origin,
		radius = 3,
		seconds = seconds,
		every = 0.25,
		attrs = { Images = T.images, Left = T.images },
		links = { Model = ctx.character },
		data = { full = shield },
		tick = function(body)
			if not StatusEffects.has(humanoid, "ward") then
				R.endBody(body)
				return
			end
			local left = 0
			for _, st in StatusEffects.snapshot(humanoid) do
				if st.id == "ward" then
					left = st.magnitude
				end
			end
			body.part:SetAttribute("Left", math.ceil(T.images * math.clamp(left / body.data.full, 0, 1)))
		end,
	})
	return { effective = true, hits = 0, note = "Copies of you circle you. Each one takes a blow for you." }
end

local function phantomBlade(ctx: Ctx): Outcome
	local T = E.phantom_blade
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0 }
	end
	R.hit(ctx, target, T.share)
	R.status(ctx, target.humanoid, "dazed", T.dazeSeconds)
	cue(ctx, { fx = "phantom_blade", at = target.root.Position }, target.root.Position)
	return { effective = true, hits = 1 }
end

local function falseWall(ctx: Ctx): Outcome
	local T = E.false_wall
	local width = at(T.width, ctx)
	local base = ground(ctx.point)
	local normal = flat(ctx.origin - base)
	local right = normal:Cross(UP).Unit
	local center = base + UP * (T.height / 2)
	R.spawn({
		look = "false_wall",
		ctx = ctx,
		position = center,
		radius = width / 2,
		seconds = at(T.seconds, ctx),
		cframe = CFrame.fromMatrix(center, right, UP),
		size = Vector3.new(width, T.height, 1),
		data = { screen = { center = center, normal = normal, right = right, width = width, height = T.height } },
	})
	return { effective = true, hits = 0, note = "A wall that isn't there. You can walk through it; nobody can see through it." }
end

local function phantomBeast(ctx: Ctx): Outcome
	local T = E.phantom_beast
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0 }
	end
	local model, humanoid = target.model, target.humanoid
	R.spawn({
		look = "phantom_beast",
		ctx = ctx,
		position = target.root.Position,
		radius = 2,
		seconds = at(T.seconds, ctx),
		every = T.every,
		links = { Model = model },
		move = function(body, _dt)
			local root = model:FindFirstChild("HumanoidRootPart")
			if not model.Parent or not root or not root:IsA("BasePart") or humanoid.Health <= 0 then
				R.endBody(body)
				return
			end
			R.place(body, root.Position)
		end,
		tick = function(body)
			R.status(body.ctx, humanoid, "fear", T.fearSeconds)
		end,
	})
	return { effective = true, hits = 1, note = "Something only they can see is after them." }
end

local function vanish(ctx: Ctx): Outcome
	local T = E.vanish
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return { effective = false, hits = 0 }
	end
	local seconds = at(T.seconds, ctx)
	R.status(ctx, humanoid, "veiled", seconds)
	cue(ctx, { fx = "vanish", at = ctx.origin }, ctx.origin)
	return { effective = true, hits = 0, note = "Minds slide off you. Nobody further than arm's length notices you." }
end

local function miragePit(ctx: Ctx): Outcome
	local T = E.mirage_pit
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 12))
	R.spawn({
		look = "mirage_pit",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				-- They see a drop: they step back off it, afraid.
				R.status(body.ctx, hit.humanoid, "fear", 1)
				R.push(hit, flat(hit.root.Position - body.position) * T.push)
			end
		end,
	})
	return { effective = true, hits = 0, note = "The ground there looks like a drop. Nobody who sees it will stand on it." }
end

-- ─── Mnemonics ──────────────────────────────────────────────────────────────

local function forgetMe(ctx: Ctx): Outcome
	local T = E.forget_me
	local target: Hit? = nil
	for _, hit in Targeting.select(ctx, 1) do
		if hit.model ~= ctx.character then
			target = hit
			break
		end
	end
	if not target then
		return { effective = false, hits = 0 }
	end
	if isPlayer(target) then
		return { effective = false, hits = 0, note = "Another player's memory isn't yours to take." }
	end
	local seconds = at(T.seconds, ctx)
	local forgot = R.forget(target.model, ctx.player.UserId, seconds)
	cue(ctx, { fx = "forget", at = target.root.Position + UP * 3 }, target.root.Position)
	return {
		effective = forgot,
		hits = if forgot then 1 else 0,
		note = if forgot then "Their eyes go blank for a moment. They don't know you any more." else "There's nothing there to forget you.",
	}
end

-- ─── Telepathy ──────────────────────────────────────────────────────────────

local function mindSpike(ctx: Ctx): Outcome
	local T = E.mind_spike
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0 }
	end
	R.hit(ctx, target, T.share)
	R.status(ctx, target.humanoid, "dazed", T.dazeSeconds)
	return { effective = true, hits = 1 }
end

local function psychicPush(ctx: Ctx): Outcome
	local T = E.psychic_push
	local reach = at(T.reach, ctx)
	local dir = aimDir(ctx)
	local hits = 0
	for _, hit in cone(ctx, reach, T.arc, 10) do
		R.hit(ctx, hit, T.share)
		R.push(hit, dir * at(T.push, ctx) + UP * 14)
		hits += 1
	end
	cue(ctx, { fx = "push", from = ctx.origin, dir = dir, reach = reach }, ctx.origin)
	return { effective = hits > 0, hits = hits }
end

local function whispers(ctx: Ctx): Outcome
	local T = E.whispers
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 16))
	R.spawn({
		look = "whispers",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "dazed", T.every + 0.4)
				R.status(body.ctx, hit.humanoid, "slow", T.every + 0.4)
			end
		end,
	})
	return { effective = true, hits = 0 }
end

local function puppet(ctx: Ctx): Outcome
	local T = E.puppet
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0, note = "Nobody there to walk." }
	end
	local player = isPlayer(target)
	local seconds = if player then math.min(at(T.seconds, ctx), T.pvpSeconds) else at(T.seconds, ctx)
	local reach = if player then T.pvpReach else at(T.reach, ctx)
	-- Walked toward where you aimed past them (or toward you if you aimed at them), up to `reach`.
	local from = target.root.Position
	local want = ctx.point - from
	want = Vector3.new(want.X, 0, want.Z)
	if want.Magnitude < 3 then
		want = flat(ctx.origin - from) * reach
	elseif want.Magnitude > reach then
		want = want.Unit * reach
	end
	R.status(ctx, target.humanoid, "charm", seconds)
	R.drag(target, from + want, seconds)
	cue(ctx, { fx = "puppet", model = target.model, seconds = seconds, from = ctx.root.Position }, from)
	return { effective = true, hits = 1, note = "Their feet are yours for a moment." }
end

-- ─── Dispatch ───────────────────────────────────────────────────────────────

local MOVES: { [string]: (Ctx) -> Outcome } = {
	far_eye = farEye,
	weak_spot = weakSpot,
	rally = rally,
	despair = despair,
	pacify = pacify,
	mirror_images = mirrorImages,
	phantom_blade = phantomBlade,
	false_wall = falseWall,
	phantom_beast = phantomBeast,
	vanish = vanish,
	mirage_pit = miragePit,
	forget_me = forgetMe,
	mind_spike = mindSpike,
	psychic_push = psychicPush,
	whispers = whispers,
	puppet = puppet,
}
MindArt.moves = MOVES

function MindArt.resolve(ctx: Ctx, params: { [string]: any }): Outcome
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

return MindArt
