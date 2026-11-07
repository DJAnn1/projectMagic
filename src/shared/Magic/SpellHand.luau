--!strict
--[[
	SpellHand: the rules behind a caster's own style ("your hand in the spell", docs/SpellHand.md).
	Pure: the server seeds a hand (Services/SpellHandService), every client decodes it from the
	Player attribute "SpellHand" and draws with it (Fx/Conjure, SpellFx cast circles).

		SpellHand.generate(rng, temperaments, tier) -> Hand     seeded; temperaments lean the shape
		SpellHand.withTier(hand, tier) -> Hand
		SpellHand.encode(hand) -> string    SpellHand.decode(string?) -> Hand?   (clamped)
		SpellHand.detail(tier) -> { motes, secondRing, crown }
		SpellHand.modeFor(form) -> "hand" | "overhead" | "ground"
		SpellHand.lookFor(domain, property?) -> Data.Look
		SpellHand.progress(held, step) -> 0..3   continuous charge progress (stage index - 1, fractional)
		SpellHand.sizeAt(mode, progress) -> studs

	WIRE FORMAT: "rune|shape|spin|speed x100|pitch x100|tier", e.g. "3|2|-1|120|105|5". Decoding
	clamps every field, so a bad value can only ever draw an ordinary hand.
]]

local Data = require(script.Parent.Data.SpellHand)

export type Hand = {
	rune: number, -- 1..#Data.runes
	shape: number, -- 1..#Data.shapes
	spin: number, -- +1 or -1
	speed: number, -- turns a second
	pitch: number,
	tier: number, -- 0..8
}

local SpellHand = {}

SpellHand.data = Data

local function pickShape(rng: Random, temperaments: { string }): number
	local weights: { number } = {}
	local total = 0
	for i, shape in Data.shapes do
		local w = 1
		for _, temperament in temperaments do
			if Data.temperamentShape[temperament] == shape then
				w = Data.temperamentWeight
			end
		end
		weights[i] = w
		total += w
	end
	local roll = rng:NextNumber() * total
	for i, w in weights do
		roll -= w
		if roll <= 0 then
			return i
		end
	end
	return #Data.shapes
end

function SpellHand.generate(rng: Random, temperaments: { string }, tier: number): Hand
	-- Fixed draw order: adding a field later must append, never reorder, or every hand changes.
	local rune = rng:NextInteger(1, #Data.runes)
	local shape = pickShape(rng, temperaments)
	local spin = if rng:NextNumber() < 0.5 then -1 else 1
	local speed = Data.spinSpeed[1] + rng:NextNumber() * (Data.spinSpeed[2] - Data.spinSpeed[1])
	local pitch = Data.pitch[1] + rng:NextNumber() * (Data.pitch[2] - Data.pitch[1])
	return {
		rune = rune,
		shape = shape,
		spin = spin,
		speed = math.floor(speed * 100 + 0.5) / 100,
		pitch = math.floor(pitch * 100 + 0.5) / 100,
		tier = math.clamp(math.floor(tier), 0, 8),
	}
end

function SpellHand.withTier(hand: Hand, tier: number): Hand
	local copy = table.clone(hand)
	copy.tier = math.clamp(math.floor(tier), 0, 8)
	return copy
end

function SpellHand.encode(hand: Hand): string
	return string.format(
		"%d|%d|%d|%d|%d|%d",
		hand.rune, hand.shape, hand.spin, math.floor(hand.speed * 100 + 0.5), math.floor(hand.pitch * 100 + 0.5), hand.tier
	)
end

local cache: { [string]: Hand } = {}
local cached = 0

function SpellHand.decode(raw: string?): Hand?
	if typeof(raw) ~= "string" or raw == "" then
		return nil
	end
	local hit = cache[raw]
	if hit then
		return hit
	end
	local fields: { number } = {}
	for part in string.gmatch(raw, "[^|]+") do
		table.insert(fields, tonumber(part) or 0)
	end
	if #fields < 6 then
		return nil
	end
	local hand: Hand = table.freeze({
		rune = math.clamp(math.floor(fields[1]), 1, #Data.runes),
		shape = math.clamp(math.floor(fields[2]), 1, #Data.shapes),
		spin = if fields[3] < 0 then -1 else 1,
		speed = math.clamp(fields[4] / 100, Data.spinSpeed[1], Data.spinSpeed[2]),
		pitch = math.clamp(fields[5] / 100, Data.pitch[1], Data.pitch[2]),
		tier = math.clamp(math.floor(fields[6]), 0, 8),
	}) :: any
	if cached > 200 then
		table.clear(cache)
		cached = 0
	end
	cache[raw] = hand
	cached += 1
	return hand
end

function SpellHand.detail(tier: number): { motes: number, secondRing: boolean, crown: boolean }
	local d = Data.detail
	return {
		motes = math.clamp(math.floor(tier / d.motesEvery), 0, d.motesMax),
		secondRing = tier >= d.secondRingAt,
		crown = tier >= d.crownAt,
	}
end

function SpellHand.modeFor(form: string?): string
	return Data.formMode[form or ""] or "hand"
end

function SpellHand.lookFor(domain: string?, property: string?): any
	local key = tostring(domain) .. "." .. tostring(property)
	return Data.properties[key] or Data.domains[domain or ""] or Data.domains.energy
end

function SpellHand.shapeName(hand: Hand?): string
	return Data.shapes[if hand then hand.shape else 1]
end

function SpellHand.progress(held: number, step: number): number
	if step <= 0 then
		return 0
	end
	return math.clamp(held / step, 0, 3)
end

-- The core grows over the safe stages and only a little more when overcharged.
function SpellHand.sizeAt(mode: string, progress: number): number
	local range = Data.size[mode] or Data.size.hand
	local t = math.clamp(progress / 2, 0, 1) + math.clamp(progress - 2, 0, 1) * 0.15
	return range[1] + (range[2] - range[1]) * t
end

return SpellHand
