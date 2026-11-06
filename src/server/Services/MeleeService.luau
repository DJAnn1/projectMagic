--!strict
--[[
	MeleeService: the spellblade, Slash1 -> Slash2 with the attuned spell's edge (docs/Combat.md
	§13). Numbers in Shared/Magic/Data/MeleeTuning; timing rules in Shared/Magic/Melee.

	MeleeIntent()   reliable event, no arguments, rate 4 burst / 4 per s. The client never says
	                what it hit. Gates: equip mode with a spell attuned, alive, the body free to
	                slash (Cast/ActionState: not mid-cast, guarding, charging, staggered), the
	                combo window (a press before it is refused: TOO_EARLY), the swing's reservoir
	                cost. Then the "slashing" action state (Slash1, or Slash2 as the variant).
	HITS            timed on the server's clock from when the swing arrived: `samples` box sweeps
	                between hitFrom and hitTo (GetPartBoundsInBox in front of the chest, turning
	                with the body), each character once per swing, never through walls, other
	                players only with pvp_enabled. If the swing is cancelled (block, dash, cast,
	                a stagger) its remaining sweeps do nothing.
	DAMAGE          Cast/DamageModel at the swing's share of the attuned spell's power (x the
	                focus bonus), plus the weapon's flat damage, through Cast/Damage as a "touch"
	                from the attacker: guards block it and a parry staggers the attacker.
	                Slash2 knocks back. A hit may carry the domain's status (statusChance, seeded).
	FINISHER        Slash2 landing opens finisherWindow (Cast/Finisher): CastService's next client
	                cast in it gets x finisherPower.
	XP              a swing that hits awards practice XP to the attuned branch at xpShare of the
	                spell's cast (the anti-grind rules in Progression apply as for casts).
	MeleeResult     to the attacker: { ok = false, reason } refusals, { hit = true, swing } on the
	                first connection (the client's hit-stop).
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local MagicCore = require(Shared.Magic.MagicCore)
local Seed = require(Shared.Magic.Seed)
local Aim = require(Shared.Magic.Aim)
local Melee = require(Shared.Magic.Melee)
local ActionRules = require(Shared.Magic.ActionRules)
local ItemDatabase = require(Shared.Items.ItemDatabase)

local Cast = script.Parent.Parent.Magic.Cast
local ActionState = require(Cast.ActionState)
local DamageModel = require(Cast.DamageModel)
local Damage = require(Cast.Damage)
local Targeting = require(Cast.Targeting)
local StatusEffects = require(Cast.StatusEffects)
local Finisher = require(Cast.Finisher)

local D = Melee.data

local MeleeService = {
	name = "MeleeService",
	dependencies = {
		"NetService",
		"PlayerDataService",
		"AttunementService",
		"ReservoirService",
		"InventoryService",
		"ProgressionService",
		"WorldService",
	},
}

type Swinging = { index: number, startedAt: number, speed: number, seq: number }

local log: any = nil
local playerData: any = nil
local attunement: any = nil
local reservoirs: any = nil
local inventory: any = nil
local progression: any = nil
local worldService: any = nil

local swings: { [Player]: Swinging } = {}
local counters: { [Player]: number } = {} -- seeds each swing's rolls

local function now(): number
	return workspace:GetServerTimeNow()
end

local function refuse(player: Player, reason: string)
	Net.fire("MeleeResult", player, { ok = false, reason = reason })
end

-- The main-hand item's bonus, plus the sheet's attack stats.
local function bonusOf(player: Player): Melee.Bonus
	local inv = inventory:inventoryOf(player)
	local rec = inv and inv.equip and inv.equip.mainHand
	local def = rec and ItemDatabase.get(rec.i)
	local sheet = inventory:sheet(player)
	local final = sheet and sheet.final or {}
	return Melee.weaponBonus(def, final.attackPower, final.attackSpeedPct)
end

-- Somebody struck by this swing: damage, status, knockback. Returns true if it connected.
local function strikeOne(player: Player, character: Model, root: BasePart, stats: any, swing: any, bonus: Melee.Bonus, rng: Random, hit: any): boolean
	local ctx: any = {
		player = player,
		character = character,
		root = root,
		stats = stats,
		power = stats.power * bonus.powerMult,
		origin = root.Position,
		point = hit.root.Position,
		rng = rng,
	}
	local result = DamageModel.compute(ctx, hit, swing.share, { noFalloff = true })
	local dealt = Damage.apply(hit.humanoid, result.amount + bonus.flat, player.UserId, stats.recipe.property, {
		domain = stats.domains[1],
		crit = result.crit,
		power = stats.recipe.power,
		from = root.Position,
		property = stats.recipe.property,
		pierce = false,
		form = "touch", -- a blade is contact: a parry staggers the attacker
		attacker = character,
		branch = stats.recipe.branch,
	})
	if dealt <= 0 then
		return false -- parried, warded away, or quest-protected
	end
	-- The domain's touch, briefly.
	local touch = D.status[stats.domains[1]]
	if touch and rng:NextNumber() < D.statusChance then
		StatusEffects.apply(hit.humanoid, touch.id, {
			duration = touch.duration,
			magnitude = (touch.magnitudePerPower or 0) * stats.recipe.power,
			source = player.UserId,
		})
	end
	if swing.knockback > 0 then
		local away = hit.root.Position - root.Position
		local flat = Vector3.new(away.X, 0, away.Z)
		local push = (if flat.Magnitude > 0.1 then flat.Unit else root.CFrame.LookVector) * swing.knockback + Vector3.new(0, 8, 0)
		local victim = Players:GetPlayerFromCharacter(hit.model)
		if victim then
			Net.fire("WorldEffect", victim, { kind = "knockback", velocity = push })
		elseif not hit.root.Anchored then
			hit.root.AssemblyLinearVelocity += push
		end
	end
	return true
end

-- Sweeps the swing's box over its active frames and resolves each character once.
local function resolveSwing(player: Player, character: Model, seq: number, index: number, speed: number, stats: any, bonus: Melee.Bonus)
	local swing = Melee.swing(index)
	local struck: { [Model]: boolean } = { [character] = true }
	local counter = (counters[player] or 0) + 1
	counters[player] = counter
	local rng = Seed.random(worldService:getSeed(), "player:" .. player.UserId, "melee", counter)
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.MaxParts = 60
	local excluded: { Instance } = { character }
	local fx = workspace:FindFirstChild("MagicFx")
	if fx then
		table.insert(excluded, fx)
	end
	params.FilterDescendantsInstances = excluded
	local reach = swing.reach + bonus.reach
	local anyHit = false
	local start = swing.hitFrom / speed
	local span = (swing.hitTo - swing.hitFrom) / speed
	local elapsed = 0
	for i = 1, D.samples do
		local at = start + span * (i - 1) / math.max(1, D.samples - 1)
		task.wait(math.max(0, at - elapsed))
		elapsed = at
		-- Cancelled (a block, dash, cast or stagger took over): the rest of the swing never lands.
		local snapshot = ActionRules.read(character)
		if snapshot.seq ~= seq or snapshot.state ~= "slashing" or not character.Parent then
			break
		end
		local root = character:FindFirstChild("HumanoidRootPart")
		if not root or not root:IsA("BasePart") then
			break
		end
		local box = root.CFrame * CFrame.new(0, 0.5, -(reach / 2 + 0.5))
		local chest = Aim.muzzle(root.Position)
		for _, part in workspace:GetPartBoundsInBox(box, Vector3.new(swing.width, swing.height, reach), params) do
			local hit = Targeting.characterOf(part)
			if hit and not struck[hit.model] then
				struck[hit.model] = true
				if
					Targeting.canHarm(player, hit.model)
					and Aim.lineOfSight(chest, hit.root.Position, { character, hit.model }, 1)
					and strikeOne(player, character, root, stats, swing, bonus, rng, hit)
				then
					if not anyHit then
						anyHit = true
						Net.fire("MeleeResult", player, { ok = true, hit = true, swing = index })
					end
				end
			end
		end
	end
	if anyHit then
		if index == #D.swings then
			Finisher.open(player, D.finisherWindow, D.finisherPower)
		end
		-- Practice XP at a share of the spell's cast.
		local xpStats = table.clone(stats)
		xpStats.cost = stats.cost * D.xpShare
		progression:awardPractice(player, xpStats, { effective = true })
	end
end

local function onIntent(player: Player)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return
	end
	if not attunement:equipMode(player) then
		refuse(player, "QUICK_MODE")
		return
	end
	local recipe = attunement:attunedRecipe(player)
	local state = playerData:get(player)
	if not recipe or not state then
		refuse(player, "NOT_ATTUNED")
		return
	end
	local free, action = ActionState.can(character, "slash")
	if not free then
		refuse(player, if action == "staggered" then "STAGGERED" else "BUSY")
		return
	end
	local t = now()
	local current = swings[player]
	local bonus = bonusOf(player)
	local index, wait = Melee.nextIndex(if current then current.index else nil, if current then t - current.startedAt else 0, if current then current.speed else bonus.speed)
	if not index then
		refuse(player, "TOO_EARLY")
		log:debug("melee_too_early", { userId = player.UserId, wait = wait })
		return
	end
	local stats = MagicCore.computeStats(recipe, state.caster, nil)
	local reservoir = reservoirs:get(player)
	if not stats or not reservoir then
		return
	end
	local cost = D.costBase + D.costShare * stats.costBreakdown.reservoir
	if not reservoir.infinite then
		if reservoir.current < cost then
			refuse(player, "INSUFFICIENT_RESERVOIR")
			return
		end
		reservoir.current -= cost
		reservoirs:push(player)
	end

	-- The blade is contact: resolve it as a touch (guards, parries), keeping the spell's power.
	local melee = table.clone(stats)
	melee.recipe = table.clone(stats.recipe)
	melee.recipe.form = "touch"

	local swing = Melee.swing(index)
	player:SetAttribute("MeleeSpeed", bonus.speed) -- the client times its combo window with it
	ActionState.set(character, "slashing", {
		duration = swing.duration / bonus.speed,
		variant = swing.clip,
		domain = stats.domains[1],
	})
	local seq = ActionRules.read(character).seq
	swings[player] = { index = index, startedAt = t, speed = bonus.speed, seq = seq }
	task.spawn(resolveSwing, player, character, seq, index, bonus.speed, melee, bonus)
end

function MeleeService.init(_self: any, ctx: any)
	log = ctx.log
	playerData = ctx.get("PlayerDataService")
	attunement = ctx.get("AttunementService")
	reservoirs = ctx.get("ReservoirService")
	inventory = ctx.get("InventoryService")
	progression = ctx.get("ProgressionService")
	worldService = ctx.get("WorldService")
	Net.on("MeleeIntent", onIntent :: any)
end

function MeleeService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		swings[player] = nil
		counters[player] = nil
	end)
end

return MeleeService
