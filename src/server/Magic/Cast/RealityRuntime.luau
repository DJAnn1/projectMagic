--!strict
--[[
	RealityRuntime: the Reality powers that outlive their cast (docs/Reality.md). Effects/RealityPower
	starts them, Services/RealityService steps them. Numbers: Shared/Magic/Data/RealityTuning.
	Decisions: Shared/Magic/RealityRules.

	FAVOR       Your hits crit more (and past the usual cap), some direct hits on you graze off, and
	            you backfire less (the reality_favored status).
	DOOM        The reverse on a target: hits on them crit more, their direct hits sometimes miss, and
	            they backfire more.
	CERTAINTY   Your next few hits on a target are guaranteed crits.
	TWIST       Charges: a direct hit on you is cancelled and a share of it lands on whoever sent it.
	CONJURE     Matter from nothing: a step, a bridge, a wall, a pillar that lifts you, a bastion.
	CAGE        A solid box around a target.
	UNMAKE      Parts in reach stop existing for a while (no collision, nearly invisible), through a
	            ledger that puts every value back. Floors, characters and anything tagged Protected or
	            NoMagicEdit are never touched. People it reaches lose wards and take a hit.
	UNDYING     Nothing can take you below 1 health for a few seconds.
	FRAY        A target takes more damage.
	POLYMORPH   A target becomes a small creature: no casting (status), no attacks or dashes (the
	            Polymorphed attribute, read by ActionState and NPCCombat), slower.
	EXCHANGE    You and a target swap health percentages.
	EDICTS      A local law: Hush (nobody you could harm may cast), Sanctuary (nobody inside takes
	            harm except from you), Severance (hostile projectiles vanish), Reversal (harm on you
	            and your allies heals instead). Worldlaw is an edict over a region.

	Hooks, each chained with whatever was already there:
		Damage.interceptor     before Time's: sanctuary, reversal, twist, graze, doom's miss, fray.
		                       After Time's: undying.
		Delivery.interceptor   before Gravity's: severance ("erase").
		DamageModel.critBonus  favor, doom, certainty.
	Statuses are the truth for the personal effects: Dispel and Cleanse remove the status, and the
	effect ends with it.
]]

local CollectionService = game:GetService("CollectionService")
local Debris = game:GetService("Debris")
local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local R = require(Shared.Magic.Data.RealityTuning)
local Rules = require(Shared.Magic.RealityRules)

local Cast = script.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local Delivery = require(Cast.Delivery)
local EffectBudget = require(Cast.EffectBudget)
local PvpRules = require(Cast.PvpRules)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)

type Ctx = CastTypes.EffectContext
type Hit = CastTypes.Hit

local byTier = Rules.byTier

local POLY_ATTRIBUTE = "Polymorphed"
local CONJURED_TAG = "RealityConjured"
local WHITE = Color3.fromRGB(255, 255, 255)
local PINK = Color3.fromRGB(255, 80, 200)
local CYAN = Color3.fromRGB(80, 255, 220)

type Luck = { expires: number, crit: number, chance: number, rng: Random }
type Seal = { left: number, expires: number }
type Twist = { expires: number, charges: number, reflect: number, userId: number }
type Fray = { expires: number, mult: number }
type Poly = { expires: number, model: Model, humanoid: Humanoid, hidden: { [Instance]: number }, critter: Model }
type Edict = {
	id: number,
	kind: string,
	owner: number,
	player: Player,
	follow: BasePart?,
	center: Vector3,
	radius: number,
	expires: number,
	nextScan: number,
	worldlaw: boolean,
	mult: number,
	maxTargets: number,
}
type Unmade = { props: { [string]: any }, expires: number, owner: number }
type Conjured = { model: Model, expires: number, owner: number }

local RealityRuntime = {}

local runner: any = nil
local log: any = nil

local favors: { [Humanoid]: Luck } = {}
local dooms: { [Humanoid]: Luck } = {}
local seals: { [Humanoid]: { [number]: Seal } } = {}
local twists: { [Humanoid]: Twist } = {}
local undying: { [Humanoid]: number } = {}
local frays: { [Humanoid]: Fray } = {}
local polys: { [Humanoid]: Poly } = {}
local polyImmune: { [Humanoid]: number } = setmetatable({}, { __mode = "k" }) :: any
local cooldowns: { [string]: { [number]: number } } = { undying = {}, exchange = {}, worldlaw = {} }
local edicts: { Edict } = {}
local unmade: { [BasePart]: Unmade } = {}
local unmadeCount = 0
local conjured: { Conjured } = {}
local reflecting = false
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
		runner:cue("reality", payload, position, heavy == true)
	end
end

-- The floating word over someone ("Grazed", "Twisted"...), like Time's "Foreseen".
local function tag(humanoid: Humanoid, id: string, word: string, harmful: boolean, source: number?)
	local root = humanoid.RootPart
	if root and runner then
		runner:cue("statusTag", { status = id, name = word, harmful = harmful, caster = source }, root.Position + Vector3.new(0, 3, 0), false)
	end
end

local function humanoidOf(model: Instance?): Humanoid?
	return if model then model:FindFirstChildOfClass("Humanoid") else nil
