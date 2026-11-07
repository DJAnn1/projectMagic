--!strict
--[[
	FamiliarRules: the decisions behind familiars, with no Instances, so Tests/Familiars.spec can check
	every case (docs/Familiars.md). Services/FamiliarService does the running.

		shouldBond(casts, tier) -> boolean
		bondDomain(manifest, affinities) -> string           the domain it's born from
		generate(worldSeed, userId, domain, temperaments, colors) -> Identity    same inputs, same familiar
		stageOf(xp) -> number
		body(identity, stage) -> Body                        the parts to build, scaled to its stage
		statsFor(identity, stage, tier, fullHit) -> Stats
		addXp(record, amount, day) -> number                 what the daily limit let through
		learnedDomain(tally, born) -> string?                the second ability's domain
		abilitiesOf(record, stage) -> { Ability }
		decide(view) -> "idle" | "follow" | "attack" | "teleport"
		retaliation(maxHealth, targetMaxHealth) -> number
		active(now, lastAction) -> boolean
]]

local Shared = game:GetService("ReplicatedStorage"):WaitForChild("Shared")
local Seed = require(Shared.Magic.Seed)
local F = require(script.Parent.Data.Familiars)

local T = F.tuning

export type Colors = { primary: Color3, secondary: Color3, accent: Color3 }

export type Identity = {
	domain: string,
	shape: string,
	defaultName: string,
	personality: F.Personality,
	colors: Colors,
	sizeJitter: number,
	followAngle: number, -- which side of you it likes to keep to, in radians
}

export type BodyPart = {
	name: string,
	shape: string,
	size: Vector3,
	offset: Vector3,
	color: Color3,
	material: Enum.Material,
	transparency: number,
}

export type Body = { parts: { BodyPart }, hover: number, glow: Color3, emit: boolean, radius: number }

export type Stats = { maxHealth: number, bite: number, biteCooldown: number, speed: number }

export type View = {
	hasOwner: boolean,
	frozen: boolean,
	mode: string,
	ownerDistance: number,
	hasTarget: boolean,
	targetInReach: boolean,
	targetToOwner: number,
	inDuel: boolean,
}

local FamiliarRules = {}

function FamiliarRules.shouldBond(casts: number, tier: number): boolean
	return casts >= T.bondCasts or tier >= T.bondTier
end

-- Your strongest awakened domain; with none awakened, your strongest of all. Ties go by id.
function FamiliarRules.bondDomain(manifest: { string }, affinities: { [string]: number }): string
	local pool: { string } = manifest
	if #pool == 0 then
		pool = {}
		for id in affinities do
			table.insert(pool, id)
		end
	end
	local best, bestValue = "energy", -math.huge
	local sorted = table.clone(pool)
	table.sort(sorted)
	for _, id in sorted do
		local value = affinities[id] or 0
		if value > bestValue then
			best, bestValue = id, value
		end
	end
	return best
end

function FamiliarRules.personalityOf(temperaments: { string }): F.Personality
	-- Sorted, so the order a save happens to hold them in doesn't change who it is.
	local sorted = table.clone(temperaments)
	table.sort(sorted)
	for _, id in sorted do
		local personality = F.personalities[id]
		if personality then
			return personality
		end
	end
	return F.defaultPersonality
end

