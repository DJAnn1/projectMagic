--!strict
--[[
	ActionState: the server's record of what each body (player character or NPC rig) is doing.
	docs/Combat.md §11. The server decides; animations only follow (client AnimationController
	for players, NPCLOD for NPC rigs). Rules and attribute names: Shared/Magic/ActionRules.

		ActionState.set(model, state, opts?) -> boolean
		    opts: duration (seconds; default = the state's), domain, variant (entry clip), force.
		    Refused (false) when the current state can't be interrupted by `state`, unless forced.
		ActionState.clear(model, only?)   back to idle (only if the current state is `only`)
		ActionState.get(model) -> string  the state in effect now (expired = its `next`)
		ActionState.can(model, action) -> (boolean, string)   e.g. can(character, "cast")
		ActionState.react(model, clip)    a one-shot reaction clip (BlockHit) over the state
		ActionState.changed               Signal(model, state, previous, info)

	EXPIRY  one Heartbeat loop (10 Hz) walks the models with a timed state and moves each expired
	        one to its `next` (or idle). Reads never wait for it: get/can apply expiry themselves.
	        The loop only runs while some timed state exists.
	COST    a set is 6 attribute writes on one model; the timed set is weak-keyed, so destroyed
	        characters drop out without cleanup.
]]

local RunService = game:GetService("RunService")

local Shared = game:GetService("ReplicatedStorage").Shared
local Signal = require(Shared.Core.Signal)
local ActionRules = require(Shared.Magic.ActionRules)
local Data = require(Shared.Magic.Data.CombatAnimations)

local A = ActionRules.ATTR
local MAX_DURATION = 30
local STEP = 0.1

local ActionState = {}

export type SetOptions = {
	duration: number?,
	domain: string?,
	variant: string?,
	force: boolean?,
}

export type Info = {
	duration: number,
	domain: string?,
	variant: string?,
	seq: number,
	forced: boolean,
}

ActionState.changed = Signal.new()

-- Models whose state ends on its own. Weak keys: a destroyed character just disappears.
local timed: { [Model]: boolean } = setmetatable({}, { __mode = "k" }) :: any
local stepper: RBXScriptConnection? = nil
local accumulated = 0

local function now(): number
	return workspace:GetServerTimeNow()
end

local step: (number) -> () -- forward declaration: the loop and set refer to each other

local function ensureStepper()
	if stepper or not RunService:IsRunning() then
		return
	end
	stepper = RunService.Heartbeat:Connect(function(dt)
		accumulated += dt
		if accumulated < STEP then
			return
		end
		accumulated = 0
		step(now())
	end)
end

local function write(model: Model, state: string, previous: string, opts: SetOptions, t: number): Info
	local def = Data.states[state]
	local duration = math.clamp(opts.duration or def.duration, 0, MAX_DURATION)
	local seq = ActionRules.read(model).seq + 1
	model:SetAttribute(A.state, state)
	model:SetAttribute(A.untilTime, if duration > 0 then t + duration else 0)
	model:SetAttribute(A.duration, duration)
	model:SetAttribute(A.domain, opts.domain)
	model:SetAttribute(A.variant, opts.variant)
	model:SetAttribute(A.seq, seq) -- last: clients re-read everything when this changes
	if duration > 0 then
		timed[model] = true
		ensureStepper()
	else
		timed[model] = nil
	end
	local info: Info = {
		duration = duration,
		domain = opts.domain,
		variant = opts.variant,
		seq = seq,
		forced = opts.force == true,
	}
	ActionState.changed:Fire(model, state, previous, info)
	return info
end

function ActionState.get(model: Model): string
	return ActionRules.effective(ActionRules.read(model), now())
end

function ActionState.set(model: Model, state: string, opts: SetOptions?): boolean
	if not Data.states[state] then
		error("ActionState.set: unknown state " .. tostring(state), 2)
	end
	local o: SetOptions = opts or {}
	local current = ActionState.get(model)
	if not o.force and not ActionRules.canEnter(current, state) then
		return false
	end
	write(model, state, current, o, now())
	return true
end

function ActionState.clear(model: Model, only: string?)
	local current = ActionState.get(model)
	if only and current ~= only then
		return
	end
	if current ~= "idle" or ActionRules.read(model).state ~= "idle" then
		write(model, "idle", current, {}, now())
	end
end

function ActionState.can(model: Model, action: string): (boolean, string)
	local state = ActionState.get(model)
	-- In a gravity hold (Cast/GravityRuntime) a body does nothing: no dash out, no swing.
	if model:GetAttribute("GravityHeld") then
		return false, state
	end
	return ActionRules.allows(state, action), state
end

function ActionState.react(model: Model, clip: string)
	if not Data.animations[clip] then
		error("ActionState.react: unknown clip " .. tostring(clip), 2)
	end
	local seq = model:GetAttribute(A.reactSeq)
	model:SetAttribute(A.react, clip)
	model:SetAttribute(A.reactSeq, (if typeof(seq) == "number" then seq else 0) + 1)
end

-- Moves every expired timed state on. Exposed for specs (they pass their own clock).
-- Collected first: write() may add a model back to `timed`, which can't happen mid-traversal.
step = function(t: number)
	local expired: { Model } = {}
	for model in timed do
		if not model.Parent then
			timed[model] = nil
		elseif t >= ActionRules.read(model).untilTime then
			table.insert(expired, model)
		end
	end
	for _, model in expired do
		timed[model] = nil
		local snapshot = ActionRules.read(model)
		local def = Data.states[snapshot.state]
		write(model, if def and def.next then def.next else "idle", snapshot.state, { domain = snapshot.domain }, t)
	end
	if next(timed) == nil and stepper then
		stepper:Disconnect()
		stepper = nil
	end
end
ActionState.step = step

return ActionState
