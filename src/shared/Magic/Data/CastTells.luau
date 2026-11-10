--!strict
--[[
	CastTells: how a spell forming in someone's hand gives away what it will do (docs/ReadTheCast.md).

	No label, no icon: the conjured spell (Fx/Conjure) MOVES differently by the kind of thing it does
	(Data/RouteSummaries kinds, through Magic/SpellOutcome), and grows with its power. People learn
	to read it: a fast, flickering, spitting core is coming for you; a slow one drifting upward is a
	heal; a still one is a ward.

	Per kind:
		spin        multiplies the caster's own spin (their hand's speed stays theirs)
		pulseRate   breaths per second of the core's size (0 = steady)
		pulseDepth  how much the core swells on each breath (share of its size)
		jitter      restless shaking even when not overcharged (share of its size)
		rise        studs the spell drifts upward (+) or sinks (−) at full charge
		pull        "in": magic drawn into it; "out": magic thrown off it
		pullSpeed   multiplies how fast those particles move
		light       multiplies its light
	Power: scale = min(scaleMax, 1 + scalePerPower x (power − 1)); the hum drops in pitch the same way.
]]

export type Tell = {
	spin: number,
	pulseRate: number,
	pulseDepth: number,
	jitter: number,
	rise: number,
	pull: string,
	pullSpeed: number,
	light: number,
}

return table.freeze({
	scalePerPower = 0.07,
	scaleMax = 1.6,
	pitchPerPower = 0.03,
	pitchMin = 0.75,
	fallback = "utility",

	kinds = table.freeze({
		-- Sharp and hungry: fast, restless, spitting sparks outward.
		attack = { spin = 1.7, pulseRate = 3.5, pulseDepth = 0.06, jitter = 0.05, rise = 0, pull = "out", pullSpeed = 1.5, light = 1.3 },
		-- Soft: slow, breathing, drifting upward, drawing gently in.
		heal = { spin = 0.45, pulseRate = 0.8, pulseDepth = 0.1, jitter = 0, rise = 0.35, pull = "in", pullSpeed = 0.5, light = 0.9 },
		-- Still: barely turning, no breath, a steady glow.
		protect = { spin = 0.25, pulseRate = 0, pulseDepth = 0, jitter = 0, rise = 0, pull = "in", pullSpeed = 0.7, light = 1 },
		-- Bright and lifting.
		boost = { spin = 0.9, pulseRate = 1.5, pulseDepth = 0.05, jitter = 0, rise = 0.2, pull = "in", pullSpeed = 1, light = 1.15 },
		-- Tightening: a quick hard pulse, pulling in fast.
		control = { spin = 1.2, pulseRate = 2.2, pulseDepth = 0.14, jitter = 0, rise = 0, pull = "in", pullSpeed = 1.6, light = 0.9 },
		-- Streaming: spinning fastest, throwing its motion off.
		move = { spin = 2.2, pulseRate = 0, pulseDepth = 0, jitter = 0.02, rise = 0, pull = "out", pullSpeed = 1.2, light = 1 },
		-- Heavy: slow, sinking toward the ground.
		land = { spin = 0.5, pulseRate = 0.6, pulseDepth = 0.05, jitter = 0, rise = -0.3, pull = "in", pullSpeed = 0.8, light = 0.8 },
		-- Listening: a slow deep breath, dim.
		sense = { spin = 0.35, pulseRate = 0.5, pulseDepth = 0.18, jitter = 0, rise = 0, pull = "in", pullSpeed = 0.4, light = 0.7 },
		utility = { spin = 1, pulseRate = 0, pulseDepth = 0, jitter = 0, rise = 0, pull = "in", pullSpeed = 1, light = 1 },
		-- A spell that does nothing looks hollow: dim and listless.
		none = { spin = 0.6, pulseRate = 0, pulseDepth = 0, jitter = 0, rise = -0.1, pull = "in", pullSpeed = 0.3, light = 0.5 },
	} :: { [string]: Tell }),
})
