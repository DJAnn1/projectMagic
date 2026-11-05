--!strict
--[[
	WeaponService: fighting with item weapons (docs/Items.md §10). Numbers in
	Shared/Items/Data/WeaponTuning; maths in Shared/Items/WeaponRules.

	WeaponIntent(op, aim?)   reliable event, rate 6 burst / 5 per s. The client never says what it
	                         hit or how hard: it sends an op and where it's aiming.
		swing     a melee weapon in the main hand (sword, axe, spear, dagger, staff)
		draw      a bow: start drawing (timed on the server's clock from when this arrives)
		release   a bow: loose the drawn arrow; a crossbow or bandolier: shoot now
		cancel    lower a drawn bow without shooting
	GATES (every op)  alive; no spell attuned (with a spell readied, left click casts it and F is
	                  the spellblade: Services/MeleeService); the main-hand item is the right kind
	                  of weapon and not broken; the body free to act (Cast/ActionState); stamina for
	                  the attack (StaminaService: "TIRED"); ranged: the reload elapsed, ammo in the
	                  grid ("NO_AMMO"), a draw of at least drawMin ("UNDERDRAWN").
	MELEE    the "slashing" state with the swing's clip; `samples` box sweeps between hitFrom and
	         hitTo (each character once per swing, never through walls), cancelled by a block, a
	         dash, a cast or a stagger. The combo (WeaponRules.nextIndex) is timed by the weapon's
	         speed; the client times its own window with the WeaponSpeed attribute.
	RANGED   ammo is taken atomically (InventoryService:transact) before the shot flies. The
	         projectile is a real server flight (Cast/Delivery: gravity, walls, guards can parry it
	         back); clients draw it from a "weapon" WorldEffect cue (Fx/WeaponFx).
	HITS     WeaponRules.baseHit x crit (seeded per attack: Seed.random(worldSeed, "player:<id>",
	         "weapon", counter)) x (1 - resistance to the damage type) x (1 - the victim's
	         defense reduction, players) -> capped like spells (maxHit, pvpMaxShare) -> Cast/Damage
	         as form "touch" (melee: guards block, a parry staggers the attacker) or "projectile".
	         Other players only with pvp_enabled (Targeting.canHarm). NPCs learn who hit them the
	         same way as for spells (Damage.onDamage).
	WEAR     the weapon loses 1 durability every `wearEvery` hits.
	WeaponResult  to the attacker: { ok = false, reason } | { ok = true, hit = true } on the first
	         connection (hit-stop) | { ok = true, fired = true, ammo = n } after a shot.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local Net = require(Shared.Net)
local Seed = require(Shared.Magic.Seed)
local Aim = require(Shared.Magic.Aim)
local ActionRules = require(Shared.Magic.ActionRules)
local ItemTypes = require(Shared.Items.ItemTypes)
local ItemDatabase = require(Shared.Items.ItemDatabase)
local ItemInstance = require(Shared.Items.ItemInstance)
local WeaponRules = require(Shared.Items.WeaponRules)

local Server = script.Parent.Parent
local Inventory = require(Server.Items.Inventory)
local Cast = Server.Magic.Cast
local C = require(Server.Magic.Data.CombatTuning)
local CastTypes = require(Cast.CastTypes)
local ActionState = require(Cast.ActionState)
local Damage = require(Cast.Damage)
local Delivery = require(Cast.Delivery)
local Resistances = require(Cast.Resistances)
local Targeting = require(Cast.Targeting)

local W = WeaponRules.data
local H = W.hits

local WeaponService = {
	name = "WeaponService",
	dependencies = { "NetService", "InventoryService", "StaminaService", "AttunementService", "WorldService", "EffectRunner" },
}

type Hit = CastTypes.Hit

type PlayerState = {
	combo: { index: number, startedAt: number, speed: number }?,
	drawStart: number?,
	drawSeq: number?,
	readyAt: number,
	counter: number,
	hits: number,
}

local log: any = nil
local inventory: any = nil
local stamina: any = nil
local attunement: any = nil
local worldService: any = nil
local runner: any = nil

local states: { [Player]: PlayerState } = {}

local function now(): number
	return workspace:GetServerTimeNow()
end

local function stateOf(player: Player): PlayerState
	local s = states[player]
	if not s then
		s = { readyAt = 0, counter = 0, hits = 0 }
		states[player] = s
	end
	return s
end

local function refuse(player: Player, reason: string)
	log:debug("weapon_refused", { userId = player.UserId, reason = reason })
	Net.fire("WeaponResult", player, { ok = false, reason = reason })
end

-- The main-hand weapon and how it fights.
local function weaponOf(player: Player): (ItemTypes.Record?, ItemTypes.ItemDef?, string?, any)
	local inv = inventory:inventoryOf(player)
	local rec = inv and inv.equip and inv.equip.mainHand
	local def = rec and ItemDatabase.get(rec.i)
	local class, kind = WeaponRules.classify(def)
	return rec, def, class, kind
end

local function finalStats(player: Player): { [string]: number }
	local sheet = inventory:sheet(player)
	return sheet and sheet.final or {}
end

local function nextRng(player: Player, s: PlayerState): Random
	s.counter += 1
	return Seed.random(worldService:getSeed(), "player:" .. player.UserId, "weapon", s.counter)
end

-- One weapon hit on one character. Returns true if any damage landed.
local function strikeOne(player: Player, character: Model, hit: Hit, weapon: ItemTypes.WeaponDef, share: number, critBonus: number, rng: Random, form: string, from: Vector3): boolean
	local final = finalStats(player)
	local amount = WeaponRules.baseHit(weapon, final.attackPower, share)
	local crit = rng:NextNumber() < math.min(0.5, H.critBase + critBonus + (final.critChancePct or 0))
	if crit then
		amount *= H.critMult
	end
	-- Resistances keyed by the damage type (gear, wards, NPC traits) apply as for spells.
	amount *= 1 - Resistances.total(hit.humanoid, {}, weapon.damageType)
	local victim = Players:GetPlayerFromCharacter(hit.model)
	if victim then
		local victimSheet = inventory:sheet(victim)
		local defense = victimSheet and victimSheet.final.defense or 0
		amount *= 1 - WeaponRules.defenseReduction(defense)
		amount = math.min(amount, hit.humanoid.MaxHealth * C.damage.pvpMaxShare)
	end
	amount = math.clamp(amount, H.minDamage, C.damage.maxHit)
	local dealt = Damage.apply(hit.humanoid, amount, player.UserId, "weapon", {
		crit = crit,
		from = from,
		property = weapon.damageType, -- Kinetic: guards can block it
		pierce = false,
		form = form,
		attacker = character,
	})
	return dealt > 0
end

local function wearWeapon(player: Player, s: PlayerState)
	s.hits += 1
	if s.hits % H.wearEvery == 0 then
		inventory:wear(player, "mainHand", 1)
	end
end

local function push(hit: Hit, from: Vector3, speed: number)
	if speed <= 0 then
		return
	end
	local away = hit.root.Position - from
	local flat = Vector3.new(away.X, 0, away.Z)
	local velocity = (if flat.Magnitude > 0.1 then flat.Unit else Vector3.new(0, 0, -1)) * speed + Vector3.new(0, 6, 0)
	local victim = Players:GetPlayerFromCharacter(hit.model)
	if victim then
		Net.fire("WorldEffect", victim, { kind = "knockback", velocity = velocity })
	elseif not hit.root.Anchored then
		hit.root.AssemblyLinearVelocity += velocity
	end
end

-- ─── Melee ──────────────────────────────────────────────────────────────────

local function resolveSwing(player: Player, character: Model, seq: number, weapon: ItemTypes.WeaponDef, kind: any, index: number, speed: number)
	local s = stateOf(player)
	local swing = WeaponRules.swing(kind, index)
	local rng = nextRng(player, s)
	local struck: { [Model]: boolean } = { [character] = true }
	local params = OverlapParams.new()
	params.FilterType = Enum.RaycastFilterType.Exclude
	params.MaxParts = 60
	local excluded: { Instance } = { character }
	local fx = workspace:FindFirstChild("MagicFx")
	if fx then
		table.insert(excluded, fx)
	end
	params.FilterDescendantsInstances = excluded

	local anyHit = false
	local start = swing.hitFrom / speed
	local span = (swing.hitTo - swing.hitFrom) / speed
	local elapsed = 0
	for i = 1, W.samples do
		local at = start + span * (i - 1) / math.max(1, W.samples - 1)
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
		local box = root.CFrame * CFrame.new(0, 0.5, -(weapon.reach / 2 + 0.5))
		local chest = Aim.muzzle(root.Position)
		for _, part in workspace:GetPartBoundsInBox(box, Vector3.new(swing.width, swing.height, weapon.reach), params) do
			local hit = Targeting.characterOf(part)
			if hit and not struck[hit.model] then
				struck[hit.model] = true
				if
					Targeting.canHarm(player, hit.model)
					and Aim.lineOfSight(chest, hit.root.Position, { character, hit.model }, 1)
					and strikeOne(player, character, hit, weapon, swing.share, kind.critBonus, rng, "touch", root.Position)
				then
					push(hit, root.Position, swing.knockback)
					wearWeapon(player, s)
					if not anyHit then
						anyHit = true
						Net.fire("WeaponResult", player, { ok = true, hit = true })
					end
				end
			end
		end
	end
end

local function onSwing(player: Player, character: Model, def: ItemTypes.ItemDef, kind: any)
	local weapon = def.weapon :: ItemTypes.WeaponDef
	local free, action = ActionState.can(character, "slash")
	if not free then
		refuse(player, if action == "staggered" then "STAGGERED" else "BUSY")
		return
	end
	local s = stateOf(player)
	local t = now()
	local speed = WeaponRules.speed(weapon, finalStats(player).attackSpeedPct)
	local combo = s.combo
	local index = WeaponRules.nextIndex(kind, if combo then combo.index else nil, if combo then t - combo.startedAt else 0, if combo then combo.speed else speed)
	if not index then
		refuse(player, "TOO_EARLY")
		return
	end
	local swing = WeaponRules.swing(kind, index)
	if not stamina:spend(player, WeaponRules.swingStamina(weapon, swing)) then
		refuse(player, "TIRED")
		return
	end
	player:SetAttribute("WeaponSpeed", speed) -- the client times its combo window with it
	ActionState.set(character, "slashing", { duration = swing.duration / speed, variant = swing.clip })
	local seq = ActionRules.read(character).seq
	s.combo = { index = index, startedAt = t, speed = speed }
	task.spawn(resolveSwing, player, character, seq, weapon, kind, index, speed)
end

-- ─── Ranged ─────────────────────────────────────────────────────────────────

local function ammoCount(player: Player, tag: string): number
	local inv = inventory:inventoryOf(player)
	if not inv then
		return 0
	end
	return Inventory.countMatching(inv, function(d)
		return table.find(d.tags, tag) ~= nil
	end)
end

local function cue(payload: { [string]: any }, at: Vector3)
	runner:cue("weapon", payload, at, false)
end

-- Flies one shot and resolves whoever it strikes.
local function shoot(player: Player, character: Model, root: BasePart, weapon: ItemTypes.WeaponDef, ranged: any, share: number, aim: Vector3)
	local s = stateOf(player)
	local rng = nextRng(player, s)
	local muzzle = Aim.muzzle(root.Position)
	local offset = aim - muzzle
	local point = if offset.Magnitude > weapon.reach then muzzle + offset.Unit * weapon.reach else aim
	local velocity = Aim.launchVelocity(muzzle, point, ranged.speed, ranged.gravity, root.CFrame.LookVector)
	local lifetime = weapon.reach * 1.3 / ranged.speed + 0.5
	local flight: Delivery.Flight = {
		id = Delivery.newId(),
		origin = muzzle,
		velocity = velocity,
		gravity = ranged.gravity,
		radius = ranged.radius,
		homing = nil,
		turnRate = 0,
		pierce = 0,
		bounces = 0,
		maxDistance = weapon.reach * 1.3,
		lifetime = lifetime,
		ownerModel = character,
		property = weapon.damageType,
		piercing = false,
		onReflect = nil,
	}
	local look = ranged.projectile
	cue({ stage = "launch", projectileId = flight.id, origin = muzzle, velocity = velocity, gravity = ranged.gravity, lifetime = lifetime, look = look, caster = player.UserId }, muzzle)
	-- A parry sends it back at the archer (Cast/Guard): re-cue the visual from where it turned.
	flight.onReflect = function(oldId: number, at: Vector3, newVelocity: Vector3)
		cue({ stage = "impact", projectileId = oldId, point = at, struck = false }, at)
		cue({ stage = "launch", projectileId = flight.id, origin = at, velocity = newVelocity, gravity = ranged.gravity, lifetime = lifetime, look = look, caster = player.UserId }, at)
	end

	task.spawn(function()
		local impact = Delivery.fly(flight, { character })
		local landed = false
		for _, hit in impact.hits do
			-- A reflected shot may find its archer: no PvP gate on your own arrow.
			if (hit.model == character or Targeting.canHarm(player, hit.model))
				and strikeOne(player, character, hit, weapon, share, 0, rng, "projectile", muzzle)
			then
				landed = true
				wearWeapon(player, s)
			end
		end
		cue({ stage = "impact", projectileId = flight.id, point = impact.point, normal = impact.normal, struck = landed, expired = impact.expired }, impact.point)
		if landed and player.Parent then
			Net.fire("WeaponResult", player, { ok = true, hit = true })
		end
	end)
end

local function onDraw(player: Player, character: Model, def: ItemTypes.ItemDef, ranged: any)
	local weapon = def.weapon :: ItemTypes.WeaponDef
	local s = stateOf(player)
	if not ranged.draw then
		return -- crossbows and knives shoot on release; nothing to draw
	end
	if s.drawStart then
		return -- already drawing
	end
	if now() < s.readyAt then
		refuse(player, "RELOADING")
		return
	end
	if ammoCount(player, weapon.ammo or "") <= 0 then
		refuse(player, "NO_AMMO")
		return
	end
	if not ActionState.can(character, "cast") or not ActionState.set(character, "charging", { duration = ranged.draw.holdMax + 3 }) then
		refuse(player, "BUSY")
		return
	end
	s.drawStart = now()
	s.drawSeq = ActionRules.read(character).seq
end

local function endDraw(character: Model, s: PlayerState)
	if s.drawStart then
		s.drawStart = nil
		s.drawSeq = nil
		ActionState.clear(character, "charging")
	end
end

local function onRelease(player: Player, character: Model, def: ItemTypes.ItemDef, ranged: any, aim: Vector3?)
	local weapon = def.weapon :: ItemTypes.WeaponDef
	local s = stateOf(player)
	local root = character:FindFirstChild("HumanoidRootPart")
	if not root or not root:IsA("BasePart") or not aim then
		endDraw(character, s)
		return
	end
	local t = now()
	local share = 1
	if ranged.draw then
		local started = s.drawStart
		if not started then
			refuse(player, "NOT_DRAWN")
			return
		end
		-- Interrupted (staggered, blocked, dashed) since the draw began: the arrow is lost to it.
		local snapshot = ActionRules.read(character)
		if snapshot.seq ~= s.drawSeq or snapshot.state ~= "charging" then
			s.drawStart, s.drawSeq = nil, nil
			-- A draw held past its timed state drifts into "holding" (the readied-spell pose); no
			-- spell is readied here (checked in onIntent), so put the body back to idle.
			ActionState.clear(character, "holding")
			refuse(player, "INTERRUPTED")
			return
		end
		local held = t - started
		local drawn = WeaponRules.drawShare(ranged, held)
		if not drawn then
			endDraw(character, s)
			refuse(player, "UNDERDRAWN")
			return
		end
		share = drawn
		local over = held - ranged.draw.holdMax
		if over > 0 then
			stamina:drain(player, WeaponRules.holdDrain(ranged, held) * over)
		end
	else
		if t < s.readyAt then
			refuse(player, "RELOADING")
			return
		end
		if not ActionState.can(character, "cast") then
			refuse(player, "BUSY")
			return
		end
	end
	if not Delivery.capacity() then
		endDraw(character, s)
		refuse(player, "BUSY")
		return
	end
	if not stamina:spend(player, weapon.stamina) then
		endDraw(character, s)
		refuse(player, "TIRED")
		return
	end
	local tag = weapon.ammo or ""
	local paid = inventory:transact(player, "shoot", tag, function(inv)
		local ok = Inventory.removeMatching(inv, function(d)
			return table.find(d.tags, tag) ~= nil
		end, 1)
		return ok, if ok then nil else "NO_AMMO"
	end)
	if not paid then
		endDraw(character, s)
		refuse(player, "NO_AMMO")
		return
	end

	s.drawStart, s.drawSeq = nil, nil
	s.readyAt = t + WeaponRules.reload(weapon, ranged)
	ActionState.set(character, "casting", { duration = 0.3, force = true }) -- the release (resumes the wind-up)
	shoot(player, character, root, weapon, ranged, share, aim)
	Net.fire("WeaponResult", player, { ok = true, fired = true, ammo = ammoCount(player, tag) })
end

-- ─── Intent ─────────────────────────────────────────────────────────────────

local function onIntent(player: Player, op: string, aim: Vector3?)
	local character = player.Character
	local humanoid = character and character:FindFirstChildOfClass("Humanoid")
	if not character or not humanoid or humanoid.Health <= 0 then
		return
	end
	local s = stateOf(player)
	if op == "cancel" then
		endDraw(character, s)
		return
	end
	if attunement:attunedKey(player) then
		endDraw(character, s)
		refuse(player, "SPELL_READY")
		return
	end
	local rec, def, class, kind = weaponOf(player)
	if not rec or not def or not class then
		endDraw(character, s)
		refuse(player, "NO_WEAPON")
		return
	end
	if ItemInstance.isBroken(rec) then
		endDraw(character, s)
		refuse(player, "BROKEN")
		return
	end
	if op == "swing" then
		if class ~= "melee" then
			refuse(player, "NOT_MELEE")
			return
		end
		onSwing(player, character, def, kind)
	elseif op == "draw" then
		if class == "ranged" then
			onDraw(player, character, def, kind)
		end
	elseif op == "release" then
		if class == "ranged" then
			onRelease(player, character, def, kind, aim)
		end
	end
end

function WeaponService.init(_self: any, ctx: any)
	log = ctx.log
	inventory = ctx.get("InventoryService")
	stamina = ctx.get("StaminaService")
	attunement = ctx.get("AttunementService")
	worldService = ctx.get("WorldService")
	runner = ctx.get("EffectRunner")
	Net.on("WeaponIntent", onIntent :: any)
end

function WeaponService.start(_self: any, _ctx: any)
	Players.PlayerRemoving:Connect(function(player)
		states[player] = nil
	end)
end

return WeaponService
