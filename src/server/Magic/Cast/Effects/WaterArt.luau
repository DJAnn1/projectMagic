--!strict
--[[
	WaterArt: Water's own spells (docs/DomainIdeas.md, "Water"). Ordinary moves that fit their branch,
	each reached by a narrow route in Data/EffectLibrary ("water_" .. move, with params.move). Numbers:
	Data/WaterTuning. Anything that lasts runs in Cast/ArtRuntime; looks in Client/Fx/WaterFx (cue kind
	"water", bodies drawn through Fx/ArtFx).

	Hydromancy, Hydrostatics
		water_whip     a whip of water lashes an arc and pulls whoever it catches a step toward you
		pressure_jet   a cutting jet of water that hurts and shoves everyone along it
		bubble         the target is caught in a floating bubble for a moment
		geyser         water blasts up out of the ground where you aim (a moment's warning), throwing people high
		mire           water in an area thickens to sludge: everyone in it is slowed
	Tidal
		wave_surge     a short wave rolls forward from you, carrying people along with it
		whirlpool      water spins in an area, pulling people round and in
		riptide        a current drags your target toward you
	Glaciation, Permafrost
		ice_slide      a strip of ice: allies on it run fast, foes may fall
		permafrost     feet freeze to the ground again and again in an area
		icicle_rain    icicles fall on marked spots
		ice_dome       a ring of ice walls rises round you and blocks bolts
	Vapor, Fogweaving
		scald          a burst of scalding steam that burns and blinds
		fog_bank       thick fog: your allies inside are hidden from anyone outside
		cloud_step     a cloud under your feet holds you up for a few seconds, even in mid-air
	Purification, Wellspring
		cleansing_rain a short rain that washes bad statuses off allies and heals them a little
		water_shield   water wraps you: a ward, and it puts out any fire on you while it lasts
		fountain       water springs up where you aim: fires around it go out, allies in it stop burning

	A backfire lands on the caster as any harmful spell's does (Effects/Impact).
]]

local Shared = game:GetService("ReplicatedStorage").Shared
local FeatureFlags = require(Shared.Core.FeatureFlags)
local Types = require(Shared.Magic.Types)
local E = require(Shared.Magic.Data.WaterTuning)

local Cast = script.Parent.Parent
local CastTypes = require(Cast.CastTypes)
local Damage = require(Cast.Damage)
local DamageModel = require(Cast.DamageModel)
local FireSim = require(Cast.FireSim)
local PropertyBehaviour = require(Cast.PropertyBehaviour)
local Resistances = require(Cast.Resistances)
local StatusEffects = require(Cast.StatusEffects)
local Targeting = require(Cast.Targeting)
local R = require(Cast.ArtRuntime)

type Ctx = CastTypes.EffectContext
type Outcome = CastTypes.Outcome
type Hit = Targeting.Hit

local UP = Vector3.new(0, 1, 0)
local L = E.looks

local flat, aimDir, ground, foesStruck, isPlayer, cone = R.flat, R.aimDir, R.ground, R.foesStruck, R.isPlayer, R.cone

-- What Cleansing Rain washes off: every harmful status that isn't a hold someone else is keeping.
local WASHES = { "poison", "rot", "hexed", "burning", "slow", "blind", "dazed", "jinxed", "chilled", "irradiated", "crumbling", "soulmarked", "withering", "aged", "sapped", "suffocating", "fear" }

local WaterArt = {}

function WaterArt.precheck(_params: { [string]: any }, _stats: Types.SpellStats, _player: Player): string?
	if FeatureFlags.get("water_arts_enabled") == false then
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
	R.cue(ctx, fields, position, heavy, "water")
end

-- Allies and the caster: who helpful water reaches.
local function friendsAround(ctx: Ctx, center: Vector3, radius: number): { Hit }
	local out: { Hit } = {}
	for _, hit in Targeting.inRadius(center, radius, 12) do
		if hit.model == ctx.character or (Targeting.canHelp(ctx.player, hit.model) and not Targeting.canHarm(ctx.player, hit.model)) then
			table.insert(out, hit)
		end
	end
	return out
end

-- ─── Hydromancy, Hydrostatics ───────────────────────────────────────────────

local function waterWhip(ctx: Ctx): Outcome
	local T = E.water_whip
	local reach = at(T.reach, ctx)
	local hits = 0
	for _, hit in cone(ctx, reach, T.arc, T.maxTargets) do
		if R.hit(ctx, hit, T.share, "flow") > 0 then
			R.push(hit, flat(ctx.origin - hit.root.Position) * T.pull + UP * 6)
			hits += 1
		end
	end
	cue(ctx, { fx = "whip", from = ctx.origin, dir = aimDir(ctx), reach = reach, arc = T.arc }, ctx.origin)
	return { effective = hits > 0, hits = hits, note = if hits == 0 then "The water cracks on empty air." else nil }
end

local function pressureJet(ctx: Ctx): Outcome
	local T = E.pressure_jet
	local dir = aimDir(ctx)
	local from = ctx.origin + UP * 1.5
	local to = from + dir * at(T.length, ctx)
	local hits = 0
	for _, hit in Targeting.alongBeam(from, to, T.width, T.maxTargets, { ctx.character }) do
		if Targeting.canHarm(ctx.player, hit.model) then
			R.hit(ctx, hit, T.share)
			R.push(hit, dir * T.push + UP * 8)
			hits += 1
		end
	end
	cue(ctx, { fx = "jet", from = from, to = to }, from)
	return { effective = hits > 0, hits = hits }
end

local function bubble(ctx: Ctx): Outcome
	local T = E.bubble
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0, note = "The bubble drifts off empty." }
	end
	local seconds = at(T.seconds, ctx)
	R.hit(ctx, target, T.share)
	if isPlayer(target) then
		seconds = math.min(seconds, T.pvpSeconds)
		R.push(target, UP * 26)
	elseif not target.root.Anchored then
		target.model:PivotTo(target.model:GetPivot() + UP * T.lift)
	end
	R.status(ctx, target.humanoid, "stasis", seconds)
	cue(ctx, { fx = "bubble", model = target.model, seconds = seconds }, target.root.Position)
	return { effective = true, hits = 1 }
