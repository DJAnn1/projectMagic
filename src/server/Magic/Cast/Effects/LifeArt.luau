--!strict
--[[
	LifeArt: Life's own spells (docs/DomainIdeas.md, "Life"). Ordinary moves that fit their branch, each
	reached by a narrow route in Data/EffectLibrary ("life_" .. move, with params.move). Numbers:
	Data/LifeTuning. Anything that lasts runs in Cast/ArtRuntime; looks in Client/Fx/LifeFx (cue kind
	"life", bodies drawn through Fx/ArtFx).

	Restoration, Mending, Resurgence
		healing_grove  flowers spring up; allies standing among them heal every second
		lifeline       a ribbon of your own health given to an ally (they get more than you give)
		petal_ward     petals circle you and allies near you: a ward that soaks up hits
		second_wind    you and allies near you shake off slows and daze, heal a little and run faster
		raise_them     a downed player is brought round where they lie (else an ordinary heal)
	Flora, Arborism, Mycology
		vine_lash      a thorny vine lashes out and drags your target to you
		root_snare     roots burst up and hold your target; the thorns keep biting
		thorn_burst    thorns shoot out in every direction; the wounds bleed
		bramble_wall   a thicket: anyone pushing through is scratched and slowed
		sapling        a tree grows in a second where you point: real cover, for a while
		spore_cloud    puffballs burst into a haze that dazes foes in it
		fairy_ring     a ring of mushrooms: anyone who steps in is bounced high
	Fauna, Wildshape
		swarm          a cloud of wasps flies at your target and keeps stinging
		flock          birds burst out of you and blind everyone near
		beast_claws    your hands are claws for a while: every blow you land tears more
	Blight, Pestilence, Withering
		rot            wood and flesh rot where you touch: a long rot, and buildings there weaken
		withering_field colour drains from an area: foes in it wither
		plague_flies   flies that poison their target, then move on to the next person near
		corpse_bloom   a fat flower that bursts into poison when a foe comes near

	A backfire lands on the caster as any harmful spell's does (Effects/Impact).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Types = require(Shared.Magic.Types)
local E = require(Shared.Magic.Data.LifeTuning)

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local Resistances = require(Cast.Resistances)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local R = require(Cast.ArtRuntime)

type Ctx = CastTypes.EffectContext
type Outcome = CastTypes.Outcome
type Hit = Targeting.Hit

local UP = Vector3.new(0, 1, 0)

local flat, aimDir, ground, foesStruck, isPlayer = R.flat, R.aimDir, R.ground, R.foesStruck, R.isPlayer

local LifeArt = {}

function LifeArt.precheck(_params: { [string]: any }, _stats: Types.SpellStats, _player: Player): string?
	if FeatureFlags.get("life_arts_enabled") == false then
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
	R.cue(ctx, fields, position, heavy, "life")
end

local function isFriend(ctx: Ctx, model: Model): boolean
	return model == ctx.character or (Targeting.canHelp(ctx.player, model) and not Targeting.canHarm(ctx.player, model))
end

local function friendsAround(ctx: Ctx, center: Vector3, radius: number): { Hit }
	local out: { Hit } = {}
	for _, hit in Targeting.inRadius(center, radius, 12) do
		if isFriend(ctx, hit.model) then
			table.insert(out, hit)
		end
	end
	return out
end

local function heal(ctx: Ctx, humanoid: Humanoid, share: number)
	Damage.heal(humanoid, DamageModel.base(ctx.power) * share, if ctx.player then ctx.player.UserId else nil, { domain = "life" })
end

local function fallback(ctx: Ctx, name: string, params: { [string]: any }): Outcome
	local module = script.Parent:FindFirstChild(name)
	if not module or not module:IsA("ModuleScript") then
		return { effective = false, hits = 0 }
	end
	return (require(module) :: any).resolve(ctx, params)
end

-- A hit that adds to a blow without a body of its own (no attacker: it mustn't feed itself).
local function extraHit(c: Ctx, victim: Humanoid, share: number, from: Vector3)
	local model = victim.Parent
	if victim.Health <= 0 or not model or not model:IsA("Model") or not Targeting.canHarm(c.player, model) then
		return
	end
	local hit = Targeting.characterOf(model)
	if not hit then
		return
	end
	local result = DamageModel.compute(c, hit, share, { noFalloff = true })
	Damage.apply(victim, result.amount, c.player.UserId, "life", {
		domain = "life",
		crit = result.crit,
		power = c.stats.recipe.power,
		from = from,
		property = c.stats.recipe.property,
		form = "touch",
		branch = c.stats.recipe.branch,
	})
end

-- ─── Restoration, Mending, Resurgence ───────────────────────────────────────

local function healingGrove(ctx: Ctx): Outcome
	local T = E.healing_grove
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 14))
	R.spawn({
		look = "healing_grove",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in friendsAround(body.ctx, body.position, body.radius) do
				heal(body.ctx, hit.humanoid, T.heal)
			end
		end,
	})
	return { effective = true, hits = 0, note = "Flowers spring up. Your friends heal standing among them." }
end

local function lifeline(ctx: Ctx): Outcome
	local T = E.lifeline
	local mine = ctx.character:FindFirstChildOfClass("Humanoid")
	local friend: Hit? = nil
	for _, hit in Targeting.select(ctx, 2) do
		if hit.model ~= ctx.character and isFriend(ctx, hit.model) then
			friend = hit
			break
		end
	end
	if not mine or not friend then
		return { effective = false, hits = 0, note = "There's nobody on your side there to give your life to." }
	end
	local give = math.min(DamageModel.base(ctx.power) * T.give, mine.Health - mine.MaxHealth * T.floor)
	if give <= 1 then
		return { effective = false, hits = 0, note = "You haven't enough life left to give." }
	end
	Damage.internal(mine, give)
	Damage.heal(friend.humanoid, give * T.mult, ctx.player.UserId, { domain = "life" })
	cue(ctx, { fx = "lifeline", from = ctx.root.Position, to = friend.root.Position }, friend.root.Position)
	return { effective = true, hits = 1 }
end

local function petalWard(ctx: Ctx): Outcome
	local T = E.petal_ward
	local seconds = at(T.seconds, ctx)
	local count = 0
	for _, hit in friendsAround(ctx, ctx.origin, T.radius) do
		StatusEffects.apply(hit.humanoid, "ward", {
			duration = seconds,
			magnitude = DamageModel.base(ctx.power) * T.shield,
			source = ctx.player.UserId,
			resist = Resistances.wardFor(ctx.stats.recipe.power),
		})
		count += 1
		R.spawn({
			look = "petal_ward",
			ctx = ctx,
			position = hit.root.Position,
			radius = 2,
			seconds = seconds,
			every = 0.3,
			links = { Model = hit.model },
			data = { wielder = hit.model },
			tick = function(body)
				if not StatusEffects.has(hit.humanoid, "ward") then
					R.endBody(body)
				end
			end,
		})
		if count >= 4 then
			break -- a ward each for you and up to three near you (the cap on lasting things is per caster)
		end
	end
	return { effective = count > 0, hits = count }
end

local function secondWind(ctx: Ctx): Outcome
	local T = E.second_wind
	local count = 0
	for _, hit in friendsAround(ctx, ctx.origin, T.radius) do
		StatusEffects.cleanse(hit.humanoid, { "slow", "dazed", "chilled", "sapped", "aged" })
		heal(ctx, hit.humanoid, T.heal)
		R.status(ctx, hit.humanoid, "haste", T.hasteSeconds)
		count += 1
	end
	cue(ctx, { fx = "second_wind", at = ctx.origin, radius = T.radius }, ctx.origin)
	return { effective = count > 0, hits = count }
end

local function raiseThem(ctx: Ctx): Outcome
	local revive = R.revive
	for _, hit in Targeting.select(ctx, 2) do
		local player = Players:GetPlayerFromCharacter(hit.model)
		if player and player ~= ctx.player and hit.humanoid:GetAttribute("Downed") and revive and revive(player, ctx.player) then
			cue(ctx, { fx = "raise", at = hit.root.Position }, hit.root.Position, true)
			return { effective = true, hits = 1, note = "They come round, alive, where they fell." }
		end
	end
	-- Nobody down: an ordinary heal.
	return fallback(ctx, "Restore", {})
end

-- ─── Flora, Arborism, Mycology ──────────────────────────────────────────────

local function vineLash(ctx: Ctx): Outcome
	local T = E.vine_lash
	local target = foesStruck(ctx, 1)[1]
	if not target then
		cue(ctx, { fx = "vine", from = ctx.root.Position, to = ctx.point }, ctx.point)
		return { effective = false, hits = 0, note = "The vine whips out and catches nothing." }
	end
	R.hit(ctx, target, T.share)
	cue(ctx, { fx = "vine", from = ctx.root.Position, to = target.root.Position }, target.root.Position)
	-- Dragged right up to you (a few studs in front, not on top of you).
	R.drag(target, ctx.origin + flat(target.root.Position - ctx.origin) * T.stopShort, T.dragSeconds)
	return { effective = true, hits = 1 }
end

local function rootSnare(ctx: Ctx): Outcome
	local T = E.root_snare
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0, note = "Roots break the ground, and hold nothing." }
	end
	local seconds = at(T.seconds, ctx)
	if isPlayer(target) then
		seconds = math.min(seconds, T.pvpSeconds)
	end
	R.hit(ctx, target, T.share)
	R.status(ctx, target.humanoid, "root", seconds)
	R.status(ctx, target.humanoid, "poison", seconds, DamageModel.base(ctx.power) * T.thornShare)
	cue(ctx, { fx = "roots", model = target.model, seconds = seconds }, target.root.Position)
	return { effective = true, hits = 1 }
