--!strict
--[[
	SpiritArt: Spirit's own spells (docs/DomainIdeas.md, "Spirit"): wards, curses, bonds and the dead.
	Ordinary moves that fit their branch, each reached by a narrow route in Data/EffectLibrary
	("spirit_" .. move, with params.move). Numbers: Data/SpiritTuning. Anything that lasts runs in
	Cast/ArtRuntime; looks in Client/Fx/SpiritFx (cue kind "spirit", bodies drawn through Fx/ArtFx).

	Warding, Sanctums, Hallowing, Counterwarding
		glyph_shield    a standing ring of runes: other people's bolts stop at it; people walk through
		sigil_trap      a sigil on the ground: the first foe to step on it is thrown back and dazed
		hallowed_ground allies standing in it heal and shed curses; cursed foes in it burn
		mirror_ward     the next bolts coming at you go back the way they came, at whoever cast them
	Hexcraft, Greater Curses
		doom_mark       a mark that counts every blow anyone lands on them; when it ends, it all lands at once
		ill_luck        bad luck follows you: foes near you are jinxed and dazed
		thorn_curse     every blow they land hurts them too
	Binding, Pactcraft, Soulbinding
		spirit_chains   chains of light rise, drag your target toward you and hold them
		soul_tether     two foes bound together: they can't get more than a few strides apart
		shared_fate     you and an ally share every hit either of you takes
	Necrourgy, Deathspeech, Revenancy
		grave_hand      a bony hand bursts from the ground and grabs
		spirit_wolves   a pack of ghost wolves runs down whoever's nearest
		ghost_form      for a moment you're barely there: hits pass through you
		wail            a spirit's scream: everyone near is afraid
		grave_mist      cold mist that slows and gnaws at the living

	A backfire lands on the caster as any harmful spell's does (Effects/Impact).
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Types = require(Shared.Magic.Types)
local E = require(Shared.Magic.Data.SpiritTuning)

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local PropertyBehaviour = require(Cast.PropertyBehaviour)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local R = require(Cast.ArtRuntime)

type Ctx = CastTypes.EffectContext
type Outcome = CastTypes.Outcome
type Hit = Targeting.Hit

local UP = Vector3.new(0, 1, 0)

local flat, ground, foesStruck, isPlayer = R.flat, R.ground, R.foesStruck, R.isPlayer

local CURSES = { "hexed", "soulmarked", "withering", "jinxed", "crumbling", "reality_doomed" }

local SpiritArt = {}

function SpiritArt.precheck(_params: { [string]: any }, _stats: Types.SpellStats, _player: Player): string?
	if FeatureFlags.get("spirit_arts_enabled") == false then
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
	R.cue(ctx, fields, position, heavy, "spirit")
end

local function isFriend(ctx: Ctx, model: Model): boolean
	return model == ctx.character or (Targeting.canHelp(ctx.player, model) and not Targeting.canHarm(ctx.player, model))
end

-- A hit with no attacker on it (so it can't feed Doom Marks, puppets or thorn curses back into itself).
local function quietHit(c: Ctx, victim: Humanoid, share: number, from: Vector3)
	local model = victim.Parent
	if victim.Health <= 0 or not model or not model:IsA("Model") then
		return
	end
	local hit = Targeting.characterOf(model)
	if not hit then
		return
	end
	local result = DamageModel.compute(c, hit, share, { noFalloff = true })
	Damage.apply(victim, result.amount, c.player.UserId, "spirit", {
		domain = "spirit",
		crit = result.crit,
		power = c.stats.recipe.power,
		from = from,
		property = c.stats.recipe.property,
		form = "touch",
		branch = c.stats.recipe.branch,
	})
end

-- ─── Warding ────────────────────────────────────────────────────────────────

local function glyphShield(ctx: Ctx): Outcome
	local T = E.glyph_shield
	local width = at(T.width, ctx)
	local base = ground(ctx.point)
	local normal = flat(ctx.origin - base)
	local right = normal:Cross(UP).Unit
	local center = base + UP * (T.height / 2)
	local character = ctx.character
	R.spawn({
		look = "glyph_shield",
		ctx = ctx,
		position = center,
		radius = width / 2,
		seconds = at(T.seconds, ctx),
		cframe = CFrame.fromMatrix(center, right, UP),
		size = Vector3.new(width, T.height, 0.4),
		deflect = function(body, position: Vector3, velocity: Vector3, flight: any): (string?, any)
			if flight.ownerModel == character then
				return nil, nil
			end
			local rel = position - body.position
			local d = rel:Dot(normal)
			if math.abs(d) > T.thickness or math.abs(rel:Dot(right)) > width / 2 or math.abs(rel.Y) > T.height / 2 then
				return nil, nil
			end
			if velocity:Dot(normal) * d >= 0 then
				return nil, nil
			end
			R.cue(body.ctx, { fx = "glyph_stop", at = position }, position, false, "spirit")
			return "stop", nil
		end,
	})
	return { effective = true, hits = 0, note = "A ring of runes stands where you point. Bolts stop at it; people walk through." }
end

local function sigilTrap(ctx: Ctx): Outcome
	local T = E.sigil_trap
	local spot = ground(ctx.point)
	R.spawn({
		look = "sigil_trap",
		ctx = ctx,
		position = spot,
		radius = T.radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			local foes = R.foesAround(body.ctx, body.position, T.radius)
			if #foes == 0 then
				return
			end
			for _, hit in foes do
				R.hit(body.ctx, hit, T.share)
				R.status(body.ctx, hit.humanoid, "dazed", T.dazeSeconds)
				R.push(hit, flat(hit.root.Position - body.position) * T.push + UP * 25)
			end
			R.cue(body.ctx, { fx = "sigil_burst", at = body.position, radius = T.radius }, body.position, true, "spirit")
			R.endBody(body)
		end,
	})
	return { effective = true, hits = 0, note = "A sigil sinks into the ground. It's waiting for someone." }
end

local function hallowedGround(ctx: Ctx): Outcome
	local T = E.hallowed_ground
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 15))
	R.spawn({
		look = "hallowed_ground",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in Targeting.inRadius(body.position, body.radius, 12) do
				if isFriend(body.ctx, hit.model) then
					StatusEffects.cleanse(hit.humanoid, CURSES)
					Damage.heal(hit.humanoid, DamageModel.base(body.ctx.power) * T.heal, body.owner, { domain = "spirit" })
				elseif Targeting.canHarm(body.ctx.player, hit.model) then
					local cursed = false
					for _, id in CURSES do
						if StatusEffects.has(hit.humanoid, id) then
							cursed = true
							break
						end
					end
					if cursed then
						R.hit(body.ctx, hit, T.burn)
					end
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "The ground is hallowed. Curses can't stand on it." }
end

local function mirrorWard(ctx: Ctx): Outcome
	local T = E.mirror_ward
	local character = ctx.character
	for _, body in R.bodiesOf(ctx.player.UserId, "mirror_ward") do
		R.endBody(body)
	end
	R.spawn({
		look = "mirror_ward",
		ctx = ctx,
		position = ctx.origin,
		radius = T.radius,
		seconds = at(T.seconds, ctx),
		links = { Model = character },
		data = { charges = math.floor(at(T.charges, ctx)) },
		move = function(body, _dt)
			local root = character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				R.place(body, root.Position)
			end
		end,
		deflect = function(body, position: Vector3, velocity: Vector3, flight: any): (string?, any)
			if flight.ownerModel == character or body.data.charges <= 0 then
				return nil, nil
			end
			local to = body.position - position
			if to.Magnitude > T.radius or velocity:Dot(to) <= 0 then
				return nil, nil
			end
			body.data.charges -= 1
			if body.data.charges <= 0 then
				task.defer(R.endBody, body)
			end
			R.cue(body.ctx, { fx = "mirror", at = position }, position, false, "spirit")
			-- Back the way it came, at whoever cast it (a parry's return: Cast/Delivery "reflect").
			return "reflect", character
		end,
	})
	return { effective = true, hits = 0, note = "A ward of mirrors turns round you. What's thrown at you goes home." }
end

-- ─── Hexcraft ───────────────────────────────────────────────────────────────

local function doomMark(ctx: Ctx): Outcome
	local T = E.doom_mark
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0 }
	end
	local victim = target.humanoid
	local seconds = at(T.seconds, ctx)
	R.spawn({
		look = "doom_mark",
		ctx = ctx,
		position = target.root.Position,
		radius = 2,
		seconds = seconds,
		attrs = { Seconds = seconds },
		links = { Model = target.model },
		data = { victim = victim, hits = 0 },
		victimHit = function(body, _attacker)
			body.data.hits = math.min(T.maxHits, body.data.hits + 1)
			body.part:SetAttribute("Hits", body.data.hits)
		end,
		finish = function(body)
			if not R.alive(body.ctx) or victim.Health <= 0 then
				return
			end
			local root = victim.RootPart
			local where = if root then root.Position else body.position
			quietHit(body.ctx, victim, T.share + T.perHit * body.data.hits, where)
			R.cue(body.ctx, { fx = "doom", at = where, hits = body.data.hits }, where, true, "spirit")
		end,
	})
	return { effective = true, hits = 1, note = "Doom is marked on them. Every blow they take adds to it." }
end

local function illLuck(ctx: Ctx): Outcome
	local T = E.ill_luck
	for _, body in R.bodiesOf(ctx.player.UserId, "ill_luck") do
		R.endBody(body)
	end
	local character = ctx.character
	R.spawn({
		look = "ill_luck",
		ctx = ctx,
		position = ctx.origin,
		radius = T.radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		links = { Model = character },
		move = function(body, _dt)
			local root = character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				R.place(body, root.Position)
			end
		end,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, T.radius) do
				R.status(body.ctx, hit.humanoid, "jinxed", T.every + 0.5)
				R.status(body.ctx, hit.humanoid, "dazed", T.every + 0.5)
			end
		end,
	})
	return { effective = true, hits = 0, note = "Bad luck follows you. It falls on everyone near who means you harm." }
end

local function thornCurse(ctx: Ctx): Outcome
	local T = E.thorn_curse
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0 }
	end
	local victim = target.humanoid
	R.spawn({
		look = "thorn_curse",
		ctx = ctx,
		position = target.root.Position,
		radius = 2,
		seconds = at(T.seconds, ctx),
		links = { Model = target.model },
		data = { wielder = target.model, gap = 0 },
		ownerHit = function(body, _hurt)
			-- They landed a blow: the curse bites them.
			local now = os.clock()
			if body.data.gap > now then
				return
			end
			body.data.gap = now + T.gap
			local root = victim.RootPart
			quietHit(body.ctx, victim, T.share, if root then root.Position else body.position)
			if root then
				R.cue(body.ctx, { fx = "thorns", at = root.Position }, root.Position, false, "spirit")
			end
		end,
	})
	return { effective = true, hits = 1, note = "A thorn curse takes them. Every blow they land hurts them too." }