end

-- A personal effect is live while its entry hasn't expired AND its status is still there.
local function live(expires: number?, humanoid: Humanoid, status: string): boolean
	return expires ~= nil and now() < expires and StatusEffects.has(humanoid, status)
end

-- Whoever dealt a hit: an NPC's model rides on info.attacker, a player's comes from the UserId.
local function attackerOf(source: number?, info: Damage.Info?): Humanoid?
	if info and info.attacker then
		return humanoidOf(info.attacker)
	end
	if source then
		local player = Players:GetPlayerByUserId(source)
		return humanoidOf(player and player.Character)
	end
	return nil
end

-- How far a rig's root sits above its feet (R6 legs aren't counted in HipHeight).
local function footOffset(humanoid: Humanoid, root: BasePart): number
	if humanoid.RigType == Enum.HumanoidRigType.R6 then
		return 3
	end
	return humanoid.HipHeight + root.Size.Y / 2
end

local function groundBelow(from: Vector3): Vector3?
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	local excluded: { Instance } = {}
	local magicFx = workspace:FindFirstChild("MagicFx")
	if magicFx then
		table.insert(excluded, magicFx)
	end
	local start = from + Vector3.new(0, 4, 0)
	for _ = 1, 6 do
		params.FilterDescendantsInstances = excluded
		local result = workspace:Raycast(start, Vector3.new(0, -300, 0), params)
		if not result then
			return nil
		end
		local instance = result.Instance
		if instance:IsA("Terrain") or ((instance :: BasePart).CanCollide and not Targeting.characterOf(instance)) then
			return result.Position
		end
		table.insert(excluded, instance)
	end
	return nil
end

-- Would a projectile from this model be an attack on that player? NPC bolts always are.
local function hostile(owner: Model, userId: number): boolean
	local player = Players:GetPlayerFromCharacter(owner)
	if player then
		return player.UserId ~= userId and PvpRules.allowed(player.UserId, userId)
	end
	return true
end

-- ─── Cooldowns ──────────────────────────────────────────────────────────────

function RealityRuntime.cooldownRefusal(name: string, userId: number): string?
	return if (cooldowns[name][userId] or 0) > now() then "REALITY_COOLDOWN" else nil
end

local function startCooldown(name: string, userId: number, seconds: number)
	cooldowns[name][userId] = now() + seconds
end

-- ─── Fortune ────────────────────────────────────────────────────────────────

function RealityRuntime.startFavor(ctx: Ctx): boolean
	local humanoid = humanoidOf(ctx.character)
	if not humanoid then
		return false
	end
	local tier = ctx.stats.masteryTier
	local seconds = byTier(R.favor.seconds, tier)
	favors[humanoid] = { expires = now() + seconds, crit = byTier(R.favor.crit, tier), chance = byTier(R.favor.graze, tier), rng = ctx.rng }
	StatusEffects.apply(humanoid, "reality_favored", { duration = seconds, source = ctx.player.UserId })
	fx("favor", { model = ctx.character, duration = seconds }, ctx.root.Position)
	return true
end

function RealityRuntime.startDoom(ctx: Ctx, hit: Hit)
	local tier = ctx.stats.masteryTier
	local seconds = byTier(R.doom.seconds, tier)
	dooms[hit.humanoid] = { expires = now() + seconds, crit = byTier(R.doom.crit, tier), chance = byTier(R.doom.miss, tier), rng = ctx.rng }
	StatusEffects.apply(hit.humanoid, "reality_doomed", { duration = seconds, source = ctx.player.UserId })
	fx("doom", { model = hit.model, duration = seconds }, hit.root.Position)
end

function RealityRuntime.startCertainty(ctx: Ctx, hit: Hit)
	local list = seals[hit.humanoid] or {}
	seals[hit.humanoid] = list
	list[ctx.player.UserId] = { left = byTier(R.certainty.hits, ctx.stats.masteryTier), expires = now() + R.certainty.seconds }
	StatusEffects.apply(hit.humanoid, "reality_sealed", { duration = R.certainty.seconds, source = ctx.player.UserId })
	fx("seal", { model = hit.model }, hit.root.Position)
end

function RealityRuntime.startTwist(ctx: Ctx): boolean
	local humanoid = humanoidOf(ctx.character)
	if not humanoid then
		return false
	end
	local tier = ctx.stats.masteryTier
	local seconds = byTier(R.twist.seconds, tier)
	twists[humanoid] = { expires = now() + seconds, charges = byTier(R.twist.charges, tier), reflect = byTier(R.twist.reflect, tier), userId = ctx.player.UserId }
	StatusEffects.apply(humanoid, "reality_fated", { duration = seconds, source = ctx.player.UserId })
	fx("twist", { model = ctx.character, duration = seconds }, ctx.root.Position)
	return true
end

-- ─── Substance ──────────────────────────────────────────────────────────────

