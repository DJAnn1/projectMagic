--!strict
--[[
	Guard: raised guards, the guard meter, blocks and parries (docs/Combat.md §12). Rules and
	numbers in Shared/Magic/GuardRules. Players and NPCs alike.

		Guard.raise(model, domain, opts?) -> (boolean, reason?)   ActionState "blocking" (BlockStart,
		                                     then the Block loop), attributes for every client's ward
		Guard.lower(model)
		Guard.isGuarding(model) -> boolean   true only while the action state is "blocking"
		Guard.mitigate(humanoid, amount, info?) -> (remaining, outcome?)
		                                     called by Cast/Damage for every hit; outcome "parry" | "block"
		Guard.parryProjectile(model, from) -> boolean
		                                     called by Cast/Delivery when a flight reaches someone
		Guard.meter(model) -> 0..1
		Guard.onAbsorb  hook(model, absorbed) GuardService drains a player's reservoir here
		Guard.onParry   hook(model, info?)    logs, NPC memory

	ATTRIBUTES (on the character model; clients draw from these)
		Guarding        domain id while raised (the ward's look)
		GuardMeter      0..1 (written on change and while refilling)
		GuardHitAt      server time of the last blocked hit (the ward flashes)
		ParriedAt       server time of the last parry (a bright flash, "Parry!")
		GuardBrokenUntil server time the guard can be raised again after a break

	The meter refills lazily (computed from the last hit time when read) and GuardService ticks
	the attribute while anyone's meter is below full. A guard turns damage away; it is not a heal
	(it never touches Damage.heal), so Brush with Death's "no healing" clock keeps running.
]]

local Players = game:GetService("Players")

local Shared = game:GetService("ReplicatedStorage").Shared
local GuardRules = require(Shared.Magic.GuardRules)

local Cast = script.Parent
local ActionState = require(Cast.ActionState)
local StatusEffects = require(Cast.StatusEffects)

local T = GuardRules.tuning

export type Info = {
	from: Vector3?,
	property: string?,
	pierce: boolean?,
	form: string?,
	attacker: Model?,
	dot: boolean?,
}

type State = {
	raisedAt: number?, -- server time the current guard went up
	parryOpen: boolean, -- this raise has a parry window (not a spam re-raise)
	parryUntil: number,
	loweredAt: number,
	meter: number, -- 0..1 at `meterAt`
	meterAt: number,
	lastHitAt: number,
}

local Guard = {}

Guard.onAbsorb = nil :: ((Model, number) -> ())?
Guard.onParry = nil :: ((Model, Info?) -> ())?

local states: { [Model]: State } = setmetatable({}, { __mode = "k" }) :: any

local function now(): number
	return workspace:GetServerTimeNow()
end

local function stateOf(model: Model): State
	local s = states[model]
	if not s then
		s = { raisedAt = nil, parryOpen = false, parryUntil = 0, loweredAt = -math.huge, meter = 1, meterAt = now(), lastHitAt = -math.huge }
		states[model] = s
	end
	return s
end

-- The meter now, with any refill since it was last written.
local function meterNow(s: State, t: number): number
	local since = t - math.max(s.meterAt, s.lastHitAt + T.regenDelay)
	if since <= 0 then
		return s.meter
	end
	return math.min(1, s.meter + since * T.regenPerSecond)
end

local function setMeter(model: Model, s: State, value: number, t: number)
	s.meter, s.meterAt = math.clamp(value, 0, 1), t
	model:SetAttribute("GuardMeter", s.meter)
end

function Guard.meter(model: Model): number
	local s = states[model]
	return if s then meterNow(s, now()) else 1
end

-- For GuardService's refill tick: writes the attribute for every meter still refilling.
function Guard.tickMeters()
	local t = now()
	for model, s in states do
		if model.Parent and s.meter < 1 then
			local m = meterNow(s, t)
			if m ~= s.meter then
				setMeter(model, s, m, t)
			end
		end
	end
end

function Guard.isGuarding(model: Model): boolean
	local s = states[model]
	return s ~= nil and s.raisedAt ~= nil and ActionState.get(model) == "blocking"
end

local function humanoidOf(model: Model): Humanoid?
	return model:FindFirstChildOfClass("Humanoid")
end

local function rootOf(model: Model): BasePart?
	local root = model:FindFirstChild("HumanoidRootPart")
	return if root and root:IsA("BasePart") then root else nil
end

export type RaiseOptions = { latency: number? }

function Guard.raise(model: Model, domain: string, opts: RaiseOptions?): (boolean, string?)
	local humanoid = humanoidOf(model)
	if not humanoid or humanoid.Health <= 0 then
		return false, "DEAD"
	end
	local t = now()
	local broken = model:GetAttribute("GuardBrokenUntil")
	if typeof(broken) == "number" and broken > t then
		return false, "GUARD_BROKEN"
	end
	if Guard.isGuarding(model) then
		return true, nil
	end
	if not ActionState.can(model, "block") then
		return false, "BUSY"
	end
	local s = stateOf(model)
	local meter = meterNow(s, t)
	if meter < T.minRaiseMeter then
		return false, "GUARD_SPENT"
	end
	setMeter(model, s, meter, t)
	s.raisedAt = t
	-- A fresh parry window only if the last guard came down a while ago (no parry spam).
	s.parryOpen = t - s.loweredAt >= T.parryCooldown
	local allowance = math.clamp((opts and opts.latency) or 0, 0, T.latencyAllowanceMax)
	s.parryUntil = if s.parryOpen then t + T.parryWindow + allowance else 0
	model:SetAttribute("Guarding", domain)
	StatusEffects.setWalkMultiplier(humanoid, "guarding", T.walkMult)
	ActionState.set(model, "blocking", { domain = domain })
	return true, nil
end

function Guard.lower(model: Model)
	local s = states[model]
	if s and s.raisedAt then
		s.raisedAt = nil
		s.loweredAt = now()
	end
	model:SetAttribute("Guarding", nil)
	local humanoid = humanoidOf(model)
	if humanoid then
		StatusEffects.setWalkMultiplier(humanoid, "guarding", nil)
	end
	if model.Parent and ActionState.get(model) == "blocking" then
		ActionState.clear(model, "blocking")
	end
end

-- An empty meter (or reservoir): the guard breaks, a stagger, and no guard for a while.
local function breakGuard(model: Model, t: number)
	Guard.lower(model)
	model:SetAttribute("GuardBrokenUntil", t + T.brokenLockout)
	ActionState.set(model, "staggered", { duration = T.breakStaggerSeconds, force = true })
end

function Guard.breakGuard(model: Model)
	breakGuard(model, now())
end

local function facingCovers(model: Model, from: Vector3?): boolean
	local root = rootOf(model)
	if not root or not from then
		return false
	end
	return GuardRules.covers(root.CFrame.LookVector, root.Position, from)
end

-- A parried touch spell staggers whoever cast it (players and NPCs).
local function punish(info: Info?)
	local attacker = info and info.attacker
	if attacker and info and info.form == "touch" and attacker.Parent then
		ActionState.set(attacker, "staggered", { duration = T.parryStaggerSeconds, force = true })
	end
end

local function parried(model: Model, s: State, t: number, info: Info?)
	s.parryUntil = 0 -- one parry per raise
	model:SetAttribute("ParriedAt", t)
	ActionState.react(model, "BlockHit")
	punish(info)
	local hook = Guard.onParry
	if hook then
		hook(model, info)
	end
end

-- Cast/Damage calls this for every hit before wards and health. Returns what gets through.
function Guard.mitigate(humanoid: Humanoid, amount: number, info: any): (number, string?)
	local model = humanoid.Parent
	if not model or not model:IsA("Model") or not info or info.dot or not Guard.isGuarding(model) then
		return amount, nil
	end
	local kind = GuardRules.kindOf(info.property, info.pierce)
	if kind == "unblockable" or not facingCovers(model, info.from) then
		return amount, nil
	end
	local s = stateOf(model)
	local t = now()
	if s.parryOpen and t <= s.parryUntil then
		parried(model, s, t, info)
		return 0, "parry"
	end
	local turned = amount * GuardRules.reduction(kind)
	local capacity = math.max(1, humanoid.MaxHealth * T.capacityShare)
	local meter = meterNow(s, t) - turned / capacity
	s.lastHitAt = t
	model:SetAttribute("GuardHitAt", t)
	ActionState.react(model, "BlockHit")
	local hook = Guard.onAbsorb
	if hook and turned > 0 then
		hook(model, turned)
	end
	if meter <= 0 then
		setMeter(model, s, 0, t)
		breakGuard(model, t)
	else
		setMeter(model, s, meter, t)
	end
	return amount - turned, "block"
end

-- Cast/Delivery: a flight is about to strike `model`. True (and the parry is spent) when it
-- should be turned back instead.
function Guard.parryProjectile(model: Model, from: Vector3, info: Info?): boolean
	if not Guard.isGuarding(model) or not facingCovers(model, from) then
		return false
	end
	if info and GuardRules.kindOf(info.property, info.pierce) == "unblockable" then
		return false
	end
	local s = stateOf(model)
	local t = now()
	if not (s.parryOpen and t <= s.parryUntil) then
		return false
	end
	parried(model, s, t, info)
	return true
end

-- Anything that ends "blocking" (a stagger, a forced state, Guard.lower) takes the ward down.
ActionState.changed:Connect(function(model: Model, state: string, previous: string)
	if previous ~= "blocking" or state == "blocking" then
		return
	end
	local s = states[model]
	if s and s.raisedAt then
		s.raisedAt = nil
		s.loweredAt = now()
	end
	model:SetAttribute("Guarding", nil)
	local humanoid = humanoidOf(model)
	if humanoid then
		StatusEffects.setWalkMultiplier(humanoid, "guarding", nil)
	end
end)

-- The ping-based allowance for a player (0 for NPCs).
function Guard.latencyOf(model: Model): number
	local player = Players:GetPlayerFromCharacter(model)
	if not player then
		return 0
	end
	local ok, ping = pcall(function()
		return player:GetNetworkPing()
	end)
	return if ok and typeof(ping) == "number" then ping else 0
end

return Guard
