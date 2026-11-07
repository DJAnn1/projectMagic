--!strict
--[[
	FeralRules: the decisions behind feral spells, with no Instances, so Tests/FeralSpells.spec can check
	every case (docs/FeralSpells.md). Services/FeralService does the running.

		escapeChance(severity) -> number
		mayEscape(view) -> boolean                  the limits on one getting loose
		energyFor(power) -> seconds
		drainRate(density) -> multiplier            thick ley energy keeps it going longer
		pickDirection(samples, roll) -> index       leans towards energy, never into the sea
		pieces(domain, palette, scale, rng) -> parts    its body, in its domain's character
		def(recipe, domain, palette, opposed, name, rng) -> a CreatureRig definition
		unstable(energy, maxEnergy) -> 0..1          how visibly it's coming apart
		response(occupation, distance) -> "fight" | "flee" | nil      how someone nearby reacts
		learnsFrom(view) -> boolean                 only a spell you didn't know can teach you
		clue(recipe, names) -> string
		pruneStudied(studied, max)                  bounded, oldest first
		rumorFor(ferals, heard, x, z, roll) -> feral?
		rumorLine(source, who, bearing, roll) -> string
]]

local Data = require(script.Parent.Data.FeralData)

local T = Data.tuning
local T_STEPS = Data.unstableSteps
local DIM = 0.42 -- how far Neon goes towards black: Bloom blows bright Neon out to white

export type EscapeView = {
	severity: number,
	roll: number,
	alive: number,
	limit: number,
	fromCaster: number,
	sinceLastEscape: number,
	onIsland: boolean,
}

export type Sample = { density: number, land: boolean }

export type RumorFeral = { id: string, x: number, z: number }

local FeralRules = {}

function FeralRules.escapeChance(severity: number): number
	return math.clamp(T.escapeBase + (severity - 1) * T.escapePerSeverity, T.escapeMin, T.escapeMax)
end

function FeralRules.mayEscape(view: EscapeView): boolean
	return view.onIsland -- inside a Rift's pocket, it stays there with the Rift's other troubles
		and view.alive < view.limit
		and view.fromCaster < T.maxPerCaster
		and view.sinceLastEscape >= T.perCasterCooldown
		and view.roll < FeralRules.escapeChance(view.severity)
end

function FeralRules.onIsland(x: number, z: number, worldSize: number): boolean
	return math.abs(x) <= worldSize / 2 and math.abs(z) <= worldSize / 2
end

function FeralRules.energyFor(power: number): number
	return T.energyBase + T.energyPerPower * power
end

function FeralRules.drainRate(density: number): number
	local share = math.clamp((density - T.densityLow) / (T.densityHigh - T.densityLow), 0, 1)
	return T.drainThin + (T.drainThick - T.drainThin) * share
end

-- A weighted pick among directions: land only, and more ley energy is more likely. No land at all (it's
-- been pushed out over water): nil, and it stays where it is.
function FeralRules.pickDirection(samples: { Sample }, roll: number): number?
	local total = 0
	for _, sample in samples do
		if sample.land then
			total += 1 + math.max(0, sample.density) * T.densityWeight
		end
	end
	if total <= 0 then
		return nil
	end
	local left = roll * total
	local last: number? = nil
	for index, sample in samples do
		if sample.land then
			last = index
			left -= 1 + math.max(0, sample.density) * T.densityWeight
			if left <= 0 then
				return index
			end
		end
	end
	return last
end

-- How far gone it is, 0 fresh to 1 nearly out, in steps: a replicated attribute shouldn't change every tick.
function FeralRules.unstable(energy: number, maxEnergy: number): number
	local share = 1 - math.clamp(energy / math.max(1, maxEnergy), 0, 1)
	return math.floor(share * T_STEPS + 0.5) / T_STEPS
end

local function between(rng: Random, range: { number }): number
	return range[1] + (range[2] - range[1]) * rng:NextNumber()
end

