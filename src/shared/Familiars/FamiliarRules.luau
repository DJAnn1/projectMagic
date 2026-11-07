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
	anim: F.Anim?,
}

export type Body = { parts: { BodyPart }, hover: number, glow: Color3, emit: boolean, radius: number, top: number, light: boolean, trail: boolean }

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
	-- The domain sets the colour, so you can tell what it is at a glance. Your signature tints it, and
	-- its accents are yours alone.
	local primary = look.glow:Lerp(identity.colors.primary, 0.25)
	local slots: { [string]: Color3 } = {
		primary = primary,
		secondary = primary:Lerp(Color3.new(0, 0, 0), 0.3):Lerp(identity.colors.secondary, 0.15),
		accent = identity.colors.accent:Lerp(look.glow, 0.25),
		glow = look.glow,
		dark = F.pupilColor,
		eye = F.eyeColor,
	}
	local parts: { BodyPart } = {}
	local radius, top = 0, 0
	local function add(name: string, kind: string, size: Vector3, offset: Vector3, color: Color3, material: Enum.Material, transparency: number?, anim: F.Anim?)
		radius = math.max(radius, offset.Magnitude + size.Magnitude / 2)
		top = math.max(top, offset.Y + size.Y / 2)
		table.insert(parts, { name = name, shape = kind, size = size, offset = offset, color = color, material = material, transparency = transparency or 0, anim = anim })
	end
	for _, spec in shape.parts do
		if stage >= (spec.fromStage or 1) then
			local size, offset = spec.size * scale, spec.offset * scale
			local anim = spec.anim
			if anim and anim.kind ~= "wag" and anim.kind ~= "flap" and anim.kind ~= "orbit" then
				anim = { kind = anim.kind, amount = anim.amount * scale, speed = anim.speed, phase = anim.phase }
			end
			if spec.slot == "eye" then
				-- A white, and a pupil just in front of it. Both blink.
				local blink: F.Anim = { kind = "blink", amount = 0, speed = 0, phase = identity.followAngle }
				local moving = if anim then anim else blink
				add(spec.name, spec.shape, size, offset, slots.eye, Enum.Material.SmoothPlastic, 0, moving)
				add(spec.name .. "Pupil", "Ball", size * Vector3.new(0.58, 0.62, 0.7), offset + Vector3.new(0, 0, -size.Z * 0.32), F.pupilColor, Enum.Material.SmoothPlastic, 0, moving)
			else
				local material = if spec.slot == "glow" then Enum.Material.Neon elseif spec.slot == "dark" then Enum.Material.SmoothPlastic else look.material
				add(spec.name, spec.shape, size, offset, slots[spec.slot] or slots.primary, material, spec.transparency, anim)
			end
		end
	end
	local g = F.growth
	local bodyRadius = radius
	for i = 1, math.max(0, stage - g.moteFrom + 1) do
		local angle = (i - 1) * 2 * math.pi / math.max(1, stage - g.moteFrom + 1)
		local at = Vector3.new(math.cos(angle), 0.25, math.sin(angle)) * (bodyRadius * 0.45 + g.moteRadius)
		add("Mote" .. i, "Ball", Vector3.one * g.moteSize * scale, at, slots.glow, Enum.Material.Neon, 0, { kind = "orbit", amount = 0, speed = g.moteSpeed })
	end
	return {
		parts = parts,
		hover = shape.hover * scale,
		glow = look.glow,
		emit = look.emit,
		radius = radius,
		top = top,
		light = stage >= g.lightFrom,
		trail = stage >= g.trailFrom,
	}
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