function RealityRuntime.startUndying(ctx: Ctx): boolean
	local humanoid = humanoidOf(ctx.character)
	if not humanoid then
		return false
	end
	local tier = ctx.stats.masteryTier
	local seconds = byTier(R.undying.seconds, tier)
	undying[humanoid] = now() + seconds
	startCooldown("undying", ctx.player.UserId, byTier(R.undying.cooldown, tier))
	StatusEffects.apply(humanoid, "reality_undying", { duration = seconds, source = ctx.player.UserId })
	fx("undying", { model = ctx.character, duration = seconds }, ctx.root.Position)
	return true
end

function RealityRuntime.startFray(ctx: Ctx, hit: Hit)
	local tier = ctx.stats.masteryTier
	local seconds = byTier(R.fray.seconds, tier)
	frays[hit.humanoid] = { expires = now() + seconds, mult = byTier(R.fray.mult, tier) }
	StatusEffects.apply(hit.humanoid, "reality_frayed", { duration = seconds, source = ctx.player.UserId })
	fx("fray", { model = hit.model, duration = seconds }, hit.root.Position)
end

-- ─── Conjure and Cage ───────────────────────────────────────────────────────

local function conjuredFolder(): Folder
	local folder = workspace:FindFirstChild("RealityConjured")
	if not folder then
		local created = Instance.new("Folder")
		created.Name = "RealityConjured"
		created.Parent = workspace
		folder = created
	end
	return folder :: Folder
end