end

-- ─── Binding ────────────────────────────────────────────────────────────────

local function spiritChains(ctx: Ctx): Outcome
	local T = E.spirit_chains
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0, note = "The chains rise and find nobody." }
	end
	local seconds = at(T.seconds, ctx)
	if isPlayer(target) then
		seconds = math.min(seconds, T.pvpSeconds)
	end
	R.hit(ctx, target, T.share)
	local toward = flat(ctx.origin - target.root.Position)
	local dist = Vector3.new(ctx.origin.X - target.root.Position.X, 0, ctx.origin.Z - target.root.Position.Z).Magnitude
	if dist > 5 then
		R.drag(target, target.root.Position + toward * math.min(T.drag, dist - 4), 0.3)
	end
	task.delay(0.32, function()
		if target.humanoid.Health > 0 then
			R.status(ctx, target.humanoid, "root", seconds)
		end
	end)
	cue(ctx, { fx = "chains", from = ctx.root.Position, model = target.model, seconds = seconds + 0.3 }, target.root.Position)
	return { effective = true, hits = 1 }
end

local function soulTether(ctx: Ctx): Outcome
	local T = E.soul_tether
	local struck = foesStruck(ctx, 2)
	local a = struck[1]
	if not a then
		return { effective = false, hits = 0 }
	end
	local b = struck[2]
	if not b then
		for _, hit in Targeting.inRadius(a.root.Position, T.findReach, 6, { [a.model] = true, [ctx.character] = true }) do
			if Targeting.canHarm(ctx.player, hit.model) then
				b = hit
				break
			end
		end
	end
	if not b then
		return { effective = false, hits = 0, note = "There's nobody near them to bind them to." }
	end
	local pa, pb = a, b
	R.spawn({
		look = "soul_tether",
		ctx = ctx,
		position = (pa.root.Position + pb.root.Position) / 2,
		radius = T.reach,
		seconds = at(T.seconds, ctx),
		every = T.every,
		links = { A = pa.root, B = pb.root },
		move = function(body, _dt)
			if not pa.model.Parent or not pb.model.Parent or pa.humanoid.Health <= 0 or pb.humanoid.Health <= 0 then
				R.endBody(body)
				return
			end
			R.place(body, (pa.root.Position + pb.root.Position) / 2)
		end,
		tick = function(body)
			local apart = pb.root.Position - pa.root.Position
			local d = Vector3.new(apart.X, 0, apart.Z).Magnitude
			if d > T.reach then
				-- The bond pulls both back toward the middle.
				local mid = body.position
				R.drag(pa, mid - flat(apart) * (T.reach * 0.35), 0.2)
				R.drag(pb, mid + flat(apart) * (T.reach * 0.35), 0.2)
			end
		end,
	})
	return { effective = true, hits = 2, note = "Their souls are bound. They can't get far from each other." }
