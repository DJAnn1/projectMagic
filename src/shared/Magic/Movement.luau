--!strict
--[[
	Movement: the pure rules for running and the dash (data in Data/MovementTuning). Shared so the
	server's checks and the client's prediction can't disagree; Tests/Movement.spec covers them.
]]

local T = require(script.Parent.Data.MovementTuning)

export type Dash = {
	style: string,
	kind: string, -- "impulse" | "blink" | "rewind"
	word: string, -- what the dash is called in this domain ("Flashstep")
	distance: number, -- studs
	duration: number, -- seconds
	speed: number, -- horizontal studs/s for impulse dashes
	lift: number, -- upward studs/s for impulse dashes
	seconds: number, -- how far back a rewind goes
}

local Movement = {}

Movement.tuning = T

-- The dash for a readied spell's domain (nil = nothing readied) at a mastery tier index (0..8).
function Movement.dashFor(domain: string?, tierIndex: number?): Dash
	local D = T.dash
	local flavour = (if domain then D.domains[domain] else nil) or D.plain
	local style = D.styles[flavour.style] or D.styles.roll
	local tier = math.clamp(math.floor(tierIndex or 0), 0, 8)
	local distance = D.distance * flavour.distance * (1 + D.tierDistance * tier)
	return {
		style = flavour.style,
		kind = style.kind,
		word = flavour.word,
		distance = distance,
		duration = D.duration,
		speed = distance / D.duration,
		lift = style.lift or 0,
		seconds = style.seconds or 0,
	}
end

-- The flat unit direction to dash in: where you're moving, else straight back from where you face.
function Movement.direction(moveDirection: Vector3, lookVector: Vector3): Vector3
	local flat = Vector3.new(moveDirection.X, 0, moveDirection.Z)
	if flat.Magnitude > 0.1 then
		return flat.Unit
	end
	local back = Vector3.new(-lookVector.X, 0, -lookVector.Z)
	return if back.Magnitude > 0.01 then back.Unit else Vector3.new(0, 0, 1)
end

--[[
	Charges after `elapsed` seconds of refilling from `charges` (fractional progress kept in the
	return's second value, 0..1, so the HUD can show a filling pip). Never above the max.
]]
function Movement.recharge(charges: number, progress: number, elapsed: number): (number, number)
	local D = T.dash
	if charges >= D.charges then
		return D.charges, 0
	end
	local total = progress + elapsed / D.recharge
	local gained = math.floor(total)
	local newCharges = math.min(D.charges, charges + gained)
	return newCharges, if newCharges >= D.charges then 0 else total - gained
end

-- Running applies only in these action states, and never with a spell readied.
function Movement.runAllowed(actionState: string, attuned: boolean): boolean
	return actionState == "idle" and not attuned
end

-- Gamepad: run while the stick is pushed far; hysteresis so it doesn't flicker at the edge.
function Movement.gamepadRun(wasRunning: boolean, stickMagnitude: number): boolean
	if wasRunning then
		return stickMagnitude >= T.run.gamepadOff
	end
	return stickMagnitude >= T.run.gamepadOn
end

return Movement