local function solid(model: Model, size: Vector3, cframe: CFrame, shape: Enum.PartType?): Part
	local p = Instance.new("Part")
	p.Name = "Conjured"
	p.Shape = shape or Enum.PartType.Block
	p.Size = size
	p.CFrame = cframe
	p.Anchored = true
	p.CanCollide = true
	p.Material = Enum.Material.Glass
	p.Color = WHITE:Lerp(if (#model:GetChildren()) % 2 == 0 then PINK else CYAN, 0.18)
	p.Transparency = 0.3
	p.Reflectance = 0.1
	p.TopSurface = Enum.SurfaceType.Smooth
	p.BottomSurface = Enum.SurfaceType.Smooth
	CollectionService:AddTag(p, "NoMagicEdit") -- reality fields leave conjured matter alone
	p.Parent = model
	return p
end

-- Is anyone but `allow` standing where this would form?
local function occupied(cframe: CFrame, size: Vector3, allow: Model?): boolean
	local params = OverlapParams.new()
	params.MaxParts = 60
	for _, part in workspace:GetPartBoundsInBox(cframe, size, params) do
		local hit = Targeting.characterOf(part)
		if hit and hit.model ~= allow then
			return true
		end
	end
	return false
end

local function keep(model: Model, owner: number, seconds: number)
	CollectionService:AddTag(model, CONJURED_TAG)
	model:SetAttribute("OwnerUserId", owner)
	model.Parent = conjuredFolder()
	Debris:AddItem(model, seconds + 2) -- a safety net: the step removes it on time
	-- One caster keeps at most a few shapes: the oldest goes (the list is in creation order).
	local mine = 0
	for _, c in conjured do
		if c.owner == owner then
			mine += 1
		end
	end
	local i = 1
	while mine >= R.conjure.maxPerCaster and i <= #conjured do
		if conjured[i].owner == owner then
			table.remove(conjured, i).model:Destroy()
			mine -= 1
		else
			i += 1
		end
	end
	table.insert(conjured, { model = model, expires = now() + seconds, owner = owner })
end

-- Builds what Conjure makes for this form. Returns how many parts, or 0 and why not.
function RealityRuntime.conjure(ctx: Ctx): (number, string?)
	local shape = Rules.conjureShape(ctx.stats.recipe.form)
	local humanoid = humanoidOf(ctx.character)
	if not shape or not humanoid then
		return 0, "Nothing takes shape."
	end
	local tier = ctx.stats.masteryTier
	local C = R.conjure
	local seconds = byTier(C.seconds, tier)
	local root = ctx.root
	local feet = root.Position - Vector3.new(0, footOffset(humanoid, root), 0)
	local model = Instance.new("Model")
	model.Name = "Conjured_" .. shape

	if shape == "step" then
		local cframe = CFrame.new(feet - Vector3.new(0, 0.5, 0)) * root.CFrame.Rotation
		solid(model, Vector3.new(C.stepSize, 1, C.stepSize), cframe)
	elseif shape == "bridge" then
		local look = Vector3.new(root.CFrame.LookVector.X, 0, root.CFrame.LookVector.Z)
		local from = feet + (if look.Magnitude > 0.1 then look.Unit else Vector3.zero)
		local middle, length, direction = Rules.bridge(from, ctx.point, byTier(C.bridgeLength, tier))
		if length < 4 then
			model:Destroy()
			return 0, "Aim further away to lay a bridge."
		end
		local cframe = CFrame.lookAt(middle, middle + direction) * CFrame.new(0, -0.5, 0)
		solid(model, Vector3.new(C.bridgeWidth, 1, length), cframe)
	elseif shape == "wall" or shape == "pillar" then
		local base = groundBelow(ctx.point) or ctx.point
		local size, cframe
		if shape == "wall" then
			local height = byTier(C.wallHeight, tier)
			local facing = Vector3.new(ctx.origin.X - base.X, 0, ctx.origin.Z - base.Z)
			local mid = base + Vector3.new(0, height / 2, 0)
			cframe = CFrame.lookAt(mid, mid + (if facing.Magnitude > 0.1 then facing.Unit else Vector3.new(0, 0, 1)))
			size = Vector3.new(byTier(C.wallWidth, tier), height, 2)
		else
			local height = byTier(C.pillarHeight, tier)
			cframe = CFrame.new(base + Vector3.new(0, height / 2, 0))
			size = Vector3.new(6, height, 6)
		end
		if occupied(cframe, size, if shape == "pillar" then ctx.character else nil) then
			model:Destroy()
			return 0, "Someone's standing where it would form."
		end
		solid(model, size, cframe)
		-- A pillar under your own feet carries you up with it.
		if shape == "pillar" and Vector3.new(feet.X - base.X, 0, feet.Z - base.Z).Magnitude < 4 then
			ctx.character:PivotTo(CFrame.new(base + Vector3.new(0, size.Y + footOffset(humanoid, root) + 0.2, 0)) * root.CFrame.Rotation)
		end
	else -- bastion
		local center = groundBelow(ctx.point) or ctx.point
		local radius = byTier(C.bastionRadius, tier)
		local height = 9 + tier
		for _, panel in Rules.ring(radius, C.bastionPanels) do
			local cframe = CFrame.new(center + panel.offset + Vector3.new(0, height / 2, 0)) * CFrame.Angles(0, panel.angle, 0)
			local size = Vector3.new(panel.width, height, 1)
			if not occupied(cframe, size, nil) then
				solid(model, size, cframe)
			end
		end
		local roof = radius * 2 + 2
		solid(model, Vector3.new(1, roof, roof), CFrame.new(center + Vector3.new(0, height + 0.5, 0)) * CFrame.Angles(0, 0, math.pi / 2), Enum.PartType.Cylinder)
	end

	local count = #model:GetChildren()
	if count == 0 or EffectBudget.takeParts(count) < count then
		model:Destroy()
		return 0, "The world won't hold any more of that right now."
	end
	keep(model, ctx.player.UserId, seconds)
	fx("conjure", { shape = shape, duration = seconds }, model:GetPivot().Position)
	return count, nil
end

function RealityRuntime.cage(ctx: Ctx, hit: Hit): boolean
	local tier = ctx.stats.masteryTier
	local seconds = byTier(R.cage.seconds, tier)
	local base = groundBelow(hit.root.Position) or (hit.root.Position - Vector3.new(0, 3, 0))
	local S, H = R.cage.size, R.cage.height
	local half = S / 2 + 0.5
	local model = Instance.new("Model")
	model.Name = "Conjured_cage"
	local mid = base + Vector3.new(0, H / 2, 0)
	solid(model, Vector3.new(S + 2, H, 1), CFrame.new(mid + Vector3.new(0, 0, half)))
	solid(model, Vector3.new(S + 2, H, 1), CFrame.new(mid - Vector3.new(0, 0, half)))
	solid(model, Vector3.new(1, H, S), CFrame.new(mid + Vector3.new(half, 0, 0)))
	solid(model, Vector3.new(1, H, S), CFrame.new(mid - Vector3.new(half, 0, 0)))
	solid(model, Vector3.new(S + 2, 1, S + 2), CFrame.new(base + Vector3.new(0, H + 0.5, 0)))
	if EffectBudget.takeParts(5) < 5 then
		model:Destroy()
		return false
	end
	keep(model, ctx.player.UserId, seconds)
	fx("cage", { duration = seconds }, mid)
	return true
end

-- ─── Unmake ─────────────────────────────────────────────────────────────────

local function shielded(instance: Instance): boolean
	if CollectionService:HasTag(instance, "Protected") or CollectionService:HasTag(instance, "NoMagicEdit") then
		return true
	end
	local ancestor = instance.Parent
	while ancestor and ancestor ~= workspace do
		if CollectionService:HasTag(ancestor, "Protected") or CollectionService:HasTag(ancestor, "NoMagicEdit") or ancestor.Name == "MagicFx" then
			return true
		end
		ancestor = ancestor.Parent
	end
	return false
end

-- Parts that someone is standing on: unmaking them would drop people through the world.
local function standingOn(center: Vector3, radius: number): { [BasePart]: boolean }
	local out: { [BasePart]: boolean } = {}
	local params = RaycastParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	for _, hit in Targeting.inRadius(center, radius + 10, 40) do
		params.FilterDescendantsInstances = { hit.model }
		local result = workspace:Raycast(hit.root.Position, Vector3.new(0, -8, 0), params)
		if result and result.Instance:IsA("BasePart") and not result.Instance:IsA("Terrain") then
			out[result.Instance :: BasePart] = true
		end
	end
	return out
end

local function restore(part: BasePart, entry: Unmade)
	unmade[part] = nil
	unmadeCount -= 1
	if part.Parent then
		for property, value in entry.props do
			(part :: any)[property] = value
		end
	end
end

-- Returns how many parts stopped existing and how many people were hit.
function RealityRuntime.unmake(ctx: Ctx): (number, number)
	local stats = ctx.stats
	local tier = stats.masteryTier
	local U = R.unmake
	local form = stats.recipe.form
	local point = form == "touch" or form == "projectile" or form == "beam" or form == "chain"
	local radius = if point then U.pointRadius else math.clamp(stats.area, 6, U.areaRadiusMax)
	local center = if form == "aura" then ctx.origin else ctx.point

	local hits = 0
	for _, hit in Targeting.select(ctx) do
		if Targeting.canHarm(ctx.player, hit.model) then
			StatusEffects.stripBeneficial(hit.humanoid, byTier(U.strip, tier))
			DamageModel.hit(ctx, hit, byTier(U.share, tier), "substance", { noFalloff = point })
			hits += 1
		end
	end

	local want = math.min(byTier(U.parts, tier), U.serverParts - unmadeCount)
	local count = 0
	if want > 0 then
		local floorTop = center.Y + 1.5
		local underfoot = standingOn(center, radius)
		local params = OverlapParams.new()
		params.MaxParts = want * 8
		local picked: { BasePart } = {}
		for _, part in workspace:GetPartBoundsInRadius(center, radius, params) do
			if #picked >= want then
				break
			end
			local size = part.Size
			local isFloor = size.Y <= 2.5 and size.X * size.Z >= 30 and part.Position.Y + size.Y / 2 <= floorTop
			if
				not part:IsA("Terrain")
				and not unmade[part]
				and not underfoot[part]
				and not isFloor
				and part.Transparency < 1
				and size.Magnitude < 200
				and not Targeting.characterOf(part)
				and not shielded(part)
			then
				table.insert(picked, part)
			end
		end
		local granted = EffectBudget.takeParts(#picked)
		local expires = now() + byTier(U.seconds, tier)
		for i = 1, granted do
			local part = picked[i]
			unmade[part] = {
				props = { CanCollide = part.CanCollide, CanTouch = part.CanTouch, Transparency = part.Transparency, Anchored = part.Anchored },
				expires = expires,
				owner = ctx.player.UserId,
			}
			unmadeCount += 1
			part.Anchored = true -- an unmade crate doesn't fall away
			part.CanCollide = false
			part.CanTouch = false
			part.Transparency = math.max(part.Transparency, U.transparency)
			count += 1
		end
	end
	fx("unmake", { radius = radius }, center)
	return count, hits
end

-- ─── Polymorph ──────────────────────────────────────────────────────────────

local function critter(root: BasePart, rng: Random, feet: number): Model
	local model = Instance.new("Model")
	model.Name = "RealityCritter"
	local fur = (if rng:NextNumber() < 0.5 then PINK else CYAN):Lerp(Color3.fromRGB(150, 130, 110), 0.55)
	local function piece(shape: Enum.PartType, size: Vector3, offset: CFrame, color: Color3)
		local p = Instance.new("Part")
		p.Name = "Critter"
		p.Shape = shape
		p.Size = size
		p.Color = color
		p.Material = Enum.Material.SmoothPlastic
		p.CanCollide = false
		p.CanQuery = false
		p.CanTouch = false
		p.Massless = true
		p.CastShadow = false
		p.CFrame = root.CFrame * offset
		local weld = Instance.new("WeldConstraint")
		weld.Part0 = root
		weld.Part1 = p
		weld.Parent = p
		p.Parent = model
	end
	local y = -feet
	piece(Enum.PartType.Block, Vector3.new(1.6, 1.2, 2.2), CFrame.new(0, y + 0.95, 0), fur)
	piece(Enum.PartType.Ball, Vector3.new(1.2, 1.2, 1.2), CFrame.new(0, y + 1.6, -1.25), fur)
	for _, side in { -1, 1 } do
		piece(Enum.PartType.Block, Vector3.new(0.25, 0.6, 0.2), CFrame.new(0.3 * side, y + 2.3, -1.2), fur)
		piece(Enum.PartType.Ball, Vector3.new(0.22, 0.22, 0.22), CFrame.new(0.25 * side, y + 1.7, -1.8), Color3.new(0.05, 0.05, 0.05))
		for _, front in { -1, 1 } do
			piece(Enum.PartType.Block, Vector3.new(0.35, 0.5, 0.35), CFrame.new(0.55 * side, y + 0.25, 0.75 * front), fur)
		end
	end
	return model
end

function RealityRuntime.startPolymorph(ctx: Ctx, hit: Hit): boolean
	local humanoid = hit.humanoid
	if polys[humanoid] or (polyImmune[humanoid] or 0) > now() then
		return false
	end
	local seconds = byTier(R.polymorph.seconds, ctx.stats.masteryTier)
	local hidden: { [Instance]: number } = {}
	for _, d in hit.model:GetDescendants() do
		-- Body parts, accessories and the face all vanish; the root stays (it carries the critter).
		if (d:IsA("BasePart") and d ~= hit.root) or d:IsA("Decal") then
			local visible = d :: any
			hidden[d] = visible.Transparency
			visible.Transparency = 1
		end
	end
	local body = critter(hit.root, ctx.rng, footOffset(humanoid, hit.root))
	body.Parent = hit.model
	hit.model:SetAttribute(POLY_ATTRIBUTE, true)
	polys[humanoid] = { expires = now() + seconds, model = hit.model, humanoid = humanoid, hidden = hidden, critter = body }
	StatusEffects.apply(humanoid, "reality_polymorphed", { duration = seconds, source = ctx.player.UserId })
	fx("poof", {}, hit.root.Position)
	return true
end

local function endPolymorph(poly: Poly)
	polys[poly.humanoid] = nil
	polyImmune[poly.humanoid] = now() + R.polymorph.immunity
	for instance, value in poly.hidden do
		if instance.Parent then
			(instance :: any).Transparency = value
		end
	end
	poly.critter:Destroy()
	if poly.model.Parent then
		poly.model:SetAttribute(POLY_ATTRIBUTE, nil)
		local root = poly.model:FindFirstChild("HumanoidRootPart")
		if root and root:IsA("BasePart") then
			fx("poof", {}, root.Position)
		end
	end
	if poly.humanoid.Parent then
		StatusEffects.remove(poly.humanoid, "reality_polymorphed")
	end
end

-- ─── Exchange ───────────────────────────────────────────────────────────────

-- Returns false when the trade would gain you nothing (and nothing happens).
function RealityRuntime.exchange(ctx: Ctx, hit: Hit): boolean
	local mine = humanoidOf(ctx.character)
	if not mine then
		return false
	end
	local newMine, newTheirs = Rules.exchange(mine.Health, mine.MaxHealth, hit.humanoid.Health, hit.humanoid.MaxHealth)
	if not newMine or not newTheirs then
		return false
	end
	local userId = ctx.player.UserId
	startCooldown("exchange", userId, byTier(R.exchange.cooldown, ctx.stats.masteryTier))
	local loss = hit.humanoid.Health - newTheirs
	if loss > 0 then
		Damage.apply(hit.humanoid, loss, userId, "exchange", {
			domain = "reality",
			power = ctx.stats.recipe.power,
			branch = ctx.stats.recipe.branch,
			property = "identity",
			pierce = true,
			from = ctx.origin,
		})
	end
	Damage.heal(mine, newMine - mine.Health, userId, { domain = "reality" })
	fx("exchange", { to = hit.root.Position }, ctx.root.Position)
	return true
end

-- ─── Edicts ─────────────────────────────────────────────────────────────────

local function inside(edict: Edict, position: Vector3): boolean
	local c = edict.center
	return Vector3.new(position.X - c.X, 0, position.Z - c.Z).Magnitude <= edict.radius and math.abs(position.Y - c.Y) <= edict.radius
end

local function countWorldlaws(): number
	local n = 0
	for _, e in edicts do
		if e.worldlaw then
			n += 1
		end
	end
	return n
end

function RealityRuntime.edictRefusal(userId: number, worldlaw: boolean): string?
	if worldlaw then
		return Rules.worldlawRefusal(countWorldlaws(), cooldowns.worldlaw[userId] or 0, now())
	end
	return if #edicts >= R.edict.maxActive + R.worldlaw.maxActive then "WORLD_STRAINED" else nil
end

local function endEdict(index: number)
	local edict = table.remove(edicts, index)
	if edict then
		fx("end", { id = edict.id }, edict.center)
	end
end

function RealityRuntime.startEdict(ctx: Ctx, kind: string, worldlaw: boolean)
	local userId = ctx.player.UserId
	local tier = ctx.stats.masteryTier
	-- One edict per caster, and one Worldlaw: a new one replaces the old.
	for i = #edicts, 1, -1 do
		if edicts[i].owner == userId and edicts[i].worldlaw == worldlaw then
			endEdict(i)
		end
	end
	local follow = if ctx.stats.recipe.form == "aura" then ctx.root else nil
	local radius = if worldlaw then byTier(R.worldlaw.radius, tier) else Rules.edictRadius(ctx.stats.area, tier)
	local seconds = if worldlaw then byTier(R.worldlaw.seconds, tier) else byTier(R.edict.seconds, tier)
	local center = if follow then follow.Position else ctx.point
	local edict: Edict = {
		id = newId(),
		kind = kind,
		owner = userId,
		player = ctx.player,
		follow = follow,
		center = center,
		radius = radius,
		expires = now() + seconds,
		nextScan = 0,
		worldlaw = worldlaw,
		mult = byTier(R.edict.reversal, tier),
		maxTargets = if worldlaw then R.worldlaw.maxTargets else R.edict.maxTargets,
	}
	table.insert(edicts, edict)
	if worldlaw then
		startCooldown("worldlaw", userId, R.worldlaw.cooldown)
		log:info("reality_worldlaw", { userId = userId, law = kind, radius = radius, seconds = seconds })
	end
	fx("edict", { id = edict.id, law = kind, radius = radius, duration = seconds, model = if follow then ctx.character else nil }, center, worldlaw)
end

local function scanHush(edict: Edict)
	local ownerModel = edict.player.Character
	local spared: { [Model]: boolean } = {}
	if ownerModel then
		spared[ownerModel] = true
	end
	for _, hit in Targeting.inRadius(edict.center, edict.radius, edict.maxTargets, spared) do
		if inside(edict, hit.root.Position) and Targeting.canHarm(edict.player, hit.model) then
			StatusEffects.apply(hit.humanoid, "silence", { duration = R.edict.scanEvery + 0.4, source = edict.owner })
		end
	end
end

-- ─── Hooks ──────────────────────────────────────────────────────────────────

-- Before Time's interceptor: the laws and luck that decide whether a hit lands at all.
local function before(humanoid: Humanoid, amount: number, source: number?, kind: string, info: Damage.Info?): number
	if kind == "internal" then
		return amount
	end
	local t = now()
	local root = humanoid.RootPart
	local model = humanoid.Parent
	local victim = if model and model:IsA("Model") then Players:GetPlayerFromCharacter(model) else nil

	if root then
		for _, edict in edicts do
			if t < edict.expires and inside(edict, root.Position) then
				if edict.kind == "sanctuary" and source ~= edict.owner then
					tag(humanoid, "sanctuary", "Sanctuary", false, edict.owner)
					return 0
				elseif edict.kind == "reversal" and victim and source ~= edict.owner and (victim.UserId == edict.owner or not PvpRules.allowed(edict.owner, victim.UserId)) then
					Damage.heal(humanoid, amount * edict.mult, edict.owner, { domain = "reality" })
					tag(humanoid, "reversal", "Reversed", false, edict.owner)
					return 0
				end
			end
		end
	end

	-- Everything below answers a direct blow only (it has a direction), never a burn or a poison tick.
	local direct = info ~= nil and info.from ~= nil and not reflecting
	if direct then
		local attacker = attackerOf(source, info)
		local twist = twists[humanoid]
		if twist and attacker and attacker ~= humanoid and live(twist.expires, humanoid, "reality_fated") then
			twist.charges -= 1
			if twist.charges <= 0 then
				twists[humanoid] = nil
				StatusEffects.remove(humanoid, "reality_fated")
			end
			reflecting = true
			local ok, err = pcall(Damage.apply, attacker, amount * twist.reflect, twist.userId, "twist_of_fate", {
				domain = "reality",
				from = if root then root.Position else nil,
				undeferred = true,
			})
			reflecting = false
			if not ok and log then
				log:throttled("reality_twist", 30, "Warn", "reality_twist_failed", { err = err })
			end
			tag(humanoid, "twist", "Twisted", false, twist.userId)
			fx("twist_hit", {}, if root then root.Position else Vector3.zero)
			return 0
		end
		local favor = favors[humanoid]
		if favor and live(favor.expires, humanoid, "reality_favored") and favor.rng:NextNumber() < favor.chance then
			tag(humanoid, "graze", "Grazed", false, source)
			return 0
		end
		local doom = attacker and dooms[attacker]
		if attacker and doom and live(doom.expires, attacker, "reality_doomed") and doom.rng:NextNumber() < doom.chance then
			tag(humanoid, "missed", "Missed", false, source)
			return 0
		end
	end

	local fray = frays[humanoid]
	if fray and live(fray.expires, humanoid, "reality_frayed") then
		amount *= fray.mult
	end
	return amount
end

-- After Time's: Undying caps what's left.
local function after(humanoid: Humanoid, amount: number): number
	if live(undying[humanoid], humanoid, "reality_undying") and amount >= humanoid.Health then
		tag(humanoid, "undying", "Undying", false, nil)
		return Rules.undyingClamp(amount, humanoid.Health)
	end
	return amount
end

local function critBonus(ctx: Ctx, hit: Hit): number
	local t = now()
	local userId = (ctx :: any).player and (ctx :: any).player.UserId
	if userId then
		local list = seals[hit.humanoid]
		local seal = list and list[userId]
		if list and seal and t < seal.expires and seal.left > 0 and StatusEffects.has(hit.humanoid, "reality_sealed") then
			seal.left -= 1
			if seal.left <= 0 then
				list[userId] = nil
			end
			return 1 -- certain
		end
	end
	local bonus = 0
	local attacker = humanoidOf(ctx.character)
	local favor = attacker and favors[attacker]
	if attacker and favor and live(favor.expires, attacker, "reality_favored") then
		bonus += favor.crit
	end
	local doom = dooms[hit.humanoid]
	if doom and live(doom.expires, hit.humanoid, "reality_doomed") then
		bonus += doom.crit
	end
	return bonus
end

local function sever(position: Vector3, flight: Delivery.Flight): boolean
	for _, edict in edicts do
		if edict.kind == "severance" and now() < edict.expires and inside(edict, position) and hostile(flight.ownerModel, edict.owner) then
			fx("severed", {}, position)
			return true
		end
	end
	return false
end

-- ─── Stepping ───────────────────────────────────────────────────────────────

local function stepAll(_dt: number)
	local t = now()

	for humanoid, entry in favors do
		if t >= entry.expires or not humanoid.Parent then
			favors[humanoid] = nil
		end
	end
	for humanoid, entry in dooms do
		if t >= entry.expires or not humanoid.Parent then
			dooms[humanoid] = nil
		end
	end
	for humanoid, list in seals do
		for userId, seal in list do
			if t >= seal.expires then
				list[userId] = nil
			end
		end
		if next(list) == nil or not humanoid.Parent then
			seals[humanoid] = nil
		end
	end
	for humanoid, twist in twists do
		if t >= twist.expires or not humanoid.Parent then
			twists[humanoid] = nil
		end
	end
	for humanoid, expires in undying do
		if t >= expires or not humanoid.Parent then
			undying[humanoid] = nil
		end
	end
	for humanoid, fray in frays do
		if t >= fray.expires or not humanoid.Parent then
			frays[humanoid] = nil
		end
	end

	for humanoid, poly in polys do
		if t >= poly.expires or not poly.model.Parent or humanoid.Health <= 0 or not StatusEffects.has(humanoid, "reality_polymorphed") then
			endPolymorph(poly)
		end
	end

	for i = #edicts, 1, -1 do
		local edict = edicts[i]
		local follow = edict.follow
		if t >= edict.expires or not edict.player.Parent or (follow and not follow.Parent) then
			endEdict(i)
		else
			if follow then
				edict.center = follow.Position
			end
			if edict.kind == "hush" and t >= edict.nextScan then
				edict.nextScan = t + R.edict.scanEvery
				scanHush(edict)
			end
		end
	end

	for part, entry in unmade do
		if t >= entry.expires or not part.Parent then
			restore(part, entry)
		end
	end

	for i = #conjured, 1, -1 do
		local c = conjured[i]
		if t >= c.expires or not c.model.Parent then
			table.remove(conjured, i)
			c.model:Destroy()
		end
	end
end

function RealityRuntime.step(dt: number)
	local ok, err = pcall(stepAll, dt)
	if not ok and log then
		log:throttled("reality_step", 30, "Error", "reality_step_failed", { err = err })
	end
end

-- Dispel ends other people's Reality near a point (EffectRunner.dispelArea). Personal effects end with
-- their statuses, which Dispel already removes. Returns how many.
function RealityRuntime.dispel(position: Vector3, radius: number, owner: number?): number
	local count = 0
	for i = #edicts, 1, -1 do
		local edict = edicts[i]
		if edict.owner ~= owner and (edict.center - position).Magnitude <= radius + edict.radius then
			endEdict(i)
			count += 1
		end
	end
	for part, entry in unmade do
		if entry.owner ~= owner and (part.Position - position).Magnitude <= radius then
			restore(part, entry)
			count += 1
		end
	end
	for i = #conjured, 1, -1 do
		local c = conjured[i]
		if c.owner ~= owner and c.model.Parent and (c.model:GetPivot().Position - position).Magnitude <= radius + 10 then
			table.remove(conjured, i)
			c.model:Destroy()
			count += 1
		end
	end
	return count
end

-- A leaving player's edicts end with them; what they conjured or unmade runs out on its own.
function RealityRuntime.forget(player: Player)
	for i = #edicts, 1, -1 do
		if edicts[i].owner == player.UserId then
			endEdict(i)
		end
	end
end

-- Server shutdown: every edit goes back and every critter goes away.
function RealityRuntime.restoreAll()
	for part, entry in unmade do
		restore(part, entry)
	end
	for _, poly in polys do
		endPolymorph(poly)
	end
	for _, c in conjured do
		c.model:Destroy()
	end
	table.clear(conjured)
end

function RealityRuntime.start(effectRunner: any, logger: any)
	runner, log = effectRunner, logger
	-- Chain: Time (and anything else) keeps its say between our before and after.
	local damageNext = Damage.interceptor
	Damage.interceptor = function(humanoid: Humanoid, amount: number, source: number?, kind: string, info: Damage.Info?): number
		local remaining = before(humanoid, amount, source, kind, info)
		if remaining <= 0 then
			return 0
		end
		if damageNext then
			remaining = damageNext(humanoid, remaining, source, kind, info)
			if remaining <= 0 then
				return 0
			end
		end
		return after(humanoid, remaining)
	end
	local flightNext = Delivery.interceptor
	Delivery.interceptor = function(position: Vector3, velocity: Vector3, flight: Delivery.Flight): (string?, any)
		if next(edicts) ~= nil and sever(position, flight) then
			return "erase", nil
		end
		if flightNext then
			return flightNext(position, velocity, flight)
		end
		return nil, nil
	end
	DamageModel.critBonus = critBonus
end

function RealityRuntime.report(): string
	local function count(t: { [any]: any }): number
		local n = 0
		for _ in t do
			n += 1
		end
		return n
	end
	return string.format(
		"favors %d · dooms %d · sealed %d · twists %d · undying %d · frayed %d · polymorphs %d · edicts %d (worldlaws %d) · unmade parts %d · conjured %d",
		count(favors), count(dooms), count(seals), count(twists), count(undying), count(frays), count(polys), #edicts, countWorldlaws(), unmadeCount, #conjured
	)
end

-- Exposed for specs.
RealityRuntime.polyAttribute = POLY_ATTRIBUTE
RealityRuntime.before = before
RealityRuntime.after = after

return RealityRuntime