end

local function geyser(ctx: Ctx): Outcome
	local T = E.geyser
	local radius = at(T.radius, ctx)
	local spot = ground(ctx.point)
	cue(ctx, { fx = "geyser_warn", at = spot, radius = radius, delay = T.warn }, spot, true)
	local c = R.later(ctx)
	task.delay(T.warn, function()
		if not R.alive(c) then
			return
		end
		cue(c, { fx = "geyser", at = spot, radius = radius }, spot, true)
		for _, hit in R.foesAround(c, spot, radius) do
			R.hit(c, hit, T.share)
			R.push(hit, UP * at(T.lift, c))
		end
		FireSim.extinguish(spot, radius + 2)
	end)
	return { effective = true, hits = 0 }
end

local function mire(ctx: Ctx): Outcome
	local T = E.mire
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 15))
	R.spawn({
		look = "mire",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "slow", T.every + 0.4)
			end
		end,
	})
	return { effective = true, hits = 0, note = "The water thickens to sludge. Anyone in it wades." }
end

-- ─── Tidal ──────────────────────────────────────────────────────────────────

local function waveSurge(ctx: Ctx): Outcome
	local T = E.wave_surge
	local dir = aimDir(ctx)
	local width = at(T.width, ctx)
	local distance = at(T.distance, ctx)
	local right = dir:Cross(UP).Unit
	local start = ground(ctx.origin + dir * 3)
	R.spawn({
		look = "wave_surge",
		ctx = ctx,
		position = start,
		radius = width / 2,
		seconds = distance / T.speed,
		attrs = { DirX = dir.X, DirZ = dir.Z, Width = width },
		data = { struck = {} },
		move = function(body, dt)
			local nextPos = body.position + dir * (T.speed * dt)
			R.place(body, Vector3.new(nextPos.X, ground(nextPos).Y, nextPos.Z))
			for _, hit in R.foesAround(body.ctx, body.position, width / 2 + 3) do
				local rel = hit.root.Position - body.position
				if math.abs(rel:Dot(right)) <= width / 2 and math.abs(rel:Dot(dir)) <= 3 and not body.data.struck[hit.model] then
					-- Once each: hurt and carried off along the wave's way (one push, not one a frame).
					body.data.struck[hit.model] = true
					R.hit(body.ctx, hit, T.share)
					R.push(hit, dir * T.carry + UP * 10)
				end
			end
			FireSim.extinguish(body.position, width / 2)
		end,
	})
	return { effective = true, hits = 0 }
