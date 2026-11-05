--!strict
--[[
	MovementTuning: running and the dash (docs/Combat.md §15). Pure data, shared: the server
	(Services/MovementService) enforces it, the client (Controllers/MovementClient) predicts with it,
	Tests/Movement.spec checks the rules built on it (Shared/Magic/Movement).

	RUN
		speedMult         walk speed while running (a StatusEffects walk multiplier, "run")
		staminaPerSecond  stamina drained while running and moving (0 = running is free)
		gamepadOn/Off     left-stick tilt that starts / stops running on a gamepad (no toggle there)
		Running pauses (the toggle stays on) in any action state but idle, and while a spell is
		readied: you run with your hands free.
	DASH
		charges, recharge   charges held, and seconds to refill one
		cooldown            minimum seconds between two dashes
		distance, duration  studs and seconds of a plain dash
		staminaCost         per dash (refused when you can't pay)
		evade               damage resistance ("all") and its seconds, from the dash's start
		tierDistance        extra distance per mastery tier index of the readied spell (0..8)
		slack               a dash that moves you more than distance x slack is logged
		                    (dash_overshoot): the hook for the movement checks (Backend.md §8)
		styles              how each style moves you:
		                      impulse  the client pushes the body (it owns its physics) for
		                               `duration`; lift adds upward speed (studs/s)
		                      blink    the server moves you instantly along a clear line
		                      rewind   the server puts you back where you were `seconds` ago
		domains             the readied spell's domain picks the style and scales the distance;
		                    with nothing readied, the plain "roll"
]]

export type Style = { kind: "impulse" | "blink" | "rewind", lift: number?, seconds: number? }
export type Flavour = { style: string, distance: number, word: string }

local MovementTuning = {
	run = {
		speedMult = 1.55,
		staminaPerSecond = 0,
		gamepadOn = 0.92,
		gamepadOff = 0.8,
	},
	dash = {
		charges = 2,
		recharge = 2.5,
		cooldown = 0.35,
		distance = 16,
		duration = 0.28,
		staminaCost = 12,
		evade = { resist = 0.4, seconds = 0.35 },
		tierDistance = 0.05,
		slack = 1.6,
		maxRewindDistance = 40, -- a rewind further than this (you teleported, fell far) is refused
		styles = {
			roll = { kind = "impulse" },
			jet = { kind = "impulse" },
			slide = { kind = "impulse" },
			wave = { kind = "impulse" },
			glide = { kind = "impulse", lift = 6 },
			flip = { kind = "impulse", lift = 34 },
			blink = { kind = "blink" },
			rewind = { kind = "rewind", seconds = 1 },
		} :: { [string]: Style },
		plain = { style = "roll", distance = 1, word = "Dash" } :: Flavour,
		domains = {
			energy = { style = "blink", distance = 1, word = "Flashstep" },
			earth = { style = "slide", distance = 0.85, word = "Stone slide" },
			water = { style = "wave", distance = 1.1, word = "Wave ride" },
			air = { style = "glide", distance = 1.35, word = "Gust" },
			life = { style = "jet", distance = 1, word = "Bound" },
			mind = { style = "blink", distance = 0.85, word = "Misdirect" },
			spirit = { style = "jet", distance = 1.05, word = "Wisp step" },
			void = { style = "blink", distance = 0.95, word = "Fade" },
			space = { style = "blink", distance = 1.25, word = "Fold" },
			time = { style = "rewind", distance = 1, word = "Rewind" },
			gravity = { style = "flip", distance = 0.9, word = "Vault" },
			reality = { style = "blink", distance = 1.1, word = "Slip" },
		} :: { [string]: Flavour },
	},
}

return MovementTuning
