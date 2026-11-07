--!strict
--[[
	FeralRules: the decisions behind feral spells, with no Instances, so Tests/FeralSpells.spec can check
	every case (docs/FeralSpells.md). Services/FeralService does the running.

		escapeChance(severity) -> number
		mayEscape(view) -> boolean                  the limits on one getting loose
		energyFor(power) -> seconds
		drainRate(density) -> multiplier            thick ley energy keeps it going longer
		pickDirection(samples, roll) -> index       leans towards energy, never into the sea
		def(recipe, domain, palette, opposed, name) -> a CreatureRig definition
		learnsFrom(view) -> boolean                 only a spell you didn't know can teach you
		clue(recipe, names) -> string
		pruneStudied(studied, max)                  bounded, oldest first
		rumorFor(ferals, heard, x, z, roll) -> feral?
		rumorLine(source, who, bearing, roll) -> string
]]

local Data = require(script.Parent.Data.FeralData)

local T = Data.tuning

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

function FeralRules.bodyFor(form: string): { Data.Part }
	return Data.bodies[Data.forms[form] or Data.defaultBody] or Data.bodies[Data.defaultBody]
end

-- A definition CreatureRig can build. Spells can hit it and lock on to it, like any creature.
function FeralRules.def(recipe: { form: string, power: number }, domain: string, palette: { Color3 }, opposed: { string }, name: string): any
	local scale = T.sizeBase + T.sizePerPower * recipe.power
	local bright = palette[1] or Color3.new(1, 1, 1)
	local colors: { [string]: Color3 } = {
		core = bright:Lerp(Color3.new(0, 0, 0), 0.42), -- dimmed: Bloom blows bright Neon out to white
		body = bright,
		haze = palette[2] or bright,
	}
	local parts = {}
	for _, spec in FeralRules.bodyFor(recipe.form) do
		table.insert(parts, {
			name = spec.name,
			shape = spec.shape,
			size = spec.size * scale,
			offset = spec.offset * scale,
			color = colors[spec.slot] or bright,
			material = if spec.slot == "core" then Enum.Material.Neon else Enum.Material.SmoothPlastic,
			transparency = spec.transparency,
		})
	end
	local resist: { [string]: number } = { [domain] = T.ownResist }
	for _, id in opposed do
		resist[id] = T.opposedWeakness
	end
	return {
		id = "feral",
		name = name,
		health = T.healthBase + T.healthPerPower * recipe.power,
		walk = T.walk,
		hipHeight = T.hover,
		hitbox = Vector3.new(2.6, 2.6, 2.6) * scale,
		resist = resist,
		body = parts,
		emit = { color = bright, rate = 8 },
	}
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