end

local function sharedFate(ctx: Ctx): Outcome
	local T = E.shared_fate
	local mine = ctx.character:FindFirstChildOfClass("Humanoid")
	local friend: Hit? = nil
	for _, hit in Targeting.select(ctx, 2) do
		if hit.model ~= ctx.character and isFriend(ctx, hit.model) then
			friend = hit
			break
		end
	end
	if not mine or not friend then
		return { effective = false, hits = 0, note = "There's nobody on your side there to share a fate with." }
	end
	local seconds = at(T.seconds, ctx)
	local untilAt = os.clock() + seconds
	R.oaths[mine] = { partner = friend.humanoid, untilAt = untilAt, split = T.split }
	R.oaths[friend.humanoid] = { partner = mine, untilAt = untilAt, split = T.split }
	R.spawn({
		look = "shared_fate",
		ctx = ctx,
		position = (ctx.root.Position + friend.root.Position) / 2,
		radius = 2,
		seconds = seconds,
		links = { A = ctx.root, B = friend.root },
	})
	return { effective = true, hits = 1, note = "Your fates are tied. Whatever falls on one of you is shared." }
end

-- ─── Necrourgy ──────────────────────────────────────────────────────────────

local function graveHand(ctx: Ctx): Outcome
	local T = E.grave_hand
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0, note = "A hand claws out of the ground and closes on nothing." }
	end
	local seconds = at(T.seconds, ctx)
	if isPlayer(target) then
		seconds = math.min(seconds, T.pvpSeconds)
	end
	R.hit(ctx, target, T.share, "unlife")
	R.status(ctx, target.humanoid, "root", seconds)
	cue(ctx, { fx = "grave_hand", model = target.model, seconds = seconds }, target.root.Position)
	return { effective = true, hits = 1 }