-- The pieces of one loose spell, in its domain's character. `rng` is seeded per spell, so the same spell
-- has the same body each time it wakes, and two spells of a domain differ.
function FeralRules.pieces(domain: string, palette: { Color3 }, scale: number, rng: Random): { any }
	local style = Data.styles[domain] or Data.styles.energy
	local bright = palette[1] or Color3.new(1, 1, 1)
	local parts: { any } = {
		{
			name = "Head",
			shape = "Ball",
			size = Vector3.one * Data.coreSize * scale,
			offset = Vector3.zero,
			color = (if style.dark then Color3.new(0.05, 0.03, 0.08) else bright:Lerp(Color3.new(0, 0, 0), DIM)),
			material = if style.dark then Enum.Material.SmoothPlastic else Enum.Material.Neon,
			transparency = 0,
			anim = { kind = "flicker", amount = 0.08 * scale, speed = 3, phase = rng:NextNumber() * 6.28 },
		},
	}
	for i = 1, style.count do
		-- Somewhere in a ball around the centre, biased outwards so it doesn't read as a solid lump.
		local angle, tilt = rng:NextNumber() * 2 * math.pi, math.acos(rng:NextNumber() * 2 - 1)
		local reach = 0.45 + rng:NextNumber() * 0.55
		local offset = Vector3.new(math.sin(tilt) * math.cos(angle), math.cos(tilt), math.sin(tilt) * math.sin(angle)) * style.spread * reach * scale
		local neon = rng:NextNumber() < style.glowShare
		local base = palette[rng:NextInteger(1, math.max(1, #palette))] or bright
		if style.dark and not neon then
			base = base:Lerp(Color3.new(0, 0, 0), 0.8)
		end
		local material = if neon then Enum.Material.Neon
			elseif style.material then (Enum.Material :: any)[style.material]
			else Enum.Material.SmoothPlastic
		table.insert(parts, {
			name = "Piece" .. i,
			shape = style.shape,
			size = style.stretch * between(rng, style.size) * scale,
			offset = offset,
			color = if neon then base:Lerp(Color3.new(0, 0, 0), DIM) else base,
			material = material,
			transparency = between(rng, style.alpha),
			anim = { kind = style.motion, amount = style.amount * scale, speed = between(rng, style.speed), phase = rng:NextNumber() * 6.28 },
		})
	end
	return parts
end

-- A definition CreatureRig can build. Spells can hit it and lock on to it, like any creature, but nothing
-- floats over it: you judge it by how it behaves.
function FeralRules.def(recipe: { form: string, power: number }, domain: string, palette: { Color3 }, opposed: { string }, name: string, rng: Random): any
	local scale = T.sizeBase + T.sizePerPower * recipe.power
	local resist: { [string]: number } = { [domain] = T.ownResist }
	for _, id in opposed do
		resist[id] = T.opposedWeakness
	end
	return {
		id = "feral",
		name = name,
		silent = true,
		health = T.healthBase + T.healthPerPower * recipe.power,
		walk = T.walk,
		hipHeight = T.hover,
		hitbox = Vector3.new(2.6, 2.6, 2.6) * scale,
		resist = resist,
		body = FeralRules.pieces(domain, palette, scale, rng),
		emit = { color = palette[1] or Color3.new(1, 1, 1), rate = 6 },
	}
end

-- Guards and hunters go for it. Everyone else gets out of the way when it's close.
function FeralRules.response(occupation: string, distance: number): string?
	if occupation == "guard" or occupation == "hunter" then
		return if distance <= T.guardRadius then "fight" else nil
	end
	return if distance <= T.fleeRadius then "flee" else nil
end

-- Only a spell you didn't know can teach you anything: your own backfires are worth nothing here, so
-- there's no point failing on purpose.
function FeralRules.learnsFrom(view: { dealt: number, maxHealth: number, known: boolean, studied: boolean }): boolean
	return view.dealt >= view.maxHealth * T.creditShare and not view.known and not view.studied
end

export type RecipeNames = { branch: string, property: string, verb: string, form: string }

function FeralRules.clue(names: RecipeNames): string
	return string.format(
		"Going through what it left behind, you can see how it was made: %s, working on %s, to %s, shaped as %s. You could try that in the Composer.",
		names.branch, names.property, names.verb, names.form
	)
end

-- Keeps the record of what you've studied bounded by dropping the oldest. Ties go by key, so it's stable.
function FeralRules.pruneStudied(studied: { [string]: number }, max: number)
	local keys: { string } = {}
	for key in studied do
		table.insert(keys, key)
	end
	if #keys <= max then
		return
	end
	table.sort(keys, function(a, b)
		if studied[a] ~= studied[b] then
			return studied[a] < studied[b]
		end
		return a < b
	end)
	for i = 1, #keys - max do
		studied[keys[i]] = nil
	end
end

-- The nearest loose spell you haven't already heard about from anyone, if it's near enough to worry them.
function FeralRules.rumorFor(ferals: { RumorFeral }, heard: { [string]: boolean }, x: number, z: number, roll: number): RumorFeral?
	if roll >= T.rumorChance then
		return nil
	end
	local best, bestDistance = nil, T.rumorRadius
	for _, feral in ferals do
		if not heard[feral.id] then
			local d = math.sqrt((feral.x - x) ^ 2 + (feral.z - z) ^ 2)
			if d <= bestDistance then
				best, bestDistance = feral, d
			end
		end
	end
	return best
end

function FeralRules.rumorLine(source: string, who: string, bearing: string, roll: number): string
	local lines = Data.rumors[source] or Data.rumors.npc
	local index = math.clamp(math.floor(roll * #lines) + 1, 1, #lines)
	return string.format(lines[index], who, bearing)
end

return FeralRules
