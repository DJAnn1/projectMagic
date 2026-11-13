--!strict
--[[
	Elementals: a harmful Summon spell takes a body and fights beside its caster
	(docs/SpellOverhaul.md §8, stage 3b; owner, 2026-11-13). Which elemental a branch gives and how
	strong it is: Shared/Magic/Elemental over Data/Elementals. Called from Cast/Shapes (shape kind
	"elemental", once per cast, after the spell's own hit lands where it was aimed).

		Elementals.summon(ctx, behaviour) -> Live?     raise one where the spell landed
		Elementals.noteThreat(ownerId, model)          someone fought this summoner (or its
		                                               elemental), or the summoner fought them
		Elementals.dismiss(live, reason)               let it go (fades)
		Elementals.list() / Elementals.clear(ownerId?)

	THE BODY: an R6 humanoid rig like every other fighter (owner: humanoid models, not custom
	bodies), made of its element (material, colour from the domain palette, dim glowing eyes and
	band, a particle aura), scaled by kind. No name or health bar: it reads as what it is.
	Attribute ElementalOwner = the summoner's UserId: Targeting.canHarm and Damage.apply keep the
	summoner's own magic off it, and let others hurt it only where they may fight its summoner.

	THE FIGHT (server-side, one Heartbeat, each one thinking every tuning.think seconds): it fights
	only those who fought its summoner or it, those its summoner fought (a practice dummy you hit
	counts), and Wildborn it sees. Never a bystander. It chases no further than `leash` from its
	summoner, walks back when idle, and steps to their side if left far behind. Blows by style
	(strike, bolt, slam) go through DamageModel as the summoner's spell (wards, guards, resistances,
	PvP caps, kill rewards to the summoner) and then the property's behaviour (Cast/PropertyBehaviour),
	so a frost wight's blows chill and a storm wight's daze.

	IT ENDS when its time runs out, it's killed, or its summoner dies or leaves. One at a time (two
	from Master); a new one replaces the oldest.

	Known gaps: Wildborn and creatures don't attack elementals back (they hunt players); its hits on
	townspeople aren't judged by settlement law (the pinned delayed-hits item); it walks straight at
	things (no pathfinding).
]]

local Players = game:GetService("Players")
local RunService = game:GetService("RunService")
local TweenService = game:GetService("TweenService")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage.Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local CombatAnimations = require(Shared.Magic.Data.CombatAnimations)
local Domains = require(Shared.Magic.Data.Domains)
local Data = require(Shared.Magic.Data.Elementals)
local Elemental = require(Shared.Magic.Elemental)

local Cast = script.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local Targeting = require(Cast.Targeting)
local PropertyBehaviour = require(Cast.PropertyBehaviour)

type Ctx = CastTypes.EffectContext
type Hit = CastTypes.Hit

local T = Data.tuning
local GLOW_DIM = 0.45 -- Neon under Bloom blows out to white: accents stay dim (as NPCs and Wildborn)
local AMBIENT = { idle = "rbxassetid://180435571", walk = "rbxassetid://180426354" }
local DISABLED_STATES = {
	Enum.HumanoidStateType.Climbing,
	Enum.HumanoidStateType.FallingDown,
	Enum.HumanoidStateType.Ragdoll,
	Enum.HumanoidStateType.Seated,
	Enum.HumanoidStateType.Flying,
	Enum.HumanoidStateType.GettingUp,
}

export type Live = {
	id: number,
	owner: Player,
	ownerId: number,
	ownerCharacter: Model,
	ctx: Ctx,
	def: Data.Elemental,
	style: { [string]: any },
	share: number,
	behaviour: string?,
	model: Model,
	humanoid: Humanoid,
	root: BasePart,
	tracks: { [string]: AnimationTrack },
	born: number,
	ends: number,
	nextThink: number,
	nextBlow: number,
	target: Model?,
	gone: boolean,
}

local Elementals = {}

-- Set by Services/ElementalService: (event, fields) for the log.
Elementals.onEvent = nil :: ((string, { [string]: any }) -> ())?