end

local function thornBurst(ctx: Ctx): Outcome
	local T = E.thorn_burst
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 15))
	local hits = 0
	for _, hit in R.foesAround(ctx, ctx.point, radius) do
		if R.hit(ctx, hit, T.share, nil, {}) > 0 then
			R.status(ctx, hit.humanoid, "poison", T.bleedSeconds, DamageModel.base(ctx.power) * T.bleedShare)
			hits += 1
		end
	end
	cue(ctx, { fx = "thorns", at = ctx.point, radius = radius }, ctx.point, true)
	return { effective = true, hits = hits }
end

local function brambleWall(ctx: Ctx): Outcome
	local T = E.bramble_wall
	local length = at(T.length, ctx)
	local dir = aimDir(ctx)
	local right = dir:Cross(UP).Unit
	local center = ground(ctx.point)
	local a, b = center - right * (length / 2), center + right * (length / 2)
	R.spawn({
		look = "bramble_wall",
		ctx = ctx,
		position = center,
		radius = length / 2,
		seconds = at(T.seconds, ctx),
		every = 0.25,
		cframe = CFrame.fromMatrix(center + UP * 1.5, right, UP),
		size = Vector3.new(length, 3, 2),
		data = { gap = {} },
		tick = function(body)
			local now = os.clock()
			for _, hit in R.foesAround(body.ctx, center, length / 2 + T.reach) do
				local p = hit.root.Position
				local ab = b - a
				local t = math.clamp((p - a):Dot(ab) / ab:Dot(ab), 0, 1)
				local closest = a + ab * t
				if Vector3.new(p.X - closest.X, 0, p.Z - closest.Z).Magnitude <= T.reach and (body.data.gap[hit.model] or 0) <= now then
					body.data.gap[hit.model] = now + T.gap
					R.hit(body.ctx, hit, T.share)
					R.status(body.ctx, hit.humanoid, "slow", T.slowSeconds)
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "A thicket of brambles grows where you point." }
end

local function sapling(ctx: Ctx): Outcome
	local T = E.sapling
	local spot = ground(ctx.point)
	local height = at(T.height, ctx)
	local seconds = at(T.seconds, ctx)
	local trunk = R.solid({
		Size = Vector3.new(1.8, height, 1.8),
		CFrame = CFrame.new(spot + UP * (height / 2 - 0.3)),
		Material = Enum.Material.Wood,
		Color = E.looks.wood,
	}, seconds)
	if not trunk then
		return { effective = false, hits = 0, note = "Nothing will grow here." }
	end
	R.solid({
		Shape = Enum.PartType.Ball,
		Size = Vector3.one * (height * 0.8),
		CFrame = CFrame.new(spot + UP * (height + height * 0.15)),
		Material = Enum.Material.LeafyGrass,
		Color = E.looks.leaf,
		CanCollide = false,
	}, seconds)
	cue(ctx, { fx = "grow", at = spot, height = height }, spot, true)
	return { effective = true, hits = 0, note = "A tree shoots up where you point." }
end

local function sporeCloud(ctx: Ctx): Outcome
	local T = E.spore_cloud
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 15))
	R.spawn({
		look = "spore_cloud",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "dazed", T.dazeSeconds)
			end
		end,
	})
	return { effective = true, hits = 0 }