end

local function spiritWolves(ctx: Ctx): Outcome
	local T = E.spirit_wolves
	for _, body in R.bodiesOf(ctx.player.UserId, "spirit_wolves") do
		R.endBody(body)
	end
	R.spawn({
		look = "spirit_wolves",
		ctx = ctx,
		position = ground(ctx.origin + flat(ctx.point - ctx.origin) * 3),
		radius = T.bite,
		seconds = at(T.seconds, ctx),
		every = T.every,
		attrs = { Count = T.count },
		move = function(body, dt)
			local foe: Hit? = nil
			for _, hit in Targeting.inRadius(body.position, T.seek, 6, { [body.ctx.character] = true }) do
				if Targeting.canHarm(body.ctx.player, hit.model) then
					foe = hit
					break
				end
			end
			if foe then
				local to = foe.root.Position - body.position
				if Vector3.new(to.X, 0, to.Z).Magnitude > 2 then
					R.place(body, ground(body.position + flat(to) * math.min(to.Magnitude, T.speed * dt)))
				end
			else
				-- Nobody to hunt: back to heel.
				local root = body.ctx.character:FindFirstChild("HumanoidRootPart")
				if root and root:IsA("BasePart") and (root.Position - body.position).Magnitude > 6 then
					R.place(body, ground(body.position + flat(root.Position - body.position) * T.speed * dt))
				end
			end
		end,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, T.bite) do
				R.hit(body.ctx, hit, T.share, "soul")
			end
		end,
	})
	return { effective = true, hits = 0, note = "Ghost wolves pour out of the ground and go hunting." }