local live: { Live } = {}
local threats: { [number]: { [Model]: number } } = {}
local nextId = 0
local folder: Folder? = nil

local function emit(event: string, fields: { [string]: any })
	local fn = Elementals.onEvent
	if fn then
		fn(event, fields)
	end
end

local function enabled(): boolean
	return FeatureFlags.get("elementals_enabled") ~= false
end

local function folderOf(): Folder
	if folder and folder.Parent then
		return folder
	end
	local made = Instance.new("Folder")
	made.Name = "Elementals"
	made.Parent = workspace
	folder = made
	return made
end

local function dim(color: Color3): Color3
	return Color3.new(color.R * GLOW_DIM, color.G * GLOW_DIM, color.B * GLOW_DIM)
end

local function send(e: Live, fields: { [string]: any }, position: Vector3, heavy: boolean?)
	local stats = e.ctx.stats
	local payload: { [string]: any } = {
		caster = e.ownerId,
		domain = stats.domains[1],
		property = stats.recipe.property,
		form = stats.recipe.form,
		power = stats.recipe.power,
		masteryTier = stats.masteryTier,
		shape = "elemental",
	}
	for k, v in fields do
		payload[k] = v
	end
	e.ctx.runtime:cue("shape", payload, position, heavy == true)
end

-- ─── The body ───────────────────────────────────────────────────────────────

local function materialOf(name: string): Enum.Material
	local ok, value = pcall(function()
		return (Enum.Material :: any)[name]
	end)
	return if ok and typeof(value) == "EnumItem" then value :: any else Enum.Material.SmoothPlastic
end

local function glowPart(name: string, size: Vector3, color: Color3, parent: BasePart, offset: CFrame)
	local part = Instance.new("Part")
	part.Name = name
	part.Size = size
	part.Color = dim(color)
	part.Material = Enum.Material.Neon
	part.CanCollide = false
	part.CanQuery = false
	part.CanTouch = false
	part.Massless = true
	part.CastShadow = false
	part.CFrame = parent.CFrame * offset
	local weld = Instance.new("WeldConstraint")
	weld.Part0 = parent
	weld.Part1 = part
	weld.Parent = part
	part.Parent = parent.Parent
end