end

local function fairyRing(ctx: Ctx): Outcome
	local T = E.fairy_ring
	local bounce = at(T.bounce, ctx)
	R.spawn({
		look = "fairy_ring",
		ctx = ctx,
		position = ground(ctx.point),
		radius = T.radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		data = { gap = {} },
		tick = function(body)
			local now = os.clock()
			for _, hit in Targeting.inRadius(body.position, T.radius, 12) do
				local rel = hit.root.Position - body.position
				if rel.Y < 5 and (body.data.gap[hit.model] or 0) <= now then
					body.data.gap[hit.model] = now + T.gap
					R.push(hit, UP * bounce)
					R.cue(body.ctx, { fx = "bounce", at = hit.root.Position - UP * 2.5 }, hit.root.Position, false, "life")
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "A ring of mushrooms. Step in and it throws you high." }
end

-- ─── Fauna, Wildshape ───────────────────────────────────────────────────────

local function swarm(ctx: Ctx): Outcome
	local T = E.swarm
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0, note = "The swarm scatters, finding nobody." }
	end
	R.hit(ctx, target, T.share)
	local model, humanoid = target.model, target.humanoid
	R.spawn({
		look = "swarm",
		ctx = ctx,
		position = target.root.Position,
		radius = 3,
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
			extraHit(body.ctx, humanoid, T.stingShare, body.position)
		end,
	})
	return { effective = true, hits = 1 }