end

local function whirlpool(ctx: Ctx): Outcome
	local T = E.whirlpool
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 16))
	R.spawn({
		look = "whirlpool",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				local inward = flat(body.position - hit.root.Position)
				local around = inward:Cross(UP)
				R.push(hit, inward * T.pull + around * T.swirl)
				R.hit(body.ctx, hit, T.share)
			end
		end,
	})
	return { effective = true, hits = 0 }
end

local function riptide(ctx: Ctx): Outcome
	local T = E.riptide
	local target = foesStruck(ctx, 1)[1]
	if not target then
		return { effective = false, hits = 0, note = "The current finds nobody to take." }
	end
	R.hit(ctx, target, T.share, "flow")
	R.push(target, flat(ctx.origin - target.root.Position) * T.pull + UP * 8)
	cue(ctx, { fx = "riptide", from = target.root.Position, to = ctx.origin }, target.root.Position)
	return { effective = true, hits = 1 }
end

-- ─── Glaciation, Permafrost ─────────────────────────────────────────────────

local function iceSlide(ctx: Ctx): Outcome
	local T = E.ice_slide
	local dir = aimDir(ctx)
	local length = at(T.length, ctx)
	local a = ground(ctx.origin)
	local b = a + dir * length
	local center = (a + b) / 2
	local right = dir:Cross(UP).Unit
	R.spawn({
		look = "ice_slide",
		ctx = ctx,
		position = center,
		radius = length / 2,
		seconds = at(T.seconds, ctx),
		every = T.every,
		cframe = CFrame.fromMatrix(center + UP * 0.1, right, UP),
		size = Vector3.new(T.width, 0.2, length),
		data = { slipped = {} },
		tick = function(body)
			local now = os.clock()
			for _, hit in Targeting.inRadius(center, length / 2 + T.width, 12) do
				local rel = hit.root.Position - a
				local along = rel:Dot(dir)
				local off = math.abs(rel:Dot(right))
				if along >= 0 and along <= length and off <= T.width / 2 + 0.5 and math.abs(rel.Y) < 6 then
					if hit.model == body.ctx.character or (Targeting.canHelp(body.ctx.player, hit.model) and not Targeting.canHarm(body.ctx.player, hit.model)) then
						R.status(body.ctx, hit.humanoid, "haste", T.hasteSeconds)
					elseif Targeting.canHarm(body.ctx.player, hit.model) and (body.data.slipped[hit.model] or 0) <= now and body.ctx.rng:NextNumber() < T.slipChance then
						body.data.slipped[hit.model] = now + T.slipGap
						R.status(body.ctx, hit.humanoid, "knockdown", 1.2)
					end
				end
			end
		end,
	})
	return { effective = true, hits = 0, note = "A strip of ice runs out ahead of you. Your friends fly along it; others slip." }
end

local function permafrost(ctx: Ctx): Outcome
	local T = E.permafrost
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 15))
	R.spawn({
		look = "permafrost",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in R.foesAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "root", T.rootSeconds)
				PropertyBehaviour.applyControl(body.ctx, hit, "cold")
			end
		end,
	})
	return { effective = true, hits = 0, note = "The ground freezes hard. Feet keep sticking to it." }
