--!strict
--[[
	ActionRules: the shared, read-only half of the action state machine (docs/Combat.md §11).
	The server writes a body's state (Server/Magic/Cast/ActionState); clients and server code read
	it from these character-model attributes:

		ActionState          state id (Data/CombatAnimations.states); missing = "idle"
		ActionStateUntil     server time (workspace:GetServerTimeNow) it ends; 0 = until changed
		ActionStateDuration  seconds the state was given (animation speed scaling)
		ActionStateDomain    domain id of the action, if any (per-domain animation style)
		ActionStateVariant   which entry animation to play instead of the state's own (e.g. Slash2)
		ActionStateSeq       increments on every set, so a repeated state (two casts) replays
		ActionReact          a one-shot reaction clip (e.g. BlockHit) layered over the state
		ActionReactSeq       increments on every reaction

	Attributes set by a client don't replicate, so nobody can change their own state.
]]

local Data = require(script.Parent.Data.CombatAnimations)

local ActionRules = {}

ActionRules.ATTR = {
	state = "ActionState",
	untilTime = "ActionStateUntil",
	duration = "ActionStateDuration",
	domain = "ActionStateDomain",
	variant = "ActionStateVariant",
	seq = "ActionStateSeq",
	react = "ActionReact",
	reactSeq = "ActionReactSeq",
}

export type Snapshot = {
	state: string,
	untilTime: number,
	duration: number,
	domain: string?,
	variant: string?,
	seq: number,
}

local function num(v: any): number
	return if typeof(v) == "number" then v else 0
end

local function str(v: any): string?
	return if typeof(v) == "string" and v ~= "" then v else nil
end

-- Everything about a body's state. An unknown or missing state reads as idle.
function ActionRules.read(model: Instance): Snapshot
	local A = ActionRules.ATTR
	local state = str(model:GetAttribute(A.state))
	return {
		state = if state and Data.states[state] then state else "idle",
		untilTime = num(model:GetAttribute(A.untilTime)),
		duration = num(model:GetAttribute(A.duration)),
		domain = str(model:GetAttribute(A.domain)),
		variant = str(model:GetAttribute(A.variant)),
		seq = num(model:GetAttribute(A.seq)),
	}
end

-- The state in effect at time `t`: an expired timed state has already become its `next`.
function ActionRules.effective(snapshot: Snapshot, t: number): string
	if snapshot.untilTime > 0 and t >= snapshot.untilTime then
		local def = Data.states[snapshot.state]
		return if def and def.next then def.next else "idle"
	end
	return snapshot.state
end

function ActionRules.allows(state: string, action: string): boolean
	local def = Data.states[state]
	return def ~= nil and def.allows[action] == true
end

-- May `to` replace `from` (without forcing)?
function ActionRules.canEnter(from: string, to: string): boolean
	local target = Data.states[to]
	if not target then
		return false
	end
	local current = Data.states[from]
	if not current or not current.interruptedBy then
		return true
	end
	return current.interruptedBy[to] == true
end

-- The clips a state plays: (entry, loop). A variant replaces the entry clip.
function ActionRules.clipsFor(state: string, variant: string?): (string?, string?)
	local def = Data.states[state]
	if not def then
		return nil, nil
	end
	local entry = def.animation
	if variant and entry and Data.animations[variant] then
		entry = variant
	end
	return entry, def.loop
end

-- Playback speed for a clip. With a duration (scaleToDuration states) the clip's "Release"
-- marker, or its end when it has none, lands when the duration ends. `length` is the track's
-- real Length (0 while loading: then the data's approxLength stands in).
function ActionRules.playbackSpeed(name: string, length: number, duration: number?, domain: string?): number
	local def = Data.animations[name]
	if not def then
		return 1
	end
	local style = domain and Data.domains[domain]
	local speed = def.speed * (if style then style.speed else 1)
	if duration and duration > 0 then
		local clip = if length > 0 then length else def.approxLength
		local fraction = 1
		for _, marker in def.markers do
			if marker.name == "Release" then
				fraction = marker.at
			end
		end
		speed = clip * fraction / duration
	end
	return math.clamp(speed, Data.minSpeed, Data.maxSpeed)
end

-- Where a named marker sits in a clip, as a fraction (the data's fallback position), or nil.
function ActionRules.markerFraction(clip: string, marker: string): number?
	local def = Data.animations[clip]
	if not def then
		return nil
	end
	for _, m in def.markers do
		if m.name == marker then
			return m.at
		end
	end
	return nil
end

-- Speed for the rest of a clip that was frozen at `fraction`, so it finishes in `duration`.
function ActionRules.resumeSpeed(clip: string, length: number, fraction: number, duration: number): number
	local def = Data.animations[clip]
	local clipLength = if length > 0 then length elseif def then def.approxLength else 1
	return math.clamp(clipLength * (1 - fraction) / math.max(duration, 0.05), Data.minSpeed, Data.maxSpeed)
end

-- A clip's AnimationPriority. A missing or misspelt priority falls back to Action instead of
-- erroring, so one bad data entry can't stop every other clip from loading.
function ActionRules.priorityOf(clip: string): Enum.AnimationPriority
	local def = Data.animations[clip]
	local name = def and def.priority
	local ok, priority = pcall(function()
		return (Enum.AnimationPriority :: any)[name]
	end)
	return if ok and typeof(priority) == "EnumItem" then priority else Enum.AnimationPriority.Action
end

function ActionRules.weightFor(domain: string?): number
	local style = domain and Data.domains[domain]
	return if style then style.weight else 1
end

return ActionRules