local function buildRig(def: Data.Elemental, domain: string, health: number, at: CFrame, ownerId: number): (Model?, Humanoid?, BasePart?, { [string]: AnimationTrack })
	local ok, made = pcall(function()
		return Players:CreateHumanoidModelFromDescription(Instance.new("HumanoidDescription"), Enum.HumanoidRigType.R6)
	end)
	if not ok or not made then
		return nil, nil, nil, {}
	end
	local model = made :: Model
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or not root or not root:IsA("BasePart") then
		model:Destroy()
		return nil, nil, nil, {}
	end
	local animate = model:FindFirstChild("Animate")
	if animate then
		animate:Destroy()
	end
	local palette = (Domains :: any)[domain] and (Domains :: any)[domain].feel.palette or { Color3.new(1, 1, 1), Color3.new(1, 1, 1) }
	local body = def.color or palette[def.tint or 1] or palette[1]
	local accent = palette[def.accent or 2] or palette[1]
	local material = materialOf(def.material)
	for _, part in model:GetDescendants() do
		if part:IsA("BasePart") and part ~= root then
			part.Material = material
			part.Color = body
			part.Transparency = def.transparency or 0
			part:SetAttribute("Flammability", 0)
		elseif part:IsA("Decal") or part:IsA("Clothing") or part:IsA("ShirtGraphic") then
			part:Destroy() -- a face or clothes would make it a person
		end
	end
	model.Name = def.name
	model:SetAttribute("ElementalOwner", ownerId)
	model:SetAttribute("Elemental", def.name)
	model:PivotTo(at)

	local torso = model:FindFirstChild("Torso") :: BasePart?
	local head = model:FindFirstChild("Head") :: BasePart?
	if torso then
		glowPart("ElementBand", Vector3.new(2.05, 0.22, 1.05), accent, torso, CFrame.new(0, -0.7, 0))
		local aura = Instance.new("ParticleEmitter")
		aura.Name = "ElementAura"
		aura.Color = ColorSequence.new(body, accent)
		aura.Size = NumberSequence.new(0.9, 0)
		aura.Transparency = NumberSequence.new(0.3, 1)
		aura.Lifetime = NumberRange.new(0.6, 1.3)
		aura.Rate = 16
		aura.Speed = NumberRange.new(1.5, 5)
		aura.SpreadAngle = Vector2.new(70, 70)
		aura.LightEmission = 0.5
		local attachment = Instance.new("Attachment")
		attachment.Parent = torso
		aura.Parent = attachment
	end
	if head then
		for side = -1, 1, 2 do
			glowPart("ElementEye", Vector3.new(0.2, 0.12, 0.05), accent, head, CFrame.new(side * 0.2, 0.15, -0.6))
		end
	end
	if def.scale and def.scale ~= 1 then
		pcall(function()
			model:ScaleTo(def.scale :: number)
		end)
	end

	humanoid.MaxHealth = health
	humanoid.Health = health
	humanoid.WalkSpeed = def.walk or 16
	humanoid.BreakJointsOnDeath = false
	humanoid.DisplayDistanceType = Enum.HumanoidDisplayDistanceType.None
	humanoid.HealthDisplayType = Enum.HumanoidHealthDisplayType.AlwaysOff
	for _, state in DISABLED_STATES do
		humanoid:SetStateEnabled(state, false)
	end

	local animator = humanoid:FindFirstChildOfClass("Animator")
	if not animator then
		local a = Instance.new("Animator")
		a.Parent = humanoid
		animator = a
	end
	local tracks: { [string]: AnimationTrack } = {}
	local function load(name: string, id: string, looped: boolean, priority: Enum.AnimationPriority)
		local animation = Instance.new("Animation")
		animation.AnimationId = id
		local ok2, track = pcall(function()
			return (animator :: Animator):LoadAnimation(animation)
		end)
		if ok2 and track then
			track.Looped = looped
			track.Priority = priority
			tracks[name] = track
		end
	end
	load("idle", AMBIENT.idle, true, Enum.AnimationPriority.Idle)
	load("walk", AMBIENT.walk, true, Enum.AnimationPriority.Movement)
	for _, clip in { "CastSpell", "Slash1" } do
		local anim = (CombatAnimations.animations :: any)[clip]
		if anim then
			load(clip, "rbxassetid://" .. tostring(anim.id), false, Enum.AnimationPriority.Action2)
		end
	end
	return model, humanoid, root, tracks
end

-- Where it stands up: the ground under the spell's landing point.
local function standAt(ctx: Ctx): CFrame
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.FilterDescendantsInstances = { ctx.character, folderOf() }
	local from = ctx.point + Vector3.new(0, 8, 0)
	local hit = workspace:Raycast(from, Vector3.new(0, -40, 0), params)
	local ground = if hit then hit.Position else ctx.point
	local facing = ctx.origin - ground
	local look = Vector3.new(facing.X, 0, facing.Z)
	local at = ground + Vector3.new(0, 3, 0)
	return if look.Magnitude > 0.1 then CFrame.lookAt(at, at - look) else CFrame.new(at)
end

-- ─── Summoning and letting go ───────────────────────────────────────────────

local function ownedBy(ownerId: number): { Live }
	local out: { Live } = {}
	for _, e in live do
		if e.ownerId == ownerId and not e.gone then
			table.insert(out, e)
		end
	end
	return out
end

function Elementals.dismiss(e: Live, reason: string)
	if e.gone then
		return
	end
	e.gone = true
	local index = table.find(live, e)
	if index then
		table.remove(live, index)
	end
	emit("elemental_faded", { userId = e.ownerId, name = e.def.name, reason = reason, seconds = math.floor(os.clock() - e.born) })
	if e.model.Parent then
		send(e, { stage = "fade", spots = { e.root.Position }, radius = 3 }, e.root.Position)
		for _, part in e.model:GetDescendants() do
			if part:IsA("BasePart") then
				part.CanCollide = false
				TweenService:Create(part, TweenInfo.new(0.5), { Transparency = 1 }):Play()
			elseif part:IsA("ParticleEmitter") then
				part.Enabled = false
			end
		end
		e.root.Anchored = true
		task.delay(0.6, function()
			e.model:Destroy()
		end)
	end