end

local function icicleRain(ctx: Ctx): Outcome
	local T = E.icicle_rain
	local radius = at(T.radius, ctx)
	local spots: { Vector3 } = {}
	for i = 1, math.floor(at(T.icicles, ctx)) do
		local angle = ctx.rng:NextNumber() * math.pi * 2
		local reach = if i == 1 then 0 else math.sqrt(ctx.rng:NextNumber()) * radius
		table.insert(spots, ground(ctx.point + Vector3.new(math.cos(angle) * reach, 0, math.sin(angle) * reach)))
	end
	cue(ctx, { fx = "icicles_warn", spots = spots, delay = T.warn, radius = T.hitRadius }, ctx.point, true)
	local c = R.later(ctx)
	task.delay(T.warn, function()
		if not R.alive(c) then
			return
		end
		cue(c, { fx = "icicles", spots = spots }, c.point, true)
		for i, spot in spots do
			task.delay((i - 1) * 0.05, function()
				for _, hit in R.foesAround(c, spot, T.hitRadius) do
					R.hit(c, hit, T.share, "cold")
				end
			end)
		end
	end)
	return { effective = true, hits = 0 }
end

local function iceDome(ctx: Ctx): Outcome
	local T = E.ice_dome
	local radius = at(T.radius, ctx)
	local seconds = at(T.seconds, ctx)
	local center = ground(ctx.origin)
	local panelWidth = 2 * math.pi * radius / T.panels * 1.08
	local raised = 0
	for i = 1, T.panels do
		local angle = (i - 0.5) / T.panels * math.pi * 2
		local out = Vector3.new(math.cos(angle), 0, math.sin(angle))
		local base = center + out * radius
		-- Leaning in a little at the top, so the ring reads as a dome.
		local frame = CFrame.lookAt(base + UP * (T.height / 2), base + UP * (T.height / 2) + out) * CFrame.Angles(math.rad(-14), 0, 0)
		if R.solid({
			Size = Vector3.new(panelWidth, T.height, 0.8),
			CFrame = frame,
			Material = Enum.Material.Ice,
			Color = L.ice,
			Transparency = 0.35,
		}, seconds) then
			raised += 1
		end
	end
	cue(ctx, { fx = "dome", at = center, radius = radius }, center, true)
	return { effective = raised > 0, hits = 0, note = if raised > 0 then "Walls of ice close round you." else "The ice won't come here." }
end

-- ─── Vapor, Fogweaving ──────────────────────────────────────────────────────

local function scald(ctx: Ctx): Outcome
	local T = E.scald
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 14))
	local hits = 0
	for _, hit in R.foesAround(ctx, ctx.point, radius) do
		if R.hit(ctx, hit, T.share, "heat", {}) > 0 then
			R.status(ctx, hit.humanoid, "blind", T.blindSeconds)
			hits += 1
		end
	end
	cue(ctx, { fx = "steam", at = ctx.point, radius = radius }, ctx.point, true)
	return { effective = true, hits = hits }
end

local function fogBank(ctx: Ctx): Outcome
	local T = E.fog_bank
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 22))
	R.spawn({
		look = "fog_bank",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in friendsAround(body.ctx, body.position, body.radius) do
				R.status(body.ctx, hit.humanoid, "veiled", T.veilSeconds)
			end
		end,
	})
	return { effective = true, hits = 0, note = "Fog rolls in. Anyone on your side inside it is hidden from outside." }
end

local function cloudStep(ctx: Ctx): Outcome
	local T = E.cloud_step
	local feet = ctx.root.Position - UP * 3.3
	local cloud = R.solid({
		Size = Vector3.new(T.size, 0.6, T.size),
		CFrame = CFrame.new(feet),
		Material = Enum.Material.SmoothPlastic,
		Color = L.cloud,
		Transparency = 0.3,
	}, at(T.seconds, ctx))
	if not cloud then
		return { effective = false, hits = 0, note = "The air won't hold a cloud here." }
	end
	cloud.CanCollide = true -- it forms under your feet, never round you
	cue(ctx, { fx = "cloud", at = feet, size = T.size, seconds = at(T.seconds, ctx) }, feet)
	return { effective = true, hits = 0 }