function FamiliarRules.generate(worldSeed: number, userId: number, domain: string, temperaments: { string }, colors: Colors): Identity
	local rng = Seed.random(worldSeed, "player:" .. userId, "familiar")
	-- A fixed order of draws: adding a new field at the end leaves everyone's familiar as it was.
	local shape = F.shapes[rng:NextInteger(1, #F.shapes)]
	local name = F.names[rng:NextInteger(1, #F.names)]
	local jitter = 0.92 + rng:NextNumber() * 0.16
	local angle = rng:NextNumber() * 2 * math.pi
	return {
		domain = domain,
		shape = shape.id,
		defaultName = name,
		personality = FamiliarRules.personalityOf(temperaments),
		colors = colors,
		sizeJitter = jitter,
		followAngle = angle,
	}
end

function FamiliarRules.stageOf(xp: number): number
	local stage = 1
	for index, def in F.stages do
		if xp >= def.xp then
			stage = index
		end
	end
	return stage
end

local function shapeOf(id: string): F.Shape
	for _, shape in F.shapes do
		if shape.id == id then
			return shape
		end
	end
	return F.shapes[1]
end

function FamiliarRules.body(identity: Identity, stage: number): Body
	local shape = shapeOf(identity.shape)
	local look = F.looks[identity.domain] or F.looks.energy
	local scale = F.stages[stage].scale * identity.sizeJitter
	local slots: { [string]: Color3 } = {
		primary = identity.colors.primary:Lerp(look.glow, 0.45),
		secondary = identity.colors.secondary:Lerp(look.glow, 0.25),
		accent = identity.colors.accent,
		eye = F.eyeColor,
	}
	local parts: { BodyPart } = {}
	local radius = 0
	for _, spec in shape.parts do
		local isEye = spec.slot == "eye"
		local size, offset = spec.size * scale, spec.offset * scale
		radius = math.max(radius, offset.Magnitude + size.Magnitude / 2)
		table.insert(parts, {
			name = spec.name,
			shape = spec.shape,
			size = size,
			offset = offset,
			color = slots[spec.slot] or slots.primary,
			material = if isEye then Enum.Material.SmoothPlastic else look.material,
			transparency = spec.transparency or 0,
		})
	end
	return { parts = parts, hover = shape.hover * scale, glow = look.glow, emit = look.emit, radius = radius }
end

-- `fullHit` is a full-strength spell at the owner's tier (DamageModel.base), so a familiar keeps its
-- share of what you can do. It's a helper: even an Ascendant's bite is under half of one of your hits.
function FamiliarRules.statsFor(identity: Identity, stage: number, tier: number, fullHit: number): Stats
	local def = F.stages[stage]
	local p = identity.personality
	local mythic = if identity.domain == "time" or identity.domain == "gravity" or identity.domain == "reality" then T.mythicDamage else 1
	return {
		maxHealth = math.floor(def.health * (1 + T.healthPerTier * math.max(0, tier - 1)) * p.health),
		bite = fullHit * def.bite * p.damage * mythic,
		biteCooldown = T.biteCooldown * p.cooldown,
		speed = T.speed * p.speed,
	}
end

export type XpRecord = { xp: number, day: number, dayXp: number }

-- Adds XP up to the daily limit, and returns how much was added.
function FamiliarRules.addXp(record: XpRecord, amount: number, day: number): number
	if record.day ~= day then
		record.day, record.dayXp = day, 0
	end
	local added = math.clamp(amount, 0, math.max(0, T.dailyXp - record.dayXp))
	record.dayXp += added
	record.xp += added
	return added
end

function FamiliarRules.killXp(targetMaxHealth: number): number
	return math.min(T.killXpMax, T.killXp + math.floor(targetMaxHealth / T.killXpHealthPer))
end

-- The domain you've cast most, other than the one it was born from. Ties go by id, so it's stable.
-- If you've cast nothing else (someone with one domain may never), it takes the first of `synergies`
-- (the domains that pair with its own), so every familiar does get a second ability.
function FamiliarRules.learnedDomain(tally: { [string]: number }, born: string, synergies: { string }?): string?
	local ids: { string } = {}
	for id in tally do
		table.insert(ids, id)
	end
	table.sort(ids)
	local best, bestCount = nil, 0
	for _, id in ids do
		local count = tally[id]
		if id ~= born and F.abilities[id] and count > bestCount then
			best, bestCount = id, count
		end
	end
	if best then
		return best
	end
	for _, id in (synergies or {}) :: { string } do
		if id ~= born and F.abilities[id] then
			return id
		end
	end
	return nil
end

function FamiliarRules.abilitiesOf(record: { domain: string, learned: string }, stage: number): { F.Ability }
	local out: { F.Ability } = {}
	if stage >= T.abilityStage and F.abilities[record.domain] then
		table.insert(out, F.abilities[record.domain])
	end
	if stage >= T.learnStage and record.learned ~= "" and F.abilities[record.learned] then
		table.insert(out, F.abilities[record.learned])
	end
	return out
end

function FamiliarRules.decide(view: View): string
	if not view.hasOwner or view.frozen then
		return "idle"
	end
	local canFight = view.hasTarget and not view.inDuel and view.mode ~= "follow"
	if view.mode == "stay" then
		if view.ownerDistance > T.stayLimit then
			return "teleport"
		end
		return if canFight and view.targetInReach then "attack" else "idle"
	end
	if view.ownerDistance > T.teleportAt then
		return "teleport"
	end
	if canFight and view.targetToOwner <= T.leash then
		return "attack"
	end
	return if view.ownerDistance > T.followAt then "follow" else "idle"
end

function FamiliarRules.retaliation(maxHealth: number, targetMaxHealth: number): number
	return maxHealth * (if targetMaxHealth >= T.bigTarget then T.retaliationBig else T.retaliation)
end

function FamiliarRules.active(now: number, lastAction: number): boolean
	return now - lastAction <= T.activeSeconds
end

function FamiliarRules.modeExists(id: any): boolean
	for _, mode in F.modes do
		if mode.id == id then
			return true
		end
	end
	return false
end

-- Trims to the length limit without cutting a character in half. Blank means no custom name.
function FamiliarRules.cleanName(raw: string): string
	local text = string.gsub(string.gsub(raw, "[%c]", ""), "^%s*(.-)%s*$", "%1")
	local length = utf8.len(text)
	if not length then
		return "" -- not valid text
	end
	if length > T.nameChars then
		text = string.sub(text, 1, (utf8.offset(text, T.nameChars + 1) or #text + 1) - 1)
	end
	return text
end

return FamiliarRules