end

function Elementals.summon(ctx: Ctx, behaviour: string?): Live?
	if not enabled() or not ctx.player or ctx.backfire then
		return nil
	end
	local owner = ctx.player
	local stats = ctx.stats
	local tier = stats.masteryTier or 0
	local power = stats.recipe.power
	local def, style = Elemental.forBranch(stats.recipe.branch)
	-- One at a time (two from Master): a new one replaces the oldest.
	local mine = ownedBy(owner.UserId)
	local limit = Elemental.limit(tier)
	while #mine >= limit do
		Elementals.dismiss(table.remove(mine, 1) :: Live, "replaced")
	end
	if #live >= T.maxAlive then
		emit("elemental_refused", { userId = owner.UserId, reason = "server full", alive = #live })
		return nil
	end

	local health = Elemental.health(def, power, tier)
	local model, humanoid, root, tracks = buildRig(def, stats.domains[1], health, standAt(ctx), owner.UserId)
	if not model or not humanoid or not root then
		emit("elemental_refused", { userId = owner.UserId, reason = "no rig" })
		return nil
	end
	-- The cast's context, frozen for later: its blows are the summoner's spell.
	local base = table.clone(ctx)
	base.delivered = nil
	base.target = nil
	nextId += 1
	local now = os.clock()
	local e: Live = {
		id = nextId,
		owner = owner,
		ownerId = owner.UserId,
		ownerCharacter = ctx.character,
		ctx = base,
		def = def,
		style = style,
		share = Elemental.share(style, tier),
		behaviour = behaviour,
		model = model,
		humanoid = humanoid,
		root = root,
		tracks = tracks,
		born = now,
		ends = now + T.seconds,
		nextThink = now + 0.4, -- a moment to rise
		nextBlow = now + 0.8,
		target = nil,
		gone = false,
	}
	model.Parent = folderOf()
	pcall(function()
		root:SetNetworkOwner(nil)
	end)
	humanoid.Died:Connect(function()
		local by = humanoid:GetAttribute("LastMagicAttacker")
		emit("elemental_killed", { userId = e.ownerId, name = def.name, by = by })
		Elementals.dismiss(e, "killed")
	end)
	local idle = tracks.idle
	if idle then
		idle:Play()
	end
	table.insert(live, e)
	if ctx.target and ctx.target ~= ctx.character then
		Elementals.noteThreat(owner.UserId, ctx.target)
	end
	send(e, { stage = "rise", spots = { root.Position }, radius = 3 * (def.scale or 1) }, root.Position, true)
	emit("elemental_summoned", {
		userId = owner.UserId,
		name = def.name,
		style = def.style,
		branch = stats.recipe.branch,
		power = power,
		tier = tier,
		health = health,
		share = math.floor(e.share * 100) / 100,
	})
	return e
end

-- ─── Who it fights ──────────────────────────────────────────────────────────

function Elementals.noteThreat(ownerId: number, model: Model)
	if model:GetAttribute("ElementalOwner") == ownerId then
		return
	end
	local list = threats[ownerId]
	if not list then
		list = {}
		threats[ownerId] = list
	end
	list[model] = os.clock() + T.threatSeconds
end

local function hitOf(model: Model): Hit?
	local humanoid = model:FindFirstChildOfClass("Humanoid")
	local root = model:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") or not model.Parent then
		return nil
	end
	return { model = model, humanoid = humanoid, root = root, distance = 0 }
end

local function ownerRoot(e: Live): BasePart?
	local character = e.owner.Character
	if character ~= e.ownerCharacter then
		return nil
	end
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	local root = character and character:FindFirstChild("HumanoidRootPart")
	if not humanoid or humanoid.Health <= 0 or not root or not root:IsA("BasePart") then
		return nil
	end
	return root
end

-- Everyone this elemental may fight right now, nearest first.
local function candidates(e: Live, home: BasePart): { Hit }
	local out: { Hit } = {}
	local seen: { [Model]: boolean } = {}
	local now = os.clock()
	local function consider(model: Model)
		if seen[model] or model == e.model or model == e.ownerCharacter then
			return
		end
		seen[model] = true
		local owner = model:GetAttribute("ElementalOwner")
		if owner == e.ownerId then
			return
		end
		local hit = hitOf(model)
		if not hit or (hit.root.Position - home.Position).Magnitude > T.leash or not Targeting.canHarm(e.owner, model) then
			return
		end
		hit.distance = (hit.root.Position - e.root.Position).Magnitude
		table.insert(out, hit)
	end
	local list = threats[e.ownerId]
	if list then
		for model, untilAt in list do
			if untilAt < now or not model.Parent then
				list[model] = nil
			else
				consider(model)
			end
		end
	end
	for _, hit in Targeting.inRadius(e.root.Position, T.sight, 8, { [e.model] = true, [e.ownerCharacter] = true }) do
		if hit.model:GetAttribute("Wildborn") ~= nil then
			consider(hit.model)
		end
	end
	table.sort(out, function(a, b)
		return a.distance < b.distance
	end)
	return out
end

-- ─── Blows ──────────────────────────────────────────────────────────────────

local function combatCtx(e: Live, target: Hit): Ctx
	local c = table.clone(e.ctx)
	c.character = e.model
	c.root = e.root
	c.origin = e.root.Position
	c.point = target.root.Position
	c.target = target.model
	c.delivered = nil
	return c
end

local function land(e: Live, c: Ctx, hit: Hit)
	if e.gone or hit.humanoid.Health <= 0 or not hit.model.Parent or not Targeting.canHarm(e.owner, hit.model) then
		return
	end
	local dealt, result = DamageModel.hit(c, hit, e.share, "elemental", { noFalloff = true })
	PropertyBehaviour.apply(c, hit, dealt, result, e.behaviour)
end

local function play(e: Live, clip: string)
	local track = e.tracks[clip]
	if track then
		track:Play(0.05)
	end
end

local function face(e: Live, at: Vector3)
	local pos = e.root.Position
	local look = Vector3.new(at.X, pos.Y, at.Z)
	if (look - pos).Magnitude > 0.1 then
		e.root.CFrame = CFrame.lookAt(pos, look)
	end
end

-- One blow by style. Returns false when it couldn't (a wall in the way of a bolt).
local function blow(e: Live, target: Hit, all: { Hit }): boolean
	local kind = e.def.style
	local c = combatCtx(e, target)
	if kind == "bolt" then
		local from = e.root.Position + Vector3.new(0, 1.5, 0)
		local to = target.root.Position
		local clear = Targeting.lineOfSight(from, to, { e.model, target.model, e.ownerCharacter }, 1)
		if not clear then
			return false
		end
		play(e, "CastSpell")
		send(e, { stage = "split", from = from, spots = { to - Vector3.new(0, 2.5, 0) } }, from)
		local travel = math.clamp((to - from).Magnitude / (e.style.speed or 90), 0.05, 0.6)
		task.delay(travel, function()
			if (target.root.Position - e.root.Position).Magnitude <= e.style.reach * 1.3 then
				land(e, c, target)
			end
		end)
	elseif kind == "slam" then
		play(e, "CastSpell")
		local radius = e.style.radius or 8
		local at = e.root.Position - Vector3.new(0, 2.5 * (e.def.scale or 1), 0)
		send(e, { stage = "hit", shape = "nova", spots = { at }, radius = radius }, at)
		for _, hit in all do
			if (hit.root.Position - e.root.Position).Magnitude <= radius then
				land(e, c, hit)
			end
		end
	else
		play(e, "Slash1")
		send(e, { stage = "hit", spots = { target.root.Position }, radius = 1.6 }, target.root.Position)
		land(e, c, target)
	end
	return true
end

-- ─── Thinking ───────────────────────────────────────────────────────────────

local function animate(e: Live)
	local moving = e.humanoid.MoveDirection.Magnitude > 0.1
	local walk, idle = e.tracks.walk, e.tracks.idle
	if walk and moving and not walk.IsPlaying then
		walk:Play(0.15)
		if idle then
			idle:Stop(0.15)
		end
	elseif idle and not moving and not idle.IsPlaying then
		idle:Play(0.15)
		if walk then
			walk:Stop(0.15)
		end
	end
end

local function think(e: Live, now: number)
	local home = ownerRoot(e)
	if not home or not e.owner.Parent then
		Elementals.dismiss(e, "summoner gone")
		return
	end
	if now >= e.ends then
		Elementals.dismiss(e, "time")
		return
	end
	if e.model:GetAttribute("TimeFrozen") or e.root.Anchored then
		return -- held in a Timestop
	end
	local fromHome = (e.root.Position - home.Position).Magnitude
	if fromHome > T.teleport then
		e.model:PivotTo(home.CFrame * CFrame.new(3, 0, 3))
		e.target = nil
		return
	end

	local all = candidates(e, home)
	local target: Hit? = nil
	if e.target then
		for _, hit in all do
			if hit.model == e.target then
				target = hit
				break
			end
		end
	end
	target = target or all[1]
	e.target = if target then target.model else nil

	if target then
		local d = Vector3.new(target.root.Position.X - e.root.Position.X, 0, target.root.Position.Z - e.root.Position.Z).Magnitude
		local reach = e.style.reach
		local inReach = d <= reach + 0.5
		if inReach then
			e.humanoid:MoveTo(e.root.Position)
			face(e, target.root.Position)
			if now >= e.nextBlow then
				if blow(e, target, all) then
					e.nextBlow = now + e.style.every
				else
					e.humanoid:MoveTo(target.root.Position) -- a wall in the way: go round it
				end
			end
		else
			e.humanoid:MoveTo(target.root.Position)
		end
	elseif fromHome > T.follow then
		local side = home.CFrame * CFrame.new(3, 0, 2)
		e.humanoid:MoveTo(side.Position)
	else
		e.humanoid:MoveTo(e.root.Position)
	end
	animate(e)
end

local function step()
	if #live == 0 then
		return
	end
	local now = os.clock()
	for i = #live, 1, -1 do
		local e = live[i]
		if e and not e.gone and now >= e.nextThink then
			e.nextThink = now + T.think
			if not e.model.Parent or e.humanoid.Health <= 0 then
				Elementals.dismiss(e, "gone")
			else
				local ok, err = pcall(think, e, now)
				if not ok then
					warn("[Elementals] think: " .. tostring(err))
					Elementals.dismiss(e, "error")
				end
			end
		end
	end
end

-- ─── Queries ────────────────────────────────────────────────────────────────

function Elementals.list(): { Live }
	return table.clone(live)
end

function Elementals.count(): number
	return #live
end

function Elementals.clear(ownerId: number?): number
	local n = 0
	for _, e in table.clone(live) do
		if ownerId == nil or e.ownerId == ownerId then
			Elementals.dismiss(e, "cleared")
			n += 1
		end
	end
	return n
end

function Elementals.forget(ownerId: number)
	threats[ownerId] = nil
	for _, e in table.clone(live) do
		if e.ownerId == ownerId then
			Elementals.dismiss(e, "summoner gone")
		end
	end
end

if RunService:IsServer() then
	RunService.Heartbeat:Connect(step)
	-- Something that isn't a player (a Wildborn, a creature, an NPC mage) hit a summoner or an
	-- elemental: their elementals fight it. Players hitting are told by ElementalService (topics).
	Damage.listenAttacked(function(humanoid: Humanoid, attacker: Model)
		local model = humanoid.Parent
		if not model or not model:IsA("Model") then
			return
		end
		local victim = Players:GetPlayerFromCharacter(model)
		local owner = if victim then victim.UserId else model:GetAttribute("ElementalOwner")
		if typeof(owner) == "number" and attacker ~= model and Players:GetPlayerFromCharacter(attacker) == nil then
			Elementals.noteThreat(owner, attacker)
		end
	end)
end

return Elementals