end

local function flock(ctx: Ctx): Outcome
	local T = E.flock
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 20))
	local hits = 0
	for _, hit in R.foesAround(ctx, ctx.origin, radius) do
		R.status(ctx, hit.humanoid, "blind", T.blindSeconds)
		hits += 1
	end
	cue(ctx, { fx = "flock", at = ctx.origin + UP * 2, radius = radius }, ctx.origin, true)
	return { effective = hits > 0, hits = hits, note = if hits == 0 then "Birds burst out of you, and wheel away." else nil }
end

local function beastClaws(ctx: Ctx): Outcome
	local T = E.beast_claws
	for _, body in R.bodiesOf(ctx.player.UserId, "beast_claws") do
		R.endBody(body)
	end
	R.spawn({
		look = "beast_claws",
		ctx = ctx,
		position = ctx.origin,
		radius = 2,
		seconds = at(T.seconds, ctx),
		links = { Model = ctx.character },
		data = { gap = {} },
		ownerHit = function(body, victim: Humanoid)
			local now = os.clock()
			if (body.data.gap[victim] or 0) > now then
				return
			end
			body.data.gap[victim] = now + T.gap
			extraHit(body.ctx, victim, T.share, body.position)
			local root = victim.RootPart
			if root then
				R.cue(body.ctx, { fx = "claw", at = root.Position }, root.Position, false, "life")
			end
		end,
	})
	return { effective = true, hits = 0, note = "Your hands are claws. Every blow tears more." }
end

-- ─── Blight, Pestilence, Withering ──────────────────────────────────────────

local function rot(ctx: Ctx): Outcome
	local T = E.rot
	local hits = 0
	for _, hit in foesStruck(ctx, 1) do
		R.hit(ctx, hit, T.share)
		R.status(ctx, hit.humanoid, "rot", T.seconds, DamageModel.base(ctx.power) * 0.06)
		R.status(ctx, hit.humanoid, "crumbling", T.seconds)
		hits += 1
	end
	local damaged = 0
	if ctx.world and ctx.world.damageStructures then
		damaged = ctx.world:damageStructures(ctx.point, T.radius, ctx.power * T.structure, "rot") or 0
	end
	cue(ctx, { fx = "rot", at = ctx.point, radius = T.radius }, ctx.point)
	return { effective = hits > 0 or (typeof(damaged) == "number" and damaged > 0), hits = hits }