end

local function ghostForm(ctx: Ctx): Outcome
	local T = E.ghost_form
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return { effective = false, hits = 0 }
	end
	local seconds = at(T.seconds, ctx)
	StatusEffects.apply(humanoid, "evading", { duration = seconds, source = ctx.player.UserId, resist = { all = T.resist } })
	R.status(ctx, humanoid, "veiled", seconds)
	cue(ctx, { fx = "ghost", model = ctx.character, seconds = seconds }, ctx.origin)
	return { effective = true, hits = 0, note = "You're barely there. Blows pass through you." }
end

local function wail(ctx: Ctx): Outcome
	local T = E.wail
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 20))
	local hits = 0
	for _, hit in R.foesAround(ctx, ctx.origin, radius) do
		R.hit(ctx, hit, T.share, nil, {})
		R.status(ctx, hit.humanoid, "fear", at(T.fearSeconds, ctx))
		hits += 1
	end
	cue(ctx, { fx = "wail", at = ctx.origin, radius = radius }, ctx.origin, true)
	return { effective = true, hits = hits }
end

local function graveMist(ctx: Ctx): Outcome
	local T = E.grave_mist
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 16))
	R.spawn({
		look = "grave_mist",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.hit(body.ctx, hit, T.share)
				R.status(body.ctx, hit.humanoid, "slow", T.every + 0.4)
				PropertyBehaviour.applyControl(body.ctx, hit, "cold")
			end
		end,
	})
	return { effective = true, hits = 0 }
end

-- ─── Dispatch ───────────────────────────────────────────────────────────────

local MOVES: { [string]: (Ctx) -> Outcome } = {
	glyph_shield = glyphShield,
	sigil_trap = sigilTrap,
	hallowed_ground = hallowedGround,
	mirror_ward = mirrorWard,
	doom_mark = doomMark,
	ill_luck = illLuck,
	thorn_curse = thornCurse,
	spirit_chains = spiritChains,
	soul_tether = soulTether,
	shared_fate = sharedFate,
	grave_hand = graveHand,
	spirit_wolves = spiritWolves,
	ghost_form = ghostForm,
	wail = wail,
	grave_mist = graveMist,
}
SpiritArt.moves = MOVES

function SpiritArt.resolve(ctx: Ctx, params: { [string]: any }): Outcome
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


return SpiritArt