end

-- ─── Purification, Wellspring ───────────────────────────────────────────────

local function cleansingRain(ctx: Ctx): Outcome
	local T = E.cleansing_rain
	local radius = math.max(at(T.radius, ctx), math.min(ctx.stats.area, 16))
	R.spawn({
		look = "cleansing_rain",
		ctx = ctx,
		position = ground(ctx.point),
		radius = radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			for _, hit in friendsAround(body.ctx, body.position, body.radius) do
				StatusEffects.cleanse(hit.humanoid, WASHES)
				Damage.heal(hit.humanoid, DamageModel.base(body.ctx.power) * T.heal, body.owner, { domain = "water" })
			end
			FireSim.extinguish(body.position, body.radius)
		end,
	})
	return { effective = true, hits = 0, note = "A soft rain falls. It washes your friends clean." }
end

local function waterShield(ctx: Ctx): Outcome
	local T = E.water_shield
	local humanoid = ctx.character:FindFirstChildOfClass("Humanoid")
	if not humanoid then
		return { effective = false, hits = 0 }
	end
	local seconds = at(T.seconds, ctx)
	StatusEffects.apply(humanoid, "ward", {
		duration = seconds,
		magnitude = DamageModel.base(ctx.power) * 2,
		source = ctx.player.UserId,
		resist = Resistances.wardFor(ctx.stats.recipe.power),
	})
	StatusEffects.cleanse(humanoid, { "burning" })
	for _, body in R.bodiesOf(ctx.player.UserId, "water_shield") do
		R.endBody(body)
	end
	local character = ctx.character
	R.spawn({
		look = "water_shield",
		ctx = ctx,
		position = ctx.origin,
		radius = 3,
		seconds = seconds,
		every = T.every,
		links = { Model = character },
		move = function(body, _dt)
			local root = character:FindFirstChild("HumanoidRootPart")
			if root and root:IsA("BasePart") then
				R.place(body, root.Position)
			end
		end,
		tick = function(body)
			StatusEffects.cleanse(humanoid, { "burning" })
			FireSim.extinguish(body.position, 3)
		end,
	})
	return { effective = true, hits = 0, note = "Water wraps you. Fire can't take hold while it lasts." }
end

local function fountain(ctx: Ctx): Outcome
	local T = E.fountain
	local spot = ground(ctx.point)
	FireSim.extinguish(spot, T.radius)
	R.spawn({
		look = "fountain",
		ctx = ctx,
		position = spot,
		radius = T.radius,
		seconds = at(T.seconds, ctx),
		every = T.every,
		tick = function(body)
			FireSim.extinguish(body.position, T.radius)
			for _, hit in Targeting.inRadius(body.position, T.radius, 12) do
				StatusEffects.cleanse(hit.humanoid, { "burning" })
			end
		end,
	})
	return { effective = true, hits = 0, note = "Water springs up where you point. Nothing near it will burn." }
end

-- ─── Dispatch ───────────────────────────────────────────────────────────────

local MOVES: { [string]: (Ctx) -> Outcome } = {
	water_whip = waterWhip,
	pressure_jet = pressureJet,
	bubble = bubble,
	geyser = geyser,
	mire = mire,
	wave_surge = waveSurge,
	whirlpool = whirlpool,
	riptide = riptide,
	ice_slide = iceSlide,
	permafrost = permafrost,
	icicle_rain = icicleRain,
	ice_dome = iceDome,
	scald = scald,
	fog_bank = fogBank,
	cloud_step = cloudStep,
	cleansing_rain = cleansingRain,
	water_shield = waterShield,
	fountain = fountain,
}
WaterArt.moves = MOVES

function WaterArt.resolve(ctx: Ctx, params: { [string]: any }): Outcome
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

return WaterArt