end

local function witheringField(ctx: Ctx): Outcome
	local T = E.withering_field
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 16))
	R.spawn({
		look = "withering_field",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "withering", T.witherSeconds, DamageModel.base(body.ctx.power) * 0.05)
				R.status(body.ctx, hit.humanoid, "aged", T.witherSeconds, -0.15)
			end
		end,
	})
	return { effective = true, hits = 0, note = "Colour drains out of the ground. Anything alive in it weakens." }
end

local function plagueFlies(ctx: Ctx): Outcome
	local T = E.plague_flies
	local first = foesStruck(ctx, 1)[1]
	if not first then
		return { effective = false, hits = 0, note = "The flies scatter, finding nobody." }
	end
	local function infect(c: Ctx, hit: Hit)
		R.status(c, hit.humanoid, "poison", T.poisonSeconds, DamageModel.base(c.power) * T.poisonShare)
		R.cue(c, { fx = "flies", model = hit.model, seconds = T.jumpEvery }, hit.root.Position, false, "life")
	end
	R.hit(ctx, first, T.share)
	infect(ctx, first)
	local c = R.later(ctx)
	task.spawn(function()
		local current = first
		local had: { [Model]: boolean } = { [first.model] = true, [c.character] = true }
		for _ = 1, T.jumps do
			task.wait(T.jumpEvery)
			if not R.alive(c) or not current.root.Parent then
				return
			end
			local nextHit: Hit? = nil
			for _, hit in Targeting.inRadius(current.root.Position, T.jumpReach, 6, had) do
				if Targeting.canHarm(c.player, hit.model) then
					nextHit = hit
					break
				end
			end
			if not nextHit then
				return
			end
			had[nextHit.model] = true
			infect(c, nextHit)
			current = nextHit
		end
	end)
	return { effective = true, hits = 1 }
end

local function corpseBloom(ctx: Ctx): Outcome
	local T = E.corpse_bloom
	R.spawn({
		look = "corpse_bloom",
		ctx = ctx,
		position = ground(ctx.point),
		radius = T.trigger,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			if #R.foesAround(body.ctx, body.position, T.trigger) == 0 then
				return
			end
			for _, hit in R.foesAround(body.ctx, body.position, T.radius) do
				R.hit(body.ctx, hit, T.share)
				R.status(body.ctx, hit.humanoid, "poison", T.poisonSeconds, DamageModel.base(body.ctx.power) * T.poisonShare)
			end
			R.cue(body.ctx, { fx = "bloom_burst", at = body.position, radius = T.radius }, body.position, true, "life")
			R.endBody(body)
		end,
	})
	return { effective = true, hits = 0, note = "A fat flower grows where you point. It's waiting for someone." }
end

-- ─── Dispatch ───────────────────────────────────────────────────────────────

local MOVES: { [string]: (Ctx) -> Outcome } = {
	healing_grove = healingGrove,
	lifeline = lifeline,
	petal_ward = petalWard,
	second_wind = secondWind,
	raise_them = raiseThem,
	vine_lash = vineLash,
	root_snare = rootSnare,
	thorn_burst = thornBurst,
	bramble_wall = brambleWall,
	sapling = sapling,
	spore_cloud = sporeCloud,
	fairy_ring = fairyRing,
	swarm = swarm,
	flock = flock,
	beast_claws = beastClaws,
	rot = rot,
	withering_field = witheringField,
	plague_flies = plagueFlies,
	corpse_bloom = corpseBloom,
}
LifeArt.moves = MOVES

function LifeArt.resolve(ctx: Ctx, params: { [string]: any }): Outcome
	if ctx.backfire then
		return fallback(ctx, "Impact", {})
	end
	local move = MOVES[params.move]
	if not move then
		return { effective = false, hits = 0 }
	end
	return move(ctx)
end

return LifeArt
